import Foundation

/// One installed application plus how much this user actually uses it.
///
/// Usage comes from macOS itself (Spotlight metadata), so OSPA never has to
/// observe the user in the background to learn their preferences.
public struct InstalledApplicationUsage: Equatable, Sendable {
    public let displayName: String
    public let openCount: Int
    /// Whole days since last launch. `nil` means never opened.
    public let lastUsedDaysAgo: Int?

    public init(displayName: String, openCount: Int, lastUsedDaysAgo: Int?) {
        self.displayName = displayName
        self.openCount = openCount
        self.lastUsedDaysAgo = lastUsedDaysAgo
    }
}

/// Builds the model's system prompt.
///
/// Output must be byte-stable for a given inventory: MLX reuses a cached prompt
/// prefix only when the prefix matches exactly, which is what makes sending the
/// whole inventory on every request affordable. So ordering is deterministic and
/// recency is quantized to whole days. Never put a clock value in here.
public struct BrainPromptBuilder: Sendable {
    /// Bound on prompt size. The most-used apps are kept.
    public static let maximumInventoryEntries = 200

    public init() {}

    public func systemPrompt(for inventory: [InstalledApplicationUsage]) -> String {
        let ordered =
            inventory
            .sorted {
                if $0.openCount != $1.openCount {
                    return $0.openCount > $1.openCount
                }
                if $0.displayName != $1.displayName {
                    return $0.displayName < $1.displayName
                }
                // Both have same openCount and displayName; order by recency.
                // Lower day numbers (more recent) come first.
                // nil (never opened) comes last.
                let days0 = $0.lastUsedDaysAgo ?? Int.max
                let days1 = $1.lastUsedDaysAgo ?? Int.max
                return days0 < days1
            }
            .prefix(Self.maximumInventoryEntries)

        let lines = ordered.map(Self.line(for:)).joined(separator: "\n")

        return """
            You help someone use their Mac. They speak normally, not in commands.
            Choose exactly one tool call for what they asked.

            These are the applications installed on this Mac, most-used first, \
            with how often this person actually opens each one:
            \(lines)

            Choose the application this person actually uses for the task, not \
            merely the one whose name matches the topic. If they ask for music \
            and they never open one music app but use another constantly, choose \
            the one they use.

            If nothing installed can do what they asked, call no_supported_action \
            and say why in one plain sentence.
            """
    }

    private static func line(for app: InstalledApplicationUsage) -> String {
        guard let days = app.lastUsedDaysAgo else {
            return "\(app.displayName) (never opened)"
        }
        let recency: String =
            switch days {
            case 0: "today"
            case 1: "1 day ago"
            default: "\(days) days ago"
            }
        return "\(app.displayName) (opened \(app.openCount) times, last used \(recency))"
    }
}
