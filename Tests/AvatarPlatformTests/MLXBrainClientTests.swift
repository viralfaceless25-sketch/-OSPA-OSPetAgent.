import AvatarCore
import Foundation
import Testing

@testable import AvatarPlatform

private struct StubTransport: BrainHTTPTransport {
    let status: Int
    let body: Data
    let error: (any Error)?

    init(status: Int = 200, body: Data = Data(), error: (any Error)? = nil) {
        self.status = status
        self.body = body
        self.error = error
    }

    func post(
        url: URL, body requestBody: Data, timeout: TimeInterval
    ) async throws -> (status: Int, body: Data) {
        if let error { throw error }
        return (status, body)
    }
}

/// Captures the outgoing request so we can assert what the model was shown.
private final class CapturingTransport: BrainHTTPTransport, @unchecked Sendable {
    private(set) var sentBody: Data?
    private(set) var sentURL: URL?
    let response: Data

    init(response: Data) { self.response = response }

    func post(
        url: URL, body: Data, timeout: TimeInterval
    ) async throws -> (status: Int, body: Data) {
        sentURL = url
        sentBody = body
        return (200, response)
    }
}

private func toolCallResponse(
    name: String = "open_application",
    arguments: String = #"{\"name\":\"Spotify\",\"reason\":\"music\"}"#
) -> Data {
    toolCallResponse(calls: [(name, arguments)])
}

private func toolCallResponse(calls: [(name: String, arguments: String)]) -> Data {
    let rendered = calls.map { call in
        """
        {"type":"function","function":{"name":"\(call.name)","arguments":"\(call.arguments)"}}
        """
    }.joined(separator: ",")
    return Data(
        """
        {"choices":[{"message":{"role":"assistant","tool_calls":[
        \(rendered)
        ]}}]}
        """.utf8
    )
}

@Suite("MLX brain client")
struct MLXBrainClientTests {
    private let inventory = [
        InstalledApplicationUsage(
            displayName: "Spotify", openCount: 12, lastUsedDaysAgo: 0
        )
    ]

    @Test("A tool call in the response becomes a raw proposal")
    func parsesToolCall() async throws {
        let client = MLXBrainClient(transport: StubTransport(body: toolCallResponse()))
        let calls = try await client.propose(
            request: "i want music", inventory: inventory
        )
        #expect(calls.count == 1)
        #expect(calls[0].toolName == "open_application")
        #expect(calls[0].argumentsJSON.contains("Spotify"))
    }

    @Test("Every tool call is returned in model order")
    func parsesOrderedToolCalls() async throws {
        let body = toolCallResponse(
            calls: [
                (
                    "open_application",
                    #"{\"name\":\"Spotify\",\"reason\":\"First.\"}"#
                ),
                (
                    "switch_to_application",
                    #"{\"name\":\"Music\",\"reason\":\"Second.\"}"#
                ),
            ]
        )
        let client = MLXBrainClient(transport: StubTransport(body: body))

        let calls = try await client.propose(
            request: "open both", inventory: inventory
        )

        #expect(
            calls.map(\.toolName)
                == ["open_application", "switch_to_application"]
        )
        #expect(calls[0].argumentsJSON.contains("Spotify"))
        #expect(calls[1].argumentsJSON.contains("Music"))
    }

    @Test("A malformed later tool call refuses the complete response")
    func rejectsMalformedLaterToolCall() async {
        let body = Data(
            """
            {"choices":[{"message":{"role":"assistant","tool_calls":[
            {"type":"function","function":{"name":"open_application","arguments":"{\\"name\\":\\"Spotify\\",\\"reason\\":\\"Valid prefix.\\"}"}},
            {"type":"function","function":{"arguments":"{}"}}
            ]}}]}
            """.utf8
        )
        let client = MLXBrainClient(transport: StubTransport(body: body))

        await #expect(throws: LocalBrainError.badResponse("unrecognized tool call")) {
            try await client.propose(request: "open both", inventory: inventory)
        }
    }

    @Test("A response with no tool call is reported, never invented")
    func rejectsMissingToolCall() async {
        let body = Data(#"{"choices":[{"message":{"role":"assistant","content":"hi"}}]}"#.utf8)
        let client = MLXBrainClient(transport: StubTransport(body: body))
        await #expect(throws: LocalBrainError.noToolCall) {
            try await client.propose(request: "hello", inventory: inventory)
        }
    }

    @Test("A non-200 status is surfaced as a bad response")
    func rejectsHTTPError() async {
        let client = MLXBrainClient(
            transport: StubTransport(status: 500, body: Data("boom".utf8))
        )
        await #expect(throws: (any Error).self) {
            try await client.propose(request: "x", inventory: inventory)
        }
    }

    @Test("Unparseable JSON is surfaced, never crashes")
    func rejectsUnparseableBody() async {
        let client = MLXBrainClient(transport: StubTransport(body: Data("<html>".utf8)))
        await #expect(throws: (any Error).self) {
            try await client.propose(request: "x", inventory: inventory)
        }
    }

    @Test("A transport failure becomes unavailable")
    func mapsTransportFailure() async {
        struct Boom: Error {}
        let client = MLXBrainClient(transport: StubTransport(error: Boom()))
        await #expect(throws: LocalBrainError.unavailable) {
            try await client.propose(request: "x", inventory: inventory)
        }
    }

    @Test("A URLError timeout is distinguished from a plain connection failure")
    func mapsTimeoutDistinctly() async {
        let client = MLXBrainClient(
            transport: StubTransport(error: URLError(.timedOut))
        )
        await #expect(throws: LocalBrainError.timedOut) {
            try await client.propose(request: "x", inventory: inventory)
        }
    }

    @Test("An unrecognized transport error still degrades to unavailable")
    func mapsUnrecognizedErrorToUnavailable() async {
        struct Weird: Error {}
        let client = MLXBrainClient(transport: StubTransport(error: Weird()))
        await #expect(throws: LocalBrainError.unavailable) {
            try await client.propose(request: "x", inventory: inventory)
        }
    }

    @Test("The request targets loopback only")
    func usesLoopback() async throws {
        let transport = CapturingTransport(response: toolCallResponse())
        let client = MLXBrainClient(transport: transport)
        _ = try await client.propose(request: "i want music", inventory: inventory)
        let host = transport.sentURL?.host
        #expect(host == "127.0.0.1")
    }

    @Test("The inventory and the user request are both sent to the model")
    func sendsInventoryAndRequest() async throws {
        let transport = CapturingTransport(response: toolCallResponse())
        let client = MLXBrainClient(transport: transport)
        _ = try await client.propose(request: "i want music", inventory: inventory)
        guard let sent = transport.sentBody,
            let text = String(data: sent, encoding: .utf8)
        else {
            Issue.record("Expected a request body")
            return
        }
        #expect(text.contains("Spotify"))
        #expect(text.contains("i want music"))
        #expect(text.contains("open_application"))
        #expect(text.contains("no_supported_action"))
    }

    @Test("Sampling is deterministic so the same request behaves the same way")
    func usesGreedySampling() async throws {
        let transport = CapturingTransport(response: toolCallResponse())
        let client = MLXBrainClient(transport: transport)
        _ = try await client.propose(request: "x", inventory: inventory)
        guard let sent = transport.sentBody,
            let object = try JSONSerialization.jsonObject(with: sent) as? [String: Any]
        else {
            Issue.record("Expected a JSON body")
            return
        }
        #expect((object["temperature"] as? Double) == 0)
    }
}
