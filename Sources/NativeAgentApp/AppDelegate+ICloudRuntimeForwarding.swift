import Foundation
import NativeAgentShared
import DeviceSync
import ChatOrchestration

extension AppDelegate {
    @MainActor
    static func forwardToSwiftRuntime(_ msg: BridgeMessage) async -> Bool {
        await ICloudIncomingTurnForwarder(
            port: AppICloudIncomingTurnPort()
        ).forwardToSwiftRuntime(msg)
    }
}

/// Mac delivery and presentation; Core owns every outgoing record's meaning.
@MainActor
private struct AppICloudIncomingTurnPort: ICloudIncomingTurnPort {
    func residentChatClient() -> SwiftNativeChatOrchestrationClient {
        AppDelegate.residentIOSChatClient
    }

    func publishReply(text: String, sessionID: String?, correlationID: String,
                      metadata: [String: String], attachments: [NativeAgentShared.MultimodalAttachment]) async throws -> BridgeMessage {
        try await NativeAgentEngine.liveDeviceSync.bridge.sendChatMessage(
            text: text, sessionID: sessionID, correlationID: correlationID,
            metadata: metadata, attachments: attachments
        )
    }

    func publishProgress(text: String, sessionID: String, correlationID: String,
                         metadata: [String: String], key: String, mirrorKey: String?) async -> Bool {
        await NativeAgentEngine.liveDeviceSync.bridge.sendKVSChatProgress(
            text: text, sessionID: sessionID, correlationID: correlationID,
            metadata: metadata, key: key, mirrorKey: mirrorKey
        )
    }

    func sendICloudReplyPushNotification(text: String, sessionID: String?, correlationID: String, kind: String) async {
        await NativeAgentEngine.liveDeviceSync.relay.sendICloudReplyPushNotification(
            text: text, sessionID: sessionID, correlationID: correlationID, kind: kind
        )
    }

    func received(in sessionID: String) {
        MacChatUnreadSessions.shared.received(in: sessionID)
    }

    func completed(sessionID: String?) {
        NotificationCenter.default.post(name: .chatTurnCompleted, object: sessionID)
    }

    func signatureVerified(_ message: BridgeMessage) -> Bool {
        (try? PairingSecretManager.loadOrGenerateSecret())
            .map { message.verifySignature(secret: $0) } ?? false
    }

    func registerActiveChatTask(_ task: Task<(text: String, deltaSeq: Int, error: String?, toolEvents: Int), Never>,
                                for sessionID: String, runID: String) {
        NativeAgentEngine.liveDeviceSync.engine.registerActiveChatTask(task, for: sessionID, runID: runID)
    }

    func unregisterActiveChatTask(for sessionID: String,
                                  expecting task: Task<(text: String, deltaSeq: Int, error: String?, toolEvents: Int), Never>) {
        NativeAgentEngine.liveDeviceSync.engine.unregisterActiveChatTask(for: sessionID, expecting: task)
    }

    func requestChatSnapshotPublication(includeTranscripts: Bool) {
        NativeAgentEngine.liveDeviceSync.engine.requestChatSnapshotPublication(includeTranscripts: includeTranscripts)
    }
}
