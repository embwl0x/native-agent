import Foundation
import Senses
import AgentWorkspace
import CryptoKit
import NativeAgentCore
import PersistenceCore
import TurnTrace
import Transcripts
import Desk
import PersonaEngine
import MemoryV2
import MCPDispatcher
import ProviderRouting
import TrustCenter
import KnowledgeGraph
import XConnector
import Dispatcher
import MacControl
import SwarmRuns
import MacIntegration
import CognitiveSubstrate
import Context
import ToolRegistry
import StandingBots

struct ResidentTurnPreparation: Sendable {
    let turnPlan: TurnPlan?
    let cognitiveProjection: CognitiveTurnProjection?
}

private actor ToolProgressPersistenceBuffer {
    struct RecordableToolResult: Sendable {
        let name: String
        let input: JSONValue
        let output: JSONValue
        let ok: Bool
    }

    private var pendingInputs: [String: [JSONValue]] = [:]

    func recordableToolResult(from event: TurnStreamEvent) -> RecordableToolResult? {
        switch event {
        case .toolUse(let name, let input):
            pendingInputs[name, default: []].append(input)
            return nil
        case .toolResult(let name, let output):
            let input = popInput(for: name) ?? .object([:])
            return RecordableToolResult(
                name: name,
                input: input,
                output: output,
                ok: ChatToolOutcome.outputLooksSuccessful(output)
            )
        case .delta, .final, .error, .notice, .replyTextSettled:
            // .notice is ephemeral in-turn status — never persisted.
            return nil
        }
    }

    private func popInput(for name: String) -> JSONValue? {
        guard var values = pendingInputs[name], !values.isEmpty else { return nil }
        let first = values.removeFirst()
        pendingInputs[name] = values.isEmpty ? nil : values
        return first
    }

    // Failure-shape heuristic moved to ChatToolOutcome.outputLooksSuccessful
    // (ChatToolDispatchTrace.swift) — the trace recorder must classify
    // identically to these persisted rows.
}

extension SwiftNativeChatOrchestrationClient {
    func emitMetacognitiveTerminalTrace(
        turnId: String,
        sessionId: String,
        surface: String,
        context: TurnContext?,
        result: TurnEngineResult
    ) {
        // User, 2026-09-06: a slot a Stop reached never ran, so it is not a
        // failed dispatch. Its synthetic envelope carries an `error` string for
        // the model to read, which is exactly what `outputLooksSuccessful`
        // fails on — so a stopped batch reported its untried calls as failures.
        //
        // 2026-09-14, same shape: a call that raised an inline card ASKED the
        // person something and never ran. A turn parked on a card was
        // reporting a failed dispatch on its terminal trace.
        let failed = result.toolDispatches.filter {
            !ChatToolOutcome.outputLooksSuccessful($0.result)
                && !ChatToolOutcome.wasCancelled($0.result)
                && !ToolLoopTraceObservation.wasStopped($0.result)
                && !ChatToolOutcome.isWaitingOnPerson($0.result)
        }.count
        let expansions = result.toolDispatches.filter { ToolNameAliases.ranTool($0.name, input: $0.input) == "context_expand" }.count
        // Discovery is `app {find}`: the rounds spent finding an action.
        let discovery = result.toolDispatches.filter {
            $0.name == "app" && $0.input["find"] != nil && $0.input["action"] == nil
                && !ChatToolOutcome.wasCancelled($0.result)
        }
        let terminalReason = result.resolvedTerminalReason(dataRoot: dataRoot)
        var payload: [String: JSONValue] = [
            "schema": .string("metacognition.observed.v1"),
            "status": .string(terminalReason.state.rawValue),
            "terminalReason": .string(terminalReason.rawValue),
            // The one loop every turn runs on (S8), named so turn.terminal
            // rows before and after the move stay comparable.
            "loop": .string("streaming_tool_loop"),
            "modelUsed": .string(result.modelUsed),
            "turnElapsedMs": .int(Int64(max(0, result.elapsedMs))),
            "recalledMemoryCount": .int(Int64(result.recalledIds.count)),
            "toolDispatchCount": .int(Int64(result.toolDispatches.count)),
            "discoveryToolDispatchCount": .int(Int64(discovery.count)),
            // Retain the legacy slot counter; attempted failures exclude synthetic skips.
            "failedToolDispatchCount": .int(Int64(failed)),
            "failedToolSlotCount": .int(Int64(failed)),
            "contextExpansionCount": .int(Int64(expansions)),
        ]
        payload.merge(ToolLoopTraceObservation.toolCounts(result.toolDispatches), uniquingKeysWith: { _, new in new })
        if let counters = result.loopCounters {
            payload.merge(counters.tracePayload, uniquingKeysWith: { _, new in new })
        }
        let observation = context.map(TurnEngineResult.TerminalObservation.init(context:))
            ?? result.terminalObservation
        if let observation {
            payload["reasoningEffort"] = .string(observation.reasoningEffort)
            payload["toolSchemaCount"] = .int(Int64(observation.toolSchemaCount))
            payload["contextSource"] = .string(observation.contextSource)
            payload["contextSelectedAtomCount"] = .int(Int64(observation.contextSelectedAtomCount))
            payload["contextPacketCharacters"] = .int(Int64(observation.contextPacketCharacters))
            payload["contextExpandablePointerCount"] = .int(Int64(observation.contextExpandablePointerCount))
        }
        TurnTraceBus.fire(TurnTraceEvent(
            turnId: turnId,
            kind: "turn.terminal",
            sessionId: sessionId,
            surface: surface,
            payload: .object(payload)
        ), on: turnTraceBus)
    }

    // 2026-09-22 WHY: a structured turn that threw (retry ladder spent)
    // left no terminal row, so the trace read as an unexplained hang.
    func emitTurnFailedTrace(
        turnId: String, sessionId: String, surface: String, error: Error,
        observation: ToolLoopTraceObservation? = nil,
        terminalReasonOverride: TurnEngineResult.TerminalReason? = nil
    ) {
        let reason = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
        let terminalReason: TurnEngineResult.TerminalReason
        if let terminalReasonOverride {
            terminalReason = terminalReasonOverride
        } else if case .streamInterrupted(let partial, _) = error as? TurnEngineError {
            terminalReason = partial.isEmpty ? .providerFailed : .providerInterrupted
        } else {
            terminalReason = .executionFailed
        }
        var payload = observation?.tracePayload ?? [:]
        payload["status"] = .string(terminalReason.state.rawValue)
        payload["terminalReason"] = .string(terminalReason.rawValue)
        payload["reason"] = .string(String(reason.prefix(200)))
        TurnTraceBus.fire(TurnTraceEvent(
            turnId: turnId,
            kind: "turn.failed",
            sessionId: sessionId,
            surface: surface,
            payload: .object(payload)
        ), on: turnTraceBus)
    }

    func emitTurnCancelledTrace(
        turnId: String, sessionId: String, surface: String, location: String,
        observation: ToolLoopTraceObservation? = nil
    ) {
        var payload = observation?.tracePayload ?? [:]
        payload["status"] = .string(TurnEngineResult.TerminalState.interrupted.rawValue)
        payload["terminalReason"] = .string(TurnEngineResult.TerminalReason.cancelled.rawValue)
        payload["where"] = .string(location)
        TurnTraceBus.fire(TurnTraceEvent(
            turnId: turnId, kind: "turn.cancelled", sessionId: sessionId,
            surface: surface, payload: .object(payload)
        ), on: turnTraceBus)
    }

    /// The one structured chat turn. Streaming surfaces consume `progress`
    /// live; chat() callers await the returned execution.
    func executeStructuredChatStreaming(
        message: String,
        sessionId: String?,
        model: String,
        reasoningEffort: String,
        fileAccess: String,
        attachments: [MultimodalAttachment],
        persona: String?,
        surface: String,
        suppressUserAppend: Bool,
        persistToolMessages: Bool,
        /// See `executeTurnWithStreamingToolLoop(rendersProse:)`. False for
        /// chat(): its callers get the final round's reply and the provider's
        /// own error, and no partial prose is saved on a stop or failure.
        rendersProse: Bool,
        progress: ChatOrchestrationProgressHandler?,
        noticeSink: @escaping @Sendable (String, String) async -> Void
    ) async throws -> StructuredChatExecution {
        let persona = PersonaSelection.current() ?? persona
        // "Take over" continues where User was: each door captured it when the
        // message arrived (MacWorkContinuation.admit). An agent's turn never
        // inherits his.
        let takeover = ChatToolSessionContext.envelope?.agent == nil
            ? ChatToolSessionContext.envelope?.macContinuation ?? MacWorkContinuation.current : nil
        return try await MacWorkContinuation.$current.withValue(takeover) {
        try await SenseTurnReads.$current.withValue(SenseTurnReads()) {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty && attachments.isEmpty {
            throw ChatOrchestrationError.emptyMessage
        }

        let resolvedSession = try Self.resolveSessionId(sessionId)
        // Transport and enqueue pins keep the canonical transcript identity
        // stable before work starts, whether or not the user row already exists.
        let runId = ChatPersistenceContext.pinnedTurnRunID ?? UUID().uuidString
        ChatTurnExecution.current?.bindHistoryRunID(runId)
        var livePartial: String?
        do {
        let outputMilestoneGate = TurnLifecycleFirstOutputGate()
        // #19 + B7: derive the per-session cancel flag AT TURN ACCEPT, keyed by
        // this run, so a stale flag from a prior turn cannot kill this one and a
        // Stop naming this run can (ChatCancelFlag).
        let cancelFlagPath = ChatCancelFlag.accept(dataRoot: dataRoot, sessionId: resolvedSession, runId: runId)
        defer {
            ChatCancelFlag.finish(cancelFlagPath)
        }

        // 2026-09-06: routed through the Trust ▸ Multimodal gates —
        // vision off means the images never become blocks, and an attached
        // PDF's text rides in `modelMessage` (model-facing only; the persisted
        // user row below keeps `message`).
        let attachmentInput = try Self.turnAttachmentInput(
            message: message, attachments: attachments, dataRoot: dataRoot,
            queryUserMessage: TurnRelevanceContext.queryUserMessage)
        let imageBlocks = attachmentInput.imageBlocks
        var modelMessage = attachmentInput.userMessage
        if ChatTurnExecution.transcriptRowKind == nil,
           let contract = StandingBotContinuity.currentContract {
            modelMessage = contract.instructions + "\n\nMessage for this turn:\n" + modelMessage
        }

        let origin: AfterTurnOrigin?
        if !suppressUserAppend {
            origin = try await appendMessage(
                sessionId: resolvedSession,
                role: "user",
                content: message,
                runId: runId,
                attachments: attachments,
                persona: persona,
                source: surface,
                // The bot brief this run was started with is the bot's own
                // machinery, stamped by the caller, never guessed from the
                // surface, which a person steering in also arrives on.
                mechanicalRow: ChatTurnExecution.transcriptRowKind
            )
        } else {
            try await consumeEnqueuedMessage(sessionId: resolvedSession, runId: runId)
            origin = try afterTurnOrigin(sessionId: resolvedSession, runId: runId)
        }
        var afterTurnStarted = false
        var survivingReply = ""
        var survivingDispatches: [TurnEngineResult.ToolDispatchRecord] = []
        let incomingTraceId = TurnTraceContext.turnId ?? runId
        defer {
            // Incoming appraisal belongs to the accepted message even when no
            // assistant completion survives. This task is not cancelled by Stop.
            if !afterTurnStarted {
                let reply = survivingReply
                let dispatches = survivingDispatches
                Task { [engine, turnTraceBus] in
                    await AfterTurnSource.$origin.withValue(origin) {
                        await TurnTraceContext.$bus.withValue(turnTraceBus) {
                            await TurnTraceContext.$turnId.withValue(incomingTraceId) {
                                let ticket = await engine.deferMemoryPromotion(
                                    userMessage: message, assistantMessage: reply, toolDispatches: dispatches,
                                    sessionId: resolvedSession, surface: surface)
                                await engine.startDeferredMemoryPromotion(ticket: ticket)
                            }
                        }
                    }
                }
            }
        }

        // The sender's identity applies only to this row and its appraisal.
        let steeringPersister: ChatTurnSteering.Persister = { [weak self] sid, offer in
            guard let self, let enqueueRunID = offer.enqueuedRunID else { return false }
            let text = offer.text
            return await PeerDataTaint.$current.withValue(nil) {
            await TurnRequest(message: text, sessionID: sid, surface: offer.envelope.surface,
                envelope: .some(offer.envelope), verifiedSessionID: .some(sid),
                verifiedChatID: .some(offer.envelope.verifiedChatId),
                verifiedUserID: .some(offer.envelope.verifiedUserId), origin: .some(offer.origin)).bind {
            do {
                // The delivery is only allowed to happen because this row is on
                // disk. A swallowed failure here left the model answering a
                // message that was absent after reload and already gone from
                // the queue — so the write decides, and a failure both tells
                // the person and sends the offer back to be re-queued.
                let steeringOrigin = try await self.enqueueSteeringMessage(
                    message: text, sessionId: sid, surface: offer.envelope.surface, runId: enqueueRunID)
                // A consumed offer never runs its own structured turn. Appraise
                // its durable incoming row without borrowing the working turn's reply.
                await AfterTurnSource.$origin.withValue(steeringOrigin) {
                    await TurnTraceContext.$bus.withValue(self.turnTraceBus) {
                        await TurnTraceContext.$turnId.withValue(enqueueRunID) {
                            let ticket = await self.engine.deferMemoryPromotion(
                                userMessage: text, assistantMessage: "", toolDispatches: [],
                                sessionId: sid, surface: offer.envelope.surface)
                            await self.engine.startDeferredMemoryPromotion(ticket: ticket)
                        }
                    }
                }
                return true
            } catch {
                await Self.reportTranscriptWriteFailure(
                    label: "steeringOffer",
                    path: self.dataRoot,
                    error: error,
                    userText: "Couldn't save your message to the transcript, so it wasn't handed to the turn in progress - it's back in the queue to send next.",
                    onNotice: noticeSink
                )
                return false
            }
            }
            }
        }
        let steeringToken = await ChatTurnSteering.shared.openTurn(
            sessionId: resolvedSession, turnId: TurnTraceContext.turnId ?? runId, persist: steeringPersister)
        defer {
            if TurnAdmission.token == nil {
                Task {
                    await ChatTurnSteering.shared.closeTurn(
                        sessionId: resolvedSession, token: steeringToken)
                }
            }
        }

        // The window cursor must not slide in a turn the autocompactor already
        // rewrote — two rewrites of the same prefix in one turn pays the cache
        // write premium twice for one turn's worth of savings. The text lane
        // carries this the same way; discarding the outcome here let compaction
        // and a cursor advance both reshape the prefix on the same turn.
        var compactionRanThisTurn = false
        do {
            compactionRanThisTurn = try await prepareSessionHistoryForTurn(
                sessionId: resolvedSession,
                model: model,
                surface: surface,
                runId: runId
            )
        } catch {
            // Two turns died silently on 2026-09-05 (00:34, 10:12) with no trace
            // after their last tool; a cancellation left nothing on paper.
            TurnTraceBus.fireFromContext(
                kind: "turn.cancelled", surface: surface,
                payload: .object([
                    "where": .string("structured_chat.\(#line)"),
                    "status": .string("interrupted"),
                    "terminalReason": .string(TurnEngineResult.TerminalReason.cancelled.rawValue),
                ])
            )
            throw CancellationError()
        }

        let gated = makeTracedGatedDispatcher(
            fileAccess: fileAccess, verifiedSessionId: resolvedSession
        )
        let boundTurnId = StructuredTurnTraceIdentity.currentOrMint()
        let workTitle = String(TurnTraceRedactor.redactText(message)
            .split(whereSeparator: \.isNewline).first.map(String.init)?.prefix(96) ?? "".prefix(96))
        TurnTraceBus.fire(TurnTraceEvent(
            turnId: boundTurnId, kind: "work.identified", sessionId: resolvedSession,
            surface: surface, payload: .object(["title": .string(workTitle)])
        ), on: turnTraceBus)
        TurnLifecycleTelemetry.emit(
            .turnAccepted,
            surface: surface,
            sessionId: resolvedSession,
            observedBy: "structured_stream.entry",
            turnId: boundTurnId,
            on: turnTraceBus
        )
        async let residentPreparationTask = prepareResidentTurnInputs(
            message: message,
            surface: surface,
            sessionId: resolvedSession,
            runId: runId,
            fileAccess: fileAccess
        )

        // Pre-resolve the context with history threading so the engine call
        // inherits prior turns (threaded in via preBuiltContext). PROPAGATE
        // failures: the history reader inside already degrades gracefully on
        // its own, so a throw here is persona/router breakage, and try?
        // silently degraded the turn to no-history + default model/persona
        // (audit 2026-06-09). The user turn is already persisted above, so it
        // gets the same persist-then-rethrow treatment as the engine call below.
        // Mind-into-circulation follow-up (2026-07-10): mint the turn id
        // BEFORE the context build and bind it around build + engine alike.
        // The old binding started at the engine call, so `context.summary`
        // (emitted inside buildTurnContext) fired with NO bound turnId and was
        // silently dropped on every non-streaming turn — bridge/claude turns
        // had no context trace at all, blinding the Observatory fallback chip
        // and the attention trace counts on exactly those turns.
        let threadedCtx: TurnContext
        do {
            threadedCtx = try await HistoryWindowTurnFacts
                .$compactionRanThisTurn.withValue(compactionRanThisTurn) {
            try await TurnTraceContext.$bus.withValue(turnTraceBus) {
            try await TurnTraceContext.$turnId.withValue(boundTurnId) {
                try await engine.buildTurnContextWithHistory(
                    surface: surface,
                    userMessage: modelMessage,
                    sessionId: resolvedSession,
                    historyLimit: historyLimit,
                    historyReader: history,
                    personaOverride: persona,
                    excludeHistoryRunId: runId,
                    // First-turn handoff from the same participant, through
                    // the existing transcript and admitted provider route.
                    sessionDigest: SessionDigestProvider(dataRoot: history.dataRoot, llm: llm),
                    imageBlocks: imageBlocks,
                    queryUserMessage: attachmentInput.queryUserMessage
                )
            }
            }
            }
        } catch is CancellationError {
            // Two turns died silently on 2026-09-05 (00:34, 10:12) with no trace
            // after their last tool; a cancellation left nothing on paper.
            emitTurnCancelledTrace(
                turnId: boundTurnId, sessionId: resolvedSession, surface: surface,
                location: "structured_chat.\(#line)"
            )
            throw CancellationError()
        } catch {
            emitTurnFailedTrace(turnId: boundTurnId, sessionId: resolvedSession, surface: surface, error: error)
            let message = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
            if Self.shouldPersistFailureMessage(surface: surface) {
                try? await appendFailureMessageIfNeeded(
                    sessionId: resolvedSession,
                    runId: runId,
                    errorMessage: message,
                    failure: error,
                    persona: persona,
                    surface: surface
                )
            }
            throw error
        }
        let residentPreparation = await residentPreparationTask
        let turnPlan = residentPreparation.turnPlan
        let threadedCtxWithTurnPlan = SwiftNativeTurnEngine.contextByAppendingTurnPlanHint(
            threadedCtx,
            turnPlan: turnPlan
        )
        let threadedCtxWithOverrides = Self.applyChatOverrides(
            to: threadedCtxWithTurnPlan,
            model: model,
            reasoningEffort: reasoningEffort
        )
        if let turnPlan {
            await TurnPlanTraceRecorder.append(
                turnPlan,
                runId: runId,
                surface: surface,
                dataRoot: dataRoot,
                turnId: boundTurnId,
                turnTraceBus: turnTraceBus
            )
        }
        let (threadedCtxWithCognition, pendingProjectionCommit) = await Self.contextByAppendingCognitiveCapsule(
            to: threadedCtxWithOverrides,
            surface: surface,
            userMessage: message,
            runId: runId,
            sessionId: resolvedSession,
            fileAccess: fileAccess,
            projection: residentPreparation.cognitiveProjection
        )
        // `app` is her one tool (docs/TOOL_LOADING.md): the turn offers it alone.
        let providerCtx = Self.applyLazyToolFilter(to: threadedCtxWithCognition, activeTools: [])
        Self.traceFinalToolContract(
            turnId: boundTurnId,
            wire: providerCtx?.toolSchemas ?? [],
            surface: surface
        )

        let toolProgressRecorder = persistToolMessages ? ToolProgressPersistenceBuffer() : nil
        let receiptWriter = ToolReceiptWriter(
            client: self, sessionId: resolvedSession, runId: runId, surface: surface,
            laneLabel: "", onNotice: noticeSink
        )
        let effectiveProgress: ChatOrchestrationProgressHandler?
        if progress != nil || toolProgressRecorder != nil {
            effectiveProgress = { event in
                let redactedEvent = Self.redactedProgressEvent(event)
                if let toolProgressRecorder,
                   let record = await toolProgressRecorder.recordableToolResult(from: event) {
                    await receiptWriter.write(ToolReceipt(
                        toolName: record.name,
                        inputJSON: (try? ChatSecretRedactor.redactValue(record.input).serialize(pretty: false)) ?? "{}",
                        resultJSON: (try? ChatSecretRedactor.redactValue(record.output).serialize(pretty: false)) ?? "null",
                        ok: record.ok,
                        cognitiveOutput: record.output
                    ))
                }
                if case .delta = redactedEvent,
                   await outputMilestoneGate.claim() {
                    TurnLifecycleTelemetry.emit(
                        .surfaceOutputEnqueued,
                        surface: surface,
                        sessionId: resolvedSession,
                        observedBy: "structured_stream.progress"
                    )
                }
                await self.observeCognitiveProgressEvent(
                    sessionId: resolvedSession,
                    runId: runId,
                    surface: surface,
                    event: redactedEvent,
                    toolResultAlreadyPersisted: toolProgressRecorder != nil
                )
                if case .delta(let text) = redactedEvent {
                    ChatLiveTap.emit(sessionId: resolvedSession, surface: surface, runId: runId, .delta(text))
                }
                await progress?(redactedEvent)
            }
        } else {
            effectiveProgress = nil
        }

        let loopObservation = ToolLoopTraceObservation()
        var terminalFailureReason: TurnEngineResult.TerminalReason?
        let result: TurnEngineResult
        do {
            // Turn Inspector W1: bind the per-turn trace id around the engine
            // call so every event the tool loop emits (llm.call, tool.dispatch,
            // memory.commit) inherits one turnId. The streaming facade has
            // already bound this same id; chat() has not, so this is where its
            // turn gets one spine. Same turnId as the context build above.
            result = try await AfterTurnSource.$origin.withValue(origin) {
            do {
            return try await ToolLoopTraceObservation.$current.withValue(loopObservation) {
            try await TurnTraceContext.$bus.withValue(turnTraceBus) {
            try await TurnTraceContext.$turnId.withValue(boundTurnId) {
            try await LLMCallContext.$turnActiveTools.withValue(Set(providerCtx?.toolSchemas.map(\.name) ?? [])) {
            try await ChatToolSessionContext.$settingRequestEvidence.withValue({ [self] setting, value, currentValue, quote in
                func normalized(_ text: String) -> String {
                    text.lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ")
                }
                // The quote may arrive wrapped ("User asked: “…”"): match the
                // quoted part too, ignoring the quote marks themselves.
                let marks = CharacterSet(charactersIn: "\"“”'‘’")
                let segments = quote.components(separatedBy: marks).map { normalized($0).trimmingCharacters(in: .punctuationCharacters.union(.whitespaces)) }
                    .filter { $0.split(separator: " ").count >= 3 }
                let candidates = [normalized(quote)] + segments
                func quotes(_ text: String) -> Bool { let t = normalized(text); return candidates.contains { t.contains($0) } }
                let envelope = TurnEnvelope.current(surface: surface)
                let origin = ChatPersistenceContext.originProvenance
                let lane = (origin?.agent ?? envelope.agent) == "agent" ? envelope.verifiedUserId.map { "peer:" + $0 } : origin?.agent ?? envelope.agent
                let currentRequest = (origin?.authored == .human || lane.map(PeerDataTaint.ownerTrusts) == true
                    || (origin == nil && envelope.agent == nil && ["chat", "app", "mac", "ios", "telegram", "slack"].contains(surface)))
                    && quotes(message)
                var found = currentRequest
                guard let history = try? await SessionHistoryReader(dataRoot: dataRoot).messagesWithStats(
                    forSessionId: resolvedSession, strictEvidence: true),
                    !["read_failed", "invalid_encoding", "invalid_session_id"].contains(history.stats.mode),
                    history.stats.malformedRowCount == 0, history.stats.invalidShapeRowCount == 0 else { return found ? false : nil }
                var lastChange: [String: JSONValue]?
                for row in history.messages {
                    guard case .object(let fields)? = row.extras else { continue }
                    let author = SwiftToolDispatcher.persistedHistoryAuthor(role: row.role, row: fields)
                    let peer = row.role == "user" ? SwiftToolDispatcher.persistedHistoryPeer(role: row.role, row: fields) : nil
                    if author == SwiftToolDispatcher.ownerAuthor || author == "human via bridge" || peer.map(PeerDataTaint.ownerTrusts) == true
                        || (peer == nil && envelope.verifiedUserId != nil && author == envelope.verifiedUserId) {
                        found = found || quotes(row.content)
                    }
                    guard case .object(let metadata)? = fields["metadata"], metadata["kind"] == .string(ChatTranscriptToolMessageKind.toolUse),
                          case .string(let result)? = metadata["resultSummary"],
                          let receipt = try? JSONValue.parse(Data(result.utf8)),
                          SessionHistoryPromptRenderer.receiptField("setting", in: receipt) == .string(setting),
                          SessionHistoryPromptRenderer.receiptField("changed", in: receipt) == .bool(true) else { continue }
                    lastChange = ["decided_by", "old_value", "new_value"].reduce(into: [:]) {
                        $0[$1] = SessionHistoryPromptRenderer.receiptField($1, in: receipt)
                    }
                }
                guard found else { return nil }
                guard case .bool = value else { return false }
                return currentRequest && value != currentValue && lastChange?["decided_by"] == .string("agent")
                    && lastChange?["old_value"] == value && lastChange?["new_value"] == currentValue
            }) {
                do {
                    return try await engine.executeTurnWithStreamingToolLoop(
                        surface: surface,
                        userMessage: message,
                        sessionId: resolvedSession,
                        runId: runId,
                        maxIterations: toolLoopMaxIterations(for: surface),
                        turnWallClockSecondsOverride: turnWallClockSecondsOverride,
                        llm: llm,
                        tools: gated,
                        preBuiltContext: providerCtx,
                        progress: effectiveProgress,
                        rendersProse: rendersProse,
                        cancelFlagPath: cancelFlagPath,
                        fileAccess: fileAccess,
                        capabilityProfile: continuationCapabilityProfile
                    )
                } catch TurnEngineError.streamCancelled where !rendersProse {
                    // No partial prose is kept for a caller that renders none: a
                    // stop is a plain cancellation, handled below.
                    throw CancellationError()
                } catch TurnEngineError.streamInterrupted(_, let underlying) where !rendersProse {
                    // Likewise: the provider failure itself, handled below.
                    terminalFailureReason = .providerFailed
                    throw underlying
                }
            }
            }
            }
            }
            }
            } catch {
                let partial: String
                let cancelled: Bool
                switch error {
                case TurnEngineError.streamInterrupted(let text, _):
                    partial = text
                    cancelled = false
                case TurnEngineError.streamCancelled(let text, _):
                    partial = text
                    cancelled = true
                default:
                    partial = ""
                    cancelled = error is CancellationError
                }
                livePartial = await persistPartialIfNeeded(
                    sessionId: resolvedSession,
                    runId: runId,
                    text: partial,
                    attachments: ChatGeneratedImageArtifacts.attachments(
                        from: loopObservation.toolDispatches, dataRoot: dataRoot
                    ),
                    cancelled: cancelled,
                    failure: error,
                    source: surface,
                    outcomeContext: providerCtx,
                    onNotice: noticeSink
                )
                survivingReply = partial
                survivingDispatches = loopObservation.toolDispatches
                throw error
            }
            }
        } catch let e as ChatOrchestrationError {
            emitTurnFailedTrace(
                turnId: boundTurnId, sessionId: resolvedSession, surface: surface, error: e,
                observation: loopObservation, terminalReasonOverride: terminalFailureReason
            )
            if Self.shouldPersistFailureMessage(surface: surface) {
                try? await appendFailureMessageIfNeeded(
                    sessionId: resolvedSession,
                    runId: runId,
                    errorMessage: Self.errorText(e),
                    failure: e,
                    persona: persona,
                    surface: surface,
                    outcomeContext: providerCtx,
                    outcomeTurnID: boundTurnId
                )
            }
            throw e
        } catch let e as TurnEngineError {
            let message = (e as LocalizedError).errorDescription ?? String(describing: e)
            // The partial output is already saved. A user stop closes the
            // trace and propagates cancellation without a failure-message row.
            if case .streamCancelled = e {
                emitTurnCancelledTrace(
                    turnId: boundTurnId, sessionId: resolvedSession, surface: surface,
                    location: "structured_chat.\(#line)", observation: loopObservation
                )
                throw CancellationError()
            }
            emitTurnFailedTrace(
                turnId: boundTurnId, sessionId: resolvedSession, surface: surface, error: e,
                observation: loopObservation, terminalReasonOverride: terminalFailureReason
            )
            if Self.shouldPersistFailureMessage(surface: surface) {
                try? await appendFailureMessageIfNeeded(
                    sessionId: resolvedSession,
                    runId: runId,
                    errorMessage: message,
                    failure: e,
                    persona: persona,
                    surface: surface,
                    outcomeContext: providerCtx,
                    outcomeTurnID: boundTurnId
                )
            }
            throw e
        } catch is CancellationError {
            // A cancel (Task stop or cancelled.flag) is NOT a failure — don't
            // persist a "Chat error: CancellationError" row; just propagate
            // (gpt-5.5 review of #19, 2026-06-14). It still needs a terminal
            // row, or the turn reads as an unexplained death (2026-09-06).
            emitTurnCancelledTrace(
                turnId: boundTurnId, sessionId: resolvedSession, surface: surface,
                location: "structured_chat.\(#line)", observation: loopObservation
            )
            throw CancellationError()
        } catch {
            emitTurnFailedTrace(
                turnId: boundTurnId, sessionId: resolvedSession, surface: surface, error: error,
                observation: loopObservation, terminalReasonOverride: terminalFailureReason
            )
            let message = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
            if Self.shouldPersistFailureMessage(surface: surface) {
                try? await appendFailureMessageIfNeeded(
                    sessionId: resolvedSession,
                    runId: runId,
                    errorMessage: message,
                    failure: error,
                    persona: persona,
                    surface: surface,
                    outcomeContext: providerCtx,
                    outcomeTurnID: boundTurnId
                )
            }
            throw error
        }

        // R-F1: the provider accepted the turn (every thrown path above rethrows,
        // so this line is unreachable on failure) — only now consume the felt
        // Body-line suppress window and update the Observatory live capsule.
        await commitDeliveredCognitiveTurnProjection(
            pendingProjectionCommit,
            surface: surface,
            userMessage: message,
            sessionId: resolvedSession,
            turnId: boundTurnId
        )

        let generatedAttachments = ChatGeneratedImageArtifacts.attachments(
            from: result.toolDispatches,
            dataRoot: dataRoot
        )

        let reply = BotRunner.conditionReply(result.reply, sessionID: resolvedSession)
        let transcriptRow = TurnSettle.transcriptRow(for: reply)
        try await appendMessage(
            sessionId: resolvedSession,
            role: "assistant",
            content: transcriptRow.text,
            runId: runId,
            attachments: generatedAttachments,
            persona: persona,
            source: surface,
            recalledMemoryIds: result.recalledIds,
            canonicalAssistantCompletion: true,
            outcomeResult: result,
            outcomeContext: providerCtx,
            outcomeTurnID: boundTurnId,
            mechanicalRow: transcriptRow.mechanicalRow,
            requestedResultIntent: TurnSettle.requestedResultIntent(
                message: message, plan: turnPlan, result: result,
                sessionID: resolvedSession, runID: runId, surface: surface,
                resumedRequest: suppressUserAppend && (
                    message.hasPrefix("[NativeAgent internal interaction continuation]") ||
                    message.hasPrefix("[NativeAgent internal approval continuation]")
                )
            )
        )
        livePartial = transcriptRow.text
        if !reply.isEmpty, await outputMilestoneGate.claim() {
            TurnLifecycleTelemetry.emit(
                .surfaceOutputEnqueued,
                surface: surface,
                sessionId: resolvedSession,
                observedBy: "structured_stream.return",
                turnId: boundTurnId,
                on: turnTraceBus
            )
        }
        // The assistant row is durable and the output milestone is claimed, so
        // the promotion can START (it can no longer run before the transcript
        // exists). It is NOT awaited here: this function returning is what lets
        // ClaudeBridge write its reply row and TelegramPollLoop finalize its
        // send, and awaiting here put the whole memory pass in front of both
        // (Astra comb 3, lane1 finding 1 / lane2 finding 3, 2026-09-12). Those
        // surfaces drain the retained handle after their own delivery milestone
        // via `drainDeferredMemoryPromotion()`, but no surface has to: a started
        // promotion completes on its own (Slack, Mac and iOS never drain).
        // The ticket starts THIS turn's promotion and no other turn's.
        await engine.startDeferredMemoryPromotion(ticket: result.memoryPromotionTicket)
        afterTurnStarted = result.memoryPromotionTicket != nil
        emitMetacognitiveTerminalTrace(
            turnId: boundTurnId,
            sessionId: resolvedSession,
            surface: surface,
            context: providerCtx,
            result: result
        )
        var response = ChatResponse(
            runId: runId,
            model: result.modelUsed,
            requestedModel: model.isEmpty ? nil : model,
            reasoningEffort: reasoningEffort.isEmpty ? nil : reasoningEffort,
            output: reply,
            sessionId: resolvedSession,
            personaFingerprint: threadedCtx.personaFingerprint,
            contextFingerprint: Self.contextFingerprint(recalledIds: result.recalledIds),
            attachments: generatedAttachments.isEmpty ? nil : generatedAttachments,
            providerCallCount: result.providerCallCount,
            terminalState: result.resolvedTerminalReason(dataRoot: dataRoot).state
        )
        response.workingCommentaryCharacters = result.workingCommentaryCharacters
        if result.completionState == .incomplete {
            // A turn parked on a card did not break — it is waiting to be
            // answered. Saying "interrupted" here is what put "Interrupted" on
            // a bot that is simply waiting on a person.
            response.runtimeStatus = ChatTurnExecution.current?.waitingForInteraction == true
                ? "waiting on you" : "interrupted"
        }
        if result.terminalReason == .replyCompleted,
           let journal = DeskContinuationScope.current,
           await journal.snapshot().runID == runId {
            try await journal.completeResponse(JSONValue.fromEncodable(response), reply: response.output,
                peerSources: PeerDataTaint.current?.checkpointSources ?? [])
        }
        // The saved row's own text, so the phone's transcript snapshot settles
        // the live bubble instead of adding a second copy.
        ChatLiveTap.emit(sessionId: resolvedSession, surface: surface, runId: runId,
                         response.runtimeStatus.map { .incomplete(transcriptRow.text, status: $0) }
                             ?? .answered(transcriptRow.text))
        return StructuredChatExecution(response: response, turn: result)
        } catch {
            let terminal: ChatLiveTap.Kind = error is CancellationError
                ? .cancelled
                : .failed(ProviderFailure.report(error)?.personDescription ?? "The reply could not be completed.")
            ChatLiveTap.emit(sessionId: resolvedSession, surface: surface, runId: runId, terminal, savedPartial: livePartial)
            throw error
        }
        }
        }
    }

    /// Measure the tools array THIS TURN ACTUALLY SENDS, after the lazy
    /// filter has run.
    ///
    /// Comb 3 lane 3 item 2: the preflight instrument in the turn engine reads
    /// the loadout on disk at context-assembly time, so it reported 20/48/19
    /// while the request that followed carried 85 schemas and an unchanged
    /// `component.toolsSHA256`.
    ///
    /// `wire` is THE ARRAY THE REQUEST CARRIES, `providerCtx.toolSchemas`.
    /// Floor/appended and both fingerprints are computed over it.
    ///
    /// Two digests on purpose. The contract digest hashes ORDERED NAMES, which
    /// is what a prefix-cache question is about. The schema digest hashes the
    /// full rows — names, descriptions and parameter JSON — so editing a
    /// description or a parameter schema, which changes the provider array
    /// byte-for-byte, can no longer leave the receipt claiming an unchanged
    /// contract.
    static func traceFinalToolContract(
        turnId: String,
        wire: [LLMToolSchema],
        surface: String?
    ) {
        let ordering = SwiftToolDispatcher.canonicalToolOrder(wire.map(\.name))
        // THE APPENDED COST, MEASURED (Astra comb 4, lane3 finding 2). The
        // snapshot's per-tool array is the first casualty of oversized-payload
        // truncation, so no retained row could separate the floor from the
        // appended schemas and the appended token cost was unanswerable. These
        // are compact scalars on a row that never gets truncated: schema-material
        // bytes (name + description + parameter JSON), the same convention
        // `context.snapshot` uses, and no schema content.
        let bytesByName = Dictionary(
            wire.map {
                ($0.name, ToolContractWeight.materialBytes(
                    name: $0.name, description: $0.description,
                    parameterBytes: $0.parametersJSON.count
                ))
            },
            uniquingKeysWith: { a, _ in a }
        )
        let weight = ToolContractWeight.Measurement(
            floorCount: ordering.floor.count,
            appendedCount: ordering.appended.count,
            floorBytes: ordering.floor.reduce(0) { $0 + (bytesByName[$1] ?? 0) },
            appendedBytes: ordering.appended.reduce(0) { $0 + (bytesByName[$1] ?? 0) }
        )
        // Published for this turn so every `llm.call` row carries the same
        // totals beside the provider's real input/cache token counts.
        ToolContractWeight.record(turnId: turnId, weight)
        // Fired with the turn id in hand: this runs before the task-local turn
        // binding opens, so the context-derived firing dropped every row.
        var payload: [String: JSONValue] = [
                "tools.finalWireCount": .int(Int64(wire.count)),
                "tools.finalFloorCount": .int(Int64(ordering.floor.count)),
                "tools.finalAppendedCount": .int(Int64(ordering.appended.count)),
                "tools.finalFingerprintSHA256":
                    .string(SwiftNativeTurnEngine.toolSchemaFingerprint(wire)),
                "tools.finalNameOrderSHA256": .string(ordering.fingerprintSHA256),
                // Schema-material bytes, not HTTP body size and not tokens.
                "tools.finalFloorBytes": .int(Int64(weight.floorBytes)),
                "tools.finalAppendedBytes": .int(Int64(weight.appendedBytes)),
                "tools.finalWireBytes": .int(Int64(weight.wireBytes)),
        ]
        if let share = weight.appendedShareOfWireBytes {
            payload["tools.finalAppendedShareOfWireBytes"] = .double(share)
        }
        TurnTraceBus.fire(TurnTraceEvent(
            turnId: turnId,
            kind: "tools.contract",
            sessionId: LLMCallContext.sessionId,
            surface: surface,
            payload: .object(payload)
        ))
    }

    /// Lazy-tool-loading filter AND the single owner of the advertised tool
    /// order: anything `normalModelToolNames` authorizes, which for her chat
    /// is `app` alone. No `mcp__*` row is ever advertised: each MCP tool is an
    /// `app` action. Returns nil if the input ctx was nil so callers can
    /// short-circuit the same as before.
    ///
    /// ORDER (2026-09-01): the surviving schemas come back in
    /// `SwiftToolDispatcher.canonicalToolOrder` — always-on floor sorted by
    /// name, then everything else in incoming order. The structured lane's
    /// `tools` array and the text lane's rendered catalog both derive from
    /// this one array, so the two lanes cannot disagree about the contract.
    static func applyLazyToolFilter(
        to context: TurnContext?,
        activeTools: Set<String>
    ) -> TurnContext? {
        guard let context else { return nil }
        let allowed = SwiftToolDispatcher.normalModelToolNames(activeTools: activeTools)
        var bySlot: [String: LLMToolSchema] = [:]
        for schema in context.toolSchemas where bySlot[schema.name] == nil && allowed.contains(schema.name) {
            bySlot[schema.name] = schema
        }
        let ordering = SwiftToolDispatcher.canonicalToolOrder(
            context.toolSchemas.map(\.name).filter { bySlot[$0] != nil }
        )
        return context.withToolSchemas(ordering.advertised.compactMap { bySlot[$0] })
    }

    func prepareCognitiveTurnProjection(
        surface: String,
        userMessage: String,
        sessionId: String,
        runId: String
    ) async -> CognitiveTurnProjection? {
        // Phase 5 E2: every verified User turn stamps the time, on both turn
        // paths and whatever the capsule does — initiative reads only this.
        if Self.isUsersTurn(surface: surface, sessionId: sessionId, dataRoot: dataRoot) {
            UserTurnStamp.record(dataRoot: dataRoot, key: runId)
        }
        guard let cognitiveContextProvider else { return nil }
        return await cognitiveContextProvider.prepareTurnProjection(
            cognitiveTurnProjectionRequest(
                surface: surface,
                userMessage: userMessage,
                sessionId: sessionId
            )
        )
    }

    /// The user message has already crossed the canonical transcript and
    /// cognition-ingestion boundary before this helper runs. Planning and the
    /// frozen resident projection are independent preparation reads, so the
    /// caller can overlap them with ContextFlow/history assembly. The result
    /// remains turn-scoped and the projection is committed only after it is
    /// actually appended to provider input.
    func prepareResidentTurnInputs(
        message: String,
        surface: String,
        sessionId: String,
        runId: String,
        fileAccess: String
    ) async -> ResidentTurnPreparation {
        async let turnPlanTask = makeTurnPlan(
            message: message,
            surface: surface,
            sessionId: sessionId,
            fileAccess: fileAccess
        )
        async let cognitiveProjectionTask = prepareCognitiveTurnProjection(
            surface: surface,
            userMessage: message,
            sessionId: sessionId,
            runId: runId
        )
        let (turnPlan, cognitiveProjection) = await (
            turnPlanTask,
            cognitiveProjectionTask
        )
        return ResidentTurnPreparation(
            turnPlan: turnPlan,
            cognitiveProjection: cognitiveProjection
        )
    }

    func cognitiveTurnProjectionRequest(
        surface: String,
        userMessage: String,
        sessionId: String
    ) -> CognitiveCapsuleRequest {
        let fromUser = Self.isUsersTurn(surface: surface, sessionId: sessionId, dataRoot: dataRoot)
        return CognitiveCapsuleRequest(
            surface: surface,
            userMessage: userMessage,
            sessionId: sessionId,
            mode: .inject,
            // Sweep R4 W3: window-aware, floored at the former 4,000 literal.
            // The substrate additionally clamps with its own configured
            // `maximumCapsuleCharacters`, so this can only ever RAISE the
            // request's own ceiling, never the substrate's.
            maximumCharacters: ContextBudgetPolicy.resolve(
                model: LLMCallContext.admittedModel,
                providerID: LLMCallContext.providerId,
                dataRoot: dataRoot,
                surface: surface
            ).capsuleChars,
            allowNonLiveProjection: Self.shouldProjectCognitiveStateForTrustedBridgeEnvelope(
                userMessage
            ),
            turnKind: Self.cognitiveMessageTurnKind(
                role: "user",
                source: surface,
                redactedContent: ChatSecretRedactor.redactText(userMessage),
                origin: ChatPersistenceContext.originProvenance
            ),
            fromUser: fromUser,
            previousUserTurnAt: fromUser ? UserTurnStamp.previous(dataRoot: dataRoot) : nil
        )
    }

    /// Phase 5 B2: a turn User started himself — the verified OWNER, not
    /// whoever reached a surface (Sol, 10-03): the Mac app's local user, his
    /// paired phone (signed command), or the Telegram owner (the bot's one
    /// allowlisted user, the approval cards' owner rule). Her wakes, peer
    /// threads, bridge lanes, Slack and any other sender never move his gap.
    static func isUsersTurn(surface: String, sessionId: String, dataRoot: URL) -> Bool {
        let envelope = ChatToolSessionContext.envelope
        guard ChatPersistenceContext.originProvenance == nil,
              (envelope?.agent ?? "").isEmpty,
              sessionId != ResidentWake.session,
              !sessionId.hasPrefix("agent-") else { return false }
        switch surface.lowercased() {
        case "chat", "app", "mac":
            return envelope?.declaredRemote != true
        case "ios":
            return envelope?.commandSignatureVerified == true
                || ChatToolSessionContext.commandSignatureVerified == true
        case "telegram":
            guard let sender = envelope?.verifiedUserId ?? ChatToolSessionContext.verifiedUserId,
                  let owner = telegramOwnerId(dataRoot: dataRoot) else { return false }
            return sender.trimmingCharacters(in: .whitespacesAndNewlines) == owner
        default:
            return false
        }
    }

    /// The Telegram bot's owner: its single allowlisted user id, else nobody.
    static func telegramOwnerId(dataRoot: URL) -> String? {
        let path = dataRoot.appendingPathComponent("telegram/config.json")
        guard let data = try? Data(contentsOf: path),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        let ids = Set(["allowed_user_ids", "allowedUserIds"].flatMap { key in
            ((object[key] as? [Any]) ?? []).map { "\($0)".trimmingCharacters(in: .whitespacesAndNewlines) }
        }.filter { !$0.isEmpty })
        return ids.count == 1 ? ids.first : nil
    }

    static func contextByAppendingCognitiveCapsule(
        to context: TurnContext?,
        surface: String,
        userMessage: String,
        runId: String,
        sessionId: String,
        fileAccess: String,
        projection: CognitiveTurnProjection?
    ) async -> (context: TurnContext?, pendingProjectionCommit: CognitiveTurnProjection?) {
        guard let context else { return (nil, nil) }
        let projection = Self.droppingDuplicateRemindedOf(
            projection, packetMemoryIDs: Set(context.fluidContextTurn?.selectedMemoryRecordIDs ?? []))
        guard let runtimeContext = Self.cognitiveRuntimeContext(
            runId: runId,
            sessionId: sessionId,
            surface: surface,
            fileAccess: fileAccess,
            capsule: projection?.capsule,
            posture: projection?.posture
        ) else {
            // Phase 5A: nothing to inject ("none" and a default posture) is
            // still an accepted turn — hand the projection back so its
            // presentation commit runs and the clocks and rests move.
            return (context, projection)
        }
        let projectedContext = SwiftNativeTurnEngine.contextByAppendingRuntimeContext(
            context,
            runtimeContext: runtimeContext
        )
        // R-F1 (2026-07-17): the commit used to fire here, at ASSEMBLY — before
        // the provider ever saw the turn. A 529 on the first provider call then
        // consumed the 20-min Body-line suppress window for a felt line the
        // model never received, and the Observatory labeled a never-delivered
        // capsule `.liveInjected`. The projection is handed back instead; the
        // turn executor commits it once, only after the engine call succeeds.
        return (projectedContext, projection)
    }

    /// Phase 5 C3: one memory once per turn. Reminded-of (the capsule) and
    /// the personal lane (the packet) pick concurrently; when both land on the
    /// same memory id, the packet keeps it and the capsule drops its line. The
    /// commit still counts it surfaced (it did), and `mind.why` says why.
    static func droppingDuplicateRemindedOf(
        _ projection: CognitiveTurnProjection?,
        packetMemoryIDs: Set<String>
    ) -> CognitiveTurnProjection? {
        guard let projection, let capsule = projection.capsule, !packetMemoryIDs.isEmpty,
              case .object(var why)? = projection.why,
              case .object(var winner)? = why["winner"],
              winner["kind"] == .string("reminded_of"),
              case .string(let source)? = winner["source"], source.hasPrefix("memory:"),
              packetMemoryIDs.contains(String(source.dropFirst(7))) else { return projection }
        let lines = capsule.dynamicContext.components(separatedBy: "\n")
            .filter { !$0.hasPrefix("- Reminded of:") }
        var trimmed = capsule
        trimmed.dynamicContext = lines.joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        winner["shown"] = .bool(false)
        winner["dropped"] = .string("same memory as the packet's personal line")
        why["winner"] = .object(winner)
        return CognitiveTurnProjection(
            fixedAt: projection.fixedAt,
            capsule: trimmed.dynamicContext.isEmpty ? nil : trimmed,
            posture: projection.posture,
            capsulePresentationCommit: projection.capsulePresentationCommit,
            why: .object(why))
    }

    /// Commits presentation-only projection bookkeeping (Body-line suppress
    /// window, Observatory live-capsule cache) AFTER the provider actually
    /// accepted the turn. Called exactly once per successful turn regardless
    /// of how many provider round-trips the tool loop made; never called on a
    /// thrown turn, so a failed delivery leaves the felt line available to the
    /// retry.
    func commitDeliveredCognitiveTurnProjection(
        _ projection: CognitiveTurnProjection?,
        surface: String,
        userMessage: String,
        sessionId: String,
        turnId: String
    ) async {
        guard let projection, let cognitiveContextProvider else { return }
        // Phase 5 B0: why this turn's felt cue (or none) — trace only.
        if let why = projection.why {
            TurnTraceBus.fire(TurnTraceEvent(
                turnId: turnId, kind: "mind.why", sessionId: sessionId,
                surface: surface, payload: why
            ), on: turnTraceBus)
        }
        await cognitiveContextProvider.commitTurnProjection(
            projection,
            request: cognitiveTurnProjectionRequest(
                surface: surface,
                userMessage: userMessage,
                sessionId: sessionId
            )
        )
    }

    private static func applyChatOverrides(
        to context: TurnContext?,
        model: String,
        reasoningEffort: String
    ) -> TurnContext? {
        guard let context else { return nil }
        let modelOverride = (LLMCallContext.admittedModel ?? model)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let effortOverride = (LLMCallContext.reasoningEffort ?? reasoningEffort)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !modelOverride.isEmpty || !effortOverride.isEmpty else {
            return context
        }
        return TurnContext(
            surface: context.surface,
            personaID: context.personaID,
            personaDocs: context.personaDocs,
            personaFingerprint: context.personaFingerprint,
            recalled: context.recalled,
            modelId: modelOverride.isEmpty ? context.modelId : modelOverride,
            reasoningEffort: effortOverride.isEmpty ? context.reasoningEffort : effortOverride,
            providerId: context.providerId,
            serviceTier: context.serviceTier,
            toolsAvailable: context.toolsAvailable,
            systemPrompt: context.systemPrompt,
            userMessage: context.userMessage,
            toolSchemas: context.toolSchemas,
            systemSegments: context.systemSegments,
            imageBlocks: context.imageBlocks,
            fluidContextTurn: context.fluidContextTurn,
            naturalExpressionCue: context.naturalExpressionCue,
            historyMessages: context.historyMessages,
            turnVolatileBlock: context.turnVolatileBlock,
            historyWindowReceipt: context.historyWindowReceipt,
            preparationMs: context.preparationMs
        )
    }

    func makeTurnPlan(
        message: String,
        surface: String,
        sessionId: String,
        fileAccess: String
    ) async -> TurnPlan? {
        do {
            return try await TurnPlanner(dataRoot: dataRoot).plan(
                message: message,
                surface: surface,
                sessionId: sessionId,
                fileAccess: fileAccess,
                approvalAvailable: true
            )
        } catch {
            FileHandle.standardError.write(
                Data("TurnPlanner: plan failed (\(surface)/\(sessionId)): \(error)\n".utf8)
            )
            return nil
        }
    }

    static let cognitiveHeaderLine = "[CognitiveSubstrate] private — it colors you; never quote it."

    static func cognitiveRuntimeContext(
        runId: String,
        sessionId: String,
        surface: String,
        fileAccess: String,
        capsule: CognitiveCapsule?,
        posture: OrganismBehaviorPosture?
    ) -> String? {
        var sections: [String] = []
        // The ops line rides FIRST and on its own, so it never reads as part of
        // her private inner state; it is empty on a default posture.
        if let posture {
            sections.append(posture.privateRuntimeContext(
                runId: runId,
                sessionId: sessionId,
                surface: surface,
                fileAccess: fileAccess
            ))
        }
        if let capsule,
           !capsule.combined.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            // One functional line, no disclaimers: her guardrails live in her soul
            // (persona), and actions are hard-gated by TrustCenter regardless of
            // prompt text (User, 2026-07-01). Phase 5A: the run/session/surface
            // ids were trace plumbing the model paid for on every call; the
            // trace reader keys on this exact line instead.
            sections.append(Self.cognitiveHeaderLine + "\n" + capsule.combined)
        }
        let combined = sections
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")
        return combined.isEmpty ? nil : combined
    }

    nonisolated static func shouldProjectCognitiveStateForTrustedBridgeEnvelope(
        _ userMessage: String
    ) -> Bool {
        let normalized = userMessage
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        return normalized.hasPrefix("[from: codex, via bridge]")
            || normalized.hasPrefix("[from: claude, via bridge]")
    }
}

/// Phase 5 E2: when User last took a turn at one of his verified doors (Mac,
/// paired phone, Telegram owner), stamped on every such turn as it starts,
/// and the verified turn before it. The one source both initiative (E) and
/// "since we last talked" (B2) read; never a feeling. Keyed per turn, so a
/// recompile of the same turn does not move `previous`.
public enum UserTurnStamp {
    struct Stamp: Codable { var at: Double; var previous: Double?; var key: String }

    static func url(_ dataRoot: URL) -> URL { dataRoot.appendingPathComponent("cognition/user_turn.json") }

    static func read(_ dataRoot: URL) -> Stamp? {
        (try? Data(contentsOf: url(dataRoot))).flatMap { try? JSONDecoder().decode(Stamp.self, from: $0) }
    }

    public static func record(dataRoot: URL, key: String, at date: Date = Date()) {
        let old = read(dataRoot)
        guard old?.key != key else { return }
        let stamp = Stamp(at: date.timeIntervalSince1970, previous: old?.at, key: key)
        let url = url(dataRoot)
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(stamp).write(to: url, options: .atomic)
        } catch {
            nativeLog("UserTurnStamp: not kept: %@", error.localizedDescription)
        }
    }

    /// His latest verified turn (this one, while it runs).
    public static func last(dataRoot: URL) -> Date? {
        read(dataRoot).map { Date(timeIntervalSince1970: $0.at) }
    }

    /// The verified turn before his latest: where a gap this turn closes opened.
    public static func previous(dataRoot: URL) -> Date? {
        read(dataRoot)?.previous.map { Date(timeIntervalSince1970: $0) }
    }
}
