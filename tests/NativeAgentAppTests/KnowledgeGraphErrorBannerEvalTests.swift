import Foundation
import KnowledgeGraph
import MemoryV2
import Testing
@testable import NativeAgentApp

// EVAL FENCE: app.mind / ui.kg.errorBanner

@MainActor
@Suite("Knowledge Graph error banner", .serialized)
struct KnowledgeGraphErrorBannerEvalTests {
    @Test("load failures win over the healthy empty state, while retained rows are explicitly stale")
    func loadFailureKeepsPriorGraphVisibleAndLabelsItsProvenance() throws {
        let placement = KnowledgeGraphPresentation.errorPlacement(
            isLoading: false,
            error: "Knowledge graph store could not be read: damaged SQLite",
            entityCount: 1,
            errorOrigin: .graphLoad
        )
        #expect(placement == .retainedDataBanner(
            message: "Knowledge graph store could not be read: damaged SQLite",
            isStale: true
        ))
        #expect(KnowledgeGraphPresentation.content(
            isLoading: false,
            error: "Knowledge graph store could not be read: damaged SQLite",
            entityCount: 1,
            displayedEntityCount: 1,
            isEnabled: true,
            viewMode: .list
        ) == .list,
        "the banner is rendered above retained rows; it must not replace them with a healthy empty state")

        let emptyFailure = KnowledgeGraphPresentation.errorPlacement(
            isLoading: false,
            error: "Knowledge graph store could not be read: damaged SQLite",
            entityCount: 0,
            errorOrigin: .graphLoad
        )
        #expect(emptyFailure == .emptyState("Knowledge graph store could not be read: damaged SQLite"))
        #expect(KnowledgeGraphPresentation.content(
            isLoading: false,
            error: "Knowledge graph store could not be read: damaged SQLite",
            entityCount: 0,
            displayedEntityCount: 0,
            isEnabled: true,
            viewMode: .list
        ) == .unavailable("Knowledge graph store could not be read: damaged SQLite"),
        "an unread first load must never claim that the graph is simply empty")
    }

    @Test("the real orphan-sweep failure is a current-graph error, not a stale-load marker")
    func maintenanceFailurePublishesMaintenanceProvenance() async throws {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("knowledge-graph-error-banner-file-\(UUID().uuidString)")
        try Data("not a directory".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }

        let outcome = await KnowledgeGraphMaintenancePresentation.preview(
            actions: KnowledgeGraphMaintenanceActions(dataRoot: file)
        )
        guard case let .failed(error) = outcome else {
            Issue.record("a file passed as the data root must produce a visible sweep failure")
            return
        }
        #expect(error.hasPrefix("Orphan sweep failed:"))
        #expect(KnowledgeGraphPresentation.errorPlacement(
            isLoading: false,
            error: error,
            entityCount: 1,
            errorOrigin: .maintenance
        ) == .retainedDataBanner(message: error, isStale: false),
        "a failed GC operation does not make the retained graph rows stale")
    }

    @Test("the mounted panel reads its own root and exposes a malformed-store failure")
    func mountedPanelDoesNotReadAnotherProfileOrFabricateAnEmptyGraph() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let storage = try MemoryStorage(dataRoot: root)
        let fact = KnowledgeGraphMemoryFact(
            id: "source-memory",
            content: "NativeAgent graph error banner fixture",
            createdAt: "2026-08-24T00:00:00Z",
            updatedAt: "2026-08-24T00:00:00Z"
        )
        _ = try await storage.insertMemory(StoredMemory(id: fact.id, content: fact.content))
        let indexer = try SwiftNativeKnowledgeGraphIndexer(memorySQLitePath: await storage.path)
        try await indexer.indexMemory(fact)

        let client = NativeClient(baseURL: "http://unused", dataRootOverride: root)
        let initial = try await client.getKnowledgeGraph()
        #expect(!initial.entities.isEmpty,
                "the graph reader must use the client/app data-root override")

        let memoryDirectory = root.appendingPathComponent("memory", isDirectory: true)
        try FileManager.default.removeItem(at: memoryDirectory)
        try FileManager.default.createDirectory(at: memoryDirectory, withIntermediateDirectories: true)
        try Data("{malformed graph bytes".utf8).write(
            to: memoryDirectory.appendingPathComponent("knowledge_graph.json")
        )
        let malformedError: String
        do {
            _ = try await client.getKnowledgeGraph()
            Issue.record("malformed graph bytes must be surfaced as a checked reader failure")
            return
        } catch {
            malformedError = error.localizedDescription
        }

        #expect(KnowledgeGraphPresentation.content(
            isLoading: false,
            error: malformedError,
            entityCount: 0,
            displayedEntityCount: 0,
            isEnabled: true,
            viewMode: .list
        ) == .unavailable(malformedError),
        "the checked read failure must route the panel to its unavailable branch, never the healthy empty graph")
    }

    private func entity(id: String, name: String) throws -> KGEntity {
        try JSONDecoder().decode(KGEntity.self, from: Data("""
        {"id":"\(id)","name":"\(name)","type":"concept"}
        """.utf8))
    }

    private func temporaryRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("knowledge-graph-error-banner-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

}
