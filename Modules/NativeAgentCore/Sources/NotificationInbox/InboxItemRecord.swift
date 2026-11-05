import Foundation
import NativeAgentCore
import NativeAgentShared
import PersistenceCore
import Desk
// Blueprint: | `InboxItemRecord.swift` | Inbox wire meaning: presentation, reading status, owner attention and system lanes |

/// Producers declare card meaning; missing presentation stays unclassified rather than inferred. The source field is required.
extension InboxSourcePresentation {
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

    public var isAttentionWorthyBacklogItem: Bool {
        guard normalizedStatus == "unread", !isProactiveCard else { return false }
        if ["actionable", "critical"].contains(severity.lowercased()) { return true }
        if hasLinkedApproval { return true }
        let passive: Set<String> = ["view", "read", "archive", "dismiss"]
        return actions.contains { !passive.contains($0.id.lowercased()) }
    }

    public var isForYouLane: Bool { !isSystemLane }
}

/// Meaning belongs to the wire's declared fields, never inferred presentation prose.
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

    /// Classify the kind component of proactive_autonomy sources so unrelated proactive cards do not share a category.
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
        // Maintenance and loop-failure producers declare prefixed source identities.
        if lower.hasPrefix("background_loop") || lower.hasPrefix("loop-failure:") { return true }
        return false
    }
}
