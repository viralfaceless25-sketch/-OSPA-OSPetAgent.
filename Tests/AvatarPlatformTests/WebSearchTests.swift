import AvatarCore
import Foundation
import Testing

@testable import AvatarPlatform

private struct CredentialStoreFailure: Error {}

private struct StubSearchCredentialStore: SearchCredentialStore {
    final class Calls: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0

        var value: Int { lock.withLock { count } }

        func record() {
            lock.withLock { count += 1 }
        }
    }

    var credential: String?
    var error: (any Error)?
    let calls = Calls()

    func apiKey() throws -> String? {
        calls.record()
        if let error { throw error }
        return credential
    }
}

private struct StubWebSearchTransport: WebSearchTransport {
    final class Calls: @unchecked Sendable {
        private let lock = NSLock()
        private var requests: [URLRequest] = []
        private var hosts: [String] = []
        private var byteLimits: [Int] = []

        var count: Int { lock.withLock { requests.count } }
        var lastRequest: URLRequest? { lock.withLock { requests.last } }
        var lastHost: String? { lock.withLock { hosts.last } }
        var lastByteLimit: Int? { lock.withLock { byteLimits.last } }

        func record(
            request: URLRequest,
            providerHost: String,
            maximumResponseBytes: Int
        ) {
            lock.withLock {
                requests.append(request)
                hosts.append(providerHost)
                byteLimits.append(maximumResponseBytes)
            }
        }
    }

    var response: WebSearchHTTPResponse?
    var error: (any Error)?
    let calls = Calls()

    func send(
        _ request: URLRequest,
        providerHost: String,
        maximumResponseBytes: Int
    ) async throws -> WebSearchHTTPResponse {
        calls.record(
            request: request,
            providerHost: providerHost,
            maximumResponseBytes: maximumResponseBytes
        )
        if let error { throw error }
        guard let response else { throw URLError(.cannotConnectToHost) }
        return response
    }
}

private final class SearchRedirectCompletion: @unchecked Sendable {
    private let lock = NSLock()
    private var storedRequest: URLRequest?
    private var storedCalled = false

    var request: URLRequest? { lock.withLock { storedRequest } }
    var wasCalled: Bool { lock.withLock { storedCalled } }

    func complete(_ request: URLRequest?) {
        lock.withLock {
            storedRequest = request
            storedCalled = true
        }
    }
}

private func searchResponse(
    statusCode: Int = 200,
    finalURL: String = "https://api.search.brave.com/res/v1/web/search",
    body: String = """
        {"web":{"results":[{"title":"Swift actors","url":"https://example.com/actors","description":"Actors isolate mutable state."}]}}
        """
) -> WebSearchHTTPResponse {
    WebSearchHTTPResponse(
        finalURL: URL(string: finalURL)!,
        statusCode: statusCode,
        body: Data(body.utf8)
    )
}

private func configuredStore() -> StubSearchCredentialStore {
    StubSearchCredentialStore(credential: UUID().uuidString)
}

@Suite("Brave web search client")
struct BraveSearchClientTests {
    @Test("No configured key returns typed setup error with zero network calls")
    func missingKeyNeverContactsTransport() async throws {
        let credentialStore = StubSearchCredentialStore(credential: nil)
        let transport = StubWebSearchTransport(response: searchResponse())
        let query = try WebSearchQuery("swift actors")

        await #expect(throws: WebSearchError.apiKeyNotConfigured) {
            try await BraveSearchClient(
                credentialStore: credentialStore,
                transport: transport
            ).search(query: query, maxResults: 3)
        }

        #expect(credentialStore.calls.value == 1)
        #expect(transport.calls.count == 0)
    }

    @Test("Invalid result limits are refused before credentials or network")
    func refusesInvalidResultLimits() async throws {
        let credentialStore = configuredStore()
        let transport = StubWebSearchTransport(response: searchResponse())
        let client = BraveSearchClient(
            credentialStore: credentialStore,
            transport: transport
        )
        let query = try WebSearchQuery("swift")

        for limit in [0, WebSearchLimits.maximumResults + 1] {
            await #expect(throws: WebSearchError.badResponse) {
                try await client.search(query: query, maxResults: limit)
            }
        }
        #expect(credentialStore.calls.value == 0)
        #expect(transport.calls.count == 0)
    }

    @Test("Credential access failure is typed and makes zero network calls")
    func credentialFailureNeverContactsTransport() async throws {
        let credentialStore = StubSearchCredentialStore(
            credential: nil,
            error: CredentialStoreFailure()
        )
        let transport = StubWebSearchTransport(response: searchResponse())

        await #expect(throws: WebSearchError.credentialFailure) {
            try await BraveSearchClient(
                credentialStore: credentialStore,
                transport: transport
            ).search(query: WebSearchQuery("swift"), maxResults: 1)
        }
        #expect(transport.calls.count == 0)
    }

    @Test("Each search reads the credential on demand")
    func readsCredentialOnDemand() async throws {
        let credentialStore = configuredStore()
        let transport = StubWebSearchTransport(response: searchResponse())
        let client = BraveSearchClient(
            credentialStore: credentialStore,
            transport: transport
        )
        let query = try WebSearchQuery("swift")

        _ = try await client.search(query: query, maxResults: 1)
        _ = try await client.search(query: query, maxResults: 1)

        #expect(credentialStore.calls.value == 2)
        #expect(transport.calls.count == 2)
    }

    @Test("Request is HTTPS, provider-scoped, timed, and asks for exact count")
    func buildsBoundedRequest() async throws {
        let credentialStore = configuredStore()
        let credential = try #require(credentialStore.credential)
        let transport = StubWebSearchTransport(response: searchResponse())
        let query = try WebSearchQuery("swift actors")

        let results = try await BraveSearchClient(
            credentialStore: credentialStore,
            transport: transport
        ).search(query: query, maxResults: 3)

        #expect(results.results.count == 1)
        #expect(results.results.first?.title == "Swift actors")
        let request = try #require(transport.calls.lastRequest)
        let url = try #require(request.url)
        #expect(url.scheme == "https")
        #expect(url.host == BraveSearchClient.providerHost)
        let components = try #require(
            URLComponents(url: url, resolvingAgainstBaseURL: false)
        )
        let queryItems = Dictionary(
            uniqueKeysWithValues: (components.queryItems ?? []).map {
                ($0.name, $0.value)
            }
        )
        #expect(queryItems["q"] == "swift actors")
        #expect(queryItems["count"] == "3")
        #expect(queryItems["result_filter"] == "web")
        #expect(request.timeoutInterval == WebSearchLimits.timeoutSeconds)
        #expect(
            request.value(forHTTPHeaderField: "X-Subscription-Token")
                == credential
        )
        #expect(transport.calls.lastHost == BraveSearchClient.providerHost)
        #expect(
            transport.calls.lastByteLimit
                == WebSearchLimits.maximumResponseBytes
        )
    }

    @Test(
        "Null or missing web results decode as an empty bounded set",
        arguments: [
            #"{"type":"search","web":null}"#,
            #"{"type":"search"}"#,
        ]
    )
    func acceptsAbsentWebResults(body: String) async throws {
        let results = try await client(
            response: searchResponse(body: body)
        ).search(query: WebSearchQuery("no matches"), maxResults: 3)

        #expect(results.results.isEmpty)
    }

    @Test("HTTP failure, timeout, malformed JSON, and network failure stay distinct")
    func mapsDistinctFailures() async throws {
        let query = try WebSearchQuery("swift")

        await #expect(throws: WebSearchError.httpStatus(503)) {
            try await client(response: searchResponse(statusCode: 503))
                .search(query: query, maxResults: 1)
        }
        await #expect(throws: WebSearchError.timedOut) {
            try await client(error: URLError(.timedOut))
                .search(query: query, maxResults: 1)
        }
        await #expect(throws: WebSearchError.badResponse) {
            try await client(response: searchResponse(body: "{"))
                .search(query: query, maxResults: 1)
        }
        await #expect(throws: WebSearchError.networkFailure) {
            try await client(error: URLError(.cannotConnectToHost))
                .search(query: query, maxResults: 1)
        }
    }

    @Test("Rate limiting and oversize responses keep their typed failures")
    func preservesProviderFailures() async throws {
        let query = try WebSearchQuery("swift")
        await #expect(throws: WebSearchError.rateLimited) {
            try await client(response: searchResponse(statusCode: 429))
                .search(query: query, maxResults: 1)
        }
        await #expect(throws: WebSearchError.responseTooLarge) {
            try await client(error: WebSearchError.responseTooLarge)
                .search(query: query, maxResults: 1)
        }
    }

    @Test("An off-provider final response is refused in depth")
    func refusesOffProviderFinalResponse() async throws {
        let query = try WebSearchQuery("swift")
        await #expect(throws: WebSearchError.badResponse) {
            try await client(
                response: searchResponse(
                    finalURL: "https://elsewhere.example/search"
                )
            ).search(query: query, maxResults: 1)
        }
    }

    private func client(
        response: WebSearchHTTPResponse? = nil,
        error: (any Error)? = nil
    ) -> BraveSearchClient {
        BraveSearchClient(
            credentialStore: configuredStore(),
            transport: StubWebSearchTransport(
                response: response,
                error: error
            )
        )
    }
}

@Suite("Bounded Brave response transport")
struct WebSearchTransportTests {
    @Test("Session config enforces 15-second request and resource timeouts")
    func sessionConfigurationHasAbsoluteTimeouts() {
        let configuration =
            URLSessionWebSearchTransport.sessionConfiguration()

        #expect(configuration.timeoutIntervalForRequest == 15)
        #expect(configuration.timeoutIntervalForResource == 15)
    }

    @Test("The byte after the cap is refused before it can be buffered")
    func refusesBytePastCap() throws {
        var buffer = BoundedWebSearchResponseBuffer(limit: 2)
        try buffer.append(0x01)
        try buffer.append(0x02)
        #expect(throws: WebSearchError.responseTooLarge) {
            try buffer.append(0x03)
        }
        #expect(buffer.data == Data([0x01, 0x02]))
    }

    @Test("Cross-host redirect is refused and never passed to URLSession")
    func refusesCrossHostRedirect() {
        let original = URL(
            string: "https://api.search.brave.com/res/v1/web/search"
        )!
        let delegate = ApprovedHostRedirectDelegate(
            approvedHosts: [BraveSearchClient.providerHost]
        )
        let task = URLSession.shared.dataTask(with: original)
        defer { task.cancel() }
        let completion = SearchRedirectCompletion()

        delegate.urlSession(
            URLSession.shared,
            task: task,
            willPerformHTTPRedirection: HTTPURLResponse(
                url: original,
                statusCode: 302,
                httpVersion: nil,
                headerFields: nil
            )!,
            newRequest: URLRequest(
                url: URL(string: "https://elsewhere.example/search")!
            ),
            completionHandler: completion.complete
        )

        #expect(completion.wasCalled)
        #expect(completion.request == nil)
        #expect(delegate.refusedHost == "elsewhere.example")
    }

    @Test("Keychain reader retains identifiers only, never a credential")
    func keychainStoreDoesNotCacheCredential() {
        let store = KeychainSearchCredentialStore(
            service: "com.example.search",
            account: "brave"
        )
        let fields = Mirror(reflecting: store).children.compactMap(\.label)
        #expect(fields == ["service", "account"])
    }

    @Test("Added search sources contain no action-authority type reference")
    func searchSourcesStayIsolatedFromActions() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let sourceURLs = [
            root.appendingPathComponent("Sources/AvatarCore/WebSearch.swift"),
            root.appendingPathComponent("Sources/AvatarPlatform/WebSearch.swift"),
        ]
        let forbiddenTypes = [
            "ParsedApplicationCommand", "ActionPlan", "ConsentGrant",
        ]
        for sourceURL in sourceURLs {
            let source = try String(contentsOf: sourceURL, encoding: .utf8)
            for typeName in forbiddenTypes {
                #expect(!source.contains(typeName))
            }
        }
    }
}
