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
// Blueprint: | `BuiltInToolSchemaFactory+DeskSchemas.swift` | `BuiltInToolSchemaFactory`: `deskSchemas` |

extension BuiltInToolSchemaFactory {
    func deskSchemas() -> [LLMToolSchema?] {
        [
            // Desk actions page canonical rows and append operations through
            // SwiftNativeDeskStore. Reached through app actions, never extra
            // always-on model tools.
            requestedSchema(name: "desk_read", toolClass: .read,
                description: "Read your durable Desk as rows with status, summary, notes, refs and dates. Numbers are permanent. limit (default 25, maximum 100) and offset page every list; total and has_more say what remains. sort changes order only. handle (stable or visible alias) also returns one exact live item's full summary, refs, dependencies/blockees, parts and ordered notes. query searches title/summary/project/alias/handle across the full live store. include_archived appends closed-out archived items. Read-only.",
                parametersJSON: ToolSchema.params(
                    properties: [
                        ("include_archived", ToolSchema.boolSchema("Also page archived items matching the same handle or query, with their own total/has_more. Exact archived reads require the stable handle. Default false.")),
                        ("archived_offset", ToolSchema.intSchema("Archived row offset: copy from next_archive_read; initially uses offset. Archives have their own total/has_more in archives.")),
                        ("handle", ToolSchema.strSchema("Optional exact live Desk handle or visible alias; returns that item's full record (notes, refs, dependencies) as well as the board. Mutually exclusive with query.")),
                        ("query", ToolSchema.strSchema("Optional case-insensitive text search across the full live Desk. Mutually exclusive with handle; limit/offset page the matches.")),
                        ("updated_on", ToolSchema.strSchema("Filter items updated on today or YYYY-MM-DD in the Mac's local timezone. With include_archived, filters archives by their closed date. Can combine with query.")),
                        ("structured", ToolSchema.boolSchema("Accepted for workspace compatibility; all reads return the same canonical rows and page continuations.")),
                        ("sort", ToolSchema.strSchema("recent (default) or stale (oldest first). Changes order only; fields and matching items are unchanged.")),
                        ("limit", ToolSchema.intSchema("Rows per page, 1–100; default 25.")),
                        ("offset", ToolSchema.intSchema("Row offset, default zero. Copy next_read for continuation.")),
                        ("notes_offset", ToolSchema.intSchema("Structured selected-record continuation: note offset; omit initially.")),
                        ("refs_offset", ToolSchema.intSchema("Structured selected-record continuation: linked-evidence offset; omit initially.")),
                        ("detail_offset", ToolSchema.intSchema("Read a bounded window of the complete selected record, including full notes. Omit for the selectable overview; start at zero.")),
                        ("detail_version", ToolSchema.strSchema("Exact complete-record version returned by the owner. Required for a nonzero detail_offset; changed records must restart.")),
                    ],
                    required: []
                )
            ),
            requestedSchema(name: "desk_add_item", toolClass: .write, capabilities: ["ledger_write", "tool_call"],
                description: "Add a Desk item: kind=watch|plan|project|gh|standing, project bucket and short title; optional parent nesting. For delegation, set assignee and lane_of (coordinating Desk item) as fields, not prose. A live same-title/project/parent item returns disposition=existing; allow_duplicate=true is only for intentional equivalents. Returns status=ok, created, disposition, stable handle and view alias (\"2\", \"2.1\").",
                parametersJSON: ToolSchema.params(
                    properties: [
                        ("kind", ToolSchema.enumStringSchema(["watch", "plan", "project", "gh", "standing"], "Item kind: watch | plan | project | gh | standing.")),
                        ("project", ToolSchema.strSchema("Project bucket this item belongs to.")),
                        ("title", ToolSchema.strSchema("Short item title.")),
                        ("until", ToolSchema.strSchema("Optional yyyy-MM-dd or ISO timestamp to defer the item in this same add call.")),
                        ("defer", ToolSchema.strSchema("Alias for until; if both are supplied, they must agree.")),
                        ("parent", ToolSchema.strSchema("Optional parent item handle to nest this item under.")),
                        ("summary", ToolSchema.strSchema("Optional one-line summary. Desk has no priority field; offer a searchable tag here, then use desk.read query to find it.")),
                        ("assignee", ToolSchema.strSchema("Optional freeform delegation assignee, such as the coding agent.")),
                        ("lane_of", ToolSchema.strSchema("Optional coordinating Desk item handle (or visible alias) for this delegated task. This link does not change Desk hierarchy.")),
                        ("allow_duplicate", ToolSchema.boolSchema("Explicitly create a second equivalent live item instead of reusing the existing owner. Default false.")),
                    ],
                    required: ["kind", "project", "title"]
                )
            ),
            requestedSchema(name: "desk_set_status", toolClass: .write, capabilities: ["ledger_write", "tool_call"],
                description: "Set Desk status: watch|flag|now|next|todo|done|blocked|canceled or 'waiting on <person>' (also available through desk.wait). Fresh canonical evidence resolving the exact tracked defect/outcome requires updating that item in the same turn. Never close from fuzzy titles, execution completion alone or unattributed commits. blocked requires a reason via blocked_reason, reason, or status='blocked: reason', and/or waiting_on. Delegation assignments/updates include assignee and lane_of; omitted metadata stays unchanged. Report concrete batch progress as progress={done,total,note?}; omit when unknown, never invent 0%. Returns refreshed alias, status and title.",
                parametersJSON: ToolSchema.params(
                    properties: [
                        ("handle", ToolSchema.strSchema("The item's desk number (4, 2.1, desk.4) or stable handle.")),
                        ("status", ToolSchema.strSchema("New status: watch | flag | now | next | todo | done | blocked | canceled | waiting on <person>. Also accepts 'blocked: reason' and stores the reason in the Desk's blocked reason field.")),
                        ("remaining_work", ToolSchema.obj([
                            ("type", .array([.string("string"), .string("null")])),
                            ("description", .string("Optional exact remaining authorized work. Attach a durable continuation to this existing task before starting a long job; settled calls and pending effects survive turn limits and restart. Never repeat an uncertain effect; verify it through its domain first. Omit or send null when only tracking status.")),
                        ])),
                        ("blocked_reason", ToolSchema.strSchema("Why it's blocked (when status=blocked).")),
                        ("reason", ToolSchema.strSchema("Alias for blocked_reason. If both are supplied, they must agree.")),
                        ("waiting_on", ToolSchema.strSchema("Who it's waiting on (when status=blocked); owner pushes the person.")),
                        ("assignee", ToolSchema.obj([
                            ("type", .array([.string("string"), .string("null")])),
                            ("description", .string("Optional assignee update; omitted/null/blank preserves it. Cannot clear assignments.")),
                        ])),
                        ("lane_of", ToolSchema.obj([
                            ("type", .array([.string("string"), .string("null")])),
                            ("description", .string("Optional live coordinating Desk handle/alias for this delegation. Omitted/null/blank preserves the link; cannot clear it. Send null if unchanged; never the item's own handle.")),
                        ])),
                        ("progress", ToolSchema.obj([
                            ("type", .array([.string("object"), .string("null")])),
                            ("description", .string("Optional explicit progress. Requires 0 <= done <= total and total > 0; omit or send null when unknown.")),
                            ("properties", ToolSchema.obj([
                                ("done", ToolSchema.intSchema("Completed units.")),
                                ("total", ToolSchema.intSchema("Total units; must be greater than zero.")),
                                ("note", ToolSchema.strSchema("Optional concise progress note.")),
                            ])),
                            ("required", .array([.string("done"), .string("total")])),
                            ("additionalProperties", .bool(false)),
                        ])),
                    ],
                    required: ["handle", "status"]
                )
            ),
            requestedSchema(name: "desk_wait", toolClass: .write, capabilities: ["ledger_write", "tool_call"],
                description: "Put a Desk item in 'waiting on <person>' with one call: handle, on (for example User or owner), and optional note. A person wait appears in the Desk status; owner waits contribute to the page's waiting-on-owner count. on also accepts an observed Desk handle/number or experience id (card, message, delivery, repair); a list waits on those dependencies until they settle. Unknown identifier-shaped inputs are refused.",
                parametersJSON: ToolSchema.params(
                    properties: [
                        ("handle", ToolSchema.strSchema("The item's handle or visible Desk number; id is accepted as an alias.")),
                        ("on", ToolSchema.obj([
                            ("anyOf", .array([
                                ToolSchema.strSchema("A person's name, or one observed Desk/experience id."),
                                ToolSchema.obj([("type", .string("array")), ("items", ToolSchema.strSchema("An observed Desk/experience id.")), ("minItems", .int(1))]),
                            ])),
                        ])),
                        ("note", ToolSchema.strSchema("Optional explanation saved with the wait.")),
                    ], required: ["handle", "on"]
                )
            ),
            requestedSchema(name: "desk_update_item", toolClass: .write, capabilities: ["ledger_write", "tool_call"],
                description: "Update a Desk item's title and/or summary. Provide at least one of title/summary. Desk has no priority field; offer a searchable tag in summary and use desk.read query to find it.",
                parametersJSON: ToolSchema.params(
                    properties: [
                        ("handle", ToolSchema.strSchema("The item's desk number (4, 2.1, desk.4) or stable handle.")),
                        ("title", ToolSchema.strSchema("New title (optional).")),
                        ("summary", ToolSchema.strSchema("New one-line summary (optional).")),
                    ],
                    required: ["handle"]
                )
            ),
            requestedSchema(name: "desk_note", toolClass: .write, capabilities: ["ledger_write", "tool_call"],
                description: "Append a timestamped note to a Desk item — progress, context, a decision.",
                parametersJSON: ToolSchema.params(
                    properties: [
                        ("handle", ToolSchema.strSchema("The item's desk number (4, 2.1, desk.4) or stable handle.")),
                        ("text", ToolSchema.strSchema("The note text.")),
                    ],
                    required: ["handle", "text"]
                )
            ),
            requestedSchema(name: "desk_add_ref", toolClass: .write, capabilities: ["ledger_write", "tool_call"],
                description: "Attach a reference to a Desk item. ref_kind selects the shape and which fields apply: file (path[,line,label]) | commit (sha[,repo,label,status]) | gh_issue (repo,number[,title,status]) | gh_pr (repo,number[,title,status,checks]) | url (url[,title]) | agent (name[,handoff_id,session_id]) | approval (id[,status]) | trace (id[,trace_kind]) | note (text).",
                parametersJSON: ToolSchema.params(
                    properties: [
                        ("handle", ToolSchema.strSchema("The item's desk number (4, 2.1, desk.4) or stable handle.")),
                        ("ref_kind", ToolSchema.enumStringSchema(["file", "commit", "gh_issue", "gh_pr", "url", "agent", "approval", "trace", "note"], "file | commit | gh_issue | gh_pr | url | agent | approval | trace | note.")),
                        ("path", ToolSchema.strSchema("file: path.")),
                        ("line", ToolSchema.intSchema("file: optional line number.")),
                        ("label", ToolSchema.strSchema("file/commit: optional label.")),
                        ("sha", ToolSchema.strSchema("commit: commit sha.")),
                        ("repo", ToolSchema.strSchema("commit/gh_issue/gh_pr: repository.")),
                        ("number", ToolSchema.intSchema("gh_issue/gh_pr: issue/PR number.")),
                        ("title", ToolSchema.strSchema("gh_issue/gh_pr/url: optional title.")),
                        ("status", ToolSchema.strSchema("commit/gh_issue/gh_pr/approval: optional status.")),
                        ("checks", ToolSchema.strSchema("gh_pr: optional CI checks summary.")),
                        ("url", ToolSchema.strSchema("url: the URL.")),
                        ("name", ToolSchema.strSchema("agent: agent name.")),
                        ("handoff_id", ToolSchema.strSchema("agent: optional handoff id.")),
                        ("session_id", ToolSchema.strSchema("agent: optional session id.")),
                        ("id", ToolSchema.strSchema("approval/trace: the id.")),
                        ("trace_kind", ToolSchema.strSchema("trace: optional trace kind.")),
                        ("text", ToolSchema.strSchema("note: the note text.")),
                    ],
                    required: ["handle", "ref_kind"]
                )
            ),
            requestedSchema(name: "desk_set_cadence", toolClass: .write, capabilities: ["ledger_write", "tool_call"],
                description: "Set how often you refresh a Desk item. mode: manual | on_ask | tick | event | daily | weekly | blocked_watch. Optionally set interval, stale_after, and refresh_sources (comma-separated).",
                parametersJSON: ToolSchema.params(
                    properties: [
                        ("handle", ToolSchema.strSchema("The item's desk number (4, 2.1, desk.4) or stable handle.")),
                        ("mode", ToolSchema.enumStringSchema(["manual", "on_ask", "tick", "event", "daily", "weekly", "blocked_watch"], "manual | on_ask | tick | event | daily | weekly | blocked_watch.")),
                        ("interval", ToolSchema.strSchema("Optional refresh interval (e.g. \"1h\", \"1d\").")),
                        ("stale_after", ToolSchema.strSchema("Optional staleness window after which the item is considered stale.")),
                        ("refresh_sources", ToolSchema.strSchema("Optional comma-separated list of refresh sources.")),
                    ],
                    required: ["handle", "mode"]
                )
            ),
            requestedSchema(name: "desk_set_notify", toolClass: .write, capabilities: ["ledger_write", "tool_call"],
                description: "Set when a Desk item should surface to the user. level: quiet | digest | direct | urgent. Optionally set on (comma-separated triggers: state_change | blocked | done | explicit) and a cooldown. Use explicit alone for a one-time announcement.",
                parametersJSON: ToolSchema.params(
                    properties: [
                        ("handle", ToolSchema.strSchema("The item's desk number (4, 2.1, desk.4) or stable handle.")),
                        ("level", ToolSchema.enumStringSchema(["quiet", "digest", "direct", "urgent"], "quiet | digest | direct | urgent.")),
                        ("on", ToolSchema.strSchema("Optional comma-separated triggers: state_change | blocked | done | explicit. Use explicit alone for a one-time announcement.")),
                        ("cooldown", ToolSchema.strSchema("Optional notify cooldown (e.g. \"6h\").")),
                    ],
                    required: ["handle", "level"]
                )
            ),
            requestedSchema(name: "desk_close", toolClass: .write, capabilities: ["ledger_write", "tool_call"],
                description: "Close an exact Desk item when the owner explicitly asks to close or mark it done, or fresh canonical evidence proves its tracked outcome. The owner's explicit instruction is sufficient even if earlier notes say work remains; record that instruction in summary without claiming the underlying work happened. Otherwise put the specific commit/receipt/observed result in summary; never use fuzzy title matches, execution completion alone or unattributed commits. Sets done (cancelled if canceled=true); stays visible briefly, then becomes archive-eligible.",
                parametersJSON: ToolSchema.params(
                    properties: [
                        ("handle", ToolSchema.strSchema("The item's desk number (4, 2.1, desk.4) or stable handle.")),
                        ("summary", ToolSchema.strSchema("What the outcome was.")),
                        ("canceled", ToolSchema.boolSchema("Close as cancelled instead of done. Default false.")),
                        ("subtree", ToolSchema.boolSchema("Also close every open descendant in this call. Returns closed count + handles. Default false.")),
                        ("expected_updated_at", ToolSchema.strSchema("Optional row version from a just-read Desk projection. When supplied, refuses if the item changed before this close.")),
                    ],
                    required: ["handle", "summary"]
                )
            ),
            requestedSchema(name: "desk_archive", toolClass: .write, capabilities: ["ledger_write", "tool_call"],
                description: "Archive a Desk item and its whole subtree: remove from live view and write archive summaries. Every item must already be done or cancelled. Refuses unfinished work and standing items anywhere in the subtree; leaves all items unchanged on refusal.",
                parametersJSON: ToolSchema.params(
                    properties: [
                        ("handle", ToolSchema.strSchema("The item's desk number (4, 2.1, desk.4) or stable handle.")),
                    ],
                    required: ["handle"]
                )
            ),
            requestedSchema(name: "desk_blocked_on", toolClass: .write, capabilities: ["ledger_write", "tool_call"],
                description: "Replace a Desk item's blockers with blocked_on CSV numbers (\"2,3.1\") or handles; empty clears. These are edges: closing/cancelling/archiving a blocker automatically readies every waiting item, without a follow-up call. Refuses unknown blockers, self-blocking and dependency cycles.",
                parametersJSON: ToolSchema.params(
                    properties: [
                        ("handle", ToolSchema.strSchema("The item's desk number (e.g. 2 or 2.1) or its stable handle.")),
                        ("blocked_on", ToolSchema.strSchema("Comma-separated desk numbers/handles of the blockers. Empty string clears all blockers.")),
                    ],
                    required: ["handle", "blocked_on"]
                )
            ),
            requestedSchema(name: "desk_breakdown", toolClass: .write, capabilities: ["ledger_write", "tool_call"],
                description: "Create an ordered numbered Desk plan: parent + children, blocked-on edges and optional child dates. children: [{title,summary?,blocked_on?,defer_until?}]. Child blocked_on CSV bare integers mean 1-based sibling positions (\"1,2\" = first two); dotted numbers (\"3.1\")/desk_ handles name existing items. Bare top-level numbers are ambiguous here; link them afterward with desk.blocked_on. parent grafts children onto an existing item, ignoring project/title/kind. Returns the numbered plan and ready children. Same-kind/project/title live campaigns return status=\"existing\", adding only missing steps. Mid-batch refusal returns status=\"partial\" and created items.",
                parametersJSON: ToolSchema.params(
                    properties: [
                        ("project", ToolSchema.strSchema("Project bucket for a new plan's parent item. Required unless parent is given.")),
                        ("title", ToolSchema.strSchema("Title for the new plan's parent item. Required unless parent is given.")),
                        ("kind", ToolSchema.enumStringSchema(["watch", "plan", "project", "gh", "standing"], "Optional parent kind (default plan): watch|plan|project|gh|standing.")),
                        ("summary", ToolSchema.strSchema("Optional one-line parent summary.")),
                        ("parent", ToolSchema.strSchema("Graft mode: desk number or handle of an existing item to attach the sub-items to.")),
                        ("children", looseObjectArraySchema("Ordered sub-items. Each: {title (required), summary?, blocked_on? (CSV string or array: bare integers = positions of siblings in this call, dotted numbers/handles = existing items), defer_until? (yyyy-MM-dd or ISO)}. no other fields — an unknown field is refused, not ignored.")),
                    ],
                    required: ["children"]
                )
            ),
            requestedSchema(name: "desk_defer", toolClass: .write, capabilities: ["ledger_write", "tool_call"],
                description: "Defer (postpone, push back, snooze) a Desk item until yyyy-MM-dd or an ISO timestamp: stays on the desk, never \"next up\" or stale-flagged until then. Empty until clears.",
                parametersJSON: ToolSchema.params(
                    properties: [
                        ("handle", ToolSchema.strSchema("The item's desk number (e.g. 2 or 2.1) or its stable handle.")),
                        ("until", ToolSchema.strSchema("yyyy-MM-dd day or full ISO timestamp. Empty string clears the deferral.")),
                    ],
                    required: ["handle", "until"]
                )
            ),
            requestedSchema(name: "desk_nag_control", toolClass: .write, capabilities: ["ledger_write", "tool_call"],
                description: "Control Desk nagging only from the person’s intent. Default off; a scope nags only while the global switch is on. enable/disable changes global or scoped switches; mute keeps tracking (until omitted: indefinite); unmute re-arms each item’s one nag for a new window and returns intervening drift; proposal returns the notify loop’s current proposal without changing Desk or reminder settings or delivering notifications; status/read reports config. A nag requires staleness plus an underlying change (blocker cleared, deferral elapsed, or movement while stale), once per item per window, digest only, never urgent.",
                parametersJSON: ToolSchema.params(
                    properties: [
                        ("action", ToolSchema.enumStringSchema(["enable", "disable", "mute", "unmute", "proposal", "status", "read"], "enable | disable | mute | unmute | proposal | status. proposal evaluates the notify loop without committing or delivering. read is an alias for status.")),
                        ("scope_kind", ToolSchema.enumStringSchema(["global", "project", "item"], "global (default) | project | item. Which switch enable/disable flips.")),
                        ("scope_id", ToolSchema.strSchema("Required for scope_kind=project (the project name) or item (the desk number, e.g. 2.1, or its stable handle).")),
                        ("until", ToolSchema.strSchema("mute only: yyyy-MM-dd day or full ISO timestamp. Omit to mute indefinitely.")),
                    ],
                    required: ["action"]
                )
            ),
            requestedSchema(name: "desk_open_pursuit", toolClass: .write, capabilities: ["ledger_write", "tool_call"],
                description: "The only route to a self-authored Desk pursuit (origin=agent): an answerable question for ~6–12 work sessions. Required: project, title, first-person why, done_looks_like, abandon_condition and typed evidence (shapes below). Needs ≥1 non-friction source; felt_salience needs ≥2 dates; chat_observation needs distinctDays≥2. Optional private_name, summary, max_sessions (default 12, cap 24), max_days (default 10, cap 21). Returns handle/alias; on cap or dossier failure, use the cause and supplied remedy.",
                parametersJSON: ToolSchema.params(
                    properties: [
                        ("project", ToolSchema.strSchema("Project bucket this pursuit belongs to.")),
                        ("title", ToolSchema.strSchema("Short pursuit title.")),
                        ("why", ToolSchema.strSchema("First-person: why this is worth your sessions.")),
                        ("done_looks_like", ToolSchema.strSchema("A question that can end — answerable in ~6–12 work sessions.")),
                        ("abandon_condition", ToolSchema.strSchema("The condition under which you'd let this go (unpenalized).")),
                        ("evidence", ToolSchema.obj([
                            ("type", .string("array")), ("minItems", .int(1)),
                            ("description", .string("Typed citations in the required source shape. At least one non-friction source is required; live source existence is not checked by preview.")),
                            ("items", ToolSchema.obj([("anyOf", .array([
                                ToolSchema.obj([("type", .string("object")), ("additionalProperties", .bool(false)),
                                     ("properties", ToolSchema.obj([("source", ToolSchema.enumStringSchema(["care", "dream_digest"])),
                                                         ("id", nonEmptyStringSchema("Exact source record ID."))])),
                                     ("required", .array(["source", "id"].map(JSONValue.string)))]),
                                ToolSchema.obj([("type", .string("object")), ("additionalProperties", .bool(false)),
                                     ("properties", ToolSchema.obj([("source", ToolSchema.enumStringSchema(["felt_salience"])),
                                                         ("dates", stringArraySchema("At least two distinct calendar dates, yyyy-MM-dd.", minItems: 2))])),
                                     ("required", .array(["source", "dates"].map(JSONValue.string)))]),
                                ToolSchema.obj([("type", .string("object")), ("additionalProperties", .bool(false)),
                                     ("properties", ToolSchema.obj([("source", ToolSchema.enumStringSchema(["chat_observation"])),
                                                         ("noteIds", stringArraySchema("Exact cited note IDs; at least distinctDays distinct notes.", minItems: 2)),
                                                         ("distinctDays", ToolSchema.intSchema("Distinct calendar days represented by the cited notes.", minimum: 2))])),
                                     ("required", .array(["source", "noteIds", "distinctDays"].map(JSONValue.string)))]),
                                ToolSchema.obj([("type", .string("object")), ("additionalProperties", .bool(false)),
                                     ("properties", ToolSchema.obj([("source", ToolSchema.enumStringSchema(["trace_friction"])),
                                                         ("count", ToolSchema.intSchema("Positive observed occurrence count.", minimum: 1)),
                                                         ("window", nonEmptyStringSchema("Positive duration, e.g. 7d, 24h or 30m."))])),
                                     ("required", .array(["source", "count", "window"].map(JSONValue.string)))]),
                            ]))])),
                        ])),
                        ("private_name", ToolSchema.strSchema("Optional private name for this pursuit (yours).")),
                        ("max_sessions", ToolSchema.intSchema("Optional session bound (default 12, cap 24).")),
                        ("max_days", ToolSchema.intSchema("Optional day bound (default 10, cap 21).")),
                        ("summary", ToolSchema.strSchema("Optional one-line summary.")),
                    ],
                    required: ["project", "title", "why", "done_looks_like", "abandon_condition", "evidence"]
                )
            ),
            requestedSchema(name: "desk_work_log", toolClass: .write, capabilities: ["ledger_write", "tool_call"],
                description: "Append a short work receipt to a Desk item: what you did and learned this session. Required: handle and nonblank receipt. Pursuits save a work receipt; ordinary items save the same text as a note. Example for item 1 from desk.read: {\"handle\":\"1\",\"receipt\":\"Reviewed the notes and recorded the next step.\"}.",
                parametersJSON: ToolSchema.params(
                    properties: [
                        ("handle", ToolSchema.strSchema("The Desk item's stable handle or its view number. Example: \"1\" from desk.read.")),
                        ("receipt", ToolSchema.strSchema("What you did / learned this work session.")),
                    ],
                    required: ["handle", "receipt"]
                )
            ),
        ]
    }
}
