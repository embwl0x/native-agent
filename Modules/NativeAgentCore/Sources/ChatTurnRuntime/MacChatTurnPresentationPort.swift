import Foundation
import NativeAgentShared
import MacControl
// Blueprint: | `MacChatTurnPresentationPort.swift` | `MacChatTurnPresentationPort` protocol; `chatHasConversationRows`, `captureMacWorkContinuation` |

public enum MacChatTurnPresentationEvent: Sendable {
    case status(String)
    case intakeClosed
    case activity(MacChatTurnActivity)
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
    func animateMacChatMutation(_ mutation: () -> Void)
    func presentMacChatTurn(_ event: MacChatTurnPresentationEvent)
    func recordMacControlHandoff(text: String, reply: String, sessionId: String) async throws
    func cancelICloudChatTurnForControlHandoff(sessionId: String)
    func refreshChatMessagesAfterTurn(sessionId: String, messagesAlreadyRefreshed: Bool) async
    func runMacChatTurnBody(
        _ text: String, attachments: [NativeAgentShared.MultimodalAttachment],
        sessionId: String, generation: Int,
        hideUserBubble: Bool, activityIdentity: MacChatTurnIdentity
    ) async
}
