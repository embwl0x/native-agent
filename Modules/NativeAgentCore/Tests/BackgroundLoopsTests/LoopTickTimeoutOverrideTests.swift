// U5 W-D "comms resilience": pin the tick-timeout overrides for the five
// LLM loops that used to ride the scheduler's 300s default (u5-reliability
// plan item 6), and prove the override actually flows through the
// scheduler's `loop.tickTimeoutOverride ?? tickTimeout` resolution.

import Testing
import Foundation
@testable import BackgroundLoops
import NativeAgentCore
import PersistenceCore
import DreamREMCycle

private final class StubLLM: LLMClient, @unchecked Sendable {
    func complete(prompt: String, system: String?, model: String?) async throws -> String {
        "stub"
    }
}

private func mkTmp() throws -> URL {
    let url = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("LoopOverrideTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

/// The module-side LLM loops from the u5-reliability audit (item 6) — each
/// must override the scheduler's 300s default with an explicit 3600s budget.
/// Asserted through `any LoopRunner` so the test pins DYNAMIC dispatch (the
/// protocol-requirement path runOneTick actually uses), not a concrete-type
/// shortcut.
///
/// U5 W-D fix-round (gpt-5.5 NEEDS_FIX): the "memory_consolidation" slot is
/// deliberately ABSENT here. Production registers
/// MemoryConsolidationHygieneRunner (NativeAgentApp target) for that slot —
/// NOT this module's MemoryConsolidationLoop, whose production wiring was
/// retired in U3. Pinning the dead type proved nothing about what ships; the
/// assembled loop's override is pinned app-side in
/// Tests/NativeAgentAppTests/BackgroundLoopsAssemblyOverrideTests.swift,
/// resolved through BackgroundLoopsAssembly.makeMemoryConsolidationLoop (the
/// factory assembleAllLoops calls).
@Test func module_llm_loops_override_tick_timeout_to_3600() async throws {
    let tmp = try mkTmp()
    defer { try? FileManager.default.removeItem(at: tmp) }
    let llm = StubLLM()
    let diary = DreamDiaryReader(dataRoot: tmp)
    let loops: [any LoopRunner] = [
        REMCycleLoop(
            consolidator: SwiftNativeREMConsolidator(llm: llm, diary: diary),
            tombstones: REMTombstoneStore(dataRoot: tmp),
            growth: GrowthDocManager(personaRoot: tmp),
            dataRoot: tmp
        ),
        WeeklySelfImprovementLoop(
            llm: llm,
            dataRoot: tmp,
            isEnabled: { true },
            stageProposal: { _ in }
        ),
    ]

    for loop in loops {
        #expect(loop.tickTimeoutOverride == 3600, "loop \(loop.loopId) must override 300s default")
    }
    // Pin the covered set so a renamed/removed loop fails loudly here
    // instead of silently dropping back to the 300s default.
    #expect(Set(loops.map(\.loopId)) == [
        "rem_cycle",
        "self_improvement_sweep",
    ])
}

private struct SlowOverrideLoop: LoopRunner {
    let loopId = "slow_override"
    let interval: TimeInterval = 60
    var tickTimeoutOverride: TimeInterval? { 0.05 }
    func tickOutcome() async -> LoopTickOutcome {
        // Far beyond the override budget; Task.sleep observes the
        // cancellation tickWithTimeout issues when the deadline fires.
        try? await Task.sleep(nanoseconds: 2_000_000_000)
        return .completed(result: nil)
    }
}

/// Call-graph proof for the override constant: a per-loop override BEATS the
/// scheduler-level default in runOneTick (`tickTimeoutOverride ?? tickTimeout`),
/// and the recorded error names the override value, not the default.
@Test func loopScheduler_per_loop_override_beats_scheduler_default() async throws {
    let sched = SwiftNativeLoopScheduler(tickTimeout: 300)
    let loop = SlowOverrideLoop()
    await sched.register(loop)
    await sched._testRunOneTick(loopId: "slow_override")
    let st = await sched.loopState(loopId: "slow_override")
    #expect(st?.tickCount == 1)
    #expect(st?.lastError == "timeout after 0.05s")
    await sched.stop()
}
