import Foundation
import NativeAgentCore
import PersistenceCore
import MemoryV2
import Context
import ChatTurnContracts
import AgentWorkspace
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
// Blueprint: | `BuiltInToolSchemaFactory+MemorySchemas.swift` | `BuiltInToolSchemaFactory`: `memoryReadSchemas`, `memoryWriteSchemas`, `memoryReviewSchemas` |

extension BuiltInToolSchemaFactory {
    func memoryReadSchemas() -> [LLMToolSchema?] {
        [
            requestedSchema(name: "recall_memory", toolClass: .read,
                description: """
                    Search long-term memory by query (optional k), or page an exact memory_id with offset/max_characters. Search returns count, \
                    total or capped, has_more and next_offset; follow read_more with the same query/k. Use one mode; null unused fields. ID pages: \
                    max 2000 characters, with recorded evidence or explicit absence. Follow read_more with expected_content_sha256 for one text \
                    version; on record_changed discard prior pages and restart at 0. Only currently eligible, disclosed records are readable.
                    """,
                parametersJSON: recallParameters()
            ),
            requestedSchema(name: "search_kg", toolClass: .read,
                description: """
                    Search the assistant's knowledge graph for entities matching query text; returns up to limit summaries. Filter by type and \
                    since, like the Knowledge Graph page; with no query the filters browse the whole graph. Pass entity_id instead to open one \
                    entity with its neighbors and the edges between them.
                    """,
                parametersJSON: ToolSchema.params(
                    properties: [
                        ("query", ToolSchema.strSchema("Text to search for. Leave it out to open entity_id or to browse by type or since.")),
                        ("limit", ToolSchema.intSchema("max results, default 10, at most 100; with entity_id, the most edges listed", minimum: 1,
                            maximum: 100)),
                        ("type", ToolSchema.strSchema("""
                            Optional: only entities of these types, comma-separated: person, organization, project, concept, place, event, tool, \
                            fact.
                            """)),
                        ("since", ToolSchema.enumStringSchema(["day", "week", "month"], "Optional: only entities seen in the last day, week or month.")),
                        ("entity_id", ToolSchema.strSchema("Optional: an entity id from a search result. Returns that entity, its edges and its neighbors.")),
                    ],
                    required: []
                )
            ),
        ]
    }

    func memoryWriteSchemas() -> [LLMToolSchema?] {
        [
            // Memory writes belong to the agent's own store, so they remain available independently of Full Mac file access.
            requestedSchema(name: "commit_memory", toolClass: .write, capabilities: ["memory_write", "tool_call"],
                description: """
                    Save a fact, decision or preference for later recall. Put the current decision first with its qualifications, then incident \
                    history. For a changed operating agreement, recall existing rules and name replaced ids in supersedes. context_topics declares \
                    subject/scope, not authority. text is the thing itself: omit metadata preambles, but keep dates that are part of the fact or \
                    decision. Each save is one root of the memory: how you came to know it, who told you and when; saving the same words \
                    again adds a root. Your own past brought from a backup or another app is yours: save each memory with since, its kind \
                    and provenance=remembered; one you already hold you restate in place with memory.rewrite (roots). Example: \
                    {\"text\":\"Sam drinks coffee black\"}.
                    """,
                parametersJSON: ToolSchema.params(
                    properties: [
                        ("text", ToolSchema.strSchema("""
                            Nonblank fact/decision/preference: complete current decision and qualifications first, then incident history. Put \
                            metadata in its fields, not a date/time/source/id/hash/'record of' preamble. Keep meaningful dates, e.g. deadlines or \
                            when a rule takes effect.
                            """)),
                        ("provenance", ToolSchema.enumStringSchema(MemoryRoot.How.stated.map(\.rawValue), """
                            How you know this: told (someone told you — also set provenance_by), noticed (you noticed it yourself), \
                            inferred (you worked it out), verified (you checked it yourself), remembered (your own past carried here — set \
                            provenance_by to where it was kept).
                            """)),
                        ("provenance_by", ToolSchema.strSchema("""
                            Who told you (told), e.g. \"Sam\", or where your own past was kept (remembered), e.g. \"my backup\" or the app name.
                            """)),
                        ("since", ToolSchema.strSchema("""
                            When you first knew this, as an ISO-8601 date-time such as 2026-10-20T00:16:38Z; never after now. For your own past \
                            carried from a backup or another app. Omit for what you learn now.
                            """)),
                        ("kind", ToolSchema.enumStringSchema(MemoryKindStamp.commitKinds, """
                            What it is about. Correction is a standing correction; instruction is an agreement. Omit when none fits. Unsupported \
                            supplied kinds are refused.
                            """)),
                        ("tags", stringArraySchema("Optional free-form tags.")),
                        ("confidence", numSchema("How confident this fact is true, 0..1. Default 0.8.")),
                        ("importance", numSchema("How important this fact is to retain, 0..1. Default 0.5.")),
                        ("corrects", ToolSchema.strSchema("""
                            Optional id of an existing memory this new fact corrects (e.g. from memory.recall). The old memory is marked \
                            lifecycle=corrected with a lineage link to this one and drops out of recall.
                            """)),
                        ("supersedes", stringArraySchema("Optional memory ids this replaces; kept in history, excluded from recall.")),
                        ("correction_reason", ToolSchema.strSchema("""
                            Optional one-line reason the old memory was wrong (stored on the corrected row's lineage).
                            """)),
                        // Strict providers encode optional arrays as []; omit minItems so that omission remains valid, and enforce the 1–8 nonempty bound in
                        // validation.
                        ("context_topics", stringArraySchema("""
                            For correction, instruction, preference, note or an omitted kind. Up to 8 explicit subject/scope phrases, each \
                            non-empty and at most 120 characters. Every supplied entry is validated; invalid scope is refused. Use only the \
                            agreement's stated scope. A save returns existing agreements with that same scope; nothing is retired without explicit \
                            supersedes or corrects. Omit or use [] for global boundaries. This limits automatic injection, not explicit recall.
                            """, maxItems: MemoryCommitArguments.topicLimit, maxItemLength: MemoryCommitArguments.topicCharacterLimit)),
                    ],
                    required: ["text"]
                )
            ),
        ]
    }

    func memoryReviewSchemas() -> [LLMToolSchema?] {
        [
            requestedSchema(name: "memory_proposals_pending", toolClass: .read,
                description: """
                    Read the memory proposals waiting on you, the same list as the Memories page: facts from an untrusted peer or a fact \
                    acceptance left for review, not kept until you accept it in memory.review. Set status to rejected for proposals already let go, with \
                    their reasons. Read-only, newest first.
                    """,
                parametersJSON: ToolSchema.params(
                    properties: [
                        ("status", ToolSchema.enumStringSchema(["pending", "rejected"],
                            "pending (default) waits on you; rejected is the history of what was let go.")),
                        ("limit", ToolSchema.intSchema("Rows, default 10, at most 50.", minimum: 1, maximum: 50)),
                    ],
                    required: []
                )
            ),
            requestedSchema(name: "memory_proposal_review",
                toolClass: .write, capabilities: ["memory_write", "tool_call"],
                description: """
                    Decide one memory proposal waiting on review (keep or let go, as the Memories page does). Accept and it becomes a memory you \
                    can recall; reject and it is gone, with the reason kept so the same one is not offered again. Reword a kept one with \
                    memory.rewrite.
                    """,
                parametersJSON: ToolSchema.params(
                    properties: [
                        ("id", ToolSchema.strSchema("The proposal id from memory.proposals.")),
                        ("decision", ToolSchema.enumStringSchema(["accept", "reject"], "accept remembers it; reject drops it for good.")),
                        ("reason", ToolSchema.strSchema("Optional line recorded on a rejection, in your own words.")),
                    ],
                    required: ["id", "decision"]
                )
            ),
            requestedSchema(name: "forget_memory", toolClass: .write, capabilities: ["memory_write", "tool_call"],
                description: "Drop one memory for good, with a tombstone so the same thing is not proposed again.",
                parametersJSON: ToolSchema.params(
                    properties: [
                        ("id", ToolSchema.strSchema("The memory id from app memory.list or memory.recall.")),
                    ],
                    required: ["id"]
                )
            ),
            requestedSchema(name: "rebuild_knowledge_graph",
                toolClass: .write, capabilities: ["memory_write", "tool_call"],
                description: """
                    Re-derive the knowledge graph from your memory store as it is now. mode sweep_orphans instead lists the entities whose memories \
                    are gone, removing nothing; call again with confirm_ids set to exactly those ids to remove them.
                    """,
                parametersJSON: ToolSchema.params(
                    properties: [
                        ("mode", ToolSchema.enumStringSchema(["rebuild", "sweep_orphans"], """
                            rebuild (default) re-derives the whole graph; sweep_orphans previews, then removes on confirm.
                            """)),
                        ("confirm_ids", ToolSchema.obj([
                            ("type", .string("array")),
                            ("items", ToolSchema.strSchema()),
                            ("description", .string("""
                                sweep_orphans only: the candidate ids from the preview, all of them, to remove those entities. Leave it out to \
                                preview.
                                """)),
                        ])),
                    ],
                    required: []
                )
            ),
        ]
    }
}
