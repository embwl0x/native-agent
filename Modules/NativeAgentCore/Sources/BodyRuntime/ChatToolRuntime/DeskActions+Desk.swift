import Foundation
import NativeAgentCore
import PersistenceCore
import MindCore
import DeskCore
import ProviderRouting
import NativeAgentShared
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import MacNerves
import SenseCore
// Blueprint: | `DeskActions+Desk.swift` | desk action contracts and execution |

extension DeskActions {
    static let deskActions: [ActionDescriptor] = {
        [
            // Read and write Desk through SwiftNativeDeskStore; discovery belongs to app actions, never extra always-on tools.
            ActionDescriptor(DeskReadArgs.self, name: "desk_read",
                run: { context, input in
                    try await context.client.impl_desk_read(input: input)
                }, toolClass: .read,
                description: """
                    Read your durable Desk as rows with status, summary, notes, refs and dates. Numbers are permanent. limit (default 25, maximum \
                    100) and offset page every list; total and has_more say what remains. sort changes order only. handle (stable or visible alias) \
                    also returns one exact live item's full summary, refs, dependencies/blockees, parts and ordered notes. query searches \
                    title/summary/project/alias/handle, and a queued step's own words, across the full live store (query \"my queue\" lists MY \
                    QUEUE). include_archived appends closed-out archived items. Read-only.
                    """
            ),
            ActionDescriptor(DeskAddItemArgs.self, name: "desk_add_item",
                run: { context, input in
                    try await context.client.impl_desk_add_item(input: input)
                }, toolClass: .write, capabilities: [.ledgerWrite, .toolCall],
                description: """
                    Add a Desk item: a short title; optional kind=watch|plan|project|gh|standing, project bucket and parent nesting. For delegation, \
                    set assignee and lane_of (coordinating Desk item) as fields, not prose. A live same-title/project/parent item returns \
                    disposition=existing; allow_duplicate=true is only for intentional equivalents. Returns status=ok, created, disposition, stable \
                    handle and view alias (\"2\", \"2.1\").
                    """
            ),
            ActionDescriptor(DeskSetStatusArgs.self, name: "desk_set_status",
                run: { context, input in
                    try await context.client.impl_desk_set_status(invocation: context.invocation, input: input, state: context.deskState!)
                }, toolClass: .write, capabilities: [.ledgerWrite, .toolCall],
                description: """
                    Set Desk status: watch|flag|now|next|todo|done|blocked|canceled or 'waiting on <person>' (also available through desk.wait). \
                    Fresh canonical evidence resolving the exact tracked defect/outcome requires updating that item in the same turn. Never close \
                    from fuzzy titles, execution completion alone or unattributed commits. blocked requires a reason via blocked_reason, reason, or \
                    status='blocked: reason', and/or waiting_on. Delegation assignments/updates include assignee and lane_of; omitted metadata \
                    stays unchanged. Report concrete batch progress as progress={done,total,note?}; omit when unknown, never invent 0%. Returns \
                    refreshed alias, status and title.
                    """
            ),
            ActionDescriptor(DeskWaitArgs.self, name: "desk_wait",
                run: { context, input in
                    try await context.client.impl_desk_wait(invocation: context.invocation, input: input, state: context.deskState!)
                }, toolClass: .write, capabilities: [.ledgerWrite, .toolCall],
                description: """
                    Put a Desk item in 'waiting on …' with one call: handle, on (a name such as User or owner, or what you are waiting for said \
                    in a sentence), and optional note. The wait appears in the Desk status; owner waits contribute to the page's \
                    waiting-on-owner count. A wait on a name, a sentence or a conversation is a status only: nothing ends it but a status change. on also accepts an observed Desk handle/number or experience id (card, \
                    message, delivery, repair); a list waits on those dependencies; such a wait is released by itself when what it names settles. \
                    To be told when a contact answers, wait on the wait_on id your send to them returned (thread.wait_on); a send held for a \
                    contact that collects its messages settles when the contact's message naming it answers it, or when you withdraw it. \
                    Unknown identifier-shaped inputs are refused.
                    """
            ),
            ActionDescriptor(DeskUpdateItemArgs.self, name: "desk_update_item",
                run: { context, input in
                    try await context.client.impl_desk_update_item(input: input)
                }, toolClass: .write, capabilities: [.ledgerWrite, .toolCall],
                description: """
                    Update a Desk item's title and/or summary. Provide at least one of title/summary. Desk has no priority field; offer a \
                    searchable tag in summary and use desk.read query to find it.
                    """
            ),
            ActionDescriptor(DeskNoteArgs.self, name: "desk_note",
                run: { context, input in
                    if case .tap? = context.turn.personAct?.by { return try await context.client.impl_desk_note(input: input, byPerson: true) }
                    return try await context.client.impl_desk_note(input: input, byPerson: false)
                }, toolClass: .write, capabilities: [.ledgerWrite, .toolCall],
                description: "Append a timestamped note to a Desk item — progress, context, a decision."
            ),
            ActionDescriptor(DeskAddRefArgs.self, name: "desk_add_ref",
                run: { context, input in
                    try await context.client.impl_desk_add_ref(input: input)
                }, toolClass: .write, capabilities: [.ledgerWrite, .toolCall],
                description: """
                    Attach a reference to a Desk item. ref_kind selects the shape and which fields apply: file (path[,line,label]) | commit \
                    (sha[,repo,label,status]) | gh_issue (repo,number[,title,status]) | gh_pr (repo,number[,title,status,checks]) | url \
                    (url[,title]) | agent (name[,handoff_id,session_id]) | approval (id[,status]) | trace (id[,trace_kind]) | note (text). \
                    A url of make:<ref> lays that made thing on the item as a piece, its title the label the Desk shows.
                    """
            ),
            ActionDescriptor(DeskSetCadenceArgs.self, name: "desk_set_cadence",
                run: { context, input in
                    try await context.client.impl_desk_set_cadence(input: input)
                }, toolClass: .write, capabilities: [.ledgerWrite, .toolCall],
                description: """
                    Set how often you refresh a Desk item. mode: manual | on_ask | tick | event | daily | weekly | blocked_watch. Optionally set \
                    interval, stale_after, and refresh_sources (comma-separated).
                    """
            ),
            ActionDescriptor(DeskSetNotifyArgs.self, name: "desk_set_notify",
                run: { context, input in
                    try await context.client.impl_desk_set_notify(input: input)
                }, toolClass: .write, capabilities: [.ledgerWrite, .toolCall],
                description: """
                    Set when a Desk item should surface to the user. level: quiet | digest | direct | urgent. Optionally set on (comma-separated \
                    triggers: state_change | blocked | done | explicit) and a cooldown. Use explicit alone for a one-time announcement.
                    """
            ),
            ActionDescriptor(DeskCloseArgs.self, name: "desk_close",
                run: { context, input in
                    try await context.client.impl_desk_close(input: input)
                }, toolClass: .write, capabilities: [.ledgerWrite, .toolCall],
                description: """
                    Close an exact Desk item with reason: the owner's explicit instruction to close or mark it done, or a fresh canonical \
                    commit/receipt/observed result proving its tracked outcome. The owner's explicit instruction is sufficient even if earlier \
                    notes say work remains; put that instruction in reason without claiming the underlying work happened. Otherwise reason must \
                    name the specific commit/receipt/observed result; \
                    never use fuzzy title matches, execution completion alone or unattributed commits. Sets done (cancelled if canceled=true); \
                    stays visible briefly, then becomes archive-eligible.
                    """
            ),
            ActionDescriptor(DeskArchiveArgs.self, name: "desk_archive",
                run: { context, input in
                    try await context.client.impl_desk_archive(input: input)
                }, toolClass: .write, capabilities: [.ledgerWrite, .toolCall],
                description: """
                    Archive a Desk item and its whole subtree: remove from live view and write archive summaries. Every item must already be done \
                    or cancelled. Refuses unfinished work and standing items anywhere in the subtree; leaves all items unchanged on refusal.
                    """
            ),
            ActionDescriptor(DeskBlockedOnArgs.self, name: "desk_blocked_on",
                run: { context, input in
                    try await context.client.impl_desk_blocked_on(input: input, state: context.deskState!)
                }, toolClass: .write, capabilities: [.ledgerWrite, .toolCall],
                description: """
                    Replace a Desk item's blockers with blocked_on CSV numbers (\"2,3.1\") or handles; empty clears. These are edges: \
                    closing/cancelling/archiving a blocker automatically readies every waiting item, without a follow-up call. Refuses unknown \
                    blockers, self-blocking and dependency cycles.
                    """
            ),
            ActionDescriptor(DeskBreakdownArgs.self, name: "desk_breakdown",
                run: { context, input in
                    try await context.client.impl_desk_breakdown(input: input)
                }, toolClass: .write, capabilities: [.ledgerWrite, .toolCall],
                description: """
                    Create an ordered numbered Desk plan: parent + children, blocked-on edges and optional child dates. children: \
                    [{title,summary?,blocked_on?,defer_until?}]. Child blocked_on CSV bare integers mean 1-based sibling positions (\"1,2\" = first \
                    two); dotted numbers (\"3.1\")/desk_ handles name existing items. Bare top-level numbers are ambiguous here; link them \
                    afterward with desk.blocked_on. parent grafts children onto an existing item, ignoring project/title/kind. Returns the numbered \
                    plan and ready children. Same-kind/project/title live campaigns return status=\"existing\", adding only missing steps. \
                    Mid-batch refusal returns status=\"partial\" and created items. One call lays out a whole plan, and the Desk page draws \
                    an item with steps as a board: a column per state (Now, Next, Waiting, Done), each step a card whose Start and Done are \
                    desk.set_status and desk.close.
                    """
            ),
            ActionDescriptor(DeskDeferArgs.self, name: "desk_defer",
                run: { context, input in
                    try await context.client.impl_desk_defer(input: input)
                }, toolClass: .write, capabilities: [.ledgerWrite, .toolCall],
                description: """
                    Defer (postpone, push back, snooze) a Desk item until yyyy-MM-dd or an ISO timestamp: stays on the desk, never \"next up\" or \
                    stale-flagged until then. Empty until clears.
                    """
            ),
            ActionDescriptor(DeskNagControlArgs.self, name: "desk_nag_control",
                run: { context, input in
                    try await context.client.impl_desk_nag_control(turn: context.turn, invocation: context.invocation, input: input, surface: context.surface)
                }, toolClass: .write, capabilities: [.ledgerWrite, .toolCall],
                description: """
                    Control Desk nagging only from the person’s intent. Default off; a scope nags only while the global switch is on. \
                    enable/disable changes global or scoped switches; mute keeps tracking (until omitted: indefinite); unmute re-arms each item’s \
                    one nag for a new window and returns intervening drift; proposal returns the notify loop’s current proposal without changing \
                    Desk or reminder settings or delivering notifications; status/read reports config. A nag requires staleness plus an underlying \
                    change (blocker cleared, deferral elapsed, or movement while stale), once per item per window, digest only, never urgent.
                    """
            ),
            ActionDescriptor(DeskOpenPursuitArgs.self, name: "desk_open_pursuit",
                run: { context, input in
                    try await context.client.impl_desk_open_pursuit(input: input)
                }, toolClass: .write, capabilities: [.ledgerWrite, .toolCall],
                description: """
                    The only route to a self-authored Desk pursuit (origin=agent): an answerable question for ~6–12 work sessions. Required: \
                    title, first-person why, done_looks_like, abandon_condition and typed evidence (shapes below). Needs ≥1 non-friction \
                    source; felt_salience needs ≥2 dates; chat_observation needs distinctDays≥2. Optional private_name, summary, max_sessions \
                    (default 12, cap 24), max_days (default 10, cap 21). Returns handle/alias; on cap or dossier failure, use the cause and \
                    supplied remedy.
                    """
            ),
            ActionDescriptor(DeskWorkLogArgs.self, name: "desk_work_log",
                run: { context, input in
                    try await context.client.impl_desk_work_log(input: input)
                }, toolClass: .write, capabilities: [.ledgerWrite, .toolCall],
                description: """
                    Append a short work receipt to a Desk item: what you did and learned this session. Required: handle and nonblank receipt. \
                    Pursuits save a work receipt; ordinary items save the same text as a note. Example for item 1 from desk.read: \
                    {\"handle\":\"1\",\"receipt\":\"Reviewed the notes and recorded the next step.\"}.
                    """
            ),
        ]
    }()
}

struct DeskReadArgs: DoorArgs {
    static let includeArchivedField = DoorFieldDescriptor("include_archived", ToolSchema.boolSchema("""
        Also page archived items matching the same handle or query, with their own total/has_more. Exact archived reads require \
        the stable handle. Default false.
        """), required: false)
    static let archivedOffsetField = DoorFieldDescriptor("archived_offset", ToolSchema.intSchema("""
        Archived row offset: copy from next_archive_read; initially uses offset. Archives have their own total/has_more in \
        archives.
        """), required: false)
    static let handleField = DoorFieldDescriptor.string("handle", """
        Optional exact live Desk handle or visible alias; returns that item's full record (notes, refs, dependencies) as well \
        as the board. Mutually exclusive with query.
        """, subject: true)
    static let queryField = DoorFieldDescriptor.string("query", """
        Optional case-insensitive text search across the full live Desk, including a queued step's words (query \"my queue\" \
        lists MY QUEUE). Mutually exclusive with handle; limit/offset page the matches.
        """)
    static let updatedOnField = DoorFieldDescriptor.string("updated_on", """
        Filter items updated on today or YYYY-MM-DD in the Mac's local timezone. With include_archived, filters archives by \
        their closed date. Can combine with query.
        """)
    static let sortField = DoorFieldDescriptor("sort", ToolSchema.enumStringSchema(["recent", "stale"], """
        recent (default) or stale (oldest first). Changes order only; fields and matching items are unchanged.
        """), required: false)
    static let limitField = DoorFieldDescriptor("limit", ToolSchema.intSchema("Rows per page, 1–100; default 25."), required: false)
    static let offsetField = DoorFieldDescriptor("offset", ToolSchema.intSchema("Row offset, default zero. Copy next_read for continuation."), required: false)
    static let notesOffsetField = DoorFieldDescriptor("notes_offset", ToolSchema.intSchema("Structured selected-record continuation: note offset; omit initially."), required: false)
    static let refsOffsetField = DoorFieldDescriptor("refs_offset", ToolSchema.intSchema("Structured selected-record continuation: linked-evidence offset; omit initially."), required: false)
    static let detailOffsetField = DoorFieldDescriptor("detail_offset", ToolSchema.intSchema("""
        Read a bounded window of the complete selected record, including full notes. Omit for the selectable overview; start at \
        zero.
        """), required: false)
    static let detailVersionField = DoorFieldDescriptor("detail_version", ToolSchema.versionSchema("""
        Exact complete-record version returned by the owner. Required for a nonzero detail_offset; changed records must restart.
        """), required: false)
    static let doorFields = [
        includeArchivedField, archivedOffsetField, handleField, queryField,
        updatedOnField, sortField, limitField, offsetField, notesOffsetField,
        refsOffsetField, detailOffsetField, detailVersionField
    ]

    let includeArchived: Bool?
    let archivedOffset: Int?
    let handle: String?
    let query: String?
    let updatedOn: String?
    let sort: String?
    let limit: Int?
    let offset: DeskReadOffset?
    let notesOffset: DeskReadOffset?
    let refsOffset: DeskReadOffset?
    let detailOffset: DeskReadOffset?
    let detailVersion: String?

    init(door: inout DoorObjectDecoder) throws(DoorDecodeError) {
        includeArchived = try door.bool(Self.includeArchivedField)
        archivedOffset = try door.int(Self.archivedOffsetField)
        handle = try door.string(Self.handleField)
        query = try door.string(Self.queryField)
        updatedOn = try door.string(Self.updatedOnField)
        sort = try door.string(Self.sortField)
        limit = try door.int(Self.limitField)
        offset = try DeskReadOffset(door: &door, field: Self.offsetField)
        notesOffset = try DeskReadOffset(door: &door, field: Self.notesOffsetField)
        refsOffset = try DeskReadOffset(door: &door, field: Self.refsOffsetField)
        detailOffset = try DeskReadOffset(door: &door, field: Self.detailOffsetField)
        detailVersion = try door.string(Self.detailVersionField)
    }
}

struct DeskReadOffset: Sendable {
    let value: Int
    let pageOffset: Int

    init?(door: inout DoorObjectDecoder, field: DoorFieldDescriptor) throws(DoorDecodeError) {
        guard let raw = try door.value(field) else { return nil }
        guard let number = SwiftToolDispatcher.jsonInt(raw) else {
            throw DoorDecodeError(path: door.path + "." + field.name, accepted: "an integer")
        }
        value = number
        if case .int = raw { pageOffset = number } else { pageOffset = 0 }
    }
}

struct DeskAddItemArgs: DoorArgs {
    static let kindField = DoorFieldDescriptor("kind", ToolSchema.enumStringSchema(["watch", "plan", "project", "gh", "standing"],
        "Optional item kind: watch | plan | project | gh | standing; left out, \(DeskItem.tasksKind.rawValue), as a person's task."), required: false)
    static let projectField = DoorFieldDescriptor.string("project", """
        Optional project bucket this item belongs to. Left out, the item goes under its parent's project, or with no parent under \
        \(DeskItem.tasksProject), where the Desk files a task the person starts.
        """)
    static let titleField = DoorFieldDescriptor.string("title", "Short item title.", required: true)
    static let untilField = DoorFieldDescriptor.string("until", "Optional yyyy-MM-dd or ISO timestamp to defer the item in this same add call.")
    static let deferredField = DoorFieldDescriptor.string("defer", "Alias for until; if both are supplied, they must agree.")
    static let parentField = DoorFieldDescriptor.string("parent", "Optional parent item handle to nest this item under.")
    static let summaryField = DoorFieldDescriptor.string("summary", """
        Optional one-line summary. Desk has no priority field; offer a searchable tag here, then use desk.read query to find it.
        """)
    static let assigneeField = DoorFieldDescriptor.string("assignee", "Optional freeform delegation assignee, such as the coding agent.")
    static let laneOfField = DoorFieldDescriptor.string("lane_of", """
        Optional coordinating Desk item handle (or visible alias) for this delegated task. This link does not change Desk \
        hierarchy.
        """)
    static let allowDuplicateField = DoorFieldDescriptor("allow_duplicate", ToolSchema.boolSchema("""
        Explicitly create a second equivalent live item instead of reusing the existing owner. Default false.
        """), required: false)
    static let doorFields = [
        kindField, projectField, titleField, untilField, deferredField, parentField,
        summaryField, assigneeField, laneOfField, allowDuplicateField
    ]

    let kind: String?
    let project: String?
    let title: String
    let until: String?
    let deferred: String?
    let parent: String?
    let summary: String?
    let assignee: String?
    let laneOf: String?
    let allowDuplicate: Bool?

    init(door: inout DoorObjectDecoder) throws(DoorDecodeError) {
        kind = try door.string(Self.kindField)
        project = try door.string(Self.projectField)
        title = try door.string(Self.titleField)!
        until = try door.string(Self.untilField)
        deferred = try door.string(Self.deferredField)
        parent = try door.string(Self.parentField)
        summary = try door.string(Self.summaryField)
        assignee = try door.string(Self.assigneeField)
        laneOf = try door.string(Self.laneOfField)
        allowDuplicate = try door.bool(Self.allowDuplicateField)
    }
}

struct DeskUpdateItemArgs: DoorArgs {
    static let handleField = DoorFieldDescriptor.string("handle", "The item's desk number (4, 2.1, desk.4) or stable handle.", required: true, subject: true)
    static let titleField = DoorFieldDescriptor.string("title", "New title (optional).")
    static let summaryField = DoorFieldDescriptor.string("summary", "New one-line summary (optional).")
    static let doorFields = [handleField, titleField, summaryField]

    let handle: String
    let title: String?
    let summary: String?

    init(door: inout DoorObjectDecoder) throws(DoorDecodeError) {
        handle = try door.string(Self.handleField)!
        title = try door.string(Self.titleField)
        summary = try door.string(Self.summaryField)
    }
}

struct DeskProgressFields: DoorObjectSchema {
    static let doneField = DoorFieldDescriptor("done", ToolSchema.intSchema("Completed units."), required: true)
    static let totalField = DoorFieldDescriptor("total", ToolSchema.intSchema("Total units; must be greater than zero."), required: true)
    static let noteField = DoorFieldDescriptor.string("note", "Optional concise progress note.")
    static let doorFields = NonEmptyFields(doneField, totalField, noteField)

    let done: Int
    let total: Int
    let note: String?

    init(door: inout DoorObjectDecoder) throws(DoorDecodeError) {
        done = try door.int(Self.doneField)!
        total = try door.int(Self.totalField)!
        note = try door.string(Self.noteField)
    }
}

struct DeskNoteArgs: DoorArgs {
    static let handleField = DoorFieldDescriptor.string("handle", "The item's desk number (4, 2.1, desk.4) or stable handle.", required: true, subject: true)
    static let textField = DoorFieldDescriptor.string("text", "The note text.", required: true)
    static let doorFields = [handleField, textField]

    let handle: String
    let text: String

    init(door: inout DoorObjectDecoder) throws(DoorDecodeError) {
        handle = try door.string(Self.handleField)!
        text = try door.string(Self.textField)!
    }
}

struct DeskAddRefArgs: DoorArgs {
    static let handleField = DoorFieldDescriptor.string("handle", "The item's desk number (4, 2.1, desk.4) or stable handle.", required: true, subject: true)
    static let refKindField = DoorFieldDescriptor("ref_kind", ToolSchema.enumStringSchema(["file", "commit", "gh_issue", "gh_pr", "url", "agent", "approval", "trace", "note"],
        "file | commit | gh_issue | gh_pr | url | agent | approval | trace | note."), required: true)
    static let pathField = DoorFieldDescriptor.string("path", "file: path.")
    static let lineField = DoorFieldDescriptor("line", ToolSchema.intSchema("file: optional line number."), required: false)
    static let labelField = DoorFieldDescriptor.string("label", "file/commit: optional label.")
    static let shaField = DoorFieldDescriptor.string("sha", "commit: commit sha.")
    static let repoField = DoorFieldDescriptor.string("repo", "commit/gh_issue/gh_pr: repository.")
    static let numberField = DoorFieldDescriptor("number", ToolSchema.intSchema("gh_issue/gh_pr: issue/PR number."), required: false)
    static let titleField = DoorFieldDescriptor.string("title", "gh_issue/gh_pr/url: optional title.")
    static let statusField = DoorFieldDescriptor.string("status", "commit/gh_issue/gh_pr/approval: optional status.")
    static let checksField = DoorFieldDescriptor.string("checks", "gh_pr: optional CI checks summary.")
    static let urlField = DoorFieldDescriptor.string("url", "url: the URL.")
    static let nameField = DoorFieldDescriptor.string("name", "agent: agent name.")
    static let handoffIDField = DoorFieldDescriptor.string("handoff_id", "agent: optional handoff id.")
    static let sessionIDField = DoorFieldDescriptor.string("session_id", "agent: optional session id.")
    static let idField = DoorFieldDescriptor.string("id", "approval/trace: the id.")
    static let traceKindField = DoorFieldDescriptor.string("trace_kind", "trace: optional trace kind.")
    static let textField = DoorFieldDescriptor.string("text", "note: the note text.")
    static let doorFields = [
        handleField, refKindField, pathField, lineField, labelField, shaField,
        repoField, numberField, titleField, statusField, checksField, urlField,
        nameField, handoffIDField, sessionIDField, idField, traceKindField,
        textField
    ]

    let handle: String
    let refKind: String
    let path: String?
    let line: Int?
    let label: String?
    let sha: String?
    let repo: String?
    let number: Int?
    let title: String?
    let status: String?
    let checks: String?
    let url: String?
    let name: String?
    let handoffID: String?
    let sessionID: String?
    let id: String?
    let traceKind: String?
    let text: String?

    init(door: inout DoorObjectDecoder) throws(DoorDecodeError) {
        handle = try door.string(Self.handleField)!
        refKind = try door.string(Self.refKindField)!
        path = try door.string(Self.pathField)
        line = try door.int(Self.lineField)
        label = try door.string(Self.labelField)
        sha = try door.string(Self.shaField)
        repo = try door.string(Self.repoField)
        number = try door.int(Self.numberField)
        title = try door.string(Self.titleField)
        status = try door.string(Self.statusField)
        checks = try door.string(Self.checksField)
        url = try door.string(Self.urlField)
        name = try door.string(Self.nameField)
        handoffID = try door.string(Self.handoffIDField)
        sessionID = try door.string(Self.sessionIDField)
        id = try door.string(Self.idField)
        traceKind = try door.string(Self.traceKindField)
        text = try door.string(Self.textField)
    }
}

struct DeskSetCadenceArgs: DoorArgs {
    static let handleField = DoorFieldDescriptor.string("handle", "The item's desk number (4, 2.1, desk.4) or stable handle.", required: true, subject: true)
    static let modeField = DoorFieldDescriptor("mode", ToolSchema.enumStringSchema(["manual", "on_ask", "tick", "event", "daily", "weekly", "blocked_watch"],
        "manual | on_ask | tick | event | daily | weekly | blocked_watch."), required: true)
    static let intervalField = DoorFieldDescriptor.string("interval", "Optional refresh interval (e.g. \"1h\", \"1d\").")
    static let staleAfterField = DoorFieldDescriptor.string("stale_after", "Optional staleness window after which the item is considered stale.")
    static let refreshSourcesField = DoorFieldDescriptor.string("refresh_sources", "Optional comma-separated list of refresh sources.")
    static let doorFields = [handleField, modeField, intervalField, staleAfterField, refreshSourcesField]

    let handle: String
    let mode: String
    let interval: String?
    let staleAfter: String?
    let refreshSources: String?

    init(door: inout DoorObjectDecoder) throws(DoorDecodeError) {
        handle = try door.string(Self.handleField)!
        mode = try door.string(Self.modeField)!
        interval = try door.string(Self.intervalField)
        staleAfter = try door.string(Self.staleAfterField)
        refreshSources = try door.string(Self.refreshSourcesField)
    }
}

struct DeskSetNotifyArgs: DoorArgs {
    static let handleField = DoorFieldDescriptor.string("handle", "The item's desk number (4, 2.1, desk.4) or stable handle.", required: true, subject: true)
    static let levelField = DoorFieldDescriptor("level", ToolSchema.enumStringSchema(["quiet", "digest", "direct", "urgent"], "quiet | digest | direct | urgent."), required: true)
    static let onField = DoorFieldDescriptor.string("on", """
        Optional comma-separated triggers: state_change | blocked | done | explicit. Use explicit alone for a one-time \
        announcement.
        """)
    static let cooldownField = DoorFieldDescriptor.string("cooldown", "Optional notify cooldown (e.g. \"6h\").")
    static let doorFields = [handleField, levelField, onField, cooldownField]

    let handle: String
    let level: String
    let on: String?
    let cooldown: String?

    init(door: inout DoorObjectDecoder) throws(DoorDecodeError) {
        handle = try door.string(Self.handleField)!
        level = try door.string(Self.levelField)!
        on = try door.string(Self.onField)
        cooldown = try door.string(Self.cooldownField)
    }
}

struct DeskCloseArgs: DoorArgs {
    static let handleField = DoorFieldDescriptor.string("handle", "The item's desk number (4, 2.1, desk.4) or stable handle.", required: true, subject: true)
    static let reasonField = DoorFieldDescriptor.string("reason", "Why it closes: the outcome, or the owner's instruction; the same word queue.done takes.", required: true)
    static let canceledField = DoorFieldDescriptor("canceled", ToolSchema.boolSchema("Close as cancelled instead of done. Default false."), required: false)
    static let subtreeField = DoorFieldDescriptor("subtree", ToolSchema.boolSchema("Also close every open descendant in this call. Returns closed count + handles. Default false."), required: false)
    static let expectedUpdatedAtField = DoorFieldDescriptor("expected_updated_at", ToolSchema.versionSchema("""
        Optional row version from a just-read Desk projection. When supplied, refuses if the item changed before this close.
        """), required: false)
    static let doorFields = [handleField, reasonField, canceledField, subtreeField, expectedUpdatedAtField]
    static let argumentNames = ["reason": ["evidence", "summary"], "canceled": ["status"]]

    let handle: String
    let reason: String
    let canceled: Bool?
    let subtree: Bool?
    let expectedUpdatedAt: String?

    init(door: inout DoorObjectDecoder) throws(DoorDecodeError) {
        handle = try door.string(Self.handleField)!
        reason = try door.string(Self.reasonField)!
        canceled = try door.bool(Self.canceledField)
        subtree = try door.bool(Self.subtreeField)
        expectedUpdatedAt = try door.string(Self.expectedUpdatedAtField)
    }
}

struct DeskArchiveArgs: DoorArgs {
    static let handleField = DoorFieldDescriptor.string("handle", "The item's desk number (4, 2.1, desk.4) or stable handle.", required: true, subject: true)
    static let doorFields = [handleField]

    let handle: String

    init(door: inout DoorObjectDecoder) throws(DoorDecodeError) {
        handle = try door.string(Self.handleField)!
    }
}

struct DeskBlockedOnArgs: DoorArgs {
    static let handleField = DoorFieldDescriptor.string("handle", "The item's desk number (e.g. 2 or 2.1) or its stable handle.", required: true, subject: true)
    static let blockedOnField = DoorFieldDescriptor.string("blocked_on", "Comma-separated desk numbers/handles of the blockers. Empty string clears all blockers.", required: true)
    static let doorFields = [handleField, blockedOnField]

    let handle: String
    let blockedOn: String

    init(door: inout DoorObjectDecoder) throws(DoorDecodeError) {
        handle = try door.string(Self.handleField)!
        blockedOn = try door.string(Self.blockedOnField)!
    }
}

struct DeskBreakdownArgs: DoorArgs {
    static let projectField = DoorFieldDescriptor.string("project", "Optional project bucket for a new plan's parent item; left out, \(DeskItem.tasksProject).")
    static let titleField = DoorFieldDescriptor.string("title", "Title for the new plan's parent item. Required unless parent is given.")
    static let kindField = DoorFieldDescriptor("kind", ToolSchema.enumStringSchema(["watch", "plan", "project", "gh", "standing"],
        "Optional parent kind (default plan): watch|plan|project|gh|standing."), required: false)
    static let summaryField = DoorFieldDescriptor.string("summary", "Optional one-line parent summary.")
    static let parentField = DoorFieldDescriptor.string("parent", "Graft mode: desk number or handle of an existing item to attach the sub-items to.")
    static let childrenField = DoorFieldDescriptor("children", ActionDescriptor.looseObjectArraySchema("""
        Ordered sub-items. Each: {title (required), summary?, blocked_on? (CSV string or array: bare integers = positions of \
        siblings in this call, dotted numbers/handles = existing items), defer_until? (yyyy-MM-dd or ISO)}. no other fields — \
        an unknown field is refused, not ignored.
        """), required: true)
    static let doorFields = [projectField, titleField, kindField, summaryField, parentField, childrenField]

    let project: String?
    let title: String?
    let kind: String?
    let summary: String?
    let parent: String?
    let children: [[String: JSONValue]]

    init(door: inout DoorObjectDecoder) throws(DoorDecodeError) {
        project = try door.string(Self.projectField)
        title = try door.string(Self.titleField)
        kind = try door.string(Self.kindField)
        summary = try door.string(Self.summaryField)
        parent = try door.string(Self.parentField)
        children = try door.objectValues(Self.childrenField)!
    }
}

struct DeskDeferArgs: DoorArgs {
    static let handleField = DoorFieldDescriptor.string("handle", "The item's desk number (e.g. 2 or 2.1) or its stable handle.", required: true, subject: true)
    static let untilField = DoorFieldDescriptor.string("until", "yyyy-MM-dd day or full ISO timestamp. Empty string clears the deferral.", required: true)
    static let doorFields = [handleField, untilField]

    let handle: String
    let until: String

    init(door: inout DoorObjectDecoder) throws(DoorDecodeError) {
        handle = try door.string(Self.handleField)!
        until = try door.string(Self.untilField)!
    }
}

struct DeskNagControlArgs: DoorArgs {
    static let actionField = DoorFieldDescriptor("action", ToolSchema.enumStringSchema(["enable", "disable", "mute", "unmute", "proposal", "status", "read"], """
        enable | disable | mute | unmute | proposal | status. proposal evaluates the notify loop without committing or \
        delivering. read is an alias for status.
        """), required: true)
    static let scopeKindField = DoorFieldDescriptor("scope_kind", ToolSchema.enumStringSchema(["global", "project", "item"],
        "global (default) | project | item. Which switch enable/disable flips."), required: false)
    static let scopeIDField = DoorFieldDescriptor.string("scope_id", """
        Required for scope_kind=project (the project name) or item (the desk number, e.g. 2.1, or its stable handle).
        """)
    static let untilField = DoorFieldDescriptor.string("until", "mute only: yyyy-MM-dd day or full ISO timestamp. Omit to mute indefinitely.")
    static let doorFields = [actionField, scopeKindField, scopeIDField, untilField]

    let action: String
    let scopeKind: String?
    let scopeID: String?
    let until: String?

    init(door: inout DoorObjectDecoder) throws(DoorDecodeError) {
        action = try door.string(Self.actionField)!
        scopeKind = try door.string(Self.scopeKindField)
        scopeID = try door.string(Self.scopeIDField)
        until = try door.string(Self.untilField)
    }
}

struct DeskWorkLogArgs: DoorArgs {
    static let handleField = DoorFieldDescriptor.string("handle", "The Desk item's stable handle or its view number. Example: \"1\" from desk.read.", required: true, subject: true)
    static let receiptField = DoorFieldDescriptor.string("receipt", "What you did / learned this work session.", required: true)
    static let doorFields = [handleField, receiptField]

    let handle: String
    let receipt: String

    init(door: inout DoorObjectDecoder) throws(DoorDecodeError) {
        handle = try door.string(Self.handleField)!
        receipt = try door.string(Self.receiptField)!
    }
}

struct DeskSetStatusArgs: DoorArgs {
    static let handleField = DoorFieldDescriptor.string("handle", "The item's desk number (4, 2.1, desk.4) or stable handle.", required: true, subject: true)
    static let statusField = DoorFieldDescriptor.string("status", """
        New status: watch | flag | now | next | todo | done | blocked | canceled | waiting on <person>. Also accepts 'blocked: \
        reason' and stores the reason in the Desk's blocked reason field.
        """, required: true)
    static let remainingWorkField = DoorFieldDescriptor("remaining_work", ToolSchema.nullable(ToolSchema.strSchema("""
        Optional exact remaining authorized work. Attach a durable continuation to this existing task before starting a \
        long job; settled calls and pending effects survive turn limits and restart. Never repeat an uncertain effect; \
        verify it through its domain first. Omit or send null when only tracking status.
        """)), required: false)
    static let blockedReasonField = DoorFieldDescriptor.string("blocked_reason", "Why it's blocked (when status=blocked).")
    static let reasonField = DoorFieldDescriptor.string("reason", "Alias for blocked_reason. If both are supplied, they must agree.")
    static let waitingOnField = DoorFieldDescriptor.string("waiting_on", "Who it's waiting on (when status=blocked); owner pushes the person.")
    static let assigneeField = DoorFieldDescriptor("assignee", ToolSchema.nullable(ToolSchema.strSchema("Optional assignee update; omitted/null/blank preserves it. Cannot clear assignments.")), required: false)
    static let laneOfField = DoorFieldDescriptor("lane_of", ToolSchema.nullable(ToolSchema.strSchema("""
        Optional live coordinating Desk handle/alias for this delegation. Omitted/null/blank preserves the link; cannot \
        clear it. Send null if unchanged; never the item's own handle.
        """)), required: false)
    static let progressField = DoorFieldDescriptor.object("progress", DeskProgressFields.self, description: "Optional explicit progress. Requires 0 <= done <= total and total > 0; omit or send null when unknown.").nullable()
    static let doorFields = [
        handleField, statusField, remainingWorkField, blockedReasonField,
        reasonField, waitingOnField, assigneeField, laneOfField, progressField
    ]

    let handle: String
    let status: String
    let remainingWork: String?
    let blockedReason: String?
    let reason: String?
    let waitingOn: String?
    let assignee: String?
    let laneOf: String?
    let progress: DeskProgressFields?

    init(waiting handle: String, on name: String, note: String?) {
        self.handle = handle
        status = "waiting on " + name
        reason = note
        remainingWork = nil
        blockedReason = nil
        waitingOn = nil
        assignee = nil
        laneOf = nil
        progress = nil
    }

    init(door: inout DoorObjectDecoder) throws(DoorDecodeError) {
        handle = try door.string(Self.handleField)!
        status = try door.string(Self.statusField)!
        remainingWork = try door.string(Self.remainingWorkField)
        blockedReason = try door.string(Self.blockedReasonField)
        reason = try door.string(Self.reasonField)
        waitingOn = try door.string(Self.waitingOnField)
        assignee = try door.string(Self.assigneeField)
        laneOf = try door.string(Self.laneOfField)
        progress = try door.object(Self.progressField, as: DeskProgressFields.self)
    }
}

struct DeskWaitArgs: DoorArgs {
    static let handleField = DoorFieldDescriptor.string("handle", "The item's handle or visible Desk number.", required: true, subject: true)
    static let onField = DoorFieldDescriptor("on", ToolSchema.obj([
            ("anyOf", .array([
                ToolSchema.strSchema("A name, a sentence saying what you wait for, or a conversation id (a status only), or one observed Desk/experience id (released when it settles)."),
                ToolSchema.obj([("type", .string("array")), ("items", ToolSchema.strSchema("An observed Desk/experience id.")), ("minItems",
                    .int(1))]),
            ])),
        ]), required: true)
    static let noteField = DoorFieldDescriptor.string("note", "Optional explanation saved with the wait.")
    static let doorFields = [handleField, onField, noteField]

    let handle: String
    let on: DoorStringOrList
    let note: String?

    init(door: inout DoorObjectDecoder) throws(DoorDecodeError) {
        handle = try door.string(Self.handleField)!
        on = try door.stringOrList(Self.onField)!
        note = try door.string(Self.noteField)
    }
}

struct DeskOpenPursuitArgs: DoorArgs {
    static let projectField = DoorFieldDescriptor.string("project", "Optional project bucket this pursuit belongs to; left out, \(DeskItem.workshopProject).")
    static let titleField = DoorFieldDescriptor.string("title", "Short pursuit title.", required: true)
    static let whyField = DoorFieldDescriptor.string("why", "First-person: why this is worth your sessions.", required: true)
    static let doneLooksLikeField = DoorFieldDescriptor.string("done_looks_like", "A question that can end — answerable in ~6–12 work sessions.", required: true)
    static let abandonConditionField = DoorFieldDescriptor.string("abandon_condition", "The condition under which you'd let this go (unpenalized).", required: true)
    static let evidenceField = DoorFieldDescriptor("evidence", .object([
        "type": .string("array"), "minItems": .int(1), "description": .string("""
        Typed citations in the required source shape. At least one non-friction source is required; live source existence \
        is not checked by preview.
        """),
        "items": .object(["anyOf": .array(DeskEvidence.alternatives.map {
            DoorArgsContract(fields: $0.all, constraints: ["additionalProperties": .bool(false)]).schema
        })])
    ]), required: true)
    static let privateNameField = DoorFieldDescriptor.string("private_name", "Optional private name for this pursuit (yours).")
    static let maxSessionsField = DoorFieldDescriptor("max_sessions", ToolSchema.intSchema("Optional session bound (default 12, cap 24)."), required: false)
    static let maxDaysField = DoorFieldDescriptor("max_days", ToolSchema.intSchema("Optional day bound (default 10, cap 21)."), required: false)
    static let summaryField = DoorFieldDescriptor.string("summary", "Optional one-line summary.")
    static let doorFields = [
        projectField, titleField, whyField, doneLooksLikeField, abandonConditionField,
        evidenceField, privateNameField, maxSessionsField, maxDaysField, summaryField
    ]

    let project: String?
    let title: String
    let why: String
    let doneLooksLike: String
    let abandonCondition: String
    let evidence: [DossierSource]
    let privateName: String?
    let maxSessions: Int?
    let maxDays: Int?
    let summary: String?

    init(door: inout DoorObjectDecoder) throws(DoorDecodeError) {
        project = try door.string(Self.projectField)
        title = try door.string(Self.titleField)!
        why = try door.string(Self.whyField)!
        doneLooksLike = try door.string(Self.doneLooksLikeField)!
        abandonCondition = try door.string(Self.abandonConditionField)!
        evidence = try door.objects(Self.evidenceField, decode: DeskEvidence.decode)!
        privateName = try door.string(Self.privateNameField)
        maxSessions = try door.int(Self.maxSessionsField)
        maxDays = try door.int(Self.maxDaysField)
        summary = try door.string(Self.summaryField)
    }
}

private enum DeskEvidence {
    static let source = DoorFieldDescriptor.string("source", required: true)
    static let id = DoorFieldDescriptor("id", ActionDescriptor.nonEmptyStringSchema("Exact source record ID."), required: true)
    static let dates = DoorFieldDescriptor("dates", ActionDescriptor.stringArraySchema("At least two distinct calendar dates, yyyy-MM-dd.", minItems: 2), required: true)
    static let noteIDs = DoorFieldDescriptor("noteIds", ActionDescriptor.stringArraySchema("Exact cited note IDs; at least distinctDays distinct notes.", minItems: 2), required: true)
    static let days = DoorFieldDescriptor("distinctDays", ToolSchema.intSchema("Distinct calendar days represented by the cited notes.", minimum: 2), required: true)
    static let count = DoorFieldDescriptor("count", ToolSchema.intSchema("Positive observed occurrence count.", minimum: 1), required: true)
    static let window = DoorFieldDescriptor("window", ActionDescriptor.nonEmptyStringSchema("Positive duration, e.g. 7d, 24h or 30m."), required: true)

    static let alternatives = [
        NonEmptyFields(DoorFieldDescriptor("source", ToolSchema.enumStringSchema(["care", "dream_digest"]), required: true), id),
        NonEmptyFields(DoorFieldDescriptor("source", ToolSchema.enumStringSchema(["felt_salience"]), required: true), dates),
        NonEmptyFields(DoorFieldDescriptor("source", ToolSchema.enumStringSchema(["chat_observation"]), required: true), noteIDs, days),
        NonEmptyFields(DoorFieldDescriptor("source", ToolSchema.enumStringSchema(["trace_friction"]), required: true), count, window),
    ]

    static func decode(_ door: inout DoorObjectDecoder) throws(DoorDecodeError) -> DossierSource {
        switch try door.string(source) {
        case "care": return .care(id: try door.string(id)!)
        case "dream_digest": return .dreamDigest(id: try door.string(id)!)
        case "felt_salience": return .feltSalience(dates: try door.strings(dates)!)
        case "chat_observation": return .chatObservation(noteIds: try door.strings(noteIDs)!, distinctDays: try door.int(days)!)
        case "trace_friction": return .traceFriction(count: try door.int(count)!, window: try door.string(window)!)
        default: throw DoorDecodeError(path: door.path + ".source", accepted: "a declared citation source")
        }
    }
}
