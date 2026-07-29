import AvatarCore
import Foundation
import Testing
@testable import AvatarPlatform

@Suite("Accessibility UI inspector")
@MainActor
struct AccessibilityUIInspectorTests {
    @Test("Inspector forwards exact PID and limits then redacts")
    func inspectsBoundedSource() throws {
        let source = FakeAccessibilityTreeSource(
            result: .success(
                AccessibilityRawSnapshot(
                    elements: [
                        RawAccessibilityElement(
                            role: "AXButton",
                            label: "Play",
                            actions: ["AXPress"]
                        ),
                        RawAccessibilityElement(
                            role: "AXStaticText",
                            label: "private content",
                            actions: []
                        ),
                    ],
                    visitedElementCount: 7,
                    truncated: false
                )
            )
        )
        let inspector = AccessibilityUIInspector(source: source)
        let validated = try makeValidatedInspection()

        let result = inspector.inspect(
            processIdentifier: 321,
            validated: validated,
            capturedAt: Date()
        )

        guard case let .success(snapshot) = result else {
            Issue.record("Expected snapshot")
            return
        }
        #expect(source.processIdentifiers == [321])
        #expect(source.maximumVisitedElements == [60])
        #expect(source.maximumDepths == [4])
        #expect(snapshot.controls.count == 1)
        #expect(snapshot.controls[0].label == "Play")
    }

    @Test("Source failure returns no partial snapshot")
    func preservesFailure() throws {
        let source = FakeAccessibilityTreeSource(
            result: .failure(.permissionDenied)
        )
        let result = AccessibilityUIInspector(source: source).inspect(
            processIdentifier: 321,
            validated: try makeValidatedInspection(),
            capturedAt: Date()
        )

        #expect(result == .failure(.permissionDenied))
    }

    @Test("System source rejects PID that is no longer foreground")
    func systemSourceRejectsFocusDriftBeforeReading() {
        let source = SystemAccessibilityTreeSnapshotSource(
            frontmostProcessIdentifier: { 999 }
        )

        let result = source.read(
            processIdentifier: 321,
            maximumVisitedElements: 60,
            maximumDepth: 4
        )

        #expect(result == .failure(.targetNoLongerForeground))
    }

    private func makeValidatedInspection() throws
        -> ValidatedAccessibilityInspection
    {
        let now = Date()
        let app = AppIdentity(
            bundleIdentifier: "com.example.target",
            displayName: "Target"
        )
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
            expiresAt: now.addingTimeInterval(30)
        )
        return try AccessibilityInspectionValidator().validate(
            request: request,
            consent: consent,
            context: AccessibilityInspectionContext(
                frontmostBundleIdentifier: app.bundleIdentifier,
                accessibilityPermissionGranted: true,
                emergencyStopped: false,
                now: now
            ),
            userApproved: true
        )
    }
}

@MainActor
private final class FakeAccessibilityTreeSource:
    AccessibilityTreeSnapshotSource
{
    private let result: Result<AccessibilityRawSnapshot, AccessibilityTreeSourceError>
    private(set) var processIdentifiers: [pid_t] = []
    private(set) var maximumVisitedElements: [Int] = []
    private(set) var maximumDepths: [Int] = []

    init(
        result:
            Result<
                AccessibilityRawSnapshot,
                AccessibilityTreeSourceError
            >
    ) {
        self.result = result
    }

    func read(
        processIdentifier: pid_t,
        maximumVisitedElements: Int,
        maximumDepth: Int
    ) -> Result<AccessibilityRawSnapshot, AccessibilityTreeSourceError> {
        processIdentifiers.append(processIdentifier)
        self.maximumVisitedElements.append(maximumVisitedElements)
        maximumDepths.append(maximumDepth)
        return result
    }
}
