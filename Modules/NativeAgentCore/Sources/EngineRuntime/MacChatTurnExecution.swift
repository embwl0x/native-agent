import Foundation
import TurnTrace
import ApprovalTransactions
import ChatTurnRuntime
import ChatTurnContracts
import ChatSessionWork
import AgentWorkspace
import NativeAgentCore
@_exported import NativeAgentShared
import ProviderRouting
import Connectors
import DeviceSync
import PersistenceCore
import CloudKit
import DoctorChecks
import MemoryV2
import StandingBots
import Observation
import Cognition
import ChatToolRuntime
import ChatToolParsing
import SlackBot
import TelegramBot
import TriggerScheduler
import BackgroundLoops
import AppToolRuntime
import TrustCenter
import MacControl
import AttentionRouting
import ApprovalInbox
import Desk
import NotificationInbox
import ToolRegistry
import Transcripts
import BackgroundWork
import DreamREMCycle
import AuthoredCapabilities
@preconcurrency import EventKit
import MacIntegration
import ToolExecution
import Senses
import Browser
import PersonaEngine
import Synchronization
import Studio
import Agents
import AgentConversations
import ChromeControl
import CognitiveSubstrate
import Context
import ContextFlow
import os
import TrustPersistence
import SwarmRuns
import Onboarding
import Privacy
import Experiences
import CryptoKit
import ActivityWatch
import OSLog
import SchedulerExecution
import Darwin
import Combine
import UserNotifications
import Research
import ImageIO
import UniformTypeIdentifiers
import AppKit
import Dispatcher
import SystemOps
import CoreGraphics
// Blueprint: | `MacChatTurnExecution.swift` | `NativeAgentEngine`, `TurnsFacade.runtime`, `ChatTurnToolPlacement`; Ordered stream settlement |

extension NativeAgentEngine {
    @MainActor
    public func runMacChatTurnBody<Port: MacChatTurnPresentationPort>(
        _ text: String,
        attachments: [NativeAgentShared.MultimodalAttachment],
        sessionId: String,
        generation: Int,
        hideUserBubble: Bool,
        activityIdentity: MacChatTurnIdentity,
        turn: Turn,
        port: Port,
        client: SwiftNativeChatOrchestrationClient,
        missingProviderGuidance: String?,
        errorAdvice: @escaping (Error) -> String,
        finishReplyPresentation: () async -> Void
    ) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty || !attachments.isEmpty else { return }
        let requestSessionId = sessionId
        let userContent = Self.macChatUserContent(trimmed, attachments: attachments)
        let bubbleId = UUID().uuidString
        // No-provider guidance precedes streaming cleanup because no turn ran.
        if let guidance = missingProviderGuidance {
            showMacChatUserBubble(text, attachments: attachments, sessionId: requestSessionId, turn: turn, port: port, leads: false)
            // Synthetic notices must survive reload with their retry affordance.
            let guidanceBubble = ChatMessage(
                id: MacChatTurnRuntime.syntheticErrorIDPrefix + UUID().uuidString,
                sessionId: requestSessionId,
                role: "assistant",
                content: guidance,
                metadata: .syntheticError(
                    "no_provider_connected",
                    userRowPersisted: false,
                    inputHadAttachments: !attachments.isEmpty
                )
            )
            port.animateMacChatMutation { transcripts.appendMessage(guidanceBubble, to: requestSessionId, leads: false) }
            await InlineInteractionResolver.raiseMissingChatProvider(
                sessionID: requestSessionId, userContent: userContent,
                hasAttachments: !attachments.isEmpty,
                dataRoot: dataRoot, turn: turn
            )
            port.presentMacChatTurn(.status("No AI provider connected — connect one with Open Providers in the chat."))
            _ = await port.settleChatTurnLifecycle(
                identity: activityIdentity,
                kind: .failed(reason: "No AI provider is connected."),
                at: Date()
            )
            return
        }
        turns.setStreamingBubbleID(bubbleId, for: requestSessionId)
        turns.streamingTexts[requestSessionId] = ""
        if !hideUserBubble {
            showMacChatUserBubble(text, attachments: attachments, sessionId: requestSessionId, turn: turn, port: port)
        }
        var streamingBubble = ChatMessage(sessionId: requestSessionId, role: "assistant", content: "")
        streamingBubble.id = bubbleId
        var streamingMetadata = ChatMessageMetadata()
        streamingMetadata.turnTraceId = activityIdentity.turnId
        streamingBubble.metadata = streamingMetadata
        port.animateMacChatMutation { transcripts.appendMessage(streamingBubble, to: requestSessionId) }
        turns.busySessions.insert(requestSessionId)
        defer {
            turns.busySessions.remove(requestSessionId)
            turns.replyingSessions.remove(requestSessionId)
            turns.streamingTexts[requestSessionId] = nil
            turns.setStreamingBubbleID(nil, for: requestSessionId)
        }

        // The turn carries the displayed user row id to core persistence.
        let execution = ChatStreamExecution.macChatStream(
            client: client, text: trimmed, attachments: attachments,
            sessionId: requestSessionId, activityIdentity: activityIdentity, replyRowId: bubbleId,
            hideUserBubble: hideUserBubble,
            onScreenPreview: { [turns] in await turns.receiveScreenPreview($0, identity: activityIdentity) },
            helperSession: { progress, _ in self.standingBotSession(admitted: true, attachments: attachments, progress: progress) },
            dataRoot: dataRoot, turn: turn
        )
        let outcome: Result<Bool, any Error>
        var consumerWasCancelled = false
        do {
            let streamedText = try await consumeMacChatStream(
                execution.events, port: port, sessionId: requestSessionId, bubbleId: bubbleId,
                generation: generation, activityIdentity: activityIdentity
            )
            guard let completion = try await port.completeMacChatStream(
                execution: execution, sessionId: requestSessionId,
                generation: generation, streamedText: streamedText
            ) else { return }
            let finalStreamText = completion.text
            let finalTrimmed = finalStreamText.trimmingCharacters(in: .whitespacesAndNewlines)
            let streamProducedNoContent = finalTrimmed.isEmpty
            if !streamProducedNoContent {
                transcripts.updateMessageContent(id: bubbleId, in: requestSessionId, content: finalStreamText)
                if let commentary = completion.workingCommentaryCharacters {
                    port.animateMacChatMutation { transcripts.setWorkingCommentary(commentary, id: bubbleId, in: requestSessionId) }
                }
            }
            // Clear restore ids before reload can reinject an empty bubble.
            if streamProducedNoContent {
                transcripts.removeMessage(id: bubbleId, from: requestSessionId)
                turns.clearStreamingBubbleState(requestSessionId)
            }
            // Wait for crossfade before reloading the saved reply under the same bubble id.
            if !streamProducedNoContent, turns.isReplyTextSettled(requestSessionId) {
                await finishReplyPresentation()
            }
            outcome = .success(streamProducedNoContent)
        } catch {
            guard await port.joinFailedMacChatStream(
                execution: execution, sessionId: requestSessionId, generation: generation
            ) else { return }
            consumerWasCancelled = Task.isCancelled
            // Discard silent replies; spoken replies settle into their saved partial under the same id.
            if transcripts.displayedTranscript(for: requestSessionId).messages.first(where: { $0.id == bubbleId })?.content
                .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false {
                transcripts.removeMessage(id: bubbleId, from: requestSessionId)
            }
            outcome = .failure(error)
        }
        let settlement = await port.settleMacChatStream(identity: activityIdentity, result: await execution.waitForProducerTermination())
        let stopped = consumerWasCancelled || settlement.state?.presentation.phase == .canceled
        // Settle through store publication rather than re-reading the view.
        transcripts.settleLive(requestSessionId)
        await Task { [self] in
        switch stopped ? nil : outcome {
            case nil: break
            case .success(let producedNoContent)?:
                if producedNoContent, !settlement.hasAssistantReceipt {
                    let notice = ChatMessage(
                        id: MacChatTurnRuntime.syntheticErrorIDPrefix + UUID().uuidString,
                        sessionId: requestSessionId, role: "assistant",
                        content: "No reply came back. Use Try again to retry.",
                        metadata: .syntheticError("stream_produced_no_content", inputHadAttachments: !attachments.isEmpty)
                    )
                    port.animateMacChatMutation { transcripts.appendMessage(notice, to: requestSessionId, leads: false) }
                }
            case .failure(let error)?:
                if settlement.state?.presentation.phase == .outcomeUnknown {
                    port.presentMacChatTurn(.status("Turn stopped; its outcome could not be confirmed"))
                } else if !settlement.hasAssistantReceipt {
                    let isRefusal = ProviderFailure.classify(error) == .refused
                    var metadata = ChatMessageMetadata.syntheticError(
                        error.localizedDescription, inputHadAttachments: !attachments.isEmpty
                    )
                    if isRefusal { metadata.providerRefusal = true }
                    metadata.failureWork = ChatTurnFailure.work(for: error)
                    var notice = ChatMessage(
                        id: MacChatTurnRuntime.syntheticErrorIDPrefix + UUID().uuidString,
                        sessionId: requestSessionId, role: "assistant",
                        content: MacChatTurnRuntime.normalizeStreamErrorForChat(error, advice: errorAdvice)
                            + (isRefusal ? " outcome unknown — inspect before retry." : ""),
                        metadata: metadata
                    )
                    // Keep unsaved requests visible with their retry notice.
                    if !hideUserBubble, let saved = try? await transcripts.loadMessages(sessionId: requestSessionId, cached: true),
                       !saved.contains(where: { $0.id == turn.rows.pinnedUserMessageID }) {
                        notice.metadata?.syntheticUserRowPersisted = false
                    }
                    port.animateMacChatMutation { transcripts.appendMessage(notice, to: requestSessionId, leads: false) }
                }
            }
            if await transcripts.refreshSessionIndex() == false, let detail = transcripts.sessionIndexError {
                port.presentMacChatTurn(.status(detail))
            }
            if case .success = outcome { _ = try? await persona.loadDocuments() }
            NotificationCenter.default.post(name: .chatTurnCompleted, object: requestSessionId)
        }.value
    }

    /// The person's optimistic row, scoped to its request session (detached views included) under the id its turn pins;
    /// shown once, by whichever path shows it first, so an arrival that waited is never appended twice.
    @MainActor
    public func showMacChatUserBubble<Port: MacChatTurnPresentationPort>(
        _ text: String, attachments: [NativeAgentShared.MultimodalAttachment], sessionId: String, turn: Turn, port: Port,
        leads: Bool = true
    ) {
        guard let id = turn.rows.pinnedUserMessageID,
              !transcripts.displayedTranscript(for: sessionId).messages.contains(where: { $0.id == id }) else { return }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        var bubble = ChatMessage(id: id, sessionId: sessionId, role: "user", content: Self.macChatUserContent(trimmed, attachments: attachments))
        if let origin = turn.origin {
            var recorded = ChatMessageOriginMetadata(surface: origin.surface, agent: origin.agent)
            recorded.authored = origin.authored?.rawValue
            recorded.peerSources = turn.peerSteering?.checkpointSources ?? []
            recorded.elevatedPeerSources = turn.peerSteering?.elevatedSources ?? []
            var metadata = ChatMessageMetadata()
            metadata.origin = recorded
            metadata.envelope = ChatMessageOriginMetadata(surface: origin.surface, agent: origin.agent)
            bubble.metadata = metadata
        }
        port.animateMacChatMutation { transcripts.appendMessage(bubble, to: sessionId, leads: leads) }
    }

    /// An attachments-only send still shows a row.
    nonisolated static func macChatUserContent(_ trimmed: String, attachments: [NativeAgentShared.MultimodalAttachment]) -> String {
        trimmed.isEmpty ? "(attached \(attachments.count) item(s))" : trimmed
    }

}

extension NativeAgentEngine {
    @MainActor
    public func resumeMacChatTurn<Port: MacChatTurnPresentationPort>(_ checkpoint: TurnCheckpoint,
        port: Port,
        operation: @escaping @Sendable (Turn) async throws -> Void) async throws {
        let macChatTurns = turns.runtime
        let session = checkpoint.sessionId
        let identity = MacChatTurnIdentity(sessionId: session, turnId: checkpoint.turnId)
        guard let generation = macChatTurns.reserveTurn(sessionId: session) else {
            throw MacChatTurnLifecycleStoreError.invalidRecord
        }
        defer {
            if macChatTurns.taskGenerations[session] == generation {
                turns.streamingTexts[session] = nil
                turns.setStreamingBubbleID(nil, for: session)
                turns.replyingSessions.remove(session)
                _ = macChatTurns.finishRuntime(sessionId: session, generation: generation)
            }
        }
        await macChatTurns.pendingStopWrites[session]?.value
        let records = try await macChatTurns.lifecycleStore.records()
        let state: MacChatTurnLifecycleState
        if let restored = records.first(where: { $0.identity == identity })?.restoredState() { state = restored }
        else {
            // A send saved while the agent worked never began its lifecycle: it begins now, as its own turn.
            guard await port.beginChatTurnLifecycle(identity: identity, generation: generation, at: Date()).persisted,
                  let begun = macChatTurns.lifecycleBySession[session] else { throw MacChatTurnLifecycleStoreError.invalidRecord }
            state = begun
        }
        guard macChatTurns.taskGenerations[session] == generation else { throw MacChatTurnLifecycleStoreError.invalidRecord }
        let rows = try await transcripts.loadMessages(sessionId: session)
        try Task.checkCancellation()
        guard macChatTurns.taskGenerations[session] == generation else { throw CancellationError() }
        let bubble = ChatMessage(sessionId: session, runId: checkpoint.runId)
        // Resumed streaming replies supersede their saved partials.
        transcripts.appendLive(bubble, to: session, replacing: Set(rows.filter { $0.runId == checkpoint.runId && $0.metadata?.partial == true }.map(\.id)))
        macChatTurns.activeTurnIDsBySession[session] = identity.turnId
        macChatTurns.lifecycleBySession[session] = state
        macChatTurns.streamingSessions.insert(session)
        turns.setStreamingBubbleID(bubble.id, for: session)

        let events = AsyncThrowingStream<TurnStreamEvent, Error>.makeStream()
        let turn = Turn(id: checkpoint.turnId, run: checkpoint.runId, session: session)
            .with(\.replyStreamRendersCards, true)
            .with(\.replyRow, .init(turnId: checkpoint.turnId, sessionId: session, messageId: bubble.id))
            .with(\.screenPreview, { [turns] in await turns.receiveScreenPreview($0, identity: identity) })
        let producer = Task {
            let lease = SessionTurnDelivery.mount(dataRoot: dataRoot, sessionID: session, runID: checkpoint.runId,
                recipient: .init(progress: { events.continuation.yield($0) }))
            defer { SessionTurnDelivery.unmount(dataRoot: dataRoot, sessionID: session, runID: checkpoint.runId, lease: lease) }
            defer { events.continuation.finish() }
            do { try await operation(turn) }
            catch { events.continuation.finish(throwing: error); throw error }
        }
        macChatTurns.tasks[session] = Task {
            _ = await withTaskCancellationHandler { await producer.result } onCancel: { producer.cancel() }
        }
        let consumer = Task {
            try await self.consumeMacChatStream(events.stream, port: port, sessionId: session, bubbleId: bubble.id,
                generation: generation, activityIdentity: identity)
        }
        let outcome = await producer.result
        let rendered = await consumer.result
        guard macChatTurns.taskGenerations[session] == generation else { throw CancellationError() }
        let result: Result<ChatResponse, any Error>? = switch outcome {
        case .success: nil
        case .failure(let error): .failure(error)
        }
        _ = await port.settleMacChatStream(identity: identity, result: result)
        guard macChatTurns.taskGenerations[session] == generation else { throw CancellationError() }
        _ = port.closeChatTurnLifecycleIntake(sessionId: session, turnId: identity.turnId, at: Date())
        turns.streamingTexts[session] = nil
        turns.setStreamingBubbleID(nil, for: session)
        turns.replyingSessions.remove(session)
        _ = macChatTurns.finishRuntime(sessionId: session, generation: generation)
        transcripts.settleLive(session)
        try outcome.get()
        _ = try rendered.get()
    }

}

@MainActor
public extension NativeAgentEngine {
    func clearMacChatTranscript(
        sessionId: String,
        didClear: () -> Void
    ) async throws {
        let clearError: (any Error)?
        do {
            try await transcripts.clear(sessionId: sessionId)
            clearError = nil
        } catch let error as ChatMessageClearError { clearError = error }
        didClear()
        do { try await transcripts.refreshMessages(sessionId: sessionId) }
        catch { throw clearError ?? error }
        if let clearError { throw clearError }
        _ = try await transcripts.readSessionIndex()
    }

    func archiveMacChatTranscript(
        port: any MacChatTurnPresentationPort,
        sessionId: String,
        prunePresentation: (String) async -> Void
    ) async throws -> Bool {
        guard try await transcripts.archive(id: sessionId) != nil else { return false }
        let runningTask = turns.runtime.tasks[sessionId]
        // Stop must include busy reservations still awaiting admission.
        if runningTask != nil || turns.runtime.streamingSessions.contains(sessionId) || turns.runtime.busySessions.contains(sessionId) {
            port.stopChatStream(sessionId: sessionId)
        }
        // Retain reservations until their producer commits Stop proof.
        await runningTask?.value
        if runningTask == nil, turns.runtime.activeTurnIDsBySession[sessionId] == nil {
            turns.runtime.taskGenerations[sessionId] = nil
        }
        turns.streamingTexts[sessionId] = nil
        turns.setStreamingBubbleID(nil, for: sessionId)
        await prunePresentation(sessionId)
        transcripts.sessions.removeAll { $0.id == sessionId }
        return true
    }

    @discardableResult func regenerateMacChatResponse(
        port: any MacChatTurnPresentationPort,
        target: ChatMessage,
        sessionId: String,
        parent: Turn?,
        syntheticPrefix: String,
        client: SwiftNativeChatOrchestrationClient,
        presentFailure: @escaping @MainActor (Error) -> Void,
        didComplete: @MainActor () -> Void,
        renderer: UUID? = nil
    ) async -> MacChatRegenerationOutcome {
        guard !sessionId.isEmpty, transcripts.sessions.contains(where: { $0.id == sessionId }) else {
            port.presentMacChatTurn(.status("Regenerate failed: that chat session is no longer available"))
            return .refused("That chat session is no longer available.")
        }
        let isSyntheticNotice = target.id.hasPrefix(syntheticPrefix)
        let completeMessages: [ChatMessage]
        do { completeMessages = try await transcripts.loadMessages(sessionId: sessionId, cached: true) }
        catch {
            presentFailure(error)
            return .refused(error.localizedDescription)
        }
        guard let retrySnapshot = MacChatRetrySnapshot.capture(
            target: target, messages: completeMessages,
            sessionId: sessionId, isSyntheticNotice: isSyntheticNotice
        ) else {
            port.presentMacChatTurn(.status("Regenerate failed: that response is no longer the current retry target"))
            return .refused("That response is no longer the current retry target.")
        }
        guard !retrySnapshot.inputHadAttachments else {
            port.presentMacChatTurn(.status("Regenerate can't replay this question's attachments yet. Send the question with its attachments again to retry."))
            return .refused("Send the question with its attachments again to retry.")
        }
        guard let admission = await port.admitMacChatRetry(
            sessionId: sessionId,
            matchesCanonical: {
                let messages = try? await self.transcripts.loadMessages(sessionId: sessionId, cached: true)
                return messages.map { retrySnapshot.matchesCanonical($0) } == true
            },
            stillMatchesLocal: {
                retrySnapshot.stillMatchesLocal(self.transcripts.displayedTranscript(for: sessionId).messages)
            }
        ) else { return .refused("The retry was not admitted; inspect the conversation's current state before retrying.") }
        let lifecycleIdentity = admission.identity
        let priorText = retrySnapshot.priorUserText
        // A UI click is the person's local act; chat.regenerate invoked by
        // another turn keeps that caller's held provenance, nil included.
        let envelope: TurnEnvelope?
        if let parent { envelope = parent.envelope }
        else { envelope = .personOnMac("mac_ui:chat.regenerate") }
        var retryTurn = TurnRequest(message: priorText, sessionID: sessionId, surface: "chat",
            envelope: .some(envelope), origin: .some(retrySnapshot.priorUserOrigin),
            replacementAssistantMessageID: .some(isSyntheticNotice ? nil : target.id))
            .turn(id: lifecycleIdentity.turnId, parent: parent)
        if let renderer { retryTurn[FacePresentationPart.self] = renderer }
        retryTurn.rows.replacementUserMessageID = retrySnapshot.userRowPersisted ? retrySnapshot.priorUserMessageId : nil
        // Save unsaved questions under their displayed id.
        retryTurn.rows.pinnedUserMessageID = retrySnapshot.userRowPersisted ? nil : retrySnapshot.priorUserMessageId
        await port.runAdmittedMacChatRetry(admission, operation: { [self] retryTurn in
            turns.runtime.busySessions.insert(sessionId)
            defer { turns.runtime.busySessions.remove(sessionId) }
            let result: Result<ChatResponse, any Error>
            do {
                let reply = try await TurnTraceContext.$turnId.withValue(retryTurn.id) {
                    try await client.chatExecution(message: priorText, sessionId: sessionId,
                        model: "", reasoningEffort: "", fileAccess: "auto", attachments: [],
                        persona: nil, surface: "chat", suppressUserAppend: retrySnapshot.userRowPersisted,
                        progress: nil, turn: retryTurn, serviceTier: nil).response
                }
                result = .success(reply)
            } catch {
                turns.runtime.busySessions.remove(sessionId)
                result = .failure(error)
            }
            let settlement = await port.settleMacChatStream(identity: lifecycleIdentity, result: result)
            transcripts.settleLive(sessionId)
            // Remove retried notices and unsaved requests only after the retry receipt is canonical.
            if isSyntheticNotice, settlement.hasCanonicalReceipt {
                transcripts.removeMessage(id: target.id, from: sessionId)
                if !retrySnapshot.userRowPersisted { transcripts.removeMessage(id: retrySnapshot.priorUserMessageId, from: sessionId) }
            }
            switch settlement.state?.presentation.phase {
            case .completed:
                port.presentMacChatTurn(.status("Regenerated response"))
            case .canceled:
                break
            case .outcomeUnknown:
                port.presentMacChatTurn(.status("Regenerate outcome could not be confirmed"))
            default:
                switch result {
                case .success:
                    port.presentMacChatTurn(.status(settlement.state?.presentation.phase == .failed
                        ? "Regenerate failed" : "Regenerate outcome could not be confirmed"))
                case .failure(let error):
                    if !Task.isCancelled { presentFailure(error) }
                }
            }
            if case .success = result {
                if await transcripts.refreshSessionIndex() == false, let detail = transcripts.sessionIndexError {
                    port.presentMacChatTurn(.status(detail))
                }
            }
            return settlement.state?.presentation.phase == .completed
        }, didComplete: didComplete, turn: retryTurn)
        let state = turns.runtime.lifecycleBySession[sessionId]
        return .outcome(lifecycleIdentity, phase: state?.identity == lifecycleIdentity ? state?.presentation.phase : nil)
    }
}

public enum MacChatRegenerationOutcome: Sendable {
    case refused(String)
    case outcome(MacChatTurnIdentity, phase: TurnPresentationPhase?)
}

@MainActor
public extension NativeAgentEngine {
    /// Stream frames publish only through the per-session transcript owner.
    func consumeMacChatStream(
        _ stream: AsyncThrowingStream<TurnStreamEvent, Error>,
        port: any MacChatTurnPresentationPort,
        sessionId requestSessionId: String,
        bubbleId: String,
        generation: Int,
        activityIdentity: MacChatTurnIdentity
    ) async throws -> String {
        let accumulator = ChatStreamAccumulator()
        return try await accumulator.consume(
            stream, interval: ChatStreamAccumulator.publishInterval,
            activityIdentity: activityIdentity,
            onTurnActivity: { [weak port] activity in
                guard let port else { return }
                await self.receiveChatTurnActivity(activity, port: port)
            },
            onMovement: { [weak port] writing in
                guard let port else { return }
                await self.receiveChatTurnMovement(writing, identity: activityIdentity, port: port)
            }
        ) { @MainActor [self, requestSessionId] snapshot, length, settled in
            try Task.checkCancellation()
            // Superseded turns must stop publishing before the post-stream guard returns.
            guard turns.runtime.taskGenerations[requestSessionId] == generation else { return }
            turns.streamingTexts[requestSessionId] = snapshot
            if !snapshot.isEmpty, !turns.runtime.replyingSessions.contains(requestSessionId) {
                turns.runtime.replyingSessions.insert(requestSessionId)
            }
            transcripts.updateMessageContent(id: bubbleId, in: requestSessionId, content: snapshot)
            _ = port.recordChatTurnStreamProgress(
                identity: activityIdentity,
                accumulatedUTF16Length: length,
                at: Date()
            )
            if let settled {
                _ = port.applyChatTurnLifecycleInput(MacChatTurnLifecycleInput(
                    identity: activityIdentity,
                    kind: .replyTextSettled(settled),
                    occurredAt: Date()
                ))
            }
        }
    }
}

@MainActor
extension NativeAgentEngine {
    /// Reduce notices and tool activity into the existing lifecycle without a second event bus or payload store.
    func receiveChatTurnActivity(_ activity: MacChatTurnActivity, port: any MacChatTurnPresentationPort) {
        guard port.applyChatTurnLifecycleInput(MacChatTurnLifecycleInput(
            identity: activity.identity,
            kind: .activity(activity),
            occurredAt: activity.occurredAt
        )) != nil else { return }

        port.presentMacChatTurn(.activity(activity))
    }

    /// Streamed bytes move the card even before they are words; a writing call names itself there.
    func receiveChatTurnMovement(_ writing: TurnCallWriting?, identity: MacChatTurnIdentity, port: any MacChatTurnPresentationPort) {
        _ = port.applyChatTurnLifecycleInput(MacChatTurnLifecycleInput(identity: identity, kind: .moved(writing), occurredAt: Date()))
    }

}
