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
