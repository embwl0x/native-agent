import Foundation
import NativeAgentCore
import PersistenceCore
import TelegramBot
import TriggerScheduler
import DeviceSync

extension SchedulerDueJobRunner {
    /// Earliest persisted scheduler-job crossing. Future rows retain their
    /// exact stored instant; an already-due row asks for one legacy-cadence
    /// retry so a capped batch or failed persistence update cannot disappear
    /// until the slow integrity sweep. Startup and source-change reconciliation
    /// still run immediately through BackgroundLoopsManager.
    public func nextMeaningfulDeadline(after now: Date) async -> Date? {
        let rows = try? await schedulerJobs.jobRows()
        guard let rows else { return nil }
        let nowEpoch = now.timeIntervalSince1970
        var earliestFuture: Double?
        var hasOverdue = false
        for row in rows {
            guard case .object(let obj) = row,
                  SchedulerJobRuntime.bool(obj["enabled"], default: true) else { continue }
            guard let epoch = SchedulerJobRuntime.scheduledEpoch(for: obj),
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

    func claimDueJob(now: Date, excludingJobIds: Set<String> = []) async throws -> ClaimedDueJobs {
        try await schedulerJobs.claimDueJobs(now: now) { rows in
            Self.dueJobs(in: rows, nowEpoch: now.timeIntervalSince1970,
                         excludingJobIds: excludingJobIds)
        }
    }

    private static func dueJobs(
        in rows: [JSONValue],
        nowEpoch: Double,
        excludingJobIds: Set<String> = []
    ) -> [DueJob] {
        // Claim only the earliest due occurrence; ties retain file order.
        var earliest: (row: JSONValue, fields: [String: JSONValue], id: String, epoch: Double)?
        for row in rows {
            guard case .object(let obj) = row else { continue }
            guard SchedulerJobRuntime.bool(obj["enabled"], default: true) else { continue }
            let nextEpoch = SchedulerJobRuntime.scheduledEpoch(for: obj)
            guard let nextEpoch, nextEpoch <= nowEpoch else { continue }
            // A scheduled effect without durable job identity cannot acquire a
            // stable occurrence claim or be settled safely. Job creation owns
            // IDs; malformed legacy rows remain untouched for repair.
            guard let id = SchedulerJobRuntime.string(obj["id"]), !id.isEmpty else { continue }
            // Excluded BEFORE the cap, so a deferred row cannot consume the
            // one-at-a-time claim slot that a later due job needs.
            guard !excludingJobIds.contains(id) else { continue }
            if earliest == nil || nextEpoch < earliest!.epoch {
                earliest = (row, obj, id, nextEpoch)
            }
        }
        guard let earliest else { return [] }
        let name = SchedulerJobRuntime.string(earliest.fields["name"]) ?? earliest.id
        let kind = (SchedulerJobRuntime.string(earliest.fields["kind"]) ?? "notify").lowercased()
        let payload: [String: JSONValue]
        if case .object(let p)? = earliest.fields["payload"] { payload = p } else { payload = [:] }
        return [DueJob(id: earliest.id, name: name, kind: kind, payload: payload,
                       row: earliest.row, dueEpoch: earliest.epoch)]
    }

    /// - Parameter reactivateCancelled: when true, a user-cancelled nightly
    ///   dream job (enabled=false + cancelledAt tombstone) is re-enabled and
    ///   the tombstone stripped. Dream only: re-adding the nightly reflection
    ///   says nothing about a weekly REM job someone cancelled. Only the EXPLICIT user re-enable action
    ///   (AppModel.createDreamJob) passes true; the passive due-job bootstrap
    ///   pass keeps false so a cancelled job is not silently resurrected.
    public func ensureDefaultCycleJobs(now: Date, reactivateCancelled: Bool = false) async throws -> [String] {
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

        let root = root
        let repaired = try await schedulerJobs.updateJobRows { rows in
            var repaired: [String] = []

            // Failed dream attempts settle this day's catch-up too. Only the
            // retry policy may schedule another attempt after a failure.
            let dreamRanToday = Self.containsLastRunToday(rows: rows, kind: "dream", dateKey: runDateKey, includingFailed: true)
            let remRanToday = Self.containsLastRunToday(rows: rows, kind: "rem", dateKey: runDateKey)
            // The daily retry cap also disarms catch-up until the day rolls over.
            let dreamParkedToday = Self.containsRetryParkedToday(rows: rows, kind: "dream", dateKey: runDateKey)
            let dreamCatchUp = scheduledDreamTimePassed && !dreamAlreadyHasEntry && !dreamRanToday && !dreamParkedToday
            let remCatchUp = scheduledREMTimePassed && !remRanToday

            let dreamSchedule = NativeAgentDreamCycleSchedule.dreamSchedule
            let remSchedule = NativeAgentDreamCycleSchedule.remSchedule
            let agentName = NativeAgentNotificationDefaults.agentDisplayName(dataRoot: root)
            let dreamJobName = "\(agentName) Nightly Dream"
            let remJobName = "\(agentName) Weekly REM"
            let legacyAgentKey = agentName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

            if try SwiftNativeTriggerScheduler.upsertDefaultCycleJob(
                rows: &rows,
                id: "nativeagent-nightly-dream",
                legacyNames: ["nightly reflection", "assistant nightly dream", "\(legacyAgentKey) nightly dream"],
                name: dreamJobName,
                kind: "dream",
                intervalSeconds: 86_400,
                schedule: dreamSchedule,
                objective: "Scheduled reflection",
                extraPayload: [:],
                nextRunEpoch: dreamCatchUp ? now.timeIntervalSince1970 : try Self.nextEpoch(schedule: dreamSchedule, now: now),
                now: now,
                reactivateCancelled: reactivateCancelled
            ) {
                repaired.append(dreamCatchUp ? "\(dreamJobName) (catch-up due now)" : dreamJobName)
            }

            if try SwiftNativeTriggerScheduler.upsertDefaultCycleJob(
                rows: &rows,
                id: "nativeagent-weekly-rem",
                legacyNames: ["weekly rem", "assistant weekly rem", "\(legacyAgentKey) weekly rem", "rem consolidation"],
                name: remJobName,
                kind: "rem",
                intervalSeconds: 604_800,
                schedule: remSchedule,
                objective: "Scheduled REM consolidation",
                extraPayload: [:],
                nextRunEpoch: remCatchUp ? now.timeIntervalSince1970 : try Self.nextEpoch(schedule: remSchedule, now: now),
                now: now
            ) {
                repaired.append(remCatchUp ? "\(remJobName) (catch-up due now)" : remJobName)
            }

            return repaired
        }
        return repaired
    }

    func backfillDreamReceiptIfNeeded(now: Date) async throws -> String? {
        let dateKey = NativeAgentDreamCycleSchedule.dreamEntryDateKey(now)
        guard !(try await notificationInboxContains(source: "dream_cycle", dateKey: dateKey)) else { return nil }
        let entries = Self.dreamEntriesForToday(dataRoot: root, dateKey: dateKey)
        guard !entries.isEmpty else { return nil }

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
        try await schedulerJobs.markDefaultCycleJobRun(
            id: "nativeagent-nightly-dream",
            detail: "dream entries found; inbox receipt backfilled",
            at: now
        )
        return itemId
    }
}
