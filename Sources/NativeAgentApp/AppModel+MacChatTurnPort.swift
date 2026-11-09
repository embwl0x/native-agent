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
// Blueprint: | `AppModel+MacChatTurnPort.swift` | `AppModel`: `resumeMacChatTurn` mounts checkpoint presentation through the core session delivery owner and lifecycle without forwarding a turn sink; `captureMacWorkContinuation`, `chatHasConversationRows`, `cancelICloudChatTurnForControlHandoff` |

extension AppModel: MacChatTurnPresentationPort {
    var macChatTurns: MacChatTurnRuntime { engine.turns.runtime }
    var knownChatSessionIDs: Set<String> { Set(engine.transcripts.sessions.map(\.id)) }

    func resumeMacChatTurn(_ checkpoint: TurnCheckpoint,
        operation: @escaping @Sendable (Turn) async throws -> Void) async throws {
        try await engine.resumeMacChatTurn(checkpoint, port: self, operation: operation)
    }

    func captureMacWorkContinuation(_ text: String, taskReference: String) async -> MacWorkContinuation? {
        guard UserMessageIntentSignals.isTakeOver(text) else { return nil }
        let front = NSWorkspace.shared.frontmostApplication
        let app = PersonOnlyWindows.isOwnProcess(front?.processIdentifier) ? (NSApp.delegate as? AppDelegate)?.previousWorkApp : front
        if let refusal = await MacControlGate.continuationCaptureRefusal(dataRoot: engine.dataRoot) {
            return .unsupported(refusal, taskReference: taskReference)
        }
        guard let app, !app.isTerminated else {
            return .unsupported("previous_app_unavailable", taskReference: taskReference)
        }
        // Capture precedes turn admission; this native operation has no caller deadline.
        return await MacAccessibilityReader.captureContinuation(pid: app.processIdentifier, taskReference: taskReference,
            context: MacOperationContext(dataRoot: engine.dataRoot))
    }

    func chatHasConversationRows(sessionId: String) throws -> Bool {
        FirstRunWelcomeTransaction.hasConversationRows(
            try engine.transcripts.completeDisplayedMessages(for: sessionId), syntheticErrorIDPrefix: Self.syntheticErrorIDPrefix)
    }
    func prepareMacChatTranscript(sessionId: String) async throws {
        _ = try await engine.transcripts.loadMessages(sessionId: sessionId, cached: true)
        _ = try engine.transcripts.completeDisplayedMessages(for: sessionId)
    }

    func cancelICloudChatTurnForControlHandoff(sessionId: String) {
        _ = NativeAgentEngine.liveDeviceSync.engine.cancelActiveChatTask(for: sessionId)
    }

    func recordMacControlHandoff(text: String, reply: String, sessionId: String, turn: Turn) async throws {
        try await engine.chatClient(profile: .mac).recordControlHandoff(
            message: text, reply: reply, sessionId: sessionId, surface: "chat", turn: turn
        )
        try await engine.transcripts.refreshMessages(sessionId: sessionId, cached: false)
    }

    func saveMacArrival(_ words: String, attachments: [NativeAgentShared.MultimodalAttachment], sessionId: String, turn: Turn) async throws {
        try await macChatClient.saveArrival(message: words, sessionId: sessionId, surface: "chat", attachments: attachments,
                                            fileAccess: "auto", turn: turn)
    }

    func showMacChatUserBubble(_ text: String, attachments: [NativeAgentShared.MultimodalAttachment], sessionId: String, turn: Turn) {
        engine.showMacChatUserBubble(text, attachments: attachments, sessionId: sessionId, turn: turn, port: self)
    }

    func runMacChatTurnBody(
        _ text: String, attachments: [NativeAgentShared.MultimodalAttachment],
        sessionId: String, generation: Int,
        hideUserBubble: Bool, activityIdentity: MacChatTurnIdentity, turn: Turn
    ) async {
        if activeChatSessionId.isEmpty { await loadChatState() }
        await engine.runMacChatTurnBody(
            text, attachments: attachments, sessionId: sessionId,
            generation: generation, hideUserBubble: hideUserBubble,
            activityIdentity: activityIdentity, turn: turn, port: self, client: macChatClient,
            missingProviderGuidance: missingProviderChatGuidance(),
            errorAdvice: UserFacingError.advice,
            finishReplyPresentation: {}
        )
    }

    func animateMacChatMutation(_ mutation: () -> Void) {
        mutation()
    }

    func presentMacChatTurn(_ event: MacChatTurnPresentationEvent) {
        switch event {
        case .status(let message):
            statusText = message
        case .activity(let activity):
            // Keep tool results in the existing notice/toast contract so they do not add duplicate chatter.
            guard case .notice(let kind) = activity.source,
                  let text = activity.userVisibleNoticeText, !text.isEmpty else { return }
            NotificationCenter.default.post(name: .nativeAgentTurnNotice, object: nil,
                userInfo: ["kind": kind, "text": text, "sessionId": activity.identity.sessionId])
        }
    }

}
