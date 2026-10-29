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
                description: "Search long-term memory by query (optional k), or page an exact memory_id with offset/max_characters. Search returns count, total or capped, has_more and next_offset; follow read_more with the same query/k. Use one mode; null unused fields. ID pages: max 2000 characters, with recorded evidence or explicit absence. Follow read_more with expected_content_sha256 for one text version; on record_changed discard prior pages and restart at 0. Only currently eligible, disclosed records are readable.",
                parametersJSON: recallParameters()
            ),
            requestedSchema(name: "search_kg", toolClass: .read,
                description: "Search the assistant's knowledge graph for entities matching query text; returns up to limit summaries. Filter by type and since, like the Knowledge Graph page; with no query the filters browse the whole graph. Pass entity_id instead to open one entity with its neighbors and the edges between them.",
                parametersJSON: ToolSchema.params(
                    properties: [
                        ("query", ToolSchema.strSchema("Text to search for. Leave it out to open entity_id or to browse by type or since.")),
                        ("limit", ToolSchema.intSchema("max results, default 10, at most 100; with entity_id, the most edges listed", minimum: 1, maximum: 100)),
                        ("type", ToolSchema.strSchema("Optional: only entities of these types, comma-separated: person, organization, project, concept, place, event, tool, fact.")),
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
            // Memory writes belong to the agent's own store, so they remain available
            // independently of Full Mac file access.
            requestedSchema(name: "commit_memory", toolClass: .write, capabilities: ["memory_write", "tool_call"],
                description: "Save a fact, decision or preference for later recall. Put the current decision first with its qualifications, then incident history. For a changed operating agreement, recall existing rules and name replaced ids in supersedes. context_topics declares subject/scope, not authority. text is the thing itself: omit metadata preambles, but keep dates that are part of the fact or decision. Example: {\"text\":\"Sam drinks coffee black\"}.",
                parametersJSON: ToolSchema.params(
                    properties: [
                        ("text", ToolSchema.strSchema("Nonblank fact/decision/preference: complete current decision and qualifications first, then incident history. Put metadata in its fields, not a date/time/source/id/hash/'record of' preamble. Keep meaningful dates, e.g. deadlines or when a rule takes effect.")),
                        ("provenance", ToolSchema.enumStringSchema(ContextMemoryProvenance.Kind.allCases.map(\.rawValue), "How you know this: verified (you checked it yourself), told (someone told you — also set provenance_by), inferred (you worked it out).")),
                        ("provenance_by", ToolSchema.strSchema("Who told you, when provenance=told. A name, e.g. \"Sam\".")),
                        ("source", ToolSchema.strSchema("Alias of provenance_by: who told you, when provenance=told. Prefer provenance_by if supplying both.")),
                        // A string, never an enum: a strict provider would refuse any other
                        // word. The vocabulary is offered; the save normalizes the rest.
                        ("kind", ToolSchema.strSchema("What it is about, one of: " + MemoryKindStamp.writerKinds.joined(separator: ", ") + ". About the person: identity, location, employment, schedule (when they sleep, work, are free), preference (likes, rules for how you work for them), relationship. Correction is a standing correction. Omit when none fits; any other word is classified for you.")),
                        ("tags", stringArraySchema("Optional free-form tags.")),
                        ("confidence", numSchema("How confident this fact is true, 0..1. Default 0.8.")),
                        ("importance", numSchema("How important this fact is to retain, 0..1. Default 0.5.")),
                        ("corrects", ToolSchema.strSchema("Optional id of an existing memory this new fact corrects (e.g. from memory.recall). The old memory is marked lifecycle=corrected with a lineage link to this one and drops out of recall.")),
                        ("supersedes", stringArraySchema("Optional memory ids this replaces; kept in history, excluded from recall.")),
                        ("correction_reason", ToolSchema.strSchema("Optional one-line reason the old memory was wrong (stored on the corrected row's lineage).")),
                        // maxItems/maxLength are declared; minItems deliberately
                        // is NOT. Strict providers materialize every optional
                        // array as [], which this tool treats as omission — a
                        // minItems of 1 would make that legal placeholder
                        // unsendable. The 1-8 floor is stated in prose and
                        // enforced by the validator instead.
                        ("context_topics", stringArraySchema("Read for kind correction or preference, or with no kind; ignored for other kinds. Up to 8 explicit subject/scope phrases, each non-empty and at most 120 characters. Use only the agreement's stated scope, including the named program when it is program-specific. A save returns existing agreements with that same declared scope for your judgment; nothing is retired without explicit supersedes or corrects. Omit for global boundaries; never invent a scope to weaken them. This limits automatic injection, not explicit recall.", maxItems: 8, maxItemLength: 120)),
                    ],
                    required: ["text"]
                )
            ),
        ]
    }

    func memoryReviewSchemas() -> [LLMToolSchema?] {
        [
            // Memory review accepts only a proposal id, decision and optional reason.
            requestedSchema(name: "memory_proposals_pending", toolClass: .read,
                description: "Read the memory proposals waiting on you, the same list as the Memories page: what another agent said, or consolidation proposed, that is not kept until you accept it in memory.review. Set status to rejected for the proposals already let go, with their reasons. Read-only, newest first.",
                parametersJSON: ToolSchema.params(
                    properties: [
                        ("status", ToolSchema.enumStringSchema(["pending", "rejected"], "pending (default) waits on you; rejected is the history of what was let go.")),
                        ("limit", ToolSchema.intSchema("Rows, default 10, at most 50.", minimum: 1, maximum: 50)),
                    ],
                    required: []
                )
            ),
            requestedSchema(name: "memory_proposal_review",
                toolClass: .write, capabilities: ["memory_write", "tool_call"],
                description: "Decide one memory proposal waiting on review (keep or let go, as the Memories page does). Accept and it becomes a memory you can recall; reject and it is gone, with the reason kept so the same one is not offered again. Reword a kept one with memory.rewrite.",
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
                description: "Re-derive the knowledge graph from your memory store as it is now. mode sweep_orphans instead lists the entities whose memories are gone, removing nothing; call again with confirm_ids set to exactly those ids to remove them.",
                parametersJSON: ToolSchema.params(
                    properties: [
                        ("mode", ToolSchema.enumStringSchema(["rebuild", "sweep_orphans"], "rebuild (default) re-derives the whole graph; sweep_orphans previews, then removes on confirm.")),
                        ("confirm_ids", ToolSchema.obj([
                            ("type", .string("array")),
                            ("items", ToolSchema.strSchema()),
                            ("description", .string("sweep_orphans only: the candidate ids from the preview, all of them, to remove those entities. Leave it out to preview.")),
                        ])),
                    ],
                    required: []
                )
            ),
        ]
    }
}
