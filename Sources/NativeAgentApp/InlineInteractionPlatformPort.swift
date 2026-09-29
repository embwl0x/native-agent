import Foundation
import PersistenceCore
import ApprovalTransactions
import ChatOrchestration
import NativeAgentShared

/// Binds Core verification to the same live owners and macOS probes as the UI.
@MainActor
struct AppInlineInteractionPlatformPort: InlineInteractionPlatformPort {
    func probeAppleEventApp(_ name: String) async -> String {
        await MacIntegrationView.probeAppleEventApp(name)
    }

    func mailListRecent(input: [String: JSONValue]) async throws -> JSONValue {
        try await MacAppleScriptBridge.mailListRecent(input: input)
    }

    func chromeConnectionStatus() async -> (enabled: Bool, connected: Bool) {
        let status = await NativeAgentEngine.live.chrome.setupConnectionStatus()
        return (status.enabled, status.state == .connected)
    }

    var chromeSteps: String { InlineCardProjection.chromeSteps }

    func pairedPhoneCount() -> Int {
        NativeAgentEngine.liveDeviceSync.pairedPhones.pairedCount()
    }

    func connectorRecords(root: URL) async throws -> [InlineInteractionConnectorStatus] {
        try await NativeClient.readConnectorRecords(root: root).map {
            (id: $0.id, authState: $0.authState, healthStatus: $0.healthStatus)
        }
    }

    func providers() async throws -> [InlineInteractionProviderStatus] {
        try await NativeAgentEngine.live.providers.list().map {
            (providerID: $0.provider_id, displayName: $0.display_name,
             authState: $0.auth_status.state, defaultModel: $0.default_model,
             firstModel: $0.models.first?.id)
        }
    }

    func cardBlockReason(_ ids: [String], mode: InlineInteraction.AccessMode?) -> String? {
        SystemPermissionPreflight.cardBlockReason(ids, mode: mode)
    }
}
