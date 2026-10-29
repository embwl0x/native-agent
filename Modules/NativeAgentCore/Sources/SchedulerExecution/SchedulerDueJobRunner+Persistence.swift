import Privacy
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
// Blueprint: | `SchedulerDueJobRunner+Persistence.swift` | `SchedulerDueJobRunner`: execution-result adaptation to canonical scheduler settlement; `appendActivity` |

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
            detail: result.detail, seen: result.seen, at: runDate
        )
    }

    func appendActivity(
        jobId: String?,
        title: String,
        detail: String,
        status: String,
        payload: JSONValue
    ) async throws {
        var payloadObj: [String: JSONValue] = [:]
        if case .object(let obj) = payload { payloadObj = obj }
        if let jobId { payloadObj["jobId"] = .string(jobId) }
        let event = SwiftNativePersistenceCore.activityEvent(
            id: UUID().uuidString.lowercased(),
            kind: "scheduler",
            title: NativeAppSecretRedactor.redactText(title),
            detail: NativeAppSecretRedactor.redactText(String(detail.prefix(1000))),
            status: status,
            executionId: nil,
            payload: NativeAppSecretRedactor.redactValue(.object(payloadObj)),
            createdAt: Self.iso(Date())
        )
        do {
            try await SwiftNativePersistenceCore.appendActivityEvent(
                event, to: activityPath, logLabel: "SchedulerDueJobRunner"
            )
        } catch {
            noteFault("Scheduler activity evidence could not be written: \(error.localizedDescription)")
            throw error
        }
    }

    static let dreamCardPresentation: JSONValue = .object(["icon": .string("moon.stars.fill"), "badge": .string("DREAM"),
                                                           "words": .string("A dream"), "act_label": .string("Go ahead")])
    static let remCardPresentation: JSONValue = .object(["icon": .string("sparkles"), "badge": .string("REM"),
                                                         "words": .string("From my rest"), "act_label": .string("Go ahead")])

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
        notifyPhone: Bool = false,
        presentation: JSONValue = .null
    ) async throws {
        let now = Self.iso(Date())
        // The producer declares what its card means (the inbox's `presentation`).
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
            "presentation": presentation,
        ])
        // LiveNotificationInbox archives evicted rows before aging out finished history.
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
        try await LiveNotificationInbox(path: notificationInboxPath)
            .archiveSupersededRows(source: "dream_cycle", groupField: "source", keeping: keepItemId) {
                let status = $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                return status != "archived" && status != "dismissed"
            }
    }

    func notificationInboxContains(source: String, dateKey: String) async throws -> Bool {
        let rows = (try? await SwiftNativePersistenceCore.readJSONL(notificationInboxPath)) ?? []
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
        var delivered: [JSONValue] = []
        var errors: [JSONValue] = []
        var notDelivered: [JSONValue] = []
        let macResult = Mutex<NativeAgentNotificationPostResult?>(nil)

        do {
            // The router derives urgency from importance and defers cycle news during quiet hours.
            var userInfo = ["screen": "inbox", "source": source, "jobId": jobId]
            if let itemId, !itemId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                userInfo["itemId"] = itemId
            }
            // Cycle news is informational; the inbox card retains its receipt.
            let outcome = try await platform.attentionRouter.route(
                eventId: "scheduler_cycle:\(userInfo["itemId"] ?? jobId)",
                importance: .informational,
                title: title,
                body: body,
                userInfo: userInfo,
                postMacBanner: { [platform] in
                    let mac = await platform.postNotification(title: title, body: body)
                    macResult.withLock { $0 = mac }
                }
            )
            // The router's delivery projection determines the channel receipt.
            switch outcome.deliveryProjection {
            case .accepted:
                delivered.append(.string("push"))
            case .queued:
                // Queued means CloudKit-only with APNS unavailable; the phone has received nothing.
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
