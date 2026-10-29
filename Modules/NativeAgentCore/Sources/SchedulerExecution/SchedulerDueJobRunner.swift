import Privacy
import Foundation
import NativeAgentCore
import PersistenceCore
import TelegramBot
import TriggerScheduler
// Blueprint: | `SchedulerDueJobRunner.swift` | `SchedulerDueJobRunner` actor; `runDueJobs`; reads canonical job rows through `SchedulerJobs`; resumable work obeys the originating DataRootLife, reads stopped/restored across lives and resumes fresh only on explicit request |

public actor SchedulerDueJobRunner {
    enum JobKind: String, CaseIterable, Sendable {
        case notify
        case connectorAction = "connector_action"
        case dream
        case rem
        case harnessBenchmark = "harness_benchmark"
        case proactiveScan = "proactive_scan"
        case workshop
        /// A part's `schedule:<cron>` wake: one job per part and schedule.
        case part
        /// A turn of hers on a schedule: the job's prompt runs as one tool turn with her
        /// full tools on her Chat route; the reply lands in the inbox under the job's name.
        case turn
    }

    typealias DueJob = SwiftNativeTriggerScheduler.DueJob
    typealias ClaimedDueJobs = SwiftNativeTriggerScheduler.ClaimedDueJobs

    struct JobResult: Sendable {
        let status: String
        let detail: String
        let output: JSONValue
        /// The row keys a watch's read saw, kept on the job; nil keeps the last ones.
        var seen: [String]? = nil
    }

    struct DreamDiarySnippet: Sendable {
        let path: String
        let title: String
        let summary: String
    }

    let root: URL
    let platform: any SchedulerExecutionPlatform
    let schedulerJobs: SwiftNativeTriggerScheduler
    /// The pass's first fault: unwritable activity evidence, unreadable or
    /// unrepairable job state, or a result that could not be settled. The loop
    /// owner reads it after a pass and publishes a failed loop receipt, so an
    /// unknown inventory never reads as "nothing due". Only a new pass clears it.
    public internal(set) var activityFeedError: String?
    var running = false
    /// Channel receipts settled by the body, retained until its terminal result.
    var notificationOutcomes: [String: JSONValue] = [:]
    /// A part's schedule that does not parse, said once rather than every pass.
    var reportedWakes: Set<String> = []

    public nonisolated var jobsPath: URL {
        root.appendingPathComponent("scheduler", isDirectory: true)
            .appendingPathComponent("jobs.json")
    }

    var activityPath: URL {
        SwiftNativePersistenceCore.activityEventsPath(dataRoot: root)
    }

    var notificationInboxPath: URL {
        root.appendingPathComponent("notifications", isDirectory: true)
            .appendingPathComponent("inbox.jsonl")
    }

    public init(
        root: URL = PersistenceCore.defaultDataRoot(),
        platform: any SchedulerExecutionPlatform
    ) {
        self.root = root
        self.schedulerJobs = SwiftNativeTriggerScheduler(root: root)
        self.platform = platform
    }

    var isLiveDataRoot: Bool {
        root.standardizedFileURL == PersistenceCore.defaultDataRoot().standardizedFileURL
    }

    public func runDueJobs(maxJobs: Int = 5) async -> [String] {
        if running { return [] }
        running = true
        defer { running = false }
        activityFeedError = nil

        let now = Date()
        do {
            let repaired = try await ensureDefaultCycleJobs(now: now).repaired
            if !repaired.isEmpty {
                try await appendActivity(
                    jobId: nil,
                    title: "Default cycle schedules repaired",
                    detail: repaired.joined(separator: ", "),
                    status: "ok",
                    payload: .object(["jobs": .array(repaired.map { .string($0) })])
                )
            }
            if let backfilled = try await backfillDreamReceiptIfNeeded(now: now) {
                try await appendActivity(
                    jobId: "nativeagent-nightly-dream",
                    title: "Dream cycle receipt backfilled",
                    detail: "Backfilled inbox item \(backfilled)",
                    status: "ok",
                    payload: .object(["inboxItemId": .string(backfilled)])
                )
            }
            let retiredJobs = try await schedulerJobs.pruneJobs { Self.pruneRetiredRows($0, now: now) }
            if retiredJobs > 0 {
                try await appendActivity(
                    jobId: nil,
                    title: "Scheduled Desk tasks retired",
                    detail: "Retired \(retiredJobs) job row(s); reasons recorded in scheduler/retired.jsonl",
                    status: "ok",
                    payload: .object(["removed": .int(Int64(retiredJobs))])
                )
            }
        } catch {
            // A failed scheduler-state repair is not safe to continue.
            noteFault("Scheduled Desk task state could not be repaired: \(error.localizedDescription)")
            do {
                try await appendActivity(
                    jobId: nil,
                    title: "Default cycle schedule repair failed",
                    detail: error.localizedDescription,
                    status: "warn",
                    payload: .object([:])
                )
            } catch { }
            return []
        }

        var settled: [String] = []
        // Defer stuck recovered claims for this pass so other due jobs can run.
        var deferredJobIds: Set<String> = []
        var exhaustedBatch = true
        // Claim exactly one occurrence immediately before its effect. Claiming
        // a whole batch would make later untouched rows look ambiguous if the
        // process crashed while executing the first row.
        for _ in 0..<max(1, maxJobs) {
            guard !Task.isCancelled else { exhaustedBatch = false; break }
            let claimed: ClaimedDueJobs
            do {
                claimed = try await claimDueJob(now: Date(), excludingJobIds: deferredJobIds)
            } catch {
                noteFault("Scheduled Desk tasks could not be read: \(error.localizedDescription)")
                do {
                    try await appendActivity(
                        jobId: nil,
                        title: "Scheduled Desk task scan failed",
                        detail: error.localizedDescription,
                        status: "error",
                        payload: .object([:])
                    )
                } catch { }
                return settled
            }

            // A durable claim left by a prior process means the effect may
            // have happened. Never blindly replay it.
            for recovery in claimed.recoveredUnknown {
                guard await recordUnknownOccurrence(recovery) else {
                    deferredJobIds.insert(recovery.jobId)
                    continue
                }
                // Release only after the unknown outcome is durably on record.
                do {
                    try await schedulerJobs.settleUnknownOccurrence(recovery, now: now)
                } catch {
                    noteFault("Scheduler reconciliation could not release occurrence "
                        + "\(recovery.occurrenceKey): \(error.localizedDescription)")
                    deferredJobIds.insert(recovery.jobId)
                    continue
                }
            }
            guard let job = claimed.jobs.first else {
                if claimed.recoveredUnknown.isEmpty {
                    exhaustedBatch = false
                    break
                }
                continue
            }

            // Each job runs under a per-kind deadline (see jobTimeoutSeconds).
            // A blown deadline yields a loud failed(timeout) receipt, then this
            // pass stops. The timed-out body remains lifecycle-quarantined until
            // it actually exits, so no later scheduled effect can overlap it.
            let rawResult = await executeWithTimeout(job: job)
            let result = Self.attachingOccurrence(rawResult, key: job.occurrenceKey)

            let settlementRecorded = await settle { [self] in
              do {
                try await update(job: job, result: result, at: Date())
                try await appendActivity(
                    jobId: job.id,
                    title: "Scheduled Desk task \(result.status)",
                    detail: "\(job.name): \(result.detail)",
                    status: result.status == "error" ? "error" : (result.status == "skipped" ? "warn" : "ok"),
                    payload: .object([
                        "jobId": .string(job.id),
                        "jobName": .string(job.name),
                        "kind": .string(job.kind),
                        "status": .string(result.status),
                        "occurrenceKey": .string(job.occurrenceKey),
                        "output": NativeAppSecretRedactor.redactValue(result.output),
                    ])
                )
                // Every settled occurrence is work this pass did, whatever its
                // outcome; a failed job is never "nothing due".
                return true
            } catch {
                await noteFault("\(job.name) ran (\(result.status)) but its result could not be settled: \(error.localizedDescription)")
                do {
                    try await appendActivity(
                        jobId: job.id,
                        title: "Scheduled Desk task update failed",
                        detail: "scheduler_settlement_unconfirmed: \(job.name): result \(result.status); settlement is unconfirmed: \(error.localizedDescription). Inspect this occurrence's retained output and delivery receipts before resuming it.",
                        status: "error",
                        payload: .object([
                            "jobId": .string(job.id),
                            "occurrenceKey": .string(job.occurrenceKey),
                            "status": .string(result.status),
                            "output": NativeAppSecretRedactor.redactValue(result.output),
                        ])
                    )
                } catch {
                    return false
                }
                return false
              }
            }
            if settlementRecorded { settled.append("\(job.name) (\(result.status))") }
            // The body has exited and settled; cancellation or timeout ends the batch.
            if Task.isCancelled || Self.isQuarantiningResult(result) {
                exhaustedBatch = false
                break
            }
        }
        if exhaustedBatch { await requestRemainingBatch(excludingJobIds: deferredJobIds) }
        return settled
    }

    func noteFault(_ fault: String) {
        if activityFeedError == nil { activityFeedError = fault }
    }

    private func recordUnknownOccurrence(_ recovery: SwiftNativeTriggerScheduler.OccurrenceRecovery) async -> Bool {
        do {
            try await appendActivity(
                jobId: recovery.jobId,
                title: recovery.reason == nil ? "Scheduled Desk task outcome needs reconciliation" : "Scheduled Desk task stopped",
                detail: recovery.detail,
                status: recovery.reason == nil ? "warn" : "stopped",
                payload: .object([
                    "occurrenceKey": .string(recovery.occurrenceKey),
                    "outcome": .string(recovery.reason == nil ? "unknown_after_restart" : "stopped"),
                    "reason": recovery.reason.map(JSONValue.string) ?? .null,
                ])
            )
            try await appendNotificationInbox(
                title: recovery.reason == nil ? "\(recovery.jobName) needs a quick check" : "\(recovery.jobName) stopped",
                message: recovery.detail,
                source: "scheduler_reconciliation",
                severity: "important",
                jobId: recovery.jobId,
                itemId: Self.reconciliationItemId(for: recovery.occurrenceKey)
            )
            return true
        } catch {
            noteFault("Scheduler reconciliation evidence could not be written: \(error.localizedDescription)")
            return false
        }
    }

    private static func reconciliationItemId(for occurrenceKey: String) -> String {
        let safe = occurrenceKey.map { character -> Character in
            character.isLetter || character.isNumber || character == "-" || character == "_"
                ? character
                : "-"
        }
        return "scheduler-unknown-\(String(safe).prefix(180))"
    }

    private static func isQuarantiningResult(_ result: JobResult) -> Bool {
        guard case .object(let output) = result.output,
              let kind = SchedulerJobRuntime.string(output["failureKind"]) else { return false }
        return kind == "job_timeout" || kind == "job_cancelled"
    }

    private static func attachingOccurrence(_ result: JobResult, key: String) -> JobResult {
        var output: [String: JSONValue]
        if case .object(let object) = result.output {
            output = object
        } else {
            output = ["value": result.output]
        }
        output["occurrenceKey"] = .string(key)
        return JobResult(status: result.status, detail: result.detail, output: .object(output), seen: result.seen)
    }

}
