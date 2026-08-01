import AppKit
import AvatarCore
import Foundation

/// Executes the exact native application plans produced by
/// `ApplicationActionPlanner` through the same `CapabilityAdapter` seam used by
/// `TaskSequenceRunner`.
///
/// Unlike foreground keyboard/Accessibility input, launching or activating an
/// app must not require that app to already be foreground. This adapter accepts
/// only the two closed native application interactions and preserves their
/// distinction: a switch never relaunches a target that stopped after preview.
@MainActor
public final class NativeApplicationPlanAdapter: CapabilityAdapter {
    public nonisolated let kind: AdapterKind = .nativeAPI

    private let workspace: any NativeApplicationWorkspace
    private let applicationURL: (String) -> URL?
    private let consentLedger: ConsentUseLedger
    private let isEmergencyStopped: @MainActor () -> Bool
    private let now: @MainActor () -> Date

    public init(
        workspace: any NativeApplicationWorkspace =
            SystemNativeApplicationWorkspace(),
        applicationURL: @escaping (String) -> URL? = { bundleIdentifier in
            NSWorkspace.shared.urlForApplication(
                withBundleIdentifier: bundleIdentifier
            )
        },
        consentLedger: ConsentUseLedger = ConsentUseLedger(),
        isEmergencyStopped: @MainActor @escaping () -> Bool,
        now: @MainActor @escaping () -> Date = { Date() }
    ) {
        self.workspace = workspace
        self.applicationURL = applicationURL
        self.consentLedger = consentLedger
        self.isEmergencyStopped = isEmergencyStopped
        self.now = now
    }

    public func execute(_ contract: ExecutionContract) async -> ExecutionOutcome {
        guard !isEmergencyStopped() else {
            return .denied("Emergency stop is active.")
        }
        guard now() < contract.expiresAt else {
            return .denied("Execution contract expired.")
        }
        guard contract.validatedPlan.consent.scopes.isEmpty else {
            return .denied("Native application actions do not need extra permission.")
        }

        let plan = contract.validatedPlan.plan
        guard plan.steps.count == 1, let step = plan.steps.first,
            step.targetBundleIdentifier == plan.app.bundleIdentifier
        else {
            return .denied("That native application plan changed before it could run.")
        }
        guard await consentLedger.consume(contract.validatedPlan.consent) else {
            return .denied("Consent already used.")
        }

        // Recheck after crossing the actor boundary to consume consent.
        guard !isEmergencyStopped() else {
            return .denied("Emergency stop is active.")
        }
        guard now() < contract.expiresAt else {
            return .denied("Execution contract expired.")
        }

        let target = plan.app.bundleIdentifier
        switch step.visibleInteraction {
        case .activateTargetApplication:
            return Self.outcome(
                for: workspace.activateRunningApplication(
                    bundleIdentifier: target
                )
            )
        case .launchOrActivateApplication:
            if case .succeeded = workspace.activateRunningApplication(
                bundleIdentifier: target
            ) {
                return .succeeded
            }
            guard let url = applicationURL(target) else {
                return .failed("Couldn’t find that app on this Mac.")
            }
            return await withCheckedContinuation { continuation in
                workspace.launchApplication(at: url) { result in
                    continuation.resume(returning: Self.outcome(for: result))
                }
            }
        case .accessibilityPress, .keyboardShortcut, .none:
            return .denied("That step is not a native application action.")
        }
    }

    private static func outcome(
        for result: NativeWorkspaceActionResult
    ) -> ExecutionOutcome {
        switch result {
        case .succeeded:
            .succeeded
        case let .failed(reason):
            .failed(reason)
        }
    }
}
