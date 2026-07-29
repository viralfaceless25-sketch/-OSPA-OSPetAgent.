import Foundation
import Testing
@testable import AvatarCore

@Suite("Capability profile validation")
struct ProfileValidatorTests {
    private let app = AppIdentity(
        bundleIdentifier: "com.example.editor",
        displayName: "Example Editor"
    )
    private let validator = ProfileValidator()
    private let now = Date(timeIntervalSince1970: 1_000)

    @Test("Foreground computer-use requires app-scoped Accessibility policy")
    func accessibilityScopeRequired() {
        let capability = CapabilityDefinition(
            id: "save",
            name: "Save",
            effectSummary: "Send visible Save shortcut",
            adapter: .foregroundComputerUse,
            risk: .meaningful,
            requiredPermissions: [],
            evidence: .bundled
        )

        #expect(
            throws: ProfileValidationError.computerUseNeedsTargetedAccessibility
        ) {
            try validator.validate(profile(capability))
        }
    }

    @Test("Foreground computer-use cannot be mislabeled low-risk")
    func computerUseRiskFloor() {
        let capability = CapabilityDefinition(
            id: "inspect",
            name: "Inspect",
            effectSummary: "Drive visible UI",
            adapter: .foregroundComputerUse,
            risk: .readOnly,
            requiredPermissions: [
                .accessibility(targetBundleIdentifier: app.bundleIdentifier)
            ],
            evidence: .bundled
        )

        #expect(throws: ProfileValidationError.computerUseMustBeMeaningful) {
            try validator.validate(profile(capability))
        }
    }

    @Test("Research evidence must be reviewed")
    func evidenceMustBeReviewed() {
        let claimID = UUID()
        let capability = CapabilityDefinition(
            id: "save",
            name: "Save",
            effectSummary: "Send visible Save shortcut",
            adapter: .keyboardShortcut,
            risk: .meaningful,
            requiredPermissions: [
                .accessibility(targetBundleIdentifier: app.bundleIdentifier)
            ],
            evidence: .reviewedClaim(claimID)
        )

        #expect(throws: ProfileValidationError.unreviewedEvidence(claimID)) {
            try validator.validate(profile(capability))
        }
    }

    @Test("Reviewed, scoped foreground capability validates")
    func validProfile() throws {
        let claimID = UUID()
        let capability = CapabilityDefinition(
            id: "save",
            name: "Save",
            effectSummary: "Send visible Save shortcut",
            adapter: .foregroundComputerUse,
            risk: .meaningful,
            requiredPermissions: [
                .accessibility(targetBundleIdentifier: app.bundleIdentifier)
            ],
            evidence: .reviewedClaim(claimID)
        )
        let profile = CapabilityProfile(
            app: app,
            capabilities: [capability],
            reviewedClaimIDs: [claimID],
            approvedAt: now
        )

        try validator.validate(profile)
    }

    private func profile(
        _ capability: CapabilityDefinition
    ) -> CapabilityProfile {
        CapabilityProfile(
            app: app,
            capabilities: [capability],
            reviewedClaimIDs: [],
            approvedAt: now
        )
    }
}
