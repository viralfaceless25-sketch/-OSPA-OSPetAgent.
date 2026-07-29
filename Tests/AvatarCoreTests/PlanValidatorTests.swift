import Foundation
import Testing
@testable import AvatarCore

@Suite("Permissioned action planning")
struct PlanValidatorTests {
    private let validator = PlanValidator()
    private let now = Date(timeIntervalSince1970: 1_000)
    private let app = AppIdentity(
        bundleIdentifier: "com.example.editor",
        displayName: "Example Editor"
    )

    @Test("Observe-only blocks valid plan")
    func observeOnlyBlocks() {
        let fixture = makeFixture()
        #expect(throws: PlanValidationError.observeOnly) {
            try validator.validate(
                plan: fixture.plan,
                profile: fixture.profile,
                consent: fixture.consent,
                safety: .initial,
                userConfirmedPreview: true,
                now: now
            )
        }
    }

    @Test("Emergency stop takes precedence")
    func stopBlocks() {
        let fixture = makeFixture()
        #expect(throws: PlanValidationError.emergencyStopped) {
            try validator.validate(
                plan: fixture.plan,
                profile: fixture.profile,
                consent: fixture.consent,
                safety: SafetyState(
                    observeOnly: false,
                    emergencyStopped: true
                ),
                userConfirmedPreview: true,
                now: now
            )
        }
    }

    @Test("Consent cannot be reused for another plan")
    func consentBindsPlan() {
        let fixture = makeFixture(consentPlanID: UUID())
        #expect(throws: PlanValidationError.consentForDifferentPlan) {
            try validate(fixture, confirmed: true)
        }
    }

    @Test("Missing Accessibility policy scope blocks execution")
    func permissionRequired() {
        let fixture = makeFixture(consentScopes: [])
        #expect(throws: PlanValidationError.missingPermissions) {
            try validate(fixture, confirmed: true)
        }
    }

    @Test("Meaningful visible action needs reviewed confirmation")
    func confirmationRequired() {
        let fixture = makeFixture()
        #expect(throws: PlanValidationError.confirmationRequired) {
            try validate(fixture, confirmed: false)
        }
    }

    @Test("Consent cannot smuggle unused broader permission")
    func excessPermissionRejected() {
        let accessibility = PermissionScope.accessibility(
            targetBundleIdentifier: app.bundleIdentifier
        )
        let fixture = makeFixture(
            consentScopes: [
                accessibility,
                .network(hosts: ["unrelated.example"]),
            ]
        )

        #expect(throws: PlanValidationError.excessPermissions) {
            try validate(fixture, confirmed: true)
        }
    }

    @Test("Exact target, scope, and confirmation produce validated plan")
    func validPlan() throws {
        let fixture = makeFixture()
        let result = try validate(fixture, confirmed: true)

        #expect(result.plan.id == fixture.plan.id)
        #expect(result.maximumRisk == .meaningful)
        #expect(result.consent.oneShot)
    }

    @Test("Audit log records contract lifecycle")
    func auditLog() async {
        let fixture = makeFixture()
        let validated = try? validate(fixture, confirmed: true)
        let contract = validated.map {
            ExecutionContract(
                validatedPlan: $0,
                issuedAt: now,
                expiresAt: now.addingTimeInterval(30)
            )
        }
        let log = InMemoryAuditLog()

        if let contract {
            await log.append(
                AuditEvent(
                    contractID: contract.id,
                    planID: contract.validatedPlan.plan.id,
                    timestamp: now,
                    outcome: .started
                )
            )
            await log.append(
                AuditEvent(
                    contractID: contract.id,
                    planID: contract.validatedPlan.plan.id,
                    timestamp: now,
                    outcome: .cancelled
                )
            )
            let events = await log.events(for: contract.id)
            #expect(events.map(\.outcome) == [.started, .cancelled])
        } else {
            Issue.record("Fixture should produce a valid contract")
        }
    }

    @Test("Execution preflight rejects focus drift")
    func focusDrift() throws {
        let fixture = makeFixture()
        let validated = try validate(fixture, confirmed: true)
        let contract = ExecutionContract(
            validatedPlan: validated,
            issuedAt: now,
            expiresAt: now.addingTimeInterval(30)
        )

        #expect(throws: ExecutionPreflightError.targetNotForeground) {
            try ExecutionPreflight().validate(
                contract,
                context: ExecutionContext(
                    frontmostBundleIdentifier: "com.example.other",
                    accessibilityPermissionGranted: true,
                    emergencyStopped: false,
                    now: now
                )
            )
        }
    }

    @Test("Execution preflight rejects missing macOS permission")
    func missingOSPermission() throws {
        let fixture = makeFixture()
        let validated = try validate(fixture, confirmed: true)
        let contract = ExecutionContract(
            validatedPlan: validated,
            issuedAt: now,
            expiresAt: now.addingTimeInterval(30)
        )

        #expect(
            throws: ExecutionPreflightError.accessibilityPermissionMissing
        ) {
            try ExecutionPreflight().validate(
                contract,
                context: ExecutionContext(
                    frontmostBundleIdentifier: app.bundleIdentifier,
                    accessibilityPermissionGranted: false,
                    emergencyStopped: false,
                    now: now
                )
            )
        }
    }

    @Test("One-shot consent can only be consumed once")
    func oneShotConsent() async {
        let grant = makeFixture().consent
        let ledger = ConsentUseLedger()

        #expect(await ledger.consume(grant))
        #expect(!(await ledger.consume(grant)))
    }

    private typealias Fixture = (
        plan: ActionPlan,
        profile: CapabilityProfile,
        consent: ConsentGrant
    )

    private func makeFixture(
        consentPlanID: UUID? = nil,
        consentScopes: Set<PermissionScope>? = nil
    ) -> Fixture {
        let permission = PermissionScope.accessibility(
            targetBundleIdentifier: app.bundleIdentifier
        )
        let capability = CapabilityDefinition(
            id: "save",
            name: "Save",
            effectSummary: "Send the visible Save shortcut",
            adapter: .foregroundComputerUse,
            risk: .meaningful,
            requiredPermissions: [permission],
            evidence: .bundled
        )
        let profile = CapabilityProfile(
            app: app,
            capabilities: [capability],
            reviewedClaimIDs: [],
            approvedAt: now
        )
        let plan = ActionPlan(
            app: app,
            steps: [
                PlannedStep(
                    capabilityID: capability.id,
                    targetBundleIdentifier: app.bundleIdentifier,
                    effectPreview: "Bring Example Editor forward and press ⌘S.",
                    redactedParameterSummary: "No parameters"
                )
            ],
            createdAt: now
        )
        let consent = ConsentGrant(
            planID: consentPlanID ?? plan.id,
            scopes: consentScopes ?? [permission],
            approvedAt: now,
            expiresAt: now.addingTimeInterval(60)
        )
        return (plan, profile, consent)
    }

    private func validate(
        _ fixture: Fixture,
        confirmed: Bool
    ) throws -> ValidatedPlan {
        try validator.validate(
            plan: fixture.plan,
            profile: fixture.profile,
            consent: fixture.consent,
            safety: SafetyState(observeOnly: false),
            userConfirmedPreview: confirmed,
            now: now
        )
    }
}
