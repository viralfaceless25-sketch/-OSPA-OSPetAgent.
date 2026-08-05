import AvatarCore
import Foundation
import Testing

@testable import AvatarPlatform

@Suite("Application usage source")
struct ApplicationUsageSourceTests {
    @Test("Standard directories are the user-facing application folders only")
    func standardDirectories() {
        let paths = SpotlightApplicationUsageSource.standardDirectories.map(\.path)
        #expect(paths.contains("/Applications"))
        #expect(paths.contains("/System/Applications"))
    }

    @Test("Whole days are computed by calendar difference, not by rounding hours")
    func bucketsWholeDays() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let elevenHoursAgo = now.addingTimeInterval(-11 * 3600)
        #expect(
            SpotlightApplicationUsageSource.wholeDaysBetween(
                elevenHoursAgo, and: now
            ) == 0
        )
        let threeDaysAgo = now.addingTimeInterval(-3 * 86_400)
        #expect(
            SpotlightApplicationUsageSource.wholeDaysBetween(
                threeDaysAgo, and: now
            ) == 3
        )
    }

    @Test("A future timestamp is clamped to today rather than going negative")
    func clampsFutureDates() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let tomorrow = now.addingTimeInterval(86_400)
        #expect(
            SpotlightApplicationUsageSource.wholeDaysBetween(tomorrow, and: now) == 0
        )
    }

    @Test("A real inventory read returns apps and never crashes")
    func readsRealInventory() {
        let inventory = SpotlightApplicationUsageSource().currentInventory()
        #expect(!inventory.isEmpty)
        #expect(inventory.allSatisfy { !$0.displayName.isEmpty })
        #expect(inventory.allSatisfy { !$0.displayName.hasSuffix(".app") })
        #expect(inventory.allSatisfy { ($0.lastUsedDaysAgo ?? 0) >= 0 })
    }

    /// Cross-task guard: the validator (`BrainProposalValidator`) certifies a
    /// model-chosen name against *this* source's inventory, but it is
    /// `InstalledApplicationResolver.resolveExact(named:)` that ultimately
    /// turns a certified name into a bundle to launch. If the two ever
    /// disagreed about an app's display name, the validator could certify a
    /// name the resolver then fails to find, or resolves to the wrong bundle
    /// -- membership in this inventory would stop implying "the resolver can
    /// launch this." `SpotlightApplicationUsageSource.usage(forApplicationAt:)`
    /// derives `displayName` via `InstalledApplicationResolver.application(at:)`
    /// specifically so this holds by construction; this test pins that
    /// agreement against the real, installed apps on this machine rather than
    /// trusting it never regresses silently.
    ///
    /// `.ambiguousExactName` is now a hard failure too, not an accepted
    /// outcome. Before this fix, `currentInventory()` kept one arbitrary
    /// entry per duplicated name, so a genuinely ambiguous name (this
    /// machine has two bundles named "JDownloader2" and two named "Siri")
    /// could still be *offered* by the inventory and then fail at resolve
    /// time. Now `currentInventory()` excludes any name that occurs more
    /// than once anywhere in the shared application-directory universe
    /// `InstalledApplicationResolver` scans (see
    /// `InstalledApplicationResolver.applicationBundleURLs(under:)`), so a
    /// name reaching this test is unique in that shared filesystem universe.
    /// The resolver may additionally see a currently running or Spotlight-
    /// registered app outside those roots. If that dynamic supplement makes
    /// the name ambiguous, resolution still fails closed and this real-system
    /// guard reports the offending app; `.ambiguousExactName` is therefore
    /// treated the same as `.notFound`, not silently accepted.
    @Test("Every displayName this source produces resolves through InstalledApplicationResolver")
    @MainActor
    func displayNamesResolveThroughInstalledApplicationResolver() {
        let inventory = SpotlightApplicationUsageSource().currentInventory()
        let resolver = InstalledApplicationResolver()

        for app in inventory {
            do {
                let resolved = try resolver.resolveExact(named: app.displayName)
                #expect(resolved.identity.displayName == app.displayName)
            } catch {
                Issue.record(
                    "resolveExact(named: \"\(app.displayName)\") failed: \(error)"
                )
            }
        }
    }

    // MARK: - Synthetic bundles

    /// Builds a minimal, real `.app` bundle on disk (just enough for
    /// `Bundle(url:)` to load its `Info.plist`) so the blank-name and
    /// duplicate-name fixes below can be exercised deterministically,
    /// without depending on whatever happens to be installed on the machine
    /// running the test.
    private static func makeAppBundle(
        named name: String,
        in root: URL,
        bundleIdentifier: String,
        displayName: String?
    ) throws -> URL {
        let appURL = root.appendingPathComponent(name)
        let contentsURL = appURL.appendingPathComponent("Contents")
        try FileManager.default.createDirectory(
            at: contentsURL, withIntermediateDirectories: true
        )

        var infoPlist: [String: Any] = [
            "CFBundleIdentifier": bundleIdentifier,
            "CFBundlePackageType": "APPL",
            "CFBundleExecutable": "Stub",
        ]
        if let displayName {
            infoPlist["CFBundleDisplayName"] = displayName
        }

        let plistData = try PropertyListSerialization.data(
            fromPropertyList: infoPlist, format: .xml, options: 0
        )
        try plistData.write(to: contentsURL.appendingPathComponent("Info.plist"))
        return appURL
    }

    private static func withTemporaryDirectory(
        _ body: (URL) throws -> Void
    ) throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ApplicationUsageSourceTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try body(root)
    }

    /// Important 3: `CFBundleDisplayName ?? CFBundleName ?? filename` only
    /// falls through on a genuinely *missing* key -- a present-but-blank
    /// `CFBundleDisplayName` is not skipped by that chain, so a malformed
    /// bundle could otherwise produce an empty or whitespace-only name that
    /// flows straight into the model's system prompt. This pins the guard
    /// that rejects it, using synthetic bundles rather than hoping the real
    /// machine happens to have a malformed one.
    @Test("A blank display name, empty or whitespace-only, is rejected")
    func rejectsBlankDisplayName() throws {
        try Self.withTemporaryDirectory { root in
            let empty = try Self.makeAppBundle(
                named: "Empty.app",
                in: root,
                bundleIdentifier: "com.ospa.test.empty",
                displayName: ""
            )
            let whitespaceOnly = try Self.makeAppBundle(
                named: "WhitespaceOnly.app",
                in: root,
                bundleIdentifier: "com.ospa.test.whitespace",
                displayName: "  \t "
            )

            #expect(
                SpotlightApplicationUsageSource.usage(forApplicationAt: empty, now: Date())
                    == nil
            )
            #expect(
                SpotlightApplicationUsageSource.usage(
                    forApplicationAt: whitespaceOnly, now: Date()
                ) == nil
            )
        }
    }

    /// Important 4: a display name that names more than one bundle must be
    /// excluded from the inventory entirely, not deduplicated to an
    /// arbitrary winner -- keeping one would attach the wrong bundle's usage
    /// stats to the kept entry, and the name would still fail at resolve
    /// time with `.ambiguousExactName` the moment it was offered. Two
    /// bundles here share a display name; a third is unique. Only the
    /// unique one should survive.
    @Test("A duplicated display name is excluded from the inventory entirely")
    func excludesDuplicateDisplayNames() throws {
        try Self.withTemporaryDirectory { root in
            _ = try Self.makeAppBundle(
                named: "First.app",
                in: root,
                bundleIdentifier: "com.ospa.test.duplicate.first",
                displayName: "Duplicate Test App"
            )
            _ = try Self.makeAppBundle(
                named: "Second.app",
                in: root,
                bundleIdentifier: "com.ospa.test.duplicate.second",
                displayName: "Duplicate Test App"
            )
            _ = try Self.makeAppBundle(
                named: "Unique.app",
                in: root,
                bundleIdentifier: "com.ospa.test.unique",
                displayName: "Unique Test App"
            )

            let inventory = SpotlightApplicationUsageSource(searchDirectories: [root])
                .currentInventory()

            #expect(!inventory.contains { $0.displayName == "Duplicate Test App" })
            #expect(inventory.contains { $0.displayName == "Unique Test App" })
        }
    }

    @Test("Names the resolver treats as equal are excluded as duplicates")
    func excludesResolverEquivalentDisplayNames() throws {
        try Self.withTemporaryDirectory { root in
            _ = try Self.makeAppBundle(
                named: "First.app",
                in: root,
                bundleIdentifier: "com.ospa.test.normalized.first",
                displayName: "Résumé Test App"
            )
            _ = try Self.makeAppBundle(
                named: "Second.app",
                in: root,
                bundleIdentifier: "com.ospa.test.normalized.second",
                displayName: "resume test app"
            )

            let inventory = SpotlightApplicationUsageSource(searchDirectories: [root])
                .currentInventory()

            #expect(
                !inventory.contains {
                    $0.displayName == "Résumé Test App"
                        || $0.displayName == "resume test app"
                }
            )
        }
    }
}
