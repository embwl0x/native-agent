import Foundation
import Testing
@testable import ChatOrchestration
import PersistenceCore

// Tool-body tests enter with the same native schema normalization as dispatch.
func normalizedToolArguments(_ tool: String, _ input: [String: JSONValue]) -> [String: JSONValue] {
    let schemas = BuiltInToolSchemaFactory(requestedNames: [tool]).schemas(
        includeFullMacFileTools: true, includeFullMacSystemTools: true, includeFullMacAppTools: true,
        includeFullMacAccessibilityReadTools: true, includeFullMacAccessibilityInjectionTools: true,
        includeActivityQueryTool: true)
    return ToolArguments.normalized(input, schema: try! JSONValue.parse(schemas.first { $0.name == tool }!.parametersJSON))
}

@Suite struct AgentConversationRoutingTests {
    @Test func normalizationPreservesUndeclaredNulls() throws {
        let input: [String: JSONValue] = ["value": .null]
        for json in [#"{}"#, #"{"type":"object","properties":{},"additionalProperties":true}"#,
                     #"{"properties":{"optional":{"type":"string"}}}"#] {
            #expect(ToolArguments.normalized(input, schema: try JSONValue.parse(Data(json.utf8))) == input)
        }
    }
    @Test func normalizationPreservesRequiredNullsAndFalse() {
        #expect(normalizedToolArguments("agent_connect", ["name": .null, "endpoint": .null, "disconnect": .bool(false)])
            == ["name": .null, "disconnect": .bool(false)])
        #expect(normalizedToolArguments("bot_update", ["fields": .object(["fast": .bool(false), "provider": .null])])
            == ["fields": .object(["fast": .bool(false)])])
    }
    @Test func explicitFalseIsNotAnAbsentUnsupportedOption() {
        #expect(throws: (any Error).self) {
            try AgentConversationRouting.route(tool: "agent_message", input: [
                "agent": .string("omp"), "text": .string("Hello"),
                "options": .object(["fast": .bool(false)])
            ])
        }
    }
    @Test func strictProviderBlanksAndNullFlagsSelectOnlyTheRequestedRoute() throws {
        for agent in ["codex", "claude", "omp", "bot:" + UUID().uuidString] {
            let route = try #require(try AgentConversationRouting.route(tool: "agent_message", input: normalizedToolArguments("agent_message", [
                "agent": .string(agent), "text": .string("Hello"), "conversation_id": .string(""),
                "message_id": .string(""), "task_id": .null, "details": .null,
                "options": .object(["topic": .string(""), "model": .string(""),
                                    "working_directory": .string(""), "fast": agent == "codex" ? .bool(false) : .null,
                                    "pair_reviewer": .null])
            ])))
            #expect(route.tool == (agent.hasPrefix("bot:") ? "bot_ask" : agent + "_message"))
            if agent == "codex" { #expect(route.input["fast"] == .bool(false)) }
            #expect(route.input["topic"] == nil)
        }
        let resumed = try #require(try AgentConversationRouting.route(tool: "agent_message", input: [
            "agent": .string("codex"), "text": .string("Continue"), "conversation_id": .string("existing"),
            "options": .object(["topic": .string(""), "working_directory": .string("")])
        ]))
        #expect(resumed.input["conversation_mode"] == .string("resume"))
    }
    @Test func recoveryLocatorUsesTheReadOwnersIdentityContract() throws {
        let locator = try #require(AgentConversationRouting.readLocator(agent: "claude", message: .string("accepted"), conversation: .string("claude:topic"), task: nil))
        #expect(locator == .object(["tool": .string("agent_read"), "input": .object(["agent": .string("claude"), "message_id": .string("accepted")])]))
        #expect(AgentConversationRouting.readLocator(agent: "peer:p", message: .string("request"), conversation: nil, task: nil) == nil)
        #expect(AgentConversationRouting.readLocator(agent: "peer:p", message: nil, conversation: .string("context"), task: .string("task")) == .object(["tool": .string("agent_read"), "input": .object(["agent": .string("peer:p"), "task_id": .string("task")])]))
    }
    @Test func strictProviderNullFieldsReachOnlyTheSelectedAdapter() throws {
        let route = try #require(try AgentConversationRouting.route(tool: "agent_read", input: normalizedToolArguments("agent_read", [
            "agent": .string("claude"), "conversation_id": .null,
            "message_id": .string("exact"), "task_id": .null,
            "limit": .int(1), "offset": .int(0)
        ])))
        #expect(route.tool == "delegation_status")
        #expect(route.input["message_id"] == .string("exact"))
        #expect(route.input["task_id"] == nil)
        let send = try #require(try AgentConversationRouting.route(tool: "agent_message", input: normalizedToolArguments("agent_message", [
            "agent": .string("codex"), "text": .string("hello"), "conversation_id": .null,
            "message_id": .null, "task_id": .null,
            "options": .object(["model": .null, "fast": .null, "timeout_seconds": .null])
        ])))
        #expect(send.input["model"] == nil)
        #expect(send.input["conversation_mode"] == .string("new"))
    }
    @Test func continuationPreservesHarnessAndExactRemoteIdentifiers() throws {
        let route = try #require(try AgentConversationRouting.route(tool: "agent_message", input: [
            "agent": .string("claude"), "text": .string("Continue that review."),
            "conversation_id": .string("claude:existing-conversation"), "message_id": .string("exact-message"),
            "session_id": .string("local-chat"), "__session_id": .string("harness-chat"),
            "options": .object(["timeout_seconds": .int(120)])
        ]))
        #expect(route.tool == "claude_message")
        #expect(route.agent == "claude")
        #expect(route.input["conversation_mode"] == .string("resume"))
        #expect(route.input["conversation_id"] == .string("claude:existing-conversation"))
        #expect(route.input["message_id"] == .string("exact-message"))
        #expect(route.input["session_id"] == .string("local-chat"))
        #expect(route.input["__session_id"] == .string("harness-chat"))
        #expect(route.input["timeout_seconds"] == .int(120))
    }

    @Test func malformedHarnessContextIsNotSilentlyRemoved() throws {
        let route = try #require(try AgentConversationRouting.route(tool: "agent_message", input: [
            "agent": .string("codex"), "text": .string("Hello"), "__session_id": .int(7)
        ]))
        #expect(route.input["__session_id"] == .int(7))
        #expect(route.input["conversation_mode"] == .string("new"))
    }

    @Test func rejectsIgnoredOptionsAndContinuationConflicts() {
        let bad: [[String: JSONValue]] = [
            ["agent": .string("codex"), "text": .string("Hi"), "options": .object(["session_id": .string("forged")])],
            ["agent": .string("omp"), "text": .string("Hi"), "options": .object(["model": .string("ignored")])],
            ["agent": .string("codex"), "text": .string("Hi"), "conversation_id": .string("existing"), "options": .object(["topic": .string("new")])],
            ["agent": .string("codex"), "text": .string("Hi"), "options": .object(["fast": .string("true")])],
            ["agent": .string("codex"), "text": .string("Hi"), "options": .object(["timeout_seconds": .int(0)])],
            ["agent": .string("bot:bad"), "text": .string("Hi")],
            ["agent": .string("peer:bad"), "text": .string("Hi")],
            ["agent": .string("codex"), "text": .string("Hi"), "conversation_mode": .string("new")]
        ]
        for input in bad {
            #expect(throws: AgentConversationRouting.InvalidRequest.self) {
                try AgentConversationRouting.route(tool: "agent_message", input: input)
            }
        }
    }

    @Test func peerIsLeftToItsAdapter() throws {
        #expect(try AgentConversationRouting.route(tool: "agent_message", input: [
            "agent": .string("peer:" + UUID().uuidString), "text": .string("Hello")
        ]) == nil)
        #expect(try AgentConversationRouting.route(tool: "read_file", input: [:]) == nil)
    }

    @Test func botContinuationAndExactReceiptRemainBoundToSameBot() throws {
        let bot = UUID().uuidString
        let entry = UUID().uuidString
        let route = try #require(try AgentConversationRouting.route(tool: "agent_message", input: [
            "agent": .string("bot:" + bot), "text": .string("Follow up"), "conversation_id": .string("bot:" + bot)
        ]))
        #expect(route.tool == "bot_ask")
        #expect(route.input == ["id": .string(bot), "question": .string("Follow up")])
        let read = try #require(try AgentConversationRouting.route(tool: "agent_read", input: [
            "agent": .string("bot:" + bot), "message_id": .string(entry)
        ]))
        #expect(read.tool == "shelf_entry")
        #expect(read.input["id"] == .string(entry))
        #expect(read.input["bot_id"] == .string(bot))
        #expect(throws: AgentConversationRouting.InvalidRequest.self) {
            try AgentConversationRouting.route(tool: "agent_message", input: [
                "agent": .string("bot:" + bot), "text": .string("Hello"), "conversation_id": .string("bot:" + UUID().uuidString)
            ])
        }
        #expect(throws: AgentConversationRouting.InvalidRequest.self) {
            try AgentConversationRouting.route(tool: "agent_message", input: [
                "agent": .string("bot:" + bot), "text": .string("Hello"), "message_id": .string(entry)
            ])
        }
    }

    @Test func readsUseCanonicalProjectorAndNeverIgnoreConversationFilter() throws {
        let route = try #require(try AgentConversationRouting.route(tool: "agent_read", input: [
            "agent": .string("codex"), "message_id": .string("exact"), "limit": .int(3), "offset": .int(2)
        ]))
        #expect(route.tool == "delegation_status")
        #expect(route.input == ["agent": .string("codex"), "message_id": .string("exact"), "limit": .int(3), "offset": .int(2), "detail": .string("full")])
        #expect(throws: AgentConversationRouting.InvalidRequest.self) {
            try AgentConversationRouting.route(tool: "agent_read", input: ["agent": .string("codex"), "conversation_id": .string("existing")])
        }
    }

    @Test(arguments: ["queued", "waiting_approval", "unknown", "failed", "completed"])
    func receiptWrappingPreservesLifecycleAndEveryOwnerField(status: String) throws {
        let route = AgentConversationRouting.Route(tool: "codex_message", input: [:], agent: "codex")
        let original: [String: JSONValue] = ["status": .string(status), "conversationId": .string("remote"), "messageId": .string("accepted"), "delivery": .object(["known": .bool(false)])]
        guard case .object(let wrapped) = AgentConversationRouting.wrap(result: .object(original), route: route) else { Issue.record("Not an object"); return }
        for (key, value) in original { #expect(wrapped[key] == value) }
        #expect(wrapped["conversation_id"] == .string("remote"))
        #expect(wrapped["message_id"] == .string("accepted"))
        #expect(wrapped["agent"] == .string("codex"))
    }

    @Test func botReceiptKeepsActualSessionSeparateAndFailuresDoNotInventAcceptance() {
        let bot = "bot:" + UUID().uuidString
        let route = AgentConversationRouting.Route(tool: "bot_ask", input: [:], agent: bot)
        guard case .object(let wrapped) = AgentConversationRouting.wrap(result: .object([
            "status": .string("waiting_on_you"), "session_id": .string("actual-chat"), "entry_id": .string("entry")
        ]), route: route) else { Issue.record("Not an object"); return }
        #expect(wrapped["session_id"] == .string("actual-chat"))
        #expect(wrapped["conversation_id"] == .string(bot))
        #expect(wrapped["message_id"] == .string("entry"))
        let coding = AgentConversationRouting.Route(tool: "codex_message", input: ["message_id": .string("unaccepted")], agent: "codex")
        guard case .object(let failure) = AgentConversationRouting.wrap(result: .object(["status": .string("error")]), route: coding) else { Issue.record("Not an object"); return }
        #expect(failure["message_id"] == nil)
        #expect(failure["conversation_id"] == nil)
        #expect(failure["status"] == .string("error"))
    }
}
