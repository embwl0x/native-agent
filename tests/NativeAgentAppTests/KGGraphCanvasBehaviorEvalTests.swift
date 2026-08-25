import CoreGraphics
import Foundation
import KnowledgeGraph
import MemoryV2
import Testing
@testable import NativeAgentApp

@Suite("Knowledge graph canvas behavior", .serialized)
struct KGGraphCanvasBehaviorEvalTests {
    private func temporaryRoot(_ label: String) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("kg-graph-canvas-\(label)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func edge(from: String, to: String, kind: String = "related") throws -> KGEdge {
        let data = Data("""
        {"from":"\(from)","to":"\(to)","kind":"\(kind)"}
        """.utf8)
        return try JSONDecoder().decode(KGEdge.self, from: data)
    }

    private func entity(id: String, name: String = "Entity") throws -> KGEntity {
        let data = Data("""
        {"id":"\(id)","name":"\(name)","type":"fact"}
        """.utf8)
        return try JSONDecoder().decode(KGEntity.self, from: data)
    }

    // app.mind / ui.kg.graphCanvas
    @Test("the real graph writer and scoped reader feed a stable in-bounds canvas layout")
    func canonicalGraphProjectsIntoTheCanvas() async throws {
        let root = try temporaryRoot("canonical")
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = try MemoryStorage(dataRoot: root)
        let indexer = try SwiftNativeKnowledgeGraphIndexer(memorySQLitePath: await storage.path)
        for fact in [
            (id: "canvas-memory-1", content: "NativeAgent prepares a release plan."),
            (id: "canvas-memory-2", content: "The release plan has source links."),
        ] {
            _ = try await storage.insertMemory(StoredMemory(id: fact.id, content: fact.content))
            try await indexer.indexMemory(KnowledgeGraphMemoryFact(
                id: fact.id,
                content: fact.content,
                createdAt: "2026-08-24T00:00:00Z",
                updatedAt: "2026-08-24T00:00:00Z"
            ))
        }

        let response = try await NativeClient(baseURL: "", dataRootOverride: root)
            .getKnowledgeGraph(page: 0)
        let nodes = KGGraphCanvasLayout.canonicalEntities(response.entities)
        try #require(!nodes.isEmpty)
        let edges = KGGraphCanvasLayout.visibleEdges(response.edges ?? [], among: nodes)
        let size = CGSize(width: 480, height: 300)
        let first = KGGraphCanvasLayout.positions(
            entities: nodes, edges: edges, in: size, nodeRadius: 14
        )
        let second = KGGraphCanvasLayout.positions(
            entities: nodes, edges: edges, in: size, nodeRadius: 14
        )

        #expect(Set(first.keys) == Set(nodes.map(\.id)))
        #expect(first == second, "a relaunch-shaped redraw must not reshuffle the same graph")
        for point in first.values {
            #expect(point.x >= 14 && point.x <= size.width - 14)
            #expect(point.y >= 14 && point.y <= size.height - 14)
        }
    }

    // app.mind / ui.kg.graphCanvas
    @Test("duplicate ids and off-canvas edges cannot create invisible layout participants")
    func canvasSanitizesPartialGraphInputAndTracksEdgeOnlyChanges() throws {
        let first = try entity(id: "first", name: "First")
        let duplicate = try entity(id: "first", name: "Duplicate")
        let second = try entity(id: "second", name: "Second")
        let blank = try entity(id: "", name: "Blank")
        let valid = try edge(from: "first", to: "second")
        let duplicateEdge = try edge(from: "first", to: "second")
        let ghost = try edge(from: "first", to: "missing")

        let nodes = KGGraphCanvasLayout.canonicalEntities([duplicate, blank, second, first])
        let visible = KGGraphCanvasLayout.visibleEdges([ghost, duplicateEdge, valid], among: nodes)
        #expect(nodes.map(\.id) == ["first", "second"])
        #expect(visible.map(\.id) == [valid.id])
        #expect(KGGraphCanvasLayout.signature(entities: nodes, edges: [])
            != KGGraphCanvasLayout.signature(entities: nodes, edges: visible))
        #expect(KGGraphCanvasLayout.positions(
            entities: [], edges: visible, in: CGSize(width: 200, height: 120), nodeRadius: 14
        ).isEmpty)
    }

    // EVAL FENCE: app.mind / ui.kg.graphSafetyNet
    @Test("the canvas owner itself blocks oversized layouts while admitting a canonical 200-node slice")
    func canvasSafetyNetCannotBeBypassedOutsideTheParentPicker() throws {
        let oversized = try (0...KGGraphCanvasLayout.maximumRenderableEntities).map {
            try entity(id: "node-\($0)", name: "Node \($0)")
        }
        #expect(KGGraphCanvasLayout.renderSafety(for: oversized)
            == .tooLarge(entityCount: KGGraphCanvasLayout.maximumRenderableEntities + 1))
        #expect(KGGraphCanvasLayout.positions(
            entities: oversized,
            edges: [],
            in: CGSize(width: 500, height: 320),
            nodeRadius: 14
        ).isEmpty,
        "direct layout callers must not bypass the same cap the mounted graph picker uses")

        // The cap applies to real canvas participants, not duplicate wire
        // rows. This preserves a usable graph when a malformed response
        // repeats one id but canonicalization reduces it to the safe bound.
        let canonicalBound = Array(oversized.dropLast()) + [try entity(id: "node-0", name: "Duplicate")]
        #expect(KGGraphCanvasLayout.renderSafety(for: canonicalBound)
            == .render(entityCount: KGGraphCanvasLayout.maximumRenderableEntities))
        #expect(KGGraphCanvasLayout.positions(
            entities: canonicalBound,
            edges: [],
            in: CGSize(width: 500, height: 320),
            nodeRadius: 14
        ).count == KGGraphCanvasLayout.maximumRenderableEntities)
    }

    // app.mind / ui.kg.graphCanvas
    @Test("an unreadable canonical graph is unavailable, not an empty canvas")
    @MainActor
    func unreadableGraphReaderDoesNotManufactureAnEmptyCanvas() async throws {
        let root = try temporaryRoot("unreadable")
        defer { try? FileManager.default.removeItem(at: root) }
        let memory = root.appendingPathComponent("memory", isDirectory: true)
        try FileManager.default.createDirectory(at: memory, withIntermediateDirectories: true)
        try Data("not a sqlite database".utf8).write(to: memory.appendingPathComponent("memory.sqlite"))

        let client = NativeClient(baseURL: "", dataRootOverride: root)
        await #expect(throws: (any Error).self) {
            _ = try await client.getKnowledgeGraph(page: 0)
        }
        #expect(KnowledgeGraphPresentation.content(
            isLoading: false,
            error: "Knowledge graph store could not be read",
            entityCount: 0,
            displayedEntityCount: 0,
            isEnabled: true,
            viewMode: .graph
        ) == .unavailable("Knowledge graph store could not be read"))
    }
}
