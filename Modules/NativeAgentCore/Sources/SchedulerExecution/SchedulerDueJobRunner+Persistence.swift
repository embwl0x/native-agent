import Privacy
import BackgroundWork
import Foundation
import Experiences
import AttentionRouting
import NativeAgentCore
import NotificationInbox
import PersistenceCore
import TelegramBot
import TriggerScheduler
import DeviceSync
import AppToolRuntime
import Synchronization

extension SchedulerDueJobRunner {
    func update(job: DueJob, result: JobResult, at runDate: Date) async throws {
        if job.kind == "dream" {
            let output = Self.object(result.output)
            if (result.status == "error" || output["skipReason"] == .string("already_running")), output["remedy"] == nil {
                await RepairOwed.owe(root, id: "scheduled-dream-repair:" + UUID().uuidString, kind: .run,
                    evidence: [.init(source: "scheduler/jobs.json", id: job.occurrenceKey)],
                    operation: "dream", owner: "scheduler/jobs.json > " + job.id,
                    words: "Scheduled dream remains owed: " + result.detail,
                    nextCall: ToolFailureError.call("app", ["action": .string("mind.dream")])).value
            }
        }
        try await schedulerJobs.settleOccurrence(
            jobId: job.id, occurrenceKey: job.occurrenceKey, status: result.status,
            detail: result.detail, output: result.output, at: runDate,
            runDateKey: NativeAgentDreamCycleSchedule.runDateKey(runDate)
        )
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
        do {
            try await appendJSONLCapped(
                event, to: activityPath, using: persistence,
                logLabel: "SchedulerDueJobRunner"
            )
            activityFeedError = nil
        } catch {
            activityFeedError = "Scheduler activity evidence could not be written: \(error.localizedDescription)"
            throw error
        }
    }

    func appendNotificationInbox(
        title: String,
        message: String,
        source: String,
        severity: String,
        jobId: String,
        itemId: String = "scheduled-\(UUID().uuidString.lowercased())",
        relatedPaths: [String] = [],
        relatedGroups: [JSONValue] = [],
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
            "related_groups": .array(relatedGroups),
            "actions": .array(actions),
            "status": .string("unread"),
            "read_at": .null,
            "schedulerJobId": .string(jobId),
        ])
        // 2026-08-31: through the feed's owner, not a raw capped append. The
        // shared cap trims by keeping a suffix, which HARD-DELETES the oldest
        // cards once the file crosses its budget; `LiveNotificationInbox` shelves
        // every row it evicts to `notifications/inbox_archive.jsonl` first and
        // ages finished history out on its own schedule.
        try await LiveNotificationInbox(path: notificationInboxPath)
            .appendUnique(row, id: itemId)
        if notifyPhone {
            await platform.notifyInboxIfAttentionWorthy(
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
            // 2026-08-11: raw-preserving read — a malformed line among valid
            // rows survives the rewrite verbatim instead of being dropped.
            let lines = try InboxRewriteGuard.readLines(inboxPath)
            let decoded = lines.compactMap(\.row)
            let result = NativeAgentDreamNotificationInboxPolicy.archiveOlderDreamRows(
                decoded,
                keeping: keepItemId
            )
            guard result.archivedCount > 0 else { return 0 }
            // The policy maps rows 1:1 in order, so walk its output alongside
            // the decoded lines; unchanged rows keep their original bytes.
            // If the policy ever stops being 1:1 the zip-back below would
            // misalign rows — refuse the rewrite loudly instead.
            guard result.rows.count == decoded.count else {
                throw NSError(
                    domain: "NativeAgentSwiftOnly", code: -431,
                    userInfo: [NSLocalizedDescriptionKey:
                        "archiveOlderDreamRows returned \(result.rows.count) rows "
                        + "for \(decoded.count) decoded — refusing misaligned rewrite"])
            }
            var mutated: [Data] = []
            mutated.reserveCapacity(lines.count)
            var rowIndex = 0
            for line in lines {
                guard let row = line.row else {
                    mutated.append(line.raw)
                    continue
                }
                let rewritten = result.rows[rowIndex]
                rowIndex += 1
                if rewritten == row {
                    mutated.append(line.raw)
                } else {
                    mutated.append(Data(try rewritten.serialize(pretty: false).utf8))
                }
            }
            try InboxRewriteGuard.writeLines(mutated, to: inboxPath)
            return result.archivedCount
        }
    }

    func notificationInboxContains(source: String, dateKey: String) async throws -> Bool {
        let rows = (try? await persistence.readJSONL(notificationInboxPath)) ?? []
        for row in rows {
            guard case .object(let obj) = row else { continue }
            guard SchedulerJobRuntime.string(obj["source"]) == source else { continue }
            let diaryDates = Self.notificationRowDiaryDateKeys(obj)
            if !diaryDates.isEmpty {
                if diaryDates.contains(dateKey) { return true }
                continue
            }
            guard let created = SchedulerJobRuntime.string(obj["created_at"]),
                  let date = Self.parseISODate(created) else { continue }
            if NativeAgentDreamCycleSchedule.runDateKey(date) == dateKey {
                return true
            }
        }
        return false
    }

    func postCycleNotification(title: String, body: String, jobId: String, source: String, itemId: String? = nil) async -> JSONValue {
        await cycleNotificationDelivery(title, body, jobId, source, itemId)
    }

    static func deliverCycleNotification(
        title: String,
        body: String,
        jobId: String,
        source: String,
        itemId: String? = nil,
        platform: any SchedulerExecutionPlatform
    ) async -> JSONValue {
        var delivered: [JSONValue] = []
        var errors: [JSONValue] = []
        var notDelivered: [JSONValue] = []
        let macResult = Mutex<NativeAgentNotificationPostResult?>(nil)

        do {
            // 2026-09-13: urgency is projected by the router from the class
            // below. An overnight dream/REM card is news; it no longer pierces
            // Sleep Focus at 3:30am to say so, and quiet hours hold it until
            // the window closes.
            var userInfo = ["screen": "inbox", "source": source, "jobId": jobId]
            if let itemId, !itemId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                userInfo["itemId"] = itemId
            }
            // Item 26: overnight cycle deliveries (dream/REM) are news, not a
            // request — informational, so they land on the phone once and the
            // inbox card is the receipt. Payload unchanged.
            let outcome = try await platform.attentionRouter.route(
                eventId: "scheduler_cycle:\(userInfo["itemId"] ?? jobId)",
                importance: .informational,
                title: title,
                body: body,
                userInfo: userInfo,
                postMacBanner: {
                    let mac = await platform.postNotification(title: title, body: body)
                    macResult.withLock { $0 = mac }
                }
            )
            // Report what actually happened, from the ROUTER'S OWN projection —
            // the same one `TriggerNotifierBinding` reads — instead of "no
            // failure was reported". A quiet-hours deferral and a routing that
            // chose no channel delivered nothing, and both were being recorded
            // as "push".
            switch outcome.deliveryProjection {
            case .accepted:
                delivered.append(.string("push"))
            case .queued:
                // 2026-09-22: queued is CloudKit-only with APNS down; nothing
                // has reached the phone yet.
                notDelivered.append(.string("push: queued (APNS unavailable)"))
            case .previouslyHandled:
                delivered.append(.string("push_already_delivered"))
            case .failed:
                errors.append(.string(
                    "push: the knock was tried and no channel accepted it; nothing was delivered"))
            case .deferred, .noChannel:
                // Not an error — nothing went wrong, and nothing was delivered.
                notDelivered.append(.string("push: \(outcome.deliveryProjection.rawValue)"))
            }
        } catch {
            errors.append(.string("push: \(error.localizedDescription)"))
        }

        let mac = macResult.withLock { $0 }
        if let mac {
            if mac.posted { delivered.insert(.string("mac"), at: 0) }
            else { errors.insert(.string("mac: \(mac.error ?? mac.delivery)"), at: 0) }
        } else {
            notDelivered.insert(.string("mac: deferred"), at: 0)
        }
        var fields: [String: JSONValue] = [
            "delivered": .array(delivered),
            "errors": .array(errors),
        ]
        if let mac { fields["mac"] = .object(mac.deliveryFields()) }
        if !notDelivered.isEmpty { fields["not_delivered"] = .array(notDelivered) }
        return .object(fields)
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
