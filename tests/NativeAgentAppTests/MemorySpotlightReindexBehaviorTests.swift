import Foundation
import MemoryV2
import Testing
@testable import NativeAgentApp

private enum SpotlightReindexEvalError: Error {
    case indexUnavailable
}

private actor FailingSpotlightIndexClient: SpotlightIndexClient {
    func index(_ items: [SpotlightItem]) async throws {
        throw SpotlightReindexEvalError.indexUnavailable
    }

    func delete(ids: [String]) async throws {}
    func deleteAll(domainIdentifier: String) async throws {}
}

// EVAL FENCE: app.mind / ui.memory.reindexSpotlight
@Suite("Memory Spotlight reindex — durable confirmation", .serialized)
struct MemorySpotlightReindexBehaviorTests {
    private func root(_ label: String) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("memory-spotlight-reindex-\(label)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    @Test("a successful reindex confirms the current SQLite generation and exact indexed batch")
    func successfulReindexWritesGenerationProofAfterTheIndexAcceptsTheBatch() async throws {
        let dataRoot = try root("success")
        defer { try? FileManager.default.removeItem(at: dataRoot) }
        let storage = try await SwiftNativeMemoryV2.resolvedStorage(dataRoot: dataRoot)
        _ = try await storage.insertMemory(StoredMemory(
            id: "spotlight-first",
            content: "The first durable memory.",
            source: "spotlight-reindex-eval"
        ))
        _ = try await storage.insertMemory(StoredMemory(
            id: "spotlight-second",
            content: "The second durable memory.",
            source: "spotlight-reindex-eval"
        ))
        let client = MockSpotlightIndexClient()

        let outcome = await MemorySpotlightReindexOperation.run(dataRoot: dataRoot, client: client)
        #expect(outcome == .indexed(count: 2))
        #expect(Set((await client.snapshot()).keys) == ["spotlight-first", "spotlight-second"])

        let generation = try await storage.projectionGenerationFingerprint()
        let marker = MemorySpotlightReindexOperation.markerURL(dataRoot: dataRoot)
        #expect(try String(contentsOf: marker, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines) == generation)

        let snapshot = await MemoryV2NativeStackSnapshot.load(dataRoot: dataRoot)
        #expect(snapshot.spotlightReindexed)
        #expect(snapshot.spotlightIndexedCount == 2)
    }

    @Test("a failing reindex clears old proof so an empty index cannot report the prior count")
    func failedReindexInvalidatesExistingSpotlightConfirmation() async throws {
        let dataRoot = try root("failure")
        defer { try? FileManager.default.removeItem(at: dataRoot) }
        let storage = try await SwiftNativeMemoryV2.resolvedStorage(dataRoot: dataRoot)
        _ = try await storage.insertMemory(StoredMemory(
            id: "spotlight-failure",
            content: "This must not remain claimed as indexed after failure.",
            source: "spotlight-reindex-eval"
        ))
        let generation = try await storage.projectionGenerationFingerprint()
        let marker = MemorySpotlightReindexOperation.markerURL(dataRoot: dataRoot)
        try FileManager.default.createDirectory(at: marker.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data((generation + "\n").utf8).write(to: marker, options: .atomic)

        let outcome = await MemorySpotlightReindexOperation.run(
            dataRoot: dataRoot,
            client: FailingSpotlightIndexClient()
        )
        guard case .failed = outcome else {
            Issue.record("a failing index client reported success: \(outcome)")
            return
        }
        #expect(!FileManager.default.fileExists(atPath: marker.path),
                "failure after clearing the index must leave no stale confirmation")

        let snapshot = await MemoryV2NativeStackSnapshot.load(dataRoot: dataRoot)
        #expect(!snapshot.spotlightReindexed)
        #expect(snapshot.spotlightIndexedCount == 0,
                "without current-generation confirmation, the panel must not infer an indexed count")
    }
}
