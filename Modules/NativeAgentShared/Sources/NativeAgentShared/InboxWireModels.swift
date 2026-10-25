import Foundation
// Blueprint: | `InboxWireModels.swift` | Shared inbox rows and `InboxActionVocabulary`: signed Mac route normalization and supported controls; `view` remains phone-local |

/// The signed Mac inbox route's vocabulary, also used by phone controls.
public enum InboxActionVocabulary {
    public static let supportedActionIDs: Set<String> = [
        "read", "archive", "dismiss", "act", "reply", "approve", "reject", "deny", "repair", "open_approvals"
    ]

    public static func supports(_ actionID: String, itemID: String) -> Bool {
        supportedActionIDs.contains(actionID)
            || (itemID.hasPrefix("interaction:") && actionID.hasPrefix("interaction_choice_"))
    }

    public static func routedAction(_ actionID: String, itemID: String) -> String {
        let normalized = actionID == "deny" ? "reject" : actionID
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
