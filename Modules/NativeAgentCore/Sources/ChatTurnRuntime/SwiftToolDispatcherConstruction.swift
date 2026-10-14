import Foundation
import StandingBots
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
        memoryV2: SwiftNativeMemoryV2? = nil,
        knowledgeGraphPath: URL? = nil,
        allowProcessGlobalTools: Bool = true,
        swarmExecutor: (any AgentSwarmExecuting)? = nil,
        providerLifecycleObserver: (any LLMCallLifecycleObserving)? = nil,
        swarmApprovalFiler: (any ApprovalFiler)? = nil,
        macIntegrationBridge: (any MacIntegrationToolBridge)? = nil,
        macIntegrationPermissionStore: MacIntegrationPermissionStore? = nil,
        appTools: (any ToolExecutor)? = nil,
        agentBridgeConfigRoot: URL? = nil,
        a2aPushConfiguration: (@Sendable (AgentPeerContact) async -> JSONValue?)? = nil,
        standingBotRunEnqueue: (@Sendable (UUID, String?) throws -> BotRunReceipt)? = nil,
        standingBotSession: BotRunnerSession? = nil
    ) {
        self.init(
            dataRoot: dataRoot,
            memoryV2: memoryV2,
            knowledgeGraphPath: knowledgeGraphPath,
            allowProcessGlobalTools: allowProcessGlobalTools,
            swarmExecutor: swarmExecutor,
            providerLifecycleObserver: providerLifecycleObserver,
            swarmApprovalFiler: swarmApprovalFiler,
            macIntegrationBridge: macIntegrationBridge,
            macIntegrationPermissionStore: macIntegrationPermissionStore,
            appTools: appTools,
            agentBridgeConfigRoot: agentBridgeConfigRoot,
            a2aPushConfiguration: a2aPushConfiguration,
            standingBotRunEnqueue: standingBotRunEnqueue,
            standingBotSession: standingBotSession,
            swarmChatFactory: NativeSwarmChatClientFactory()
        )
    }
}
