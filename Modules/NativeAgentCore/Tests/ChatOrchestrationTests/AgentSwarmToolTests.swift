import Testing
import Foundation
@testable import ChatOrchestration
import NativeAgentCore
import PersistenceCore
import SwarmRuns

private struct FakeSwarmExecutor: AgentSwarmExecuting {
    func runTool(input: [String: JSONValue], policy: AgentSwarmPolicy) async throws -> JSONValue {
        let request = try AgentSwarmRunRequest.parse(input: input, policy: policy)
        return .object([
            "status": .string("completed"),
            "runtime": .string("swift-native"),
            "surface": input["surface"] ?? .null,
            "workerOriginSurface": .string(request.requestedBy),
            "workerAccess": .string(request.workers.first?.access ?? ""),
            "policyMaxAgents": .int(Int64(policy.maxAgents)),
            "policyDefaultModel": .string(policy.defaultModel),
            "policyDefaultEffort": .string(policy.defaultReasoningEffort),
        ])
    }
}

private actor RecordingSwarmToolClient: ToolDispatchClient {
    private(set) var dispatched: [String] = []

    func dispatch(tool: String, input: [String: JSONValue], surface: String) async throws -> JSONValue {
        dispatched.append(tool)
        return .object(["status": .string("ok"), "tool": .string(tool)])
    }

    func listAvailableTools() async throws -> [String] {
        ["read_file", "write_file", "agent_swarm", "restart_app", "invoke_codex", "codex_message", "claude_message", "omp_message", "agent.swarm", "omp.message", "restart.app"]
    }

    func listAvailableToolSchemas() async throws -> [LLMToolSchema] {
        try await listAvailableTools().map { name in
            LLMToolSchema(
                name: name,
                description: name,
                parametersJSON: Data(#"{"type":"object","properties":{}}"#.utf8)
            )
        }
    }
}

private struct SwarmDiscoveryToolClient: ToolDispatchClient {
    let names = ["read_file", "write_file", "shell", "agent_swarm", "codex_message", "restart_app"]

    func listAvailableTools() async throws -> [String] { names }
    func listAvailableToolSchemas() async throws -> [LLMToolSchema] {
        names.map { LLMToolSchema(name: $0, description: $0, parametersJSON: Data(#"{"type":"object"}"#.utf8)) }
    }
    func dispatch(tool: String, input: [String: JSONValue], surface: String) async throws -> JSONValue {
        .object([
            "status": .string("ok"), "received_tool": .string(tool), "received_surface": .string(surface),
            "available_tools": .array(names.map(JSONValue.string)),
            "currently_loaded": .array([.string("agent_swarm")]),
            "builder_available_tools": .array([.string("shell"), .string("restart_app")]),
            "builder_policy_locked_tools": .array([.string("self_install")]),
            "tool_groups": .object([
                "mixed": .array([.string("write_file"), .string("codex_message")]),
                "subagents": .array([.string("agent_swarm")]),
            ]),
            "tools": .array(names.map { .object(["name": .string($0), "load_state": .string("discovery_only"),
                                               "parameters": .object(["type": .string("object")])]) }),
            "builder_bridge_readiness": .object(["codex": .object(["status": .string("ready"), "execution_ready": .bool(true)])]),
        ])
    }
}

private final class SwarmProviderAssemblyCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var assembly: SwarmProviderAssembly?
    private var workerCodexEnvironment: [String: String]?

    func record(_ value: SwarmProviderAssembly) {
        lock.withLock { assembly = value }
    }

    func value() -> SwarmProviderAssembly? {
        lock.withLock { assembly }
    }

    func recordWorkerCodexEnvironment(_ environment: [String: String]?) {
        lock.withLock { workerCodexEnvironment = environment }
    }

    func workerEnvironment() -> [String: String]? {
        lock.withLock { workerCodexEnvironment }
    }
}

private func tempSwarmToolRoot() throws -> URL {
    let url = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("chat-swarm-tool-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

@Test func swiftToolDispatcher_exposesAgentSwarmTool() async throws {
    let root = try tempSwarmToolRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let dispatcher = SwiftToolDispatcher(dataRoot: root, swarmExecutor: FakeSwarmExecutor())

    let names = try await dispatcher.listAvailableTools()
    #expect(names.contains("agent_swarm"))

    let schemas = try await dispatcher.listAvailableToolSchemas()
    let schema = schemas.first { $0.name == "agent_swarm" }
    #expect(schema != nil)
    if let schema {
        let params = try JSONValue.parse(schema.parametersJSON)
        guard case .object(let obj) = params,
              case .array(let required)? = obj["required"],
              case .object(let properties)? = obj["properties"] else {
            Issue.record("expected object schema with required array")
            return
        }
        #expect(required.contains(.string("objective")))
        #expect(properties["access"] != nil)
        #expect(properties["readOnly"] != nil)
    }
}

@Test func swiftToolDispatcher_usesConfiguredSwarmsBrainAsDefault() async throws {
    let root = try tempSwarmToolRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let providers = root.appendingPathComponent("providers", isDirectory: true)
    try FileManager.default.createDirectory(at: providers, withIntermediateDirectories: true)
    try JSONSerialization.data(withJSONObject: [
        "swarms": [
            "model": "claude-opus-4-8",
            "reasoningEffort": "high",
        ],
    ]).write(to: providers.appendingPathComponent("surfaces.json"))
    try JSONSerialization.data(withJSONObject: [
        "swarms": "anthropic_oauth_direct",
    ]).write(to: providers.appendingPathComponent("active.json"))

    let dispatcher = SwiftToolDispatcher(dataRoot: root, swarmExecutor: FakeSwarmExecutor())
    let out = try await dispatcher.dispatch(
        tool: "agent_swarm",
        input: ["objective": .string("use configured brain")],
        surface: "chat"
    )
    guard case .object(let object) = out else {
        Issue.record("expected object")
        return
    }
    #expect(object["policyDefaultModel"] == .string("claude-opus-4-8"))
    #expect(object["policyDefaultEffort"] == .string("high"))
}

@Test func swiftToolDispatcher_activeSwarmsProviderCannotFallBackToWrongModelFamily() async throws {
    let root = try tempSwarmToolRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let providers = root.appendingPathComponent("providers", isDirectory: true)
    try FileManager.default.createDirectory(at: providers, withIntermediateDirectories: true)
    try JSONSerialization.data(withJSONObject: [
        "swarms": "anthropic_oauth_direct",
    ]).write(to: providers.appendingPathComponent("active.json"))

    let dispatcher = SwiftToolDispatcher(dataRoot: root, swarmExecutor: FakeSwarmExecutor())
    let out = try await dispatcher.dispatch(
        tool: "agent_swarm",
        input: ["objective": .string("use provider-compatible default")],
        surface: "chat"
    )
    guard case .object(let object) = out else {
        Issue.record("expected object")
        return
    }
    #expect(object["policyDefaultModel"] == .string("claude-opus-4-8"))
}

@Test func swiftToolDispatcher_corruptSwarmsRoutingFailsClosedBeforeExecution() async throws {
    let root = try tempSwarmToolRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let providers = root.appendingPathComponent("providers", isDirectory: true)
    try FileManager.default.createDirectory(at: providers, withIntermediateDirectories: true)
    try Data("{not-json".utf8).write(to: providers.appendingPathComponent("surfaces.json"))

    let dispatcher = SwiftToolDispatcher(dataRoot: root, swarmExecutor: FakeSwarmExecutor())
    do {
        _ = try await dispatcher.dispatch(
            tool: "agent_swarm",
            input: ["objective": .string("must not use a guessed model")],
            surface: "chat"
        )
        Issue.record("corrupt provider authority should fail closed")
    } catch {
        #expect(error.localizedDescription.lowercased().contains("surface"))
    }
}

@Test func swiftToolDispatcher_dispatchesAgentSwarmThroughInjectedExecutor() async throws {
    let root = try tempSwarmToolRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let dispatcher = SwiftToolDispatcher(dataRoot: root, swarmExecutor: FakeSwarmExecutor())
    let out = try await dispatcher.dispatch(
        tool: "agent_swarm",
        input: [
            "objective": .string("fan out"),
            "surface": .string("chat"),
        ],
        surface: "telegram"
    )
    guard case .object(let obj) = out else {
        Issue.record("expected object output")
        return
    }
    #expect(obj["status"] == .string("completed"))
    #expect(obj["runtime"] == .string("swift-native"))
    #expect(obj["surface"] == .string("telegram"))
    #expect(obj["policyMaxAgents"] == .int(20))
}

@Test func swiftToolDispatcher_swarmOriginAliasesCannotReplaceAuthenticatedParent() async throws {
    let root = try tempSwarmToolRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let dispatcher = SwiftToolDispatcher(dataRoot: root, swarmExecutor: FakeSwarmExecutor())
    for surface in ["chat", "telegram", "slack", "ios"] {
        for alias in ["requestedBy", "requested_by"] {
            let out = try await dispatcher.dispatch(
                tool: "agent_swarm",
                input: [
                    "objective": .string("inherit this admitted parent's ordinary tools"),
                    "access": .string("inherit"),
                    "surface": .string(surface == "chat" ? "telegram" : "chat"),
                    alias: .string("forged-origin"),
                ],
                surface: surface
            )
            guard case .object(let object) = out else {
                Issue.record("expected successful injected worker admission")
                return
            }
            #expect(object["status"] == .string("completed"))
            #expect(object["surface"] == .string(surface))
            #expect(object["workerOriginSurface"] == .string(surface))
            #expect(object["workerAccess"] == .string("inherit"))
        }
    }
}

/// Ledger row `chat.factory.credentialRootEnvOverride`. This invokes the
/// DEFAULT agent_swarm assembly (no fake swarm executor) in dry-run mode, so
/// no worker/provider call can reach the network. The observer sees the actual
/// provider assembly immediately before it is installed into that executor.
@Test func defaultAgentSwarmAssemblesEveryCredentialAuthorityUnderItsScratchRoot() async throws {
    let root = try tempSwarmToolRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let capture = SwarmProviderAssemblyCapture()
    let dispatcher = SwiftToolDispatcher(
        dataRoot: root,
        swarmProviderAssemblyObserver: { assembly in capture.record(assembly) },
        swarmWorkerCodexEnvironmentObserver: { environment in
            capture.recordWorkerCodexEnvironment(environment)
        }
    )

    let result = try await dispatcher.dispatch(
        tool: "agent_swarm",
        input: ["objective": .string("plan only"), "dryRun": .bool(true)],
        surface: "chat"
    )
    guard case .object(let object) = result else {
        Issue.record("expected the default swarm dry-run plan")
        return
    }
    #expect(object["status"] == .string("dry_run"))

    let assembly = try #require(capture.value())
    #expect(assembly.dataRoot.standardizedFileURL == root.standardizedFileURL)
    #expect(assembly.codexEnvironment["CODEX_HOME"] == root
        .appendingPathComponent("codex_home", isDirectory: true).path)
    #expect(assembly.codexEnvironment["NATIVE_AGENT_DATA_ROOT"] == root.path)
    #expect(assembly.anthropicDataRoot.standardizedFileURL == root.standardizedFileURL)
    #expect(assembly.openAIDataRoot.standardizedFileURL == root.standardizedFileURL)
    #expect(assembly.moonshotDataRoot.standardizedFileURL == root.standardizedFileURL)
    for path in [assembly.openAIOAuthPath, assembly.anthropicOAuthPath, assembly.xaiOAuthPath] {
        #expect(path.standardizedFileURL.path.hasPrefix(root.standardizedFileURL.path + "/"))
    }
    let workerEnvironment = try #require(capture.workerEnvironment())
    #expect(workerEnvironment["CODEX_HOME"] == root
        .appendingPathComponent("codex_home", isDirectory: true).path)
    #expect(workerEnvironment["NATIVE_AGENT_DATA_ROOT"] == root.path)
}

@Test func swiftToolDispatcher_toolLoadSwarmCategoryReturnsAgentSwarm() async throws {
    let root = try tempSwarmToolRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let dispatcher = SwiftToolDispatcher(dataRoot: root, swarmExecutor: FakeSwarmExecutor())
    let out = try await dispatcher.dispatch(
        tool: "tool_load",
        input: ["category": .string("subagents")],
        surface: "chat"
    )
    guard case .object(let obj) = out,
          case .array(let loaded)? = obj["loaded"] else {
        Issue.record("expected tool_load object")
        return
    }
    #expect(loaded.contains(.string("agent_swarm")))
}

@Test func inheritedSwarmToolScope_keepsOrdinaryTools_butBlocksNestedAgentsAndLifecycle() async throws {
    let inner = RecordingSwarmToolClient()
    let scoped = AgentSwarmInheritedToolScope(inner: inner)

    #expect(try await scoped.listAvailableTools() == ["read_file", "write_file"])
    #expect(try await scoped.listAvailableToolSchemas().map(\.name) == ["read_file", "write_file"])

    _ = try await scoped.dispatch(tool: "write_file", input: [:], surface: "chat")
    #expect(await inner.dispatched == ["write_file"])

    for tool in ["agent_swarm", "codex_message", "claude_message", "omp_message",
                 "agent.swarm", "codex.message", "claude.message", "omp.message",
                 "invoke.codex", "invoke.claude", "install.app", "restart.app", "self.install"] {
        do {
            _ = try await scoped.dispatch(tool: tool, input: [:], surface: "telegram")
            Issue.record("nested delegation should be denied: \(tool)")
        } catch AutonomyGateError.toolDenied(let reason) {
            #expect(reason.contains("parent turn"))
        }
    }
    // Only the worker wrapper narrows delegation; the parent's bridge stays usable.
    _ = try await inner.dispatch(tool: "omp_message", input: [:], surface: "telegram")
    _ = try await scoped.dispatch(tool: "write_file", input: [:], surface: "telegram")
    // Ordinary dotted aliases retain the inner dispatcher's routing and the
    // admitted parent surface; the scope does not normalize or narrow them.
    _ = try await scoped.dispatch(tool: "write.file", input: [:], surface: "telegram")
    _ = try await inner.dispatch(tool: "omp.message", input: [:], surface: "telegram")
    #expect(await inner.dispatched == ["write_file", "omp_message", "write_file", "write.file", "omp.message"])
}

@Test func inheritedSwarmDiscoveryMatchesFixedWorkerCatalog() async throws {
    let scoped = AgentSwarmInheritedToolScope(inner: SwarmDiscoveryToolClient())
    let ready = Set(try await scoped.listAvailableToolSchemas().map(\.name))
    let result = try await LLMCallContext.$turnActiveTools.withValue(ready) {
        try await scoped.dispatch(tool: "tool.catalog", input: ["detail": .string("full")], surface: "telegram")
    }
    guard case .object(let object) = result,
          case .object(let groups)? = object["tool_groups"],
          case .array(let schemas)? = object["tools"],
          case .object(let bridges)? = object["builder_bridge_readiness"],
          case .object(let codex)? = bridges["codex"] else { Issue.record("missing scoped catalog"); return }
    let ordinary = JSONValue.array(["read_file", "shell", "write_file"].map(JSONValue.string))
    #expect(object["currently_loaded"] == ordinary)
    #expect(object["turn_active_tools"] == ordinary)
    #expect(object["discovery_only_tools"] == .array([]))
    #expect(object["builder_available_tools"] == .array([.string("shell")]))
    #expect(object["builder_policy_locked_tools"] == .array([]))
    #expect(object["received_tool"] == .string("tool_catalog"))
    #expect(object["received_surface"] == .string("telegram"))
    #expect(groups["subagents"] == nil)
    #expect(groups["mixed"] == .array([.string("write_file")]))
    #expect(schemas.count == 3)
    #expect(schemas.allSatisfy { value in
        guard case .object(let row) = value else { return false }
        return row["load_state"] == .string("loaded") && row["parameters"] == .object(["type": .string("object")])
    })
    #expect(codex["status"] == .string("parent_only"))
    #expect(codex["execution_ready"] == .bool(false))
    // The parent still advertises its own delegation capability.
    let parentNames = try await SwarmDiscoveryToolClient().listAvailableTools()
    #expect(parentNames.contains("agent_swarm"))
}

@Test func inheritedSwarmLoadAndUnloadLeaveActualParentLoadoutBytePreserved() async throws {
    let root = try tempSwarmToolRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let inner = SwiftToolDispatcher(dataRoot: root, swarmExecutor: FakeSwarmExecutor())
    let session = UUID().uuidString
    _ = try await inner.activeToolsStore.addLoaded(sessionId: session, names: ["read_file", "agent_swarm"])
    let path = root.appendingPathComponent("chat/active_tools/\(session).json")
    let before = try Data(contentsOf: path)
    let scoped = AgentSwarmInheritedToolScope(inner: inner)
    let scopedSchemas = try await scoped.listAvailableToolSchemas()
    let parentSchemas = try await inner.listAvailableToolSchemas()
    let unloadSchema = try #require(scopedSchemas.first { $0.name == "tool_unload" })
    let parentUnload = try #require(parentSchemas.first { $0.name == "tool_unload" })
    #expect(unloadSchema.description.contains("Reports no change"))
    #expect(unloadSchema.parametersJSON == parentUnload.parametersJSON)
    let ordinarySchema = try #require(scopedSchemas.first { $0.name == "read_file" })
    #expect(ordinarySchema == parentSchemas.first { $0.name == "read_file" })
    let ready = Set(scopedSchemas.map(\.name))
    try await ChatToolSessionContext.$verifiedSessionId.withValue(session) {
        try await LLMCallContext.$turnActiveTools.withValue(ready) {
            for surface in ["chat", "telegram"] {
                let loaded = try await scoped.dispatch(tool: "tool.load", input: [
                    "session_id": .string(session), "names": .array([.string("read.file"), .string("agent.swarm")]),
                ], surface: surface)
                guard case .object(let object) = loaded else { Issue.record("missing load receipt"); return }
                #expect(object["status"] == .string("partial"))
                #expect(object["loaded"] == .array([.string("read_file")]))
                #expect(object["already_active"] == .array([.string("read_file")]))
                #expect(object["loaded_now"] == .array([]))
                #expect(object["schemas_added"] == .array([]))
                #expect(object["parent_only"] == .array([.string("agent_swarm")]))
                #expect(object["aliased"] == .object(["read.file": .string("read_file"), "agent.swarm": .string("agent_swarm")]))
                let category = try await scoped.dispatch(tool: "tool_load", input: ["category": .string("subagents")], surface: surface)
                guard case .object(let categoryObject) = category else { Issue.record("missing category receipt"); return }
                #expect(categoryObject["loaded"] == .array([]))
                #expect(categoryObject["unavailable"] == .array([.string("agent_swarm")]))
                let unloaded = try await scoped.dispatch(tool: "tool.unload", input: ["all": .bool(true)], surface: surface)
                guard case .object(let unloadObject) = unloaded else { Issue.record("missing unload receipt"); return }
                #expect(unloadObject["status"] == .string("no_change"))
                #expect(unloadObject["changed"] == .bool(false))
                #expect(unloadObject["dropped"] == .array([]))
                #expect(unloadObject["parent_loadout_changed"] == .bool(false))
                #expect(try Data(contentsOf: path) == before)
            }
        }
    }
    let after = await inner.activeToolsStore.load(sessionId: session)
    #expect(after.activeTools == Set(["read_file", "agent_swarm"]))
}
