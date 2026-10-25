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

/// One assembled swarm provider body. The default swarm executor receives this
/// exact root for every credential authority; the observer is a test-only
/// assembly probe and never replaces adapters or dispatch behavior.
public struct SwarmProviderAssembly: Sendable {
    let dataRoot: URL
    let codexEnvironment: [String: String]
    let anthropicDataRoot: URL
    let openAIDataRoot: URL
    let anthropicOAuthPath: URL
    let xaiOAuthPath: URL
    let moonshotDataRoot: URL

    init(dataRoot: URL, environment: [String: String] = ProcessInfo.processInfo.environment) {
        self.dataRoot = dataRoot
        self.codexEnvironment = environment
        self.anthropicDataRoot = dataRoot
        self.openAIDataRoot = dataRoot
        self.anthropicOAuthPath = dataRoot.appendingPathComponent("providers", isDirectory: true)
            .appendingPathComponent("anthropic_oauth_direct.json")
        self.xaiOAuthPath = XAIOAuthDirectAdapter.tokenPath(dataRoot: dataRoot)
        self.moonshotDataRoot = dataRoot
    }
}

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
        let router = Self.makeSwarmRouter(dataRoot: dataRoot)
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
        let executor = swarmExecutor ?? makeDefaultAgentSwarmExecutor(
            router: router,
            routing: SwarmAdmittedRouting(
                model: policy.defaultModel,
                providerID: routingSnapshot.activeProviders["swarms"],
                effort: policy.defaultReasoningEffort,
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

    private static func makeSwarmRouter(dataRoot: URL) -> SwiftNativeProviderRouting {
        SwiftNativeProviderRouting(
            dataRoot: dataRoot,
            surfacesPathOverride: dataRoot
                .appendingPathComponent("providers", isDirectory: true)
                .appendingPathComponent("surfaces.json"),
            activeProviderPathOverride: dataRoot
                .appendingPathComponent("providers", isDirectory: true)
                .appendingPathComponent("active.json")
        )
    }

    private func makeDefaultAgentSwarmExecutor(
        router: SwiftNativeProviderRouting,
        routing: SwarmAdmittedRouting,
        providerLifecycleObserver: (any LLMCallLifecycleObserving)? = nil
    ) -> any AgentSwarmExecuting {
        // A swarm is an ordinary child of this dispatcher body. Its provider
        // adapters must not fall back to the process-default credentials just
        // because the worker is assembled here instead of by the chat factory.
        let providerAssembly = SwarmProviderAssembly(dataRoot: dataRoot)
        let llm = SwiftNativeLLMClient(
            router: router,
            codex: CodexAdapter(
                processEnvironmentOverride: providerAssembly.codexEnvironment,
                dataRootOverride: providerAssembly.dataRoot
            ),
            anthropic: AnthropicAdapter(dataRootOverride: providerAssembly.anthropicDataRoot, telemetryDataRootOverride: providerAssembly.dataRoot),
            openAI: OpenAIAdapter(dataRootOverride: providerAssembly.openAIDataRoot, telemetryDataRootOverride: providerAssembly.dataRoot),
            openAIOAuthDirect: OpenAIOAuthDirectAdapter(
                dataRootOverride: providerAssembly.dataRoot,
                telemetryDataRootOverride: providerAssembly.dataRoot
            ),
            anthropicOAuthDirect: AnthropicOAuthDirectAdapter(
                authPathOverride: providerAssembly.anthropicOAuthPath,
                telemetryDataRootOverride: providerAssembly.dataRoot
            ),
            xaiOAuthDirect: XAIOAuthDirectAdapter(
                tokenPathOverride: providerAssembly.xaiOAuthPath,
                telemetryDataRootOverride: providerAssembly.dataRoot
            ),
            moonshot: MoonshotAdapter(dataRootOverride: providerAssembly.moonshotDataRoot, telemetryDataRootOverride: providerAssembly.dataRoot),
            kimiCode: AnthropicAdapter.kimiCode(
                dataRootOverride: dataRoot,
                telemetryDataRootOverride: dataRoot
            ),
            openRouter: OpenRouterAdapter(dataRootOverride: dataRoot),
            lifecycleObserver: providerLifecycleObserver,
            moonshotCatalogDataRoot: dataRoot
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
            llm: SwarmAdmittedLLMClient(inner: llm, routing: routing),
            runsPath: dataRoot
                .appendingPathComponent("swarms", isDirectory: true)
                .appendingPathComponent("runs.json"),
            workerRunner: ChatOrchestrationSwarmWorkerRunner(
                client: workerClient,
                routing: routing
            ),
            turnTraceBus: workerClient.turnTraceBus,
            runLedgerDataRoot: dataRoot
        )
    }
}

private struct ChatOrchestrationSwarmWorkerRunner: AgentSwarmWorkerRunning {
    let client: any SwarmChatClient
    let routing: SwarmAdmittedRouting

    func runWorker(
        prompt: String,
        model: String,
        reasoningEffort: String,
        access: String,
        originSurface: String,
        originSessionId: String?
    ) async throws -> String {
        do {
            return try await client.runSwarmToolTurn(
                message: prompt,
                model: model,
                reasoningEffort: reasoningEffort,
                providerID: routing.provider(for: model),
                serviceTier: routing.serviceTier,
                sessionID: originSessionId,
                surface: originSurface
            )
        } catch let incomplete as EphemeralToolTurnIncomplete {
            throw AgentSwarmWorkerIncomplete(output: incomplete.output, reason: incomplete.reason)
        }
    }
}

/// The checked swarm picker tuple belongs to this fan-out, not to each later
/// origin-surface context build or provider settings reread.
struct SwarmAdmittedRouting: Sendable {
    let model: String
    let providerID: String?
    let effort: String
    let serviceTier: String

    /// The route is the one the Work group chose — never one inferred from a
    /// model name the request supplied. Inferring from the request meant an
    /// off-family name silently redirected the spend to another account
    /// (2026-09-13 review); the parser now refuses such a name outright, and
    /// this is the second half of that rule: nothing a caller says picks a
    /// route. S12a: nor does the captured model's name — with no Work route
    /// none is bound, and the LLM client takes the surface's explicit pick or
    /// refuses the call.
    func provider(for requestedModel: String) -> String? {
        providerID
    }
}

/// Retain all LLMClient entry points: this adapter only binds selection and
/// never flattens structured messages or replaces streaming with completion.
struct SwarmAdmittedLLMClient: LLMClient {
    let inner: any LLMClient
    let routing: SwarmAdmittedRouting

    private func admitted<T: Sendable>(model: String?, operation: () async throws -> T) async rethrows -> T {
        let selected = model?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let model = selected.isEmpty ? routing.model : selected
        let effort = LLMCallContext.reasoningEffort ?? routing.effort
        return try await LLMCallContext.$admittedModel.withValue(model) {
            try await LLMCallContext.$providerId.withValue(routing.provider(for: model)) {
                try await LLMCallContext.$reasoningEffort.withValue(effort) {
                    try await LLMCallContext.$serviceTier.withValue(routing.serviceTier) {
                        try await operation()
                    }
                }
            }
        }
    }

    func complete(prompt: String, system: String?, model: String?) async throws -> String {
        try await admitted(model: model) { try await inner.complete(prompt: prompt, system: system, model: model) }
    }

    func complete(prompt: String, system: String?, model: String?, surface: String) async throws -> String {
        try await admitted(model: model) { try await inner.complete(prompt: prompt, system: system, model: model, surface: surface) }
    }

    func complete(prompt: String, system: String?, model: String?, tools: [LLMToolSchema]?) async throws -> String {
        try await admitted(model: model) { try await inner.complete(prompt: prompt, system: system, model: model, tools: tools) }
    }

    func completeMessages(messages: [LLMMessage], system: String?, model: String?, surface: String, tools: [LLMToolSchema]?) async throws -> String {
        try await admitted(model: model) { try await inner.completeMessages(messages: messages, system: system, model: model, surface: surface, tools: tools) }
    }

    func servingProviderID(model: String?, surface: String) async -> String? {
        await admitted(model: model) { await inner.servingProviderID(model: model, surface: surface) }
    }

    func streamMessages(messages: [LLMMessage], system: String?, model: String?, surface: String, tools: [LLMToolSchema]?) -> AsyncThrowingStream<LLMMessageStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await admitted(model: model) {
                        for try await event in inner.streamMessages(messages: messages, system: system, model: model, surface: surface, tools: tools) {
                            try Task.checkCancellation()
                            continuation.yield(event)
                        }
                    }
                    continuation.finish()
                } catch { continuation.finish(throwing: error) }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
