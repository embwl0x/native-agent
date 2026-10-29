import CryptoKit
import Foundation
import NativeAgentShared
import NativeAgentCore
import PersistenceCore
import Privacy
import os
import TrustCenter
import WorkshopExecution
import Experiences
import NotificationInbox
import Darwin
// Blueprint: | `SchedulerJobOccurrences.swift` | SwiftNativeTriggerScheduler life-stamped job occurrence claims, settlement, pruning and default-cycle row updates |

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
        ) throws {
            _ = try SchedulerJobNormalizer.checkedEpoch(dueEpoch)
            self.id = id
            self.name = name
            self.kind = kind
            self.payload = payload
            self.row = row
            self.dueEpoch = dueEpoch
            let civil: String? = if case .object(let object) = row, object["retryPendingUntilEpoch"] == nil {
                SchedulerJobRuntime.wallClockOccurrence(for: object, epoch: dueEpoch)
            } else { nil }
            self.occurrenceKey = try occurrenceKey ?? Self.makeOccurrenceKey(jobId: id, dueEpoch: dueEpoch, civil: civil)
        }

        static func makeOccurrenceKey(jobId: String, dueEpoch: Double, civil: String? = nil) throws -> String {
            _ = try SchedulerJobNormalizer.checkedEpoch(dueEpoch)
            guard let millis = Int64(exactly: (dueEpoch * 1_000).rounded()) else {
                throw TriggerSchedulerError.schedulerInvalid("occurrence milliseconds exceed the supported range")
            }
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
        try await SwiftNativePersistenceCore.withFileLock(jobsPath) {
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
        try await SwiftNativePersistenceCore.withFileLock(jobsPath) {
            let original = try Self.readJobsChecked(at: jobsPath)
            var rows = original
            let result = try update(&rows)
            if rows != original {
                let data = try Self.jobsDataForWrite(rows)
                do {
                    try await SwiftNativePersistenceCore.writeDataAtomicDurableAsync(data, to: jobsPath)
                } catch {
                    throw TriggerSchedulerError.persistenceFailure(String(describing: error))
                }
            }
            return result
        }
    }

    /// Claim the first selected occurrence under the jobs lock, before effects.
    /// Same-life restart claims need reconciliation; another life's are stopped.
    public func claimDueJobs(
        now: Date,
        select: @Sendable ([JSONValue]) throws -> [DueJob]
    ) async throws -> ClaimedDueJobs {
        try await updateJobRows { rows in
            let life = try DataRootLife.current(in: root)
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
            }
            let selected = try select(rows).prefix(1)
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
                        try Self.stampNextRun(&object, epoch: next)
                    } else {
                        object["enabled"] = .bool(false)
                        object["disabledReason"] = .string("could not compute next scheduled run")
                    }
                    rows[index] = .object(object)
                    continue
                }

                var claim: [String: JSONValue] = [
                    "key": .string(job.occurrenceKey),
                    "dueEpoch": .int(try SchedulerJobNormalizer.checkedEpoch(job.dueEpoch.rounded())),
                    "claimedAt": .string(Self.isoTimestamp(now)),
                    "state": .string("claimed"),
                    "lifeID": .string(life),
                ]
                claim["scheduleGeneration"] = object["scheduleGeneration"]
                object["activeOccurrence"] = .object(claim)
                try Self.stampNextRun(&object, epoch: job.dueEpoch)
                rows[index] = .object(object)
                claimed.append(job)
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
        try await updateJobRows { rows in
            guard let index = rows.firstIndex(where: { row in
                guard case .object(let object) = row else { return false }
                return SchedulerJobRuntime.string(object["id"]) == recovery.jobId
            }), case .object(var object) = rows[index],
                let activeValue = object["activeOccurrence"] else { return }
            if recovery.reason != nil, try DataRootLife.isCurrent(SchedulerJobRuntime.string(activeValue.objectValue?["lifeID"]), in: root) { return }
            if Self.rearmFutureOneShot(&object, now: now, life: try DataRootLife.current(in: root)) {
                rows[index] = .object(object)
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
                try Self.stampNextRun(&object, epoch: next)
            } else {
                object["enabled"] = .bool(false)
                object["disabledReason"] = .string("unknown outcome and next run could not be computed")
            }
            // Unknown means "do not automatically replay." Any prior retry
            // floor/counter would contradict that settlement and could re-arm
            // the same occurrence through catch-up logic.
            Self.clearRetryState(&object)
            rows[index] = .object(object)
        }
    }

    public func settleOccurrence(
        jobId: String, occurrenceKey: String, status: String, detail: String,
        seen: [String]? = nil, at runDate: Date
    ) async throws {
        try await updateJobRows { rows in
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
                    try Self.stampNextRun(&obj, epoch: next)
                    Self.clearRetryState(&obj)
                } else {
                    obj["enabled"] = .bool(false)
                    obj["disabledReason"] = .string("could not compute next scheduled run")
                    Self.clearRetryState(&obj)
                }
                obj["lastOccurrenceKey"] = .string(occurrenceKey)
                // A watch keeps the rows its read saw on its own row, for the next read to compare.
                if let seen { obj["lastSeen"] = .array(seen.map(JSONValue.string)) }
                obj.removeValue(forKey: "activeOccurrence")
                rows[idx] = .object(obj)
                break
            }
            guard found else {
                throw NSError(domain: "NativeAgentScheduler", code: -404, userInfo: [
                    NSLocalizedDescriptionKey: "scheduler_job_missing: Scheduled Desk task \(jobId) disappeared before settlement. Effects may have occurred; inspect scheduler/jobs.json and the delivery receipts before recreating it."
                ])
            }
        }

    }

    /// Record retirement durably before removing rows under the jobs lock;
    /// a kept row the selection changed (paused) is written too.
    @discardableResult
    public func pruneJobs(
        select: @Sendable ([JSONValue]) -> (rows: [JSONValue], retired: [JSONValue])
    ) async throws -> Int {
        try await SwiftNativePersistenceCore.withFileLock(jobsPath) { () async throws -> Int in
            let rows = try Self.readJobsChecked(at: jobsPath)
            let result = select(rows)
            guard !result.retired.isEmpty || result.rows != rows else { return 0 }
            if !result.retired.isEmpty {
                try await SwiftNativePersistenceCore.appendJSONLDurable(result.retired, to: jobsPath.deletingLastPathComponent()
                    .appendingPathComponent("retired.jsonl"))
            }
            try await SwiftNativePersistenceCore.writeDataAtomicDurableAsync(SwiftNativeTriggerScheduler.jobsDataForWrite(result.rows), to: jobsPath)
            return result.retired.count
        }
    }

    public func markDefaultCycleJobRun(id: String, detail: String, at runDate: Date) async throws {
        try await updateJobRows { rows in
            for idx in rows.indices {
                guard case .object(var obj) = rows[idx],
                      (SchedulerJobRuntime.string(obj["id"]) ?? "") == id else {
                    continue
                }
                obj["lastRunAt"] = .string(Self.isoTimestamp(runDate))
                obj["lastRunStatus"] = .string("completed")
                obj["lastRunDetail"] = .string(detail)
                obj.removeValue(forKey: "lastRunError")
                // A completion clears retry backoff.
                Self.clearRetryState(&obj)
                if let next = try? SchedulerJobRuntime.nextRunEpochAfterNow(for: .object(obj), now: { runDate }) {
                    try Self.stampNextRun(&obj, epoch: next)
                }
                rows[idx] = .object(obj)
                break
            }
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
            try stampNextRun(&next, epoch: nextRunEpoch)
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
    static func stampNextRun(_ obj: inout [String: JSONValue], epoch: Double) throws {
        let seconds = try SchedulerJobNormalizer.checkedEpoch(epoch)
        obj["nextRunAt"] = .string(SchedulerJobRuntime.floatString(epoch))
        obj["nextRunAtEpoch"] = .int(seconds)
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
