import Foundation
import Context
import MemoryV2
import CryptoKit
import NativeAgentCore
import PersistenceCore
import ProviderRouting

// MARK: - SessionHistoryMessageProjection (v2Prefix conversation prefix)

/// Prior turns → `[LLMMessage]`, oldest→newest, for the `v2Prefix`
/// conversation shape.
///
/// The whole point of v2 is that the transcript stops riding the DYNAMIC
/// system segment (which churns every turn and therefore can never be cached
/// across turns) and becomes a real message prefix that a provider cache can
/// match byte-for-byte from one turn to the next.
///
/// ADMISSION IS NOT RE-DERIVED. This replays EXACTLY the rows
/// `SessionHistoryPromptRenderer.conversationHistory` admits — same
/// `renderable` filter, same `capForRole`, same
/// `budget(for:windowTokens:)`, same newest-first fill including the
/// compaction-summary reservation — by calling the renderer's own internal
/// helpers. A second, drifting copy of that rule is the one way this change
/// could silently change what the model sees.
///
/// Mapping (deliberately conservative — prior tool rounds have NO provider
/// call ids, so inventing `tool_use`/`tool_result` pairs would be a lie the
/// provider would reject or, worse, accept):
///   - user      → `.user` text
///   - assistant → `.assistant` text, with `<tool_use>` markers STRIPPED
///                 (text-compat transcripts retain literal markers; replaying
///                 one re-injects a call)
///   - tool row  → an extra text block `[tool <name> <status>] <projection>`
///                 appended to the immediately preceding assistant message
///                 (a synthetic assistant message when there is none)
///   - compaction summary → a leading `[session recollection] …` text block on
///                 the OLDEST replayed user message
/// Consecutive same-role rows merge; leading assistant rows are trimmed so
/// `messages[0]` is always `.user`.
enum SessionHistoryMessageProjection {
    struct Result: Sendable {
        /// Oldest → newest. Always starts with a `.user` message (or is empty).
        let messages: [LLMMessage]
        /// Every admitted row reduced to what the window cursor needs —
        /// identity, role, rendered length, anchor/recollection exemption.
        /// Payload-free by construction: no transcript content leaves here.
        let rows: [HistoryWindowRow]
        /// Sum of every rendered row's v1 line length — the number the window
        /// cursor compares against `budget.historyChars`.
        let usedChars: Int
        /// Rows the cursor skipped this turn (already outside the window).
        let droppedRowCount: Int
        /// Run ids of the user turns this prefix actually replays. The volatile
        /// archive is pruned to exactly this set: a block whose position is no
        /// longer in the prefix cannot be replayed into it.
        let replayedRunIds: Set<String>

        var admittedIdentities: [String] { rows.map(\.identity) }

        static let empty = Result(
            messages: [], rows: [], usedChars: 0, droppedRowCount: 0, replayedRunIds: []
        )
    }

    /// Rows pinned at the HEAD regardless of the window cursor. Mirrors the
    /// reader's `anchorLimit: 3` — the opening of a session is what makes the
    /// rest of it legible, so sliding the window never eats it.
    static let anchorLimit = 3

    /// The admitted rows ALONE, without building any message. The window
    /// cursor needs the rows to decide whether to advance, and the projection
    /// needs the cursor's answer — so the admission runs once here and both
    /// halves read it, rather than the projection running twice per turn.
    struct Admission {
        let renderables: [SessionHistoryPromptRenderer.Renderable]
        let budget: ContextBudgetPolicy.Resolved
        let rows: [HistoryWindowRow]
        var usedChars: Int { rows.reduce(0) { $0 + $1.length + 1 } }
    }

    /// v2 ADMISSION — deliberately NOT the v1 rule.
    ///
    /// v1 fills newest-first against `budget.historyChars` and re-runs that
    /// fill every turn. Both halves of that are per-turn moving parts: the
    /// `suffix(historyLimit)` head slides as the session grows, and the
    /// budget fill re-decides where the block starts every time a row's size
    /// changes. Either one rewrites the head of the replayed prefix, which is
    /// precisely what a provider cache cannot survive — so on v2 they are both
    /// gone and the cursor is the ONLY head.
    ///
    /// What remains here: the contiguous range the reader returned, rendered
    /// under the SAME per-row caps (`capForRole`), with the anchors and the
    /// compaction recollection pinned. Size is enforced downstream, and only
    /// by the cursor's hysteresis — rarely, at a turn boundary, oldest-first.
    ///
    /// `historyLimit == 0` still means "no history"; it is the disable switch,
    /// not a window.
    static func admission(
        messages: [ChatMessage],
        historyLimit: Int,
        surface: String,
        windowTokens: Int? = nil
    ) -> Admission? {
        guard max(0, historyLimit) > 0 else { return nil }
        let renderables = messages.compactMap(SessionHistoryPromptRenderer.renderable)
        guard !renderables.isEmpty else { return nil }
        let budget = SessionHistoryPromptRenderer.budget(
            for: surface, windowTokens: windowTokens
        )
        let anchorIdentities = Set(
            renderables
                .filter { $0.role == "user" || $0.role == "assistant" }
                .prefix(anchorLimit)
                .map(\.historyIdentity)
        )
        let rows = renderables.map { row in
            HistoryWindowRow(
                identity: row.historyIdentity,
                role: row.isTool ? "tool" : row.role,
                length: SessionHistoryPromptRenderer
                    .renderedHistoryLine(row, budget: budget).count,
                isAnchor: anchorIdentities.contains(row.historyIdentity),
                isCompactionSummary: row.isCompactionSummary
            )
        }
        return Admission(renderables: renderables, budget: budget, rows: rows)
    }

    static func project(
        messages: [ChatMessage],
        historyLimit: Int,
        surface: String,
        windowTokens: Int? = nil,
        cursor: HistoryWindowCursor? = nil,
        archivedTurnMessages: [String: [LLMMessage]] = [:]
    ) -> Result {
        guard let admission = admission(
            messages: messages,
            historyLimit: historyLimit,
            surface: surface,
            windowTokens: windowTokens
        ) else { return .empty }
        return project(
            admission, cursor: cursor, archivedTurnMessages: archivedTurnMessages
        )
    }

    /// `archivedTurnMessages` (run id → the messages that turn sent after its
    /// user turn, in order) replays each earlier turn's mid-conversation system
    /// messages at THEIR ORIGINAL POSITIONS: immediately after the user message
    /// they followed, before that turn's assistant reply.
    ///
    /// Two kinds ride here and both must stay. The turn-scoped volatile block
    /// is cleared once a later user message arrives — 0 input tokens — but must
    /// remain in `messages`. The `tool_addition`/`tool_removal` message is NOT
    /// turn-scoped at all, and removing an already-sent one invalidates the
    /// prefix from that point.
    ///
    /// This is not an optimization, it is the contract. A cleared turn-scoped
    /// message costs 0 input tokens but must STAY in `messages` byte-for-byte;
    /// omitting it makes turn N+1's prefix diverge from turn N's at the element
    /// right after `user(N)`, so everything from there — the previous turn's
    /// tool rounds and reply included — is re-created at full price.
    ///
    /// Empty by default, so every non-clear_at lane is unchanged.
    static func project(
        _ admission: Admission,
        cursor: HistoryWindowCursor?,
        archivedTurnMessages: [String: [LLMMessage]] = [:]
    ) -> Result {
        var admitted = admission.renderables
        let budget = admission.budget
        let rows = admission.rows
        let usedChars = admission.usedChars
        let identities = rows.map(\.identity)

        // Window cursor: drop the oldest admitted rows through (and including)
        // the recorded boundary. Anchors and the compaction summary are exempt
        // — they are the two row classes whose loss is not recoverable from
        // what remains. A boundary that is not present (compaction rewrote the
        // transcript, or the window already slid past it) drops nothing:
        // fail-open is a bigger prompt, never a lost row.
        var droppedRowCount = 0
        if let boundary = cursor?.dropBoundaryIdentity,
           let boundaryOffset = identities.firstIndex(of: boundary) {
            // THE HEAD IS THE BOUNDARY — nothing is pinned in front of it.
            //
            // Anchors used to be exempt, which produced `anchors ‖ GAP ‖ live
            // window`. The anchors themselves are deterministic (the reader
            // takes the first lines of the transcript file, not
            // relevance-chosen rows), but the row immediately AFTER them is
            // whatever the reader's sliding tail happened to reach back to, so
            // the joint between the two moved as the session grew — and the
            // merge of a trailing anchor into that first live row changed with
            // it. That is a head that differs between requests even while the
            // cursor reports stable.
            //
            // Now the emitted head is exactly the first row after the persisted
            // boundary, so `messages[0]` is a pure function of the cursor. The
            // opening of the session is not lost: `continuityState` carries
            // "Initial anchors: …" in the volatile block, which is where
            // per-turn relevance material belongs anyway.
            //
            // The compaction recollection is the one exception — it is the only
            // surviving record of everything already elided, and it leads the
            // oldest replayed user message rather than standing as a row.
            var kept: [SessionHistoryPromptRenderer.Renderable] = []
            for (offset, row) in admitted.enumerated() {
                if offset <= boundaryOffset, !rows[offset].isCompactionSummary {
                    droppedRowCount += 1
                    continue
                }
                kept.append(row)
            }
            admitted = kept
        }
        guard !admitted.isEmpty else { return .empty }

        var out: [LLMMessage] = []
        var pendingRecollection: String?
        var replayedRunIds = Set<String>()
        // A replayed block is HELD until the turn's assistant reply is emitted.
        // The same wire rule that governs the current turn governs a replayed
        // one: a system message may end the array or precede an assistant turn,
        // never precede a user turn. A turn whose reply is not in the prefix
        // (transient failure, filtered by `renderable`) has no intact position
        // to replay into, and the tail block would sit directly before the
        // CURRENT user message — so both cases drop the block rather than
        // emit an array the provider rejects.
        var pendingReplay: (runId: String, messages: [LLMMessage])?

        func flushPendingReplay() {
            guard let pending = pendingReplay else { return }
            pendingReplay = nil
            out.append(contentsOf: pending.messages)
        }

        func appendText(_ role: LLMMessage.Role, _ text: String) {
            guard !text.isEmpty else { return }
            if let last = out.last, last.role == role {
                out[out.count - 1] = LLMMessage(role: role, content: last.content + [.text(text)])
            } else {
                out.append(LLMMessage(role: role, content: [.text(text)]))
            }
        }

        for row in admitted {
            let body = SessionHistoryPromptRenderer.projectedHistoryText(row, budget: budget)
            if body.isEmpty { continue }
            if row.isCompactionSummary {
                // Held for the oldest replayed USER message rather than
                // emitted as its own turn: a synthetic role here would read as
                // a real exchange that never happened.
                pendingRecollection = row.recollectionLabel + " " + body
                continue
            }
            if row.isTool {
                flushPendingReplay()
                let label = "[tool \(row.toolName ?? "tool") \(row.toolStatus ?? "ran")]"
                if let last = out.last, last.role == .assistant {
                    out[out.count - 1] = LLMMessage(
                        role: .assistant,
                        content: last.content + [.text("\(label) \(body)")]
                    )
                } else {
                    out.append(LLMMessage(
                        role: .assistant, content: [.text("\(label) \(body)")]
                    ))
                }
                continue
            }
            switch row.role {
            case "user":
                pendingReplay = nil
                if let recollection = pendingRecollection {
                    pendingRecollection = nil
                    if let last = out.last, last.role == .user {
                        out[out.count - 1] = LLMMessage(
                            role: .user, content: last.content + [.text(body)]
                        )
                    } else {
                        out.append(LLMMessage(
                            role: .user, content: [.text(recollection), .text(body)]
                        ))
                    }
                } else {
                    appendText(.user, body)
                }
                if let runId = row.runId {
                    replayedRunIds.insert(runId)
                    // Byte-for-byte, in position, exactly once — held until the
                    // reply proves the position is intact.
                    if let replay = archivedTurnMessages[runId], !replay.isEmpty,
                       pendingReplay == nil {
                        pendingReplay = (runId, replay)
                    }
                }
            case "assistant":
                flushPendingReplay()
                // A replayed assistant turn that still carries a literal
                // `<tool_use>` marker would re-issue that call on the next
                // provider read. Strip before it ever reaches the wire.
                appendText(.assistant, ToolCallParser.stripToolUseMarkers(body))
            default:
                // system/summary/unknown rows are not a two-party turn; fold
                // them into the user side rather than inventing a role.
                pendingReplay = nil
                appendText(.user, "[\(row.role)] " + body)
            }
        }

        // The tail block is deliberately dropped: `seed` appends the CURRENT
        // user message next, and a system message directly before it is the
        // exact 400 this shape has to avoid.
        pendingReplay = nil
        // A conversation must open on a user turn: an assistant-first prefix is
        // rejected outright by the Anthropic wire and reads as a hallucinated
        // opening everywhere else. A leading system row would be equally
        // invalid, and the same loop removes it.
        while let first = out.first, first.role != .user {
            out.removeFirst()
        }
        // User, 2026-09-06: a summary-only history dropped the WHOLE
        // recollection here. A backstop compaction can leave the newest raw
        // message as the only survivor, and at turn start that is the current
        // user row, which history reading excludes by run id — so projection
        // sees the summary alone, holds it in pendingRecollection, produces no
        // ordinary message, and returned `.empty` BEFORE the preservation
        // fallback two lines below. The recollection is the session's entire
        // memory of itself; it goes out on a user message of its own.
        if out.isEmpty {
            guard let recollection = pendingRecollection else { return .empty }
            pendingRecollection = nil
            out = [LLMMessage(role: .user, content: [.text(recollection)])]
        }
        // A recollection with no surviving user row to lead still has to be
        // said: prepend it to the first message rather than dropping it.
        if let recollection = pendingRecollection, let first = out.first {
            out[0] = LLMMessage(role: first.role, content: [.text(recollection)] + first.content)
        }
        return Result(
            messages: out,
            rows: rows,
            usedChars: usedChars,
            droppedRowCount: droppedRowCount,
            replayedRunIds: replayedRunIds
        )
    }
}

// MARK: - Mid-conversation tool changes (Anthropic structured lanes)

/// The turn-invariant `tools` array plus this turn's OFFERED delta, for the
/// Anthropic beta `mid-conversation-tool-changes-2026-07-01`.
///
/// WHY: `tools` sits FIRST in Anthropic's hashed prefix (tools → system →
/// messages), so a session load or an idle drop that edits the array
/// invalidates the cache for the WHOLE conversation. The fix is to declare the
/// session's full pinned catalog once, mark every non-floor tool
/// `defer_loading: true`, and express what is actually offered THIS turn as
/// `tool_addition` / `tool_removal` blocks in a `role: "system"` message that
/// sits behind the cache breakpoint.
///
/// NO LEDGER. History is rebuilt from the transcript every turn, so the turn's
/// message re-declares the FULL delta relative to the array's own defaults
/// (floor offered, everything else deferred) rather than a diff against what
/// some earlier turn declared.
///
/// `array` names are INTERNAL tool names; the loop maps them through
/// `ProviderToolNameMap` before they reach the wire.
struct StructuredToolChangePlan: Sendable, Equatable {
    /// The session's FULL pinned catalog, canonical order, byte-stable across
    /// turns. Non-floor entries carry `deferLoading`.
    let array: [LLMToolSchema]
    /// Everything offered to the model at turn start (floor + resident +
    /// pinned MCP + session loads + promotions, minus drops).
    let offered: [String]
    /// Offered − array defaults: the `tool_addition` set.
    let additions: [String]
    /// Array defaults (the always-on floor) withdrawn by policy this turn:
    /// the `tool_removal` set. A deferred tool is withdrawn by simply not
    /// being added, so it never needs a removal block.
    let removals: [String]
    /// RECEIPT: offered names that are not declared in `array`. Referencing
    /// one is a 400, so they are dropped from the addition list and never
    /// sent — recorded here so the drop is observable instead of silent.
    let droppedUnknown: [String]
    /// The session declaration's re-pin counter. The array can only move when
    /// this moves, so the turn trace carries it next to the array fingerprint
    /// and a cache miss is attributable instead of mysterious.
    let declarationGeneration: Int

    var arrayNames: Set<String> { Set(array.map(\.name)) }
}

/// Per-turn binding for the plan above, bound by the STRUCTURED chat turn-start
/// sites around the engine call and read at the tool loop's seeding site.
///
/// Unbound (every text-compat turn, every non-Anthropic provider, every model
/// whose catalog row does not claim the capability, every non-chat caller) →
/// the loop keeps today's churning-tools-array behavior exactly.
enum StructuredToolChangeContext {
    @TaskLocal static var plan: StructuredToolChangePlan?
}

// MARK: - ConversationPrefixSeeding (v2Prefix message assembly)

/// Assembles the provider message array for one turn:
///
///   historyMessages ‖ [volatile block] ‖ [current user message]
///
/// On `.v1Legacy` this is a no-op that returns the exact single-user-message
/// array every lane built before — the rollback arm is byte-identical by
/// construction, not by a parallel code path that has to be kept in sync.
///
/// DELIVERY LADDER for the volatile block. The block has to sit AFTER the
/// cached transcript prefix, and how it can be expressed depends on what the
/// provider can actually encode:
///
///   1. `.system(clearAtNextUserMessage: true)` — the model both supports a
///      mid-conversation system role AND can drop it at the next user turn, so
///      a turn-scoped instruction never becomes permanent transcript.
///   2. `.system(...)` plain — mid-conversation system supported, no clear_at.
///   3. `.system(...)` on the OpenAI OAuth Responses lane, where the adapter
///      encodes it as a `developer` item.
///   4. Leading text block of the CURRENT user message — every provider whose
///      adapter has a TWO-WAY role model and would therefore encode `.system`
///      as ASSISTANT prose (XAI OAuth, OpenAI api-key, Moonshot) and every
///      unknown model. Putting words in her own mouth is a worse failure than
///      losing the cache win, so this rung is the default, not the exception.
enum ConversationPrefixSeeding {
    enum VolatileDelivery: String, Sendable, Equatable {
        /// Mid-conversation system message, dropped by the provider at the
        /// next user turn.
        case systemClearAt
        /// Mid-conversation system message (Responses `developer` included).
        case system
        /// Leading text block of the current user message.
        case userLeadingBlock
        /// Nothing to deliver (empty volatile block, or `.v1Legacy`).
        case none
    }

    /// Providers whose OAuth Responses adapter encodes `.system` as a
    /// `developer` input item — rung 3.
    static func isOpenAIResponsesLane(_ providerId: String?) -> Bool {
        let normalized = (providerId ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "-", with: "_")
        return normalized == "openai_oauth_direct" || normalized == "codex"
    }

    static func delivery(model: String, providerId: String?) -> VolatileDelivery {
        if supportsMidConversationSystemClearAt(forModel: model) { return .systemClearAt }
        if supportsMidConversationSystem(forModel: model) { return .system }
        if isOpenAIResponsesLane(providerId) { return .system }
        return .userLeadingBlock
    }

    /// The current user message exactly as every lane built it before v2.
    static func currentUserMessage(_ ctx: TurnContext) -> LLMMessage {
        ctx.imageBlocks.isEmpty
            ? .user(ctx.userMessage)
            : .userWithImages(ctx.userMessage, images: ctx.imageBlocks)
    }

    struct Seed {
        /// The context to hand the provider. On v2 its `systemSegments.dynamic`
        /// is EMPTY (the bytes moved into `turnVolatileBlock`); on v1 it is the
        /// caller's context, untouched.
        let context: TurnContext
        let messages: [LLMMessage]
        let delivery: VolatileDelivery
        /// Index of the volatile system message, which is the LAST element of
        /// `messages` when one exists. nil when the block folded into the user
        /// turn instead, or when there was nothing volatile to deliver.
        let volatileIndex: Int?
        /// Index of the CURRENT turn's user message. Everything strictly before
        /// it is the cacheable prefix — history through the previous assistant
        /// — which is what `prefixFingerprint` hashes and what the next turn can
        /// reuse. The current user message is per-turn by definition and is
        /// deliberately excluded.
        let currentUserIndex: Int
        /// The shape this seed ACTUALLY produced — not the shape that was
        /// asked for. A `.v2Prefix` request with no replayed history falls back
        /// to the v1 message array, and the adapters read the task-local shape
        /// to choose their wire layout, so the caller must re-bind THIS value
        /// for the rest of the turn or the body and the layout disagree.
        let shape: ConversationPrefixShape
        /// TEXT-COMPAT lane only: the session-loaded tool catalog run was
        /// delivered in the volatile block instead of the cached prefix, so the
        /// prefix's tool contribution is the FLOOR alone (see `telemetry`).
        let textToolCatalogRidesVolatileBlock: Bool
    }

    /// `textToolCatalogAppendix` is the text-compat lane's "Also loaded this
    /// session:" run. Passing it (even as `""`) declares this a TEXT lane: its
    /// tool contract is rendered prose, not a provider tools array, so the
    /// appended rows ride the per-turn volatile block and only the always-on
    /// floor stays in the cached prefix. `nil` (the default, and every
    /// structured/native caller) is the pre-2026-09-01 behavior exactly —
    /// there the provider's own `tools` array is the contract and the
    /// equivalent fix is Anthropic's mid-conversation `tool_addition` content
    /// blocks (follow-up, not this change).
    /// The mid-conversation tool-change message for one turn, or nil when
    /// there is nothing to declare. `additions`/`removals` are PROVIDER names,
    /// already validated against the request's `tools` array by the caller.
    static func toolChangeMessage(
        additions: [String],
        removals: [String]
    ) -> LLMMessage? {
        let changes = additions.map(LLMToolChange.addition)
            + removals.map(LLMToolChange.removal)
        return changes.isEmpty ? nil : .toolChanges(changes)
    }

    /// `toolChanges` is the mid-conversation `tool_addition`/`tool_removal`
    /// message (structured Anthropic lanes only). It goes AFTER the current
    /// user message and BEFORE the turn-scoped volatile block: a turn-scoped
    /// message is text-only and 400s if it carries a tool-change block, and
    /// consecutive system messages are judged as one group, so the pair still
    /// satisfies "follows a user turn, ends the array". nil (every other
    /// caller) is byte-identical to the pre-2026-09-02 shape.
    static func seed(
        _ ctx: TurnContext,
        shape: ConversationPrefixShape,
        textToolCatalogAppendix: String? = nil,
        toolChanges: LLMMessage? = nil
    ) -> Seed {
        // v2 only engages when there IS a replayed prefix to protect. A turn
        // with no prior history (session turn 1, an ephemeral tool turn, any
        // non-chat caller) has nothing to reuse across turns, so relocating its
        // volatile block would be a model-visible move that buys nothing. Those
        // turns stay on the v1 shape, byte for byte.
        guard shape == .v2Prefix, !ctx.historyMessages.isEmpty else {
            // The tool-change message is NOT a v2 feature: on a plan turn the
            // array declares most tools deferred, so dropping the additions
            // here would leave the model holding the floor alone. It still
            // ends the array, directly after the one user message — legal.
            return Seed(
                context: ctx,
                messages: [currentUserMessage(ctx)] + (toolChanges.map { [$0] } ?? []),
                delivery: .none,
                volatileIndex: nil,
                currentUserIndex: 0,
                shape: .v1Legacy,
                // The v1 arm never relocates anything: on that shape the
                // catalog run stays in `stableSuffix` where the layout put it.
                textToolCatalogRidesVolatileBlock: false
            )
        }
        let split = ctx.splittingVolatileBlock(appending: textToolCatalogAppendix ?? "")
        let volatile = split.turnVolatileBlock ?? ""
        var messages = split.historyMessages
        var delivery: VolatileDelivery = .none
        var current = currentUserMessage(split)
        if !volatile.isEmpty {
            delivery = Self.delivery(model: split.modelId, providerId: split.providerId)
            if delivery == .userLeadingBlock {
                // The block leads the CURRENT turn's words. When the merge
                // below folds this into a trailing history user message, the
                // block still sits immediately before those words, which is
                // what the ordering is for.
                current = LLMMessage(role: .user, content: [.text(volatile)] + current.content)
            }
        }

        // WIRE RULE (live 400 on 785d7c42, `messages.28`): a text-carrying
        // system message must IMMEDIATELY FOLLOW a user turn, and must either
        // END the array or be followed by an assistant turn. One followed
        // directly by another user message is rejected outright. So the
        // current user message goes in FIRST and the volatile block goes LAST:
        //
        //     history … ‖ current user ‖ volatile system
        //
        // This is also the better cache layout — the current user turn now sits
        // inside the prefix the next turn replays, instead of behind a system
        // message that has to be re-sent ahead of it.
        //
        // Merge rather than append when history already ends on a user turn
        // (the previous assistant reply was a transient failure and was filtered
        // out of the projection): two consecutive user messages are their own
        // 400, and this is the only place that adjacency can appear.
        let currentUserIndex: Int
        if let last = messages.last, last.role == .user {
            messages[messages.count - 1] = LLMMessage(
                role: .user, content: last.content + current.content
            )
            currentUserIndex = messages.count - 1
        } else {
            currentUserIndex = messages.count
            messages.append(current)
        }

        // Tool changes first, turn-scoped volatile block last: the volatile
        // block is the one that must END the array to render.
        if let toolChanges { messages.append(toolChanges) }

        var volatileIndex: Int?
        switch delivery {
        case .systemClearAt:
            volatileIndex = messages.count
            // Ends the array, so it always renders — and the provider clears it
            // as soon as a later user message exists.
            messages.append(.system(volatile, clearAtNextUserMessage: true))
        case .system:
            volatileIndex = messages.count
            messages.append(.system(volatile))
        case .userLeadingBlock, .none:
            break
        }

        return Seed(
            context: split,
            messages: messages,
            delivery: delivery,
            volatileIndex: volatileIndex,
            currentUserIndex: currentUserIndex,
            shape: .v2Prefix,
            textToolCatalogRidesVolatileBlock: textToolCatalogAppendix != nil
        )
    }

    /// Append user-role text to a seeded conversation without ever producing a
    /// shape the wire rejects.
    ///
    /// TWO adjacencies are fatal here, and this is the one helper that knows
    /// both: two consecutive user messages, and a user message placed directly
    /// after the volatile system message. Since v2 ends the seeded array with
    /// that system message, an empty-reply nudge appended naively lands in
    /// exactly the second case — on the recovery path, which is when a second
    /// failure costs most.
    ///
    /// Rule: walk back over any trailing system run, then merge into the user
    /// message in front of it, or insert a new one at that position. With no
    /// trailing system run this is byte-identical to the previous
    /// merge-into-trailing-user-else-append behavior, so `.v1Legacy` is
    /// unchanged.
    static func appendUserText(_ text: String, to conversation: inout [LLMMessage]) {
        var insertAt = conversation.count
        while insertAt > 0, conversation[insertAt - 1].role == .system { insertAt -= 1 }
        if insertAt > 0, conversation[insertAt - 1].role == .user {
            let target = conversation[insertAt - 1]
            conversation[insertAt - 1] = LLMMessage(
                role: .user, content: target.content + [.text(text)]
            )
        } else {
            conversation.insert(.user(text), at: insertAt)
        }
    }

    /// PERMANENT DIAGNOSTIC: a short digest of ONE message — its role plus its
    /// serialized content — so head drift is visible in the trace.
    ///
    /// Sizes are blind to this failure: two different first messages have the
    /// same length, so `historyMessageChars` looks stable while the provider
    /// re-reads everything. Twelve hex characters is enough to compare two
    /// turns' rows by eye and far too little to reconstruct content from.
    static func messageDigest(_ message: LLMMessage) -> String {
        var hasher = SHA256()
        func feed(_ label: String, _ data: Data) {
            hasher.update(data: Data("\(label.utf8.count):\(label)\(data.count):".utf8))
            hasher.update(data: data)
        }
        feed("role", Data(message.role.rawValue.utf8))
        feed("clearAt", Data(String(message.turnScopedClearAtNextUserMessage).utf8))
        for change in message.toolChanges {
            feed("change." + change.kind.rawValue, Data(change.name.utf8))
        }
        for (index, block) in message.content.enumerated() {
            switch block {
            case .text(let text):
                feed("b\(index).text", Data(text.utf8))
            case .toolUse(let id, let name, let inputJSON):
                feed("b\(index).toolUse.id", Data(id.utf8))
                feed("b\(index).toolUse.name", Data(name.utf8))
                feed("b\(index).toolUse.input", inputJSON)
            case .toolResult(let toolUseId, let content, let isError):
                feed("b\(index).toolResult.id", Data(toolUseId.utf8))
                feed("b\(index).toolResult.content", Data(content.utf8))
                feed("b\(index).toolResult.error", Data(String(isError).utf8))
            case .image(let mediaType, let base64, let name, let byteSize):
                feed("b\(index).image.mediaType", Data(mediaType.utf8))
                feed("b\(index).image.base64", Data(base64.utf8))
                feed("b\(index).image.name", Data((name ?? "").utf8))
                feed("b\(index).image.byteSize", Data(String(max(0, byteSize)).utf8))
            }
        }
        return String(hasher.finalize().map { String(format: "%02x", $0) }.joined().prefix(12))
    }

    /// How many leading messages carry a digest. Six covers the head — where
    /// drift actually shows — without turning a trace row into a transcript.
    static let messageDigestCount = 6

    /// SHA-256 over everything that must be byte-identical from one turn to the
    /// next for a provider prefix cache to hit: the stable segments, the tool
    /// contract, and every message STRICTLY BEFORE the volatile block.
    ///
    /// Sizes and digests only — no prompt content ever leaves this function.
    static func prefixFingerprint(
        stable: String,
        stableSuffix: String,
        toolSchemaFingerprint: String,
        messagesBeforeVolatile: [LLMMessage]
    ) -> String {
        var hasher = SHA256()
        func feed(_ label: String, _ data: Data) {
            hasher.update(data: Data("\(label.utf8.count):\(label)\(data.count):".utf8))
            hasher.update(data: data)
        }
        feed("stable", Data(stable.utf8))
        feed("stableSuffix", Data(stableSuffix.utf8))
        feed("tools", Data(toolSchemaFingerprint.utf8))
        for (index, message) in messagesBeforeVolatile.enumerated() {
            feed("m\(index).role", Data(message.role.rawValue.utf8))
            for (blockIndex, block) in message.content.enumerated() {
                let prefix = "m\(index).b\(blockIndex)"
                switch block {
                case .text(let text):
                    feed(prefix + ".text", Data(text.utf8))
                case .toolUse(let id, let name, let inputJSON):
                    feed(prefix + ".toolUse.id", Data(id.utf8))
                    feed(prefix + ".toolUse.name", Data(name.utf8))
                    feed(prefix + ".toolUse.input", inputJSON)
                case .toolResult(let toolUseId, let content, let isError):
                    feed(prefix + ".toolResult.id", Data(toolUseId.utf8))
                    feed(prefix + ".toolResult.content", Data(content.utf8))
                    feed(prefix + ".toolResult.error", Data(String(isError).utf8))
                case .image(let mediaType, let base64, let name, let byteSize):
                    feed(prefix + ".image.mediaType", Data(mediaType.utf8))
                    feed(prefix + ".image.base64", Data(base64.utf8))
                    feed(prefix + ".image.name", Data((name ?? "").utf8))
                    feed(prefix + ".image.byteSize", Data(String(max(0, byteSize)).utf8))
                }
            }
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// One labelled component digest. Same length-prefixed feed as
    /// `prefixFingerprint` so a component hash cannot be confused with a
    /// concatenation of its neighbours. Sizes and digests only.
    static func componentFingerprint(_ label: String, _ parts: [String]) -> String {
        var hasher = SHA256()
        hasher.update(data: Data("\(label.utf8.count):\(label)".utf8))
        for part in parts {
            let bytes = Data(part.utf8)
            hasher.update(data: Data("\(bytes.count):".utf8))
            hasher.update(data: bytes)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// One redacted, capped, single-line preview of conversation text for a
    /// trace row. User, 2026-09-06: redaction runs on the WHOLE string before
    /// the cap, so a secret that starts inside the kept window cannot survive
    /// as a half-matched tail.
    static func tracePreview(_ text: String, limit: Int) -> String {
        String(
            NativeAgentSecretRedactor.redactText(text)
                .replacingOccurrences(of: "\n", with: " ")
                .prefix(limit)
        )
    }

    /// Fingerprint + size receipts for one seeded turn, published to the turn
    /// trace and the `llm.call` row. Payload-free.
    /// The window facts come off the CONTEXT, not from the caller: the cursor
    /// ran ONCE, inside the context build, and every seeding site has to report
    /// that same decision rather than re-reading it from disk or passing a
    /// placeholder that quietly disagrees with it.
    static func telemetry(
        _ seed: Seed,
        shape: ConversationPrefixShape,
        toolSchemaFingerprint: String,
        toolChangePlan: StructuredToolChangePlan? = nil
    ) -> ConversationPrefixTelemetrySnapshot {
        // "What the next turn can reuse": history through the previous
        // assistant. The CURRENT user message is per-turn content and is
        // excluded — including it would make the fingerprint change every turn
        // by construction and measure nothing.
        let before = Array(seed.messages.prefix(seed.currentUserIndex))
        let segments = seed.context.systemSegments
        // TEXT-COMPAT lane: only the always-on FLOOR is inside the cached
        // prefix — the session-loaded run rides the volatile block. Hashing the
        // whole schema set here would report a moved prefix on every
        // tool_load/promotion the layout deliberately stopped moving, which is
        // the instrument lying about the exact fix it is measuring.
        let prefixToolFingerprint = seed.textToolCatalogRidesVolatileBlock
            ? SwiftNativeTurnEngine.toolSchemaFingerprint(
                seed.context.toolSchemas.filter {
                    SwiftToolDispatcher.alwaysOnCoreNames.contains($0.name)
                }
            )
            : toolSchemaFingerprint
        return ConversationPrefixTelemetrySnapshot(
            shapeVersion: shape.rawValue,
            prefixFingerprintSHA256: prefixFingerprint(
                stable: segments?.stable ?? seed.context.systemPrompt ?? "",
                stableSuffix: segments?.stableSuffix ?? "",
                toolSchemaFingerprint: prefixToolFingerprint,
                messagesBeforeVolatile: before
            ),
            historyMessageCount: seed.context.historyMessages.count,
            historyMessageChars: seed.context.historyMessages.reduce(0) { total, message in
                total + message.content.reduce(0) {
                    if case .text(let text) = $1 { return $0 + text.count }
                    return $0
                }
            },
            volatileBlockChars: seed.context.turnVolatileBlock?.count ?? 0,
            volatileDelivery: seed.delivery.rawValue,
            windowCursorAdvanceCount: seed.context.historyWindowReceipt?.advanceCount ?? 0,
            windowSlid: seed.context.historyWindowReceipt?.slid ?? false,
            messageCount: seed.messages.count,
            messageDigests: seed.messages.prefix(messageDigestCount).map(messageDigest),
            toolChanges: toolChangePlan.map {
                .init(
                    arrayFingerprintSHA256: SwiftNativeTurnEngine
                        .toolSchemaFingerprint($0.array),
                    offeredCount: $0.offered.count,
                    additionCount: $0.additions.count,
                    removalCount: $0.removals.count,
                    droppedUnknownCount: $0.droppedUnknown.count,
                    declarationGeneration: $0.declarationGeneration
                )
            },
            prefixMessageDigests: before.map(messageDigest),
            // REQUEST-COMPONENT FINGERPRINTS (A3 2026-09-11). The whole-prefix
            // hash moves every turn by construction, which left the 2026-09-11
            // audit inferring "probably the tools array" from schema COUNTS.
            // These three name the component that actually moved.
            stablePrefixFingerprintSHA256: Self.componentFingerprint(
                "stablePrefix",
                [segments?.stable ?? seed.context.systemPrompt ?? "", segments?.stableSuffix ?? ""]
            ),
            toolsFingerprintSHA256: prefixToolFingerprint,
            historyHeadFingerprintSHA256: Self.componentFingerprint(
                "historyHead",
                before.prefix(4).map(messageDigest)
            ),
            // User, 2026-09-06: these previews are RAW CONVERSATION TEXT and they
            // ride into the `llm.call` trace row and the persisted telemetry
            // file, which the rest of this payload deliberately keeps to
            // counts/timings/identifiers. A key or token pasted into the first
            // messages was copied there verbatim. Every preview now goes
            // through the canonical redactor (the one inner_state uses,
            // [REDACTED_*]) BEFORE truncation — truncating first would cut a
            // secret in half and leave the tail unmatched — and the caps are
            // shorter: this is a prefix-shape probe, not a transcript.
            headPreviews: (before.prefix(4).map { message in
                let text = message.content.compactMap { block -> String? in
                    if case .text(let t) = block { return t }
                    return nil
                }.joined(separator: " ")
                return "\(message.role.rawValue): " + Self.tracePreview(text, limit: 64)
            }) + (before.count > 1 ? before[1].content.prefix(16).enumerated().map { index, block -> String in
                if case .text(let t) = block {
                    return "m1.\(index)[\(t.count)]: " + Self.tracePreview(t, limit: 48)
                }
                return "m1.\(index): <non-text>"
            } : []) + [],
        )
    }
}
