import Foundation
import NativeAgentShared
// Blueprint: | `InboxModels.swift` | Phone rendering and bounded notification planning over shared inbox values; status and source meaning are supplied by the Mac |

// MARK: - Model

extension InboxItemRecord {
    var isUnread: Bool { status == "unread" }

    /// Presentation must expose only actions with a real end-to-end native
    /// contract. This is deliberately closed: an action introduced by a card
    /// producer cannot become a tappable iOS control until the signed Mac
    /// action router accepts it.
    var presentableActions: [InboxActionRecord] {
        actions.filter { $0.id == "view" || InboxActionVocabulary.supports($0.id, itemID: id) }
    }

    /// The Mac's reading of where a card came from, in plain words.
    var sourceWords: String { presentation?.words ?? "A note from me" }

    var createdDate: Date? {
        UserDisplayFormatters.parseISOTimestamp(created_at)
    }

    var relativeCreatedAt: String {
        guard let date = createdDate else { return "" }
        let interval = Date().timeIntervalSince(date)
        if interval < 60  { return "just now" }
        if interval < 3600 { return "\(Int(interval / 60))m ago" }
        if interval < 86_400 { return "\(Int(interval / 3600))h ago" }
        if interval < 7 * 86_400 { return "\(Int(interval / 86_400))d ago" }
        return date.formatted(.dateTime.month(.abbreviated).day())
    }

}

extension InboxRelatedGroup {
    func matches(_ item: InboxItemRecord) -> Bool {
        matches(itemID: item.id, title: item.title)
    }
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
