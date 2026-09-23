import Foundation
import Testing
import NativeAgentCore
import PersistenceCore
@testable import ChatOrchestration

@Suite struct AgentWorkspaceGateTests {
    private static let prepared: JSONValue = .object([
        "status": .string("prepared"), "execution": .string("requires_workspace_runtime")
    ])
    private static let denied: JSONValue = .object([
        "status": .string("blocked"), "detail": .string("Denied by the inner tool gate"), "completed": .bool(false)
    ])

    private func root() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("workspace-gate-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
    private func object(_ value: JSONValue?) -> [String: JSONValue] {
        guard case .object(let row)? = value else { return [:] }; return row
    }
    private func action(_ view: JSONValue, _ label: String) throws -> JSONValue {
        let row = object(view)
        var buttons: [JSONValue] = []
        if case .array(let values)? = row["actions"] { buttons += values }
        if case .array(let items)? = row["items"] {
            for item in items {
                if case .array(let values)? = object(item)["actions"] { buttons += values }
            }
        }
        let button = try #require(buttons.first { object($0)["label"] == .string(label) })
        return try #require(object(button)["action"])
    }

    @Test func facadeDenialStopsBeforeAnyWorkOwner() async throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let inner = MockToolDispatchClient(scripted: ["workspace": Self.denied])
        let client = CanonicalToolNameDispatcher(inner: inner, peerDataRoot: root, conversationScope: "verified-chat")
        let result = try await client.dispatch(tool: "workspace", input: ["query": .string("design")], surface: "chat")
        #expect(result == Self.denied)
        #expect(inner.dispatches.map(\.tool) == ["workspace"])
    }

    @Test func workspaceAdmissionDoesNotGrantWorkReaderAccess() async throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let inner = MockToolDispatchClient(scripted: ["workspace": Self.prepared, "work_context": Self.denied])
        let client = CanonicalToolNameDispatcher(inner: inner, peerDataRoot: root, conversationScope: "verified-chat")
        let result = try await client.dispatch(tool: "workspace", input: ["query": .string("design")], surface: "chat")
        #expect(inner.dispatches.map(\.tool) == ["workspace", "work_context"])
        #expect(inner.dispatches.last?.input == ["query": .string("design"), "__session_id": .string("verified-chat")])
        #expect(object(result)["status"] == .string("blocked"))
        #expect(object(result)["content"] == Self.denied)
    }

    @Test func selectedFileReentersInnerGateWithExactArgumentsAndPreservesDenial() async throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let documents: JSONValue = .object(["status": .string("ok"), "artifacts": .array([.object([
            "name": .string("Draft"), "open_current_file": .object(["tool": .string("read_file"),
                "arguments": .object(["path": .string("/workspace/exact-draft.md")])])
        ])])])
        let inner = MockToolDispatchClient(scripted: ["workspace": Self.prepared, "artifact_find": documents, "read_file": Self.denied])
        let client = CanonicalToolNameDispatcher(inner: inner, peerDataRoot: root, conversationScope: "verified-chat")
        let home = try await client.dispatch(tool: "workspace", input: [:], surface: "chat")
        let found = try await client.dispatch(tool: "workspace", input: [
            "action": try action(home, "Find a document"), "text": .string("draft")
        ], surface: "chat")
        let opened = try await client.dispatch(tool: "workspace", input: ["action": try action(found, "Open current file")], surface: "chat")
        #expect(inner.dispatches.map(\.tool) == ["workspace", "workspace", "artifact_find", "workspace", "read_file"])
        #expect(inner.dispatches.last?.input == ["path": .string("/workspace/exact-draft.md"), "max_bytes": .int(12_000), "__session_id": .string("verified-chat")])
        #expect(inner.dispatches.allSatisfy { $0.surface == "chat" })
        #expect(object(opened)["status"] == .string("blocked"))
        #expect(object(opened)["content"] == Self.denied)
    }

    @Test func modelSessionFieldsCannotCreateVerifiedScope() async throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let inner = MockToolDispatchClient(scripted: ["workspace": Self.prepared])
        let client = CanonicalToolNameDispatcher(inner: inner, peerDataRoot: root)
        let result = try await ChatToolSessionContext.$verifiedSessionId.withValue(nil) {
            try await client.dispatch(tool: "workspace", input: ["query": .string("design"),
                "session_id": .string("claimed-chat"), "__session_id": .string("claimed-chat")], surface: "chat")
        }
        #expect(object(result)["status"] == .string("unavailable"))
        #expect(inner.dispatches.isEmpty)
    }

    @Test func environmentFormStillUsesActualWriteGateAndVerifiedSession() async throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let schema = LLMToolSchema(name: "write_file", description: "Write a file", parametersJSON: Data(#"{"type":"object","properties":{"path":{"type":"string"},"content":{"type":"string"}},"required":["path","content"]}"#.utf8))
        let inner = MockToolDispatchClient(scripted: ["workspace": Self.prepared, "write_file": Self.denied], schemas: [schema])
        let client = CanonicalToolNameDispatcher(inner: inner, peerDataRoot: root, conversationScope: "verified-chat")
        let home = try await client.dispatch(tool: "workspace", input: [:], surface: "chat")
        let create = try await client.dispatch(tool: "workspace", input: ["action": action(home, "Find an action"), "text": .string("write_file")], surface: "chat")
        let form = try await client.dispatch(tool: "workspace", input: ["action": action(create, "Open")], surface: "chat")
        let result = try await client.dispatch(tool: "workspace", input: ["action": action(form, "Submit Write File"), "fields": .array([
            .object(["field": .string("path"), "value": .string("exact.md")]),
            .object(["field": .string("content"), "value": .string("Exact content")])])], surface: "chat")
        #expect(inner.dispatches.last?.tool == "write_file")
        #expect(inner.dispatches.last?.input == ["path": .string("exact.md"), "content": .string("Exact content"), "__session_id": .string("verified-chat")])
        #expect(object(result)["status"] == .string("blocked"))
        _ = try await client.dispatch(tool: "workspace", input: [:], surface: "chat")
        #expect(inner.dispatches.filter { $0.tool == "write_file" }.count == 1)
    }

    @Test func stolenActionCannotCrossVerifiedScopeUsingSpoofedSessionFields() async throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let inner = MockToolDispatchClient(scripted: ["workspace": Self.prepared,
            "work_context": .object(["status": .string("ok")])])
        let client = CanonicalToolNameDispatcher(inner: inner, peerDataRoot: root, conversationScope: "construction-fallback")
        let home = try await ChatToolSessionContext.$verifiedSessionId.withValue("owner-chat") {
            try await client.dispatch(tool: "workspace", input: [:], surface: "chat")
        }
        let offered = try action(home, "Find work")
        await #expect(throws: (any Error).self) {
            try await ChatToolSessionContext.$verifiedSessionId.withValue("other-chat") {
                try await client.dispatch(tool: "workspace", input: ["action": offered, "text": .string("design"),
                    "session_id": .string("owner-chat"), "__session_id": .string("owner-chat")], surface: "chat")
            }
        }
        #expect(inner.dispatches.map(\.tool) == ["workspace", "workspace"])
        _ = try await ChatToolSessionContext.$verifiedSessionId.withValue("owner-chat") {
            try await client.dispatch(tool: "workspace", input: ["action": offered, "text": .string("design")], surface: "chat")
        }
        #expect(inner.dispatches.map(\.tool) == ["workspace", "workspace", "workspace", "work_context"])
        #expect(inner.dispatches.last?.input["__session_id"] == .string("owner-chat"))
    }

    @Test func selectedPeerMessageStillReachesItsOwnGateAndKeepsRefusal() async throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let peer = try AgentPeerStore(dataRoot: root).upsert(AgentPeerContact(
            name: "Gate fixture", endpoint: URL(string: "https://workspace-fixture.invalid")!, transport: .a2a))
        let agent = "peer:" + peer.id
        let contacts: JSONValue = .object(["status": .string("ok"), "contacts": .array([.object([
            "name": .string(peer.name), "agent": .string(agent), "capabilities": .array([.string("message")])
        ])])])
        let inner = MockToolDispatchClient(scripted: ["workspace": Self.prepared, "agent_contacts": contacts, "agent_message": Self.denied])
        let client = CanonicalToolNameDispatcher(inner: inner, peerDataRoot: root, conversationScope: "verified-chat")
        let home = try await client.dispatch(tool: "workspace", input: [:], surface: "chat")
        let people = try await client.dispatch(tool: "workspace", input: ["action": try action(home, "People and agents")], surface: "chat")
        let refused = try await client.dispatch(tool: "workspace", input: [
            "action": try action(people, "Message"), "text": .string("Please review the draft")
        ], surface: "chat")
        #expect(inner.dispatches.map(\.tool) == ["workspace", "workspace", "agent_contacts", "workspace", "agent_message"])
        #expect(inner.dispatches.last?.input["agent"] == .string(agent))
        #expect(inner.dispatches.last?.input["text"] == .string("Please review the draft"))
        #expect(object(refused)["status"] == .string("blocked"))
        #expect(object(object(refused)["content"])["completed"] == .bool(false))
    }
}
