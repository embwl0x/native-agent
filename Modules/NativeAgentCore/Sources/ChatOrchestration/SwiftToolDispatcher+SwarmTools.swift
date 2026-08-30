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
        let executor = swarmExecutor ?? makeDefaultAgentSwarmExecutor(
            router: router,
            routing: SwarmAdmittedRouting(
                model: policy.defaultModel,
                providerID: routingSnapshot.activeProviders["swarms"] ?? router.inferProviderForModel(policy.defaultModel),
                effort: policy.defaultReasoningEffort,
                serviceTier: routingSnapshot.preferences["swarms"]?.serviceTier ?? "default"
            ),
            providerLifecycleObserver: providerLifecycleObserver
        )
        // Child effort is filled by the parsed worker or the captured swarm
        // tuple (synthesis), never an ambient parent call's reasoning depth.
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

/// A swarm worker reuses NativeAgent's ordinary tool dispatcher and policy
/// membrane. Only recursive delegation and app lifecycle replacement are
/// removed from its request-scoped catalog; those actions must remain with the
/// parent turn that owns the swarm receipt.
struct AgentSwarmInheritedToolScope: ToolDispatchClient {
    let inner: any ToolDispatchClient

    private static let blocked: Set<String> = [
        "agent_swarm",
        "invoke_codex", "invoke_claude",
        "codex_message", "claude_message", "omp_message",
        "install_app", "restart_app", "self_install",
    ]

    private static func isParentOwned(_ tool: String) -> Bool {
        // Match the inner dispatcher's exact dotted alias contract before
        // checking this existing worker-only boundary. Otherwise agent.swarm
        // can pass this wrapper and become agent_swarm in the inner dispatcher.
        let canonical = SwiftToolDispatcher.canonicalToolName(tool) { blocked.contains($0) }
        return blocked.contains(canonical)
    }

    func dispatch(tool: String, input: [String: JSONValue], surface: String) async throws -> JSONValue {
        guard !Self.isParentOwned(tool) else {
            throw AutonomyGateError.toolDenied(
                reason: "\(tool) is reserved for the parent turn and is unavailable inside a swarm worker"
            )
        }
        let discovery = SwiftToolDispatcher.canonicalToolName(tool) {
            ["tool_catalog", "tool_load", "tool_unload"].contains($0)
        }
        switch discovery {
        case "tool_catalog":
            let result = try await inner.dispatch(tool: discovery, input: input, surface: surface)
            return try await scopedCatalog(result)
        case "tool_load":
            return try await scopedLoad(input)
        case "tool_unload":
            return .object([
                "status": .string("no_change"), "changed": .bool(false), "dropped": .array([]),
                "worker_active_count": .int(Int64(try await requestToolNames().count)),
                "parent_loadout_changed": .bool(false),
                "note": .string(Self.fixedCatalogNote),
            ])
        default: break
        }
        return try await inner.dispatch(tool: tool, input: input, surface: surface)
    }

    private static let fixedCatalogNote = "Worker tools are fixed for this request's lifetime. Loading only reports existing worker readiness; unloading makes no change. The parent's session loadout is untouched."

    private static func discoveryDescription(_ name: String) -> String? {
        switch name {
        case "tool_catalog": return "Discover this worker's available tools and fixed request readiness. Parent-owned delegation and app lifecycle tools are excluded."
        case "tool_load": return "Check requested names or a category against this worker's already-exposed tools. Does not load new schemas or change the parent's session loadout."
        case "tool_unload": return "Reports no change: worker tools remain fixed for this request's lifetime. Does not unload tools or change the parent's session loadout."
        default: return nil
        }
    }

    private func requestToolNames() async throws -> Set<String> {
        if let active = LLMCallContext.turnActiveTools {
            return active.filter { !Self.isParentOwned($0) }
        }
        return Set(try await listAvailableToolSchemas().map(\.name))
    }

    /// Discovery is a view of this worker, not the inner parent's loadout.
    /// Filter only defined tool-name slots, never arbitrary tool content.
    private func scopedCatalog(_ result: JSONValue) async throws -> JSONValue {
        guard case .object(var object) = result else { return result }
        func names(_ value: JSONValue) -> JSONValue {
            guard case .array(let rows) = value else { return value }
            return .array(rows.filter {
                guard case .string(let name) = $0 else { return true }
                return !Self.isParentOwned(name)
            })
        }
        for key in ["available_tools", "currently_loaded", "turn_active_tools", "discovery_only_tools",
                    "builder_available_tools", "builder_policy_locked_tools", "active_tools"] {
            if let value = object[key] { object[key] = names(value) }
        }
        if case .object(let groups)? = object["tool_groups"] {
            object["tool_groups"] = .object(groups.mapValues(names).filter {
                if case .array(let rows) = $0.value { return !rows.isEmpty }
                return true
            })
        }
        if case .array(let rows)? = object["tools"] {
            object["tools"] = .array(rows.filter {
                guard case .object(let row) = $0, case .string(let name)? = row["name"] else { return true }
                return !Self.isParentOwned(name)
            })
        }
        let ready = try await requestToolNames()
        if case .array(let available)? = object["available_tools"] {
            let visible = Set(available.compactMap { value -> String? in
                if case .string(let name) = value { return name }; return nil
            })
            object["currently_loaded"] = .array(visible.intersection(ready).sorted().map(JSONValue.string))
            object["turn_active_tools"] = object["currently_loaded"]
            object["discovery_only_tools"] = .array(visible.subtracting(ready).sorted().map(JSONValue.string))
        }
        if case .array(let rows)? = object["tools"] {
            object["tools"] = .array(rows.map { value in
                guard case .object(var row) = value, case .string(let name)? = row["name"] else { return value }
                row["load_state"] = .string(ready.contains(name) ? "loaded" : "discovery_only")
                if let description = Self.discoveryDescription(name) { row["description"] = .string(description) }
                return .object(row)
            })
        }
        if case .object(let bridges)? = object["builder_bridge_readiness"] {
            object["builder_bridge_readiness"] = .object(bridges.mapValues { value in
                guard case .object(var bridge) = value else { return value }
                bridge["status"] = .string("parent_only")
                bridge["execution_ready"] = .bool(false)
                bridge["worker_available"] = .bool(false)
                return .object(bridge)
            })
        }
        object["dynamic_loading"] = .string("fixed_worker_request")
        object["builder_mode_detail"] = .string("Ordinary worker tools retain the parent's policy. Recursive delegation and app lifecycle replacement remain parent-owned.")
        object["worker_scope_note"] = .string(Self.fixedCatalogNote)
        return .object(object)
    }

    /// Ephemeral workers already expose their complete scoped schemas. Never
    /// call the session-mutating loader with the inherited parent session ID.
    private func scopedLoad(_ input: [String: JSONValue]) async throws -> JSONValue {
        func string(_ value: JSONValue?) -> String? {
            guard case .string(let raw)? = value else { return nil }
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        var requested = Set<String>()
        let category = string(input["category"])?.lowercased()
        if let category {
            guard let group = ToolPreloadHeuristics.loadGroup(forCategory: category) else {
                return .object(["status": .string("failed"), "reason": .string("unknown_category"),
                                "category": .string(category),
                                "known_categories": .array(ToolPreloadHeuristics.knownLoadCategories.map(JSONValue.string))])
            }
            requested.formUnion(group.tools)
        }
        if case .array(let values)? = input["names"] { requested.formUnion(values.compactMap { string($0) }) }
        if let name = string(input["name"]) { requested.insert(name) }
        let all = Set(try await inner.listAvailableTools())
        var aliases: [String: JSONValue] = [:]
        requested = Set(requested.map { name in
            let canonical = SwiftToolDispatcher.canonicalToolName(name) { all.contains($0) }
            if canonical != name { aliases[name] = .string(canonical) }
            return canonical
        })
        let ready = try await requestToolNames()
        let loaded = requested.intersection(all).intersection(ready).filter { !Self.isParentOwned($0) }
        let unavailable = requested.subtracting(loaded)
        return .object([
            "status": .string(unavailable.isEmpty ? "loaded" : "partial"),
            "category": category.map(JSONValue.string) ?? .null,
            "loaded": .array(loaded.sorted().map(JSONValue.string)), "loaded_now": .array([]),
            "already_active": .array(loaded.sorted().map(JSONValue.string)),
            "turn_active": .array(loaded.sorted().map(JSONValue.string)), "schemas_added": .array([]),
            "unavailable": .array(unavailable.sorted().map(JSONValue.string)),
            "parent_only": .array(requested.filter(Self.isParentOwned).sorted().map(JSONValue.string)),
            "not_in_catalog": .array(requested.subtracting(all).sorted().map(JSONValue.string)),
            "aliased": .object(aliases), "parent_loadout_changed": .bool(false),
            "next_turn_note": .string(Self.fixedCatalogNote),
        ])
    }

    func listAvailableTools() async throws -> [String] {
        try await inner.listAvailableTools().filter { !Self.isParentOwned($0) }
    }

    func listAvailableToolSchemas() async throws -> [LLMToolSchema] {
        try await inner.listAvailableToolSchemas().filter { !Self.isParentOwned($0.name) }.map { schema in
            guard let description = Self.discoveryDescription(schema.name) else { return schema }
            return LLMToolSchema(name: schema.name, description: description, parametersJSON: schema.parametersJSON)
        }
    }
}

private struct ChatOrchestrationSwarmWorkerRunner: AgentSwarmWorkerRunning {
    let client: SwiftNativeChatOrchestrationClient
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
            let response = try await client.runEphemeralToolTurn(
                message: prompt,
                model: model,
                reasoningEffort: reasoningEffort,
                fileAccess: "auto",
                providerID: routing.provider(for: model),
                serviceTierOverride: routing.serviceTier,
                verifiedSessionId: originSessionId,
                requireCompleted: true,
                surface: originSurface
            )
            return response.output
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

    func provider(for requestedModel: String) -> String? {
        let inferred = SwiftNativeProviderRouting.inferredProviderID(forModel: requestedModel)
        let defaultFamily = SwiftNativeProviderRouting.inferredProviderID(forModel: model)
        if requestedModel == model || (inferred != nil && inferred == defaultFamily) {
            return providerID ?? inferred
        }
        return inferred ?? providerID
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
