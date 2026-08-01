import Foundation

/// Everything needed to launch and supervise a local model server process.
public struct LocalBrainServerConfiguration: Sendable {
    public let executableURL: URL
    public let arguments: [String]
    public let idleShutdownInterval: TimeInterval
    public let startupTimeout: TimeInterval

    public init(
        executableURL: URL,
        arguments: [String],
        idleShutdownInterval: TimeInterval = 300,
        startupTimeout: TimeInterval = 60
    ) {
        self.executableURL = executableURL
        self.arguments = arguments
        self.idleShutdownInterval = idleShutdownInterval
        self.startupTimeout = startupTimeout
    }
}

public enum LocalBrainServerState: Equatable, Sendable {
    case stopped
    case starting
    case ready
    case failed(String)
}

/// Owns the local model server's lifetime.
///
/// The server is started on first need rather than at app launch, and released
/// once idle, because a resident model is several gigabytes: on an 18GB machine a
/// larger model measurably pushed the system into memory compression and swap
/// (free memory hit 0.08GB with 8.68GB compressed; unloading recovered 8.44GB
/// immediately). So the server starts lazily and this controller tracks whether
/// it was the one that started it.
///
/// Only a server this controller itself launched is ever terminated. A server
/// that was already answering when `ensureReady()` was called is adopted --
/// left alone -- because it may belong to the user running their own model
/// server for other work; killing it would be destructive and surprising.
public actor LocalBrainServerController {
    private let launchServer: @Sendable () throws -> Void
    private let terminateServer: @Sendable () -> Void
    private let isHealthy: @Sendable () async -> Bool
    private let now: @Sendable () -> Date
    private let startupTimeout: TimeInterval
    private let idleShutdownInterval: TimeInterval

    private var currentState: LocalBrainServerState = .stopped
    private var didLaunch = false
    private var lastRequestFinishedAt: Date?

    /// Coalesces concurrent `ensureReady()` callers onto a single in-flight
    /// attempt. `ensureReady()` awaits a health-check closure, which is a
    /// suspension point -- and an actor releases its exclusivity across a
    /// suspension point, so two calls that both arrive while the server is
    /// still `.stopped` could otherwise both decide "not healthy, not ready,
    /// I must launch it" and each call `launchServer()`. Tracking "is a
    /// startup already in flight" as explicit state (rather than re-deriving
    /// intent from the health probe each time) closes that window: the second
    /// caller finds this non-nil and awaits the first caller's result instead
    /// of starting its own.
    private var inFlightEnsureReady: Task<LocalBrainServerState, Never>?

    public init(
        launch: @Sendable @escaping () throws -> Void,
        terminate: @Sendable @escaping () -> Void,
        isHealthy: @Sendable @escaping () async -> Bool,
        now: @Sendable @escaping () -> Date,
        startupTimeout: TimeInterval = 60,
        idleShutdownInterval: TimeInterval = 300
    ) {
        self.launchServer = launch
        self.terminateServer = terminate
        self.isHealthy = isHealthy
        self.now = now
        self.startupTimeout = startupTimeout
        self.idleShutdownInterval = idleShutdownInterval
    }

    public var state: LocalBrainServerState { currentState }

    /// Starts the server if needed and waits for it to answer, or adopts one
    /// that is already answering. Safe to call concurrently: every caller
    /// that arrives while a startup attempt is already in flight awaits that
    /// same attempt's result rather than launching its own (see
    /// `inFlightEnsureReady`).
    public func ensureReady() async -> LocalBrainServerState {
        if let inFlight = inFlightEnsureReady {
            return await inFlight.value
        }

        let task = Task { await self.performEnsureReady() }
        inFlightEnsureReady = task
        defer { inFlightEnsureReady = nil }
        return await task.value
    }

    private func performEnsureReady() async -> LocalBrainServerState {
        if currentState == .ready, await isHealthy() {
            return .ready
        }

        // Not (still) ready by our own bookkeeping. Before launching anything,
        // check whether a server is already answering -- ours from an earlier
        // run we lost track of, or someone else's entirely -- and adopt it
        // without setting `didLaunch`, so `shutdown()` will never terminate it.
        if await isHealthy() {
            currentState = .ready
            return .ready
        }

        currentState = .starting
        do {
            try launchServer()
        } catch {
            currentState = .failed("The local assistant could not be started.")
            return currentState
        }
        didLaunch = true

        let deadline = now().addingTimeInterval(startupTimeout)
        while true {
            // Check health before sleeping, and before re-checking the
            // deadline, so a `startupTimeout` of zero resolves on this first
            // pass without ever sleeping: `now()` is an injected closure that,
            // in tests, is a fixed stub rather than the wall clock, so a loop
            // shaped "sleep, then check the deadline" would sleep at least
            // once even when the deadline has already passed, and a loop that
            // only reads the deadline in its `while` condition risks spinning
            // for real wall-clock time forever if that stub never advances.
            // Checking health first, then the deadline, then sleeping avoids
            // both: it always attempts at least one health check, and it
            // never sleeps once the deadline has already been reached.
            if await isHealthy() {
                currentState = .ready
                return .ready
            }
            if now() >= deadline {
                currentState = .failed("The local assistant took too long to start.")
                return currentState
            }
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
    }

    public func noteRequestFinished() {
        lastRequestFinishedAt = now()
    }

    public func shutdownIfIdle() async {
        guard currentState == .ready, let last = lastRequestFinishedAt else {
            return
        }
        guard now().timeIntervalSince(last) >= idleShutdownInterval else {
            return
        }
        shutdown()
    }

    /// Idempotent, and only ever terminates a server this controller itself
    /// launched -- an adopted server (`didLaunch == false`) is left running.
    public func shutdown() {
        guard didLaunch else {
            currentState = .stopped
            return
        }
        terminateServer()
        didLaunch = false
        lastRequestFinishedAt = nil
        currentState = .stopped
    }
}
