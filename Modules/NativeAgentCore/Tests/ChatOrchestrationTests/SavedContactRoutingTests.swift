import Foundation
import Testing
import NativeAgentCore
@testable import ChatOrchestration

@Suite struct SavedContactRoutingTests {
    @Test func catalogPutsSavedContactAheadOfBotTools() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try AgentPeerStore(dataRoot: root).upsert(AgentPeerContact(
            name: "Grok Bot", endpoint: URL(string: "https://agent.example")!, transport: .a2a))
        let dispatcher = SwiftToolDispatcher(dataRoot: root)
        for query in ["gRoK bOt", "Ask GROK BOT this: what is 6 times 7?"] {
            let result = try await dispatcher.impl_tool_catalog(input: ["query": .string(query), "limit": .int(1)])
            guard case .object(let envelope) = result,
                  case .array(let matches)? = envelope["matches"],
                  case .object(let first)? = matches.first else {
                Issue.record("Missing contact match"); return
            }
            #expect(first["name"] == .string("agent_message"))
            #expect(first["load_state"] == .string("loaded"))
            #expect(first["description"] == .string("Grok Bot is a saved agent contact; agent_message reaches it — no load needed."))
            #expect(envelope["load_next"] == nil)
        }
    }

    @Test func predictionUsesSavedNamesAndWholeNameBoundaries() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AgentPeerStore(dataRoot: root)
        try store.upsert(AgentPeerContact(name: "Grok Bot", endpoint: URL(string: "https://agent.example")!, transport: .a2a))
        let message = "Ask grok bot this: what is 6 times 7?"
        #expect(ToolPreloadHeuristics.predict(userMessage: message, dataRoot: root)?.candidateTools == ["agent_message"])
        #expect(try store.namesMentioned(in: "Ask Grok Bots").isEmpty)
        #expect(try store.namesMentioned(in: "Ask NotGrok Bot").isEmpty)
        #expect(try store.namesMentioned(in: "Ask another bot").isEmpty)
        #expect(ToolPreloadHeuristics.predict(userMessage: "Connect Grok Bot", dataRoot: root)?.candidateTools.contains("agent_connect") == true)
    }
}
