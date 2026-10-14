import Foundation
import NativeAgentCore
import NotificationInbox
import PersistenceCore

/// The host publishes the inbox snapshot through its paired-device transport.
public protocol TriggerSnapshotDeliveryPort: Sendable {
    func writeSnapshots() async
}

public enum TriggerNotificationInbox {
    /// THE THIRD-ROOT FIX (2026-07-09): the trigger engine writes its item into
    /// the legacy ProactiveInboxStore (<root>/inbox/) — a parallel silo NOTHING
    /// user-facing reads. The Mac UI, getInboxItems, and the iOS snapshot all
    /// read NotificationInbox (<root>/notifications/inbox.jsonl). Mirror the
    /// EXACT built card (scheduler id, severity, detail — carried through the
    /// seam) into the REAL inbox, normalized to the notifications-store shape.
    ///
    /// Shared by the notification delivery owner and app-side fire sites, which
    /// mirror the cards of NON-notified fires (board M18). One normalization,
    /// so a notify:false card is indistinguishable from a notify:true one.
    ///
    /// Outcome of a mirror attempt. `.duplicate` means an ACTIVE equivalent
    /// card (same source+title+summary, unread/read, within 7 days) already
    /// sits in the live inbox — checked ATOMICALLY under the inbox file lock
    /// right before the append, closing the check-then-append race between
    /// concurrent fires that the scheduler's advisory `surface()` dedup can't
    /// see (gpt-5.5 review, 2026-07-24: two overlapping fires could both pass
    /// the advisory check and double-card).
    public enum MirrorOutcome: Sendable {
        case appended
        case duplicate(existingId: String)
        case failed
    }

    /// Returns `.failed` on write failure, having logged loudly; each caller
    /// decides what a failed or deduped mirror means for it.
    public static func mirrorCardIntoRealInbox(
        _ card: JSONValue,
        triggerName: String,
        dataRoot: URL = PersistenceCore.defaultDataRoot()
    ) async -> MirrorOutcome {
        guard case .object(var cardObj) = card else {
            nativeLog("trigger_mirror: card for %@ is not a JSON object — NOT written to the real inbox",
                  triggerName)
            return .failed
        }
        let inboxPath = dataRoot
            .appendingPathComponent("notifications", isDirectory: true)
            .appendingPathComponent("inbox.jsonl")
        // Normalize the card to the notifications-store shape.
        let fmt = ISO8601DateFormatter()
        fmt.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if cardObj["created_at"] == nil { cardObj["created_at"] = .string(fmt.string(from: Date())) }
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
        do {
            // A5.2 (2026-07-24): dedup-check + append run under ONE file lock so
            // two concurrent fires can't both pass the check and double-card.
            // 2026-08-31: that lock is now taken by the feed's owner rather than
            // by hand around a raw capped append — the shared cap trims by
            // keeping a suffix and hard-deletes the oldest cards once the file
            // crosses its budget, while `LiveNotificationInbox` shelves what it
            // evicts to `notifications/inbox_archive.jsonl` first.
            let existingId = try await LiveNotificationInbox(path: inboxPath)
                .appendUnlessDuplicate(normalized) { rows in
                    activeDuplicateId(for: normalizedObj, rows: rows)
                }
            if let existingId { return .duplicate(existingId: existingId) }
            if case .string("trigger:morning_brief")? = normalizedObj["source"] {
                await archiveSupersededMorningBriefs(dataRoot: dataRoot)
            }
            return .appended
        } catch {
            nativeLog("trigger_mirror: REAL-inbox card write FAILED for %@: %@",
                  triggerName, String(describing: error))
            return .failed
        }
    }

    /// Advisory identity suppresses a duplicate push; the mirror repeats this
    /// matcher against fresh rows under the inbox owner's lock.
    static func surface(_ item: JSONValue, dataRoot: URL) async throws -> String {
        guard case .object(let object) = item,
              let id = string(object["id"]), !id.isEmpty else {
            throw TriggerSchedulerError.invalidRequest("inbox item missing id")
        }
        guard let rows = try? await LiveNotificationInbox.live(dataRoot: dataRoot).rows() else { return id }
        return activeDuplicateId(for: object, rows: rows) ?? id
    }

    static func activeDuplicateId(for candidate: [String: JSONValue], rows: [JSONValue]) -> String? {
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

    /// 2026-09-22: every brief stayed unread beside the next one. Only the
    /// newest brief stays active; runs after each brief and once at launch.
    public static func archiveSupersededMorningBriefs(
        dataRoot: URL = PersistenceCore.defaultDataRoot()
    ) async {
        do {
            _ = try await LiveNotificationInbox(path: LiveNotificationInbox.livePath(dataRoot: dataRoot))
                .archiveSupersededActiveRows(
                    source: "trigger:morning_brief",
                    groupField: "source",
                    readAt: ISO8601DateFormatter().string(from: Date())
                )
        } catch {
            nativeLog("trigger_mirror: morning brief reconciliation failed: %@", String(describing: error))
        }
    }

    /// Mirror the card of a fire that the notifier did NOT handle.
    ///
    /// A notify:true fire is already mirrored by `TriggerNotificationDelivery`, so
    /// mirroring here too would double-write the card. A fire deduped against an
    /// active card carries no `item` — the card it would mirror is the one
    /// already in the inbox. Everything else (notify:false, notify-with-no-
    /// notifier) used to land ONLY in the legacy ProactiveInboxStore, where
    /// nothing user-facing reads it: that is the silo this closes (board M18).
    ///
    /// Refreshes snapshots after a successful mirror so the iOS companion sees
    /// the card too, the same way the notify path does before it knocks.
    ///
    /// Returns false ONLY when a mirror was needed and failed — a fire that
    /// needs no mirror (not fired, already notified, deduped) is true, so the
    /// manual "Fire now" path can report an honest failure instead of success
    /// with an empty inbox (gpt-5.5 review, 2026-07-09).
    @discardableResult
    public static func mirrorNonNotifiedFire(
        _ result: TriggerFireResult,
        dataRoot: URL = PersistenceCore.defaultDataRoot(),
        delivery: any TriggerSnapshotDeliveryPort
    ) async -> Bool {
        guard result.status == "fired", result.notified != true, let item = result.item else { return true }
        let name = result.name ?? "unknown"
        switch await mirrorCardIntoRealInbox(item, triggerName: name, dataRoot: dataRoot) {
        case .failed:
            nativeLog("trigger_mirror: non-notified fire for %@ (item %@) did NOT reach the real inbox — the card was DROPPED",
                  name, result.itemId ?? "?")
            return false
        case .duplicate:
            // An active equivalent card is already in the inbox — nothing to
            // mirror; the fire is honestly represented by the existing card.
            return true
        case .appended:
            // A recovered/test root must never borrow production iCloud state
            // merely to prove its own local card write.
            if dataRoot.standardizedFileURL == PersistenceCore.defaultDataRoot().standardizedFileURL {
                await delivery.writeSnapshots()
            }
            return true
        }
    }
}
