import AvatarCore
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

/// Turns plain language plus an app inventory into one untrusted tool call.
public protocol LocalBrainService: Sendable {
    func propose(
        request: String,
        inventory: [InstalledApplicationUsage]
    ) async throws -> RawBrainToolCall
}

/// Talks to a local `mlx_lm.server` over loopback using the OpenAI chat
/// completions shape. Returns the model's tool call verbatim; validation is
/// deliberately somebody else's job.
public struct MLXBrainClient: LocalBrainService {
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
    ) async throws -> RawBrainToolCall {
        let body = try JSONSerialization.data(
            withJSONObject: requestPayload(request: request, inventory: inventory)
        )

        let response: (status: Int, body: Data)
        do {
            response = try await transport.post(
                url: endpoint, body: body, timeout: timeout
            )
        } catch {
            throw LocalBrainError.unavailable
        }

        guard response.status == 200 else {
            throw LocalBrainError.badResponse("status \(response.status)")
        }
        return try Self.firstToolCall(in: response.body)
    }

    private func requestPayload(
        request: String,
        inventory: [InstalledApplicationUsage]
    ) -> [String: Any] {
        [
            "model": modelIdentifier,
            // Greedy: the same request should behave the same way every time.
            "temperature": 0,
            "max_tokens": 200,
            "messages": [
                [
                    "role": "system",
                    "content": promptBuilder.systemPrompt(for: inventory),
                ],
                ["role": "user", "content": request],
            ],
            "tools": Self.toolSchemas,
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

    private static func functionSchema(
        name: String,
        description: String,
        properties: [String: Any],
        required: [String]
    ) -> [String: Any] {
        [
            "type": "function",
            "function": [
                "name": name,
                "description": description,
                "parameters": [
                    "type": "object",
                    "properties": properties,
                    "required": required,
                ],
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
    private static func firstToolCall(in data: Data) throws -> RawBrainToolCall {
        guard
            let root = try? JSONSerialization.jsonObject(with: data)
                as? [String: Any],
            let choices = root["choices"] as? [[String: Any]],
            let message = choices.first?["message"] as? [String: Any]
        else {
            throw LocalBrainError.badResponse("unrecognized response shape")
        }
        guard
            let calls = message["tool_calls"] as? [[String: Any]],
            let function = calls.first?["function"] as? [String: Any],
            let name = function["name"] as? String
        else {
            throw LocalBrainError.noToolCall
        }
        // `arguments` is untrusted: a non-string value (missing, null,
        // number, nested object) must not crash. Passing an empty string
        // through is safe -- RawBrainToolCall.argumentsJSON is documented as
        // raw, unvalidated text, and the downstream BrainProposalValidator
        // already treats an empty/unparseable arguments string as
        // `.malformedArguments`. This layer's only job is not to trap.
        let arguments = function["arguments"] as? String ?? ""
        return RawBrainToolCall(toolName: name, argumentsJSON: arguments)
    }
}
