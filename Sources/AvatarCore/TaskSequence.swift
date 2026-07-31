import Foundation

/// One executable unit inside a sequence. Each carries its own plan and profile
/// so the existing single-app validator still governs it unchanged.
public struct SequencedPlan: Equatable, Sendable, Identifiable {
    public let id: UUID
    public let summary: String
    public let plan: ActionPlan
    public let profile: CapabilityProfile

    public init(
        id: UUID = UUID(),
        summary: String,
        plan: ActionPlan,
        profile: CapabilityProfile
    ) {
        self.id = id
        self.summary = summary
        self.plan = plan
        self.profile = profile
    }
}

/// An ordered chain of single-app plans authorized by one explicit confirmation.
/// The chain is the consent unit; each link still gets its own scoped grant,
/// contract, and preflight when it runs.
public struct TaskSequence: Equatable, Sendable, Identifiable {
    public static let maximumSteps = 5

    public let id: UUID
    public let steps: [SequencedPlan]
    public let createdAt: Date
    public let expiresAt: Date

    public init(
        id: UUID = UUID(),
        steps: [SequencedPlan],
        createdAt: Date,
        expiresAt: Date
    ) {
        self.id = id
        self.steps = steps
        self.createdAt = createdAt
        self.expiresAt = expiresAt
    }
}

public enum TaskSequenceValidationError: Error, Equatable {
    case emptySequence
    case tooManySteps
    case sequenceExpired
    case observeOnly
    case emergencyStopped
    case confirmationRequired
    case stepRejected(index: Int)
}

public struct ValidatedTaskSequence: Equatable, Sendable {
    public let sequence: TaskSequence
    public let maximumRisk: ActionRisk
}

/// Validates the whole chain up front so the user confirms against the exact
/// set of steps that will run. Each step is checked with the same
/// `PlanValidator` rules used for a lone plan.
public struct TaskSequenceValidator: Sendable {
    public init() {}

    public func validate(
        sequence: TaskSequence,
        safety: SafetyState,
        userConfirmed: Bool,
        now: Date
    ) throws -> ValidatedTaskSequence {
        if safety.emergencyStopped {
            throw TaskSequenceValidationError.emergencyStopped
        }
        if safety.observeOnly {
            throw TaskSequenceValidationError.observeOnly
        }
        guard !sequence.steps.isEmpty else {
            throw TaskSequenceValidationError.emptySequence
        }
        guard sequence.steps.count <= TaskSequence.maximumSteps else {
            throw TaskSequenceValidationError.tooManySteps
        }
        guard now < sequence.expiresAt else {
            throw TaskSequenceValidationError.sequenceExpired
        }
        guard userConfirmed else {
            throw TaskSequenceValidationError.confirmationRequired
        }

        let validator = PlanValidator()
        var maximumRisk = ActionRisk.readOnly

        for (index, step) in sequence.steps.enumerated() {
            let probeConsent = ConsentGrant(
                planID: step.plan.id,
                scopes: requiredScopes(for: step),
                approvedAt: now,
                expiresAt: sequence.expiresAt,
                oneShot: true
            )
            do {
                let preview = try validator.validateForPreview(
                    plan: step.plan,
                    profile: step.profile,
                    consent: probeConsent,
                    userConfirmedPreview: true,
                    now: now
                )
                maximumRisk = max(maximumRisk, preview.maximumRisk)
            } catch {
                throw TaskSequenceValidationError.stepRejected(index: index)
            }
        }

        return ValidatedTaskSequence(
            sequence: sequence,
            maximumRisk: maximumRisk
        )
    }

    /// Least privilege per step: exactly the scopes that step's capabilities
    /// declare, never the union across the whole sequence.
    public func requiredScopes(for step: SequencedPlan) -> Set<PermissionScope> {
        let capabilities = Dictionary(
            step.profile.capabilities.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        var scopes = Set<PermissionScope>()
        for planStep in step.plan.steps {
            if let capability = capabilities[planStep.capabilityID] {
                scopes.formUnion(capability.requiredPermissions)
            }
        }
        return scopes
    }
}

public struct TaskSequenceStepOutcome: Equatable, Sendable {
    public let index: Int
    public let planID: UUID
    public let summary: String
    public let outcome: ExecutionOutcome

    public init(
        index: Int,
        planID: UUID,
        summary: String,
        outcome: ExecutionOutcome
    ) {
        self.index = index
        self.planID = planID
        self.summary = summary
        self.outcome = outcome
    }
}

public enum TaskSequenceResult: Equatable, Sendable {
    case completed([TaskSequenceStepOutcome])
    /// Stopped before finishing. `outcomes` holds every step already attempted,
    /// the last of which is the one that stopped the chain.
    case halted(atIndex: Int, outcomes: [TaskSequenceStepOutcome])

    public var outcomes: [TaskSequenceStepOutcome] {
        switch self {
        case let .completed(outcomes): outcomes
        case let .halted(_, outcomes): outcomes
        }
    }
}

/// Runs a validated chain in order. Each step mints its own scoped, one-shot,
/// expiring consent and contract, so a link that never runs never had authority.
/// The first non-success stops the chain.
public struct TaskSequenceRunner: Sendable {
    private let stepDuration: TimeInterval

    public init(stepDuration: TimeInterval = 30) {
        self.stepDuration = stepDuration
    }

    public func run(
        _ validated: ValidatedTaskSequence,
        adapter: any CapabilityAdapter,
        isEmergencyStopped: @Sendable () async -> Bool,
        now: @Sendable () -> Date,
        onStepOutcome: (@Sendable (TaskSequenceStepOutcome) async -> Void)? = nil
    ) async -> TaskSequenceResult {
        let validator = TaskSequenceValidator()
        var outcomes: [TaskSequenceStepOutcome] = []

        for (index, step) in validated.sequence.steps.enumerated() {
            let startedAt = now()

            func record(_ outcome: ExecutionOutcome) async
                -> TaskSequenceStepOutcome
            {
                let recorded = TaskSequenceStepOutcome(
                    index: index,
                    planID: step.plan.id,
                    summary: step.summary,
                    outcome: outcome
                )
                outcomes.append(recorded)
                await onStepOutcome?(recorded)
                return recorded
            }

            if await isEmergencyStopped() {
                _ = await record(.denied("Emergency stop is active."))
                return .halted(atIndex: index, outcomes: outcomes)
            }
            guard startedAt < validated.sequence.expiresAt else {
                _ = await record(.denied("These steps expired before running."))
                return .halted(atIndex: index, outcomes: outcomes)
            }

            let consent = ConsentGrant(
                planID: step.plan.id,
                scopes: validator.requiredScopes(for: step),
                approvedAt: startedAt,
                expiresAt: min(
                    startedAt.addingTimeInterval(stepDuration),
                    validated.sequence.expiresAt
                ),
                oneShot: true
            )
            let validatedPlan = ValidatedPlan(
                plan: step.plan,
                consent: consent,
                maximumRisk: validated.maximumRisk
            )
            let contract = ExecutionContract(
                validatedPlan: validatedPlan,
                issuedAt: startedAt,
                expiresAt: consent.expiresAt
            )

            let outcome = await adapter.execute(contract)
            _ = await record(outcome)

            guard outcome == .succeeded else {
                return .halted(atIndex: index, outcomes: outcomes)
            }
        }

        return .completed(outcomes)
    }
}
