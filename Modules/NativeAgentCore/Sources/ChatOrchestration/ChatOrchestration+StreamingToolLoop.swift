import Foundation
import Dispatcher
import NativeAgentCore
import PersistenceCore
import MemoryV2
import ProviderRouting
import MacIntegration
import Context

extension SwiftNativeTurnEngine {
    /// Streaming sibling of executeTurnWithToolLoop. It preserves the same
    /// structured tool_use/tool_result conversation shape, but consumes
    /// provider text deltas and tool-call events as they arrive so app chat
    /// surfaces do not look dead while a tool-capable response is running.
    public func executeTurnWithStreamingToolLoop(
        surface: String = "chat",
        userMessage: String,
        sessionId: String? = nil,
        runId: String? = nil,
        maxIterations: Int? = nil,
        turnWallClockSecondsOverride: TimeInterval? = nil,
        llm: any LLMClient,
        tools: any ToolDispatchClient,
        preBuiltContext: TurnContext? = nil,
        progress: ChatOrchestrationProgressHandler? = nil,
        cancelFlagPath: URL? = nil
    ) async throws -> TurnEngineResult {
        // Image-only turn (no caption) is valid when the pre-built context
        // carries image blocks.
        if userMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && (preBuiltContext?.imageBlocks.isEmpty ?? true) {
            throw TurnEngineError.emptyMessage
        }
        let recoveryScope = ProviderToolResultRecoveryStore.Scope(
            sessionId: sessionId,
            turnId: TurnTraceContext.turnId
        )
        defer {
            if let recoveryScope {
                Task { await ProviderToolResultRecoveryStore.shared.remove(scope: recoveryScope) }
            }
        }
        var wholeTurnBudget = WholeTurnWallClockBudget.start(surface: surface, requestedSeconds: turnWallClockSecondsOverride)
        let startNs = DispatchTime.now().uptimeNanoseconds
        // Shared pre-loop context resolution (C2): same build + lazy-filter +
        // snapshot as the non-streaming path so the streaming surface doesn't
        // ship the full eager catalog either.
        let resolvedTurnContext = try await resolveToolLoopContext(
            surface: surface,
            userMessage: userMessage,
            sessionId: sessionId,
            runId: runId,
            preBuiltContext: preBuiltContext
        )

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
        // the structured streaming lane (mirrors the non-streaming sibling and
        // the text-compat call site). Bounded at two; third announcement final.
        var announceNudgeCount = 0
        // FIX 1 (B1.1, 2026-07-23): empty-reply recovery on the streaming lane —
        // sibling of the non-streaming loop and the text-compat lane. Bounded at
        // two; third empty reply accepted as final.
        var emptyReplyNudgeCount = 0
        var emittedProviderFirstDelta = false
        var noProgressGuard = ToolLoopNoProgressGuard()
        var loopRecoveryReply: String?
        // B3 (2026-07-17): the streaming loop is the PRIMARY chat path but never
        // counted provider calls — cost/telemetry undercounted the main surface.
        // One streamMessages call per iteration; count it like the non-streaming
        // loop does, and thread it into both TurnEngineResult returns below.
        var providerCallCount = 0
        // In-loop provider recovery (2026-09-05): sibling of the non-streaming
        // loop's counter. Bounds the recoveries across the WHOLE turn.
        var turnRecoveries = 0
        var wallClockElapsedSeconds: Int?
        let iterationLimit = ToolLoopBudget.resolve(surface: surface, requested: maxIterations)

        streamingIterations: for _ in 0..<iterationLimit {
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
            // User, 2026-09-06: counted HERE, after the last exit above it — the
            // sibling of the non-streaming loop's move. A compaction that
            // exhausted the budget used to leave a counted round that was never
            // made.
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
            var retryAfterDrop: Error?
            var reachedLengthLimit = false
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
            // See the non-streaming sibling: bind the shape the seed actually
            // produced, not the one that was asked for.
            try await ConversationPrefixShape.$override.withValue(prefixSeed.shape) {
            // See the non-streaming sibling: the authoritative current-turn
            // seam, so a replayed archived system block cannot hijack it.
            try await ConversationPrefixBoundary.$currentUserIndex
                .withValue(prefixSeed.currentUserIndex) {
            // User, 2026-09-06: see the non-streaming sibling — the router
            // shortens this call's wall to fit inside the turn's remainder.
            try await LLMCallContext.$remainingTurnSeconds
                .withValue(wholeTurnBudget.remainingSeconds) {
            try await LLMCallContext.$admittedModel.withValue(ctx.modelId) {
            try await LLMCallContext.$providerId.withValue(providerRoute) {
            try await LLMCallContext.$serviceTier.withValue(serviceTier) {
            try await LLMCallContext.$systemSegments.withValue(ctx.systemSegments) {
            try await LLMCallContext.$sessionId.withValue(sessionId) {
            try await LLMCallContext.$reasoningEffort.withValue(ctx.reasoningEffort) {
            let stream = llm.streamMessages(
                messages: attemptMessages,
                system: ctx.systemPrompt,
                model: ctx.modelId,
                surface: surface,
                tools: providerTools.schemas.isEmpty ? nil : providerTools.schemas
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
                       FileManager.default.fileExists(atPath: flag.path) {
                        throw CancellationError()
                    }
                    switch event {
                    case .textDelta(let delta):
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
                        if let marker = ToolCallParser.earliestPotentialProtocolMarker(
                            in: pendingProtocolDelta
                        ) {
                            let safe = String(pendingProtocolDelta[..<marker.lowerBound])
                            pendingProtocolDelta = String(pendingProtocolDelta[marker.lowerBound...])
                            if !safe.isEmpty {
                                iterEmittedProse += safe
                                await progress?(.delta(safe))
                            }
                        } else if pendingProtocolDelta.count > 16 {
                            // Preserve a short cross-chunk tail so a marker
                            // split at an arbitrary SSE boundary is detected
                            // before any part of it reaches the surface.
                            let split = pendingProtocolDelta.index(
                                pendingProtocolDelta.endIndex,
                                offsetBy: -16
                            )
                            let safe = String(pendingProtocolDelta[..<split])
                            pendingProtocolDelta = String(pendingProtocolDelta[split...])
                            if !safe.isEmpty {
                                iterEmittedProse += safe
                                await progress?(.delta(safe))
                            }
                        }
                    case .toolCall(let call):
                        guard !ToolCallParser.isIgnorableToolName(call.name) else {
                            continue
                        }
                        guard let parsed = try? JSONValue.parse(call.inputJSON),
                              case .object(let input) = parsed else {
                            throw LLMError.providerError(message: "streamed tool batch contains invalid object arguments")
                        }
                        streamedCalls.append(ParsedToolCall(id: call.id, name: call.name, input: input))
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
                if let flag = cancelFlagPath,
                   FileManager.default.fileExists(atPath: flag.path) {
                    throw CancellationError()
                }
            } catch is CancellationError {
                // 2026-07-21 audit fix: a user stop mid-stream CARRIES the
                // visible partial (marker-stripped, same as the interrupted
                // path below) so the orchestration catch can persist it with
                // cancelled:true — previously this lane dropped every
                // streamed character on Stop while text-compat persisted it.
                // Cancel still propagates as cancel semantics (not a
                // failure) via the dedicated case.
                let safePartial = ToolCallParser.visiblePrefix(in: visibleText)
                throw TurnEngineError.streamCancelled(
                    partial: safePartial,
                    underlying: CancellationError()
                )
            } catch {
                if case .outputLengthLimit = error as? LLMError {
                    reachedLengthLimit = true
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
                   // the interrupted-stream continuation path below.
                   iterAccumulated.isEmpty, iterEmittedProse.isEmpty, streamedCalls.isEmpty,
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
                let safePartial = ToolCallParser.visiblePrefix(in: visibleText)
                // Wrap the UNDERLYING only: `case .streamInterrupted(partial, _)`
                // pattern-matches upstream still fire (partial persistence), and
                // streamInterrupted's errorDescription flows the wrapped marker
                // through to surface retry ladders.
                throw TurnEngineError.streamInterrupted(
                    partial: safePartial,
                    underlying: ProviderErrorAfterToolEffects.wrapping(error, dispatchCount: ProviderErrorAfterToolEffects.effectfulCount(dispatches))
                )
            }
            } // LLMCallContext.$reasoningEffort.withValue
            } // LLMCallContext.$sessionId.withValue
            } // LLMCallContext.$systemSegments.withValue
            } // LLMCallContext.$serviceTier.withValue
            } // LLMCallContext.$providerId.withValue
            } // LLMCallContext.$admittedModel.withValue
            } // LLMCallContext.$remainingTurnSeconds.withValue
            } // ConversationPrefixBoundary.$currentUserIndex.withValue
            } // ConversationPrefixShape.$override.withValue

            if reachedLengthLimit {
                if Task.isCancelled || cancelFlagPath.map({ FileManager.default.fileExists(atPath: $0.path) }) == true {
                    throw TurnEngineError.streamCancelled(
                        partial: ToolCallParser.visiblePrefix(in: visibleText),
                        underlying: CancellationError()
                    )
                }
                return await finishLengthLimitedTurn(
                    ctx: ctx, partial: visibleText, dispatches: dispatches,
                    startNs: startNs, providerCallCount: providerCallCount
                )
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
                let safePartial = ToolCallParser.visiblePrefix(in: visibleText)
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
                if let flag = cancelFlagPath,
                   FileManager.default.fileExists(atPath: flag.path) {
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
            let recoveryMode = iterEmittedProse.isEmpty ? "replay" : "continuation"
            // User, 2026-09-06: see the non-streaming sibling — Retry-After wins
            // over the ladder's backoff, and a wait longer than the turn's
            // remainder ends the ladder with a notice instead of a dead sleep.
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
            if let flag = cancelFlagPath,
               FileManager.default.fileExists(atPath: flag.path) {
                throw stopCarryingPartial()
            }
            // Same status line as the non-streaming loop, same ordering rules:
            // after the cancellation checks, before the backoff. On this path
            // the user may already be watching prose render, so the notice
            // rides the surface's status lane and never the reply text.
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
            if let flag = cancelFlagPath,
               FileManager.default.fileExists(atPath: flag.path) {
                throw stopCarryingPartial()
            }
            // Same rule as the non-streaming ladder: no attempt starts after
            // the whole-turn budget is spent.
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
                let seen = ToolCallParser.visiblePrefix(in: iterEmittedProse)
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

            if let violation = ToolCallParser.formattedToolCallViolation(in: iterAccumulated) {
                lastProtocolViolation = violation
                violationNudgeCount += 1
                if violationNudgeCount > 2 { break }
                lastProviderHadToolCalls = false
                pendingProtocolDelta.removeAll(keepingCapacity: true)
                lastRawResponse = ""
                if let marker = ToolCallParser.earliestPotentialProtocolMarker(in: visibleText) {
                    visibleText = String(visibleText[..<marker.lowerBound])
                } else {
                    visibleText = ""
                }
                conversation.append(.assistantText(iterAccumulated))
                conversation.append(.user(violation.modelFeedback))
                continue
            }
            lastProtocolViolation = nil
            let providerCalls = ToolCallParser.executableCalls(streamedCalls.isEmpty
                ? ToolCallParser.parse(iterAccumulated)
                : streamedCalls)
            lastProviderHadToolCalls = !providerCalls.isEmpty
            if providerCalls.isEmpty {
                let reply = ToolCallParser.containsOnlyIgnorableCalls(iterAccumulated)
                    ? ToolCallParser.stripToolUseMarkers(iterAccumulated).trimmingCharacters(in: .whitespacesAndNewlines)
                    : iterAccumulated
                // FIX 1 (B1.1): empty-reply recovery, checked BEFORE the announce
                // bounce. Empty text + empty tool calls is not a valid final;
                // nudge (max 2) then accept. Resets the accumulated stream state
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
                    lastRawResponse = ""
                    lastProviderHadToolCalls = false
                    if let marker = ToolCallParser.earliestPotentialProtocolMarker(in: visibleText) {
                        visibleText = String(visibleText[..<marker.lowerBound])
                    } else {
                        visibleText = ""
                    }
                    continue
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
                if announceNudgeCount < 2,
                   !providerTools.schemas.isEmpty,
                   ToolCallParser.looksLikeUnfulfilledActionPromise(reply) {
                    announceNudgeCount += 1
                    conversation.append(.assistantText(iterAccumulated))
                    conversation.append(.user(
                        ToolCallParser.structuredAnnounceContractRemedy(
                            secondBounce: announceNudgeCount == 2
                        )
                    ))
                    pendingProtocolDelta.removeAll(keepingCapacity: true)
                    lastRawResponse = ""
                    lastProviderHadToolCalls = false
                    if let marker = ToolCallParser.earliestPotentialProtocolMarker(in: visibleText) {
                        visibleText = String(visibleText[..<marker.lowerBound])
                    } else {
                        visibleText = ""
                    }
                    continue
                }
                if !pendingProtocolDelta.isEmpty {
                    await progress?(.delta(pendingProtocolDelta))
                    pendingProtocolDelta.removeAll(keepingCapacity: true)
                }
                // Shared completed-turn finish (C2). Streaming passes the
                // accumulated lastRawResponse as rawLLMResponse (vs the
                // non-streaming iteration `raw`).
                //
                // The PERSISTED reply is every visible byte of the turn — the
                // narration streamed before each tool round plus this final
                // iteration's text — not just the last iteration. Single-round
                // turns leave `turnInterstitialProse` empty, so they persist
                // exactly `reply` as before.
                return await finishCompletedTurn(
                    reply: turnInterstitialProse + reply,
                    ctx: ctx,
                    dispatches: dispatches,
                    startNs: startNs,
                    rawLLMResponse: lastRawResponse,
                    providerCallCount: providerCallCount,
                    userMessage: userMessage,
                    sessionId: sessionId,
                    surface: surface
                )
            }

            let pendingProse = ToolCallParser.stripToolUseMarkers(pendingProtocolDelta)
            if !pendingProse.isEmpty {
                iterEmittedProse += pendingProse
                await progress?(.delta(pendingProse))
            }
            pendingProtocolDelta.removeAll(keepingCapacity: true)
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
            // all, exactly as before this fix.
            if !streamedCalls.isEmpty {
                turnInterstitialProse += ToolCallParser.stripToolUseMarkers(iterEmittedProse)
            }
            // Shared post-dispatch round (C2): identical to the non-streaming
            // loop — assistant blocks → shared dispatch core → no-progress guard
            // → paired tool_result append → schema refresh + compat-only sweep.
            // The streaming-only pending-prose flush above runs first.
            let outcome = await runToolDispatchRound(
                providerCalls: providerCalls,
                iterationRawText: iterAccumulated,
                ctx: ctx,
                surface: surface,
                sessionId: sessionId,
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
            // A6 progress extension (same rule as the non-streaming sibling —
            // streamed TEXT is never progress; a landed tool result is).
            if case .continueLoop(let madeProgress) = outcome, madeProgress {
                wholeTurnBudget.recordProgress()
            }
            // User, 2026-09-06: same as the non-streaming sibling — a Stop during
            // the last batch left through the exhaustion tail as `.abandoned`
            // instead of as a cancel. Here the cancellation carries the prose
            // the user already watched render, exactly like a Stop inside the
            // stream does.
            if Task.isCancelled || cancelFlagPath.map({
                FileManager.default.fileExists(atPath: $0.path)
            }) == true {
                let safePartial = ToolCallParser.visiblePrefix(in: visibleText)
                throw TurnEngineError.streamCancelled(
                    partial: safePartial, underlying: CancellationError()
                )
            }
            if case .stopLoop = outcome { break }
        }

        // Shared exhaustion tail (C2). Streaming also treats a streamed
        // tool-call round as "only a structured tool call", so it passes
        // lastProviderHadToolCalls as the extra signal.
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
            surface: surface,
            additionalStructuredToolCallSignal: lastProviderHadToolCalls,
            visiblePartial: ToolCallParser.visiblePrefix(in: visibleText)
        )
    }
}
