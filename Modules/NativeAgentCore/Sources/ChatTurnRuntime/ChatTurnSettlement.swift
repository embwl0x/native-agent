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

    /// The answer is born once, built off the reply path in its own order; a later writer (recovery, a resend) finds it born and leaves it. Its heard settles in the heard's order.
    static func recordAnswer(runID: String, heardID: String, evidence: Experience.Ref?, state: TurnEngineResult.TerminalState,
                             dataRoot: URL, words: String, attachments: [MultimodalAttachment],
                             conversation: (session: String, turn: String)? = nil) async {
        let id = Experience.answer(run: runID)
        let answerWrite = ExperienceStore.record(dataRoot, id) { store in
            guard try await store.experience(id) == nil else { return }
            var answer = Experience(id: id, kind: .answer, cause: [heardID], evidence: evidence.map { [$0] } ?? [],
                face: face(words, attachments), addressedTo: conversation.map { ["conversation:" + $0.session] } ?? [])
            if let conversation,
               let checkpoint = try? TurnCheckpoint.read(dataRoot: dataRoot, sessionId: conversation.session, turnId: conversation.turn),
               let owed = checkpoint.owedDelivery(status: state.rawValue) {
                answer.addressedTo.append(owed.to)
                answer.owes[owed.key] = .init(to: owed.to)
            }
            try await store.begin(answer)
        }
        let heardWrite = ExperienceStore.record(dataRoot, heardID) { store in
            guard let heard = try await store.experience(heardID) else { return }
            var changes: [ExperienceStore.Change] = []
            if state == .waiting { changes.append(.progress("waiting")) }
            else if heard.outcome == nil {
                changes.append(.outcome(.init(domain: "turn", status: state.rawValue)))
            }
            // An answer already settled (let go when the turn was interrupted) stays as it was.
            if heard.owes["answer"]?.phase.isSettled == false {
                if state == .completed {
                    changes.append(.obligation(key: "answer", phase: .accepted, evidence: evidence ?? .init(source: "experience", id: id)))
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
        result: TurnEngineResult
    ) -> TurnTraceEvent {
        // Legacy failed-slot count includes neverRan refusals. Attempt counts and subsequent-round behavior use ToolLoopTraceObservation instead.
        let failed = result.toolDispatches.filter {
            !ChatToolOutcome.outputLooksSuccessful($0.result)
                && !ChatToolOutcome.wasCancelled($0.result)
                && !ChatToolOutcome.isWaitingOnPerson($0.result)
        }.count
        let expansions = result.toolDispatches.filter { $0.ranCall.tool == "context_expand" }.count
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
            // The recorded loop name remains stable across source moves.
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
            payload: .object(payload)
        )
    }

    // Record a terminal trace event when a structured turn fails.
    func turnFailedEvent(
        turnId: String, sessionId: String, surface: String, error: Error,
        observation: ToolLoopTraceObservation? = nil
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
            payload: .object(payload)
        )
    }

    func turnCancelledEvent(
        turnId: String, sessionId: String, surface: String, location: String,
        observation: ToolLoopTraceObservation? = nil
    ) -> TurnTraceEvent {
        var payload = observation?.tracePayload ?? [:]
        payload["status"] = .string(TurnEngineResult.TerminalState.stopped.rawValue)
        payload["terminalReason"] = .string(TurnEngineResult.TerminalReason.cancelled.rawValue)
        payload["where"] = .string(location)
        return TurnTraceEvent(
            turnId: turnId, kind: "turn.cancelled", sessionId: sessionId,
            surface: surface, payload: .object(payload)
        )
    }

    /// The accepted turn owns one settlement, after its effect has returned or thrown.
    func settleStructuredChatTurn(
        _ outcome: Result<ProducedChatTurn, any Error>, observation: ToolLoopTraceObservation, context: TurnContext?,
        message: String, sessionId resolvedSession: String, runId: String, turnId boundTurnId: String,
        heardID: String, model: String, reasoningEffort: String, persona: String?, surface: String,
        suppressUserAppend: Bool, chosenPaths: [String], outputMilestoneGate: TurnLifecycleFirstOutputGate,
        noticeSink: @escaping @Sendable (String, String) async -> Void
    ) async -> Result<StructuredChatExecution, any Error> {
        var terminal: TurnTraceEvent
        switch outcome {
        case .success(let produced):
            terminal = metacognitiveTerminalEvent(turnId: boundTurnId, sessionId: resolvedSession,
                surface: surface, context: produced.context, result: produced.result)
        case .failure(let error):
            terminal = error is CancellationError
                ? turnCancelledEvent(turnId: boundTurnId, sessionId: resolvedSession, surface: surface,
                                     location: "structured_chat", observation: observation)
                : turnFailedEvent(turnId: boundTurnId, sessionId: resolvedSession, surface: surface,
                                  error: error, observation: observation)
        }
        var settled: Result<StructuredChatExecution, any Error>
        var promotionStarted = false
        do {
        let execution: StructuredChatExecution
        switch outcome {
        case .success(let produced):
        let result = produced.result
        let providerCtx = produced.context
        let reply = BotRunner.conditionReply(result.reply, sessionID: resolvedSession)
        let transcriptRow = TurnSettle.transcriptRow(for: reply)
        let generatedAttachments = produced.attachments
        // The row the surface drew this reply in, when it drew one for this turn: the answer lands in place instead of replacing it.
        let answerID = produced.answerID
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
                message: message, result: result,
                sessionID: resolvedSession, runID: runId, surface: surface,
                resumedRequest: suppressUserAppend && (
                    message.hasPrefix("[NativeAgent internal interaction continuation]") ||
                    message.hasPrefix("[NativeAgent internal approval continuation]")
                )
            ),
            messageId: answerID
        )
        // The answer is its conversation's once the transcript holds it, and owes the door the turn came from until that door accepts it: the delivery its checkpoint keeps. Its face is that row's words, redacted as the transcript's
        // evidence is, and the artifacts she chose; built off the reply path.
        let answerRef = Self.transcriptRef(resolvedSession, answerID)
        let answerState = result.resolvedTerminalReason(dataRoot: dataRoot).state
        await Self.recordAnswer(runID: runId, heardID: heardID, evidence: answerRef, state: answerState,
            dataRoot: dataRoot, words: transcriptRow.text, attachments: generatedAttachments,
            conversation: (resolvedSession, boundTurnId))
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
        // Settlement awaits owed recording, then releases interpretation and private work.
        await result.afterReply?.start()
        promotionStarted = result.afterReply?.recordsMemory == true
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
        response.workingCommentaryCharacters = result.workingCommentaryCharacters
        let runtimeExecution = ChatTurnExecution.current
        if response.terminalState != .completed {
            response.runtimeStatus = runtimeExecution?.waitingForApproval == true ? "waiting for approval"
                : runtimeExecution?.waitingForInteraction == true ? "waiting on you" : response.terminalState?.rawValue
        }
        response.statusDetail = runtimeExecution?.waitingForApproval == true ? "Answer the approval card in this conversation."
            : runtimeExecution?.waitingForInteraction == true
                ? (runtimeExecution?.waitingInteraction?.title).map { "\($0) — answer it in the conversation." }
                    ?? "Waiting on your answer in the conversation."
            : LLMCallContext.turnTokenBudget?.exhausted == true ? "Stopped at the per-run token limit." : nil
        response.statusDetail = runtimeExecution?.statusDetail(response.statusDetail)
        response.pendingApprovalID = runtimeExecution?.pendingApprovalID
        if result.terminalReason == .replyCompleted,
           let journal = DeskContinuationScope.current,
           await journal.snapshot().runID == runId {
            do {
                try await journal.completeResponse(JSONValue.fromEncodable(response), reply: response.output,
                    peerSources: PeerDataTaint.current?.checkpointSources ?? [])
            } catch {
                nativeLog("Saved reply; its work journal could not settle: %@", String(describing: error))
                await noticeSink("turn_settlement_failed", "Saved the reply, but couldn't update its work record.")
            }
        }
        // The saved row's own text, so the phone's transcript snapshot settles the live bubble instead of adding a second copy.
        ChatLiveTap.emit(sessionId: resolvedSession, surface: surface, runId: runId,
                         response.runtimeStatus.map { .incomplete(transcriptRow.text, status: $0) }
                             ?? .answered(transcriptRow.text))
        execution = StructuredChatExecution(response: response, turn: .success(result))
        case .failure(let error):
            let cancelled = error is CancellationError
            let partial = BotRunner.conditionReply(
                ToolCallParser.visiblePrefix(in: ToolCallParser.stripToolUseMarkers(observation.partialReply)),
                sessionID: resolvedSession)
            let attachments = ChatGeneratedImageArtifacts.attachments(
                from: observation.toolDispatches, chosen: chosenPaths, dataRoot: dataRoot)
            let saved = try await persistPartialIfNeeded(
                sessionId: resolvedSession, runId: runId, text: partial, attachments: attachments,
                cancelled: cancelled, failure: error, source: surface, outcomeContext: context, onNotice: noticeSink)
            if saved == nil, !cancelled, Self.shouldPersistFailureMessage(surface: surface) {
                try await appendFailureMessageIfNeeded(sessionId: resolvedSession, runId: runId,
                    failure: error, persona: persona, surface: surface,
                    outcomeContext: context, outcomeTurnID: boundTurnId)
            }
            var response = ChatResponse(runId: runId, model: model, reasoningEffort: reasoningEffort,
                output: saved ?? "", sessionId: resolvedSession, attachments: saved == nil ? nil : attachments)
            response.terminalState = cancelled ? .stopped : .failed
            response.runtimeStatus = response.terminalState?.rawValue
            response.statusDetail = LLMCallContext.turnTokenBudget?.exhausted == true ? "Stopped at the per-run token limit."
                : cancelled ? (saved == nil ? "Stopped." : "Stopped. What was produced has been saved.") : String(describing: error)
            response.statusDetail = ChatTurnExecution.current?.statusDetail(response.statusDetail)
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
                    error: error, observation: observation)
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
        do {
            try await settleTurnCheckpoint(terminal, sessionId: resolvedSession, runId: runId)
        } catch {
            nativeLog("Turn terminal could not be saved; checkpoint retained: %@", String(describing: error))
            await noticeSink("turn_settlement_failed", "Couldn't save this turn's final record.")
            settled = .failure(error)
        }
        // The accepted message owns its incoming appraisal even without a saved answer; a reply that captured a promotion already owns that appraisal.
        if !promotionStarted {
            let afterReply = await engine.deferMemoryPromotion(userMessage: message, assistantMessage: observation.partialReply,
                toolDispatches: observation.toolDispatches, sessionId: resolvedSession, surface: surface)
            await afterReply.start()
        }
        return settled
    }

    // Trace the exact post-filter tools array sent by this turn; schema bytes exclude HTTP framing and tokens.
    static func traceFinalToolContract(
        turnId: String,
        wire: [LLMToolSchema],
        surface: String?
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
        ConversationPrefixTelemetry.sink?.set(weight)
        // Fired with the turn id in hand: this runs before the task-local turn binding opens, so the context-derived firing dropped every row.
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
}
