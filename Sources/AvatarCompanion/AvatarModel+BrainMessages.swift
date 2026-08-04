import AvatarCore
import AvatarPlatform
import Foundation

// MARK: - Brain Routing and Chat Messages

@MainActor
extension AvatarModel {
    /// Honest copy for a request no installed capability can serve. Fixed text,
    /// never model-authored, so an unsupported answer cannot be influenced by
    /// the request that triggered it.
    static let unsupportedRequestMessage =
        "I can’t browse the web or use current online information yet. "
        + "I can open or switch Mac apps, or chat about things that don’t need "
        + "current information."
    /// Plain language only. These strings are read by someone who does not know
    /// what a model, a port, or a tool call is.
    static func brainMessage(for error: any Error) -> String {
        if let proposalError = error as? BrainProposalError {
            switch proposalError {
            case let .applicationNotInstalled(name):
                return "\(name) isn’t installed on this Mac."
            case .unknownTool:
                // The model understood the request and proposed something
                // outside the closed menu. Saying "I didn't understand" would
                // misdescribe what happened; the request was refused, not
                // misread.
                return
                    "That’s not allowed. I can only open or switch apps that are "
                    + "already installed on this Mac."
            case .noToolCalls, .tooManyToolCalls,
                .malformedArguments, .missingArgument, .unsafeApplicationName,
                .unsafeReason:
                return "I didn’t understand that well enough to suggest something safe."
            }
        }

        if let localError = error as? LocalBrainError {
            switch localError {
            case .unavailable:
                return "I can’t think right now. You can still type an exact command."
            case .timedOut:
                return "That took too long, so I stopped."
            case .noToolCall, .badResponse:
                return "I couldn’t work out what to do with that."
            }
        }

        return "Something went wrong working that out."
    }
}
