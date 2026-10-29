import PersistenceCore
import Foundation
import ChatTurnRuntime
import NativeAgentShared
import AppKit
import SwiftUI
import MacControl
import NativeAgentCore
import TrustCenter
import TurnTrace
// Blueprint: | `AppModel+MacChatTurnPort.swift` | `AppModel`: `resumeMacChatTurn` reconnects checkpoint progress to the core event stream and lifecycle; `captureMacWorkContinuation`, `chatHasConversationRows`, `cancelICloudChatTurnForControlHandoff` |

extension AppModel: MacChatTurnPresentationPort {
    var macChatTurns: MacChatTurnRuntime { engine.turns.runtime }
    var knownChatSessionIDs: Set<String> { Set(engine.transcripts.sessions.map(\.id)) }

    func resumeMacChatTurn(_ checkpoint: TurnCheckpoint,
        operation: @escaping @Sendable (@escaping TurnEventSink) async throws -> Void) async throws {
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
        try await engine.transcripts.refreshMessages(sessionId: sessionId, cached: false)
    }

    func runMacChatTurnBody(
        _ text: String, attachments: [NativeAgentShared.MultimodalAttachment],
        sessionId: String, generation: Int,
        hideUserBubble: Bool, activityIdentity: MacChatTurnIdentity
    ) async {
        if activeChatSessionId.isEmpty { await loadChatState() }
        await engine.runMacChatTurnBody(
            text, attachments: attachments, sessionId: sessionId,
            generation: generation, hideUserBubble: hideUserBubble,
            activityIdentity: activityIdentity, port: self, client: macChatClient,
            missingProviderGuidance: missingProviderChatGuidance(),
            errorAdvice: UserFacingError.advice,
            finishReplyPresentation: {
                try? await Task.sleep(for: .seconds(NativeAgentMotion.standardDuration))
            }
        )
    }

    func animateMacChatMutation(_ mutation: () -> Void) {
        withAnimation(NativeAgentMotion.arrive, mutation)
    }

    func presentMacChatTurn(_ event: MacChatTurnPresentationEvent) {
        switch event {
        case .status(let message):
            statusText = message
        case .intakeClosed:
            drainPendingResidentRefreshIfTurnsIdle()
        case .activity(let activity):
            // Preserve the existing notice/toast contract; tools add no chatter.
            guard case .notice(let kind) = activity.source,
                  let text = activity.userVisibleNoticeText, !text.isEmpty else { return }
            NotificationCenter.default.post(name: .nativeAgentTurnNotice, object: nil,
                userInfo: ["kind": kind, "text": text, "sessionId": activity.identity.sessionId])
        }
    }

}
