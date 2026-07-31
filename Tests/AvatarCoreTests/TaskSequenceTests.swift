import AvatarCore
import Foundation
import Testing

@Suite("Task sequence")
struct TaskSequenceTests {
    private let now = Date(timeIntervalSince1970: 9_000)

    @Test("A confirmed multi-app chain runs every step in order")
    func runsEveryStepInOrder() async throws {
        let sequence = makeSequence(apps: ["com.example.one", "com.example.two"])
        let validated = try TaskSequenceValidator().validate(
            sequence: sequence,
            safety: SafetyState(observeOnly: false),
            userConfirmed: true,
            now: now
        )
        let adapter = RecordingAdapter()

        let result = await TaskSequenceRunner().run(
            validated,
            adapter: adapter,
            isEmergencyStopped: { false },
            now: { self.now }
        )

        #expect(result == .completed(result.outcomes))
        #expect(result.outcomes.map(\.index) == [0, 1])
        #expect(result.outcomes.allSatisfy { $0.outcome == .succeeded })
        #expect(
            await adapter.targets() == ["com.example.one", "com.example.two"]
        )
    }

    @Test("A failing step halts the chain and later steps never run")
    func failingStepHaltsChain() async throws {
        let sequence = makeSequence(
            apps: ["com.example.one", "com.example.two", "com.example.three"]
        )
        let validated = try TaskSequenceValidator().validate(
            sequence: sequence,
            safety: SafetyState(observeOnly: false),
            userConfirmed: true,
            now: now
        )
        let adapter = RecordingAdapter(
            failAtIndex: 1,
            failure: .failed("Couldn't find that button on screen.")
        )

        let result = await TaskSequenceRunner().run(
            validated,
            adapter: adapter,
            isEmergencyStopped: { false },
            now: { self.now }
        )

        #expect(result == .halted(atIndex: 1, outcomes: result.outcomes))
        #expect(result.outcomes.count == 2)
        #expect(
            result.outcomes.last?.outcome
                == .failed("Couldn't find that button on screen.")
        )
        // The third step never reached the adapter.
        #expect(await adapter.targets().count == 2)
    }

    @Test("Emergency stop mid-chain halts before the next step runs")
    func emergencyStopHaltsChain() async throws {
        let sequence = makeSequence(apps: ["com.example.one", "com.example.two"])
        let validated = try TaskSequenceValidator().validate(
            sequence: sequence,
            safety: SafetyState(observeOnly: false),
            userConfirmed: true,
            now: now
        )
        let adapter = RecordingAdapter()
        let stop = StopFlag()

        let result = await TaskSequenceRunner().run(
            validated,
            adapter: adapter,
            isEmergencyStopped: { await stop.value },
            now: { self.now },
            onStepOutcome: { _ in await stop.trip() }
        )

        #expect(result == .halted(atIndex: 1, outcomes: result.outcomes))
        #expect(
            result.outcomes.last?.outcome == .denied("Emergency stop is active.")
        )
        #expect(await adapter.targets() == ["com.example.one"])
    }

    @Test("Each step receives its own scoped one-shot consent")
    func mintsPerStepConsent() async throws {
        let sequence = makeSequence(apps: ["com.example.one", "com.example.two"])
        let validated = try TaskSequenceValidator().validate(
            sequence: sequence,
            safety: SafetyState(observeOnly: false),
            userConfirmed: true,
            now: now
        )
        let adapter = RecordingAdapter()

        _ = await TaskSequenceRunner().run(
            validated,
            adapter: adapter,
            isEmergencyStopped: { false },
            now: { self.now }
        )

        let consents = await adapter.consents()
        #expect(consents.count == 2)
        #expect(consents.allSatisfy { $0.oneShot })
        // Distinct grants, each bound to its own plan.
        #expect(Set(consents.map(\.id)).count == 2)
        #expect(
            zip(consents, validated.sequence.steps)
                .allSatisfy { $0.planID == $1.plan.id }
        )
        // Least privilege: a step's grant names only its own app.
        #expect(
            consents[0].scopes
                == [.accessibility(targetBundleIdentifier: "com.example.one")]
        )
        #expect(
            consents[1].scopes
                == [.accessibility(targetBundleIdentifier: "com.example.two")]
        )
    }

    @Test("Observe-only, emergency stop, and missing confirmation are refused")
    func refusesUnsafeSequences() {
        let sequence = makeSequence(apps: ["com.example.one"])
        let validator = TaskSequenceValidator()

        #expect(throws: TaskSequenceValidationError.observeOnly) {
            try validator.validate(
                sequence: sequence,
                safety: SafetyState(observeOnly: true),
                userConfirmed: true,
                now: now
            )
        }
        #expect(throws: TaskSequenceValidationError.emergencyStopped) {
            try validator.validate(
                sequence: sequence,
                safety: SafetyState(observeOnly: false, emergencyStopped: true),
                userConfirmed: true,
                now: now
            )
        }
        #expect(throws: TaskSequenceValidationError.confirmationRequired) {
            try validator.validate(
                sequence: sequence,
                safety: SafetyState(observeOnly: false),
                userConfirmed: false,
                now: now
            )
        }
    }

    @Test("Empty, oversized, and expired sequences are refused")
    func refusesMalformedSequences() {
        let validator = TaskSequenceValidator()
        let safety = SafetyState(observeOnly: false)

        #expect(throws: TaskSequenceValidationError.emptySequence) {
            try validator.validate(
                sequence: makeSequence(apps: []),
                safety: safety,
                userConfirmed: true,
                now: now
            )
        }
        #expect(throws: TaskSequenceValidationError.tooManySteps) {
            try validator.validate(
                sequence: makeSequence(
                    apps: (0...TaskSequence.maximumSteps).map {
                        "com.example.app\($0)"
                    }
                ),
                safety: safety,
                userConfirmed: true,
                now: now
            )
        }
        #expect(throws: TaskSequenceValidationError.sequenceExpired) {
            try validator.validate(
                sequence: makeSequence(
                    apps: ["com.example.one"],
                    expiry: now.addingTimeInterval(-1)
                ),
                safety: safety,
                userConfirmed: true,
                now: now
            )
        }
    }

    // MARK: - Fixture

    private func makeSequence(
        apps: [String],
        expiry: Date? = nil
    ) -> TaskSequence {
        let steps = apps.map { bundleIdentifier -> SequencedPlan in
            let app = AppIdentity(
                bundleIdentifier: bundleIdentifier,
                displayName: bundleIdentifier
            )
            let permission = PermissionScope.accessibility(
                targetBundleIdentifier: bundleIdentifier
            )
            let capability = CapabilityDefinition(
                id: "computer_use",
                name: "Visible foreground action",
                effectSummary: "Performs a visible foreground action.",
                adapter: .foregroundComputerUse,
                risk: .meaningful,
                requiredPermissions: [permission],
                evidence: .bundled
            )
            let plan = ActionPlan(
                app: app,
                steps: [
                    PlannedStep(
                        capabilityID: capability.id,
                        targetBundleIdentifier: bundleIdentifier,
                        effectPreview: "Bring \(bundleIdentifier) forward.",
                        redactedParameterSummary: "[redacted]",
                        visibleInteraction: .activateTargetApplication
                    )
                ],
                createdAt: now
            )
            return SequencedPlan(
                summary: "Open \(bundleIdentifier)",
                plan: plan,
                profile: CapabilityProfile(
                    app: app,
                    capabilities: [capability],
                    reviewedClaimIDs: [],
                    approvedAt: now
                )
            )
        }
        return TaskSequence(
            steps: steps,
            createdAt: now,
            expiresAt: expiry ?? now.addingTimeInterval(120)
        )
    }
}

private actor StopFlag {
    private(set) var value = false
    func trip() { value = true }
}

private actor RecordingAdapter: CapabilityAdapter {
    nonisolated let kind: AdapterKind = .foregroundComputerUse

    private let failAtIndex: Int?
    private let failure: ExecutionOutcome
    private var executed: [ExecutionContract] = []

    init(failAtIndex: Int? = nil, failure: ExecutionOutcome = .succeeded) {
        self.failAtIndex = failAtIndex
        self.failure = failure
    }

    func execute(_ contract: ExecutionContract) async -> ExecutionOutcome {
        let index = executed.count
        executed.append(contract)
        return index == failAtIndex ? failure : .succeeded
    }

    func targets() -> [String] {
        executed.map(\.validatedPlan.plan.app.bundleIdentifier)
    }

    func consents() -> [ConsentGrant] {
        executed.map(\.validatedPlan.consent)
    }
}
