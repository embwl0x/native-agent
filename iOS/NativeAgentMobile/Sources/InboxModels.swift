import Foundation
import NativeAgentShared
// Blueprint: | `InboxModels.swift` | Phone inbox presentation; the Mac supplies status/source meaning |

// MARK: - Model

extension InboxItemRecord {
    var isUnread: Bool { status == "unread" }

    /// Expose a card action only when the signed Mac router accepts it; producer declarations alone do not establish a working phone control.
    var presentableActions: [InboxActionRecord] {
        InboxActionVocabulary.actions(declared: actions, approvalLinked: !(related_approval_id ?? "").isEmpty)
            .filter { $0.id == "view" || InboxActionVocabulary.supports($0.id, itemID: id) }
    }

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
