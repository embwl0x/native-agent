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
// Blueprint: | `StudioActions+Studio.swift` | studio action contracts and execution |

extension StudioActions {
    static let studioActions: [ActionDescriptor] = {
        [
            // Consultation stages an envelope without writing the journal or prejudging a verdict.
            ActionDescriptor(StudioConsultArgs.self, name: "studio_consult",
                run: { context, input in
                    try await context.client.impl_studio_consult(input: input)
                }, toolClass: .write, capabilities: [.ledgerWrite, .toolCall],
                description: """
                    File a consult against your developed taste: real work, a real question, no suggested answer. Give artifact_refs (actual \
                    files/URLs: images, page, build, cut) and/or description, available portion and question. Include \
                    project_context/stage/constraints/prior_discussion only when relevant. Without artifact_refs, description_only must be true: \
                    concepts/briefs can be critiqued but never journaled as encounters. Writes only a consult envelope; no journal write/retrieval \
                    or decision. Returns stable consult_id for studio.consult_read and deliberate later journaling if worth keeping.
                    """
            ),
            ActionDescriptor(StudioConsultReadArgs.self, name: "studio_consult_read",
                run: { context, input in
                    try await context.client.impl_studio_consult_read(input: input)
                }, toolClass: .read,
                description: "Read a filed consult verbatim: artifact refs, question, context and description-only status. Read-only."
            ),
            ActionDescriptor(StudioShelfReadArgs.self, name: "studio_shelf_read",
                run: { context, input in
                    await context.client.impl_studio_shelf(turn: context.turn, input: input, surface: context.surface)
                }, toolClass: .read,
                description: """
                    Explicitly read the private working shelf: up to three ordered journal selections with exact sentences, limitations and intact \
                    work refs. No pictures are opened. Open the work explicitly to see it.
                    """
            ),
            ActionDescriptor(StudioShelfSetArgs.self, name: "studio_shelf_set",
                preflight: { context, input in
                    let result = await context.client.impl_studio_shelf_set(turn: context.turn, input: input, surface: context.surface, preview: true)
                    let reply = ToolResult(result)
                    if case .object(let fields) = result,
                       !(reply.said("would") && reply.status == fields["status"]?.stringValue) { return reply.payload }
                    return nil
                },
                run: { context, input in
                    await context.client.impl_studio_shelf_set(turn: context.turn, input: input, surface: context.surface)
                }, toolClass: .write, capabilities: [.ledgerWrite, .toolCall],
                description: """
                    Replace the private working shelf with the complete ordered slots list (at most three distinct entries). Remove, reorder or \
                    empty with []. Changes only the shelf, never the journal or canon. selected_sentence must exist verbatim in the journal \
                    response (or quote_field stance.reason). Limitation defaults to Not yet tested. Invalid input refuses the whole replacement.
                    """
            ),
            ActionDescriptor(StudioJournalArgs.self, name: "studio_journal",
                run: { context, input in
                    try await context.client.impl_studio_journal(turn: context.turn, input: input, surface: context.surface)
                }, toolClass: .write, capabilities: [.ledgerWrite, .toolCall],
                description: """
                    Write one encounter and your honest judgment in your own words in response; other fields describe what/how you met. Additive: \
                    no tool can edit/delete earlier entries. Changed judgments become new entries linked by relations \
                    (revises/contradicts/deepens/echoes), preserving both. Wrong facts use additive studio.amend: originals stay visible, struck \
                    through. Verdicts are optional: stance.kind=abstained alone permits omitting response; optional reason in stance.reason. \
                    origin.kind=consult requires origin.ref; description_only consults cannot be encounters. Rating/score/confidence/sentiment \
                    fields are errors, never silently dropped. Server stamps id and recorded_at.
                    """
            ),
            ActionDescriptor(StudioJournalAmendArgs.self, name: "studio_journal_amend",
                run: { context, input in
                    try await context.client.impl_studio_journal_amend(turn: context.turn, input: input, surface: context.surface)
                },
                toolClass: .write, capabilities: [.ledgerWrite, .toolCall],
                description: """
                    Append a correction to an existing entry for a wrong fact/detail with no new encounter; never edit/delete its line. supersedes \
                    must quote its response verbatim: that passage stays visible, struck through, beside correction/date/reason. Without \
                    supersedes, append a dated correction block. Every read shows the correction. Changed judgments require a new studio.journal \
                    encounter linked by relations (revises/contradicts), preserving both. Cannot change work, stance, refs, tags or dates.
                    """
            ),
            ActionDescriptor(StudioRecallArgs.self, name: "studio_recall",
                run: { context, input in
                    try await context.client.impl_studio_recall(turn: context.turn, invocation: context.invocation, input: input)
                }, toolClass: .read,
                description: """
                    Search your journal only when you choose; nothing calls this for you. Filter title/creator/medium/tag/relation or free text \
                    across the entry, including response; filters combine with AND. Returns verbatim entries newest first, capped by limit, with \
                    matched/has_more coverage. No relevance score/ranking. Read-only.
                    """
            ),
        ] + dreamActions + [
            // Canon proposals require three later echoes or a pointer pulled in live judgment; only the agent resolves them, never automatically.
            ActionDescriptor(StudioCanonArgs.self, name: "studio_canon",
                run: { context, input in
                    try await context.client.impl_studio_canon(input: input)
                }, toolClass: .read, capabilities: [.toolCall],
                description: """
                    Read your museum's canon, anti-canon and works awaiting your decision. Rows cite the journal entries arguing for them; pull \
                    these with studio.recall before deciding. Binary membership, no ranking/score; reasons live in entries. Read-only.
                    """
            ),
            ActionDescriptor(StudioCanonResolveArgs.self, name: "studio_canon_resolve",
                preflight: { context, _ in
                    guard case .failure(let refusal) = StudioCanonSeatGate.liveTurnProvenance(turn: context.turn, dispatchSurface: context.surface)
                    else { return nil }
                    return .object(["status": .string("refused"), "refusal": .string(refusal.rawValue),
                        "reason": .string("\(context.tool): \(refusal.spoken). It is done from inside your own conversation, in your own turn.")])
                },
                run: { context, input in
                    try await context.client.impl_studio_canon_resolve(turn: context.turn, input: input, surface: context.surface)
                }, toolClass: .write,
                description: """
                    Decide a proposal after reading studio.canon evidence. Only you resolve it here; no owner-surface resolution or automatic \
                    canonization. Approve promote adds canon/anti_canon (work you revisit to say no); approve demote removes a canon work gone \
                    silent. Deny records the decision without changing canon. Journal entries and graph stay untouched.
                    """
            ),
        ]
    }()
}

struct StudioConsultArgs: DoorArgs {
    static let artifactRefsField = DoorFieldDescriptor("artifact_refs", ActionDescriptor.stringArraySchema("""
        File paths or URLs to the actual work being asked about. Omit or leave empty only for a description-only consult.
        """), required: false)
    static let descriptionField = DoorFieldDescriptor.string("description", "What the work is, in words. Required when there are no artifact_refs.")
    static let portionAvailableField = DoorFieldDescriptor.string("portion_available", """
        What portion is actually available — the whole thing, one spread, a rough cut, a single screen.
        """)
    static let questionField = DoorFieldDescriptor.string("question", "The real question being asked. Required.", required: true)
    static let projectContextField = DoorFieldDescriptor.string("project_context", "What the work is for and who it is for.")
    static let stageField = DoorFieldDescriptor.string("stage", "Where the work is — sketch, draft, near-final, shipped.")
    static let constraintsField = DoorFieldDescriptor.string("constraints", "Real constraints: budget, format, deadline, brand, technical limits.")
    static let priorDiscussionField = DoorFieldDescriptor.string("prior_discussion", "What has already been argued about this, if anything.")
    static let descriptionOnlyField = DoorFieldDescriptor("description_only", ToolSchema.boolSchema("""
        True when no actual work is attached — a concept or brief only. must be true when artifact_refs is empty; such a \
        consult can never become a journal encounter.
        """), required: false)
    static let doorFields = [
        artifactRefsField, descriptionField, portionAvailableField, questionField,
        projectContextField, stageField, constraintsField, priorDiscussionField,
        descriptionOnlyField
    ]

    let artifactRefs: [String]?
    let description: String?
    let portionAvailable: String?
    let question: String
    let projectContext: String?
    let stage: String?
    let constraints: String?
    let priorDiscussion: String?
    let descriptionOnly: Bool?

    init(door: inout DoorObjectDecoder) throws(DoorDecodeError) {
        artifactRefs = try door.strings(Self.artifactRefsField)
        description = try door.string(Self.descriptionField)
        portionAvailable = try door.string(Self.portionAvailableField)
        question = try door.string(Self.questionField)!
        projectContext = try door.string(Self.projectContextField)
        stage = try door.string(Self.stageField)
        constraints = try door.string(Self.constraintsField)
        priorDiscussion = try door.string(Self.priorDiscussionField)
        descriptionOnly = try door.bool(Self.descriptionOnlyField)
    }
}

struct StudioConsultReadArgs: DoorArgs {
    static let consultIDField = DoorFieldDescriptor.string("consult_id", "The exact consult_id returned by studio.consult.", required: true)
    static let doorFields = [consultIDField]

    let consultID: String

    init(door: inout DoorObjectDecoder) throws(DoorDecodeError) {
        consultID = try door.string(Self.consultIDField)!
    }
}

struct StudioJournalAmendArgs: DoorArgs {
    static func isTransportMetadata(_ key: String) -> Bool { ["__session_id", "session_id", "sessionId"].contains(key) }
    static let entryIDField = DoorFieldDescriptor.string("entry_id", "The exact entry_id of the entry being corrected (from studio.journal or studio.recall).", required: true)
    static let reasonField = DoorFieldDescriptor.string("reason", """
        Why it is wrong, in your own words. Required — a correction with no reason is a rewrite wearing a date.
        """, required: true)
    static let correctionField = DoorFieldDescriptor.string("correction", "What now stands: the corrected wording, or the correction as a standalone note. Required.", required: true)
    static let supersedesField = DoorFieldDescriptor.string("supersedes", """
        Optional. A passage quoted verbatim from that entry's response, appearing exactly once. It is kept and struck through \
        with your correction beside it. Omit to append a dated correction block instead.
        """)
    static let doorFields = [entryIDField, reasonField, correctionField, supersedesField]
    static let rootSchemaConstraints: [String: JSONValue] = ["additionalProperties": .bool(false)]

    let entryID: String
    let reason: String
    let correction: String
    let supersedes: String?

    init(door: inout DoorObjectDecoder) throws(DoorDecodeError) {
        entryID = try door.string(Self.entryIDField)!
        reason = try door.string(Self.reasonField)!
        correction = try door.string(Self.correctionField)!
        supersedes = try door.string(Self.supersedesField)
    }
}

struct StudioRecallArgs: DoorArgs {
    static let queryField = DoorFieldDescriptor("query", ToolSchema.nullable(ToolSchema.strSchema("""
        Free text matched across the whole entry, response text included. Omit, or send null, for no text filter.
        """)), required: false)
    static let titleField = DoorFieldDescriptor("title", ToolSchema.nullable(ToolSchema.strSchema("Substring of the work's title. Omit or null for no title filter.")), required: false)
    static let creatorField = DoorFieldDescriptor("creator", ToolSchema.nullable(ToolSchema.strSchema("Substring of the creator. Omit or null for no creator filter.")), required: false)
    static let mediumField = DoorFieldDescriptor("medium", ToolSchema.nullable(ToolSchema.strSchema("Substring of the medium. Omit or null for no medium filter.")), required: false)
    static let tagField = DoorFieldDescriptor("tag", ToolSchema.nullable(ToolSchema.strSchema("Exact tag (case-insensitive). Omit or null for no tag filter.")), required: false)
    static let relationKindField = DoorFieldDescriptor("relation_kind", ToolSchema.nullable(ToolSchema.enumStringSchema(["deepens", "contradicts", "revises", "echoes"],
        """
            Only entries carrying a relation of this kind. Every filter here is optional — send null (or omit this) unless you \
            truly want to restrict to related entries; entries with no relations are only findable without it.
            """)), required: false)
    static let relatedToField = DoorFieldDescriptor("related_to", ToolSchema.nullable(ToolSchema.strSchema("""
        Only entries whose relations point at this entry_id. Omit or null for no relation filter.
        """)), required: false)
    static let limitField = DoorFieldDescriptor("limit", ToolSchema.nullable(ToolSchema.intSchema("Entries to return: default 10, max 50. Omit or null for the default.",
        minimum: 1, maximum: 50)), required: false)
    static let doorFields = [
        queryField, titleField, creatorField, mediumField, tagField, relationKindField,
        relatedToField, limitField
    ]

    let query: String?
    let title: String?
    let creator: String?
    let medium: String?
    let tag: String?
    let relationKind: String?
    let relatedTo: String?
    let limit: Int?

    init(door: inout DoorObjectDecoder) throws(DoorDecodeError) {
        query = try door.string(Self.queryField)
        title = try door.string(Self.titleField)
        creator = try door.string(Self.creatorField)
        medium = try door.string(Self.mediumField)
        tag = try door.string(Self.tagField)
        relationKind = try door.string(Self.relationKindField)
        relatedTo = try door.string(Self.relatedToField)
        limit = try door.int(Self.limitField)
    }
}

struct StudioCanonArgs: DoorArgs {
    static let includeProposalsField = DoorFieldDescriptor("include_proposals", ToolSchema.nullable(ToolSchema.boolSchema("Include the proposals waiting on you. Default true.")), required: false)
    static let doorFields = [includeProposalsField]

    let includeProposals: Bool?

    init(door: inout DoorObjectDecoder) throws(DoorDecodeError) {
        includeProposals = try door.bool(Self.includeProposalsField)
    }
}

struct StudioCanonResolveArgs: DoorArgs {
    static let proposalIDField = DoorFieldDescriptor.string("proposal_id", "The proposal_id from studio.canon.", required: true)
    static let decisionField = DoorFieldDescriptor("decision", ToolSchema.enumStringSchema(["approve", "deny"], "Both record the decision; only approve changes canon."), required: true)
    static let standingField = DoorFieldDescriptor("standing", ToolSchema.enumStringSchema(["canon", "anti_canon"], """
        Which shelf, when approving a promote. Default canon. Nothing infers this from your writing — it is yours to say.
        """), required: false)
    static let noteField = DoorFieldDescriptor.string("note", "Optional line recorded on the row, in your own words.")
    static let doorFields = [proposalIDField, decisionField, standingField, noteField]

    let proposalID: String
    let decision: String
    let standing: String?
    let note: String?

    init(door: inout DoorObjectDecoder) throws(DoorDecodeError) {
        proposalID = try door.string(Self.proposalIDField)!
        decision = try door.string(Self.decisionField)!
        standing = try door.string(Self.standingField)
        note = try door.string(Self.noteField)
    }
}

struct StudioJournalArgs: DoorArgs {
    static func isTransportMetadata(_ key: String) -> Bool { ["__session_id", "session_id", "sessionId"].contains(key) }
    static let encounteredAtField = DoorFieldDescriptor.string("encountered_at", """
        When you actually encountered it (ISO-8601). Omit to use now — the server always stamps recorded_at separately.
        """)
    static let workField = DoorFieldDescriptor.object("work", StudioWorkFields.self, description: "What you encountered. Only title is required; fill the rest only with what you actually know.", required: true)
    static let receptionField = DoorFieldDescriptor.object("reception", StudioReceptionFields.self, description: "How you received it — this is what makes the encounter honest.", declaresRequired: false)
    static let artifactRefsField = DoorFieldDescriptor("artifact_refs", ActionDescriptor.stringOrStringArraySchema("What you actually saw / heard / read / played — paths or URLs."), required: false)
    static let originField = DoorFieldDescriptor.object("origin", StudioOriginFields.self, description: "Where this encounter came from. ref is required when kind=consult.", required: true)
    static let responseField = DoorFieldDescriptor.string("response", """
        Your judgment, in your own words, at whatever length it takes. Required unless stance.kind=abstained.
        """)
    static let stanceField = DoorFieldDescriptor.object("stance", StudioStanceFields.self, description: "Where the judgment stands. abstained is a real outcome, not a failure.", required: true)
    static let relationsField = DoorFieldDescriptor.objects("relations", StudioRelationFields.self, description: "Typed links to earlier entries; the earlier entry is never rewritten.")
    static let tagsField = DoorFieldDescriptor("tags", ActionDescriptor.stringOrStringArraySchema("Your own tags, if you want them. Nothing tags an entry for you."), required: false)
    static let doorFields = [
        encounteredAtField, workField, receptionField, artifactRefsField,
        originField, responseField, stanceField, relationsField, tagsField
    ]
    static let rootSchemaConstraints: [String: JSONValue] = ["additionalProperties": .bool(false)]

    let encounteredAt: String?
    let work: StudioWorkFields
    let reception: StudioReceptionFields?
    let artifactRefs: [String]?
    let origin: StudioOriginFields
    let response: String?
    let stance: StudioStanceFields
    let relations: [StudioRelationFields]?
    let tags: [String]?

    init(door: inout DoorObjectDecoder) throws(DoorDecodeError) {
        encounteredAt = try door.string(Self.encounteredAtField)
        work = try door.object(Self.workField, as: StudioWorkFields.self)!
        reception = try door.object(Self.receptionField, as: StudioReceptionFields.self)
        artifactRefs = try door.stringOrList(Self.artifactRefsField)?.values
        origin = try door.object(Self.originField, as: StudioOriginFields.self)!
        response = try door.string(Self.responseField)
        stance = try door.object(Self.stanceField, as: StudioStanceFields.self)!
        relations = try door.objects(Self.relationsField, as: StudioRelationFields.self)
        tags = try door.stringOrList(Self.tagsField)?.values
    }
}

struct StudioShelfReadArgs: DoorArgs {
    static let doorFields: [DoorFieldDescriptor] = []
    static func isTransportMetadata(_ key: String) -> Bool { key == "__session_id" }

    init(door: inout DoorObjectDecoder) {}
}

struct StudioShelfSetArgs: DoorArgs {
    static func isTransportMetadata(_ key: String) -> Bool { key == "__session_id" }
    static let slotsField = DoorFieldDescriptor.objects("slots", StudioShelfSlotFields.self, maxItems: 3, required: true)
    static let doorFields = [slotsField]

    let slots: [StudioShelfSlotFields]

    init(door: inout DoorObjectDecoder) throws(DoorDecodeError) {
        slots = try door.objects(Self.slotsField, as: StudioShelfSlotFields.self)!
    }
}

struct StudioWorkFields: DoorObjectSchema {
    static let titleField = DoorFieldDescriptor.string("title", "The work's title.", required: true)
    static let creatorField = DoorFieldDescriptor.string("creator", "Who made it.")
    static let mediumField = DoorFieldDescriptor.string("medium", "Painting, film, building, typeface, garment, game, photograph, interior …")
    static let dateField = DoorFieldDescriptor.string("date", "When it was made.")
    static let versionField = DoorFieldDescriptor.string("version", "Which version/cut/build, when that matters.")
    static let editionField = DoorFieldDescriptor.string("edition", "Which edition/printing/pressing, when that matters.")
    static let doorFields = NonEmptyFields(titleField, creatorField, mediumField, dateField, versionField, editionField)

    let title: String
    let creator: String?
    let medium: String?
    let date: String?
    let version: String?
    let edition: String?

    init(door: inout DoorObjectDecoder) throws(DoorDecodeError) {
        title = try door.string(Self.titleField)!
        creator = try door.string(Self.creatorField)
        medium = try door.string(Self.mediumField)
        date = try door.string(Self.dateField)
        version = try door.string(Self.versionField)
        edition = try door.string(Self.editionField)
    }
}

struct StudioReceptionFields: DoorObjectSchema {
    static let howField = DoorFieldDescriptor.string("how", "Original, reproduction, screening, playthrough, excerpt — or whatever it actually was.")
    static let wholeOrPartField = DoorFieldDescriptor.string("whole_or_part", "The whole thing, or which part.")
    static let doorFields = NonEmptyFields(howField, wholeOrPartField)

    let how: String?
    let wholeOrPart: String?

    init(door: inout DoorObjectDecoder) throws(DoorDecodeError) {
        how = try door.string(Self.howField)
        wholeOrPart = try door.string(Self.wholeOrPartField)
    }
}

struct StudioOriginFields: DoorObjectSchema {
    static let kindField = DoorFieldDescriptor.string("kind", """
        wandering (you went looking), consult (it came in through studio.consult), project (it came out of work); \
        case-insensitive.
        """, required: true)
    static let refField = DoorFieldDescriptor.string("ref", "The consult_id when kind=consult; otherwise whatever identifies the source.")
    static let doorFields = NonEmptyFields(kindField, refField)

    let kind: String
    let ref: String?

    init(door: inout DoorObjectDecoder) throws(DoorDecodeError) {
        kind = try door.string(Self.kindField)!
        ref = try door.string(Self.refField)
    }
}

struct StudioStanceFields: DoorObjectSchema {
    static let kindField = DoorFieldDescriptor.string("kind", """
        open (still working on it), formed (you know what you think), abstained (not enough to judge, or you chose not \
        to); case-insensitive.
        """, required: true)
    static let reasonField = DoorFieldDescriptor.string("reason", "Optional — why you abstained, or what is still open.")
    static let doorFields = NonEmptyFields(kindField, reasonField)

    let kind: String
    let reason: String?

    init(door: inout DoorObjectDecoder) throws(DoorDecodeError) {
        kind = try door.string(Self.kindField)!
        reason = try door.string(Self.reasonField)
    }
}

struct StudioRelationFields: DoorObjectSchema {
    static let kindField = DoorFieldDescriptor.string("kind", "deepens|contradicts|revises|echoes", required: true)
    static let entryIDField = DoorFieldDescriptor.string("entry_id", required: true)
    static let doorFields = NonEmptyFields(kindField, entryIDField)

    let kind: String
    let entryID: String

    init(door: inout DoorObjectDecoder) throws(DoorDecodeError) {
        kind = try door.string(Self.kindField)!
        entryID = try door.string(Self.entryIDField)!
    }
}

struct StudioShelfSlotFields: DoorObjectSchema {
    static let entryIDField = DoorFieldDescriptor.string("entry_id", "Exact existing journal entry ID.", required: true)
    static let titleField = DoorFieldDescriptor.string("title", "Required chosen short title, at most 120 UTF-8 bytes on one line.", required: true)
    static let selectedSentenceField = DoorFieldDescriptor.string("selected_sentence", """
        One complete sentence verbatim from the selected journal field, including its terminator. Fragments and \
        multiple sentences are refused. The encounter must have work refs. Never paraphrase.
        """, required: true)
    static let quoteFieldField = DoorFieldDescriptor("quote_field", ToolSchema.enumStringSchema(["response", "stance.reason"], "response (default) or stance.reason."), required: false)
    static let limitationField = DoorFieldDescriptor.string("limitation", "Optional limitation or counterexample; defaults to Not yet tested.")
    static let doorFields = NonEmptyFields(entryIDField, titleField, selectedSentenceField, quoteFieldField, limitationField)

    let entryID: String
    let title: String
    let selectedSentence: String
    let quoteField: String?
    let limitation: String?

    init(door: inout DoorObjectDecoder) throws(DoorDecodeError) {
        entryID = try door.string(Self.entryIDField)!
        title = try door.string(Self.titleField)!
        selectedSentence = try door.string(Self.selectedSentenceField)!
        quoteField = try door.string(Self.quoteFieldField)
        limitation = try door.string(Self.limitationField)
    }
}
