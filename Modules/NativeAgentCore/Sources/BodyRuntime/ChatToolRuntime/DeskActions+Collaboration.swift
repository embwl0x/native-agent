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
// Blueprint: | `DeskActions+Collaboration.swift` | collaboration action contracts and execution |

enum DeskActions {}

extension DeskActions {
    static let collaborationActions: [ActionDescriptor] = {
        [
            // The shared ledger uses the bridge feed's file lock and actor-pinned posts.
            ActionDescriptor(TaskLedgerPostArgs.self, name: "task_ledger_post",
                run: { context, input in
                    try await context.client.impl_task_ledger_post(input: input)
                }, toolClass: .write, capabilities: [.ledgerWrite, .toolCall],
                description: """
                    Post an event to the cross-agent task ledger: the shared who-owns-what/done/blocked feed for the agent, the person and \
                    saved contacts. Use it to open a task (kind=created), claim one (kind=claimed), log progress (kind=update), flag a \
                    blocker (kind=blocked), close it (kind=done/cancelled), or remove it from task views (kind=deleted, with exact task_id \
                    and expected_title). Events post as the agent. Returns the event and its task_id.
                    """
            ),
            // Status reads must not spawn work or contact a peer.
            ActionDescriptor(DelegationStatusArgs.self, name: "delegation_status",
                run: { context, input in
                    try await context.client.impl_delegation_status(invocation: context.invocation, input: input)
                }, toolClass: .read,
                description: """
                    Your jobs (work you gave other agents and your own lines with agent.job, newest first) and retained reply deliveries \
                    (answers owed to, delivered to or let go for the chats and contacts that asked). agent.read {job} opens one job; agent.read \
                    opens a conversation. Discarded text is not recoverable.
                    """
            ),
            ActionDescriptor(TaskLedgerListArgs.self, name: "task_ledger_list",
                run: { context, input in
                    try await context.client.impl_task_ledger_list(input: input)
                }, toolClass: .read,
                description: """
                    List the shared cross-agent task ledger, a separate list from your Desk. Without a task_id: paged per-task summaries (owner, \
                    status, last note), newest-updated first, with total and has_more. With a task_id: that task's event timeline. Read-only.
                    """
            ),
        ]
    }()
}

struct TaskLedgerPostArgs: DoorArgs {
    static let kindField = DoorFieldDescriptor("kind", ToolSchema.enumStringSchema(["created", "claimed", "update", "blocked", "done", "cancelled", "deleted"],
        "Event kind: created | claimed | update | blocked | done | cancelled | deleted."), required: true)
    static let taskIDField = DoorFieldDescriptor.string("task_id", """
        The task this event belongs to. Required for everything except 'created' (omit on created to mint a new task id).
        """)
    static let titleField = DoorFieldDescriptor.string("title", "Short task title (set on created; updates the title if provided later).")
    static let expectedTitleField = DoorFieldDescriptor.string("expected_title", """
        For deleted: exact current title from ledger.list. The task stays in the audit feed but leaves task views.
        """)
    static let noteField = DoorFieldDescriptor.string("note", "Optional free-text note for this event (what happened, why blocked, etc.).")
    static let refsField = DoorFieldDescriptor("refs", ActionDescriptor.stringArraySchema("Optional reference strings — file paths, commit ids, PR urls."), required: false)
    static let doorFields = [kindField, taskIDField, titleField, expectedTitleField, noteField, refsField]

    let kind: String
    let taskID: String?
    let title: String?
    let expectedTitle: String?
    let note: String?
    let refs: [String]?

    init(door: inout DoorObjectDecoder) throws(DoorDecodeError) {
        kind = try door.string(Self.kindField)!
        taskID = try door.string(Self.taskIDField)
        title = try door.string(Self.titleField)
        expectedTitle = try door.string(Self.expectedTitleField)
        note = try door.string(Self.noteField)
        refs = try door.strings(Self.refsField)
    }
}

struct DelegationStatusArgs: DoorArgs {
    static let limitField = DoorFieldDescriptor("limit", ToolSchema.intSchema("Deliveries per page: default 8, max 12."), required: false)
    static let offsetField = DoorFieldDescriptor("offset", ToolSchema.intSchema("Delivery offset. Follow next_offset; omit on first page."), required: false)
    static let agentField = DoorFieldDescriptor.string("agent", """
        Optional saved contact whose jobs and deliveries to list, or self for your own lines. Omit for everything.
        """)
    static let detailField = DoorFieldDescriptor.string("detail", "Delivery compact (default) or full lifecycle metadata.")
    static let doorFields = [limitField, offsetField, agentField, detailField]

    let limit: Int?
    let offset: Int?
    let agent: String?
    let detail: String?

    init(door: inout DoorObjectDecoder) throws(DoorDecodeError) {
        limit = try door.int(Self.limitField)
        offset = try door.int(Self.offsetField)
        agent = try door.string(Self.agentField)
        detail = try door.string(Self.detailField)
    }
}

struct TaskLedgerListArgs: DoorArgs {
    static let taskIDField = DoorFieldDescriptor.string("task_id", "Optional task id. Omit to list all tasks; provide to get one task's event timeline.")
    static let limitField = DoorFieldDescriptor("limit", ToolSchema.intSchema("Rows per page, 1–100; default 25."), required: false)
    static let offsetField = DoorFieldDescriptor("offset", ToolSchema.intSchema("Row offset; default zero."), required: false)
    static let includeDoneField = DoorFieldDescriptor("include_done", ToolSchema.boolSchema("Include done/cancelled tasks in the list. Default false (open tasks only)."), required: false)
    static let doorFields = [taskIDField, limitField, offsetField, includeDoneField]

    let taskID: String?
    let limit: Int?
    let offset: Int?
    let includeDone: Bool?

    init(door: inout DoorObjectDecoder) throws(DoorDecodeError) {
        taskID = try door.string(Self.taskIDField)
        limit = try door.int(Self.limitField)
        offset = try door.int(Self.offsetField)
        includeDone = try door.bool(Self.includeDoneField)
    }
}
