import Foundation
import NativeAgentShared
import NativeAgentCore
import NotificationInbox
import PersistenceCore
// Blueprint: | `TriggerNotificationInbox.swift` | `TriggerNotificationInbox`: proactive identity matcher, checked locked mirror, `archiveSupersededMorningBriefs` |

/// The host publishes the inbox snapshot through its paired-device transport.
public protocol TriggerSnapshotDeliveryPort: Sendable {
    func writeSnapshots() async
}

public enum TriggerNotificationInbox {
    /// Accept one normalized card under the inbox owner's duplicate-check lock.
    /// A returned id identifies the durable equivalent card; nil means appended.
    public static func accept(_ note: TriggerNotification, notify: Bool, dataRoot: URL) async throws -> String? {
        guard case .object(var cardObj) = note.item, !note.itemId.isEmpty else {
            throw TriggerSchedulerError.invalidRequest("inbox item missing id")
        }
        if notify {
            cardObj["held_delivery"] = .array([.string("phone")])
            cardObj["held_title"] = .string(note.title)
            cardObj["held_body"] = .string(note.body)
            cardObj["held_event_id"] = .string("trigger:\(note.itemId)")
            cardObj["held_reason"] = .string(note.body)
            cardObj["held_importance"] = .string(note.ownerWaiting ? "owner_waiting" : "informational")
            cardObj["held_user_info"] = .object([
                "screen": .string(note.screen), "source": .string(note.source), "urgency": .string(note.urgency),
                "itemId": .string(note.itemId), "trigger": .string(note.triggerName),
            ])
        }
        let inboxPath = dataRoot
            .appendingPathComponent("notifications", isDirectory: true)
            .appendingPathComponent("inbox.jsonl")
        // Normalize the card to the notifications-store shape.
        if cardObj["created_at"] == nil { cardObj["created_at"] = .string(NativeTimestampFormat.fractionalZulu(Date())) }
        if cardObj["status"] == nil { cardObj["status"] = .string("unread") }
        if cardObj["read_at"] == nil { cardObj["read_at"] = .null }
        if cardObj["actions"] == nil {
            cardObj["actions"] = .array([
                .object(["id": .string("view"), "label": .string("View"),
                         "description": .string("See full detail")]),
                .object(["id": .string("dismiss"), "label": .string("Dismiss"),
                         "description": .string("Dismiss this card")]),
            ])
        }
        let normalizedObj = cardObj
        let normalized: JSONValue = .object(normalizedObj)
        let existingId = try await LiveNotificationInbox(path: inboxPath)
            .appendUnlessDuplicate(normalized) { rows in
                activeDuplicateId(for: normalizedObj, rows: rows)
            }
        if existingId == nil, normalizedObj["source"] == .string("trigger:morning_brief") {
            await archiveSupersededMorningBriefs(dataRoot: dataRoot)
        }
        return existingId
    }

    static func activeDuplicateId(for candidate: [String: JSONValue], rows: [JSONValue]) -> String? {
        if let occurrence = candidate["trigger_occurrence"],
           let prior = rows.last(where: { $0.objectValue?["source"] == candidate["source"]
               && $0.objectValue?["trigger_occurrence"] == occurrence }),
           let id = string(prior.objectValue?["id"]) { return id }
        guard let candidateKey = duplicateKey(candidate), shouldDedupeSource(candidateKey.source) else { return nil }
        let candidateCreatedAt = parseInboxDate(string(candidate["created_at"]))
        // Last-write-wins per id keeps dismissed revisions from matching an
        // earlier active row. First-seen order preserves the existing choice.
        var order: [String] = []
        var latest: [String: JSONValue] = [:]
        for row in rows {
            guard case .object(let object) = row,
                  let id = string(object["id"]), !id.isEmpty else { continue }
            if latest[id] == nil { order.append(id) }
            latest[id] = row
        }
        for id in order.reversed() {
            guard case .object(let existing)? = latest[id],
                  let existingKey = duplicateKey(existing), existingKey == candidateKey,
                  activeStatus(for: existing) else { continue }
            if let candidateCreatedAt,
               let existingCreatedAt = parseInboxDate(string(existing["created_at"])),
               candidateCreatedAt.timeIntervalSince(existingCreatedAt) > 7 * 24 * 60 * 60 { continue }
            return id
        }
        return nil
    }

    private static func shouldDedupeSource(_ source: String) -> Bool {
        let source = source.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return source == "idle_checkin" || source.hasPrefix("trigger:") || source.hasPrefix("proactive_autonomy:")
    }

    private static func duplicateKey(_ object: [String: JSONValue]) -> (source: String, title: String, summary: String)? {
        guard let source = normalizedText(object["source"]), let title = normalizedText(object["title"]) else { return nil }
        return (source, title, normalizedText(object["summary"]) ?? "")
    }

    private static func activeStatus(for item: [String: JSONValue]) -> Bool {
        let status = (string(item["status"]) ?? "unread").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return status == "unread" || status == "read"
    }

    private static func normalizedText(_ value: JSONValue?) -> String? {
        guard let value = string(value)?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        return value.lowercased()
    }

    private static func string(_ value: JSONValue?) -> String? {
        guard case .string(let value)? = value else { return nil }
        return value
    }

    private static func parseInboxDate(_ value: String?) -> Date? {
        guard let value, !value.isEmpty else { return nil }
        return NativeTimestampFormat.parseISO8601FractionalFirst(value)
    }

    /// Only the newest brief stays active; runs after each brief and once at launch.
    public static func archiveSupersededMorningBriefs(
        dataRoot: URL = PersistenceCore.defaultDataRoot()
    ) async {
        do {
            _ = try await LiveNotificationInbox(path: LiveNotificationInbox.livePath(dataRoot: dataRoot))
                .archiveSupersededRows(
                    source: "trigger:morning_brief",
                    groupField: "source",
                    readAt: NativeTimestampFormat.plainZulu(Date()),
                    statusIsEligible: { $0 != "archived" && $0 != "dismissed" }
                )
        } catch {
            nativeLog("trigger_mirror: morning brief reconciliation failed: %@", String(describing: error))
        }
    }

}
