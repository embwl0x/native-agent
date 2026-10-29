import Foundation
import NativeAgentCore
import PersistenceCore
import ChatTurnContracts
import AgentWorkspace
import MemoryV2
import ProviderRouting
import ToolRegistry
import NativeAgentShared
import CoreGraphics
import CryptoKit
import ImageIO
import UniformTypeIdentifiers
import Dispatcher
import MacControl
import Senses
import StandingBots
// Blueprint: | `BuiltInToolSchemaFactory+HistorySchemas.swift` | `BuiltInToolSchemaFactory`: `historySchemas` |

extension BuiltInToolSchemaFactory {
    func historySchemas() -> [LLMToolSchema?] {
        [
            requestedSchema(name: "search_chat_history", toolClass: .read,
                description: "Search persisted conversation transcripts, including this conversation; scope/session_id narrows it. For work status/resumption, start at app {} for Desk state, original evidence and document discovery. Returns ranked snippets with conversation ids, titles, roles, timestamps and is_current_session when known. Background reads never show/detach a conversation: resolve with chat.list, then session_id, no query, sort:newest, limit:12 messages (not exchanges). Follow next_call for older pages and chat.message for truncated bodies; order collected messages chronologically and disclose coverage/truncation.",
                parametersJSON: ToolSchema.params(
                    properties: [
                        ("query", ToolSchema.strSchema("Words or phrase to search for in prior conversation transcripts. Omit with after/before for a conversation digest with activity times, message counts and bounded excerpts of the owner's own messages; omit with session_id to list that conversation.")),
                        ("session_id", ToolSchema.strSchema("Optional conversation id to restrict search to one conversation, e.g. a Mac, iOS, or telegram conversation id.")),
                        ("scope", ToolSchema.enumStringSchema(["all_sessions", "current_session", "previous_session", "auto", "current_session_first", "current", "last_session", "all", "global", "all_session"], "Scope: all_sessions (default), current_session, previous_session, or auto/current_session_first. auto/current_session_first searches the current conversation first and searches all conversations only if no strong current match exists. previous_session reopens the \"Since last session\" anchor on this surface, excluding machine/bridge runs; it accepts no query, returning that conversation's tail.")),
                        ("role", ToolSchema.strSchema("Optional role: user/assistant/tool/system. user includes agents through bridges; owner means only the owner on their own door. tool explicitly searches persisted argument/result/status receipts, possibly redacted/truncated; ordinary search excludes them.")),
                        ("author", ToolSchema.strSchema("Optional recorded author, e.g. owner or an agent's name. Use owner for what the owner said; bridge/wake and unknown authors are excluded. User-role hits include author and author_route.")),
                        ("mode", ToolSchema.enumStringSchema(["hybrid", "exact", "continuity"], "hybrid (default), exact substring or continuity. For requested conversation resumption/revisiting, continuity returns up to four hits with bounded neighboring user/assistant messages, preserving decision/correction context. Retrieves nothing until invoked.")),
                        ("limit", ToolSchema.intSchema("Results per page, default 8; capped at 8 conversations for date-only digests, 4 hits for continuity, otherwise 12 hits.")),
                        ("offset", ToolSchema.intSchema("result offset for a follow-up page; omit on the first search")),
                        ("before", ToolSchema.strSchema("Optional exclusive ISO8601 upper bound; omitted/null/empty is unbounded. Unknown-timestamp matches are excluded and reported.")),
                        ("after", ToolSchema.strSchema("Optional exclusive ISO8601 lower bound; omitted/null/empty is unbounded. Unknown-timestamp matches are excluded and reported.")),
                        ("since", ToolSchema.strSchema("Optional lower bound: ISO8601 or a positive relative duration such as 1d, 7d or 2h. Combined with after, the later bound applies.")),
                        ("sort", ToolSchema.enumStringSchema(["relevance", "oldest", "newest"], "Default relevance; oldest/newest sorts matches chronologically regardless of relevance. all_sessions + oldest finds earliest matches. Use mode exact for whole phrases; hybrid may match individual words. Chronology does not prove original authorship.")),
                    ],
                    required: []
                )
            ),
            requestedSchema(name: "read_chat_message", toolClass: .read,
                description: "Page a full persisted message using the exact work.context/chat.search locator, rather than rephrasing a query for another preview fragment. Tool messages contain retained receipt metadata, not fresh reads or unabridged original output. Coverage distinguishes missing evidence from unreadable history; incomplete lookups prove neither absence nor permission to replay actions.",
                parametersJSON: ToolSchema.params(
                    properties: [
                        ("message_id", ToolSchema.strSchema("The message_id from a work.context or chat.search source locator.")),
                        ("session_id", ToolSchema.strSchema("Optional conversation id the message belongs to. Omit to look through every transcript, newest first.")),
                        ("offset", ToolSchema.intSchema("Character offset into the message, default 0. Pass the previous response's next_offset for the following page.", minimum: 0)),
                        ("limit", ToolSchema.intSchema("Characters per page, default 8000, capped at 16000.", minimum: 1, maximum: 16_000)),
                    ],
                    required: ["message_id"]
                )
            ),
        ]
    }
}
