import Foundation

public enum DeferredApplicationGoal: Equatable, Sendable {
    case continuePlayback(title: String)
    case unsupported(request: String)

    public var displayTitle: String {
        switch self {
        case let .continuePlayback(title):
            "Continue playing \(title)"
        case let .unsupported(request):
            request.prefix(1).uppercased() + request.dropFirst()
        }
    }
}

public struct ParsedApplicationSequence: Equatable, Sendable {
    public let firstCommand: ParsedApplicationCommand
    public let deferredGoal: DeferredApplicationGoal

    public init(
        firstCommand: ParsedApplicationCommand,
        deferredGoal: DeferredApplicationGoal
    ) {
        self.firstCommand = firstCommand
        self.deferredGoal = deferredGoal
    }
}

public enum ApplicationSequenceParsing: Equatable, Sendable {
    case sequence(ParsedApplicationSequence)
    case notSequence
    case rejected(reason: String)
}

/// Splits one supported app lifecycle command from one non-executable goal.
public struct ApplicationSequenceParser: Sendable {
    private let applicationParser = ApplicationCommandParser()

    public init() {}

    public func parse(_ input: String) -> ApplicationSequenceParsing {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard
            let separator = trimmed.range(
                of: " and ",
                options: .caseInsensitive
            )
        else {
            return .notSequence
        }

        let firstText = String(trimmed[..<separator.lowerBound])
        let goalText = String(trimmed[separator.upperBound...])
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let firstCommand: ParsedApplicationCommand
        switch applicationParser.parse(firstText) {
        case let .command(command):
            firstCommand = command
        case let .rejected(reason):
            return .rejected(reason: reason)
        case .notApplicationCommand:
            return .notSequence
        }

        guard !goalText.isEmpty else {
            return .rejected(
                reason: "Describe one later app goal after “and”."
            )
        }
        guard goalText.count <= 160 else {
            return .rejected(reason: "Later app goal is too long.")
        }
        guard
            goalText.unicodeScalars.allSatisfy({
                !CharacterSet.controlCharacters.contains($0)
            })
        else {
            return .rejected(
                reason: "Later app goal contains control characters."
            )
        }

        guard let goal = parseDeferredGoal(goalText) else {
            return .rejected(
                reason:
                    "Follow-up must describe an app goal, not another application name."
            )
        }
        return .sequence(
            ParsedApplicationSequence(
                firstCommand: firstCommand,
                deferredGoal: goal
            )
        )
    }

    private func parseDeferredGoal(
        _ input: String
    ) -> DeferredApplicationGoal? {
        let lowered = input.lowercased()
        let playbackPrefixes = [
            "continue playing ",
            "continue watching ",
            "resume playing ",
            "resume watching ",
        ]
        if let prefix = playbackPrefixes.first(where: {
            lowered.hasPrefix($0)
        }) {
            let title = String(input.dropFirst(prefix.count))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty else {
                return .unsupported(request: input)
            }
            return .continuePlayback(title: title)
        }

        let firstToken = lowered.split(whereSeparator: \.isWhitespace).first
        let deferredVerbs: Set<Substring> = [
            "click",
            "close",
            "continue",
            "enter",
            "find",
            "pause",
            "play",
            "quit",
            "resume",
            "search",
            "select",
            "type",
        ]
        guard let firstToken, deferredVerbs.contains(firstToken) else {
            return nil
        }
        return .unsupported(request: input)
    }
}

public enum ApplicationSequenceStepAvailability: Equatable, Sendable {
    case confirmableNow
    case deferredUnsupported
}

public struct ApplicationSequenceStep: Equatable, Sendable, Identifiable {
    public let id: Int
    public let title: String
    public let effectPreview: String
    public let availability: ApplicationSequenceStepAvailability

    public init(
        id: Int,
        title: String,
        effectPreview: String,
        availability: ApplicationSequenceStepAvailability
    ) {
        self.id = id
        self.title = title
        self.effectPreview = effectPreview
        self.availability = availability
    }
}

public struct ApplicationSequenceProposal: Equatable, Sendable {
    public let applicationProposal: ApplicationActionProposal
    public let deferredGoal: DeferredApplicationGoal
    public let orderedSteps: [ApplicationSequenceStep]

    public init(
        applicationProposal: ApplicationActionProposal,
        deferredGoal: DeferredApplicationGoal,
        orderedSteps: [ApplicationSequenceStep]
    ) {
        self.applicationProposal = applicationProposal
        self.deferredGoal = deferredGoal
        self.orderedSteps = orderedSteps
    }
}

public struct ApplicationSequencePlanner: Sendable {
    public init() {}

    public func propose(
        sequence: ParsedApplicationSequence,
        application: ResolvedApplication,
        now: Date
    ) throws -> ApplicationSequenceProposal {
        let applicationProposal = try ApplicationActionPlanner().propose(
            command: sequence.firstCommand,
            application: application,
            now: now
        )
        let firstEffect =
            applicationProposal.plan.steps.first?.effectPreview
            ?? "The exact application will open or move to foreground."

        return ApplicationSequenceProposal(
            applicationProposal: applicationProposal,
            deferredGoal: sequence.deferredGoal,
            orderedSteps: [
                ApplicationSequenceStep(
                    id: 1,
                    title:
                        sequence.firstCommand.operation == .switchToRunning
                        ? "Switch to \(application.identity.displayName)"
                        : "Open \(application.identity.displayName)",
                    effectPreview: firstEffect,
                    availability: .confirmableNow
                ),
                ApplicationSequenceStep(
                    id: 2,
                    title: sequence.deferredGoal.displayTitle,
                    effectPreview:
                        "Not executable. Requires future visible foreground app interaction, exact UI-state verification, and a new user confirmation. Nothing is queued.",
                    availability: .deferredUnsupported
                ),
            ]
        )
    }
}
