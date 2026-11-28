import NativeAgentCore
import PersistenceCore
import MacNerves
import NativeAgentShared
import DeskCore
import SenseCore
import Foundation
import ProviderRouting
import MindCore
// Blueprint: | `AppActions+MindGroup.swift` | Mind action declarations |

struct MemoryRootArguments: DoorObjectSchema {
    static let howField = DoorFieldDescriptor.string("how", required: true)
    static let byField = DoorFieldDescriptor.string("by")
    static let sinceField = DoorFieldDescriptor.string("since")
    static let doorFields = NonEmptyFields(howField, byField, sinceField)
    let how: String
    let by: String?
    let since: String?

    init(door: inout DoorObjectDecoder) throws(DoorDecodeError) {
        guard let how = try door.string(Self.howField) else { throw DoorDecodeError(path: "$.how", accepted: "a string") }
        self.how = how
        by = try door.string(Self.byField)
        since = try door.string(Self.sinceField)
    }
}

extension AppActions {
    static func mindGroup() -> [AppAction] {
        [
        AppAction("history.clear", "trust", "Delete all recorded activity", irreversible: true,
                  capabilities: [.appDataWrite, .safeRead, .toolCall], tool: "upkeep", input: verb("activity_wipe")),
        AppAction("embeddings.pause", "settings", "Pause the memory-search download", tool: "upkeep",
                  input: verb("embeddings_pause")),
        AppAction("embeddings.resume", "settings", "Resume the memory-search download", tool: "upkeep",
                  input: verb("embeddings_resume")),
        AppAction("memory.reindex", "memories", "Spotlight reindex", tool: "upkeep", input: verb("spotlight_reindex")),
        AppAction("memory.list", "memories", "List memories with exact total and remaining counts; follow next_after_id only for more entries. "
                  + "sort newest_first or oldest_first; status active or archived; pinned true for only the pinned ones, false for the rest. "
                  + "Archived entries include what replaced them",
                  [.optional("status"), .optional("sort"), .optional("offset", .integer), .optional("after_id"), .optional("limit", .integer), .optional("kind"), .optional("pinned", .boolean)],tool: "list_memories",
                  read: true),
        AppAction("memory.rewrite", "memories", "Rewrite, pin, unpin or restore a memory, or restate its roots: how, from whom and since when you know it",
                  [.required("id"), .optional("text"), .optional("pinned", .boolean), .optional("restore", .boolean), .optional("reason"), .optional("roots", .objects(MemoryRootArguments.self, spelling: "[{how,by?,since?}]"))], subject: ["id"],
                  capabilities: [.memoryWrite, .toolCall], warn: "text is the thing itself, one or two sentences, no date, source, ids or preamble; "
                      + "a restore that matches something forgotten stays archived; roots restates every root of yours in one call, one per telling: "
                      + "how is told, noticed, inferred, verified or remembered, by who told you or where your own past was kept, since when you "
                      + "first knew it (an ISO-8601 date-time or date). In a peer-steered Ask, each stated root needs how told and by one attested peer "
                      + "(peer ID, raw ID or unambiguous contact name), without since. Carried roots stay as they are. A rewrite that changes nothing writes nothing",
                  // Rewrites and restores need versions because they can overwrite another conversation's correction; commit supersedes is idempotent.
                  tool: "rewrite_memory"),
        AppAction("memory.pin", "memories", """
            Pin a fact about the owner (identity, location, employment, schedule, preference, relationship, attribute) to your prompt core, in pin order; \
            moments stay in recall
            """, [.required("id")], subject: ["id"],
                  capabilities: [.memoryWrite, .toolCall], tool: "rewrite_memory", input: ["pinned": .bool(true)]),

        AppAction("mind.dream", "personality", "Run a dream pass", tool: "mind_run", input: verb("dream")),
        AppAction("mind.sleep", "personality", "Sleep now: a dream pass, the night's reading, a thought if it asks", tool: "mind_run", input: verb("sleep")),
        AppAction("mind.canon", "diagnostics", "Tend studio canon now; skip its clock wait, retain proposal and seat gates", tool: "mind_run", input: verb(
            "canon")),
        AppAction("mind.horizon", "diagnostics", "Refresh horizon expectations now from current sources", tool: "mind_run", input: verb("horizon")),
        AppAction("mind.rhythm", "diagnostics", """
            Read the person's day now with the standing-time boundary satisfied; keep real history and care admission
            """, tool: "mind_run", input: verb("rhythm")),
        AppAction("mind.maintenance", "diagnostics", "Run the checked substrate maintenance now, satisfying only its interval", tool: "mind_run", input: verb(
            "maintenance")),
        AppAction("mind.residual_repair", "diagnostics", "Run eligible bounded residual repair now, satisfying only its quiet wait", tool: "mind_run",
            input: verb("residual_repair")),
        AppAction("mind.rem", "personality", "Run a REM pass now, skipping its weekly wait; Trust and one run at a time still gate it", [.optional("repair", .boolean)], tool: "mind_run", input: verb("rem")),
        AppAction("mind.misses", "today", "Your misses: corrections by lesson, this week against last, each with its history locator",
                 tool: "mind_run", input: verb("misses"), read: true),
        AppAction("mind.think_now", "diagnostics", "Think now", tool: "mind_run", input: verb("think_now")),
        AppAction("mind.body", "personality", """
            Your body: each organ's latest beat, its why and when it beats next, with what broke from its record first; the same lines as Doctor's Body
            """, tool: "mind_run", input: verb("body"), read: true),
        AppAction("mind.why", "personality", "Why a felt cue or memory surfaced on a turn (default: latest recorded completed turn)",
                  [.optional("turn")],tool: "mind_run", input: verb("why"), read: true),
        AppAction("mind.night", "personality", """
            The night's reading of your parts, as numbers and ids: open trials' verdicts, and the parts whose surprise rose above their own record \
            (since: ISO time, default 24 hours ago)
            """, [.optional("since")], tool: "mind_run", input: verb("night"), read: true),
        AppAction("mind.reject", "personality",
                  "Stop a memory, care or dream phrase surfacing for this kind of thing (source from mind.why)",
                  [.required("source"), .optional("turn"), .optional("always", .boolean)], tool: "mind_run", input: verb("reject")),
        AppAction("mind.undo", "personality",
                  "Undo an undertone nudge of yours; no item lists them",
                  [.optional("item")], tool: "mind_run", input: verb("undo")),
        AppAction("mind.reflect", "diagnostics", "Reflect", tool: "mind_run", input: verb("reflect")),
        AppAction("mind.workspace", "cognition", "Include or leave out the workspace in thinking", [.required("value", .boolean)],
                  tool: "mind_run", input: verb("workspace")),
        AppAction("mind.settle_body", "diagnostics", "Settle your body state (calm down when wound up)", tool: "mind_run", input: verb("settle_body")),
        AppAction("mind.reset_body", "diagnostics", "Reset body", tool: "mind_run", input: verb("reset_body")),
        AppAction("mind.pin_concern", "diagnostics", """
            Keep a concern open in your cares: care names the care it belongs to in its own words, omitted it is a care of its own; omitted concern uses what \
            presses most
            """, [.optional("concern"), .optional("care")], tool: "mind_run", input: verb("pin_concern")),
        AppAction("mind.clear", "diagnostics", "Clear the thought store",
                  irreversible: true, capabilities: [.appDataWrite, .safeRead, .toolCall], tool: "mind_run", input: verb("clear")),
        ]
    }
}
