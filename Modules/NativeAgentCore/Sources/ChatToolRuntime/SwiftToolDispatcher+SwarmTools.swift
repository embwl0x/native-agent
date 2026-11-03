import Foundation
import NativeAgentCore
import NativeAgentShared
import PersistenceCore
import MemoryV2
import PersonaEngine
import ProviderRouting
import ToolRegistry
import TrustCenter
import Dispatcher
import MacControl
import Context
import SwarmRuns
import WorkshopExecution
// Blueprint: | `SwiftToolDispatcher+SwarmTools.swift` | `impl_agent_swarm` checks Trust authority, binds one authenticated requestedBy origin and the checked Work route, and reads OpenRouter efforts from its own catalog before fan-out |

// MARK: - Agent swarm tools

extension SwiftToolDispatcher {
    func impl_agent_swarm(input: [String: JSONValue], surface: String) async throws -> JSONValue {
        var body = input
        // The dispatcher supplies the authenticated origin. A model-provided
        // origin must never reclassify Telegram/Slack/iOS work as local Mac.
        // requestedBy is the sole origin consumed by the request owner.
        body["requestedBy"] = .string(surface)
        let trust = SwiftNativeTrustCenter(dataRoot: dataRoot)
        let policyJSON = try await trust.loadTrustPolicyChecked()
        var policy = AgentSwarmPolicy.fromTrustPolicy(.object(policyJSON))
        let router = SwiftNativeProviderRouting(dataRoot: dataRoot)
        let providerSnapshot = try await router.checkedProviderSnapshot()
        let routingSnapshot = providerSnapshot.routing
        let routing = try routingSnapshot.routeAdmission(for: "swarms", choice: nil)
        policy.defaultModel = routing.modelId
        policy.defaultReasoningEffort = routing.reasoningEffort
        guard let providerID = routing.providerId else { throw ProviderRoutingError.providerNotFound }
        guard let provider = providerSnapshot.providers.first(where: { $0.id == providerID }), provider.configured == true else {
            throw ProviderRoutingError.configurationFailed("Work's account is unavailable. Repair it in Providers before starting helpers.")
        }
        policy.supportedReasoningEfforts = try SwiftNativeProviderRouting.modelReasoningEfforts(
            provider: provider, modelID: policy.defaultModel)
        // The checked provider/account belongs to the fan-out; requested models cannot redirect it.
        let executor = makeAgentSwarmExecutor(
            router: router,
            routing: routing,
            providerLifecycleObserver: providerLifecycleObserver
        )
        // Child effort is filled by the parsed worker/run, never an ambient
        // parent call's reasoning depth.
        return try await LLMCallContext.$reasoningEffort.withValue(nil) {
            try await executor.runTool(input: body, policy: policy)
        }
    }

    private func makeAgentSwarmExecutor(
        router: SwiftNativeProviderRouting,
        routing: TurnRouteAdmission,
        providerLifecycleObserver: (any LLMCallLifecycleObserving)? = nil
    ) -> SwiftNativeAgentSwarmExecutor {
        // A swarm is an ordinary child of this dispatcher body. Its provider
        // adapters must not fall back to the process-default credentials just
        // because the worker is assembled here instead of by the chat factory.
        let llm = makeResidentProviderLLMClient(
            dataRoot: dataRoot, providersRoot: dataRoot, router: router,
            lifecycleObserver: providerLifecycleObserver,
            processEnvironmentOverride: ProcessInfo.processInfo.environment,
            stallOnlyTransport: false
        )
        let workerClient = swarmChatFactory.makeClient(
            // A worker is her hands: this same dispatcher, under User's
            // posture like her own turn (the permission law).
            tools: self,
            dataRoot: dataRoot,
            // Workers are real chat clients; name the swarm body as their
            // credential authority so they do not fall onto the alternate-root
            // fail-closed lane or borrow process-default credentials.
            approvalFiler: swarmApprovalFiler,
            providerLifecycleObserver: providerLifecycleObserver
        )
        return SwiftNativeAgentSwarmExecutor(
            llm: llm, routing: routing,
            runsPath: dataRoot
                .appendingPathComponent("swarms", isDirectory: true)
                .appendingPathComponent("runs.json"),
            workerClient: workerClient,
            turnTraceBus: workerClient.turnTraceBus,
            runLedgerDataRoot: dataRoot
        )
    }
}
