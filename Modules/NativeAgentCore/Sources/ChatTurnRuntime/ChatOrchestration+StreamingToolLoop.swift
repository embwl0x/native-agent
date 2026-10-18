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
import os

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
        // build + lazy-filter (so the turn never ships the full eager catalog).
        let gathered = try await resolveToolLoopContext(
            surface: surface, userMessage: userMessage, sessionId: sessionId, preBuiltContext: preBuiltContext)
        // Her turn part runs the turn's decisions; this loop runs its effects.
        // The message goes in first; a turn resumed after a relaunch rebuilds
        // from its log, and hears `resumed` when an effect was in flight.
        let restarted = TurnCheckpointScope.resuming.flatMap {
            $0.runId == runId && $0.turnId == TurnTraceContext.turnId ? $0 : nil
        }
        var part = try await TurnPart(dataRoot: remPinsDataRoot ?? defaultDataRoot(), surface: surface, stop: cancelFlagPath,
                                      context: gathered, log: restarted?.log ?? [])
        defer { part.tellHer() }
        var inFlight = false
        if part.log.isEmpty {
            try await part.deliver([.object([
                "type": .string("message"), "text": .string(gathered.userMessage), "surface": .string(surface),
                "attachments": .array(gathered.imageBlocks.compactMap {
                    if case .image(_, _, let name, _) = $0 { .string(name ?? "image") } else { nil }
                }),
                "who": .string(ChatPersistenceContext.originPrincipal),
                "trust": .string(PeerDataTaint.current?.isTainted == true ? "untrusted" : "trusted"),
            ])])
        } else {
            inFlight = try await part.resume()
        }
        try Task.checkCancellation()
        guard let system = part.system else {
            throw TurnEngineError.turnPartFailed("Its log opened with no model.call naming the system.")
        }
        let resolvedTurnContext = gathered.composing(system, tools: part.offeredTools)
        let traceSessionId = Self.fireContextSnapshotEvent(
            surface: surface, context: resolvedTurnContext, sessionId: sessionId, runId: runId)
        // The request milestone belongs to the dispatch it names: the transport
        // calls this once routing is validated and the adapter chosen, and the
        // turn's first such call is its request start.
        let requestStarted = OSAllocatedUnfairLock(initialState: false)
        let requestDispatched: @Sendable () -> Void = {
            guard requestStarted.withLock({ started in defer { started = true }; return !started }) else { return }
            TurnLifecycleTelemetry.emit(.providerRequestStarted, surface: surface, sessionId: traceSessionId,
                                        observedBy: "transport.dispatch", flags: ["initialRequest": true])
        }
        Self.fireAssemblyStageEvent(surface: surface, context: resolvedTurnContext)
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

        // How tools are offered and calls read back, per provider (8a seam).
        // Chosen from the provider the client itself resolves under the SAME
        // bindings every call of this turn runs with: the admitted route when
        // the turn carries one, the surface's pick when it carries none.
        let toolCallCodec = ToolCallCodec.forProvider(
            await LLMCallContext.$admittedModel.withValue(resolvedTurnContext.modelId) {
                await LLMCallContext.$providerId.withValue(resolvedTurnContext.providerId ?? LLMCallContext.providerId) {
                    await llm.servingProviderID(model: resolvedTurnContext.modelId, surface: surface)
                }
            }
        )
        /// The request her part's opening model.call names, seeded as the turn's
        /// prefix; seeded again when a heal brings a version that names another.
        func seeded(_ composed: TurnContext) -> (ConversationPrefixSeeding.Seed, (prompt: String?, segments: SystemPromptSegments?)) {
            let seed = ConversationPrefixSeeding.seed(
                composed,
                // The marker catalog's session-loaded run rides the volatile block
                // on v2, so a mid-session tool_load cannot move the cached prefix.
                textToolCatalogAppendix: toolCallCodec == .textMarkers
                    ? TextMarkerCodec.volatileCatalogAppendix(for: composed)
                    : nil
            )
            let ctx = seed.context
            guard toolCallCodec == .textMarkers else { return (seed, (ctx.systemPrompt, ctx.systemSegments)) }
            let layout = TextMarkerCodec.systemLayout(baseSystem: ctx.systemPrompt, segments: ctx.systemSegments, context: ctx)
            return (seed, (layout.system, layout.segments))
        }
        var (prefixSeed, wireSystem) = seeded(resolvedTurnContext)
        var composed = (system: system, tools: part.offeredTools)
        var ctx = prefixSeed.context
        // The provider-name map is built from the array and then held still
        // until a heal names other tools.
        var providerTools = ProviderToolNameMap(ctx.toolSchemas)
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
        var compactionTurnStart = prefixSeed.messages.count - 1
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
        var retryingLiveFirstOutputCut = false

        if let restarted {
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
                let ranCall: (tool: String, input: [String: JSONValue])
                if case .object(let saved)? = metadata["ranCall"],
                   case .string(let tool)? = saved["tool"], case .object(let args)? = saved["input"] {
                    ranCall = (tool, args)
                } else {
                    // Legacy receipts only prove their saved name/input, never a current binding.
                    ranCall = (metadata["generatedImages"] == nil ? name : "image_generate", input)
                }
                return TurnEngineResult.ToolDispatchRecord(
                    name: metadata["generatedImages"] == nil ? name : "image_generate", input: input,
                    ranCall: ranCall, result: result)
            }
            guard let user = rows.first(where: { $0.role == "user" }) else {
                throw ChatOrchestrationError.underlying("The resumed turn's saved user message is missing; repair its transcript.")
            }
            let replay = SessionHistoryMessageProjection.project(messages: [user] + receipts,
                historyLimit: max(1, receipts.count + 1), windowTokens: turnWindowTokens)
            visibleText = restarted.keptProse
            turnInterstitialProse = String(restarted.keptProse.prefix(restarted.workingCommentaryCharacters))
            retainedAnswerProse = String(restarted.keptProse.dropFirst(restarted.workingCommentaryCharacters))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !restarted.workingNotes.isEmpty { conversation.append(.assistantText(restarted.workingNotes)) }
            let resumed = TurnObservation.Kind.restarted(stepsDone: receipts.count,
                unknownStep: restarted.runningStep == nil ? nil : receipts.count + 1)
            TurnObservation.apply(resumed, kept: restarted.keptProse, to: &conversation, surface: surface)
            // Reuse the history projection, without inventing provider call IDs.
            if let last = conversation.last {
                conversation[conversation.count - 1] = LLMMessage(role: last.role,
                    content: last.content + replay.messages.dropFirst().flatMap(\.content))
            }
            if !visibleText.isEmpty { await progress?(.delta(visibleText)) }
            if !part.streamed.isEmpty { await progress?(.delta(part.streamed)) }
            if inFlight {
                try await part.deliver([.object(["type": .string("resumed"),
                    "text": .string(TurnObservation.text(resumed)), "steps": .int(Int64(receipts.count))])])
            }
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

        /// Lane A's observation, applied (or only recorded) by the stem and
        /// handed to her part, which says how to go on.
        func observe(_ kind: TurnObservation.Kind, kept: String = "", applying: Bool = true) async throws {
            if applying { TurnObservation.apply(kind, kept: kept, to: &conversation, surface: surface) }
            else { TurnObservation.record(kind, kept: kept, surface: surface) }
            try await part.deliver([.object(["type": .string("observation"), "text": .string(TurnObservation.text(kind))])])
        }
        /// Her final words: the model's answer and anything she streamed, exactly as sent.
        var answerProse = part.streamed
        /// Every effect boundary checkpoints the turn with its log.
        func capture(startingCalls: Int = 0) async throws {
            try await TurnCheckpointScope.current?.capture(
                prose: Self.joinedProse(turnInterstitialProse, retainedAnswerProse),
                commentaryCharacters: turnInterstitialProse.count, conversation: conversation, log: part.log,
                startingCalls: startingCalls)
        }
        /// The model round whose calls the next app effects dispatch.
        var round: (calls: [ParsedToolCall], raw: String, codec: TextMarkerCodec?, boundary: LLMToolBoundaryReason?)?

        while true {
            if Task.isCancelled || ChatCancelFlag.isRaised(cancelFlagPath) {
                throw stopCarryingPartial()
            }
            guard let effect = try await part.next() else {
                let completed = await finishCompletedTurn(
                    reply: Self.joinedProse(turnInterstitialProse, Self.joinedProse(retainedAnswerProse, answerProse)),
                    ctx: ctx, dispatches: dispatches, startNs: startNs,
                    rawLLMResponse: lastRawResponse, providerCallCount: providerCallCount,
                    userMessage: userMessage, sessionId: sessionId, surface: surface,
                    workingCommentaryCharacters: turnInterstitialProse.isEmpty ? nil : turnInterstitialProse.count,
                    afterTurn: part.afterTurn)
                return observed(completed, reason: completed.resolvedTerminalReason(dataRoot: remPinsDataRoot))
            }
            switch effect["effect"] {
            case .string("reply.stream"):
                if case .string(let text)? = effect["text"], !text.isEmpty {
                    await progress?(.delta(text))
                    visibleText += text
                    answerProse += text
                    part.sent(text)
                }
                try await capture()
                continue
            case .string("app"):
                // The part names calls of this model round; they run verbatim.
                var batch = [effect]
                while part.nextIsApp, let more = try await part.next() { batch.append(more) }
                guard let round else { throw TurnEngineError.turnPartFailed("Its app effects came with no model round to run.") }
                let indices = batch.compactMap { if case .int(let at)? = $0["index"] { Int(at) } else { nil } }
                let providerCalls = indices.map { round.calls[$0] }
                counters.toolRoundCount += 1
                try await capture(startingCalls: providerCalls.count)
                let roundStart = dispatches.count
                let outcome = await runToolDispatchRound(
                    providerCalls: providerCalls,
                    iterationRawText: round.raw,
                    ctx: ctx, surface: surface, sessionId: toolSessionId ?? sessionId,
                    tools: tools, progress: progress, conversation: &conversation,
                    dispatches: &dispatches, providerTools: providerTools,
                    noProgressGuard: &noProgressGuard, cancelFlagPath: cancelFlagPath,
                    markerCodec: round.codec, toolBoundaryReason: round.boundary)
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
                // dispatchIterationCalls keeps call order and runs every call but an ignorable one.
                var records = dispatches.dropFirst(roundStart).makeIterator()
                try await part.deliver(indices.map { index in
                    let call = round.calls[index]
                    let record = ToolCallParser.isIgnorableToolName(call.name) ? nil : records.next()
                    return .object(["type": .string("result"), "index": .int(Int64(index)), "id": .string(call.id),
                                    "name": .string(call.name), "ok": .bool(record.map { ChatToolOutcome.outputLooksSuccessful($0.result) } ?? false)])
                })
                continue
            case .string("model.call"):
                // A heal brought a version that names another system or tools.
                if let system = part.system, system != composed.system || part.offeredTools != composed.tools {
                    let seededCount = prefixSeed.messages.count
                    (prefixSeed, wireSystem) = seeded(gathered.composing(system, tools: part.offeredTools))
                    ctx = prefixSeed.context
                    providerTools = ProviderToolNameMap(ctx.toolSchemas)
                    conversation = prefixSeed.messages + conversation.dropFirst(seededCount)
                    compactionTurnStart = prefixSeed.messages.count - 1
                    composed = (system, part.offeredTools)
                }
            default:
                // reply.end and after: the part's own bookkeeping, checkpointed like any effect.
                try await capture()
                continue
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
            try await capture()
            var iterAccumulated = ""
            var iterEmittedProse = ""
            var streamedCalls: [ParsedToolCall] = []
            var toolBoundaryReason: LLMToolBoundaryReason?
            var pendingProtocolDelta = ""
            let rawProviderEvents = OSAllocatedUnfairLock<String>(initialState: "")
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
                if let sessionId, !sessionId.isEmpty {
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
                let purpose: String
                if LLMCallContext.purpose == "other", case .string(let named)? = effect["purpose"] { purpose = named }
                else { purpose = LLMCallContext.purpose }
                let captureEvents: @Sendable (SSEEvent) -> Void = { event in
                    guard providerRoute == "anthropic_oauth_direct" else { return }
                    rawProviderEvents.withLock { raw in
                        if let name = event.event { raw += "event: \(name)\n" }
                        raw += "data: " + event.data.replacingOccurrences(of: "\n", with: "\ndata: ") + "\n\n"
                    }
                }
                let consumeStream: () async throws -> Void = {
                    try await ProviderStreamContext.$retryingLiveFirstOutputCut.withValue(retryingLiveFirstOutputCut) {
                    try await ProviderStreamContext.$diagnosticEvent.withValue(captureEvents) {
                    try await ProviderStreamContext.$dispatched.withValue(requestDispatched) {
                    try await LLMCallContext.$purpose.withValue(purpose) {
                    let stream = llm.streamMessages(
                        messages: conversation,
                        system: wireSystem.prompt,
                        model: ctx.modelId,
                        surface: surface,
                        tools: toolCallCodec.requestTools(providerTools.schemas)
                    )
                    streaming: for try await event in stream {
                        try Task.checkCancellation()
                        if ChatCancelFlag.isRaised(cancelFlagPath) { throw CancellationError() }
                        // A Steer waits: cut here, keep what was said, and the next
                        // round reads the person's words (the drain below).
                        if let sessionId, !sessionId.isEmpty, ChatTurnSteering.hasPending(sessionId) {
                            toolBoundaryReason = .steered
                            break streaming
                        }
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
                    // A steer cut is not the stream's end: nothing more was said, so an
                    // offer read this round is not marked delivered by it (Sol).
                    if toolBoundaryReason != .steered { try await commitDelivery() }
                    }
                    }
                    }
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
                if ProviderFailure.classify(error) == .malformedResponse {
                    let raw = rawProviderEvents.withLock { $0 }
                    if !raw.isEmpty { RunawayOutputDetector.writeDiagnostic(raw, reason: "malformed_stream") }
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
                    try await observe(.contextFull, kept: kept)
                    await progress?(.notice(kind: IntraTurnContextCompaction.noticeKind,
                        text: IntraTurnContextCompaction.noticeText))
                } else if case .outputLengthLimit = error as? LLMError {
                    try await observe(.lengthLimit(chars: kept.count), kept: kept)
                } else if ProviderRecoveryPolicy.isEmptyReply(error) || ProviderRecoveryPolicy.isRecoverable(error) {
                    retryingLiveFirstOutputCut = retryingLiveFirstOutputCut
                        || (error as? ProviderFailure.Diagnostic)?.liveFirstOutputCut == true
                    retryAttempt += 1
                    let delay = ProviderRecoveryPolicy.retryDelaySeconds(forRetry: retryAttempt, error: error)
                    let elapsed = Int((DispatchTime.now().uptimeNanoseconds &- roundStarted) / 1_000_000_000)
                    let emptyReply = ProviderRecoveryPolicy.isEmptyReply(error)
                    if emptyReply {
                        counters.emptyReplyRoundCount += 1
                        try await observe(.emptyReply, kept: kept)
                    } else if kept.isEmpty {
                        counters.providerReplayCount += 1
                        // An empty transport cut replays the identical conversation.
                        try await observe(.cut(seconds: elapsed, keptChars: 0), applying: false)
                    } else {
                        counters.providerContinuationCount += 1
                        try await observe(.cut(seconds: elapsed, keptChars: kept.count), kept: kept)
                    }
                    ProviderRetryTrace.emit(error: error, attempt: retryAttempt,
                        delaySeconds: delay, mode: kept.isEmpty && !emptyReply ? "replay" : "continuation",
                        turnRecoveries: counters.providerRecoveryCount, surface: surface)
                    await progress?(.notice(kind: "provider_retry",
                        text: ProviderRecoveryPolicy.reconnectStatus(attemptsMade: retryAttempt)))
                    do { try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
                    catch is CancellationError { throw stopCarryingPartial() }
                } else {
                    switch ProviderFailure.classify(error) {
                    case .authExpired, .codexCLISessionExpired, .routingUnavailable, .modelUnavailable:
                        throw TurnEngineError.streamInterrupted(partial: visibleText, underlying: error)
                    case .refused:
                        try await observe(.refused(reason: ProviderFailure.diagnosticDescription(error)), kept: kept)
                    default:
                        try await observe(.malformedCall(why: ProviderFailure.diagnosticDescription(error)), kept: kept)
                    }
                }
                continue
            }
            retryAttempt = 0
            retryingLiveFirstOutputCut = false
            if toolBoundaryReason == .outputLimit {
                let kept = await keepPartial()
                if LLMCallContext.turnTokenBudget?.exhausted == true {
                    return await finishIncompleteTurn()
                }
                try await observe(.lengthLimit(chars: kept.count), kept: kept)
                continue
            }
            let iterProse = ToolCallParser.stripProtocolDebris(iterAccumulated)
            let answerText = iterProse.replacingOccurrences(
                of: #"</?[\p{L}_][\p{L}\p{N}_.:-]*(?:\s[^<>]*)?/?>|<[!?][^>]*>"#, with: "", options: .regularExpression)
            func saveSuspiciousReply() {
                let visible = answerText.trimmingCharacters(in: .whitespacesAndNewlines)
                guard visible.split(whereSeparator: { $0.isWhitespace }).count < 2
                    || (visible.count < 12 && iterProse.contains(where: { "<=>".contains($0) })) else { return }
                let raw = rawProviderEvents.withLock { $0 }
                if !raw.isEmpty { RunawayOutputDetector.writeDiagnostic(raw, reason: "suspicious_reply") }
            }
            if streamedCalls.isEmpty && !answerText.contains(where: { !$0.isWhitespace }) {
                saveSuspiciousReply()
                visibleText = roundBaseVisibleText
                counters.emptyReplyRoundCount += 1
                try await observe(.emptyReply)
                continue
            }
            let markerCodec = toolCallCodec == .textMarkers
                ? TextMarkerCodec(schemas: ctx.toolSchemas,
                    turnActiveTools: LLMCallContext.turnActiveTools ?? [], catalogNames: Set(ctx.toolsAvailable))
                : nil
            var violation = markerCodec?.malformedCall(in: iterProse)
                ?? ToolCallParser.formattedToolCallViolation(in: iterProse, toolNames: Set(ctx.toolsAvailable))
            if violation?.traceType == "malformedToolUseMarker", markerCodec != nil, streamedCalls.isEmpty,
               let repaired = ToolCallParser.repairMalformedRegion(
                in: iterAccumulated, toolNames: Set(ctx.toolSchemas.map(\.name))) {
                iterAccumulated = repaired
                violation = nil
            }
            if let violation {
                counters.protocolViolationRoundCount += 1
                let rejectedBytes = Data(iterAccumulated.utf8)
                var diagnostic: [String: JSONValue] = [
                    "type": .string(violation.traceType),
                    "byteSize": .int(Int64(rejectedBytes.count)),
                    "sha256": .string(SHA256.hash(data: rejectedBytes).map { String(format: "%02x", $0) }.joined()),
                ]
                do {
                    diagnostic["path"] = .string(try RunawayOutputDetector.writeDiagnostic(iterAccumulated, reason: violation.traceType).get().path)
                } catch { diagnostic["file_error"] = .string(error.localizedDescription) }
                TurnTraceBus.fireFromContext(kind: "tool.protocol_violation", surface: surface, payload: .object(diagnostic))
                let kept = await keepPartial()
                try await observe(.malformedCall(why: violation.modelFeedback), kept: kept)
                continue
            }
            let providerCalls = toolCallCodec.roundCalls(
                streamed: streamedCalls, text: iterAccumulated, schemas: ctx.toolSchemas)
            if providerCalls.isEmpty {
                saveSuspiciousReply()
                if let toolBoundaryReason {
                    let kept = await keepPartial()
                    try await observe(.boundary(toolBoundaryReason), kept: kept)
                    continue
                }
                let promisesWork = (markerCodec?.promisesUnfulfilledWork(iterProse)
                    ?? (!providerTools.schemas.isEmpty && ToolCallParser.looksLikeUnfulfilledActionPromise(iterProse)))
                    || (dispatches.contains(where: { !ChatToolOutcome.neverRan($0.result) })
                        && ToolCallParser.looksLikeAnnouncedNextToolStep(iterProse))
                if promisesWork {
                    counters.unfulfilledPromiseRoundCount += 1
                    let kept = await keepPartial()
                    try await observe(.announcedNoCall, kept: kept)
                    continue
                }
                if !pendingProtocolDelta.isEmpty {
                    await progress?(.delta(toolCallCodec.visiblePrefix(in: pendingProtocolDelta)))
                }
                answerProse += iterProse
                try await part.deliver([.object(["type": .string("model"), "text": .string(iterProse), "calls": .array([])])])
                continue
            }

            let pendingProse = toolBoundaryReason == .fabricatedResult
                ? "" : toolCallCodec.proseReleasedAtDispatch(pendingProtocolDelta)
            if !pendingProse.isEmpty {
                iterEmittedProse += pendingProse
                await progress?(.delta(pendingProse))
            }
            visibleText = roundBaseVisibleText + iterEmittedProse
            turnInterstitialProse = Self.joinedProse(turnInterstitialProse, iterEmittedProse)
            round = (providerCalls, toolCallCodec == .textMarkers ? iterAccumulated : iterEmittedProse, markerCodec, toolBoundaryReason)
            try await part.deliver([.object(["type": .string("model"), "text": .string(iterEmittedProse),
                "calls": .array(providerCalls.enumerated().map {
                    .object(["index": .int(Int64($0.offset)), "id": .string($0.element.id), "name": .string($0.element.name),
                             "input": .object($0.element.input)])
                })])])
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
