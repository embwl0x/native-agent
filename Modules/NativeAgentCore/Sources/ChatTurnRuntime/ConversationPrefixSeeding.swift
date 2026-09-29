import ChatToolParsing
import Privacy
import Foundation
import Context
import MemoryV2
import CryptoKit
import NativeAgentCore
import PersistenceCore
import ProviderRouting

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
        // v2 engages from session turn 1 (User 09-29, prompt cache): the tools and
        // stable system prompt are identical across turns and sessions, so turn 1
        // both reads them from cache and leaves them for turn 2 to read. On the
        // v1 shape turn 1's system carried the volatile block and turn 2 missed.
        guard shape == .v2Prefix else {
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
