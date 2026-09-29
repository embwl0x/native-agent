import ChatToolParsing
import Foundation
import Dispatcher
import NativeAgentCore
import PersistenceCore
import MemoryV2
import ProviderRouting
import MacIntegration
import Context

// MARK: - Tool-dispatch loops

// Context is prepared once. Each iteration parses provider output, dispatches
// through the injected tool client, and returns tool results to the provider.
// Tool errors remain model-visible feedback. The loop itself lives in
// ChatOrchestration+StreamingToolLoop.swift; its dispatch, completion, and
// exhaustion segments are below.

/// `tool_load` mutates the session's authorized loadout during a turn. The
/// structured loops must append those schemas before the next provider call;
/// otherwise the model can see the returned schema text but cannot emit a
/// native tool call until a later user turn. Existing schemas stay in place so
/// provider aliases already present in the conversation remain stable.
enum SameTurnToolSchemaRefresh {
    static func afterLoad(
        current: [LLMToolSchema],
        sessionId: String?,
        tools: any ToolDispatchClient,
        activeToolsStore: ActiveToolsStore
    ) async throws -> [LLMToolSchema] {
        let session = (sessionId ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !session.isEmpty else { return current }
        // A throw here used to keep the old array, so the loaded tool was
        // described to the model but never callable. It fails the turn instead.
        let available: [LLMToolSchema]
        do {
            available = try await tools.listAvailableToolSchemas()
        } catch {
            try Task.checkCancellation()
            throw TurnEngineError.toolCatalogLoadFailed(underlying: error)
        }

        let loadout = try await activeToolsStore.load(sessionId: session)
        let active = loadout.activeTools.union(LLMCallContext.turnActiveTools ?? [])
        let allowed = SwiftToolDispatcher.normalModelToolNames(activeTools: active)
        var known = Set(current.map(\.name))
        var refreshed = current
        var additions: [String: LLMToolSchema] = [:]
        for schema in available where !known.contains(schema.name) {
            guard schema.name.hasPrefix("mcp__") || allowed.contains(schema.name) else { continue }
            additions[schema.name] = loadout.pinnedSchemas[schema.name]?.schema(named: schema.name) ?? schema
            known.insert(schema.name)
        }
        // Match turn-start order, including a multi-name load's persisted order.
        // Catalog enumeration must not reorder these slots on the next turn.
        let order = SwiftToolDispatcher.canonicalToolOrder(
            available.map(\.name).filter { additions[$0] != nil },
            loadOrder: loadout.advertisedLoadOrder
        )
        refreshed.append(contentsOf: order.advertised.compactMap { additions[$0] })
        return refreshed
    }

    /// PLAN LANE (Anthropic mid-conversation tool changes). The `tools` array
    /// is TURN-INVARIANT there — growing it mid-turn is exactly the prefix
    /// rewrite the whole lane exists to stop — so a `tool_load` is expressed
    /// as a `tool_addition` message instead. Everything the model could load
    /// is already declared in the array, so this only has to work out which
    /// declared names became OFFERED, in array order.
    static func newlyOfferedNames(
        plan: StructuredToolChangePlan,
        alreadyOffered: Set<String>,
        sessionId: String?,
        activeToolsStore: ActiveToolsStore
    ) async throws -> [String] {
        let session = (sessionId ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !session.isEmpty else { return [] }
        let persisted = try await activeToolsStore.load(sessionId: session).activeTools
        let active = persisted.union(LLMCallContext.turnActiveTools ?? [])
        let allowed = SwiftToolDispatcher.normalModelToolNames(activeTools: active)
        let declared = plan.arrayNames
        return plan.array.map(\.name).filter {
            allowed.contains($0) && declared.contains($0) && !alreadyOffered.contains($0)
        }
    }

    static let placeOpeningTools: Set<String> = [
        "workspace", "browser.chrome_navigate", "browser.chrome_acquire",
    ]

    static func wasRequested(
        calls: [ParsedToolCall],
        providerTools: ProviderToolNameMap
    ) -> Bool {
        calls.contains { call in
            let name = CanonicalToolNameDispatcher.canonical(providerTools.internalName(forProviderName: call.name))
            if name == "tool_load" { return true }
            // Her-screen Phase 3: opening a place or a page loads its tools
            // inside the call, so the next provider call must offer them.
            if placeOpeningTools.contains(name) { return true }
            guard name == "tool_catalog" || name == "list_tools" else { return false }
            if call.input["load"] == .bool(true) { return true }
            if case .string(let raw)? = call.input["load"] {
                return raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "true"
            }
            return false
        }
    }
}

// MARK: - Lazy tool filtering

extension TurnContext {
    /// Copy of this context with only `toolSchemas` replaced. The ONE
    /// manual-copy site for the 15 let-only fields — every lazy-filter rebuild
    /// routes through here so a newly added TurnContext field can't be silently
    /// dropped by a hand-inlined 15-field copy (the field-drop trap C3 closes).
    func withToolSchemas(_ newSchemas: [LLMToolSchema]) -> TurnContext {
        TurnContext(
            surface: surface,
            personaID: personaID,
            personaDocs: personaDocs,
            recalled: recalled,
            modelId: modelId,
            reasoningEffort: reasoningEffort,
            providerId: providerId,
            serviceTier: serviceTier,
            toolsAvailable: toolsAvailable,
            systemPrompt: systemPrompt,
            userMessage: userMessage,
            toolSchemas: newSchemas,
            systemSegments: systemSegments,
            imageBlocks: imageBlocks,
            fluidContextTurn: fluidContextTurn,
            naturalExpressionCue: naturalExpressionCue,
            historyMessages: historyMessages,
            turnVolatileBlock: turnVolatileBlock,
            historyWindowReceipt: historyWindowReceipt
        )
    }
}

extension SwiftNativeTurnEngine {
    /// Derive the session's active-tools set (persisted ∪ turn-local; fail
    /// closed to turn-local only on an empty/nil session) and return `ctx` with
    /// its toolSchemas lazy-filtered to `alwaysOnCore ∪ active` (MCP schemas
    /// always pass). Single owner of the `persisted.union(turnActiveTools)`
    /// derivation + the filter + the rebuild that the structured loop and
    /// `streamTurn` used to hand-inline. Byte-identical to those inlines.
    /// `nonisolated` because it only reads the `activeToolsStore` `let`,
    /// task-locals, and pure statics — callable from `streamTurn`'s nonisolated
    /// task without an actor hop.
    nonisolated func lazyFilteredTurnContext(
        _ ctx: TurnContext,
        sessionId: String?,
        pinnedActiveTools: Set<String>? = nil,
        pinnedContract: SessionToolContract? = nil
    ) async throws -> TurnContext {
        // pinnedActiveTools (2026-08-13, turn-context-iteration-cache): the
        // text-compat marker lane rebuilds context per tool iteration, and a
        // fresh ActiveToolsStore read here after a mid-turn `tool_load` grows
        // the tool catalog INSIDE the stable cache-breakpointed system
        // segment — byte-diff-proven to kill the Anthropic prefix cache for
        // the rest of the turn (369k cache-creation tokens on one live turn).
        // A caller that pins passes its turn-start set: the advertised
        // catalog stays byte-stable for the whole turn. Dispatchability is
        // NOT reduced — the lazy dispatch gate re-reads the store per call,
        // and tool_load's result already carries the loaded schemas
        // (schemas_added), so the model can use a just-loaded tool
        // immediately. Callers that need next-iteration list refresh pass nil
        // and keep the store read.
        //
        // The CONTRACT is pinned for the whole turn on a pinned lane, exactly
        // like the active set. Re-reading the store per iteration was a
        // mid-turn shrink: `tool_unload(A)` (or an idle drop landing between
        // iterations) removed A's row, so the next iteration advertised a
        // SHORTER catalog inside the cache-breakpointed stable segment and
        // killed the prefix for the rest of the turn. Every contract change —
        // unloads included — now takes effect at the NEXT turn start.
        let trimmedSession = (sessionId ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let contract: SessionToolContract?
        let active: Set<String>
        if let pinnedActiveTools {
            contract = pinnedContract
            active = pinnedActiveTools.union(LLMCallContext.turnActiveTools ?? [])
        } else if !trimmedSession.isEmpty {
            let loadout = try await activeToolsStore.load(sessionId: trimmedSession)
            contract = loadout.toolContract
            active = loadout.activeTools.union(LLMCallContext.turnActiveTools ?? [])
        } else {
            contract = nil
            active = LLMCallContext.turnActiveTools ?? []
        }
        return SwiftNativeChatOrchestrationClient.applyLazyToolFilter(
            to: ctx,
            activeTools: active,
            contract: contract
        ) ?? ctx
    }
}

// MARK: - Loop

extension SwiftNativeTurnEngine {
    // MARK: - Turn-loop segments
    // Context, completion, dispatch and exhaustion. Provider calls stay in the
    // loop, which owns live deltas and protocol-buffer cleanup.

    /// Empty replies leave no assistant message. Append the nudge through
    /// the shared prefix owner so it preserves Anthropic role adjacency.
    static func appendStructuredUserNudge(_ text: String, to conversation: inout [LLMMessage]) {
        ConversationPrefixSeeding.appendUserText(text, to: &conversation)
    }

    /// Shared pre-loop context resolution. Prefer a caller-provided context
    /// (e.g. one already threaded with session history); otherwise build a fresh
    /// per-turn context AND lazy-filter ctx.toolSchemas through the session's
    /// active-tools set so the no-preBuiltContext path can't expose the full
    /// eager catalog. Then fire the context-snapshot event.
    func resolveToolLoopContext(
        surface: String,
        userMessage: String,
        sessionId: String?,
        runId: String?,
        preBuiltContext: TurnContext?
    ) async throws -> TurnContext {
        if let preBuiltContext {
            // This is the production structured-chat shape. Its context already
            // contains the chosen persona, threaded history/session digest, and
            // cognitive capsule, and has already received its turn-scoped lazy
            // tool filter. Rebuilding here would silently discard those inputs.
            Self.fireContextSnapshotEvent(
                surface: surface,
                context: preBuiltContext,
                sessionId: sessionId,
                runId: runId
            )
            return preBuiltContext
        }
        let rawCtx = try await buildTurnContext(
            surface: surface,
            userMessage: userMessage,
            personaOverride: nil,
            imageBlocks: [],
            sessionID: sessionId
        )
        // Apply lazy-load filter (C3 shared helper):
        //   - non-empty sessionId: alwaysOnCore + sessionActive + MCP
        //   - empty/nil sessionId: alwaysOnCore + MCP only (fail closed)
        let ctx = try await lazyFilteredTurnContext(rawCtx, sessionId: sessionId)
        Self.fireContextSnapshotEvent(
            surface: surface,
            context: ctx,
            sessionId: sessionId,
            runId: runId
        )
        return ctx
    }

    /// Shared terminal for a loop iteration that produced a final reply (no
    /// executable tool calls): record the completed outcome, run the realtime
    /// memory-promotion side channel (production chat goes through this loop, so
    /// without it AdaptiveMemoryPromoter never sees the user/assistant pair), and
    /// build the TurnEngineResult. `rawLLMResponse` is the turn's accumulated
    /// raw output.
    func finishCompletedTurn(
        reply: String,
        ctx: TurnContext,
        dispatches: [TurnEngineResult.ToolDispatchRecord],
        startNs: UInt64,
        rawLLMResponse: String,
        providerCallCount: Int,
        userMessage: String,
        sessionId: String?,
        surface: String,
        workingCommentaryCharacters: Int? = nil
    ) async -> TurnEngineResult {
        // An assistant row is NEVER blank. A completed turn whose reply trims
        // to nothing persisted an empty bubble under the receipts — the
        // "Looked something up · 8 of 12 failed" card with no sentence beside
        // it. The streaming lane's empty-reply bounce is capped at two and
        // accepts the third empty text as final, so a blank still reaches
        // here; this is the one place every completed turn passes through.
        let reply = reply.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? ToolLoopExhaustion.emptyReply(
                dispatchCount: dispatches.count,
                providerRounds: providerCallCount
            )
            : reply
        let recalledIds = ctx.resolvedRecalledIds
        await ctx.fluidContextTurn?.recordOutcome(.completed)
        // NOT run here (Astra audit 2, finding 4, 2026-09-11): this used to hold
        // the TurnEngineResult — and therefore the caller's assistant-row persist
        // and output milestone — for the whole promotion, 8-10 s on live bridge
        // turns. This only CAPTURES the promotion's inputs; the caller's
        // `startDeferredMemoryPromotion(ticket:)` starts it once the assistant
        // row is durable, so the work is deferred behind the append, not dropped.
        // The ticket rides home on the result: it is what makes the start
        // per-turn instead of "whatever this actor last captured" (Astra comb 3
        // review, finding 1, 2026-09-12).
        let promotionTicket = deferMemoryPromotion(
            userMessage: userMessage,
            assistantMessage: reply,
            toolDispatches: dispatches,
            sessionId: sessionId,
            surface: surface
        )
        let endNs = DispatchTime.now().uptimeNanoseconds
        let elapsedMs = Int((endNs &- startNs) / 1_000_000)
        return TurnEngineResult(
            reply: reply,
            modelUsed: ctx.modelId,
            recalledIds: recalledIds,
            toolDispatches: dispatches,
            elapsedMs: elapsedMs,
            rawLLMResponse: rawLLMResponse,
            providerCallCount: providerCallCount,
            completionState: .completed,
            memoryPromotionTicket: promotionTicket,
            workingCommentaryCharacters: workingCommentaryCharacters
        )
    }

    /// Result of a shared post-dispatch round: `.stopLoop` when the no-progress
    /// guard tripped (caller breaks BEFORE the next-iteration prep, exactly as
    /// the inlined code did), `.continueLoop` otherwise.
    ///
    /// `madeProgress` is the whole-turn wall-clock budget's extension signal:
    /// true when at least ONE dispatch in the round returned a real result
    /// (`ChatToolOutcome.outputLooksSuccessful` — the same classification that
    /// sets the provider's tool_result `is_error` bit). An all-errored round is
    /// exactly the stuck case the budget exists to kill, so it extends nothing.
    enum ToolDispatchRoundOutcome { case continueLoop(madeProgress: Bool), stopLoop }

    /// Post-provider-call round of the structured loop: mint the
    /// assistant message (prose + tool_use blocks, synthesizing collision-free
    /// ids for id-less calls), dispatch the iteration's calls through the shared
    /// core, append the paired tool_result user message, run the no-progress
    /// guard, and — unless a stop was raised — refresh same-turn tool schemas and
    /// age older tool-result bodies (compat-only). The loop flushes its
    /// pending prose delta BEFORE calling this.
    func runToolDispatchRound(
        providerCalls: [ParsedToolCall],
        iterationRawText: String,
        ctx: TurnContext,
        surface: String,
        sessionId: String?,
        tools: any ToolDispatchClient,
        progress: ChatOrchestrationProgressHandler?,
        conversation: inout [LLMMessage],
        dispatches: inout [TurnEngineResult.ToolDispatchRecord],
        activeToolSchemas: inout [LLMToolSchema],
        providerTools: inout ProviderToolNameMap,
        noProgressGuard: inout ToolLoopNoProgressGuard,
        loopRecoveryReply: inout String?,
        toolChangePlan: StructuredToolChangePlan? = nil,
        offeredToolNames: inout Set<String>,
        cancelFlagPath: URL? = nil,
        /// Set on the marker protocol: the round replays as the model's own
        /// text and its results come back as one text message (8b carrier).
        markerCodec: TextMarkerCodec? = nil
    ) async throws -> ToolDispatchRoundOutcome {
        // Append the assistant turn that contained the tool calls. Strip any
        // <tool_use> markers from the surfaced text so the assistant text block
        // carries only the model's prose (the structured toolUse blocks below
        // carry the actual tool calls). The marker protocol replays the
        // model's reply as written, cut after its last marker: text past it
        // was written before any result existed.
        let prose = ToolCallParser.stripToolUseMarkers(iterationRawText).trimmingCharacters(in: .whitespacesAndNewlines)
        var assistantBlocks: [LLMContentBlock] = []
        if let markerCodec {
            assistantBlocks.append(.text(markerCodec.throughLastMarker(iterationRawText)))
        } else if !prose.isEmpty {
            assistantBlocks.append(.text(prose))
        }
        // If the parser didn't recover an id (legacy marker), mint a stable one
        // keyed on round base + call index + name so the provider has SOMETHING
        // to round-trip. The index matters: two id-less calls to the SAME tool in
        // one round must not collide (audit 2026-06-09). pairedIds keeps the
        // result side echoing the exact assistant-side id by position.
        let roundBase = dispatches.count
        var pairedIds: [String] = []
        for (idx, call) in providerCalls.enumerated() {
            let argsJSON: Data = {
                if let v = try? JSONValue.object(call.input).serializedData(pretty: false) {
                    return v
                }
                return Data("{}".utf8)
            }()
            let id = call.id.isEmpty
                ? "toolu_synth_\(roundBase + idx)_\(call.name)"
                : call.id
            pairedIds.append(id)
            if markerCodec == nil {
                assistantBlocks.append(.toolUse(id: id, name: call.name, inputJSON: argsJSON))
            }
        }
        conversation.append(LLMMessage(role: .assistant, content: assistantBlocks))

        // Dispatch the iteration's calls (parallel-safe runs concurrent, cap 4,
        // everything else serial in order — U1 step 6) and append the results as
        // ONE user message of tool_result blocks paired by id in original order.
        var (toolResultBlocks, iterationRecords) = await dispatchIterationCalls(
            providerCalls: providerCalls,
            pairedIds: pairedIds,
            providerTools: providerTools,
            modelId: ctx.modelId,
            surface: surface,
            sessionId: sessionId,
            personaID: ctx.personaID,
            fluidContextTurn: ctx.fluidContextTurn,
            tools: tools,
            progress: progress,
            // OFFERED != AUTHORIZED != DECLARED. The array declares the whole
            // session catalog; only the offered set may dispatch, and
            // SwiftToolDispatcher still gates every one of those.
            offeredToolNames: toolChangePlan == nil ? nil : offeredToolNames,
            cancelFlagPath: cancelFlagPath,
            neutralizingTextResults: markerCodec != nil
        )
        if let markerCodec {
            // The round's results as the marker protocol returns them: one
            // text carrier in call order, closed once, pixels after it.
            var carrier = ""
            var images: [LLMContentBlock] = []
            var resultIndex = 0
            for block in toolResultBlocks {
                guard case .toolResult(_, let content, let isError) = block else {
                    images.append(block)
                    continue
                }
                markerCodec.appendResult(
                    index: resultIndex,
                    toolName: iterationRecords[resultIndex].name,
                    ok: !isError,
                    content: content,
                    wroteResult: resultIndex < providerCalls.count && providerCalls[resultIndex].wroteResult,
                    to: &carrier
                )
                resultIndex += 1
            }
            if resultIndex > 0 { markerCodec.closeRound(&carrier) }
            toolResultBlocks = (carrier.isEmpty ? [] : [.text(carrier)]) + images
        }
        dispatches.append(contentsOf: iterationRecords)
        ChatTurnExecution.current?.keepTools(iterationRecords)
        if surface == "bot", iterationRecords.contains(where: { ChatToolOutcome.isWaitingApproval($0.result) }) {
            ChatTurnExecution.current?.waitForApproval()
        }
        // Setup and permission cards leave this item skipped while the turn
        // finishes its other work. Only a question needed by the turn parks it.
        if let waiting = iterationRecords.lazy
            .compactMap({ InlineInteractionNeed.interaction(in: $0.result) })
            .first(where: InlineInteractionNeed.blocksTurn) {
            ChatTurnExecution.current?.waitForInteraction(waiting)
            return .stopLoop
        }
        // Whole-turn budget extension signal (see ToolDispatchRoundOutcome).
        // User, 2026-09-06: an approval FILED is not a tool that ran, so it does
        // not re-earn the surface window. A model stuck re-asking for the same
        // CONFIRM renewed the budget every round and rode the turn to the
        // iteration cap.
        let madeProgress = iterationRecords.contains {
            ChatToolOutcome.outputLooksSuccessful($0.result)
                && !ChatToolOutcome.isWaitingOnPerson($0.result)
                && !ChatToolOutcome.neverRan($0.result)
        }
        switch noProgressGuard.observe(iterationRecords) {
        case .none:
            break
        case .warn(let feedback, let visible):
            // 2026-09-13 (first-failure pass): the model-directed correction
            // used to go straight into the visible progress stream, so the
            // reader was handed the agent's repair work ("change the
            // arguments", "use a narrower query"). Only an evidenced blocker
            // they can actually resolve surfaces now; the correction still
            // rides into the conversation below, where it belongs.
            if let visible {
                await progress?(.notice(kind: "tool_loop_recovery", text: visible))
            }
            // 2026-07-21 audit fix: the WARN text is model-directed
            // guidance ("change the arguments, use a narrower query or a
            // different tool...") but only the USER ever saw it — the
            // model repeated identical rounds 9-15 with zero corrective
            // signal until the hard stop (whose feedback IS appended).
            // Feed it into the conversation like the stop branch does.
            toolResultBlocks.append(.text(feedback))
        case .stop(let feedback, let visible):
            toolResultBlocks.append(.text(feedback))
            // The final answer is the person-facing half: what stopped and what
            // survived, never an inference about the agent's arguments.
            loopRecoveryReply = visible
        }
        // Item 5 (third conversation pass): a message the person sent while
        // this turn was working is delivered HERE — the next safe boundary,
        // after the round's results and before the model picks its next action
        // — as plain text in the same tool_result turn (the same shape the
        // no-progress feedback above uses, so no role alternation changes).
        // Empty in the ordinary case: one actor hop and nothing appended.
        //
        // NOT when this round already chose a terminal reply: draining takes the
        // offer out of BOTH queues, and the loop stops below without another
        // provider call — so the message would be neither read by the model nor
        // left to run as its own turn. Left pending, the close/cleanup requeues
        // it, which is the lossless contract `ChatTurnSteering` documents.
        if loopRecoveryReply == nil, let sessionId, !sessionId.isEmpty {
            for offer in await ChatTurnSteering.shared.drain(sessionId: sessionId) {
                toolResultBlocks.append(.text(ChatTurnSteering.deliveryText(offer.text)))
            }
        }
        conversation.append(contentsOf: LocalToolImage.continuation(toolResultBlocks))
        LocalToolImage.boundConversation(&conversation)
        if loopRecoveryReply != nil { return .stopLoop }
        if SameTurnToolSchemaRefresh.wasRequested(calls: providerCalls, providerTools: providerTools) {
            if let toolChangePlan {
                // Same SEMANTICS as the refresh below — a tool loaded mid-turn
                // is usable on the very next provider call — expressed without
                // touching the array. The message goes after the tool_result
                // user message (a legal position for a mid-conversation system
                // message) and ends the array, so it renders on the next call.
                let newlyOffered = try await SameTurnToolSchemaRefresh.newlyOfferedNames(
                    plan: toolChangePlan,
                    alreadyOffered: offeredToolNames,
                    sessionId: sessionId,
                    activeToolsStore: activeToolsStore
                )
                if !newlyOffered.isEmpty {
                    offeredToolNames.formUnion(newlyOffered)
                    // Validated by construction: every name came out of the
                    // array, and the map was built from that same array.
                    let providerNames = newlyOffered.compactMap {
                        providerTools.providerName(forInternalName: $0)
                    }
                    if let message = ConversationPrefixSeeding.toolChangeMessage(
                        additions: providerNames, removals: []
                    ) {
                        conversation.append(message)
                    }
                }
            } else {
                activeToolSchemas = try await SameTurnToolSchemaRefresh.afterLoad(
                    current: activeToolSchemas,
                    sessionId: sessionId,
                    tools: tools,
                    activeToolsStore: activeToolsStore
                )
                providerTools = ProviderToolNameMap(activeToolSchemas)
            }
        }
        return .continueLoop(madeProgress: madeProgress)
    }

    /// Shared exhaustion tail for a loop that ran out of iterations without a
    /// final reply: pick the best-effort reply (loop-recovery stop > protocol-
    /// violation terminal > exhaustion fallback when there's no usable prose or
    /// the last raw was only a structured tool call > the stripped fallback
    /// text), record the abandoned outcome, run memory promotion, and build the
    /// result. A streamed tool-call round also counts as "only a structured
    /// tool call", so that extra signal is a parameter.
    /// The turn's OWN terminal for "waiting on you".
    ///
    /// A raised need is not exhaustion, not a protocol violation, and not a
    /// cancellation, and it must not borrow any of their endings: the generic
    /// "I ran out of iterations" line would sit above the card contradicting
    /// it, and `.abandoned` would tell the context ledger that the selection
    /// failed when what actually happened is that the work reached a person.
    ///
    /// So: keep exactly the prose the person already watched render, add
    /// nothing, and record the turn as a deliberate stop. The card beneath it
    /// is the rest of the message, and resolving it resumes the request.
    func waitingOnInteractionResult(
        ctx: TurnContext,
        visible: String,
        lastRawResponse: String,
        dispatches: [TurnEngineResult.ToolDispatchRecord],
        startNs: UInt64,
        providerCallCount: Int
    ) -> TurnEngineResult {
        Task { [weak turn = ctx.fluidContextTurn] in
            await turn?.recordOutcome(.completed)
        }
        return TurnSettle.waitingOnCard(
            visible: visible,
            modelUsed: ctx.modelId,
            recalledIds: ctx.resolvedRecalledIds,
            dispatches: dispatches,
            startNs: startNs,
            rawLLMResponse: lastRawResponse,
            providerCallCount: providerCallCount
        )
    }

    func finishExhaustedTurn(
        ctx: TurnContext,
        lastRawResponse: String,
        lastProtocolViolation: ToolCallProtocolViolation?,
        loopRecoveryReply: String?,
        iterationLimit: Int,
        wallClockElapsedSeconds: Int?,
        dispatches: [TurnEngineResult.ToolDispatchRecord],
        startNs: UInt64,
        providerCallCount: Int,
        userMessage: String,
        sessionId: String?,
        surface: String,
        additionalStructuredToolCallSignal: Bool,
        /// Prose the user ALREADY WATCHED RENDER this turn, marker-stripped.
        /// User, 2026-09-06: a streaming turn that hit the whole-turn budget in
        /// the reconnect ladder took the generic exhaustion reply whenever an
        /// earlier round had tool calls, and the client persisted THAT as the
        /// reply — so displayed paragraphs vanished on reload.
        visiblePartial: String,
        codec: ToolCallCodec = .native
    ) async -> TurnEngineResult {
        let fallbackText = ToolCallParser.stripToolUseMarkers(lastRawResponse).trimmingCharacters(in: .whitespacesAndNewlines)
        let recalledIds = ctx.resolvedRecalledIds
        let rawWasOnlyStructuredToolCall = additionalStructuredToolCallSignal
            || !ToolCallParser.parse(lastRawResponse, parseInvoke: codec == .textMarkers).isEmpty
        // What the user saw stays: the terminal line explains the stop, but it
        // never REPLACES prose that already rendered.
        //
        // User, 2026-09-06: this used to apply on the exhaustion branch alone, so
        // a turn that ended on the no-progress guard or on a protocol violation
        // persisted the canned line by itself and the paragraphs the user had
        // just watched render vanished on reload.
        let shown = visiblePartial.trimmingCharacters(in: .whitespacesAndNewlines)
        func keepingVisible(_ terminal: String) -> String {
            shown.isEmpty ? terminal : shown + "\n\n" + terminal
        }
        let final: String
        if let loopRecoveryReply {
            final = keepingVisible(loopRecoveryReply)
        } else if let lastProtocolViolation {
            final = keepingVisible(lastProtocolViolation.terminalReply)
        } else if fallbackText.isEmpty || rawWasOnlyStructuredToolCall {
            final = keepingVisible(ToolLoopExhaustion.fallbackReply(
                iterationLimit: iterationLimit,
                dispatchCount: dispatches.count,
                providerRounds: providerCallCount,
                wallClockElapsedSeconds: wallClockElapsedSeconds
            ))
        } else {
            final = fallbackText
        }
        await ctx.fluidContextTurn?.recordRetry()
        await ctx.fluidContextTurn?.recordOutcome(.abandoned)
        await observeMemoryPromotion(
            userMessage: userMessage,
            assistantMessage: final,
            toolDispatches: dispatches,
            sessionId: sessionId,
            surface: surface
        )
        let endNs = DispatchTime.now().uptimeNanoseconds
        let elapsedMs = Int((endNs &- startNs) / 1_000_000)
        return TurnEngineResult(
            reply: final,
            modelUsed: ctx.modelId,
            recalledIds: recalledIds,
            toolDispatches: dispatches,
            elapsedMs: elapsedMs,
            rawLLMResponse: lastRawResponse,
            providerCallCount: providerCallCount,
            completionState: .incomplete
        )
    }

    /// A provider output budget is a terminal incomplete answer, with no retry
    /// or dispatch of the unfinished round's tool plan.
    func finishLengthLimitedTurn(
        ctx: TurnContext,
        partial: String,
        dispatches: [TurnEngineResult.ToolDispatchRecord],
        startNs: UInt64,
        providerCallCount: Int,
        codec: ToolCallCodec = .native
    ) async -> TurnEngineResult {
        // 2026-09-23: keep the prose before any repetition loop, and say why.
        let (kept, notice) = RunawayOutputDetector.cutoffReply(partial)
        let prefix = codec.visiblePrefix(in: ToolCallParser.stripToolUseMarkers(kept))
        let prose = LLMCallContext.turnTokenBudget != nil ? prefix : prefix.trimmingCharacters(in: .whitespacesAndNewlines)
        await ctx.fluidContextTurn?.recordOutcome(.abandoned)
        return TurnEngineResult(
            reply: LLMCallContext.turnTokenBudget != nil ? prose : (prose.isEmpty ? notice : prose + "\n\n" + notice),
            modelUsed: ctx.modelId,
            recalledIds: ctx.resolvedRecalledIds,
            toolDispatches: dispatches,
            elapsedMs: Int((DispatchTime.now().uptimeNanoseconds &- startNs) / 1_000_000),
            rawLLMResponse: partial,
            providerCallCount: providerCallCount,
            completionState: .incomplete
        )
    }
}
