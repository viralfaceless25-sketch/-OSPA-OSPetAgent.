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
            // A JSON *escape sequence* for NUL, not a literal NUL byte: an
            // unescaped control byte in the JSON text itself is invalid JSON
            // and would be caught by decodeArguments before ever reaching
            // the name-shape guard this test means to exercise.
            "Spotify\\u0000",
            "~/Spotify",
        ]
    )
    func rejectsUnsafeNames(name: String) {
        let json = #"{"name":"\#(name)","reason":"x"}"#
        #expect(throws: BrainProposalError.unsafeApplicationName) {
            try validator.validate(
                call("open_application", json),
                installedApplicationNames: installed
            )
        }
    }

    /// The zero-width space sits at U+200B, but unlike the other Cf format
    /// characters this guard exists for, Foundation's `.whitespaces` /
    /// `.whitespacesAndNewlines` classify it as trimmable whitespace. Placed
    /// at the edge of a name it would simply be trimmed away before this
    /// guard runs at all (the same as an ordinary trailing space, and just as
    /// harmless there) -- so this test places it mid-name, where trimming
    /// cannot remove it and the control/format-character guard is what has
    /// to catch it.
    @Test("A name containing a zero-width space is refused")
    func rejectsZeroWidthSpaceInName() {
        let name = "Spo\u{200B}tify"
        #expect(throws: BrainProposalError.unsafeApplicationName) {
            try validator.validate(
                call("open_application", #"{"name":"\#(name)","reason":"x"}"#),
                installedApplicationNames: installed
            )
        }
    }

    @Test("A name containing a right-to-left override character is refused")
    func rejectsRightToLeftOverrideInName() {
        let name = "Spotify\u{202E}"
        #expect(throws: BrainProposalError.unsafeApplicationName) {
            try validator.validate(
                call("open_application", #"{"name":"\#(name)","reason":"x"}"#),
                installedApplicationNames: installed
            )
        }
    }

    /// Mirrors `ApplicationCommandParser`'s refusal of the deictic phrase
    /// "this app" (ApplicationCommand.swift:49-51). It refers to whatever is
    /// currently focused, not a literal application identity, so it must be
    /// refused even when an installed application happens to be named
    /// exactly that.
    @Test("The deictic phrase \"this app\" is refused even when literally installed")
    func rejectsThisAppName() {
        #expect(throws: BrainProposalError.unsafeApplicationName) {
            try validator.validate(
                call("open_application", #"{"name":"This App","reason":"x"}"#),
                installedApplicationNames: ["This App"]
            )
        }
    }

    /// Regression test: an unsafe `name` must be reported as such even when
    /// `reason` is also absent. Before this was fixed, `name` was never
    /// shape-checked until after `reason` had already been extracted, so this
    /// call reported `missingArgument("reason")` and masked the real,
    /// more serious problem: a path in the name.
    @Test("An unsafe name is reported even when reason is also missing")
    func unsafeNameIsNotMaskedByMissingReason() {
        #expect(throws: BrainProposalError.unsafeApplicationName) {
            try validator.validate(
                call("open_application", #"{"name":"/etc/passwd"}"#),
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
    /// strict as the typed path, so this must be refused here too, even when
    /// the name is the exact, real display name of an installed application --
    /// otherwise the guard's only observable effect would be which error gets
    /// thrown, not whether the call is accepted.
    @Test("A name containing the multi-target conjunction is refused even when it matches an installed app")
    func rejectsConjunctionEvenWhenNameMatchesInstalledApp() {
        let installedWithConjunction: Set<String> = ["Bed and Breakfast Manager"]
        #expect(throws: BrainProposalError.unsafeApplicationName) {
            try validator.validate(
                call(
                    "open_application",
                    #"{"name":"Bed and Breakfast Manager","reason":"x"}"#
                ),
                installedApplicationNames: installedWithConjunction
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

    /// An unknown tool name is echoed into the thrown error, and that error
    /// may eventually reach diagnostics or UI, so a control character in it
    /// must be stripped rather than carried through verbatim.
    @Test("A control character in an unknown tool name is stripped before it is echoed")
    func sanitizesControlCharacterInUnknownToolName() {
        #expect(throws: BrainProposalError.unknownTool("delete_everything")) {
            try validator.validate(
                call("delete\u{0}_everything", #"{"name":"Spotify","reason":"x"}"#),
                installedApplicationNames: installed
            )
        }
    }

    /// Same concern as above, for length rather than content: an unbounded
    /// tool name must not be echoed unbounded.
    @Test("An overlong unknown tool name is truncated before it is echoed")
    func truncatesOverlongUnknownToolName() {
        let long = String(repeating: "z", count: 200)
        #expect(throws: BrainProposalError.unknownTool(String(long.prefix(80)))) {
            try validator.validate(
                call(long, #"{"name":"Spotify","reason":"x"}"#),
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
        let decomposed = "Cafe\u{301} Notes"  // "Café Notes" as "e" + combining acute accent
        let canonical = "Café Notes"  // precomposed form, as the inventory holds it
        let json = #"{"name":"\#(decomposed)","reason":"music"}"#
        let proposal = try validator.validate(
            call("open_application", json),
            installedApplicationNames: [canonical]
        )
        #expect(proposal == .openApplication(name: canonical, reason: "music"))
    }

    // MARK: - Reason validation (the consent-dialog text)

    /// Regression test for a verified finding: a 20,022-character `reason`
    /// containing a bidi override and control characters was accepted
    /// verbatim by an earlier version of this validator. `reason` is the one
    /// piece of untrusted model text that reaches a human at the moment they
    /// decide whether to authorize an action, so it must be validated at
    /// least as strictly as `name`.
    @Test("A reason containing a right-to-left override character is refused")
    func rejectsBidiOverrideReason() {
        let reason = "Safe\u{202E}gnihtemos"
        #expect(throws: BrainProposalError.unsafeReason) {
            try validator.validate(
                call("open_application", #"{"name":"Spotify","reason":"\#(reason)"}"#),
                installedApplicationNames: installed
            )
        }
    }

    @Test("A reason containing a control character is refused")
    func rejectsControlCharacterReason() {
        // A JSON escape sequence for NUL, not a literal NUL byte -- see the
        // matching comment on rejectsUnsafeNames for why that distinction
        // matters for actually reaching the guard under test. Built by
        // concatenation, with the backslash produced by an explicit `\\`
        // escape, so the six literal characters land in the JSON text as a
        // NUL escape sequence rather than an actual NUL byte.
        let json =
            #"{"name":"Spotify","reason":"bad"# + "\\u0000" + #"reason"}"#
        #expect(throws: BrainProposalError.unsafeReason) {
            try validator.validate(
                call("open_application", json),
                installedApplicationNames: installed
            )
        }
    }

    @Test("An absurdly long reason is refused before it can reach a consent dialog")
    func rejectsOverlongReason() {
        let long = String(repeating: "a", count: 20_022)
        #expect(throws: BrainProposalError.unsafeReason) {
            try validator.validate(
                call("open_application", #"{"name":"Spotify","reason":"\#(long)"}"#),
                installedApplicationNames: installed
            )
        }
    }

    /// `no_supported_action` carries no `name`, but its `reason` is shown to
    /// the user just the same, so it must get the identical guard.
    @Test("no_supported_action's reason is validated the same way as an app-targeting call's")
    func rejectsUnsafeReasonForNoSupportedAction() {
        let long = String(repeating: "a", count: 300)
        #expect(throws: BrainProposalError.unsafeReason) {
            try validator.validate(
                call("no_supported_action", #"{"reason":"\#(long)"}"#),
                installedApplicationNames: installed
            )
        }
    }
}
