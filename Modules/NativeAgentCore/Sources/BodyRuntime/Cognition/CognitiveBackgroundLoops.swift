import Foundation
import SenseCore
import NativeAgentCore
// Blueprint: | `CognitiveBackgroundLoops.swift` | `CognitiveMaintenanceLoop` struct; `tick`, `tickOutcome` |

/// Each tick reads the body's mind when it runs: there is none until setup finishes, and none after a reset closes it.
public struct CognitiveMaintenanceLoop: LoopRunner {
    public let wake: OrganWake
    let runtime: @Sendable () -> NativeCognitionRuntime?

    public init(interval: TimeInterval, runtime: @escaping @Sendable () -> NativeCognitionRuntime?) {
        self.wake = .every(interval)
        self.runtime = runtime
    }
    public var loopId: String { "cognition_maintenance" }
    public var needsAgent: Bool { true }

    public func tickOutcome() async -> LoopTickOutcome {
        guard let runtime = runtime() else { return .notNeeded(LoopTickOutcome.waitingForSetup) }
        return await runtime.runMaintenance(reason: loopId)
    }
}

public struct CognitiveReplayLoop: LoopRunner {
    public let wake: OrganWake
    let runtime: @Sendable () -> NativeCognitionRuntime?

    public init(interval: TimeInterval, runtime: @escaping @Sendable () -> NativeCognitionRuntime?) {
        self.wake = .every(interval)
        self.runtime = runtime
    }
    public var loopId: String { "cognition_replay" }
    public var needsAgent: Bool { true }

    public func tickOutcome() async -> LoopTickOutcome {
        guard let runtime = runtime() else { return .notNeeded(LoopTickOutcome.waitingForSetup) }
        return await runtime.runReplay(reason: loopId)
    }
}
