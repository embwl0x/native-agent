import Foundation
import NativeAgentCore
import PersistenceCore
import ProviderRouting
import TurnTrace

/// The ordinary chat client behind an inherited swarm worker.
public protocol SwarmChatClient: Sendable {
    var turnTraceBus: TurnTraceBus { get }
    func runSwarmToolTurn(message: String, model: String, reasoningEffort: String,
                         providerID: String?, serviceTier: String,
                         sessionID: String?, surface: String) async throws -> String
}

/// Construction stays with chat orchestration; the tool runtime supplies the
/// exact inherited tool surface, approval filer and provider assembly inputs.
public protocol SwarmChatClientFactory: Sendable {
    func makeClient(tools: any ToolDispatchClient, dataRoot: URL,
                    approvalFiler: (any ApprovalFiler)?,
                    providerLifecycleObserver: (any LLMCallLifecycleObserving)?,
                    codexAdapterFactory: (@Sendable ([String: String]?) -> any LLMAdapter)?) -> any SwarmChatClient
}
