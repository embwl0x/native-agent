import Foundation
import NativeAgentShared
import NativeAgentCore
import EngineRuntime
import Transcripts
import TurnTrace
import ChatTurnRuntime
import ChatTurnContracts
import ChatSessionWork
import ToolExecution
// Blueprint: | `AppModel+ChatActions.swift` | Chat mutations, regeneration and turn admission through `MacChatTurnCommands`. |

struct AppMutationResult: Equatable, Sendable {
    let succeeded: Bool
    let userMessage: String
    /// Preserve the raw cause for agent-facing failures while the UI stays plain.
    var cause: String?

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
    @discardableResult
    func clearActiveChatMessages(sessionId: String? = nil) async -> AppMutationResult {
        let clearingSessionID = sessionId ?? activeChatSessionId
        guard !clearingSessionID.isEmpty else {
            statusText = "Clear failed: no active chat session"
            return .failure(statusText, cause: statusCause)
        }
        var transcriptCleared = false
        // Durable truncation owes republication even if metadata or reload fails; transcript version still governs phone authority.
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
        await regenerateChatResponse(message, parent: nil)
    }

    func regenerateChatResponse(_ message: ChatMessage, parent: Turn?) async {
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
            target: message, sessionId: sessionId, parent: parent,
            syntheticPrefix: Self.syntheticErrorIDPrefix,
            client: macChatClient,
            presentFailure: { [self] in setFailureStatus($0, action: "try that again") },
            didComplete: {
                NotificationCenter.default.post(name: .chatTurnCompleted, object: sessionId)
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

    /// Nil `sessionId` targets the conversation on screen.
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

    /// Only archiving the active conversation may choose its replacement.
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
            // Only the originally active chat may clear its projection or choose a replacement; a selection during the write must survive.
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


    /// Return at turn acceptance so the composer clears its draft and attachments only after the task is installed.
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

    /// Detached panels return at acceptance or queuing so drafts do not wait for the model response.
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

    /// An accepted Mac send anchors the conversation across surfaces; publication failure must not reject an accepted message.
    @discardableResult
    func publishConversationAnchor(for acceptance: ChatTurnAcceptance, activityAt: Date = Date()) -> ChatTurnAcceptance {
        let sessionId: String
        switch acceptance {
        case .accepted(let id): sessionId = id
        case .rejected: return acceptance
        }
        publishConversationAnchor(sessionId: sessionId, conversationKind: nil, activityAt: activityAt)
        return acceptance
    }

    /// Preserve publication failures in the notice owner after chat succeeds, for both accepted sends and New Chat.
    func publishConversationAnchor(sessionId: String, conversationKind: ChatThreadKind?, activityAt: Date) {
        let dataRoot = engine.dataRoot
        Task { @MainActor in
            let result: Result<ConversationAnchor.PublishOutcome, Error> = await settle {
                do {
                    // An unreadable index fails here and reaches the notice; only a missing row is unclassified, which publish refuses.
                    let kind = try conversationKind ?? SessionConversation.checkedKind(sessionId, dataRoot: dataRoot) ?? .unclassified
                    return .success(try await ConversationAnchor.publish(sessionId: sessionId, source: "app",
                        conversationKind: kind, dataRoot: dataRoot, now: activityAt))
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
    /// Acceptance proves installation, not successful streaming; one-shot callers need rejection while mid-stream failures belong in the transcript.
    @discardableResult
    func sendChat(
        _ text: String,
        attachments: [MultimodalAttachment] = [],
        sessionId: String? = nil,
        hideUserBubble: Bool = false,
        requireIdleAndEmpty: Bool = false
    ) async -> ChatTurnAcceptance {
        let activityAt = Date()
        let started: _StartedChatTurn
        if let sessionId, !sessionId.isEmpty {
            // Fixed-session callers own their target and may send while another session is active.
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
