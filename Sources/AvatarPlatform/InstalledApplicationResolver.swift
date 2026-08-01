import AppKit
import AvatarCore
import Foundation

public enum InstalledApplicationResolutionError: Error, Equatable {
    case notFound
    case ambiguousExactName
}

@MainActor
public final class InstalledApplicationResolver: NSObject {
    private var cachedInstalledApplications: [ResolvedApplication]?
    private var metadataQuery: NSMetadataQuery?
    private var metadataCompletion: (@MainActor ([ResolvedApplication], Bool) -> Void)?
    private var metadataIndexComplete = false

    public override init() {
        super.init()
    }

    public func resolveExact(
        named requestedName: String
    ) throws -> ResolvedApplication {
        let exactMatches = installedApplications().filter {
            normalize($0.identity.displayName) == normalize(requestedName)
        }
        guard !exactMatches.isEmpty else {
            throw InstalledApplicationResolutionError.notFound
        }
        guard exactMatches.count == 1, let match = exactMatches.first else {
            throw InstalledApplicationResolutionError.ambiguousExactName
        }

        let running = !NSRunningApplication.runningApplications(
            withBundleIdentifier: match.identity.bundleIdentifier
        ).isEmpty
        return ResolvedApplication(
            identity: match.identity,
            applicationURL: match.applicationURL,
            isRunning: running
        )
    }

    public func resolveExact(
        url expectedURL: URL,
        identity expectedIdentity: AppIdentity
    ) throws -> ResolvedApplication {
        guard
            let match = applicationsWithCurrentRunningState().first(where: {
                $0.applicationURL.standardizedFileURL
                    == expectedURL.standardizedFileURL
                    && $0.identity == expectedIdentity
            })
        else {
            throw InstalledApplicationResolutionError.notFound
        }
        return match
    }

    /// Returns standard/running apps immediately, then registered Spotlight apps.
    public func loadIndex(
        refresh: Bool = false,
        completion:
            @escaping @MainActor ([ResolvedApplication], Bool) -> Void
    ) {
        if refresh {
            cachedInstalledApplications = nil
            metadataIndexComplete = false
        }

        completion(
            applicationsWithCurrentRunningState(),
            metadataIndexComplete
        )
        guard !metadataIndexComplete, metadataQuery == nil else { return }

        metadataCompletion = completion
        let query = NSMetadataQuery()
        query.predicate = NSPredicate(
            format: "%K == %@",
            "kMDItemContentType",
            "com.apple.application-bundle"
        )
        query.searchScopes = [NSMetadataQueryLocalComputerScope]
        query.valueListAttributes = ["kMDItemPath"]
        metadataQuery = query
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(metadataQueryDidFinish(_:)),
            name: .NSMetadataQueryDidFinishGathering,
            object: query
        )
        query.start()
    }

    public func currentIndex() -> [ResolvedApplication] {
        applicationsWithCurrentRunningState()
    }

    private func installedApplications() -> [ResolvedApplication] {
        if let cachedInstalledApplications {
            return cachedInstalledApplications
        }

        var urls = Set<URL>()
        let workspace = NSWorkspace.shared

        for running in workspace.runningApplications {
            if let bundleURL = running.bundleURL {
                urls.insert(bundleURL.standardizedFileURL)
            }
        }

        for root in Self.applicationDirectoryRoots {
            urls.formUnion(Self.applicationBundleURLs(under: root))
        }

        let applications = urls.compactMap(Self.application(at:))
        cachedInstalledApplications = applications
        return applications
    }

    /// The root "Applications" directories macOS designates across every
    /// `FileManager` search-path domain (local, system, user) -- typically
    /// `/Applications`, `/System/Applications`, a sealed-volume mirror of the
    /// latter, and `~/Applications`. Exposed here (not `public`, since it is
    /// an implementation detail of how this resolver builds its universe of
    /// apps, not a capability callers outside the module should depend on)
    /// so `ApplicationUsageSource` can enumerate the exact same root set this
    /// resolver does, rather than maintaining an independently written list
    /// that can silently drift from what `resolveExact(named:)` actually
    /// scans. See `applicationBundleURLs(under:)` for the traversal itself.
    nonisolated static var applicationDirectoryRoots: [URL] {
        FileManager.default.urls(
            for: .applicationDirectory,
            in: [.localDomainMask, .systemDomainMask, .userDomainMask]
        )
    }

    /// All `.app` bundle URLs reachable under `root`: recurses into ordinary
    /// subfolders (e.g. a vendor's own subfolder nested under `/Applications`)
    /// but never into a bundle's own internals (`.skipsPackageDescendants`
    /// stops descent the moment an item is itself recognized as a package).
    /// This is deliberately more than a non-recursive directory listing --
    /// nested vendor subfolders are real, user-visible install locations,
    /// and a caller that only checked the top level of `root` could miss an
    /// app this resolver can still find and launch, or worse, miss a
    /// same-named duplicate living one level deeper. `ApplicationUsageSource`
    /// calls this directly instead of re-implementing the traversal, so the
    /// two components can never disagree about which URLs are candidates.
    nonisolated static func applicationBundleURLs(under root: URL) -> [URL] {
        guard
            let enumerator = FileManager.default.enumerator(
                at: root,
                includingPropertiesForKeys: [
                    .isDirectoryKey,
                    .isPackageKey,
                ],
                options: [
                    .skipsHiddenFiles,
                    .skipsPackageDescendants,
                ]
            )
        else {
            return []
        }

        return enumerator.compactMap { entry -> URL? in
            guard let url = entry as? URL,
                url.pathExtension.caseInsensitiveCompare("app") == .orderedSame
            else {
                return nil
            }
            return url.standardizedFileURL
        }
    }

    private func applicationsWithCurrentRunningState()
        -> [ResolvedApplication]
    {
        let runningBundleIdentifiers = Set(
            NSWorkspace.shared.runningApplications.compactMap(
                \.bundleIdentifier
            )
        )
        return installedApplications().map { application in
            ResolvedApplication(
                identity: application.identity,
                applicationURL: application.applicationURL,
                isRunning: runningBundleIdentifiers.contains(
                    application.identity.bundleIdentifier
                )
            )
        }
    }

    @objc private func metadataQueryDidFinish(
        _ notification: Notification
    ) {
        guard
            let query = notification.object as? NSMetadataQuery,
            query === metadataQuery
        else {
            return
        }

        query.disableUpdates()
        var urls = Set(
            installedApplications().map {
                $0.applicationURL.standardizedFileURL
            }
        )
        for case let item as NSMetadataItem in query.results {
            if let path = item.value(
                forAttribute: "kMDItemPath"
            ) as? String {
                urls.insert(
                    URL(fileURLWithPath: path).standardizedFileURL
                )
            }
        }

        cachedInstalledApplications = urls.compactMap(Self.application(at:))
        metadataIndexComplete = true
        query.stop()
        NotificationCenter.default.removeObserver(
            self,
            name: .NSMetadataQueryDidFinishGathering,
            object: query
        )
        metadataQuery = nil

        let completion = metadataCompletion
        metadataCompletion = nil
        completion?(applicationsWithCurrentRunningState(), true)
    }

    /// Derives the identity macOS itself would report for an app bundle:
    /// `CFBundleDisplayName`, falling back to `CFBundleName`, falling back to
    /// the filename. `nonisolated static` -- not actor state, so
    /// `ApplicationUsageSource` can share this exact derivation instead of
    /// re-deriving display names its own way and risking disagreement with
    /// what `resolveExact(named:)` will later resolve.
    nonisolated static func application(at url: URL) -> ResolvedApplication? {
        guard let bundle = Bundle(url: url),
            let bundleIdentifier = bundle.bundleIdentifier
        else {
            return nil
        }
        let packageType =
            bundle.object(
                forInfoDictionaryKey: "CFBundlePackageType"
            ) as? String
        guard Self.isSupportedPackageType(packageType) else {
            return nil
        }

        let displayName =
            bundle.object(
                forInfoDictionaryKey: "CFBundleDisplayName"
            ) as? String
            ?? bundle.object(
                forInfoDictionaryKey: "CFBundleName"
            ) as? String
            ?? url.deletingPathExtension().lastPathComponent

        return ResolvedApplication(
            identity: AppIdentity(
                bundleIdentifier: bundleIdentifier,
                displayName: displayName
            ),
            applicationURL: url,
            isRunning: false
        )
    }

    private func normalize(_ value: String) -> String {
        value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
    }

    nonisolated static func isSupportedPackageType(_ value: String?) -> Bool {
        value == "APPL" || value == "AAPL"
    }
}
