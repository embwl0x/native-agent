import Privacy
import Foundation
import NativeAgentCore
import PersistenceCore
import TelegramBot
import TriggerScheduler

public actor SchedulerDueJobRunner {
    typealias CycleNotificationDelivery = @Sendable (String, String, String, String, String?) async -> JSONValue
    enum JobKind: String, CaseIterable, Sendable {
        case notify
        case connectorAction = "connector_action"
        case dream
        case rem
        case harnessBenchmark = "harness_benchmark"
        case proactiveScan = "proactive_scan"
        case workshop
    }

    typealias DueJob = SwiftNativeTriggerScheduler.DueJob
    typealias ClaimedDueJobs = SwiftNativeTriggerScheduler.ClaimedDueJobs

    struct JobResult: Sendable {
        let status: String
        let detail: String
        let output: JSONValue
    }

    struct DreamDiarySnippet: Sendable {
        let path: String
        let title: String
        let summary: String
    }

    let root: URL
    let platform: any SchedulerExecutionPlatform
    let persistence = SwiftNativePersistenceCore()
    let schedulerJobs: SwiftNativeTriggerScheduler
    let cycleNotificationDelivery: CycleNotificationDelivery
    /// The loop owner reads this after a tick and publishes a failed loop
    /// receipt. Activity evidence is not best-effort: if it cannot be written,
    /// subsequent scheduled effects stop rather than becoming unaccountable.
    public internal(set) var activityFeedError: String?
    var running = false
    /// Bodies that crossed their caller-facing deadline but have not actually
    /// exited yet. A new scheduler pass must not overlap them.
    var inFlightJobBodies = 0
    var jobBodyExitWaiters: [CheckedContinuation<Void, Never>] = []

    public nonisolated var jobsPath: URL {
        root.appendingPathComponent("scheduler", isDirectory: true)
            .appendingPathComponent("jobs.json")
    }

    var activityPath: URL {
        root.appendingPathComponent("activity", isDirectory: true)
            .appendingPathComponent("events.jsonl")
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
        self.cycleNotificationDelivery = { title, body, jobId, source, itemId in
            await SchedulerDueJobRunner.deliverCycleNotification(
                title: title, body: body, jobId: jobId, source: source, itemId: itemId,
                platform: platform
            )
        }
    }

    var isLiveDataRoot: Bool {
        root.standardizedFileURL == PersistenceCore.defaultDataRoot().standardizedFileURL
    }

    public func runDueJobs(maxJobs: Int = 5) async -> [String] {
        if running || inFlightJobBodies > 0 { return [] }
        running = true
        defer { running = false }
        activityFeedError = nil

        let now = Date()
        do {
            let repaired = try await ensureDefaultCycleJobs(now: now)
            if !repaired.isEmpty {
                try await appendActivity(
                    jobId: nil,
                    kind: "scheduler",
                    title: "Default cycle schedules repaired",
                    detail: repaired.joined(separator: ", "),
                    status: "ok",
                    payload: .object(["jobs": .array(repaired.map { .string($0) })])
                )
            }
            if let backfilled = try await backfillDreamReceiptIfNeeded(now: now) {
                try await appendActivity(
                    jobId: "nativeagent-nightly-dream",
                    kind: "dream",
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
                    kind: "scheduler",
                    title: "Scheduled jobs retired",
                    detail: "Retired \(retiredJobs) job row(s); reasons recorded in scheduler/retired.jsonl",
                    status: "ok",
                    payload: .object(["removed": .int(Int64(retiredJobs))])
                )
            }
        } catch {
            // appendActivity records its own durable-evidence failure. Either
            // way, a failed scheduler-state repair is not safe to continue.
            do {
                try await appendActivity(
                    jobId: nil,
                    kind: "scheduler",
                    title: "Default cycle schedule repair failed",
                    detail: error.localizedDescription,
                    status: "warn",
                    payload: .object([:])
                )
            } catch { }
            return []
        }

        var completedNames: [String] = []
        // 2026-09-06: rows this pass cannot make progress on — a recovered
        // claim whose notice would not write, or whose release failed. They are
        // excluded from selection so the pass keeps reaching the other due jobs
        // instead of re-detecting the same stuck row on every iteration.
        var deferredJobIds: Set<String> = []
        // Claim exactly one occurrence immediately before its effect. Claiming
        // a whole batch would make later untouched rows look ambiguous if the
        // process crashed while executing the first row.
        for _ in 0..<max(1, maxJobs) {
            let claimed: ClaimedDueJobs
            do {
                claimed = try await claimDueJob(now: now, excludingJobIds: deferredJobIds)
            } catch {
                do {
                    try await appendActivity(
                        jobId: nil,
                        kind: "scheduler",
                        title: "Scheduled job scan failed",
                        detail: error.localizedDescription,
                        status: "error",
                        payload: .object([:])
                    )
                } catch { }
                return completedNames
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
                    if activityFeedError == nil {
                        activityFeedError = "Scheduler reconciliation could not release occurrence "
                            + "\(recovery.occurrenceKey): \(error.localizedDescription)"
                    }
                    deferredJobIds.insert(recovery.jobId)
                    continue
                }
            }
            guard let job = claimed.jobs.first else {
                if claimed.recoveredUnknown.isEmpty { break }
                continue
            }

            // Each job runs under a per-kind deadline (see jobTimeoutSeconds).
            // A blown deadline yields a loud failed(timeout) receipt, then this
            // pass stops. The timed-out body remains lifecycle-quarantined until
            // it actually exits, so no later scheduled effect can overlap it.
            let rawResult = await executeWithTimeout(job: job, now: now)
            let result = Self.attachingOccurrence(rawResult, key: job.occurrenceKey)

            do {
                try await update(job: job, result: result, at: Date())
                try await appendActivity(
                    jobId: job.id,
                    kind: job.kind,
                    title: "Scheduled job \(result.status)",
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
                if result.status == "completed" || result.status == "warn" {
                    completedNames.append(job.name)
                }
            } catch {
                do {
                    try await appendActivity(
                        jobId: job.id,
                        kind: job.kind,
                        title: "Scheduled job update failed",
                        detail: "\(job.name): \(error.localizedDescription)",
                        status: "error",
                        payload: .object(["jobId": .string(job.id)])
                    )
                } catch {
                    return completedNames
                }
            }
            // Parent-cancel propagation (W3b Finding 2): if the scheduler loop was
            // stopped mid-job, executeWithTimeout returned the loud .cancelled
            // receipt (persisted just above). Stop here rather than starting the
            // remaining due rows — each would only mint its own cancelled receipt.
            if Task.isCancelled { break }
            if Self.isQuarantiningResult(result) {
                // Keep the TriggerScheduler loop's actual tick alive until the
                // timed-out effect body is gone. BackgroundLoopsManager may
                // bound its caller at the outer deadline, but its registration
                // then remains quarantined on this same child lifecycle.
                await waitForInFlightJobBodies()
                break
            }
        }
        return completedNames
    }

    private func recordUnknownOccurrence(_ recovery: SwiftNativeTriggerScheduler.OccurrenceRecovery) async -> Bool {
        do {
            try await appendActivity(
                jobId: recovery.jobId,
                kind: recovery.kind,
                title: "Scheduled job outcome needs reconciliation",
                detail: recovery.detail,
                status: "warn",
                payload: .object([
                    "occurrenceKey": .string(recovery.occurrenceKey),
                    "outcome": .string("unknown_after_restart"),
                ])
            )
            try await appendNotificationInbox(
                title: "\(recovery.jobName) needs a quick check",
                message: recovery.detail,
                source: "scheduler_reconciliation",
                severity: "important",
                jobId: recovery.jobId,
                itemId: Self.reconciliationItemId(for: recovery.occurrenceKey)
            )
            return true
        } catch {
            if activityFeedError == nil {
                activityFeedError = "Scheduler reconciliation evidence could not be written: \(error.localizedDescription)"
            }
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
        return JobResult(status: result.status, detail: result.detail, output: .object(output))
    }

    private func waitForInFlightJobBodies() async {
        guard inFlightJobBodies > 0 else { return }
        await withCheckedContinuation { jobBodyExitWaiters.append($0) }
    }
}
