import Foundation
import Testing

@testable import AvatarPlatform

/// Mutable scoreboard shared with the controller's injected closures.
private final class Recorder: @unchecked Sendable {
    var launches = 0
    var terminations = 0
    var healthy = false
    var launchError: (any Error)?
    var now = Date(timeIntervalSince1970: 1_000_000)
}

/// Holds the first health check until a second concurrent check arrives.
/// Calls after the first pair continue immediately.
private actor InitialHealthCheckBarrier {
    private var arrivals = 0
    private var firstArrival: CheckedContinuation<Void, Never>?

    func waitForBothChecks() async {
        arrivals += 1
        guard arrivals == 1 else {
            firstArrival?.resume()
            firstArrival = nil
            return
        }

        await withCheckedContinuation { continuation in
            firstArrival = continuation
        }
    }
}

/// Controller whose server does NOT answer until it is launched. Use this for
/// anything about launching, idle shutdown, or termination — the controller only
/// terminates a server it started itself.
private func makeLaunchingController(
    _ recorder: Recorder,
    startupTimeout: TimeInterval = 5,
    idleShutdownInterval: TimeInterval = 300
) -> LocalBrainServerController {
    LocalBrainServerController(
        launch: {
            recorder.launches += 1
            if let error = recorder.launchError { throw error }
            recorder.healthy = true
        },
        terminate: {
            recorder.terminations += 1
            recorder.healthy = false
        },
        isHealthy: {
            // A genuine suspension point, not just an `async`-typed closure
            // with a synchronous body: without it, two concurrent
            // `ensureReady()` calls are not guaranteed to actually interleave
            // on the actor, which would make a concurrency test pass whether
            // or not the coalescing it is meant to guard actually works.
            await Task.yield()
            return recorder.healthy
        },
        now: { recorder.now },
        startupTimeout: startupTimeout,
        idleShutdownInterval: idleShutdownInterval
    )
}

/// Controller whose server is already answering before it is asked. Use this for
/// adoption behavior.
private func makeController(
    _ recorder: Recorder,
    startupTimeout: TimeInterval = 5,
    idleShutdownInterval: TimeInterval = 300
) -> LocalBrainServerController {
    LocalBrainServerController(
        launch: {
            recorder.launches += 1
            if let error = recorder.launchError { throw error }
        },
        terminate: { recorder.terminations += 1 },
        isHealthy: {
            await Task.yield()
            return recorder.healthy
        },
        now: { recorder.now },
        startupTimeout: startupTimeout,
        idleShutdownInterval: idleShutdownInterval
    )
}

@Suite("Local brain server controller")
struct LocalBrainServerControllerTests {
    @Test("A stopped server is launched once and then reused")
    func startsOnce() async {
        let recorder = Recorder()
        let controller = makeLaunchingController(recorder)

        #expect(await controller.ensureReady() == .ready)
        #expect(await controller.ensureReady() == .ready)
        #expect(recorder.launches == 1)
    }

    @Test("A server already answering is adopted, never launched a second time")
    func adoptsRunningServer() async {
        let recorder = Recorder()
        recorder.healthy = true
        let controller = makeController(recorder)

        #expect(await controller.ensureReady() == .ready)
        #expect(recorder.launches == 0)
        #expect(recorder.terminations == 0)
    }

    @Test("A server this controller did not start is never terminated")
    func leavesAdoptedServerRunning() async {
        let recorder = Recorder()
        recorder.healthy = true
        let controller = makeController(recorder)

        _ = await controller.ensureReady()
        await controller.shutdown()

        #expect(recorder.terminations == 0)
    }

    @Test("A launch failure is reported and never leaves the state as ready")
    func reportsLaunchFailure() async {
        struct Boom: Error {}
        let recorder = Recorder()
        recorder.launchError = Boom()
        let controller = makeLaunchingController(recorder)

        let state = await controller.ensureReady()
        guard case .failed = state else {
            Issue.record("Expected failed state, got \(state)")
            return
        }
    }

    @Test("A server that never becomes healthy times out instead of hanging")
    func timesOutWhenNeverHealthy() async {
        let recorder = Recorder()
        // Launch succeeds but the server never answers.
        let controller = LocalBrainServerController(
            launch: { recorder.launches += 1 },
            terminate: { recorder.terminations += 1 },
            isHealthy: { false },
            now: { recorder.now },
            startupTimeout: 0,
            idleShutdownInterval: 300
        )

        let state = await controller.ensureReady()
        guard case .failed = state else {
            Issue.record("Expected failed state, got \(state)")
            return
        }
    }

    @Test("An idle server is shut down and its memory returned")
    func shutsDownWhenIdle() async {
        let recorder = Recorder()
        let controller = makeLaunchingController(recorder, idleShutdownInterval: 60)

        _ = await controller.ensureReady()
        await controller.noteRequestFinished()

        recorder.now = recorder.now.addingTimeInterval(120)
        await controller.shutdownIfIdle()

        #expect(recorder.terminations == 1)
        #expect(await controller.state == .stopped)
    }

    @Test("A server still inside its idle window is left running")
    func keepsRecentlyUsedServer() async {
        let recorder = Recorder()
        let controller = makeLaunchingController(recorder, idleShutdownInterval: 600)

        _ = await controller.ensureReady()
        await controller.noteRequestFinished()

        recorder.now = recorder.now.addingTimeInterval(60)
        await controller.shutdownIfIdle()

        #expect(recorder.terminations == 0)
        #expect(await controller.state == .ready)
    }

    @Test("Shutdown is idempotent and never terminates a server twice")
    func shutdownIsIdempotent() async {
        let recorder = Recorder()
        let controller = makeLaunchingController(recorder)

        _ = await controller.ensureReady()
        await controller.shutdown()
        await controller.shutdown()

        #expect(recorder.terminations == 1)
    }

    @Test("A server that was never started is not terminated")
    func neverTerminatesUnstartedServer() async {
        let recorder = Recorder()
        let controller = makeLaunchingController(recorder)
        await controller.shutdown()
        #expect(recorder.terminations == 0)
    }

    @Test("A failed-but-launched startup is terminated before a retry launches again")
    func terminatesBeforeRetryingAfterTimeout() async {
        let recorder = Recorder()
        // Launch succeeds (a process starts) but the server never answers, so
        // every attempt times out. Nothing in this closure ever sets
        // `recorder.healthy`.
        let controller = LocalBrainServerController(
            launch: { recorder.launches += 1 },
            terminate: {
                recorder.terminations += 1
                recorder.healthy = false
            },
            isHealthy: {
                await Task.yield()
                return false
            },
            now: { recorder.now },
            startupTimeout: 0,
            idleShutdownInterval: 300
        )

        let first = await controller.ensureReady()
        guard case .failed = first else {
            Issue.record("Expected failed state, got \(first)")
            return
        }
        // Exactly one process outstanding: launched once, nothing terminated
        // yet (there is nothing to terminate before the very first launch).
        #expect(recorder.launches == 1)
        #expect(recorder.terminations == 0)

        let second = await controller.ensureReady()
        guard case .failed = second else {
            Issue.record("Expected failed state, got \(second)")
            return
        }
        // The retry must terminate the first outstanding process before
        // launching a second one -- never two resident processes at once.
        #expect(recorder.launches == 2)
        #expect(recorder.terminations == 1)
    }

    @Test("A self-launched ready server that goes unhealthy is terminated before relaunching")
    func terminatesBeforeRelaunchingAfterGoingUnhealthy() async {
        let recorder = Recorder()
        let controller = makeLaunchingController(recorder)

        #expect(await controller.ensureReady() == .ready)
        #expect(recorder.launches == 1)
        #expect(recorder.terminations == 0)

        // The server we started goes unhealthy without `shutdown()` ever
        // being called -- e.g. it crashed, or a health probe is flaky.
        recorder.healthy = false

        // The retry must terminate the still-tracked first process before
        // launching a replacement.
        #expect(await controller.ensureReady() == .ready)
        #expect(recorder.launches == 2)
        #expect(recorder.terminations == 1)
    }

    @Test("Two concurrent ensureReady calls coalesce into a single launch")
    func concurrentEnsureReadyLaunchesOnce() async {
        let recorder = Recorder()
        let barrier = InitialHealthCheckBarrier()
        let controller = LocalBrainServerController(
            launch: {
                recorder.launches += 1
                recorder.healthy = true
            },
            terminate: { recorder.terminations += 1 },
            isHealthy: {
                await barrier.waitForBothChecks()
                return recorder.healthy
            },
            now: { recorder.now },
            startupTimeout: 0,
            idleShutdownInterval: 300
        )

        await withTaskGroup(of: LocalBrainServerState.self) { group in
            group.addTask { await controller.ensureReady() }
            group.addTask { await controller.ensureReady() }
            for await _ in group {}
        }

        #expect(recorder.launches == 1)
    }

    @Test("Shutdown clears stale outstanding requests before the next server instance")
    func shutdownResetsOutstandingRequests() async {
        let recorder = Recorder()
        let controller = makeLaunchingController(recorder, idleShutdownInterval: 60)

        _ = await controller.ensureReady()
        await controller.noteRequestStarted()
        await controller.shutdown()

        _ = await controller.ensureReady()
        await controller.noteRequestStarted()
        await controller.noteRequestFinished()
        recorder.now = recorder.now.addingTimeInterval(120)
        await controller.shutdownIfIdle()

        #expect(recorder.terminations == 2)
        #expect(await controller.state == .stopped)
    }

    @Test("Replacing a self-owned server clears stale outstanding requests")
    func relaunchResetsOutstandingRequests() async {
        let recorder = Recorder()
        let controller = makeLaunchingController(recorder, idleShutdownInterval: 60)

        _ = await controller.ensureReady()
        await controller.noteRequestStarted()
        await controller.noteRequestStarted()
        recorder.healthy = false

        _ = await controller.ensureReady()
        await controller.noteRequestStarted()
        await controller.noteRequestFinished()
        recorder.now = recorder.now.addingTimeInterval(120)
        await controller.shutdownIfIdle()

        #expect(recorder.terminations == 2)
        #expect(await controller.state == .stopped)
    }

    @Test("An adopted server that flaps unhealthy is never replaced or terminated")
    func adoptedServerFailsClosedUntilItRecovers() async {
        let recorder = Recorder()
        recorder.healthy = true
        let controller = makeController(recorder, startupTimeout: 0)

        #expect(await controller.ensureReady() == .ready)
        recorder.healthy = false

        let unhealthyState = await controller.ensureReady()
        guard case .failed = unhealthyState else {
            Issue.record("Expected failed state, got \(unhealthyState)")
            return
        }
        #expect(recorder.launches == 0)
        #expect(recorder.terminations == 0)

        recorder.healthy = true
        #expect(await controller.ensureReady() == .ready)
        #expect(recorder.launches == 0)
        #expect(recorder.terminations == 0)
    }

    @Test("Tracked requests always finish when their operation throws")
    func trackedRequestFinishesOnThrow() async {
        struct RequestFailure: Error {}

        let recorder = Recorder()
        let controller = makeLaunchingController(recorder, idleShutdownInterval: 0)
        _ = await controller.ensureReady()

        await #expect(throws: RequestFailure.self) {
            try await controller.withTrackedRequest {
                throw RequestFailure()
            }
        }

        await controller.shutdownIfIdle()
        #expect(recorder.terminations == 1)
        #expect(await controller.state == .stopped)
    }

    @Test("Tracked requests always finish when their task is cancelled")
    func trackedRequestFinishesOnCancellation() async {
        let recorder = Recorder()
        let controller = makeLaunchingController(recorder, idleShutdownInterval: 0)
        _ = await controller.ensureReady()

        let request = Task {
            try await controller.withTrackedRequest {
                try await Task.sleep(nanoseconds: .max)
            }
        }
        await Task.yield()
        request.cancel()
        _ = try? await request.value

        await controller.shutdownIfIdle()
        #expect(recorder.terminations == 1)
        #expect(await controller.state == .stopped)
    }

    @Test("shutdownIfIdle refuses to stop a server with a request outstanding, and proceeds once it finishes")
    func idleShutdownWaitsForOutstandingRequest() async {
        let recorder = Recorder()
        let controller = makeLaunchingController(recorder, idleShutdownInterval: 60)

        _ = await controller.ensureReady()
        await controller.noteRequestFinished()

        // A new request begins. `lastRequestFinishedAt` still reflects the
        // *previous* completed request, so as real time passes the idle
        // window elapses even though this request is still live.
        await controller.noteRequestStarted()
        recorder.now = recorder.now.addingTimeInterval(120)
        await controller.shutdownIfIdle()
        #expect(recorder.terminations == 0)
        #expect(await controller.state == .ready)

        // The outstanding request completes; idleness is now genuine once the
        // window elapses again.
        await controller.noteRequestFinished()
        recorder.now = recorder.now.addingTimeInterval(120)
        await controller.shutdownIfIdle()
        #expect(recorder.terminations == 1)
        #expect(await controller.state == .stopped)
    }
}
