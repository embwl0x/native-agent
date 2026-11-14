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
    public var needsAgent: Bool { true }

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
    public var needsAgent: Bool { true }

    public func tickOutcome() async -> LoopTickOutcome {
        await runtime.runReplay(reason: loopId)
    }
}
