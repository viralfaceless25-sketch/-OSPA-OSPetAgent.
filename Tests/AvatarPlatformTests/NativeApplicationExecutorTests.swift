import AvatarCore
@testable import AvatarPlatform
import Foundation
import Testing

@MainActor
@Suite("Native application executor")
struct NativeApplicationExecutorTests {
    private let now = Date(timeIntervalSince1970: 4_000)

    @Test("Launch command routes only to native launch")
    func routesLaunch() throws {
        let fixture = try makeFixture(
            operation: .launchOrActivate,
            isRunning: false
        )
        let workspace = FakeWorkspace()
        var outcome: ExecutionOutcome?

        NativeApplicationExecutor(workspace: workspace).execute(
            proposal: fixture.proposal,
            contract: fixture.contract,
            emergencyStopped: false
        ) {
            outcome = $0
        }

        #expect(workspace.launchedURLs == [fixture.proposal.application.applicationURL])
        #expect(workspace.activatedBundleIdentifiers.isEmpty)
        #expect(outcome == .succeeded)
    }

    @Test("Open running app routes only to native activation")
    func routesRunningOpenToActivation() throws {
        let fixture = try makeFixture(
            operation: .launchOrActivate,
            isRunning: true
        )
        let workspace = FakeWorkspace()
        var outcome: ExecutionOutcome?

        NativeApplicationExecutor(workspace: workspace).execute(
            proposal: fixture.proposal,
            contract: fixture.contract,
            emergencyStopped: false
        ) {
            outcome = $0
        }

        #expect(
            workspace.activatedBundleIdentifiers
                == [fixture.proposal.application.identity.bundleIdentifier]
        )
        #expect(workspace.launchedURLs.isEmpty)
        #expect(outcome == .succeeded)
    }

    @Test("Emergency stop prevents every native call")
    func stopPreventsCall() throws {
        let fixture = try makeFixture(
            operation: .launchOrActivate,
            isRunning: false
        )
        let workspace = FakeWorkspace()
        var outcome: ExecutionOutcome?

        NativeApplicationExecutor(workspace: workspace).execute(
            proposal: fixture.proposal,
            contract: fixture.contract,
            emergencyStopped: true
        ) {
            outcome = $0
        }

        #expect(workspace.activatedBundleIdentifiers.isEmpty)
        #expect(workspace.launchedURLs.isEmpty)
        #expect(outcome == .denied("Emergency stop is active."))
    }

    @Test("Expired contract prevents every native call")
    func expiryPreventsCall() throws {
        let fixture = try makeFixture(
            operation: .launchOrActivate,
            isRunning: false,
            contractExpiry: Date.distantPast
        )
        let workspace = FakeWorkspace()
        var outcome: ExecutionOutcome?

        NativeApplicationExecutor(workspace: workspace).execute(
            proposal: fixture.proposal,
            contract: fixture.contract,
            emergencyStopped: false
        ) {
            outcome = $0
        }

        #expect(workspace.activatedBundleIdentifiers.isEmpty)
        #expect(workspace.launchedURLs.isEmpty)
        #expect(outcome == .denied("Execution contract expired."))
    }

    @Test("Workspace failure becomes bounded failure outcome")
    func reportsFailure() throws {
        let fixture = try makeFixture(
            operation: .switchToRunning,
            isRunning: true
        )
        let workspace = FakeWorkspace(result: .failed("Synthetic failure."))
        var outcome: ExecutionOutcome?

        NativeApplicationExecutor(workspace: workspace).execute(
            proposal: fixture.proposal,
            contract: fixture.contract,
            emergencyStopped: false
        ) {
            outcome = $0
        }

        #expect(outcome == .failed("Synthetic failure."))
        #expect(workspace.launchedURLs.isEmpty)
    }

    private typealias Fixture = (
        proposal: ApplicationActionProposal,
        contract: ExecutionContract
    )

    private func makeFixture(
        operation: ApplicationOperation,
        isRunning: Bool,
        contractExpiry: Date? = nil
    ) throws -> Fixture {
        let application = ResolvedApplication(
            identity: AppIdentity(
                bundleIdentifier: "com.example.editor",
                displayName: "Example Editor"
            ),
            applicationURL: URL(
                fileURLWithPath: "/Applications/Example Editor.app"
            ),
            isRunning: isRunning
        )
        let command = ParsedApplicationCommand(
            operation: operation,
            requestedApplicationName: application.identity.displayName
        )
        let proposal = try ApplicationActionPlanner().propose(
            command: command,
            application: application,
            now: now
        )
        let consent = ConsentGrant(
            planID: proposal.plan.id,
            scopes: [],
            approvedAt: now,
            expiresAt: now.addingTimeInterval(30)
        )
        let validated = try PlanValidator().validate(
            plan: proposal.plan,
            profile: proposal.profile,
            consent: consent,
            safety: SafetyState(observeOnly: false),
            userConfirmedPreview: true,
            now: now
        )
        let contract = ExecutionContract(
            validatedPlan: validated,
            issuedAt: now,
            expiresAt: contractExpiry ?? Date.distantFuture
        )
        return (proposal, contract)
    }
}

@MainActor
private final class FakeWorkspace: NativeApplicationWorkspace {
    private let result: NativeWorkspaceActionResult
    private(set) var activatedBundleIdentifiers: [String] = []
    private(set) var launchedURLs: [URL] = []

    init(result: NativeWorkspaceActionResult = .succeeded) {
        self.result = result
    }

    func activateRunningApplication(
        bundleIdentifier: String
    ) -> NativeWorkspaceActionResult {
        activatedBundleIdentifiers.append(bundleIdentifier)
        return result
    }

    func launchApplication(
        at url: URL,
        completion: @escaping @MainActor (NativeWorkspaceActionResult) -> Void
    ) {
        launchedURLs.append(url)
        completion(result)
    }
}
