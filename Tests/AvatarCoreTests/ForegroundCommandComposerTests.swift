import Testing
@testable import AvatarCore

@Suite("Foreground-context command composer")
struct ForegroundCommandComposerTests {
    private let composer = ForegroundCommandComposer()
    private let app = AppIdentity(
        bundleIdentifier: "com.example.editor",
        displayName: "Example Editor"
    )

    @Test(
        "Recognizes deterministic local intents",
        arguments: [
            ("Please focus this app", SupportedForegroundIntent.focusApplication),
            ("Save this document", .previewSaveShortcut),
            ("Could you find text?", .previewFindShortcut),
        ]
    )
    func recognizesSupported(
        input: String,
        expected: SupportedForegroundIntent
    ) {
        let result = composer.compose(input, target: app)

        guard case let .supported(composed) = result else {
            Issue.record("Expected supported composition, got \(result)")
            return
        }
        #expect(composed.intent == expected)
        #expect(composed.target == app)
        #expect(!composed.steps.isEmpty)
        #expect(composed.steps.count == composed.effectPreviews.count)
    }

    @Test("Multiple intents are rejected as ambiguous")
    func rejectsMultipleIntents() {
        let result = composer.compose(
            "Focus the app and save",
            target: app
        )

        guard case let .ambiguous(reason) = result else {
            Issue.record("Expected ambiguous composition")
            return
        }
        #expect(reason.contains("multiple supported intents"))
    }

    @Test("High-impact verbs are rejected before planning")
    func rejectsHighImpactVerb() {
        let result = composer.compose(
            "Save and then send it",
            target: app
        )

        guard case let .unsupported(reason) = result else {
            Issue.record("Expected unsupported composition")
            return
        }
        #expect(reason.contains("external effect"))
        #expect(reason.contains("send"))
    }

    @Test("Unknown request explains current allowlist")
    func explainsUnsupported() {
        let result = composer.compose(
            "Make the canvas blue",
            target: app
        )

        guard case let .unsupported(reason) = result else {
            Issue.record("Expected unsupported composition")
            return
        }
        #expect(reason.contains("Current allowlist"))
    }

    @Test("Token matching does not infer from similar words")
    func avoidsSubstringInference() {
        let result = composer.compose(
            "Show saved items",
            target: app
        )

        guard case .unsupported = result else {
            Issue.record("Expected unsupported composition")
            return
        }
    }

    @Test("Save preview produces exact illustrative shortcut")
    func saveProducesExactSteps() {
        let result = composer.compose(
            "preview save",
            target: app
        )

        guard case let .supported(composed) = result else {
            Issue.record("Expected supported composition")
            return
        }
        #expect(
            composed.steps == [
                .activateTargetApplication,
                .keyboardShortcut(key: "S", modifiers: [.command]),
            ]
        )
        #expect(composed.effectPreviews[1].contains("not learned"))
    }
}
