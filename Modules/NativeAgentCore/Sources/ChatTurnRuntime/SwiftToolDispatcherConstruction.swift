import Foundation
import StandingBots
import Research
import CryptoKit
import NativeAgentCore
import PersistenceCore
import PersonaEngine
import MemoryV2
import MCPDispatcher
import ProviderRouting
import ToolRegistry
import TrustCenter
import KnowledgeGraph
import XConnector
import SlackConnector
import Dispatcher
import MacControl
import SwarmRuns
import MacIntegration
import ChatToolRuntime
import AgentConversations
import ChatTurnContracts

// Preserve direct construction through the ordinary orchestration factory.
extension SwiftToolDispatcher {
    public convenience init(
        dataRoot: URL = PersistenceCore.defaultDataRoot(),
        pageReader: (any ResearchClientProtocol)? = nil,
        memoryV2: SwiftNativeMemoryV2? = nil,
        knowledgeGraphPath: URL? = nil,
        allowProcessGlobalTools: Bool = true,
        swarmExecutor: (any AgentSwarmExecuting)? = nil,
        swarmProviderAssemblyObserver: (@Sendable (SwarmProviderAssembly) -> Void)? = nil,
        swarmWorkerCodexEnvironmentObserver: (@Sendable ([String: String]?) -> Void)? = nil,
        providerLifecycleObserver: (any LLMCallLifecycleObserving)? = nil,
        swarmApprovalFiler: (any ApprovalFiler)? = nil,
        macIntegrationBridge: (any MacIntegrationToolBridge)? = nil,
        macIntegrationPermissionStore: MacIntegrationPermissionStore? = nil,
        evolutionBridge: (any EvolutionToolBridge)? = nil,
        appTools: (any ToolExecutor)? = nil,
        agentBridgeConfigRoot: URL? = nil,
        a2aPushConfiguration: (@Sendable (AgentPeerContact) async -> JSONValue?)? = nil,
        codexMessageNotificationPermissionOverride: Bool? = nil,
        codexMessageWakeupHelperOverride: URL? = nil,
        codexMessageWakeupOverride: (@Sendable ([String: JSONValue]) async -> JSONValue)? = nil,
        ompMessageWakeupHelperOverride: URL? = nil,
        ompMessageWakeupOverride: (@Sendable ([String: JSONValue]) async -> JSONValue)? = nil,
        standingBotRunEnqueue: (@Sendable (UUID) throws -> UUID)? = nil,
        standingBotSession: BotRunnerSession? = nil
    ) {
        self.init(
            dataRoot: dataRoot,
            pageReader: pageReader,
            memoryV2: memoryV2,
            knowledgeGraphPath: knowledgeGraphPath,
            allowProcessGlobalTools: allowProcessGlobalTools,
            swarmExecutor: swarmExecutor,
            swarmProviderAssemblyObserver: swarmProviderAssemblyObserver,
            swarmWorkerCodexEnvironmentObserver: swarmWorkerCodexEnvironmentObserver,
            providerLifecycleObserver: providerLifecycleObserver,
            swarmApprovalFiler: swarmApprovalFiler,
            macIntegrationBridge: macIntegrationBridge,
            macIntegrationPermissionStore: macIntegrationPermissionStore,
            evolutionBridge: evolutionBridge,
            appTools: appTools,
            agentBridgeConfigRoot: agentBridgeConfigRoot,
            a2aPushConfiguration: a2aPushConfiguration,
            codexMessageNotificationPermissionOverride: codexMessageNotificationPermissionOverride,
            codexMessageWakeupHelperOverride: codexMessageWakeupHelperOverride,
            codexMessageWakeupOverride: codexMessageWakeupOverride,
            ompMessageWakeupHelperOverride: ompMessageWakeupHelperOverride,
            ompMessageWakeupOverride: ompMessageWakeupOverride,
            standingBotRunEnqueue: standingBotRunEnqueue,
            standingBotSession: standingBotSession,
            swarmChatFactory: NativeSwarmChatClientFactory()
        )
    }
}
