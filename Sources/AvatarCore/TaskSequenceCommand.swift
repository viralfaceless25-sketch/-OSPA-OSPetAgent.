import Foundation

public enum TaskSequenceParsing: Equatable, Sendable {
    /// Two or more clauses that are each independently executable.
    case sequence([ParsedApplicationCommand])
    /// Not a multi-clause request. Callers fall through to single-command and
    /// deferred-goal parsing, which still own their existing behavior.
    case notSequence
    case rejected(reason: String)
}

/// Splits one natural request into several executable app commands.
///
/// Deliberately conservative: every clause must parse as a supported command, or
/// the whole request is refused rather than partially run. A request where only
/// the first clause is executable is left to `ApplicationSequenceParser`, which
/// previews the remainder as an explicitly deferred, non-executable goal.
public struct TaskSequenceCommandParser: Sendable {
    private let commandParser = ApplicationCommandParser()

    public init() {}

    public func parse(_ input: String) -> TaskSequenceParsing {
        let clauses = Self.clauses(in: input)
        guard clauses.count > 1 else { return .notSequence }
        guard clauses.count <= TaskSequence.maximumSteps else {
            return .rejected(
                reason:
                    "That is more than \(TaskSequence.maximumSteps) requests at once. Split it up."
            )
        }

        var commands: [ParsedApplicationCommand] = []
        for (index, clause) in clauses.enumerated() {
            switch commandParser.parse(clause) {
            case let .command(command):
                commands.append(command)
            case .notApplicationCommand:
                // Any non-command clause means this is not a fully executable
                // chain. Fall through so existing parsing can handle it.
                return .notSequence
            case let .rejected(reason):
                return .rejected(
                    reason: "Request \(index + 1) of \(clauses.count): \(reason)"
                )
            }
        }
        return .sequence(commands)
    }

    /// Splits on the connectors people actually use, without treating a comma
    /// inside a single request as a separator when it yields empty clauses.
    public static func clauses(in input: String) -> [String] {
        var working = input
        for separator in [" and then ", " then ", " and ", ";", ","] {
            working = working.replacingOccurrences(
                of: separator,
                with: "\u{1}",
                options: [.caseInsensitive]
            )
        }
        return
            working
            .split(separator: "\u{1}")
            .map {
                $0.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            .filter { !$0.isEmpty }
    }
}
