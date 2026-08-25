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

/// One assembled swarm provider body. The default swarm executor receives this
/// exact root for every credential authority; the observer is a test-only
/// assembly probe and never replaces adapters or dispatch behavior.
public struct SwarmProviderAssembly: Sendable {
    let dataRoot: URL
    let codexEnvironment: [String: String]
    let anthropicDataRoot: URL
    let openAIDataRoot: URL
    let openAIOAuthPath: URL
    let anthropicOAuthPath: URL
    let xaiOAuthPath: URL
    let moonshotDataRoot: URL

    init(dataRoot: URL, environment: [String: String] = ProcessInfo.processInfo.environment) {
        self.dataRoot = dataRoot
        self.codexEnvironment = environment.merging([
            "CODEX_HOME": dataRoot.appendingPathComponent("codex_home", isDirectory: true).path,
            "NATIVE_AGENT_DATA_ROOT": dataRoot.path,
        ]) { _, bound in bound }
        self.anthropicDataRoot = dataRoot
        self.openAIDataRoot = dataRoot
        self.openAIOAuthPath = OpenAIOAuthDirectAdapter.preferredAuthPath(
            dataRoot: dataRoot, allowSharedFallbacks: false, defaultRoot: dataRoot
        )
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
        // A swarm is an ordinary child of this dispatcher body. Its provider
        // adapters must not fall back to the process-default credentials just
        // because the worker is assembled here instead of by the chat factory.
        let providerAssembly = SwarmProviderAssembly(dataRoot: dataRoot)
        swarmProviderAssemblyObserver?(providerAssembly)
        let llm = SwiftNativeLLMClient(
            router: router,
            codex: CodexAdapter(processEnvironmentOverride: providerAssembly.codexEnvironment),
            anthropic: AnthropicAdapter(dataRootOverride: providerAssembly.anthropicDataRoot, telemetryDataRootOverride: providerAssembly.dataRoot),
            openAI: OpenAIAdapter(dataRootOverride: providerAssembly.openAIDataRoot, telemetryDataRootOverride: providerAssembly.dataRoot),
            openAIOAuthDirect: OpenAIOAuthDirectAdapter(
                authPathOverride: providerAssembly.openAIOAuthPath,
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
        let workerTools = AgentSwarmInheritedToolScope(inner: self)
        let workerCodexFactory: (@Sendable ([String: String]?) -> any LLMAdapter)?
        if let observer = swarmWorkerCodexEnvironmentObserver {
            workerCodexFactory = { environment in
                observer(environment)
                return CodexAdapter(processEnvironmentOverride: environment)
            }
        } else {
            workerCodexFactory = nil
        }
        let workerClient = makeChatOrchestrationClient(
            tools: workerTools,
            dataRoot: dataRoot,
            // Workers are real chat clients; name the swarm body as their
            // credential authority so they do not fall onto the alternate-root
            // fail-closed lane or borrow process-default credentials.
            providersRoot: dataRoot,
            approvalFiler: swarmApprovalFiler,
            providerLifecycleObserver: providerLifecycleObserver,
            codexAdapterFactory: workerCodexFactory
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
