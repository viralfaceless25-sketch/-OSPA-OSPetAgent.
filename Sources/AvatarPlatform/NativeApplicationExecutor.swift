import AppKit
import AvatarCore
import Foundation

public enum NativeWorkspaceActionResult: Equatable, Sendable {
    case succeeded
    case failed(String)
}

@MainActor
public protocol NativeApplicationWorkspace: AnyObject {
    func activateRunningApplication(
        bundleIdentifier: String
    ) -> NativeWorkspaceActionResult

    func launchApplication(
        at url: URL,
        completion: @escaping @MainActor (NativeWorkspaceActionResult) -> Void
    )
}

@MainActor
public final class SystemNativeApplicationWorkspace:
    NativeApplicationWorkspace
{
    public init() {}

    public func activateRunningApplication(
        bundleIdentifier: String
    ) -> NativeWorkspaceActionResult {
        guard
            let running = NSRunningApplication.runningApplications(
                withBundleIdentifier: bundleIdentifier
            ).first
        else {
            return .failed("Target application is no longer running.")
        }

        return running.activate(options: [.activateAllWindows])
            ? .succeeded
            : .failed("macOS declined application activation.")
    }

    public func launchApplication(
        at url: URL,
        completion: @escaping @MainActor (NativeWorkspaceActionResult) -> Void
    ) {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        configuration.addsToRecentItems = false

        NSWorkspace.shared.openApplication(
            at: url,
            configuration: configuration
        ) { runningApplication, error in
            Task { @MainActor in
                if let error {
                    completion(
                        .failed(
                            "macOS launch failed: \(error.localizedDescription)"
                        )
                    )
                } else if runningApplication != nil {
                    completion(.succeeded)
                } else {
                    completion(
                        .failed("macOS returned no running application.")
                    )
                }
            }
        }
    }
}

@MainActor
public struct NativeApplicationExecutor {
    private let workspace: any NativeApplicationWorkspace

    public init(
        workspace: any NativeApplicationWorkspace =
            SystemNativeApplicationWorkspace()
    ) {
        self.workspace = workspace
    }

    public func execute(
        proposal: ApplicationActionProposal,
        contract: ExecutionContract,
        emergencyStopped: Bool,
        completion: @escaping @MainActor (ExecutionOutcome) -> Void
    ) {
        guard !emergencyStopped else {
            completion(.denied("Emergency stop is active."))
            return
        }
        guard Date() < contract.expiresAt else {
            completion(.denied("Execution contract expired."))
            return
        }
        guard
            contract.validatedPlan.plan.id == proposal.plan.id,
            contract.validatedPlan.plan.app
                == proposal.application.identity
        else {
            completion(.denied("Execution contract target mismatch."))
            return
        }

        switch proposal.command.operation {
        case .switchToRunning:
            activateRunningApplication(
                proposal.application,
                completion: completion
            )
        case .launchOrActivate:
            if proposal.application.isRunning {
                activateRunningApplication(
                    proposal.application,
                    completion: completion
                )
            } else {
                launchApplication(
                    proposal.application,
                    completion: completion
                )
            }
        }
    }

    private func activateRunningApplication(
        _ application: ResolvedApplication,
        completion: @escaping @MainActor (ExecutionOutcome) -> Void
    ) {
        complete(
            workspace.activateRunningApplication(
                bundleIdentifier: application.identity.bundleIdentifier
            ),
            completion: completion
        )
    }

    private func launchApplication(
        _ application: ResolvedApplication,
        completion: @escaping @MainActor (ExecutionOutcome) -> Void
    ) {
        workspace.launchApplication(at: application.applicationURL) { result in
            complete(result, completion: completion)
        }
    }

    private func complete(
        _ result: NativeWorkspaceActionResult,
        completion: @escaping @MainActor (ExecutionOutcome) -> Void
    ) {
        switch result {
        case .succeeded:
            completion(.succeeded)
        case let .failed(reason):
            completion(.failed(reason))
        }
    }
}
