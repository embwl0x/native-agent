import CryptoKit
import Privacy
import Foundation
import os
import NativeAgentCore
import PersistenceCore
import WorkshopExecution
// Blueprint: | `SchedulerJobs.swift` | Canonical bounded jobs, life-stamped occurrence claims and settlement; other-life (no stamp = first life) claims read stopped/restored, stay disabled until explicit Resume starts fresh; claimDueJobs, settleOccurrence, pruneJobs and upsertDefaultCycleJob |

// Canonical scheduled-job storage and occurrence transactions shared by UI,
// agent tools, and execution. Effects run only after a durable claim.

// MARK: - Errors (scheduler-job specific)

extension TriggerSchedulerError {
    /// The normalizer owns its cause and accepted input through every door.
    static func schedulerInvalid(_ msg: String, code: String = "schedule_input_invalid", path: String = "$") -> ToolFailureError {
        ToolFailureError(msg, argumentPath: path, accepted: msg, effects: .none,
                         nextCall: ToolFailureError.call("app", ["action": .string("schedule.list")]),
                         code: code, instruction: "Correct \(path) in the scheduled Desk task request; inspect saved tasks with next_call.",
                         recovery: .correctArguments)
    }
}

// MARK: - Protocol extension

/// The canonical scheduled-job read/write surface shared by every caller.
/// Activity receipts are best-effort after a job mutation commits.
public protocol SchedulerJobWriter: Sendable {
    /// Mirrors POST /v1/scheduler/jobs → create_job(body). `body` is the raw
    /// request dict (name/kind/interval_seconds/schedule/payload/run_at/...).
    /// Returns the persisted job dict (the daemon returns `job` verbatim).
    func createJob(body: JSONValue) async throws -> JSONValue

    /// Mirrors `Daemon.cancel_job(job_id)` — the
    /// connector-action `scheduler.cancel_job` backing call. Disables the job
    /// (`enabled=False`) and stamps `cancelledAt`, then appends a "warn"
    /// scheduler activity event. Returns `{"ok": true, "job": <updated job>}`.
    /// Throws for a blank id (Python `ValueError("jobId is required")`), and
    /// for an unknown or ambiguous one (`jobIndex`: a unique start of an id names its job).
    func cancelJob(jobId: String) async throws -> JSONValue

    /// Pause or resume one scheduled job — the write behind the Scheduler
    /// screen's enabled/paused control (Fable 5.1 sweep item 36). Returns
    /// `{"ok": true, "job": <updated job>}` and appends a scheduler activity
    /// receipt, exactly like `cancelJob`.
    ///
    /// Disabling stamps `enabled=false` + `pausedAt`; enabling clears both
    /// `pausedAt` and `cancelledAt`. The passive default-cycle bootstrap
    /// honors both markers, so neither flips itself back on.
    func setJobEnabled(jobId: String, enabled: Bool) async throws -> JSONValue

    /// Edit configuration in place under the canonical jobs lock. Runtime
    /// history and enablement are preserved; only a new schedule moves nextRunAt.
    func updateJob(jobId: String, changes: [String: JSONValue]) async throws -> JSONValue

    /// Mirrors `Daemon.list_jobs` — the READ side of
    /// `/v1/scheduler/jobs` (GET) and the `scheduler.list_jobs` connector action.
    /// Reads scheduler/jobs.json under the cross-process flock. Only a missing
    /// file is empty; existing malformed/non-list state fails closed. It then
    /// decorates each row's `nextRunAt` (float-string
    /// epoch → ISO-8601 UTC; adds `nextRunAtEpoch` + `nextRunAtISO`). Returns the
    /// decorated array verbatim (`[JSONValue]`).
    func listJobs() async throws -> [JSONValue]
}

// MARK: - SwiftNative create-job impl

extension SwiftNativeTriggerScheduler: SchedulerJobWriter {
    private static let jobActivityLogger = Logger(subsystem: "com.nativeagent.core", category: "scheduler-jobs")

    // Jobs are already committed; a missing activity receipt must not invite
    // a retry of the successful mutation.
    private nonisolated static func appendJobActivity(
        _ event: JSONValue,
        to path: URL,
        using persistence: any PersistenceCoreProtocol,
        logLabel: String
    ) async {
        do {
            try await SwiftNativePersistenceCore.appendActivityEvent(event, to: path,
                using: persistence, logLabel: logLabel)
        } catch {
            jobActivityLogger.error("Scheduled Desk task mutation committed, but activity receipt failed (\(logLabel, privacy: .public)): \(String(describing: error))")
        }
    }

    public nonisolated var jobsPath: URL {
        root
            .appendingPathComponent("scheduler", isDirectory: true)
            .appendingPathComponent("jobs.json")
    }

    public nonisolated var activityPath: URL {
        SwiftNativePersistenceCore.activityEventsPath(dataRoot: root)
    }

    /// Faithful port of Daemon.create_job:
    ///   job = normalize_scheduler_job_payload(body)
    ///   with jobs_lock, _jobs_file_lock(): append + write jobs.json
    ///   record_activity("scheduler", "Scheduled job created", ...)
    ///   return job
    ///
    /// connector_action kind validates against the Swift registry before write.
    public func createJob(body: JSONValue) async throws -> JSONValue {
        guard case .object(let obj) = body else {
            throw TriggerSchedulerError.schedulerInvalid("request body must be a JSON object")
        }

        let job = try SchedulerJobNormalizer.normalize(
            body: obj,
            now: now,
            uuid: uuid,
            displayNameFallback: Self.displayNameFallback,
            connectorActionIDs: connectorActionIDs
        )

        // Serialize mutations and hold the jobs-file lock across read-modify-write.
        _ = try await runSerialized { [persistence, jobsPath, activityPath, now, uuid] () async throws -> Int in
            let work: @Sendable () async throws -> Void = {
                // read-modify-write: append the new job (matches daemon).
                var jobs = try Self.readJobsChecked(at: jobsPath)
                if case .object(let newJob) = job,
                   jobs.contains(where: { row in
                       guard case .object(let existing) = row else { return false }
                       return SchedulerJobNormalizer.pyStrForId(existing["id"])
                           == SchedulerJobNormalizer.pyStrForId(newJob["id"])
                   }) {
                    throw TriggerSchedulerError.schedulerInvalid("A scheduled Desk task with this id already exists.")
                }
                jobs.append(job)
                let data = try Self.jobsDataForWrite(jobs)
                do {
                    try await persistence.writeDataAtomicDurable(data, to: jobsPath)
                } catch {
                    throw TriggerSchedulerError.persistenceFailure(String(describing: error))
                }
            }
            // Uniform locking (L7, 2026-08-01): `withFileLock` is a
            // PersistenceCoreProtocol EXTENSION (PersistenceCore+FileLock.swift:4), so
            // every conformer already has it. The old downcast to
            // SwiftNativePersistenceCore only had the effect of running this critical
            // section UNLOCKED for any other conformer.
            try await persistence.withFileLock(jobsPath, work)

            // Record creation through the shared activity-feed owner.
            let jobObj: [String: JSONValue]
            if case .object(let o) = job { jobObj = o } else { jobObj = [:] }
            let jobName = SchedulerJobNormalizer.string(jobObj["name"]) ?? ""
            let jobKind = SchedulerJobNormalizer.string(jobObj["kind"]) ?? ""
            let event = SwiftNativePersistenceCore.activityEvent(
                id: uuid(),
                kind: "scheduler",
                title: SchedulerSecretRedactor.redactText("Scheduled Desk task created"),
                detail: SchedulerSecretRedactor.redactText("\(jobName) · \(jobKind)"),
                status: "ok",
                executionId: nil,
                payload: SchedulerSecretRedactor.redactValue(.object([
                    "jobId": jobObj["id"] ?? .null,
                    "kind": jobObj["kind"] ?? .null,
                    "intervalSeconds": jobObj["intervalSeconds"] ?? .null,
                    "oneShot": jobObj["oneShot"] ?? .null,
                ])),
                createdAt: SwiftNativeTriggerScheduler.isoTimestamp(now())
            )
            await Self.appendJobActivity(
                event, to: activityPath, using: persistence,
                logLabel: "SchedulerJobs.create.activity"
            )
            return 0
        }

        return job
    }

    /// Faithful port of Daemon.cancel_job:
    ///   if not job_id: raise ValueError("jobId is required")
    ///   with jobs_lock, _jobs_file_lock():
    ///       jobs = read_json(...) (coerce non-list → [])
    ///       target = first job where str(job["id"]) == job_id
    ///           job["enabled"] = False; job["cancelledAt"] = now_iso()
    ///       if target is None: raise ValueError("Unknown scheduled job: …")
    ///       write_json(jobs)
    ///   record_activity("scheduler", "Scheduled job cancelled",
    ///                    str(target.name or job_id), "warn", payload={"jobId": …})
    ///   return {"ok": True, "job": dict(target)}
    ///
    /// Note: unlike `create_job`, the daemon's `cancel_job` was NOT exposed on an
    /// HTTP route — it is the backing call for the `scheduler.cancel_job`
    /// connector action. This SwiftNative impl gives
    /// the native write surface parity with that mutation. No connector-registry
    /// validation is involved for cancel because it takes only a job id.
    public func cancelJob(jobId: String) async throws -> JSONValue {
        // Python: `if not job_id:` — empty string is falsey. (The daemon receives
        // an already-`.strip()`ed id from the connector dispatch; we mirror the
        // method's own guard, which is the raw-emptiness check.)
        if jobId.isEmpty {
            throw TriggerSchedulerError.schedulerInvalid("jobId is required")
        }

        // Share createJob's serialization and jobs-file lock across read-modify-write.
        let updatedTarget: JSONValue = try await runSerialized {
            [persistence, jobsPath, now] () async throws -> JSONValue in
            // The R-M-W returns the updated target job. Throws on the not-found
            // path so no write happens (mirrors the daemon raising before write_json).
            let work: @Sendable () async throws -> JSONValue = {
                var jobs = try Self.readJobsChecked(at: jobsPath)
                // Thrown INSIDE the lock, so a miss writes nothing.
                let idx = try Self.jobIndex(jobs, id: jobId)
                guard case .object(var obj) = jobs[idx] else { throw TriggerSchedulerError.schedulerInvalid("Unknown scheduled Desk task: \(jobId)") }
                obj["enabled"] = .bool(false)
                obj.removeValue(forKey: "pausedAt")
                obj["cancelledAt"] = .string(SwiftNativeTriggerScheduler.isoTimestamp(now()))
                jobs[idx] = .object(obj)
                let target = JSONValue.object(obj)

                let data = try Self.jobsDataForWrite(jobs)
                do {
                    try await persistence.writeDataAtomicDurable(data, to: jobsPath)
                } catch {
                    throw TriggerSchedulerError.persistenceFailure(String(describing: error))
                }
                return target
            }
            // Uniform locking (L7, 2026-08-01): `withFileLock` is a
            // PersistenceCoreProtocol EXTENSION (PersistenceCore+FileLock.swift:4), so
            // every conformer already has it. The old downcast to
            // SwiftNativePersistenceCore only had the effect of running this critical
            // section UNLOCKED for any other conformer.
            return try await persistence.withFileLock(jobsPath, work)
        }

        // record_activity("scheduler", "Scheduled job cancelled",
        //                  str(target.get("name") or job_id), "warn", payload={"jobId": job_id})
        // → activity/events.jsonl. Swift-owned flock (mirror createJob / Connectors W20).
        let targetObj: [String: JSONValue]
        if case .object(let o) = updatedTarget { targetObj = o } else { targetObj = [:] }
        let jobId = SchedulerJobNormalizer.pyStrForId(targetObj["id"])  // the job a start of its id named
        // Python `str(target.get("name") or job_id)`: a falsey/absent name falls
        // back to the id (pyOr truthiness — empty string is falsey).
        let detailRaw = SchedulerJobNormalizer.string(
            SchedulerJobNormalizer.pyOr(targetObj["name"], .string(jobId))
        ) ?? jobId
        _ = try await runSerialized { [persistence, activityPath, uuid, now] () async throws -> Int in
            let event = SwiftNativePersistenceCore.activityEvent(
                id: uuid(),
                kind: "scheduler",
                title: SchedulerSecretRedactor.redactText("Scheduled Desk task disabled"),
                detail: SchedulerSecretRedactor.redactText(detailRaw),
                status: "warn",
                executionId: nil,
                payload: SchedulerSecretRedactor.redactValue(.object(["jobId": .string(jobId)])),
                createdAt: SwiftNativeTriggerScheduler.isoTimestamp(now())
            )
            await Self.appendJobActivity(
                event, to: activityPath, using: persistence,
                logLabel: "SchedulerJobs.cancel.activity"
            )
            return 0
        }

        // Daemon returns `{"ok": True, "job": dict(target)}`.
        return .object(["ok": .bool(true), "job": updatedTarget])
    }

    /// Pause / resume one scheduled job. Same locked read-modify-write and
    /// activity receipt as `cancelJob`, with a separate pause marker.
    public func setJobEnabled(jobId: String, enabled: Bool) async throws -> JSONValue {
        if jobId.isEmpty {
            throw TriggerSchedulerError.schedulerInvalid("jobId is required")
        }

        let updatedTarget: JSONValue = try await runSerialized {
            [persistence, jobsPath, now, root] () async throws -> JSONValue in
            let work: @Sendable () async throws -> JSONValue = {
                var jobs = try Self.readJobsChecked(at: jobsPath)
                let idx = try Self.jobIndex(jobs, id: jobId)
                guard case .object(var obj) = jobs[idx] else { throw TriggerSchedulerError.schedulerInvalid("Unknown scheduled Desk task: \(jobId)") }
                obj["enabled"] = .bool(enabled)
                if enabled {
                    if case .object(let claim)? = obj["activeOccurrence"],
                       try !DataRootLife.isCurrent(SchedulerJobRuntime.string(claim["lifeID"]), in: root) {
                        obj["lastRunStatus"] = .string("stopped")
                        obj["lastRunDetail"] = .string(DataRootLife.stoppedReason)
                        obj.removeValue(forKey: "activeOccurrence")
                        Self.clearRetryState(&obj)
                    }
                    // Resume also clears a cancel (and legacy pauses,
                    // which were stored as cancels).
                    obj.removeValue(forKey: "pausedAt")
                    obj.removeValue(forKey: "cancelledAt")
                    obj.removeValue(forKey: "disabledReason")
                } else {
                    obj["pausedAt"] = .string(SwiftNativeTriggerScheduler.isoTimestamp(now()))
                }
                jobs[idx] = .object(obj)
                let target = JSONValue.object(obj)
                let data = try Self.jobsDataForWrite(jobs)
                do {
                    try await persistence.writeDataAtomicDurable(data, to: jobsPath)
                } catch {
                    throw TriggerSchedulerError.persistenceFailure(String(describing: error))
                }
                return target
            }
            return try await persistence.withFileLock(jobsPath, work)
        }

        let targetObj: [String: JSONValue]
        if case .object(let o) = updatedTarget { targetObj = o } else { targetObj = [:] }
        let jobId = SchedulerJobNormalizer.pyStrForId(targetObj["id"])  // the job a start of its id named
        let detailRaw = SchedulerJobNormalizer.string(
            SchedulerJobNormalizer.pyOr(targetObj["name"], .string(jobId))
        ) ?? jobId
        let title = enabled ? "Scheduled Desk task resumed" : "Scheduled Desk task paused"
        _ = try await runSerialized { [persistence, activityPath, uuid, now] () async throws -> Int in
            let event = SwiftNativePersistenceCore.activityEvent(
                id: uuid(),
                kind: "scheduler",
                title: SchedulerSecretRedactor.redactText(title),
                detail: SchedulerSecretRedactor.redactText(detailRaw),
                status: enabled ? "ok" : "warn",
                executionId: nil,
                payload: SchedulerSecretRedactor.redactValue(.object([
                    "jobId": .string(jobId),
                    "enabled": .bool(enabled),
                ])),
                createdAt: SwiftNativeTriggerScheduler.isoTimestamp(now())
            )
            await Self.appendJobActivity(
                event, to: activityPath, using: persistence,
                logLabel: "SchedulerJobs.setEnabled.activity"
            )
            return 0
        }

        return .object(["ok": .bool(true), "job": updatedTarget])
    }

    public func updateJob(jobId: String, changes: [String: JSONValue]) async throws -> JSONValue {
        func invalid(_ message: String, path: String, accepted: String) -> ToolFailureError {
            ToolFailureError(message, argumentPath: path, accepted: accepted, effects: .none,
                             nextCall: ToolFailureError.call("app", ["action": .string("schedule.list")]),
                             code: "schedule_input_invalid", instruction: "Correct \(path) using the accepted input; inspect saved tasks with next_call.",
                             recovery: .correctArguments)
        }
        guard !jobId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw invalid("jobId is required", path: "$.job_id", accepted: Self.jobIDAccepted)
        }
        let changes = changes.filter { $0.value != .null }
        let allowed: Set<String> = ["name", "kind", "payload", "schedule", "interval_seconds"]
        guard !changes.isEmpty, Set(changes.keys).isSubset(of: allowed) else {
            throw invalid("Supply at least one of name, kind, payload, schedule, interval_seconds; other fields cannot be edited.", path: "$", accepted: "At least one of name, kind, payload, schedule, interval_seconds; no other edit fields.")
        }
        if let name = changes["name"] {
            guard case .string(let value) = name,
                  !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  value.count <= 160 else {
                throw invalid("name must contain 1-160 characters", path: "$.name", accepted: "A nonblank string of 1-160 characters.")
            }
        }
        if let kind = changes["kind"] {
            guard case .string(let value) = kind,
                  SchedulerJobNormalizer.allowedKinds.contains(value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()) else {
                throw invalid("kind must name a supported scheduled Desk task kind", path: "$.kind", accepted: SchedulerJobNormalizer.allowedKinds.sorted().joined(separator: ", "))
            }
        }
        if let payload = changes["payload"] {
            guard case .object = payload else {
                throw invalid("payload must be an object", path: "$.payload", accepted: "An object containing parameters for the scheduled Desk task kind.")
            }
        }
        if let schedule = changes["schedule"] {
            switch schedule {
            case .object, .string: break
            default:
                throw invalid("schedule must be an object or ISO-8601 datetime string", path: "$.schedule", accepted: "An ISO-8601 datetime string or an object with type once, every, hourly, daily, weekly, monthly or cron and its required fields.")
            }
        }
        if let interval = changes["interval_seconds"] {
            guard case .int(let seconds) = interval, seconds >= 60 else {
                throw invalid("interval_seconds must be an integer of at least 60", path: "$.interval_seconds", accepted: "An integer of at least 60.")
            }
            guard changes["schedule"] == nil else {
                throw invalid("Supply schedule or interval_seconds, not both.", path: "$.schedule", accepted: "Supply schedule or interval_seconds, not both.")
            }
        }

        let updated = try await runSerialized {
            [persistence, jobsPath, now, uuid, connectorActionIDs] () async throws -> JSONValue in
            try await persistence.withFileLock(jobsPath) {
                var jobs = try Self.readJobsChecked(at: jobsPath)
                let index = try Self.jobIndex(jobs, id: jobId)
                guard case .object(var existing) = jobs[index] else {
                    throw ToolFailureError("Unknown scheduled Desk task: \(jobId)", argumentPath: "$.job_id", accepted: Self.jobIDAccepted, effects: .none)
                }
                var body = existing
                for (key, value) in changes { body[key] = value }
                let newKind = SchedulerJobNormalizer.string(changes["kind"])?
                    .trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                let kindChanged = newKind != nil && newKind != SchedulerJobNormalizer.string(existing["kind"])
                if kindChanged, changes["payload"] == nil {
                    throw ToolFailureError("Changing kind requires the complete payload for the new kind.", argumentPath: "$.payload", accepted: "The complete payload for the new kind.", effects: .none)
                }
                if !kindChanged, case .object(let patch)? = changes["payload"],
                   case .object(var payload)? = existing["payload"] {
                    payload.merge(patch) { _, new in new }
                    body["payload"] = .object(payload)
                }
                let rescheduled = changes["schedule"] != nil || changes["interval_seconds"] != nil
                if let interval = changes["interval_seconds"] {
                    body["schedule"] = .object(["type": .string("every"), "interval_seconds": interval])
                }
                if rescheduled {
                    body.removeValue(forKey: "oneShot")
                    body.removeValue(forKey: "one_shot")
                    if case .object(var payload)? = body["payload"] {
                        payload.removeValue(forKey: "one_shot")
                        body["payload"] = .object(payload)
                    }
                    body.removeValue(forKey: "run_at")
                    body.removeValue(forKey: "runAt")
                }
                let result = try SchedulerJobNormalizer.normalize(
                    body: body, now: now, uuid: uuid,
                    displayNameFallback: Self.displayNameFallback,
                    connectorActionIDs: connectorActionIDs)
                guard case .object(let normalized) = result else {
                    throw TriggerSchedulerError.schedulerInvalid("Scheduled Desk task normalization produced no task")
                }
                if changes["name"] != nil { existing["name"] = normalized["name"] }
                if changes["kind"] != nil { existing["kind"] = normalized["kind"] }
                if changes["payload"] != nil || rescheduled { existing["payload"] = normalized["payload"] }
                if rescheduled {
                    for key in ["schedule", "intervalSeconds", "oneShot", "nextRunAt", "nextRunAtEpoch", "nextWallClockOccurrence"] {
                        existing[key] = normalized[key]
                    }
                    existing.removeValue(forKey: "nextRunAtISO")
                    existing.removeValue(forKey: "completedAt")
                    existing["scheduleGeneration"] = .string(uuid())
                    for key in ["retryCount", "retryDayKey", "retryPendingUntilEpoch", "retryParkedDateKey"] {
                        existing.removeValue(forKey: key)
                    }
                }
                jobs[index] = .object(existing)
                let data = try Self.jobsDataForWrite(jobs)
                do {
                    try await persistence.writeDataAtomicDurable(data, to: jobsPath)
                } catch {
                    throw TriggerSchedulerError.persistenceFailure(String(describing: error))
                }
                return .object(existing)
            }
        }
        let jobId = if case .object(let row) = updated { SchedulerJobNormalizer.pyStrForId(row["id"]) } else { jobId }
        let event = SwiftNativePersistenceCore.activityEvent(
            id: uuid(),
            kind: "scheduler",
            title: "Scheduled Desk task updated",
            detail: SchedulerSecretRedactor.redactText(jobId),
            status: "ok",
            executionId: nil,
            payload: SchedulerSecretRedactor.redactValue(.object(["jobId": .string(jobId)])),
            createdAt: Self.isoTimestamp(now())
        )
        do {
            try await SwiftNativePersistenceCore.appendActivityEvent(event, to: activityPath,
                using: persistence, logLabel: "SchedulerJobs.update.activity")
        } catch {
            throw ToolFailureError("The scheduled Desk task was updated, but recording its activity failed: \(error)", effects: .occurred)
        }
        return .object(["ok": .bool(true), "job": updated])
    }

    /// Read under the same serialization and jobs-file lock as mutations,
    /// then project timing with `decorateNextRunAt`. Only absence is empty.
    public func listJobs() async throws -> [JSONValue] {
        try await listJobsIfPresent() ?? []
    }

    /// The same decorated snapshot, retaining absence for read-only surfaces.
    public func listJobsIfPresent() async throws -> [JSONValue]? {
        try await runSerialized { [persistence, jobsPath] in
            try await persistence.withFileLock(jobsPath) {
                guard FileManager.default.fileExists(atPath: jobsPath.path) else { return nil as [JSONValue]? }
                return try Self.readJobsChecked(at: jobsPath).map { SchedulerJobNormalizer.decorateNextRunAt($0) }
            }
        }
    }

    /// APP constant from the daemon. Used as the
    /// notify-title / name fallback. See PARITY DIVERGENCES in the header.
    nonisolated static var displayNameFallback: String { "NativeAgent" }

    /// Every writer, including occurrence settlement, must stay readable by
    /// the canonical job reader. Validate the exact bytes before replacement.
    public nonisolated static func jobsDataForWrite(_ rows: [JSONValue]) throws -> Data {
        guard rows.count <= 1_024 else {
            throw ToolFailureError("scheduler/jobs.json would exceed 1024 rows.", effects: .none,
                                   nextCall: ToolFailureError.call("app", ["action": .string("schedule.list")]),
                                   code: "schedule_store_row_limit", instruction: "The task store is full. schedule.delete only turns a task off; completed tasks leave after seven days of retention. Tell the person no new task can be saved until then.", recovery: .inspect)
        }
        let data = try JSONValue.array(rows).serializedData(pretty: true)
        guard data.count <= 4 * 1_024 * 1_024 else {
            throw ToolFailureError("scheduler/jobs.json would exceed 4 MiB.", effects: .none,
                                   nextCall: ToolFailureError.call("app", ["action": .string("schedule.list")]),
                                   code: "schedule_store_byte_limit", instruction: "The task store is at its size limit. Reduce the proposed payload; schedule.delete only turns a task off, and completed tasks leave after seven days of retention.", recovery: .inspect)
        }
        return data
    }

    /// Scheduler jobs are authority state. Only a missing file means an empty
    /// schedule; malformed or wrongly typed existing bytes must not be
    /// reinterpreted as a dormant empty schedule and then overwritten by the
    /// next create/cancel mutation.
    /// The one place a job id is read: the exact id (Python `str(id)`, so a
    /// row with no id answers "None"), else the one job whose id it starts.
    /// An unknown id, or a start several jobs share, refuses and names them.
    nonisolated static func jobIndex(_ jobs: [JSONValue], id jobId: String) throws -> Int {
        let ids = jobs.map { if case .object(let row) = $0 { SchedulerJobNormalizer.pyStrForId(row["id"]) } else { "" } }
        if !jobId.isEmpty, let exact = ids.firstIndex(of: jobId) { return exact }
        let matches = ids.indices.filter { !jobId.isEmpty && !ids[$0].isEmpty && ids[$0].lowercased().hasPrefix(jobId.lowercased()) }
        guard matches.count == 1 else {
            throw ToolFailureError(matches.isEmpty ? "Unknown scheduled Desk task: \(jobId)"
                : "\(jobId) starts \(matches.count) task IDs: \(matches.map { ids[$0] }.joined(separator: ", ")). Give a longer ID.",
                argumentPath: "$.job_id", accepted: jobIDAccepted, effects: .none)
        }
        return matches[0]
    }

    static let jobIDAccepted = "A scheduled Desk task ID from schedule.list, or an unambiguous prefix."

    public nonisolated static func readJobsChecked(at path: URL) throws -> [JSONValue] {
        let manager = FileManager.default
        guard manager.fileExists(atPath: path.path) else { return [] }
        do {
            let data = try Data(contentsOf: path)
            guard data.count <= 4 * 1_024 * 1_024 else {
                throw Self.jobStoreReadFailure("Saved task array exceeds 4 MiB.", code: "schedule_store_byte_limit", path: path)
            }
            let raw = try JSONValue.parse(data)
            guard case .array(let rows) = raw else {
                throw Self.jobStoreReadFailure("Saved scheduled Desk tasks are not a JSON array.", code: "schedule_store_shape_invalid", path: path)
            }
            guard rows.count <= 1_024 else {
                throw Self.jobStoreReadFailure("Saved task array exceeds 1024 rows.", code: "schedule_store_row_limit", path: path)
            }
            // User 10-21: a zone saved before schedules followed the Mac is dropped
            // here, so an edit never trips on it; normalize refuses only a new one.
            return rows.map { row in
                guard case .object(var job) = row, case .object(var schedule)? = job["schedule"] else { return row }
                schedule["timezone"] = nil
                schedule["tz"] = nil
                job["schedule"] = .object(schedule)
                return .object(job)
            }
        } catch let error as ToolFailureError {
            throw error
        } catch {
            throw Self.jobStoreReadFailure(error.localizedDescription, code: "schedule_store_unreadable", path: path)
        }
    }

    private nonisolated static func jobStoreReadFailure(_ detail: String, code: String, path: URL) -> ToolFailureError {
        ToolFailureError(detail, effects: .none, owner: path.path,
                         nextCall: ToolFailureError.call("app", ["action": .string("files.info"), "args": .object(["path": .string(path.path)])]),
                         code: code, instruction: "Inspect the file with next_call, then repair its saved array or access. Preserve occurrence and delivery evidence.", recovery: .repair)
    }
}

extension SwiftNativeTriggerScheduler {
    public struct DueJob: Sendable {
        public let id: String
        public let name: String
        public let kind: String
        public let payload: [String: JSONValue]
        public let row: JSONValue
        public let dueEpoch: Double
        /// Stable identity for exactly one scheduled occurrence. This key is
        /// persisted before any effect and survives process restart.
        public let occurrenceKey: String

        public init(
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
            let civil: String? = if case .object(let object) = row, object["retryPendingUntilEpoch"] == nil {
                SchedulerJobRuntime.wallClockOccurrence(for: object, epoch: dueEpoch)
            } else { nil }
            self.occurrenceKey = occurrenceKey ?? Self.makeOccurrenceKey(jobId: id, dueEpoch: dueEpoch, civil: civil)
        }

        static func makeOccurrenceKey(jobId: String, dueEpoch: Double, civil: String? = nil) -> String {
            let millis = Int64((dueEpoch * 1_000).rounded())
            let canonical = "\(jobId.utf8.count):\(jobId):\(civil ?? String(millis))"
            let digest = SHA256.hash(data: Data(canonical.utf8))
                .map { String(format: "%02x", $0) }
                .joined()
            // 74 bytes: safely inside downstream 128-byte idempotency limits,
            // even when a repaired legacy job carries an unusually long id.
            return "scheduler.\(digest)"
        }
    }

    public struct OccurrenceRecovery: Sendable {
        public let jobId: String
        public let jobName: String
        public let kind: String
        public let occurrenceKey: String
        public let detail: String
        public var reason: String? = nil
    }

    public struct ClaimedDueJobs: Sendable {
        public let jobs: [DueJob]
        public let recoveredUnknown: [OccurrenceRecovery]
    }

    public func jobRows() async throws -> [JSONValue] {
        try await persistence.withFileLock(jobsPath) {
            let life = try DataRootLife.current(in: root)
            return try Self.readJobsChecked(at: jobsPath).map { row in
                guard case .object(var object) = row, case .object(var claim)? = object["activeOccurrence"],
                      DataRootLife.life(of: claim["lifeID"]) != life else { return row }
                claim["state"] = .string("stopped")
                claim["reason"] = .string(DataRootLife.stoppedReason)
                object["activeOccurrence"] = .object(claim)
                return .object(object)
            }
        }
    }

    public func updateJobRows<Result: Sendable>(
        _ update: @Sendable (inout [JSONValue]) throws -> Result
    ) async throws -> Result {
        try await persistence.withFileLock(jobsPath) {
            let original = try Self.readJobsChecked(at: jobsPath)
            var rows = original
            let result = try update(&rows)
            if rows != original {
                try await persistence.writeDataAtomicDurable(Self.jobsDataForWrite(rows), to: jobsPath)
            }
            return result
        }
    }

    /// Claim the first selected occurrence under the jobs lock, before effects.
    /// Same-life restart claims need reconciliation; another life's are stopped.
    public func claimDueJobs(
        now: Date,
        select: @Sendable ([JSONValue]) -> [DueJob]
    ) async throws -> ClaimedDueJobs {
        try await persistence.withFileLock(jobsPath) { () async throws -> ClaimedDueJobs in
            var rows = try Self.readJobsChecked(at: jobsPath)
            let life = try DataRootLife.current(in: root)
            var changed = false
            for index in rows.indices {
                guard case .object(var object) = rows[index] else { continue }
                var rowChanged = Self.rearmFutureOneShot(&object, now: now, life: life)
                if object["nextWallClockOccurrence"] == nil,
                   let occurrence = SchedulerJobRuntime.nextWallClockOccurrence(for: object) {
                    object["nextWallClockOccurrence"] = .string(occurrence)
                    rowChanged = true
                }
                guard rowChanged else { continue }
                rows[index] = .object(object)
                changed = true
            }
            let selected = select(rows).prefix(1)
            var claimed: [DueJob] = []
            var recovered: [OccurrenceRecovery] = []
            for job in selected {
                guard let index = rows.firstIndex(where: { row in
                    guard case .object(let object) = row else { return false }
                    return SchedulerJobRuntime.string(object["id"]) == job.id
                }), case .object(var object) = rows[index] else { continue }

                if let activeValue = object["activeOccurrence"] {
                    let restored = DataRootLife.life(of: activeValue.objectValue?["lifeID"]) != life
                    let decodedPriorKey: String?
                    if case .object(let active) = activeValue {
                        decodedPriorKey = SchedulerJobRuntime.string(active["key"])
                    } else {
                        decodedPriorKey = nil
                    }
                    let priorKey = decodedPriorKey ?? job.occurrenceKey
                    let detail: String
                    if restored {
                        detail = DataRootLife.stoppedReason
                    } else if decodedPriorKey == nil {
                        detail = "A prior scheduler occurrence claim was malformed. Its external effect "
                            + "may have happened, so NativeAgent preserved the claim and did not repeat it."
                    } else {
                        detail = "A prior scheduler pass ended after claiming occurrence \(priorKey). "
                            + "Its external effect may have happened, so NativeAgent did not repeat it."
                    }
                    // Keep the claim until settleUnknownOccurrence has its durable notice.
                    recovered.append(OccurrenceRecovery(
                        jobId: job.id,
                        jobName: job.name,
                        kind: job.kind,
                        occurrenceKey: priorKey,
                        detail: detail, reason: restored ? DataRootLife.stoppedReason : nil
                    ))
                    continue
                }

                // A recurring job settles each occurrence once; it moves past a
                // settled key instead of claiming it again. (A one-shot's resume
                // reruns its one occurrence on purpose.)
                if !SchedulerJobRuntime.bool(object["oneShot"], default: false),
                   SchedulerJobRuntime.string(object["lastOccurrenceKey"]) == job.occurrenceKey {
                    if let next = try? SchedulerJobRuntime.nextRunEpochAfterNow(
                        for: .object(object), beyond: job.dueEpoch, now: { now }
                    ) {
                        Self.stampNextRun(&object, epoch: next)
                    } else {
                        object["enabled"] = .bool(false)
                        object["disabledReason"] = .string("could not compute next scheduled run")
                    }
                    rows[index] = .object(object)
                    changed = true
                    continue
                }

                var claim: [String: JSONValue] = [
                    "key": .string(job.occurrenceKey),
                    "dueEpoch": .int(Int64(job.dueEpoch.rounded())),
                    "claimedAt": .string(Self.isoTimestamp(now)),
                    "state": .string("claimed"),
                    "lifeID": .string(life),
                ]
                claim["scheduleGeneration"] = object["scheduleGeneration"]
                object["activeOccurrence"] = .object(claim)
                Self.stampNextRun(&object, epoch: job.dueEpoch)
                rows[index] = .object(object)
                claimed.append(job)
            }
            // Detecting a stale claim does not itself change canonical state.
            if changed || !claimed.isEmpty {
                try await persistence.writeDataAtomicDurable(SwiftNativeTriggerScheduler.jobsDataForWrite(rows), to: jobsPath)
            }
            return ClaimedDueJobs(jobs: claimed, recoveredUnknown: recovered)
        }
    }

    private static func rearmFutureOneShot(_ object: inout [String: JSONValue], now: Date, life: String) -> Bool {
        guard SchedulerJobRuntime.bool(object["oneShot"], default: false),
              SchedulerJobRuntime.bool(object["enabled"], default: true),
              SchedulerJobRuntime.string(object["cancelledAt"]) == nil,
              case .object(let claim)? = object["activeOccurrence"],
              DataRootLife.life(of: claim["lifeID"]) == life,
              Set(claim.keys).isSubset(of: ["key", "dueEpoch", "claimedAt", "state", "lifeID"]),
              SchedulerJobRuntime.string(claim["key"])?.isEmpty == false,
              SchedulerJobRuntime.string(claim["state"]) == "claimed",
              let claimedAt = SchedulerJobRuntime.string(claim["claimedAt"]).flatMap(NativeTimestampFormat.parseISO8601FractionalFirst),
              let claimedDue = SchedulerJobRuntime.epoch(from: claim["dueEpoch"]),
              claimedDue.isFinite,
              // A rewind cannot make a due-time claim evidence of non-execution.
              // Round up to avoid mistaking the stored dueEpoch's rounding for it.
              claimedDue > claimedAt.timeIntervalSince1970.rounded(.up),
              let due = SchedulerJobRuntime.epoch(from: object["nextRunAt"])
                ?? SchedulerJobRuntime.epoch(from: object["nextRunAtEpoch"]),
              due > now.timeIntervalSince1970 else { return false }
        object.removeValue(forKey: "activeOccurrence")
        clearRetryState(&object)
        return true
    }

    /// Settle a retained claim after its notice; a stopped life waits for Resume.
    public func settleUnknownOccurrence(_ recovery: OccurrenceRecovery, now: Date) async throws {
        try await persistence.withFileLock(jobsPath) { () async throws -> Void in
            var rows = try Self.readJobsChecked(at: jobsPath)
            guard let index = rows.firstIndex(where: { row in
                guard case .object(let object) = row else { return false }
                return SchedulerJobRuntime.string(object["id"]) == recovery.jobId
            }), case .object(var object) = rows[index],
                let activeValue = object["activeOccurrence"] else { return }
            if recovery.reason != nil, try DataRootLife.isCurrent(SchedulerJobRuntime.string(activeValue.objectValue?["lifeID"]), in: root) { return }
            if Self.rearmFutureOneShot(&object, now: now, life: try DataRootLife.current(in: root)) {
                rows[index] = .object(object)
                try await persistence.writeDataAtomicDurable(SwiftNativeTriggerScheduler.jobsDataForWrite(rows), to: jobsPath)
                return
            }
            var decodedPriorKey: String?
            var replacedSchedule = false
            var claimedDue: Double?
            if case .object(let active) = activeValue {
                claimedDue = SchedulerJobRuntime.epoch(from: active["dueEpoch"])
                decodedPriorKey = SchedulerJobRuntime.string(active["key"])
                if case .string(let key)? = active["key"], !key.isEmpty {
                    replacedSchedule = object["scheduleGeneration"] != active["scheduleGeneration"]
                }
            }
            if decodedPriorKey == nil { object["lastInvalidOccurrenceClaim"] = activeValue }
            object["lastRunAt"] = .string(Self.isoTimestamp(now))
            object["lastRunStatus"] = .string(recovery.reason == nil ? "unknown" : "stopped")
            object["lastRunDetail"] = .string(recovery.detail)
            object["lastRunError"] = .string(recovery.detail)
            object["lastUnknownOccurrenceKey"] = .string(recovery.occurrenceKey)
            object.removeValue(forKey: "activeOccurrence")
            if recovery.reason != nil {
                object["enabled"] = .bool(false)
                object["disabledReason"] = .string(DataRootLife.stoppedReason)
            } else if replacedSchedule {
                // The unknown result belongs to the old schedule, not its replacement.
            } else if SchedulerJobRuntime.bool(object["oneShot"], default: false) {
                object["enabled"] = .bool(false)
                object["disabledReason"] = .string("unknown outcome after restart; review before retry")
            } else if let next = try? SchedulerJobRuntime.nextRunEpochAfterNow(
                for: .object(object), beyond: claimedDue, now: { now }
            ) {
                Self.stampNextRun(&object, epoch: next)
            } else {
                object["enabled"] = .bool(false)
                object["disabledReason"] = .string("unknown outcome and next run could not be computed")
            }
            // Unknown means "do not automatically replay." Any prior retry
            // floor/counter would contradict that settlement and could re-arm
            // the same occurrence through catch-up logic.
            Self.clearRetryState(&object)
            rows[index] = .object(object)
            try await persistence.writeDataAtomicDurable(SwiftNativeTriggerScheduler.jobsDataForWrite(rows), to: jobsPath)
        }
    }

    public func settleOccurrence(
        jobId: String, occurrenceKey: String, status: String, detail: String,
        output: JSONValue, at runDate: Date, runDateKey: String
    ) async throws {
        try await persistence.withFileLock(jobsPath) {
            var rows = try Self.readJobsChecked(at: jobsPath)
            var found = false
            for idx in rows.indices {
                guard case .object(var obj) = rows[idx],
                      (SchedulerJobRuntime.string(obj["id"]) ?? "") == jobId else {
                    continue
                }
                guard case .object(let active)? = obj["activeOccurrence"],
                      SchedulerJobRuntime.string(active["key"]) == occurrenceKey else {
                    throw NSError(domain: "NativeAgentScheduler", code: -409, userInfo: [
                        NSLocalizedDescriptionKey: "scheduler_claim_changed: Claim changed before settlement: \(occurrenceKey). Effects may have occurred; inspect scheduler/jobs.json and the delivery receipts before resuming this scheduled Desk task."
                    ])
                }
                found = true
                obj["lastRunAt"] = .string(Self.isoTimestamp(runDate))
                obj["lastRunStatus"] = .string(status)
                obj["lastRunDetail"] = .string(String(detail.prefix(1000)))
                if status == "error" {
                    obj["lastRunError"] = .string(String(detail.prefix(1000)))
                } else {
                    obj.removeValue(forKey: "lastRunError")
                }

                let oneShot = SchedulerJobRuntime.bool(obj["oneShot"], default: false)
                if obj["scheduleGeneration"] != active["scheduleGeneration"] {
                    // Keep the run's evidence without consuming the newly saved schedule.
                } else if oneShot {
                    obj["enabled"] = .bool(false)
                    if status == "completed" {
                        obj["completedAt"] = .string(Self.isoTimestamp(runDate))
                    } else {
                        obj.removeValue(forKey: "completedAt")
                        obj["pausedAt"] = .string(Self.isoTimestamp(runDate))
                        obj["disabledReason"] = .string("occurrence was not completed; review its retained result before resuming")
                    }
                    Self.clearRetryState(&obj)
                } else if let next = try? SchedulerJobRuntime.nextRunEpochAfterNow(
                    for: .object(obj), beyond: SchedulerJobRuntime.epoch(from: active["dueEpoch"]), now: { runDate }
                ) {
                    Self.stampNextRun(&obj, epoch: next)
                    Self.clearRetryState(&obj)
                } else {
                    obj["enabled"] = .bool(false)
                    obj["disabledReason"] = .string("could not compute next scheduled run")
                    Self.clearRetryState(&obj)
                }
                obj["lastOccurrenceKey"] = .string(occurrenceKey)
                obj.removeValue(forKey: "activeOccurrence")
                rows[idx] = .object(obj)
                break
            }
            guard found else {
                throw NSError(domain: "NativeAgentScheduler", code: -404, userInfo: [
                    NSLocalizedDescriptionKey: "scheduler_job_missing: Scheduled Desk task \(jobId) disappeared before settlement. Effects may have occurred; inspect scheduler/jobs.json and the delivery receipts before recreating it."
                ])
            }
            try await persistence.writeDataAtomicDurable(SwiftNativeTriggerScheduler.jobsDataForWrite(rows), to: jobsPath)
        }

    }

    /// Record retirement durably before removing rows under the jobs lock;
    /// a kept row the selection changed (paused) is written too.
    @discardableResult
    public func pruneJobs(
        select: @Sendable ([JSONValue]) -> (rows: [JSONValue], retired: [JSONValue])
    ) async throws -> Int {
        try await persistence.withFileLock(jobsPath) { () async throws -> Int in
            let rows = try Self.readJobsChecked(at: jobsPath)
            let result = select(rows)
            guard !result.retired.isEmpty || result.rows != rows else { return 0 }
            if !result.retired.isEmpty {
                try await SwiftNativePersistenceCore().appendJSONLDurable(result.retired, to: jobsPath.deletingLastPathComponent()
                    .appendingPathComponent("retired.jsonl"))
            }
            try await persistence.writeDataAtomicDurable(SwiftNativeTriggerScheduler.jobsDataForWrite(result.rows), to: jobsPath)
            return result.retired.count
        }
    }

    public func markDefaultCycleJobRun(id: String, detail: String, at runDate: Date) async throws {
        try await persistence.withFileLock(jobsPath) {
            var rows = try Self.readJobsChecked(at: jobsPath)
            for idx in rows.indices {
                guard case .object(var obj) = rows[idx],
                      (SchedulerJobRuntime.string(obj["id"]) ?? "") == id else {
                    continue
                }
                obj["lastRunAt"] = .string(Self.isoTimestamp(runDate))
                obj["lastRunStatus"] = .string("completed")
                obj["lastRunDetail"] = .string(detail)
                obj.removeValue(forKey: "lastRunError")
                // FIX 2 (A4.4): a successful/backfilled completion clears the
                // retry backoff so it self-heals once the outage clears.
                Self.clearRetryState(&obj)
                if let next = try? SchedulerJobRuntime.nextRunEpochAfterNow(for: .object(obj), now: { runDate }) {
                    Self.stampNextRun(&obj, epoch: next)
                }
                rows[idx] = .object(obj)
                break
            }
            try await persistence.writeDataAtomicDurable(SwiftNativeTriggerScheduler.jobsDataForWrite(rows), to: jobsPath)
        }
    }

    public nonisolated static func upsertDefaultCycleJob(
        rows: inout [JSONValue],
        id: String,
        legacyNames: Set<String>,
        name: String,
        kind: String,
        intervalSeconds: Int,
        schedule: [String: JSONValue],
        objective: String,
        extraPayload: [String: JSONValue],
        nextRunEpoch: @autoclosure () throws -> Double,
        now: Date,
        reactivateCancelled: Bool = false
    ) throws -> (changed: Bool, job: JSONValue) {
        let matchIndex = rows.firstIndex { row in
            guard case .object(let obj) = row else { return false }
            let rowID = SchedulerJobRuntime.string(obj["id"]) ?? ""
            if rowID == id { return true }
            let rowKind = (SchedulerJobRuntime.string(obj["kind"]) ?? "").lowercased()
            let rowName = (SchedulerJobRuntime.string(obj["name"]) ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            return rowKind == kind && legacyNames.contains(rowName)
        }

        var existing: [String: JSONValue] = [:]
        if let matchIndex, case .object(let obj) = rows[matchIndex] {
            existing = obj
        }

        // Passive bootstrap honors cancellation; only explicit reactivation clears it.
        let isCancelledTombstone = existing["cancelledAt"] != nil
            && existing["enabled"] == .bool(false)
        // Pauses survive bootstrap; only setJobEnabled resumes them.
        let isPaused = existing["pausedAt"] != nil
            && existing["enabled"] == .bool(false)
        if isPaused || (isCancelledTombstone && !reactivateCancelled) {
            return (false, .object(existing))
        }

        var next = existing
        if isCancelledTombstone, reactivateCancelled {
            next.removeValue(forKey: "cancelledAt")
            next["enabled"] = .bool(true)
        }
        // Bootstrap fills missing fields; the canonical writer owns saved edits.
        next["id"] = existing["id"] ?? .string(id)
        next["name"] = existing["name"] ?? .string(name)
        next["kind"] = existing["kind"] ?? .string(kind)
        // Legacy interval metadata; recurrence uses `schedule` whenever present.
        next["intervalSeconds"] = existing["intervalSeconds"] ?? .int(Int64(intervalSeconds))
        next["enabled"] = next["enabled"] ?? .bool(true)
        next["oneShot"] = existing["oneShot"] ?? .bool(false)
        next["schedule"] = existing["schedule"] ?? .object(schedule)
        var payload = extraPayload
        payload["objective"] = .string(objective)
        next["payload"] = existing["payload"] ?? .object(payload)
        next["createdBy"] = existing["createdBy"] ?? .string("nativeagent_bootstrap")
        next["createdAt"] = existing["createdAt"] ?? .string(isoTimestamp(now))
        if existing["nextRunAt"] == nil && existing["nextRunAtEpoch"] == nil {
            let nextRunEpoch = try nextRunEpoch()
            stampNextRun(&next, epoch: nextRunEpoch)
            if existing["schedule"] == nil, nextRunEpoch <= now.timeIntervalSince1970 {
                var firstSchedule = schedule
                firstSchedule["firstRunAt"] = .string(isoTimestamp(Date(timeIntervalSince1970: nextRunEpoch)))
                next["schedule"] = .object(firstSchedule)
                next.removeValue(forKey: "nextWallClockOccurrence")
            }
        }
        if existing["lastRunAt"] == nil { next["lastRunAt"] = .null }

        let nextValue = JSONValue.object(next)
        if let matchIndex {
            if rows[matchIndex] == nextValue { return (false, nextValue) }
            rows[matchIndex] = nextValue
        } else {
            rows.append(nextValue)
        }
        return (true, nextValue)
    }

    /// Save the instant and civil identity; `scheduledEpoch` resolves the effective deadline.
    static func stampNextRun(_ obj: inout [String: JSONValue], epoch: Double) {
        obj["nextRunAt"] = .string(SchedulerJobRuntime.floatString(epoch))
        obj["nextRunAtEpoch"] = .int(Int64(epoch))
        obj["nextRunAtISO"] = .string(SchedulerJobRuntime.decorationISO(epoch: epoch))
        obj["nextWallClockOccurrence"] = SchedulerJobRuntime.wallClockOccurrence(for: obj, epoch: epoch).map(JSONValue.string)
    }

    /// Settlement clears legacy retry/park markers and rearms ordinary recurrence.
    static func clearRetryState(_ obj: inout [String: JSONValue]) {
        obj.removeValue(forKey: "retryCount")
        obj.removeValue(forKey: "retryDayKey")
        obj.removeValue(forKey: "retryPendingUntilEpoch")
        obj.removeValue(forKey: "retryParkedDateKey")
    }

}

// MARK: - SchedulerJobNormalizer
//
// Pure, dependency-free port of Daemon.normalize_scheduler_job_payload and its
// helper cluster (_scheduler_* methods, the retired daemon). Kept
// as a stateless enum with injected `now`/`uuid` so it is trivially testable
// against the daemon's behavior without booting an actor.

enum SchedulerJobNormalizer {
    static let allowedKinds: Set<String> = [
        "notify", "connector_action", "dream", "rem", "harness_benchmark", "proactive_scan", "workshop",
    ]

    // MARK: top-level normalize

    static func normalize(
        body: [String: JSONValue],
        now: @Sendable () -> Date,
        uuid: @Sendable () -> String,
        displayNameFallback: String,
        connectorActionIDs: Set<String>? = nil
    ) throws -> JSONValue {
        let payload: [String: JSONValue]
        if case .object(let p)? = body["payload"] { payload = p } else { payload = [:] }

        // kind = str(body.get("kind") or "notify").strip().lower()
        let kind = (string(pyOr(body["kind"], .string("notify"))) ?? "notify")
            .trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard allowedKinds.contains(kind) else {
            throw TriggerSchedulerError.schedulerInvalid("Unsupported scheduled Desk task kind: \(kind)")
        }

        // interval = max(60, int(body.interval_seconds or intervalSeconds or payload.interval_seconds or 3600))
        var interval = try max(60, pyIntOr(
            body["interval_seconds"], body["intervalSeconds"], payload["interval_seconds"],
            default: 3600
        ))

        // schedule resolution.
        var schedule: [String: JSONValue]
        let scheduleShapes = "schedule accepts an ISO-8601 time, 'in N minutes', or an object: type once with at, every with an interval, or hourly/daily/weekly/monthly/cron; alternatively in_minutes, interval_seconds or run_at"
        switch (body["in_minutes"], body["schedule"]) {
        case (let minutes?, _) where minutes != .null:
            guard [body["schedule"], body["interval_seconds"], body["intervalSeconds"],
                   payload["interval_seconds"], body["run_at"], body["runAt"], body["nextRunAt"]]
                .allSatisfy({ $0 == nil || $0 == .null }) else {
                throw TriggerSchedulerError.schedulerInvalid("Supply in_minutes alone, not with another schedule, interval or run time.")
            }
            schedule = try onceInMinutes(minutes, now: now)
        case (_, .object(let raw)):
            schedule = raw
        case (_, .string(let raw)):
            let at = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            let words = at.lowercased().split(whereSeparator: { $0.isWhitespace })
            if words.first == "in" {
                guard words.count == 3, ["minute", "minutes"].contains(words[2]),
                      let minutes = Double(words[1]) else {
                    throw TriggerSchedulerError.schedulerInvalid("Relative schedule must say 'in N minutes', with a positive number of minutes.")
                }
                schedule = try onceInMinutes(.double(minutes), now: now)
            } else {
                guard parseISO(at) != nil else { throw TriggerSchedulerError.schedulerInvalid(scheduleShapes) }
                schedule = ["type": .string("once"), "at": .string(at)]
            }
        case (_, nil), (_, .null?):
            let hasInterval = [body["interval_seconds"], body["intervalSeconds"], payload["interval_seconds"]]
                .contains(where: { $0.map(truthy) == true })
            let hasRunAt = [body["run_at"], body["runAt"], body["nextRunAt"]]
                .contains(where: { $0.map(truthy) == true })
            // No schedule at all must not silently become hourly.
            guard hasInterval || hasRunAt else {
                throw TriggerSchedulerError.schedulerInvalid(scheduleShapes)
            }
            // _scheduler_schedule_from_legacy_body({**body, one_shot from payload if present}, interval)
            var legacyBody = body
            if let os = payload["one_shot"] { legacyBody["one_shot"] = os }
            schedule = scheduleFromLegacyBody(legacyBody, interval: interval)
        default:
            throw TriggerSchedulerError.schedulerInvalid(scheduleShapes)
        }

        let typeLower = scheduleType(schedule)
        // User 10-21: schedules run on the Mac's local clock and follow it when it
        // changes zone; no zone is stored. "local"/"system" already meant that.
        for key in ["timezone", "tz"] {
            guard let zone = string(schedule.removeValue(forKey: key))?.trimmingCharacters(in: .whitespaces),
                  !["", "local", "system"].contains(zone.lowercased()) else { continue }
            throw TriggerSchedulerError.schedulerInvalid("Schedules run on this Mac's local clock and follow it when it changes zone; remove \(key) \(zone). For one moment elsewhere, give an ISO-8601 time with its offset.")
        }
        if typeLower == "every" {
            interval = try everyInterval(schedule, default: interval)
            schedule["seconds"] = .int(Int64(interval))
            for key in ["minutes", "hours", "days", "interval_seconds", "intervalSeconds"] {
                schedule.removeValue(forKey: key)
            }
        }

        // one_shot = str(schedule.type or "").lower() == "once"
        //            OR bool(body.get("one_shot", body.get("oneShot", payload.get("one_shot", False))))
        let oneShotFallback = body["one_shot"]
            ?? body["oneShot"]
            ?? payload["one_shot"]
        let oneShot = typeLower == "once" || boolValue(oneShotFallback, default: false)

        // first_run = schedule.firstRunAt or body.run_at or body.runAt  (Python `or`)
        let firstRun = pyOr(schedule["firstRunAt"], body["run_at"], body["runAt"])
        let scheduledRun = try nextFromSchedule(schedule, afterEpoch: nil, now: now)
        let nextRun: Double
        if let fr = firstRun, truthy(fr) {
            nextRun = try epochFromValue(fr, zone: .autoupdatingCurrent, now: now)
            schedule["firstRunAt"] = fr
        } else {
            nextRun = scheduledRun
        }

        // name = str(body.name or payload.name or kind.replace("_"," ").title() or "Scheduled Job")[:160]
        let nameRaw = string(pyOr(
            body["name"], payload["name"],
            .string(titleCased(kind.replacingOccurrences(of: "_", with: " "))),
            .string("Scheduled Desk task")
        )) ?? "Scheduled Desk task"
        let name = nameRaw.prefixString(160)

        // per-kind payload normalization.
        var outPayload: [String: JSONValue]
        switch kind {
        case "notify":
            // title = str(payload.title or body.title or name or display)[:120]
            let title = (string(pyOr(
                payload["title"], body["title"],
                .string(name), .string(displayNameFallback)
            )) ?? displayNameFallback).prefixString(120)
            // message = str(payload.message or payload.body or body.message or "").strip()
            let message = (string(pyOr(
                payload["message"], payload["body"], body["message"], .string("")
            )) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if message.isEmpty {
                throw TriggerSchedulerError.schedulerInvalid("notify scheduled Desk tasks require payload.message")
            }
            let delivery = try deliveryChannels(payload)
            outPayload = [
                "title": .string(title),
                "message": .string(message.prefixString(1000)),
                "source": .string(string(pyOr(payload["source"], .string("scheduled_job"))) ?? "scheduled_job"),
                "delivery": .array(delivery.map { .string($0) }),
            ]
            if case .string(let projectSpaceId)? = payload["projectSpaceId"], !projectSpaceId.isEmpty {
                outPayload["projectSpaceId"] = .string(projectSpaceId.prefixString(160))
            }
            // delivery_options = payload.deliveryOptions or payload.delivery_options or {}
            let rawOpts = pyOr(payload["deliveryOptions"], payload["delivery_options"], .object([:]))
            if case .object(let opts)? = rawOpts {
                outPayload["deliveryOptions"] = .object(opts)
            }
        case "dream", "rem":
            // objective = str(payload.objective or body.objective or "").strip()
            var objective = (string(pyOr(payload["objective"], body["objective"], .string(""))) ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if objective.isEmpty {
                objective = kind == "rem" ? "Scheduled REM consolidation" : "Scheduled reflection"
            }
            outPayload = ["objective": .string(objective.prefixString(2000))]
        case "workshop":
            let objective = (string(pyOr(payload["objective"], body["objective"], .string(""))) ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !objective.isEmpty else {
                throw TriggerSchedulerError.schedulerInvalid("workshop scheduled Desk tasks require payload.objective")
            }
            let title = (string(pyOr(payload["title"], body["title"], .string(name))) ?? name)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let expectedEvidence = (string(pyOr(
                payload["expectedEvidence"], payload["expected_evidence"], .string("canonical Workshop completion receipt")
            )) ?? "canonical Workshop completion receipt")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            // Its result is the Desk task's own completion receipt; a workshop job
            // carries no delivery of its own, so none is stored to promise one.
            outPayload = [
                "title": .string((title.isEmpty ? name : title).prefixString(160)),
                "objective": .string(objective.prefixString(2000)),
                "expectedEvidence": .string(expectedEvidence.prefixString(500)),
            ]
        case "proactive_scan":
            // reason = str(orig.reason or body.reason or "scheduled_proactive_scan")[:120]
            let reason = (string(pyOr(
                payload["reason"], body["reason"], .string("scheduled_proactive_scan")
            )) ?? "scheduled_proactive_scan").prefixString(120)
            // limit = max(1, min(int(orig.limit or body.limit or 10), 50))
            let limit = try max(1, min(pyIntOr(payload["limit"], body["limit"], default: 10), 50))
            // surfaceLimit = max(0, min(int(orig.surfaceLimit or surface_limit or body.surfaceLimit or 4), 12))
            let surfaceLimit = try max(0, min(pyIntOr(
                payload["surfaceLimit"], payload["surface_limit"], body["surfaceLimit"],
                default: 4
            ), 12))
            outPayload = [
                "reason": .string(reason),
                "limit": .int(Int64(limit)),
                "surfaceLimit": .int(Int64(surfaceLimit)),
            ]
            // sources = orig.sources or body.sources or []  (Python `or`)
            let rawSources = pyOr(payload["sources"], body["sources"], .array([]))
            if case .array(let arr)? = rawSources {
                // [str(item)[:80] for item in sources[:8] if str(item).strip()]
                let sources = arr.prefix(8).compactMap { v -> JSONValue? in
                    let s = string(v) ?? ""
                    guard !s.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
                    return .string(s.prefixString(80))
                }
                outPayload["sources"] = .array(sources)
            }
            let watchTemplateId = (string(pyOr(
                payload["watchTemplateId"], payload["watch_template_id"], body["watchTemplateId"], .string("")
            )) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if !watchTemplateId.isEmpty {
                outPayload["watchTemplateId"] = .string(watchTemplateId.prefixString(120))
            }
        case "connector_action":
            let actionId = (string(pyOr(
                payload["actionId"], payload["action_id"], payload["id"],
                body["actionId"], body["action_id"], body["action"]
            )) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !actionId.isEmpty else {
                throw TriggerSchedulerError.schedulerInvalid("connector_action scheduled Desk tasks require payload.actionId")
            }
            guard let connectorActionIDs else {
                throw TriggerSchedulerError.schedulerInvalid(
                    "connector_action scheduled Desk tasks require Swift connector registry validation"
                )
            }
            guard connectorActionIDs.contains(actionId) else {
                throw TriggerSchedulerError.schedulerInvalid("Unknown connector action: \(actionId)")
            }
            let rawInput = pyOr(payload["input"], body["input"], .object([:]))
            let input: [String: JSONValue]
            if case .object(let obj)? = rawInput {
                input = obj
            } else {
                throw TriggerSchedulerError.schedulerInvalid("connector_action scheduled Desk tasks require payload.input to be an object when provided")
            }
            outPayload = [
                "actionId": .string(actionId),
                "input": .object(input),
            ]
        default:
            // harness_benchmark (and any other allowed-but-unhandled kind):
            // payload = {**payload, manualAllowed: true, lightweight: true}
            outPayload = payload
            outPayload["manualAllowed"] = .bool(true)
            outPayload["lightweight"] = .bool(true)
        }

        // Native Experience blueprints compile into ordinary canonical jobs.
        // Preserve only their bounded identity/version markers so an explicit
        // reinstall can be idempotent or repair a cancelled/older row without
        // creating a parallel blueprint store.
        if case .string(let blueprintId)? = payload["blueprintId"], !blueprintId.isEmpty {
            outPayload["blueprintId"] = .string(blueprintId.prefixString(120))
        }
        if case .int(let blueprintVersion)? = payload["blueprintVersion"], blueprintVersion > 0 {
            outPayload["blueprintVersion"] = .int(min(blueprintVersion, 10_000))
        }

        // id = str(body.get("id") or uuid.uuid4())
        let id = string(pyOr(body["id"], .string(uuid()))) ?? uuid()
        // enabled = bool(body.get("enabled", True)) — explicit null is FALSEY.
        let enabled = boolValue(body["enabled"], default: true)
        // createdBy = str(body.get("createdBy") or "agent")
        let createdBy = string(pyOr(body["createdBy"], .string("agent"))) ?? "agent"

        var job: [String: JSONValue] = [
            "id": .string(id),
            "name": .string(name),
            "kind": .string(kind),
            "intervalSeconds": !oneShot && typeLower == "every" ? .int(Int64(interval)) : .null,
            "enabled": .bool(enabled),
            "oneShot": .bool(oneShot),
            "nextRunAt": .string(pyFloatString(nextRun)),
            "nextRunAtEpoch": .int(try checkedEpoch(nextRun)),
            "lastRunAt": .null,
            "schedule": .object(schedule),
            "payload": .object(outPayload),
            "createdBy": .string(createdBy),
            "createdAt": .string(nowIso(now())),
        ]
        if typeLower != "every", !oneShot {
            job.removeValue(forKey: "intervalSeconds")
        }
        job["nextWallClockOccurrence"] = SchedulerJobRuntime.wallClockOccurrence(for: job, epoch: nextRun).map(JSONValue.string)
        return .object(job)
    }

    // MARK: schedule helpers (port of _scheduler_* methods)

    /// _scheduler_schedule_from_legacy_body (L43217)
    ///   raw_run_at = body.run_at or body.runAt or body.nextRunAt    (Python `or`)
    ///   one_shot   = bool(body.get("one_shot", body.get("oneShot", False)))
    private static func onceInMinutes(_ value: JSONValue, now: @Sendable () -> Date) throws -> [String: JSONValue] {
        let minutes: Double
        switch value {
        case .int(let number): minutes = Double(number)
        case .double(let number): minutes = number
        default: throw TriggerSchedulerError.schedulerInvalid("in_minutes must be a positive number.")
        }
        guard minutes.isFinite, minutes > 0 else {
            throw TriggerSchedulerError.schedulerInvalid("in_minutes must be a positive finite number.")
        }
        let epoch = now().timeIntervalSince1970 + minutes * 60
        _ = try checkedEpoch(epoch)
        return ["type": .string("once"), "at": .double(epoch)]
    }

    static func scheduleFromLegacyBody(_ body: [String: JSONValue], interval: Int) -> [String: JSONValue] {
        let rawRunAt = pyOr(body["run_at"], body["runAt"], body["nextRunAt"])
        // nested get-defaults: one_shot present? else oneShot present? else False.
        let oneShotRaw = body["one_shot"] ?? body["oneShot"]
        let oneShot = boolValue(oneShotRaw, default: false)
        if let r = rawRunAt, truthy(r), oneShot {
            return ["type": .string("once"), "run_at": r]
        }
        if let r = rawRunAt, truthy(r) {
            return ["type": .string("every"), "seconds": .int(Int64(interval)), "firstRunAt": r]
        }
        return ["type": .string("every"), "seconds": .int(Int64(interval))]
    }

    /// Omitted or explicitly empty delivery is push; invalid destinations refuse.
    static func deliveryChannels(_ payload: [String: JSONValue]) throws -> [String] {
        let raw = payload["delivery"] ?? payload["deliveries"] ?? payload["channels"] ?? payload["notifyVia"]
        let values: [String]
        switch raw {
        case .some(.array(let arr)):
            if arr.isEmpty { return ["push"] }
            values = try arr.map {
                guard case .string(let value) = $0 else {
                    throw TriggerSchedulerError.schedulerInvalid("delivery must contain only channel names.")
                }
                return value
            }
        case .some(.string(let s)):
            let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
            if t.isEmpty { return ["push"] }
            values = s.replacingOccurrences(of: ",", with: " ")
                .split(separator: " ").map(String.init)
        case nil:
            return ["push"]
        default:
            throw TriggerSchedulerError.schedulerInvalid("delivery must be a channel name or an array of channel names.")
        }
        let aliases: [String: String] = [
            "iphone": "push", "ios": "push", "apns": "push", "mobile": "push", "phone": "push",
            "telegram": "telegram", "tg": "telegram",
            "macos": "mac", "desktop": "mac", "mac": "mac",
            "chat": "chat", "session": "chat",
            "inbox": "inbox",
            "activity": "activity", "log": "activity",
        ]
        let canonical: Set<String> = ["push", "telegram", "mac", "chat", "inbox", "activity"]
        var channels: [String] = []
        for value in values {
            let lower = value.trimmingCharacters(in: .whitespaces).lowercased()
            let channel = aliases[lower] ?? lower
            guard canonical.contains(channel) else {
                throw TriggerSchedulerError.schedulerInvalid("Unsupported delivery channel '\(value)'. Use push, telegram, mac, chat, inbox, or activity.")
            }
            if !channels.contains(channel) {
                channels.append(channel)
            }
        }
        guard !channels.isEmpty else {
            throw TriggerSchedulerError.schedulerInvalid("delivery must name a channel. Use push, telegram, mac, chat, inbox, or activity.")
        }
        return channels
    }

    /// _scheduler_epoch_from_value (L43076)
    static func epochFromValue(_ raw: JSONValue, zone: TimeZone, now: @Sendable () -> Date) throws -> Double {
        let nowEpoch = now().timeIntervalSince1970
        let epoch: Double
        switch raw {
        case .int(let i):
            epoch = Double(i)
        case .double(let d):
            epoch = d
        case .string(let s):
            let text = s.trimmingCharacters(in: .whitespacesAndNewlines)
            if text.isEmpty { throw TriggerSchedulerError.schedulerInvalid("run_at is required") }
            if let d = Double(text) { epoch = d }
            else if let parsed = parseISO(text, zone: zone) { epoch = parsed }
            else { throw TriggerSchedulerError.schedulerInvalid("run_at must be an epoch timestamp or ISO-8601 datetime") }
        case .null:
            throw TriggerSchedulerError.schedulerInvalid("run_at is required")
        default:
            throw TriggerSchedulerError.schedulerInvalid("run_at must be an epoch timestamp or ISO-8601 datetime")
        }
        _ = try checkedEpoch(epoch)
        let resolved = max(nowEpoch, epoch)
        _ = try checkedEpoch(resolved)
        return resolved
    }

    static func checkedEpoch(_ epoch: Double) throws -> Int64 {
        guard epoch.isFinite, let value = Int64(exactly: epoch.rounded(.towardZero)) else {
            throw TriggerSchedulerError.schedulerInvalid("run_at must be a finite epoch timestamp within the supported range")
        }
        return value
    }

    static func everyInterval(_ schedule: [String: JSONValue], default defaultInterval: Int = 3600) throws -> Int {
        var seconds = try pyIntOr(schedule["seconds"], default: 0)
        for (key, multiplier) in [("minutes", 60), ("hours", 3600), ("days", 86400)] {
            let value = try pyIntOr(schedule[key], default: 0)
            let product = value.multipliedReportingOverflow(by: multiplier)
            let sum = seconds.addingReportingOverflow(product.partialValue)
            guard !product.overflow, !sum.overflow else {
                throw TriggerSchedulerError.schedulerInvalid("schedule duration is too large")
            }
            seconds = sum.partialValue
        }
        return try max(60, pyIntOr(
            schedule["interval_seconds"], schedule["intervalSeconds"],
            seconds != 0 ? .int(Int64(seconds)) : nil,
            default: defaultInterval
        ))
    }

    static func scheduleType(_ schedule: [String: JSONValue]) -> String {
        (string(schedule["type"]) ?? string(schedule["kind"]) ?? "every")
            .trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    /// _scheduler_next_from_schedule (L43176), read in the Mac's current zone;
    /// `zone` is only for civil arithmetic (UTC) on wall-clock keys.
    static func nextFromSchedule(_ schedule: [String: JSONValue], afterEpoch: Double?, now: @Sendable () -> Date,
                                 zone tz: TimeZone = .autoupdatingCurrent) throws -> Double {
        let typ = scheduleType(schedule)
        let nowEpoch = afterEpoch ?? now().timeIntervalSince1970

        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = tz

        // after = the minute after the one the clock shows, kept as an instant:
        // in the hour a fall-back repeats, one reading names two instants.
        let offset = Double(tz.secondsFromGMT(for: Date(timeIntervalSince1970: nowEpoch)))
        let shown = ((nowEpoch + offset) / 60).rounded(.down) * 60
        let afterMinute = Date(timeIntervalSince1970: shown - offset + 60)
        // A minute the clock already showed is spent: one civil minute is one occurrence.
        func spent(_ date: Date) -> Bool { date.timeIntervalSince1970 + Double(tz.secondsFromGMT(for: date)) <= shown }

        switch typ {
        case "once":
            // run_at or runAt or at  (Python `or`)
            return try epochFromValue(pyOr(schedule["run_at"], schedule["runAt"], schedule["at"]) ?? .null, zone: tz, now: now)
        case "every":
            let resolved = try everyInterval(schedule)
            // datetime.fromtimestamp(after_epoch or now, UTC) + seconds → epoch.
            let nextRun = nowEpoch + Double(resolved)
            _ = try checkedEpoch(nextRun)
            return nextRun
        case "hourly", "daily", "weekly", "monthly", "cron":
            // An hourly minute is int(spec.get("minute", 0)), a present-default get.
            let (hour, minute) = typ == "cron" ? (0, 0) : typ == "hourly" ? (0, try schedule["minute"].map { try pyInt($0) } ?? 0) : try timeParts(schedule)
            guard (0...59).contains(minute) else {
                throw TriggerSchedulerError.schedulerInvalid("hourly schedule minute out of range")
            }
            // weekdays = _scheduler_weekdays(spec.weekdays or spec.weekday)  (Python `or`)
            let weekdays = typ == "weekly" ? try weekdaySet(pyOr(schedule["weekdays"], schedule["weekday"])) : Set(0...6)
            // month_day = max(1, min(31, int(spec.day or monthday or monthDay or 1)))
            let monthDay = try max(1, min(31, pyIntOr(
                schedule["day"], schedule["monthday"], schedule["monthDay"],
                default: 1
            )))
            // expression = str(spec.expression or spec.cron or "")  (Python `or`)
            let expression = (string(pyOr(schedule["expression"], schedule["cron"], .string(""))) ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let cron = typ == "cron" ? try cronFields(expression) : nil
            // Advance candidate by ONE WALL-CLOCK MINUTE per iteration (mirrors
            // Python's `candidate += timedelta(minutes=1)` on a tz-aware
            // datetime — correct across DST, unlike adding raw 60s).
            var candidate = afterMinute
            for _ in 0..<(370 * 24 * 60) {
                let c = cal.dateComponents([.hour, .minute, .day, .weekday], from: candidate)
                let cHour = c.hour ?? -1
                let cMinute = c.minute ?? -1
                let cDay = c.day ?? -1
                // Calendar.weekday: 1=Sunday..7=Saturday → Python weekday(): 0=Mon..6=Sun
                let pyWeekday = ((c.weekday ?? 1) + 5) % 7
                let fresh = !spent(candidate)
                // The next civil minute that matches, so a half-hour DST jump never shifts an hourly job's minute.
                if fresh, typ == "hourly", cMinute == minute {
                    return candidate.timeIntervalSince1970
                }
                if fresh, typ == "daily", cHour == hour, cMinute == minute {
                    return candidate.timeIntervalSince1970
                }
                if fresh, typ == "weekly", weekdays.contains(pyWeekday), cHour == hour, cMinute == minute {
                    return candidate.timeIntervalSince1970
                }
                if fresh, typ == "monthly", cDay == monthDay, cHour == hour, cMinute == minute {
                    return candidate.timeIntervalSince1970
                }
                if fresh, let cron, cronMatches(candidate, fields: cron, cal: cal) {
                    return candidate.timeIntervalSince1970
                }
                guard let nextCandidate = cal.date(byAdding: .minute, value: 1, to: candidate) else {
                    throw TriggerSchedulerError.schedulerInvalid("could not advance \(typ) candidate")
                }
                candidate = nextCandidate
            }
            throw TriggerSchedulerError.schedulerInvalid("Could not find next run for \(typ) schedule within one year")
        default:
            throw TriggerSchedulerError.schedulerInvalid("Unsupported schedule type: \(typ)")
        }
    }

    /// _scheduler_time_parts (L43094)
    ///   raw = spec.get("at") or spec.get("time")   (Python `or`)
    ///   if raw not in (None, ""): regex ^\s*(\d{1,2})(?::(\d{1,2}))?\s*$
    ///   else: hour = int(spec.get("hour", default)); minute = int(spec.get("minute", default))
    static func timeParts(_ spec: [String: JSONValue], defaultHour: Int = 9, defaultMinute: Int = 0) throws -> (Int, Int) {
        let raw = pyOr(spec["at"], spec["time"])
        let hour: Int
        let minute: Int
        if let r = raw, truthy(r) {
            // str(raw) then exact regex match over the WHOLE string.
            let text = string(r) ?? jsonScalarString(r)
            guard let (h, m) = parseHHMM(text) else {
                throw TriggerSchedulerError.schedulerInvalid("schedule.at must be HH:MM")
            }
            hour = h
            minute = m
        } else {
            // present-default get → strict int().
            hour = try spec["hour"].map { try pyInt($0) } ?? defaultHour
            minute = try spec["minute"].map { try pyInt($0) } ?? defaultMinute
        }
        guard (0...23).contains(hour), (0...59).contains(minute) else {
            throw TriggerSchedulerError.schedulerInvalid("scheduled hour/minute out of range")
        }
        return (hour, minute)
    }

    /// Match Python regex `^\s*(\d{1,2})(?::(\d{1,2}))?\s*$`: 1-2 digit hour,
    /// optional `:` + 1-2 digit minute, surrounded only by whitespace. Returns
    /// (hour, minute) — minute defaults to 0 when the `:MM` group is absent.
    static func parseHHMM(_ raw: String) -> (Int, Int)? {
        let s = raw.trimmingCharacters(in: .whitespaces)
        let parts = s.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count >= 1 else { return nil }
        let hStr = parts[0]
        guard (1...2).contains(hStr.count), hStr.allSatisfy({ $0.isASCII && $0.isNumber }), let h = Int(hStr) else {
            return nil
        }
        if parts.count == 2 {
            let mStr = parts[1]
            guard (1...2).contains(mStr.count), mStr.allSatisfy({ $0.isASCII && $0.isNumber }), let m = Int(mStr) else {
                return nil
            }
            return (h, m)
        }
        return (h, 0)
    }

    /// _scheduler_weekdays (L43109) → Python weekday ints (0=Mon..6=Sun)
    static func weekdaySet(_ raw: JSONValue?) throws -> Set<Int> {
        let names: [String: Int] = [
            "mon": 0, "monday": 0, "tue": 1, "tues": 1, "tuesday": 1,
            "wed": 2, "wednesday": 2, "thu": 3, "thur": 3, "thurs": 3, "thursday": 3,
            "fri": 4, "friday": 4, "sat": 5, "saturday": 5, "sun": 6, "sunday": 6,
        ]
        guard let raw, !isEmptyForWeekdays(raw) else { return Set(0...6) }
        let values: [String]
        if case .array(let arr) = raw {
            values = arr.map { string($0) ?? jsonScalarString($0) }
        } else {
            values = (string(raw) ?? jsonScalarString(raw))
                .replacingOccurrences(of: ",", with: " ")
                .split(separator: " ").map(String.init)
        }
        var result: Set<Int> = []
        for item in values {
            let text = item.trimmingCharacters(in: .whitespaces).lowercased()
            if text == "weekday" || text == "weekdays" {
                result.formUnion([0, 1, 2, 3, 4])
            } else if text == "weekend" || text == "weekends" {
                result.formUnion([5, 6])
            } else if let n = names[text] {
                result.insert(n)
            } else if let value = Int(text) {
                // (value - 1) % 7 if value >= 1 else value
                result.insert(value >= 1 ? ((value - 1) % 7) : value)
            } else {
                throw TriggerSchedulerError.schedulerInvalid("Unknown weekday: \(item)")
            }
        }
        return result.isEmpty ? Set(0...6) : result
    }

    /// _scheduler_cron_values (L43131)
    static func cronValues(_ field: String, minimum: Int, maximum: Int, names: [String: Int] = [:]) throws -> Set<Int> {
        var allowed: Set<Int> = []
        for partRaw in field.lowercased().split(separator: ",", omittingEmptySubsequences: false) {
            var part = String(partRaw).trimmingCharacters(in: .whitespaces)
            func namedOrInt(_ token: String) throws -> Int {
                let t = token.trimmingCharacters(in: .whitespaces)
                if let n = names[t] { return n }
                if t.allSatisfy({ $0.isNumber }), !t.isEmpty, let v = Int(t) { return v }
                throw TriggerSchedulerError.schedulerInvalid("cron token '\(token)' is invalid; use an integer from \(minimum) through \(maximum)\(names.isEmpty ? "" : " or " + names.keys.sorted().joined(separator: ", ")) in schedule.expression", code: "schedule_cron_token_invalid", path: "$.schedule.expression")
            }
            var step = 1
            if let slash = part.firstIndex(of: "/") {
                let stepText = String(part[part.index(after: slash)...]).trimmingCharacters(in: .whitespaces)
                part = String(part[..<slash])
                // Python: step = max(1, int(step_text)) — int() raises on non-numeric.
                guard let parsedStep = Int(stepText), stepText.allSatisfy({ $0.isASCII && ($0.isNumber || $0 == "-") }) else {
                    throw TriggerSchedulerError.schedulerInvalid("cron step '\(stepText)' is not an integer; use */N in schedule.expression, for example */5", code: "schedule_cron_step_invalid", path: "$.schedule.expression")
                }
                step = max(1, parsedStep)
            }
            let start: Int
            let end: Int
            if part == "*" || part == "?" {
                start = minimum; end = maximum
            } else if let dash = part.firstIndex(of: "-") {
                let left = String(part[..<dash])
                let right = String(part[part.index(after: dash)...])
                start = try namedOrInt(left)
                end = try namedOrInt(right)
            } else {
                let value = try namedOrInt(part)
                start = value; end = value
            }
            guard (minimum...maximum).contains(start), (minimum...maximum).contains(end), start <= end else {
                throw TriggerSchedulerError.schedulerInvalid("cron range '\(part)' must ascend within \(minimum)...\(maximum); edit schedule.expression", code: "schedule_cron_range_invalid", path: "$.schedule.expression")
            }
            var value = start
            while value <= end {
                allowed.insert(value)
                if step > end - value { break }
                value += step
            }
        }
        return allowed
    }

    typealias CronFields = (minute: Set<Int>, hour: Set<Int>, day: Set<Int>, month: Set<Int>, dow: Set<Int>)

    static func cronFields(_ expression: String) throws -> CronFields {
        let fields = expression.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        guard fields.count == 5 else {
            throw TriggerSchedulerError.schedulerInvalid("schedule.expression needs 5 cron fields: minute hour day month weekday; for example 0 9 * * *", code: "schedule_cron_fields_invalid", path: "$.schedule.expression")
        }
        let weekdayNames: [String: Int] = ["sun": 0, "mon": 1, "tue": 2, "wed": 3, "thu": 4, "fri": 5, "sat": 6]
        let minute = try cronValues(fields[0], minimum: 0, maximum: 59)
        let hour = try cronValues(fields[1], minimum: 0, maximum: 23)
        let day = try cronValues(fields[2], minimum: 1, maximum: 31)
        let month = try cronValues(fields[3], minimum: 1, maximum: 12)
        let dow = try cronValues(fields[4], minimum: 0, maximum: 7, names: weekdayNames)
        return (minute, hour, day, month, dow)
    }

    /// _scheduler_cron_matches (L43163)
    static func cronMatches(_ date: Date, fields: CronFields, cal: Calendar) -> Bool {
        let c = cal.dateComponents([.minute, .hour, .day, .month, .weekday], from: date)
        // cron_dow = (dt.weekday() + 1) % 7; dt.weekday(): 0=Mon..6=Sun.
        let pyWeekday = ((c.weekday ?? 1) + 5) % 7   // Calendar 1=Sun → py 6; 2=Mon → py 0
        let cronDow = (pyWeekday + 1) % 7
        let dowMatch = fields.dow.contains(cronDow) || (cronDow == 0 && fields.dow.contains(7))
        return fields.minute.contains(c.minute ?? -1)
            && fields.hour.contains(c.hour ?? -1)
            && fields.day.contains(c.day ?? -1)
            && fields.month.contains(c.month ?? -1)
            && dowMatch
    }

    // MARK: scalar helpers
    //
    // The daemon's normalize path leans on Python semantics that do NOT map to
    // Swift's `??` / numeric inits:
    //   * `a or b or c`            → first TRUTHY value (0 / "" / [] / {} / None
    //                                are falsey), not first non-nil.
    //   * `int(x)`                 → raises on non-numeric / decimal strings.
    //   * `str(x)`                 → coerces any scalar to text.
    //   * `bool(d.get(k, True))`   → explicit JSON null is FALSEY.
    // These helpers reproduce that so a value of 0 / "" / wrong-type does not
    // silently change the persisted job (gpt-5.5 review wave 33 W18).

    /// Python `str(x)` for the scalar JSON cases the daemon coerces. Objects /
    /// arrays never reach a `str(...)` site in normalize, so they map to nil
    /// (caller treats as absent) rather than Python's "[...]"/"{...}" repr.
    static func string(_ v: JSONValue?) -> String? {
        switch v {
        case .some(.string(let s)): return s
        case .some(.int(let i)): return String(i)
        case .some(.double(let d)): return pyFloatString(d)
        case .some(.bool(let b)): return b ? "True" : "False"
        default: return nil
        }
    }

    /// Python `str(x)` for the `cancel_job` id COMPARISON specifically
    /// (`str(job.get("id")) == job_id`). Differs from `string` in one way that
    /// matters there: an ABSENT or `null` id → Python `str(None) == "None"`, so
    /// a malformed job with no id matches a literal `jobId == "None"`. Arrays /
    /// objects can't appear as a real job id and Python's list/dict repr never
    /// equals a UUID-shaped id, so they map to a non-matching sentinel.
    static func pyStrForId(_ v: JSONValue?) -> String {
        switch v {
        case .some(.string(let s)): return s
        case .some(.int(let i)): return String(i)
        case .some(.double(let d)): return pyFloatString(d)
        case .some(.bool(let b)): return b ? "True" : "False"
        case .some(.null), .none: return "None"   // Python str(None)
        case .some(.array), .some(.object):
            // Python would produce a list/dict repr; it can never equal a real
            // job id, so return a value that won't match any caller-supplied id.
            return "\u{0}__nonscalar_id__"
        }
    }

    /// Retired truthiness: 0 / 0.0 / "" / [] / {} / null / absent are falsey.
    static func truthy(_ v: JSONValue?) -> Bool {
        switch v {
        case .some(.bool(let b)): return b
        case .some(.int(let i)): return i != 0
        case .some(.double(let d)): return d != 0
        case .some(.string(let s)): return !s.isEmpty
        case .some(.array(let a)): return !a.isEmpty
        case .some(.object(let o)): return !o.isEmpty
        case .some(.null), .none: return false
        }
    }

    /// Python `a or b or c …` — returns the first TRUTHY argument, else the
    /// last argument (retired semantics returned the final operand when all are
    /// falsey, e.g. `x or 3600` → 3600).
    static func pyOr(_ values: JSONValue?...) -> JSONValue? {
        for v in values where truthy(v) { return v }
        return values.last ?? nil
    }

    /// Python `int(x)` with the daemon's strictness: ints pass through; floats
    /// truncate toward zero; numeric strings (no decimal point) parse; bools →
    /// 0/1; everything else THROWS (matching ValueError → 400). Empty string and
    /// null also throw. Used where the daemon would surface a 400 on bad input.
    static func pyInt(_ v: JSONValue?) throws -> Int {
        switch v {
        case .some(.int(let i)): return Int(i)
        case .some(.double(let d)):
            guard let value = Int(exactly: d.rounded(.towardZero)) else {
                throw TriggerSchedulerError.schedulerInvalid("expected an integer")
            }
            return value
        case .some(.bool(let b)): return b ? 1 : 0
        case .some(.string(let s)):
            // Python int("  12 ") strips surrounding whitespace; int("1.5") raises.
            let t = s.trimmingCharacters(in: .whitespaces)
            if let i = Int(t) { return i }
            throw TriggerSchedulerError.schedulerInvalid("invalid integer literal: \(s)")
        case .some(.array), .some(.object), .some(.null), .none:
            throw TriggerSchedulerError.schedulerInvalid("expected an integer")
        }
    }

    /// `int(a or b or c or default)` — the daemon's recurring pattern: pick the
    /// first truthy operand, fall back to `default`, then `int()` it (strict).
    static func pyIntOr(_ values: JSONValue?..., default def: Int) throws -> Int {
        for v in values where truthy(v) { return try pyInt(v) }
        return def
    }

    /// `bool(d.get(k, default))` — present-with-null is FALSEY; absent uses the
    /// stored default. `def` is the Python `d.get(k, def)` default applied when
    /// the key is ABSENT (nil); a present null/scalar follows retired truthiness.
    static func boolValue(_ v: JSONValue?, default def: Bool) -> Bool {
        guard let v else { return def }   // key absent → Python default
        return truthy(v)                  // present (incl. null) → truthiness
    }

    /// _scheduler_weekdays empty-guard: raw in (None, "", []).
    static func isEmptyForWeekdays(_ v: JSONValue) -> Bool {
        switch v {
        case .null: return true
        case .string(let s): return s.isEmpty
        case .array(let a): return a.isEmpty
        default: return false
        }
    }

    static func jsonScalarString(_ v: JSONValue) -> String {
        switch v {
        case .string(let s): return s
        case .int(let i): return String(i)
        case .double(let d): return pyFloatString(d)
        case .bool(let b): return b ? "True" : "False"
        default: return ""
        }
    }

    /// Python `str.title()` — capitalize first letter of each word.
    static func titleCased(_ s: String) -> String {
        s.split(separator: " ", omittingEmptySubsequences: false)
            .map { word -> String in
                guard let first = word.first else { return String(word) }
                return String(first).uppercased() + word.dropFirst().lowercased()
            }
            .joined(separator: " ")
    }

    /// Python `str(float)` — integral floats render as "N.0".
    static func pyFloatString(_ d: Double) -> String {
        if d.isFinite, d == d.rounded(), abs(d) < 1e16 {
            return String(format: "%.1f", d)
        }
        return String(d)
    }

    /// now_iso() — ISO-8601 UTC with offset (millisecond precision; see header).
    static func nowIso(_ date: Date) -> String {
        SwiftNativeTriggerScheduler.isoTimestamp(date)
    }

    // MARK: list_jobs nextRunAt decoration

    /// Project timing through `SchedulerJobRuntime.scheduledEpoch`, then format
    /// the epoch as ISO. Ambiguous wall-clock timing is nulled with a warning.
    /// Non-object rows and other metadata pass through; one-offs omit the interval.
    static func decorateNextRunAt(_ row: JSONValue) -> JSONValue {
        guard case .object(var d) = row else { return row }
        if case .object? = d["schedule"] {
            d["mac_timezone"] = .string(TimeZone.autoupdatingCurrent.identifier)
            if let due = SchedulerJobRuntime.scheduledEpoch(for: d) {
                d["nextRunAt"] = .string(pyFloatString(due))
                d["timezone_detail"] = .string("Follows the Mac: \(TimeZone.autoupdatingCurrent.identifier).")
            } else if SchedulerJobRuntime.wallClockSchedule(d) != nil {
                d["timezone_warning"] = .string("Wall-clock occurrence is ambiguous. Review and save this schedule before it can run.")
                d["nextRunAt"] = .null
                d["nextRunAtEpoch"] = .null
                d["nextRunAtISO"] = .null
            }
        }
        // Older one-off and calendar rows retained the default hourly interval.
        let calendarTypes: Set<String> = ["once", "hourly", "daily", "weekly", "monthly", "cron"]
        let scheduleType: String? = {
            guard case .object(let schedule)? = d["schedule"] else { return nil }
            return SchedulerJobNormalizer.scheduleType(schedule)
        }()
        if d["oneShot"] == .bool(true) || scheduleType == "once" {
            d["intervalSeconds"] = .null
        } else if scheduleType.map(calendarTypes.contains) == true {
            d.removeValue(forKey: "intervalSeconds")
        }
        // raw = d.get("nextRunAt"); epoch = float(raw) if raw not in (None,"") else None
        let epoch = floatEpochForDecoration(d["nextRunAt"])
        if let epoch {
            let iso = epochToDecorationISO(epoch)
            // Python stores the FLOAT under nextRunAtEpoch (json → number). Use
            // .double so the wire shape matches (e.g. 1893456000.0, not "…").
            d["nextRunAtEpoch"] = .double(epoch)
            d["nextRunAt"] = .string(iso)
            d["nextRunAtISO"] = .string(iso)
        }
        return .object(d)
    }

    /// `epoch = float(raw) if raw not in (None, "") else None`, catching
    /// TypeError/ValueError → None. Mirrors Python `float()` coercion EXACTLY for
    /// the stored-row cases: the daemon writes `nextRunAt` as `pyFloatString`
    /// (a float-string like "1893456000.0"), but a row may also carry a numeric
    /// JSON value (older shells) or garbage. Crucially, `raw not in (None, "")`
    /// means a literal `0` / `0.0` / `"0"` is NOT skipped — it coerces to 0.0 and
    /// decorates to the epoch (1970-01-01T00:00:00+00:00), same as the daemon.
    static func floatEpochForDecoration(_ raw: JSONValue?) -> Double? {
        switch raw {
        case .none, .some(.null):
            // Python: raw is None → skipped (in the (None, "") set).
            return nil
        case .some(.string(let s)):
            // Python: "" → skipped; otherwise float(s). float() strips
            // surrounding whitespace and accepts int/decimal/exponent forms.
            if s.isEmpty { return nil }
            let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
            // Double(_:) rejects empty / non-numeric → Python float() ValueError.
            guard let v = Double(trimmed), v.isFinite else { return nil }
            return v
        case .some(.int(let i)):
            return Double(i)
        case .some(.double(let d)):
            return d.isFinite ? d : nil
        case .some(.bool):
            // Python float(True/False) == 1.0/0.0, BUT a bool nextRunAt can't be
            // produced by the daemon and `float(bool)` is a degenerate path the
            // real data never hits; treat as garbage → None (TypeError-equivalent
            // is the safe call here since it can never appear in jobs.json).
            return nil
        case .some(.array), .some(.object):
            // Python float([...]) / float({...}) raises TypeError → None.
            return nil
        }
    }

    /// Faithful mirror of `datetime.fromtimestamp(epoch, tz=timezone.utc)
    /// .isoformat()` — the EXACT call the daemon's list_jobs decoration uses.
    /// Python's isoformat:
    ///   * omits the fractional-seconds component entirely when the microsecond
    ///     field is 0 (integral epoch → "2030-01-01T00:00:00+00:00"),
    ///   * renders SIX fractional digits (microseconds) otherwise
    ///     ("…T00:00:00.500000+00:00"),
    ///   * always uses the "+00:00" offset (never "Z") for a UTC-aware datetime.
    /// This DIFFERS from `SwiftNativeTriggerScheduler.isoTimestamp` (which always
    /// emits millisecond ".SSS"), so we cannot reuse it for the decoration.
    static func epochToDecorationISO(_ epoch: Double) -> String {
        NativeTimestampFormat.microsecondUTCOffset(Date(timeIntervalSince1970: epoch), rounding: .toNearestOrEven)
    }

    /// Mirror `datetime.fromisoformat(text.replace("Z","+00:00"))`, accepting
    /// both `T` and space separators and naive (offset-less) forms, including
    /// date-only. We try, in order:
    ///   1. offset-bearing forms (with/without fractional seconds)
    ///   2. naive datetime forms → wall-clock time in `zone` (the Mac's
    ///      current zone unless the caller is doing civil arithmetic)
    ///   3. date-only `YYYY-MM-DD` → midnight in `zone`
    static func parseISO(_ text: String, zone: TimeZone = .autoupdatingCurrent) -> Double? {
        let normalized = text.replacingOccurrences(of: "Z", with: "+00:00")

        // 1. Offset-bearing (Internet date-time).
        let withFrac = ISO8601DateFormatter()
        withFrac.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = withFrac.date(from: normalized) { return d.timeIntervalSince1970 }
        let noFrac = ISO8601DateFormatter()
        noFrac.formatOptions = [.withInternetDateTime]
        if let d = noFrac.date(from: normalized) { return d.timeIntervalSince1970 }

        // 2 & 3. Naive forms (no offset) → `zone`. Accept both `T` and space.
        let candidates = ["yyyy-MM-dd'T'HH:mm:ss.SSSSSS",
                          "yyyy-MM-dd'T'HH:mm:ss.SSS",
                          "yyyy-MM-dd'T'HH:mm:ss",
                          "yyyy-MM-dd'T'HH:mm",
                          "yyyy-MM-dd HH:mm:ss.SSSSSS",
                          "yyyy-MM-dd HH:mm:ss.SSS",
                          "yyyy-MM-dd HH:mm:ss",
                          "yyyy-MM-dd HH:mm",
                          "yyyy-MM-dd"]
        for fmt in candidates {
            let df = DateFormatter()
            df.locale = Locale(identifier: "en_US_POSIX")
            df.timeZone = zone
            df.dateFormat = fmt
            if let d = df.date(from: normalized) { return d.timeIntervalSince1970 }
        }
        return nil
    }
}

private extension String {
    /// Python `s[:n]` slices by Unicode code points (scalars), NOT by Swift
    /// extended grapheme clusters. Slice on `unicodeScalars` so a combining
    /// sequence / flag emoji counts the same number of positions Python would.
    func prefixString(_ n: Int) -> String {
        let scalars = unicodeScalars
        if scalars.count <= n { return self }
        return String(String.UnicodeScalarView(scalars.prefix(n)))
    }
}

// MARK: - Factory (scheduler-job writer)

/// Swift-native create-job writer. Job creation carries no briefing-part host
/// or notification sender; the engine supplies those only at their native entry.
public func makeSchedulerJobWriter(
    connectorActionIDs: Set<String>? = nil,
    dataRoot: URL = PersistenceCore.defaultDataRoot()
) -> any SchedulerJobWriter {
    let runner = makeWorkshopRunner(dataRoot: dataRoot)
    return SwiftNativeTriggerScheduler(
        root: dataRoot,
        workshopRunner: runner,
        connectorActionIDs: connectorActionIDs
    )
}

typealias SchedulerSecretRedactor = NativeAgentSecretRedactor
