import Foundation
import Agents
import AppToolRuntime
import ChatOrchestration
import Cognition
import CognitiveSubstrate
import DeviceSync
import PersistenceCore
import TrustCenter

/// The agent-bridge listener an A2A peer pushes task notifications to.
public protocol EngineAgentBridgePort: Sendable {
    func a2aPushConfiguration(for peer: AgentPeerContact) async -> JSONValue?
}

/// The standing-bot runner that drains queued bot runs.
public protocol EngineStandingBotQueuePort: Sendable {
    func enqueueRun(bot: UUID) throws -> UUID
}

/// Platform hosts supplied once to Core's composition root. The factories
/// bind existing app adapters; dispatch and chat policy stay in the engine.
public struct NativeAgentEnginePorts: Sendable {
    public let cognitionHost: any CognitionHost
    public let deviceSyncHost: any DeviceSyncHost
    public let macIntegration: any MacIntegrationToolBridge
    public let agentBridge: any EngineAgentBridgePort
    public let completionSender: @Sendable (URL) -> any AgentBridgeCompletionSending
    public let standingBotQueue: any EngineStandingBotQueuePort
    public let appTools: @Sendable (SwiftNativeSecurityCenter, Bool) -> AppToolExecutor
    public let interactions: any ToolInteractionResolving
    public let chatPlatform: ChatToolPlatformPort
    public let catalogPosture: @Sendable () async -> OrganismBehaviorPosture?
    public let evolutionBridge: @Sendable (URL) -> any EvolutionToolBridge
    public let connectorActionStatuses: @Sendable () async throws -> [String: String]

    public init(
        cognitionHost: any CognitionHost,
        deviceSyncHost: any DeviceSyncHost,
        macIntegration: any MacIntegrationToolBridge,
        agentBridge: any EngineAgentBridgePort,
        completionSender: @escaping @Sendable (URL) -> any AgentBridgeCompletionSending,
        standingBotQueue: any EngineStandingBotQueuePort,
        appTools: @escaping @Sendable (SwiftNativeSecurityCenter, Bool) -> AppToolExecutor,
        interactions: any ToolInteractionResolving,
        chatPlatform: ChatToolPlatformPort,
        catalogPosture: @escaping @Sendable () async -> OrganismBehaviorPosture?,
        evolutionBridge: @escaping @Sendable (URL) -> any EvolutionToolBridge,
        connectorActionStatuses: @escaping @Sendable () async throws -> [String: String]
    ) {
        self.cognitionHost = cognitionHost
        self.deviceSyncHost = deviceSyncHost
        self.macIntegration = macIntegration
        self.agentBridge = agentBridge
        self.completionSender = completionSender
        self.standingBotQueue = standingBotQueue
        self.appTools = appTools
        self.interactions = interactions
        self.chatPlatform = chatPlatform
        self.catalogPosture = catalogPosture
        self.evolutionBridge = evolutionBridge
        self.connectorActionStatuses = connectorActionStatuses
    }
}
