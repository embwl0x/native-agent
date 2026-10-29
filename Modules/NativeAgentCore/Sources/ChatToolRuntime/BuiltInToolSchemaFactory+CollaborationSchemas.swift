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
// Blueprint: | `BuiltInToolSchemaFactory+CollaborationSchemas.swift` | `BuiltInToolSchemaFactory`: `collaborationSchemas`: workshop, shared task ledger and delegation status |

extension BuiltInToolSchemaFactory {
    func collaborationSchemas() -> [LLMToolSchema?] {
        [
            requestedSchema(name: "workshop_submit", toolClass: .write, capabilities: ["tool_call", "workshop_write"],
                description: "Run a user-directed task from the Desk. For an exact workspace file copy, set operation=copy_workspace_file with source and destination. An active reviewed copy procedure runs directly; an unavailable or refused exact implementation reports failure without ordinary planning. Use procedure=local_file_copy_v1 only for explicit/manual compatibility. Every other objective follows normal planning and approval and creates a user-directed Desk task, unless desk_handle names an existing live Desk item to run — then the project keeps its own identity instead of gaining a second one. Returns Desk identity and execution status; use workshop.status to follow queued work.",
                parametersJSON: ToolSchema.params(
                    properties: [
                        ("text", ToolSchema.strSchema("The task objective — what the user wants done (required).")),
                        ("expected_outputs", stringArraySchema("Optional exact phrases that must occur in completed text outputs, e.g. [\"12\"] for arithmetic synthesis. Ordinary tasks only: omit operation and procedure. This verifies text containment, not external effects; omit when no exact text criterion is known.")),
                        ("context", ToolSchema.strSchema("Optional short title/context. Defaults to a prefix of the objective.")),
                        ("desk_handle", ToolSchema.strSchema("Optional live Desk handle or visible alias to execute as — use it when this work is the next piece of a project already on the Desk (name the relevant child, not the whole project, so finishing it does not close everything). Omit to create a new Desk task.")),
                        ("operation", ToolSchema.enumStringSchema(["copy_workspace_file"], "Stable exact operation. Use copy_workspace_file only for an unambiguous byte-for-byte workspace file copy and also provide source and destination. The procedure store chooses an active reviewed implementation; omit for every other task.")),
                        ("procedure", ToolSchema.enumStringSchema(["local_file_copy_v1"], "Optional native procedure. Use the only allowed value, local_file_copy_v1, for a byte-for-byte workspace file copy and also provide source and destination. Omit for every other task.")),
                        ("source", ToolSchema.strSchema("Source path relative to NativeAgent's workspace, without a leading slash. Used only with the exact copy operation/procedure.")),
                        ("destination", ToolSchema.strSchema("Destination path relative to NativeAgent's workspace, without a leading slash. Used only with the exact copy operation/procedure.")),
                    ],
                    required: ["text"]
                )
            ),
            requestedSchema(name: "workshop_status", toolClass: .read,
                description: "Read task progress in the Desk. Without an id: list active and recent work. With an execution id: return detail and step receipts. Read-only.",
                parametersJSON: ToolSchema.params(
                    properties: [
                        ("id", ToolSchema.strSchema("Optional execution id. Omit to list active and recent Desk tasks.")),
                    ],
                    required: []
                )
            ),
            // The shared ledger uses the bridge feed's file lock and actor-pinned posts.
            requestedSchema(name: "task_ledger_post", toolClass: .write, capabilities: ["ledger_write", "tool_call"],
                description: "Post an event to the cross-agent task ledger: the shared who-owns-what/done/blocked feed for the agent, Codex, and the assistant. Use it to open a task (kind=created), claim one (kind=claimed), log progress (kind=update), flag a blocker (kind=blocked), close it (kind=done/cancelled), or remove it from task views (kind=deleted, with exact task_id and expected_title). Events post as the assistant. Returns the event and its task_id.",
                parametersJSON: ToolSchema.params(
                    properties: [
                        ("kind", ToolSchema.enumStringSchema(["created", "claimed", "update", "blocked", "done", "cancelled", "deleted"], "Event kind: created | claimed | update | blocked | done | cancelled | deleted.")),
                        ("task_id", ToolSchema.strSchema("The task this event belongs to. Required for everything except 'created' (omit on created to mint a new task id).")),
                        ("title", ToolSchema.strSchema("Short task title (set on created; updates the title if provided later).")),
                        ("expected_title", ToolSchema.strSchema("For deleted: exact current title from ledger.list. The task stays in the audit feed but leaves task views.")),
                        ("note", ToolSchema.strSchema("Optional free-text note for this event (what happened, why blocked, etc.).")),
                        ("refs", stringArraySchema("Optional reference strings — file paths, commit ids, PR urls.")),
                    ],
                    required: ["kind"]
                )
            ),
            // Durable delegation status is a local read, without spawn or network.
            requestedSchema(name: "delegation_status", toolClass: .read,
                description: "Read retained inbox-door or swarm evidence. Prefer agent.read for ordinary conversations; reading both is not independent confirmation. message_id selects exact accepted-message evidence. For a swarm, set agent='swarm' and run_id, then report_id to page retained text without rerunning work. Discarded text is not recoverable; stall_basis='none' means unmeasurable.",
                parametersJSON: ToolSchema.params(
                    properties: [
                        ("limit", ToolSchema.intSchema("Bridge jobs per page: default 8, max 12. With agent='swarm' and report_id: retained text characters per page, default/max 2000.")),
                        ("offset", ToolSchema.intSchema("Bridge result offset, or character offset within the selected swarm report. Follow next_offset; omit on first page.")),
                        ("agent", ToolSchema.strSchema("Optional saved contact or retained inbox-door handle. Omit for every retained door; swarm with run_id reads a swarm receipt.")),
                        ("message_id", ToolSchema.obj([
                            ("type", .array([.string("string"), .string("null")])),
                            ("description", .string("Exact messageId from the contact's send receipt, up to 160 characters. Filters recorded identities before paging; never matches topic or filename. Omit for ordinary listing. Missing evidence does not prove work never ran.")),
                        ])),
                        ("run_id", ToolSchema.strSchema("Required only for agent='swarm': exact id returned by agent.swarm. This is an identifier, never a file path.")),
                        ("report_id", ToolSchema.obj([
                            ("type", .array([.string("string"), .string("null")])),
                            ("description", .string("For agent='swarm': exact worker report_id from descriptors, or synthesis. Omit, null, or empty for metadata only; provide to page retained output/error text.")),
                        ])),
                        ("detail", ToolSchema.strSchema("Bridge compact (default) or full lifecycle metadata. Native swarm bodies require report_id; full alone still returns only compact descriptors.")),
                    ],
                    required: []
                )
            ),
            requestedSchema(name: "task_ledger_list", toolClass: .read,
                description: "List the shared cross-agent task ledger, a separate list from your Desk. Without a task_id: paged per-task summaries (owner, status, last note), newest-updated first, with total and has_more. With a task_id: that task's event timeline. Read-only.",
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
