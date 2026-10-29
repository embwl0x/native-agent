import Foundation
import BackgroundLoops
import NativeAgentCore
// Blueprint: | `CognitiveBackgroundLoops.swift` | `CognitiveMaintenanceLoop` struct; `tick`, `tickOutcome` |

public struct CognitiveMaintenanceLoop: LoopRunner {
    public let interval: TimeInterval
    let runtime: NativeCognitionRuntime

    public init(interval: TimeInterval, runtime: NativeCognitionRuntime) {
        self.interval = interval
        self.runtime = runtime
    }
    public var loopId: String { "cognition_maintenance" }
    public var tickTimeoutOverride: TimeInterval? { 30 }

    public func tickOutcome() async -> LoopTickOutcome {
        await runtime.runMaintenance(reason: loopId)
    }
}

public struct CognitiveReplayLoop: LoopRunner {
    public let interval: TimeInterval
    let runtime: NativeCognitionRuntime

    public init(interval: TimeInterval, runtime: NativeCognitionRuntime) {
        self.interval = interval
        self.runtime = runtime
    }
    public var loopId: String { "cognition_replay" }
    public var tickTimeoutOverride: TimeInterval? { 30 }

    public func tickOutcome() async -> LoopTickOutcome {
        await runtime.runReplay(reason: loopId)
    }
}

public struct CognitiveReflectionLoop: LoopRunner {
    public let interval: TimeInterval
    let llm: any LLMClient
    let runtime: NativeCognitionRuntime

    public init(interval: TimeInterval, llm: any LLMClient, runtime: NativeCognitionRuntime) {
        self.interval = interval
        self.llm = llm
        self.runtime = runtime
    }
    public var loopId: String { "cognition_reflection" }
    public var tickTimeoutOverride: TimeInterval? { 180 }

    public func tickOutcome() async -> LoopTickOutcome {
        // The window is claimed inside runReflectionIfDue,
        // after the cognition gate and before planning; a refused plan or a
        // pre-provider skip returns it, so a not-due tick never spends the
        // window and blocks the workshop for nothing.
        return await runtime.runReflectionIfDue(
            llm: llm,
            reason: "scheduled cognitive reflection",
            demand: .spontaneous,
            sameSourceCooldown: 6 * 3600
        )
    }
}
