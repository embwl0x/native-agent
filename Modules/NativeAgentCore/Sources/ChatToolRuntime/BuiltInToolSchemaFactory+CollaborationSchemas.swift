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
// Blueprint: | `BuiltInToolSchemaFactory+CollaborationSchemas.swift` | `BuiltInToolSchemaFactory`, `collaborationSchemas`: Shared work schemas. |

extension BuiltInToolSchemaFactory {
    func collaborationSchemas() -> [LLMToolSchema?] {
        [
            // The shared ledger uses the bridge feed's file lock and actor-pinned posts.
            requestedSchema(name: "task_ledger_post", toolClass: .write, capabilities: ["ledger_write", "tool_call"],
                description: """
                    Post an event to the cross-agent task ledger: the shared who-owns-what/done/blocked feed for the agent, the person and \
                    saved contacts. Use it to open a task (kind=created), claim one (kind=claimed), log progress (kind=update), flag a \
                    blocker (kind=blocked), close it (kind=done/cancelled), or remove it from task views (kind=deleted, with exact task_id \
                    and expected_title). Events post as the agent. Returns the event and its task_id.
                    """,
                parametersJSON: ToolSchema.params(
                    properties: [
                        ("kind", ToolSchema.enumStringSchema(["created", "claimed", "update", "blocked", "done", "cancelled", "deleted"],
                            "Event kind: created | claimed | update | blocked | done | cancelled | deleted.")),
                        ("task_id", ToolSchema.strSchema("""
                            The task this event belongs to. Required for everything except 'created' (omit on created to mint a new task id).
                            """)),
                        ("title", ToolSchema.strSchema("Short task title (set on created; updates the title if provided later).")),
                        ("expected_title", ToolSchema.strSchema("""
                            For deleted: exact current title from ledger.list. The task stays in the audit feed but leaves task views.
                            """)),
                        ("note", ToolSchema.strSchema("Optional free-text note for this event (what happened, why blocked, etc.).")),
                        ("refs", stringArraySchema("Optional reference strings — file paths, commit ids, PR urls.")),
                    ],
                    required: ["kind"]
                )
            ),
            // Status reads must not spawn work or contact a peer.
            requestedSchema(name: "delegation_status", toolClass: .read,
                description: """
                    Your jobs (work you gave other agents and your own lines with agent.job, newest first) and retained reply deliveries \
                    (answers owed to, delivered to or let go for the chats and contacts that asked). agent.read {job} opens one job; agent.read \
                    opens a conversation. Discarded text is not recoverable; stall_basis='none' means unmeasurable.
                    """,
                parametersJSON: ToolSchema.params(
                    properties: [
                        ("limit", ToolSchema.intSchema("Deliveries per page: default 8, max 12.")),
                        ("offset", ToolSchema.intSchema("Delivery offset. Follow next_offset; omit on first page.")),
                        ("agent", ToolSchema.strSchema("""
                            Optional saved contact whose jobs and deliveries to list, or self for your own lines. Omit for everything.
                            """)),
                        ("detail", ToolSchema.strSchema("Delivery compact (default) or full lifecycle metadata.")),
                    ],
                    required: []
                )
            ),
            requestedSchema(name: "task_ledger_list", toolClass: .read,
                description: """
                    List the shared cross-agent task ledger, a separate list from your Desk. Without a task_id: paged per-task summaries (owner, \
                    status, last note), newest-updated first, with total and has_more. With a task_id: that task's event timeline. Read-only.
                    """,
                parametersJSON: ToolSchema.params(
                    properties: [
                        ("task_id", ToolSchema.strSchema("Optional task id. Omit to list all tasks; provide to get one task's event timeline.")),
                        ("limit", ToolSchema.intSchema("Rows per page, 1–100; default 25.")),
                        ("offset", ToolSchema.intSchema("Row offset; default zero.")),
                        ("include_done", ToolSchema.boolSchema("Include done/cancelled tasks in the list. Default false (open tasks only).")),
                    ],
                    required: []
                )
            ),
        ]
    }
}
