import AvatarCore
import AvatarPlatform
import Foundation

// MARK: - Confidence Gate

@MainActor
extension AvatarModel {
    /// UX tuning only. It never grants authority or skips validation, preview,
    /// consent, expiry, Emergency Stop, or execution checks.
    static let brainProposalConfidenceThreshold = 0.65

    static func disambiguationMessage(
        proposals: [BrainProposal],
        alternatives: [String]
    ) -> String {
        if proposals.count > 1 {
            return "I’m not sure which apps you mean. Please name them in order."
        }
        guard !alternatives.isEmpty,
            proposals.count == 1,
            let proposedName = proposals.first.flatMap({ proposal in
                switch proposal {
                case let .openApplication(name, _),
                    let .switchToApplication(name, _):
                    name
                case .noSupportedAction:
                    nil
                }
            })
        else {
            return "I’m not sure which app you mean. Please name it."
        }

        let candidates = [proposedName] + alternatives
        if candidates.count == 2 {
            return "Did you mean \(candidates[0]) or \(candidates[1])? Please say which app."
        }
        return "Did you mean \(candidates[0]), \(candidates[1]), or \(candidates[2])? Please say which app."
    }
}
