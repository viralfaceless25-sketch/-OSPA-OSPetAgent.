import AvatarCore
import AvatarPlatform
import Foundation

// MARK: - Safety

@MainActor
extension AvatarModel {
    func setObserveOnly(_ enabled: Bool) {
        safety.observeOnly = enabled
        if enabled {
            status = "Observe-only mode is on. Actions are blocked."
        } else {
            status = "Action mode on. Every action still needs explicit confirmation."
        }
    }
    func resumeObservation() {
        safety = .initial
        status = "Emergency stop cleared. Observe-only mode remains on."
        brainStatus = isBrainEnabled
            ? "Natural language is on. Type what you want in ordinary words."
            : "Natural language is off. Type exact commands."
    }
}
