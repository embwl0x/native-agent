import Foundation
import NativeAgentCore
import PersistenceCore
import MemoryV2
import MCPDispatcher
import KnowledgeGraph
import PersonaEngine
import ProviderRouting
import TrustCenter
import Dispatcher
import MacControl
import Context
import SwarmRuns
import WorkshopExecution

// MARK: - Agent swarm tools

extension SwiftToolDispatcher {
    func impl_agent_swarm(input: [String: JSONValue], surface: String) async throws -> JSONValue {
        var body = input
        // The dispatcher supplies the authenticated origin. A model-provided
        // `surface` must never reclassify Telegram/Slack/iOS work as local Mac.
        body["surface"] = .string(surface)
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
        let executor = swarmExecutor ?? makeDefaultAgentSwarmExecutor(
            router: router,
            providerID: routingSnapshot.activeProviders["swarms"]
                ?? routingSnapshot.preferences["swarms"].flatMap {
                    router.inferProviderForModel($0.model)
                },
            providerLifecycleObserver: providerLifecycleObserver
        )
        return try await executor.runTool(input: body, policy: policy)
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
        providerID: String?,
        providerLifecycleObserver: (any LLMCallLifecycleObserving)? = nil
    ) -> any AgentSwarmExecuting {
        let llm = SwiftNativeLLMClient(
            router: router,
            codex: CodexAdapter(),
            anthropic: AnthropicAdapter(),
            openAI: OpenAIAdapter(),
            openAIOAuthDirect: OpenAIOAuthDirectAdapter(),
            anthropicOAuthDirect: AnthropicOAuthDirectAdapter(),
            xaiOAuthDirect: XAIOAuthDirectAdapter(),
            moonshot: MoonshotAdapter(),
            // Root the kimi-code credential/telemetry reads in the SAME
            // dataRoot the router resolves provider state from — a non-default
            // runtime must not silently read the default root's key (gpt-5.5
            // review MED). NOTE: the neighboring adapters predate this fix and
            // still use default roots — pre-existing pattern, tracked on the
            // kimi-code-provider board, not widened here.
            kimiCode: AnthropicAdapter.kimiCode(
                dataRootOverride: dataRoot,
                telemetryDataRootOverride: dataRoot
            ),
            openRouter: OpenRouterAdapter(),
            lifecycleObserver: providerLifecycleObserver
        )
        let workerTools = AgentSwarmInheritedToolScope(inner: self)
        let workerClient = makeChatOrchestrationClient(
            tools: workerTools,
            dataRoot: dataRoot,
            approvalFiler: swarmApprovalFiler,
            providerLifecycleObserver: providerLifecycleObserver
        )
        return SwiftNativeAgentSwarmExecutor(
            llm: llm,
            runsPath: dataRoot
                .appendingPathComponent("swarms", isDirectory: true)
                .appendingPathComponent("runs.json"),
            workerRunner: ChatOrchestrationSwarmWorkerRunner(
                client: workerClient,
                providerID: providerID,
                router: router
            ),
            runLedgerDataRoot: dataRoot
        )
    }
}

/// A swarm worker reuses NativeAgent's ordinary tool dispatcher and policy
/// membrane. Only recursive delegation and app lifecycle replacement are
/// removed from its request-scoped catalog; those actions must remain with the
/// parent turn that owns the swarm receipt.
struct AgentSwarmInheritedToolScope: ToolDispatchClient {
    let inner: any ToolDispatchClient

    private static let blocked: Set<String> = [
        "agent_swarm",
        "invoke_codex", "invoke_claude",
        "codex_message", "claude_message",
        "install_app", "restart_app", "self_install",
    ]

    func dispatch(tool: String, input: [String: JSONValue], surface: String) async throws -> JSONValue {
        guard !Self.blocked.contains(tool) else {
            throw AutonomyGateError.toolDenied(
                reason: "\(tool) is reserved for the parent turn and is unavailable inside a swarm worker"
            )
        }
        return try await inner.dispatch(tool: tool, input: input, surface: surface)
    }

    func listAvailableTools() async throws -> [String] {
        try await inner.listAvailableTools().filter { !Self.blocked.contains($0) }
    }

    func listAvailableToolSchemas() async throws -> [LLMToolSchema] {
        try await inner.listAvailableToolSchemas().filter { !Self.blocked.contains($0.name) }
    }
}

private struct ChatOrchestrationSwarmWorkerRunner: AgentSwarmWorkerRunning {
    let client: SwiftNativeChatOrchestrationClient
    let providerID: String?
    let router: SwiftNativeProviderRouting

    func runWorker(
        prompt: String,
        model: String,
        reasoningEffort: String,
        access: String,
        originSurface: String,
        originSessionId: String?
    ) async throws -> String {
        let response = try await client.runEphemeralToolTurn(
            message: prompt,
            model: model,
            reasoningEffort: reasoningEffort,
            fileAccess: "auto",
            providerID: router.inferProviderForModel(model) ?? providerID,
            verifiedSessionId: originSessionId,
            surface: originSurface
        )
        return response.output
    }
}
