import Foundation
import NativeAgentCore
import PersistenceCore
import ProviderRouting
import TurnTrace
import ChatTurnContracts

struct NativeSwarmChatClientFactory: SwarmChatClientFactory {
    func makeClient(tools: any ToolDispatchClient, dataRoot: URL,
                    approvalFiler: (any ApprovalFiler)?,
                    providerLifecycleObserver: (any LLMCallLifecycleObserving)?,
                    codexAdapterFactory: (@Sendable ([String: String]?) -> any LLMAdapter)?) -> any SwarmChatClient {
        NativeSwarmChatClient(client: makeChatOrchestrationClient(
            tools: tools, dataRoot: dataRoot, providersRoot: dataRoot,
            approvalFiler: approvalFiler,
            providerLifecycleObserver: providerLifecycleObserver,
            codexAdapterFactory: codexAdapterFactory
        ))
    }
}

private struct NativeSwarmChatClient: SwarmChatClient {
    let client: SwiftNativeChatOrchestrationClient
    var turnTraceBus: TurnTraceBus { client.turnTraceBus }

    func runSwarmToolTurn(message: String, model: String, reasoningEffort: String,
                         providerID: String?, serviceTier: String,
                         sessionID: String?, surface: String) async throws -> String {
        let response = try await client.runEphemeralToolTurn(
            message: message, model: model, reasoningEffort: reasoningEffort,
            fileAccess: "auto", providerID: providerID,
            serviceTierOverride: serviceTier, verifiedSessionId: sessionID,
            requireCompleted: true, surface: surface
        )
        return response.output
    }
}
