import Foundation
import NativeAgentShared
import PersistenceCore
import ProviderRouting
import ChatOrchestration

/// App/platform facts and effects; card authority stays with the resolver.
@MainActor
public protocol InlineInteractionPlatformPort {
    func probeAppleEventApp(_ name: String) async -> String
    func mailListRecent(input: [String: JSONValue]) async throws -> JSONValue
    func chromeConnectionStatus() async -> (enabled: Bool, connected: Bool)
    var chromeSteps: String { get }
    func pairedPhoneCount() async -> Int
    func connectorRecords(root: URL) async throws -> [InlineInteractionConnectorStatus]
    func providers() async throws -> [InlineInteractionProviderStatus]
    func cardBlockReason(_ ids: [String], mode: InlineInteraction.AccessMode?) async -> String?
    func permissionChanges() -> AsyncStream<Void>
    /// Every card still open in the inbox, with the session it belongs to.
    func openInteractionCards() async -> [(id: String, sessionID: String)]
    func askMacOSForCard(_ ids: [String], mode: InlineInteraction.AccessMode?) async -> Bool
    func writeInteractionSnapshots() async
    func refreshInteractionInbox() async
    func postInteractionBanner(title: String, body: String, sessionID: String) async
    func residentWakeHeld(sessionID: String, dataRoot: URL) -> Bool
    func routeInteractionAttention(id: String, title: String, body: String) async throws
    var telegramApprovalFiler: TelegramApprovalFiler? { get }
    /// The Mac's live controls, for a door that answers a card away from it.
    func interactionControls() -> (any InlineInteractionControlPort)?
}

/// A captured app door into existing connector, routing and Trust owners.
/// The capture keeps an asynchronous card action bound to the controls that
/// admitted it, without making the transaction owner depend on app assembly.
@MainActor
public protocol InlineInteractionControlPort {
    var screenCaptureEnabled: Bool { get }
    var chromeControlEnabled: Bool { get }
    var fullMacGrantIsActive: Bool { get }
    func enableChromeControl() async
    func setUpChromeControl() async -> String?
    func saveConnectorCredentials(connector: String, values: [String: String], dataRoot: URL) async -> (error: String?, note: String?)
    func saveProviderCredential(provider: String, value: String) async -> (error: String?, note: String?)
    func signInProvider(_ signIn: InlineInteractionRegistry.ProviderSignIn, dataRoot: URL) async -> String?
    func grantMacControlCategories(_ categories: [String], dataRoot: URL, logTag: String) async
    func grantCapabilityFlag(policyKey: String, dataRoot: URL, logTag: String) async
    func saveProviderGroupSelection(group: ProviderSurfaceGroup, providerID: String?, model: String) async throws
}

public typealias InlineInteractionConnectorStatus = (
    id: String, authState: String?, healthStatus: String?
)

public typealias InlineInteractionProviderStatus = (
    providerID: String, displayName: String, authState: String, eligible: Bool,
    defaultModel: String?, firstModel: String?
)
