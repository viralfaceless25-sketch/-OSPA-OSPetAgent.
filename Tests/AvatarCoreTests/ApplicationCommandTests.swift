import Foundation
import Testing
@testable import AvatarCore

@Suite("Deterministic application commands")
struct ApplicationCommandParserTests {
    private let parser = ApplicationCommandParser()

    @Test(
        "Parses explicit launch commands",
        arguments: ["open Safari", "Launch TextEdit", "start QuickTime Player"]
    )
    func parsesLaunch(input: String) {
        let result = parser.parse(input)
        guard case let .command(command) = result else {
            Issue.record("Expected application command")
            return
        }
        #expect(command.operation == .launchOrActivate)
        #expect(!command.requestedApplicationName.isEmpty)
    }

    @Test(
        "Parses explicit switch commands",
        arguments: ["switch to Notes", "focus Finder", "activate Safari"]
    )
    func parsesSwitch(input: String) {
        let result = parser.parse(input)
        guard case let .command(command) = result else {
            Issue.record("Expected application command")
            return
        }
        #expect(command.operation == .switchToRunning)
    }

    @Test("Leaves contextual focus command for preview composer")
    func preservesContextualCommand() {
        #expect(parser.parse("focus this app") == .notApplicationCommand)
    }

    @Test(
        "Rejects paths, bundles, and multi-actions",
        arguments: [
            "open /Applications/Safari.app",
            "open Safari.app",
            "open Safari and Notes",
        ]
    )
    func rejectsUnsafeTargets(input: String) {
        guard case .rejected = parser.parse(input) else {
            Issue.record("Expected rejected command")
            return
        }
    }

    @Test("Unrelated language is not captured")
    func ignoresUnrelated() {
        #expect(parser.parse("find text") == .notApplicationCommand)
    }
}

@Suite("Native application action planning")
struct ApplicationActionPlannerTests {
    private let planner = ApplicationActionPlanner()
    private let now = Date(timeIntervalSince1970: 3_000)
    private let app = ResolvedApplication(
        identity: AppIdentity(
            bundleIdentifier: "com.apple.TextEdit",
            displayName: "TextEdit"
        ),
        applicationURL: URL(fileURLWithPath: "/Applications/TextEdit.app"),
        isRunning: false
    )

    @Test("Open plan contains one exact native activation step")
    func plansOpen() throws {
        let command = ParsedApplicationCommand(
            operation: .launchOrActivate,
            requestedApplicationName: "TextEdit"
        )
        let proposal = try planner.propose(
            command: command,
            application: app,
            now: now
        )

        #expect(proposal.plan.app == app.identity)
        #expect(proposal.plan.steps.count == 1)
        #expect(
            proposal.plan.steps[0].visibleInteraction
                == .launchOrActivateApplication
        )
        #expect(proposal.profile.capabilities[0].adapter == .nativeAPI)
        #expect(
            proposal.profile.capabilities[0].requiredPermissions.isEmpty
        )
    }

    @Test("Switch refuses an app that is not running")
    func switchRequiresRunning() {
        let command = ParsedApplicationCommand(
            operation: .switchToRunning,
            requestedApplicationName: "TextEdit"
        )

        #expect(
            throws: ApplicationProposalError.switchTargetNotRunning
        ) {
            try planner.propose(
                command: command,
                application: app,
                now: now
            )
        }
    }

    @Test("Explicit confirmation validates exact no-permission consent")
    func validatesConfirmedProposal() throws {
        let command = ParsedApplicationCommand(
            operation: .launchOrActivate,
            requestedApplicationName: "TextEdit"
        )
        let proposal = try planner.propose(
            command: command,
            application: app,
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

        #expect(validated.maximumRisk == .meaningful)
        #expect(validated.consent.oneShot)
    }

    @Test("Observe-only still blocks native app execution")
    func observeOnlyBlocks() throws {
        let command = ParsedApplicationCommand(
            operation: .launchOrActivate,
            requestedApplicationName: "TextEdit"
        )
        let proposal = try planner.propose(
            command: command,
            application: app,
            now: now
        )
        let consent = ConsentGrant(
            planID: proposal.plan.id,
            scopes: [],
            approvedAt: now,
            expiresAt: now.addingTimeInterval(30)
        )

        #expect(throws: PlanValidationError.observeOnly) {
            try PlanValidator().validate(
                plan: proposal.plan,
                profile: proposal.profile,
                consent: consent,
                safety: .initial,
                userConfirmedPreview: true,
                now: now
            )
        }
    }
}
