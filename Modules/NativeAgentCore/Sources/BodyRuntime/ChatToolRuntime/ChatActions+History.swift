import Foundation
import NativeAgentCore
import PersistenceCore
import MindCore
import ProviderRouting
import DeskCore
import NativeAgentShared
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import MacNerves
import SenseCore
// Blueprint: | `ChatActions+History.swift` | history action contracts and execution |

enum ChatActions {}

struct WorkContextArgs: DoorArgs {
    static let queryField = DoorFieldDescriptor.string("query", "The work or topic to pick back up, in ordinary words (1–400 characters).", required: true)
    static let sessionIDField = DoorFieldDescriptor.string("session_id", """
        Optional exact conversation to restrict historical evidence; null searches across conversations. Desk remains the current \
        shared Desk.
        """).nullable()
    static let limitField = DoorFieldDescriptor.int("limit", """
        Maximum Desk items and chat excerpts per source, default 3, range 1–4; null uses the default. Mail returns at most five \
        matches.
        """).nullable()
    static let deskOffsetField = DoorFieldDescriptor.int("desk_offset", "Omit initially; retained continuation for more current work.").nullable()
    static let historyOffsetField = DoorFieldDescriptor.int("history_offset", """
        Omit initially; retained continuation for more history with the same topic and selection policy.
        """).nullable()
    static let doorFields: [DoorFieldDescriptor] = [queryField, sessionIDField, limitField, deskOffsetField, historyOffsetField]
    let query: String
    let sessionID: String?
    let limit: Int?
    let deskOffset: Int?
    let historyOffset: Int?

    init(door: inout DoorObjectDecoder) throws(DoorDecodeError) {
        query = try door.requiredString(Self.queryField)
        sessionID = try door.string(Self.sessionIDField)
        limit = try door.numberLiteral(Self.limitField)?.wire.exactIntegerValue
        deskOffset = try door.numberLiteral(Self.deskOffsetField)?.wire.exactIntegerValue
        historyOffset = try door.numberLiteral(Self.historyOffsetField)?.wire.exactIntegerValue
    }
}

struct ArtifactFindArgs: DoorArgs {
    static let queryField = DoorFieldDescriptor.string("query", "Describe the artifact or its topic in ordinary words.", required: true)
    static let sessionIDField = DoorFieldDescriptor.string("session_id", "Optional exact conversation to search. When supplied, excludes shared Desk links.")
    static let limitField = DoorFieldDescriptor.int("limit", "Maximum artifact candidates, default 6, range 1–12.")
    static let sessionOffsetField = DoorFieldDescriptor.int("session_offset", "Omit initially; use returned continuation for older conversation evidence.")
    static let doorFields: [DoorFieldDescriptor] = [queryField, sessionIDField, limitField, sessionOffsetField]
    let query: String
    let sessionID: String?
    let limit: Int?
    let sessionOffset: Int?

    init(door: inout DoorObjectDecoder) throws(DoorDecodeError) {
        query = try door.requiredString(Self.queryField)
        sessionID = try door.string(Self.sessionIDField)
        limit = try door.numberLiteral(Self.limitField)?.wire.exactIntegerValue
        sessionOffset = try door.numberLiteral(Self.sessionOffsetField)?.wire.exactIntegerValue
    }
}

struct SearchChatHistoryArgs: DoorArgs {
    static let queryField = DoorFieldDescriptor.string("query", """
        Words or phrase to search for in prior conversation transcripts. Omit with after/before for a conversation digest with \
        activity times, message counts and bounded excerpts of the owner's own messages; omit with session_id to list that \
        conversation.
        """)
    static let sessionIDField = DoorFieldDescriptor.string("session_id", """
        Optional conversation id to restrict search to one conversation, e.g. a Mac, iOS, or telegram conversation id.
        """)
    static let currentSessionIDField = DoorFieldDescriptor.string("current_session_id", """
        Current conversation supplied by the runtime for scope resolution and is_current_session labels; distinct from the \
        session_id search filter.
        """)
    static let scopeField = DoorFieldDescriptor.choice("scope", ["all_sessions", "current_session", "previous_session"], """
        One requested scope: all_sessions (default), current_session, or previous_session. An unavailable current or previous \
        conversation returns incomplete coverage. previous_session reopens the \"Since last session\" anchor on this surface, \
        excluding machine/bridge runs; it accepts no query, returning that conversation's tail.
        """)
    static let roleField = DoorFieldDescriptor.string("role", """
        Optional role: user/assistant/tool/system. user includes agents through bridges; owner means only the owner on their \
        own door. tool explicitly searches persisted argument/result/status receipts, possibly redacted/truncated; ordinary \
        search excludes them.
        """)
    static let authorField = DoorFieldDescriptor.string("author", """
        Optional recorded author, e.g. owner or an agent's name. Use owner for what the owner said; bridge/wake and unknown \
        authors are excluded. User-role hits include author and author_route.
        """)
    static let modeField = DoorFieldDescriptor.choice("mode", ["hybrid", "exact", "continuity"], """
        hybrid (default), exact substring or continuity. For requested conversation resumption/revisiting, continuity returns \
        up to four hits with bounded neighboring user/assistant messages, preserving decision/correction context. Retrieves \
        nothing until invoked.
        """)
    static let limitField = DoorFieldDescriptor.int("limit", """
        Results per page, default 8; capped at 8 conversations for date-only digests, 4 hits for continuity, otherwise 12 hits.
        """)
    static let offsetField = DoorFieldDescriptor.int("offset", "result offset for a follow-up page; omit on the first search")
    static let beforeField = DoorFieldDescriptor.string("before", """
        Optional exclusive ISO8601 upper bound; omitted/null/empty is unbounded. Unknown-timestamp matches are excluded and \
        reported.
        """)
    static let afterField = DoorFieldDescriptor.string("after", """
        Optional exclusive ISO8601 lower bound; omitted/null/empty is unbounded. Unknown-timestamp matches are excluded and \
        reported.
        """)
    static let sinceField = DoorFieldDescriptor.string("since", """
        Optional lower bound: ISO8601 or a positive relative duration such as 1d, 7d or 2h. Combined with after, the later \
        bound applies.
        """)
    static let sortField = DoorFieldDescriptor.choice("sort", ["relevance", "oldest", "newest"], """
        Default relevance; oldest/newest sorts matches chronologically regardless of relevance. all_sessions + oldest finds \
        earliest matches. Use mode exact for whole phrases; hybrid may match individual words. Chronology does not prove \
        original authorship.
        """)
    static let doorFields = [
        queryField, sessionIDField, currentSessionIDField, scopeField, roleField, authorField, modeField,
        limitField, offsetField, beforeField, afterField, sinceField, sortField,
    ]
    let query: String?
    let sessionID: String?
    let currentSessionID: String?
    let scope: String?
    let role: String?
    let author: String?
    let mode: String?
    let limit: DoorNumberLiteral?
    let offset: DoorNumberLiteral?
    let before: String?
    let after: String?
    let since: String?
    let sort: String?

    init(workQuery: String, sessionID: String?, limit: Int, offset: Int) {
        query = workQuery
        self.sessionID = sessionID
        currentSessionID = nil
        scope = "all_sessions"
        role = nil
        author = nil
        mode = "continuity"
        self.limit = .int(Int64(limit))
        self.offset = .int(Int64(offset))
        before = nil
        after = nil
        since = nil
        sort = "newest"
    }

    init(door: inout DoorObjectDecoder) throws(DoorDecodeError) {
        query = try door.string(Self.queryField)
        sessionID = try door.string(Self.sessionIDField)
        currentSessionID = try door.string(Self.currentSessionIDField)
        scope = try door.string(Self.scopeField)
        role = try door.string(Self.roleField)
        author = try door.string(Self.authorField)
        mode = try door.string(Self.modeField)
        limit = try door.numberLiteral(Self.limitField)
        offset = try door.numberLiteral(Self.offsetField)
        before = try door.string(Self.beforeField)
        after = try door.string(Self.afterField)
        since = try door.string(Self.sinceField)
        sort = try door.string(Self.sortField)
    }

    var wire: [String: JSONValue] {
        var fields: [String: JSONValue] = [:]
        fields[Self.queryField.name] = query.map(JSONValue.string)
        fields[Self.sessionIDField.name] = sessionID.map(JSONValue.string)
        fields[Self.currentSessionIDField.name] = currentSessionID.map(JSONValue.string)
        fields[Self.scopeField.name] = scope.map(JSONValue.string)
        fields[Self.roleField.name] = role.map(JSONValue.string)
        fields[Self.authorField.name] = author.map(JSONValue.string)
        fields[Self.modeField.name] = mode.map(JSONValue.string)
        fields[Self.limitField.name] = limit?.wire
        fields[Self.offsetField.name] = offset?.wire
        fields[Self.beforeField.name] = before.map(JSONValue.string)
        fields[Self.afterField.name] = after.map(JSONValue.string)
        fields[Self.sinceField.name] = since.map(JSONValue.string)
        fields[Self.sortField.name] = sort.map(JSONValue.string)
        return fields
    }
}

struct ReadChatMessageArgs: DoorArgs {
    static let messageIDField = DoorFieldDescriptor.string("message_id", "The message_id from a work.context or chat.search source locator.", required: true)
    static let sessionIDField = DoorFieldDescriptor.string("session_id", """
        Optional conversation id the message belongs to. Omit to look through every transcript, newest first.
        """)
    static let offsetField = DoorFieldDescriptor.int("offset", """
        Character offset into the message, default 0. Pass the previous response's next_offset for the following page.
        """, minimum: 0)
    static let limitField = DoorFieldDescriptor.int("limit", "Characters per page, default 8000, capped at 16000.", minimum: 1, maximum: 16_000)
    static let doorFields: [DoorFieldDescriptor] = [messageIDField, sessionIDField, offsetField, limitField]
    let messageID: String
    let sessionID: String?
    let offset: Int?
    let limit: Int?

    init(historyID: String, offset: Int, limit: Int) {
        messageID = historyID
        self.offset = offset
        self.limit = limit
        sessionID = nil
    }

    init(door: inout DoorObjectDecoder) throws(DoorDecodeError) {
        messageID = try door.requiredString(Self.messageIDField)
        sessionID = try door.string(Self.sessionIDField)
        offset = try door.numberLiteral(Self.offsetField)?.wire.exactIntegerValue
        limit = try door.int(Self.limitField)
    }
}

extension ChatActions {
    static let historyActions: [ActionDescriptor] = {
        [
            ActionDescriptor(WorkContextArgs.self, name: "work_context",
                run: { context, input in
                    try await context.client.impl_work_context(turn: context.turn, invocation: context.invocation, input: input)
                }, toolClass: .read,
                description: """
                    Read current Desk status, original conversation evidence and recent Mail sender/subject matches for a topic, with dates and \
                    exact source links. Mail Read must be allowed and ready; its search is bounded to 1.5 seconds, five newest inbox matches from \
                    the last 90 days, with mail.N names to open bodies. Mail, Messages and Notes can hold personal facts; Messages and Notes \
                    require their own readers. This detailed reader also supports conversation and result limits. Historical reports are not fresh \
                    verification; nothing is restarted.
                    """
            ),
            ActionDescriptor(ArtifactFindArgs.self, name: "artifact_find",
                run: { context, input in
                    try await context.client.impl_artifact_find(turn: context.turn, input: input)
                }, toolClass: .read,
                description: """
                    Find a document, image, mockup or handoff by what it was for or the conversation around it. Searches recorded chat attachments, \
                    structured artifact references in call results and current Desk links; returns exact references with source conversation and version \
                    evidence when recorded. Does not crawl disk, open files, infer approval from filenames, or prove current file availability. Use \
                    the returned evidence to distinguish approved work from a later draft.
                    """
            ),
            ActionDescriptor(SearchChatHistoryArgs.self, name: "search_chat_history",
                run: { context, input in
                    try await context.client.impl_search_chat_history(input: input, invokedAs: context.tool)
                }, toolClass: .read,
                description: """
                    Search persisted conversation transcripts, including this conversation; scope/session_id narrows it. For work \
                    status/resumption, start at app {} for Desk state, original evidence and document discovery. Returns ranked snippets with \
                    conversation ids, titles, roles, timestamps and is_current_session when known. Background reads never show/detach a \
                    conversation: resolve with chat.list, then session_id, no query, sort:newest, limit:12 messages (not exchanges). Follow \
                    next_call for older pages and chat.message for truncated bodies; order collected messages chronologically and disclose \
                    coverage/truncation.
                    """
            ),
            ActionDescriptor(ReadChatMessageArgs.self, name: "read_chat_message",
                run: { context, input in
                    try await context.client.impl_read_chat_message(input: input, invokedAs: context.tool)
                }, toolClass: .read,
                description: """
                    Page a full persisted message using the exact work.context/chat.search locator, rather than rephrasing a query for another \
                    preview fragment. Call-result messages contain retained receipt metadata, not fresh reads or unabridged original output. Coverage \
                    distinguishes missing evidence from unreadable history; incomplete lookups prove neither absence nor permission to replay \
                    actions.
                    """
            ),
        ]
    }()
}
