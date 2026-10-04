import ChatToolParsing
import ToolRegistry
import Foundation
import CryptoKit
import Dispatcher
import NativeAgentCore
import PersistenceCore
import TurnTrace
import Transcripts
import MemoryV2
import ProviderRouting
import MacIntegration
import Context

extension SwiftNativeTurnEngine {
    /// The one structured tool loop. It builds a tool_use/tool_result
    /// conversation and consumes provider text deltas and tool-call events as
    /// they arrive, so a surface that renders `progress` never looks dead
    /// while a tool-capable response is running. Callers that do not render
    /// progress simply await the result.
    func executeContinuationTurnBody(
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
        /// Does the caller render this turn's prose as it streams? When it does
        /// not (chat() and ephemeral callers await the result), no prose was
        /// "watched": the reply is the final round's text, a dropped stream
        /// replays whole, and the terminals read the last round, exactly as a
        /// turn that only awaits its result has always been answered.
        rendersProse: Bool = true,
        cancelFlagPath: URL? = nil,
        /// Asked before every provider call of the turn, retries included. A
        /// throw ends the turn before that call starts.
        providerAdmission: (@Sendable () async throws -> Void)? = nil
    ) async throws -> TurnEngineResult {
        // P2-3: fold the Workshop surface once at the loop entry (see
        // buildTurnContext) so the whole tool loop threads one vocabulary.
        let surface = WorkshopSurfaceVocabulary.foldLegacySpelling(surface)
        // Prepared document text and image-only turns need no caption.
        if (preBuiltContext?.userMessage ?? userMessage).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
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
        // build + lazy-filter (so the turn never ships the full eager catalog),
        // then fire the context snapshot.
        let resolvedTurnContext = try await resolveToolLoopContext(
            surface: surface,
            userMessage: userMessage,
            sessionId: sessionId,
            runId: runId,
            preBuiltContext: preBuiltContext
        )
        var commitInstructionDelivery = pendingInstructionDelivery(in: resolvedTurnContext, sessionID: sessionId)

        // The provider-name map is built from the array and then held still
        // for the whole turn.
        var providerTools = ProviderToolNameMap(resolvedTurnContext.toolSchemas)
        // How tools are offered and calls read back, per provider (8a seam).
        // Chosen from the provider the client itself resolves under the SAME
        // bindings every call of this turn runs with, so a route the client
        // reaches by model prefix (Codex, with no provider pinned) reads as
        // that provider, not as the unpinned default.
        let toolCallCodec = ToolCallCodec.forProvider(
            await LLMCallContext.$admittedModel.withValue(resolvedTurnContext.modelId) {
                await LLMCallContext.$providerId.withValue(resolvedTurnContext.providerId ?? LLMCallContext.providerId) {
                    await llm.servingProviderID(model: resolvedTurnContext.modelId, surface: surface)
                }
            }
        )
        let prefixSeed = ConversationPrefixSeeding.seed(
            resolvedTurnContext,
            // The marker catalog's session-loaded run rides the volatile block
            // on v2, so a mid-session tool_load cannot move the cached prefix.
            textToolCatalogAppendix: toolCallCodec == .textMarkers
                ? TextMarkerCodec.volatileCatalogAppendix(for: resolvedTurnContext)
                : nil
        )
        let ctx = prefixSeed.context
        let wireSystem: (prompt: String?, segments: SystemPromptSegments?) = toolCallCodec == .textMarkers
            ? {
                let layout = TextMarkerCodec.systemLayout(
                    baseSystem: ctx.systemPrompt, segments: ctx.systemSegments, context: ctx)
                return (layout.system, layout.segments)
            }()
            : (ctx.systemPrompt, ctx.systemSegments)
        // ARCHIVE THIS TURN'S REPLAYABLE TAIL — the turn-scoped volatile block,
        // exactly as seeded.
        if let sessionId, !sessionId.isEmpty, let runId, !runId.isEmpty {
            let replayable = Array(prefixSeed.messages.dropFirst(prefixSeed.currentUserIndex + 1))
            if !replayable.isEmpty {
                await TurnVolatileArchiveRegistry.shared
                    .archive(dataRoot: remPinsDataRoot)
                    .record(sessionId: sessionId, runId: runId, messages: replayable)
            }
        }
        ConversationPrefixTelemetry.sink?.set(ConversationPrefixSeeding.telemetry(
            prefixSeed,
            toolSchemaFingerprint: Self.toolSchemaFingerprint(ctx.toolSchemas)
        ))
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
        // Distilling the working notes is Memory and mind work, not this turn's
        // (2026-09-13 review). It used to take `ctx.modelId` and the turn's own
        // surface, and the deadline child inherits the turn's task-locals on top
        // — so a long Chat or Work turn summarized on the Chat/Work account.
        // Resolve the `compaction` group and bind its WHOLE tuple: model,
        // route, Think and tier, with this turn's own provider choice set aside
        // because it is this turn's, not compaction's. Resolved lazily, so a
        // turn that never compacts pays for no extra snapshot read.
        let compactionSurface = ChatCompactionDistiller.distillSurface
        let distillWorkingNotes: @Sendable (String) async throws -> String? = { [weak self] rendered in
            guard let self else { return nil }
            let route = try await ProviderTurnChoice.$current.withValue(nil) {
                try await self.checkedRouteAdmission(for: compactionSurface)
            }
            return await IntraTurnContextCompaction.withDeadline(
                seconds: IntraTurnContextCompaction.distillDeadlineSeconds
            ) {
                try await ProviderTurnChoice.$current.withValue(nil) {
                try await LLMCallContext.$admittedModel.withValue(route.modelId) {
                try await LLMCallContext.$providerId.withValue(route.providerId) {
                try await LLMCallContext.$serviceTier.withValue(route.serviceTier) {
                try await LLMCallContext.$reasoningEffort.withValue(route.reasoningEffort) {
                    try await compactionClient.complete(
                        prompt: rendered,
                        system: IntraTurnContextCompaction.workingNotesSystem,
                        model: route.modelId,
                        surface: compactionSurface
                    )
                }
                }
                }
                }
                }
            }
        }
        let activeToolSchemas = ctx.toolSchemas
        var dispatches: [TurnEngineResult.ToolDispatchRecord] = []
        var counters = TurnEngineResult.LoopCounters()
        defer { ToolLoopTraceObservation.current?.record(counters, dispatches: dispatches) }
        var previousRoundFailed = false
        var brakeReason = TurnEngineResult.TerminalReason.iterationLimit
        func observed(_ result: TurnEngineResult, reason: TurnEngineResult.TerminalReason) -> TurnEngineResult {
            result.observingTerminal(reason: reason, counters: counters)
        }
        var lastRawResponse = ""
        // #5: visible prose accumulated across iterations (text deltas only, no
        // tool markers) — carried across a mid-stream throw so the partial isn't
        // lost. Used only on the failure path.
        var visibleText = ""
        // Transcript-loss fix (2026-07-31): interstitial narration from every
        // NON-final iteration (prose → tool → prose → tool → prose). Those bytes
        // were streamed to the surface but the success return built `reply` from
        // the LAST iteration's `iterAccumulated` only, so a reload showed one
        // paragraph where the user watched three render. The failure path already
        // persisted the whole accumulated `visibleText`; success now matches it —
        // raw concatenation, no injected separator, exactly the bytes emitted via
        // progress?(.delta(...)). Bounced iterations (violation / empty-reply /
        // announce) `continue` before the append, so rejected narration is
        // discarded here the same way those paths reset `visibleText`.
        var turnInterstitialProse = ""
        // The last round's raw output (text, then its tool calls as markers):
        // what the terminals read when the caller renders no prose.
        var lastRoundRaw = ""
        var lastProviderHadToolCalls = false
        var lastProtocolViolation: ToolCallProtocolViolation?
        // 2026-07-21 audit fix: bound the violation bounce — a
        // deterministically malformed model could violate EVERY iteration and
        // burn the whole iteration budget (violation rounds dispatch zero
        // tools, so the no-progress guard never fires). Third violation is
        // accepted as final: break into the exhausted finish, which yields
        // lastProtocolViolation.terminalReply.
        var violationNudgeCount = 0
        // F2-M4 (2026-07-23): completion-contract announce-without-act bounce on
        // the structured lane (mirrors the text-compat call site), so missions,
        // workshop, bridge and every OpenAI-wire provider enforce it. Bounded
        // at two; a third announcement settles explicitly as incomplete.
        var announceNudgeCount = 0
        // FIX 1 (B1.1, 2026-07-23): empty-reply recovery, ported from the
        // text-compat lane. Bounded at two; the third empty reply is accepted
        // as final, so a thinking-only provider can never loop.
        var emptyReplyNudgeCount = 0
        var emittedProviderFirstDelta = false
        var noProgressGuard = ToolLoopNoProgressGuard()
        var loopRecoveryReply: String?
        // B3 (2026-07-17): the streaming loop is the PRIMARY chat path but never
        // counted provider calls — cost/telemetry undercounted the main surface.
        // One streamMessages call per iteration; count it and thread it into
        // every TurnEngineResult return below.
        var providerCallCount = 0
        var replyTextSettled = false
        // In-loop provider recovery (2026-09-05): how many times THIS turn has
        // re-issued a provider call after a recoverable drop. Bounded so a
        // provider that fails every round cannot ride the per-call budget
        // forever. See ProviderRecoveryPolicy.
        var turnRecoveries = 0
        var wallClockElapsedSeconds: Int?
        let iterationLimit = ToolLoopBudget.resolve(surface: surface, requested: maxIterations)

        streamingIterations: for _ in 0..<iterationLimit {
            if replyTextSettled {
                replyTextSettled = false
                await progress?(.replyTextSettled(false))
            }
            // B7: a cross-process Stop that only WROTE cancelled.flag (no Task
            // handle — e.g. the bridge) is honored before a round starts, not
            // only once a stream is running: a buffered provider yields nothing
            // to poll until it is done.
            if ChatCancelFlag.isRaised(cancelFlagPath) {
                throw TurnEngineError.streamCancelled(
                    partial: toolCallCodec.visiblePrefix(in: visibleText),
                    underlying: CancellationError()
                )
            }
            // A6: do not interrupt an active provider stream or dispatch. At
            // this boundary, expiry falls through to the one exhaustion tail.
            if wholeTurnBudget.isExhausted {
                wallClockElapsedSeconds = wholeTurnBudget.elapsedSeconds
                break
            }
            var iterAccumulated = ""
            // Bytes this iteration actually handed to the surface (marker-safe
            // slices only). Folded into `turnInterstitialProse` when the
            // iteration ends in a tool dispatch.
            var iterEmittedProse = ""
            var streamedCalls: [ParsedToolCall] = []
            var pendingProtocolDelta = ""
            if await IntraTurnContextCompaction.compactProactivelyIfNeeded(
                conversation: &conversation,
                turnStartIndex: compactionTurnStart,
                windowTokens: turnWindowTokens,
                distill: distillWorkingNotes,
                surface: surface,
                turnRecoveries: turnRecoveries,
                progress: progress
            ) {
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
            // User, 2026-09-06: counted HERE, after the last exit above it. A
            // compaction that exhausted the budget used to leave a counted
            // round that was never made, and the exhaustion line quoted that
            // inflated count back to the user.
            providerCallCount += 1
            // In-loop provider recovery (2026-09-05). A recoverable mid-stream
            // drop no longer kills the turn: the tool results already sit in
            // `conversation`, so the stream is re-issued in place. `retryAfterDrop`
            // is how the catch (which lives INSIDE the task-local nest below)
            // reports the drop out to the retry block after the nest closes —
            // the stream has to be rebuilt under freshly-entered bindings.
            // `attemptBase*` are the per-turn accumulators as they stood BEFORE
            // this attempt, so a replay can discard the attempt whole.
            var callAttempt = 1
            var recoveryMode = "replay"
            var retryAfterDrop: Error?
            var reachedLengthLimit = false
            var lengthLimitPartial = ""
            var emptyThinkingOnlyReply = false
            // Context-overflow survival: `overflowAfterDrop` is the sibling of
            // `retryAfterDrop` — the compaction receipt reported out of the nest
            // so the block after it can announce and re-issue.
            var overflowRecoveries = 0
            var overflowAfterDrop: IntraTurnContextCompaction.Receipt?
            var attemptMessages = conversation
            let attemptBaseVisibleText = visibleText
            let attemptBaseRawResponse = lastRawResponse
            while true {
            // U1 step 4: thread the session id task-locally so the OpenAI
            // Responses adapter gets a stable prompt_cache_key. U1 step 2b/3b:
            // same for the stable/dynamic system split (Anthropic adapters'
            // breakpoint placement).
            // MEMORY-SAFETY (2026-07-04): bind via the ASYNC withValue overload
            // wrapping BOTH construction AND consumption — NOT a sync withValue
            // around construction alone. llm.streamMessages(...) builds an
            // AsyncThrowingStream whose adapter child Task inherits these
            // task-locals and reads them LAZILY (e.g. sessionId → prompt_cache_key
            // in buildResponsesBodyFromMessages, after streamMessages has already
            // returned). A sync withValue pops the binding the instant the stream
            // is constructed — while the child still references it — the same
            // task-allocator LIFO shape ("freed pointer was not the last
            // allocation" / swift_task_dealloc_specific) that caused the
            // release-only first-chat crash on the text-compat path (1b1caf58).
            // The async overload holds the binding until the stream is fully
            // drained (child Task done), keeping the pop LIFO-ordered. The
            // no-tool-calls early return + tool dispatch stay OUTSIDE this block,
            // so wrapping only construction+consumption needs no re-indent.
            let providerRoute = ctx.providerId ?? LLMCallContext.providerId
            let serviceTier = ctx.serviceTier ?? LLMCallContext.serviceTier
            // Keep stream reduction out of the nested generic expressions;
            // construction and consumption still run inside every binding below.
            let wakeRoot = remPinsDataRoot
            let consumeAttempt: () async throws -> Void = {
            // Before the stream exists, so a refusal starts no provider call.
            do {
                try await providerAdmission?()
            } catch {
                throw ProviderErrorAfterToolEffects.wrapping(error, dispatchCount: ProviderErrorAfterToolEffects.effectfulCount(dispatches))
            }
            // Iteration, budget, compaction, schema refresh and provider
            // admission all succeeded. Only now can a follow-up leave its queue.
            if !dispatches.isEmpty, let sessionId, !sessionId.isEmpty {
                let offers = await ChatTurnSteering.shared.drain(
                    sessionId: sessionId, cancelFlagPath: cancelFlagPath)
                if Task.isCancelled || ChatCancelFlag.isRaised(cancelFlagPath) {
                    await ChatTurnSteering.shared.returnUndelivered(offers, sessionId: sessionId)
                    throw TurnEngineError.streamCancelled(
                        partial: toolCallCodec.visiblePrefix(in: visibleText),
                        underlying: CancellationError())
                }
                if wholeTurnBudget.isExhausted {
                    await ChatTurnSteering.shared.returnUndelivered(offers, sessionId: sessionId)
                    wallClockElapsedSeconds = wholeTurnBudget.elapsedSeconds
                    return
                }
                for offer in offers {
                    Self.appendStructuredUserNudge(
                        ChatTurnSteering.deliveryText(offer.text), to: &conversation)
                    Self.appendStructuredUserNudge(
                        ChatTurnSteering.deliveryText(offer.text), to: &attemptMessages)
                }
                // What resolved meanwhile feeds this turn, not a second one:
                // hers only, never a helper's or one a peer steers or answers to.
                if let root = wakeRoot, !sessionId.hasPrefix("bot-"), PeerDataTaint.current?.isTainted != true,
                   [nil, "self"].contains(ChatToolSessionContext.envelope?.agent),
                   let arrived = ResidentWake.shared.take(dataRoot: root) {
                    Self.appendStructuredUserNudge(arrived, to: &conversation)
                    Self.appendStructuredUserNudge(arrived, to: &attemptMessages)
                }
            }
            // Sample after steering persistence has spent its wall time.
            try await LLMCallContext.$remainingTurnSeconds
                .withValue(wholeTurnBudget.remainingSeconds) {
            counters.providerAttemptCount += 1
            if callAttempt == 1 {
                counters.providerRoundCount += 1
                if previousRoundFailed { counters.roundsAfterToolFailureCount += 1 }
                previousRoundFailed = false
            } else {
                counters.providerRecoveryCount += 1
                if recoveryMode == "overflow" { counters.contextOverflowRecoveryCount += 1 }
                if recoveryMode == "continuation" { counters.providerContinuationCount += 1 }
                else { counters.providerReplayCount += 1 }
            }
            let stream = llm.streamMessages(
                messages: attemptMessages,
                system: wireSystem.prompt,
                model: ctx.modelId,
                surface: surface,
                tools: toolCallCodec.requestTools(providerTools.schemas)
            )
            var streamEventIndex = 0
            do {
                for try await event in stream {
                    try Task.checkCancellation()
                    streamEventIndex += 1
                    // #19 (2026-06-14): a cross-process Stop that only WRITES the
                    // cancelled.flag (no Task handle — e.g. the bridge surface)
                    // must be able to halt a structured turn, else it runs to
                    // completion burning provider tokens. Mirror streamTurn's poll.
                    if let flag = cancelFlagPath,
                       streamEventIndex % 8 == 0,
                       ChatCancelFlag.isRaised(flag) {
                        throw CancellationError()
                    }
                    switch event {
                    case .replyTextSettled(let settled):
                        if settled {
                            let prose = toolCallCodec.proseReleasedAtDispatch(pendingProtocolDelta)
                            if !prose.isEmpty {
                                iterEmittedProse += prose
                                await progress?(.delta(prose))
                            }
                            pendingProtocolDelta.removeAll(keepingCapacity: true)
                        }
                        replyTextSettled = settled
                        await progress?(.replyTextSettled(settled))
                    case .textDelta(let delta):
                        if !delta.isEmpty {
                            commitInstructionDelivery?()
                            commitInstructionDelivery = nil
                        }
                        if !delta.isEmpty, !emittedProviderFirstDelta {
                            emittedProviderFirstDelta = true
                            TurnLifecycleTelemetry.emit(
                                .providerFirstDelta,
                                surface: surface,
                                sessionId: sessionId,
                                observedBy: "structured_tool_loop.stream"
                            )
                        }
                        iterAccumulated += delta
                        lastRawResponse += delta
                        visibleText += delta
                        pendingProtocolDelta += delta
                        let safe = toolCallCodec.releasableProse(holding: &pendingProtocolDelta)
                        if !safe.isEmpty {
                            iterEmittedProse += safe
                            await progress?(.delta(safe))
                        }
                    case .toolCall(let call):
                        commitInstructionDelivery?()
                        commitInstructionDelivery = nil
                        guard let parsed = try toolCallCodec.decode(call) else {
                            continue
                        }
                        streamedCalls.append(parsed)
                        let args = String(data: call.inputJSON, encoding: .utf8) ?? "{}"
                        lastRawResponse += "\n<tool_use id=\"\(call.id)\" name=\"\(call.name)\">\(args)</tool_use>"
                    case .keepAlive:
                        // Liveness signal (no content): nothing to accumulate and
                        // no progress delta to emit. The cancel-flag poll above
                        // still ran, so a keepalive is also a valid stop checkpoint.
                        break
                    }
                }
                // Cancellation can resume AsyncThrowingStream.next() with nil
                // rather than throw or deliver another event. Check the same
                // stop signals at EOF before treating visible prose as complete
                // or dispatching any tool calls buffered by this iteration.
                try Task.checkCancellation()
                if ChatCancelFlag.isRaised(cancelFlagPath) {
                    throw CancellationError()
                }
                commitInstructionDelivery?()
                commitInstructionDelivery = nil
            } catch is CancellationError {
                // 2026-07-21 audit fix: a user stop mid-stream CARRIES the
                // visible partial (marker-stripped, same as the interrupted
                // path below) so the orchestration catch can persist it with
                // cancelled:true — previously this lane dropped every
                // streamed character on Stop while text-compat persisted it.
                // Cancel still propagates as cancel semantics (not a
                // failure) via the dedicated case.
                let safePartial = toolCallCodec.visiblePrefix(in: visibleText)
                throw TurnEngineError.streamCancelled(
                    partial: safePartial,
                    underlying: CancellationError()
                )
            } catch {
                if replyTextSettled {
                    replyTextSettled = false
                    await progress?(.replyTextSettled(false))
                }
                if case .outputLengthLimit(let partial) = error as? LLMError {
                    reachedLengthLimit = true
                    lengthLimitPartial = partial
                    return
                }
                counters.failedProviderAttemptCount += 1
                // A reply that was all thinking and no text: the Anthropic-wire
                // adapters report it as a transient error ("no answer text"),
                // and an identical replay is proven useless against it
                // (2026-07-20). It is an empty round, so it ends the attempt
                // with nothing in it and takes the empty-reply bounce below,
                // same caps, instead of the reconnect ladder.
                if ProviderRecoveryPolicy.isEmptyReply(error),
                   iterAccumulated.isEmpty, streamedCalls.isEmpty {
                    emptyThinkingOnlyReply = true
                    return
                }
                // Context-overflow survival, REACTIVE half: the provider refused
                // the body as TOO LONG. The 400 lands BEFORE any delta, so the
                // attempt is discarded whole (replay) and nothing the user
                // watched render is lost. Compaction runs HERE and mutates the
                // REAL `conversation`, not the attempt copy, so every later round
                // of the turn keeps the room it gave back; the block after the
                // nest does the announcing and the re-issue.
                if callAttempt < ProviderRecoveryPolicy.maxAttemptsPerCall,
                   overflowRecoveries < IntraTurnContextCompaction.maxOverflowRecoveriesPerCall,
                   turnRecoveries < ProviderRecoveryPolicy.maxRecoveriesPerTurn,
                   // Replay is only honest when the attempt produced NOTHING: a
                   // provider that streamed text and then reported overflow has
                   // already put prose on the surface, and that case belongs to
                   // the interrupted-stream continuation path below. A caller
                   // that renders no prose saw nothing, so it always replays.
                   !rendersProse || (iterAccumulated.isEmpty && iterEmittedProse.isEmpty && streamedCalls.isEmpty),
                   ProviderRecoveryPolicy.isContextOverflow(error) {
                    let receipt = await IntraTurnContextCompaction.compact(
                        conversation: &conversation,
                        turnStartIndex: compactionTurnStart,
                        windowTokens: turnWindowTokens,
                        pressure: .overflow,
                        distill: distillWorkingNotes
                    )
                    // "none" means nothing left to trim — fall through to the
                    // throw below and die the old way.
                    if receipt.mode != "none" {
                        overflowAfterDrop = receipt
                        return
                    }
                }
                // A recoverable drop is a RETRY, not a death: report it out of
                // the task-local nest and let the block after the nest back off
                // and re-issue. Only an unrecoverable failure — or a spent
                // budget — falls through to the throw below.
                if callAttempt < ProviderRecoveryPolicy.maxAttemptsPerCall,
                   turnRecoveries < ProviderRecoveryPolicy.maxRecoveriesPerTurn,
                   ProviderRecoveryPolicy.isRecoverableTurnFailure(error) {
                    retryAfterDrop = error
                    return
                }
                // #5 (2026-06-14): a mid-stream provider failure must not silently
                // DROP the prose the user already watched render. Carry the visible
                // partial across the throw so the orchestration catch can persist
                // it (cancelled:false). Strip any tool marker first — some
                // structured-path providers emit <tool_use> as TEXT (the
                // streamedCalls.isEmpty fallback below parses it), so visibleText
                // can hold a raw/partial marker that must NOT persist as visible
                // prose (gpt-5.5 review 2026-06-14).
                let safePartial = toolCallCodec.visiblePrefix(in: visibleText)
                // Wrap the UNDERLYING only: `case .streamInterrupted(partial, _)`
                // pattern-matches upstream still fire (partial persistence), and
                // streamInterrupted's errorDescription flows the wrapped marker
                // through to surface retry ladders.
                throw TurnEngineError.streamInterrupted(
                    partial: safePartial,
                    underlying: ProviderErrorAfterToolEffects.wrapping(error, dispatchCount: ProviderErrorAfterToolEffects.effectfulCount(dispatches))
                )
            }
            } // LLMCallContext.$remainingTurnSeconds.withValue
            }
            // Where THIS turn begins. The adapter cannot re-derive it: replayed
            // history carries archived `system` blocks of its own, so the old
            // `lastIndex(.system)` anchor selected one of THOSE and dropped the
            // cross-turn 1h marker near the start of the conversation. Rounds
            // only ever APPEND, so this index stays correct for the whole turn.
            try await ConversationPrefixBoundary.$currentUserIndex
                .withValue(prefixSeed.currentUserIndex) {
            try await LLMCallContext.$admittedModel.withValue(ctx.modelId) {
            try await LLMCallContext.$providerId.withValue(providerRoute) {
            try await LLMCallContext.$serviceTier.withValue(serviceTier) {
            try await LLMCallContext.$systemSegments.withValue(wireSystem.segments) {
            try await LLMCallContext.$sessionId.withValue(sessionId) {
            try await LLMCallContext.$reasoningEffort.withValue(ctx.reasoningEffort) {
            // Read only by the Claude subscription adapter: this conversation is
            // re-sent as a prefix next round (its conversation cache markers),
            // and the Mac chat surface's summarized-thinking opt-in.
            try await AnthropicOAuthDirectAdapter.MessagesCacheHint.$withinTurnReuse.withValue(true) {
            try await InspectorThinkingLane.$summarizedThinking
                .withValue(InspectorThinkingLane.isEnabledForSurface(surface)) {
                try await consumeAttempt()
            } // InspectorThinkingLane.$summarizedThinking.withValue
            } // MessagesCacheHint.$withinTurnReuse.withValue
            } // LLMCallContext.$reasoningEffort.withValue
            } // LLMCallContext.$sessionId.withValue
            } // LLMCallContext.$systemSegments.withValue
            } // LLMCallContext.$serviceTier.withValue
            } // LLMCallContext.$providerId.withValue
            } // LLMCallContext.$admittedModel.withValue
            } // ConversationPrefixBoundary.$currentUserIndex.withValue

            if wallClockElapsedSeconds != nil {
                providerCallCount -= 1
                break streamingIterations
            }

            // The same Stop checks a clean end of stream gets.
            if emptyThinkingOnlyReply, Task.isCancelled || ChatCancelFlag.isRaised(cancelFlagPath) {
                throw TurnEngineError.streamCancelled(
                    partial: toolCallCodec.visiblePrefix(in: visibleText),
                    underlying: CancellationError()
                )
            }
            if reachedLengthLimit {
                if Task.isCancelled || ChatCancelFlag.isRaised(cancelFlagPath) {
                    throw TurnEngineError.streamCancelled(
                        partial: toolCallCodec.visiblePrefix(in: visibleText),
                        underlying: CancellationError()
                    )
                }
                return observed(await finishLengthLimitedTurn(
                    ctx: ctx, partial: rendersProse ? visibleText : lengthLimitPartial, dispatches: dispatches,
                    startNs: startNs, providerCallCount: providerCallCount, codec: toolCallCodec
                ), reason: .outputLimit)
            }

            // Context-overflow survival, second act: the conversation was
            // already trimmed inside the nest. Announce it and re-issue in
            // REPLAY mode — the 400 arrived before any delta, so discarding the
            // attempt whole loses nothing. No backoff: the body CHANGED.
            // A Stop that lands between attempts carries the prose the user
            // already watched, exactly as one inside the stream does (Codex
            // review 2026-09-05: a bare CancellationError here skipped the
            // partial persistence).
            func stopCarryingPartial() -> Error {
                let safePartial = toolCallCodec.visiblePrefix(in: visibleText)
                return TurnEngineError.streamCancelled(partial: safePartial, underlying: CancellationError())
            }
            if let overflowReceipt = overflowAfterDrop {
                overflowAfterDrop = nil
                overflowRecoveries += 1
                turnRecoveries += 1
                TurnTraceBus.fireFromContext(
                    kind: TurnLifecycleMilestone.contextIntraTurnCompaction.rawValue,
                    surface: surface,
                    payload: IntraTurnContextCompaction.tracePayload(
                        overflowReceipt, trigger: "overflow", turnRecoveries: turnRecoveries
                    )
                )
                // Cancellation outranks recovery — the same two signals the
                // stream body polls, checked before anything is re-issued.
                if Task.isCancelled { throw stopCarryingPartial() }
                if ChatCancelFlag.isRaised(cancelFlagPath) {
                    throw stopCarryingPartial()
                }
                await progress?(.notice(
                    kind: IntraTurnContextCompaction.noticeKind,
                    text: IntraTurnContextCompaction.noticeText
                ))
                if wholeTurnBudget.isExhausted {
                    wallClockElapsedSeconds = wholeTurnBudget.elapsedSeconds
                    break streamingIterations
                }
                callAttempt += 1
                recoveryMode = "overflow"
                providerCallCount += 1
                streamedCalls.removeAll(keepingCapacity: true)
                pendingProtocolDelta = ""
                iterAccumulated = ""
                iterEmittedProse = ""
                visibleText = attemptBaseVisibleText
                lastRawResponse = attemptBaseRawResponse
                attemptMessages = conversation
                continue
            }
            guard let droppedStream = retryAfterDrop else { break }
            retryAfterDrop = nil
            // Prose the user ALREADY WATCHED RENDER decides the recovery shape.
            // Nothing emitted → replay: discard the attempt whole and re-issue
            // the identical call. Something emitted → continuation: keep those
            // bytes as the prefix and ask the provider to resume after them,
            // because re-issuing would render the same paragraph twice.
            recoveryMode = iterEmittedProse.isEmpty || !rendersProse ? "replay" : "continuation"
            // User, 2026-09-06: honor the provider's own Retry-After when it
            // asked for a longer wait than the ladder's backoff, and refuse a
            // wait the turn cannot afford — sleeping past the budget only
            // converts a rate limit into a bare exhaustion.
            let delaySeconds = ProviderRecoveryPolicy.retryDelaySeconds(
                forRetry: callAttempt, error: droppedStream
            )
            let remainingBudget = wholeTurnBudget.remainingSeconds
            if delaySeconds >= remainingBudget {
                if let notice = ProviderRecoveryPolicy.retryAfterBeyondBudgetNotice(
                    for: droppedStream, remainingSeconds: remainingBudget
                ) {
                    await progress?(.notice(
                        kind: "provider_retry",
                        text: notice
                    ))
                }
                wallClockElapsedSeconds = wholeTurnBudget.elapsedSeconds
                break streamingIterations
            }
            turnRecoveries += 1
            ProviderRetryTrace.emit(
                error: droppedStream, attempt: callAttempt,
                delaySeconds: delaySeconds, mode: recoveryMode,
                turnRecoveries: turnRecoveries, surface: surface
            )
            // Cancellation outranks recovery — same two signals the stream body
            // polls, checked before the backoff so a Stop lands immediately.
            if Task.isCancelled { throw stopCarryingPartial() }
            if ChatCancelFlag.isRaised(cancelFlagPath) {
                throw stopCarryingPartial()
            }
            // A silent reconnect looks identical to a hang. Emitted AFTER the
            // cancellation checks so a Stop never leaves a "reconnecting" line
            // as the last thing the surface said, and BEFORE the backoff so it
            // stands for the whole wait. The user may already be watching prose
            // render, so the notice rides the surface's status lane and never
            // the reply text.
            await progress?(.notice(
                kind: "provider_retry",
                text: ProviderRecoveryPolicy.reconnectStatus(attemptsMade: callAttempt)
            ))
            do {
                try await providerRecoverySleep(delaySeconds)
            } catch is CancellationError {
                throw stopCarryingPartial()
            }
            // A Stop written during the backoff must not start one more
            // provider call: re-check both signals after the wait.
            if Task.isCancelled { throw stopCarryingPartial() }
            if ChatCancelFlag.isRaised(cancelFlagPath) {
                throw stopCarryingPartial()
            }
            // The retry ladder is not exempt from the whole-turn budget: no
            // attempt starts after it is spent (Codex review 2026-09-05).
            if wholeTurnBudget.isExhausted {
                wallClockElapsedSeconds = wholeTurnBudget.elapsedSeconds
                break streamingIterations
            }
            callAttempt += 1
            providerCallCount += 1
            // Streamed tool calls from the dropped attempt are DISCARDED in both
            // modes: they were never dispatched, and the re-issued call emits
            // its own. Same for the held-back marker tail, which never reached
            // the surface.
            streamedCalls.removeAll(keepingCapacity: true)
            pendingProtocolDelta = ""
            if recoveryMode == "replay" {
                iterAccumulated = ""
                iterEmittedProse = ""
                visibleText = attemptBaseVisibleText
                lastRawResponse = attemptBaseRawResponse
                attemptMessages = conversation
            } else {
                // Marker-strip exactly as the interrupted path does — emitted
                // slices are marker-safe by construction, so this is a no-op in
                // practice and a guard if that ever stops being true.
                let seen = toolCallCodec.visiblePrefix(in: iterEmittedProse)
                iterAccumulated = seen
                iterEmittedProse = seen
                visibleText = attemptBaseVisibleText + seen
                lastRawResponse = attemptBaseRawResponse + seen
                // A LOCAL copy: the continuation nudge is scaffolding for one
                // re-issue, never appended to the real `conversation` and never
                // persisted. The next iteration builds from `conversation`.
                attemptMessages = conversation + [
                    .assistantText(seen),
                    .user("[Your reply was interrupted by a connection drop right after the text above. Continue exactly where you stopped. Do not repeat anything already written.]"),
                ]
            }
            }

            lastRoundRaw = iterAccumulated + streamedCalls.map { call in
                let args = (try? JSONValue.object(call.input).serializedData(pretty: false))
                    .map { String(decoding: $0, as: UTF8.self) } ?? "{}"
                return "\n<tool_use id=\"\(call.id)\" name=\"\(call.name)\">\(args)</tool_use>"
            }.joined()
            // The marker protocol's detection and words (8b): the whole catalog
            // and the session's loaded tools name what counts as a call.
            let markerCodec = toolCallCodec == .textMarkers
                ? TextMarkerCodec(
                    schemas: activeToolSchemas,
                    turnActiveTools: LLMCallContext.turnActiveTools ?? [],
                    catalogNames: Set(ctx.toolsAvailable))
                : nil
            let roundViolation: ToolCallProtocolViolation? = if let markerCodec {
                markerCodec.malformedCall(in: iterAccumulated)
            } else {
                ToolCallParser.formattedToolCallViolation(
                    in: iterAccumulated, toolNames: Set(ctx.toolsAvailable))
            }
            if let violation = roundViolation {
                lastProtocolViolation = violation
                counters.protocolViolationRoundCount += 1
                violationNudgeCount += 1
                // Rejected arguments may contain secrets; retain no raw output.
                let rejectedBytes = Data(iterAccumulated.utf8)
                TurnTraceBus.fireFromContext(kind: "tool.protocol_violation", surface: surface, payload: .object([
                    "type": .string(violation.traceType),
                    "byteSize": .int(Int64(rejectedBytes.count)),
                    "sha256": .string(SHA256.hash(data: rejectedBytes).map { String(format: "%02x", $0) }.joined()),
                ]))
                if violationNudgeCount > 2 { brakeReason = .protocolViolation; break }
                lastProviderHadToolCalls = false
                pendingProtocolDelta.removeAll(keepingCapacity: true)
                // Rewind to where THIS iteration started, not to nothing.
                // Both of these are the WHOLE turn's accumulation, so
                // wiping them here threw away the prose the person watched
                // render in EARLIER rounds as well as this rejected one -
                // and every later Stop, interruption or exhaustion on this
                // turn then persisted a partial missing all of it. The
                // bases are marker-free by construction, which is what the
                // marker search was protecting.
                lastRawResponse = attemptBaseRawResponse
                visibleText = attemptBaseVisibleText
                conversation.append(.assistantText(iterAccumulated))
                conversation.append(.user(violation.modelFeedback))
                continue
            }
            lastProtocolViolation = nil
            let providerCalls = toolCallCodec.roundCalls(
                streamed: streamedCalls, text: iterAccumulated, schemas: activeToolSchemas)
            lastProviderHadToolCalls = !providerCalls.isEmpty
            // A pending promise stop is only relevant until the next reply.
            loopRecoveryReply = nil
            if providerCalls.isEmpty {
                let reply = ToolCallParser.containsOnlyIgnorableCalls(iterAccumulated)
                    ? ToolCallParser.stripToolUseMarkers(iterAccumulated).trimmingCharacters(in: .whitespacesAndNewlines)
                    : iterAccumulated
                let emptyReply = reply.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                if emptyReply { counters.emptyReplyRoundCount += 1 }
                // FIX 1 (B1.1): empty-reply recovery, checked BEFORE the announce
                // bounce. Empty text + empty tool calls is not a valid final;
                // nudge (max 2) then settle incomplete. Resets the stream state
                // exactly like the announce/violation siblings so the re-prompted
                // response cannot leak into the next iteration. An empty string
                // can never match looksLikeUnfulfilledActionPromise, so the two
                // bounces never contend.
                if emptyReplyNudgeCount < 2,
                   !providerTools.schemas.isEmpty,
                   reply.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    emptyReplyNudgeCount += 1
                    Self.appendStructuredUserNudge(
                        ToolCallParser.structuredEmptyReplyRemedy(
                            secondBounce: emptyReplyNudgeCount == 2
                        ),
                        to: &conversation
                    )
                    pendingProtocolDelta.removeAll(keepingCapacity: true)
                    lastProviderHadToolCalls = false
                    // Rewind to this iteration's base, as the violation bounce does.
                    lastRawResponse = attemptBaseRawResponse
                    visibleText = attemptBaseVisibleText
                    continue
                }
                if reply.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    loopRecoveryReply = "Stopped without a final answer: the model returned no reply text."
                    brakeReason = .emptyReply
                    break
                }
                // F2-M4: completion-contract bounce, BEFORE flushing the pending
                // delta as final. Only when tools are available and at most
                // twice per turn. On a bounce, reset the accumulated stream state
                // exactly like the protocol-violation path above so this
                // re-prompted response cannot leak into the next iteration.
                //
                // KNOWN PARITY LIMITATION (gpt-5.5 round-3 review, accepted):
                // deltas already flushed past the 16-char holdback may have
                // surfaced part of the rejected narration before this bounce
                // runs; the accepted continuation then streams after it. The
                // text-compat lane has behaved this way since the detector
                // shipped. A true fix needs a retract/reset TurnStreamEvent
                // honored by every consumer surface — tracked on the round-3
                // board as a design item, not silently absorbed here. Buffering
                // all deltas until iteration-accept was rejected: it would turn
                // every streaming turn into chunk-at-end delivery.
                let promisesWork = (markerCodec?.promisesUnfulfilledWork(reply)
                    ?? (!providerTools.schemas.isEmpty
                        && ToolCallParser.looksLikeUnfulfilledActionPromise(reply)))
                    || (dispatches.contains(where: { !ChatToolOutcome.neverRan($0.result) })
                        && ToolCallParser.looksLikeAnnouncedNextToolStep(reply))
                if promisesWork {
                    counters.unfulfilledPromiseRoundCount += 1
                    let stoppedAt = dispatches.last(where: { !ChatToolOutcome.neverRan($0.result) })
                        .map { "after the \(ToolNameAliases.shown($0.name, input: .object($0.input)).name) result" }
                        ?? "before any tool ran"
                    loopRecoveryReply = "Stopped \(stoppedAt): the reply announced more work without making a tool call. The remaining work is unfinished."
                    guard announceNudgeCount < 2, !providerTools.schemas.isEmpty else {
                        brakeReason = .unfulfilledPromise
                        break
                    }
                    announceNudgeCount += 1
                    conversation.append(.assistantText(iterAccumulated))
                    conversation.append(.user(
                        markerCodec?.unfulfilledPromiseFeedback(bounce: announceNudgeCount)
                            ?? ToolCallParser.structuredAnnounceContractRemedy(
                                secondBounce: announceNudgeCount == 2
                            )
                    ))
                    pendingProtocolDelta.removeAll(keepingCapacity: true)
                    lastProviderHadToolCalls = false
                    // Rewind to this iteration's base, as the violation bounce does.
                    lastRawResponse = attemptBaseRawResponse
                    visibleText = attemptBaseVisibleText
                    continue
                }
                if !pendingProtocolDelta.isEmpty {
                    await progress?(.delta(pendingProtocolDelta))
                    pendingProtocolDelta.removeAll(keepingCapacity: true)
                }
                // Shared completed-turn finish (C2), with the turn's
                // accumulated lastRawResponse as rawLLMResponse.
                //
                // The PERSISTED reply is every visible byte of the turn — the
                // narration streamed before each tool round plus this final
                // iteration's text — not just the last iteration. Single-round
                // turns leave `turnInterstitialProse` empty, so they persist
                // exactly `reply` as before.
                let completed = await finishCompletedTurn(
                    reply: Self.joinedProse(turnInterstitialProse, reply),
                    ctx: ctx,
                    dispatches: dispatches,
                    startNs: startNs,
                    rawLLMResponse: lastRawResponse,
                    providerCallCount: providerCallCount,
                    userMessage: userMessage,
                    sessionId: sessionId,
                    surface: surface,
                    // Item 3 (third conversation pass): the commentary bytes
                    // still go to the transcript exactly as before — this only
                    // says where they stop, so the settled bubble can fold
                    // "I'll check… now I'll read…" away and leave the answer.
                    workingCommentaryCharacters: turnInterstitialProse.isEmpty
                        ? nil : turnInterstitialProse.count
                )
                return observed(completed, reason: emptyReply ? .emptyReply : completed.resolvedTerminalReason(dataRoot: remPinsDataRoot))
            }

            let pendingProse = toolCallCodec.proseReleasedAtDispatch(pendingProtocolDelta)
            if !pendingProse.isEmpty {
                iterEmittedProse += pendingProse
                await progress?(.delta(pendingProse))
            }
            pendingProtocolDelta.removeAll(keepingCapacity: true)
            // Text-parsed call encoding rides the text deltas, so
            // the round's raw text in `visibleText` would cut every later
            // partial at this round's first marker. Keep only what reached the
            // surface, as the violation bounce's rewind does.
            if streamedCalls.isEmpty || toolCallCodec == .textMarkers {
                visibleText = attemptBaseVisibleText + iterEmittedProse
            }
            // This iteration is committed (it dispatches tools, so it can never
            // be rewound by a bounce): keep its narration for the persisted
            // reply.
            //
            // ONLY when the provider streamed STRUCTURED tool calls. If the
            // calls were instead recovered by parsing the iteration's TEXT, that
            // text IS the call encoding — an XML <tool_use> marker or a raw
            // {"tool_calls":[…]} payload depending on dialect — and must never
            // land in the transcript as prose. stripToolUseMarkers only knows
            // the XML dialect, so text-parsed iterations contribute nothing at
            // all, exactly as before this fix. The marker protocol is the
            // exception: its emitted prose stopped before the first marker.
            if rendersProse, !streamedCalls.isEmpty || toolCallCodec == .textMarkers {
                turnInterstitialProse = Self.joinedProse(turnInterstitialProse, ToolCallParser.stripToolUseMarkers(iterEmittedProse))
            }
            // Shared post-dispatch round (C2): assistant blocks → shared
            // dispatch core → no-progress guard → paired tool_result append →
            // schema refresh + compat-only sweep. The pending-prose flush above
            // runs first.
            counters.toolRoundCount += 1
            let roundStart = dispatches.count
            let outcome: ToolDispatchRoundOutcome
            do {
                outcome = try await runToolDispatchRound(
                    providerCalls: providerCalls,
                    iterationRawText: iterAccumulated,
                    ctx: ctx,
                    surface: surface,
                    sessionId: toolSessionId ?? sessionId,
                    tools: tools,
                    progress: progress,
                    conversation: &conversation,
                    dispatches: &dispatches,
                    providerTools: &providerTools,
                    noProgressGuard: &noProgressGuard,
                    loopRecoveryReply: &loopRecoveryReply,
                    cancelFlagPath: cancelFlagPath,
                    markerCodec: markerCodec
                )
            } catch is CancellationError {
                throw TurnEngineError.streamCancelled(
                    partial: toolCallCodec.visiblePrefix(in: visibleText),
                    underlying: CancellationError()
                )
            } catch {
                // Schema refresh can fail after dispatch; keep the same partial
                // and whole-turn retry veto as a failure inside the stream.
                throw TurnEngineError.streamInterrupted(
                    partial: toolCallCodec.visiblePrefix(in: visibleText),
                    underlying: ProviderErrorAfterToolEffects.wrapping(error, dispatchCount: ProviderErrorAfterToolEffects.effectfulCount(dispatches))
                )
            }
            previousRoundFailed = dispatches.dropFirst(roundStart).contains {
                !ChatToolOutcome.outputLooksSuccessful($0.result)
                    && !ChatToolOutcome.wasCancelled($0.result)
                    && !ToolLoopTraceObservation.wasStopped($0.result)
                    && !ChatToolOutcome.isWaitingOnPerson($0.result)
                    && !ChatToolOutcome.neverRan($0.result)
            }
            // A6 progress extension: a round that actually landed a tool result
            // re-earns the surface window (capped at the unattended ceiling).
            // Streamed TEXT is never progress.
            if case .continueLoop(let madeProgress) = outcome, madeProgress {
                wholeTurnBudget.recordProgress()
            }
            // User, 2026-09-06: a Stop during the last batch used to leave
            // through the exhaustion tail as `.abandoned` instead of as a
            // cancel. Decide cancellation right after the round; it carries the
            // prose the user already watched render, exactly like a Stop inside
            // the stream does.
            if Task.isCancelled || ChatCancelFlag.isRaised(cancelFlagPath) {
                let shown = toolCallCodec.visiblePrefix(in: visibleText).trimmingCharacters(in: .whitespacesAndNewlines)
                let safePartial = loopRecoveryReply.map { shown.isEmpty ? $0 : shown + "\n\n" + $0 } ?? shown
                throw TurnEngineError.streamCancelled(
                    partial: safePartial, underlying: CancellationError()
                )
            }
            // A bot round that filed an approval ends the run here: the
            // approval resumes it, and the reply is what the bot said so far.
            if surface == "bot", ChatTurnExecution.current?.waitingForApproval == true {
                return observed(TurnEngineResult(reply: toolCallCodec.visiblePrefix(in: LLMCallContext.turnTokenBudget?.partialReply ?? iterAccumulated),
                    modelUsed: ctx.modelId, recalledIds: ctx.resolvedRecalledIds, toolDispatches: dispatches,
                    elapsedMs: Int((DispatchTime.now().uptimeNanoseconds &- startNs) / 1_000_000),
                    rawLLMResponse: lastRawResponse, providerCallCount: providerCallCount, completionState: .incomplete), reason: .approvalRequired)
            }
            if case .stopLoop = outcome { brakeReason = .noProgress; break }
        }

        // A raised need is its own terminal, not exhaustion: the turn ends as
        // "waiting on you", keeping the prose the person already watched
        // render and adding no exhaustion line under it.
        // A finished round returned above; a need outranks the exhaustion
        // below on this lane.
        if TurnSettle.isWaitingOnCard(finishedRound: false, capped: false) {
            return observed(waitingOnInteractionResult(
                ctx: ctx,
                visible: rendersProse
                    ? toolCallCodec.visiblePrefix(in: visibleText)
                    : toolCallCodec.visiblePrefix(in: LLMCallContext.turnTokenBudget?.partialReply ?? lastRoundRaw),
                lastRawResponse: lastRawResponse,
                dispatches: dispatches,
                startNs: startNs,
                providerCallCount: providerCallCount
            ), reason: .interactionRequired)
        }
        // Shared exhaustion tail (C2). Streaming also treats a streamed
        // tool-call round as "only a structured tool call", so it passes
        // lastProviderHadToolCalls as the extra signal.
        return observed(await finishExhaustedTurn(
            ctx: ctx,
            lastRawResponse: rendersProse ? lastRawResponse : lastRoundRaw,
            lastProtocolViolation: lastProtocolViolation,
            loopRecoveryReply: loopRecoveryReply,
            iterationLimit: iterationLimit,
            wallClockElapsedSeconds: wallClockElapsedSeconds,
            dispatches: dispatches,
            startNs: startNs,
            providerCallCount: providerCallCount,
            userMessage: userMessage,
            sessionId: sessionId,
            surface: surface,
            // A marker round's text is its call encoding (and what followed the
            // last marker was written before any result), so it is never the
            // answer, rendered or not.
            additionalStructuredToolCallSignal: (rendersProse || toolCallCodec == .textMarkers)
                && lastProviderHadToolCalls,
            visiblePartial: rendersProse ? toolCallCodec.visiblePrefix(in: visibleText) : "",
            codec: toolCallCodec
        ), reason: wallClockElapsedSeconds == nil ? brakeReason : .wallClockLimit)
    }

    /// 2026-09-22: each round's narration and the answer were concatenated
    /// bare ("worth it.Exactly."). A blank line keeps them apart; the
    /// commentary offset lands before the separator, which the fold trims.
    nonisolated static func joinedProse(_ head: String, _ tail: String) -> String {
        let blank = { (text: String) in text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        return blank(head) || blank(tail) ? head + tail : head + "\n\n" + tail
    }
}
