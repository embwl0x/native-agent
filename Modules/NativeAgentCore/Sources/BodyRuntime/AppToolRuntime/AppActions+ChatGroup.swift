import MacNerves
import NativeAgentCore
import NativeAgentShared
import PersistenceCore
import DeskCore
import SenseCore
import Foundation
import ProviderRouting
import MindCore
// Blueprint: | `AppActions+ChatGroup.swift` | Chat action declarations |

extension AppActions {
    static func chatGroup() -> [AppAction] {
        [
        // Version-exempt: chat appends through Reach without overwriting page state. The agent's own words to its own person: a write to its
        // own conversation, never a send to a third party, so no posture and no steering of the turn holds it on a card.
        AppAction("chat.post", "chat", "Tell the person directly", [.required("message")], irreversible: true,
                  toolClass: .write, capabilities: [.appDataWrite, .safeRead, .toolCall], tool: "chat_post", versionExempt: true, voice: true),
        AppAction("chat.list", "chat", """
            Conversations, newest first; query filters by title; pinned:true only pinned, pinned:false only unpinned; filters apply before offset
            """, [.optional("archived", .boolean), .optional("pinned", .boolean), .optional("query"), .optional("offset", .integer)],
                  tool: "chat_conversations", read: true),
        AppAction("chat.new", "chat", "New chat; title names it in the same call", [.optional("title")], tool: "chat_session", input: verb("new")),
        AppAction("chat.rename", "chat", "Rename", [.required("session_id"), .required("title")], subject: ["session_id"], tool: "chat_session", input: verb("rename")),
        AppAction("chat.pin", "chat", "Pin", [.optional("session_id")], subject: ["session_id"], tool: "chat_session", input: verb("pin")),
        AppAction("chat.unpin", "chat", "Unpin", [.optional("session_id")], subject: ["session_id"], tool: "chat_session", input: verb("unpin")),
        AppAction("chat.archive", "chat", "Archive", [.optional("session_id"), .optional("reason")], subject: ["session_id"], tool: "chat_session", input: verb("archive")),
        AppAction("chat.stop", "chat", "Stop", [.optional("session_id")], subject: ["session_id"], tool: "chat_session", input: verb("stop")),
        AppAction("chat.regenerate", "chat", "Regenerate (redo / try again) your last answer", [.optional("session_id")], subject: ["session_id"], irreversible: true,
                  capabilities: [.appDataWrite, .safeRead, .toolCall], tool: "chat_session", input: verb("regenerate")),
        AppAction("chat.export", "chat", "Export to Markdown", [.optional("session_id")], subject: ["session_id"], tool: "chat_session", input: verb("export")),
        AppAction("chat.clear", "chat", "/clear", [.required("session_id")], subject: ["session_id"], irreversible: true,
                  capabilities: [.appDataWrite, .safeRead, .toolCall], tool: "chat_session", input: verb("clear")),
        AppAction("chat.draft", "chat", "Draft", [.required("value"), .optional("session_id"), .optional("attachments", .list)],
                  tool: "interaction_act", input: composer("set_draft")),
        AppAction("chat.send", "chat", "Send", [.optional("value"), .optional("session_id"), .optional("attachments", .list)], irreversible: true,
                  toolClass: .send, capabilities: [.appDataWrite, .safeRead, .toolCall], tool: "interaction_act", input: composer("send")),
        AppAction("chat.model", "chat", "Model (app-wide: every chat)", [.required("provider"), .required("model"), .optional("session_id")], tool: "interaction_act",
                  input: composer("set_model"), rename: ["provider": "value", "model": "choice"]),
        AppAction("chat.think", "chat", "Thinking level (app-wide: every chat)", [.required("level"), .optional("session_id")], tool: "interaction_act",
                  input: composer("set_think"), rename: ["level": "value"]),
        AppAction("chat.fast", "chat", "Fast mode (app-wide: every chat)", [.required("value", .options("on", "off")), .optional("session_id")], tool: "interaction_act",
                  input: composer("set_fast")),
        AppAction("chat.open_card", "chat", "Open the composer's card", [.required("card", .options("model", "think", "trust", "context"))], screen: true,
                  tool: "interaction_act", input: composer("open_card"), rename: ["card": "value"]),
        AppAction("chat.close_card", "chat", "Close the composer's card", screen: true,
                  tool: "interaction_act", input: composer("close_card")),
        AppAction("chat.speak", "chat", "Read aloud", [.required("value")], screen: true, tool: "interaction_act",
                  input: composer("speak")),
        AppAction("chat.scratch", "chat", "Scratch", [.required("key"), .required("value"), .optional("session_id")], tool: "interaction_act",
                  input: composer("write_scratch"), rename: ["key": "choice"]),
        AppAction("chat.working_memory", "chat", """
            Hold a private choice or plan in this conversation (up to 1200 characters); shown privately to you each turn until replaced or cleared
            """, [.required("text", .secret)], warn: "Empty text clears it. Its words stay out of scratch reads, receipts and the person's surfaces.",
                  tool: "chat_working_memory", versionExempt: true),
        AppAction("page.show", "*", "Go to page; returns what it now shows", [.required("page"), .optional("item")], subject: ["page"], screen: true, tool: "interaction_act",
                  input: composer("set_page"), rename: ["page": "value", "item": "choice"]),
        AppAction("browser.show", "chat", "Show your own built-in browser (NativeAgent's browser, not Chrome)", screen: true, tool: "interaction_act",
                  input: composer("show_browser")),
        AppAction("pane.show", "chat", "Open the Work pane or the table window", [.required("view", .options("steps", "screen", "make", "table")), .optional("ref")], screen: true,
                  tool: "interaction_act", input: composer("show_pane"), rename: ["view": "value", "ref": "choice"]),
        AppAction("pane.hide", "chat", "Close the Work pane", screen: true, tool: "interaction_act",
                  input: composer("hide_pane")),
        // Version-exempt: adding a version never overwrites an existing one.
        ]
    }
}
