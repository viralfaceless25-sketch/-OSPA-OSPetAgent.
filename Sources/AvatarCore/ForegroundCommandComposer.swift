import Foundation

public enum SupportedForegroundIntent: String, Equatable, Sendable {
    case focusApplication
    case previewSaveShortcut
    case previewFindShortcut
}

public struct ComposedForegroundIntent: Equatable, Sendable {
    public let intent: SupportedForegroundIntent
    public let target: AppIdentity
    public let title: String
    public let capabilityID: String
    public let steps: [VisibleInteraction]
    public let effectPreviews: [String]

    public init(
        intent: SupportedForegroundIntent,
        target: AppIdentity,
        title: String,
        capabilityID: String,
        steps: [VisibleInteraction],
        effectPreviews: [String]
    ) {
        self.intent = intent
        self.target = target
        self.title = title
        self.capabilityID = capabilityID
        self.steps = steps
        self.effectPreviews = effectPreviews
    }
}

public enum ForegroundComposition: Equatable, Sendable {
    case supported(ComposedForegroundIntent)
    case ambiguous(reason: String)
    case unsupported(reason: String)
}

/// Small deterministic allowlist. It performs no inference or external request.
public struct ForegroundCommandComposer: Sendable {
    public init() {}

    public func compose(
        _ input: String,
        target: AppIdentity
    ) -> ForegroundComposition {
        let tokens = normalizedTokens(input)

        guard !tokens.isEmpty else {
            return .unsupported(
                reason:
                    "Enter a request such as “focus this app”, “preview save”, or “preview find”."
            )
        }

        let blocked = tokens.intersection([
            "close", "delete", "email", "erase", "publish", "quit", "send",
            "submit", "upload",
        ])
        if let first = blocked.sorted().first {
            return .unsupported(
                reason:
                    "“\(first)” may cause a meaningful external effect and is not in the preview allowlist."
            )
        }

        var matches: [SupportedForegroundIntent] = []
        if tokens.contains("focus") || tokens.contains("activate") {
            matches.append(.focusApplication)
        }
        if tokens.contains("save") || tokens.contains("saving") {
            matches.append(.previewSaveShortcut)
        }
        if tokens.contains("find") || tokens.contains("search") {
            matches.append(.previewFindShortcut)
        }

        guard matches.count <= 1 else {
            return .ambiguous(
                reason:
                    "Request contains multiple supported intents. Ask for focus, save preview, or find preview separately."
            )
        }
        guard let match = matches.first else {
            return .unsupported(
                reason:
                    "No supported local intent found. Current allowlist: focus app, preview save, preview find."
            )
        }

        return .supported(makeIntent(match, target: target))
    }

    private func normalizedTokens(_ input: String) -> Set<String> {
        let words = input.lowercased().split {
            !$0.isLetter && !$0.isNumber
        }
        return Set(words.map(String.init))
    }

    private func makeIntent(
        _ intent: SupportedForegroundIntent,
        target: AppIdentity
    ) -> ComposedForegroundIntent {
        switch intent {
        case .focusApplication:
            return ComposedForegroundIntent(
                intent: intent,
                target: target,
                title: "Focus \(target.displayName)",
                capabilityID: "local.preview.focus",
                steps: [.activateTargetApplication],
                effectPreviews: [
                    "\(target.displayName) would become the foreground app."
                ]
            )
        case .previewSaveShortcut:
            return ComposedForegroundIntent(
                intent: intent,
                target: target,
                title: "Illustrative save preview",
                capabilityID: "local.preview.command-s",
                steps: [
                    .activateTargetApplication,
                    .keyboardShortcut(key: "S", modifiers: [.command]),
                ],
                effectPreviews: [
                    "\(target.displayName) would become the foreground app.",
                    "Command-S would be sent once. Support is illustrative, not learned or guaranteed.",
                ]
            )
        case .previewFindShortcut:
            return ComposedForegroundIntent(
                intent: intent,
                target: target,
                title: "Illustrative find preview",
                capabilityID: "local.preview.command-f",
                steps: [
                    .activateTargetApplication,
                    .keyboardShortcut(key: "F", modifiers: [.command]),
                ],
                effectPreviews: [
                    "\(target.displayName) would become the foreground app.",
                    "Command-F would be sent once. Support is illustrative, not learned or guaranteed.",
                ]
            )
        }
    }
}
