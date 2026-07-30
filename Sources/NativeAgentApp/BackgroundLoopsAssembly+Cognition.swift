import Foundation
import BackgroundLoops
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
        // C2 lease PRIORITY: the window is marked INSIDE runReflectionIfDue,
        // only when reflection actually runs its expensive work (gpt-5.5 LOW —
        // marking here pre-emptively would let a not-due tick consume the
        // window and block the workshop for nothing).
        return await runtime.runReflectionIfDue(
            llm: llm,
            reason: "scheduled budgeted cognitive reflection"
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
