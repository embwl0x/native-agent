import Foundation
import BackgroundLoops
import NativeAgentCore
import TriggerScheduler
import StandingBots
// Blueprint: | `TriggerSchedulerBackgroundWork.swift` | `TriggerSchedulerBackgroundWork`, `BackgroundLoopLifetimes`, `native-morning-brief.js`; scheduling |

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
        return JobWork(
            runDueJobs: {
                async let jobs = runDueJobs(5)
                async let botJobs = bots.runDue()
                async let deskJobs = continuations?.runDue() ?? []
                let due = await (jobs, botJobs, deskJobs)
                return due.0 + due.1 + due.2
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
    public let wake: OrganWake = .onChange
    public var tickTimeoutOverride: TimeInterval? { 1800 }
    public var eventCoalescingDelay: TimeInterval { 0.5 }

    let events: @Sendable ([URL], String) -> AsyncStream<Void>
    let dataRoot: URL
    let schedulerJobsPath: URL
    let triggerScheduler: SwiftNativeTriggerScheduler
    let runDueJobs: @Sendable () async -> [String]
    let shutdownJobs: @Sendable () async -> Void
    /// Read activity immediately after effects; missing evidence must fail before later trigger effects proceed.
    let schedulerActivityFailure: @Sendable () async -> String?
    let nextSchedulerJobDeadline: @Sendable (Date) async -> Date?

    public init(
        dataRoot: URL,
        events: @escaping @Sendable ([URL], String) -> AsyncStream<Void>,
        schedulerJobsPath: URL,
        triggerScheduler: SwiftNativeTriggerScheduler,
        runDueJobs: @escaping @Sendable () async -> [String],
        shutdownJobs: @escaping @Sendable () async -> Void,
        schedulerActivityFailure: @escaping @Sendable () async -> String? = { nil },
        nextSchedulerJobDeadline: @escaping @Sendable (Date) async -> Date?
    ) {
        self.events = events
        self.dataRoot = dataRoot
        self.schedulerJobsPath = schedulerJobsPath
        self.triggerScheduler = triggerScheduler
        self.runDueJobs = runDueJobs
        self.shutdownJobs = shutdownJobs
        self.schedulerActivityFailure = schedulerActivityFailure
        self.nextSchedulerJobDeadline = nextSchedulerJobDeadline
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
            // The Autonomy switch governs bot admission and must rearm or retire its deadline.
            dataRoot.appendingPathComponent("trust/policy.json"),
            triggerScheduler.inboxPath,
            triggerScheduler.inboxStatePath,
            // Session changes wake reconciliation; only `time` triggers are clock-due.
            dataRoot.appendingPathComponent("chat/sessions.json"),
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
        guard failures.isEmpty else {
            return .failed(error: failures.map { $0.error ?? "Trigger \($0.name ?? "unknown") remains owed." }.joined(separator: "\n"))
        }

        let active = (fires.compactMap(\.name) + dueJobs).sorted()
        // A clean read proves source repair even when no trigger is due to fire.
        guard !active.isEmpty else { return .completed(result: "every trigger read; nothing due") }
        return .completed(result: "settled \(active.count) due item(s): \(active.joined(separator: ", "))")
    }
}
