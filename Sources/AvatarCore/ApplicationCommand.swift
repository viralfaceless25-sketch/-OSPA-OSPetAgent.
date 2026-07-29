import Foundation

public enum ApplicationOperation: String, Equatable, Sendable {
    case launchOrActivate
    case switchToRunning
}

public struct ParsedApplicationCommand: Equatable, Sendable {
    public let operation: ApplicationOperation
    public let requestedApplicationName: String

    public init(
        operation: ApplicationOperation,
        requestedApplicationName: String
    ) {
        self.operation = operation
        self.requestedApplicationName = requestedApplicationName
    }
}

public enum ApplicationCommandParsing: Equatable, Sendable {
    case command(ParsedApplicationCommand)
    case notApplicationCommand
    case rejected(reason: String)
}

/// Closed local parser for explicit application names.
public struct ApplicationCommandParser: Sendable {
    public init() {}

    public func parse(_ input: String) -> ApplicationCommandParsing {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let lowered = trimmed.lowercased()
        let prefixes: [(String, ApplicationOperation)] = [
            ("switch to ", .switchToRunning),
            ("activate ", .switchToRunning),
            ("launch ", .launchOrActivate),
            ("focus ", .switchToRunning),
            ("start ", .launchOrActivate),
            ("open ", .launchOrActivate),
        ]

        guard let match = prefixes.first(where: { lowered.hasPrefix($0.0) }) else {
            return .notApplicationCommand
        }

        let name = String(trimmed.dropFirst(match.0.count))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if name.lowercased() == "this app" {
            return .notApplicationCommand
        }
        guard !name.isEmpty else {
            return .rejected(reason: "Enter one exact installed application name.")
        }
        guard name.count <= 80 else {
            return .rejected(reason: "Application name is too long.")
        }
        guard !name.lowercased().hasSuffix(".app") else {
            return .rejected(
                reason: "Use the application’s display name without an .app suffix."
            )
        }
        guard !name.contains("/"), !name.contains("\\"), !name.contains("~") else {
            return .rejected(
                reason: "Paths are not allowed. Enter an installed application name."
            )
        }
        guard !name.lowercased().contains(" and ") else {
            return .rejected(
                reason: "Only one application action can be confirmed at a time."
            )
        }
        guard
            name.unicodeScalars.allSatisfy({ scalar in
                !CharacterSet.controlCharacters.contains(scalar)
            })
        else {
            return .rejected(reason: "Application name contains control characters.")
        }

        return .command(
            ParsedApplicationCommand(
                operation: match.1,
                requestedApplicationName: name
            )
        )
    }
}

public struct ResolvedApplication: Equatable, Sendable {
    public let identity: AppIdentity
    public let applicationURL: URL
    public let isRunning: Bool

    public init(
        identity: AppIdentity,
        applicationURL: URL,
        isRunning: Bool
    ) {
        self.identity = identity
        self.applicationURL = applicationURL
        self.isRunning = isRunning
    }
}

public struct ApplicationActionProposal: Equatable, Sendable {
    public let command: ParsedApplicationCommand
    public let application: ResolvedApplication
    public let profile: CapabilityProfile
    public let plan: ActionPlan

    public init(
        command: ParsedApplicationCommand,
        application: ResolvedApplication,
        profile: CapabilityProfile,
        plan: ActionPlan
    ) {
        self.command = command
        self.application = application
        self.profile = profile
        self.plan = plan
    }
}

public enum ApplicationProposalError: Error, Equatable {
    case switchTargetNotRunning
}

public struct ApplicationActionPlanner: Sendable {
    public init() {}

    public func propose(
        command: ParsedApplicationCommand,
        application: ResolvedApplication,
        now: Date
    ) throws -> ApplicationActionProposal {
        if command.operation == .switchToRunning, !application.isRunning {
            throw ApplicationProposalError.switchTargetNotRunning
        }

        let capabilityID: String
        let title: String
        let interaction: VisibleInteraction
        let effect: String

        switch command.operation {
        case .launchOrActivate:
            capabilityID = "native.application.launch-or-activate"
            title = "Open \(application.identity.displayName)"
            interaction = .launchOrActivateApplication
            effect =
                application.isRunning
                ? "\(application.identity.displayName) will move to the foreground."
                : "\(application.identity.displayName) will launch and move to the foreground."
        case .switchToRunning:
            capabilityID = "native.application.switch"
            title = "Switch to \(application.identity.displayName)"
            interaction = .activateTargetApplication
            effect = "\(application.identity.displayName) will move to the foreground."
        }

        let capability = CapabilityDefinition(
            id: capabilityID,
            name: title,
            effectSummary: effect,
            adapter: .nativeAPI,
            risk: .meaningful,
            requiredPermissions: [],
            evidence: .bundled
        )
        let profile = CapabilityProfile(
            app: application.identity,
            capabilities: [capability],
            reviewedClaimIDs: [],
            approvedAt: now
        )
        let plan = ActionPlan(
            app: application.identity,
            steps: [
                PlannedStep(
                    capabilityID: capability.id,
                    targetBundleIdentifier:
                        application.identity.bundleIdentifier,
                    effectPreview: effect,
                    redactedParameterSummary:
                        "Exact bundle identifier; no document or URL",
                    visibleInteraction: interaction
                )
            ],
            createdAt: now
        )

        return ApplicationActionProposal(
            command: command,
            application: application,
            profile: profile,
            plan: plan
        )
    }
}
