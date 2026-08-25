import Foundation
import KnowledgeGraph
import MemoryV2
import Testing
@testable import NativeAgentApp

// EVAL FENCE: app.runtimes / client.knowledgeGraphView
@Suite("Native client knowledge graph view read")
struct NativeClientKnowledgeGraphViewReadEvalTests {
    @Test("one checked graph snapshot supplies mutually consistent mounted-view projections")
    func mountedViewReadUsesOneInjectedGraphRoot() async throws {
        let root = try temporaryRoot("healthy")
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = try MemoryStorage(dataRoot: root)
        let fact = KnowledgeGraphMemoryFact(
            id: "knowledge-graph-view-read",
            content: "The graph view must retain one checked projection.",
            createdAt: "2026-08-24T00:00:00Z",
            updatedAt: "2026-08-24T00:00:00Z"
        )
        _ = try await storage.insertMemory(StoredMemory(id: fact.id, content: fact.content))
        let indexer = try SwiftNativeKnowledgeGraphIndexer(memorySQLitePath: await storage.path)
        try await indexer.indexMemory(fact)
        let client = NativeClient(baseURL: "", dataRootOverride: root)
        let factNodeID = SwiftNativeKnowledgeGraphIndexer.memoryFactEntityID(for: fact.id)

        let read = try await client.getKnowledgeGraphViewRead()

        #expect(read.entities.contains { $0.id == factNodeID },
                "the canonical snapshot must retain the indexed MemoryV2 fact node")
        #expect(read.agentGraph.nodes.map(\.id) == read.entities.map(\.id))
        #expect(read.agentGraph.summary.nodes == read.entities.count)
        #expect(read.status.nodeCount == read.entities.count)
        #expect(read.status.entityCount == read.entities.count)
    }

    @Test("a damaged authoritative SQLite graph refuses the whole mounted view read")
    func damagedAuthoritativeGraphIsNotAnEmptyView() async throws {
        let root = try temporaryRoot("damaged")
        defer { try? FileManager.default.removeItem(at: root) }
        let memory = root.appendingPathComponent("memory", isDirectory: true)
        try FileManager.default.createDirectory(at: memory, withIntermediateDirectories: true)
        try Data("not a SQLite database".utf8).write(
            to: memory.appendingPathComponent("memory.sqlite")
        )
        try Data("""
        {"entities":{"stale":{"id":"stale","name":"Stale fallback","type":"concept"}},"edges":[]}
        """.utf8).write(to: memory.appendingPathComponent("knowledge_graph.json"))
        let client = NativeClient(baseURL: "", dataRootOverride: root)

        await #expect(throws: (any Error).self) {
            _ = try await client.getKnowledgeGraphViewRead()
        }
    }

    private func temporaryRoot(_ label: String) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("native-client-kg-view-\(label)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
}
