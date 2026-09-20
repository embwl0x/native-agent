import Foundation
import Testing
import NativeAgentCore
import PersistenceCore
@testable import ChatOrchestration

private struct OrderedRefreshCatalog: ToolDispatchClient {
    let schemas: [LLMToolSchema]
    func listAvailableTools() async throws -> [String] { schemas.map(\.name) }
    func listAvailableToolSchemas() async throws -> [LLMToolSchema] { schemas }
    func dispatch(tool: String, input: [String: JSONValue], surface: String) async throws -> JSONValue { .null }
}

@Test func toolRefreshKeepsPersistedOrderAcrossLoadsAndTurns() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = ActiveToolsStore(dataRoot: root)
    func schema(_ name: String) -> LLMToolSchema {
        LLMToolSchema(name: name, description: name, parametersJSON: Data(#"{"type":"object","properties":{}}"#.utf8))
    }
    let floor = schema("tool_load")
    let first = schema("z_first")
    let second = schema("a_second")
    let third = schema("b_third")
    _ = try await store.addLoaded(sessionId: "order", names: [first.name], descriptors: [first.name: PinnedToolSchema(first)])
    _ = try await store.addLoaded(sessionId: "order", names: [third.name, second.name], descriptors: [second.name: PinnedToolSchema(second), third.name: PinnedToolSchema(third)])
    // Catalog order disagrees with both load chronology and the sorted batch.
    let catalog = OrderedRefreshCatalog(schemas: [third, second, floor, first])
    let refreshed = await SameTurnToolSchemaRefresh.afterLoad(
        current: [floor], sessionId: "order", tools: catalog, activeToolsStore: store
    )
    #expect(refreshed.map(\.name) == [floor.name, first.name, second.name, third.name])
    let nextTurn = SwiftToolDispatcher.canonicalToolOrder(
        catalog.schemas.map(\.name), loadOrder: await store.load(sessionId: "order").advertisedLoadOrder
    )
    #expect(refreshed.map(\.name) == nextTurn.advertised)
    let repeated = await SameTurnToolSchemaRefresh.afterLoad(
        current: refreshed, sessionId: "order", tools: catalog, activeToolsStore: store
    )
    #expect(repeated.map(\.name) == refreshed.map(\.name))
    #expect(repeated.map(\.parametersJSON) == refreshed.map(\.parametersJSON))
}
