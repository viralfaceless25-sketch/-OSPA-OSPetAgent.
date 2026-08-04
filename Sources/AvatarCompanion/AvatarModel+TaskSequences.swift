import AvatarCore
import AvatarPlatform
import Foundation

// MARK: - Task Sequences

@MainActor
extension AvatarModel {
    var taskSequenceExecutionReady: Bool {
        guard let sequence = pendingTaskSequence,
            !safety.observeOnly,
            !safety.emergencyStopped,
            !isExecutingTaskSequence
        else {
            return false
        }
        return Date() < sequence.expiresAt
    }
    func taskSequenceResultMessage(
        _ result: TaskSequenceResult
    ) -> String {
        switch result {
        case let .completed(outcomes):
            return "Done. All \(outcomes.count) requests finished."
        case let .halted(index, outcomes):
            let reason: String
            switch outcomes.last?.outcome {
            case let .denied(message), let .failed(message):
                reason = message
            default:
                reason = "It could not be completed."
            }
            return
                "Stopped at request \(index + 1). \(reason) The remaining requests were not attempted."
        }
    }

    func taskSequenceStepFailureMessage(
        _ error: Error,
        index: Int,
        total: Int,
        requestedName: String
    ) -> String {
        let prefix = "Request \(index + 1) of \(total):"
        switch error {
        case InstalledApplicationResolutionError.notFound:
            return "\(prefix) no installed app is named “\(requestedName)”."
        case InstalledApplicationResolutionError.ambiguousExactName:
            return
                "\(prefix) several apps share the name “\(requestedName)”. Use Search this Mac to pick one."
        case ApplicationProposalError.switchTargetNotRunning:
            return
                "\(prefix) “\(requestedName)” is not running, so it cannot be switched to. Say “open \(requestedName)” instead."
        default:
            return "\(prefix) it could not be planned safely."
        }
    }
}
