import Foundation
import ChatOrchestration
import NativeAgentShared

extension AppModel: MacChatTurnPresentationPort {
    var macChatTurns: MacChatTurnRuntime { engine.turns.runtime }
    var knownChatSessionIDs: Set<String> { Set(engine.transcripts.sessions.map(\.id)) }

    func chatHasConversationRows(sessionId: String) -> Bool {
        Self.hasConversationRows(engine.transcripts.messages(for: sessionId))
    }

    func runMacChatTurnBody(
        _ text: String, attachments: [NativeAgentShared.MultimodalAttachment],
        sessionId: String, generation: Int, ctx: MacChatTurnBodyContext,
        hideUserBubble: Bool, activityIdentity: MacChatTurnIdentity
    ) async {
        await _sendChatBody(text, attachments: attachments, sessionId: sessionId,
            generation: generation, ctx: ctx, hideUserBubble: hideUserBubble,
            activityIdentity: activityIdentity)
    }

    func presentMacChatTurn(_ event: MacChatTurnPresentationEvent) {
        switch event {
        case .status(let message):
            statusText = message
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
            updateChatMessageContent(id: bubbleId, in: sessionId, content: snapshot)
        case .activity(let activity):
            // Preserve the existing notice/toast contract; tools add no chatter.
            guard case .notice(let kind) = activity.source,
                  let text = activity.userVisibleNoticeText, !text.isEmpty else { return }
            NotificationCenter.default.post(name: .nativeAgentTurnNotice, object: nil,
                userInfo: ["kind": kind, "text": text, "sessionId": activity.identity.sessionId])
        }
    }
}
