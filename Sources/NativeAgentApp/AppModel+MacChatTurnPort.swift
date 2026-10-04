import Foundation
import ChatOrchestration
import NativeAgentShared
import AppKit
import MacControl
import TrustCenter

extension AppModel: MacChatTurnPresentationPort {
    var macChatTurns: MacChatTurnRuntime { engine.turns.runtime }
    var knownChatSessionIDs: Set<String> { Set(engine.transcripts.sessions.map(\.id)) }

    func captureMacWorkContinuation(_ text: String, taskReference: String) async -> MacWorkContinuation? {
        let request = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard request.range(of: #"^(?:please )?(?:(?:can|could|will|would) you )?(?:please )?take over(?:$|[\s,:.!?])"#,
                            options: .regularExpression) != nil else { return nil }
        let front = NSWorkspace.shared.frontmostApplication
        let app = front?.processIdentifier == getpid() ? (NSApp.delegate as? AppDelegate)?.previousWorkApp : front
        do {
            let snapshot = try await SwiftNativeTrustCenter(dataRoot: NativeAgentPaths.dataRoot).loadAuthorizationSnapshotChecked()
            let authority = SwiftNativeSecurityCenter.fullMacYoloAuthority(tool: "mac_control",
                surface: "chat", originTrusted: true, snapshot: snapshot)
            let policy = MacControlGate.policyForAdmittedFullMac(
                MacControlPolicy.fromTrustPolicyObject(snapshot.policy), admitted: authority.state == .admitted)
            guard MacControlGate.fullMacActive(policy.trustPolicy ?? MacControlTrustPolicy()),
                  MacControlGate.gate(policy, category: "accessibility", trigger: "user").allowed else {
                return .unsupported("accessibility_read_not_authorized", taskReference: taskReference)
            }
        } catch {
            return .unsupported("trust_policy_unavailable", taskReference: taskReference)
        }
        guard let app, !app.isTerminated else {
            return .unsupported("previous_app_unavailable", taskReference: taskReference)
        }
        return MacAccessibilityReader.captureContinuation(pid: app.processIdentifier, taskReference: taskReference)
    }

    func chatHasConversationRows(sessionId: String) -> Bool {
        Self.hasConversationRows(engine.transcripts.messages(for: sessionId))
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
