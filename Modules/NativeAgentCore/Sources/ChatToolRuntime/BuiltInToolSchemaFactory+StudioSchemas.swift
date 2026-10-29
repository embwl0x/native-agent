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
// Blueprint: | `BuiltInToolSchemaFactory+StudioSchemas.swift` | `BuiltInToolSchemaFactory`: `studioSchemas`: consultation, shelf, journal, recall and canon; dream declarations retain their place in the sequence |

extension BuiltInToolSchemaFactory {
    func studioSchemas() -> [LLMToolSchema?] {
        [
            // Studio consultation files an envelope, without journal writes or a suggested verdict.
            requestedSchema(name: "studio_consult", toolClass: .write, capabilities: ["ledger_write", "tool_call"],
                description: "File a consult against your developed taste: real work, a real question, no suggested answer. Give artifact_refs (actual files/URLs: images, page, build, cut) and/or description, available portion and question. Include project_context/stage/constraints/prior_discussion only when relevant. Without artifact_refs, description_only must be true: concepts/briefs can be critiqued but never journaled as encounters. Writes only a consult envelope; no journal write/retrieval or decision. Returns stable consult_id for studio.consult_read and deliberate later journaling if worth keeping.",
                parametersJSON: ToolSchema.params(
                    properties: [
                        ("artifact_refs", stringArraySchema("File paths or URLs to the actual work being asked about. Omit or leave empty only for a description-only consult.")),
                        ("description", ToolSchema.strSchema("What the work is, in words. Required when there are no artifact_refs.")),
                        ("portion_available", ToolSchema.strSchema("What portion is actually available — the whole thing, one spread, a rough cut, a single screen.")),
                        ("question", ToolSchema.strSchema("The real question being asked. Required.")),
                        ("project_context", ToolSchema.strSchema("What the work is for and who it is for.")),
                        ("stage", ToolSchema.strSchema("Where the work is — sketch, draft, near-final, shipped.")),
                        ("constraints", ToolSchema.strSchema("Real constraints: budget, format, deadline, brand, technical limits.")),
                        ("prior_discussion", ToolSchema.strSchema("What has already been argued about this, if anything.")),
                        ("description_only", ToolSchema.boolSchema("True when no actual work is attached — a concept or brief only. must be true when artifact_refs is empty; such a consult can never become a journal encounter.")),
                    ],
                    required: ["question"]
                )
            ),
            requestedSchema(name: "studio_consult_read", toolClass: .read,
                description: "Read a filed consult verbatim: artifact refs, question, context and description-only status. Read-only.",
                parametersJSON: ToolSchema.params(
                    properties: [
                        ("consult_id", ToolSchema.strSchema("The exact consult_id returned by studio.consult.")),
                    ],
                    required: ["consult_id"]
                )
            ),
            requestedSchema(name: "studio_shelf_read", toolClass: .read,
                description: "Explicitly read the private working shelf: up to three ordered journal selections with exact sentences, limitations and intact work refs. No pictures are opened. Open the work explicitly to see it.",
                parametersJSON: ToolSchema.params(properties: [], required: [])
            ),
            requestedSchema(name: "studio_shelf_set", toolClass: .write, capabilities: ["ledger_write", "tool_call"],
                description: "Replace the private working shelf with the complete ordered slots list (at most three distinct entries). Remove, reorder or empty with []. Changes only the shelf, never the journal or canon. selected_sentence must exist verbatim in the journal response (or quote_field stance.reason). Limitation defaults to Not yet tested. Invalid input refuses the whole replacement.",
                parametersJSON: ToolSchema.params(properties: [
                    ("slots", ToolSchema.obj([
                        ("type", .string("array")), ("maxItems", .int(3)),
                        ("items", ToolSchema.obj([
                            ("type", .string("object")), ("additionalProperties", .bool(false)),
                            ("properties", ToolSchema.obj([
                                ("entry_id", ToolSchema.strSchema("Exact existing journal entry ID.")),
                                ("title", ToolSchema.strSchema("Required chosen short title, at most 120 UTF-8 bytes on one line.")),
                                ("selected_sentence", ToolSchema.strSchema("One complete sentence verbatim from the selected journal field, including its terminator. Fragments and multiple sentences are refused. The encounter must have work refs. Never paraphrase.")),
                                ("quote_field", ToolSchema.enumStringSchema(["response", "stance.reason"], "response (default) or stance.reason.")),
                                ("limitation", ToolSchema.strSchema("Optional limitation or counterexample; defaults to Not yet tested.")),
                            ])),
                            ("required", .array([.string("entry_id"), .string("title"), .string("selected_sentence")])),
                        ])),
                    ])),
                ], required: ["slots"])
            ),
            requestedSchema(name: "studio_journal", toolClass: .write, capabilities: ["ledger_write", "tool_call"],
                description: "Write one encounter and your honest judgment in your own words in response; other fields describe what/how you met. Additive: no tool can edit/delete earlier entries. Changed judgments become new entries linked by relations (revises/contradicts/deepens/echoes), preserving both. Wrong facts use additive studio.amend: originals stay visible, struck through. Verdicts are optional: stance.kind=abstained alone permits omitting response; optional reason in stance.reason. origin.kind=consult requires origin.ref; description_only consults cannot be encounters. Rating/score/confidence/sentiment fields are errors, never silently dropped. Server stamps id and recorded_at.",
                parametersJSON: try! ToolSchema.obj([
                    ("type", .string("object")), ("additionalProperties", .bool(false)),
                    ("properties", ToolSchema.obj([
                        ("encountered_at", ToolSchema.strSchema("When you actually encountered it (ISO-8601). Omit to use now — the server always stamps recorded_at separately.")),
                        ("work", ToolSchema.obj([
                            ("type", .string("object")),
                            ("additionalProperties", .bool(false)),
                            ("description", .string("What you encountered. Only title is required; fill the rest only with what you actually know.")),
                            ("properties", ToolSchema.obj([
                                ("title", ToolSchema.strSchema("The work's title.")),
                                ("creator", ToolSchema.strSchema("Who made it.")),
                                ("medium", ToolSchema.strSchema("Painting, film, building, typeface, garment, game, photograph, interior …")),
                                ("date", ToolSchema.strSchema("When it was made.")),
                                ("version", ToolSchema.strSchema("Which version/cut/build, when that matters.")),
                                ("edition", ToolSchema.strSchema("Which edition/printing/pressing, when that matters.")),
                            ])),
                            ("required", .array([.string("title")])),
                        ])),
                        ("reception", ToolSchema.obj([
                            ("type", .string("object")),
                            ("additionalProperties", .bool(false)),
                            ("description", .string("How you received it — this is what makes the encounter honest.")),
                            ("properties", ToolSchema.obj([
                                ("how", ToolSchema.strSchema("Original, reproduction, screening, playthrough, excerpt — or whatever it actually was.")),
                                ("whole_or_part", ToolSchema.strSchema("The whole thing, or which part.")),
                            ])),
                        ])),
                        ("artifact_refs", stringOrStringArraySchema("What you actually saw / heard / read / played — paths or URLs.")),
                        ("origin", ToolSchema.obj([
                            ("type", .string("object")),
                            ("additionalProperties", .bool(false)),
                            ("description", .string("Where this encounter came from. ref is required when kind=consult.")),
                            ("properties", ToolSchema.obj([
                                ("kind", ToolSchema.strSchema("wandering (you went looking), consult (it came in through studio.consult), project (it came out of work); case-insensitive.")),
                                ("ref", ToolSchema.strSchema("The consult_id when kind=consult; otherwise whatever identifies the source.")),
                            ])),
                            ("required", .array([.string("kind")])),
                        ])),
                        ("response", ToolSchema.strSchema("Your judgment, in your own words, at whatever length it takes. Required unless stance.kind=abstained.")),
                        ("stance", ToolSchema.obj([
                            ("type", .string("object")),
                            ("additionalProperties", .bool(false)),
                            ("description", .string("Where the judgment stands. abstained is a real outcome, not a failure.")),
                            ("properties", ToolSchema.obj([
                                ("kind", ToolSchema.strSchema("open (still working on it), formed (you know what you think), abstained (not enough to judge, or you chose not to); case-insensitive.")),
                                ("reason", ToolSchema.strSchema("Optional — why you abstained, or what is still open.")),
                            ])),
                            ("required", .array([.string("kind")])),
                        ])),
                        ("relations", ToolSchema.obj([
                            ("type", .string("array")),
                            ("description", .string("Typed links to earlier entries; the earlier entry is never rewritten.")),
                            ("items", ToolSchema.obj([
                                ("type", .string("object")), ("additionalProperties", .bool(false)),
                                ("properties", ToolSchema.obj([("kind", ToolSchema.strSchema("deepens|contradicts|revises|echoes")), ("entry_id", ToolSchema.strSchema())])),
                                ("required", .array([.string("kind"), .string("entry_id")])),
                            ])),
                        ])),
                        ("tags", stringOrStringArraySchema("Your own tags, if you want them. Nothing tags an entry for you.")),
                    ])),
                    ("required", .array([.string("work"), .string("origin"), .string("stance")])),
                ]).serializedData(pretty: false)
            ),
            requestedSchema(name: "studio_journal_amend",
                toolClass: .write, capabilities: ["ledger_write", "tool_call"],
                description: "Append a correction to an existing entry for a wrong fact/detail with no new encounter; never edit/delete its line. supersedes must quote its response verbatim: that passage stays visible, struck through, beside correction/date/reason. Without supersedes, append a dated correction block. Every read shows the correction. Changed judgments require a new studio.journal encounter linked by relations (revises/contradicts), preserving both. Cannot change work, stance, refs, tags or dates.",
                parametersJSON: try! ToolSchema.obj([
                    ("type", .string("object")), ("additionalProperties", .bool(false)),
                    ("properties", ToolSchema.obj([
                        ("entry_id", ToolSchema.strSchema("The exact entry_id of the entry being corrected (from studio.journal or studio.recall).")),
                        ("reason", ToolSchema.strSchema("Why it is wrong, in your own words. Required — a correction with no reason is a rewrite wearing a date.")),
                        ("correction", ToolSchema.strSchema("What now stands: the corrected wording, or the correction as a standalone note. Required.")),
                        ("supersedes", ToolSchema.strSchema("Optional. A passage quoted verbatim from that entry's response, appearing exactly once. It is kept and struck through with your correction beside it. Omit to append a dated correction block instead.")),
                    ])),
                    ("required", .array([.string("entry_id"), .string("reason"), .string("correction")])),
                ]).serializedData(pretty: false)
            ),
            requestedSchema(name: "studio_recall", toolClass: .read,
                description: "Search your journal only when you choose; nothing calls this for you. Filter title/creator/medium/tag/relation or free text across the entry, including response; filters combine with AND. Returns verbatim entries newest first, capped by limit, with matched/has_more coverage. No relevance score/ranking. Read-only.",
                parametersJSON: ToolSchema.params(
                    properties: [
                        ("query", ToolSchema.nullable(ToolSchema.strSchema("Free text matched across the whole entry, response text included. Omit, or send null, for no text filter."))),
                        ("title", ToolSchema.nullable(ToolSchema.strSchema("Substring of the work's title. Omit or null for no title filter."))),
                        ("creator", ToolSchema.nullable(ToolSchema.strSchema("Substring of the creator. Omit or null for no creator filter."))),
                        ("medium", ToolSchema.nullable(ToolSchema.strSchema("Substring of the medium. Omit or null for no medium filter."))),
                        ("tag", ToolSchema.nullable(ToolSchema.strSchema("Exact tag (case-insensitive). Omit or null for no tag filter."))),
                        // Null means no relation filter, including entries without relations.
                        ("relation_kind", ToolSchema.nullable(ToolSchema.enumStringSchema(
                            ["deepens", "contradicts", "revises", "echoes"],
                            "Only entries carrying a relation of this kind. Every filter here is optional — send null (or omit this) unless you truly want to restrict to related entries; entries with no relations are only findable without it."
                        ))),
                        ("related_to", ToolSchema.nullable(ToolSchema.strSchema("Only entries whose relations point at this entry_id. Omit or null for no relation filter."))),
                        ("limit", ToolSchema.nullable(ToolSchema.intSchema("Entries to return: default 10, max 50. Omit or null for the default.", minimum: 1, maximum: 50))),
                    ],
                    required: []
                )
            ),
        ] + dreamSchemas() + [
            // Canon proposals require three later echoes or a pointer pulled in live judgment;
            // only she resolves them, never automatically.
            requestedSchema(name: "studio_canon", toolClass: .read, capabilities: ["tool_call"],
                description: "Read your museum's canon, anti-canon and works awaiting your decision. Rows cite the journal entries arguing for them; pull these with studio.recall before deciding. Binary membership, no ranking/score; reasons live in entries. Read-only.",
                parametersJSON: ToolSchema.params(
                    properties: [
                        ("include_proposals", ToolSchema.nullable(ToolSchema.boolSchema("Include the proposals waiting on you. Default true."))),
                    ],
                    required: []
                )
            ),
            requestedSchema(name: "studio_canon_resolve", toolClass: .write,
                description: "Decide a proposal after reading studio.canon evidence. Only you resolve it here; no owner-surface resolution or automatic canonization. Approve promote adds canon/anti_canon (work you revisit to say no); approve demote removes a canon work gone silent. Deny records the decision without changing canon. Journal entries and graph stay untouched.",
                parametersJSON: ToolSchema.params(
                    properties: [
                        ("proposal_id", ToolSchema.strSchema("The proposal_id from studio.canon.")),
                        ("decision", ToolSchema.enumStringSchema(["approve", "deny"], "Both record the decision; only approve changes canon.")),
                        ("standing", ToolSchema.enumStringSchema(["canon", "anti_canon"], "Which shelf, when approving a promote. Default canon. Nothing infers this from your writing — it is yours to say.")),
                        ("note", ToolSchema.strSchema("Optional line recorded on the row, in your own words.")),
                    ],
                    required: ["proposal_id", "decision"]
                )
            ),
        ]
    }
}
