import AppKit
import AvatarCore
import Foundation

@MainActor
final class AvatarModel: ObservableObject {
    @Published var isExpanded = false
    @Published var command = ""
    @Published var previewedAction: AvatarAction?
    @Published var safety = SafetyState.initial
    @Published var status = "Observe-only mode is on."

    var onExpansionChanged: ((Bool) -> Void)?
    var onHide: (() -> Void)?

    private let interpreter = CommandInterpreter()
    private let gate = ActionGate()

    func toggleExpanded() {
        isExpanded.toggle()
        onExpansionChanged?(isExpanded)
    }

    func previewCommand() {
        switch interpreter.interpret(command) {
        case .help:
            previewedAction = nil
            status = "Try “copy time”. Only allowlisted commands are recognized."
        case let .rejected(reason):
            previewedAction = nil
            status = reason
        case let .action(action):
            previewedAction = action
            switch gate.evaluate(action, state: safety, userConfirmed: false) {
            case let .denied(reason):
                status = "\(action.preview) \(reason)"
            case let .needsConfirmation(preview):
                status = preview
            case .allowed:
                status = action.preview
            }
        }
    }

    func performPreviewedAction() {
        guard let action = previewedAction else {
            status = "Preview a command first."
            return
        }

        switch gate.evaluate(action, state: safety, userConfirmed: true) {
        case let .denied(reason):
            status = reason
        case .needsConfirmation:
            status = "Confirmation required."
        case .allowed:
            execute(action)
        }
    }

    func setObserveOnly(_ enabled: Bool) {
        safety.observeOnly = enabled
        if enabled {
            status = "Observe-only mode is on. Actions are blocked."
        } else {
            status = "Action mode on. Every action still needs explicit confirmation."
        }
    }

    func emergencyStop() {
        safety.emergencyStopped = true
        safety.observeOnly = true
        previewedAction = nil
        command = ""
        status = "Stopped. All actions blocked."
    }

    func resumeObservation() {
        safety = .initial
        status = "Emergency stop cleared. Observe-only mode remains on."
    }

    private func execute(_ action: AvatarAction) {
        switch action {
        case .copyCurrentTime:
            let formatter = DateFormatter()
            formatter.dateStyle = .none
            formatter.timeStyle = .medium
            let value = formatter.string(from: Date())

            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(value, forType: .string)
            status = "Copied “\(value)” to clipboard."
            previewedAction = nil
            command = ""
        }
    }
}
