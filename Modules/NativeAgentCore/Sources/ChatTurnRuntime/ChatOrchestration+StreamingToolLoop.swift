import ChatToolParsing
import ChatSessionWork
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
import Senses

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
        llm: any LLMClient,
        tools: any ToolDispatchClient,
        preBuiltContext: TurnContext? = nil,
        progress: ChatOrchestrationProgressHandler? = nil,
        cancelFlagPath: URL? = nil,
        /// Asked before every provider call, retries included. Admission errors
        /// stay with their owner; provider recovery cannot override them.
        providerAdmission: (@Sendable () async throws -> Void)? = nil
    ) async throws -> TurnEngineResult {
        return try await ChatToolSessionContext.$userText.withValue(userMessage) {
        try await SenseTurnReads.$current.withValue(SenseTurnReads.current ?? SenseTurnReads()) {
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
        var cleanFinish = false
        defer {
            if cleanFinish || Task.isCancelled || ChatCancelFlag.isRaised(cancelFlagPath), let recoveryScope {
                Task { await ProviderToolResultRecoveryStore.shared.remove(scope: recoveryScope) }
            }
        }
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
        // Steered messages reach the queue owner as delivered at the same
        // moment instructions do: the round carrying them produced output.
        var steeringOffers: [ChatTurnSteering.Offer] = []
        func commitDelivery() async throws {
            commitInstructionDelivery?()
            commitInstructionDelivery = nil
            guard let sessionId, !steeringOffers.isEmpty else { return }
            let offers = steeringOffers
            steeringOffers = []
            guard await ChatTurnSteering.shared.markDelivered(offers, sessionId: sessionId) else {
                throw ChatOrchestrationError.underlying("Couldn't commit steering delivery; the message stays queued.")
            }
        }

        // The provider-name map is built from the array and then held still
        // for the whole turn.
        let providerTools = ProviderToolNameMap(resolvedTurnContext.toolSchemas)
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
                        surface: compactionSurface, purpose: "compaction"
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
        func observed(_ result: TurnEngineResult, reason: TurnEngineResult.TerminalReason) -> TurnEngineResult {
            cleanFinish = reason == .replyCompleted || reason == .incomplete
            return result.observingTerminal(reason: reason, counters: counters)
        }
        var lastRawResponse = ""
        var visibleText = ""
        var turnInterstitialProse = ""
        var retainedAnswerProse = ""
        var emittedProviderFirstDelta = false
        var noProgressGuard = ToolLoopNoProgressGuard()
        var providerCallCount = 0
        var replyTextSettled = false
        var retryAttempt = 0

        if let restarted = TurnCheckpointScope.resuming, restarted.runId == runId,
           restarted.turnId == TurnTraceContext.turnId {
            let rows = TurnCheckpointScope.resumedRows
            let receipts = rows.filter { SessionHistoryPromptRenderer.renderable($0)?.isTool == true }
            dispatches = receipts.compactMap { row in
                guard case .object(let fields)? = row.extras, case .object(let metadata)? = fields["metadata"],
                      case .string(let name)? = metadata["toolName"],
                      case .string(let raw)? = metadata["resultBody"] ?? metadata["resultSummary"],
                      var result = try? JSONValue.parse(Data(raw.utf8)) else { return nil }
                if let images = metadata["generatedImages"], case .object(var fields) = result {
                    fields["images"] = images
                    result = .object(fields)
                }
                let input: [String: JSONValue]
                if case .string(let raw)? = metadata["inputJSON"],
                   case .object(let saved)? = try? JSONValue.parse(Data(raw.utf8)) { input = saved }
                else { input = [:] }
                return TurnEngineResult.ToolDispatchRecord(
                    name: metadata["generatedImages"] == nil ? name : "image_generate", input: input, result: result)
            }
            guard let user = rows.first(where: { $0.role == "user" }) else {
                throw ChatOrchestrationError.underlying("The resumed turn's saved user message is missing; repair its transcript.")
            }
            let replay = SessionHistoryMessageProjection.project(messages: [user] + receipts,
                historyLimit: max(1, receipts.count + 1), surface: surface, windowTokens: turnWindowTokens)
            visibleText = restarted.keptProse
            turnInterstitialProse = String(restarted.keptProse.prefix(restarted.workingCommentaryCharacters))
            retainedAnswerProse = String(restarted.keptProse.dropFirst(restarted.workingCommentaryCharacters))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !restarted.workingNotes.isEmpty { conversation.append(.assistantText(restarted.workingNotes)) }
            TurnObservation.apply(.restarted(stepsDone: receipts.count,
                unknownStep: restarted.runningStep == nil ? nil : receipts.count + 1),
                kept: restarted.keptProse, to: &conversation, surface: surface)
            // Reuse the history projection, without inventing provider call IDs.
            if let last = conversation.last {
                conversation[conversation.count - 1] = LLMMessage(role: last.role,
                    content: last.content + replay.messages.dropFirst().flatMap(\.content))
            }
            if !visibleText.isEmpty { await progress?(.delta(visibleText)) }
        }

        func finishIncompleteTurn() async -> TurnEngineResult {
            observed(await finishCompletedTurn(
                reply: Self.joinedProse(turnInterstitialProse, retainedAnswerProse),
                ctx: ctx, dispatches: dispatches,
                startNs: startNs, rawLLMResponse: lastRawResponse,
                providerCallCount: providerCallCount, userMessage: userMessage,
                sessionId: sessionId, surface: surface,
                workingCommentaryCharacters: turnInterstitialProse.isEmpty ? nil : turnInterstitialProse.count,
                completionState: .incomplete
            ), reason: .incomplete)
        }

        func stopCarryingPartial() -> Error {
            TurnEngineError.streamCancelled(
                partial: toolCallCodec.visiblePrefix(in: visibleText),
                underlying: CancellationError())
        }

        while true {
            if Task.isCancelled || ChatCancelFlag.isRaised(cancelFlagPath) {
                throw stopCarryingPartial()
            }
            if replyTextSettled {
                replyTextSettled = false
                await progress?(.replyTextSettled(false))
            }
            _ = await IntraTurnContextCompaction.compactProactivelyIfNeeded(
                conversation: &conversation,
                turnStartIndex: compactionTurnStart,
                windowTokens: turnWindowTokens,
                distill: distillWorkingNotes,
                surface: surface,
                turnRecoveries: counters.providerRecoveryCount,
                progress: progress
            )
            try await TurnCheckpointScope.current?.capture(
                prose: Self.joinedProse(turnInterstitialProse, retainedAnswerProse),
                commentaryCharacters: turnInterstitialProse.count, conversation: conversation, nextIteration: true)
            var iterAccumulated = ""
            var iterEmittedProse = ""
            var streamedCalls: [ParsedToolCall] = []
            var toolBoundaryReason: LLMToolBoundaryReason?
            var pendingProtocolDelta = ""
            let roundBaseVisibleText = visibleText
            let roundBaseRawResponse = lastRawResponse
            let roundStarted = DispatchTime.now().uptimeNanoseconds

            // Only prose can survive an incomplete stream; none of its calls ran.
            func keepPartial() async -> String {
                let kept = toolBoundaryReason == .fabricatedResult
                    ? iterEmittedProse : toolCallCodec.visiblePrefix(in: iterAccumulated)
                if kept.hasPrefix(iterEmittedProse) {
                    let tail = String(kept.dropFirst(iterEmittedProse.count))
                    if !tail.isEmpty { await progress?(.delta(tail)) }
                }
                visibleText = roundBaseVisibleText + kept
                lastRawResponse = roundBaseRawResponse + kept
                retainedAnswerProse = Self.joinedProse(retainedAnswerProse, kept)
                streamedCalls.removeAll(keepingCapacity: true)
                pendingProtocolDelta.removeAll(keepingCapacity: true)
                return kept
            }

            do { try await providerAdmission?() }
            catch is CancellationError { throw stopCarryingPartial() }
            do {
                if !dispatches.isEmpty, let sessionId, !sessionId.isEmpty {
                    let offers = await ChatTurnSteering.shared.drain(
                        sessionId: sessionId, cancelFlagPath: cancelFlagPath)
                    if Task.isCancelled || ChatCancelFlag.isRaised(cancelFlagPath) {
                        throw CancellationError()
                    }
                    steeringOffers += offers
                    for offer in offers {
                        Self.appendStructuredUserNudge(
                            ChatTurnSteering.deliveryText(offer.text), to: &conversation)
                    }
                    if let root = remPinsDataRoot, !sessionId.hasPrefix("bot-"), PeerDataTaint.current?.isTainted != true,
                       [nil, "self"].contains(ChatToolSessionContext.envelope?.agent),
                       let arrived = ResidentWake.shared.take(dataRoot: root) {
                        Self.appendStructuredUserNudge(arrived, to: &conversation)
                    }
                }
                providerCallCount += 1
                counters.providerAttemptCount += 1
                if retryAttempt == 0 {
                    counters.providerRoundCount += 1
                    if previousRoundFailed { counters.roundsAfterToolFailureCount += 1 }
                    previousRoundFailed = false
                } else {
                    counters.providerRecoveryCount += 1
                }
                // Construction and consumption share the async task-local scope.
                let providerRoute = ctx.providerId ?? LLMCallContext.providerId
                let serviceTier = ctx.serviceTier ?? LLMCallContext.serviceTier
                let purpose = LLMCallContext.purpose == "other"
                    ? (dispatches.isEmpty ? "turn" : "tool_round") : LLMCallContext.purpose
                let consumeStream: () async throws -> Void = {
                    try await LLMCallContext.$purpose.withValue(purpose) {
                    let stream = llm.streamMessages(
                        messages: conversation,
                        system: wireSystem.prompt,
                        model: ctx.modelId,
                        surface: surface,
                        tools: toolCallCodec.requestTools(providerTools.schemas)
                    )
                    for try await event in stream {
                        try Task.checkCancellation()
                        if ChatCancelFlag.isRaised(cancelFlagPath) { throw CancellationError() }
                        switch event {
                        case .toolBoundary(let reason):
                            toolBoundaryReason = reason
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
                                await ctx.fluidContextTurn?.recordDelivery()
                                try await commitDelivery()
                                if !emittedProviderFirstDelta {
                                    emittedProviderFirstDelta = true
                                    TurnLifecycleTelemetry.emit(
                                        .providerFirstDelta, surface: surface, sessionId: sessionId,
                                        observedBy: "structured_tool_loop.stream")
                                }
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
                            await ctx.fluidContextTurn?.recordDelivery()
                            try await commitDelivery()
                            guard let parsed = try toolCallCodec.decode(call) else { continue }
                            streamedCalls.append(parsed)
                            let args = String(data: call.inputJSON, encoding: .utf8) ?? "{}"
                            lastRawResponse += "\n<tool_use id=\"\(call.id)\" name=\"\(call.name)\">\(args)</tool_use>"
                        case .keepAlive:
                            break
                        }
                    }
                    try Task.checkCancellation()
                    if ChatCancelFlag.isRaised(cancelFlagPath) { throw CancellationError() }
                    try await commitDelivery()
                    }
                }
                try await ConversationPrefixBoundary.$currentUserIndex.withValue(prefixSeed.currentUserIndex) {
                try await LLMCallContext.$admittedModel.withValue(ctx.modelId) {
                try await LLMCallContext.$providerId.withValue(providerRoute) {
                try await LLMCallContext.$serviceTier.withValue(serviceTier) {
                try await LLMCallContext.$systemSegments.withValue(wireSystem.segments) {
                try await LLMCallContext.$sessionId.withValue(sessionId) {
                try await LLMCallContext.$reasoningEffort.withValue(ctx.reasoningEffort) {
                try await AnthropicOAuthDirectAdapter.MessagesCacheHint.$withinTurnReuse.withValue(true) {
                try await InspectorThinkingLane.$summarizedThinking
                    .withValue(InspectorThinkingLane.isEnabledForSurface(surface)) {
                    try await consumeStream()
                }
                }
                }
                }
                }
                }
                }
                }
                }
            } catch {
                if Task.isCancelled || ChatCancelFlag.isRaised(cancelFlagPath) || error is CancellationError {
                    throw stopCarryingPartial()
                }
                counters.failedProviderAttemptCount += 1
                if iterAccumulated.isEmpty, case .outputLengthLimit(let partial) = error as? LLMError {
                    iterAccumulated = partial
                }
                let kept = await keepPartial()
                if case .outputLengthLimit = error as? LLMError,
                   LLMCallContext.turnTokenBudget?.exhausted == true {
                    return await finishIncompleteTurn()
                }
                if ProviderRecoveryPolicy.isContextOverflow(error) {
                    let receipt = await IntraTurnContextCompaction.compact(
                        conversation: &conversation, turnStartIndex: compactionTurnStart,
                        windowTokens: turnWindowTokens, pressure: .overflow, distill: distillWorkingNotes)
                    if Task.isCancelled || ChatCancelFlag.isRaised(cancelFlagPath) { throw stopCarryingPartial() }
                    counters.contextOverflowRecoveryCount += 1
                    TurnTraceBus.fireFromContext(
                        kind: TurnLifecycleMilestone.contextIntraTurnCompaction.rawValue,
                        surface: surface, payload: IntraTurnContextCompaction.tracePayload(
                            receipt, trigger: "overflow", turnRecoveries: counters.providerRecoveryCount))
                    if receipt.mode == "none" {
                        await progress?(.notice(kind: "context_full",
                            text: ProviderFailure.contextTooLong.localizedDescription))
                        return await finishIncompleteTurn()
                    }
                    TurnObservation.apply(.contextFull, kept: kept, to: &conversation, surface: surface)
                    await progress?(.notice(kind: IntraTurnContextCompaction.noticeKind,
                        text: IntraTurnContextCompaction.noticeText))
                } else if case .outputLengthLimit = error as? LLMError {
                    TurnObservation.apply(.lengthLimit(chars: kept.count), kept: kept, to: &conversation, surface: surface)
                } else if ProviderRecoveryPolicy.isEmptyReply(error) {
                    counters.emptyReplyRoundCount += 1
                    TurnObservation.apply(.emptyReply, kept: kept, to: &conversation, surface: surface)
                } else if ProviderRecoveryPolicy.isRecoverable(error) {
                    retryAttempt += 1
                    let delay = ProviderRecoveryPolicy.retryDelaySeconds(forRetry: retryAttempt, error: error)
                    let elapsed = Int((DispatchTime.now().uptimeNanoseconds &- roundStarted) / 1_000_000_000)
                    if kept.isEmpty {
                        counters.providerReplayCount += 1
                        // An empty transport cut replays the identical conversation.
                        TurnObservation.record(.cut(seconds: elapsed, keptChars: 0), surface: surface)
                    } else {
                        counters.providerContinuationCount += 1
                        TurnObservation.apply(.cut(seconds: elapsed, keptChars: kept.count),
                            kept: kept, to: &conversation, surface: surface)
                    }
                    ProviderRetryTrace.emit(error: error, attempt: retryAttempt,
                        delaySeconds: delay, mode: kept.isEmpty ? "replay" : "continuation",
                        turnRecoveries: counters.providerRecoveryCount, surface: surface)
                    await progress?(.notice(kind: "provider_retry",
                        text: ProviderRecoveryPolicy.reconnectStatus(attemptsMade: retryAttempt)))
                    do { try await providerRecoverySleep(delay) }
                    catch is CancellationError { throw stopCarryingPartial() }
                } else {
                    switch ProviderFailure.classify(error) {
                    case .authExpired, .codexCLISessionExpired, .routingUnavailable, .modelUnavailable:
                        throw TurnEngineError.streamInterrupted(partial: visibleText, underlying: error)
                    case .refused:
                        TurnObservation.apply(.refused(reason: ProviderFailure.diagnosticDescription(error)),
                            kept: kept, to: &conversation, surface: surface)
                    default:
                        TurnObservation.apply(.malformedCall(why: ProviderFailure.diagnosticDescription(error)),
                            kept: kept, to: &conversation, surface: surface)
                    }
                }
                continue
            }
            retryAttempt = 0
            if toolBoundaryReason == .outputLimit {
                let kept = await keepPartial()
                if LLMCallContext.turnTokenBudget?.exhausted == true {
                    return await finishIncompleteTurn()
                }
                TurnObservation.apply(.lengthLimit(chars: kept.count), kept: kept, to: &conversation, surface: surface)
                continue
            }
            let markerCodec = toolCallCodec == .textMarkers
                ? TextMarkerCodec(schemas: activeToolSchemas,
                    turnActiveTools: LLMCallContext.turnActiveTools ?? [], catalogNames: Set(ctx.toolsAvailable))
                : nil
            let violation = markerCodec?.malformedCall(in: iterAccumulated)
                ?? ToolCallParser.formattedToolCallViolation(in: iterAccumulated, toolNames: Set(ctx.toolsAvailable))
            if let violation {
                counters.protocolViolationRoundCount += 1
                let rejectedBytes = Data(iterAccumulated.utf8)
                TurnTraceBus.fireFromContext(kind: "tool.protocol_violation", surface: surface, payload: .object([
                    "type": .string(violation.traceType),
                    "byteSize": .int(Int64(rejectedBytes.count)),
                    "sha256": .string(SHA256.hash(data: rejectedBytes).map { String(format: "%02x", $0) }.joined()),
                ]))
                let kept = await keepPartial()
                TurnObservation.apply(.malformedCall(why: violation.modelFeedback),
                    kept: kept, to: &conversation, surface: surface)
                continue
            }
            let providerCalls = toolCallCodec.roundCalls(
                streamed: streamedCalls, text: iterAccumulated, schemas: activeToolSchemas)
            if providerCalls.isEmpty {
                if let toolBoundaryReason {
                    let kept = await keepPartial()
                    TurnObservation.apply(.boundary(toolBoundaryReason), kept: kept, to: &conversation, surface: surface)
                    continue
                }
                if iterAccumulated.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    counters.emptyReplyRoundCount += 1
                    TurnObservation.apply(.emptyReply, to: &conversation, surface: surface)
                    continue
                }
                let promisesWork = (markerCodec?.promisesUnfulfilledWork(iterAccumulated)
                    ?? (!providerTools.schemas.isEmpty && ToolCallParser.looksLikeUnfulfilledActionPromise(iterAccumulated)))
                    || (dispatches.contains(where: { !ChatToolOutcome.neverRan($0.result) })
                        && ToolCallParser.looksLikeAnnouncedNextToolStep(iterAccumulated))
                if promisesWork {
                    counters.unfulfilledPromiseRoundCount += 1
                    let kept = await keepPartial()
                    TurnObservation.apply(.announcedNoCall, kept: kept, to: &conversation, surface: surface)
                    continue
                }
                if !pendingProtocolDelta.isEmpty {
                    await progress?(.delta(toolCallCodec.visiblePrefix(in: pendingProtocolDelta)))
                }
                let completed = await finishCompletedTurn(
                    reply: Self.joinedProse(turnInterstitialProse,
                        Self.joinedProse(retainedAnswerProse, iterAccumulated)),
                    ctx: ctx, dispatches: dispatches, startNs: startNs,
                    rawLLMResponse: lastRawResponse, providerCallCount: providerCallCount,
                    userMessage: userMessage, sessionId: sessionId, surface: surface,
                    workingCommentaryCharacters: turnInterstitialProse.isEmpty ? nil : turnInterstitialProse.count)
                return observed(completed, reason: completed.resolvedTerminalReason(dataRoot: remPinsDataRoot))
            }

            let pendingProse = toolBoundaryReason == .fabricatedResult
                ? "" : toolCallCodec.proseReleasedAtDispatch(pendingProtocolDelta)
            if !pendingProse.isEmpty {
                iterEmittedProse += pendingProse
                await progress?(.delta(pendingProse))
            }
            visibleText = roundBaseVisibleText + iterEmittedProse
            turnInterstitialProse = Self.joinedProse(turnInterstitialProse, iterEmittedProse)
            counters.toolRoundCount += 1
            try await TurnCheckpointScope.current?.capture(
                prose: Self.joinedProse(turnInterstitialProse, retainedAnswerProse),
                commentaryCharacters: turnInterstitialProse.count, conversation: conversation,
                startingCalls: providerCalls.count)
            let roundStart = dispatches.count
            let outcome = await runToolDispatchRound(
                providerCalls: providerCalls,
                iterationRawText: toolCallCodec == .textMarkers ? iterAccumulated : iterEmittedProse,
                ctx: ctx, surface: surface, sessionId: toolSessionId ?? sessionId,
                tools: tools, progress: progress, conversation: &conversation,
                dispatches: &dispatches, providerTools: providerTools,
                noProgressGuard: &noProgressGuard, cancelFlagPath: cancelFlagPath,
                markerCodec: markerCodec, toolBoundaryReason: toolBoundaryReason)
            previousRoundFailed = dispatches.dropFirst(roundStart).contains {
                !ChatToolOutcome.outputLooksSuccessful($0.result)
                    && !ChatToolOutcome.wasCancelled($0.result)
                    && !ToolLoopTraceObservation.wasStopped($0.result)
                    && !ChatToolOutcome.isWaitingOnPerson($0.result)
                    && !ChatToolOutcome.neverRan($0.result)
            }
            if Task.isCancelled || ChatCancelFlag.isRaised(cancelFlagPath) { throw stopCarryingPartial() }
            if StandingBotContinuity.isHelperTurn, ChatTurnExecution.current?.waitingForApproval == true {
                return observed(waitingOnInteractionResult(ctx: ctx, visible: visibleText,
                    lastRawResponse: lastRawResponse, dispatches: dispatches,
                    startNs: startNs, providerCallCount: providerCallCount), reason: .approvalRequired)
            }
            if case .waiting(let reason) = outcome {
                return observed(waitingOnInteractionResult(ctx: ctx, visible: visibleText,
                    lastRawResponse: lastRawResponse, dispatches: dispatches,
                    startNs: startNs, providerCallCount: providerCallCount), reason: reason)
            }
        }
        }
        }
    }

    /// 2026-09-22: each round's narration and the answer were concatenated
    /// bare ("worth it.Exactly."). A blank line keeps them apart; the
    /// commentary offset lands before the separator, which the fold trims.
    nonisolated static func joinedProse(_ head: String, _ tail: String) -> String {
        let blank = { (text: String) in text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        return blank(head) || blank(tail) ? head + tail : head + "\n\n" + tail
    }
}
