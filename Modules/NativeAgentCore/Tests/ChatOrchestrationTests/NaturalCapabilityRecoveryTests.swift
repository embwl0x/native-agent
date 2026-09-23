import Foundation
import Testing
import NativeAgentCore
import PersistenceCore
@testable import ChatOrchestration

@Suite struct NaturalCapabilityRecoveryTests {
    @Test func findAndLoadRequestsTheSameTurnSchemaRefresh() {
        let schemas = ["tool_catalog", "list_tools", "tool_load"].map {
            LLMToolSchema(name: $0, description: "fixture", parametersJSON: Data("{}".utf8))
        }
        let names = ProviderToolNameMap(schemas)
        for tool in ["tool_catalog", "list_tools"] {
            #expect(SameTurnToolSchemaRefresh.wasRequested(
                calls: [.init(id: "check", name: tool, input: ["load": .bool(true)])], providerTools: names))
            #expect(!SameTurnToolSchemaRefresh.wasRequested(
                calls: [.init(id: "check", name: tool, input: ["load": .bool(false)])], providerTools: names))
        }
    }

    @Test func catalogSelectionRequiresUniqueNativeWinner() {
        func row(_ name: String, _ score: Int64) -> JSONValue {
            .object(["name": .string(name), "match_score": .int(score)])
        }
        func result(_ rows: [JSONValue]) -> JSONValue {
            .object(["status": .string("ok"), "matches": .array(rows)])
        }
        #expect(ToolCatalogSelection.selectedName(in: result([row("read_file", 40), row("write_file", 30)])) == "read_file")
        #expect(ToolCatalogSelection.selectedName(in: result([row("read_file", 40), row("read_page", 40)])) == nil)
        #expect(ToolCatalogSelection.selectedName(in: result([row("mcp__peer__send", 40)])) == nil)
        #expect(ToolCatalogSelection.searchInput(["load": .bool(true), "limit": .int(1)])["limit"] == .int(2))
    }

    @Test func continuationRetainsModeAndRefusesOtherScopes() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ProviderToolResultRecoveryStore(root: root)
        let receipt = try #require(await store.store(content: String(repeating: "a", count: 8_000) + "tail",
            toolName: "write_file", sessionId: "chat", turnId: "turn", originalResultClass: .failed))
        _ = await store.page(handle: receipt.handle, page: 0, sessionId: "chat", turnId: "turn", query: nil)
        guard case .object(let next) = await store.continueReading(handle: nil, sessionId: "chat", turnId: "turn") else {
            Issue.record("No continuation"); return
        }
        #expect(next["page"] == .int(1))
        #expect(next["content"] == .string("tail"))
        #expect(next["original_result_class"] == .string("failed"))
        guard case .object(let end) = await store.continueReading(handle: nil, sessionId: "chat", turnId: "turn"),
              case .object(let other) = await store.continueReading(handle: nil, sessionId: "other", turnId: "turn") else {
            Issue.record("Missing recovery state"); return
        }
        #expect(end["reading_complete"] == .bool(true))
        #expect(other["reason"] == .string("result_handle_unavailable"))
        #expect(other["content"] == nil)
    }
}
