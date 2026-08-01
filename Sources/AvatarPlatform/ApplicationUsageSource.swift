import AvatarCore
import CoreServices
import Foundation

/// Supplies the installed-app inventory the model reasons over, and that the
/// validator grounds the model's answer against.
public protocol ApplicationUsageSource: Sendable {
    func currentInventory() -> [InstalledApplicationUsage]
}

/// Reads how much each app is actually used from macOS's own Spotlight metadata
/// (`kMDItemUseCount`, `kMDItemLastUsedDate`).
///
/// This is why OSPA needs no background observer and no learned-preference
/// store: the operating system already knows, the read is one-shot and
/// read-only, and it requires no additional permission.
public struct SpotlightApplicationUsageSource: ApplicationUsageSource {
    public static var standardDirectories: [URL] {
        var directories = [
            URL(fileURLWithPath: "/Applications"),
            URL(fileURLWithPath: "/System/Applications"),
            URL(fileURLWithPath: "/System/Applications/Utilities"),
        ]
        directories.append(
            FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Applications")
        )
        return directories
    }

    private let searchDirectories: [URL]

    public init(searchDirectories: [URL] = SpotlightApplicationUsageSource.standardDirectories) {
        self.searchDirectories = searchDirectories
    }

    public func currentInventory() -> [InstalledApplicationUsage] {
        let now = Date()
        var seen = Set<String>()
        var inventory: [InstalledApplicationUsage] = []

        for directory in searchDirectories {
            let contents =
                (try? FileManager.default.contentsOfDirectory(
                    at: directory,
                    includingPropertiesForKeys: nil,
                    options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]
                )) ?? []

            for url in contents where url.pathExtension == "app" {
                guard let usage = Self.usage(forApplicationAt: url, now: now),
                    seen.insert(usage.displayName).inserted
                else { continue }
                inventory.append(usage)
            }
        }
        return inventory
    }

    /// Only top-level bundles are considered. Spotlight's raw application query
    /// also returns embedded helpers and updaters, which are not apps a person
    /// would ever ask for.
    ///
    /// `displayName` is derived by `InstalledApplicationResolver.application(at:)`
    /// rather than re-derived here from the filename. That function is the same
    /// one `InstalledApplicationResolver` uses to build the list that
    /// `resolveExact(named:)` searches, and it also applies the same
    /// supported-package-type filter. Deriving the name any other way (e.g.
    /// from the bundle filename) risks this source certifying a name that
    /// `resolveExact(named:)` cannot find, or resolves to a different bundle --
    /// see the cross-task note in the Task 4 brief. Sharing the function is
    /// what makes the two lists agree by construction instead of by luck.
    public static func usage(
        forApplicationAt url: URL, now: Date
    ) -> InstalledApplicationUsage? {
        guard let resolved = InstalledApplicationResolver.application(at: url) else {
            return nil
        }
        let displayName = resolved.identity.displayName

        guard let item = MDItemCreateWithURL(nil, url as CFURL) else {
            return InstalledApplicationUsage(
                displayName: displayName, openCount: 0, lastUsedDaysAgo: nil
            )
        }

        let count =
            (MDItemCopyAttribute(item, "kMDItemUseCount" as CFString) as? NSNumber)?
            .intValue ?? 0
        let lastUsed =
            MDItemCopyAttribute(item, "kMDItemLastUsedDate" as CFString) as? Date

        return InstalledApplicationUsage(
            displayName: displayName,
            openCount: count,
            lastUsedDaysAgo: lastUsed.map { wholeDaysBetween($0, and: now) }
        )
    }

    /// Calendar-day difference, clamped at zero. Quantizing to whole days is what
    /// keeps the model's system prompt byte-stable between requests, which is
    /// what makes prompt caching work.
    public static func wholeDaysBetween(_ earlier: Date, and later: Date) -> Int {
        let days = Calendar.current.dateComponents(
            [.day], from: earlier, to: later
        ).day ?? 0
        return max(0, days)
    }
}
