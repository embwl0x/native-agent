import Privacy
import Foundation
import NativeAgentShared
import os
import NativeAgentCore
import PersistenceCore
import TrustCenter
import WorkshopExecution
import CryptoKit
import Desk
// Blueprint: | `SchedulerJobs.swift` | SwiftNativeTriggerScheduler canonical bounded job storage, mutation (including intention-kind resume refusals), post-migration restored intentions kept stopped with a keyed Desk notice and byte-exact backup, activity receipts and read-only app-door watch admission |

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

extension SwiftNativeTriggerScheduler {
    /// A completed migration is never rerun. A later legacy definition is
    /// evidence for her, not another runnable copy of an intention she has.
    public func stopRestoredIntentionJobs() async throws {
        let finished = MyQueue.scheduledMigrationMarker(dataRoot: root)
        guard FileManager.default.fileExists(atPath: finished.path) else { return }
        _ = try Data(contentsOf: finished)
        try await SwiftNativePersistenceCore.withFileLock(jobsPath) {
            guard FileManager.default.fileExists(atPath: jobsPath.path) else { return }
            let rows = try Self.readJobsChecked(at: jobsPath)
            let restored = rows.indices.filter { index in
                guard let job = rows[index].objectValue,
                      ["notify", "turn", "workshop"].contains(SchedulerJobRuntime.string(job["kind"])?.lowercased() ?? "notify") else { return false }
                let receipt = (job["intentionMigration"] ?? job["lastRunDetail"])?.stringValue ?? ""
                let kept = receipt.hasPrefix("became intention ") || receipt == "its intention ends itself"
                    || receipt == "kept disabled at first migration" || receipt == "restored backup; stopped"
                return SchedulerJobRuntime.bool(job["enabled"], default: true) || !kept
            }
            guard !restored.isEmpty else { return }
            // Preserve every original byte and occurrence receipt before mutation.
            let snapshot = try Data(contentsOf: jobsPath)
            let backup = root.appendingPathComponent("scheduler/pre-intentions-restored-\(UUID().uuidString.lowercased()).jobs.json")
            try await SwiftNativePersistenceCore.writeDataAtomicDurableAsync(snapshot, to: backup)
            guard case .array(var savedRows) = try JSONValue.parse(snapshot) else {
                throw TriggerSchedulerError.schedulerInvalid("Scheduled jobs must be an array; source bytes preserved.")
            }
            let store = SwiftNativeDeskStore(dataRoot: root)
            for index in restored {
                guard let job = rows[index].objectValue, case .object(var saved) = savedRows[index] else { continue }
                guard let id = job["id"]?.stringValue, !id.isEmpty else {
                    throw TriggerSchedulerError.schedulerInvalid("A restored scheduled intention has no job id. Its source is preserved; repair its identity before filing its Desk notice.")
                }
                let name = job["name"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let shownName = name.isEmpty ? id : name
                let schedule = try job["schedule"]?.serialize(pretty: false)
                let when = job["nextWallClockOccurrence"]?.stringValue
                    ?? SchedulerJobRuntime.scheduledEpoch(for: job).map { NativeTimestampFormat.microsecondUTCOffset(Date(timeIntervalSince1970: $0), rounding: .up) }
                    ?? job["nextRunAt"]?.stringValue ?? schedule
                let words = "A restored backup brought back scheduled job \(shownName) (\(when ?? "time unavailable")); add it again with queue.add if you still want it"
                do {
                    _ = try await store.fileSystemItem(kind: .watch, project: "NativeAgent", title: words,
                        summary: words + "\nStopped source: \(jobsPath.path), job \(id).", assignee: nil,
                        findingKey: "restored-scheduled-intention:" + id,
                        note: words, refs: [])
                } catch DeskError.findingArchived {
                    // Her archived notice is already surfaced; do not recreate it.
                }
                saved["enabled"] = .bool(false)
                saved["lastRunStatus"] = .string("stopped")
                saved["disabledReason"] = .string(words)
                saved["intentionMigration"] = .string("restored backup; stopped")
                if case .object(var active)? = saved["activeOccurrence"] {
                    active["state"] = .string("stopped")
                    active["reason"] = .string(words)
                    saved["activeOccurrence"] = .object(active)
                }
                savedRows[index] = .object(saved)
            }
            // Notice first, then disposition: interruption reuses the same keyed
            // Desk finding. A failed notice leaves the source for a later retry.
            let stoppedRows = savedRows
            try await updateJobRows { $0 = stoppedRows }
        }
    }

    private static let jobActivityLogger = Logger(subsystem: "com.nativeagent.core", category: "scheduler-jobs")

    // Jobs are already committed; a missing activity receipt must not invite
    // a retry of the successful mutation.
    private nonisolated static func appendJobActivity(
        _ event: JSONValue,
        to path: URL,
        logLabel: String
    ) async {
        do {
            try await SwiftNativePersistenceCore.appendActivityEvent(event, to: path,
                logLabel: logLabel)
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

    /// A connector_action job is a watch: its action must be a read of the app door (`watchRefusal`).
    public func createJob(body: JSONValue) async throws -> JSONValue {
        guard case .object(let obj) = body else {
            throw TriggerSchedulerError.schedulerInvalid("request body must be a JSON object")
        }

        let job = try SchedulerJobNormalizer.normalize(
            body: obj,
            now: now,
            uuid: uuid
        )

        try await updateJobRows { jobs in
            if case .object(let newJob) = job,
               jobs.contains(where: { row in
                   guard case .object(let existing) = row else { return false }
                   return (SchedulerJobNormalizer.string(existing["id"]) ?? "")
                       == (SchedulerJobNormalizer.string(newJob["id"]) ?? "")
               }) {
                throw TriggerSchedulerError.schedulerInvalid("A scheduled Desk task with this id already exists.")
            }
            jobs.append(job)
        }

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
            event, to: activityPath,
            logLabel: "SchedulerJobs.create.activity"
        )

        return job
    }

    /// Cancel by exact or unique-prefix id, retaining a durable cancellation marker.
    public func cancelJob(jobId: String) async throws -> JSONValue {
        if jobId.isEmpty {
            throw TriggerSchedulerError.schedulerInvalid("jobId is required")
        }

        let updatedTarget: JSONValue = try await updateJobRows { jobs in
            // Thrown INSIDE the lock, so a miss writes nothing.
            let idx = try Self.jobIndex(jobs, id: jobId)
            guard case .object(var obj) = jobs[idx] else { throw TriggerSchedulerError.schedulerInvalid("Unknown scheduled Desk task: \(jobId)") }
            obj["enabled"] = .bool(false)
            obj.removeValue(forKey: "pausedAt")
            obj["cancelledAt"] = .string(SwiftNativeTriggerScheduler.isoTimestamp(now()))
            jobs[idx] = .object(obj)
            return .object(obj)
        }

        let targetObj: [String: JSONValue]
        if case .object(let o) = updatedTarget { targetObj = o } else { targetObj = [:] }
        let jobId = (SchedulerJobNormalizer.string(targetObj["id"]) ?? "")  // the job a start of its id named
        // A blank or absent display name uses the id.
        let detailRaw = SchedulerJobNormalizer.string(
            targetObj["name"]
        ) ?? jobId
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
            event, to: activityPath,
            logLabel: "SchedulerJobs.cancel.activity"
        )

        return .object(["ok": .bool(true), "job": updatedTarget])
    }

    /// Pause / resume one scheduled job. Same locked read-modify-write and
    /// activity receipt as `cancelJob`, with a separate pause marker.
    public func setJobEnabled(jobId: String, enabled: Bool) async throws -> JSONValue {
        if jobId.isEmpty {
            throw TriggerSchedulerError.schedulerInvalid("jobId is required")
        }

        let updatedTarget: JSONValue = try await updateJobRows { jobs in
            let idx = try Self.jobIndex(jobs, id: jobId)
            guard case .object(var obj) = jobs[idx] else { throw TriggerSchedulerError.schedulerInvalid("Unknown scheduled Desk task: \(jobId)") }
            if enabled, ["notify", "turn", "workshop"].contains(SchedulerJobNormalizer.string(obj["kind"]) ?? "notify") {
                // Resume cannot resurrect the retired execution path. The
                // normalizer returns the same MY QUEUE remedy as create/update.
                _ = try SchedulerJobNormalizer.normalize(body: obj, now: now, uuid: uuid)
            }
            obj["enabled"] = .bool(enabled)
            if enabled {
                if case .object(let claim)? = obj["activeOccurrence"],
                   try !DataRootLife.isCurrent(SchedulerJobRuntime.string(claim["lifeID"]), in: root) {
                    obj["lastRunStatus"] = .string("stopped")
                    obj["lastRunDetail"] = .string(DataRootLife.stoppedReason)
                    obj.removeValue(forKey: "activeOccurrence")
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
            return .object(obj)
        }

        let targetObj: [String: JSONValue]
        if case .object(let o) = updatedTarget { targetObj = o } else { targetObj = [:] }
        let jobId = (SchedulerJobNormalizer.string(targetObj["id"]) ?? "")  // the job a start of its id named
        let detailRaw = SchedulerJobNormalizer.string(
            targetObj["name"]
        ) ?? jobId
        let title = enabled ? "Scheduled Desk task resumed" : "Scheduled Desk task paused"
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
            event, to: activityPath,
            logLabel: "SchedulerJobs.setEnabled.activity"
        )

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
                throw invalid("kind must name a supported scheduled Desk task kind. Use queue.add {text, when, until?, say?} for intentions, check-ins and reminders.", path: "$.kind", accepted: SchedulerJobNormalizer.allowedKinds.sorted().joined(separator: ", "))
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

        let updated: JSONValue = try await updateJobRows { jobs in
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
            body.removeValue(forKey: "interval_seconds")
            let result = try SchedulerJobNormalizer.normalize(
                body: body, now: now, uuid: uuid)
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
                existing.removeValue(forKey: "completedAt")
                existing["scheduleGeneration"] = .string(uuid())
            }
            jobs[index] = .object(existing)
            return .object(existing)
        }
        let jobId = if case .object(let row) = updated { (SchedulerJobNormalizer.string(row["id"]) ?? "") } else { jobId }
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
                logLabel: "SchedulerJobs.update.activity")
        } catch {
            throw ToolFailureError("The scheduled Desk task was updated, but recording its activity failed: \(error)", effects: .occurred)
        }
        return .object(["ok": .bool(true), "job": updated])
    }

    /// Read under the same jobs-file lock as mutations,
    /// then project timing with `decorateNextRunAt`. Only absence is empty.
    public func listJobs() async throws -> [JSONValue] {
        try await listJobsIfPresent() ?? []
    }

    /// The same decorated snapshot, retaining absence for read-only surfaces.
    public func listJobsIfPresent() async throws -> [JSONValue]? {
        try await SwiftNativePersistenceCore.withFileLock(jobsPath) {
            guard FileManager.default.fileExists(atPath: jobsPath.path) else { return nil as [JSONValue]? }
            return try Self.readJobsChecked(at: jobsPath).map { SchedulerJobNormalizer.decorateNextRunAt($0) }
        }
    }

    /// Every writer, including occurrence settlement, must stay readable by
    /// the canonical job reader. Validate the exact bytes before replacement.
    public nonisolated static func jobsDataForWrite(_ rows: [JSONValue]) throws -> Data {
        try validateRows(rows)
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
    /// Exact string identity first, then one unambiguous prefix.
    /// An unknown id, or a start several jobs share, refuses and names them.
    nonisolated static func jobIndex(_ jobs: [JSONValue], id jobId: String) throws -> Int {
        let ids = jobs.map { if case .object(let row) = $0 { (SchedulerJobNormalizer.string(row["id"]) ?? "") } else { "" } }
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

    private nonisolated static func validateRows(_ rows: [JSONValue]) throws {
        func check(_ object: [String: JSONValue], path: String) throws {
            for (key, value) in object where key != "payload" && value != .null {
                if case .object(let nested) = value {
                    if key == "schedule" || key == "activeOccurrence" {
                        try check(nested, path: path + "." + key)
                    }
                } else if key.hasSuffix("Epoch") || key.hasSuffix("At") || key.hasSuffix("AtISO")
                    || ["run_at", "runAt"].contains(key)
                    || key == "at" && SchedulerJobNormalizer.scheduleType(object) == "once" {
                    let parsed = SchedulerJobNormalizer.string(value).flatMap { SchedulerJobNormalizer.parseISO($0) }
                    guard let epoch = SchedulerJobNormalizer.floatEpochForDecoration(value) ?? parsed else {
                        throw TriggerSchedulerError.schedulerInvalid("\(path).\(key): invalid saved timestamp; bytes preserved")
                    }
                    do { _ = try SchedulerJobNormalizer.checkedEpoch(epoch) }
                    catch { throw TriggerSchedulerError.schedulerInvalid("\(path).\(key): timestamp outside supported civil/millisecond domain; bytes preserved") }
                }
            }
        }
        var identities: Set<String> = []
        for (index, row) in rows.enumerated() {
            guard case .object(let object) = row,
                  case .string(let id)? = object["id"], !id.isEmpty,
                  identities.insert(id).inserted,
                  case .string(let name)? = object["name"], !name.isEmpty,
                  case .string(let kind)? = object["kind"],
                  case .bool? = object["enabled"],
                  case .bool? = object["oneShot"],
                  case .object(let schedule)? = object["schedule"],
                  case .object(let payload)? = object["payload"] else {
                throw TriggerSchedulerError.schedulerInvalid("job[\(index)] has missing, duplicate or wrongly typed required authority; bytes preserved")
            }
            // DATA PRESENT: migrated intention definitions and their original
            // backup still exist. They remain readable for that one conversion,
            // while due-job admission accepts only allowedKinds.
            guard SchedulerJobNormalizer.allowedKinds.contains(kind) || ["notify", "turn", "workshop"].contains(kind) else {
                throw TriggerSchedulerError.schedulerInvalid("job[\(index)].kind is unsupported; bytes preserved")
            }
            try SchedulerJobNormalizer.validateSchedule(schedule)
            guard object["oneShot"] == .bool(SchedulerJobNormalizer.scheduleType(schedule) == "once") else {
                throw TriggerSchedulerError.schedulerInvalid("job[\(index)].oneShot contradicts its schedule.type; bytes preserved")
            }
            try SchedulerJobNormalizer.validatePayload(kind: kind, payload: payload)
            if let interval = object["intervalSeconds"], interval != .null {
                guard case .int(let seconds) = interval, seconds >= 60 else {
                    throw TriggerSchedulerError.schedulerInvalid("job[\(index)].intervalSeconds must be an integer of at least 60; bytes preserved")
                }
            }
            if let active = object["activeOccurrence"] {
                guard case .object(let claim) = active,
                      case .string(let key)? = claim["key"], !key.isEmpty,
                      case .string(let state)? = claim["state"], ["claimed", "stopped"].contains(state),
                      SchedulerJobRuntime.epoch(from: claim["dueEpoch"]) != nil,
                      case .string(let life)? = claim["lifeID"], UUID(uuidString: life) != nil else {
                    throw TriggerSchedulerError.schedulerInvalid("job[\(index)].activeOccurrence is unreadable; bytes preserved")
                }
            }
            if SchedulerJobRuntime.wallClockSchedule(object) != nil,
               object["enabled"] == .bool(true) || object["activeOccurrence"] != nil || object["nextWallClockOccurrence"] != nil {
                guard let key = SchedulerJobRuntime.nextWallClockOccurrence(for: object),
                      SchedulerJobRuntime.civilEpoch(key) != nil else {
                    throw TriggerSchedulerError.schedulerInvalid("job[\(index)] has no current civil occurrence identity; bytes preserved")
                }
            }
            guard SchedulerJobRuntime.epoch(from: object["nextRunAt"]) != nil
                    || SchedulerJobRuntime.epoch(from: object["nextRunAtEpoch"]) != nil
                    || object["enabled"] == .bool(false) && object["disabledReason"]?.stringValue?.isEmpty == false else {
                throw TriggerSchedulerError.schedulerInvalid("job[\(index)] has no saved occurrence time; bytes preserved")
            }
            try check(object, path: "job[\(index)]")
        }
    }

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
            do { try validateRows(rows) }
            catch {
                throw Self.jobStoreReadFailure(error.localizedDescription, code: "schedule_store_shape_invalid", path: path)
            }
            return rows
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

// MARK: - Factory (scheduler-job writer)

/// Swift-native create-job writer. Job creation carries no briefing-part host
/// or notification sender; the engine supplies those only at their native entry.
public func makeSchedulerJobWriter(
    dataRoot: URL = PersistenceCore.defaultDataRoot()
) -> SwiftNativeTriggerScheduler {
    let runner = makeWorkshopRunner(dataRoot: dataRoot)
    return SwiftNativeTriggerScheduler(
        root: dataRoot,
        workshopRunner: runner
    )
}

extension SwiftNativeTriggerScheduler {
    /// A scheduled read is a watch: its action runs through the app door as a
    /// read, and what changed comes to her as news. Nil when `action` is such a
    /// read; otherwise why not, in words she can act on. Scheduling and each run ask it.
    public static func watchRefusal(action: String, input: [String: JSONValue]) -> String? {
        let declared: ToolClass?
        do { declared = try PermissionLaw.doorClass(action: action, args: input) }
        catch {
            return "The action's effect class is unavailable: \(error.localizedDescription). Repair its action catalog before scheduling this watch."
        }
        switch declared {
        case .read?: return nil
        case nil: return "No app action is called \(action). A watch reads through the app door (app {find} names the reads; a part of yours runs as authored.<id>), and what changed comes to you as news."
        case let other?: return "\(action) is a \(other), and a watch only reads: what changed comes to you as news. To act on a schedule, give a part a schedule:<cron> wake instead."
        }
    }
}

typealias SchedulerSecretRedactor = NativeAgentSecretRedactor
