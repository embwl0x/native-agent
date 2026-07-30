import Foundation
import NativeAgentCore
import PersistenceCore
import TelegramBot
import TriggerScheduler

actor SchedulerDueJobRunner {
    static let shared = SchedulerDueJobRunner()

    struct DueJob: Sendable {
        let id: String
        let name: String
        let kind: String
        let payload: [String: JSONValue]
        let row: JSONValue
        let dueEpoch: Double
    }

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
    let persistence = SwiftNativePersistenceCore()
    var running = false

    nonisolated var jobsPath: URL {
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

    init(root: URL = PersistenceCore.defaultDataRoot()) {
        self.root = root
    }

    func runDueJobs(maxJobs: Int = 5) async -> [String] {
        if running { return [] }
        running = true
        defer { running = false }

        let now = Date()
        do {
            let repaired = try await ensureDefaultCycleJobs(now: now)
            if !repaired.isEmpty {
                try? await appendActivity(
                    jobId: nil,
                    kind: "scheduler",
                    title: "Default cycle schedules repaired",
                    detail: repaired.joined(separator: ", "),
                    status: "ok",
                    payload: .object(["jobs": .array(repaired.map { .string($0) })])
                )
            }
            if let backfilled = try await backfillDreamReceiptIfNeeded(now: now) {
                try? await appendActivity(
                    jobId: "nativeagent-nightly-dream",
                    kind: "dream",
                    title: "Dream cycle receipt backfilled",
                    detail: "Backfilled inbox item \(backfilled)",
                    status: "ok",
                    payload: .object(["inboxItemId": .string(backfilled)])
                )
            }
            // FIX 3 (A4.5): bound completed oneShot rows — they previously only
            // gained enabled=false + completedAt and were never removed, so
            // jobs.json grew without limit.
            let prunedOneShots = (try? await pruneCompletedOneShotJobs(now: now)) ?? 0
            if prunedOneShots > 0 {
                try? await appendActivity(
                    jobId: nil,
                    kind: "scheduler",
                    title: "Completed one-shot jobs pruned",
                    detail: "Removed \(prunedOneShots) completed one-shot job row(s) past the retention window",
                    status: "ok",
                    payload: .object(["removed": .int(Int64(prunedOneShots))])
                )
            }
        } catch {
            try? await appendActivity(
                jobId: nil,
                kind: "scheduler",
                title: "Default cycle schedule repair failed",
                detail: error.localizedDescription,
                status: "warn",
                payload: .object([:])
            )
        }

        let dueJobs: [DueJob]
        do {
            dueJobs = try await selectDueJobs(now: now, maxJobs: max(1, maxJobs))
        } catch {
            try? await appendActivity(
                jobId: nil,
                kind: "scheduler",
                title: "Scheduled job scan failed",
                detail: error.localizedDescription,
                status: "error",
                payload: .object([:])
            )
            return []
        }

        var completedNames: [String] = []
        for job in dueJobs {
            // Each job runs under a per-kind deadline (see jobTimeoutSeconds).
            // A blown deadline yields a loud failed(timeout) receipt and the loop
            // CONTINUES — one hung body can no longer wedge every later row or
            // hold `running` true. `running` is released by the outer defer once
            // the (now bounded) loop finishes.
            let result = await executeWithTimeout(job: job, now: now)

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
                        "output": NativeAppSecretRedactor.redactValue(result.output),
                    ])
                )
                if result.status == "completed" || result.status == "warn" {
                    completedNames.append(job.name)
                }
            } catch {
                try? await appendActivity(
                    jobId: job.id,
                    kind: job.kind,
                    title: "Scheduled job update failed",
                    detail: "\(job.name): \(error.localizedDescription)",
                    status: "error",
                    payload: .object(["jobId": .string(job.id)])
                )
            }
            // Parent-cancel propagation (W3b Finding 2): if the scheduler loop was
            // stopped mid-job, executeWithTimeout returned the loud .cancelled
            // receipt (persisted just above). Stop here rather than starting the
            // remaining due rows — each would only mint its own cancelled receipt.
            if Task.isCancelled { break }
        }
        return completedNames
    }
}
