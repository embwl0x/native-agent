import Foundation
import BackgroundLoops
import NativeAgentCore
// Blueprint: | `CognitiveBackgroundLoops.swift` | `CognitiveMaintenanceLoop` struct; `tick`, `tickOutcome` |

public struct CognitiveMaintenanceLoop: LoopRunner {
    public let wake: OrganWake
    let runtime: NativeCognitionRuntime

    public init(interval: TimeInterval, runtime: NativeCognitionRuntime) {
        self.wake = .every(interval)
        self.runtime = runtime
    }
    public var loopId: String { "cognition_maintenance" }
    public var tickTimeoutOverride: TimeInterval? { 30 }

    public func tickOutcome() async -> LoopTickOutcome {
        await runtime.runMaintenance(reason: loopId)
    }
}

public struct CognitiveReplayLoop: LoopRunner {
    public let wake: OrganWake
    let runtime: NativeCognitionRuntime

    public init(interval: TimeInterval, runtime: NativeCognitionRuntime) {
        self.wake = .every(interval)
        self.runtime = runtime
    }
    public var loopId: String { "cognition_replay" }
    public var tickTimeoutOverride: TimeInterval? { 30 }

    public func tickOutcome() async -> LoopTickOutcome {
        await runtime.runReplay(reason: loopId)
    }
}

public struct CognitiveReflectionLoop: LoopRunner {
    public let wake: OrganWake
    let llm: any LLMClient
    let runtime: NativeCognitionRuntime

    public init(interval: TimeInterval, llm: any LLMClient, runtime: NativeCognitionRuntime) {
        self.wake = .every(interval)
        self.llm = llm
        self.runtime = runtime
    }
    public var loopId: String { "cognition_reflection" }
    public var tickTimeoutOverride: TimeInterval? { 180 }

    public func tickOutcome() async -> LoopTickOutcome {
        // Claim the window after admission and return it on planning or pre-provider skips so unused reflection cannot block Workshop.
        return await runtime.runReflectionIfDue(
            llm: llm,
            reason: "scheduled cognitive reflection",
            demand: .spontaneous,
            sameSourceCooldown: 6 * 3600
        )
    }
}
