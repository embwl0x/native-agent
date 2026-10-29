import Foundation
import NativeAgentShared
import NativeAgentCore
import EngineRuntime
import Transcripts
import TurnTrace
import ChatTurnRuntime
import ChatSessionWork
import ToolExecution
// Blueprint: | `AppModel+ChatActions.swift` | `AppModel`: `compactSession`, `compactActiveChat`, `clearActiveChatMessages`, `regenerateAssistantMessage`, `startActiveChatTurn`, `startChatTurnForSession`; turn options from `ChatTurnRuntime/MacChatTurnCommands.swift` |

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
            do {
                try await engine.transcripts.refreshMessages(sessionId: sessionID, cached: true)
            } catch {
                ModuleLog.app("%@", "[chat] compact reload failed: \(error)")
                setFailureStatus("Chat compacted, but it couldn't reload. " + UserFacingError.advice(for: error), cause: error)
                return .failure(statusText, cause: statusCause)
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
            try await engine.clearMacChatTranscript(
                sessionId: clearingSessionID,
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
        await engine.regenerateMacChatResponse(
            port: self,
            target: message, sessionId: sessionId,
            syntheticPrefix: Self.syntheticErrorIDPrefix,
            client: macChatClient,
            serviceTier: { NativeChatTurnOptions.current(surface: "chat").serviceTier },
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
            guard try await engine.archiveMacChatTranscript(
                port: self,
                sessionId: archivingId,
                prunePresentation: { [self] sessionId in
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
                try await selectAutomaticChatSession()
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
        let activityAt = Date()
        guard let targetSessionId = readyActiveChatSessionId() else {
            return rejectChatTurn(activeChatReadinessFailureMessage())
        }
        if let expectedSessionId,
           expectedSessionId.isEmpty || expectedSessionId != targetSessionId {
            return rejectChatTurn("The active chat changed before send. Your message was not sent.")
        }
        return publishConversationAnchor(for: await startChatTurn(
            text,
            attachments: ChatAttachmentTypeResolver.submittingSpeech(attachments, text: text),
            sessionId: targetSessionId,
            hideUserBubble: false,
            requireActiveSession: true
        ).acceptance, activityAt: activityAt)
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
        let activityAt = Date()
        return publishConversationAnchor(for: await startChatTurn(
            text,
            attachments: ChatAttachmentTypeResolver.submittingSpeech(attachments, text: text),
            sessionId: sessionId,
            hideUserBubble: false,
            requireActiveSession: false
        ).acceptance, activityAt: activityAt)
    }

    /// User sent this from the Mac, so its session is now the conversation he
    /// is in — the anchor the phone, both Siris and Simple follow. Publication
    /// failure is reported separately and never fails his accepted message.
    @discardableResult
    func publishConversationAnchor(for acceptance: ChatTurnAcceptance, activityAt: Date = Date()) -> ChatTurnAcceptance {
        let sessionId: String
        switch acceptance {
        case .accepted(let id), .queued(let id, _): sessionId = id
        case .rejected: return acceptance
        }
        publishConversationAnchor(sessionId: sessionId, conversationKind: nil, activityAt: activityAt)
        return acceptance
    }

    /// Both accepted messages and New Chat settle the same publication. Keep
    /// any write failure in the existing notice owner after chat has succeeded.
    func publishConversationAnchor(sessionId: String, conversationKind: ChatThreadKind?, activityAt: Date) {
        let dataRoot = engine.dataRoot
        Task { @MainActor in
            let result: Result<ConversationAnchor.PublishOutcome, Error> = await settle {
                do {
                    return .success(try await ConversationAnchor.publish(sessionId: sessionId, source: "mac",
                        conversationKind: conversationKind ?? SessionConversation.kind(sessionId, dataRoot: dataRoot) ?? .legacy,
                        dataRoot: dataRoot, now: activityAt))
                } catch { return .failure(error) }
            }
            if case .failure(let error) = result {
                let line = "Your chat is ready, but its shared conversation couldn't be updated. Other surfaces may still open the previous conversation."
                setFailureStatus(line, cause: error)
                systemToasts.push(error: UserFacingError.forAgent(line, cause: error.localizedDescription), autoDismissAfter: nil)
            }
        }
    }

    @MainActor
    /// Returns the turn's acceptance so one-shot callers (first-run welcome)
    /// can tell a rejected send from an accepted one; ordinary callers ignore
    /// it. Acceptance means the turn was installed, not that streaming
    /// succeeded — mid-stream failures surface in the transcript, not here.
    @discardableResult
    func sendChat(_ text: String, attachments: [MultimodalAttachment] = [], sessionId: String? = nil, hideUserBubble: Bool = false, requireIdleAndEmpty: Bool = false) async -> ChatTurnAcceptance {
        let activityAt = Date()
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
        if !hideUserBubble { publishConversationAnchor(for: started.acceptance, activityAt: activityAt) }
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

}

extension AppModel {
    // MARK: Chat context / tools
    /// ChatOrchestration's canonical transcript compactor, so automatic and
    /// manual requests share validation, verified backup, durable
    /// replacement, traces, and optional distillation.
    func compactSession(
        sessionId: String,
        model: String? = nil,
        providerID: String? = nil,
        force: Bool = false
    ) async throws -> ChatSessionCompactionOutcome {
        try await engine.compactSession(
            sessionId: sessionId, model: model, providerID: providerID, force: force, client: macChatClient
        )
    }
}
