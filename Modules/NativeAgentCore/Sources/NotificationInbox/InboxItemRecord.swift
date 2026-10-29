import Foundation
import NativeAgentCore
import NativeAgentShared
import PersistenceCore
import Desk
// Blueprint: | `InboxItemRecord.swift` | Tolerant raw-row construction, declared source meaning and action/proactive interpretation on shared inbox values; latest stable-card identity and OwnerAttentionPolicy projection |

/// The inbox reader deliberately keeps cards with a bad optional source rather
/// than dropping the whole record. Preserve why the source is unavailable so
/// the visible provenance badge does not turn a bad wire value into silence.
public enum InboxSourceReadState: Hashable, Sendable {
    case present
    case missing
    case malformed
}

/// What an inbox card means, declared by the producer that files it (the
/// card's `presentation` field): its icon, badge, plain words and act-button
/// label. The Mac's inbox renders it and the phone reads it from the
/// snapshot. A card that declares nothing is shown as unclassified, never
/// classified here; a missing or malformed source stays an explicit adverse
/// state.
extension InboxSourcePresentation {
    /// The field a producer puts on its card.
    public var row: JSONValue {
        .object(["icon": .string(icon), "badge": .string(badge), "words": .string(words),
                 "act_label": actLabel.map(JSONValue.string) ?? .null])
    }

    init(source: String, readState: InboxSourceReadState, hasLinkedApproval: Bool, declared: InboxSourcePresentation?) {
        func unclassified(_ badge: String) -> Self { .init(icon: "bell.fill", badge: badge, words: "A note from me") }
        if hasLinkedApproval { self.init(icon: "checkmark.shield.fill", badge: "APPROVAL", words: "Asking first"); return }
        let normalized = source.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789_:-")
        switch readState {
        case .missing: self = unclassified("SOURCE MISSING")
        case .malformed: self = unclassified("SOURCE INVALID")
        case .present where normalized.isEmpty: self = unclassified("SOURCE UNKNOWN")
        case .present where !normalized.unicodeScalars.allSatisfy(allowed.contains): self = unclassified("SOURCE INVALID")
        case .present: self = declared ?? unclassified(Self.humanized(normalized))
        }
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
        let lowerDetail = (detail ?? "").lowercased()
        return hasLinkedApproval
            || lowerSource.hasPrefix("proactive_autonomy:approval_backlog:")
            || lowerDetail.contains("suggested action: approvals.triage")
    }

    public var fallbackPrimaryAction: InboxActionRecord? {
        if isApprovalBacklogCard {
            return InboxActionRecord(
                id: "open_approvals",
                label: "Open Approvals",
                description: "Review pending approvals"
            )
        }
        if isProactiveCard {
            return nil
        }
        if severity.lowercased() == "actionable" || relatedWorkshopExecutionId != nil {
            return InboxActionRecord(id: "act", label: "Act", description: "Take primary action")
        }
        return nil
    }

    public var effectiveActions: [InboxActionRecord] {
        if !actions.isEmpty { return actions }
        var fallback = [InboxActionRecord(id: "view", label: "View", description: "See full detail")]
        if let primary = fallbackPrimaryAction {
            fallback.append(primary)
        }
        fallback.append(contentsOf: [
            InboxActionRecord(id: "archive", label: "Archive", description: "Archive this item"),
            InboxActionRecord(id: "dismiss", label: "Dismiss", description: "Dismiss this item"),
        ])
        return fallback
    }

    public var actionIDs: Set<String> {
        Set(effectiveActions.map(\.id))
    }

    public var isForYouLane: Bool { !isSystemLane }

    /// A row without a string `id` is not a card. Every other field keeps the
    /// card: a missing or mistyped value takes its default, and a list with
    /// one unreadable element is read as absent (actions as none).
    public init?(row: JSONValue) {
        guard case .object(let o) = row, let id = Self.string(o["id"]) else { return nil }
        let source: String
        let sourceReadState: InboxSourceReadState
        let created_at = Self.string(o["created_at"]) ?? ""
        if o["source"] == nil {
            source = ""
            sourceReadState = .missing
        } else if let decodedSource = Self.string(o["source"]) {
            source = decodedSource
            sourceReadState = .present
        } else {
            source = ""
            sourceReadState = .malformed
        }
        let severity = id.hasPrefix("delegation-outcome:") && id.hasSuffix(":adverse-rollup") && o["adverse_jobs"] == .array([])
            ? "info" : Self.string(o["severity"]) ?? "info"
        let title = Self.string(o["title"]) ?? ""
        let summary = Self.string(o["summary"]) ?? ""
        let detail = Self.string(o["detail"])
        let relatedWorkshopExecutionId = Self.string(o[InboxExecutionLinkVocabulary.futureKey])
            ?? Self.string(o[InboxExecutionLinkVocabulary.wireKey])
        let related_approval_id = Self.string(o["related_approval_id"])
        let related_paths = Self.strings(o["related_paths"])
        let related_groups = Self.all(o["related_groups"], Self.group)
        let actions = Self.all(o["actions"], Self.action) ?? []
        let status = Self.string(o["status"]) ?? "unread"
        let read_at = Self.string(o["read_at"])
        let chat_session_id = Self.string(o["chat_session_id"])
        let declaredPresentation = o["presentation"].flatMap { try? JSONDecoder().decode(InboxSourcePresentation.self, from: $0.serializedData(pretty: false)) }
        self.init(id: id, created_at: created_at, source: source, severity: severity, title: title,
                  summary: summary, detail: detail, relatedWorkshopExecutionId: relatedWorkshopExecutionId,
                  related_approval_id: related_approval_id, related_paths: related_paths, related_groups: related_groups,
                  actions: actions, status: status, read_at: read_at, chat_session_id: chat_session_id,
                  presentation: InboxSourcePresentation(source: source, readState: sourceReadState,
                      hasLinkedApproval: !(related_approval_id ?? "").isEmpty, declared: declaredPresentation),
                  interaction_session_id: Self.string(o["interaction_session_id"]), interaction_id: Self.string(o["interaction_id"]))
    }

    /// A producer may re-file a settled card under its stable id. Its newest
    /// physical row owns the state, as LiveNotificationInbox.updateStatus does.
    public static func latest(in rows: [JSONValue]) -> [InboxItemRecord] {
        var seen = Set<String>()
        return rows.reversed().compactMap { row in
            guard let item = InboxItemRecord(row: row), seen.insert(item.id).inserted else { return nil }
            return item
        }
    }

    // MARK: - Row fields

    private static func string(_ value: JSONValue?) -> String? {
        if case .string(let s)? = value { return s }
        return nil
    }

    private static func strings(_ value: JSONValue?) -> [String]? {
        all(value) { string($0) }
    }

    /// Every element read, or nil when the value is not an array or any
    /// element is unreadable.
    private static func all<T>(_ value: JSONValue?, _ read: (JSONValue) -> T?) -> [T]? {
        guard case .array(let elements)? = value else { return nil }
        var out: [T] = []
        out.reserveCapacity(elements.count)
        for element in elements {
            guard let item = read(element) else { return nil }
            out.append(item)
        }
        return out
    }

    private static func group(_ value: JSONValue) -> InboxRelatedGroup? {
        guard let row = try? JSONRow(value), let count = try? row.optionalInt("count") else { return nil }
        return try? InboxRelatedGroup(id: row.string("id"), title: row.string("title"), count: count,
                                     item_ids: row.optionalStrings("item_ids"), source: row.optionalString("source"))
    }

    private static func action(_ value: JSONValue) -> InboxActionRecord? {
        guard let row = try? JSONRow(value) else { return nil }
        return try? InboxActionRecord(id: row.string("id"), label: row.string("label"),
                                     description: row.optionalString("description"))
    }
}

/// The only route from a persisted digest card to its Review Groups controls.
/// New cards use the structured wire; prose remains compatibility for existing
/// JSONL cards only.
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
