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
    /// Delegates to `InstalledApplicationResolver.applicationDirectoryRoots`
    /// -- the same root "Applications" directories that resolver scans --
    /// rather than maintaining an independently written list here. An
    /// independent list is exactly how the two components' search spaces
    /// drifted apart before: this one didn't include the sealed-volume
    /// system-apps mirror the resolver's `FileManager` search path picks up,
    /// and it listed `/System/Applications/Utilities` as its own root only
    /// because it wasn't recursing into `/System/Applications` to find it.
    /// See `currentInventory()` for how the traversal itself is kept in sync
    /// too -- matching roots alone is not sufficient.
    public static var standardDirectories: [URL] {
        InstalledApplicationResolver.applicationDirectoryRoots
    }

    private let searchDirectories: [URL]

    public init(searchDirectories: [URL] = SpotlightApplicationUsageSource.standardDirectories) {
        self.searchDirectories = searchDirectories
    }

    /// Builds the inventory the validator certifies model-chosen names
    /// against. Two properties matter for that certification to actually
    /// mean "the resolver can launch this":
    ///
    /// 1. **Same application-directory universe as the resolver.** Each directory in
    ///    `searchDirectories` is walked with
    ///    `InstalledApplicationResolver.applicationBundleURLs(under:)` --
    ///    the resolver's own traversal (recurses into ordinary subfolders,
    ///    never into a bundle's internals) -- rather than a
    ///    non-recursive listing. "Only top-level bundles are considered"
    ///    means only in the sense of never descending into a `.app`
    ///    package's own `Contents/...`; it does NOT mean skipping ordinary
    ///    subfolders nested under a search directory, which the resolver
    ///    does descend into and this source must too.
    /// 2. **No ambiguous names offered.** A display name that names more
    ///    than one bundle anywhere in that universe is dropped from the
    ///    inventory entirely -- not deduplicated to an arbitrary winner.
    ///    Keeping one of two same-named bundles would attach the *other*
    ///    bundle's `openCount` / `lastUsedDaysAgo` to the kept entry, and
    ///    the name would still fail at resolve time with
    ///    `.ambiguousExactName` the moment the model asked for it. The resolver
    ///    can also supplement this shared filesystem universe with currently
    ///    running or Spotlight-registered app URLs; any collision introduced by
    ///    those dynamic sources still fails closed at resolution time. Failing
    ///    to ever offer the name is strictly better than offering it and
    ///    failing later.
    public func currentInventory() -> [InstalledApplicationUsage] {
        let now = Date()
        var candidateURLs = Set<URL>()
        for directory in searchDirectories {
            candidateURLs.formUnion(
                InstalledApplicationResolver.applicationBundleURLs(under: directory)
            )
        }

        var usageByName: [String: InstalledApplicationUsage] = [:]
        var occurrencesByName: [String: Int] = [:]
        for url in candidateURLs {
            guard let usage = Self.usage(forApplicationAt: url, now: now) else { continue }
            let normalizedName = InstalledApplicationResolver.normalizedApplicationName(
                usage.displayName
            )
            occurrencesByName[normalizedName, default: 0] += 1
            usageByName[normalizedName] = usage
        }

        return
            usageByName
            .compactMap { normalizedName, usage in
                occurrencesByName[normalizedName] == 1 ? usage : nil
            }
            .sorted { $0.displayName < $1.displayName }
    }

    /// Derives `displayName` via `InstalledApplicationResolver.application(at:)`
    /// -- the same function `InstalledApplicationResolver` uses to build the
    /// list `resolveExact(named:)` searches, including its supported-package-type
    /// filter -- rather than re-deriving it independently from the filename.
    /// Sharing the derivation guarantees that *for a given URL* the two
    /// components compute the same name. It does NOT by itself guarantee the
    /// two components see the same *set* of URLs (see `currentInventory()`
    /// and `InstalledApplicationResolver.applicationBundleURLs(under:)` for
    /// that), and it does not skip a display name that is present but empty:
    /// `CFBundleDisplayName ?? CFBundleName ?? filename` only falls through
    /// on a genuinely missing key, never on an empty or whitespace-only
    /// string, so a malformed bundle could otherwise produce a blank name
    /// that flows straight into the model's system prompt. Both gaps are
    /// closed explicitly for the shared application-directory universe by
    /// `currentInventory()`, and for the blank-name case immediately below.
    public static func usage(
        forApplicationAt url: URL, now: Date
    ) -> InstalledApplicationUsage? {
        guard let resolved = InstalledApplicationResolver.application(at: url) else {
            return nil
        }
        let displayName = resolved.identity.displayName
        guard !displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }

        guard let item = MDItemCreateWithURL(nil, url as CFURL) else {
            return InstalledApplicationUsage(
                displayName: displayName, openCount: 0, lastUsedDaysAgo: nil
            )
        }

        // `kMDItemLastUsedDate` is a documented attribute with a real header
        // declaration in `Metadata.framework`, so it is referenced directly.
        // `kMDItemUseCount`, despite being the conventional way every
        // developer reads Spotlight's open count, has no such declaration
        // anywhere in the SDK headers -- the symbol exists in the compiled
        // framework but Swift (and Clang) cannot see it without one, so the
        // raw string literal is the only way to reference it; there is no
        // framework constant to switch to.
        let count =
            (MDItemCopyAttribute(item, "kMDItemUseCount" as CFString) as? NSNumber)?
            .intValue ?? 0
        let lastUsed = MDItemCopyAttribute(item, kMDItemLastUsedDate) as? Date

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
