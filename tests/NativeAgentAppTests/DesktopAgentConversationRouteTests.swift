import Foundation
import Testing
import ChatOrchestration
import NativeAgentCore
import PersistenceCore
@testable import NativeAgentApp

private actor DesktopRouteFixture: ToolDispatchClient {
    var calls: [String] = []
    func dispatch(tool: String, input: [String: JSONValue], surface: String) async throws -> JSONValue {
        calls.append(tool)
        return .object(["ok": .bool(true), "text": .string("Grok, Unread activity. Grok: older reply. Chat with Grok. hello violet bird. Grok: hello back")])
    }
    func listAvailableTools() async throws -> [String] { ["screen", "act", "go", "wait", "shell"] }
    func listAvailableToolSchemas() async throws -> [LLMToolSchema] { [] }
}

@Suite struct DesktopAgentConversationRouteTests {
    @Test func normalSchemaDefaultsAndObservedStatusLabelsWork() async throws {
        let fixture = DesktopRouteFixture()
        let route = DesktopConversationTools(inner: fixture, bundle: "test.app", label: "Grok", message: "hello violet bird", frontmostBundle: { "test.app" })
        _ = try await route.dispatch(tool: "go", input: ["name": .string("test.app")], surface: "chat")
        _ = try await route.dispatch(tool: "act", input: ["verb": .string("click"), "target": .string("Grok, Unread activity"), "button": .string("auto"), "repeat": .int(1), "seconds": .int(0), "interval": .double(0), "holding": .string(""), "to": .string(""), "to_app": .string("")], surface: "chat")
        #expect(await fixture.calls == ["screen", "act"])
    }
    @Test func exactSendIsSingleAttemptAndDeliveryNeedsObservedEvidence() async throws {
        let fixture = DesktopRouteFixture()
        let route = DesktopConversationTools(inner: fixture, bundle: "test.app", label: "Grok", message: "hello violet bird", frontmostBundle: { "test.app" })
        _ = try await route.dispatch(tool: "act", input: ["verb": .string("type"), "target": .string("Prompt"), "text": .string("hello violet bird")], surface: "chat")
        _ = try await route.dispatch(tool: "act", input: ["verb": .string("key"), "target": .string("Return")], surface: "chat")
        let repeated = try await route.dispatch(tool: "act", input: ["verb": .string("key"), "target": .string("Return")], surface: "chat")
        guard case .object(let state) = repeated else { Issue.record("Missing submission state"); return }
        #expect(state["ok"] == .bool(true))
        #expect(state["status"] == .string("already_submitted"))
        #expect(state["sent"] == .bool(false))
        #expect(await fixture.calls == ["act", "act"])
        _ = try await route.dispatch(tool: "screen", input: [:], surface: "chat")
        let result = await route.project(answer: ["state": .string("sent")], agent: "peer:test")
        guard case .object(let fields) = result else { Issue.record("Missing result"); return }
        #expect(fields["status"] == .string("sent"))
        #expect(fields["sent"] == .bool(true))
        #expect(fields["completed"] == .bool(false))
        // Send-only: no reply is looked for, reported, or offered as a read.
        #expect(fields["reply"] == nil)
        #expect(fields["read_with"] == nil)
        #expect(fields["untrusted_remote_data"] == nil)
        let claimed = await route.project(answer: ["state": .string("sent"), "reply": .string("hello back")], agent: "peer:test")
        guard case .object(let withoutReply) = claimed else { return }
        #expect(withoutReply["reply"] == nil)
        // An outgoing message that was never observed is not a delivery.
        let unseen = DesktopConversationTools(inner: fixture, bundle: "test.app", label: "Grok", message: "never typed", frontmostBundle: { "test.app" })
        let unknown = await unseen.project(answer: ["state": .string("sent")], agent: "peer:test")
        guard case .object(let absent) = unknown else { return }
        #expect(absent["status"] == .string("outcome_unknown"))
        #expect(absent["sent"] == .bool(false))
        #expect(absent["untrusted_remote_data"] == nil)
        let blocked = await unseen.project(answer: ["state": .string("blocked")], agent: "peer:test")
        guard case .object(let stopped) = blocked else { return }
        #expect(stopped["untrusted_remote_data"] == nil)
    }

    @Test func scopeAndForegroundChangesRefuseBeforeExecution() async throws {
        let fixture = DesktopRouteFixture()
        let route = DesktopConversationTools(inner: fixture, bundle: "test.app", label: "Grok", message: "hello violet bird", frontmostBundle: { "other.app" })
        await #expect(throws: (any Error).self) { try await route.dispatch(tool: "shell", input: [:], surface: "chat") }
        await #expect(throws: (any Error).self) { try await route.dispatch(tool: "act", input: ["verb": .string("click"), "target": .string("Grok")], surface: "chat") }
        #expect(await fixture.calls.isEmpty)
        #expect(try await route.listAvailableTools() == ["screen", "act", "go"])
    }

    @Test func operatorCannotComposeOtherTextOrGrantPermissions() async throws {
        let fixture = DesktopRouteFixture()
        let route = DesktopConversationTools(inner: fixture, bundle: "test.app", label: "Grok", message: "hello violet bird", frontmostBundle: { "test.app" })
        await #expect(throws: (any Error).self) { try await route.dispatch(tool: "act", input: ["verb": .string("type"), "target": .string("Prompt"), "text": .string("hello")], surface: "chat") }
        await #expect(throws: (any Error).self) { try await route.dispatch(tool: "act", input: ["verb": .string("click"), "target": .string("Allow")], surface: "chat") }
        await #expect(throws: (any Error).self) { try await route.dispatch(tool: "read", input: ["path": .string("/private/file")], surface: "chat") }
        #expect(await fixture.calls.isEmpty)
        _ = try await route.dispatch(tool: "read", input: [:], surface: "chat")
        #expect(await fixture.calls == ["read"])
    }
}
