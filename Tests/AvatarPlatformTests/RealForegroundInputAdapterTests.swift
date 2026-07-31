import AvatarCore
@testable import AvatarPlatform
import Foundation
import Testing

@MainActor
@Suite("Real foreground input adapter")
struct RealForegroundInputAdapterTests {
    private let target = "com.example.calculator"
    private let now = Date(timeIntervalSince1970: 5_000)

    @Test("Accessibility press step routes only to the accessibility performer")
    func routesAccessibilityPress() async throws {
        let deps = Dependencies()
        let contract = try makeContract(
            steps: [.accessibilityPress(role: "AXButton", label: "5")]
        )

        let outcome = await deps.makeAdapter().execute(contract)

        #expect(outcome == .succeeded)
        #expect(deps.accessibility.calls == [PressCall(role: "AXButton", label: "5", bundle: target)])
        #expect(deps.keyboard.calls.isEmpty)
        #expect(deps.activation.calls.isEmpty)
    }

    @Test("Keyboard shortcut step routes only to the keyboard performer")
    func routesKeyboardShortcut() async throws {
        let deps = Dependencies()
        let contract = try makeContract(
            steps: [.keyboardShortcut(key: "c", modifiers: [.command])]
        )

        let outcome = await deps.makeAdapter().execute(contract)

        #expect(outcome == .succeeded)
        #expect(deps.keyboard.calls == [KeyCall(key: "c", modifiers: [.command], bundle: target)])
        #expect(deps.accessibility.calls.isEmpty)
    }

    @Test("Activation steps route only to the activation performer")
    func routesActivation() async throws {
        let deps = Dependencies()
        let contract = try makeContract(
            steps: [.activateTargetApplication, .launchOrActivateApplication]
        )

        let outcome = await deps.makeAdapter().execute(contract)

        #expect(outcome == .succeeded)
        #expect(deps.activation.calls == [target, target])
        #expect(deps.accessibility.calls.isEmpty)
    }

    @Test("Missing accessibility permission is denied before any performer runs")
    func deniesMissingPermission() async throws {
        let deps = Dependencies()
        deps.probe.accessibilityGranted = false
        let contract = try makeContract(
            steps: [.accessibilityPress(role: "AXButton", label: "5")]
        )

        let outcome = await deps.makeAdapter().execute(contract)

        #expect(outcome == .denied("macOS Accessibility permission is not granted."))
        #expect(deps.accessibility.calls.isEmpty)
    }

    @Test("Expired contract is denied")
    func deniesExpiredContract() async throws {
        let deps = Dependencies()
        let contract = try makeContract(
            steps: [.accessibilityPress(role: "AXButton", label: "5")],
            expiry: now.addingTimeInterval(-1)
        )

        let outcome = await deps.makeAdapter().execute(contract)

        #expect(outcome == .denied("Execution contract expired."))
        #expect(deps.accessibility.calls.isEmpty)
    }

    @Test("Foreground drift before a step is denied")
    func deniesForegroundDrift() async throws {
        let deps = Dependencies()
        // Preflight sees target in front; the per-step re-check sees a different app.
        deps.probe.scriptedFrontmost = [target, "com.other.app"]
        let contract = try makeContract(
            steps: [.accessibilityPress(role: "AXButton", label: "5")]
        )

        let outcome = await deps.makeAdapter().execute(contract)

        #expect(outcome == .denied("The app you wanted is no longer in front."))
        #expect(deps.accessibility.calls.isEmpty)
    }

    @Test("One-shot consent cannot be replayed")
    func deniesConsentReplay() async throws {
        let deps = Dependencies()
        let adapter = deps.makeAdapter()
        let contract = try makeContract(
            steps: [.accessibilityPress(role: "AXButton", label: "5")]
        )

        let first = await adapter.execute(contract)
        let second = await adapter.execute(contract)

        #expect(first == .succeeded)
        #expect(second == .denied("Consent already used."))
        #expect(deps.accessibility.calls.count == 1)
    }

    @Test("A failing step short-circuits and preserves order")
    func failingStepShortCircuits() async throws {
        let deps = Dependencies()
        deps.accessibility.result = .failed("Couldn't find that button on screen.")
        let contract = try makeContract(
            steps: [
                .accessibilityPress(role: "AXButton", label: "5"),
                .keyboardShortcut(key: "c", modifiers: [.command]),
            ]
        )

        let outcome = await deps.makeAdapter().execute(contract)

        #expect(outcome == .failed("Couldn't find that button on screen."))
        #expect(deps.accessibility.calls.count == 1)
        #expect(deps.keyboard.calls.isEmpty)
    }

    @Test("Label matching normalizes case and whitespace like the redactor")
    func normalizesLabels() {
        let performer = SystemAccessibilityActionPerformer.self
        #expect(performer.normalized("Play") == performer.normalized("play"))
        #expect(performer.normalized("  PLAY ") == performer.normalized("Play"))
        #expect(
            performer.normalized("Continue  watching")
                == performer.normalized("Continue watching")
        )
        #expect(performer.normalized("   ") == nil)
        #expect(performer.normalized(nil) == nil)
        #expect(performer.normalized("Play") != performer.normalized("Pause"))
    }

    // MARK: - Fixture

    private func makeContract(
        steps: [VisibleInteraction],
        expiry: Date? = nil
    ) throws -> ExecutionContract {
        let app = AppIdentity(bundleIdentifier: target, displayName: "Calculator")
        let capability = CapabilityDefinition(
            id: "computer_use",
            name: "Visible foreground action",
            effectSummary: "Performs a visible foreground action.",
            adapter: .foregroundComputerUse,
            risk: .meaningful,
            requiredPermissions: [.accessibility(targetBundleIdentifier: target)],
            evidence: .bundled
        )
        let profile = CapabilityProfile(
            app: app,
            capabilities: [capability],
            reviewedClaimIDs: [],
            approvedAt: now
        )
        let plannedSteps = steps.map { interaction in
            PlannedStep(
                capabilityID: "computer_use",
                targetBundleIdentifier: target,
                effectPreview: "Visible action.",
                redactedParameterSummary: "[redacted]",
                visibleInteraction: interaction
            )
        }
        let plan = ActionPlan(app: app, steps: plannedSteps, createdAt: now)
        let consent = ConsentGrant(
            planID: plan.id,
            scopes: [.accessibility(targetBundleIdentifier: target)],
            approvedAt: now,
            expiresAt: now.addingTimeInterval(60),
            oneShot: true
        )
        let validated = try PlanValidator().validate(
            plan: plan,
            profile: profile,
            consent: consent,
            safety: SafetyState(observeOnly: false),
            userConfirmedPreview: true,
            now: now
        )
        return ExecutionContract(
            validatedPlan: validated,
            issuedAt: now,
            expiresAt: expiry ?? now.addingTimeInterval(60)
        )
    }

    @MainActor
    private final class Dependencies {
        let probe = FakeProbe()
        let accessibility = FakeAccessibilityPerformer()
        let keyboard = FakeKeyboardPerformer()
        let activation = FakeActivationPerformer()
        let ledger = ConsentUseLedger()

        init() {
            probe.frontmost = "com.example.calculator"
        }

        func makeAdapter() -> RealForegroundInputAdapter {
            RealForegroundInputAdapter(
                probe: probe,
                accessibilityPerformer: accessibility,
                keyboardPerformer: keyboard,
                activationPerformer: activation,
                consentLedger: ledger,
                now: { Date(timeIntervalSince1970: 5_000) }
            )
        }
    }
}

struct PressCall: Equatable {
    let role: String
    let label: String
    let bundle: String
}

struct KeyCall: Equatable {
    let key: String
    let modifiers: Set<ModifierKey>
    let bundle: String
}

@MainActor
final class FakeProbe: ForegroundEnvironmentProbe {
    var frontmost: String?
    var accessibilityGranted = true
    var emergencyStopped = false
    var scriptedFrontmost: [String?]?
    var scriptedEmergency: [Bool]?
    private var call = 0

    func currentContext(now: Date) -> ExecutionContext {
        let frontmostValue: String?
        if let scriptedFrontmost {
            frontmostValue = call < scriptedFrontmost.count
                ? scriptedFrontmost[call]
                : scriptedFrontmost.last ?? frontmost
        } else {
            frontmostValue = frontmost
        }

        let emergencyValue: Bool
        if let scriptedEmergency {
            emergencyValue = call < scriptedEmergency.count
                ? scriptedEmergency[call]
                : scriptedEmergency.last ?? emergencyStopped
        } else {
            emergencyValue = emergencyStopped
        }

        call += 1
        return ExecutionContext(
            frontmostBundleIdentifier: frontmostValue,
            accessibilityPermissionGranted: accessibilityGranted,
            emergencyStopped: emergencyValue,
            now: now
        )
    }
}

@MainActor
final class FakeAccessibilityPerformer: AccessibilityActionPerformer {
    var result: ForegroundInputResult = .performed
    private(set) var calls: [PressCall] = []

    func press(
        role: String,
        label: String,
        inBundleIdentifier bundleIdentifier: String
    ) -> ForegroundInputResult {
        calls.append(PressCall(role: role, label: label, bundle: bundleIdentifier))
        return result
    }
}

@MainActor
final class FakeKeyboardPerformer: KeyboardShortcutPerformer {
    var result: ForegroundInputResult = .performed
    private(set) var calls: [KeyCall] = []

    func post(
        key: String,
        modifiers: Set<ModifierKey>,
        toBundleIdentifier bundleIdentifier: String
    ) -> ForegroundInputResult {
        calls.append(KeyCall(key: key, modifiers: modifiers, bundle: bundleIdentifier))
        return result
    }
}

@MainActor
final class FakeActivationPerformer: ForegroundActivationPerformer {
    var result: ForegroundInputResult = .performed
    private(set) var calls: [String] = []

    func activate(bundleIdentifier: String) -> ForegroundInputResult {
        calls.append(bundleIdentifier)
        return result
    }
}
