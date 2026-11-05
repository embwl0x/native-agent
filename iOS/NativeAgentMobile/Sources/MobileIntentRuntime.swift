import Foundation
import NativeAgentShared
// Blueprint: | `MobileIntentRuntime.swift` | `MobileIntentRuntime` enum; `prepare`, `agent` |

/// Use shared signed transport for Siri and notifications even before a scene mounts.
@MainActor
enum MobileIntentRuntime {
    private static var retainedPairing: PairingStore?

    static func prepare() throws {
        let bridge = iCloudBridge.shared
        if bridge.pairingStore == nil {
            retainedPairing = PairingStore()
            bridge.pairingStore = retainedPairing
        }
        guard let pairing = bridge.pairingStore, pairing.usesICloudTransport else {
            throw failure("Open NativeAgent and pair this iPhone with your Mac first.")
        }
        iCloudSyncEngine.shared.pairingStore = pairing
        ChatRuntimeControls.primeDeviceSourceKey()
        bridge.setup()
        guard bridge.usesCloudKitDeviceTransport else {
            throw failure("CloudKit is unavailable. Open NativeAgent to check the connection.")
        }
    }

    static func agent() async throws -> MobileAgentEntity {
        try prepare()
        await iCloudBridge.shared.deviceIncomingSetupTask?.value
        await iCloudBridge.shared.setupTask?.value
        await iCloudSyncEngine.shared.refreshLightweightSnapshots()
        let sync = iCloudSyncEngine.shared
        guard let fingerprint = AgentNameCache.fingerprint(sync.pairingStore?.iCloudPairingSecret),
              let name = AgentNameCache.name(pairing: sync.pairingStore?.iCloudPairingSecret) else {
            throw failure("Your agent's name has not synced yet. Open NativeAgent to sync with the Mac.")
        }
        return MobileAgentEntity(id: fingerprint, name: name)
    }

    static func validate(_ agent: MobileAgentEntity) async throws {
        guard try await self.agent().id == agent.id else {
            throw failure("This shortcut belongs to a different pairing. Choose your current agent.")
        }
    }

    static var phoneConversationID: String {
        // Continue the Mac's current conversation, not the last session this screen adopted.
        if let anchor = iCloudSyncEngine.shared.chatAnchor?.cleanSessionId { return anchor }
        if let pending = ChatStore.shared.locallyCreatedSessionID { return pending }
        let id = UUID().uuidString
        ChatStore.shared.markLocallyCreatedSession(id)
        return id
    }

    static func reply(to text: String, sessionID: String? = nil, timeout: TimeInterval) async throws -> String {
        try prepare()
        await iCloudBridge.shared.deviceIncomingSetupTask?.value
        await iCloudBridge.shared.setupTask?.value
        await ChatStore.shared.restorationTask?.value
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw failure("Enter a message to send.")
        }
        // Retain the first phone conversation identity before sending so another invocation cannot fork a chat while snapshots lag.
        let session = sessionID ?? phoneConversationID
        let id = UUID().uuidString
        let bridge = iCloudBridge.shared
        let waiters = ActionResponseWaiters.shared
        var result: Result<String, Error>?
        waiters.arm(id)
        let observer = bridge.observeIncomingMessages { message in
            receiveRetainedChatMessage(message)
            guard message.sender == "mac", message.correlationID == id,
                  message.sessionID == session else { return }
            let kind = message.metadata?["kind"]
            if kind == "rejection" {
                result = .failure(failure(message.metadata?["errorDetail"] ?? message.text))
            } else {
                switch MobileChatTerminal.classify(kind) {
                case .completed: result = .success(message.text)
                case .failed, .stopped:
                    result = .failure(failure(message.metadata?["errorDetail"] ?? message.text))
                case .incomplete:
                    let status = message.metadata?["status"] ?? "Reply ending is unconfirmed."
                    let words = message.text.isEmpty ? status : "\(message.text)\n\n\(status)"
                    result = .failure(failure(words))
                case nil: return
                }
            }
            waiters.signal(id)
        }
        defer {
            bridge.removeIncomingObserver(observer)
            waiters.disarm(id)
        }
        let client = MacBridgeClient()
        _ = try await client.sendMessage(text, sessionID: session, messageID: id)
        let deadline = Date().addingTimeInterval(timeout)
        while result == nil, Date() < deadline {
            try Task.checkCancellation()
            await bridge.pollIncomingNow()
            if result != nil { break }
            await waiters.wait(id, timeout: min(ChatStore.iCloudReplyNudgeFloorSeconds, max(0, deadline.timeIntervalSinceNow)))
        }
        if let result { return try result.get() }
        throw failure(
            "Your message was sent, but the Mac has not replied yet. Open NativeAgent to read the reply; running this shortcut again sends a new message.")
    }

    static func pendingApprovals() async throws -> [ApprovalRequest] {
        try prepare()
        return try await withDeliveryConsumers {
            await iCloudBridge.shared.pollIncomingNow()
            let sync = iCloudSyncEngine.shared
            await sync.refreshApprovalsSnapshot()
            guard sync.approvalsSnapshotLoaded else { throw failure("Approvals have not synced from the Mac yet.") }
            return sync.approvals.filter { $0.outcome == .pending }
        }
    }

    static func decide(id: String, approve: Bool) async throws {
        guard let row = try await pendingApprovals().first(where: { $0.id == id }) else {
            throw failure("This approval is no longer pending in the synced snapshot.")
        }
        guard ActivityScreenPresentation.canDecideRemotely(action: row.action) else {
            throw failure(ApprovalText.agentDecision)
        }
        try await withDeliveryConsumers {
            if approve { _ = try await iCloudSyncEngine.shared.approveApproval(id: id) }
            else { _ = try await iCloudSyncEngine.shared.rejectApproval(id: id) }
        }
        await iCloudSyncEngine.shared.refreshApprovalsSnapshot()
    }

    private static func withDeliveryConsumers<T>(_ operation: () async throws -> T) async rethrows -> T {
        let bridge = iCloudBridge.shared
        let messages = bridge.observeIncomingMessages { receiveRetainedChatMessage($0) }
        defer {
            bridge.removeIncomingObserver(messages)
        }
        return try await operation()
    }

    private static func receiveRetainedChatMessage(_ message: BridgeMessage) {
        // Cold intents settle through the scene's shared store; unrelated transcript rows arrive through snapshots to avoid duplicates.
        guard ChatStore.visibleStore == nil, let id = message.correlationID,
              ChatStore.shared.pendingExchanges[id] != nil else { return }
        Task { await ChatStore.shared.receiveICloudReply(message) }
    }

    nonisolated static func failure(_ message: String) -> NSError {
        NSError(domain: "NativeAgentMobileIntent", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
