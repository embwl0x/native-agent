import Foundation
import Testing
@testable import NativeAgentApp
import BackgroundLoops
import protocol BackgroundLoops.LoopRunner
import enum BackgroundLoops.LoopTickOutcome

private typealias CoreBackgroundLoopsManager = BackgroundLoops.BackgroundLoopsManager
// Importing the whole BackgroundLoops module would shadow this app-side
// composition facade with the core manager.  The scoped imports above leave
// the app target's internal type unambiguous to this @testable test target.
private typealias AppBackgroundLoopsManager = NativeAppBackgroundLoopsManager

private struct FailingWatchdogLoop: LoopRunner {
    let loopId = "watchdog_failure_probe"
    let interval: TimeInterval = 86_400

    func tickOutcome() async -> LoopTickOutcome { .failed(error: "deliberate watchdog failure") }
}

private func isolatedWatchdogManager() -> (
    core: CoreBackgroundLoopsManager,
    app: AppBackgroundLoopsManager
) {
    let core = CoreBackgroundLoopsManager()
    return (
        core,
        AppBackgroundLoopsManager(
            coreManager: core,
            assembleLoops: { [] },
            runAutoDoctorAtLaunch: { false },
            runHeartbeatAtLaunch: { false }
        )
    )
}

@Test
func watchdogStatus_decodesSwiftLifecycleSeparatelyFromLegacyLaunchAgent() throws {
    let data = Data("""
    {
      "daemon": "swift",
      "uptimeSeconds": 42,
      "daemonLifecycleStatus": "ok",
      "daemonLifecycleDetail": "Swift background loops are running in NativeAgent.app.",
      "launchAgentStatus": "not_applicable",
      "launchAgentDetail": "NativeAgent.app owns background loops; legacy daemon launch agents are retired.",
      "runningImprovements": 0,
      "runningMissions": 0,
      "repairAvailable": false
    }
    """.utf8)

    let status = try JSONDecoder().decode(NativeAppWatchdogStatus.self, from: data)

    #expect(status.daemon == "swift")
    #expect(status.daemonLifecycleStatus == "ok")
    #expect(status.runtimeBadgeText == "SWIFT")
    #expect(status.runtimeBadgeStatus == "ok")
    #expect(status.runtimeLifecycleStatus == "ok")
    #expect(status.runtimeLifecycleDetail == "Swift background loops are running in NativeAgent.app.")
    #expect(status.launchAgentStatus == "not_applicable")
}

@Test
func watchdogStatus_legacySwiftNotApplicableDoesNotDisplayAsPrimaryLifecycle() throws {
    let data = Data("""
    {
      "daemon": "swift",
      "launchAgentStatus": "not_applicable",
      "launchAgentDetail": "NativeAgent.app owns background loops; legacy daemon launch agents are retired."
    }
    """.utf8)

    let status = try JSONDecoder().decode(NativeAppWatchdogStatus.self, from: data)

    #expect(status.runtimeBadgeStatus == "ok")
    #expect(status.runtimeLifecycleStatus == "ok")
    #expect(status.runtimeLifecycleDetail == "Swift runtime is owned by NativeAgent.app.")
    #expect(status.launchAgentStatus == "not_applicable")
}

@Test
func nativeClientGetWatchdogReadsButDoesNotStartAnInjectedManager() async throws {
    let manager = isolatedWatchdogManager()
    let client = NativeClient(baseURL: "", backgroundLoopsManager: manager.app)

    let status = try await client.getWatchdog()

    #expect(status.daemon == "swift")
    #expect(status.runtimeLifecycleStatus == "stopped")
    #expect(status.runtimeLifecycleDetail == "Swift background loops are not running.")
    #expect(status.launchAgentStatus == "not_applicable")
    #expect(status.lastActivity == nil)
    await manager.app.stop()
}

@Test
func nativeClientGetWatchdogPublishesAFailingLoopAsDegraded() async throws {
    let manager = isolatedWatchdogManager()
    let loop = FailingWatchdogLoop()
    _ = await manager.core.start(loops: [loop])
    guard case .failed(let error) = await manager.core.runTickOnce(loopId: loop.loopId) else {
        Issue.record("the injected watchdog loop did not fail")
        await manager.app.stop()
        return
    }
    #expect(error == "deliberate watchdog failure")

    let status = try await NativeClient(baseURL: "", backgroundLoopsManager: manager.app).getWatchdog()
    #expect(status.runtimeLifecycleStatus == "degraded")
    #expect(status.runtimeBadgeStatus == "warn")
    #expect(status.runtimeLifecycleDetail.contains(loop.loopId))
    #expect(status.lastActivity?.kind == "background_loops")
    #expect(status.repairAvailable)
    await manager.app.stop()
}
