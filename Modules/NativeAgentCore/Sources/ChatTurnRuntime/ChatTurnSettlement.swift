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
// Blueprint: | `ChatTurnSettlement.swift` | One joined turn settlement preserves append-before-observe, produced output, terminal evidence and releases |

extension SwiftNativeChatOrchestrationClient {
    static func transcriptRef(_ session: String, _ messageID: String) -> Experience.Ref {
        .init(source: "chat/messages/\(session).jsonl", id: messageID)
    }

    static func face(_ words: String, _ attachments: [MultimodalAttachment]) -> Experience.Face {
        .init(words: TurnTraceRedactor.redactText(words), artifacts: attachments.compactMap { attachment in
            attachment.path.map { Experience.Ref(source: $0, id: attachment.id) } })
    }

    /// Create the answer once in reply order; recovery and redelivery preserve its birth. Settle heard records in their own order.
    static func recordAnswer(runID: String, heardID: String, evidence: Experience.Ref?, state: TurnEngineResult.TerminalState,
                             dataRoot: URL, words: String, attachments: [MultimodalAttachment],
                             conversation: (session: String, turn: String)? = nil, silence: String? = nil) async {
        let id = Experience.answer(run: runID)
        let answerEvidence = silence.map { Experience.Ref(source: "silence", id: $0) } ?? evidence
        let answerWrite = ExperienceStore.record(dataRoot, id) { store in
            guard try await store.experience(id) == nil else { return }
            var answer = Experience(id: id, kind: .answer, cause: [heardID], evidence: answerEvidence.map { [$0] } ?? [],
                face: silence == nil ? face(words, attachments) : nil,
                addressedTo: silence == nil ? conversation.map { ["conversation:" + $0.session] } ?? [] : [])
            if silence != nil {
                if let conversation { answer.evidence.append(.init(source: "conversation", id: conversation.session)) }
                answer.outcome = .init(domain: "turn", status: state.rawValue)
            }
            if silence == nil, let conversation,
               let checkpoint = try TurnCheckpoint.read(dataRoot: dataRoot, sessionId: conversation.session, turnId: conversation.turn) {
                if let owed = checkpoint.owedDelivery(status: state.rawValue) {
                    answer.addressedTo.append(owed.to)
                    answer.owes[owed.key] = .init(to: owed.to)
                } else if let surface = checkpoint.replyRoute["surface"]?.stringValue,
                          AgentBridgeCompletionRoute.Kind(surface: surface) == .local, answerEvidence != nil {
                    // The local destination already accepted the saved transcript row; other doors settle their own delivery.
                    var delivery = Experience.Obligation(to: "conversation:" + conversation.session)
                    delivery.phase = .accepted
                    delivery.evidence = answerEvidence
                    answer.owes["deliver:conversation"] = delivery
                }
            }
            try await store.begin(answer)
        }
        let heardWrite = ExperienceStore.record(dataRoot, heardID) { store in
            guard let heard = try await store.experience(heardID) else { return }
            if silence != nil {
                await answerWrite.value
                guard let answerEvidence, let answer = try await store.experience(id), answer.evidence.contains(answerEvidence) else {
                    throw ExperienceStore.LawError.unknown(id)
                }
            }
            var changes: [ExperienceStore.Change] = []
            if state == .waiting { changes.append(.progress("waiting")) }
            else if heard.outcome == nil {
                changes.append(.outcome(.init(domain: "turn", status: state.rawValue)))
            }
            // Already-settled answers retain their interrupted outcome.
            if heard.owes["answer"]?.phase.isSettled == false {
                if state == .completed {
                    changes.append(.obligation(key: "answer", phase: .accepted, evidence: answerEvidence ?? .init(source: "experience", id: id)))
                } else if state != .waiting {
                    changes.append(.letGo(key: "answer", reason: state == .stopped ? .cancelled : .failed))
                }
            }
            try await store.append(changes, to: heardID)
        }
        await answerWrite.value
        await heardWrite.value
    }

    func metacognitiveTerminalEvent(
        turnId: String,
        sessionId: String,
        surface: String,
        context: TurnContext?,
        result: TurnEngineResult,
        turn: Turn
    ) -> TurnTraceEvent {
        // Slot failures include neverRan refusals. Attempt counts use ToolLoopTraceObservation.
        let failed = result.toolDispatches.filter {
            let reply = ToolResult($0.result)
            return !ChatToolOutcome.outputLooksSuccessful(reply.payload, verdict: reply.outcome)
                && !ChatToolOutcome.isPersonArrivalHandBack($0.result)
                && reply.outcome != .cancelled
                && !ChatToolOutcome.isWaitingOnPerson(reply.payload, verdict: reply.outcome)
        }.count
        let expansions = result.toolDispatches.filter { $0.ranCall.tool == "context_expand" }.count
        let discovery = result.toolDispatches.filter {
            let reply = ToolResult($0.result)
            return $0.name == "app" && $0.input["find"] != nil && $0.input["action"] == nil
                && reply.outcome != .cancelled
        }
        let terminalReason = result.resolvedTerminalReason(dataRoot: dataRoot)
        var payload: [String: JSONValue] = [
            "schema": .string("metacognition.observed.v1"),
            "status": .string(terminalReason.state.rawValue),
            "terminalReason": .string(terminalReason.rawValue),
            // The recorded loop name remains stable across source moves.
            "loop": .string("streaming_tool_loop"),
            "modelUsed": .string(result.modelUsed),
            "turnElapsedMs": .int(Int64(max(0, result.elapsedMs))),
            "recalledMemoryCount": .int(Int64(result.recalledIds.count)),
            "toolDispatchCount": .int(Int64(result.toolDispatches.count)),
            "discoveryToolDispatchCount": .int(Int64(discovery.count)),
            "failedToolSlotCount": .int(Int64(failed)),
            "contextExpansionCount": .int(Int64(expansions)),
        ]
        payload.merge(ToolLoopTraceObservation.toolCounts(result.toolDispatches), uniquingKeysWith: { _, new in new })
        if let counters = result.loopCounters {
            payload.merge(counters.tracePayload, uniquingKeysWith: { _, new in new })
        }
        let observation = context.map(TurnEngineResult.TerminalObservation.init(context:))
        if let observation {
            payload["reasoningEffort"] = .string(observation.reasoningEffort)
            payload["toolSchemaCount"] = .int(Int64(observation.toolSchemaCount))
            payload["contextSource"] = .string(observation.contextSource)
            payload["contextSelectedAtomCount"] = .int(Int64(observation.contextSelectedAtomCount))
            payload["contextPacketCharacters"] = .int(Int64(observation.contextPacketCharacters))
            payload["contextExpandablePointerCount"] = .int(Int64(observation.contextExpandablePointerCount))
        }
        return TurnTraceEvent(
            turnId: turnId,
            kind: "turn.terminal",
            sessionId: sessionId,
            surface: surface,
            payload: .object(payload),
            turn: turn
        )
    }

    func turnFailedEvent(
        turnId: String, sessionId: String, surface: String, error: Error,
        observation: ToolLoopTraceObservation? = nil,
        turn: Turn
    ) -> TurnTraceEvent {
        let reason = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
        let terminalReason: TurnEngineResult.TerminalReason
        if [.authExpired, .codexCLISessionExpired, .routingUnavailable, .modelUnavailable].contains(ProviderFailure.classify(error)) {
            terminalReason = .providerRequired
        } else if case .streamInterrupted(let partial, _) = error as? TurnEngineError {
            terminalReason = partial.isEmpty ? .providerFailed : .providerInterrupted
        } else {
            terminalReason = .executionFailed
        }
        var payload = observation?.tracePayload ?? [:]
        payload["reason"] = .string(String(reason.prefix(200)))
        payload["status"] = .string(TurnEngineResult.TerminalState.failed.rawValue)
        payload["terminalReason"] = .string(terminalReason.rawValue)
        return TurnTraceEvent(
            turnId: turnId,
            kind: "turn.failed",
            sessionId: sessionId,
            surface: surface,
            payload: .object(payload),
            turn: turn
        )
    }

    func turnCancelledEvent(
        turnId: String, sessionId: String, surface: String, location: String,
        observation: ToolLoopTraceObservation? = nil,
        turn: Turn
    ) -> TurnTraceEvent {
        var payload = observation?.tracePayload ?? [:]
        payload["status"] = .string(TurnEngineResult.TerminalState.stopped.rawValue)
        payload["terminalReason"] = .string(TurnEngineResult.TerminalReason.cancelled.rawValue)
        payload["where"] = .string(location)
        return TurnTraceEvent(
            turnId: turnId, kind: "turn.cancelled", sessionId: sessionId,
            surface: surface, payload: .object(payload),
            turn: turn
        )
    }

    /// The accepted turn owns one settlement, after its effect has returned or thrown.
    func settleStructuredChatTurn(
        _ outcome: Result<ProducedChatTurn, any Error>, observation: ToolLoopTraceObservation, context: TurnContext?,
        message: String, sessionId resolvedSession: String, runId: String, turnId boundTurnId: String, replyRowID: String?,
        heardID: String, model: String, reasoningEffort: String, persona: String?, surface: String,
        suppressUserAppend: Bool, chosenPaths: [String], cancelFlagPath: URL?, outputMilestoneGate: TurnLifecycleFirstOutputGate,
        noticeSink: @escaping @Sendable (String, String) async -> Void,
        turn: Turn, work: ChatTurnWork
    ) async -> Result<StructuredChatExecution, any Error> {
        let stopReadFailure = ChatCancelFlag.readFailure(cancelFlagPath).map(TurnTraceRedactor.redactText)
        var terminal: TurnTraceEvent
        switch outcome {
        case .success(let produced):
            terminal = metacognitiveTerminalEvent(turnId: boundTurnId, sessionId: resolvedSession,
                surface: surface, context: produced.context, result: produced.result, turn: turn)
        case .failure(let error):
            terminal = error is CancellationError
                ? turnCancelledEvent(turnId: boundTurnId, sessionId: resolvedSession, surface: surface,
                                     location: "structured_chat", observation: observation, turn: turn)
                : turnFailedEvent(turnId: boundTurnId, sessionId: resolvedSession, surface: surface,
                                  error: error, observation: observation, turn: turn)
        }
        if let stopReadFailure {
            await noticeSink("stop_marker_unreadable", stopReadFailure)
        }
        var settled: Result<StructuredChatExecution, any Error>
        var promotionStarted = false
        do {
        let execution: StructuredChatExecution
        switch outcome {
        case .success(let produced):
        let result = produced.result
        let providerCtx = produced.context
        let reply = result.reply
        let transcriptRow = TurnSettle.transcriptRow(for: reply, turn: turn)
        let generatedAttachments = produced.attachments
        var response = ChatResponse(
            runId: runId,
            model: result.modelUsed,
            requestedModel: model.isEmpty ? nil : model,
            reasoningEffort: reasoningEffort.isEmpty ? nil : reasoningEffort,
            output: reply,
            sessionId: resolvedSession,
            personaFingerprint: produced.personaFingerprint,
            contextFingerprint: Self.contextFingerprint(recalledIds: result.recalledIds),
            attachments: generatedAttachments.isEmpty ? nil : generatedAttachments,
            providerCallCount: result.providerCallCount,
            terminalState: result.resolvedTerminalReason(dataRoot: dataRoot).state
        )
        let silence = response.isSilentCompletion ? boundTurnId : nil
        if let silence, case .object(var payload) = terminal.payload {
            response.output = ""
            payload["silence"] = .string(silence)
            terminal = TurnTraceEvent(turnId: terminal.turnId, ts: terminal.ts, kind: terminal.kind,
                sessionId: terminal.sessionId, surface: terminal.surface, destinationId: terminal.destinationId,
                threadId: terminal.threadId, payload: .object(payload), turn: nil)
        }
        // Keep the surface's existing reply identity so settlement updates the live row in place.
        let answerID = produced.answerID
        if silence == nil {
            try await appendMessage(
                sessionId: resolvedSession,
                role: "assistant",
                content: transcriptRow.text,
                runId: runId,
                attachments: generatedAttachments,
                persona: persona,
                source: ChatThreadKind.transcriptSource(surface: turn.arrivalSurface(authorizing: surface)),
                recalledMemoryIds: result.recalledIds,
                canonicalAssistantCompletion: true,
                outcomeResult: result,
                outcomeContext: providerCtx,
                outcomeTurnID: boundTurnId,
                mechanicalRow: transcriptRow.mechanicalRow,
                requestedResultIntent: TurnSettle.requestedResultIntent(
                    message: message, result: result,
                    sessionID: resolvedSession, runID: runId, surface: surface,
                    resumedRequest: suppressUserAppend && (
                        message.hasPrefix("[NativeAgent internal interaction continuation]") ||
                        message.hasPrefix("[NativeAgent internal approval continuation]")
                    ),
                    turn: turn),
                messageId: answerID,
                turn: turn)
        }
        // Spoken answers refer to their saved row; chosen silence refers to the turn, with nothing addressed or owed to a door.
        let answerRef = Self.transcriptRef(resolvedSession, answerID)
        let answerState = result.resolvedTerminalReason(dataRoot: dataRoot).state
        await Self.recordAnswer(runID: runId, heardID: heardID, evidence: answerRef, state: answerState,
            dataRoot: dataRoot, words: transcriptRow.text, attachments: generatedAttachments,
            conversation: (resolvedSession, boundTurnId), silence: silence)
        if let silence {
            guard try Self.silentTurn(dataRoot: dataRoot, sessionId: resolvedSession, runId: runId,
                                     turnId: boundTurnId) == silence else {
                throw ChatOrchestrationError.underlying("The turn's chosen silence could not be saved; repair its experience record.")
            }
            await RepairOwed.settle(dataRoot, operation: "session.delivery:" + resolvedSession + ":" + runId,
                                   evidence: .init(source: "silence", id: silence)).value
        }
        if silence == nil, !reply.isEmpty, await outputMilestoneGate.claim() {
            TurnLifecycleTelemetry.emit(
                .surfaceOutputEnqueued,
                surface: surface,
                sessionId: resolvedSession,
                observedBy: "structured_stream.return",
                turnId: boundTurnId,
                on: turnTraceBus,
                turn: turn
            )
        }
        // Settlement awaits owed recording, then releases interpretation and private work.
        await result.afterReply?.start()
        promotionStarted = result.afterReply?.recordsMemory == true
        response.workingCommentaryCharacters = result.workingCommentaryCharacters
        let runtimeExecution = turn.execution
        if response.terminalState != .completed {
            response.runtimeStatus = runtimeExecution?.waitingForApproval == true ? "waiting for approval"
                : runtimeExecution?.waitingForInteraction == true ? "waiting on you" : response.terminalState?.rawValue
        }
        response.statusDetail = runtimeExecution?.waitingForApproval == true ? "Answer the approval card in this conversation."
            : runtimeExecution?.waitingForInteraction == true
                ? (runtimeExecution?.waitingInteraction?.title).map { "\($0) — answer it in the conversation." }
                    ?? "Waiting on your answer in the conversation."
            : turn.tokenBudget?.exhausted == true ? "Stopped at the per-run token limit." : nil
        response.statusDetail = runtimeExecution?.statusDetail(response.statusDetail)
        if let stopReadFailure { response.statusDetail = stopReadFailure }
        response.pendingApprovalID = runtimeExecution?.pendingApprovalID
        if result.terminalReason == .replyCompleted,
           let journal = work.journal,
           await journal.snapshot().runID == runId {
            do {
                try await journal.completeResponse(JSONValue.fromEncodable(response), reply: response.output,
                    peerSources: turn.peerSteering?.checkpointSources ?? [])
            } catch {
                nativeLog("Saved reply; its work journal could not settle: %@", String(describing: error))
                await noticeSink("turn_settlement_failed", "Saved the reply, but couldn't update its work record.")
            }
        }
        // The saved row's own text, so the phone's transcript snapshot settles the live bubble instead of adding a second copy.
        ChatLiveTap.emit(sessionId: resolvedSession, surface: surface, runId: runId,
                         response.runtimeStatus.map { .incomplete(transcriptRow.text, status: $0) }
                             ?? .answered(silence == nil ? transcriptRow.text : ""))
        execution = StructuredChatExecution(response: response, turn: .success(result))
        case .failure(let error):
            let cancelled = error is CancellationError
            let partial = ToolCallParser.visiblePrefix(in: ToolCallParser.stripToolUseMarkers(observation.partialReply))
            let attachments = ChatGeneratedImageArtifacts.attachments(
                from: observation.toolDispatches, chosen: chosenPaths, dataRoot: dataRoot)
            let saved = try await persistPartialIfNeeded(
                sessionId: resolvedSession, runId: runId, text: partial, attachments: attachments,
                cancelled: cancelled, failure: error, source: ChatThreadKind.transcriptSource(surface: turn.arrivalSurface(authorizing: surface)),
                outcomeContext: context,
                // Save partial output under the live bubble's original identity.
                replyRowID: replyRowID, onNotice: noticeSink, turn: turn)
            if saved == nil, !cancelled, Self.shouldPersistFailureMessage(surface: surface) {
                try await appendFailureMessageIfNeeded(sessionId: resolvedSession, runId: runId,
                    failure: error, persona: persona, surface: surface,
                    outcomeContext: context, outcomeTurnID: boundTurnId, turn: turn)
            }
            var response = ChatResponse(runId: runId, model: model, reasoningEffort: reasoningEffort,
                output: saved ?? "", sessionId: resolvedSession, attachments: saved == nil ? nil : attachments)
            response.terminalState = cancelled ? .stopped : .failed
            response.runtimeStatus = response.terminalState?.rawValue
            response.statusDetail = turn.tokenBudget?.exhausted == true ? "Stopped at the per-run token limit."
                : cancelled ? (saved == nil ? "Stopped." : "Stopped. What was produced has been saved.") : String(describing: error)
            response.statusDetail = turn.execution?.statusDetail(response.statusDetail)
            if let stopReadFailure { response.statusDetail = stopReadFailure }
            ChatLiveTap.emit(sessionId: resolvedSession, surface: surface, runId: runId,
                cancelled ? .cancelled : .failed(ProviderFailure.report(error)?.personDescription ?? "The reply could not be completed."),
                savedPartial: saved)
            execution = StructuredChatExecution(response: response, turn: .failure(error))
        }
        settled = .success(execution)
        } catch {
            // A failed save is still a settled fact. Keep Stop's terminal; a completed effect whose reply could not be saved ends failed.
            if terminal.kind != "turn.cancelled" {
                terminal = turnFailedEvent(turnId: boundTurnId, sessionId: resolvedSession, surface: surface,
                    error: error, observation: observation, turn: turn)
            }
            nativeLog("Turn reply settlement failed: %@", String(describing: error))
            await noticeSink("turn_settlement_failed", "Couldn't finish saving this turn.")
            settled = .failure(error)
        }
        if terminal.kind != "turn.terminal" {
            let letGo: ObligationPhase.LetGo = terminal.kind == "turn.cancelled" ? .cancelled : .failed
            await ExperienceStore.record(dataRoot, heardID) { store in
                guard let heard = try await store.experience(heardID) else { return }
                var changes: [ExperienceStore.Change] = [.letGo(key: "answer", reason: letGo)]
                if heard.outcome == nil { changes.append(.outcome(.init(domain: "turn", status: letGo.rawValue))) }
                try await store.append(changes, to: heardID)
            }.value
        }
        if let stopReadFailure, case .object(var payload) = terminal.payload {
            payload["stopMarkerError"] = .string(stopReadFailure)
            terminal = TurnTraceEvent(turnId: terminal.turnId, ts: terminal.ts, kind: terminal.kind,
                sessionId: terminal.sessionId, surface: terminal.surface, destinationId: terminal.destinationId,
                threadId: terminal.threadId, payload: .object(payload), turn: nil)
        }
        do {
            try await settleTurnCheckpoint(terminal, sessionId: resolvedSession, runId: runId)
        } catch {
            nativeLog("Turn terminal could not be saved; checkpoint retained: %@", String(describing: error))
            await noticeSink("turn_settlement_failed", "Couldn't save this turn's final record.")
            settled = .failure(error)
        }
        if case .success(let execution) = settled, case .success(let produced) = outcome,
           produced.result.cognitiveContextDelivered, execution.response.terminalState == .completed,
           !execution.response.isSilentCompletion {
            await commitRepliedCognitiveTurnProjection(produced.cognitiveProjection)
        }
        // The accepted message owns its incoming appraisal even without a saved answer; a reply that captured a promotion already owns that appraisal.
        if !promotionStarted {
            // A turn that failed, stopped or could not save its reply has no reply that reached anyone.
            var replied = false
            if case .success = outcome, case .success = settled { replied = true }
            let afterReply = await engine.deferMemoryPromotion(userMessage: message, assistantMessage: observation.partialReply,
                toolDispatches: observation.toolDispatches, sessionId: resolvedSession, surface: surface, replied: replied, turn: turn,work: work)
            await afterReply.start()
        }
        return settled
    }

    // Trace the exact post-filter tools array sent by this turn; schema bytes exclude HTTP framing and tokens.
    static func traceFinalToolContract(
        turnId: String,
        wire: [LLMToolSchema],
        surface: String?,
        turn: Turn, work: ChatTurnWork
    ) {
        let ordering = SwiftToolDispatcher.canonicalToolOrder(wire.map(\.name))
        // Material bytes use the context.snapshot convention, without schema content.
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
        // Published for this turn so every `llm.call` row carries the same totals beside the provider's real input/cache token counts.
        work.prefixTelemetry?.set(weight)
        // Pass the turn ID explicitly because this fires before its task-local binding exists.
        var payload: [String: JSONValue] = [
                "tools.finalWireCount": .int(Int64(wire.count)),
                "tools.finalFloorCount": .int(Int64(ordering.floor.count)),
                "tools.finalAppendedCount": .int(Int64(ordering.appended.count)),
                "tools.finalFingerprintSHA256":
                    .string(SwiftNativeTurnEngine.toolSchemaFingerprint(wire)),
                "tools.finalNameOrderSHA256": .string(ordering.fingerprintSHA256),
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
            sessionId: turn.session,
            surface: surface,
            payload: .object(payload),
            turn: turn
        ))
    }
}
