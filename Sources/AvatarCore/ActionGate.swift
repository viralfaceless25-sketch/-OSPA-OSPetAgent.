import Foundation

public struct SafetyState: Equatable, Sendable {
    public var observeOnly: Bool
    public var emergencyStopped: Bool

    public init(observeOnly: Bool = true, emergencyStopped: Bool = false) {
        self.observeOnly = observeOnly
        self.emergencyStopped = emergencyStopped
    }

    public static let initial = SafetyState()
}

public enum ActionDecision: Equatable, Sendable {
    case needsConfirmation(preview: String)
    case allowed
    case denied(reason: String)
}

/// Pure policy boundary between intent and side effects.
public struct ActionGate: Sendable {
    public init() {}

    public func evaluate(
        _ action: AvatarAction,
        state: SafetyState,
        userConfirmed: Bool
    ) -> ActionDecision {
        if state.emergencyStopped {
            return .denied(
                reason: "Emergency stop is active. Resume manually before any action."
            )
        }

        if state.observeOnly {
            return .denied(
                reason: "Observe-only mode blocks all actions."
            )
        }

        guard userConfirmed else {
            return .needsConfirmation(preview: action.preview)
        }

        return .allowed
    }
}
