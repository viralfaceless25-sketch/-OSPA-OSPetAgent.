import Foundation
import Testing
@testable import AvatarCore

@Suite("Scoped Accessibility inspection")
struct AccessibilityInspectionTests {
    private let now = Date(timeIntervalSince1970: 5_000)
    private let app = AppIdentity(
        bundleIdentifier: "com.example.video",
        displayName: "Example Video"
    )

    @Test("Exact target, permission, and approval validate in observe-only")
    func validatesReadOnlyInspection() throws {
        let fixture = makeFixture()
        let validated = try AccessibilityInspectionValidator().validate(
            request: fixture.request,
            consent: fixture.consent,
            context: AccessibilityInspectionContext(
                frontmostBundleIdentifier: app.bundleIdentifier,
                accessibilityPermissionGranted: true,
                emergencyStopped: false,
                now: now
            ),
            userApproved: true
        )

        #expect(validated.request.target == app)
    }

    @Test("Focus, permission, expiry, stop, and approval block inspection")
    func blocksInvalidPreflight() {
        let fixture = makeFixture()
        let validator = AccessibilityInspectionValidator()

        #expect(throws: AccessibilityInspectionValidationError.targetNotForeground) {
            try validator.validate(
                request: fixture.request,
                consent: fixture.consent,
                context: context(frontmost: "com.example.other"),
                userApproved: true
            )
        }
        #expect(
            throws:
                AccessibilityInspectionValidationError
                .accessibilityPermissionMissing
        ) {
            try validator.validate(
                request: fixture.request,
                consent: fixture.consent,
                context: context(permission: false),
                userApproved: true
            )
        }
        #expect(throws: AccessibilityInspectionValidationError.emergencyStopped) {
            try validator.validate(
                request: fixture.request,
                consent: fixture.consent,
                context: context(stopped: true),
                userApproved: true
            )
        }
        #expect(throws: AccessibilityInspectionValidationError.requestExpired) {
            try validator.validate(
                request: fixture.request,
                consent: fixture.consent,
                context: context(now: now.addingTimeInterval(61)),
                userApproved: true
            )
        }
        #expect(throws: AccessibilityInspectionValidationError.userApprovalRequired) {
            try validator.validate(
                request: fixture.request,
                consent: fixture.consent,
                context: context(),
                userApproved: false
            )
        }
    }

    @Test("Broader or wrong Accessibility scope is rejected")
    func rejectsWrongScope() {
        let fixture = makeFixture()
        let wrongConsent = ConsentGrant(
            planID: fixture.request.id,
            scopes: [
                .accessibility(
                    targetBundleIdentifier: "com.example.other"
                )
            ],
            approvedAt: now,
            expiresAt: now.addingTimeInterval(30)
        )

        #expect(
            throws:
                AccessibilityInspectionValidationError
                .wrongPermissionScope
        ) {
            try AccessibilityInspectionValidator().validate(
                request: fixture.request,
                consent: wrongConsent,
                context: context(),
                userApproved: true
            )
        }
    }

    @Test("Inspection requires one-shot consent and bounded traversal")
    func rejectsReusableConsentAndInvalidLimits() {
        let fixture = makeFixture()
        let reusableConsent = ConsentGrant(
            planID: fixture.request.id,
            scopes: fixture.consent.scopes,
            approvedAt: now,
            expiresAt: now.addingTimeInterval(30),
            oneShot: false
        )

        #expect(
            throws:
                AccessibilityInspectionValidationError
                .oneShotConsentRequired
        ) {
            try AccessibilityInspectionValidator().validate(
                request: fixture.request,
                consent: reusableConsent,
                context: context(),
                userApproved: true
            )
        }

        let unboundedRequest = AccessibilityInspectionRequest(
            target: app,
            createdAt: now,
            expiresAt: now.addingTimeInterval(60),
            maximumControls: 41,
            maximumVisitedElements: 60,
            maximumDepth: 4
        )
        let consent = ConsentGrant(
            planID: unboundedRequest.id,
            scopes: [
                .accessibility(
                    targetBundleIdentifier: app.bundleIdentifier
                )
            ],
            approvedAt: now,
            expiresAt: now.addingTimeInterval(30),
            oneShot: true
        )

        #expect(
            throws:
                AccessibilityInspectionValidationError.invalidLimits
        ) {
            try AccessibilityInspectionValidator().validate(
                request: unboundedRequest,
                consent: consent,
                context: context(),
                userApproved: true
            )
        }
    }

    @Test("Unknown labels and actions are removed or redacted")
    func redactsSensitiveMetadata() throws {
        let snapshot = AccessibilitySnapshotRedactor().makeSnapshot(
            validated: try validatedFixture(),
            rawElements: [
                RawAccessibilityElement(
                    role: "AXButton",
                    label: "Play One Piece for alice@example.com",
                    actions: ["AXPress", "AXUnknownAction"]
                ),
                RawAccessibilityElement(
                    role: "AXButton",
                    label: "Play",
                    actions: ["AXPress"]
                ),
                RawAccessibilityElement(
                    role: "AXStaticText",
                    label: "Secret account balance",
                    actions: []
                ),
            ],
            visitedElementCount: 3,
            sourceTruncated: false,
            capturedAt: now
        )

        #expect(snapshot.controls.count == 2)
        #expect(snapshot.controls[0].label == "[redacted label]")
        #expect(snapshot.controls[0].labelWasRedacted)
        #expect(snapshot.controls[0].actions == [.press])
        #expect(snapshot.controls[1].label == "Play")
        #expect(!snapshot.controls[1].labelWasRedacted)
        #expect(!String(describing: snapshot).contains("alice@example.com"))
        #expect(!String(describing: snapshot).contains("Secret account balance"))
    }

    @Test("Snapshot applies strict control and visited-element caps")
    func capsSnapshot() throws {
        let raw = (0..<50).map { index in
            RawAccessibilityElement(
                role: "AXButton",
                label: index == 0 ? "Play" : "private \(index)",
                actions: ["AXPress"]
            )
        }
        let snapshot = AccessibilitySnapshotRedactor().makeSnapshot(
            validated: try validatedFixture(),
            rawElements: raw,
            visitedElementCount: 400,
            sourceTruncated: true,
            capturedAt: now
        )

        #expect(snapshot.controls.count == 20)
        #expect(snapshot.visitedElementCount == 60)
        #expect(snapshot.truncated)
    }

    @Test("Evidence preview never enables execution")
    func evidenceIsPreviewOnly() throws {
        let snapshot = AccessibilitySnapshotRedactor().makeSnapshot(
            validated: try validatedFixture(),
            rawElements: [
                RawAccessibilityElement(
                    role: "AXButton",
                    label: "Play",
                    actions: ["AXPress"]
                )
            ],
            visitedElementCount: 1,
            sourceTruncated: false,
            capturedAt: now
        )
        let preview = AccessibilityInteractionPreview(snapshot: snapshot)

        #expect(!preview.executionEnabled)
        #expect(
            preview.evidence == [
                AccessibilityInteractionEvidence(
                    id: 1,
                    description: "Button “Play” exposes Press."
                )
            ])
    }

    @Test("Audit records cannot contain labels or captured text")
    func auditIsMetadataOnly() {
        let record = AccessibilityInspectionAuditRecord(
            requestID: UUID(),
            targetBundleIdentifier: app.bundleIdentifier,
            timestamp: now,
            outcome: .succeeded(controlCount: 3, truncated: true)
        )
        let rendered = String(describing: record)

        #expect(rendered.contains(app.bundleIdentifier))
        #expect(rendered.contains("controlCount: 3"))
        #expect(!rendered.contains("Play"))
        #expect(!rendered.contains("label"))
        #expect(!rendered.contains("text"))
    }

    private typealias Fixture = (
        request: AccessibilityInspectionRequest,
        consent: ConsentGrant
    )

    private func makeFixture() -> Fixture {
        let request = AccessibilityInspectionRequest(
            target: app,
            createdAt: now,
            expiresAt: now.addingTimeInterval(60)
        )
        let consent = ConsentGrant(
            planID: request.id,
            scopes: [
                .accessibility(
                    targetBundleIdentifier: app.bundleIdentifier
                )
            ],
            approvedAt: now,
            expiresAt: now.addingTimeInterval(30),
            oneShot: true
        )
        return (request, consent)
    }

    private func context(
        frontmost: String? = nil,
        permission: Bool = true,
        stopped: Bool = false,
        now contextNow: Date? = nil
    ) -> AccessibilityInspectionContext {
        AccessibilityInspectionContext(
            frontmostBundleIdentifier:
                frontmost ?? app.bundleIdentifier,
            accessibilityPermissionGranted: permission,
            emergencyStopped: stopped,
            now: contextNow ?? now
        )
    }

    private func validatedFixture() throws
        -> ValidatedAccessibilityInspection
    {
        let fixture = makeFixture()
        return try AccessibilityInspectionValidator().validate(
            request: fixture.request,
            consent: fixture.consent,
            context: context(),
            userApproved: true
        )
    }
}
