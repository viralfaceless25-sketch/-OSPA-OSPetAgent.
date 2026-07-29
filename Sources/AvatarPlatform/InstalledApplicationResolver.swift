import AppKit
import AvatarCore
import Foundation

public enum InstalledApplicationResolutionError: Error, Equatable {
    case notFound
    case ambiguousExactName
}

@MainActor
public final class InstalledApplicationResolver {
    private var cachedInstalledApplications: [ResolvedApplication]?

    public init() {}

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

    private func application(at url: URL) -> ResolvedApplication? {
        guard let bundle = Bundle(url: url),
            let bundleIdentifier = bundle.bundleIdentifier
        else {
            return nil
        }
        if let packageType = bundle.object(
            forInfoDictionaryKey: "CFBundlePackageType"
        ) as? String,
            packageType != "APPL"
        {
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
}
