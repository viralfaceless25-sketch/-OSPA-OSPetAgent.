import Testing
@testable import AvatarCore

@Suite("Action safety gate")
struct ActionGateTests {
    private let gate = ActionGate()
    private let action = AvatarAction.copyCurrentTime

    @Test("Defaults to observe-only")
    func safeDefault() {
        #expect(SafetyState.initial.observeOnly)
        #expect(!SafetyState.initial.emergencyStopped)
    }

    @Test("Observe-only denies even confirmed actions")
    func observeOnlyDenies() {
        let result = gate.evaluate(
            action,
            state: .initial,
            userConfirmed: true
        )
        #expect(result == .denied(reason: "Observe-only mode blocks all actions."))
    }

    @Test("Emergency stop overrides action mode")
    func emergencyStopDenies() {
        let state = SafetyState(observeOnly: false, emergencyStopped: true)
        let result = gate.evaluate(action, state: state, userConfirmed: true)
        #expect(
            result == .denied(
                reason: "Emergency stop is active. Resume manually before any action."
            )
        )
    }

    @Test("Enabled action still requires confirmation")
    func confirmationRequired() {
        let state = SafetyState(observeOnly: false)
        let result = gate.evaluate(action, state: state, userConfirmed: false)
        #expect(result == .needsConfirmation(preview: action.preview))
    }

    @Test("Enabled, confirmed action passes")
    func confirmedActionAllowed() {
        let state = SafetyState(observeOnly: false)
        let result = gate.evaluate(action, state: state, userConfirmed: true)
        #expect(result == .allowed)
    }
}

@Suite("Command interpreter")
struct CommandInterpreterTests {
    private let interpreter = CommandInterpreter()

    @Test(
        "Recognizes allowlisted time commands",
        arguments: ["time", "copy time", " COPY CURRENT TIME "]
    )
    func recognizedCommands(input: String) {
        #expect(interpreter.interpret(input) == .action(.copyCurrentTime))
    }

    @Test("Rejects non-allowlisted commands")
    func rejectsUnknownCommand() {
        #expect(
            interpreter.interpret("delete files")
                == .rejected("Unknown command. Available command: copy time")
        )
    }

    @Test("Empty input shows help")
    func emptyShowsHelp() {
        #expect(interpreter.interpret("  ") == .help)
    }
}
