import Foundation

public enum ModifierKey: String, Equatable, Hashable, Sendable {
    case command
    case option
    case control
    case shift

    public var symbol: String {
        switch self {
        case .command: "⌘"
        case .option: "⌥"
        case .control: "⌃"
        case .shift: "⇧"
        }
    }
}

/// Typed description only. It contains no event-generation implementation.
public enum VisibleInteraction: Equatable, Sendable {
    case launchOrActivateApplication
    case activateTargetApplication
    case keyboardShortcut(key: String, modifiers: Set<ModifierKey>)
    case accessibilityPress(role: String, label: String)

    public var previewDescription: String {
        switch self {
        case .launchOrActivateApplication:
            return "Launch the exact application if needed, then bring it to the foreground."
        case .activateTargetApplication:
            return "Bring the exact target application to the foreground."
        case let .keyboardShortcut(key, modifiers):
            let prefix =
                modifiers
                .sorted { $0.rawValue < $1.rawValue }
                .map(\.symbol)
                .joined()
            return "Press \(prefix)\(key.uppercased()) once."
        case let .accessibilityPress(role, label):
            return "Press accessibility element “\(label)” with role \(role)."
        }
    }
}

public struct PlannedStep: Equatable, Sendable, Identifiable {
    public let id: UUID
    public let capabilityID: String
    public let targetBundleIdentifier: String
    public let effectPreview: String
    public let redactedParameterSummary: String
    public let visibleInteraction: VisibleInteraction?

    public init(
        id: UUID = UUID(),
        capabilityID: String,
        targetBundleIdentifier: String,
        effectPreview: String,
        redactedParameterSummary: String,
        visibleInteraction: VisibleInteraction? = nil
    ) {
        self.id = id
        self.capabilityID = capabilityID
        self.targetBundleIdentifier = targetBundleIdentifier
        self.effectPreview = effectPreview
        self.redactedParameterSummary = redactedParameterSummary
        self.visibleInteraction = visibleInteraction
    }
}

public struct ActionPlan: Equatable, Sendable, Identifiable {
    public let id: UUID
    public let app: AppIdentity
    public let steps: [PlannedStep]
    public let createdAt: Date

    public init(
        id: UUID = UUID(),
        app: AppIdentity,
        steps: [PlannedStep],
        createdAt: Date
    ) {
        self.id = id
        self.app = app
        self.steps = steps
        self.createdAt = createdAt
    }
}

public struct ConsentGrant: Equatable, Sendable, Identifiable {
    public let id: UUID
    public let planID: UUID
    public let scopes: Set<PermissionScope>
    public let approvedAt: Date
    public let expiresAt: Date
    public let oneShot: Bool

    public init(
        id: UUID = UUID(),
        planID: UUID,
        scopes: Set<PermissionScope>,
        approvedAt: Date,
        expiresAt: Date,
        oneShot: Bool = true
    ) {
        self.id = id
        self.planID = planID
        self.scopes = scopes
        self.approvedAt = approvedAt
        self.expiresAt = expiresAt
        self.oneShot = oneShot
    }
}

public enum PlanValidationError: Error, Equatable {
    case observeOnly
    case emergencyStopped
    case emptyPlan
    case wrongAppTarget
    case unknownCapability(String)
    case consentForDifferentPlan
    case consentExpired
    case missingPermissions
    case excessPermissions
    case confirmationRequired
}

public struct ValidatedPlan: Equatable, Sendable {
    public let plan: ActionPlan
    public let consent: ConsentGrant
    public let maximumRisk: ActionRisk
}

public struct PreviewValidatedPlan: Equatable, Sendable {
    public let plan: ActionPlan
    public let consent: ConsentGrant
    public let maximumRisk: ActionRisk
}

public struct PlanValidator: Sendable {
    public init() {}

    public func validate(
        plan: ActionPlan,
        profile: CapabilityProfile,
        consent: ConsentGrant,
        safety: SafetyState,
        userConfirmedPreview: Bool,
        now: Date
    ) throws -> ValidatedPlan {
        if safety.emergencyStopped {
            throw PlanValidationError.emergencyStopped
        }
        if safety.observeOnly {
            throw PlanValidationError.observeOnly
        }
        let preview = try validateForPreview(
            plan: plan,
            profile: profile,
            consent: consent,
            userConfirmedPreview: userConfirmedPreview,
            now: now
        )

        return ValidatedPlan(
            plan: preview.plan,
            consent: preview.consent,
            maximumRisk: preview.maximumRisk
        )
    }

    /// Validates structure and consent without creating executable authority.
    public func validateForPreview(
        plan: ActionPlan,
        profile: CapabilityProfile,
        consent: ConsentGrant,
        userConfirmedPreview: Bool,
        now: Date
    ) throws -> PreviewValidatedPlan {
        try ProfileValidator().validate(profile)
        guard !plan.steps.isEmpty else {
            throw PlanValidationError.emptyPlan
        }
        guard profile.app == plan.app,
            plan.steps.allSatisfy({
                $0.targetBundleIdentifier == plan.app.bundleIdentifier
            })
        else {
            throw PlanValidationError.wrongAppTarget
        }
        guard consent.planID == plan.id else {
            throw PlanValidationError.consentForDifferentPlan
        }
        guard now < consent.expiresAt else {
            throw PlanValidationError.consentExpired
        }

        let capabilities = Dictionary(
            uniqueKeysWithValues: profile.capabilities.map { ($0.id, $0) }
        )
        var requiredPermissions = Set<PermissionScope>()
        var maximumRisk = ActionRisk.readOnly

        for step in plan.steps {
            guard let capability = capabilities[step.capabilityID] else {
                throw PlanValidationError.unknownCapability(step.capabilityID)
            }
            requiredPermissions.formUnion(capability.requiredPermissions)
            maximumRisk = max(maximumRisk, capability.risk)
        }

        guard requiredPermissions.isSubset(of: consent.scopes) else {
            throw PlanValidationError.missingPermissions
        }
        guard consent.scopes.isSubset(of: requiredPermissions) else {
            throw PlanValidationError.excessPermissions
        }
        if maximumRisk >= .meaningful, !userConfirmedPreview {
            throw PlanValidationError.confirmationRequired
        }

        return PreviewValidatedPlan(
            plan: plan,
            consent: consent,
            maximumRisk: maximumRisk
        )
    }
}
