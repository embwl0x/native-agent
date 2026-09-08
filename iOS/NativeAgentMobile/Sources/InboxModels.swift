import SwiftUI
import NativeAgentShared

// MARK: - Model

struct InboxItemRecord: Identifiable, Codable, Hashable, Sendable {
    let id: String
    let created_at: String
    let source: String
    let severity: String
    let title: String
    let summary: String
    let detail: String?
    let relatedWorkshopExecutionId: String?
    let related_approval_id: String?
    let related_paths: [String]?
    let related_groups: [InboxRelatedGroup]?
    let actions: [InboxActionRecord]
    let status: String
    let read_at: String?

    enum CodingKeys: String, CodingKey {
        case id, created_at, source, severity, title, summary, detail
        case relatedWorkshopExecutionId = "related_mission_id" // compatibility wire ID
        case related_approval_id, related_paths, related_groups, actions, status, read_at
    }

    /// Wave 4 (phase A) read-both: accept the FUTURE `related_execution_id`
    /// spelling as well as the on-wire `related_mission_id` above. Decode-only —
    /// `encode(to:)` stays the synthesized one, so anything this build writes
    /// still carries `related_mission_id`.
    fileprivate enum FutureCodingKeys: String, CodingKey {
        case related_execution_id
    }
}

// The decoder lives in an extension on purpose: declaring `init(from:)` in the
// struct body would suppress the synthesized memberwise init that the view
// (InboxView.swift:151) and InboxStoreTests both construct records with.
extension InboxItemRecord {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        // Every non-optional field keeps the SYNTHESIZED semantics exactly
        // (`decode`, i.e. a missing key still throws). This init exists only to
        // widen the one execution-link key; it must not quietly become a more
        // lenient decoder.
        created_at = try c.decode(String.self, forKey: .created_at)
        source = try c.decode(String.self, forKey: .source)
        severity = try c.decode(String.self, forKey: .severity)
        title = try c.decode(String.self, forKey: .title)
        summary = try c.decode(String.self, forKey: .summary)
        detail = try c.decodeIfPresent(String.self, forKey: .detail)
        let futureRelatedExecutionId: String? = {
            guard let future = try? decoder.container(keyedBy: FutureCodingKeys.self) else {
                return nil
            }
            return try? future.decodeIfPresent(String.self, forKey: .related_execution_id)
        }()
        relatedWorkshopExecutionId = try futureRelatedExecutionId
            ?? c.decodeIfPresent(String.self, forKey: .relatedWorkshopExecutionId)
        related_approval_id = try c.decodeIfPresent(String.self, forKey: .related_approval_id)
        related_paths = try c.decodeIfPresent([String].self, forKey: .related_paths)
        related_groups = try c.decodeIfPresent([InboxRelatedGroup].self, forKey: .related_groups)
        actions = try c.decode([InboxActionRecord].self, forKey: .actions)
        status = try c.decode(String.self, forKey: .status)
        read_at = try c.decodeIfPresent(String.self, forKey: .read_at)
    }

    var isUnread: Bool { status == "unread" }
    var hasLinkedApproval: Bool { !(related_approval_id ?? "").isEmpty }

    /// Presentation must expose only actions with a real end-to-end native
    /// contract. This is deliberately closed: an action introduced by a card
    /// producer cannot become a tappable iOS control until the signed Mac
    /// action router accepts it.
    var presentableActions: [InboxActionRecord] {
        actions.filter { InboxActionPresentation.presentableActionIDs.contains($0.id) }
    }

    var severityColor: Color {
        switch severity {
        case "actionable": return .orange
        case "important":  return .blue
        default:           return NativeAgentPalette.agentAccent
        }
    }

    var sourceIcon: String {
        if hasLinkedApproval { return "checkmark.shield.fill" }
        if source.hasPrefix("proactive_autonomy") { return "lightbulb.fill" }
        if source.hasPrefix("harness_learning") { return "wand.and.stars" }
        if source == "dream_cycle"               { return "moon.stars.fill" }
        if source == "rem_cycle"                 { return "sparkles" }
        if source.hasPrefix("trigger:file_watch") { return "doc.text.magnifyingglass" }
        // P2-4: `execution_complete:<id>` is the canonical source; historical
        // cards synced from the Mac still say `mission_complete:<id>`.
        if source.hasPrefix("execution_complete") || source.hasPrefix("mission_complete") {
            return "checkmark.circle.fill"
        }
        if source == "idle_checkin"               { return "clock.fill" }
        if source.hasPrefix("trigger:morning_brief") { return "sun.horizon.fill" }
        if source.hasPrefix("trigger:stuck_pattern") { return "arrow.trianglehead.2.clockwise" }
        if source == "self_test"                  { return "testtube.2" }
        return "bell.fill"
    }

    var sourceBadgeLabel: String {
        if hasLinkedApproval { return "APPROVAL" }
        if source.hasPrefix("proactive_autonomy") { return "IDEA" }
        if source.hasPrefix("harness_learning") { return "LEARNING" }
        if source == "dream_cycle" { return "DREAM" }
        if source == "rem_cycle" { return "REM" }
        if source.hasPrefix("trigger:file_watch")    { return "FILE-WATCH" }
        if source.hasPrefix("trigger:morning_brief") { return "MORNING-BRIEF" }
        if source.hasPrefix("trigger:stuck_pattern") { return "STUCK-PATTERNS" }
        if source == "idle_checkin"                  { return "IDLE-CHECKIN" }
        if source.hasPrefix("execution_complete") || source.hasPrefix("mission_complete") {
            return "WORKSHOP"
        }
        return source.uppercased().prefix(14).description
    }

    var createdDate: Date? {
        ISO8601DateFormatter().date(from: created_at)
    }

    var relativeCreatedAt: String {
        guard let date = createdDate else { return "" }
        let interval = Date().timeIntervalSince(date)
        if interval < 60  { return "\(Int(interval))s ago" }
        if interval < 3600 { return "\(Int(interval / 60))m ago" }
        return "\(Int(interval / 3600))h ago"
    }

    func replacingStatus(_ nextStatus: String, readAt: String? = nil) -> InboxItemRecord {
        InboxItemRecord(
            id: id,
            created_at: created_at,
            source: source,
            severity: severity,
            title: title,
            summary: summary,
            detail: detail,
            relatedWorkshopExecutionId: relatedWorkshopExecutionId,
            related_approval_id: related_approval_id,
            related_paths: related_paths,
            related_groups: related_groups,
            actions: actions,
            status: nextStatus,
            read_at: readAt ?? read_at
        )
    }
}

typealias InboxRelatedGroup = NativeAgentShared.InboxRelatedGroup
typealias InboxActionRecord = NativeAgentShared.InboxActionRecord

extension InboxRelatedGroup {
    func matches(_ item: InboxItemRecord) -> Bool {
        matches(itemID: item.id, title: item.title)
    }
}

/// The complete inbox-card vocabulary this iOS build can present. `view` is
/// local-only; every other id is sent through `iCloudSyncEngine.inboxAction`.
enum InboxActionPresentation {
    static let localOnlyActionIDs: Set<String> = ["view"]
    static let forwardedActionIDs: Set<String> = [
        "read", "act", "approve", "reject", "deny",
        "archive", "dismiss", "repair", "open_approvals",
    ]

    static let presentableActionIDs = localOnlyActionIDs.union(forwardedActionIDs)
}

/// A bounded notification plan for one inbox snapshot. Large arrivals still
/// get one summary notification so the safety cap never becomes a silent
/// "notify nothing" policy for a Mac that publishes in batches.
enum InboxLocalNotificationPlan: Equatable {
    case none
    case items([InboxItemRecord])
    case summary(newUnreadCount: Int)
}

enum InboxNotificationBurstPresentation {
    static let burstThreshold = 8
    static let individualFireCap = 3

    static func plan(
        newUnreadItems: [InboxItemRecord],
        isInboxVisible: Bool
    ) -> InboxLocalNotificationPlan {
        guard !isInboxVisible, !newUnreadItems.isEmpty else { return .none }
        if newUnreadItems.count >= burstThreshold {
            return .summary(newUnreadCount: newUnreadItems.count)
        }
        let alertable = newUnreadItems.filter {
            $0.severity == "important" || $0.severity == "actionable"
        }
        return alertable.isEmpty ? .none : .items(Array(alertable.prefix(individualFireCap)))
    }
}
