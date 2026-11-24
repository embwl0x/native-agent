import Synchronization
import SenseCore
import Foundation
import DeskCore
import NativeAgentCore
import PersistenceCore
import MindCore
import ProviderRouting
import MacNerves
import NativeAgentShared
// Blueprint: | `ChatOrchestrationClient+StructuredChat.swift` | Structured turns record heard words, speaker, door and birth steering before execution |

extension SwiftNativeChatOrchestrationClient {

    /// The one structured chat turn. Session delivery is mandatory to resolve;
    /// `progress` only adds an observer, and callers await the saved execution.
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
        progress: TurnEventSink?,
        turn: Turn, work: ChatTurnWork
    ) async throws -> StructuredChatExecution {
        let persona = PersonaSelection.current() ?? persona
        let requestedFileAccess = fileAccess
        let fileAccess = DoorPipeline.sharedFileAccess(requestedFileAccess)
        // Each structured execution owns its served-version evidence, even when its caller has a ledger.
        return try await holding(work.with(\.senseReads, SenseTurnReads())) { work in
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty && attachments.isEmpty {
            throw ChatOrchestrationError.emptyMessage
        }

        let resolvedSession = try Self.resolveSessionId(sessionId)
        // Transport and enqueue pins keep the canonical transcript identity stable before work starts, whether or not the user row already exists.
        let runId = turn.run
        let boundTurnId = turn.id
        var acceptedTurn = turn.with(\.session, resolvedSession)
        acceptedTurn.fileAccess = requestedFileAccess
        acceptedTurn.fileAccess = fileAccess
        // A thought may offer hidden steering but write its own opening row when it runs; that row remains its input owner.
        if !suppressUserAppend { acceptedTurn.rows.hiddenInput = nil }
        acceptedTurn.rows.hiddenInput?.persona = persona
        let turn = acceptedTurn
        return try await TurnTraceContext.$turnId.withValue(boundTurnId) {
        return try await SessionTurnDelivery.withDelivery(dataRoot: dataRoot, sessionID: resolvedSession,
            runID: runId, surface: surface, observer: progress, turn: turn, resolver: sessionDelivery) { progress in
        let noticeSink: @Sendable (String, String) async -> Void = { kind, text in
            await progress(.notice(kind: kind, text: text))
        }
        let heardID = suppressUserAppend ? turn.envelope?.answerExperienceID ?? boundTurnId : boundTurnId
        let cancelFlagPath = ChatCancelFlag.accept(
            dataRoot: dataRoot, sessionId: resolvedSession, runId: runId, turnId: boundTurnId)
        let outputMilestoneGate = TurnLifecycleFirstOutputGate()
        let loopObservation = ToolLoopTraceObservation()
        let replyChoices = ReplyChoices()
        let structured = StructuredTurnCall(message: message, attachments: attachments, persona: persona,
            surface: surface, suppressUserAppend: suppressUserAppend, fileAccess: fileAccess,
            resolvedSession: resolvedSession, runId: runId, boundTurnId: boundTurnId, heardID: heardID,
            cancelFlagPath: cancelFlagPath, outputMilestoneGate: outputMilestoneGate,
            loopObservation: loopObservation, replyChoices: replyChoices, noticeSink: noticeSink, progress: progress)
        let outcome: Result<ProducedChatTurn, any Error>
        do {
        let admittedAt = clock()
        await ChatTurnSteering.shared.noteTurnActivity(for: dataRoot, at: admittedAt)
        // Reading intentions does not add their steering principals to the turn.
        let taint = turn.peerSteering
        var envelope = TurnEnvelope.current(turn: turn, surface: surface)
        envelope.answerExperienceID = heardID
        outcome = .success(try await holding(turn) { turn in
            try await holding(turn.with(\.envelope, envelope)) { turn in
                try await withSessionContextMeasurement(sessionId: resolvedSession, surface: surface,
                    turn: turn, work: work) { work in
                    try await executeStructuredTurn(structured, turn: turn.with(\.peerSteering, taint), work: work)

                }
            }
        })
        } catch {
            if ChatCancelFlag.readFailure(cancelFlagPath) != nil { outcome = .failure(CancellationError()) }
            else if case .streamCancelled = error as? TurnEngineError { outcome = .failure(CancellationError()) }
            else { outcome = .failure(error) }
        }
        let (origin, partialContext, steeringToken) = (structured.origin, structured.partialContext,
            structured.steeringToken)
        // The effect has ended. Capture the settlement's identity explicitly: settle does not inherit task locals, and Stop cannot cancel this work.
        var envelope = TurnEnvelope.current(turn: turn, surface: surface)
        envelope.answerExperienceID = heardID
        let settlementTurn = turn.with(\.envelope, envelope)
            .with(\.afterTurnOrigin, origin).with(\.notices, noticeSink)
        let closeSteering = turn.admissionToken == nil
        let replyRowID = turn.replyRow?.messageId(turn: turn.id, session: resolvedSession)
        guard let settlement = structured.settlement.take() else { preconditionFailure("Structured chat already settled") }
        let settled = await settlement.settle { [self, settlementTurn, work, origin, partialContext, steeringToken] in
            await TurnTraceContext.$bus.withValue(turnTraceBus) {
                await TurnTraceContext.$turnId.withValue(settlementTurn.id) {
                    let saved = await self.settleStructuredChatTurn(
                        outcome, observation: loopObservation, context: partialContext,
                        message: message, sessionId: resolvedSession, runId: runId, turnId: boundTurnId, replyRowID: replyRowID,
                        heardID: heardID, model: model, reasoningEffort: reasoningEffort, persona: persona,
                        surface: surface, suppressUserAppend: suppressUserAppend, chosenPaths: replyChoices.paths,
                        cancelFlagPath: cancelFlagPath,
                        outputMilestoneGate: outputMilestoneGate, noticeSink: noticeSink,
                        turn: settlementTurn, work: work)
                    ChatCancelFlag.finish(cancelFlagPath)
                    if closeSteering {
                        await ChatTurnSteering.shared.closeTurn(sessionId: resolvedSession, token: steeringToken)
                    }
                    return saved
                }
            }
        }
        let result = try settled.get()
        if case .success = result.turn, let suffix = TurnSettle.takeStreamSuffix(turn: turn) {
            await progress(.delta(suffix))
        }
        return result
        }
        }
        }
    }

    /// One structured turn's work: open it, prepare its context, then run its streaming tool loop.
    private func executeStructuredTurn(_ structured: StructuredTurnCall, turn: Turn,
                                       work: ChatTurnWork) async throws -> ProducedChatTurn {
        let (attachmentInput, imageBlocks, modelMessage, ask) = try await openStructuredTurn(structured, turn: turn, work: work)
        let gated = makeTracedGatedDispatcher(fileAccess: structured.fileAccess, verifiedSessionId: structured.resolvedSession, work: work)
        let (opening, trace) = try admitContext(structured, imageBlocks: imageBlocks, modelMessage: modelMessage, turn: turn)
        let fromUser = Self.isUsersTurn(surface: structured.surface, sessionId: structured.resolvedSession, dataRoot: dataRoot, turn: turn)
        if fromUser { UserTurnStamp.record(dataRoot: dataRoot, key: structured.runId, door: structured.surface) }
        let (message, persona, session) = (structured.message, structured.persona, structured.resolvedSession)
        let context = LazyContextBox(opening: opening) { [self] in
            try await prepareStructuredContext(message: message, persona: persona, session: session, turn: turn, work: work,
                attachmentInput: attachmentInput, opening: opening, trace: trace, fromUser: fromUser)
        }
        if turn.originPrincipal == "person" || fromUser { context.start() }
        do {
            let result = try await runStructuredTurn(structured, turn: turn, work: work, ask: ask, gated: gated, context: context)
            await context.finish()
            return result
        } catch {
            await context.finish()
            structured.partialContext = context.opened?.context
            throw error
        }
    }

    /// The turn's input: its saved row (or the consumed queued one), its heard experience, and its steering door.
    private func openStructuredTurn(
        _ structured: StructuredTurnCall, turn: Turn, work: ChatTurnWork
    ) async throws -> (attachmentInput: TurnAttachmentInput, imageBlocks: [LLMContentBlock], modelMessage: String,
                       ask: TurnAsk) {
        let (message, attachments, persona, surface) = (structured.message, structured.attachments,
            structured.persona, structured.surface)
        let (suppressUserAppend, resolvedSession, runId, boundTurnId) = (structured.suppressUserAppend,
            structured.resolvedSession, structured.runId, structured.boundTurnId)
        let (heardID, noticeSink) = (structured.heardID, structured.noticeSink)
        // Trust gates image blocks; extracted PDF text enters modelMessage while the persisted user row keeps message.
        let attachmentInput = try Self.turnAttachmentInput(
            message: message, attachments: attachments, dataRoot: dataRoot,
            queryUserMessage: turn.queryUserMessage, runId: runId)
        let imageBlocks = attachmentInput.imageBlocks
        var modelMessage = attachmentInput.userMessage
        if turn.execution?.transcriptRowKind == nil,
           let contract = turn.botContract {
            modelMessage = contract.instructions + "\n\nMessage for this turn:\n" + modelMessage
        }

        if !suppressUserAppend {
            structured.origin = try await appendMessage(
                sessionId: resolvedSession,
                role: "user",
                content: message,
                runId: runId,
                attachments: attachments,
                persona: persona,
                source: ChatThreadKind.transcriptSource(surface: turn.arrivalSurface(authorizing: surface)),
                // Only the caller stamps bot machinery; a person can use the same surface, so the surface cannot prove authorship.
                mechanicalRow: turn.execution?.transcriptRowKind,
                // The row the screen already shows is the row saved (one id, no remount at turn end).
                messageId: turn.rows.pinnedUserMessageID ?? UUID().uuidString,
             turn: turn)
        } else {
            structured.origin = try await consumeEnqueuedMessage(sessionId: resolvedSession, runId: runId)
        }
        let heard = Experience(id: heardID, kind: .heard,
            evidence: (structured.origin.map { [Self.transcriptRef(resolvedSession, $0.messageId)] } ?? [])
                + [.init(source: "door", id: turn.arrivalSurface(authorizing: surface))],
            addressedTo: ["her"], owes: ["answer": .init(to: "conversation:" + resolvedSession)],
            steeredBy: turn.steeringStamp())
        let correlation = turn.replyRoute?.correlationId
        ExperienceStore.record(dataRoot, heardID) { store in
            if heardID == boundTurnId {
                try await store.begin(heard)
                try await store.append([.face(Self.face(message, attachments, from: turn.originPrincipal))], to: heardID)
            }
            try await store.append([.progress("working"),
                .evidence(.init(source: "run", id: runId)),
                .evidence(.init(source: "runtime", id: ExperienceStore.processID))], to: heardID)
            if let correlation {
                try await store.append([.evidence(.init(source: "correlation", id: correlation))], to: heardID)
            }
        }
        // The ask this turn acts on: its heard experience and the runs of its messages, for the person's word (`requestHeard`).
        let ask = TurnAsk(heard: heardID, continuing: heardID != boundTurnId, run: runId)
        // The arrival's own turn writes its row and appraisal: its sender, door and taint, never the working turn's.
        let steeringPersister: ChatTurnSteering.Persister = { [weak self] sid, offer in
            guard let self else { return false }
            let arrival = offer.arrival, enqueueRunID = offer.turn.run
            // A hidden continuation writes no row, as its hidden bubble writes none.
            guard arrival.row != .hidden else { return true }
            return await holding(offer.turn) { turn in
            do {
                let steeringOrigin: AfterTurnOrigin?
                if arrival.row == .saved { steeringOrigin = try await self.consumeEnqueuedMessage(sessionId: sid, runId: turn.run) }
                else {
                    steeringOrigin = try await self.enqueueSteeringMessage(message: arrival.words, sessionId: sid, surface: arrival.surface,
                        attachments: arrival.attachments, turn: turn)
                }
                // A taken arrival never runs its own structured turn. Appraise its durable row without borrowing the working turn's reply.
                await holding(turn.with(\.afterTurnOrigin, steeringOrigin)) { turn in
                    await TurnTraceContext.$bus.withValue(self.turnTraceBus) {
                        await TurnTraceContext.$turnId.withValue(enqueueRunID) {
                            let afterReply = await self.engine.deferMemoryPromotion(
                                userMessage: arrival.words, assistantMessage: "", toolDispatches: [],
                                sessionId: sid, surface: arrival.surface, turn: turn, work: work)
                            await afterReply.start()
                        }
                    }
                }
                // A message this turn reads while it runs joins its ask.
                ask.joined(enqueueRunID)
                return true
            } catch {
                await Self.reportTranscriptWriteFailure(
                    label: "steeringOffer",
                    path: self.dataRoot,
                    error: error,
                    userText: """
                        Couldn't save your message to the transcript, so the turn in progress didn't take it; it runs as its own \
                        turn next.
                        """,
                    onNotice: noticeSink,
                 turn: turn)
                return false
            }
            }
        }
        structured.steeringToken = try await ChatTurnSteering.shared.openTurn(
            sessionId: resolvedSession, turnId: turn.id, dataRoot: dataRoot,
            door: turn.replyRoute ?? TurnEnvelope.current(turn: turn, surface: surface).deliveryRoute, persist: steeringPersister,turn: turn)
        return (attachmentInput, imageBlocks, modelMessage, ask)
    }

    private func admitContext(_ structured: StructuredTurnCall, imageBlocks: [LLMContentBlock], modelMessage: String,
                              turn: Turn) throws -> (TurnContext, ContextStageTrace) {
        var modelMessage = modelMessage
        let (message, surface, fileAccess) = (structured.message, structured.surface, structured.fileAccess)
        let (resolvedSession, runId, boundTurnId) = (structured.resolvedSession, structured.runId, structured.boundTurnId)
        let workTitle = String(TurnTraceRedactor.redactText(message)
            .split(whereSeparator: \.isNewline).first.map(String.init)?.prefix(96) ?? "".prefix(96))
        TurnTraceBus.fire(TurnTraceEvent(
            turnId: boundTurnId, kind: "work.identified", sessionId: resolvedSession,
            surface: surface, payload: .object(["title": .string(workTitle),
                "workIdentity": turn.envelope?.workIdentity.map(JSONValue.string) ?? .null]),
            turn: turn
        ), on: turnTraceBus)
        TurnLifecycleTelemetry.emit(
            .turnAccepted,
            surface: surface,
            sessionId: resolvedSession,
            observedBy: "structured_stream.entry",
            turnId: boundTurnId,
            on: turnTraceBus,
            turn: turn
        )
        var preparationTrace = ContextStageTrace(turn: turn)
        let checkpointStart = DispatchTime.now().uptimeNanoseconds
        // Write the acceptance checkpoint before assembly so relaunch can recover the turn.
        // A failed write reaches the turn as evidence that restart recovery is unavailable; it does not end the answer.
        if turn.resumingCheckpoint == nil, let root = engine.remPinsDataRoot {
            let saved = try SwiftNativeTurnEngine.continuation(dataRoot: root, runId: runId, sessionId: resolvedSession, surface: surface,
                userMessage: message, fileAccess: fileAccess, capabilityProfile: continuationCapabilityProfile, turn: turn)
            if let saved, let unwritten = TurnCheckpointWriter.persist(
                SwiftNativeTurnEngine.checkpoint(saved, turnId: boundTurnId, sessionId: resolvedSession,
                    hiddenInput: turn.rows.hiddenInput), dataRoot: root) {
                modelMessage += "\n\n[" + unwritten + "]"
            }
        }
        preparationTrace.record(.checkpoint, since: checkpointStart)
        guard let admission = turn.admission, let effort = admission.reasoningEffort else {
            throw ProviderRoutingError.configurationFailed("The turn's admitted Think level is unavailable.")
        }
        return (TurnContext(surface: surface, personaDocs: [:], personaFingerprint: "", recalled: [],
            modelId: admission.model, reasoningEffort: effort, providerId: admission.provider, serviceTier: admission.serviceTier,
            toolsAvailable: [], userMessage: modelMessage, imageBlocks: imageBlocks, turnReach: TurnReach()), preparationTrace)
    }

    private func prepareStructuredContext(message: String, persona: String?, session resolvedSession: String, turn: Turn, work: ChatTurnWork,
                                          attachmentInput: TurnAttachmentInput, opening: TurnContext,
                                          trace: ContextStageTrace, fromUser: Bool) async throws -> LazyContextBox.Prepared {
        let (surface, runId, boundTurnId) = (opening.surface, turn.run, turn.id)
        var preparationTrace = trace
        async let cognitiveProjectionTask = try prepareCognitiveTurnProjection(
            surface: surface,
            userMessage: message,
            sessionId: resolvedSession,
            fromUser: fromUser,
         turn: turn)

        // Context-build failures are saved and rethrown; one bound turn ID keeps assembly and execution traces correlated.
        let historyStart = DispatchTime.now().uptimeNanoseconds
        let built = try await TurnTraceContext.$bus.withValue(turnTraceBus) {
            try await TurnTraceContext.$turnId.withValue(boundTurnId) {
                try await engine.buildTurnContextWithHistory(
                    surface: surface,
                    userMessage: opening.userMessage,
                    sessionId: resolvedSession,
                    historyLimit: historyLimit,
                    historyReader: history,
                    personaOverride: persona,
                    excludeHistoryRunId: runId,
                    imageBlocks: opening.imageBlocks,
                    queryUserMessage: attachmentInput.queryUserMessage,
                    startedNs: historyStart,
                 turn: turn, work: work)
            }
            }
        let historyEnd = DispatchTime.now().uptimeNanoseconds
        let threadedCtx = built.context
        // The builder's summary covers historyStart up to its close; the rest is the hop back onto this actor.
        preparationTrace.record(.historyContext, since: historyStart, until: historyEnd)
        preparationTrace.record(.historyBuild, since: historyStart, until: built.closedNs, of: .historyContext)
        preparationTrace.record(.historyContextReturn, since: built.closedNs, until: historyEnd, of: .historyContext)
        let cognitionJoinStart = DispatchTime.now().uptimeNanoseconds
        let cognitiveProjection = try await cognitiveProjectionTask
        preparationTrace.record(.cognitionJoin, since: cognitionJoinStart)
        let appendStart = DispatchTime.now().uptimeNanoseconds
        let threadedCtxWithCognition = await Self.contextByAppendingCognitiveCapsule(
            to: threadedCtx,
            projection: cognitiveProjection?.projection
        )
        // `app` is the agent's one door (docs/ONE_DOOR.md): the turn offers it alone.
        let providerCtx = Self.applyLazyToolFilter(to: threadedCtxWithCognition)
        preparationTrace.record(.cognitiveAppend, since: appendStart)
        _ = TurnTraceContext.$bus.withValue(turnTraceBus) {
            TurnTraceContext.$turnId.withValue(boundTurnId) {
                preparationTrace.emit(kind: "turn.preparation.summary", surface: surface)
            }
        }
        Self.traceFinalToolContract(
            turnId: boundTurnId,
            wire: providerCtx.toolSchemas,
            surface: surface,
            turn: turn, work: work)
        return .init(context: providerCtx, projection: cognitiveProjection)
    }

    /// The turn's streaming tool loop under its held parts, and what it produced.
    private func runStructuredTurn(
        _ structured: StructuredTurnCall, turn: Turn, work: ChatTurnWork, ask: TurnAsk, gated: any ToolDispatchClient,
        context: LazyContextBox
    ) async throws -> ProducedChatTurn {
        let (message, surface, fileAccess, resolvedSession) = (structured.message, structured.surface,
            structured.fileAccess, structured.resolvedSession)
        let (runId, boundTurnId, noticeSink, progress) = (structured.runId, structured.boundTurnId,
            structured.noticeSink, structured.progress)
        let (outputMilestoneGate, loopObservation, replyChoices) = (structured.outputMilestoneGate,
            structured.loopObservation, structured.replyChoices)
        let (cancelFlagPath, origin) = (structured.cancelFlagPath, structured.origin)
        let receiptWriter = ToolReceiptWriter(
            client: self, sessionId: resolvedSession, runId: runId, surface: surface,
            laneLabel: "", onNotice: noticeSink
        )
        let effectiveProgress = ToolProgress { event, receipt, invocationID in
            let redactedEvent = Self.redactedProgressEvent(event)
            if let receipt {
                await receiptWriter.write(receipt)
            }
            if case .delta = redactedEvent,
               await outputMilestoneGate.claim() {
                TurnLifecycleTelemetry.emit(
                    .surfaceOutputEnqueued,
                    surface: surface,
                    sessionId: resolvedSession,
                    observedBy: "structured_stream.progress",
                    turn: turn
                )
            }
            await self.observeCognitiveProgressEvent(
                sessionId: resolvedSession,
                runId: runId,
                surface: surface,
                event: redactedEvent, turn: turn.with(\.invocationID, invocationID)
            )
            if case .delta(let text) = redactedEvent {
                self.liveTurns?.emit(sessionId: resolvedSession, surface: surface, runId: runId, .delta(text))
            }
            if case .writing(let writing) = redactedEvent, let writing {
                self.liveTurns?.emit(sessionId: resolvedSession, surface: surface, runId: runId, .writing(writing.line))
            }
            await progress(redactedEvent)
        }

        let result: TurnEngineResult
        result = try await holding(turn.with(\.afterTurnOrigin, origin)) { turn in
            return try await holding(turn.with(\.replyChoices, replyChoices)) { turn in
            try await holding(turn.with(\.observation, loopObservation)) { turn in
            try await TurnTraceContext.$bus.withValue(turnTraceBus) {
            try await TurnTraceContext.$turnId.withValue(boundTurnId) {
            try await holding(turn.with(\.offeredTools, nil)) { turn in
            try await holding(turn.with(\.settingRequestEvidence, { [self] setting, value, currentValue, quote in
                let heard = await Self.requestHeard(quote, setting: setting, message: message, surface: surface, session: resolvedSession,
                                                    dataRoot: dataRoot, turn: turn)
                guard heard.readable else { return heard.current ? false : nil }
                guard heard.found else { return nil }
                guard case .bool = value else { return false }
                return heard.current && value != currentValue && heard.lastChange?["decided_by"] == .string("agent")
                    && heard.lastChange?["old_value"] == value && heard.lastChange?["new_value"] == currentValue
            }).with(\.personsAsk, { [self] in
                await Self.personsAsk(message: message, surface: surface, session: resolvedSession, dataRoot: dataRoot, ask: ask, turn: turn)
            })) { turn in
                return try await engine.executeTurnWithStreamingToolLoop(
                        surface: surface,
                        userMessage: message,
                        sessionId: resolvedSession,
                        runId: runId,
                        llm: llm,
                        tools: gated,
                        context: context,
                        progress: effectiveProgress,
                        onDelivery: { await self.commitDeliveredCognitiveTurnProjection(context.opened?.projection, turn: turn) },
                        cancelFlagPath: cancelFlagPath,
                        fileAccess: fileAccess,
                        capabilityProfile: continuationCapabilityProfile, turn: turn, work: work,
                        call: LLMCall(turn: turn, surface: surface, purpose: "other").with(\.conversationRequest, true)
                    )
            }
            }
            }
            }
            }
            }
        }
        return ProducedChatTurn(result: result, context: context.opened?.context,
            attachments: ChatGeneratedImageArtifacts.attachments(
                from: result.toolDispatches, chosen: replyChoices.paths, dataRoot: dataRoot),
            answerID: turn.replyRow?.messageId(turn: boundTurnId, session: resolvedSession) ?? UUID().uuidString,
            cognitiveProjection: context.opened?.projection)
    }

    /// One structured chat turn: its fixed identity and gates, and what settlement reads however the work ended.
    final class StructuredTurnCall {
        let message: String
        let attachments: [MultimodalAttachment]
        let persona: String?
        let surface: String
        let suppressUserAppend: Bool
        let fileAccess: String
        let resolvedSession: String
        let runId: String
        let boundTurnId: String
        let heardID: String
        let cancelFlagPath: URL
        fileprivate var settlement: SettlementTicket? = SettlementTicket("structured chat")
        let outputMilestoneGate: TurnLifecycleFirstOutputGate
        let loopObservation: ToolLoopTraceObservation
        let replyChoices: ReplyChoices
        let noticeSink: @Sendable (String, String) async -> Void
        let progress: TurnEventSink
        /// Written the moment the turn makes each, so settlement reads them after a throw.
        var origin: AfterTurnOrigin?
        var partialContext: TurnContext?
        var steeringToken: UUID?

        init(message: String, attachments: [MultimodalAttachment], persona: String?, surface: String,
             suppressUserAppend: Bool, fileAccess: String, resolvedSession: String, runId: String, boundTurnId: String,
             heardID: String, cancelFlagPath: URL, outputMilestoneGate: TurnLifecycleFirstOutputGate,
             loopObservation: ToolLoopTraceObservation, replyChoices: ReplyChoices,
             noticeSink: @escaping @Sendable (String, String) async -> Void, progress: @escaping TurnEventSink) {
            self.message = message
            self.attachments = attachments
            self.persona = persona
            self.surface = surface
            self.suppressUserAppend = suppressUserAppend
            self.fileAccess = fileAccess
            self.resolvedSession = resolvedSession
            self.runId = runId
            self.boundTurnId = boundTurnId
            self.heardID = heardID
            self.cancelFlagPath = cancelFlagPath
            self.outputMilestoneGate = outputMilestoneGate
            self.loopObservation = loopObservation
            self.replyChoices = replyChoices
            self.noticeSink = noticeSink
            self.progress = progress
        }
    }

    /// Both protocols use canonical order so the always-on floor stays stable while remaining schemas retain incoming order.
    static func applyLazyToolFilter(
        to context: TurnContext
    ) -> TurnContext {
        let allowed = SwiftToolDispatcher.alwaysOnCoreNames
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
        fromUser: Bool,
        turn: Turn
    ) async throws -> (request: CognitiveCapsuleRequest, projection: CognitionAtTurn)? {
        guard let cognitiveRuntime else { return nil }
        let request = CognitiveCapsuleRequest(
            surface: surface,
            userMessage: userMessage,
            sessionId: sessionId,
            mode: .inject,
            // The model window sizes the request; the substrate applies its own ceiling.
            maximumCharacters: try ContextBudgetPolicy.resolve(turn: turn, dataRoot: dataRoot).capsuleChars,
            turnKind: Self.cognitiveMessageTurnKind(),
            fromUser: fromUser,
            previousUserTurnAt: fromUser ? UserTurnStamp.previous(dataRoot: dataRoot) : nil,
            speaker: fromUser ? CognitiveCare.ownerKey : Self.cognitivePeerSpeaker(sessionId: sessionId, dataRoot: dataRoot, turn: turn)
        )
        return (request, await cognitiveRuntime.prepareTurnProjection(request, turn: turn))
    }

    /// Resolve a peer's person key from the same session and origin owner used by after-turn cares; no named peer yields nil.
    static func cognitivePeerSpeaker(sessionId: String, dataRoot: URL, turn: Turn) -> String? {
        var metadata: [String: JSONValue] = ["sessionId": .string(sessionId)]
        if let origin = turn.origin {
            var object: [String: JSONValue] = [:]
            if let agent = origin.agent { object["agent"] = .string(agent) }
            if let authored = origin.authored { object["authored"] = .string(authored.rawValue) }
            metadata["origin"] = .object(object)
        }
        return CognitiveSubstrate.peerIdentity(metadata: metadata, dataRoot: dataRoot).map(CognitiveCareProvenance.personKey)
    }

    /// Direct-conversation ingress proof shared by owner-turn stamps and pinned conversation requests; the caller checks its current request context.
    /// Wakes, peers, bridges and other senders cannot claim the user's return.
    public static func isUsersTurn(surface: String, sessionId: String, dataRoot: URL, turn: Turn) -> Bool {
        guard let envelope = turn.envelope, turn.origin == nil,
              envelope.agent == nil,
              SessionConversation.kind(sessionId, dataRoot: dataRoot)?.isPersonConversation == true else { return false }
        switch surface.lowercased() {
        case "chat":
            return envelope.declaredRemote == false
        case "ios":
            return envelope.commandSignatureVerified == true
        case "telegram":
            guard let sender = envelope.verifiedUserId,
                  let owner = telegramOwnerId(dataRoot: dataRoot) else { return false }
            return sender.trimmingCharacters(in: .whitespacesAndNewlines) == owner
        default:
            return false
        }
    }

    /// The ask a turn is acting on now: the heard experience it answers (its own for a fresh turn; for a continuation after a card, the
    /// earlier turn's, named by the envelope's `answerExperienceID`), whose `run` evidence names every run that worked on that ask, and the
    /// runs of messages that joined the turn while it ran (`ChatTurnSteering` arrivals this turn read). The person's messages of this ask
    /// are their rows with one of those runs.
    final class TurnAsk: Sendable {
        let heard: String
        /// True when this turn carries on an earlier turn's ask (a card's continuation), whose message is not this turn's own.
        let continuing: Bool
        private let runs: Mutex<Set<String>>
        init(heard: String, continuing: Bool, run: String) { self.heard = heard; self.continuing = continuing; runs = Mutex([run]) }
        /// A message that joined this turn while it ran is part of its ask.
        func joined(_ run: String) { runs.withLock { _ = $0.insert(run) } }
        /// The runs of this ask: this turn's, those that joined it, and every run the heard experience records.
        func allRuns(dataRoot: URL) async -> Set<String> {
            let own = runs.withLock { $0 }
            let recorded = (try? await ExperienceStore.at(dataRoot).experience(heard))?.evidence.filter { $0.source == "run" }.map(\.id) ?? []
            return own.union(recorded)
        }
    }

    /// What one reading of request evidence found for a quote (`requestHeard`).
    struct RequestHeard: Sendable {
        /// The message that started this turn says it, and its author's words count for the agent's own dials.
        var current = false
        /// Someone whose words count for the agent's own dials said it: in this turn's message or earlier in this conversation.
        var found = false
        /// The conversation's history was read whole.
        var readable = false
        /// The receipt fields (decided_by, old_value, new_value) of the last change of the asked setting in this conversation.
        var lastChange: [String: JSONValue]?
    }

    /// Request evidence for the agent's own dials below Full Mac on a turn that is not the person's own ask (`Turn.settingRequestEvidence`):
    /// were the quote's words said in this conversation by someone whose words count (the person, a trusted agent, a human relayed through a
    /// bridge). A message says a quote when it contains the quote whole, or one of the quote's quoted runs of three words or more (a transport
    /// may wrap the request with attribution). A tool result, a page, a file, a helper and the agent's own words are no message here.
    static func requestHeard(_ quote: String, setting: String?, message: String, surface: String, session: String, dataRoot: URL,
                             turn: Turn) async -> RequestHeard {
        // Match quoted request text even when a transport wraps it with attribution.
        let marks = CharacterSet(charactersIn: "\"“”'‘’")
        let segments = quote.components(separatedBy: marks)
            .map { TextNormalization.lowercasedWithCollapsedWhitespace($0)
                .trimmingCharacters(in: .punctuationCharacters.union(.whitespaces)) }
            .filter { $0.split(separator: " ").count >= 3 }
        let candidates = [TextNormalization.lowercasedWithCollapsedWhitespace(quote)] + segments
        func quotes(_ text: String) -> Bool {
            let normalized = TextNormalization.lowercasedWithCollapsedWhitespace(text)
            return candidates.contains { normalized.contains($0) }
        }
        let envelope = TurnEnvelope.current(turn: turn, surface: surface)
        let origin = turn.origin
        let lane = (origin?.agent ?? envelope.agent) == "agent"
            ? PeerDataTaint.attestedPeerID(turn: turn).map { "peer:" + $0 } : origin?.agent ?? envelope.agent
        var heard = RequestHeard()
        heard.current = (origin?.authored == .human || lane.map({ PeerDataTaint.ownerTrusts(turn.dataRoot, $0) }) == true
            || (origin == nil && envelope.agent == nil && MyQueue.Door(rawValue: surface) != nil)) && quotes(message)
        heard.found = heard.current
        guard let history = try? await SessionHistoryReader(dataRoot: dataRoot).messagesWithStats(
            forSessionId: session, strictEvidence: true),
            !["read_failed", "invalid_encoding", "invalid_session_id"].contains(history.stats.mode),
            history.stats.malformedRowCount == 0, history.stats.invalidShapeRowCount == 0 else { return heard }
        heard.readable = true
        let rows: [(row: HistoryChatMessage, fields: [String: JSONValue], author: String?, peer: String?)] = history.messages.compactMap { row in
            guard case .object(let fields)? = row.extras else { return nil }
            let author = SwiftToolDispatcher.persistedHistoryAuthor(role: row.role, row: fields)
            let peer = row.role == "user" ? SwiftToolDispatcher.persistedHistoryPeer(role: row.role, row: fields) : nil
            return (row, fields, author, peer)
        }
        let historyPeers: [String] = heard.found ? [] : rows.flatMap { item -> [String] in
            let persons = item.author == SwiftToolDispatcher.ownerAuthor
                || (item.peer == nil && envelope.verifiedUserId != nil && item.author == envelope.verifiedUserId)
            guard !persons, item.author != "human via bridge", let peer = item.peer else { return [] }
            return peer.split(separator: "\n").map(String.init)
        }
        let trust = PeerTrust.read(historyPeers, dataRoot: turn.dataRoot)
        for item in rows {
            if !heard.found {
                let persons = item.author == SwiftToolDispatcher.ownerAuthor
                    || (item.peer == nil && envelope.verifiedUserId != nil && item.author == envelope.verifiedUserId)
                if persons || item.author == "human via bridge"
                    || item.peer.map({ $0.split(separator: "\n").allSatisfy { trust.ownerTrusts(String($0)) } }) == true {
                    heard.found = quotes(item.row.content)
                }
            }
            guard let setting, case .object(let metadata)? = item.fields["metadata"],
                  metadata["kind"] == .string(ChatTranscriptToolMessageKind.toolUse),
                  case .string(let result)? = metadata["resultSummary"],
                  let receipt = try? JSONValue.parse(Data(result.utf8)),
                  ChatTranscriptEvidenceRendering.receiptField("setting", in: receipt) == .string(setting),
                  ChatTranscriptEvidenceRendering.receiptField("changed", in: receipt) == .bool(true) else { continue }
            heard.lastChange = ["decided_by", "old_value", "new_value"].reduce(into: [:]) {
                $0[$1] = ChatTranscriptEvidenceRendering.receiptField($1, in: receipt)
            }
        }
        return heard
    }

    /// The person's own ask this turn acts on (`Turn.personsAsk`), when the person started it: their Mac chat, their signed phone, Telegram's
    /// one owner (`isUsersTurn`), or a card's continuation at such a door; and no untrusted agent steers it. The ask is the person's own
    /// messages of it (`TurnAsk`): this turn's (never a continuation's, which is the card's outcome), those that joined it while it ran, and
    /// the one a card's answer continues. Nil on any other turn, so its levers keep their card.
    static func personsAsk(message: String, surface: String, session: String, dataRoot: URL, ask: TurnAsk, turn: Turn) async -> String? {
        let envelope = TurnEnvelope.current(turn: turn, surface: surface)
        let door = surface.lowercased()
        let personTurn = isUsersTurn(surface: surface, sessionId: session, dataRoot: dataRoot, turn: turn)
            || (ask.continuing && turn.origin == nil && envelope.agent == nil
                && SessionConversation.kind(session, dataRoot: dataRoot)?.isPersonConversation == true
                && (door == "telegram" ? envelope.verifiedUserId.map { $0 == telegramOwnerId(dataRoot: dataRoot) } == true
                    : ["chat", "ios"].contains(door)))
        guard personTurn, CapabilityLifecycle.turnWriteCheck(turn)() == nil else { return nil }
        var said: [String] = ask.continuing ? [] : [message]
        let runs = await ask.allRuns(dataRoot: dataRoot)
        if let history = try? await SessionHistoryReader(dataRoot: dataRoot).messagesWithStats(forSessionId: session, strictEvidence: true) {
            for row in history.messages where row.role == "user" {
                guard case .object(let fields)? = row.extras, let run = fields["runId"]?.stringValue, runs.contains(run) else { continue }
                let author = SwiftToolDispatcher.persistedHistoryAuthor(role: row.role, row: fields)
                let peer = SwiftToolDispatcher.persistedHistoryPeer(role: row.role, row: fields)
                guard author == SwiftToolDispatcher.ownerAuthor || (peer == nil && envelope.verifiedUserId != nil && author == envelope.verifiedUserId)
                else { continue }
                said.append(row.content)
            }
        }
        let words = said.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
            .reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
        return words.isEmpty ? nil : words.joined(separator: "\n")
    }

    /// Only a single allowlisted user identifies the bot's owner.
    static func telegramOwnerId(dataRoot: URL) -> String? {
        let path = dataRoot.appendingPathComponent("telegram/config.json")
        guard let data = try? Data(contentsOf: path),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        let users = Set(["allowed_user_ids", "allowedUserIds"].flatMap { key in
            ((object[key] as? [Any]) ?? []).map { "\($0)".trimmingCharacters(in: .whitespacesAndNewlines) }
        }.filter { !$0.isEmpty })
        // A sole private chat is its user's id, as TelegramBotConfig.ownerUserId defines.
        let ids = users.isEmpty ? Set(["allowed_chat_ids", "allowedChatIds"].flatMap { key in
            ((object[key] as? [Any]) ?? []).compactMap { Int64("\($0)") }.filter { $0 > 0 }.map(String.init)
        }) : users
        return ids.count == 1 ? ids.first : nil
    }

    static func contextByAppendingCognitiveCapsule(
        to context: TurnContext,
        projection: CognitionAtTurn?
    ) async -> TurnContext {
        guard let runtimeContext = Self.cognitiveRuntimeContext(
            capsule: projection?.capsule,
            posture: projection?.posture
        ) else {
            return context
        }
        var projectedContext = context
        projectedContext.innerStream.append(runtimeContext)
        projectedContext.cognitiveRuntimeContext = runtimeContext
        projectedContext.cognitiveFeelingFrame = projection?.capsule?.feelingFrame
        // Projection bookkeeping commits only after the provider accepts this material.
        return projectedContext
    }

    /// The loop's confirmed-delivery boundary commits the prepared presentation once.
    func commitDeliveredCognitiveTurnProjection(
        _ prepared: (request: CognitiveCapsuleRequest, projection: CognitionAtTurn)?,
        turn: Turn
    ) async {
        guard let prepared, let cognitiveRuntime else { return }
        let (request, projection) = prepared
        if let why = projection.why {
            TurnTraceBus.fire(TurnTraceEvent(
                turnId: turn.id, kind: "mind.why", sessionId: request.sessionId,
                surface: request.surface, payload: why,
                turn: turn
            ), on: turnTraceBus)
        }
        await cognitiveRuntime.commitTurnProjection(
            projection,
            request: request,
            turn: turn
        )
    }

    static let cognitiveHeaderLine = "[CognitiveSubstrate] private — it colors you; never quote it."

    func commitRepliedCognitiveTurnProjection(
        _ prepared: (request: CognitiveCapsuleRequest, projection: CognitionAtTurn)?
    ) async {
        guard let prepared, let cognitiveRuntime else { return }
        await cognitiveRuntime.commitReplyFeeling(prepared.projection, request: prepared.request)
    }

    static func cognitiveRuntimeContext(
        capsule: CognitiveCapsule?,
        posture: OrganismBehaviorPosture?
    ) -> String? {
        var sections: [String] = []
        // The ops line rides FIRST and on its own, so it never reads as part of the agent's private inner state; it is empty on a default posture.
        if let posture {
            sections.append(posture.privateRuntimeContext())
        }
        if let capsule,
           !capsule.combined.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            sections.append(Self.cognitiveHeaderLine + "\n" + capsule.combined)
        }
        let combined = sections
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")
        return combined.isEmpty ? nil : combined
    }
}
