import AvatarCore
import Foundation
import Testing

@testable import AvatarPlatform

private struct StubTransport: PageTransport {
    var response: FetchedPageResponse?
    var error: (any Error)?

    final class Calls: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        private var hosts: Set<String> = []
        private var timeout: TimeInterval?

        var value: Int { lock.withLock { count } }
        var approvedHosts: Set<String> { lock.withLock { hosts } }
        var requestedTimeout: TimeInterval? { lock.withLock { timeout } }

        func record(hosts: Set<String>, timeout: TimeInterval) {
            lock.withLock {
                count += 1
                self.hosts = hosts
                self.timeout = timeout
            }
        }
    }

    let calls = Calls()

    func get(
        url: URL,
        approvedHosts: Set<String>,
        timeout: TimeInterval
    ) async throws -> FetchedPageResponse {
        calls.record(hosts: approvedHosts, timeout: timeout)
        if let error { throw error }
        guard let response else { throw DocumentFetchError.unreachable }
        return response
    }
}

private func authorization(
    hosts: Set<String> = ["example.com"],
    expiresAt: Date = Date(timeIntervalSince1970: 2_000_000)
) -> ResearchAuthorization {
    let approvedAt = Date(timeIntervalSince1970: 1_000_000)
    let request = ResearchRequest(
            app: AppIdentity(
                bundleIdentifier: "com.example.app", displayName: "Example"
            ),
            approvedHosts: hosts,
            maxDocuments: 5,
            createdAt: approvedAt
    )
    return try! ResearchGate().authorize(
        request,
        userApproved: true,
        now: approvedAt,
        duration: expiresAt.timeIntervalSince(approvedAt)
    )
}

private let now = Date(timeIntervalSince1970: 1_000_100)

private func htmlResponse(
    _ html: String,
    finalURL: String = "https://example.com/page",
    contentType: String? = "text/html; charset=utf-8"
) -> FetchedPageResponse {
    FetchedPageResponse(
        finalURL: URL(string: finalURL)!,
        contentType: contentType,
        body: Data(html.utf8)
    )
}

@Suite("Approved-host redirect policy")
struct ApprovedHostRedirectPolicyTests {
    @Test("A same-host HTTPS redirect is followed")
    func followsSameHost() {
        #expect(
            ApprovedHostRedirectPolicy.decision(
                for: URL(string: "https://example.com/moved")!,
                approvedHosts: ["example.com"]
            ) == .follow
        )
    }

    @Test("A foreign-host redirect is refused before connection")
    func refusesForeignHost() {
        #expect(
            ApprovedHostRedirectPolicy.decision(
                for: URL(string: "https://evil.example.net/page")!,
                approvedHosts: ["example.com"]
            ) == .refuse(host: "evil.example.net")
        )
    }

    @Test("A same-host downgrade to HTTP is refused")
    func refusesHTTPSDowngrade() {
        #expect(
            ApprovedHostRedirectPolicy.decision(
                for: URL(string: "http://example.com/page")!,
                approvedHosts: ["example.com"]
            ) == .refuse(host: "example.com")
        )
    }
}

@Suite("Document fetcher")
struct DocumentFetcherTests {
    private let approvedURL = URL(string: "https://example.com/page")!

    @Test("An approved page becomes extracted text with exact byte metadata")
    func fetchesApprovedPage() async throws {
        let html = "<p>Hello from the page.</p>"
        let transport = StubTransport(response: htmlResponse(html))
        let document = try await DocumentFetcher(transport: transport).fetch(
            url: approvedURL, authorization: authorization(), now: now
        )
        #expect(document.text == "Hello from the page.")
        #expect(document.sourceURL == approvedURL)
        #expect(document.responseByteCount == Data(html.utf8).count)
        #expect(transport.calls.approvedHosts == ["example.com"])
        #expect(transport.calls.requestedTimeout == FetchLimits.timeoutSeconds)
    }

    /// The delegate is the real guarantee. This stub-level test retains the
    /// fetcher's post-response check as defence in depth.
    @Test("A final response from an unapproved host is refused")
    func refusesOffHostFinalResponse() async {
        let transport = StubTransport(
            response: htmlResponse(
                "<p>Elsewhere.</p>", finalURL: "https://evil.example.net/page"
            )
        )
        await #expect(
            throws: DocumentFetchError.redirectedOffApprovedHost(
                "evil.example.net"
            )
        ) {
            try await DocumentFetcher(transport: transport).fetch(
                url: approvedURL, authorization: authorization(), now: now
            )
        }
    }

    @Test("A final same-host HTTPS redirect is allowed")
    func allowsSameHostRedirect() async throws {
        let transport = StubTransport(
            response: htmlResponse(
                "<p>Moved.</p>", finalURL: "https://example.com/moved"
            )
        )
        let document = try await DocumentFetcher(transport: transport).fetch(
            url: approvedURL, authorization: authorization(), now: now
        )
        #expect(document.text == "Moved.")
    }

    @Test("An oversize response is refused before extraction")
    func refusesOversizeResponse() async {
        let big = Data(
            repeating: UInt8(ascii: "a"),
            count: FetchLimits.maximumResponseBytes + 1
        )
        let transport = StubTransport(
            response: FetchedPageResponse(
                finalURL: approvedURL, contentType: "text/html", body: big
            )
        )
        await #expect(throws: DocumentFetchError.responseTooLarge) {
            try await DocumentFetcher(transport: transport).fetch(
                url: approvedURL, authorization: authorization(), now: now
            )
        }
    }

    @Test(
        "Non-text content types are refused",
        arguments: ["application/pdf", "image/png", nil]
    )
    func refusesNonTextContentType(contentType: String?) async {
        let transport = StubTransport(
            response: FetchedPageResponse(
                finalURL: approvedURL,
                contentType: contentType,
                body: Data("<p>x</p>".utf8)
            )
        )
        await #expect(throws: DocumentFetchError.self) {
            try await DocumentFetcher(transport: transport).fetch(
                url: approvedURL, authorization: authorization(), now: now
            )
        }
    }

    @Test("Plain text is not interpreted as HTML markup")
    func preservesPlainTextMarkup() async throws {
        let text = "Use <example> literally."
        let transport = StubTransport(
            response: htmlResponse(text, contentType: "text/plain")
        )
        let document = try await DocumentFetcher(transport: transport).fetch(
            url: approvedURL, authorization: authorization(), now: now
        )
        #expect(document.text == text)
    }

    @Test("A page with no readable text is refused")
    func refusesUnreadablePage() async {
        let transport = StubTransport(
            response: htmlResponse("<script>only()</script>")
        )
        await #expect(throws: DocumentFetchError.notReadableText) {
            try await DocumentFetcher(transport: transport).fetch(
                url: approvedURL, authorization: authorization(), now: now
            )
        }
    }

    /// The boundary runs before the transport, so a rejected request never
    /// reaches the network at all.
    @Test("An unapproved host is refused without contacting anything")
    func neverContactsUnapprovedHost() async {
        let transport = StubTransport(response: htmlResponse("<p>x</p>"))
        let fetcher = DocumentFetcher(transport: transport)
        await #expect(throws: (any Error).self) {
            try await fetcher.fetch(
                url: URL(string: "https://other.example.org/page")!,
                authorization: authorization(),
                now: now
            )
        }
        #expect(transport.calls.value == 0)
    }

    @Test("A plain HTTP URL is refused without contacting anything")
    func refusesInsecureURL() async {
        let transport = StubTransport(response: htmlResponse("<p>x</p>"))
        let fetcher = DocumentFetcher(transport: transport)
        await #expect(throws: (any Error).self) {
            try await fetcher.fetch(
                url: URL(string: "http://example.com/page")!,
                authorization: authorization(),
                now: now
            )
        }
        #expect(transport.calls.value == 0)
    }

    @Test("An expired authorization is refused without contacting anything")
    func refusesExpiredAuthorization() async {
        let transport = StubTransport(response: htmlResponse("<p>x</p>"))
        let fetcher = DocumentFetcher(transport: transport)
        await #expect(throws: (any Error).self) {
            try await fetcher.fetch(
                url: approvedURL,
                authorization: authorization(
                    expiresAt: Date(timeIntervalSince1970: 1_000_050)
                ),
                now: now
            )
        }
        #expect(transport.calls.value == 0)
    }

    @Test("A transport failure surfaces as a typed error")
    func mapsTransportFailure() async {
        struct Boom: Error {}
        let transport = StubTransport(error: Boom())
        await #expect(throws: DocumentFetchError.unreachable) {
            try await DocumentFetcher(transport: transport).fetch(
                url: approvedURL, authorization: authorization(), now: now
            )
        }
    }

    @Test("A timeout is distinguishable from being unreachable")
    func mapsTimeout() async {
        let transport = StubTransport(error: URLError(.timedOut))
        await #expect(throws: DocumentFetchError.timedOut) {
            try await DocumentFetcher(transport: transport).fetch(
                url: approvedURL, authorization: authorization(), now: now
            )
        }
    }
}
