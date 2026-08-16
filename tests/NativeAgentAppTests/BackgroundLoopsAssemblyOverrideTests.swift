// U5 W-D fix-round (gpt-5.5 NEEDS_FIX): the 3600s tick-timeout override for
// the "memory_consolidation" slot must be proven on the loop PRODUCTION
// registers. assembleAllLoops() registers what
// BackgroundLoopsAssembly.makeMemoryConsolidationLoop returns —
// MemoryConsolidationHygieneRunner. Resolve
// through the factory (the exact expression assembleAllLoops calls) and
// assert through `any LoopRunner` so the pin exercises the dynamic-dispatch
// path the scheduler's `tickTimeoutOverride ?? tickTimeout` resolution uses.

import Foundation
import Testing
import BackgroundLoops
@testable import NativeAgentApp

@Test func assembled_memory_consolidation_loop_overrides_tick_timeout_to_3600() throws {
    let tmp = FileManager.default.temporaryDirectory
        .appendingPathComponent("AssemblyOverrideTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tmp) }

    let assembled: any LoopRunner =
        BackgroundLoopsAssembly.makeMemoryConsolidationLoop(dataRoot: tmp)
    #expect(assembled.loopId == "memory_consolidation")
    #expect(
        assembled.tickTimeoutOverride == 3600,
        "the loop production registers for memory_consolidation must override the scheduler's 300s default"
    )
}

@Test func periodic_cognition_integrity_cadences_are_pinned() throws {
    // The fast microcycle is event-driven and intentionally has no periodic
    // factory. Only the remaining maintenance and replay integrity cadences are
    // pinned here; the production exclusion and live settlement path are
    // proved in CognitiveTurnKindPropagationTests.
    let maintenance: any LoopRunner = BackgroundLoopsAssembly.makeCognitionMaintenanceLoop()
    let replay: any LoopRunner = BackgroundLoopsAssembly.makeCognitionReplayLoop()

    #expect(maintenance.loopId == "cognition_maintenance")
    #expect(
        maintenance.interval == 24 * 60 * 60,
        "maintenance is exact-deadline driven; the periodic owner is only a slow integrity sweep"
    )
    #expect(replay.loopId == "cognition_replay")
    #expect(
        replay.interval == 24 * 60 * 60,
        "replay is event-driven; the periodic owner is only a slow integrity sweep"
    )
}

@Test func github_tracking_loop_is_manager_owned_and_inert_without_config() async throws {
    let tmp = FileManager.default.temporaryDirectory
        .appendingPathComponent("GitHubTrackingLoopTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tmp) }

    let loop: any EventDeadlineLoopRunner = BackgroundLoopsAssembly.makeGitHubTrackingLoop(
        dataRoot: tmp,
        intervalSeconds: 42
    )
    #expect(loop.loopId == "github_tracking")
    #expect(loop.interval == 42)
    // 600s: a full ~99-item refresh is hundreds of sequential GitHub calls;
    // the old 120s cap cancelled nearly every tick once cadence became 15 min.
    #expect(loop.tickTimeoutOverride == 600)
    await loop.tick()
    #expect(!FileManager.default.fileExists(atPath: tmp.appendingPathComponent("connectors/github/tracking_snapshot.json").path))
}

@Test func github_tracking_default_is_event_deadline_driven_with_slow_repair() {
    let loop: any EventDeadlineLoopRunner = BackgroundLoopsAssembly.makeGitHubTrackingLoop()
    #expect(loop.loopId == "github_tracking")
    #expect(loop.interval == 6 * 60 * 60)
    #expect(loop.eventCoalescingDelay == 0.5)
}

@Test func github_tracking_watches_every_canonical_input_store_file() {
    let root = URL(fileURLWithPath: "/tmp/nativeagent-github-physiology")
    let relative = Set(
        BackgroundLoopsAssembly.githubTrackingWatchedPaths(dataRoot: root)
            .map { $0.path.replacingOccurrences(of: root.path + "/", with: "") }
    )
    #expect(relative == [
        "connectors/github/tracking.json",
        "connectors/github/tracking_snapshot.json",
        "desk/desk_ops.jsonl",
        "desk/desk_ops_base.json",
        "workshop/github_command/ops.jsonl",
        "workshop/github_command/ops_base.json",
    ])
}
