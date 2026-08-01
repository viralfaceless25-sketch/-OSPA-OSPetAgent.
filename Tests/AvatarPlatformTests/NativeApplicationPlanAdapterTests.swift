import AvatarCore
@testable import AvatarPlatform
import Foundation
import Testing

@MainActor
@Suite("Native application plan adapter")
struct NativeApplicationPlanAdapterTests {
    private let now = Date(timeIntervalSince1970: 7_000)

    @Test("A confirmed chain activates distinct targets without foreground preconditions")
    func activatesDistinctTargetsInOrder() async throws {
        let applications = [
            application("com.example.first", "First", isRunning: false),
            application("com.example.second", "Second", isRunning: false),
        ]
        let validated = try validatedSequence(
            applications.map {
                ParsedApplicationCommand(
                    operation: .launchOrActivate,
                    requestedApplicationName: $0.identity.displayName
                )
            },
            applications: applications
        )
        let workspace = RecordingNativeWorkspace()
        workspace.activationResult = .failed("Not running.")
        let adapter = NativeApplicationPlanAdapter(
            workspace: workspace,
            applicationURL: { bundleIdentifier in
                URL(fileURLWithPath: "/Applications/\(bundleIdentifier).app")
            },
            consentLedger: ConsentUseLedger(),
            isEmergencyStopped: { false },
            now: { Date(timeIntervalSince1970: 7_000) }
        )

        let result = await TaskSequenceRunner().run(
            validated,
            adapter: adapter,
            isEmergencyStopped: { false },
            now: { Date(timeIntervalSince1970: 7_000) }
        )

        #expect(result.outcomes.map(\.outcome) == [.succeeded, .succeeded])
        #expect(
            workspace.activationCalls
                == ["com.example.first", "com.example.second"]
        )
        #expect(
            workspace.launchCalls.map(\.lastPathComponent)
                == ["com.example.first.app", "com.example.second.app"]
        )
    }

    @Test("A switch step never relaunches an app that stopped after preview")
    func switchDoesNotRelaunchStoppedTarget() async throws {
        let target = application(
            "com.example.running",
            "Running",
            isRunning: true
        )
        let validated = try validatedSequence(
            [
                ParsedApplicationCommand(
                    operation: .switchToRunning,
                    requestedApplicationName: target.identity.displayName
                )
            ],
            applications: [target]
        )
        let workspace = RecordingNativeWorkspace()
        workspace.activationResult = .failed("Target is no longer running.")
        let adapter = NativeApplicationPlanAdapter(
            workspace: workspace,
            applicationURL: { _ in
                URL(fileURLWithPath: "/Applications/MustNotLaunch.app")
            },
            consentLedger: ConsentUseLedger(),
            isEmergencyStopped: { false },
            now: { Date(timeIntervalSince1970: 7_000) }
        )

        let result = await TaskSequenceRunner().run(
            validated,
            adapter: adapter,
            isEmergencyStopped: { false },
            now: { Date(timeIntervalSince1970: 7_000) }
        )

        #expect(
            result.outcomes.map(\.outcome)
                == [.failed("Target is no longer running.")]
        )
        #expect(workspace.launchCalls.isEmpty)
    }

    @Test("Emergency Stop is rechecked inside the native adapter")
    func emergencyStopPreventsNativeCall() async throws {
        let target = application("com.example.target", "Target", isRunning: false)
        let validated = try validatedSequence(
            [
                ParsedApplicationCommand(
                    operation: .launchOrActivate,
                    requestedApplicationName: target.identity.displayName
                )
            ],
            applications: [target]
        )
        let workspace = RecordingNativeWorkspace()
        let adapter = NativeApplicationPlanAdapter(
            workspace: workspace,
            applicationURL: { _ in nil },
            consentLedger: ConsentUseLedger(),
            isEmergencyStopped: { true },
            now: { Date(timeIntervalSince1970: 7_000) }
        )

        let result = await TaskSequenceRunner().run(
            validated,
            adapter: adapter,
            isEmergencyStopped: { false },
            now: { Date(timeIntervalSince1970: 7_000) }
        )

        #expect(
            result.outcomes.map(\.outcome)
                == [.denied("Emergency stop is active.")]
        )
        #expect(workspace.activationCalls.isEmpty)
        #expect(workspace.launchCalls.isEmpty)
    }

    private func application(
        _ bundleIdentifier: String,
        _ displayName: String,
        isRunning: Bool
    ) -> ResolvedApplication {
        ResolvedApplication(
            identity: AppIdentity(
                bundleIdentifier: bundleIdentifier,
                displayName: displayName
            ),
            applicationURL: URL(
                fileURLWithPath: "/Applications/\(displayName).app"
            ),
            isRunning: isRunning
        )
    }

    private func validatedSequence(
        _ commands: [ParsedApplicationCommand],
        applications: [ResolvedApplication]
    ) throws -> ValidatedTaskSequence {
        let planner = ApplicationActionPlanner()
        let steps = try zip(commands, applications).map { command, application in
            let proposal = try planner.propose(
                command: command,
                application: application,
                now: now
            )
            return SequencedPlan(
                summary: application.identity.displayName,
                plan: proposal.plan,
                profile: proposal.profile
            )
        }
        return try TaskSequenceValidator().validate(
            sequence: TaskSequence(
                steps: steps,
                createdAt: now,
                expiresAt: now.addingTimeInterval(60)
            ),
            safety: SafetyState(observeOnly: false),
            userConfirmed: true,
            now: now
        )
    }
}

@MainActor
private final class RecordingNativeWorkspace: NativeApplicationWorkspace {
    var activationResult: NativeWorkspaceActionResult = .succeeded
    var launchResult: NativeWorkspaceActionResult = .succeeded
    private(set) var activationCalls: [String] = []
    private(set) var launchCalls: [URL] = []

    func activateRunningApplication(
        bundleIdentifier: String
    ) -> NativeWorkspaceActionResult {
        activationCalls.append(bundleIdentifier)
        return activationResult
    }

    func launchApplication(
        at url: URL,
        completion: @escaping @MainActor (NativeWorkspaceActionResult) -> Void
    ) {
        launchCalls.append(url)
        completion(launchResult)
    }
}
