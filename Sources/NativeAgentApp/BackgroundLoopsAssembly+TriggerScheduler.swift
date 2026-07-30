import Foundation
import BackgroundLoops
import PersistenceCore
import TriggerScheduler
import WorkshopExecution

// Trigger and scheduler-job physiology.
//
// User schedules remain canonical in scheduler/jobs.json and the two trigger
// config stores. BackgroundLoopsManager owns their one lifecycle, single-flight
// execution, status, startup reconciliation, event coalescing, and deadline
// task. This wrapper owns no Task and no timer of its own.

extension BackgroundLoopsAssembly {
    static func makeTriggerSchedulerLoop(
        dataRoot: URL = PersistenceCore.defaultDataRoot()
    ) -> some LoopRunner {
        let standardized = dataRoot.standardizedFileURL
        let isLiveRoot = standardized
            == PersistenceCore.defaultDataRoot().standardizedFileURL
        let workshopRunner: (any WorkshopRunnerClient)? = isLiveRoot
            ? makeWorkshopRunner(lifecycleObserver: NativeCognitionRuntime.shared)
            : nil
        let notifier: TriggerNotifier? = isLiveRoot
            ? TriggerNotifierBinding.pairedDevicePush
            : nil
        let native = SwiftNativeTriggerScheduler(
            root: standardized,
            workshopRunner: workshopRunner,
            notifier: notifier,
            worklogPath: isLiveRoot
                ? nil
                : standardized.appendingPathComponent("no-such-worklog.jsonl")
        )
        let mirror: @Sendable (TriggerFireResult) async -> Bool
        if isLiveRoot {
            mirror = { result in
                await TriggerNotifierBinding.mirrorNonNotifiedFire(result)
            }
        } else {
            mirror = { _ in true }
        }
        let dueJobRunner = SchedulerDueJobRunner(root: standardized)
        let runDueJobs: @Sendable () async -> [String]
        let nextJobDeadline: @Sendable (Date) async -> Date?
        if isLiveRoot {
            runDueJobs = { await dueJobRunner.runDueJobs(maxJobs: 5) }
            nextJobDeadline = { date in
                await dueJobRunner.nextMeaningfulDeadline(after: date)
            }
        } else {
            // Scheduler jobs can dispatch process-global notification,
            // connector, provider, and sync owners. Secondary/test roots may
            // inspect their own files but never borrow those live effects.
            runDueJobs = { [] }
            nextJobDeadline = { _ in nil }
        }
        return TriggerSchedulerEventDeadlineRunner(
            dataRoot: standardized,
            schedulerJobsPath: dueJobRunner.jobsPath,
            triggerScheduler: native,
            runDueJobs: runDueJobs,
            nextSchedulerJobDeadline: nextJobDeadline,
            mirrorFire: mirror
        )
    }
}

struct TriggerSchedulerEventDeadlineRunner: EventDeadlineLoopRunner {
    let loopId = "trigger_scheduler_due_work"
    /// Missed-event integrity only. Normal work wakes from canonical file
    /// invalidations or an exact persisted due instant.
    let interval: TimeInterval = 6 * 60 * 60
    var tickTimeoutOverride: TimeInterval? { 1800 }
    var eventCoalescingDelay: TimeInterval { 0.5 }

    let dataRoot: URL
    let schedulerJobsPath: URL
    let triggerScheduler: SwiftNativeTriggerScheduler
    let runDueJobs: @Sendable () async -> [String]
    let nextSchedulerJobDeadline: @Sendable (Date) async -> Date?
    let mirrorFire: @Sendable (TriggerFireResult) async -> Bool

    init(
        dataRoot: URL,
        schedulerJobsPath: URL,
        triggerScheduler: SwiftNativeTriggerScheduler,
        runDueJobs: @escaping @Sendable () async -> [String],
        nextSchedulerJobDeadline: @escaping @Sendable (Date) async -> Date?,
        mirrorFire: @escaping @Sendable (TriggerFireResult) async -> Bool
    ) {
        self.dataRoot = dataRoot
        self.schedulerJobsPath = schedulerJobsPath
        self.triggerScheduler = triggerScheduler
        self.runDueJobs = runDueJobs
        self.nextSchedulerJobDeadline = nextSchedulerJobDeadline
        self.mirrorFire = mirrorFire
    }

    func physiologyEvents() -> AsyncStream<Void> {
        EventDeadlinePhysiology.storeAndFileEvents(paths: [
            schedulerJobsPath,
            triggerScheduler.inboxPath,
            triggerScheduler.workshopExecutionsPath,
            // Idle triggers derive their exact crossing from max(updatedAt).
            dataRoot.appendingPathComponent("chat/sessions.json"),
        ])
    }

    func nextMeaningfulDeadline(after now: Date) async -> Date? {
        let schedulerJob = await nextSchedulerJobDeadline(now)
        let trigger = await triggerScheduler.nextMeaningfulDeadline(after: now)
        return [schedulerJob, trigger].compactMap { $0 }.min()
    }

    func tick() async {
        _ = await tickOutcome()
    }

    func tickOutcome() async -> LoopTickOutcome {
        let dueJobs = await runDueJobs()
        guard !Task.isCancelled else { return .skipped(reason: "cancelled") }

        let fires = await triggerScheduler.evaluateAndFireDetailed()
        for fire in fires {
            guard !Task.isCancelled else { return .skipped(reason: "cancelled") }
            _ = await mirrorFire(fire)
        }

        let active = (fires.compactMap(\.name) + dueJobs).sorted()
        guard !active.isEmpty else { return .skipped(reason: "nothing due") }
        return .completed(result: "settled \(active.count) due item(s)")
    }
}
