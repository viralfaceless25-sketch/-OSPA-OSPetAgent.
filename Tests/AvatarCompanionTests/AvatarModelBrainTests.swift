import AvatarCore
import AvatarPlatform
import Foundation
import Testing

@testable import AvatarCompanion

private struct FixedUsageSource: ApplicationUsageSource {
    let inventory: [InstalledApplicationUsage]

    func currentInventory() -> [InstalledApplicationUsage] {
        inventory
    }
}

private actor RecordingBrainService: LocalBrainService {
    enum Behavior: Sendable {
        case proposal(RawBrainToolCall)
        case failure(LocalBrainError)
    }

    private let behavior: Behavior
    private var requests: [String] = []

    init(_ behavior: Behavior) {
        self.behavior = behavior
    }

    func propose(
        request: String,
        inventory: [InstalledApplicationUsage]
    ) async throws -> RawBrainToolCall {
        requests.append(request)
        switch behavior {
        case let .proposal(call):
            return call
        case let .failure(error):
            throw error
        }
    }

    func requestCount() -> Int {
        requests.count
    }
}

private actor ControlledBrainService: LocalBrainService {
    private var continuation: CheckedContinuation<RawBrainToolCall, Never>?
    private var started = false

    func propose(
        request: String,
        inventory: [InstalledApplicationUsage]
    ) async throws -> RawBrainToolCall {
        started = true
        return await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func hasStarted() -> Bool {
        started
    }

    func finishAfterCancellation() {
        continuation?.resume(
            returning: RawBrainToolCall(
                toolName: "no_supported_action",
                argumentsJSON: #"{"reason":"Late result must be ignored."}"#
            )
        )
        continuation = nil
    }
}

private func readyServerController() -> LocalBrainServerController {
    LocalBrainServerController(
        launch: {},
        terminate: {},
        isHealthy: { true },
        now: { Date(timeIntervalSince1970: 1_000_000) },
        startupTimeout: 0,
        idleShutdownInterval: 300
    )
}

@MainActor
private func waitUntil(
    _ condition: @MainActor () -> Bool
) async {
    for _ in 0..<200 {
        if condition() { return }
        await Task.yield()
    }
    Issue.record("Timed out waiting for AvatarModel state")
}

@Suite("Avatar model local brain")
@MainActor
struct AvatarModelBrainTests {
    private let inventory = [
        InstalledApplicationUsage(
            displayName: "Test App", openCount: 10, lastUsedDaysAgo: 0
        )
    ]

    @Test("Plain language reaches the brain only after deterministic parsers decline")
    func usesBrainFallback() async {
        let service = RecordingBrainService(
            .proposal(
                RawBrainToolCall(
                    toolName: "no_supported_action",
                    argumentsJSON: #"{"reason":"No installed app can do that."}"#
                )
            )
        )
        let model = AvatarModel(
            usageSource: FixedUsageSource(inventory: inventory),
            brainService: service,
            brainServerController: readyServerController()
        )
        model.isBrainEnabled = true
        model.command = "do something unusual"

        model.previewCommand()
        await waitUntil { !model.isBrainThinking }

        #expect(await service.requestCount() == 1)
        #expect(model.brainReason == "No installed app can do that.")
        #expect(model.pendingApplicationProposal == nil)
    }

    @Test("Exact typed commands never reach the brain")
    func deterministicCommandSkipsBrain() async {
        let service = RecordingBrainService(
            .failure(.unavailable)
        )
        let model = AvatarModel(
            usageSource: FixedUsageSource(inventory: inventory),
            brainService: service,
            brainServerController: readyServerController()
        )
        model.isBrainEnabled = true
        model.brainReason = "Stale reason"
        model.brainStatus = "Stale reason"
        model.command = "open Safari"

        model.previewCommand()
        await Task.yield()

        #expect(await service.requestCount() == 0)
        #expect(!model.isBrainThinking)
        #expect(model.brainReason == nil)
        #expect(
            model.brainStatus
                == "Natural language is on. Type what you want in ordinary words."
        )
    }

    @Test("Deterministic foreground composition stays ahead of the brain")
    func foregroundComposerSkipsBrain() async {
        let service = RecordingBrainService(.failure(.unavailable))
        let model = AvatarModel(
            usageSource: FixedUsageSource(inventory: inventory),
            brainService: service,
            brainServerController: readyServerController(),
            frontmostBundleIdentifier: { "com.ospa.test.editor" }
        )
        model.isBrainEnabled = true
        model.discoveredApp = AppIdentity(
            bundleIdentifier: "com.ospa.test.editor",
            displayName: "Test Editor"
        )
        model.command = "Please focus this app"

        model.previewCommand()
        await Task.yield()

        #expect(await service.requestCount() == 0)
        #expect(model.computerUsePreview != nil)
        #expect(!model.isBrainThinking)
    }

    @Test("Brain failures use plain language and leave no proposal")
    func unavailableMessage() async {
        let service = RecordingBrainService(.failure(.unavailable))
        let model = AvatarModel(
            usageSource: FixedUsageSource(inventory: inventory),
            brainService: service,
            brainServerController: readyServerController()
        )
        model.isBrainEnabled = true
        model.command = "help me choose an app"

        model.previewCommand()
        await waitUntil { !model.isBrainThinking }

        #expect(model.brainStatus == "I can’t think right now. You can still type an exact command.")
        #expect(model.pendingApplicationProposal == nil)
    }

    @Test("Emergency stop cancels in-flight brain work")
    func emergencyStopCancelsBrain() async {
        let service = ControlledBrainService()
        let model = AvatarModel(
            usageSource: FixedUsageSource(inventory: inventory),
            brainService: service,
            brainServerController: readyServerController()
        )
        model.isBrainEnabled = true
        model.command = "keep thinking"

        model.previewCommand()
        for _ in 0..<200 {
            if await service.hasStarted() { break }
            await Task.yield()
        }
        #expect(await service.hasStarted())
        model.emergencyStop()
        await service.finishAfterCancellation()
        for _ in 0..<10 { await Task.yield() }

        #expect(!model.isBrainThinking)
        #expect(model.brainReason == nil)
        #expect(model.brainStatus == "Emergency stop active. Thinking cancelled.")
        #expect(model.pendingApplicationProposal == nil)

        model.resumeObservation()
        #expect(
            model.brainStatus
                == "Natural language is on. Type what you want in ordinary words."
        )
    }
}
