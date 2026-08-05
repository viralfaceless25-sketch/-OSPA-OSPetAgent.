import AvatarCore
import Foundation
import Testing

@Suite("Task sequence command parsing")
struct TaskSequenceCommandTests {
    private let parser = TaskSequenceCommandParser()

    @Test("Two executable clauses joined by and become an ordered sequence")
    func parsesTwoClauses() {
        guard case let .sequence(commands) = parser.parse(
            "open Safari and open Notes"
        ) else {
            Issue.record("Expected a sequence.")
            return
        }

        #expect(commands.count == 2)
        #expect(commands[0].requestedApplicationName == "Safari")
        #expect(commands[1].requestedApplicationName == "Notes")
    }

    @Test("Commas and then are accepted as separators")
    func parsesOtherSeparators() {
        guard case let .sequence(commands) = parser.parse(
            "open Safari, open Notes and then switch to Music"
        ) else {
            Issue.record("Expected a sequence.")
            return
        }

        #expect(
            commands.map(\.requestedApplicationName) == ["Safari", "Notes", "Music"]
        )
        #expect(commands[2].operation == .switchToRunning)
    }

    @Test("A single request is not a sequence")
    func singleRequestIsNotSequence() {
        #expect(parser.parse("open Safari") == .notSequence)
    }

    @Test("A non-command clause falls through to existing deferred parsing")
    func nonCommandClauseFallsThrough() {
        // The second clause is a goal, not a supported command, so this stays
        // with ApplicationSequenceParser rather than becoming an executable chain.
        #expect(
            parser.parse("open Netflix and continue playing One Piece")
                == .notSequence
        )
    }

    @Test("More clauses than the sequence cap are refused, not truncated")
    func refusesOversizedRequest() {
        let request = (0...TaskSequence.maximumSteps)
            .map { "open App\($0)" }
            .joined(separator: " and ")

        guard case let .rejected(reason) = parser.parse(request) else {
            Issue.record("Expected a rejection.")
            return
        }
        #expect(reason.contains("\(TaskSequence.maximumSteps)"))
    }

    @Test("Empty clauses from stray separators are ignored")
    func ignoresEmptyClauses() {
        #expect(
            TaskSequenceCommandParser.clauses(in: "open Safari,, and open Notes")
                == ["open Safari", "open Notes"]
        )
    }
}
