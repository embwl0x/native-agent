import Foundation
import NativeAgentShared
// Blueprint: | `InboxModels.swift` | Phone inbox reading; the Mac supplies status/source meaning, and every card is the Inbox face's row |

// MARK: - Model

extension InboxItemRecord {
    var isUnread: Bool { status == "unread" }
}
