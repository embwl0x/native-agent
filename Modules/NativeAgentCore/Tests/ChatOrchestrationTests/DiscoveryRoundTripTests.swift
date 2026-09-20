import Foundation
import Testing
@testable import ChatOrchestration
import NativeAgentCore
import PersistenceCore

@Suite("Discovery round trips")
struct DiscoveryRoundTripTests {
    private func schema(_ name: String) -> LLMToolSchema {
        LLMToolSchema(name: name, description: name,
                      parametersJSON: Data(#"{"type":"object","properties":{}}"#.utf8))
    }

    @Test(arguments: [false, true])
    func lateMCPAndReverseAlphabeticalLoadsKeepPersistedPrefix(stable: Bool) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let servers = root.appendingPathComponent("mcp/servers.json")
        try FileManager.default.createDirectory(at: servers.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(#"[{"id":"new","status":"ready"}]"#.utf8).write(to: servers)
        let store = ActiveToolsStore(dataRoot: root)
        let session = "discovery-order"
        let first = "workshop_status", second = "market_status", mcp = "mcp__new__read"
        var catalog = [schema(first), schema(second)]
        _ = try await store.addLoaded(sessionId: session, names: [first], descriptors: [first: PinnedToolSchema(schema(first))])
        _ = await store.commitTurnStartContract(sessionId: session, promoting: [], catalog: catalog, stableToolArray: stable)
        catalog.insert(schema(mcp), at: 0)
        _ = await store.commitTurnStartContract(sessionId: session, promoting: [], catalog: catalog, stableToolArray: stable)
        _ = try await store.addLoaded(sessionId: session, names: [second])
        // Explicitly loading an already pinned MCP must not move its slot.
        _ = try await store.addLoaded(sessionId: session, names: [mcp])
        let commit = try #require(await store.commitTurnStartContract(
            sessionId: session, promoting: [], catalog: Array(catalog.reversed()), stableToolArray: stable))
        let expected = [first, mcp, second]
        #expect(commit.state.loadOrder == expected)
        let restored = await ActiveToolsStore(dataRoot: root).load(sessionId: session)
        #expect(restored.loadOrder == expected)
        let context = TurnContext(surface: "chat", personaDocs: [:], recalled: [], modelId: "test",
            reasoningEffort: "high", toolsAvailable: catalog.map(\.name), systemPrompt: "test",
            userMessage: "continue", toolSchemas: catalog)
        let filtered = SwiftNativeChatOrchestrationClient.applyLazyToolFilter(
            to: context, activeTools: restored.activeTools, contract: restored.toolContract)
        #expect(filtered?.toolSchemas.map(\.name) == expected)
    }

}
