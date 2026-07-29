import Foundation
import Testing
@testable import AvatarCore

@Suite("Preview-only foreground computer use")
struct ComputerUsePreviewTests {
    private let now = Date(timeIntervalSince1970: 2_000)
    private let app = AppIdentity(
        bundleIdentifier: "com.example.editor",
        displayName: "Example Editor"
    )

    @Test("Preview validation does not create execution authority")
    func previewValidatesWithoutActionMode() throws {
        let fixture = makeFixture()
        let preview = try PlanValidator().validateForPreview(
            plan: fixture.plan,
            profile: fixture.profile,
            consent: fixture.consent,
            userConfirmedPreview: true,
            now: now
        )

        #expect(preview.plan.id == fixture.plan.id)
        #expect(preview.maximumRisk == .meaningful)
    }

    @Test("Adapter renders precise typed steps but never enables execution")
    func rendersTypedSteps() throws {
        let contract = try makeContract()
        let preview = PreviewOnlyForegroundAdapter().render(
            contract,
            context: ExecutionContext(
                frontmostBundleIdentifier: app.bundleIdentifier,
                accessibilityPermissionGranted: true,
                emergencyStopped: false,
                now: now
            )
        )

        #expect(preview.steps.count == 2)
        #expect(
            preview.steps[0].contains(
                "Bring the exact target application to the foreground."
            )
        )
        #expect(preview.steps[1].contains("Press ⌘S once."))
        #expect(preview.readinessIssues.isEmpty)
        #expect(!preview.executionEnabled)
    }

    @Test("Preflight path reports permission and focus blockers")
    func reportsReadinessBlockers() throws {
        let contract = try makeContract()
        let preview = PreviewOnlyForegroundAdapter().render(
            contract,
            context: ExecutionContext(
                frontmostBundleIdentifier: "com.example.other",
                accessibilityPermissionGranted: false,
                emergencyStopped: false,
                now: now
            )
        )

        #expect(preview.readinessIssues.contains(.targetNotForeground))
        #expect(
            preview.readinessIssues.contains(
                .accessibilityPermissionMissing
            )
        )
        #expect(!preview.executionEnabled)
    }

    @Test("Emergency stop remains visible in preview preflight")
    func reportsEmergencyStop() throws {
        let preview = PreviewOnlyForegroundAdapter().render(
            try makeContract(),
            context: ExecutionContext(
                frontmostBundleIdentifier: app.bundleIdentifier,
                accessibilityPermissionGranted: true,
                emergencyStopped: true,
                now: now
            )
        )

        #expect(preview.readinessIssues.contains(.emergencyStopped))
        #expect(!preview.executionEnabled)
    }

    private typealias Fixture = (
        plan: ActionPlan,
        profile: CapabilityProfile,
        consent: ConsentGrant
    )

    private func makeFixture() -> Fixture {
        let permission = PermissionScope.accessibility(
            targetBundleIdentifier: app.bundleIdentifier
        )
        let capability = CapabilityDefinition(
            id: "preview.shortcut",
            name: "Preview shortcut",
            effectSummary: "Preview one visible shortcut.",
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
                    effectPreview: "Target would become foreground.",
                    redactedParameterSummary: "Bundle identifier",
                    visibleInteraction: .activateTargetApplication
                ),
                PlannedStep(
                    capabilityID: capability.id,
                    targetBundleIdentifier: app.bundleIdentifier,
                    effectPreview: "Illustrative shortcut only.",
                    redactedParameterSummary: "Command-S",
                    visibleInteraction: .keyboardShortcut(
                        key: "S",
                        modifiers: [.command]
                    )
                ),
            ],
            createdAt: now
        )
        let consent = ConsentGrant(
            planID: plan.id,
            scopes: [permission],
            approvedAt: now,
            expiresAt: now.addingTimeInterval(60)
        )
        return (plan, profile, consent)
    }

    private func makeContract() throws -> ComputerUsePreviewContract {
        let fixture = makeFixture()
        let validated = try PlanValidator().validateForPreview(
            plan: fixture.plan,
            profile: fixture.profile,
            consent: fixture.consent,
            userConfirmedPreview: true,
            now: now
        )
        return ComputerUsePreviewContract(
            validatedPlan: validated,
            issuedAt: now
        )
    }
}
