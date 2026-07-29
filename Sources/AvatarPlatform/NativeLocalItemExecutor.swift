import AppKit
import AvatarCore
import Foundation

public enum NativeLocalItemExecutionOutcome: Equatable, Sendable {
    case succeeded
    case blocked
    case expired
    case targetChanged
    case failed
}

public enum NativeLocalItemState: Equatable, Sendable {
    case missing
    case file
    case folder
}

@MainActor
public protocol NativeLocalItemWorkspace: AnyObject {
    func state(at url: URL) -> NativeLocalItemState
    func open(
        _ url: URL,
        completion: @escaping @MainActor (Bool) -> Void
    )
}

@MainActor
public final class SystemNativeLocalItemWorkspace:
    NativeLocalItemWorkspace
{
    public init() {}

    public func state(at url: URL) -> NativeLocalItemState {
        var isDirectory: ObjCBool = false
        guard
            FileManager.default.fileExists(
                atPath: url.path,
                isDirectory: &isDirectory
            )
        else {
            return .missing
        }
        return isDirectory.boolValue ? .folder : .file
    }

    public func open(
        _ url: URL,
        completion: @escaping @MainActor (Bool) -> Void
    ) {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        configuration.addsToRecentItems = false
        guard
            let handlerURL = NSWorkspace.shared.urlForApplication(
                toOpen: url
            )
        else {
            completion(false)
            return
        }
        NSWorkspace.shared.open(
            [url],
            withApplicationAt: handlerURL,
            configuration: configuration
        ) { _, error in
            Task { @MainActor in
                completion(error == nil)
            }
        }
    }
}

@MainActor
public final class NativeLocalItemExecutor {
    private let workspace: any NativeLocalItemWorkspace

    public init(
        workspace: any NativeLocalItemWorkspace =
            SystemNativeLocalItemWorkspace()
    ) {
        self.workspace = workspace
    }

    public func execute(
        contract: LocalItemOpenExecutionContract,
        emergencyStopped: Bool,
        completion:
            @escaping @MainActor (
                NativeLocalItemExecutionOutcome
            ) -> Void
    ) {
        guard !emergencyStopped else {
            completion(.blocked)
            return
        }
        guard Date() < contract.expiresAt else {
            completion(.expired)
            return
        }

        let item = contract.validated.plan.item
        guard item.kind != .application else {
            completion(.targetChanged)
            return
        }
        let expectedState: NativeLocalItemState =
            item.kind == .folder ? .folder : .file
        guard workspace.state(at: item.url) == expectedState else {
            completion(.targetChanged)
            return
        }

        workspace.open(item.url) { succeeded in
            completion(succeeded ? .succeeded : .failed)
        }
    }
}
