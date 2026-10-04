import Foundation
import BackgroundLoops
import Cognition
import WorkshopExecution

/// Event/deadline adapter for WorkshopExecutorLoop. Canonical execution-file
/// mutations wake the queue immediately; configured approval timeouts own one
/// exact persisted deadline. The daily interval is only a crash/missed-event
/// integrity pass. A drained execution may still run multi-minute LLM/tool
/// steps, so the 1800s timeout remains.
public struct WorkshopExecutorDrainRunner: EventDeadlineLoopRunner {
    public let loopId = "mission_executor"
    public let interval: TimeInterval = 24 * 60 * 60
    public var tickTimeoutOverride: TimeInterval? { 1800 }
    let dataRoot: URL
    let executor: WorkshopExecutorLoop

    public init(dataRoot: URL, executor: WorkshopExecutorLoop) {
        self.dataRoot = dataRoot
        self.executor = executor
    }

    public func physiologyEvents() -> AsyncStream<Void> {
        EventDeadlinePhysiology.storeAndFileEvents(paths: [
            dataRoot.appendingPathComponent("workshop/executions", isDirectory: true),
            dataRoot.appendingPathComponent("trust/policy.json"),
        ], loopId: loopId)
    }

    public func nextMeaningfulDeadline(after now: Date) async -> Date? {
        await executor.nextMeaningfulDeadline(after: now)
    }

    public func tick() async {
        _ = await tickOutcome()
    }

    public func tickOutcome() async -> LoopTickOutcome {
        let ran = await executor.drainOnce()
        if Task.isCancelled { return .skipped(reason: "Desk executor canceled") }
        // A drain that claimed nothing did no work. Reporting it `.completed`
        // advanced the dormancy clock on every idle tick, so an executor that
        // has not run a mission in weeks looked freshly successful.
        guard ran > 0 else { return .skipped(reason: "no queued Desk executions") }
        return .completed(result: "drained \(ran) queued Desk execution(s)")
    }
}
