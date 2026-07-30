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
        let raw = try? await persistence.withFileLock(jobsPath) {
            await persistence.readJSON(jobsPath, defaultValue: .array([]))
        }
        guard case .array(let rows)? = raw else { return nil }
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
        let raw = try await persistence.withFileLock(jobsPath) {
            await persistence.readJSON(jobsPath, defaultValue: .array([]))
        }
        guard case .array(let rows) = raw else { return [] }
        var due: [DueJob] = []
        for row in rows {
            guard case .object(let obj) = row else { continue }
            guard SchedulerJobRuntime.bool(obj["enabled"], default: true) else { continue }
            let nextEpoch = SchedulerJobRuntime.epoch(from: obj["nextRunAt"])
                ?? SchedulerJobRuntime.epoch(from: obj["nextRunAtEpoch"])
            guard let nextEpoch, nextEpoch <= nowEpoch else { continue }
            let id = SchedulerJobRuntime.string(obj["id"]) ?? UUID().uuidString.lowercased()
            let name = SchedulerJobRuntime.string(obj["name"]) ?? id
            let kind = (SchedulerJobRuntime.string(obj["kind"]) ?? "notify").lowercased()
            let payload: [String: JSONValue]
            if case .object(let p)? = obj["payload"] { payload = p } else { payload = [:] }
            due.append(DueJob(id: id, name: name, kind: kind, payload: payload, row: row, dueEpoch: nextEpoch))
            if due.count >= maxJobs { break }
        }
        return due
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
            let raw = await persistence.readJSON(jobsPath, defaultValue: .array([]))
            var rows: [JSONValue]
            if case .array(let arr) = raw { rows = arr } else { rows = [] }
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
