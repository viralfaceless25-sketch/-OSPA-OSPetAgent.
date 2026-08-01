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
        isHealthy: { recorder.healthy },
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
        isHealthy: { recorder.healthy },
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
}
