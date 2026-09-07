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
// Tool errors remain model-visible feedback; streaming and non-streaming entry
// points share dispatch, completion, and exhaustion helpers below.

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
    ) async -> [LLMToolSchema] {
        let session = (sessionId ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !session.isEmpty,
              let available = try? await tools.listAvailableToolSchemas() else {
            return current
        }

        let persisted = await activeToolsStore.load(sessionId: session).activeTools
        let active = persisted.union(LLMCallContext.turnActiveTools ?? [])
        let allowed = SwiftToolDispatcher.normalModelToolNames(activeTools: active)
        var known = Set(current.map(\.name))
        var refreshed = current
        for schema in available where !known.contains(schema.name) {
            guard schema.name.hasPrefix("mcp__") || allowed.contains(schema.name) else { continue }
            refreshed.append(schema)
            known.insert(schema.name)
        }
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
    ) async -> [String] {
        let session = (sessionId ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !session.isEmpty else { return [] }
        let persisted = await activeToolsStore.load(sessionId: session).activeTools
        let active = persisted.union(LLMCallContext.turnActiveTools ?? [])
        let allowed = SwiftToolDispatcher.normalModelToolNames(activeTools: active)
        let declared = plan.arrayNames
        return plan.array.map(\.name).filter {
            allowed.contains($0) && declared.contains($0) && !alreadyOffered.contains($0)
        }
    }

    static func wasRequested(
        calls: [ParsedToolCall],
        providerTools: ProviderToolNameMap
    ) -> Bool {
        calls.contains { providerTools.internalName(forProviderName: $0.name) == "tool_load" }
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
    /// derivation + the filter + the rebuild that both structured loops and
    /// `streamTurn` used to hand-inline. Byte-identical to those inlines.
    /// `nonisolated` because it only reads the `activeToolsStore` `let`,
    /// task-locals, and pure statics — callable from `streamTurn`'s nonisolated
    /// task without an actor hop.
    nonisolated func lazyFilteredTurnContext(
        _ ctx: TurnContext,
        sessionId: String?,
        pinnedActiveTools: Set<String>? = nil,
        pinnedContract: SessionToolContract? = nil
    ) async -> TurnContext {
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
        // immediately. Callers that need next-iteration list refresh (the
        // kimi native-tools lane, whose provider tools array is the only way
        // its model can call a tool) pass nil and keep the store read.
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
            let loadout = await activeToolsStore.load(sessionId: trimmedSession)
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
    // MARK: - Shared turn-loop segments
    // Context, completion, dispatch and exhaustion share helpers. Provider
    // calls stay in their respective loops: streaming owns live deltas and
    // protocol-buffer cleanup, while blocking calls check cancellation per round.

    /// Empty replies leave no assistant message. Append the nudge through
    /// the shared prefix owner so it preserves Anthropic role adjacency.
    static func appendStructuredUserNudge(_ text: String, to conversation: inout [LLMMessage]) {
        ConversationPrefixSeeding.appendUserText(text, to: &conversation)
    }

    /// Shared pre-loop context resolution. Prefer a caller-provided context
    /// (e.g. one already threaded with session history); otherwise build a fresh
    /// per-turn context AND lazy-filter ctx.toolSchemas through the session's
    /// active-tools set so the no-preBuiltContext path can't expose the full
    /// eager catalog. Then fire the context-snapshot event. Byte-identical to
    /// the inline both loops used.
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
        let ctx = await lazyFilteredTurnContext(rawCtx, sessionId: sessionId)
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
    /// build the TurnEngineResult. Identical to the empty-calls returns both
    /// loops inlined; `rawLLMResponse` differs per path (non-streaming passes the
    /// iteration `raw`, streaming the accumulated `lastRawResponse`), so it's a
    /// parameter.
    func finishCompletedTurn(
        reply: String,
        ctx: TurnContext,
        dispatches: [TurnEngineResult.ToolDispatchRecord],
        startNs: UInt64,
        rawLLMResponse: String,
        providerCallCount: Int,
        userMessage: String,
        sessionId: String?,
        surface: String
    ) async -> TurnEngineResult {
        let recalledIds = ctx.resolvedRecalledIds
        await ctx.fluidContextTurn?.recordOutcome(.completed)
        await observeMemoryPromotion(
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
            completionState: .completed
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

    /// Shared post-provider-call round for both structured loops: mint the
    /// assistant message (prose + tool_use blocks, synthesizing collision-free
    /// ids for id-less calls), dispatch the iteration's calls through the shared
    /// core, append the paired tool_result user message, run the no-progress
    /// guard, and — unless a stop was raised — refresh same-turn tool schemas and
    /// age older tool-result bodies (compat-only). Byte-identical to both inlines;
    /// the streaming path flushes its pending prose delta BEFORE calling this.
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
        cancelFlagPath: URL? = nil
    ) async -> ToolDispatchRoundOutcome {
        // Append the assistant turn that contained the tool calls. Strip any
        // <tool_use> markers from the surfaced text so the assistant text block
        // carries only the model's prose (the structured toolUse blocks below
        // carry the actual tool calls).
        let prose = ToolCallParser.stripToolUseMarkers(iterationRawText).trimmingCharacters(in: .whitespacesAndNewlines)
        var assistantBlocks: [LLMContentBlock] = []
        if !prose.isEmpty {
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
            assistantBlocks.append(.toolUse(id: id, name: call.name, inputJSON: argsJSON))
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
            cancelFlagPath: cancelFlagPath
        )
        dispatches.append(contentsOf: iterationRecords)
        // Whole-turn budget extension signal (see ToolDispatchRoundOutcome).
        // User, 2026-09-06: an approval FILED is not a tool that ran, so it does
        // not re-earn the surface window. A model stuck re-asking for the same
        // CONFIRM renewed the budget every round and rode the turn to the
        // iteration cap.
        let madeProgress = iterationRecords.contains {
            ChatToolOutcome.outputLooksSuccessful($0.result)
                && !ChatToolOutcome.isWaitingApproval($0.result)
        }
        switch noProgressGuard.observe(iterationRecords) {
        case .none:
            break
        case .warn(let feedback):
            await progress?(.notice(kind: "tool_loop_recovery", text: feedback))
            // 2026-07-21 audit fix: the WARN text is model-directed
            // guidance ("change the arguments, use a narrower query or a
            // different tool...") but only the USER ever saw it — the
            // model repeated identical rounds 9-15 with zero corrective
            // signal until the hard stop (whose feedback IS appended).
            // Feed it into the conversation like the stop branch does.
            toolResultBlocks.append(.text(feedback))
        case .stop(let feedback):
            toolResultBlocks.append(.text(feedback))
            loopRecoveryReply = feedback
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
                let newlyOffered = await SameTurnToolSchemaRefresh.newlyOfferedNames(
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
                activeToolSchemas = await SameTurnToolSchemaRefresh.afterLoad(
                    current: activeToolSchemas,
                    sessionId: sessionId,
                    tools: tools,
                    activeToolsStore: activeToolsStore
                )
                providerTools = ProviderToolNameMap(activeToolSchemas)
            }
        }
        // U1 step 5 + item 8 (review fix): the sweep mutates bytes inside the
        // trailing-message cached prefix, so it fires ONLY in compat mode (no
        // message breakpoint). Default shape leaves the conversation byte-stable
        // and lets prefix caching pay.
        if AnthropicOAuthDirectAdapter.GrownPromptCompat.effective {
            IntraTurnToolResultClearing.sweep(&conversation)
        }
        return .continueLoop(madeProgress: madeProgress)
    }

    /// Shared exhaustion tail for a loop that ran out of iterations without a
    /// final reply: pick the best-effort reply (loop-recovery stop > protocol-
    /// violation terminal > exhaustion fallback when there's no usable prose or
    /// the last raw was only a structured tool call > the stripped fallback
    /// text), record the abandoned outcome, run memory promotion, and build the
    /// result. The streaming path also treats a streamed tool-call round as
    /// "only a structured tool call", so that extra signal is a parameter
    /// (default false → byte-identical to the non-streaming inline).
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
        additionalStructuredToolCallSignal: Bool = false,
        /// Prose the user ALREADY WATCHED RENDER this turn, marker-stripped.
        /// User, 2026-09-06: a streaming turn that hit the whole-turn budget in
        /// the reconnect ladder took the generic exhaustion reply whenever an
        /// earlier round had tool calls, and the client persisted THAT as the
        /// reply — so displayed paragraphs vanished on reload. Empty on the
        /// non-streaming lane, where nothing was displayed.
        visiblePartial: String = ""
    ) async -> TurnEngineResult {
        let fallbackText = ToolCallParser.stripToolUseMarkers(lastRawResponse).trimmingCharacters(in: .whitespacesAndNewlines)
        let recalledIds = ctx.resolvedRecalledIds
        let rawWasOnlyStructuredToolCall = additionalStructuredToolCallSignal
            || !ToolCallParser.parse(lastRawResponse).isEmpty
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
        providerCallCount: Int
    ) async -> TurnEngineResult {
        let prose = ToolCallParser.visiblePrefix(in: partial)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let notice = LLMError.outputLengthLimitNotice
        await ctx.fluidContextTurn?.recordOutcome(.abandoned)
        return TurnEngineResult(
            reply: prose.isEmpty ? notice : prose + "\n\n" + notice,
            modelUsed: ctx.modelId,
            recalledIds: ctx.resolvedRecalledIds,
            toolDispatches: dispatches,
            elapsedMs: Int((DispatchTime.now().uptimeNanoseconds &- startNs) / 1_000_000),
            rawLLMResponse: partial,
            providerCallCount: providerCallCount,
            completionState: .incomplete
        )
    }

    /// Execute one turn with a tool-dispatch loop. See file header for carves.
    ///
    /// `llm` and `tools` must be the SAME instances passed to the engine's
    /// initializer — they're parameters here only because the actor's stored
    /// llm/tools are `private` and we are not touching the base file.
    public func executeTurnWithToolLoop(
        surface: String = "chat",
        userMessage: String,
        sessionId: String? = nil,
        /// Request-scoped identity used only for tool loading/dispatch. This is
        /// distinct from `sessionId`: ephemeral turns need a verified tool
        /// identity without becoming a chat transcript or provider session.
        toolSessionId: String? = nil,
        runId: String? = nil,
        maxIterations: Int? = nil,
        turnWallClockSecondsOverride: TimeInterval? = nil,
        llm: any LLMClient,
        tools: any ToolDispatchClient,
        preBuiltContext: TurnContext? = nil,
        progress: ChatOrchestrationProgressHandler? = nil,
        // B7 (2026-07-17): a cross-process Stop that only WRITES the session's
        // cancelled.flag (no Task handle — e.g. the bridge surface) must be able
        // to halt a NON-streaming structured turn between provider calls, just
        // like the streaming loop's per-event poll. nil → legacy behavior (no
        // cross-process cancel), so existing callers are byte-identical.
        cancelFlagPath: URL? = nil,
        providerAdmission: (@Sendable () async throws -> Void)? = nil
    ) async throws -> TurnEngineResult {
        // P2-3: fold the Workshop surface once at the loop entry (see
        // buildTurnContext) so the whole tool loop threads one vocabulary.
        let surface = WorkshopSurfaceVocabulary.foldLegacySpelling(surface)
        // An image-only turn (no caption text) is valid when the pre-built
        // context carries image blocks — don't reject it as empty.
        if userMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && (preBuiltContext?.imageBlocks.isEmpty ?? true) {
            throw TurnEngineError.emptyMessage
        }
        let recoveryScope = ProviderToolResultRecoveryStore.Scope(
            sessionId: toolSessionId ?? sessionId,
            turnId: TurnTraceContext.turnId
        )
        defer {
            if let recoveryScope {
                Task { await ProviderToolResultRecoveryStore.shared.remove(scope: recoveryScope) }
            }
        }
        var wholeTurnBudget = WholeTurnWallClockBudget.start(surface: surface, requestedSeconds: turnWallClockSecondsOverride)
        let startNs = DispatchTime.now().uptimeNanoseconds
        // Shared pre-loop context resolution (C2): prefer preBuiltContext, else
        // build + lazy-filter through the session's active tools, then fire the
        // context-snapshot event.
        let resolvedTurnContext = try await resolveToolLoopContext(
            surface: surface,
            userMessage: userMessage,
            sessionId: sessionId,
            runId: runId,
            preBuiltContext: preBuiltContext
        )

        // HOTFIX 2026-06-03 conversation-shape: was single-prompt mutation
        // ("prompt += Tool X returned: ..."), which left the model without
        // PAIRED tool_use/tool_result blocks each round — it kept re-emitting
        // the same tool call up to maxIterations and never produced a final
        // reply. Now we build a structured [LLMMessage] conversation and
        // route via llm.completeMessages, which the OAuth-direct adapters
        // override to emit canonical wire shape for each provider.
        // Image blocks ride on the CURRENT user message ONLY (per-turn DYNAMIC)
        // — never persisted, never re-sent. Empty → exact pre-multimodal shape.
        // v2Prefix (2026-09-01): prior turns become a REAL message prefix and
        // the per-turn volatile mass moves out of the churning tail of the
        // system prompt into a message that sits AFTER it. On `.v1Legacy` this
        // returns the exact single-user-message array built here before —
        // `ctx` untouched, byte-identical request body.
        // The BOUND shape, never `.effective`: the adapters read only the
        // task-local, so resolving a second time here could disagree with what
        // the outer turn entry bound and with what the context was built under.
        // Mid-conversation tool changes (Anthropic structured lane). Unbound
        // on every other lane → nil → nothing below this line changes.
        //
        // The provider-name map is built from the ARRAY and then held still
        // for the whole turn: the array is turn-invariant, so its aliases are
        // too, and every `tool_reference` name has to be the one THIS map
        // minted or the request 400s.
        let toolChangePlan = StructuredToolChangeContext.plan
        var providerTools = ProviderToolNameMap(
            toolChangePlan?.array ?? resolvedTurnContext.toolSchemas
        )
        let turnToolChanges = toolChangePlan.flatMap { plan in
            ConversationPrefixSeeding.toolChangeMessage(
                additions: plan.additions.compactMap {
                    providerTools.providerName(forInternalName: $0)
                },
                removals: plan.removals.compactMap {
                    providerTools.providerName(forInternalName: $0)
                }
            )
        }
        let prefixSeed = ConversationPrefixSeeding.seed(
            resolvedTurnContext,
            shape: ConversationPrefixShape.override ?? .v1Legacy,
            toolChanges: turnToolChanges
        )
        let ctx = prefixSeed.context
        // ARCHIVE THIS TURN'S REPLAYABLE TAIL — the tool-change message and the
        // turn-scoped volatile block, exactly as seeded. The tool-change
        // message is NOT turn-scoped: removing an already-sent one invalidates
        // the prefix from that point, so it has the same must-stay contract as
        // the volatile block and the same failure if dropped.
        if let sessionId, !sessionId.isEmpty, let runId, !runId.isEmpty {
            let replayable = Array(prefixSeed.messages.dropFirst(prefixSeed.currentUserIndex + 1))
            if !replayable.isEmpty {
                await TurnVolatileArchiveRegistry.shared
                    .archive(dataRoot: remPinsDataRoot)
                    .record(sessionId: sessionId, runId: runId, messages: replayable)
            }
        }
        if prefixSeed.shape == .v2Prefix {
            ConversationPrefixTelemetry.sink?.set(ConversationPrefixSeeding.telemetry(
                prefixSeed,
                shape: prefixSeed.shape,
                // On a plan lane the cacheable tool contribution is the ARRAY,
                // not the offered set: hashing the offered set would report a
                // moved prefix on exactly the loads this lane stopped moving.
                toolSchemaFingerprint: Self.toolSchemaFingerprint(
                    toolChangePlan?.array ?? ctx.toolSchemas
                ),
                toolChangePlan: toolChangePlan
            ))
        }
        var conversation: [LLMMessage] = prefixSeed.messages
        // Context-overflow survival (2026-09-05): the model's REAL window,
        // resolved once per turn, plus the working-notes writer the compactor
        // folds with. Nothing at or before `compactionTurnStart` is ever folded
        // — that index is the last message the SEED produced, so it covers this
        // turn's user message (the request) and the volatile tail after it,
        // both of which the replayed prefix requires. See
        // IntraTurnContextCompaction.
        let turnWindowTokens = ContextBudgetPolicy.windowTokens(
            forModel: ctx.modelId,
            providerID: ctx.providerId ?? LLMCallContext.providerId,
            dataRoot: remPinsDataRoot
        )
        let compactionTurnStart = prefixSeed.messages.count - 1
        let compactionClient = llm
        let compactionModel = ctx.modelId
        let compactionSurface = surface
        let distillWorkingNotes: @Sendable (String) async throws -> String? = { rendered in
            await IntraTurnContextCompaction.withDeadline(
                seconds: IntraTurnContextCompaction.distillDeadlineSeconds
            ) {
                // A plain prompt with no replayed prefix: say v1 outright rather
                // than inheriting whatever shape the turn bound.
                try await ConversationPrefixShape.$override.withValue(.v1Legacy) {
                    try await compactionClient.complete(
                        prompt: rendered,
                        system: IntraTurnContextCompaction.workingNotesSystem,
                        model: compactionModel,
                        surface: compactionSurface
                    )
                }
            }
        }
        var activeToolSchemas = toolChangePlan?.array ?? ctx.toolSchemas
        // Offered-so-far, so a mid-turn `tool_load` only ever adds what is not
        // already on the table.
        var offeredToolNames = Set(toolChangePlan?.offered ?? [])
        var dispatches: [TurnEngineResult.ToolDispatchRecord] = []
        var lastRawResponse: String = ""
        var lastProtocolViolation: ToolCallProtocolViolation?
        // 2026-07-21 audit fix: bound the violation bounce (same cap as the
        // streaming loop and text-compat — third violation accepted as final
        // via the exhausted finish's terminalReply).
        var violationNudgeCount = 0
        // F2-M4 (2026-07-23): the completion-contract announce-without-act
        // bounce, hoisted from the text-compat call site into the STRUCTURED
        // lane so missions/workshop/bridge + every OpenAI-wire provider enforce
        // it too (not just prompt-only). Same cap as text-compat: at most TWICE
        // per turn, then the third announcement is accepted as final so a model
        // that refuses to act can never loop.
        var announceNudgeCount = 0
        // FIX 1 (B1.1, 2026-07-23): empty-reply recovery, ported from the
        // text-compat lane's `emptyReplyNudgeCount` into the STRUCTURED loop. An
        // empty text reply + zero tool calls is not a valid final; nudge at most
        // twice, then accept so a thinking-only provider can never loop.
        var emptyReplyNudgeCount = 0
        var noProgressGuard = ToolLoopNoProgressGuard()
        var loopRecoveryReply: String?
        var providerCallCount = 0
        // In-loop provider recovery (2026-09-05): how many times THIS turn has
        // re-issued a provider call after a recoverable drop. Bounded so a
        // provider that fails every round cannot ride the per-call budget
        // forever. See ProviderRecoveryPolicy.
        var turnRecoveries = 0
        var wallClockElapsedSeconds: Int?
        let iterationLimit = ToolLoopBudget.resolve(surface: surface, requested: maxIterations)

        iterations: for _ in 0..<iterationLimit {
            // B7: cross-process Stop between provider calls. A bridge-surface
            // Stop that only WROTE cancelled.flag (no Task handle) halts the
            // turn here instead of running to iterationLimit burning tokens.
            // Mirrors the streaming loop's mid-stream poll, at iteration grain.
            if let flag = cancelFlagPath,
               FileManager.default.fileExists(atPath: flag.path) {
                throw CancellationError()
            }
            // A6: stop only at the safe iteration boundary. Cancellation keeps
            // its prior precedence. Falling through here reuses
            // finishExhaustedTurn below, including its existing abandoned
            // outcome, promotion, fallback, and receipt behavior.
            if wholeTurnBudget.isExhausted {
                wallClockElapsedSeconds = wholeTurnBudget.elapsedSeconds
                break
            }
            // U1 step 4: thread the session id task-locally so the OpenAI
            // Responses adapter can derive a stable per-session
            // prompt_cache_key (additive; nil binding = pre-U1 behavior).
            // U1 step 2b/3b: thread the stable/dynamic system split the same
            // way so the Anthropic adapters can place the sys cache
            // breakpoint at the stable-segment end (nil = combined block).
            let providerRoute = ctx.providerId ?? LLMCallContext.providerId
            let serviceTier = ctx.serviceTier ?? LLMCallContext.serviceTier
            var raw = ""
            // Context-overflow survival, PROACTIVE half: measure the whole
            // in-flight conversation against the real window BEFORE spending a
            // round trip on a body that cannot fit. Over the pressure line we
            // trim first, so no provider call is ever wasted on a 400.
            if IntraTurnContextCompaction.estimatedChars(conversation)
                > IntraTurnContextCompaction.pressureChars(windowTokens: turnWindowTokens) {
                let receipt = await IntraTurnContextCompaction.compact(
                    conversation: &conversation,
                    turnStartIndex: compactionTurnStart,
                    windowTokens: turnWindowTokens,
                    distill: distillWorkingNotes
                )
                if receipt.mode != "none" {
                    TurnTraceBus.fireFromContext(
                        kind: TurnLifecycleMilestone.contextIntraTurnCompaction.rawValue,
                        surface: surface,
                        payload: IntraTurnContextCompaction.tracePayload(
                            receipt, trigger: "pressure", turnRecoveries: turnRecoveries
                        )
                    )
                    await progress?(.notice(
                        kind: IntraTurnContextCompaction.noticeKind,
                        text: IntraTurnContextCompaction.noticeText
                    ))
                }
                // User, 2026-09-06: compaction can distill through the model, so
                // it spends real wall time. Re-check the budget it may have
                // just exhausted — otherwise the round below samples a
                // remainder of zero for its per-call wall and starts a provider
                // call the turn has no time for.
                if wholeTurnBudget.isExhausted {
                    wallClockElapsedSeconds = wholeTurnBudget.elapsedSeconds
                    break
                }
            }
            // User, 2026-09-06: counted HERE, after the last exit above it. The
            // increment used to sit at the top of the round, so a compaction
            // that exhausted the budget left behind a provider round the turn
            // never made — and the exhaustion line quoted that inflated count
            // back to the user.
            providerCallCount += 1
            // The provider call is retried IN PLACE on a recoverable failure:
            // `conversation` already holds every tool result, so a retry
            // re-issues the identical request and re-executes nothing. Only
            // when the budget is spent does the turn die the old way.
            var callAttempt = 1
            // Overflow recoveries burnt on THIS provider call (step A, then
            // step B). Bounded separately from the retry ladder because each
            // one changes the body rather than repeating it.
            var overflowRecoveries = 0
            while true {
            do {
            // Seeding may have fallen back to the v1 message array (no
            // replayed history). Re-bind what was ACTUALLY produced so the
            // adapter's wire layout and this body cannot disagree.
            raw = try await ConversationPrefixShape.$override.withValue(prefixSeed.shape) {
            // Where THIS turn begins. The adapter cannot re-derive it: replayed
            // history carries archived `system` blocks of its own, so the old
            // `lastIndex(.system)` anchor selected one of THOSE and dropped the
            // cross-turn 1h marker near the start of the conversation — caching
            // almost nothing, silently. Within-turn rounds only ever APPEND, so
            // this index stays correct for every round of the turn.
            try await ConversationPrefixBoundary.$currentUserIndex
                .withValue(prefixSeed.currentUserIndex) {
            // User, 2026-09-06: how long the WHOLE turn has left, so the router
            // can shorten this call's wall to leave the reconnect ladder room.
            try await LLMCallContext.$remainingTurnSeconds
                .withValue(wholeTurnBudget.remainingSeconds) {
            try await LLMCallContext.$admittedModel.withValue(ctx.modelId) {
            try await LLMCallContext.$providerId.withValue(providerRoute) {
            try await LLMCallContext.$serviceTier.withValue(serviceTier) {
            try await LLMCallContext.$systemSegments.withValue(ctx.systemSegments) {
                try await LLMCallContext.$sessionId.withValue(sessionId) {
                    try await LLMCallContext.$reasoningEffort.withValue(ctx.reasoningEffort) {
                    try await providerAdmission?()
                    return try await llm.completeMessages(
                        messages: conversation,
                        system: ctx.systemPrompt,
                        model: ctx.modelId,
                        surface: surface,
                        tools: providerTools.schemas.isEmpty ? nil : providerTools.schemas
                    )
                    }
            }
            }
            }
            }
            }
            }
            }
            }
            break
            } catch {
                if case .outputLengthLimit(let partial) = error as? LLMError {
                    try Task.checkCancellation()
                    if let flag = cancelFlagPath, FileManager.default.fileExists(atPath: flag.path) {
                        throw CancellationError()
                    }
                    return await finishLengthLimitedTurn(
                        ctx: ctx, partial: partial, dispatches: dispatches,
                        startNs: startNs, providerCallCount: providerCallCount
                    )
                }
                // Context-overflow survival, REACTIVE half: the provider refused
                // the body as TOO LONG. Re-issuing it verbatim gets the identical
                // 400, so trim the conversation and ask again with a smaller one.
                // Bounded per call and counted against the turn's recovery
                // budget; a receipt of "none" means there is nothing left to give
                // back, and the failure falls through to the throw below.
                if callAttempt < ProviderRecoveryPolicy.maxAttemptsPerCall,
                   overflowRecoveries < IntraTurnContextCompaction.maxOverflowRecoveriesPerCall,
                   turnRecoveries < ProviderRecoveryPolicy.maxRecoveriesPerTurn,
                   ProviderRecoveryPolicy.isContextOverflow(error) {
                    let receipt = await IntraTurnContextCompaction.compact(
                        conversation: &conversation,
                        turnStartIndex: compactionTurnStart,
                        windowTokens: turnWindowTokens,
                        pressure: .overflow,
                        distill: distillWorkingNotes
                    )
                    if receipt.mode != "none" {
                        overflowRecoveries += 1
                        turnRecoveries += 1
                        TurnTraceBus.fireFromContext(
                            kind: TurnLifecycleMilestone.contextIntraTurnCompaction.rawValue,
                            surface: surface,
                            payload: IntraTurnContextCompaction.tracePayload(
                                receipt, trigger: "overflow", turnRecoveries: turnRecoveries
                            )
                        )
                        // Cancellation outranks recovery — same two signals, same
                        // ordering as the retry ladder below. No backoff: the body
                        // CHANGED, so asking again immediately is the right move.
                        try Task.checkCancellation()
                        if let flag = cancelFlagPath,
                           FileManager.default.fileExists(atPath: flag.path) {
                            throw CancellationError()
                        }
                        await progress?(.notice(
                            kind: IntraTurnContextCompaction.noticeKind,
                            text: IntraTurnContextCompaction.noticeText
                        ))
                        // User, 2026-09-06: same rule as the retry ladder below
                        // and as the streaming overflow path — no attempt
                        // starts after the whole-turn budget is spent.
                        if wholeTurnBudget.isExhausted {
                            wallClockElapsedSeconds = wholeTurnBudget.elapsedSeconds
                            break iterations
                        }
                        callAttempt += 1
                        providerCallCount += 1
                        continue
                    }
                }
                if callAttempt < ProviderRecoveryPolicy.maxAttemptsPerCall,
                   turnRecoveries < ProviderRecoveryPolicy.maxRecoveriesPerTurn,
                   ProviderRecoveryPolicy.isRecoverableTurnFailure(error) {
                    // User, 2026-09-06: honor the provider's own Retry-After when
                    // it asked for a longer wait than the ladder's backoff, and
                    // refuse a wait the turn cannot afford — sleeping past the
                    // budget only converts a rate limit into a bare exhaustion.
                    let delaySeconds = ProviderRecoveryPolicy.retryDelaySeconds(
                        forRetry: callAttempt, error: error
                    )
                    let remainingBudget = wholeTurnBudget.remainingSeconds
                    if delaySeconds >= remainingBudget {
                        if let notice = ProviderRecoveryPolicy.retryAfterBeyondBudgetNotice(
                            for: error, remainingSeconds: remainingBudget
                        ) {
                            await progress?(.notice(
                                kind: "provider_retry",
                                text: notice
                            ))
                        }
                        wallClockElapsedSeconds = wholeTurnBudget.elapsedSeconds
                        break iterations
                    }
                    turnRecoveries += 1
                    ProviderRetryTrace.emit(
                        error: error, attempt: callAttempt,
                        delaySeconds: delaySeconds, mode: "replay",
                        turnRecoveries: turnRecoveries, surface: surface
                    )
                    // Cancellation outranks recovery, by Task state and by the
                    // cross-process flag the loop already polls at this grain.
                    try Task.checkCancellation()
                    if let flag = cancelFlagPath,
                       FileManager.default.fileExists(atPath: flag.path) {
                        throw CancellationError()
                    }
                    // A silent reconnect looks identical to a hang. Emitted
                    // AFTER the cancellation checks so a Stop never leaves a
                    // "reconnecting" line as the last thing the surface said,
                    // and BEFORE the backoff so it stands for the whole wait.
                    // The kind carries "retry", which is what both surfaces
                    // match on to show the retrying phase.
                    await progress?(.notice(
                        kind: "provider_retry",
                        text: ProviderRecoveryPolicy.reconnectStatus(attemptsMade: callAttempt)
                    ))
                    try await providerRecoverySleep(delaySeconds)
                    // A Stop written during the backoff must not start one more
                    // provider call: re-check both signals after the wait.
                    try Task.checkCancellation()
                    if let flag = cancelFlagPath,
                       FileManager.default.fileExists(atPath: flag.path) {
                        throw CancellationError()
                    }
                    // The retry ladder is not exempt from the whole-turn budget:
                    // an expired budget ends the turn on the exhausted path
                    // instead of starting one more attempt (Codex review
                    // 2026-09-05).
                    if wholeTurnBudget.isExhausted {
                        wallClockElapsedSeconds = wholeTurnBudget.elapsedSeconds
                        break iterations
                    }
                    callAttempt += 1
                    providerCallCount += 1
                    continue
                }
                // A provider failure after this turn already dispatched tools
                // must not be whole-turn-replayed by surface retry ladders.
                throw ProviderErrorAfterToolEffects.wrapping(error, dispatchCount: ProviderErrorAfterToolEffects.effectfulCount(dispatches))
            }
            }
            // User, 2026-09-06: a Stop that landed WHILE this non-streaming call
            // was in flight was only read before the request, so the tool calls
            // it came back with were parsed and dispatched anyway. Re-check both
            // stop signals before touching the response — the streaming lane
            // already does exactly this at stream EOF.
            try Task.checkCancellation()
            if let flag = cancelFlagPath,
               FileManager.default.fileExists(atPath: flag.path) {
                throw CancellationError()
            }
            lastRawResponse = raw
            if let violation = ToolCallParser.formattedToolCallViolation(in: raw) {
                lastProtocolViolation = violation
                violationNudgeCount += 1
                if violationNudgeCount > 2 { break }
                // Reflect the rejected assistant output back as conversation
                // state, then give the model a precise protocol error. Nothing
                // is dispatched, persisted, promoted, or returned to a surface.
                conversation.append(.assistantText(raw))
                conversation.append(.user(violation.modelFeedback))
                continue
            }
            lastProtocolViolation = nil
            let providerCalls = ToolCallParser.executableCalls(ToolCallParser.parse(raw))
            if providerCalls.isEmpty {
                let reply = ToolCallParser.containsOnlyIgnorableCalls(raw)
                    ? ToolCallParser.stripToolUseMarkers(raw).trimmingCharacters(in: .whitespacesAndNewlines)
                    : raw
                // FIX 1 (B1.1): empty-reply recovery — checked BEFORE the announce
                // bounce. An empty text reply + empty tool calls is not a valid
                // final; nudge (max 2) then accept. An empty string can never
                // match looksLikeUnfulfilledActionPromise (it guards
                // `!trimmed.isEmpty`), so the two bounces never contend. An empty
                // reply produces no assistant text, so the remedy is folded into
                // the trailing user message when one is present (mirrors the
                // native-lane appendNativeUserText merge) to keep wire roles
                // alternating; otherwise it stands alone.
                if emptyReplyNudgeCount < 2,
                   !providerTools.schemas.isEmpty,
                   reply.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    emptyReplyNudgeCount += 1
                    let remedy = ToolCallParser.structuredEmptyReplyRemedy(
                        secondBounce: emptyReplyNudgeCount == 2
                    )
                    Self.appendStructuredUserNudge(remedy, to: &conversation)
                    continue
                }
                // F2-M4: completion-contract bounce. Only when tools are actually
                // available to call (else the model has nothing to act with) and
                // at most twice per turn. Preserves the exact terminal behavior
                // for turns WITH tool calls — this block is calls-empty only.
                if announceNudgeCount < 2,
                   !providerTools.schemas.isEmpty,
                   ToolCallParser.looksLikeUnfulfilledActionPromise(reply) {
                    announceNudgeCount += 1
                    conversation.append(.assistantText(raw))
                    conversation.append(.user(
                        ToolCallParser.structuredAnnounceContractRemedy(
                            secondBounce: announceNudgeCount == 2
                        )
                    ))
                    continue
                }
                // Shared completed-turn finish (C2): records .completed, runs the
                // realtime memory-promotion side channel, builds the result.
                return await finishCompletedTurn(
                    reply: reply,
                    ctx: ctx,
                    dispatches: dispatches,
                    startNs: startNs,
                    rawLLMResponse: raw,
                    providerCallCount: providerCallCount,
                    userMessage: userMessage,
                    sessionId: sessionId,
                    surface: surface
                )
            }
            // Shared post-dispatch round (C2): assistant blocks → dispatch →
            // no-progress guard → paired tool_result append → schema refresh +
            // compat-only sweep. `.stopLoop` means the guard tripped; break
            // BEFORE the next-iteration prep, exactly as the inline code did.
            let outcome = await runToolDispatchRound(
                providerCalls: providerCalls,
                iterationRawText: raw,
                ctx: ctx,
                surface: surface,
                sessionId: toolSessionId ?? sessionId,
                tools: tools,
                progress: progress,
                conversation: &conversation,
                dispatches: &dispatches,
                activeToolSchemas: &activeToolSchemas,
                providerTools: &providerTools,
                noProgressGuard: &noProgressGuard,
                loopRecoveryReply: &loopRecoveryReply,
                toolChangePlan: toolChangePlan,
                offeredToolNames: &offeredToolNames,
                cancelFlagPath: cancelFlagPath
            )
            // A6 progress extension: a round that actually landed a tool result
            // re-earns the surface window (capped at the unattended ceiling).
            if case .continueLoop(let madeProgress) = outcome, madeProgress {
                wholeTurnBudget.recordProgress()
            }
            // User, 2026-09-06: a Stop that landed during the LAST batch used to
            // fall out of the loop and leave through `finishExhaustedTurn`,
            // which records `.abandoned` and hands back the generic "ran out of
            // iterations" reply — the user's Stop reported as ordinary
            // exhaustion. Decide cancellation right after the round, on the
            // same two signals the dispatch runner polls.
            try Task.checkCancellation()
            if let flag = cancelFlagPath,
               FileManager.default.fileExists(atPath: flag.path) {
                throw CancellationError()
            }
            if case .stopLoop = outcome { break }
        }
        // Loop exhausted. Shared exhaustion tail (C2): best-effort final reply
        // from the last raw response + dispatch trail rather than throwing, so
        // the caller still gets SOMETHING usable.
        return await finishExhaustedTurn(
            ctx: ctx,
            lastRawResponse: lastRawResponse,
            lastProtocolViolation: lastProtocolViolation,
            loopRecoveryReply: loopRecoveryReply,
            iterationLimit: iterationLimit,
            wallClockElapsedSeconds: wallClockElapsedSeconds,
            dispatches: dispatches,
            startNs: startNs,
            providerCallCount: providerCallCount,
            userMessage: userMessage,
            sessionId: sessionId,
            surface: surface
        )
    }


}
