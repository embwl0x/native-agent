import Foundation
import NativeAgentCore
import NativeAgentShared
import MacControl
// Blueprint: | `MacChatTurnPresentationPort.swift` | `MacChatTurnPresentationPort` protocol; `chatHasConversationRows`, `captureMacWorkContinuation` |

public enum MacChatTurnPresentationEvent: Sendable {
    case status(String)
    case activity(MacChatTurnActivity)
}

/// The turn's body owner supplies transcript and status publication at transaction boundaries; tokens use the stream port.
@MainActor
public protocol MacChatTurnPresentationPort: AnyObject, Sendable {
    var macChatTurns: MacChatTurnRuntime { get }
    var activeChatSessionId: String { get }
    var knownChatSessionIDs: Set<String> { get }
    func chatHasConversationRows(sessionId: String) throws -> Bool
    func prepareMacChatTranscript(sessionId: String) async throws
    func captureMacWorkContinuation(_ text: String, taskReference: String) async -> MacWorkContinuation?
    func animateMacChatMutation(_ mutation: () -> Void)
    func presentMacChatTurn(_ event: MacChatTurnPresentationEvent)
    func recordMacControlHandoff(text: String, reply: String, sessionId: String, turn: Turn) async throws
    func cancelICloudChatTurnForControlHandoff(sessionId: String)
    /// Save a send before it is accepted: its row (files included) and its checkpoint, so a relaunch before it is answered resumes it.
    func saveMacArrival(_ words: String, attachments: [NativeAgentShared.MultimodalAttachment], sessionId: String, turn: Turn) async throws
    /// The person's row while the agent works, under the id the turn pins, so the turn that writes it later shows no second one.
    func showMacChatUserBubble(_ text: String, attachments: [NativeAgentShared.MultimodalAttachment], sessionId: String, turn: Turn)
    func runMacChatTurnBody(
        _ text: String, attachments: [NativeAgentShared.MultimodalAttachment],
        sessionId: String, generation: Int,
        hideUserBubble: Bool, activityIdentity: MacChatTurnIdentity, turn: Turn
    ) async
}
