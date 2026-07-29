import Foundation

/// Closed action vocabulary. Adding capability requires an explicit code change.
public enum AvatarAction: Equatable, Sendable {
    case copyCurrentTime

    public var title: String {
        switch self {
        case .copyCurrentTime:
            "Copy current time"
        }
    }

    public var preview: String {
        switch self {
        case .copyCurrentTime:
            "Write the current local time to the clipboard."
        }
    }
}

public enum CommandInterpretation: Equatable, Sendable {
    case action(AvatarAction)
    case help
    case rejected(String)
}

public struct CommandInterpreter: Sendable {
    public init() {}

    public func interpret(_ input: String) -> CommandInterpretation {
        let normalized = input
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()

        switch normalized {
        case "", "help", "?":
            return .help
        case "time", "copy time", "copy current time":
            return .action(.copyCurrentTime)
        default:
            return .rejected(
                "Unknown command. Available command: copy time"
            )
        }
    }
}
