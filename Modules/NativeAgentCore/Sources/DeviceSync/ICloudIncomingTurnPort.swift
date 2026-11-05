import Foundation
import NativeAgentShared
import ChatTurnRuntime
import NativeAgentCore
// Blueprint: | `ICloudIncomingTurnPort.swift` | Incoming phone turn engine port: resident chat, helper execution, presentation and control handoff |

/// The port presents and delivers; record meaning and input-consumption policy stay with the interpreter.
@MainActor
public protocol ICloudIncomingTurnPort: Sendable {
    func residentChatClient() -> SwiftNativeChatOrchestrationClient
    func helperReply(message: String, sessionID: String, attachments: [NativeAgentShared.MultimodalAttachment], fileAccess: String,
                     progress: TurnEventSink?, turn: Turn) async throws -> ChatResponse
    func received(in sessionID: String)
    func completed(sessionID: String?)
    func stopChatForControlHandoff(sessionID: String, messageDate: Date) async throws -> String
    func controlHandoffGeneration(sessionID: String) -> Int
    func holdsMessageAfterControlHandoff(sessionID: String, receivedAtGeneration: Int, sentAt: Date) -> Bool
    func awaitPendingChatStop(sessionID: String) async
}
