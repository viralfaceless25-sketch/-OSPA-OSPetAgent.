import Foundation
import Testing

@testable import AvatarCore

@Suite("Brain proposal validation")
struct BrainProposalValidatorTests {
    private let validator = BrainProposalValidator()
    private let installed: Set<String> = ["Spotify", "Notes", "Google Chrome"]

    private func call(_ tool: String, _ json: String) -> RawBrainToolCall {
        RawBrainToolCall(toolName: tool, argumentsJSON: json)
    }

    @Test("A well-formed open call for an installed app is accepted")
    func acceptsOpen() throws {
        let proposal = try validator.validate(
            call("open_application", #"{"name":"Spotify","reason":"You use it for music."}"#),
            installedApplicationNames: installed
        )
        #expect(
            proposal == .openApplication(
                name: "Spotify", reason: "You use it for music."
            )
        )
    }

    @Test("A well-formed switch call for an installed app is accepted")
    func acceptsSwitch() throws {
        let proposal = try validator.validate(
            call("switch_to_application", #"{"name":"Notes","reason":"Already running."}"#),
            installedApplicationNames: installed
        )
        #expect(
            proposal == .switchToApplication(
                name: "Notes", reason: "Already running."
            )
        )
    }

    @Test("no_supported_action needs only a reason")
    func acceptsNoSupportedAction() throws {
        let proposal = try validator.validate(
            call("no_supported_action", #"{"reason":"Nothing installed can book flights."}"#),
            installedApplicationNames: installed
        )
        #expect(
            proposal == .noSupportedAction(
                reason: "Nothing installed can book flights."
            )
        )
    }

    /// Regression test for a real observed failure: Qwen3-8B proposed opening
    /// Photoshop on a Mac where Photoshop is not installed. The model is allowed
    /// to be wrong; the validator is not.
    @Test("An app that is not installed is rejected, never passed through")
    func rejectsHallucinatedApplication() {
        #expect(throws: BrainProposalError.applicationNotInstalled("Photoshop")) {
            try validator.validate(
                call("open_application", #"{"name":"Photoshop","reason":"To edit photos."}"#),
                installedApplicationNames: installed
            )
        }
    }

    @Test("An unknown tool name is rejected")
    func rejectsUnknownTool() {
        #expect(throws: BrainProposalError.unknownTool("delete_everything")) {
            try validator.validate(
                call("delete_everything", #"{"name":"Spotify","reason":"x"}"#),
                installedApplicationNames: installed
            )
        }
    }

    @Test(
        "Malformed argument JSON is rejected rather than guessed at",
        arguments: ["not json at all", "", "{\"name\":", "[]", "null"]
    )
    func rejectsMalformedArguments(json: String) {
        #expect(throws: BrainProposalError.malformedArguments) {
            try validator.validate(
                call("open_application", json),
                installedApplicationNames: installed
            )
        }
    }

    @Test("A missing or empty name is rejected")
    func rejectsMissingName() {
        #expect(throws: BrainProposalError.missingArgument("name")) {
            try validator.validate(
                call("open_application", #"{"reason":"no name here"}"#),
                installedApplicationNames: installed
            )
        }
        #expect(throws: BrainProposalError.missingArgument("name")) {
            try validator.validate(
                call("open_application", #"{"name":"   ","reason":"blank"}"#),
                installedApplicationNames: installed
            )
        }
    }

    @Test("A missing reason is rejected so the preview can always explain itself")
    func rejectsMissingReason() {
        #expect(throws: BrainProposalError.missingArgument("reason")) {
            try validator.validate(
                call("open_application", #"{"name":"Spotify"}"#),
                installedApplicationNames: installed
            )
        }
    }

    @Test("Surrounding whitespace in a name is tolerated")
    func trimsName() throws {
        let proposal = try validator.validate(
            call("open_application", #"{"name":"  Spotify  ","reason":"music"}"#),
            installedApplicationNames: installed
        )
        #expect(proposal == .openApplication(name: "Spotify", reason: "music"))
    }

    @Test(
        "Names with paths, suffixes, or control characters are refused",
        arguments: [
            "/Applications/Spotify.app",
            "Spotify.app",
            "Spotify\u{0}",
            "~/Spotify",
        ]
    )
    func rejectsUnsafeNames(name: String) {
        let json = #"{"name":"\#(name)","reason":"x"}"#
        #expect(throws: (any Error).self) {
            try validator.validate(
                call("open_application", json),
                installedApplicationNames: installed
            )
        }
    }

    @Test("An absurdly long name is refused before it reaches the resolver")
    func rejectsOverlongName() {
        let long = String(repeating: "a", count: 200)
        #expect(throws: BrainProposalError.unsafeApplicationName) {
            try validator.validate(
                call("open_application", #"{"name":"\#(long)","reason":"x"}"#),
                installedApplicationNames: installed
            )
        }
    }

    @Test("An empty installed set can never yield an app proposal")
    func rejectsEverythingWhenNothingInstalled() {
        #expect(throws: BrainProposalError.applicationNotInstalled("Spotify")) {
            try validator.validate(
                call("open_application", #"{"name":"Spotify","reason":"x"}"#),
                installedApplicationNames: []
            )
        }
    }

    @Test("An accepted open proposal converts to the existing launch command")
    func convertsToLaunchCommand() throws {
        let proposal = try validator.validate(
            call("open_application", #"{"name":"Spotify","reason":"music"}"#),
            installedApplicationNames: installed
        )
        let command = proposal.parsedApplicationCommand
        #expect(command?.operation == .launchOrActivate)
        #expect(command?.requestedApplicationName == "Spotify")
    }

    @Test("An accepted switch proposal converts to the existing switch command")
    func convertsToSwitchCommand() throws {
        let proposal = try validator.validate(
            call("switch_to_application", #"{"name":"Notes","reason":"running"}"#),
            installedApplicationNames: installed
        )
        #expect(proposal.parsedApplicationCommand?.operation == .switchToRunning)
    }

    @Test("no_supported_action yields no executable command")
    func noSupportedActionHasNoCommand() throws {
        let proposal = try validator.validate(
            call("no_supported_action", #"{"reason":"nope"}"#),
            installedApplicationNames: installed
        )
        #expect(proposal.parsedApplicationCommand == nil)
    }

    // MARK: - Additional adversarial cases

    /// `ApplicationCommandParser` refuses any name containing " and " so that a
    /// single typed line can never be read as two application targets (that
    /// ambiguity is handled by the separate multi-clause sequence parser
    /// instead). The brief's contract requires the brain path to be at least as
    /// strict as the typed path, so this must be refused here too, even though
    /// the brain call only ever carries one `name` field.
    @Test("A name containing the multi-target conjunction is refused")
    func rejectsConjunctionInName() {
        #expect(throws: BrainProposalError.unsafeApplicationName) {
            try validator.validate(
                call(
                    "open_application",
                    #"{"name":"Spotify and Chrome","reason":"x"}"#
                ),
                installedApplicationNames: installed
            )
        }
    }

    /// A tool name that differs from the closed set only by case must not match
    /// `BrainTool(rawValue:)`, which is exact-string. Confirms the check is not
    /// accidentally case-folding somewhere upstream.
    @Test("A tool name differing only by case is treated as unknown")
    func rejectsToolNameCasingVariant() {
        #expect(throws: BrainProposalError.unknownTool("Open_Application")) {
            try validator.validate(
                call("Open_Application", #"{"name":"Spotify","reason":"x"}"#),
                installedApplicationNames: installed
            )
        }
    }

    /// If the model emits `"name": 123` instead of a string, the argument must
    /// be treated as absent rather than coerced by any implicit `"\(value)"`
    /// stringification, which would let non-string JSON values sneak through.
    @Test("A name argument with the right key but a non-string JSON value is rejected")
    func rejectsNonStringNameValue() {
        #expect(throws: BrainProposalError.missingArgument("name")) {
            try validator.validate(
                call("open_application", #"{"name":123,"reason":"x"}"#),
                installedApplicationNames: installed
            )
        }
    }

    /// Same as above for `reason`, and additionally covers a boolean and an
    /// object value to make sure no JSON scalar type is silently accepted.
    @Test(
        "A reason argument with a non-string JSON value is rejected",
        arguments: [
            #"{"name":"Spotify","reason":true}"#,
            #"{"name":"Spotify","reason":{"nested":"x"}}"#,
            #"{"name":"Spotify","reason":42}"#,
        ]
    )
    func rejectsNonStringReasonValue(json: String) {
        #expect(throws: BrainProposalError.missingArgument("reason")) {
            try validator.validate(
                call("open_application", json),
                installedApplicationNames: installed
            )
        }
    }

    /// Matching against the inventory is case-insensitive so the model's
    /// rendering of a name doesn't have to match capitalization exactly, but the
    /// canonical spelling from the inventory is always what gets returned, never
    /// the model's own casing.
    @Test("A name matching only by case still resolves to the inventory's canonical spelling")
    func matchesCaseInsensitively() throws {
        let proposal = try validator.validate(
            call("open_application", #"{"name":"SPOTIFY","reason":"music"}"#),
            installedApplicationNames: installed
        )
        #expect(proposal == .openApplication(name: "Spotify", reason: "music"))
    }

    /// A name that is Unicode-equivalent to an installed name under canonical
    /// decomposition, but not byte-identical (precomposed "é" vs. "e" + a
    /// combining acute accent), must still resolve — and must resolve to the
    /// inventory's own precomposed spelling, not the model's decomposed one.
    @Test("Unicode-normalization-equivalent names resolve to the inventory's spelling")
    func matchesAcrossUnicodeNormalization() throws {
        let precomposed = "Cafe\u{301} Notes"  // "Café Notes", decomposed form
        let canonical = "Café Notes"  // precomposed form, as the inventory holds it
        let json = #"{"name":"\#(precomposed)","reason":"music"}"#
        let proposal = try validator.validate(
            call("open_application", json),
            installedApplicationNames: [canonical]
        )
        #expect(proposal == .openApplication(name: canonical, reason: "music"))
    }
}
