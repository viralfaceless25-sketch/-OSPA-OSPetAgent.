import Foundation

/// The closed set of tools offered to the model. Anything outside this is
/// rejected; adding a case is a deliberate change requiring new validation.
public enum BrainTool: String, CaseIterable, Sendable {
    case openApplication = "open_application"
    case switchToApplication = "switch_to_application"
    case noSupportedAction = "no_supported_action"
}

/// Exactly what the model returned, unvalidated and untrusted.
///
/// Arguments stay as raw JSON text so that parsing failures are caught by the
/// pure validator below, where they are exhaustively tested, rather than in the
/// networking layer.
public struct RawBrainToolCall: Equatable, Sendable {
    public let toolName: String
    public let argumentsJSON: String

    public init(toolName: String, argumentsJSON: String) {
        self.toolName = toolName
        self.argumentsJSON = argumentsJSON
    }
}

/// A model suggestion that has been proven safe: the tool is known and any named
/// application is one that actually exists on this Mac.
public enum BrainProposal: Equatable, Sendable {
    case openApplication(name: String, reason: String)
    case switchToApplication(name: String, reason: String)
    case noSupportedAction(reason: String)

    /// Hands off to the existing typed-command pipeline. Everything downstream of
    /// this point is unchanged Sub-A code.
    public var parsedApplicationCommand: ParsedApplicationCommand? {
        switch self {
        case let .openApplication(name, _):
            ParsedApplicationCommand(
                operation: .launchOrActivate,
                requestedApplicationName: name
            )
        case let .switchToApplication(name, _):
            ParsedApplicationCommand(
                operation: .switchToRunning,
                requestedApplicationName: name
            )
        case .noSupportedAction:
            nil
        }
    }

    public var reason: String {
        switch self {
        case let .openApplication(_, reason): reason
        case let .switchToApplication(_, reason): reason
        case let .noSupportedAction(reason): reason
        }
    }
}

public enum BrainProposalError: Error, Equatable {
    case unknownTool(String)
    case malformedArguments
    case missingArgument(String)
    /// The model named an application that is not installed. Expected in normal
    /// operation, not exceptional: this is the hallucination backstop.
    case applicationNotInstalled(String)
    case unsafeApplicationName
}

/// The sole safety authority over model output.
///
/// Prompt wording cannot be relied on for correctness: making the prompt strict
/// enough to stop one model hallucinating made a larger model refuse legitimate
/// requests. So the prompt is tuned for helpfulness and every guarantee is
/// enforced here, in code, against the same inventory the model was shown.
public struct BrainProposalValidator: Sendable {
    private static let maximumNameLength = 80

    public init() {}

    public func validate(
        _ call: RawBrainToolCall,
        installedApplicationNames: Set<String>
    ) throws -> BrainProposal {
        guard let tool = BrainTool(rawValue: call.toolName) else {
            throw BrainProposalError.unknownTool(call.toolName)
        }

        let arguments = try Self.decodeArguments(call.argumentsJSON)
        let reason = try Self.requiredValue(named: "reason", from: arguments)

        switch tool {
        case .noSupportedAction:
            return .noSupportedAction(reason: reason)
        case .openApplication, .switchToApplication:
            let name = try Self.requiredValue(named: "name", from: arguments)
            try Self.validateNameShape(name)
            guard
                let installed = Self.installedMatch(
                    for: name,
                    in: installedApplicationNames
                )
            else {
                throw BrainProposalError.applicationNotInstalled(name)
            }
            return tool == .openApplication
                ? .openApplication(name: installed, reason: reason)
                : .switchToApplication(name: installed, reason: reason)
        }
    }

    private static func decodeArguments(_ json: String) throws -> [String: String] {
        guard let data = json.data(using: .utf8), !data.isEmpty,
            let object = try? JSONSerialization.jsonObject(with: data),
            let dictionary = object as? [String: Any]
        else {
            throw BrainProposalError.malformedArguments
        }
        return dictionary.compactMapValues { $0 as? String }
    }

    private static func requiredValue(
        named key: String,
        from arguments: [String: String]
    ) throws -> String {
        let value =
            arguments[key]?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !value.isEmpty else {
            throw BrainProposalError.missingArgument(key)
        }
        return value
    }

    /// Same shape rules the typed-command parser enforces, so the brain path can
    /// never smuggle in a target the typed path would have refused.
    private static func validateNameShape(_ name: String) throws {
        guard name.count <= maximumNameLength else {
            throw BrainProposalError.unsafeApplicationName
        }
        guard !name.lowercased().hasSuffix(".app") else {
            throw BrainProposalError.unsafeApplicationName
        }
        guard !name.contains("/"), !name.contains("\\"), !name.contains("~")
        else {
            throw BrainProposalError.unsafeApplicationName
        }
        // Mirrors ApplicationCommandParser's guard against " and ": that parser
        // refuses it so one typed line can never be read as two application
        // targets. The brain call only ever carries a single `name` field, but
        // the contract is that this validator is at least as strict as the
        // typed path, so the same string is refused here too.
        guard !name.lowercased().contains(" and ") else {
            throw BrainProposalError.unsafeApplicationName
        }
        guard
            name.unicodeScalars.allSatisfy({
                !CharacterSet.controlCharacters.contains($0)
            })
        else {
            throw BrainProposalError.unsafeApplicationName
        }
    }

    /// Returns the inventory's own spelling so downstream resolution uses the
    /// canonical name rather than the model's rendering of it.
    private static func installedMatch(
        for name: String,
        in installed: Set<String>
    ) -> String? {
        installed.first { normalize($0) == normalize(name) }
    }

    private static func normalize(_ value: String) -> String {
        value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .precomposedStringWithCanonicalMapping
            .lowercased()
    }
}
