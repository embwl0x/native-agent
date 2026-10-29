import Foundation
import NativeAgentCore
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
// Blueprint: | `SwiftToolDispatcher+SwarmTools.swift` | `SwiftToolDispatcher`: `impl_agent_swarm` |

// MARK: - Agent swarm tools

extension SwiftToolDispatcher {
    func impl_agent_swarm(input: [String: JSONValue], surface: String) async throws -> JSONValue {
        var body = input
        // The dispatcher supplies the authenticated origin. A model-provided
        // `surface` must never reclassify Telegram/Slack/iOS work as local Mac.
        body["surface"] = .string(surface)
        // The request parser also accepts these legacy aliases, with
        // requestedBy taking precedence over surface. Bind that canonical
        // field too: it is the inherited worker's authorization origin.
        body["requestedBy"] = .string(surface)
        body.removeValue(forKey: "requested_by")
        let trust = SwiftNativeTrustCenter(dataRoot: dataRoot)
        let policyJSON = await trust.loadTrustPolicy()
        var policy = AgentSwarmPolicy.fromTrustPolicy(.object(policyJSON))
        let router = SwiftNativeProviderRouting(dataRoot: dataRoot)
        let routingSnapshot = try await router.checkedRoutingSnapshot()
        if let preference = routingSnapshot.preferences["swarms"] {
            // Provider Settings is the one owner of cognitive selection.
            // TrustCenter still owns enablement and concurrency caps, but it
            // no longer carries a stale second swarm-model default.
            policy.defaultModel = preference.model
            policy.defaultReasoningEffort = preference.reasoningEffort
        }
        if let providerID = routingSnapshot.activeProviders["swarms"] {
            if CodexAccountModelCatalog.isAccountBackedProvider(providerID) {
                policy.supportedReasoningEfforts = CodexAccountModelCatalog.load(
                    providerID: providerID,
                    cacheURL: CodexAccountModelCatalog.chatGPTOAuthCacheCandidate(dataRoot: dataRoot),
                    useDefaultCacheWhenNil: false
                ).first { $0.id.caseInsensitiveCompare(policy.defaultModel) == .orderedSame }?.supportedReasoningEfforts ?? []
            } else {
                policy.supportedReasoningEfforts = FirstPartyModelCatalog.models(forProviderID: providerID)
                    .first { $0.id.caseInsensitiveCompare(policy.defaultModel) == .orderedSame }?.supportedReasoningEfforts ?? []
            }
        }
        // The checked provider/account belongs to the fan-out; requested models cannot redirect it.
        let executor = makeAgentSwarmExecutor(
            router: router,
            routing: TurnRouteAdmission(
                routingSurface: "swarms",
                modelId: policy.defaultModel,
                reasoningEffort: policy.defaultReasoningEffort,
                providerId: routingSnapshot.activeProviders["swarms"],
                serviceTier: routingSnapshot.preferences["swarms"]?.serviceTier ?? "default"
            ),
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
