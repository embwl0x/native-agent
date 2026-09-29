import Foundation
import BackgroundLoops
import Cognition
import CognitiveSubstrate
import NativeAgentCore
import PersistenceCore

extension BackgroundLoopsAssembly {
    static func makeCognitionMaintenanceLoop(
        // Maintenance is exact-deadline driven by the cognition runtime. This
        // daily wake is only crash/integrity recovery for missed process-local
        // deadlines, matching the replay fallback below.
        intervalSeconds: TimeInterval = 24 * 60 * 60,
        runtime: NativeCognitionRuntime = NativeAgentEngine.liveCognition
    ) -> some LoopRunner {
        CognitiveMaintenanceLoop(interval: intervalSeconds, runtime: runtime)
    }

    static func makeCognitionReplayLoop(
        // Replay normally flows directly from the canonical dream/REM commit's
        // somatic signal. This daily wake is deliberately only a slow integrity
        // sweep for diary/proposal files written outside the live app process or
        // an event lost across a crash; it is no longer the replay heartbeat.
        intervalSeconds: TimeInterval = 24 * 60 * 60,
        runtime: NativeCognitionRuntime = NativeAgentEngine.liveCognition
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
        runtime: NativeCognitionRuntime = NativeAgentEngine.liveCognition
    ) -> some LoopRunner {
        CognitiveReflectionLoop(interval: intervalSeconds, llm: llm, runtime: runtime)
    }

}
