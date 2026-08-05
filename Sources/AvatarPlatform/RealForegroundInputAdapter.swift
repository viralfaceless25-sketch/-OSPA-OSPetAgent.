import AvatarCore
import Foundation

/// Result of a single visible foreground act. Kept tiny and Sendable so it can
/// cross the actor boundary out of a performer.
public enum ForegroundInputResult: Equatable, Sendable {
    case performed
    case failed(String)
}

/// Live snapshot of the world the executor must re-verify against. Injected so
/// tests can script foreground drift, permission, and stop states.
@MainActor
public protocol ForegroundEnvironmentProbe: AnyObject {
    func currentContext(now: Date) -> ExecutionContext
}

/// Presses one Accessibility element by role + label. No coordinates, ever.
@MainActor
public protocol AccessibilityActionPerformer: AnyObject {
    func press(
        role: String,
        label: String,
        inBundleIdentifier bundleIdentifier: String
    ) -> ForegroundInputResult
}

/// Posts one bounded keyboard chord to the frontmost app. Only CGEvent path.
@MainActor
public protocol KeyboardShortcutPerformer: AnyObject {
    func post(
        key: String,
        modifiers: Set<ModifierKey>,
        toBundleIdentifier bundleIdentifier: String
    ) -> ForegroundInputResult
}

/// Brings the exact target application to the front, launching it first if it
/// is not running. No HID. Async because launching is inherently asynchronous.
@MainActor
public protocol ForegroundActivationPerformer: AnyObject {
    func activate(bundleIdentifier: String) async -> ForegroundInputResult
}

/// The first real `CapabilityAdapter`. Reuses the existing
/// ExecutionContract -> execute -> ExecutionOutcome seam unchanged. It re-runs
/// preflight, burns one-shot consent, and re-checks expiry + foreground before
/// every step, then dispatches each typed `VisibleInteraction` to a performer.
@MainActor
public final class RealForegroundInputAdapter: CapabilityAdapter {
    public nonisolated let kind: AdapterKind = .foregroundComputerUse

    private let probe: any ForegroundEnvironmentProbe
    private let accessibilityPerformer: any AccessibilityActionPerformer
    private let keyboardPerformer: any KeyboardShortcutPerformer
    private let activationPerformer: any ForegroundActivationPerformer
    private let consentLedger: ConsentUseLedger
    private let now: @MainActor () -> Date
    private let preflight = ExecutionPreflight()

    public init(
        probe: any ForegroundEnvironmentProbe,
        accessibilityPerformer: any AccessibilityActionPerformer,
        keyboardPerformer: any KeyboardShortcutPerformer,
        activationPerformer: any ForegroundActivationPerformer,
        consentLedger: ConsentUseLedger,
        now: @MainActor @escaping () -> Date = { Date() }
    ) {
        self.probe = probe
        self.accessibilityPerformer = accessibilityPerformer
        self.keyboardPerformer = keyboardPerformer
        self.activationPerformer = activationPerformer
        self.consentLedger = consentLedger
        self.now = now
    }

    public func execute(_ contract: ExecutionContract) async -> ExecutionOutcome {
        let context = probe.currentContext(now: now())
        do {
            try preflight.validate(contract, context: context)
        } catch let error as ExecutionPreflightError {
            return .denied(Self.reason(for: error))
        } catch {
            return .failed("Something went wrong before I could start.")
        }

        guard await consentLedger.consume(contract.validatedPlan.consent) else {
            return .denied("Consent already used.")
        }

        let target = contract.validatedPlan.plan.app.bundleIdentifier

        for step in contract.validatedPlan.plan.steps {
            let live = probe.currentContext(now: now())
            guard live.now < contract.expiresAt else {
                return .denied("Execution contract expired.")
            }
            guard !live.emergencyStopped else {
                return .denied("Emergency stop is active.")
            }
            guard live.frontmostBundleIdentifier == target else {
                return .denied("The app you wanted is no longer in front.")
            }

            let result: ForegroundInputResult
            switch step.visibleInteraction {
            case let .accessibilityPress(role, label):
                result = accessibilityPerformer.press(
                    role: role,
                    label: label,
                    inBundleIdentifier: target
                )
            case let .keyboardShortcut(key, modifiers):
                result = keyboardPerformer.post(
                    key: key,
                    modifiers: modifiers,
                    toBundleIdentifier: target
                )
            case .activateTargetApplication, .launchOrActivateApplication:
                result = await activationPerformer.activate(
                    bundleIdentifier: target
                )
            case .none:
                return .failed("This step has nothing I can do.")
            }

            if case let .failed(message) = result {
                return .failed(message)
            }
        }

        return .succeeded
    }

    private static func reason(for error: ExecutionPreflightError) -> String {
        switch error {
        case .emergencyStopped:
            "Emergency stop is active."
        case .contractExpired:
            "Execution contract expired."
        case .targetNotForeground:
            "The app you wanted is no longer in front."
        case .accessibilityPermissionMissing:
            "macOS Accessibility permission is not granted."
        }
    }
}
