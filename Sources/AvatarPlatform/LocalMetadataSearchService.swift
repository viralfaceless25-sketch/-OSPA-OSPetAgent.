import AvatarCore
import Foundation

public enum LocalMetadataSearchError: Error, Equatable {
    case queryTooShort
    case noPersonalScope
    case unavailableScope(LocalSearchScopeID)
    case queryDidNotStart
}

@MainActor
public final class LocalMetadataSearchService: NSObject {
    private var metadataQuery: NSMetadataQuery?
    private var completion:
        (@MainActor (Result<[LocalSearchItem], LocalMetadataSearchError>) -> Void)?
    private var activeScopeRoots: [LocalSearchScopeID: URL] = [:]

    public override init() {
        super.init()
    }

    /// Queries filename metadata only. It never requests content attributes.
    public func search(
        nameQuery: String,
        approvedScopes: Set<LocalSearchScopeID>,
        completion:
            @escaping @MainActor (
                Result<[LocalSearchItem], LocalMetadataSearchError>
            ) -> Void
    ) {
        cancel()

        let trimmed = nameQuery.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard let pattern = Self.metadataNamePattern(for: trimmed) else {
            completion(.failure(.queryTooShort))
            return
        }

        let personalScopes = approvedScopes.filter(\.isPersonal)
        guard !personalScopes.isEmpty else {
            completion(.failure(.noPersonalScope))
            return
        }

        var roots: [LocalSearchScopeID: URL] = [:]
        for scope in personalScopes {
            guard let root = Self.url(for: scope) else {
                completion(.failure(.unavailableScope(scope)))
                return
            }
            roots[scope] = root.standardizedFileURL
        }

        let query = NSMetadataQuery()
        query.predicate = NSPredicate(
            format: "%K LIKE[cd] %@",
            "kMDItemFSName",
            pattern
        )
        query.searchScopes = Array(roots.values)
        metadataQuery = query
        activeScopeRoots = roots
        self.completion = completion

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(queryDidFinish(_:)),
            name: .NSMetadataQueryDidFinishGathering,
            object: query
        )
        guard query.start() else {
            cancel()
            completion(.failure(.queryDidNotStart))
            return
        }
    }

    public func cancel() {
        if let metadataQuery {
            metadataQuery.stop()
            NotificationCenter.default.removeObserver(
                self,
                name: .NSMetadataQueryDidFinishGathering,
                object: metadataQuery
            )
        }
        metadataQuery = nil
        completion = nil
        activeScopeRoots = [:]
    }

    @objc private func queryDidFinish(_ notification: Notification) {
        guard
            let query = notification.object as? NSMetadataQuery,
            query === metadataQuery
        else {
            return
        }

        query.disableUpdates()
        let items = Array(
            query.results
                .lazy
                .compactMap { $0 as? NSMetadataItem }
                .compactMap(item(from:))
                .prefix(200)
        )
        let completion = completion
        cancel()
        completion?(.success(items))
    }

    private func item(from metadata: NSMetadataItem) -> LocalSearchItem? {
        guard
            let path = metadata.value(
                forAttribute: "kMDItemPath"
            ) as? String
        else {
            return nil
        }
        let url = URL(fileURLWithPath: path).standardizedFileURL
        guard !Self.isExcludedPath(url) else { return nil }
        guard
            let scope = activeScopeRoots.first(where: {
                Self.isSafelyWithin(url, root: $0.value)
            })?.key
        else {
            return nil
        }

        let contentType =
            metadata.value(
                forAttribute: "kMDItemContentType"
            ) as? String
        let kind: LocalSearchItemKind =
            contentType == "public.folder" ? .folder : .file
        return LocalSearchItem(
            name: url.lastPathComponent,
            url: url,
            kind: kind,
            scope: scope
        )
    }

    static func url(for scope: LocalSearchScopeID) -> URL? {
        let directory: FileManager.SearchPathDirectory
        switch scope {
        case .applications:
            return nil
        case .desktop:
            directory = .desktopDirectory
        case .documents:
            directory = .documentDirectory
        case .downloads:
            directory = .downloadsDirectory
        }
        return FileManager.default.urls(
            for: directory,
            in: .userDomainMask
        ).first
    }

    nonisolated static func isSafelyWithin(
        _ item: URL,
        root: URL
    ) -> Bool {
        let itemPath = item.standardizedFileURL.path
        let rootPath = root.standardizedFileURL.path
        return itemPath == rootPath
            || itemPath.hasPrefix(rootPath + "/")
    }

    nonisolated static func isExcludedPath(_ url: URL) -> Bool {
        let packageExtensions: Set<String> = [
            "app",
            "bundle",
            "framework",
            "photoslibrary",
            "photolibrary",
            "musiclibrary",
        ]
        return url.standardizedFileURL.pathComponents.contains { component in
            component.hasPrefix(".")
                || packageExtensions.contains(
                    URL(fileURLWithPath: component)
                        .pathExtension
                        .lowercased()
                )
        }
    }

    nonisolated static func metadataNamePattern(
        for query: String
    ) -> String? {
        let meaningfulCount = query.unicodeScalars.count {
            CharacterSet.alphanumerics.contains($0)
        }
        guard meaningfulCount >= 2 else { return nil }

        let escaped =
            query
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "*", with: "\\*")
            .replacingOccurrences(of: "?", with: "\\?")
            .replacingOccurrences(of: "[", with: "\\[")
        return "*\(escaped)*"
    }
}
