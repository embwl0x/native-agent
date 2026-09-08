import Foundation
import NativeAgentCore
import PersistenceCore
import WorkshopExecution

// MARK: - ProactiveInboxStore

/// A5.2 (2026-07-24): formerly the file-backed mirror of the retired
/// daemon::Inbox.surface (`<root>/inbox/` items.jsonl + index.json). That
/// silo is retired — nothing user-facing ever read it, and every fired card
/// already lands in `notifications/inbox.jsonl` via the app-side mirror seam.
/// What remains here is the 7-day active-duplicate identity check against
/// the live inbox; the fire path uses it to suppress duplicate pushes.
public actor ProactiveInboxStore {
    private let root: URL

    public init(root: URL, persistence: any PersistenceCoreProtocol) {
        self.root = root
    }

    /// The LIVE inbox — the one store the Mac UI, getInboxItems, and the iOS
    /// snapshot read, and the one the app-side mirror seam writes.
    public nonisolated var notificationsInboxPath: URL {
        root
            .appendingPathComponent("notifications", isDirectory: true)
            .appendingPathComponent("inbox.jsonl")
    }

    /// A5.2 (2026-07-24): the legacy `<root>/inbox/` silo (items.jsonl +
    /// index.json) is retired — nothing user-facing ever read it, and every
    /// fired card already lands in the live inbox via the app-side seam
    /// (`TriggerNotifierBinding.pairedDevicePush` for notify:true fires,
    /// `mirrorNonNotifiedFire` for everything else). This store's remaining
    /// job is the 7-day active-duplicate check, now anchored to the live
    /// inbox: a repeat fire hands back the EXISTING card id, and the fire
    /// path uses that identity to suppress the duplicate push + mirror.
    /// No writes happen here anymore.
    public func surface(_ item: JSONValue) async throws -> String {
        guard case .object(let obj) = item,
              case .string(let id) = obj["id"] ?? .null,
              !id.isEmpty else {
            throw TriggerSchedulerError.invalidRequest("inbox item missing id")
        }
        if let existing = Self.activeDuplicateId(
            for: obj,
            notificationsInboxPath: notificationsInboxPath
        ) {
            return existing
        }
        return id
    }

    private static let activeDuplicateWindow: TimeInterval = 7 * 24 * 60 * 60

    /// Suppress repeated proactive/routine inbox cards while an equivalent
    /// active card is still visible. This is deliberately scoped to proactive
    /// sources so event-like inbox writers can still emit separate events.
    /// Public so the app-side mirror seam (TriggerNotifierBinding) can run the
    /// SAME matcher atomically under the live-inbox file lock right before it
    /// appends — surface()'s call is advisory (suppresses the push early); the
    /// mirror's locked call is the backstop that closes the check-then-append
    /// race between concurrent fires (gpt-5.5 review, 2026-07-24).
    public nonisolated static func activeDuplicateId(
        for candidate: [String: JSONValue],
        notificationsInboxPath: URL
    ) -> String? {
        guard let candidateKey = duplicateKey(candidate),
              shouldDedupeSource(candidateKey.source) else {
            return nil
        }
        let candidateCreatedAt = parseInboxDate(string(candidate["created_at"]))
        guard let data = try? Data(contentsOf: notificationsInboxPath),
              let text = String(data: data, encoding: .utf8) else {
            return nil
        }
        // The live inbox is append-only with last-write-wins per id (a status
        // change appends a full replacement row). Collapse to the FINAL row
        // per id first, so a dismissed/archived card can't shadow-match on an
        // earlier unread revision of itself.
        var order: [String] = []
        var latest: [String: [String: JSONValue]] = [:]
        for raw in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = String(raw).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty,
                  let lineData = line.data(using: .utf8),
                  case .object(let row)? = try? JSONValue.parse(lineData),
                  let rowId = string(row["id"]), !rowId.isEmpty else {
                continue
            }
            if latest[rowId] == nil { order.append(rowId) }
            latest[rowId] = row
        }
        for rowId in order.reversed() {
            guard let existing = latest[rowId],
                  let existingKey = duplicateKey(existing),
                  existingKey == candidateKey,
                  activeStatus(for: existing) else {
                continue
            }
            if isStaleDuplicate(existing: existing, candidateCreatedAt: candidateCreatedAt) {
                continue
            }
            return rowId
        }
        return nil
    }

    private nonisolated static func shouldDedupeSource(_ source: String) -> Bool {
        let s = source.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return s == "idle_checkin"
            || s.hasPrefix("trigger:")
            || s.hasPrefix("\(WorkshopCompletionTrigger.canonicalKind):")
            || s.hasPrefix("\(WorkshopCompletionTrigger.legacyKind):")
            || s.hasPrefix("proactive_autonomy:")
    }

    private nonisolated static func duplicateKey(_ object: [String: JSONValue])
        -> (source: String, title: String, summary: String)?
    {
        guard let source = normalizedText(object["source"]),
              let title = normalizedText(object["title"]) else {
            return nil
        }
        return (source, title, normalizedText(object["summary"]) ?? "")
    }

    /// Status lives per-line in the live inbox (the caller already collapsed
    /// to the final row per id — no index overlay exists anymore).
    private nonisolated static func activeStatus(
        for item: [String: JSONValue]
    ) -> Bool {
        let status = (string(item["status"]) ?? "unread")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        return status == "unread" || status == "read"
    }

    private nonisolated static func isStaleDuplicate(
        existing: [String: JSONValue],
        candidateCreatedAt: Date?
    ) -> Bool {
        guard let candidateCreatedAt,
              let existingCreatedAt = parseInboxDate(string(existing["created_at"])) else {
            return false
        }
        return candidateCreatedAt.timeIntervalSince(existingCreatedAt) > activeDuplicateWindow
    }

    private nonisolated static func normalizedText(_ value: JSONValue?) -> String? {
        guard let value = string(value)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else {
            return nil
        }
        return value.lowercased()
    }

    private nonisolated static func string(_ value: JSONValue?) -> String? {
        guard case .string(let value)? = value else { return nil }
        return value
    }

    private nonisolated static func parseInboxDate(_ value: String?) -> Date? {
        guard let value, !value.isEmpty else { return nil }
        return NativeTimestampFormat.parseISO8601FractionalFirst(value)
    }
}
