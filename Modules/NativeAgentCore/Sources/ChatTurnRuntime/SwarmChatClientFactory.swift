import Foundation
import NativeAgentCore
import PersistenceCore
import ProviderRouting
import TurnTrace
import ChatTurnContracts
// Blueprint: | `SwarmChatClientFactory.swift` | `NativeSwarmChatClientFactory.makeClient` constructs the orchestration actor, whose `SwarmChatClient` conformance runs completed-required ephemeral tool turns |

struct NativeSwarmChatClientFactory: SwarmChatClientFactory {
    func makeClient(tools: any ToolDispatchClient, dataRoot: URL,
                    approvalFiler: (any ApprovalFiler)?,
                    providerLifecycleObserver: (any LLMCallLifecycleObserving)?) -> any SwarmChatClient {
        makeChatOrchestrationClient(
            tools: tools, dataRoot: dataRoot, providersRoot: dataRoot,
            approvalFiler: approvalFiler,
            providerLifecycleObserver: providerLifecycleObserver
        )
    }
}

extension SwiftNativeChatOrchestrationClient: SwarmChatClient {
    public func runSwarmToolTurn(message: String, model: String, reasoningEffort: String,
                         providerID: String?, serviceTier: String,
                         sessionID: String?, surface: String) async throws -> String {
        let response = try await LLMCallContext.$purpose.withValue("swarm") {
        try await runEphemeralToolTurn(
            message: message, model: model, reasoningEffort: reasoningEffort,
            // Her hands keep the caller's file access (same posture, same fences).
            fileAccess: ChatToolSessionContext.fileAccess ?? "auto", providerID: providerID,
            serviceTierOverride: serviceTier, verifiedSessionId: sessionID,
            requireCompleted: true, surface: surface
        )
        }
        return response.output
    }
}
