import BackgroundWork
import ActivityWatch
import Foundation
import SchedulerExecution
import BackgroundLoops
import NativeAgentCore
import PersistenceCore
import TriggerScheduler
import WorkshopExecution
import StandingBots
import ProviderRouting
import ChatOrchestration
import Cognition

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
            ? makeWorkshopRunner(lifecycleObserver: NativeAgentEngine.liveCognition)
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
                : standardized.appendingPathComponent("no-such-worklog.jsonl"),
            // L5 G3: the time trigger fires the blueprint turn. Live root only —
            // a secondary/test root must never borrow the provider, the tools,
            // or the cost. nil there means the deterministic counts brief,
            // exactly as before.
            morningBriefSynthesizer: isLiveRoot ? makeMorningBriefSynthesizer() : nil
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
        let schedulerActivityFailure: @Sendable () async -> String?
        let nextJobDeadline: @Sendable (Date) async -> Date?
        if isLiveRoot {
            // Scheduled bot runs are unattended provider spend and pass through the
            // same master Autonomy switch Workshop does (lane1 finding 1: the
            // replaced runner's checked unattended admission was never restored).
            // Manual requests queued by the user are admitted inside the scheduler
            // without this gate.
            let bots = BotRunnerScheduler(dataRoot: standardized,
                session: NativeAgentEngine.live.standingBotSession(),
                isAutonomyEnabled: { await unattendedWorkAllowed(dataRoot: standardized) })
            let work = TriggerSchedulerBackgroundWork.makeJobWork(
                runDueJobs: { await dueJobRunner.runDueJobs(maxJobs: $0) },
                activityFailure: { await dueJobRunner.activityFeedError },
                nextDeadline: { await dueJobRunner.nextMeaningfulDeadline(after: $0) },
                bots: bots
            )
            runDueJobs = work.runDueJobs
            schedulerActivityFailure = work.activityFailure
            nextJobDeadline = work.nextDeadline
        } else {
            // Scheduler jobs can dispatch process-global notification,
            // connector, provider, and sync owners. Secondary/test roots may
            // inspect their own files but never borrow those live effects.
            runDueJobs = { [] }
            schedulerActivityFailure = { nil }
            nextJobDeadline = { _ in nil }
        }
        return TriggerSchedulerEventDeadlineRunner(
            dataRoot: standardized,
            events: { paths, loopId in
                EventDeadlinePhysiology.storeAndFileEvents(paths: paths, notifications: [
                    BotRunQueue.didChange,
                    // 2026-09-06: every deadline this runner reports is an ABSOLUTE
                    // instant derived from local time — a cron-shaped job's "09:00", an
                    // idle crossing. A clock correction or a time-zone move changes
                    // what those instants ARE, and no watched file records it, so the
                    // armed deadline went on pointing at the old wall time until the
                    // six-hour integrity tick recomputed it.
                    .NSSystemClockDidChange,
                    .NSSystemTimeZoneDidChange,
                ], loopId: loopId)
            },
            schedulerJobsPath: dueJobRunner.jobsPath,
            triggerScheduler: native,
            runDueJobs: runDueJobs,
            schedulerActivityFailure: schedulerActivityFailure,
            nextSchedulerJobDeadline: nextJobDeadline,
            mirrorFire: mirror
        )
    }

    static func makeMorningBriefSynthesizer() -> MorningBriefSynthesizer {
        TriggerSchedulerBackgroundWork.makeMorningBriefSynthesizer(runTurn: { prompt in
            let client = NativeAgentEngine.live.chatClient(profile: .background)
            let response = try await client.runEphemeralToolTurn(
                message: prompt,
                fileAccess: "read_only",
                surface: WorkshopSurfaceVocabulary.canonical
            )
            return response.output
        })
    }
}
