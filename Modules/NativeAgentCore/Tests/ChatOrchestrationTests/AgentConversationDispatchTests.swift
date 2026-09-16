import Foundation
import Testing
@testable import ChatOrchestration
import NativeAgentCore
import PersistenceCore
import ProviderRouting
import TrustCenter
import StandingBots

private actor ConversationGateProbe: ToolDispatchClient {
    let trust: SwiftNativeTrustCenter
    let policy: [String: JSONValue]
    private(set) var calls: [(String, [String: JSONValue], GatedToolNameAlias?)] = []
    init(root: URL, blocked: String? = nil) {
        trust = SwiftNativeTrustCenter(dataRoot: root)
        policy = ["autonomyDefault": .string("auto"), "autonomyOverrides": .object(blocked.map { [$0: .string("blocked")] } ?? [:])]
    }
    func dispatch(tool: String, input: [String: JSONValue], surface: String) async throws -> JSONValue {
        calls.append((tool, input, GatedToolNameContext.alias))
        let level = trust.autonomyForTool(tool, policy: policy)
        return .object(["status": .string(level == "blocked" ? "blocked" : "queued"), "messageId": .string("receipt")])
    }
    func listAvailableTools() async throws -> [String] { [] }
    func listAvailableToolSchemas() async throws -> [LLMToolSchema] { [] }
}

@Suite struct AgentConversationDispatchTests {
    private func root() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("agent-conversation-dispatch-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    @Test func translationPrecedesGatesAndNestedCanonicalizersPreservePolicyAndSession() async throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let probe = ConversationGateProbe(root: root)
        let client = CanonicalToolNameDispatcher(inner: CanonicalToolNameDispatcher(inner: probe))
        let result = try await client.dispatch(tool: "agent_message", input: [
            "agent": .string("codex"), "text": .string("Hello"), "session_id": .string("chat"), "__session_id": .string("verified")
        ], surface: "chat")
        let calls = await probe.calls
        #expect(calls.count == 1)
        let call = try #require(calls.first)
        #expect(call.0 == "codex_message")
        #expect(call.1["session_id"] == .string("chat"))
        #expect(call.1["__session_id"] == .string("verified"))
        #expect(call.2 == GatedToolNameAlias(raw: "agent_message", canonical: "codex_message"))
        guard case .object(let object) = result else { Issue.record("Missing receipt"); return }
        #expect(object["status"] == .string("queued"))
        #expect(object["message_id"] == .string("receipt"))
        #expect(CanonicalToolNameDispatcher.canonical("agent.message") == "agent.message")
        #expect(CanonicalToolNameDispatcher.canonical("agent.read") == "agent.read")
    }

    @Test func peerSpecificArgumentsReachTheirOwnValidator() throws {
        let route = try AgentConversationRouting.route(tool: "agent_read", input: [
            "agent": .string("peer:" + UUID().uuidString), "task_id": .string("remote-task"), "max_chars": .int(1000)
        ])
        #expect(route == nil)
    }

    @Test(arguments: ["agent_message", "codex_message"])
    func eitherExplicitPolicyNameCanBlockTheTranslatedCall(blocked: String) async throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let probe = ConversationGateProbe(root: root, blocked: blocked)
        let result = try await CanonicalToolNameDispatcher(inner: probe).dispatch(tool: "agent_message", input: [
            "agent": .string("codex"), "text": .string("Hello")
        ], surface: "chat")
        guard case .object(let object) = result else { Issue.record("Missing refusal"); return }
        #expect(object["status"] == .string("blocked"))
    }

    @Test func lazyGateAcceptsOnlyLoadedMatchingFacadeAndHonorsExplicitUnload() async throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let dispatcher = SwiftToolDispatcher(dataRoot: root, enforceLazyToolLoading: true)
        let session = "routing-test"
        _ = try await dispatcher.activeToolsStore.addLoaded(sessionId: session, names: ["agent_message"])
        let args: [String: JSONValue] = ["__session_id": .string(session)]
        let catalog = ["agent_message", "agent_read", "codex_message", "claude_message", "omp_message", "bot_ask", "delegation_status", "shelf_entry", "shelf_read"]
        await SwiftToolDispatcher.$lazyGateCatalogOverrideForTests.withValue({ catalog }) {
            for tool in ["codex_message", "claude_message", "omp_message", "bot_ask"] {
                let allowed = await GatedToolNameContext.$alias.withValue(.init(raw: "agent_message", canonical: tool)) {
                    await dispatcher.lazyToolLoadingRefusal(tool: tool, input: args)
                }
                #expect(allowed == nil)
            }
            let bare = await dispatcher.lazyToolLoadingRefusal(tool: "codex_message", input: args)
            #expect(bare != nil)
            let wrong = await GatedToolNameContext.$alias.withValue(.init(raw: "agent_message", canonical: "shelf_entry")) {
                await dispatcher.lazyToolLoadingRefusal(tool: "shelf_entry", input: args)
            }
            #expect(wrong != nil)
            let unread = await GatedToolNameContext.$alias.withValue(.init(raw: "agent_read", canonical: "delegation_status")) {
                await dispatcher.lazyToolLoadingRefusal(tool: "delegation_status", input: args)
            }
            #expect(unread != nil)
            await dispatcher.activeToolsStore.noteTurnUnloaded(sessionId: session, names: ["agent_message"])
            let unloaded = await GatedToolNameContext.$alias.withValue(.init(raw: "agent_message", canonical: "codex_message")) {
                await dispatcher.lazyToolLoadingRefusal(tool: "codex_message", input: args)
            }
            #expect(unloaded != nil)
        }
        _ = try await dispatcher.activeToolsStore.addLoaded(sessionId: session, names: ["agent_read"])
        await SwiftToolDispatcher.$lazyGateCatalogOverrideForTests.withValue({ catalog }) {
            for tool in ["delegation_status", "shelf_read", "shelf_entry"] {
                let allowed = await GatedToolNameContext.$alias.withValue(.init(raw: "agent_read", canonical: tool)) {
                    await dispatcher.lazyToolLoadingRefusal(tool: tool, input: args)
                }
                #expect(allowed == nil)
            }
        }
    }

    @Test func crossBotExactReadDoesNotAcknowledgeTheEntry() async throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let bot = try BotDefinitionStore(dataRoot: root).create(BotDefinition(name: "Test", brief: "Read fixture facts", cadence: .manual, budget: .init(tokens: 500, seconds: 30)))
        let now = Date()
        let entry = ShelfEntry(botId: bot.id, briefVersion: bot.briefVersion, runAt: now, coverageStart: now, coverageEnd: now,
                               headline: "Fixture", findings: "Retained fact", changedSinceLastGood: "First run", runHealth: .ok, spend: .init(tokens: 1, seconds: 1))
        let shelf = ShelfStore(dataRoot: root)
        try shelf.append(entry)
        let dispatcher = SwiftToolDispatcher(dataRoot: root)
        let result = try await dispatcher.impl_standingBots(tool: "shelf_entry", input: ["id": .string(entry.id.uuidString), "bot_id": .string(UUID().uuidString)])
        guard case .object(let refusal) = result else { Issue.record("Missing refusal"); return }
        #expect(refusal["status"] != .string("ok"))
        #expect(try shelf.readCursor(readerId: SwiftToolDispatcher.standingBotReaderID).readEntryIds.isEmpty)
        _ = try await dispatcher.impl_standingBots(tool: "shelf_entry", input: ["id": .string(entry.id.uuidString), "bot_id": .string(bot.id.uuidString)])
        #expect(try shelf.readCursor(readerId: SwiftToolDispatcher.standingBotReaderID).readEntryIds.contains(entry.id))
    }
}
