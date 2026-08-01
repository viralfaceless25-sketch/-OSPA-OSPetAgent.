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
    /// A `.ambiguousExactName` failure is not a disagreement between the two
    /// lists: it means this machine genuinely has two bundles that share a
    /// display name, and `resolveExact(named:)` deliberately fails closed
    /// rather than guessing which one the caller meant. That is acceptable.
    /// A `.notFound` (or any other error) means the inventory produced a name
    /// the resolver cannot see at all, which is the real defect this test
    /// exists to catch.
    @Test("Every displayName this source produces resolves through InstalledApplicationResolver")
    @MainActor
    func displayNamesResolveThroughInstalledApplicationResolver() {
        let inventory = SpotlightApplicationUsageSource().currentInventory()
        let resolver = InstalledApplicationResolver()

        for app in inventory {
            do {
                let resolved = try resolver.resolveExact(named: app.displayName)
                #expect(resolved.identity.displayName == app.displayName)
            } catch InstalledApplicationResolutionError.ambiguousExactName {
                // Duplicate display names exist on this machine; the resolver
                // fails closed rather than guessing. Not a defect.
                continue
            } catch {
                Issue.record(
                    "resolveExact(named: \"\(app.displayName)\") failed: \(error)"
                )
            }
        }
    }
}
