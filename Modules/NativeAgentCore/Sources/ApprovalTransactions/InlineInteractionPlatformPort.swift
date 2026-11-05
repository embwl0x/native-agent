import Foundation
import NativeAgentCore
import NativeAgentShared
import PersistenceCore
import ProviderRouting
import ChatToolRuntime
// Blueprint: | `InlineInteractionPlatformPort.swift` | `InlineInteractionPlatformPort`; Platform effects, resolver authority. |

/// App/platform facts and effects; card authority stays with the resolver.
@MainActor
public protocol InlineInteractionPlatformPort {
    /// The integration-status owner's permission AND checked read evidence. A projection reads it; explicit verification asks the owner to check.
    func mailReadiness(root: URL, check: Bool) async -> (status: String, word: String, next: String?)
    func chromeConnectionStatus() async -> (enabled: Bool, connected: Bool)
    var chromeSteps: String { get }
    /// Nil when the paired-phone store can't be read.
    func phoneStanding() async -> NAPhoneStanding?
    func connectorRecords(root: URL) async throws -> [InlineInteractionConnectorStatus]
    func providers() async throws -> [InlineInteractionProviderStatus]
    func cardBlockReason(_ ids: [String], mode: InlineInteraction.AccessMode?) async -> String?
    func permissionChanges() -> AsyncStream<Void>
    func openInteractionCards() async throws -> [(id: String, sessionID: String)]
    /// Ask macOS for each grant still off, in walk order, opening the first unresolved one's pane. Returns why each item is still unresolved.
    func askMacOSForCard(_ ids: [String], mode: InlineInteraction.AccessMode?) async throws -> [String]
    func writeInteractionSnapshots() async
    func refreshInteractionInbox() async
    func interactionControls() -> (any InlineInteractionControlPort)?
}

/// Capture admitted controls across suspension without coupling transactions to app assembly.
@MainActor
public protocol InlineInteractionControlPort {
    var screenCaptureEnabled: Bool { get }
    var chromeControlEnabled: Bool { get }
    var fullMacGrantIsActive: Bool { get }
    func enableChromeControl() async
    func setUpChromeControl(turn: Turn) async -> String?
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
