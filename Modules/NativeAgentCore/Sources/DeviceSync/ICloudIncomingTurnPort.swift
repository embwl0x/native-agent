import Foundation
import NativeAgentShared
import ChatOrchestration

/// Delivery and Mac presentation for the incoming-turn interpreter. The port
/// does not choose record fields, reply meaning, or input-consumption policy.
@MainActor
public protocol ICloudIncomingTurnPort: Sendable {
    func residentChatClient() -> SwiftNativeChatOrchestrationClient
    func publishReply(text: String, sessionID: String?, correlationID: String,
                      metadata: [String: String], attachments: [NativeAgentShared.MultimodalAttachment]) async throws -> BridgeMessage
    func publishProgress(text: String, sessionID: String, correlationID: String,
                         metadata: [String: String], key: String, mirrorKey: String?) async -> Bool
    func sendICloudReplyPushNotification(text: String, sessionID: String?, correlationID: String, kind: String) async
    func received(in sessionID: String)
    func completed(sessionID: String?)
    func signatureVerified(_ message: BridgeMessage) -> Bool
    func registerActiveChatTask(_ task: Task<(text: String, deltaSeq: Int, error: String?, toolEvents: Int), Never>,
                                for sessionID: String, runID: String)
    func unregisterActiveChatTask(for sessionID: String,
                                  expecting task: Task<(text: String, deltaSeq: Int, error: String?, toolEvents: Int), Never>)
    func requestChatSnapshotPublication(includeTranscripts: Bool)
}

extension ICloudIncomingTurnPort {
    func sendChatMessage(text: String, sessionID: String?, correlationID: String,
                         metadata: [String: String], attachments: [NativeAgentShared.MultimodalAttachment] = []) async throws -> BridgeMessage {
        try await publishReply(text: text, sessionID: sessionID, correlationID: correlationID,
                               metadata: metadata, attachments: attachments)
    }

    func sendKVSChatProgress(text: String, sessionID: String, correlationID: String,
                             metadata: [String: String],
                             key: String = NativeAgentICloudBridgeConstants.KVSKey.chatProgressLatest,
                             mirrorKey: String? = nil) async -> Bool {
        await publishProgress(text: text, sessionID: sessionID, correlationID: correlationID,
                              metadata: metadata, key: key, mirrorKey: mirrorKey)
    }
}
