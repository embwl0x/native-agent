import MacNerves
import NativeAgentCore
import NativeAgentShared
import PersistenceCore
import DeskCore
import SenseCore
import Foundation
import ProviderRouting
import MindCore
// Blueprint: | `AppActions+BotGroup.swift` | Bot action declarations |

extension AppActions {
    static func botGroup() throws -> [AppAction] {
        try [
        .fold("bot_list", "bots", read: true),
        .fold("shelf_read", "bots", "Saved replies, newest first; sort:oldest_unread selects unread oldest first; page with offset or cursor", read: true),
        .fold("shelf_entry", "bots", "Read one helper reply; mark_read:false leaves it unread"),
        .fold("bot_ask", "bots"),
        .fold("bot_run_once", "bots", "Run a helper by id; its outcome and bot.reply reference return to the asking conversation"),
        .fold("bot_create", "bots"),
        .fold("bot_update", "bots"),
        .fold("bot_pause", "bots", "Pause or resume scheduled/event work by id; a manual helper has no schedule to pause"),
        .fold("bot_delete", "bots", "Delete a helper by id; keep its conversation, replies and owned run settlement"),
        ]
    }
}
