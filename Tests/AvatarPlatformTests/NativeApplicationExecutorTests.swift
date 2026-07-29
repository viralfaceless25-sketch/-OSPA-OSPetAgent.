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

@Suite("Installed application metadata policy")
struct InstalledApplicationMetadataPolicyTests {
    @Test("Allows native and Safari web-app package types")
    func supportedPackageTypes() {
        #expect(InstalledApplicationResolver.isSupportedPackageType("APPL"))
        #expect(InstalledApplicationResolver.isSupportedPackageType("AAPL"))
    }

    @Test("Rejects non-application bundles")
    func rejectsOtherPackageTypes() {
        #expect(!InstalledApplicationResolver.isSupportedPackageType("BNDL"))
        #expect(!InstalledApplicationResolver.isSupportedPackageType(nil))
    }

    @Test("Metadata search keeps results inside an approved root")
    func metadataScopeContainment() {
        let root = URL(fileURLWithPath: "/Users/example/Documents")

        #expect(
            LocalMetadataSearchService.isSafelyWithin(
                URL(fileURLWithPath: "/Users/example/Documents/Report.pdf"),
                root: root
            )
        )
        #expect(
            !LocalMetadataSearchService.isSafelyWithin(
                URL(
                    fileURLWithPath:
                        "/Users/example/Documents-Archive/Report.pdf"
                ),
                root: root
            )
        )
    }

    @Test("Metadata search excludes hidden and package internals")
    func metadataPrivacyExclusions() {
        #expect(
            LocalMetadataSearchService.isExcludedPath(
                URL(fileURLWithPath: "/Users/example/Documents/.secret")
            )
        )
        #expect(
            LocalMetadataSearchService.isExcludedPath(
                URL(
                    fileURLWithPath:
                        "/Users/example/Documents/Photos.photoslibrary/private.db"
                )
            )
        )
        #expect(
            !LocalMetadataSearchService.isExcludedPath(
                URL(fileURLWithPath: "/Users/example/Documents/Report.pdf")
            )
        )
    }

    @Test("Metadata query cannot turn wildcard input into a broad scan")
    func metadataPatternEscaping() {
        #expect(
            LocalMetadataSearchService.metadataNamePattern(for: "*?") == nil
        )
        #expect(
            LocalMetadataSearchService.metadataNamePattern(for: "ne*")
                == "*ne\\**"
        )
    }
}

@Suite("Native exact-item fallback")
@MainActor
struct NativeLocalItemExecutorTests {
    @Test("Exact validated URL is the only open request")
    func opensExactURL() throws {
        let workspace = FakeLocalItemWorkspace(state: .file)
        let executor = NativeLocalItemExecutor(workspace: workspace)
        let contract = try makeLocalItemContract()
        var outcome: NativeLocalItemExecutionOutcome?

        executor.execute(
            contract: contract,
            emergencyStopped: false
        ) {
            outcome = $0
        }

        #expect(outcome == .succeeded)
        #expect(workspace.openedURLs == [contract.validated.plan.item.url])
    }

    @Test("Stop, expiry, and identity drift prevent open")
    func preflightBlocks() throws {
        let stoppedWorkspace = FakeLocalItemWorkspace(state: .file)
        var stoppedOutcome: NativeLocalItemExecutionOutcome?
        NativeLocalItemExecutor(workspace: stoppedWorkspace).execute(
            contract: try makeLocalItemContract(),
            emergencyStopped: true
        ) {
            stoppedOutcome = $0
        }
        #expect(stoppedOutcome == .blocked)
        #expect(stoppedWorkspace.openedURLs.isEmpty)

        let expiredWorkspace = FakeLocalItemWorkspace(state: .file)
        var expiredOutcome: NativeLocalItemExecutionOutcome?
        NativeLocalItemExecutor(workspace: expiredWorkspace).execute(
            contract: try makeLocalItemContract(
                contractExpiry: .distantPast
            ),
            emergencyStopped: false
        ) {
            expiredOutcome = $0
        }
        #expect(expiredOutcome == .expired)
        #expect(expiredWorkspace.openedURLs.isEmpty)

        let changedWorkspace = FakeLocalItemWorkspace(state: .folder)
        var changedOutcome: NativeLocalItemExecutionOutcome?
        NativeLocalItemExecutor(workspace: changedWorkspace).execute(
            contract: try makeLocalItemContract(),
            emergencyStopped: false
        ) {
            changedOutcome = $0
        }
        #expect(changedOutcome == .targetChanged)
        #expect(changedWorkspace.openedURLs.isEmpty)
    }

    private func makeLocalItemContract(
        contractExpiry: Date = .distantFuture
    ) throws -> LocalItemOpenExecutionContract {
        let now = Date()
        let item = LocalSearchItem(
            name: "Report.pdf",
            url: URL(fileURLWithPath: "/Users/example/Documents/Report.pdf"),
            kind: .file,
            scope: .documents
        )
        let plan = LocalItemOpenPlan(
            item: item,
            createdAt: now,
            expiresAt: .distantFuture
        )
        let authorization = try LocalSearchScopePolicy().authorize(
            scopes: [.applications, .documents],
            userApproved: true,
            now: now,
            duration: 3_600
        )
        let consent = ConsentGrant(
            planID: plan.id,
            scopes: [],
            approvedAt: now,
            expiresAt: .distantFuture
        )
        let validated = try LocalItemOpenValidator().validate(
            plan: plan,
            authorization: authorization,
            consent: consent,
            safety: SafetyState(observeOnly: false),
            userConfirmedPreview: true,
            now: now
        )
        return LocalItemOpenExecutionContract(
            validated: validated,
            issuedAt: now,
            expiresAt: contractExpiry
        )
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

@MainActor
private final class FakeLocalItemWorkspace: NativeLocalItemWorkspace {
    private let itemState: NativeLocalItemState
    private let openSucceeds: Bool
    private(set) var openedURLs: [URL] = []

    init(
        state: NativeLocalItemState,
        openSucceeds: Bool = true
    ) {
        self.itemState = state
        self.openSucceeds = openSucceeds
    }

    func state(at url: URL) -> NativeLocalItemState {
        itemState
    }

    func open(
        _ url: URL,
        completion: @escaping @MainActor (Bool) -> Void
    ) {
        openedURLs.append(url)
        completion(openSucceeds)
    }
}
