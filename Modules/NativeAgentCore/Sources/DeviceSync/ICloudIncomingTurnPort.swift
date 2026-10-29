import Foundation
import NativeAgentShared
import ChatTurnRuntime
// Blueprint: | `ICloudIncomingTurnPort.swift` | Incoming phone turn engine port: resident chat, helper execution, presentation and control handoff |

/// Delivery and Mac presentation for the incoming-turn interpreter. The port
/// does not choose record fields, reply meaning, or input-consumption policy.
@MainActor
public protocol ICloudIncomingTurnPort: Sendable {
    func residentChatClient() -> SwiftNativeChatOrchestrationClient
    func helperReply(message: String, sessionID: String, attachments: [NativeAgentShared.MultimodalAttachment], fileAccess: String,
                     progress: TurnEventSink?) async throws -> ChatResponse
    func received(in sessionID: String)
    func completed(sessionID: String?)
    func stopChatForControlHandoff(sessionID: String, messageDate: Date) async throws -> String
    func controlHandoffGeneration(sessionID: String) -> Int
    func holdsMessageAfterControlHandoff(sessionID: String, receivedAtGeneration: Int, sentAt: Date) -> Bool
    func awaitPendingChatStop(sessionID: String) async
}
