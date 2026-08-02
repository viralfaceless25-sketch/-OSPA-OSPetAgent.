import AvatarCore
import CoreFoundation
import Foundation

public enum LocalBrainError: Error, Equatable {
    case unavailable
    case timedOut
    case badResponse(String)
    case noToolCall
}

/// Injected so the client can be tested without a running model or a network.
public protocol BrainHTTPTransport: Sendable {
    func post(
        url: URL, body: Data, timeout: TimeInterval
    ) async throws -> (status: Int, body: Data)
}

public struct URLSessionBrainTransport: BrainHTTPTransport {
    public init() {}

    public func post(
        url: URL, body: Data, timeout: TimeInterval
    ) async throws -> (status: Int, body: Data) {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        request.timeoutInterval = timeout

        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        return (status, data)
    }
}

/// Turns plain language plus an app inventory into ordered, untrusted tool calls.
public protocol LocalBrainService: Sendable {
    func propose(
        request: String,
        inventory: [InstalledApplicationUsage]
    ) async throws -> [RawBrainToolCall]

    func propose(
        request: String,
        inventory: [InstalledApplicationUsage],
        corrections: [BrainCorrection]
    ) async throws -> [RawBrainToolCall]
}

public extension LocalBrainService {
    func propose(
        request: String,
        inventory: [InstalledApplicationUsage],
        corrections: [BrainCorrection]
    ) async throws -> [RawBrainToolCall] {
        try await propose(request: request, inventory: inventory)
    }
}

/// A classification only. It contains no application, arguments, or plan.
public enum LocalBrainIntentLane: String, Equatable, Sendable {
    case nativeApp = "native_app"
    case chat
    case unsupported
}

/// Chooses which existing boundary should handle otherwise-unparsed language.
public protocol LocalBrainIntentRouting: Sendable {
    func route(request: String) async throws -> LocalBrainIntentLane
}

/// Produces display-only offline text. It has no action or plan representation.
public protocol LocalBrainChatService: Sendable {
    func answer(request: String) async throws -> String
}

/// Display-only UX evidence. It grants no authority and cannot create a plan.
public struct BrainProposalConfidence: Equatable, Sendable {
    public let score: Double
    public let alternatives: [String]

    public init(score: Double, alternatives: [String]) {
        self.score = score
        self.alternatives = alternatives
    }
}

/// Scores an already-validated proposal for clarification UX only.
public protocol LocalBrainProposalEvaluating: Sendable {
    func evaluate(
        request: String,
        proposals: [BrainProposal],
        inventory: [InstalledApplicationUsage]
    ) async throws -> BrainProposalConfidence
}

/// Talks to a local `mlx_lm.server` over loopback using the OpenAI chat
/// completions shape. Returns the model's tool calls verbatim; validation is
/// deliberately somebody else's job.
public struct MLXBrainClient:
    LocalBrainService, LocalBrainIntentRouting, LocalBrainChatService,
    LocalBrainProposalEvaluating
{
    private let endpoint: URL
    private let modelIdentifier: String
    private let timeout: TimeInterval
    private let transport: any BrainHTTPTransport
    private let promptBuilder = BrainPromptBuilder()

    public init(
        endpoint: URL = URL(string: "http://127.0.0.1:8081/v1/chat/completions")!,
        modelIdentifier: String = "mlx-community/Qwen3-8B-4bit",
        timeout: TimeInterval = 30,
        transport: any BrainHTTPTransport = URLSessionBrainTransport()
    ) {
        self.endpoint = endpoint
        self.modelIdentifier = modelIdentifier
        self.timeout = timeout
        self.transport = transport
    }

    public func propose(
        request: String,
        inventory: [InstalledApplicationUsage]
    ) async throws -> [RawBrainToolCall] {
        try await propose(
            request: request,
            inventory: inventory,
            corrections: []
        )
    }

    public func propose(
        request: String,
        inventory: [InstalledApplicationUsage],
        corrections: [BrainCorrection]
    ) async throws -> [RawBrainToolCall] {
        let response = try await send(
            payload: requestPayload(
                request: request,
                inventory: inventory,
                corrections: corrections
            )
        )
        return try Self.toolCalls(in: response)
    }

    public func route(request: String) async throws -> LocalBrainIntentLane {
        let response = try await send(payload: routePayload(request: request))
        let calls = try Self.toolCalls(in: response)
        guard calls.count == 1, let call = calls.first else {
            throw LocalBrainError.badResponse(
                "expected exactly one intent route"
            )
        }
        // Servers and models routinely omit `arguments` entirely, or send "",
        // for a zero-parameter function. Treat absent as equivalent to {} —
        // rejecting it would fail closed on every single request against a
        // real server, which reads as the whole feature being broken.
        let rawArguments = call.argumentsJSON.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        if !rawArguments.isEmpty {
            guard
                let data = rawArguments.data(using: .utf8),
                let arguments = try? JSONSerialization.jsonObject(with: data)
                    as? [String: Any],
                arguments.isEmpty
            else {
                throw LocalBrainError.badResponse(
                    "intent route arguments must be absent or empty"
                )
            }
        }
        guard let lane = LocalBrainIntentLane(rawValue: call.toolName) else {
            throw LocalBrainError.badResponse("unknown intent route")
        }
        return lane
    }

    public func answer(request: String) async throws -> String {
        let response = try await send(payload: chatPayload(request: request))
        return try Self.chatAnswer(in: response)
    }

    public func evaluate(
        request: String,
        proposals: [BrainProposal],
        inventory: [InstalledApplicationUsage]
    ) async throws -> BrainProposalConfidence {
        let response = try await send(
            payload: evaluatorPayload(
                request: request,
                proposals: proposals,
                inventory: inventory
            )
        )
        return try Self.proposalConfidence(
            in: response,
            proposals: proposals,
            inventory: inventory
        )
    }

    private func send(payload: [String: Any]) async throws -> Data {
        let body: Data
        do {
            body = try JSONSerialization.data(
                withJSONObject: payload
            )
        } catch {
            // Every value `requestPayload` builds today (strings, an Int, a
            // fixed array of dictionaries) is guaranteed JSON-representable,
            // so this is unreachable in practice. It is still caught rather
            // than left to propagate a raw `CocoaError`, so a future edit to
            // `requestPayload` (e.g. introducing a `Date` or a non-finite
            // `Double`) fails the same documented `LocalBrainError` contract
            // instead of silently breaking it. `.badResponse` is the closest
            // fit of the four existing cases: it is the only one that
            // carries a free-form diagnostic string, and it already means
            // "this call could not be turned into a usable HTTP exchange" --
            // `.unavailable`/`.timedOut` are reserved for transport-layer
            // reachability signals (see the `post` failure handling below),
            // and `.noToolCall` is unrelated to request construction.
            throw LocalBrainError.badResponse("failed to encode request: \(error)")
        }

        let response: (status: Int, body: Data)
        do {
            response = try await transport.post(
                url: endpoint, body: body, timeout: timeout
            )
        } catch {
            // The transport may not be URLSession-backed -- an injected fake
            // can throw anything -- so only a recognized `URLError.timedOut`
            // is distinguished; every other error (including unrecognized
            // error types) degrades to `.unavailable`, which is the correct
            // default for "the local model server could not be reached."
            if let urlError = error as? URLError, urlError.code == .timedOut {
                throw LocalBrainError.timedOut
            }
            throw LocalBrainError.unavailable
        }

        guard response.status == 200 else {
            throw LocalBrainError.badResponse("status \(response.status)")
        }
        return response.body
    }

    private func requestPayload(
        request: String,
        inventory: [InstalledApplicationUsage],
        corrections: [BrainCorrection]
    ) -> [String: Any] {
        var messages: [[String: String]] = [
            [
                "role": "system",
                "content": promptBuilder.systemPrompt(for: inventory),
            ]
        ]
        let installedNames = Set(inventory.map(\.displayName))
        let groundedCorrections = corrections.filter {
            installedNames.contains($0.rejectedApplicationName)
        }
        if let context = promptBuilder.correctionContext(
            for: groundedCorrections
        ) {
            messages.append(["role": "system", "content": context])
        }
        messages.append(["role": "user", "content": request])

        return [
            "model": modelIdentifier,
            // Greedy: the same request should behave the same way every time.
            "temperature": 0,
            "max_tokens": 800,
            "messages": messages,
            "tools": Self.toolSchemas,
        ]
    }

    private func routePayload(request: String) -> [String: Any] {
        [
            "model": modelIdentifier,
            "temperature": 0,
            "max_tokens": 32,
            "messages": [
                [
                    "role": "system",
                    "content": """
                        Classify the request into exactly one lane. Call one tool \
                        and do not answer the request. Use native_app only for \
                        requests to open, switch to, or use Mac applications. \
                        Use chat only for conversation or timeless general \
                        knowledge that needs no current information or action. \
                        Use unsupported for web browsing, current information, \
                        or any action beyond opening or switching applications.
                        """,
                ],
                ["role": "user", "content": request],
            ],
            "tools": Self.routeToolSchemas,
            "tool_choice": "required",
        ]
    }

    private func chatPayload(request: String) -> [String: Any] {
        [
            "model": modelIdentifier,
            "temperature": 0,
            "max_tokens": 600,
            "messages": [
                [
                    "role": "system",
                    "content": """
                        You are OSPA's offline chat. Answer in one short plain-text \
                        paragraph using timeless general knowledge only. You have \
                        no web access, current information, or action tools. Never \
                        claim that you browsed, checked live data, or performed an \
                        action. If the request needs those things, say plainly that \
                        you cannot do it.
                        """,
                ],
                ["role": "user", "content": request],
            ],
        ]
    }

    private func evaluatorPayload(
        request: String,
        proposals: [BrainProposal],
        inventory: [InstalledApplicationUsage]
    ) -> [String: Any] {
        let proposed = proposals.compactMap {
            Self.applicationName(in: $0)
        }
        let installed = inventory.map {
            "\($0.displayName) (opened \($0.openCount) times)"
        }.joined(separator: "\n")
        return [
            "model": modelIdentifier,
            "temperature": 0,
            "max_tokens": 100,
            "messages": [
                [
                    "role": "system",
                    "content": """
                        Score how confidently the proposed installed application \
                        matches the request. Call score_proposal exactly once. A \
                        score of 1 means unambiguous; 0 means a guess. If useful, \
                        list at most two better alternatives copied exactly from \
                        the installed list. This is evaluation only: do not choose \
                        an action or answer the request.
                        """,
                ],
                [
                    "role": "user",
                    "content": """
                        Request: \(request)
                        Proposed: \(proposed.joined(separator: ", "))
                        Installed applications:
                        \(installed)
                        """,
                ],
            ],
            "tools": Self.evaluatorToolSchemas,
            "tool_choice": "required",
        ]
    }

    // Computed, not a stored `static let`: `[[String: Any]]` is not `Sendable`,
    // and Swift 6 strict concurrency rejects a stored global of a non-Sendable
    // type as possible shared mutable state. A computed property rebuilds the
    // (small, constant) array on each access instead, which sidesteps that
    // without introducing any actual shared state.
    private static var toolSchemas: [[String: Any]] {
        [
        functionSchema(
            name: BrainTool.openApplication.rawValue,
            description: "Launch an installed application, or bring it to the front if it is already running.",
            properties: [
                "name": [
                    "type": "string",
                    "description": "Exact display name, copied from the installed list.",
                ],
                "reason": [
                    "type": "string",
                    "description": "One short sentence explaining why this app suits the request.",
                ],
            ],
            required: ["name", "reason"]
        ),
        functionSchema(
            name: BrainTool.switchToApplication.rawValue,
            description: "Bring an application that is already running to the front.",
            properties: [
                "name": [
                    "type": "string",
                    "description": "Exact display name, copied from the installed list.",
                ],
                "reason": ["type": "string"],
            ],
            required: ["name", "reason"]
        ),
        functionSchema(
            name: BrainTool.noSupportedAction.rawValue,
            description: "Use when no installed application can satisfy the request, or the application the person named is not installed.",
            properties: ["reason": ["type": "string"]],
            required: ["reason"]
        ),
        ]
    }

    private static var routeToolSchemas: [[String: Any]] {
        [
            routeFunctionSchema(
                name: LocalBrainIntentLane.nativeApp.rawValue,
                description: "The request is for one or more native Mac application actions."
            ),
            routeFunctionSchema(
                name: LocalBrainIntentLane.chat.rawValue,
                description: "The request needs only offline conversation or timeless general knowledge."
            ),
            routeFunctionSchema(
                name: LocalBrainIntentLane.unsupported.rawValue,
                description: "The request needs current or external information, web access, or an unsupported action."
            ),
        ]
    }

    private static var evaluatorToolSchemas: [[String: Any]] {
        [
            functionSchema(
                name: "score_proposal",
                description: "Score proposal confidence and suggest display-only installed alternatives.",
                properties: [
                    "score": [
                        "type": "number",
                        "minimum": 0,
                        "maximum": 1,
                    ],
                    "alternatives": [
                        "type": "array",
                        "items": ["type": "string"],
                        "maxItems": 2,
                    ],
                ],
                required: ["score", "alternatives"],
                additionalProperties: false
            )
        ]
    }

    private static func routeFunctionSchema(
        name: String,
        description: String
    ) -> [String: Any] {
        [
            "type": "function",
            "function": [
                "name": name,
                "description": description,
                "parameters": [
                    "type": "object",
                    "properties": [String: Any](),
                    "required": [String](),
                    "additionalProperties": false,
                ],
            ],
        ]
    }

    private static func functionSchema(
        name: String,
        description: String,
        properties: [String: Any],
        required: [String],
        additionalProperties: Bool? = nil
    ) -> [String: Any] {
        var parameters: [String: Any] = [
            "type": "object",
            "properties": properties,
            "required": required,
        ]
        if let additionalProperties {
            parameters["additionalProperties"] = additionalProperties
        }
        return [
            "type": "function",
            "function": [
                "name": name,
                "description": description,
                "parameters": parameters,
            ],
        ]
    }

    /// Parses the OpenAI chat-completions response shape. `data` is untrusted
    /// bytes from a local process: every cast here is optional and every
    /// intermediate access goes through `?`/`.first`, so a missing key, a
    /// `null` where an object is expected, a wrong type, or an empty
    /// `tool_calls` array all fall through to a typed error rather than a
    /// trap. Nothing here force-unwraps, force-tries, or indexes an array
    /// directly.
    private static func toolCalls(in data: Data) throws -> [RawBrainToolCall] {
        guard
            let root = try? JSONSerialization.jsonObject(with: data)
                as? [String: Any],
            let choices = root["choices"] as? [[String: Any]],
            let message = choices.first?["message"] as? [String: Any]
        else {
            throw LocalBrainError.badResponse("unrecognized response shape")
        }
        guard let calls = message["tool_calls"] as? [[String: Any]],
            !calls.isEmpty
        else {
            throw LocalBrainError.noToolCall
        }
        return try calls.map { call in
            guard
                let function = call["function"] as? [String: Any],
                let name = function["name"] as? String
            else {
                // Throwing `map`, rather than `compactMap`, makes a malformed
                // later entry refuse the complete response. A valid prefix is
                // never returned on its own.
                throw LocalBrainError.badResponse("unrecognized tool call")
            }
            // `arguments` is untrusted: a non-string value (missing, null,
            // number, nested object) must not crash. Passing an empty string
            // through is safe -- RawBrainToolCall.argumentsJSON is documented
            // as raw, unvalidated text, and BrainProposalValidator rejects it
            // as `.malformedArguments`.
            let arguments = function["arguments"] as? String ?? ""
            return RawBrainToolCall(
                toolName: name,
                argumentsJSON: arguments
            )
        }
    }

    private static func chatAnswer(in data: Data) throws -> String {
        guard
            let root = try? JSONSerialization.jsonObject(with: data)
                as? [String: Any],
            let choices = root["choices"] as? [[String: Any]],
            let message = choices.first?["message"] as? [String: Any],
            let content = message["content"] as? String
        else {
            throw LocalBrainError.badResponse(
                "unrecognized chat response shape"
            )
        }

        // One implementation of the bound, owned by the pure layer, so the
        // transport check and the publication check cannot drift apart.
        guard let answer = BrainChatAnswer.sanitized(content) else {
            throw LocalBrainError.badResponse("unsafe chat response")
        }
        return answer
    }

    private static func proposalConfidence(
        in data: Data,
        proposals: [BrainProposal],
        inventory: [InstalledApplicationUsage]
    ) throws -> BrainProposalConfidence {
        let calls = try toolCalls(in: data)
        guard calls.count == 1, let call = calls.first,
            call.toolName == "score_proposal",
            let argumentsData = call.argumentsJSON.data(using: .utf8),
            let arguments = try? JSONSerialization.jsonObject(
                with: argumentsData
            ) as? [String: Any],
            Set(arguments.keys) == Set(["score", "alternatives"]),
            let scoreNumber = arguments["score"] as? NSNumber,
            CFGetTypeID(scoreNumber) != CFBooleanGetTypeID(),
            let alternatives = arguments["alternatives"] as? [String]
        else {
            throw LocalBrainError.badResponse(
                "invalid proposal confidence"
            )
        }

        let score = scoreNumber.doubleValue
        let installedNames = Set(inventory.map(\.displayName))
        let proposedNames = Set(proposals.compactMap(applicationName(in:)))
        guard score.isFinite, (0...1).contains(score),
            alternatives.count <= 2,
            Set(alternatives).count == alternatives.count,
            alternatives.allSatisfy({
                installedNames.contains($0) && !proposedNames.contains($0)
            })
        else {
            throw LocalBrainError.badResponse(
                "invalid proposal confidence"
            )
        }
        return BrainProposalConfidence(
            score: score,
            alternatives: alternatives
        )
    }

    private static func applicationName(
        in proposal: BrainProposal
    ) -> String? {
        switch proposal {
        case let .openApplication(name, _),
            let .switchToApplication(name, _):
            name
        case .noSupportedAction:
            nil
        }
    }
}
