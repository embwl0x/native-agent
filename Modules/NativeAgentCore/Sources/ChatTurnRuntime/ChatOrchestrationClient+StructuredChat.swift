import AuthoredCapabilities
import Foundation
import Senses
import AgentWorkspace
import CryptoKit
import NativeAgentCore
import PersistenceCore
import TurnTrace
import Transcripts
import Desk
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
// Blueprint: | `ChatOrchestrationClient+StructuredChat.swift` | Accepted turn ingress and execution with captured run identity, carried offers and prepared cognitive context; effect completion joins canonical turn settlement |

extension SwiftNativeChatOrchestrationClient {

    /// The one structured chat turn. Streaming surfaces consume `progress` live; chat() callers await the returned execution.
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
        noticeSink: @escaping @Sendable (String, String) async -> Void
    ) async throws -> StructuredChatExecution {
        let persona = PersonaSelection.current() ?? persona
        let fileAccess = FileAccessGatedDispatcher.sharedFileAccess(fileAccess)
        // Trusted turns retain the working context captured at arrival.
        let takeover = PeerDataTaint.abilityWriteCheck() == nil
            ? ChatToolSessionContext.envelope?.macContinuation ?? MacWorkContinuation.current : nil
        return try await MacWorkContinuation.$current.withValue(takeover) {
        try await SenseTurnReads.$current.withValue(SenseTurnReads()) {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty && attachments.isEmpty {
            throw ChatOrchestrationError.emptyMessage
        }

        let resolvedSession = try Self.resolveSessionId(sessionId)
        // Transport and enqueue pins keep the canonical transcript identity stable before work starts, whether or not the user row already exists.
        let runId = ChatPersistenceContext.pinnedTurnRunID ?? UUID().uuidString
        ChatTurnExecution.current?.bindHistoryRunID(runId)
        var partialContext: TurnContext?
        var origin: AfterTurnOrigin?
        var steeringToken: UUID?
        let boundTurnId = TurnTraceContext.turnId ?? TurnTraceContext.mintTurnId()
        let heardID = suppressUserAppend ? ChatToolSessionContext.envelope?.answerExperienceID ?? boundTurnId : boundTurnId
        let cancelFlagPath = ChatCancelFlag.accept(
            dataRoot: dataRoot, sessionId: resolvedSession, runId: runId, turnId: boundTurnId)
        let outputMilestoneGate = TurnLifecycleFirstOutputGate()
        let loopObservation = ToolLoopTraceObservation()
        let replyChoices = ReplyChoices()
        let outcome: Result<ProducedChatTurn, any Error>
        do {
        let admittedAt = clock()
        await ChatTurnSteering.shared.noteTurnActivity(for: dataRoot, at: admittedAt)
        let carried: [MyQueue.Entry]
        var queueUnavailable = false
        if ChatTurnExecution.transcriptRowKind == nil {
            let projection = await (cognitiveRuntime as? any MyQueueTurnProjectionProviding)?.queueTurnCandidates()
            let candidates = projection?.candidates
            queueUnavailable = candidates == nil && projection?.refreshPendingAfterWrite == true
            carried = candidates.map { MyQueueReady.forTurn(items: $0, session: resolvedSession, door: surface,
                personTurn: ChatPersistenceContext.originPrincipal == "person", at: admittedAt, dataRoot: dataRoot)
                .filter { ChatToolSessionContext.envelope?.workIdentity != "carry." + $0.item.handle } } ?? []
        } else { carried = [] }
        // Queue-item steering applies only when that item's decision resumes its work.
        let taint = PeerDataTaint.current
        func executeCarriedTurn() async throws -> ProducedChatTurn {
        // Trust gates image blocks; extracted PDF text enters modelMessage while the persisted user row keeps message.
        let attachmentInput = try Self.turnAttachmentInput(
            message: message, attachments: attachments, dataRoot: dataRoot,
            queryUserMessage: TurnRelevanceContext.queryUserMessage, runId: runId)
        let imageBlocks = attachmentInput.imageBlocks
        var modelMessage = attachmentInput.userMessage
        if queueUnavailable { modelMessage += "\n\n[MY QUEUE is unavailable; no queued step was admitted with this message.]" }
        if !carried.isEmpty {
            let items = carried.map { entry in
                var arrival = ResidentWake.carriedArrival(entry.item, crossing: admittedAt)
                arrival.reason = "what you carry"
                return arrival
            }
            modelMessage += "\n\n" + ResidentWake.text(items, live: true)
        }
        if ChatTurnExecution.transcriptRowKind == nil,
           let contract = StandingBotContinuity.currentContract {
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
                source: surface,
                // The bot brief this run was started with is the bot's own machinery, stamped by the caller, never guessed from the surface, which a person steering in also arrives on.
                mechanicalRow: ChatTurnExecution.transcriptRowKind,
                // The row the screen already shows is the row saved (one id, no remount at turn end).
                messageId: ChatPersistenceContext.pinnedUserMessageID ?? UUID().uuidString
            )
        } else {
            origin = try await consumeEnqueuedMessage(sessionId: resolvedSession, runId: runId)
        }
        // Her turn hears the message and owes its conversation an answer.
        let heard = Experience(id: heardID, kind: .heard,
            evidence: origin.map { [Self.transcriptRef(resolvedSession, $0.messageId)] } ?? [],
            addressedTo: ["her"], owes: ["answer": .init(to: "conversation:" + resolvedSession)])
        let correlation = ChatToolSessionContext.replyRoute?.correlationId
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
                // Persist the incoming row before delivery; failed persistence requeues its offer.
                let steeringOrigin = try await self.enqueueSteeringMessage(
                    message: text, sessionId: sid, surface: offer.envelope.surface, runId: enqueueRunID)
                // A consumed offer never runs its own structured turn. Appraise its durable incoming row without borrowing the working turn's reply.
                await AfterTurnSource.$origin.withValue(steeringOrigin) {
                    await TurnTraceContext.$bus.withValue(self.turnTraceBus) {
                        await TurnTraceContext.$turnId.withValue(enqueueRunID) {
                            let afterReply = await self.engine.deferMemoryPromotion(
                                userMessage: text, assistantMessage: "", toolDispatches: [],
                                sessionId: sid, surface: offer.envelope.surface)
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
                    userText: "Couldn't save your message to the transcript, so it wasn't handed to the turn in progress - it's back in the queue to send next.",
                    onNotice: noticeSink
                )
                return false
            }
            }
            }
        }
        steeringToken = await ChatTurnSteering.shared.openTurn(
            sessionId: resolvedSession, turnId: TurnTraceContext.turnId ?? runId, dataRoot: dataRoot,
            door: ChatToolSessionContext.replyRoute ?? TurnEnvelope.current(surface: surface).deliveryRoute, persist: steeringPersister)
        // A turn whose history was compacted cannot also advance the window cursor.
        var compactionRanThisTurn = false
        var transcript: Data?
        do {
            (compactionRanThisTurn, transcript) = try await prepareSessionHistoryForTurn(
                sessionId: resolvedSession,
                model: model,
                surface: surface,
                runId: runId,
                progress: progress
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            // A compaction that did not finish is this message's input: she answers from the history that is there and holds the lever.
            modelMessage += "\n\n[This conversation's compaction did not finish: \(error.localizedDescription)"
                + ((error as? ToolFailureError)?.nextCall.map { " Repair: \($0)" } ?? "") + "]"
        }

        let gated = makeTracedGatedDispatcher(
            fileAccess: fileAccess, verifiedSessionId: resolvedSession
        )
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
        // Acceptance owns its checkpoint before any context is built: a relaunch from here on finds this turn and answers it. A checkpoint that could not be written is this turn's fact, never its end: she answers knowing a relaunch before
        // she finishes will not find it.
        if TurnCheckpointScope.resuming == nil, let root = engine.remPinsDataRoot {
            let saved = try SwiftNativeTurnEngine.continuation(dataRoot: root, runId: runId, sessionId: resolvedSession, surface: surface,
                userMessage: message, fileAccess: fileAccess, capabilityProfile: continuationCapabilityProfile)
            if let saved, let unwritten = TurnCheckpointWriter.persist(
                SwiftNativeTurnEngine.checkpoint(saved, turnId: boundTurnId, sessionId: resolvedSession), dataRoot: root) {
                modelMessage += "\n\n[" + unwritten + "]"
            }
        }
        async let cognitiveProjectionTask = prepareCognitiveTurnProjection(
            surface: surface,
            userMessage: message,
            sessionId: resolvedSession,
            runId: runId
        )

        // Prebuilt context threads history into the engine; context-build failures are persisted and rethrown. Mint and bind one turn id across context building and execution so both retain their trace events.
        let threadedCtx = try await HistoryWindowTurnFacts
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
                    // First-turn handoff from the same participant, through the existing transcript and admitted provider route.
                    sessionDigest: SessionDigestProvider(dataRoot: history.dataRoot, llm: llm),
                    imageBlocks: imageBlocks,
                    queryUserMessage: attachmentInput.queryUserMessage,
                    transcript: transcript
                )
            }
            }
            }
        let cognitiveProjection = await cognitiveProjectionTask
        let threadedCtxWithCognition = await Self.contextByAppendingCognitiveCapsule(
            to: threadedCtx,
            projection: cognitiveProjection?.projection
        )
        // `app` is her one tool (docs/TOOL_LOADING.md): the turn offers it alone.
        let providerCtx = Self.applyLazyToolFilter(to: threadedCtxWithCognition, activeTools: [])
        partialContext = providerCtx
        Self.traceFinalToolContract(
            turnId: boundTurnId,
            wire: providerCtx.toolSchemas,
            surface: surface
        )

        let receiptWriter = ToolReceiptWriter(
            client: self, sessionId: resolvedSession, runId: runId, surface: surface,
            laneLabel: "", onNotice: noticeSink
        )
        let effectiveProgress: TurnEventSink = { event in
            let redactedEvent = Self.redactedProgressEvent(event)
            if case .toolResult = event, let receipt = ToolReceipt.dispatched {
                await receiptWriter.write(receipt)
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
                event: redactedEvent
            )
            if case .delta(let text) = redactedEvent {
                ChatLiveTap.emit(sessionId: resolvedSession, surface: surface, runId: runId, .delta(text))
            }
            await progress?(redactedEvent)
        }

        let result: TurnEngineResult
            // Bind one turn ID through context building, engine execution and every emitted trace event.
        result = try await AfterTurnSource.$origin.withValue(origin) {
            return try await ReplyChoices.$current.withValue(replyChoices) {
            try await ToolLoopTraceObservation.$current.withValue(loopObservation) {
            try await TurnTraceContext.$bus.withValue(turnTraceBus) {
            try await TurnTraceContext.$turnId.withValue(boundTurnId) {
            try await LLMCallContext.$turnActiveTools.withValue(Set(providerCtx.toolSchemas.map(\.name))) {
            try await ChatToolSessionContext.$settingRequestEvidence.withValue({ [self] setting, value, currentValue, quote in
                func normalized(_ text: String) -> String {
                    text.lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ")
                }
                // The quote may arrive wrapped ("User asked: “…”"): match the quoted part too, ignoring the quote marks themselves.
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
            }) {
                return try await engine.executeTurnWithStreamingToolLoop(
                        surface: surface,
                        userMessage: message,
                        sessionId: resolvedSession,
                        runId: runId,
                        llm: llm,
                        tools: gated,
                        preBuiltContext: providerCtx,
                        progress: effectiveProgress,
                        onDelivery: { await self.commitDeliveredCognitiveTurnProjection(cognitiveProjection, turnId: boundTurnId) },
                        cancelFlagPath: cancelFlagPath,
                        fileAccess: fileAccess,
                        capabilityProfile: continuationCapabilityProfile
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
            answerID: TurnTraceContext.replyRow.flatMap {
                $0.turnId == boundTurnId ? $0.messageId : nil
            } ?? UUID().uuidString)
        }
        var envelope = TurnEnvelope.current(surface: surface)
        envelope.answerExperienceID = heardID
        outcome = .success(try await ChatPersistenceContext.$pinnedTurnRunID.withValue(nil) {
            try await ChatToolSessionContext.$envelope.withValue(envelope) {
                try await PeerDataTaint.$current.withValue(taint, operation: executeCarriedTurn)
            }
        })
        } catch {
            if case .streamCancelled = error as? TurnEngineError { outcome = .failure(CancellationError()) }
            else { outcome = .failure(error) }
        }
        // The effect has ended. Capture the settlement's identity explicitly: settle does not inherit task locals, and Stop cannot cancel this work.
        var envelope = TurnEnvelope.current(surface: surface)
        envelope.answerExperienceID = heardID
        let execution = ChatTurnExecution.current
        let partID = SkillRunContext.partID
        let taint = PeerDataTaint.current
        var settlement = TurnRequest(message: message, sessionID: resolvedSession, surface: surface,
            envelope: .some(envelope), origin: .some(ChatPersistenceContext.originProvenance),
            codexCompletion: .some(ChatPersistenceContext.codexCompletionBinding),
            replacementAssistantMessageID: .some(ChatPersistenceContext.replacementAssistantMessageID),
            queryUserMessage: .some(TurnRelevanceContext.queryUserMessage))
        settlement.replyRoute = .some(ChatToolSessionContext.replyRoute)
        let journal = DeskContinuationScope.current
        let budget = LLMCallContext.turnTokenBudget
        let standingBot = StandingBotContinuity.currentBot
        let senseReads = SenseTurnReads.current
        let conditionVerdict = BotRunner.conditionVerdict
        let admittedModel = LLMCallContext.admittedModel
        let providerId = LLMCallContext.providerId
        let closeSteering = TurnAdmission.token == nil
        let save: @Sendable () async -> Result<StructuredChatExecution, any Error> = { [self, partialContext, steeringToken] in
            let settled = await self.settleStructuredChatTurn(
                outcome, observation: loopObservation, context: partialContext,
                message: message, sessionId: resolvedSession, runId: runId, turnId: boundTurnId,
                heardID: heardID, model: model, reasoningEffort: reasoningEffort, persona: persona,
                surface: surface, suppressUserAppend: suppressUserAppend,
                chosenPaths: replyChoices.paths,
                outputMilestoneGate: outputMilestoneGate, noticeSink: noticeSink)
            ChatCancelFlag.finish(cancelFlagPath)
            if closeSteering {
                await ChatTurnSteering.shared.closeTurn(sessionId: resolvedSession, token: steeringToken)
            }
            return settled
        }
        let withContext: @Sendable () async -> Result<StructuredChatExecution, any Error> = { [self, settlement] in
            await SkillRunContext.$partID.withValue(partID) {
            await TurnTraceContext.$bus.withValue(turnTraceBus) {
            await TurnTraceContext.$turnId.withValue(boundTurnId) {
            await ChatTurnExecution.$current.withValue(execution) {
            await PeerDataTaint.$current.withValue(taint) {
            await DeskContinuationScope.$current.withValue(journal) {
            await LLMCallContext.$admittedModel.withValue(admittedModel) {
            await LLMCallContext.$providerId.withValue(providerId) {
                await settlement.bindContext(save)
            }
            }
            }
            }
            }
            }
            }
            }
        }
        let settled = await settle { [origin] in
            await LLMCallContext.$turnTokenBudget.withValue(budget) {
            await AfterTurnSource.$origin.withValue(origin) {
            await StandingBotContinuity.$currentBot.withValue(standingBot) {
            await SenseTurnReads.$current.withValue(senseReads) {
            await BotRunner.$conditionVerdict.withValue(conditionVerdict) {
            await ToolNoticeBus.$emit.withValue(noticeSink, operation: withContext)
            }
            }
            }
            }
            }
        }
        return try settled.get()
        }
        }
    }

    /// Filter to normalModelToolNames (app alone for chat). Both protocols use canonicalToolOrder: always-on schemas by name, then remaining schemas in incoming order.
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
        runId: String
    ) async -> (request: CognitiveCapsuleRequest, projection: CognitionAtTurn)? {
        // Every verified owner turn stamps the time, whether or not cognition is wired.
        let fromUser = Self.isUsersTurn(surface: surface, sessionId: sessionId, dataRoot: dataRoot)
        if fromUser {
            UserTurnStamp.record(dataRoot: dataRoot, key: runId)
        }
        guard let cognitiveRuntime else { return nil }
        let request = CognitiveCapsuleRequest(
            surface: surface,
            userMessage: userMessage,
            sessionId: sessionId,
            mode: .inject,
            // The model window sizes the request; the substrate applies its own ceiling.
            maximumCharacters: ContextBudgetPolicy.resolve(
                model: LLMCallContext.admittedModel,
                providerID: LLMCallContext.providerId,
                dataRoot: dataRoot
            ).capsuleChars,
            turnKind: Self.cognitiveMessageTurnKind(),
            fromUser: fromUser,
            previousUserTurnAt: fromUser ? UserTurnStamp.previous(dataRoot: dataRoot) : nil,
            speaker: fromUser ? CognitiveCare.ownerKey : Self.cognitivePeerSpeaker(sessionId: sessionId, dataRoot: dataRoot)
        )
        return (request, await cognitiveRuntime.prepareTurnProjection(request))
    }

    /// A peer's person key, read from the session and origin the way the after-turn cares read a peer's words; nil when the turn names no peer.
    static func cognitivePeerSpeaker(sessionId: String, dataRoot: URL) -> String? {
        var metadata: [String: JSONValue] = ["sessionId": .string(sessionId)]
        if let origin = ChatPersistenceContext.originProvenance {
            var object: [String: JSONValue] = [:]
            if let agent = origin.agent { object["agent"] = .string(agent) }
            if let authored = origin.authored { object["authored"] = .string(authored.rawValue) }
            metadata["origin"] = .object(object)
        }
        return CognitiveSubstrate.peerIdentity(metadata: metadata, dataRoot: dataRoot).map(CognitiveCareProvenance.personKey)
    }

    /// Only verified owner turns advance his gap: local Mac, signed phone commands, or Telegram's sole allowlisted owner. Wakes, peers, bridges and other senders do not.
    static func isUsersTurn(surface: String, sessionId: String, dataRoot: URL) -> Bool {
        let envelope = ChatToolSessionContext.envelope
        guard ChatPersistenceContext.originProvenance == nil,
              (envelope?.agent ?? "").isEmpty,
              SessionConversation.kind(sessionId, dataRoot: dataRoot)?.isHisConversation == true else { return false }
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
        // Projection bookkeeping commits only after the provider accepts this material.
        return projectedContext
    }

    /// The loop's confirmed-delivery boundary commits the prepared presentation once.
    func commitDeliveredCognitiveTurnProjection(
        _ prepared: (request: CognitiveCapsuleRequest, projection: CognitionAtTurn)?,
        turnId: String
    ) async {
        guard let prepared, let cognitiveRuntime else { return }
        let (request, projection) = prepared
        // Why this turn's felt cue (or none) — trace only.
        if let why = projection.why {
            TurnTraceBus.fire(TurnTraceEvent(
                turnId: turnId, kind: "mind.why", sessionId: request.sessionId,
                surface: request.surface, payload: why
            ), on: turnTraceBus)
        }
        await cognitiveRuntime.commitTurnProjection(
            projection,
            request: request
        )
    }

    static let cognitiveHeaderLine = "[CognitiveSubstrate] private — it colors you; never quote it."

    static func cognitiveRuntimeContext(
        capsule: CognitiveCapsule?,
        posture: OrganismBehaviorPosture?
    ) -> String? {
        var sections: [String] = []
        // The ops line rides FIRST and on its own, so it never reads as part of her private inner state; it is empty on a default posture.
        if let posture {
            sections.append(posture.privateRuntimeContext())
        }
        if let capsule,
           !capsule.combined.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            // The header marks these cues as private inner state.
            sections.append(Self.cognitiveHeaderLine
                + " Snapshot as of \(capsule.generatedAt.formatted(.iso8601)): selected inner cues; no external-state reads, full Doctor check or complete activity log.\n" + capsule.combined)
        }
        let combined = sections
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")
        return combined.isEmpty ? nil : combined
    }
}
