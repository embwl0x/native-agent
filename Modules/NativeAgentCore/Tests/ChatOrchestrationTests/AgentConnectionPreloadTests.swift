import Foundation
import Testing
@testable import ChatOrchestration

@Suite struct AgentConnectionPreloadTests {
    @Test(arguments: ["Disconnect from Codex", "Connect to Claude Code", "connect to CC"])
    func connectionRequestsOfferContactTools(message: String) throws {
        let prediction = try #require(ToolPreloadHeuristics.predict(userMessage: message))
        let names = ToolPreloadHeuristics.preloadableNames(prediction: prediction,
            availableToolNames: ["agent_contacts", "agent_connect"], alreadyActive: [])
        #expect(names.contains("agent_contacts"))
        #expect(names.contains("agent_connect"))
    }

    @Test func nameAloneDoesNotMeanConnection() {
        let prediction = ToolPreloadHeuristics.predict(userMessage: "What is Codex?")
        #expect(prediction?.groupNames.contains("delegation") != true)
    }

    @Test(arguments: ["connect to Wi-Fi", "disconnect", "disconnect from My Research Friend", "connect to Codexish", "connect to Claude"])
    func unrelatedConnectionsLoadNothing(message: String) {
        #expect(ToolPreloadHeuristics.predict(userMessage: message) == nil)
    }

    @Test func savedContactNameEnablesConnectionPreload() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AgentPeerStore(dataRoot: root)
        _ = try store.upsert(AgentPeerContact(name: "My Research Friend",
            endpoint: URL(string: "https://example.com/agent")!, transport: .a2a))
        let prediction = ToolPreloadHeuristics.predict(userMessage: "disconnect from MY RESEARCH FRIEND",
            dataRoot: root)
        #expect(prediction?.groupNames.contains("delegation") == true)
    }
}
