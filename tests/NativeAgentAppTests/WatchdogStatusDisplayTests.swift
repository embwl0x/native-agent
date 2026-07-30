import Foundation
import Testing
@testable import NativeAgentApp

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

    let status = try JSONDecoder().decode(WatchdogStatus.self, from: data)

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

    let status = try JSONDecoder().decode(WatchdogStatus.self, from: data)

    #expect(status.runtimeBadgeStatus == "ok")
    #expect(status.runtimeLifecycleStatus == "ok")
    #expect(status.runtimeLifecycleDetail == "Swift runtime is owned by NativeAgent.app.")
    #expect(status.launchAgentStatus == "not_applicable")
}

@Test
func nativeClientGetWatchdogReadsAppBackgroundLoopManager() async throws {
    await BackgroundLoopsManager.shared.stop()
    defer { Task { await BackgroundLoopsManager.shared.stop() } }

    let status = try await NativeClient(baseURL: "").getWatchdog()

    #expect(status.daemon == "swift")
    #expect(status.runtimeLifecycleStatus == "ok")
    #expect(status.runtimeLifecycleDetail == "Swift background loops are running in NativeAgent.app.")
    #expect(status.launchAgentStatus == "not_applicable")
}
