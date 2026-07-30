import Testing
import Foundation
@testable import ChatOrchestration
import NativeAgentCore
import PersistenceCore
import SwarmRuns

private struct FakeSwarmExecutor: AgentSwarmExecuting {
    func runTool(input: [String: JSONValue], policy: AgentSwarmPolicy) async throws -> JSONValue {
        .object([
            "status": .string("completed"),
            "runtime": .string("swift-native"),
            "surface": input["surface"] ?? .null,
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
        ["read_file", "write_file", "agent_swarm", "restart_app", "invoke_codex"]
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

    do {
        _ = try await scoped.dispatch(tool: "agent_swarm", input: [:], surface: "chat")
        Issue.record("nested swarm should be denied")
    } catch AutonomyGateError.toolDenied(let reason) {
        #expect(reason.contains("parent turn"))
    }
}
