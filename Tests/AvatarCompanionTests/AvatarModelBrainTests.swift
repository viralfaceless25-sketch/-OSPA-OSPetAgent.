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
        case proposals([RawBrainToolCall])
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
    ) async throws -> [RawBrainToolCall] {
        requests.append(request)
        switch behavior {
        case let .proposal(call):
            return [call]
        case let .proposals(calls):
            return calls
        case let .failure(error):
            throw error
        }
    }

    func requestCount() -> Int {
        requests.count
    }
}

private actor ControlledBrainService: LocalBrainService {
    private var continuation: CheckedContinuation<[RawBrainToolCall], Never>?
    private var started = false

    func propose(
        request: String,
        inventory: [InstalledApplicationUsage]
    ) async throws -> [RawBrainToolCall] {
        started = true
        return await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func hasStarted() -> Bool {
        started
    }

    func finishAfterCancellation(
        returning calls: [RawBrainToolCall] = [
            RawBrainToolCall(
                toolName: "no_supported_action",
                argumentsJSON: #"{"reason":"Late result must be ignored."}"#
            )
        ]
    ) {
        continuation?.resume(
            returning: calls
        )
        continuation = nil
    }
}

private actor RecordingIntentRouter: LocalBrainIntentRouting {
    enum Behavior: Sendable {
        case lane(LocalBrainIntentLane)
        case failure(LocalBrainError)
    }

    private let behavior: Behavior
    private var requests: [String] = []

    init(_ behavior: Behavior) {
        self.behavior = behavior
    }

    func route(request: String) async throws -> LocalBrainIntentLane {
        requests.append(request)
        switch behavior {
        case let .lane(lane):
            return lane
        case let .failure(error):
            throw error
        }
    }

    func requestCount() -> Int {
        requests.count
    }
}

private actor ControlledIntentRouter: LocalBrainIntentRouting {
    private var continuation: CheckedContinuation<LocalBrainIntentLane, Never>?
    private var started = false

    func route(request: String) async throws -> LocalBrainIntentLane {
        started = true
        return await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func hasStarted() -> Bool {
        started
    }

    func finishAfterCancellation(returning lane: LocalBrainIntentLane) {
        continuation?.resume(returning: lane)
        continuation = nil
    }
}

private struct FixedChatService: LocalBrainChatService {
    let response: String

    func answer(request: String) async throws -> String {
        response
    }
}

private actor ControlledChatService: LocalBrainChatService {
    private var continuation: CheckedContinuation<String, Never>?
    private var started = false

    func answer(request: String) async throws -> String {
        started = true
        return await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func hasStarted() -> Bool {
        started
    }

    func finishAfterCancellation(returning response: String) {
        continuation?.resume(returning: response)
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
        try? await Task.sleep(nanoseconds: 5_000_000)
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

    private func exactInstalledApplications(
        count: Int
    ) throws -> [ResolvedApplication] {
        let resolver = InstalledApplicationResolver()
        var applications: [ResolvedApplication] = []

        for candidate in resolver.currentIndex().sorted(by: {
            $0.identity.displayName < $1.identity.displayName
        }) {
            guard
                let resolved = try? resolver.resolveExact(
                    named: candidate.identity.displayName
                ),
                resolved.applicationURL.standardizedFileURL
                    == candidate.applicationURL.standardizedFileURL,
                !applications.contains(where: {
                    $0.identity == candidate.identity
                })
            else {
                continue
            }
            applications.append(candidate)
            if applications.count == count { return applications }
        }

        Issue.record("Need \(count) uniquely resolvable installed applications")
        return []
    }

    private func brainApplicationModel(
        target: ResolvedApplication,
        reason: String
    ) -> AvatarModel {
        let usage = InstalledApplicationUsage(
            displayName: target.identity.displayName,
            openCount: 10,
            lastUsedDaysAgo: 0
        )
        let service = RecordingBrainService(
            .proposal(
                RawBrainToolCall(
                    toolName: "open_application",
                    argumentsJSON:
                        #"{"name":"\#(target.identity.displayName)","reason":"\#(reason)"}"#
                )
            )
        )
        return AvatarModel(
            usageSource: FixedUsageSource(inventory: [usage]),
            brainService: service,
            brainIntentRouter: RecordingIntentRouter(.lane(.nativeApp)),
            brainServerController: readyServerController()
        )
    }

    private func rawApplicationCall(
        toolName: String = "open_application",
        target: ResolvedApplication,
        reason: String
    ) throws -> RawBrainToolCall {
        let data = try JSONSerialization.data(
            withJSONObject: [
                "name": target.identity.displayName,
                "reason": reason,
            ],
            options: [.sortedKeys]
        )
        return RawBrainToolCall(
            toolName: toolName,
            argumentsJSON: try #require(String(data: data, encoding: .utf8))
        )
    }

    private func brainModel(
        applications: [ResolvedApplication],
        calls: [RawBrainToolCall]
    ) -> AvatarModel {
        AvatarModel(
            usageSource: FixedUsageSource(
                inventory: applications.map {
                    InstalledApplicationUsage(
                        displayName: $0.identity.displayName,
                        openCount: 10,
                        lastUsedDaysAgo: 0
                    )
                }
            ),
            brainService: RecordingBrainService(.proposals(calls)),
            brainIntentRouter: RecordingIntentRouter(.lane(.nativeApp)),
            brainServerController: readyServerController()
        )
    }

    private func previewBrainApplication(
        with model: AvatarModel
    ) async {
        model.setBrainEnabled(true)
        model.command = "choose the best application for this unusual request"
        model.previewCommand()
        await waitUntil { !model.isBrainThinking }
    }

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
            brainIntentRouter: RecordingIntentRouter(.lane(.nativeApp)),
            brainServerController: readyServerController()
        )
        model.isBrainEnabled = true
        model.command = "do something unusual"

        model.previewCommand()
        await waitUntil { !model.isBrainThinking }

        #expect(await service.requestCount() == 1)
        #expect(model.brainReason == nil)
        #expect(model.brainStatus == "No installed app can do that.")
        #expect(model.pendingApplicationProposal == nil)
    }

    @Test("A weather request is refused honestly without an app proposal")
    func weatherRoutesToUnsupported() async {
        let service = RecordingBrainService(.failure(.unavailable))
        let router = RecordingIntentRouter(.lane(.unsupported))
        let model = AvatarModel(
            usageSource: FixedUsageSource(inventory: inventory),
            brainService: service,
            brainIntentRouter: router,
            brainServerController: readyServerController()
        )
        model.isBrainEnabled = true
        model.command = "what's the weather in Tokyo"

        model.previewCommand()
        await waitUntil { !model.isBrainThinking }

        #expect(await router.requestCount() == 1)
        #expect(await service.requestCount() == 0)
        #expect(model.pendingApplicationProposal == nil)
        #expect(model.pendingTaskSequence == nil)
        #expect(
            model.brainStatus
                == "I can’t browse the web or use current online information yet. I can open or switch Mac apps, or chat about things that don’t need current information."
        )
    }

    @Test("The chat lane publishes text but no action")
    func chatLanePublishesNoAction() async {
        let service = RecordingBrainService(.failure(.unavailable))
        let model = AvatarModel(
            usageSource: FixedUsageSource(inventory: inventory),
            brainService: service,
            brainIntentRouter: RecordingIntentRouter(.lane(.chat)),
            brainChatService: FixedChatService(
                response: "Photosynthesis turns light into stored chemical energy."
            ),
            brainServerController: readyServerController()
        )
        model.isBrainEnabled = true
        model.command = "explain photosynthesis"

        model.previewCommand()
        await waitUntil { !model.isBrainThinking }

        #expect(await service.requestCount() == 0)
        #expect(
            model.brainStatus
                == "Photosynthesis turns light into stored chemical energy."
        )
        #expect(model.pendingApplicationProposal == nil)
        #expect(model.pendingTaskSequence == nil)
        #expect(model.previewedAction == nil)
    }

    @Test("The native app lane still refuses an invalid model tool")
    func nativeLaneStillUsesProposalValidator() async {
        let service = RecordingBrainService(
            .proposal(
                RawBrainToolCall(
                    toolName: "run_shell",
                    argumentsJSON: #"{"reason":"Must be refused."}"#
                )
            )
        )
        let router = RecordingIntentRouter(.lane(.nativeApp))
        let model = AvatarModel(
            usageSource: FixedUsageSource(inventory: inventory),
            brainService: service,
            brainIntentRouter: router,
            brainServerController: readyServerController()
        )
        model.isBrainEnabled = true
        model.command = "run something for me"

        model.previewCommand()
        await waitUntil { !model.isBrainThinking }

        #expect(await router.requestCount() == 1)
        #expect(await service.requestCount() == 1)
        #expect(model.pendingApplicationProposal == nil)
        #expect(model.pendingTaskSequence == nil)
        #expect(model.brainStatus.contains("not allowed"))
    }

    @Test("Disabling natural language ignores a late router result")
    func disablingBrainCancelsIntentRouting() async {
        let service = RecordingBrainService(.failure(.unavailable))
        let router = ControlledIntentRouter()
        let model = AvatarModel(
            usageSource: FixedUsageSource(inventory: inventory),
            brainService: service,
            brainIntentRouter: router,
            brainServerController: readyServerController()
        )
        model.isBrainEnabled = true
        model.command = "choose an app"

        model.previewCommand()
        for _ in 0..<200 {
            if await router.hasStarted() { break }
            await Task.yield()
        }
        #expect(await router.hasStarted())
        model.setBrainEnabled(false)
        await router.finishAfterCancellation(returning: .nativeApp)
        for _ in 0..<10 { await Task.yield() }

        #expect(await service.requestCount() == 0)
        #expect(model.pendingApplicationProposal == nil)
        #expect(model.pendingTaskSequence == nil)
        #expect(model.brainStatus == "Natural language is off. Type exact commands.")
    }

    @Test("Emergency Stop ignores a late chat answer")
    func emergencyStopCancelsChat() async {
        let chat = ControlledChatService()
        let model = AvatarModel(
            usageSource: FixedUsageSource(inventory: inventory),
            brainService: RecordingBrainService(.failure(.unavailable)),
            brainIntentRouter: RecordingIntentRouter(.lane(.chat)),
            brainChatService: chat,
            brainServerController: readyServerController()
        )
        model.isBrainEnabled = true
        model.command = "tell me something"

        model.previewCommand()
        for _ in 0..<200 {
            if await chat.hasStarted() { break }
            await Task.yield()
        }
        #expect(await chat.hasStarted())
        model.emergencyStop()
        await chat.finishAfterCancellation(returning: "Late text must be ignored.")
        for _ in 0..<10 { await Task.yield() }

        #expect(model.pendingApplicationProposal == nil)
        #expect(model.pendingTaskSequence == nil)
        #expect(model.brainStatus == "Emergency stop active. Thinking cancelled.")
    }

    @Test("A brain chain previews every validated step in model order")
    func previewsOrderedBrainChain() async throws {
        let applications = try exactInstalledApplications(count: 2)
        let first = try #require(applications.first)
        let second = try #require(applications.dropFirst().first)
        let firstReason = "Start with the first requested application."
        let secondReason = "Then open the second requested application."
        let model = brainModel(
            applications: applications,
            calls: [
                try rawApplicationCall(target: first, reason: firstReason),
                try rawApplicationCall(target: second, reason: secondReason),
            ]
        )

        await previewBrainApplication(with: model)

        let sequence = try #require(model.pendingTaskSequence)
        #expect(sequence.steps.count == 2)
        #expect(
            sequence.steps.map(\.summary)
                == [
                    "Open \(first.identity.displayName) — \(firstReason)",
                    "Open \(second.identity.displayName) — \(secondReason)",
                ]
        )
        #expect(model.pendingApplicationProposal == nil)
        #expect(model.brainReason == nil)
    }

    @Test("An invalid later brain call publishes no valid prefix")
    func invalidLaterCallRefusesWholeChain() async throws {
        let applications = try exactInstalledApplications(count: 1)
        let first = try #require(applications.first)
        let model = brainModel(
            applications: applications,
            calls: [
                try rawApplicationCall(
                    target: first,
                    reason: "This valid prefix must never be published alone."
                ),
                RawBrainToolCall(
                    toolName: "run_shell",
                    argumentsJSON: #"{"reason":"unsafe"}"#
                ),
            ]
        )

        await previewBrainApplication(with: model)

        #expect(model.pendingTaskSequence == nil)
        #expect(model.pendingApplicationProposal == nil)
    }

    @Test("An unsupported link refuses every executable link in the chain")
    func unsupportedLinkRefusesWholeChain() async throws {
        let applications = try exactInstalledApplications(count: 1)
        let first = try #require(applications.first)
        let model = brainModel(
            applications: applications,
            calls: [
                try rawApplicationCall(
                    target: first,
                    reason: "This app could satisfy only the first part."
                ),
                RawBrainToolCall(
                    toolName: "no_supported_action",
                    argumentsJSON:
                        #"{"reason":"Nothing installed can do the second part."}"#
                ),
            ]
        )

        await previewBrainApplication(with: model)

        #expect(model.pendingTaskSequence == nil)
        #expect(model.pendingApplicationProposal == nil)
        #expect(
            model.brainStatus
                == "I couldn’t prepare every requested step, so nothing was prepared."
        )
    }

    @Test("Disabling the brain clears its pending chain")
    func disablingBrainClearsPendingChain() async throws {
        let applications = try exactInstalledApplications(count: 2)
        let first = try #require(applications.first)
        let second = try #require(applications.dropFirst().first)
        let model = brainModel(
            applications: applications,
            calls: [
                try rawApplicationCall(target: first, reason: "First step."),
                try rawApplicationCall(target: second, reason: "Second step."),
            ]
        )

        await previewBrainApplication(with: model)
        _ = try #require(model.pendingTaskSequence)

        model.setBrainEnabled(false)

        #expect(model.pendingTaskSequence == nil)
        #expect(model.pendingApplicationProposal == nil)
        #expect(model.brainReason == nil)
        #expect(model.brainStatus == "Natural language is off. Type exact commands.")
    }

    @Test("An expired brain chain clears its owned status with the preview")
    func expiredBrainChainClearsStatus() async throws {
        let applications = try exactInstalledApplications(count: 2)
        let first = try #require(applications.first)
        let second = try #require(applications.dropFirst().first)
        let model = brainModel(
            applications: applications,
            calls: [
                try rawApplicationCall(target: first, reason: "First step."),
                try rawApplicationCall(target: second, reason: "Second step."),
            ]
        )

        await previewBrainApplication(with: model)
        let sequence = try #require(model.pendingTaskSequence)
        model.pendingTaskSequence = TaskSequence(
            id: sequence.id,
            steps: sequence.steps,
            createdAt: sequence.createdAt,
            expiresAt: .distantPast
        )
        await waitUntil { model.pendingTaskSequence == nil }

        #expect(model.pendingTaskSequence == nil)
        #expect(model.status == "That request expired. Ask again.")
        #expect(model.taskSequenceStatus == "That request expired. Ask again.")
        #expect(
            model.brainStatus
                == "Natural language is on. Type what you want in ordinary words."
        )
    }

    @Test("Selecting a search result replaces a completed brain chain")
    func searchReplacementClearsBrainChain() async throws {
        let applications = try exactInstalledApplications(count: 3)
        let first = try #require(applications.first)
        let second = try #require(applications.dropFirst().first)
        let searchTarget = try #require(applications.dropFirst(2).first)
        let model = brainModel(
            applications: applications,
            calls: [
                try rawApplicationCall(target: first, reason: "First step."),
                try rawApplicationCall(target: second, reason: "Second step."),
            ]
        )

        await previewBrainApplication(with: model)
        _ = try #require(model.pendingTaskSequence)

        model.openSearch()
        model.approveSearchScopes()
        await waitUntil { model.searchStatus.hasPrefix("Ready.") }
        model.updateSearchQuery(searchTarget.identity.displayName)
        await waitUntil {
            model.searchCandidates.contains {
                $0.item.url.standardizedFileURL
                    == searchTarget.applicationURL.standardizedFileURL
            }
        }
        let replacement = try #require(
            model.searchCandidates.first {
                $0.item.url.standardizedFileURL
                    == searchTarget.applicationURL.standardizedFileURL
            }
        )
        model.selectSearchCandidate(replacement)

        #expect(model.pendingTaskSequence == nil)
        #expect(
            model.pendingApplicationProposal?.application.identity
                == searchTarget.identity
        )
    }

    @Test("A late brain result cannot replace a selected search result")
    func searchReplacementCancelsInFlightBrain() async throws {
        let applications = try exactInstalledApplications(count: 2)
        let brainTarget = try #require(applications.first)
        let searchTarget = try #require(applications.dropFirst().first)
        let service = ControlledBrainService()
        let model = AvatarModel(
            usageSource: FixedUsageSource(
                inventory: applications.map {
                    InstalledApplicationUsage(
                        displayName: $0.identity.displayName,
                        openCount: 10,
                        lastUsedDaysAgo: 0
                    )
                }
            ),
            brainService: service,
            brainIntentRouter: RecordingIntentRouter(.lane(.nativeApp)),
            brainServerController: readyServerController()
        )
        model.setBrainEnabled(true)
        model.command = "choose an app for this unusual request"
        model.previewCommand()
        for _ in 0..<200 {
            if await service.hasStarted() { break }
            await Task.yield()
        }
        #expect(await service.hasStarted())

        model.openSearch()
        model.approveSearchScopes()
        await waitUntil { model.searchStatus.hasPrefix("Ready.") }
        model.updateSearchQuery(searchTarget.identity.displayName)
        await waitUntil {
            model.searchCandidates.contains {
                $0.item.url.standardizedFileURL
                    == searchTarget.applicationURL.standardizedFileURL
            }
        }
        let replacement = try #require(
            model.searchCandidates.first {
                $0.item.url.standardizedFileURL
                    == searchTarget.applicationURL.standardizedFileURL
            }
        )
        model.selectSearchCandidate(replacement)
        let selectedPlanID = try #require(model.pendingApplicationProposal?.plan.id)

        await service.finishAfterCancellation(
            returning: [
                try rawApplicationCall(
                    target: brainTarget,
                    reason: "This late result must be ignored."
                )
            ]
        )
        for _ in 0..<10 { await Task.yield() }

        #expect(model.pendingApplicationProposal?.plan.id == selectedPlanID)
        #expect(
            model.pendingApplicationProposal?.application.identity
                == searchTarget.identity
        )
    }

    @Test("Exact typed commands never reach the brain")
    func deterministicCommandSkipsBrain() async {
        let service = RecordingBrainService(
            .failure(.unavailable)
        )
        let router = RecordingIntentRouter(.lane(.nativeApp))
        let model = AvatarModel(
            usageSource: FixedUsageSource(inventory: inventory),
            brainService: service,
            brainIntentRouter: router,
            brainServerController: readyServerController()
        )
        model.isBrainEnabled = true
        model.command = "open Safari"

        model.previewCommand()
        await Task.yield()

        #expect(await service.requestCount() == 0)
        #expect(await router.requestCount() == 0)
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
        let router = RecordingIntentRouter(.lane(.nativeApp))
        let model = AvatarModel(
            usageSource: FixedUsageSource(inventory: inventory),
            brainService: service,
            brainIntentRouter: router,
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
        #expect(await router.requestCount() == 0)
        #expect(model.computerUsePreview != nil)
        #expect(!model.isBrainThinking)
    }

    @Test("Brain failures use plain language and leave no proposal")
    func unavailableMessage() async {
        let service = RecordingBrainService(.failure(.unavailable))
        let model = AvatarModel(
            usageSource: FixedUsageSource(inventory: inventory),
            brainService: service,
            brainIntentRouter: RecordingIntentRouter(.lane(.nativeApp)),
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
            brainIntentRouter: RecordingIntentRouter(.lane(.nativeApp)),
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

    @Test("Selecting a different app cannot retain a brain proposal's reason")
    func searchReplacementClearsBrainReason() async throws {
        let applications = try exactInstalledApplications(count: 2)
        let brainTarget = try #require(applications.first)
        let searchTarget = try #require(applications.dropFirst().first)
        let reason = "This reason belongs only to the first application."
        let model = brainApplicationModel(target: brainTarget, reason: reason)

        await previewBrainApplication(with: model)
        #expect(
            model.pendingApplicationProposal?.application.identity
                == brainTarget.identity
        )
        #expect(model.brainReason == reason)

        model.openSearch()
        model.approveSearchScopes()
        await waitUntil { model.searchStatus.hasPrefix("Ready.") }
        model.updateSearchQuery(searchTarget.identity.displayName)
        await waitUntil {
            model.searchCandidates.contains {
                $0.item.url.standardizedFileURL
                    == searchTarget.applicationURL.standardizedFileURL
            }
        }
        let replacement = try #require(
            model.searchCandidates.first {
                $0.item.url.standardizedFileURL
                    == searchTarget.applicationURL.standardizedFileURL
            }
        )
        model.selectSearchCandidate(replacement)

        #expect(
            model.pendingApplicationProposal?.application.identity
                == searchTarget.identity
        )
        #expect(model.brainReason == nil)
        #expect(model.brainStatus != reason)
    }

    @Test("Disabling the brain clears its confirmable proposal and reason together")
    func disablingBrainClearsPublishedProposal() async throws {
        let target = try #require(exactInstalledApplications(count: 1).first)
        let reason = "This reason is bound to the brain proposal."
        let model = brainApplicationModel(target: target, reason: reason)

        await previewBrainApplication(with: model)
        #expect(model.pendingApplicationProposal != nil)
        #expect(model.brainReason == reason)

        model.setBrainEnabled(false)

        #expect(model.pendingApplicationProposal == nil)
        #expect(model.applicationProposalExpiresAt == nil)
        #expect(model.brainReason == nil)
        #expect(model.brainStatus == "Natural language is off. Type exact commands.")
    }

    @Test("An expired brain proposal loses its reason when it stops being confirmable")
    func expiryClearsBrainReason() async throws {
        let target = try #require(exactInstalledApplications(count: 1).first)
        let reason = "This reason expires with its proposal."
        let model = brainApplicationModel(target: target, reason: reason)

        await previewBrainApplication(with: model)
        #expect(model.pendingApplicationProposal != nil)
        #expect(model.brainReason == reason)

        model.applicationProposalExpiresAt = .distantPast
        model.confirmApplicationAction()

        #expect(model.pendingApplicationProposal == nil)
        #expect(model.brainReason == nil)
        #expect(model.brainStatus != reason)
    }

    @Test("Emergency stop clears a completed brain proposal and its reason")
    func emergencyStopClearsPublishedProposal() async throws {
        let target = try #require(exactInstalledApplications(count: 1).first)
        let reason = "This reason ends with Emergency Stop."
        let model = brainApplicationModel(target: target, reason: reason)

        await previewBrainApplication(with: model)
        #expect(model.pendingApplicationProposal != nil)
        #expect(model.brainReason == reason)

        model.emergencyStop()

        #expect(model.pendingApplicationProposal == nil)
        #expect(model.applicationProposalExpiresAt == nil)
        #expect(model.brainReason == nil)
        #expect(model.brainStatus == "Emergency stop active. Thinking cancelled.")
    }
}
