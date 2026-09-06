import Foundation
import NativeAgentCore
import PersistenceCore
import TelegramBot
import TriggerScheduler

extension SchedulerDueJobRunner {
    /// Earliest persisted scheduler-job crossing. Future rows retain their
    /// exact stored instant; an already-due row asks for one legacy-cadence
    /// retry so a capped batch or failed persistence update cannot disappear
    /// until the slow integrity sweep. Startup and source-change reconciliation
    /// still run immediately through BackgroundLoopsManager.
    func nextMeaningfulDeadline(after now: Date) async -> Date? {
        let rows = try? await persistence.withFileLock(jobsPath) {
            try Self.readJobRowsChecked(at: jobsPath)
        }
        guard let rows else { return nil }
        let nowEpoch = now.timeIntervalSince1970
        var earliestFuture: Double?
        var hasOverdue = false
        for row in rows {
            guard case .object(let obj) = row,
                  SchedulerJobRuntime.bool(obj["enabled"], default: true) else { continue }
            guard let epoch = SchedulerJobRuntime.epoch(from: obj["nextRunAt"])
                ?? SchedulerJobRuntime.epoch(from: obj["nextRunAtEpoch"]),
                  epoch.isFinite else { continue }
            if epoch <= nowEpoch {
                hasOverdue = true
            } else if earliestFuture == nil || epoch < earliestFuture! {
                earliestFuture = epoch
            }
        }
        if hasOverdue {
            // Preserve the retired 60-second recovery cadence only while
            // canonical state remains overdue; ordinary schedules no longer
            // wake on that cadence.
            return now.addingTimeInterval(60)
        }
        return earliestFuture.map { Date(timeIntervalSince1970: $0) }
    }

    func selectDueJobs(now: Date, maxJobs: Int) async throws -> [DueJob] {
        let nowEpoch = now.timeIntervalSince1970
        let rows = try await persistence.withFileLock(jobsPath) {
            try Self.readJobRowsChecked(at: jobsPath)
        }
        return Self.dueJobs(in: rows, nowEpoch: nowEpoch, maxJobs: maxJobs)
    }

    /// Atomically selects and claims scheduled occurrences before any effect
    /// executes. A claim surviving process restart is an ambiguous outcome,
    /// not permission to repeat a notification, connector action, Desk task,
    /// or other non-idempotent effect.
    /// - Parameter excludingJobIds: rows the caller has already handled and
    ///   cannot make progress on during this pass (2026-09-06: a recovered
    ///   claim whose reconciliation notice could not be written). Selection
    ///   claims one earliest-due row at a time, so without this the same row
    ///   would be re-detected every iteration and later due jobs would starve.
    func claimDueJobs(
        now: Date,
        maxJobs: Int,
        excludingJobIds: Set<String> = []
    ) async throws -> ClaimedDueJobs {
        try await persistence.withFileLock(jobsPath) { () async throws -> ClaimedDueJobs in
            var rows = try Self.readJobRowsChecked(at: jobsPath)
            let selected = Self.dueJobs(
                in: rows,
                nowEpoch: now.timeIntervalSince1970,
                // An occurrence claim is intentionally one-at-a-time. Keep the
                // legacy parameter for source compatibility, but make it
                // impossible for a future caller to preclaim an untouched
                // batch that would become falsely ambiguous after a crash.
                maxJobs: min(max(0, maxJobs), 1),
                excludingJobIds: excludingJobIds
            )
            guard !selected.isEmpty else { return ClaimedDueJobs(jobs: [], recoveredUnknown: []) }

            var claimed: [DueJob] = []
            var recovered: [OccurrenceRecovery] = []
            for job in selected {
                guard let index = rows.firstIndex(where: { row in
                    guard case .object(let object) = row else { return false }
                    return SchedulerJobRuntime.string(object["id"]) == job.id
                }), case .object(var object) = rows[index] else { continue }

                if let activeValue = object["activeOccurrence"] {
                    let decodedPriorKey: String?
                    if case .object(let active) = activeValue {
                        decodedPriorKey = SchedulerJobRuntime.string(active["key"])
                    } else {
                        decodedPriorKey = nil
                    }
                    let priorKey = decodedPriorKey ?? job.occurrenceKey
                    let detail: String
                    if decodedPriorKey == nil {
                        detail = "A prior scheduler occurrence claim was malformed. Its external effect "
                            + "may have happened, so NativeAgent preserved the claim and did not repeat it."
                    } else {
                        detail = "A prior scheduler pass ended after claiming occurrence \(priorKey). "
                            + "Its external effect may have happened, so NativeAgent did not repeat it."
                    }
                    // DETECTION ONLY (2026-09-06). The row is left exactly as
                    // found — claim intact, next run unmoved — until the caller
                    // has the reconciliation notice durably on record and calls
                    // `settleUnknownOccurrence`. Clearing it here gave the
                    // notice a ONE-ATTEMPT window: the claim and the old
                    // schedule were already gone, so a failed notice write left
                    // nothing for a later pass to find and reconcile. Either
                    // way this job is not claimed on this pass, so nothing can
                    // be replayed by waiting.
                    recovered.append(OccurrenceRecovery(
                        jobId: job.id,
                        jobName: job.name,
                        kind: job.kind,
                        occurrenceKey: priorKey,
                        detail: detail
                    ))
                    continue
                }

                object["activeOccurrence"] = .object([
                    "key": .string(job.occurrenceKey),
                    "dueEpoch": .int(Int64(job.dueEpoch.rounded())),
                    "claimedAt": .string(Self.iso(now)),
                    "state": .string("claimed"),
                ])
                rows[index] = .object(object)
                claimed.append(job)
            }
            // 2026-09-06: detection is read-only, so a scan that only recovered
            // stale claims changed no row. Rewriting jobs.json anyway rewrote
            // canonical state for nothing and gave a read-only pass a write's
            // failure surface.
            if !claimed.isEmpty {
                try await persistence.writeJSON(.array(rows), to: jobsPath)
            }
            return ClaimedDueJobs(jobs: claimed, recoveredUnknown: recovered)
        }
    }

    /// Release a recovered stale claim and advance the job — ONLY once its
    /// reconciliation notice is on record. Re-reads the row under the lock and
    /// does nothing if the claim is already gone, so a retry after a partial
    /// pass is harmless.
    func settleUnknownOccurrence(_ recovery: OccurrenceRecovery, now: Date) async throws {
        try await persistence.withFileLock(jobsPath) { () async throws -> Void in
            var rows = try Self.readJobRowsChecked(at: jobsPath)
            guard let index = rows.firstIndex(where: { row in
                guard case .object(let object) = row else { return false }
                return SchedulerJobRuntime.string(object["id"]) == recovery.jobId
            }), case .object(var object) = rows[index],
                let activeValue = object["activeOccurrence"] else { return }
            var decodedPriorKey: String?
            if case .object(let active) = activeValue {
                decodedPriorKey = SchedulerJobRuntime.string(active["key"])
            }
            if decodedPriorKey == nil { object["lastInvalidOccurrenceClaim"] = activeValue }
            object["lastRunAt"] = .string(Self.iso(now))
            object["lastRunStatus"] = .string("unknown")
            object["lastRunDetail"] = .string(recovery.detail)
            object["lastRunError"] = .string(recovery.detail)
            object["lastUnknownOccurrenceKey"] = .string(recovery.occurrenceKey)
            object.removeValue(forKey: "activeOccurrence")
            if SchedulerJobRuntime.bool(object["oneShot"], default: false) {
                object["enabled"] = .bool(false)
                object["disabledReason"] = .string("unknown outcome after restart; review before retry")
            } else if let next = try? SchedulerJobRuntime.nextRunEpochAfterNow(
                for: .object(object), now: { now }
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
            try await persistence.writeJSON(.array(rows), to: jobsPath)
        }
    }

    private static func dueJobs(
        in rows: [JSONValue],
        nowEpoch: Double,
        maxJobs: Int,
        excludingJobIds: Set<String> = []
    ) -> [DueJob] {
        // The cap is applied AFTER an earliest-due-first sort. Walking file
        // order and breaking at `maxJobs` meant a row late in jobs.json could
        // starve behind head rows once the job list outgrew the cap, no matter
        // how overdue it was. Ties keep file order (the index tiebreak makes
        // the sort stable), so nothing else about selection changes.
        var due: [(job: DueJob, index: Int)] = []
        for (index, row) in rows.enumerated() {
            guard case .object(let obj) = row else { continue }
            guard SchedulerJobRuntime.bool(obj["enabled"], default: true) else { continue }
            let nextEpoch = SchedulerJobRuntime.epoch(from: obj["nextRunAt"])
                ?? SchedulerJobRuntime.epoch(from: obj["nextRunAtEpoch"])
            guard let nextEpoch, nextEpoch <= nowEpoch else { continue }
            // A scheduled effect without durable job identity cannot acquire a
            // stable occurrence claim or be settled safely. Job creation owns
            // IDs; malformed legacy rows remain untouched for repair.
            guard let id = SchedulerJobRuntime.string(obj["id"]), !id.isEmpty else { continue }
            // Excluded BEFORE the cap, so a deferred row cannot consume the
            // one-at-a-time claim slot that a later due job needs.
            guard !excludingJobIds.contains(id) else { continue }
            let name = SchedulerJobRuntime.string(obj["name"]) ?? id
            let kind = (SchedulerJobRuntime.string(obj["kind"]) ?? "notify").lowercased()
            let payload: [String: JSONValue]
            if case .object(let p)? = obj["payload"] { payload = p } else { payload = [:] }
            due.append((
                DueJob(id: id, name: name, kind: kind, payload: payload, row: row, dueEpoch: nextEpoch),
                index
            ))
        }
        due.sort {
            $0.job.dueEpoch == $1.job.dueEpoch
                ? $0.index < $1.index
                : $0.job.dueEpoch < $1.job.dueEpoch
        }
        return due.prefix(max(0, maxJobs)).map(\.job)
    }

    /// - Parameter reactivateCancelled: when true, a user-cancelled default
    ///   cycle job (enabled=false + cancelledAt tombstone) is re-enabled and
    ///   the tombstone stripped. Only the EXPLICIT user re-enable action
    ///   (AppModel.createDreamJob) passes true; the passive due-job bootstrap
    ///   pass keeps false so a cancelled job is not silently resurrected.
    func ensureDefaultCycleJobs(now: Date, reactivateCancelled: Bool = false) async throws -> [String] {
        let runDateKey = NativeAgentDreamCycleSchedule.runDateKey(now)
        let dreamDateKey = NativeAgentDreamCycleSchedule.dreamEntryDateKey(now)
        let dreamAlreadyHasEntry = Self.hasDreamEntry(dataRoot: root, dateKey: dreamDateKey)
        let scheduledDreamTimePassed = NativeAgentDreamCycleSchedule.clockHasReached(
            now,
            hour: NativeAgentDreamCycleSchedule.dreamHour,
            minute: NativeAgentDreamCycleSchedule.dreamMinute
        )
        let scheduledREMTimePassed = NativeAgentDreamCycleSchedule.isSunday(now)
            && NativeAgentDreamCycleSchedule.clockHasReached(
                now,
                hour: NativeAgentDreamCycleSchedule.remHour,
                minute: NativeAgentDreamCycleSchedule.remMinute
            )

        let repaired = try await persistence.withFileLock(jobsPath) { () async throws -> [String] in
            var rows = try Self.readJobRowsChecked(at: jobsPath)
            var repaired: [String] = []

            let dreamRanToday = Self.containsLastRunToday(rows: rows, kind: "dream", dateKey: runDateKey)
            let remRanToday = Self.containsLastRunToday(rows: rows, kind: "rem", dateKey: runDateKey)
            // FIX 2 (A4.4): once the dream job is PARKED for the day (retry cap
            // reached), catch-up must stay disarmed even though a failed run
            // does not count as "ran today" — otherwise the park would re-arm
            // the ≈now catch-up stamp and revive the storm the park exists to
            // stop. The park self-clears when the day rolls over.
            let dreamParkedToday = Self.containsRetryParkedToday(rows: rows, kind: "dream", dateKey: runDateKey)
            let dreamCatchUp = scheduledDreamTimePassed && !dreamAlreadyHasEntry && !dreamRanToday && !dreamParkedToday
            let remCatchUp = scheduledREMTimePassed && !remRanToday

            let dreamSchedule = NativeAgentDreamCycleSchedule.dreamSchedule
            let remSchedule = NativeAgentDreamCycleSchedule.remSchedule
            let agentName = NativeAgentNotificationDefaults.agentDisplayName(dataRoot: root)
            let dreamJobName = "\(agentName) Nightly Dream"
            let remJobName = "\(agentName) Weekly REM"
            let legacyAgentKey = agentName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

            let dreamNext = dreamCatchUp
                ? now.timeIntervalSince1970
                : try Self.nextEpoch(schedule: dreamSchedule, now: now, fallbackInterval: 86_400)
            let remNext = remCatchUp
                ? now.timeIntervalSince1970
                : try Self.nextEpoch(schedule: remSchedule, now: now, fallbackInterval: 604_800)

            if Self.upsertDefaultCycleJob(
                rows: &rows,
                id: "nativeagent-nightly-dream",
                legacyNames: ["nightly reflection", "assistant nightly dream", "\(legacyAgentKey) nightly dream"],
                name: dreamJobName,
                kind: "dream",
                intervalSeconds: 86_400,
                schedule: dreamSchedule,
                objective: "Scheduled reflection",
                extraPayload: [:],
                nextRunEpoch: dreamNext,
                now: now,
                reactivateCancelled: reactivateCancelled
            ) {
                repaired.append(dreamCatchUp ? "\(dreamJobName) (catch-up due now)" : dreamJobName)
            }

            if Self.upsertDefaultCycleJob(
                rows: &rows,
                id: "nativeagent-weekly-rem",
                legacyNames: ["weekly rem", "assistant weekly rem", "\(legacyAgentKey) weekly rem", "rem consolidation"],
                name: remJobName,
                kind: "rem",
                intervalSeconds: 604_800,
                schedule: remSchedule,
                objective: "Scheduled REM consolidation",
                extraPayload: [:],
                nextRunEpoch: remNext,
                now: now,
                reactivateCancelled: reactivateCancelled
            ) {
                repaired.append(remCatchUp ? "\(remJobName) (catch-up due now)" : remJobName)
            }

            if !repaired.isEmpty {
                try await persistence.writeJSON(.array(rows), to: jobsPath)
            }
            return repaired
        }
        return repaired
    }

    func backfillDreamReceiptIfNeeded(now: Date) async throws -> String? {
        let dateKey = NativeAgentDreamCycleSchedule.dreamEntryDateKey(now)
        let entries = Self.dreamEntriesForToday(dataRoot: root, dateKey: dateKey)
        guard !entries.isEmpty else { return nil }
        guard !(try await notificationInboxContains(source: "dream_cycle", dateKey: dateKey)) else { return nil }

        let paths = entries.map { $0.path }
        let agentName = NativeAgentNotificationDefaults.agentDisplayName(dataRoot: root)
        let title = "\(agentName) dreamed"
        let message = Self.dreamInboxMessage(
            entriesWritten: entries.count,
            sessionsProcessed: entries.count,
            errors: [],
            entries: entries
        )
        let itemId = "dream-cycle-\(dateKey)-backfill"
        try await appendNotificationInbox(
            title: title,
            message: message,
            source: "dream_cycle",
            severity: "important",
            jobId: "nativeagent-nightly-dream",
            itemId: itemId,
            relatedPaths: paths
        )
        _ = try await archiveOlderDreamInboxItems(keeping: itemId)
        _ = await postCycleNotification(
            title: title,
            body: Self.notificationBody(message),
            jobId: "nativeagent-nightly-dream",
            source: "dream_cycle",
            itemId: itemId
        )
        try await markDefaultCycleJobRun(
            id: "nativeagent-nightly-dream",
            detail: "dream entries found; inbox receipt backfilled",
            at: now
        )
        return itemId
    }
}
