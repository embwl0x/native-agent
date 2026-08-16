import Foundation
import CryptoKit
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
        /// Stable identity for exactly one scheduled occurrence. This key is
        /// persisted before any effect and survives process restart.
        let occurrenceKey: String

        init(
            id: String,
            name: String,
            kind: String,
            payload: [String: JSONValue],
            row: JSONValue,
            dueEpoch: Double,
            occurrenceKey: String? = nil
        ) {
            self.id = id
            self.name = name
            self.kind = kind
            self.payload = payload
            self.row = row
            self.dueEpoch = dueEpoch
            self.occurrenceKey = occurrenceKey ?? Self.makeOccurrenceKey(jobId: id, dueEpoch: dueEpoch)
        }

        static func makeOccurrenceKey(jobId: String, dueEpoch: Double) -> String {
            let millis = Int64((dueEpoch * 1_000).rounded())
            let canonical = "\(jobId.utf8.count):\(jobId):\(millis)"
            let digest = SHA256.hash(data: Data(canonical.utf8))
                .map { String(format: "%02x", $0) }
                .joined()
            // 74 bytes: safely inside downstream 128-byte idempotency limits,
            // even when a repaired legacy job carries an unusually long id.
            return "scheduler.\(digest)"
        }
    }

    struct OccurrenceRecovery: Sendable {
        let jobId: String
        let jobName: String
        let kind: String
        let occurrenceKey: String
        let detail: String
    }

    struct ClaimedDueJobs: Sendable {
        let jobs: [DueJob]
        let recoveredUnknown: [OccurrenceRecovery]
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
    /// Bodies that crossed their caller-facing deadline but have not actually
    /// exited yet. A new scheduler pass must not overlap them.
    var inFlightJobBodies = 0
    var jobBodyExitWaiters: [CheckedContinuation<Void, Never>] = []

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

    /// Read the canonical scheduler array without converting damaged durable
    /// state into an empty genesis file. `readJSON(defaultValue:)` is right for
    /// optional projections, but unsafe at this authority boundary: callers
    /// immediately rewrite jobs.json and would erase every user job after one
    /// malformed byte. Missing is the only state that means an empty schedule.
    nonisolated static func readJobRowsChecked(at path: URL) throws -> [JSONValue] {
        guard FileManager.default.fileExists(atPath: path.path) else { return [] }
        let data = try Data(contentsOf: path)
        let parsed = try JSONValue.parse(data)
        guard case .array(let rows) = parsed else {
            throw PersistenceCoreError.ioFailure(
                "scheduler jobs state is not a JSON array: \(path.path)"
            )
        }
        return rows
    }

    func runDueJobs(maxJobs: Int = 5) async -> [String] {
        if running || inFlightJobBodies > 0 { return [] }
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

        var completedNames: [String] = []
        // Claim exactly one occurrence immediately before its effect. Claiming
        // a whole batch would make later untouched rows look ambiguous if the
        // process crashed while executing the first row.
        for _ in 0..<max(1, maxJobs) {
            let claimed: ClaimedDueJobs
            do {
                claimed = try await claimDueJobs(now: now, maxJobs: 1)
            } catch {
                try? await appendActivity(
                    jobId: nil,
                    kind: "scheduler",
                    title: "Scheduled job scan failed",
                    detail: error.localizedDescription,
                    status: "error",
                    payload: .object([:])
                )
                break
            }

            // A durable claim left by a prior process means the effect may
            // have happened. Never blindly replay it.
            for recovery in claimed.recoveredUnknown {
                await recordUnknownOccurrence(recovery)
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

    private func recordUnknownOccurrence(_ recovery: OccurrenceRecovery) async {
        try? await appendActivity(
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
        try? await appendNotificationInbox(
            title: "\(recovery.jobName) needs a quick check",
            message: recovery.detail,
            source: "scheduler_reconciliation",
            severity: "important",
            jobId: recovery.jobId,
            itemId: Self.reconciliationItemId(for: recovery.occurrenceKey)
        )
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
