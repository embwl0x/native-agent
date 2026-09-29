import Foundation
import NativeAgentShared
import PersistenceCore

/// Live app/platform facts used by the transaction owner's verification.
/// These reads do not settle a card or own its continuation.
@MainActor
public protocol InlineInteractionPlatformPort {
    func probeAppleEventApp(_ name: String) async -> String
    func mailListRecent(input: [String: JSONValue]) async throws -> JSONValue
    func chromeConnectionStatus() async -> (enabled: Bool, connected: Bool)
    var chromeSteps: String { get }
    func pairedPhoneCount() -> Int
    func connectorRecords(root: URL) async throws -> [InlineInteractionConnectorStatus]
    func providers() async throws -> [InlineInteractionProviderStatus]
    func cardBlockReason(_ ids: [String], mode: InlineInteraction.AccessMode?) -> String?
}

public typealias InlineInteractionConnectorStatus = (
    id: String, authState: String?, healthStatus: String?
)

public typealias InlineInteractionProviderStatus = (
    providerID: String, displayName: String, authState: String,
    defaultModel: String?, firstModel: String?
)
