import Foundation
import os
import Observation
import Darwin
import AppKit
@preconcurrency import EventKit
import SwiftUI
import NativeAgentShared
import PersistenceCore
import Transcripts
import TurnTrace
import NativeAgentCore
import MemoryV2
import ToolRegistry
import KnowledgeGraph
import XConnector
import SlackConnector
import ProviderRouting
import BackgroundLoops
import ApprovalInbox
import MCPDispatcher
import ToolExecution
import PersonaEngine
import ChatOrchestration
import TrustCenter
import DreamREMCycle
import DoctorChecks
import SelfImprovement
import Research
import MultimodalTTS
import TriggerScheduler
import WorkshopExecution
import NotificationInbox
import SystemOps
import ScreenVision
import TelegramBot
import Dispatcher
import MacControl
import Onboarding
import MacAssistantStatus
import WorkflowOrchestration
import Skills
import Connectors
import Browser
import DeviceSync

struct AppMutationResult: Equatable, Sendable {
    let succeeded: Bool
    let userMessage: String
    /// The raw error behind a plain failure line; the agent's result keeps it.
    var cause: String?

    /// What the agent's tool result says: the same line plus the raw cause.
    var agentMessage: String { UserFacingError.forAgent(userMessage, cause: cause) }

    static func success(_ message: String) -> Self {
        Self(succeeded: true, userMessage: message)
    }

    static func failure(_ message: String, cause: String? = nil) -> Self {
        Self(succeeded: false, userMessage: message, cause: cause)
    }
}

@MainActor
extension AppModel {
    func compactActiveChat() async -> AppMutationResult {
        guard !activeChatSessionId.isEmpty else {
            return .failure("No active session to compact")
        }
        let sessionID = activeChatSessionId
        do {
            let outcome = try await compactSession(
                sessionId: sessionID,
                model: chatModel,
                providerID: chatProvider,
                force: true
            )
            if let failure = ContextFillCompactionPresentation.failureMessage(for: outcome) {
                statusText = failure
                return .failure(failure)
            }
            let lifecycleBeforeReload = engine.turns.lifecycle(for: sessionID)
            let messagesBeforeReload = engine.transcripts.messages(for: sessionID)
            let messages: [ChatMessage]
            do {
                messages = try await engine.transcripts.loadMessages(sessionId: sessionID, cached: true)
            } catch {
                ModuleLog.app("%@", "[chat] compact reload failed: \(error)")
                setFailureStatus("Chat compacted, but it couldn't reload. " + UserFacingError.advice(for: error), cause: error)
                return .failure(statusText, cause: statusCause)
            }
            let lifecycleAfterReload = engine.turns.lifecycle(for: sessionID)
            if !engine.turns.streamingSessions.contains(sessionID),
               lifecycleAfterReload == lifecycleBeforeReload,
               engine.transcripts.messages(for: sessionID) == messagesBeforeReload {
                engine.transcripts.setMessages(messages, for: sessionID)
            }
            statusText = "Session compacted"
            return .success(statusText)
        } catch {
            setFailureStatus(error, action: "compact this chat")
            return .failure(statusText, cause: statusCause)
        }
    }

    @discardableResult
    func clearActiveChatMessages(sessionId: String? = nil) async -> AppMutationResult {
        let clearingSessionID = sessionId ?? activeChatSessionId
        guard !clearingSessionID.isEmpty else {
            statusText = "Clear failed: no active chat session"
            return .failure(statusText, cause: statusCause)
        }
        var transcriptCleared = false
        // Durable truncation owes republication even when metadata or reload
        // fails; the transcript version still governs phone authority.
        defer {
            if transcriptCleared {
                NativeAgentEngine.liveDeviceSync.engine.requestChatTranscriptSnapshotPublication()
            }
        }
        do {
            try await clearMacChatTranscript(
                sessionId: clearingSessionID,
                clear: { [transcripts = engine.transcripts] in try await transcripts.clear(sessionId: $0) },
                didTruncate: { $0 is ChatMessageClearError },
                didClear: { transcriptCleared = true }
            )
            statusText = "Chat messages cleared"
            publishChatSnapshot()
            return .success(statusText)
        } catch let error as ChatMessageClearError {
            switch error {
            case .transcriptClearedMetadataNotSaved:
                ModuleLog.app("%@", "[chat] clear: \(error.localizedDescription)")
                setFailureStatus("Messages were cleared, but the chat list didn't save. Try again in a moment.", cause: error)
            case .transcriptVersionExhausted:
                statusText = error.localizedDescription
            }
            publishChatSnapshot()
            return .failure(statusText, cause: statusCause)
        } catch {
            if transcriptCleared { ModuleLog.app("%@", "[chat] reload after clear failed: \(error)") }
            setFailureStatus(transcriptCleared
                ? "Messages were cleared, but the chat couldn't reload. " + UserFacingError.advice(for: error)
                : UserFacingError.message(error, action: "clear this chat"), cause: error)
            return .failure(statusText, cause: statusCause)
        }
    }

    @MainActor
    func regenerateAssistantMessage(_ message: ChatMessage) async {
        if message.metadata?.providerRefusal == true {
            if message.metadata?.providerRefusalDraft == true {
                prepareRejectedTurnDraft(message)
            } else {
                statusText = "outcome unknown — inspect before retry. This rejected turn may have run steps."
            }
            return
        }
        let sessionId = message.sessionId ?? activeChatSessionId
        await regenerateMacChatResponse(
            target: message, sessionId: sessionId,
            syntheticPrefix: Self.syntheticErrorIDPrefix,
            client: macChatClient,
            serviceTier: { NativeChatTurnOptions.current(surface: "chat").serviceTier },
            makeReplacement: { output, runId in
                ChatMessage(sessionId: sessionId, role: "assistant", content: output, runId: runId)
            },
            presentFailure: { [self] in setFailureStatus($0, action: "try that again") },
            didComplete: {
                NotificationCenter.default.post(
                    name: .chatTurnCompleted, object: sessionId,
                    userInfo: ["messagesAlreadyRefreshed": true]
                )
            }
        )
    }

    @MainActor
    func prepareRejectedTurnDraft(_ message: ChatMessage) {
        let sessionId = message.sessionId ?? activeChatSessionId
        guard message.metadata?.providerRefusalDraft == true,
              sessionId == activeChatSessionId,
              let snapshot = MacChatRetrySnapshot.capture(
                target: message,
                messages: engine.transcripts.messages(for: sessionId),
                sessionId: sessionId,
                isSyntheticNotice: false
              ) else {
            statusText = "Retry draft unavailable: open the original conversation."
            return
        }
        guard !snapshot.inputHadAttachments else {
            statusText = "Retry draft needs its original attachment; attach it again before sending."
            return
        }
        NotificationCenter.default.post(name: .chatFlushLiveDrafts, object: nil)
        guard chatDraft(for: sessionId).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            statusText = "The composer already has a draft; clear it before using Retry draft."
            return
        }
        injectChatDraft(snapshot.priorUserText, sessionId: sessionId)
        statusText = "Retry draft ready. Choose another configured model in the chat model picker, then send."
    }

    @MainActor
    func addMemoryFact(_ text: String) async -> AppMutationResult {
        do {
            try await macChatTurns.storeMacChatMemoryFact(text)
            statusText = "Memory saved"
            return .success(statusText)
        } catch {
            setFailureStatus(error, action: "save that to memory")
            return .failure(statusText, cause: statusCause)
        }
    }

    func addNote(_ text: String) async -> AppMutationResult {
        do {
            try await macChatTurns.storeMacChatNote(text)
            statusText = "Note committed"
            return .success(statusText)
        } catch {
            setFailureStatus(error, action: "save that note")
            return .failure(statusText, cause: statusCause)
        }
    }

    /// `sessionId` nil writes into the conversation on screen.
    func writeScratch(key: String, value: String, sessionId: String? = nil) async -> AppMutationResult {
        do {
            let sessionId = sessionId ?? (activeChatSessionId.isEmpty ? nil : activeChatSessionId)
            let outcome = try await macChatTurns.writeMacChatScratch(key: key, value: value, sessionId: sessionId)
            statusText = outcome.message
            return outcome.succeeded ? .success(statusText) : .failure(statusText, cause: statusCause)
        } catch {
            setFailureStatus(error, action: "write that scratch note")
            return .failure(statusText, cause: statusCause)
        }
    }

    /// Archives the chat on screen, or `sessionId` when the agent names one
    /// (chat_session); only the chat on screen chooses a replacement.
    @MainActor
    @discardableResult
    func archiveActiveChat(sessionId: String? = nil) async -> AppMutationResult {
        let archivingId = sessionId ?? activeChatSessionId
        guard !archivingId.isEmpty else {
            statusText = "Archive failed: no active chat session"
            return .failure(statusText, cause: statusCause)
        }
        do {
            guard try await archiveMacChatTranscript(
                sessionId: archivingId,
                archive: { [transcripts = engine.transcripts] in try await transcripts.archive(id: $0) },
                prunePresentation: { [self] sessionId in
                    engine.turns.streamingTexts[sessionId] = nil
                    engine.turns.streamingBubbleIds[sessionId] = nil
                    engine.turns.streamingUserTurnIds[sessionId] = nil
                    engine.turns.streamingUserTurnTexts[sessionId] = nil
                    pruneSessionChatState(sessionId)
                }
            ) else {
                statusText = "Archive failed: that chat session is no longer available"
                return .failure(statusText, cause: statusCause)
            }
            // Do not redirect or erase a chat the user selected while the
            // archival write was in flight. Only the originally active chat
            // chooses a replacement and clears its active projection.
            if activeChatSessionId == archivingId {
                chatSelectionGeneration += 1
                activeChatSessionId = ""
                persistActiveChatSessionID(nil)
                if let replacement = engine.transcripts.sessions.first(where: { $0.archived != true }) {
                    await selectChatSession(replacement)
                }
            }
            statusText = "Chat archived"
            publishChatSnapshot()
            return .success(statusText)
        } catch {
            setFailureStatus(error, action: "archive this chat")
            return .failure(statusText, cause: statusCause)
        }
    }

    typealias ChatTurnAcceptance = MacChatTurnAcceptance
    typealias _StartedChatTurn = MacChatStartedTurn


    /// Accept a turn for the currently visible chat without waiting for the
    /// model response. The composer uses this transaction boundary so it only
    /// clears its draft and attachments after the task is actually installed.
    @MainActor
    func startActiveChatTurn(
        _ text: String,
        attachments: [MultimodalAttachment] = [],
        expectedSessionId: String? = nil
    ) async -> ChatTurnAcceptance {
        guard let targetSessionId = readyActiveChatSessionId() else {
            return rejectChatTurn(activeChatReadinessFailureMessage())
        }
        if let expectedSessionId,
           expectedSessionId.isEmpty || expectedSessionId != targetSessionId {
            return rejectChatTurn("The active chat changed before send. Your message was not sent.")
        }
        return publishConversationAnchor(for: await startChatTurn(
            text,
            attachments: attachments,
            sessionId: targetSessionId,
            hideUserBubble: false,
            requireActiveSession: true
        ).acceptance)
    }

    /// Fixed-session acceptance boundary for detached chat panels. Like the
    /// active composer boundary, this returns as soon as the turn is started
    /// or queued; it does not keep the draft visible until the model finishes.
    @MainActor
    func startChatTurnForSession(
        _ text: String,
        attachments: [MultimodalAttachment] = [],
        sessionId: String
    ) async -> ChatTurnAcceptance {
        publishConversationAnchor(for: await startChatTurn(
            text,
            attachments: attachments,
            sessionId: sessionId,
            hideUserBubble: false,
            requireActiveSession: false
        ).acceptance)
    }

    /// User sent this from the Mac, so its session is now the conversation he
    /// is in — the anchor the phone, both Siris and Simple follow. Best-effort
    /// like every publisher: a failed publish never fails his message.
    @discardableResult
    func publishConversationAnchor(for acceptance: ChatTurnAcceptance) -> ChatTurnAcceptance {
        let sessionId: String
        switch acceptance {
        case .accepted(let id), .queued(let id, _): sessionId = id
        case .rejected: return acceptance
        }
        Task.detached {
            _ = try? await ConversationAnchor.publish(
                sessionId: sessionId, source: "mac", conversationKind: .direct
            )
        }
        return acceptance
    }

    @MainActor
    // PATCH-2026-05-06: multimodal-ui Sprint 3 — sendChat now accepts optional attachments
    // PATCH-2026-05-08: wave2-chat-ux — wraps body in cancellable Task, sets isChatStreaming
    // PATCH-2026-05-13: parallel-sessions — guard and bookkeep per-session
    /// Returns the turn's acceptance so one-shot callers (first-run welcome)
    /// can tell a rejected send from an accepted one; ordinary callers ignore
    /// it. Acceptance means the turn was installed, not that streaming
    /// succeeded — mid-stream failures surface in the transcript, not here.
    @discardableResult
    func sendChat(_ text: String, attachments: [MultimodalAttachment] = [], sessionId: String? = nil, hideUserBubble: Bool = false, requireIdleAndEmpty: Bool = false) async -> ChatTurnAcceptance {
        let started: _StartedChatTurn
        if let sessionId, !sessionId.isEmpty {
            // Fixed-session callers (detached windows, first-run greeting) own
            // their target identity and may legitimately send while another
            // session is active.
            started = await startChatTurn(
                text,
                attachments: attachments,
                sessionId: sessionId,
                hideUserBubble: hideUserBubble,
                requireActiveSession: false,
                requireIdleAndEmpty: requireIdleAndEmpty
            )
        } else {
            guard let targetSessionId = readyActiveChatSessionId() else {
                return rejectChatTurn(activeChatReadinessFailureMessage())
            }
            started = await startChatTurn(
                text,
                attachments: attachments,
                sessionId: targetSessionId,
                hideUserBubble: hideUserBubble,
                requireActiveSession: true,
                requireIdleAndEmpty: requireIdleAndEmpty
            )
        }
        if !hideUserBubble { publishConversationAnchor(for: started.acceptance) }
        await started.task?.value
        return started.acceptance
    }

    @MainActor
    private func readyActiveChatSessionId() -> String? {
        let sessionId = activeChatSessionId
        guard !sessionId.isEmpty,
              engine.transcripts.sessions.contains(where: { $0.id == sessionId })
        else { return nil }
        return sessionId
    }

    @MainActor
    private func activeChatReadinessFailureMessage() -> String {
        if engine.transcripts.sessionTransactions.loadInFlight || engine.transcripts.sessions.isEmpty {
            return "Chat is still starting. Your message was not sent."
        }
        return "No active chat session. Your message was not sent."
    }

    @MainActor
    private func rejectChatTurn(_ message: String) -> ChatTurnAcceptance {
        statusText = message
        return .rejected(message: message)
    }

    static let syntheticErrorIDPrefix = MacChatTurnRuntime.syntheticErrorIDPrefix

    func isCompletedAssistant(_ message: ChatMessage?) -> Bool {
        MacChatTurnRuntime.isCompletedAssistant(message)
    }
}

extension AppModel: MacChatTurnTranscriptPort {
    var macChatSessionRows: [ChatSession] {
        get { engine.transcripts.sessions }
        set { engine.transcripts.sessions = newValue }
    }

    var macChatMessageRows: [String: [ChatMessage]] {
        get { engine.transcripts.messagesBySession }
        set { engine.transcripts.messagesBySession = newValue }
    }

    func loadMacChatMessages(sessionId: String, cached: Bool) async throws -> [ChatMessage] {
        try await engine.transcripts.loadMessages(sessionId: sessionId, cached: cached)
    }

    func loadMacChatSessions() async throws -> [ChatSession] {
        try await engine.transcripts.listForPresentation()
    }

    func appendMacChatMessage(_ message: ChatMessage, to sessionId: String) {
        appendChatMessage(message, to: sessionId)
    }
}
