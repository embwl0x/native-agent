import Foundation
import BackgroundLoops
import NativeAgentCore

public struct CognitiveMaintenanceLoop: LoopRunner {
    public let interval: TimeInterval
    let runtime: NativeCognitionRuntime

    public init(interval: TimeInterval, runtime: NativeCognitionRuntime) {
        self.interval = interval
        self.runtime = runtime
    }
    public var loopId: String { "cognition_maintenance" }
    public var tickTimeoutOverride: TimeInterval? { 30 }

    public func tick() async {
        _ = await tickOutcome()
    }

    public func tickOutcome() async -> LoopTickOutcome {
        await runtime.runMaintenance(reason: loopId).loopTickOutcome
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

    public func tick() async {
        _ = await tickOutcome()
    }

    public func tickOutcome() async -> LoopTickOutcome {
        await runtime.runReplay(reason: loopId).loopTickOutcome
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

    public func tick() async {
        _ = await tickOutcome()
    }

    public func tickOutcome() async -> LoopTickOutcome {
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
