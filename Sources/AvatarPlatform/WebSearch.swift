import AvatarCore
import Foundation

public protocol WebSearchService: Sendable {
    func search(
        query: WebSearchQuery,
        maxResults: Int
    ) async throws -> WebSearchResultSet
}

public struct WebSearchHTTPResponse: Equatable, Sendable {
    public let finalURL: URL
    public let statusCode: Int
    public let body: Data

    public init(finalURL: URL, statusCode: Int, body: Data) {
        self.finalURL = finalURL
        self.statusCode = statusCode
        self.body = body
    }
}

/// Injected so service tests never open a socket.
public protocol WebSearchTransport: Sendable {
    func send(
        _ request: URLRequest,
        providerHost: String,
        maximumResponseBytes: Int
    ) async throws -> WebSearchHTTPResponse
}

struct BoundedWebSearchResponseBuffer {
    let limit: Int
    private(set) var data = Data()

    mutating func append(_ byte: UInt8) throws {
        guard data.count < limit else {
            throw WebSearchError.responseTooLarge
        }
        data.append(byte)
    }
}

/// Ephemeral, streaming HTTPS transport for one provider request.
public struct URLSessionWebSearchTransport: WebSearchTransport {
    public init() {}

    public func send(
        _ request: URLRequest,
        providerHost: String,
        maximumResponseBytes: Int
    ) async throws -> WebSearchHTTPResponse {
        guard let requestURL = request.url,
            requestURL.scheme?.lowercased() == "https",
            requestURL.host?.lowercased() == providerHost.lowercased()
        else {
            throw WebSearchError.badResponse
        }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        let session = URLSession(configuration: configuration)
        let delegate = ApprovedHostRedirectDelegate(
            approvedHosts: [providerHost]
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
            if delegate.refusedHost != nil {
                throw WebSearchError.badResponse
            }
            throw error
        }
        guard delegate.refusedHost == nil,
            let http = response as? HTTPURLResponse
        else {
            throw WebSearchError.badResponse
        }
        if http.expectedContentLength > maximumResponseBytes {
            bytes.task.cancel()
            throw WebSearchError.responseTooLarge
        }

        var buffer = BoundedWebSearchResponseBuffer(
            limit: maximumResponseBytes
        )
        do {
            for try await byte in bytes {
                try buffer.append(byte)
            }
        } catch WebSearchError.responseTooLarge {
            bytes.task.cancel()
            throw WebSearchError.responseTooLarge
        }
        return WebSearchHTTPResponse(
            finalURL: http.url ?? requestURL,
            statusCode: http.statusCode,
            body: buffer.data
        )
    }
}

/// Brave Search API client. Results remain inert until a user separately approves one.
public struct BraveSearchClient: WebSearchService {
    public static let providerHost = "api.search.brave.com"

    private let credentialStore: any SearchCredentialStore
    private let transport: any WebSearchTransport

    public init(
        credentialStore: any SearchCredentialStore = KeychainSearchCredentialStore(),
        transport: any WebSearchTransport = URLSessionWebSearchTransport()
    ) {
        self.credentialStore = credentialStore
        self.transport = transport
    }

    public func search(
        query: WebSearchQuery,
        maxResults: Int
    ) async throws -> WebSearchResultSet {
        guard (1...WebSearchLimits.maximumResults).contains(maxResults) else {
            throw WebSearchError.badResponse
        }

        let apiKey: String
        do {
            guard let storedKey = try credentialStore.apiKey(),
                !storedKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else {
                throw WebSearchError.apiKeyNotConfigured
            }
            apiKey = storedKey
        } catch let error as WebSearchError {
            throw error
        } catch {
            throw WebSearchError.credentialFailure
        }

        var components = URLComponents()
        components.scheme = "https"
        components.host = Self.providerHost
        components.path = "/res/v1/web/search"
        components.queryItems = [
            URLQueryItem(name: "q", value: query.value),
            URLQueryItem(name: "count", value: String(maxResults)),
        ]
        guard let url = components.url else {
            throw WebSearchError.badResponse
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = WebSearchLimits.timeoutSeconds
        request.httpShouldHandleCookies = false
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(apiKey, forHTTPHeaderField: "X-Subscription-Token")

        let response: WebSearchHTTPResponse
        do {
            response = try await transport.send(
                request,
                providerHost: Self.providerHost,
                maximumResponseBytes: WebSearchLimits.maximumResponseBytes
            )
        } catch let error as WebSearchError {
            throw error
        } catch let error as URLError where error.code == .timedOut {
            throw WebSearchError.timedOut
        } catch {
            throw WebSearchError.networkFailure
        }

        guard ApprovedHostRedirectPolicy.decision(
            for: response.finalURL,
            approvedHosts: [Self.providerHost]
        ) == .follow else {
            throw WebSearchError.badResponse
        }
        if response.statusCode == 429 {
            throw WebSearchError.rateLimited
        }
        guard (200..<300).contains(response.statusCode) else {
            throw WebSearchError.httpStatus(response.statusCode)
        }
        guard response.body.count <= WebSearchLimits.maximumResponseBytes else {
            throw WebSearchError.responseTooLarge
        }

        let decoded: BraveResponse
        do {
            decoded = try JSONDecoder().decode(BraveResponse.self, from: response.body)
        } catch {
            throw WebSearchError.badResponse
        }
        guard decoded.web.results.count <= maxResults else {
            throw WebSearchError.badResponse
        }

        do {
            let results = try decoded.web.results.map { raw in
                guard let url = URL(string: raw.url) else {
                    throw WebSearchError.badResponse
                }
                return try WebSearchResult(
                    title: raw.title,
                    url: url,
                    snippet: raw.description
                )
            }
            return try WebSearchResultSet(results: results)
        } catch let error as WebSearchError {
            throw error
        } catch {
            throw WebSearchError.badResponse
        }
    }
}

private struct BraveResponse: Decodable {
    let web: BraveWebResults
}

private struct BraveWebResults: Decodable {
    let results: [BraveRawResult]
}

private struct BraveRawResult: Decodable {
    let title: String
    let url: String
    let description: String
}
