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
    case noToolCalls
    case tooManyToolCalls
    case unknownTool(String)
    case malformedArguments
    case missingArgument(String)
    /// The model named an application that is not installed. Expected in normal
    /// operation, not exceptional: this is the hallucination backstop.
    case applicationNotInstalled(String)
    case unsafeApplicationName
    /// The `reason` text failed a safety check (control/format characters, or
    /// too long). `reason` is the one piece of untrusted model text that
    /// reaches a human at the exact moment they decide whether to authorize
    /// an action, so it is validated as strictly as `name`.
    case unsafeReason
}

/// The sole safety authority over model output.
///
/// Prompt wording cannot be relied on for correctness: making the prompt strict
/// enough to stop one model hallucinating made a larger model refuse legitimate
/// requests. So the prompt is tuned for helpfulness and every guarantee is
/// enforced here, in code, against the same inventory the model was shown.
public struct BrainProposalValidator: Sendable {
    private static let maximumNameLength = 80

    /// A single clear English justification sentence is comfortably under
    /// 100 characters -- every example in this file's own tests ("You use it
    /// for music.", "Already running.", "Nothing installed can book
    /// flights.") is under 40. 200 leaves generous headroom for a compound
    /// sentence while remaining obviously incompatible with a
    /// multi-kilobyte payload built to push the actual requested action
    /// below the fold of a consent dialog.
    private static let maximumReasonLength = 200

    /// `call.toolName` is untrusted and, on the unknown-tool path, is echoed
    /// straight into a thrown error that may eventually reach diagnostics or
    /// UI. This bounds how much of it survives that trip.
    private static let maximumEchoedToolNameLength = 80

    public init() {}

    /// Shared display boundary for installed names shown outside a validated
    /// action proposal, such as confidence-gate alternatives.
    public static func isSafeApplicationDisplayName(_ name: String) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed == name else { return false }
        do {
            try validateNameShape(name)
            return true
        } catch {
            return false
        }
    }

    /// Validates a complete model response before any proposal can leave this
    /// pure boundary. `map` may build a local prefix while checking, but a
    /// thrown error prevents the array from being returned, so callers can
    /// never publish a partially valid chain.
    public func validate(
        _ calls: [RawBrainToolCall],
        installedApplicationNames: Set<String>
    ) throws -> [BrainProposal] {
        guard !calls.isEmpty else {
            throw BrainProposalError.noToolCalls
        }
        guard calls.count <= TaskSequence.maximumSteps else {
            throw BrainProposalError.tooManyToolCalls
        }
        return try calls.map {
            try validate(
                $0,
                installedApplicationNames: installedApplicationNames
            )
        }
    }

    public func validate(
        _ call: RawBrainToolCall,
        installedApplicationNames: Set<String>
    ) throws -> BrainProposal {
        guard let tool = BrainTool(rawValue: call.toolName) else {
            throw BrainProposalError.unknownTool(
                Self.sanitizedToolNameForError(call.toolName)
            )
        }

        let arguments = try Self.decodeArguments(call.argumentsJSON)

        switch tool {
        case .noSupportedAction:
            let reason = try Self.requiredValue(named: "reason", from: arguments)
            try Self.validateReasonShape(reason)
            return .noSupportedAction(reason: reason)
        case .openApplication, .switchToApplication:
            // Validate and resolve `name` before ever looking at `reason`, so
            // an unsafe name is reported as such even when `reason` is also
            // missing or invalid -- an unsafe-name error must never be
            // masked by a missing-reason error.
            let name = try Self.requiredValue(named: "name", from: arguments)
            try Self.validateNameShape(name)
            let reason = try Self.requiredValue(named: "reason", from: arguments)
            try Self.validateReasonShape(reason)
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
        // Mirrors ApplicationCommandParser's guard against the deictic phrase
        // "this app" (ApplicationCommand.swift): it refers to whatever
        // happens to be focused, not a literal application identity, so it is
        // refused unconditionally -- even if some installed application
        // happens to be named exactly that.
        guard name.lowercased() != "this app" else {
            throw BrainProposalError.unsafeApplicationName
        }
        guard !containsControlOrFormatCharacter(name) else {
            throw BrainProposalError.unsafeApplicationName
        }
    }

    /// `reason` is the one piece of untrusted model text that reaches a human
    /// at the moment they decide whether to authorize an action, so it gets
    /// the same control/format-character guard as `name`, plus the length
    /// cap documented on `maximumReasonLength`. Reject rather than truncate:
    /// a silently truncated justification could still read as sensible while
    /// hiding what was cut.
    private static func validateReasonShape(_ reason: String) throws {
        guard reason.count <= maximumReasonLength else {
            throw BrainProposalError.unsafeReason
        }
        guard !containsControlOrFormatCharacter(reason) else {
            throw BrainProposalError.unsafeReason
        }
    }

    /// `CharacterSet.controlCharacters` spans Unicode General Categories Cc
    /// (control -- e.g. NUL, LF, CR) *and* Cf (format -- e.g. U+200B ZERO
    /// WIDTH SPACE, U+200C ZERO WIDTH NON-JOINER, U+202E RIGHT-TO-LEFT
    /// OVERRIDE, U+FEFF BOM, U+00AD SOFT HYPHEN). Keeping both categories
    /// blocked here is deliberate, not incidental: Cf characters are
    /// invisible or bidi-reordering rather than "control" in the colloquial
    /// sense, but they are exactly what would let a name or a consent-dialog
    /// reason *display* as something other than what it actually is. Do NOT
    /// replace this with a numeric range check such as `scalar.value <
    /// 0x20` -- that covers only Cc and would silently drop all Cf
    /// (zero-width / bidi-override) protection while every existing test
    /// still passes.
    private static func containsControlOrFormatCharacter(_ value: String) -> Bool {
        value.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
    }

    /// Bounds and strips `toolName` before it is allowed into a thrown error,
    /// mirroring the same "untrusted text must not reach a display surface
    /// unsanitized" concern as `reason` above.
    private static func sanitizedToolNameForError(_ toolName: String) -> String {
        let stripped = String(
            toolName.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }
        )
        return String(stripped.prefix(maximumEchoedToolNameLength))
    }

    /// Returns the inventory's own spelling so downstream resolution uses the
    /// canonical name rather than the model's rendering of it.
    private static func installedMatch(
        for name: String,
        in installed: Set<String>
    ) -> String? {
        let target = normalize(name)
        return installed.first { normalize($0) == target }
    }

    private static func normalize(_ value: String) -> String {
        // Lowercase before precomposing, not after: `lowercased()` can itself
        // emit a decomposed sequence (e.g. "İ".lowercased() ==
        // "i" + U+0307 COMBINING DOT ABOVE), and composing first would leave
        // that decomposition unrecomposed.
        value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .precomposedStringWithCanonicalMapping
    }
}

/// Display-safety bound for offline chat text.
///
/// Chat answers never become an action, but they are shown on the same surface
/// the user reads while deciding whether to authorize one. The model client is
/// untrusted by design, so this bound lives here in the pure layer and is
/// applied at the publication point as well as in the transport — the same
/// arrangement that keeps `BrainProposalValidator`, not `MLXBrainClient`, the
/// authority over proposals.
public enum BrainChatAnswer: Sendable {
    /// Generous next to `maximumReasonLength` (200), because a chat answer is
    /// the whole response rather than a one-line justification, but still
    /// bounded so it cannot flood the surface.
    public static let maximumScalarCount = 2_000

    /// Returns the trimmed answer, or `nil` when it is empty, over-long, or
    /// carries unsafe control, format, or line/paragraph separators. Newlines
    /// and tabs are allowed, with newline runs capped to one blank line.
    public static func sanitized(_ answer: String) -> String? {
        let trimmed = answer.trimmingCharacters(in: .whitespacesAndNewlines)
        let scalars = trimmed.unicodeScalars
        guard (1...maximumScalarCount).contains(scalars.count) else {
            return nil
        }
        let hasUnsafeScalar = scalars.contains { scalar in
            switch scalar.properties.generalCategory {
            // Cc/Cf cover control and format characters, including zero-width
            // and bidi overrides. U+000A and U+0009 are the only display-safe
            // controls accepted here. Zl/Zp remain unsafe line breaks.
            case .control:
                scalar.value != 0x000A && scalar.value != 0x0009
            case .format, .lineSeparator, .paragraphSeparator:
                true
            default:
                false
            }
        }
        guard !hasUnsafeScalar else { return nil }

        var sanitized = ""
        var consecutiveNewlines = 0
        for scalar in scalars {
            if scalar.value == 0x000A {
                consecutiveNewlines += 1
                guard consecutiveNewlines <= 2 else { continue }
            } else {
                consecutiveNewlines = 0
            }
            sanitized.unicodeScalars.append(scalar)
        }
        return sanitized
    }
}
