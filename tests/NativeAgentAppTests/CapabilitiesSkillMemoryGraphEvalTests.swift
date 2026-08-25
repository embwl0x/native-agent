import Foundation
import KnowledgeGraph
import MemoryV2
import Testing
@testable import NativeAgentApp

private func skillMemoryGraphRoot() throws -> URL {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("capabilities-skill-graph-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}

@Suite("Capabilities skill memory graph — root-resolved projection")
struct CapabilitiesSkillMemoryGraphEvalTests {
    @Test("the panel renders and searches the canonical graph under its app root")
    @MainActor
    func panelUsesTheInjectedGraphRootForProjectionAndSearch() async throws {
        let root = try skillMemoryGraphRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = try MemoryStorage(dataRoot: root)
        let fact = KnowledgeGraphMemoryFact(
            id: "capability-root-fact",
            content: "Root scoped capability graph memory",
            createdAt: "2026-08-24T00:00:00Z",
            updatedAt: "2026-08-24T00:00:00Z"
        )
        _ = try await storage.insertMemory(StoredMemory(id: fact.id, content: fact.content))
        let indexer = try SwiftNativeKnowledgeGraphIndexer(memorySQLitePath: await storage.path)
        try await indexer.indexMemory(fact)

        let client = NativeClient(baseURL: "", dataRootOverride: root)
        let graph = try await client.getAgentGraph()
        let entities = try await client.getGraphEntities()
        let status = try await client.getGraphStatus()
        let entity = try #require(entities.first)
        let search = try await client.searchGraph(query: entity.name)
        #expect(graph.summary.nodes == entities.count)
        #expect((status.entityCount ?? -1) == entities.count)
        #expect(search.results.contains(where: { $0.node.id == entity.id }))

        let app = AppModel(dataRootOverride: root, startBackgroundTasks: false)
        await app.refreshForSidebarItem(.capabilities)
        #expect(app.agentGraph?.summary.nodes == graph.summary.nodes)
        #expect(app.graphEntities.count == entities.count)
        #expect(app.graphStatus?.entityCount == status.entityCount)
        #expect(app.graphLoadError == nil)
        await app.searchGraph(entity.name)
        #expect(app.graphSearchResults.contains(where: { $0.node.id == entity.id }))
        #expect(app.graphEntities.contains(where: { $0.id == entity.id }))
    }

    @Test("a damaged graph root is visibly unavailable rather than an empty graph")
    @MainActor
    func panelSurfacesARealGraphReadFailure() async throws {
        let root = try skillMemoryGraphRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let memoryDirectory = root.appendingPathComponent("memory", isDirectory: true)
        try FileManager.default.createDirectory(at: memoryDirectory, withIntermediateDirectories: true)
        try Data("not a sqlite database".utf8).write(
            to: memoryDirectory.appendingPathComponent("memory.sqlite")
        )

        let app = AppModel(dataRootOverride: root, startBackgroundTasks: false)
        await app.refreshGraph()
        #expect(app.agentGraph == nil)
        let error = try #require(app.graphLoadError)
        #expect(!error.isEmpty)
        #expect(app.graphEntities.isEmpty)
        #expect(app.graphSearchResults.isEmpty)
    }
}
