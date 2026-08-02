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

private func chatResponse(_ content: String) throws -> Data {
    try JSONSerialization.data(
        withJSONObject: [
            "choices": [
                ["message": ["role": "assistant", "content": content]]
            ]
        ]
    )
}

@Suite("MLX brain client")
struct MLXBrainClientTests {
    private let inventory = [
        InstalledApplicationUsage(
            displayName: "Spotify", openCount: 12, lastUsedDaysAgo: 0
        )
    ]

    @Test("The router returns exactly one allowlisted lane")
    func parsesIntentRoute() async throws {
        let client = MLXBrainClient(
            transport: StubTransport(
                body: toolCallResponse(name: "unsupported", arguments: "{}")
            )
        )

        let lane = try await client.route(
            request: "what's the weather in Tokyo"
        )

        #expect(lane == .unsupported)
    }

    @Test("The router sees no inventory or action arguments")
    func routePayloadIsClassificationOnly() async throws {
        let transport = CapturingTransport(
            response: toolCallResponse(name: "native_app", arguments: "{}")
        )
        let client = MLXBrainClient(transport: transport)

        _ = try await client.route(request: "open my music app")

        let body = try #require(transport.sentBody)
        let object = try #require(
            try JSONSerialization.jsonObject(with: body) as? [String: Any]
        )
        let tools = try #require(object["tools"] as? [[String: Any]])
        let functions = try tools.map { tool in
            try #require(tool["function"] as? [String: Any])
        }
        #expect(
            functions.compactMap { $0["name"] as? String }
                == ["native_app", "chat", "unsupported"]
        )
        for function in functions {
            let parameters = try #require(
                function["parameters"] as? [String: Any]
            )
            #expect((parameters["properties"] as? [String: Any])?.isEmpty == true)
            #expect(parameters["additionalProperties"] as? Bool == false)
        }
        #expect(object["tool_choice"] as? String == "required")
        #expect((object["temperature"] as? Double) == 0)
        let text = try #require(String(data: body, encoding: .utf8))
        #expect(text.contains("open my music app"))
        #expect(!text.contains("Spotify"))
        #expect(!text.contains("open_application"))
        #expect(!text.contains("switch_to_application"))
    }

    @Test("Missing or multiple routes are refused rather than guessed")
    func rejectsWrongIntentRouteCount() async {
        let missing = MLXBrainClient(
            transport: StubTransport(
                body: Data(
                    #"{"choices":[{"message":{"role":"assistant","content":"unsupported"}}]}"#.utf8
                )
            )
        )
        await #expect(throws: LocalBrainError.noToolCall) {
            try await missing.route(request: "weather")
        }

        let multiple = MLXBrainClient(
            transport: StubTransport(
                body: toolCallResponse(
                    calls: [
                        ("chat", "{}"),
                        ("unsupported", "{}"),
                    ]
                )
            )
        )
        await #expect(
            throws: LocalBrainError.badResponse(
                "expected exactly one intent route"
            )
        ) {
            try await multiple.route(request: "weather")
        }
    }

    @Test("Unknown routes and argument-bearing routes are refused")
    func rejectsInvalidIntentRoute() async {
        let unknown = MLXBrainClient(
            transport: StubTransport(
                body: toolCallResponse(name: "browse_web", arguments: "{}")
            )
        )
        await #expect(
            throws: LocalBrainError.badResponse("unknown intent route")
        ) {
            try await unknown.route(request: "weather")
        }

        let argumentBearing = MLXBrainClient(
            transport: StubTransport(
                body: toolCallResponse(
                    name: "native_app",
                    arguments: #"{\"name\":\"Safari\"}"#
                )
            )
        )
        await #expect(
            throws: LocalBrainError.badResponse(
                "intent route arguments must be absent or empty"
            )
        ) {
            try await argumentBearing.route(request: "weather")
        }

        let malformed = MLXBrainClient(
            transport: StubTransport(
                body: toolCallResponse(name: "chat", arguments: "not-json")
            )
        )
        await #expect(
            throws: LocalBrainError.badResponse(
                "intent route arguments must be absent or empty"
            )
        ) {
            try await malformed.route(request: "hello")
        }
    }

    /// Servers and models commonly omit `arguments`, or send `""`, for a
    /// zero-parameter function. Rejecting that would fail closed on every real
    /// request, so absent arguments must be accepted as equivalent to `{}`.
    @Test(
        "A zero-argument route is accepted however the server spells it",
        arguments: ["", "   ", "{}"]
    )
    func acceptsAbsentIntentRouteArguments(arguments: String) async throws {
        let client = MLXBrainClient(
            transport: StubTransport(
                body: toolCallResponse(name: "chat", arguments: arguments)
            )
        )
        #expect(try await client.route(request: "explain photosynthesis") == .chat)
    }

    @Test("Offline chat returns one trimmed safe paragraph")
    func parsesOfflineChatResponse() async throws {
        let client = MLXBrainClient(
            transport: StubTransport(
                body: try chatResponse("  Hello there.  ")
            )
        )

        let answer = try await client.answer(request: "hello")

        #expect(answer == "Hello there.")
    }

    @Test("Offline chat receives no tools or application inventory")
    func chatPayloadCannotProposeActions() async throws {
        let transport = CapturingTransport(
            response: try chatResponse("A short offline answer.")
        )
        let client = MLXBrainClient(transport: transport)

        _ = try await client.answer(request: "explain photosynthesis")

        let body = try #require(transport.sentBody)
        let object = try #require(
            try JSONSerialization.jsonObject(with: body) as? [String: Any]
        )
        #expect(object["tools"] == nil)
        #expect((object["temperature"] as? Double) == 0)
        #expect(object["max_tokens"] as? Int == 600)
        let text = try #require(String(data: body, encoding: .utf8))
        #expect(text.contains("explain photosynthesis"))
        #expect(text.contains("offline"))
        #expect(!text.contains("Spotify"))
        #expect(!text.contains("open_application"))
        #expect(!text.contains("native_app"))
    }

    @Test("Unsafe or unbounded chat text is refused before publication")
    func rejectsUnsafeChatResponse() async throws {
        let invalidAnswers = [
            "   ",
            String(repeating: "a", count: 2_001),
            "unsafe\u{0007}text",
            "misleading\u{202E}text",
            "multiple\nlines",
        ]

        for answer in invalidAnswers {
            let client = MLXBrainClient(
                transport: StubTransport(
                    body: try chatResponse(answer)
                )
            )
            await #expect(
                throws: LocalBrainError.badResponse("unsafe chat response")
            ) {
                try await client.answer(request: "hello")
            }
        }
    }

    @Test("A malformed chat response is refused rather than guessed")
    func rejectsMalformedChatResponse() async {
        let client = MLXBrainClient(
            transport: StubTransport(
                body: Data(
                    #"{"choices":[{"message":{"role":"assistant","content":42}}]}"#.utf8
                )
            )
        )

        await #expect(
            throws: LocalBrainError.badResponse(
                "unrecognized chat response shape"
            )
        ) {
            try await client.answer(request: "hello")
        }
    }

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

    @Test("Corrections follow the stable inventory prefix and stay grounded")
    func sendsCorrectionsAfterStablePrefix() async throws {
        let transport = CapturingTransport(response: toolCallResponse())
        let client: any LocalBrainService = MLXBrainClient(transport: transport)
        let corrections = [
            BrainCorrection(
                requestShape: "play music",
                rejectedApplicationName: "Spotify",
                declinedAt: Date(timeIntervalSince1970: 10)
            ),
            BrainCorrection(
                requestShape: "play music",
                rejectedApplicationName: "Uninstalled",
                declinedAt: Date(timeIntervalSince1970: 11)
            ),
        ]

        _ = try await client.propose(
            request: "play music",
            inventory: inventory,
            corrections: corrections
        )

        let body = try #require(transport.sentBody)
        let object = try #require(
            try JSONSerialization.jsonObject(with: body) as? [String: Any]
        )
        let messages = try #require(object["messages"] as? [[String: String]])
        try #require(messages.count == 3)
        #expect(
            messages[0]["content"]
                == BrainPromptBuilder().systemPrompt(for: inventory)
        )
        #expect(messages[1]["content"]?.contains("Spotify") == true)
        #expect(messages[1]["content"]?.contains("Uninstalled") == false)
        #expect(messages[2] == ["role": "user", "content": "play music"])
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

    @Test("The evaluator returns one bounded score with grounded alternatives")
    func parsesProposalConfidence() async throws {
        let transport = CapturingTransport(
            response: toolCallResponse(
                name: "score_proposal",
                arguments:
                    #"{\"score\":0.42,\"alternatives\":[\"Music\"]}"#
            )
        )
        let client: any LocalBrainProposalEvaluating = MLXBrainClient(
            transport: transport
        )
        let expandedInventory = inventory + [
            InstalledApplicationUsage(
                displayName: "Music", openCount: 8, lastUsedDaysAgo: 1
            )
        ]

        let confidence = try await client.evaluate(
            request: "play music",
            proposals: [
                .openApplication(name: "Spotify", reason: "You use it for music.")
            ],
            inventory: expandedInventory
        )

        #expect(confidence == BrainProposalConfidence(score: 0.42, alternatives: ["Music"]))
        let body = try #require(transport.sentBody)
        let object = try #require(
            try JSONSerialization.jsonObject(with: body) as? [String: Any]
        )
        let tools = try #require(object["tools"] as? [[String: Any]])
        let function = try #require(tools.first?["function"] as? [String: Any])
        #expect(tools.count == 1)
        #expect(function["name"] as? String == "score_proposal")
        #expect(object["tool_choice"] as? String == "required")
        let text = try #require(String(data: body, encoding: .utf8))
        #expect(text.contains("play music"))
        #expect(text.contains("Spotify"))
        #expect(text.contains("Music"))
        #expect(!text.contains("open_application"))
        #expect(!text.contains("switch_to_application"))
    }

    @Test("Malformed or authority-expanding evaluator output is refused")
    func rejectsInvalidProposalConfidence() async {
        let proposal = BrainProposal.openApplication(
            name: "Spotify",
            reason: "You use it for music."
        )
        let expandedInventory = inventory + [
            InstalledApplicationUsage(
                displayName: "Music", openCount: 8, lastUsedDaysAgo: 1
            )
        ]
        let responses = [
            Data(#"{"choices":[{"message":{"role":"assistant","content":"0.9"}}]}"#.utf8),
            toolCallResponse(
                calls: [
                    ("score_proposal", #"{\"score\":0.8,\"alternatives\":[]}"#),
                    ("score_proposal", #"{\"score\":0.9,\"alternatives\":[]}"#),
                ]
            ),
            toolCallResponse(name: "open_application", arguments: #"{\"score\":0.8,\"alternatives\":[]}"#),
            toolCallResponse(name: "score_proposal", arguments: #"{\"alternatives\":[]}"#),
            toolCallResponse(name: "score_proposal", arguments: #"{\"score\":\"high\",\"alternatives\":[]}"#),
            toolCallResponse(name: "score_proposal", arguments: #"{\"score\":-0.1,\"alternatives\":[]}"#),
            toolCallResponse(name: "score_proposal", arguments: #"{\"score\":1.1,\"alternatives\":[]}"#),
            toolCallResponse(name: "score_proposal", arguments: #"{\"score\":0.5,\"alternatives\":[\"Music\",\"Spotify\",\"Other\"]}"#),
            toolCallResponse(name: "score_proposal", arguments: #"{\"score\":0.5,\"alternatives\":[\"Uninstalled\"]}"#),
            toolCallResponse(name: "score_proposal", arguments: #"{\"score\":0.5,\"alternatives\":[\"Spotify\"]}"#),
            toolCallResponse(name: "score_proposal", arguments: #"{\"score\":0.5,\"alternatives\":[\"Music\",\"Music\"]}"#),
            toolCallResponse(name: "score_proposal", arguments: #"{\"score\":0.5,\"alternatives\":[],\"action\":\"open Music\"}"#),
        ]

        for response in responses {
            let client = MLXBrainClient(
                transport: StubTransport(body: response)
            )
            await #expect(throws: (any Error).self) {
                try await client.evaluate(
                    request: "play music",
                    proposals: [proposal],
                    inventory: expandedInventory
                )
            }
        }
    }
}
