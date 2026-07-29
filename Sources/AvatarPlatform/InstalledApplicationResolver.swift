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

        let domains: FileManager.SearchPathDomainMask = [
            .localDomainMask,
            .systemDomainMask,
            .userDomainMask,
        ]
        let roots = FileManager.default.urls(
            for: .applicationDirectory,
            in: domains
        )
        for root in roots {
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
                continue
            }

            for case let url as URL in enumerator
            where url.pathExtension.caseInsensitiveCompare("app") == .orderedSame {
                urls.insert(url.standardizedFileURL)
            }
        }

        let applications = urls.compactMap(application(at:))
        cachedInstalledApplications = applications
        return applications
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

        cachedInstalledApplications = urls.compactMap(application(at:))
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

    private func application(at url: URL) -> ResolvedApplication? {
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
