import Foundation
import NativeAgentCore
import NativeAgentShared
import PersistenceCore
import Desk
// Blueprint: | `InboxItemRecord.swift` | Checked current-card schema and producer-declared actions; retained execution-link read, declared source meaning, latest stable-card identity and OwnerAttentionPolicy projection |

/// What an inbox card means, declared by the producer that files it (the
/// card's `presentation` field): its icon, badge, plain words and act-button
/// label. The Mac's inbox renders it and the phone reads it from the
/// snapshot. A card that declares nothing is shown as unclassified, never
/// classified here. The filing/read boundary requires its source field.
extension InboxSourcePresentation {
    /// The field a producer puts on its card.
    public var row: JSONValue {
        .object(["icon": .string(icon), "badge": .string(badge), "words": .string(words),
                 "act_label": actLabel.map(JSONValue.string) ?? .null])
    }

    init(source: String, hasLinkedApproval: Bool, declared: InboxSourcePresentation?) {
        func unclassified(_ badge: String) -> Self { .init(icon: "bell.fill", badge: badge, words: "A note from me") }
        if hasLinkedApproval { self.init(icon: "checkmark.shield.fill", badge: "APPROVAL", words: "Asking first"); return }
        let normalized = source.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789_:-")
        self = normalized.unicodeScalars.allSatisfy(allowed.contains)
            ? declared ?? unclassified(Self.humanized(normalized)) : unclassified("SOURCE INVALID")
    }

    private static func humanized(_ source: String) -> String {
        var label = ""
        for word in source.split(whereSeparator: { $0 == "_" || $0 == ":" || $0 == "-" }).map({ $0.uppercased() }) {
            let candidate = label.isEmpty ? word : label + " " + word
            if candidate.count > 16 { break }
            label = candidate
        }
        return label.isEmpty ? "SOURCE UNKNOWN" : label
    }
}

extension InboxItemRecord {
    public var isHiddenFromDefaultInbox: Bool {
        normalizedStatus == "archived" || normalizedStatus == "dismissed"
    }
    public var hasLinkedApproval: Bool { !(related_approval_id ?? "").isEmpty }
    public var isProactiveCard: Bool { source.lowercased().hasPrefix("proactive_autonomy:") }
    public var isApprovalBacklogCard: Bool {
        let lowerSource = source.lowercased()
        return hasLinkedApproval
            || lowerSource.hasPrefix("proactive_autonomy:approval_backlog:")
    }

    public var actionIDs: Set<String> {
        Set(InboxActionVocabulary.actions(declared: actions, approvalLinked: hasLinkedApproval).map(\.id))
    }

    /// Proactive scanning uses this same checked link/action interpretation.
    public var isAttentionWorthyBacklogItem: Bool {
        guard normalizedStatus == "unread", !isProactiveCard else { return false }
        if ["actionable", "critical"].contains(severity.lowercased()) { return true }
        if hasLinkedApproval || relatedWorkshopExecutionId?.isEmpty == false { return true }
        let passive: Set<String> = ["view", "read", "archive", "dismiss"]
        return actions.contains { !passive.contains($0.id.lowercased()) }
    }

    public var isForYouLane: Bool { !isSystemLane }

    /// The shared current wire decoder checks every required/optional field and
    /// every action. No unreadable list becomes an executable default policy.
    public init(row: JSONValue) throws {
        let fields = try JSONRow(row)
        let currentLink = try fields.optionalString(InboxExecutionLinkVocabulary.wireKey)
        // DATA PRESENT: retained cards still carry this key. This is its one reader.
        let retainedLink = try fields.optionalString(InboxExecutionLinkVocabulary.legacyKey)
        var object = fields.fields
        if currentLink == nil, let retainedLink {
            object[InboxExecutionLinkVocabulary.wireKey] = .string(retainedLink)
        }
        self = try JSONDecoder().decode(Self.self, from: JSONValue.object(object).serializedData(pretty: false))
        for (key, value) in [("id", id), ("source", source), ("severity", severity), ("title", title)] {
            guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw JSONRow.Malformed.field(key) }
        }
        guard NativeTimestampFormat.parseISO8601FractionalFirst(created_at) != nil else {
            throw JSONRow.Malformed.field("created_at")
        }
        guard ["unread", "active", "read", "archived", "dismissed"].contains(status) else {
            throw JSONRow.Malformed.field("status")
        }
        if let read_at, NativeTimestampFormat.parseISO8601FractionalFirst(read_at) == nil {
            throw JSONRow.Malformed.field("read_at")
        }
        var actionIDs = Set<String>()
        for action in actions {
            guard !action.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !action.label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  actionIDs.insert(action.id).inserted else { throw JSONRow.Malformed.field("actions") }
        }
        if let related_groups, related_groups.contains(where: { $0.count < 0 }) {
            throw JSONRow.Malformed.field("related_groups")
        }
        if let raw = fields.fields["occurrence_count"] {
            guard case .int(let count) = raw, count > 0, count < Int.max else {
                throw JSONRow.Malformed.field("occurrence_count")
            }
        }
        presentation = InboxSourcePresentation(source: source,
            hasLinkedApproval: hasLinkedApproval, declared: presentation)
    }

    /// A producer may re-file a settled card under its stable id. Its newest
    /// physical row owns the state, as LiveNotificationInbox.updateStatus does.
    public static func latest(in rows: [JSONValue]) throws -> [InboxItemRecord] {
        var seen = Set<String>()
        var items: [InboxItemRecord] = []
        for row in rows.reversed() {
            let item = try InboxItemRecord(row: row)
            if seen.insert(item.id).inserted { items.append(item) }
        }
        return items
    }
}

/// The only route from a persisted digest card to its Review Groups controls.
/// Cards use the producer's structured wire, never inferred presentation prose.
extension InboxItemRecord {
    public var normalizedStatus: String {
        status.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    /// Unread/active ordering for the phone's inbox, separate from obligations.
    public var isActivityPending: Bool {
        normalizedStatus == "unread" || normalizedStatus == "active"
    }

    /// Every projection asks the same owner whether this card needs the person.
    public var requiresOwnerInput: Bool {
        OwnerAttentionPolicy.inboxAsks(pending: ["unread", "active", "read"].contains(normalizedStatus), systemLane: isSystemLane,
            severity: severity, linkedApproval: !(related_approval_id ?? "").isEmpty, actionIDs: actions.map(\.id))
    }

    // MARK: - "For you" vs "System"

    /// Operational sources describe the app's own machinery.
    public static let systemLaneSources: Set<String> = [
        "background_loop",
        "disk_hygiene",
        "doctor",
        "heartbeat",
        "provider_vitals",
        "self_test",
        "memory_repair",
        "memory_kind_backfill",
    ]

    /// Proactive-scan kinds that are self-referential housekeeping. These
    /// arrive as `proactive_autonomy:<kind>:<opportunityId>`, so the lane test
    /// has to read the KIND component — matching on the raw source would put
    /// every proactive card in one lane regardless of what it is about.
    public static let systemLaneProactiveKinds: Set<String> = [
        "scheduler_health",
        "approval_backlog",
        "inbox_digest",
    ]

    public var isSystemLane: Bool {
        let lower = source.lowercased()
        if Self.systemLaneSources.contains(lower) { return true }
        if lower.hasPrefix("proactive_autonomy:") {
            let parts = lower.split(separator: ":", omittingEmptySubsequences: false)
            if parts.count >= 2, Self.systemLaneProactiveKinds.contains(String(parts[1])) {
                return true
            }
        }
        // `loop-failure:*` and the maintenance producers prefix rather than
        // match exactly.
        if lower.hasPrefix("background_loop") || lower.hasPrefix("loop-failure:") { return true }
        return false
    }
}
