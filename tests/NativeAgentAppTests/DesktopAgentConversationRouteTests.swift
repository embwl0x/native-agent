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
        let route = DesktopConversationTools(inner: fixture, bundle: "test.app", label: "Grok", message: nil, frontmostBundle: { "test.app" })
        _ = try await route.dispatch(tool: "go", input: ["name": .string("test.app")], surface: "chat")
        _ = try await route.dispatch(tool: "act", input: ["verb": .string("click"), "target": .string("Grok, Unread activity"), "button": .string("auto"), "repeat": .int(1), "seconds": .int(0), "interval": .double(0), "holding": .string(""), "to": .string(""), "to_app": .string("")], surface: "chat")
        #expect(await fixture.calls == ["screen", "act"])
    }
    @Test func exactSendIsSingleAttemptAndReplyNeedsObservedEvidence() async throws {
        let fixture = DesktopRouteFixture()
        let route = DesktopConversationTools(inner: fixture, bundle: "test.app", label: "Grok", message: "hello violet bird", frontmostBundle: { "test.app" })
        _ = try await route.dispatch(tool: "act", input: ["verb": .string("type"), "target": .string("Prompt"), "text": .string("hello violet bird")], surface: "chat")
        _ = try await route.dispatch(tool: "act", input: ["verb": .string("key"), "target": .string("Return")], surface: "chat")
        await #expect(throws: (any Error).self) {
            try await route.dispatch(tool: "act", input: ["verb": .string("key"), "target": .string("Return")], surface: "chat")
        }
        _ = try await route.dispatch(tool: "screen", input: [:], surface: "chat")
        let result = await route.project(answer: ["state": .string("reply"), "reply": .string("hello back")], agent: "peer:test")
        guard case .object(let fields) = result else { Issue.record("Missing result"); return }
        #expect(fields["status"] == .string("reply_received"))
        #expect(fields["sent"] == .bool(true))
        #expect(fields["completed"] == .bool(false))
        #expect(fields["reply_association"] == .string("observed_after_outgoing_message"))
        let stale = await route.project(answer: ["state": .string("reply"), "reply": .string("older reply")], agent: "peer:test")
        guard case .object(let old) = stale else { return }
        #expect(old["reply"] == nil)
        let invented = await route.project(answer: ["state": .string("reply"), "reply": .string("invented answer")], agent: "peer:test")
        guard case .object(let absent) = invented else { return }
        #expect(absent["reply"] == nil)
        #expect(absent["status"] == .string("sent"))
    }

    @Test func scopeAndForegroundChangesRefuseBeforeExecution() async throws {
        let fixture = DesktopRouteFixture()
        let route = DesktopConversationTools(inner: fixture, bundle: "test.app", label: "Grok", message: nil, frontmostBundle: { "other.app" })
        await #expect(throws: (any Error).self) { try await route.dispatch(tool: "shell", input: [:], surface: "chat") }
        await #expect(throws: (any Error).self) { try await route.dispatch(tool: "act", input: ["verb": .string("click"), "target": .string("Grok")], surface: "chat") }
        #expect(await fixture.calls.isEmpty)
        #expect(try await route.listAvailableTools() == ["screen", "act", "go", "wait"])
    }

    @Test func readCannotComposeOrGrantPermissions() async throws {
        let fixture = DesktopRouteFixture()
        let route = DesktopConversationTools(inner: fixture, bundle: "test.app", label: "Grok", message: nil, frontmostBundle: { "test.app" })
        await #expect(throws: (any Error).self) { try await route.dispatch(tool: "act", input: ["verb": .string("type"), "target": .string("Prompt"), "text": .string("hello")], surface: "chat") }
        await #expect(throws: (any Error).self) { try await route.dispatch(tool: "act", input: ["verb": .string("click"), "target": .string("Allow")], surface: "chat") }
        await #expect(throws: (any Error).self) { try await route.dispatch(tool: "read", input: ["path": .string("/private/file")], surface: "chat") }
        #expect(await fixture.calls.isEmpty)
        _ = try await route.dispatch(tool: "read", input: [:], surface: "chat")
        #expect(await fixture.calls == ["read"])
    }
}
