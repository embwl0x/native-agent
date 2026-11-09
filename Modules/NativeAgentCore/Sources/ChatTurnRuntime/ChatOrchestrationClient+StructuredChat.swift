import AuthoredCapabilities
import Foundation
import Senses
import CryptoKit
import Desk
import NativeAgentCore
import PersistenceCore
import TurnTrace
import Transcripts
import Experiences
import PersonaEngine
import MemoryV2
import ProviderRouting
import TrustCenter
import Dispatcher
import MacControl
import SwarmRuns
import MacIntegration
import CognitiveSubstrate
import Context
import ToolRegistry
import StandingBots
import ChatToolParsing
import NativeAgentShared
// Blueprint: | `ChatOrchestrationClient+StructuredChat.swift` | Session-owned delivery, accepted input and canonical settlement |

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
        let fileAccess = FileAccessGatedDispatcher.sharedFileAccess(requestedFileAccess)
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
            runID: runId, surface: surface, observer: progress,turn: turn) { progress in
        let noticeSink: @Sendable (String, String) async -> Void = { kind, text in
            await progress(.notice(kind: kind, text: text))
        }
        var partialContext: TurnContext?
        var origin: AfterTurnOrigin?
        var steeringToken: UUID?
        let heardID = suppressUserAppend ? turn.envelope?.answerExperienceID ?? boundTurnId : boundTurnId
        let cancelFlagPath = ChatCancelFlag.accept(
            dataRoot: dataRoot, sessionId: resolvedSession, runId: runId, turnId: boundTurnId)
        let outputMilestoneGate = TurnLifecycleFirstOutputGate()
        let loopObservation = ToolLoopTraceObservation()
        let replyChoices = ReplyChoices()
        let outcome: Result<ProducedChatTurn, any Error>
        do {
        let admittedAt = clock()
        await ChatTurnSteering.shared.noteTurnActivity(for: dataRoot, at: admittedAt)
        // Reading intentions does not add their steering principals to the turn.
        let taint = turn.peerSteering
        func executeTurn(turn: Turn, work: ChatTurnWork) async throws -> ProducedChatTurn {
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
            origin = try await appendMessage(
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
            origin = try await consumeEnqueuedMessage(sessionId: resolvedSession, runId: runId)
        }
        let heard = Experience(id: heardID, kind: .heard,
            evidence: origin.map { [Self.transcriptRef(resolvedSession, $0.messageId)] } ?? [],
            addressedTo: ["her"], owes: ["answer": .init(to: "conversation:" + resolvedSession)])
        let correlation = turn.replyRoute?.correlationId
        ExperienceStore.record(dataRoot, heardID) { store in
            if heardID == boundTurnId {
                try await store.begin(heard)
                try await store.append([.face(Self.face(message, attachments))], to: heardID)
            }
            try await store.append([.progress("working"),
                .evidence(.init(source: "run", id: runId)),
                .evidence(.init(source: "runtime", id: ExperienceStore.processID))], to: heardID)
            if let correlation {
                try await store.append([.evidence(.init(source: "correlation", id: correlation))], to: heardID)
            }
        }
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
        steeringToken = try await ChatTurnSteering.shared.openTurn(
            sessionId: resolvedSession, turnId: turn.id, dataRoot: dataRoot,
            door: turn.replyRoute ?? TurnEnvelope.current(turn: turn, surface: surface).deliveryRoute, persist: steeringPersister,turn: turn)
        let gated = makeTracedGatedDispatcher(
            fileAccess: fileAccess, verifiedSessionId: resolvedSession,
        work: work)
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
        async let cognitiveProjectionTask = try prepareCognitiveTurnProjection(
            surface: surface,
            userMessage: message,
            sessionId: resolvedSession,
            runId: runId,
         turn: turn)

        // Context-build failures are saved and rethrown; one bound turn ID keeps assembly and execution traces correlated.
        let historyStart = DispatchTime.now().uptimeNanoseconds
        let threadedCtx = try await TurnTraceContext.$bus.withValue(turnTraceBus) {
            try await TurnTraceContext.$turnId.withValue(boundTurnId) {
                try await engine.buildTurnContextWithHistory(
                    surface: surface,
                    userMessage: modelMessage,
                    sessionId: resolvedSession,
                    historyLimit: historyLimit,
                    historyReader: history,
                    personaOverride: persona,
                    excludeHistoryRunId: runId,
                    imageBlocks: imageBlocks,
                    queryUserMessage: attachmentInput.queryUserMessage,
                 turn: turn, work: work)
            }
            }
        preparationTrace.record(.historyContext, since: historyStart)
        let cognitionJoinStart = DispatchTime.now().uptimeNanoseconds
        let cognitiveProjection = try await cognitiveProjectionTask
        preparationTrace.record(.cognitionJoin, since: cognitionJoinStart)
        let appendStart = DispatchTime.now().uptimeNanoseconds
        let threadedCtxWithCognition = await Self.contextByAppendingCognitiveCapsule(
            to: threadedCtx,
            projection: cognitiveProjection?.projection
        )
        // `app` is the agent's one tool (docs/TOOL_LOADING.md): the turn offers it alone.
        let providerCtx = Self.applyLazyToolFilter(to: threadedCtxWithCognition, activeTools: [])
        preparationTrace.record(.cognitiveAppend, since: appendStart)
        _ = TurnTraceContext.$bus.withValue(turnTraceBus) {
            TurnTraceContext.$turnId.withValue(boundTurnId) {
                preparationTrace.emit(kind: "turn.preparation.summary", surface: surface)
            }
        }
        partialContext = providerCtx
        Self.traceFinalToolContract(
            turnId: boundTurnId,
            wire: providerCtx.toolSchemas,
            surface: surface,
            turn: turn, work: work)

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
                ChatLiveTap.emit(sessionId: resolvedSession, surface: surface, runId: runId, .delta(text))
            }
            if case .writing(let writing) = redactedEvent, let writing {
                ChatLiveTap.emit(sessionId: resolvedSession, surface: surface, runId: runId, .writing(writing.line))
            }
            await progress(redactedEvent)
        }

        let result: TurnEngineResult
        result = try await holding(turn.with(\.afterTurnOrigin, origin)) { turn in
            return try await holding(turn.with(\.replyChoices, replyChoices)) { turn in
            try await holding(turn.with(\.observation, loopObservation)) { turn in
            try await TurnTraceContext.$bus.withValue(turnTraceBus) {
            try await TurnTraceContext.$turnId.withValue(boundTurnId) {
            try await holding(turn.with(\.offeredTools, Set(providerCtx.toolSchemas.map(\.name)))) { turn in
            try await holding(turn.with(\.settingRequestEvidence, { [self] setting, value, currentValue, quote in
                func normalized(_ text: String) -> String {
                    text.lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ")
                }
                // Match quoted request text even when a transport wraps it with attribution.
                let marks = CharacterSet(charactersIn: "\"“”'‘’")
                let segments = quote.components(separatedBy: marks).map { normalized($0).trimmingCharacters(in: .punctuationCharacters.union(.whitespaces)) }
                    .filter { $0.split(separator: " ").count >= 3 }
                let candidates = [normalized(quote)] + segments
                func quotes(_ text: String) -> Bool { let t = normalized(text); return candidates.contains { t.contains($0) } }
                let envelope = TurnEnvelope.current(turn: turn, surface: surface)
                let origin = turn.origin
                let lane = (origin?.agent ?? envelope.agent) == "agent" ? envelope.verifiedUserId.map { "peer:" + $0 } : origin?.agent ?? envelope.agent
                let currentRequest = (origin?.authored == .human || lane.map(PeerDataTaint.ownerTrusts) == true
                    || (origin == nil && envelope.agent == nil && MyQueue.Door(rawValue: surface) != nil))
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
                    if author == SwiftToolDispatcher.ownerAuthor || author == "human via bridge"
                        || peer.map({ $0.split(separator: "\n").allSatisfy { PeerDataTaint.ownerTrusts(String($0)) } }) == true
                        || (peer == nil && envelope.verifiedUserId != nil && author == envelope.verifiedUserId) {
                        found = found || quotes(row.content)
                    }
                    guard case .object(let metadata)? = fields["metadata"], metadata["kind"] == .string(ChatTranscriptToolMessageKind.toolUse),
                          case .string(let result)? = metadata["resultSummary"],
                          let receipt = try? JSONValue.parse(Data(result.utf8)),
                          ChatTranscriptEvidenceRendering.receiptField("setting", in: receipt) == .string(setting),
                          ChatTranscriptEvidenceRendering.receiptField("changed", in: receipt) == .bool(true) else { continue }
                    lastChange = ["decided_by", "old_value", "new_value"].reduce(into: [:]) {
                        $0[$1] = ChatTranscriptEvidenceRendering.receiptField($1, in: receipt)
                    }
                }
                guard found else { return nil }
                guard case .bool = value else { return false }
                return currentRequest && value != currentValue && lastChange?["decided_by"] == .string("agent")
                    && lastChange?["old_value"] == value && lastChange?["new_value"] == currentValue
            })) { turn in
                return try await engine.executeTurnWithStreamingToolLoop(
                        surface: surface,
                        userMessage: message,
                        sessionId: resolvedSession,
                        runId: runId,
                        llm: llm,
                        tools: gated,
                        preBuiltContext: providerCtx,
                        progress: effectiveProgress,
                        onDelivery: { await self.commitDeliveredCognitiveTurnProjection(cognitiveProjection, turn: turn) },
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
        return ProducedChatTurn(result: result, context: providerCtx, personaFingerprint: threadedCtx.personaFingerprint,
            attachments: ChatGeneratedImageArtifacts.attachments(
                from: result.toolDispatches, chosen: replyChoices.paths, dataRoot: dataRoot),
            answerID: turn.replyRow?.messageId(turn: boundTurnId, session: resolvedSession) ?? UUID().uuidString,
            cognitiveProjection: cognitiveProjection)
        }
        var envelope = TurnEnvelope.current(turn: turn, surface: surface)
        envelope.answerExperienceID = heardID
        outcome = .success(try await holding(turn) { turn in
            try await holding(turn.with(\.envelope, envelope)) { turn in
                try await withSessionContextMeasurement(sessionId: resolvedSession, model: model,
                    providerID: turn.admission?.provider, surface: surface, runId: runId, progress: progress,
                    turn: turn, work: work) { work in
                    try await executeTurn(turn: turn.with(\.peerSteering, taint), work: work)

                }
            }
        })
        } catch {
            if case .streamCancelled = error as? TurnEngineError { outcome = .failure(CancellationError()) }
            else { outcome = .failure(error) }
        }
        // The effect has ended. Capture the settlement's identity explicitly: settle does not inherit task locals, and Stop cannot cancel this work.
        var envelope = TurnEnvelope.current(turn: turn, surface: surface)
        envelope.answerExperienceID = heardID
        let settlementTurn = turn.with(\.envelope, envelope)
            .with(\.afterTurnOrigin, origin).with(\.notices, noticeSink)
        let closeSteering = turn.admissionToken == nil
        let replyRowID = turn.replyRow?.messageId(turn: turn.id, session: resolvedSession)
        let settled = await settle { [self, settlementTurn, work, origin, partialContext, steeringToken] in
            await TurnTraceContext.$bus.withValue(turnTraceBus) {
                await TurnTraceContext.$turnId.withValue(settlementTurn.id) {
                    let saved = await self.settleStructuredChatTurn(
                        outcome, observation: loopObservation, context: partialContext,
                        message: message, sessionId: resolvedSession, runId: runId, turnId: boundTurnId, replyRowID: replyRowID,
                        heardID: heardID, model: model, reasoningEffort: reasoningEffort, persona: persona,
                        surface: surface, suppressUserAppend: suppressUserAppend, chosenPaths: replyChoices.paths,
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

    /// Both protocols use canonical order so the always-on floor stays stable while remaining schemas retain incoming order.
    static func applyLazyToolFilter(
        to context: TurnContext,
        activeTools: Set<String>
    ) -> TurnContext {
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
        runId: String,
        turn: Turn
    ) async throws -> (request: CognitiveCapsuleRequest, projection: CognitionAtTurn)? {
        // Every verified owner turn stamps the time, whether or not cognition is wired.
        let fromUser = Self.isUsersTurn(surface: surface, sessionId: sessionId, dataRoot: dataRoot,turn: turn)
        if fromUser {
            UserTurnStamp.record(dataRoot: dataRoot, key: runId, door: surface)
        }
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
        var projectedContext = SwiftNativeTurnEngine.contextByAppendingRuntimeContext(
            context,
            runtimeContext: runtimeContext
        )
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
            sections.append(Self.cognitiveHeaderLine
                + """
                     Snapshot as of \(capsule.generatedAt.formatted(.iso8601)): selected inner cues; no external-state reads, full Doctor check or \
                    complete activity log.\n
                    """ + capsule.combined)
        }
        let combined = sections
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")
        return combined.isEmpty ? nil : combined
    }
}
