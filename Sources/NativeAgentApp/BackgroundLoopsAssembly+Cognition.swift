import Foundation
import BackgroundLoops
import CognitiveSubstrate
import NativeAgentCore
import PersistenceCore

extension BackgroundLoopsAssembly {
    static func makeCognitionMaintenanceLoop(
        // Maintenance is exact-deadline driven by the cognition runtime. This
        // daily wake is only crash/integrity recovery for missed process-local
        // deadlines, matching the replay fallback below.
        intervalSeconds: TimeInterval = 24 * 60 * 60,
        runtime: NativeCognitionRuntime = .shared
    ) -> some LoopRunner {
        CognitiveMaintenanceLoop(interval: intervalSeconds, runtime: runtime)
    }

    static func makeCognitionReplayLoop(
        // Replay normally flows directly from the canonical dream/REM commit's
        // somatic signal. This daily wake is deliberately only a slow integrity
        // sweep for diary/proposal files written outside the live app process or
        // an event lost across a crash; it is no longer the replay heartbeat.
        intervalSeconds: TimeInterval = 24 * 60 * 60,
        runtime: NativeCognitionRuntime = .shared
    ) -> some LoopRunner {
        CognitiveReplayLoop(interval: intervalSeconds, runtime: runtime)
    }

    static func makeCognitionReflectionLoop(
        llm: any LLMClient,
        // A4.6: reflection now flows from the canonical dream/REM commit's
        // somatic signal (scheduleEventDrivenReflection, fired downstream of
        // replay in the somatic handler), matching maintenance and replay
        // above. This daily wake is deliberately only the slow integrity sweep
        // for a commit signal lost across a crash or material written outside
        // the live app process; it is no longer the reflection heartbeat.
        // Item 41: the sweep is `.spontaneous` too — it wakes the ADMISSION,
        // not a call. A quiet day still spends nothing when it fires.
        intervalSeconds: TimeInterval = 24 * 60 * 60,
        runtime: NativeCognitionRuntime = .shared
    ) -> some LoopRunner {
        CognitiveReflectionLoop(interval: intervalSeconds, llm: llm, runtime: runtime)
    }

}

private struct CognitiveMaintenanceLoop: LoopRunner {
    let interval: TimeInterval
    let runtime: NativeCognitionRuntime
    var loopId: String { "cognition_maintenance" }
    var tickTimeoutOverride: TimeInterval? { 30 }

    func tick() async {
        _ = await tickOutcome()
    }

    func tickOutcome() async -> LoopTickOutcome {
        await runtime.runMaintenance(reason: loopId).loopTickOutcome
    }
}

private struct CognitiveReplayLoop: LoopRunner {
    let interval: TimeInterval
    let runtime: NativeCognitionRuntime
    var loopId: String { "cognition_replay" }
    var tickTimeoutOverride: TimeInterval? { 30 }

    func tick() async {
        _ = await tickOutcome()
    }

    func tickOutcome() async -> LoopTickOutcome {
        await runtime.runReplay(reason: loopId).loopTickOutcome
    }
}

private struct CognitiveReflectionLoop: LoopRunner {
    let interval: TimeInterval
    let llm: any LLMClient
    let runtime: NativeCognitionRuntime
    var loopId: String { "cognition_reflection" }
    var tickTimeoutOverride: TimeInterval? { 180 }

    func tick() async {
        _ = await tickOutcome()
    }

    func tickOutcome() async -> LoopTickOutcome {
        // C2 lease PRIORITY: the window is claimed INSIDE runReflectionIfDue,
        // after the cognition gate and before planning; a refused plan or a
        // pre-provider skip returns it, so a not-due tick never spends the
        // window and blocks the workshop for nothing.
        return await runtime.runReflectionIfDue(
            llm: llm,
            reason: "scheduled cognitive reflection",
            demand: .spontaneous,
            sameSourceCooldown: 6 * 3600
        ).loopTickOutcome
    }
}

private extension CognitiveBackgroundRunOutcome {
    var loopTickOutcome: LoopTickOutcome {
        switch self {
        case .completed(let result): return .completed(result: result)
        case .skipped(let reason): return .skipped(reason: reason)
        case .failed(let error): return .failed(error: error)
        }
    }
}
