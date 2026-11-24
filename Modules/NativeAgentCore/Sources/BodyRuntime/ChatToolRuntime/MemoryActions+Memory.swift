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
// Blueprint: | `MemoryActions+Memory.swift` | memory action contracts and execution |

struct RecallMemoryArgs: DoorArgs {
    static let queryField = DoorFieldDescriptor.string("query", "Search text; null in ID page mode.").nullable()
    static let kField = DoorFieldDescriptor.int("k", "Search result count, default 5; null in ID page mode.").nullable()
    static let memoryIDField = DoorFieldDescriptor.string("memory_id", "Exact id from a recall hit; null in search mode. Set query/k to null when paging.", subject: true).nullable()
    static let offsetField = DoorFieldDescriptor.int("offset", """
        Copy next_offset to continue the same query/k (ranked candidate offset), or the same memory_id (character offset). Default 0.
        """).nullable()
    static let maxCharactersField = DoorFieldDescriptor.int("max_characters", "ID mode only: positive page size, capped at 2000. Null in search mode.").nullable()
    static let expectedContentSHA256Field = DoorFieldDescriptor.string("expected_content_sha256", """
        ID mode: content_sha256 from the previous page, supplied by read_more. Null for a first page or search. A mismatch returns \
        record_changed without text.
        """).nullable()
    static let doorFields: [DoorFieldDescriptor] = [queryField, kField, memoryIDField, offsetField, maxCharactersField, expectedContentSHA256Field]
    let query: String?
    let k: DoorNumberLiteral?
    let memoryID: String?
    let offset: DoorNumberLiteral?
    let maxCharacters: DoorNumberLiteral?
    let expectedContentSHA256: String?

    init(door: inout DoorObjectDecoder) throws(DoorDecodeError) {
        query = try door.string(Self.queryField)
        k = try door.numberLiteral(Self.kField)
        memoryID = try door.string(Self.memoryIDField)
        offset = try door.numberLiteral(Self.offsetField)
        maxCharacters = try door.numberLiteral(Self.maxCharactersField)
        expectedContentSHA256 = try door.string(Self.expectedContentSHA256Field)
    }
}

struct SearchKGArgs: DoorArgs {
    static let queryField = DoorFieldDescriptor.string("query", "Text to search for. Leave it out to open entity_id or to browse by type or since.")
    static let limitField = DoorFieldDescriptor.int("limit", "max results, default 10, at most 100; with entity_id, the most edges listed", minimum: 1,
        maximum: 100)
    static let typeField = DoorFieldDescriptor.string("type", """
        Optional: only entities of these types, comma-separated: person, organization, project, concept, place, event, tool, \
        fact.
        """)
    static let sinceField = DoorFieldDescriptor.choice("since", ["day", "week", "month"], "Optional: only entities seen in the last day, week or month.")
    static let entityIDField = DoorFieldDescriptor.string("entity_id", "Optional: an entity id from a search result. Returns that entity, its edges and its neighbors.")
    static let doorFields: [DoorFieldDescriptor] = [queryField, limitField, typeField, sinceField, entityIDField]
    let query: String?
    let limit: Int?
    let type: String?
    let since: String?
    let entityID: String?

    init(door: inout DoorObjectDecoder) throws(DoorDecodeError) {
        query = try door.string(Self.queryField)
        limit = try door.int(Self.limitField)
        type = try door.string(Self.typeField)
        since = try door.string(Self.sinceField)
        entityID = try door.string(Self.entityIDField)
    }
}

struct CommitMemoryArgs: DoorArgs {
    static let textField = DoorFieldDescriptor.string("text", """
        Nonblank fact/decision/preference: complete current decision and qualifications first, then incident history. Put \
        metadata in its fields, not a date/time/source/id/hash/'record of' preamble. Keep meaningful dates, e.g. deadlines or \
        when a rule takes effect.
        """, required: true)
    static let provenanceField = DoorFieldDescriptor.choice("provenance", MemoryRoot.How.stated.map(\.rawValue), """
        How you know this: told (someone told you — also set provenance_by), noticed (you noticed it yourself), \
        inferred (you worked it out), verified (you checked it yourself), remembered (your own past carried here — set \
        provenance_by to where it was kept).
        """)
    static let provenanceByField = DoorFieldDescriptor.string("provenance_by", """
        Who told you (told), e.g. \"Sam\", or where your own past was kept (remembered), e.g. \"my backup\" or the app name.
        Use \(MemoryRoot.nameForm).
        """)
    static let sinceField = DoorFieldDescriptor.string("since", """
        When you first knew this, as an ISO-8601 date-time such as 2026-10-20T00:16:38Z or a date; never after now. For your own past \
        carried from a backup or another app. Omit for what you learn now.
        """)
    static let kindField = DoorFieldDescriptor.choice("kind", MemoryKindStamp.commitKinds, """
        What it is about. Correction is a standing correction; instruction is an agreement. Omit when none fits. Unsupported \
        supplied kinds are refused.
        """)
    static let tagsField = DoorFieldDescriptor.strings("tags", "Optional free-form tags.")
    static let confidenceField = DoorFieldDescriptor.number("confidence", "How confident this fact is true, 0..1. Default 0.8.")
    static let importanceField = DoorFieldDescriptor.number("importance", "How important this fact is to retain, 0..1. Default 0.5.")
    static let correctsField = DoorFieldDescriptor.string("corrects", """
        Optional id of an existing memory this new fact corrects (e.g. from memory.recall). The old memory is marked \
        lifecycle=corrected with a lineage link to this one and drops out of recall and context. A correction or \
        instruction saved without a target can return possible_matches from recall. Supply an ID only if you judge \
        that the new wording explicitly replaces that memory.
        """)
    static let supersedesField = DoorFieldDescriptor.strings("supersedes", "Optional memory ids this replaces; kept in history, excluded from recall.")
    static let correctionReasonField = DoorFieldDescriptor.string("correction_reason", """
        Optional one-line reason the old memory was wrong (stored on the corrected row's lineage).
        """)
    static let contextTopicsField = DoorFieldDescriptor.strings("context_topics", """
        For correction, instruction, preference, note or an omitted kind. Up to 8 explicit subject/scope phrases, each \
        non-empty and at most 120 characters. Every supplied entry is validated; invalid scope is refused. Use only the \
        agreement's stated scope. A save returns existing agreements with that same scope; nothing is retired without explicit \
        supersedes or corrects. Omit or use [] for global boundaries. This limits automatic injection, not explicit recall.
        """, maxItems: MemoryCommitArguments.topicLimit, maxItemLength: MemoryCommitArguments.topicCharacterLimit)
    static let doorFields = [
        textField, provenanceField, provenanceByField, sinceField, kindField, tagsField, confidenceField,
        importanceField, correctsField, supersedesField, correctionReasonField, contextTopicsField,
    ]
    let text: String
    let provenance: String?
    let provenanceBy: String?
    let since: String?
    let kind: String?
    let tags: [String]?
    let confidence: Double?
    let importance: Double?
    let corrects: String?
    let supersedes: [String]?
    let correctionReason: String?
    let contextTopics: [String]?

    init(door: inout DoorObjectDecoder) throws(DoorDecodeError) {
        text = try door.requiredString(Self.textField)
        provenance = try door.string(Self.provenanceField)
        provenanceBy = try door.string(Self.provenanceByField)
        since = try door.string(Self.sinceField)
        kind = try door.string(Self.kindField)
        tags = try door.strings(Self.tagsField)
        confidence = try door.number(Self.confidenceField)
        importance = try door.number(Self.importanceField)
        corrects = try door.string(Self.correctsField)
        supersedes = try door.strings(Self.supersedesField)
        correctionReason = try door.string(Self.correctionReasonField)
        contextTopics = try door.strings(Self.contextTopicsField)
    }
}

struct MemoryProposalsPendingArgs: DoorArgs {
    static let statusField = DoorFieldDescriptor.choice("status", ["pending", "rejected"],
        "pending (default) waits on you; rejected is the history of what was let go.")
    static let limitField = DoorFieldDescriptor.int("limit", "Rows, default 10, at most 50.", minimum: 1, maximum: 50)
    static let doorFields: [DoorFieldDescriptor] = [statusField, limitField]
    let status: String?
    let limit: Int?

    init(door: inout DoorObjectDecoder) throws(DoorDecodeError) {
        status = try door.string(Self.statusField)
        limit = try door.int(Self.limitField)
    }
}

struct MemoryProposalReviewArgs: DoorArgs {
    static let idField = DoorFieldDescriptor.string("id", "The proposal id from memory.proposals.", required: true)
    static let decisionField = DoorFieldDescriptor.choice("decision", ["accept", "reject"], "accept remembers it; reject drops it for good.", required: true)
    static let reasonField = DoorFieldDescriptor.string("reason", "Optional line recorded on a rejection, in your own words.")
    static let doorFields: [DoorFieldDescriptor] = [idField, decisionField, reasonField]
    let id: String
    let decision: String
    let reason: String?

    init(door: inout DoorObjectDecoder) throws(DoorDecodeError) {
        id = try door.requiredString(Self.idField)
        decision = try door.string(Self.decisionField)!
        reason = try door.string(Self.reasonField)
    }
}

struct ForgetMemoryArgs: DoorArgs {
    static let idField = DoorFieldDescriptor.string("id", "The memory id from app memory.list or memory.recall.", required: true)
    static let doorFields: [DoorFieldDescriptor] = [idField]
    let id: String

    init(door: inout DoorObjectDecoder) throws(DoorDecodeError) {
        id = try door.requiredString(Self.idField)
    }
}

struct RebuildKnowledgeGraphArgs: DoorArgs {
    static let modeField = DoorFieldDescriptor.choice("mode", ["rebuild", "sweep_orphans"], """
        rebuild (default) re-derives the whole graph; sweep_orphans previews, then removes on confirm.
        """)
    static let confirmIDsField = DoorFieldDescriptor.strings("confirm_ids", """
                sweep_orphans only: the candidate ids from the preview, all of them, to remove those entities. Leave it out to \
                preview.
                """)
    static let doorFields: [DoorFieldDescriptor] = [modeField, confirmIDsField]
    let mode: String?
    let confirmIDs: [String]?

    init(door: inout DoorObjectDecoder) throws(DoorDecodeError) {
        mode = try door.string(Self.modeField)
        confirmIDs = try door.strings(Self.confirmIDsField)
    }
}

extension MemoryActions {
    static let memoryReadActions: [ActionDescriptor] = {
        [
            ActionDescriptor(RecallMemoryArgs.self, name: "recall_memory",
                run: { context, input in
                    try await context.client.impl_recall_memory(turn: context.turn, input: input, surface: context.surface)
                }, toolClass: .read,
                description: """
                    Search long-term memory by query (optional k), or page an exact memory_id with offset/max_characters. Search returns count, \
                    total or capped, has_more and next_offset; follow read_more with the same query/k. Use one mode; null unused fields. ID pages: \
                    max 2000 characters, with recorded evidence or explicit absence. Follow read_more with expected_content_sha256 for one text \
                    version; on record_changed discard prior pages and restart at 0. Only currently eligible, disclosed records are readable.
                    """
            ),
            ActionDescriptor(SearchKGArgs.self, name: "search_kg",
                run: { context, input in
                    try await context.client.impl_search_kg(input: input, surface: context.surface)
                }, toolClass: .read,
                description: """
                    Search the assistant's knowledge graph for entities matching query text; returns up to limit summaries. Filter by type and \
                    since, like the Knowledge Graph page; with no query the filters browse the whole graph. Pass entity_id instead to open one \
                    entity with its neighbors and the edges between them.
                    """
            ),
        ]
    }()

    static let memoryWriteActions: [ActionDescriptor] = {
        [
            // Memory writes belong to the agent's own store, so they remain available independently of Full Mac file access.
            ActionDescriptor(CommitMemoryArgs.self, name: "commit_memory",
                run: { context, input in
                    try await context.client.impl_commit_memory(turn: context.turn, invocation: context.invocation, input: input)
                }, toolClass: .write, capabilities: [.memoryWrite, .toolCall],
                description: """
                    Save a fact, decision or preference for later recall. Put the current decision first with its qualifications, then incident \
                    history. For a changed operating agreement, recall existing rules and name replaced ids in supersedes. context_topics declares \
                    subject/scope, not authority. text is the thing itself: omit metadata preambles, but keep dates that are part of the fact or \
                    decision. Each save is one root of the memory: how you came to know it, who told you and when; saving the same words \
                    again adds a root. Your own past brought from a backup or another app is yours: save each memory with since, its kind \
                    and provenance=remembered; one you already hold you restate in place with memory.rewrite (roots). Example: \
                    {\"text\":\"Sam drinks coffee black\"}.
                    """
            ),
        ]
    }()

    static let memoryReviewActions: [ActionDescriptor] = {
        [
            ActionDescriptor(MemoryProposalsPendingArgs.self, name: "memory_proposals_pending",
                run: { context, input in
                    try await context.client.impl_memory_proposals_pending(input: input, surface: context.surface)
                }, toolClass: .read,
                description: """
                    Read the memory proposals waiting on you, the same list as the Memories page: facts from an untrusted peer or a fact \
                    acceptance left for review, not kept until you accept it in memory.review. Set status to rejected for proposals already let go, with \
                    their reasons. Read-only, newest first.
                    """
            ),
            ActionDescriptor(MemoryProposalReviewArgs.self, name: "memory_proposal_review",
                run: { context, input in
                    try await context.client.impl_memory_proposal_review(turn: context.turn, invocation: context.invocation, input: input, surface: context.surface)
                },
                toolClass: .write, capabilities: [.memoryWrite, .toolCall],
                description: """
                    Decide one memory proposal waiting on review (keep or let go, as the Memories page does). Accept and it becomes a memory you \
                    can recall; reject and it is gone, with the reason kept so the same one is not offered again. Reword a kept one with \
                    memory.rewrite.
                    """
            ),
            ActionDescriptor(ForgetMemoryArgs.self, name: "forget_memory",
                run: { context, input in
                    try await context.client.impl_forget_memory(input: input)
                }, toolClass: .write, capabilities: [.memoryWrite, .toolCall],
                description: "Drop one memory for good, with a tombstone so the same thing is not proposed again."
            ),
            ActionDescriptor(RebuildKnowledgeGraphArgs.self, name: "rebuild_knowledge_graph",
                run: { context, input in
                    try await context.client.impl_rebuild_knowledge_graph(input: input)
                },
                toolClass: .write, capabilities: [.memoryWrite, .toolCall],
                description: """
                    Re-derive the knowledge graph from your memory store as it is now. mode sweep_orphans instead lists the entities whose memories \
                    are gone, removing nothing; call again with confirm_ids set to exactly those ids to remove them.
                    """
            ),
        ]
    }()
}
