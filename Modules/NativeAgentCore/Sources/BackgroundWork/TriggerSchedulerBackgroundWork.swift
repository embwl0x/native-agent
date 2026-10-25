import ActivityWatch
import Foundation
import BackgroundLoops
import NativeAgentCore
import TriggerScheduler
import StandingBots
// Blueprint: | `TriggerSchedulerBackgroundWork.swift` | `TriggerSchedulerBackgroundWork` enum; `makeJobWork`; event/deadline runner for canonical scheduler jobs and inbox occurrences; briefing prompt and synthesis policy live in `native-morning-brief.js` |

public enum TriggerSchedulerBackgroundWork {
    public struct JobWork: Sendable {
        public let runDueJobs: @Sendable () async -> [String]
        public let activityFailure: @Sendable () async -> String?
        public let nextDeadline: @Sendable (Date) async -> Date?
        public let shutdown: @Sendable () async -> Void
    }

    public static func makeJobWork(
        runDueJobs: @escaping @Sendable (Int) async -> [String],
        activityFailure: @escaping @Sendable () async -> String?,
        nextDeadline: @escaping @Sendable (Date) async -> Date?,
        bots: BotRunnerScheduler,
        continuations: DeskContinuationScheduler? = nil
    ) -> JobWork {
        JobWork(
            runDueJobs: {
                let jobs = await runDueJobs(5)
                return jobs + (await bots.runDue()) + (await continuations?.runDue() ?? [])
            },
            activityFailure: {
                let jobs = await activityFailure()
                let botFailure = await bots.failure
                let continuationFailure = await continuations?.failure
                return jobs ?? botFailure ?? continuationFailure
            },
            nextDeadline: { date in
                let jobs = await nextDeadline(date)
                let botDeadline = await bots.nextDeadline(after: date)
                let continuationDeadline = await continuations?.nextDeadline(after: date)
                return [jobs, botDeadline, continuationDeadline].compactMap { $0 }.min()
            },
            shutdown: { await bots.shutdown() }
        )
    }

}

public struct TriggerSchedulerEventDeadlineRunner: EventDeadlineLoopRunner {
    public let loopId = "trigger_scheduler_due_work"
    /// Missed-event integrity only. Normal work wakes from canonical file
    /// invalidations or an exact persisted due instant.
    public let interval: TimeInterval = 6 * 60 * 60
    public var tickTimeoutOverride: TimeInterval? { 1800 }
    public var eventCoalescingDelay: TimeInterval { 0.5 }

    let events: @Sendable ([URL], String) -> AsyncStream<Void>
    let dataRoot: URL
    let schedulerJobsPath: URL
    let triggerScheduler: SwiftNativeTriggerScheduler
    let runDueJobs: @Sendable () async -> [String]
    let shutdownJobs: @Sendable () async -> Void
    /// Read immediately after `runDueJobs`. A durable scheduler effect without
    /// its activity evidence is deliberately a failed loop receipt, not a
    /// quiet "nothing due" tick that lets later trigger effects proceed.
    let schedulerActivityFailure: @Sendable () async -> String?
    let nextSchedulerJobDeadline: @Sendable (Date) async -> Date?
    let mirrorFire: @Sendable (TriggerFireResult) async -> Bool

    public init(
        dataRoot: URL,
        events: @escaping @Sendable ([URL], String) -> AsyncStream<Void>,
        schedulerJobsPath: URL,
        triggerScheduler: SwiftNativeTriggerScheduler,
        runDueJobs: @escaping @Sendable () async -> [String],
        shutdownJobs: @escaping @Sendable () async -> Void,
        schedulerActivityFailure: @escaping @Sendable () async -> String? = { nil },
        nextSchedulerJobDeadline: @escaping @Sendable (Date) async -> Date?,
        mirrorFire: @escaping @Sendable (TriggerFireResult) async -> Bool
    ) {
        self.events = events
        self.dataRoot = dataRoot
        self.schedulerJobsPath = schedulerJobsPath
        self.triggerScheduler = triggerScheduler
        self.runDueJobs = runDueJobs
        self.shutdownJobs = shutdownJobs
        self.schedulerActivityFailure = schedulerActivityFailure
        self.nextSchedulerJobDeadline = nextSchedulerJobDeadline
        self.mirrorFire = mirrorFire
    }

    public func physiologyEvents() -> AsyncStream<Void> {
        events([
            schedulerJobsPath,
            dataRoot.appendingPathComponent("desk/desk_ops.jsonl"),
            dataRoot.appendingPathComponent("desk/desk_ops_base.json"),
            dataRoot.appendingPathComponent("bots/shelf-index.json"),
            dataRoot.appendingPathComponent("bots/definitions"),
            dataRoot.appendingPathComponent("bots/runner-jobs.json"),
            dataRoot.appendingPathComponent("bots/run-queue.json"),
            // Scheduled bot admission now reads the master Autonomy switch, so
            // flipping it is the event that re-arms (or retires) the bot
            // deadline — the same watch the Workshop pump keeps.
            dataRoot.appendingPathComponent("trust/policy.json"),
            triggerScheduler.inboxPath,
            triggerScheduler.inboxStatePath,
            triggerScheduler.workshopExecutionsPath,
            triggerScheduler.workshopExecutionStatePath,
            // Retained activity watches wake reconciliation; only `time` triggers are clock-due.
            dataRoot.appendingPathComponent("chat/sessions.json"),
            HumanPresenceStamp.transitionURL(dataRoot: dataRoot),
        ], loopId)
    }

    public func nextMeaningfulDeadline(after now: Date) async -> Date? {
        let schedulerJob = await nextSchedulerJobDeadline(now)
        let trigger = await triggerScheduler.nextMeaningfulDeadline(after: now)
        return [schedulerJob, trigger].compactMap { $0 }.min()
    }

    public func shutdown() async { await shutdownJobs() }

    public func tickOutcome() async -> LoopTickOutcome {
        let dueJobs = await runDueJobs()
        guard !Task.isCancelled else { return .skipped(reason: "cancelled") }
        if let activityFailure = await schedulerActivityFailure() {
            return .failed(error: activityFailure)
        }

        let fires = await triggerScheduler.evaluateAndFireDetailed()
        let failures = fires.filter { $0.status != "fired" }
        var mirrorFailures = 0
        for fire in fires where fire.status == "fired" {
            guard !Task.isCancelled else { return .skipped(reason: "cancelled") }
            if !(await mirrorFire(fire)) { mirrorFailures += 1 }
        }
        guard mirrorFailures == 0 else {
            return .failed(error: "Could not add \(mirrorFailures) trigger notification(s) to the inbox.")
        }

        guard failures.isEmpty else {
            return .failed(error: failures.map { $0.error ?? "Trigger \($0.name ?? "unknown") remains owed." }.joined(separator: "\n"))
        }

        let active = (fires.compactMap(\.name) + dueJobs).sorted()
        // Reading every trigger cleanly is this loop's work, due or not: it is
        // what proves a failed read repaired, without waiting for a fire.
        guard !active.isEmpty else { return .completed(result: "every trigger read; nothing due") }
        return .completed(result: "settled \(active.count) due item(s): \(active.joined(separator: ", "))")
    }
}
