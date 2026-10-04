import Foundation
import NativeAgentShared
import MacControl

public enum MacChatTurnPresentationEvent: Sendable {
    case status(String)
    case clearPreview(String)
    case movePreview(from: String, to: String)
    case moveReplying(from: String, to: String)
    case replySettledChanged(sessionId: String, settled: Bool)
    case intakeClosed
    case activity(MacChatTurnActivity)
    case streamFrame(sessionId: String, bubbleId: String, text: String)
}

/// The app supplies selection and presentation only. Core calls this port at
/// the original transaction boundaries; token snapshots use the stream port.
@MainActor
public protocol MacChatTurnPresentationPort: AnyObject, Sendable {
    var macChatTurns: MacChatTurnRuntime { get }
    var activeChatSessionId: String { get }
    var knownChatSessionIDs: Set<String> { get }
    func chatHasConversationRows(sessionId: String) -> Bool
    func captureMacWorkContinuation(_ text: String, taskReference: String) async -> MacWorkContinuation?
    func presentMacChatTurn(_ event: MacChatTurnPresentationEvent)
    func recordMacControlHandoff(text: String, reply: String, sessionId: String) async throws
    func cancelICloudChatTurnForControlHandoff(sessionId: String)
    func runMacChatTurnBody(
        _ text: String, attachments: [NativeAgentShared.MultimodalAttachment],
        sessionId: String, generation: Int, ctx: MacChatTurnBodyContext,
        hideUserBubble: Bool, activityIdentity: MacChatTurnIdentity
    ) async
}
