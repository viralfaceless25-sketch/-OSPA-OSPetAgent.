import Foundation
import Testing
@testable import AvatarCore

@Suite("Deterministic application sequences")
struct ApplicationSequenceTests {
    private let parser = ApplicationSequenceParser()

    @Test("Splits exact app launch from deferred playback goal")
    func parsesPlaybackGoal() {
        guard
            case let .sequence(sequence) = parser.parse(
                "open Netflix and continue playing One Piece"
            )
        else {
            Issue.record("Expected application sequence")
            return
        }

        #expect(sequence.firstCommand.operation == .launchOrActivate)
        #expect(sequence.firstCommand.requestedApplicationName == "Netflix")
        #expect(
            sequence.deferredGoal
                == .continuePlayback(title: "One Piece")
        )
    }

    @Test("Unknown app goal is retained but remains unsupported")
    func preservesUnsupportedGoal() {
        guard
            case let .sequence(sequence) = parser.parse(
                "open Notes and type a draft"
            )
        else {
            Issue.record("Expected application sequence")
            return
        }

        #expect(
            sequence.deferredGoal
                == .unsupported(request: "type a draft")
        )
    }

    @Test("A second app name is not treated as a goal")
    func rejectsSecondAppName() {
        guard
            case .rejected = parser.parse("open Safari and Notes")
        else {
            Issue.record("Expected rejection")
            return
        }
    }

    @Test("Single app commands remain outside sequence parser")
    func ignoresSingleCommand() {
        #expect(parser.parse("open Netflix") == .notSequence)
    }

    @Test("Ordered plan exposes only first step as confirmable")
    func plansOneExecutableStep() throws {
        guard
            case let .sequence(sequence) = parser.parse(
                "open Netflix and continue playing One Piece"
            )
        else {
            Issue.record("Expected application sequence")
            return
        }
        let application = ResolvedApplication(
            identity: AppIdentity(
                bundleIdentifier: "com.apple.Safari.WebApp.netflix",
                displayName: "Netflix"
            ),
            applicationURL: URL(
                fileURLWithPath: "/Users/example/Applications/Netflix.app"
            ),
            isRunning: false
        )

        let proposal = try ApplicationSequencePlanner().propose(
            sequence: sequence,
            application: application,
            now: Date()
        )

        #expect(proposal.orderedSteps.count == 2)
        #expect(proposal.orderedSteps[0].availability == .confirmableNow)
        #expect(
            proposal.orderedSteps[1].availability
                == .deferredUnsupported
        )
        #expect(proposal.applicationProposal.plan.steps.count == 1)
        #expect(
            !proposal.applicationProposal.plan.steps.contains {
                $0.effectPreview.contains("One Piece")
                    || $0.redactedParameterSummary.contains("One Piece")
            }
        )
    }
}
