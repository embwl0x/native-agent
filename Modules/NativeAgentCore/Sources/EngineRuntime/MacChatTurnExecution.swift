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
import WorkshopExecution
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
import Procedures
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
// Blueprint: | `MacChatTurnExecution.swift` | `NativeAgentEngine`: Mac turn streaming, checkpoint resume, clear/archive, retry and lifecycle activity use `TurnsFacade.runtime`; producer joins, transcript publication, settlement and queue release retain their order; `ChatTurnToolPlacement` places canonical tool rows before the live reply |

extension NativeAgentEngine {
    @MainActor
    public func runMacChatTurnBody<Port: MacChatTurnPresentationPort>(
        _ text: String,
        attachments: [NativeAgentShared.MultimodalAttachment],
        sessionId: String,
        generation: Int,
        hideUserBubble: Bool,
        activityIdentity: MacChatTurnIdentity,
        port: Port,
        client: SwiftNativeChatOrchestrationClient,
        missingProviderGuidance: String?,
        errorAdvice: @escaping (Error) -> String,
        finishReplyPresentation: () async -> Void
    ) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty || !attachments.isEmpty else { return }
        let requestSessionId = sessionId
        let userContent = trimmed.isEmpty ? "(attached \(attachments.count) item(s))" : trimmed
        let bubbleId = UUID().uuidString
        let userTurnId = UUID().uuidString
        // No-provider guidance precedes streaming cleanup because no turn ran.
        if let guidance = missingProviderGuidance {
            var typedBubble = ChatMessage(sessionId: requestSessionId, role: "user", content: userContent)
            typedBubble.id = userTurnId
            port.animateMacChatMutation { transcripts.appendMessage(typedBubble, to: requestSessionId, leads: false) }
            // Synthetic notices survive reload and retain their retry affordance.
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
                dataRoot: dataRoot
            )
            port.presentMacChatTurn(.status("No AI provider connected — connect one with Open Providers in the chat."))
            _ = await port.settleChatTurnLifecycle(
                identity: activityIdentity,
                kind: .failed(reason: "No AI provider is connected."),
                at: Date()
            )
            return
        }
        // Retain only the accepted local request and its preceding conversation
        // row. If routing fails before the core writes the user, an unchanged
        // canonical tail can prove that this request still needs persistence.
        var originalUserBubble = ChatMessage(
            id: userTurnId, sessionId: requestSessionId, role: "user", content: userContent
        )
        if let origin = ChatPersistenceContext.originProvenance {
            var recorded = ChatMessageOriginMetadata(surface: origin.surface, agent: origin.agent)
            recorded.authored = origin.authored?.rawValue
            recorded.peerSources = PeerDataTaint.current?.checkpointSources ?? []
            recorded.elevatedPeerSources = PeerDataTaint.current?.elevatedSources ?? []
            var metadata = ChatMessageMetadata()
            metadata.origin = recorded
            metadata.envelope = ChatMessageOriginMetadata(surface: origin.surface, agent: origin.agent)
            originalUserBubble.metadata = metadata
        }

        // A session switch restores the accepted prompt and its live reply.
        turns.streamingBubbleIds[requestSessionId] = bubbleId
        turns.streamingTexts[requestSessionId] = ""
        // Optimistic rows belong to the request session, including detached views.
        if !hideUserBubble {
            port.animateMacChatMutation { transcripts.appendMessage(originalUserBubble, to: requestSessionId) }
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
            turns.streamingBubbleIds[requestSessionId] = nil
        }

        // The user row the screen already shows is the row the core saves (one id).
        let execution = ChatPersistenceContext.$pinnedUserMessageID.withValue(hideUserBubble ? nil : userTurnId) {
            ChatStreamExecution.macChatStream(
                client: client, text: trimmed, attachments: attachments,
                sessionId: requestSessionId, activityIdentity: activityIdentity, replyRowId: bubbleId,
                hideUserBubble: hideUserBubble,
                onScreenPreview: { [turns] in await turns.receiveScreenPreview($0, identity: activityIdentity) },
                helperSession: { progress in self.standingBotSession(admitted: true, attachments: attachments, progress: progress) }, dataRoot: dataRoot
            )
        }
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
            // Clear restore IDs before reload can reinject an empty bubble.
            if streamProducedNoContent {
                transcripts.removeMessage(id: bubbleId, from: requestSessionId)
                turns.clearStreamingBubbleState(requestSessionId)
            }
            // Wait for the settled reply's crossfade before reloading its saved row into the same bubble id.
            if !streamProducedNoContent, turns.isReplyTextSettled(requestSessionId) {
                await finishReplyPresentation()
            }
            outcome = .success(streamProducedNoContent)
        } catch {
            guard await port.joinFailedMacChatStream(
                execution: execution, sessionId: requestSessionId, generation: generation
            ) else { return }
            consumerWasCancelled = Task.isCancelled
            // A reply that said nothing leaves; one that spoke settles into its saved partial (same row id).
            if transcripts.messages(for: requestSessionId).first(where: { $0.id == bubbleId })?.content
                .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false {
                transcripts.removeMessage(id: bubbleId, from: requestSessionId)
            }
            outcome = .failure(error)
        }
        let settlement = await port.settleMacChatStream(identity: activityIdentity, result: await execution.waitForProducerTermination())
        let stopped = consumerWasCancelled || settlement.state?.presentation.phase == .canceled
        // The turn is over: its rows settle into the store's own publication; nothing here re-reads the view.
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
                    // A request the store never took is still on screen as its live row; the notice says so for Try again.
                    if !hideUserBubble, let saved = try? await transcripts.loadMessages(sessionId: requestSessionId, cached: true),
                       !saved.contains(where: { $0.id == originalUserBubble.id }) {
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

}

extension NativeAgentEngine {
    @MainActor
    public func resumeMacChatTurn<Port: MacChatTurnPresentationPort>(_ checkpoint: TurnCheckpoint,
        port: Port,
        operation: @escaping @Sendable () async throws -> Void) async throws {
        let macChatTurns = turns.runtime
        let session = checkpoint.sessionId
        let identity = MacChatTurnIdentity(sessionId: session, turnId: checkpoint.turnId)
        guard let generation = macChatTurns.reserveTurn(sessionId: session) else {
            throw MacChatTurnLifecycleStoreError.invalidRecord
        }
        defer {
            if macChatTurns.taskGenerations[session] == generation {
                turns.streamingTexts[session] = nil
                turns.streamingBubbleIds[session] = nil
                turns.replyingSessions.remove(session)
                // A send queued behind this reservation goes once it is released.
                if macChatTurns.finishRuntime(sessionId: session, generation: generation) {
                    Task { @MainActor in await port.drainNextQueuedChatTurnIfPossible(sessionId: session) }
                }
            }
        }
        await macChatTurns.pendingStopWrites[session]?.value
        let records = try await macChatTurns.lifecycleStore.records()
        guard let state = records.first(where: { $0.identity == identity })?.restoredState(),
              macChatTurns.taskGenerations[session] == generation else { throw MacChatTurnLifecycleStoreError.invalidRecord }
        let rows = try await transcripts.loadMessages(sessionId: session)
        try Task.checkCancellation()
        guard macChatTurns.taskGenerations[session] == generation else { throw CancellationError() }
        let bubble = ChatMessage(sessionId: session, runId: checkpoint.runId)
        // The resumed reply stands over its saved partials while it streams.
        transcripts.appendLive(bubble, to: session, replacing: Set(rows.filter { $0.runId == checkpoint.runId && $0.metadata?.partial == true }.map(\.id)))
        macChatTurns.activeTurnIDsBySession[session] = identity.turnId
        macChatTurns.lifecycleBySession[session] = state
        macChatTurns.streamingSessions.insert(session)
        turns.streamingBubbleIds[session] = bubble.id

        let events = AsyncThrowingStream<TurnStreamEvent, Error>.makeStream()
        let producer = Task {
            let lease = SessionTurnDelivery.mount(dataRoot: dataRoot, sessionID: session, runID: checkpoint.runId,
                recipient: .init(progress: { events.continuation.yield($0) }))
            defer { SessionTurnDelivery.unmount(dataRoot: dataRoot, sessionID: session, runID: checkpoint.runId, lease: lease) }
            defer { events.continuation.finish() }
            do { try await ChatToolSessionContext.$replyStreamRendersCards.withValue(true) {
                try await MacScreenPreviewBus.$publish.withValue({ [turns] in
                    await turns.receiveScreenPreview($0, identity: identity)
                }) {
                    try await operation()
                }
            } } catch { events.continuation.finish(throwing: error); throw error }
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
        turns.streamingBubbleIds[session] = nil
        turns.replyingSessions.remove(session)
        let released = macChatTurns.finishRuntime(sessionId: session, generation: generation)
        transcripts.settleLive(session)
        if released { await port.drainNextQueuedChatTurnIfPossible(sessionId: session) }
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
        transcripts.sessions = try await transcripts.list()
    }

    func archiveMacChatTranscript(
        port: any MacChatTurnPresentationPort,
        sessionId: String,
        prunePresentation: (String) -> Void
    ) async throws -> Bool {
        guard try await transcripts.archive(id: sessionId) != nil else { return false }
        let runningTask = turns.runtime.tasks[sessionId]
        // A reservation still reading admission (busy, no task yet) is stopped too.
        if runningTask != nil || turns.runtime.streamingSessions.contains(sessionId) || turns.runtime.busySessions.contains(sessionId) {
            port.stopChatStream(sessionId: sessionId)
        }
        // Do not erase the reservation while its producer commits Stop proof.
        await runningTask?.value
        if runningTask == nil, turns.runtime.activeTurnIDsBySession[sessionId] == nil {
            turns.runtime.taskGenerations[sessionId] = nil
        }
        turns.streamingTexts[sessionId] = nil
        turns.streamingBubbleIds[sessionId] = nil
        prunePresentation(sessionId)
        transcripts.sessions.removeAll { $0.id == sessionId }
        return true
    }

    func regenerateMacChatResponse(
        port: any MacChatTurnPresentationPort,
        target: ChatMessage,
        sessionId: String,
        syntheticPrefix: String,
        client: SwiftNativeChatOrchestrationClient,
        presentFailure: @escaping @MainActor (Error) -> Void,
        didComplete: @MainActor () -> Void
    ) async {
        guard !sessionId.isEmpty, transcripts.sessions.contains(where: { $0.id == sessionId }) else {
            port.presentMacChatTurn(.status("Regenerate failed: that chat session is no longer available"))
            return
        }
        let isSyntheticNotice = target.id.hasPrefix(syntheticPrefix)
        guard let retrySnapshot = MacChatRetrySnapshot.capture(
            target: target, messages: transcripts.messages(for: sessionId),
            sessionId: sessionId, isSyntheticNotice: isSyntheticNotice
        ) else {
            port.presentMacChatTurn(.status("Regenerate failed: that response is no longer the current retry target"))
            return
        }
        guard !retrySnapshot.inputHadAttachments else {
            port.presentMacChatTurn(.status("Regenerate can't replay this question's attachments yet. Send the question with its attachments again to retry."))
            return
        }
        guard let admission = await port.admitMacChatRetry(
            sessionId: sessionId,
            matchesCanonical: {
                let messages = try? await self.transcripts.loadMessages(sessionId: sessionId, cached: true)
                return messages.map { retrySnapshot.matchesCanonical($0) } == true
            },
            stillMatchesLocal: {
                retrySnapshot.stillMatchesLocal(self.transcripts.messages(for: sessionId))
            }
        ) else { return }
        let lifecycleIdentity = admission.identity
        await port.runAdmittedMacChatRetry(admission, operation: { [self] in
            turns.runtime.busySessions.insert(sessionId)
            defer { turns.runtime.busySessions.remove(sessionId) }
            let result: Result<ChatResponse, any Error>
            do {
                let priorText = retrySnapshot.priorUserText
                let reply = try await TurnTraceContext.$turnId.withValue(lifecycleIdentity.turnId) {
                    try await TurnRequest(message: priorText, sessionID: sessionId, surface: "chat",
                        envelope: .some(nil), verifiedSessionID: .some(nil), verifiedChatID: .some(nil),
                        verifiedUserID: .some(nil), origin: .some(retrySnapshot.priorUserOrigin)).bind {
                        try await ChatPersistenceContext.$replacementUserMessageID.withValue(
                            retrySnapshot.userRowPersisted ? retrySnapshot.priorUserMessageId : nil
                        ) {
                        // An unsaved question is saved under the id it is shown with.
                        try await ChatPersistenceContext.$pinnedUserMessageID.withValue(
                            retrySnapshot.userRowPersisted ? nil : retrySnapshot.priorUserMessageId
                        ) {
                            try await TurnRequest(
                                message: priorText, sessionID: sessionId,
                                model: "", reasoningEffort: "", attachments: [], persona: nil, surface: "chat",
                                suppressUserAppend: retrySnapshot.userRowPersisted,
                                replacementAssistantMessageID: isSyntheticNotice ? nil : target.id
                            ).bind {
                                try await client.chatExecution(message: priorText, sessionId: sessionId,
                                    model: "", reasoningEffort: "", fileAccess: "auto", attachments: [],
                                    persona: nil, surface: "chat", suppressUserAppend: retrySnapshot.userRowPersisted,
                                    progress: nil).response
                            }
                        }
                        }
                    }
                }
                result = .success(reply)
            } catch {
                turns.runtime.busySessions.remove(sessionId)
                result = .failure(error)
            }
            let settlement = await port.settleMacChatStream(identity: lifecycleIdentity, result: result)
            transcripts.settleLive(sessionId)
            // A retried notice, and the unsaved request it carried, leave once the retry's receipt is canonical.
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
        }, didComplete: didComplete)
    }
}

@MainActor
public extension NativeAgentEngine {
    /// Publish admitted stream frames through the per-session transcript owner.
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
            }
        ) { @MainActor [self, requestSessionId] snapshot, length, settled in
            try Task.checkCancellation()
            // A superseded turn stops publishing; the post-stream guard returns.
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
    /// Existing notice and tool activity converges on the lifecycle reducer;
    /// no second event bus or raw payload store is introduced.
    func receiveChatTurnActivity(_ activity: MacChatTurnActivity, port: any MacChatTurnPresentationPort) {
        guard port.applyChatTurnLifecycleInput(MacChatTurnLifecycleInput(
            identity: activity.identity,
            kind: .activity(activity),
            occurredAt: activity.occurredAt
        )) != nil else { return }

        port.presentMacChatTurn(.activity(activity))
    }

}
