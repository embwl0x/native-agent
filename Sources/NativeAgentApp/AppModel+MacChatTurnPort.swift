import Foundation
import ChatOrchestration
import NativeAgentShared
import AppKit
import MacControl
import NativeAgentCore
import TrustCenter

extension AppModel: MacChatTurnPresentationPort {
    var macChatTurns: MacChatTurnRuntime { engine.turns.runtime }
    var knownChatSessionIDs: Set<String> { Set(engine.transcripts.sessions.map(\.id)) }

    func captureMacWorkContinuation(_ text: String, taskReference: String) async -> MacWorkContinuation? {
        guard UserMessageIntentSignals.isTakeOver(text) else { return nil }
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

enum ChatTurnToolPlacement {
    /// `local` with the running turn's persisted rows placed just above the
    /// live reply, in disk order: its tool rows, and any steering message it
    /// took between them (a user row of its own run id, which splits the fold
    /// exactly as the reload will). Nil when nothing is new. The turn's rows
    /// share its run id, which the newest tool row carries; its own user row
    /// is already on screen. An approval waiting on User stays on the turn
    /// card until the reload; a mirrored card is never a tool row.
    static func placing(disk: [ChatMessage], into local: [ChatMessage], before bubbleId: String) -> [ChatMessage]? {
        guard let run = disk.last(where: { $0.role == "tool" })?.runId,
              let start = disk.firstIndex(where: { $0.runId == run }) else { return nil }
        let rows = disk[start...].filter { row in
            row.role == "tool"
                ? row.metadata?.isPendingApproval != true && row.metadata?.interactionMirror == nil
                : row.role == "user" && row.runId != run
        }
        let ids = Set(rows.map(\.id))
        // A slower read of an older file never takes rows away.
        guard !ids.isSubset(of: Set(local.map(\.id))) else { return nil }
        var placed = local.filter { !ids.contains($0.id) }
        guard let reply = placed.firstIndex(where: { $0.id == bubbleId }) else { return nil }
        placed.insert(contentsOf: rows, at: reply)
        return placed
    }
}
