import PersistenceCore
import Foundation
import ChatTurnRuntime
import NativeAgentShared
import AppKit
import MacControl
import NativeAgentCore
import TrustCenter
import TurnTrace
// Blueprint: | `AppModel+MacChatTurnPort.swift` | `AppModel`: `resumeMacChatTurn` reconnects checkpoint progress to the existing stream adapter and lifecycle; `captureMacWorkContinuation`, `chatHasConversationRows`, `cancelICloudChatTurnForControlHandoff` |

extension AppModel: MacChatTurnPresentationPort {
    var macChatTurns: MacChatTurnRuntime { engine.turns.runtime }
    var knownChatSessionIDs: Set<String> { Set(engine.transcripts.sessions.map(\.id)) }

    func resumeMacChatTurn(_ checkpoint: TurnCheckpoint,
        operation: @escaping @Sendable (@escaping ChatOrchestrationProgressHandler) async throws -> Void) async throws {
        try await engine.resumeMacChatTurn(checkpoint, port: self, operation: operation)
    }

    func captureMacWorkContinuation(_ text: String, taskReference: String) async -> MacWorkContinuation? {
        guard UserMessageIntentSignals.isTakeOver(text) else { return nil }
        let front = NSWorkspace.shared.frontmostApplication
        let app = front?.processIdentifier == getpid() ? (NSApp.delegate as? AppDelegate)?.previousWorkApp : front
        if let refusal = await MacControlGate.continuationCaptureRefusal(dataRoot: PersistenceCore.defaultDataRoot()) {
            return .unsupported(refusal, taskReference: taskReference)
        }
        guard let app, !app.isTerminated else {
            return .unsupported("previous_app_unavailable", taskReference: taskReference)
        }
        return MacAccessibilityReader.captureContinuation(pid: app.processIdentifier, taskReference: taskReference)
    }

    func chatHasConversationRows(sessionId: String) -> Bool {
        FirstRunWelcomeTransaction.hasConversationRows(
            engine.transcripts.messages(for: sessionId), syntheticErrorIDPrefix: Self.syntheticErrorIDPrefix)
    }

    func cancelICloudChatTurnForControlHandoff(sessionId: String) {
        _ = NativeAgentEngine.liveDeviceSync.engine.cancelActiveChatTask(for: sessionId)
    }

    func recordMacControlHandoff(text: String, reply: String, sessionId: String) async throws {
        try await engine.chatClient(profile: .mac).recordControlHandoff(
            message: text, reply: reply, sessionId: sessionId, surface: "chat"
        )
        let messages = try await engine.transcripts.loadMessages(sessionId: sessionId)
        engine.transcripts.setMessages(messages, for: sessionId)
    }

    func runMacChatTurnBody(
        _ text: String, attachments: [NativeAgentShared.MultimodalAttachment],
        sessionId: String, generation: Int, ctx: MacChatTurnBodyContext,
        hideUserBubble: Bool, activityIdentity: MacChatTurnIdentity
    ) async {
        if activeChatSessionId.isEmpty { await loadChatState() }
        await engine.runMacChatTurnBody(
            text, attachments: attachments, sessionId: sessionId,
            generation: generation, ctx: ctx, hideUserBubble: hideUserBubble,
            activityIdentity: activityIdentity, port: self, client: macChatClient,
            missingProviderGuidance: missingProviderChatGuidance(),
            errorAdvice: UserFacingError.advice,
            finishReplyPresentation: {
                try? await Task.sleep(for: .seconds(NativeAgentMotion.standardDuration))
            }
        )
    }

    func presentMacChatTurn(_ event: MacChatTurnPresentationEvent) {
        switch event {
        case .status(let message):
            statusText = message
        case .dropDraft(let sessionId):
            composerDraft(for: sessionId).edit("")
        case .moveDraft(let from, let to):
            if let draft = chatComposerDrafts[from] {
                composerDraft(for: to).edit(draft.text)
                draft.edit("")
            }
        case .selectMigratedSession(let sessionId):
            activeChatSessionId = sessionId
            UserDefaults.standard.set(activeChatSessionId, forKey: "activeChatSessionId")
        case .workingCommentary(let sessionId, let bubbleId, let characters):
            setChatMessageWorkingCommentary(characters, id: bubbleId, in: sessionId)
        case .clearPreview(let sessionId):
            engine.turns.screenPreviewBySession.removeValue(forKey: sessionId)
        case .movePreview(let oldSessionId, let newSessionId):
            if let carried = engine.turns.screenPreviewBySession.removeValue(forKey: oldSessionId) {
                engine.turns.screenPreviewBySession[newSessionId] = carried
            }
        case .replySettledChanged(let sessionId, let settled):
            if !settled { engine.turns.replyingSessions.remove(sessionId) }
        case .moveReplying(let oldSessionId, let newSessionId):
            if engine.turns.replyingSessions.remove(oldSessionId) != nil {
                engine.turns.replyingSessions.insert(newSessionId)
            }
        case .intakeClosed:
            drainPendingResidentRefreshIfTurnsIdle()
        case .streamFrame(let sessionId, let bubbleId, let snapshot):
            engine.turns.streamingTexts[sessionId] = snapshot
            if !snapshot.isEmpty, !engine.turns.replyingSessions.contains(sessionId) {
                engine.turns.replyingSessions.insert(sessionId)
            }
            engine.transcripts.updateMessageContent(id: bubbleId, in: sessionId, content: snapshot)
        case .activity(let activity):
            if activity.source == .toolResult { placeTurnToolRows(sessionId: activity.identity.sessionId) }
            // Preserve the existing notice/toast contract; tools add no chatter.
            guard case .notice(let kind) = activity.source,
                  let text = activity.userVisibleNoticeText, !text.isEmpty else { return }
            NotificationCenter.default.post(name: .nativeAgentTurnNotice, object: nil,
                userInfo: ["kind": kind, "text": text, "sessionId": activity.identity.sessionId])
        }
    }

    /// User, 2026-10-07: her tool rows reached the transcript only at the
    /// post-turn reload, which slid them in between his message and her
    /// finished reply — the reply jumped down a row as it landed. Each
    /// finished tool now places the turn's persisted rows where that reload
    /// puts them, under the same ids, so the reload moves nothing.
    func placeTurnToolRows(sessionId: String) {
        Task { @MainActor in
            guard let disk = try? await engine.transcripts.loadMessages(sessionId: sessionId, cached: true),
                  engine.turns.streamingSessions.contains(sessionId),
                  let bubbleId = engine.turns.streamingBubbleIds[sessionId],
                  let local = engine.transcripts.messagesBySession[sessionId],
                  let placed = ChatTurnToolPlacement.placing(disk: disk, into: local, before: bubbleId)
            else { return }
            engine.transcripts.setMessages(placed, for: sessionId)
        }
    }
}
