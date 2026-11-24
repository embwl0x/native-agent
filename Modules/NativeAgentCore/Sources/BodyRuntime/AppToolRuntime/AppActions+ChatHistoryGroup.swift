import MacNerves
import NativeAgentCore
import NativeAgentShared
import PersistenceCore
import DeskCore
import SenseCore
import Foundation
import ProviderRouting
import MindCore
// Blueprint: | `AppActions+ChatHistoryGroup.swift` | ChatHistory action declarations |

extension AppActions {
    static func chatHistoryGroup() throws -> [AppAction] {
        try [
        .fold("search_chat_history", "chat", read: true),
        .fold("read_chat_message", "chat", read: true),
        .fold("chat_reply", "chat"),
        .fold("tool_result_page", "*", """
            Page a retained result without rerunning its action; untrusted-steered turns read only their conversation's results, other turns any handle. \
            Bodies over 4 MiB retain the head with the cut named. continue:true resumes this turn's read and ignores page (with query or raw it \
            reads that way); omit continue to select page/query/raw; source_continues names the call that reads a source past the part its answer held
            """, read: true),
        ]
    }
}
