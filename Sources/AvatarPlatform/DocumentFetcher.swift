import AvatarCore
import Foundation

public enum DocumentFetchError: Error, Equatable {
    case unreachable
    case timedOut
    case httpStatus(Int)
    /// The response came from a host the user never approved.
    case redirectedOffApprovedHost(String)
    case responseTooLarge
    case unsupportedContentType(String?)
    case notReadableText
}

public struct FetchedPageResponse: Equatable, Sendable {
    /// Where the response actually came from after any redirects — not where
    /// the request was aimed.
    public let finalURL: URL
    public let contentType: String?
    public let body: Data

    public init(finalURL: URL, contentType: String?, body: Data) {
        self.finalURL = finalURL
        self.contentType = contentType
        self.body = body
    }
}

/// Injected so every boundary and model test runs offline.
public protocol PageTransport: Sendable {
    func get(
        url: URL,
        approvedHosts: Set<String>,
        timeout: TimeInterval
    ) async throws -> FetchedPageResponse
}

enum ApprovedHostRedirectDecision: Equatable, Sendable {
    case follow
    case refuse(host: String)
}

/// Pure policy tested without opening a socket. URLSession's task delegate
/// applies this decision before following a redirect.
enum ApprovedHostRedirectPolicy {
    static func decision(
        for newURL: URL,
        approvedHosts: Set<String>
    ) -> ApprovedHostRedirectDecision {
        let host = newURL.host?.lowercased() ?? "(missing host)"
        let normalizedHosts = Set(approvedHosts.map { $0.lowercased() })
        guard newURL.scheme?.lowercased() == "https",
            newURL.user == nil,
            newURL.password == nil,
            normalizedHosts.contains(host)
        else {
            return .refuse(host: host)
        }
        return .follow
    }
}

final class ApprovedHostRedirectDelegate:
    NSObject, URLSessionTaskDelegate, @unchecked Sendable
{
    private let approvedHosts: Set<String>
    private let lock = NSLock()
    private var storedRefusedHost: String?

    init(approvedHosts: Set<String>) {
        self.approvedHosts = approvedHosts
    }

    var refusedHost: String? {
        lock.withLock { storedRefusedHost }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        guard let newURL = request.url else {
            recordRefusal(host: "(missing host)")
            completionHandler(nil)
            return
        }
        switch ApprovedHostRedirectPolicy.decision(
            for: newURL,
            approvedHosts: approvedHosts
        ) {
        case .follow:
            completionHandler(request)
        case .refuse(let host):
            recordRefusal(host: host)
            completionHandler(nil)
        }
    }

    private func recordRefusal(host: String) {
        lock.withLock {
            if storedRefusedHost == nil { storedRefusedHost = host }
        }
    }
}

struct BoundedResponseBuffer {
    let limit: Int
    private(set) var data = Data()

    mutating func append(_ byte: UInt8) throws {
        guard data.count < limit else {
            throw DocumentFetchError.responseTooLarge
        }
        data.append(byte)
    }
}

/// The only outbound-network code in this project.
public struct URLSessionPageTransport: PageTransport {
    public init() {}

    public func get(
        url: URL,
        approvedHosts: Set<String>,
        timeout: TimeInterval
    ) async throws -> FetchedPageResponse {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = timeout
        // No cookies, credentials, or cache. Nothing about this request should
        // carry identity or persist.
        request.httpShouldHandleCookies = false
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData

        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        let session = URLSession(configuration: configuration)
        let delegate = ApprovedHostRedirectDelegate(
            approvedHosts: approvedHosts
        )
        defer { session.invalidateAndCancel() }

        let bytes: URLSession.AsyncBytes
        let response: URLResponse
        do {
            (bytes, response) = try await session.bytes(
                for: request,
                delegate: delegate
            )
        } catch {
            if let host = delegate.refusedHost {
                throw DocumentFetchError.redirectedOffApprovedHost(host)
            }
            throw error
        }
        if let host = delegate.refusedHost {
            throw DocumentFetchError.redirectedOffApprovedHost(host)
        }
        guard let http = response as? HTTPURLResponse else {
            throw DocumentFetchError.unreachable
        }
        guard (200..<300).contains(http.statusCode) else {
            throw DocumentFetchError.httpStatus(http.statusCode)
        }
        if http.expectedContentLength > FetchLimits.maximumResponseBytes {
            bytes.task.cancel()
            throw DocumentFetchError.responseTooLarge
        }

        var buffer = BoundedResponseBuffer(
            limit: FetchLimits.maximumResponseBytes
        )
        do {
            for try await byte in bytes {
                try buffer.append(byte)
            }
        } catch DocumentFetchError.responseTooLarge {
            bytes.task.cancel()
            throw DocumentFetchError.responseTooLarge
        }
        return FetchedPageResponse(
            finalURL: http.url ?? url,
            contentType: http.value(forHTTPHeaderField: "Content-Type"),
            body: buffer.data
        )
    }
}

public protocol DocumentFetching: Sendable {
    func fetch(
        url: URL,
        authorization: ResearchAuthorization,
        now: Date
    ) async throws -> FetchedDocument
}

/// Applies the existing research boundary, then reads one page within bounds.
///
/// Order matters: the boundary runs first, so a request the user never approved
/// never reaches the network at all.
public struct DocumentFetcher: DocumentFetching {
    private let transport: any PageTransport
    private let gate = ResearchGate()
    private let extractor = ReadabilityExtractor()

    public init(transport: any PageTransport = URLSessionPageTransport()) {
        self.transport = transport
    }

    public func fetch(
        url: URL,
        authorization: ResearchAuthorization,
        now: Date
    ) async throws -> FetchedDocument {
        // Existing, already-reviewed boundary: HTTPS, approved host, expiry.
        try gate.validateFetch(url, authorization: authorization, now: now)
        guard url.user == nil, url.password == nil else {
            throw ResearchBoundaryError.credentialsNotAllowed
        }

        let response: FetchedPageResponse
        do {
            response = try await transport.get(
                url: url,
                approvedHosts: authorization.request.approvedHosts,
                timeout: FetchLimits.timeoutSeconds
            )
        } catch let error as DocumentFetchError {
            throw error
        } catch let error as URLError where error.code == .timedOut {
            throw DocumentFetchError.timedOut
        } catch {
            throw DocumentFetchError.unreachable
        }

        // Defence in depth after the delegate's pre-connection redirect check.
        let redirectDecision = ApprovedHostRedirectPolicy.decision(
            for: response.finalURL,
            approvedHosts: authorization.request.approvedHosts
        )
        if case .refuse(let host) = redirectDecision {
            throw DocumentFetchError.redirectedOffApprovedHost(host)
        }

        guard response.body.count <= FetchLimits.maximumResponseBytes else {
            throw DocumentFetchError.responseTooLarge
        }
        guard FetchLimits.isAllowedContentType(response.contentType) else {
            throw DocumentFetchError.unsupportedContentType(response.contentType)
        }
        guard let text = String(data: response.body, encoding: .utf8) else {
            throw DocumentFetchError.notReadableText
        }

        let document: FetchedDocument?
        if Self.mediaType(response.contentType) == "text/plain" {
            document = FetchedDocument(
                sourceURL: response.finalURL,
                text: text,
                responseByteCount: response.body.count
            )
        } else {
            document = extractor.extract(
                html: text,
                sourceURL: response.finalURL,
                responseByteCount: response.body.count
            )
        }
        guard let document else {
            throw DocumentFetchError.notReadableText
        }
        return document
    }

    private static func mediaType(_ rawValue: String?) -> String? {
        rawValue?
            .split(
                separator: ";",
                maxSplits: 1,
                omittingEmptySubsequences: false
            )
            .first
            .map(String.init)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }
}
