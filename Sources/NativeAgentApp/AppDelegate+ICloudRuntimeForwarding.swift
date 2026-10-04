import Foundation
import NativeAgentShared
import DeviceSync
import ChatOrchestration
import NativeAgentCore

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

    func controlHandoffGeneration(sessionID: String) -> Int {
        NativeAgentEngine.live.turns.runtime.controlHandoffGenerations[sessionID] ?? 0
    }

    /// Waiting when a handoff landed, or sent by the phone before its handoff.
    /// Same-second stamps are not provably older, so they run.
    func holdsMessageAfterControlHandoff(sessionID: String, receivedAtGeneration: Int, sentAt: Date) -> Bool {
        let runtime = NativeAgentEngine.live.turns.runtime
        if (runtime.controlHandoffGenerations[sessionID] ?? 0) != receivedAtGeneration { return true }
        guard let handoffSentAt = runtime.phoneControlHandoffSentAt[sessionID] else { return false }
        return sentAt < handoffSentAt
    }

    func awaitPendingChatStop(sessionID: String) async {
        while let pending = NativeAgentEngine.live.turns.runtime.pendingStopWrites[sessionID] {
            await pending.value
        }
    }

    func stopChatForControlHandoff(sessionID: String, messageDate: Date) async throws -> String {
        guard let appModel = QuietSelfAdmin.shared.appModel else {
            throw NSError(domain: "NativeAgentControlHandoff", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Mac chat is not attached"])
        }
        let turns = NativeAgentEngine.live.turns
        let sync = NativeAgentEngine.liveDeviceSync
        let runID = sync.engine.activeChatRunID(for: sessionID)
        var activity = turns.lifecycle(for: sessionID)?.presentation.currentAction
        if let runID,
           let data = NSUbiquitousKeyValueStore.default.data(forKey: NativeAgentICloudBridgeConstants.KVSKey.chatProgressLatest) {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            if let progress = try? decoder.decode(BridgeMessage.self, from: data),
               progress.sessionID == sessionID, progress.correlationID == runID,
               progress.metadata?["kind"] == "tool_use", let name = progress.metadata?["toolName"] {
                activity = ToolActivityPresentation.progress(name)
            }
        }
        turns.runtime.phoneControlHandoffSentAt[sessionID] = max(
            turns.runtime.phoneControlHandoffSentAt[sessionID] ?? messageDate, messageDate
        )
        await appModel.releaseControlForHandoff(sessionId: sessionID) {
            if let runID { _ = sync.engine.cancelActiveChatTask(for: sessionID, runIDs: [runID]) }
        }
        return UserMessageIntentSignals.controlHandoffReply(lastActivity: activity)
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
