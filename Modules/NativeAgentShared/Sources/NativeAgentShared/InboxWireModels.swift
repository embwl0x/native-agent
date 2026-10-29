import Foundation
// Blueprint: | `InboxWireModels.swift` | Shared inbox rows and `InboxActionVocabulary`: action normalization and native operation set, with broader signed-wire recognition; `view` remains phone-local |

/// The signed Mac inbox route's vocabulary, also used by phone controls.
public enum InboxActionVocabulary {
    public static let nativeActionIDs: Set<String> = [
        "read", "archive", "dismiss", "act", "approve", "reject", "open_approvals"
    ]
    public static let supportedActionIDs = nativeActionIDs.union(["reply", "deny", "repair"])

    public static func normalizedAction(_ actionID: String) -> String {
        actionID == "deny" ? "reject" : actionID
    }

    public static func supports(_ actionID: String, itemID: String) -> Bool {
        supportedActionIDs.contains(actionID)
            || (itemID.hasPrefix("interaction:") && actionID.hasPrefix("interaction_choice_"))
    }

    public static func routedAction(_ actionID: String, itemID: String) -> String {
        let normalized = normalizedAction(actionID)
        return supports(normalized, itemID: itemID) ? normalized : "act"
    }
}

public struct InboxRelatedGroup: Identifiable, Codable, Hashable, Sendable {
    public let id: String
    public let title: String
    public let count: Int
    public let item_ids: [String]?
    public let source: String?

    public init(id: String, title: String, count: Int, item_ids: [String]?, source: String?) {
        self.id = id
        self.title = title
        self.count = count
        self.item_ids = item_ids
        self.source = source
    }

    public var itemIDs: Set<String> {
        Set(item_ids ?? [])
    }

    public var displayCount: Int {
        max(count, item_ids?.count ?? 0)
    }

    public func matches(itemID: String, title itemTitle: String) -> Bool {
        if itemID == id { return false }
        let ids = itemIDs
        if !ids.isEmpty && ids.contains(itemID) {
            return true
        }
        let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return !cleanTitle.isEmpty && itemTitle == cleanTitle
    }
}

public struct InboxActionRecord: Codable, Hashable, Sendable {
    public let id: String
    public let label: String
    public let description: String?

    public init(id: String, label: String, description: String?) {
        self.id = id
        self.label = label
        self.description = description
    }
}

public struct InboxSourcePresentation: Codable, Hashable, Sendable {
    public let icon: String
    public let badge: String
    public let words: String
    /// Nil: the card's own action label says it.
    public let actLabel: String?

    enum CodingKeys: String, CodingKey { case icon, badge, words, actLabel = "act_label" }

    public init(icon: String, badge: String, words: String, actLabel: String? = "Go ahead") {
        self.icon = icon; self.badge = badge; self.words = words; self.actLabel = actLabel
    }

}

public struct InboxItemRecord: Identifiable, Codable, Hashable, Sendable {
    public let id: String
    public let created_at: String
    public let source: String
    public let severity: String
    public let title: String
    public let summary: String
    public let detail: String?
    public let relatedWorkshopExecutionId: String?
    public let related_approval_id: String?
    public let related_paths: [String]?
    public let related_groups: [InboxRelatedGroup]?
    public let actions: [InboxActionRecord]
    public var status: String
    public let read_at: String?
    /// The conversation a card raised elsewhere was mirrored into for User.
    public var chat_session_id: String? = nil
    /// The original card's session and identity, separate from its mirror destination.
    public let interaction_session_id: String?
    public let interaction_id: String?
    /// What the source means, as the Mac says it; nil from a Mac too old to say.
    public var presentation: InboxSourcePresentation? = nil

    public init(id: String, created_at: String, source: String, severity: String, title: String,
                summary: String, detail: String?, relatedWorkshopExecutionId: String?,
                related_approval_id: String?, related_paths: [String]?, related_groups: [InboxRelatedGroup]?,
                actions: [InboxActionRecord], status: String, read_at: String?,
                chat_session_id: String? = nil, presentation: InboxSourcePresentation? = nil,
                interaction_session_id: String? = nil, interaction_id: String? = nil) {
        self.id = id; self.created_at = created_at; self.source = source; self.severity = severity
        self.title = title; self.summary = summary; self.detail = detail
        self.relatedWorkshopExecutionId = relatedWorkshopExecutionId; self.related_approval_id = related_approval_id
        self.related_paths = related_paths; self.related_groups = related_groups; self.actions = actions
        self.status = status; self.read_at = read_at; self.chat_session_id = chat_session_id
        self.presentation = presentation
        self.interaction_session_id = interaction_session_id; self.interaction_id = interaction_id
    }

    enum CodingKeys: String, CodingKey {
        case id, created_at, source, severity, title, summary, detail
        case relatedWorkshopExecutionId = "related_mission_id" // compatibility wire ID
        case related_approval_id, related_paths, related_groups, actions, status, read_at, chat_session_id, presentation
        case interaction_session_id, interaction_id
    }

    // Decode the execution alias; encode the established mission key.
    fileprivate enum FutureCodingKeys: String, CodingKey {
        case related_execution_id
    }
}

extension InboxItemRecord {
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
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
        chat_session_id = try c.decodeIfPresent(String.self, forKey: .chat_session_id)
        interaction_session_id = try c.decodeIfPresent(String.self, forKey: .interaction_session_id)
        interaction_id = try c.decodeIfPresent(String.self, forKey: .interaction_id)
        presentation = try? c.decodeIfPresent(InboxSourcePresentation.self, forKey: .presentation)
    }

}
