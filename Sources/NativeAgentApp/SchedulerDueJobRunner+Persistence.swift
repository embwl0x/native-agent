import Foundation
import NativeAgentCore
import PersistenceCore
import TelegramBot
import TriggerScheduler

extension SchedulerDueJobRunner {
    func update(job: DueJob, result: JobResult, at runDate: Date) async throws {
        // FIX 2 (A4.4): a park (retry cap reached) must leave a user-visible
        // receipt. The park decision is made under the jobs lock; the receipt
        // is emitted afterward so the two file locks never nest.
        let parkedAttempts: Int? = try await persistence.withFileLock(jobsPath) { () async throws -> Int? in
            let raw = await persistence.readJSON(jobsPath, defaultValue: .array([]))
            guard case .array(var rows) = raw else { return nil }
            var parkedAttempts: Int?
            for idx in rows.indices {
                guard case .object(var obj) = rows[idx],
                      (SchedulerJobRuntime.string(obj["id"]) ?? "") == job.id else {
                    continue
                }
                obj["lastRunAt"] = .string(Self.iso(runDate))
                obj["lastRunStatus"] = .string(result.status)
                obj["lastRunDetail"] = .string(String(result.detail.prefix(1000)))
                if result.status == "error" {
                    obj["lastRunError"] = .string(String(result.detail.prefix(1000)))
                } else {
                    obj.removeValue(forKey: "lastRunError")
                }

                let oneShot = SchedulerJobRuntime.bool(obj["oneShot"], default: false)
                if oneShot {
                    obj["enabled"] = .bool(false)
                    obj["completedAt"] = .string(Self.iso(runDate))
                    Self.clearRetryState(&obj)
                } else if let retryFloor = Self.retryEpoch(from: result.output, runDate: runDate) {
                    // FIX 2 (A4.4): per-job retry count + exponential backoff +
                    // a daily attempt cap. The retry stamp IS the backoff
                    // carrier and composes with FIX 1 (catch-up honors
                    // retryPendingUntilEpoch as a floor).
                    let todayKey = NativeAgentDreamCycleSchedule.runDateKey(runDate)
                    let sameDay = SchedulerJobRuntime.string(obj["retryDayKey"]) == todayKey
                    let priorCount = sameDay ? SchedulerJobRuntime.int(obj["retryCount"], default: 0) : 0
                    let attempt = priorCount + 1
                    obj["retryDayKey"] = .string(todayKey)
                    obj["retryCount"] = .int(Int64(attempt))
                    if attempt > Self.maxRetryAttemptsPerDay {
                        // Cap reached: PARK. Stop retrying today, reschedule to
                        // the next natural run, drop the pending-retry floor,
                        // and mark the day parked so catch-up stays disarmed.
                        // A receipt is emitted below (never a silent give-up).
                        obj["retryParkedDateKey"] = .string(todayKey)
                        obj.removeValue(forKey: "retryPendingUntilEpoch")
                        if let next = try? SchedulerJobRuntime.nextRunEpochAfterNow(for: .object(obj), now: { runDate }) {
                            Self.stampNextRun(&obj, epoch: next)
                        }
                        parkedAttempts = attempt - 1
                    } else {
                        let backoff = runDate
                            .addingTimeInterval(Double(Self.retryBackoffSeconds(attempt: attempt)))
                            .timeIntervalSince1970
                        let retry = max(retryFloor, backoff)
                        Self.stampNextRun(&obj, epoch: retry)
                        obj["retryPendingUntilEpoch"] = .int(Int64(retry))
                    }
                } else if let next = try? SchedulerJobRuntime.nextRunEpochAfterNow(for: .object(obj), now: { runDate }) {
                    Self.stampNextRun(&obj, epoch: next)
                    Self.clearRetryState(&obj)
                } else {
                    obj["enabled"] = .bool(false)
                    obj["disabledReason"] = .string("could not compute next scheduled run")
                    Self.clearRetryState(&obj)
                }
                rows[idx] = .object(obj)
                break
            }
            try await persistence.writeJSON(.array(rows), to: jobsPath)
            return parkedAttempts
        }

        if let attempts = parkedAttempts {
            let agentName = NativeAgentNotificationDefaults.agentDisplayName(dataRoot: root)
            try? await appendNotificationInbox(
                title: "\(job.name) paused after repeated failures",
                message: "\(job.name) failed \(attempts) time\(attempts == 1 ? "" : "s") today and was paused to stop a retry storm. \(agentName) will try again at its next scheduled time.",
                source: "scheduler",
                severity: "important",
                jobId: job.id
            )
        }
    }

    /// FIX 3 (A4.5): prune completed oneShot rows past the retention window.
    /// Runs each due-job pass under the same jobs lock; a no-op write is
    /// avoided when nothing crossed the window. Returns the number removed.
    @discardableResult
    func pruneCompletedOneShotJobs(now: Date) async throws -> Int {
        try await persistence.withFileLock(jobsPath) { () async throws -> Int in
            let raw = await persistence.readJSON(jobsPath, defaultValue: .array([]))
            guard case .array(let rows) = raw else { return 0 }
            let result = Self.pruneCompletedOneShotRows(rows, now: now)
            guard result.removed > 0 else { return 0 }
            try await persistence.writeJSON(.array(result.rows), to: jobsPath)
            return result.removed
        }
    }

    func appendActivity(
        jobId: String?,
        kind: String,
        title: String,
        detail: String,
        status: String,
        payload: JSONValue
    ) async throws {
        var payloadObj: [String: JSONValue] = [:]
        if case .object(let obj) = payload { payloadObj = obj }
        if let jobId { payloadObj["jobId"] = .string(jobId) }
        let event: JSONValue = .object([
            "id": .string(UUID().uuidString.lowercased()),
            "kind": .string("scheduler"),
            "title": .string(NativeAppSecretRedactor.redactText(title)),
            "detail": .string(NativeAppSecretRedactor.redactText(String(detail.prefix(1000)))),
            "status": .string(status),
            "executionId": .null,
            "payload": NativeAppSecretRedactor.redactValue(.object(payloadObj)),
            "createdAt": .string(Self.iso(Date())),
        ])
        // U5 fix-round (2026-06-11, gpt-5.5 review): routed through the shared
        // capped append (PersistenceCore.appendJSONLCapped) — same flock as
        // before, plus the shared activity-feed line cap with rotation logging.
        try await appendJSONLCapped(
            event, to: activityPath, using: persistence,
            logLabel: "SchedulerDueJobRunner"
        )
    }

    func appendNotificationInbox(
        title: String,
        message: String,
        source: String,
        severity: String,
        jobId: String,
        itemId: String = "scheduled-\(UUID().uuidString.lowercased())",
        relatedPaths: [String] = [],
        detail: String? = nil,
        actions: [JSONValue] = [],
        notifyPhone: Bool = false
    ) async throws {
        let now = Self.iso(Date())
        let row: JSONValue = .object([
            "id": .string(itemId),
            "created_at": .string(now),
            "source": .string(source),
            "severity": .string(severity),
            "title": .string(NativeAppSecretRedactor.redactText(String(title.prefix(160)))),
            "summary": .string(NativeAppSecretRedactor.redactText(String(message.prefix(500)))),
            "detail": .string(NativeAppSecretRedactor.redactText(String((detail ?? message).prefix(2000)))),
            "related_mission_id": .null,
            "related_approval_id": .null,
            "related_paths": .array(relatedPaths.map { .string($0) }),
            "related_groups": .array([]),
            "actions": .array(actions),
            "status": .string("unread"),
            "read_at": .null,
            "schedulerJobId": .string(jobId),
        ])
        // 2026-07-21 audit (MED): route through the shared capped append —
        // notifications/inbox.jsonl is the LIVE inbox the UI and iOS read and
        // grew with no rotation. Same 1000-line budget as the legacy
        // items.jsonl cap; the trim runs under the same flock as the append.
        try await appendJSONLCapped(
            row, to: notificationInboxPath, using: persistence,
            maxLines: JSONLLineCaps.notificationInbox,
            logLabel: "SchedulerDueJobRunner.inbox"
        )
        if notifyPhone {
            await InboxPushNotifier.notifyIfAttentionWorthy(
                dataRoot: root,
                itemId: itemId,
                title: title,
                summary: message,
                source: source,
                severity: severity
            )
        }
    }

    @discardableResult
    func archiveOlderDreamInboxItems(keeping keepItemId: String) async throws -> Int {
        let inboxPath = notificationInboxPath
        return try await persistence.withFileLock(inboxPath) { () async throws -> Int in
            let rows = try await persistence.readJSONL(inboxPath)
            let result = NativeAgentDreamNotificationInboxPolicy.archiveOlderDreamRows(
                rows,
                keeping: keepItemId
            )
            guard result.archivedCount > 0 else { return 0 }
            let payload = try result.rows
                .map { try $0.serialize(pretty: false) }
                .joined(separator: "\n")
            try FileManager.default.createDirectory(
                at: inboxPath.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try Data((payload + "\n").utf8).write(to: inboxPath, options: [.atomic])
            _ = chmod(inboxPath.path, 0o600)
            return result.archivedCount
        }
    }

    func notificationInboxContains(source: String, dateKey: String) async throws -> Bool {
        let rows = (try? await persistence.readJSONL(notificationInboxPath)) ?? []
        for row in rows {
            guard case .object(let obj) = row else { continue }
            guard SchedulerJobRuntime.string(obj["source"]) == source else { continue }
            guard let created = SchedulerJobRuntime.string(obj["created_at"]),
                  let date = Self.parseISODate(created) else { continue }
            if Self.notificationRowReferencesDate(obj, dateKey: dateKey)
                || NativeAgentDreamCycleSchedule.runDateKey(date) == dateKey {
                return true
            }
        }
        return false
    }

    func markDefaultCycleJobRun(id: String, detail: String, at runDate: Date) async throws {
        try await persistence.withFileLock(jobsPath) {
            let raw = await persistence.readJSON(jobsPath, defaultValue: .array([]))
            guard case .array(var rows) = raw else { return }
            for idx in rows.indices {
                guard case .object(var obj) = rows[idx],
                      (SchedulerJobRuntime.string(obj["id"]) ?? "") == id else {
                    continue
                }
                obj["lastRunAt"] = .string(Self.iso(runDate))
                obj["lastRunStatus"] = .string("completed")
                obj["lastRunDetail"] = .string(detail)
                obj.removeValue(forKey: "lastRunError")
                // FIX 2 (A4.4): a successful/backfilled completion clears the
                // retry backoff so it self-heals once the outage clears.
                Self.clearRetryState(&obj)
                if let next = try? SchedulerJobRuntime.nextRunEpochAfterNow(for: .object(obj), now: { runDate }) {
                    obj["nextRunAt"] = .string(SchedulerJobRuntime.floatString(next))
                    obj["nextRunAtEpoch"] = .int(Int64(next))
                    obj["nextRunAtISO"] = .string(SchedulerJobRuntime.decorationISO(epoch: next))
                }
                rows[idx] = .object(obj)
                break
            }
            try await persistence.writeJSON(.array(rows), to: jobsPath)
        }
    }

    func postCycleNotification(title: String, body: String, jobId: String, source: String, itemId: String? = nil) async -> JSONValue {
        var delivered: [JSONValue] = []
        var errors: [JSONValue] = []

        let mac = await NativeAgentNotifications.postAndReport(title: title, body: body)
        if mac.posted {
            delivered.append(.string("mac"))
        } else if let error = mac.error {
            errors.append(.string("mac: \(error)"))
        } else {
            errors.append(.string("mac: \(mac.delivery)"))
        }

        do {
            // 2026-07-04: urgency=urgent → APNS interruption-level time-sensitive,
            // so overnight cycle pushes (dream/REM land ~3-4am) show on the lock
            // screen through Sleep Focus instead of dropping silently into
            // Notification Center.
            var userInfo = ["screen": "inbox", "source": source, "jobId": jobId, "urgency": "urgent"]
            if let itemId, !itemId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                userInfo["itemId"] = itemId
            }
            try await MacSyncEngine.shared.sendNotificationToPairedDevices(
                title: title,
                body: body,
                userInfo: userInfo
            )
            delivered.append(.string("push"))
        } catch {
            errors.append(.string("push: \(error.localizedDescription)"))
        }

        return .object([
            "delivered": .array(delivered),
            "errors": .array(errors),
            "mac": .object(mac.deliveryFields()),
        ])
    }

    static func iso(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSS'+00:00'"
        return formatter.string(from: date)
    }

    func deliveryChannels(_ raw: JSONValue?) -> [String] {
        switch raw {
        case .array(let arr):
            let values = arr.compactMap { string($0)?.lowercased() }
            return values.isEmpty ? ["push"] : values
        case .string(let s):
            let values = s.replacingOccurrences(of: ",", with: " ")
                .split(separator: " ")
                .map { String($0).lowercased() }
            return values.isEmpty ? ["push"] : values
        default:
            return ["push"]
        }
    }

    func deliveryText(
        channel: String,
        payload: [String: JSONValue],
        fallbackTitle: String,
        fallbackMessage: String
    ) -> (title: String, message: String) {
        guard case .object(let options)? = payload["deliveryOptions"] ?? payload["delivery_options"],
              case .object(let channelOptions)? = options[channel] else {
            return (fallbackTitle, fallbackMessage)
        }
        let title = string(channelOptions["title"]) ?? fallbackTitle
        let message = string(channelOptions["message"]) ?? string(channelOptions["body"]) ?? fallbackMessage
        return (title, message)
    }

    func string(_ raw: JSONValue?) -> String? {
        SchedulerJobRuntime.string(raw)
    }

    func int(_ raw: JSONValue?, default defaultValue: Int) -> Int {
        SchedulerJobRuntime.int(raw, default: defaultValue)
    }
}
