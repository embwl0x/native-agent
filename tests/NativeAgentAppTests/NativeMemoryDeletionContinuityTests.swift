import Foundation
import MemoryV2
import Testing
@testable import NativeAgentApp

@Suite("Native memory deletion continuity")
struct NativeMemoryDeletionContinuityTests {
    @Test func foregroundDeleteCompletesProjectionAndPreservesAtomicMissingResult() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("memory-delete-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = try MemoryStorage(dataRoot: root)
        let row = StoredMemory(content: "The orchard gate opens at dusk.")
        _ = try await storage.insertMemory(row)
        let recorder = DeletionProjectionRecorder()
        await storage.attachKnowledgeGraphHook { memory, deleted in
            await recorder.record(id: memory.id, deleted: deleted)
        }
        let memory = SwiftNativeMemoryV2(embedder: MockEmbeddingProvider(), storage: MemoryStorageBridge(storage: storage))
        let client = NativeClient(baseURL: "", dataRootOverride: root)
        let response = try await client.deleteMemory(id: row.id, memory: memory)
        #expect(response["status"] as? String == "ok")
        #expect(await recorder.deletedIDs == [row.id])
        #expect(try await storage.memory(id: row.id) == nil)
        #expect(try await storage.isTombstoned(content: row.content))
        do {
            _ = try await client.deleteMemory(id: row.id, memory: memory)
            Issue.record("missing row must retain 404 behavior")
        } catch {
            #expect((error as NSError).code == 404)
        }
        #expect(await recorder.deletedIDs == [row.id])
        // The older protocol-facing API retains its idempotent ok contract.
        #expect(try await memory.deleteMemory(id: row.id) == .ok)
    }

    @Test func uninjectedDeleteUsesClientRootOverride() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("memory-delete-root-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let targetRoot = root.appendingPathComponent("target")
        let otherRoot = root.appendingPathComponent("other")
        let target = try MemoryStorage(dataRoot: targetRoot)
        let other = try MemoryStorage(dataRoot: otherRoot)
        let row = StoredMemory(id: UUID().uuidString, content: "The orchard fence is painted blue.")
        _ = try await target.insertMemory(row)
        _ = try await other.insertMemory(row)
        let client = NativeClient(baseURL: "", dataRootOverride: targetRoot)
        let response = try await client.deleteMemory(id: row.id)
        #expect(response["status"] as? String == "ok")
        #expect(try await target.memory(id: row.id) == nil)
        #expect(try await target.isTombstoned(content: row.content))
        #expect(try await other.memory(id: row.id)?.content == row.content)
        #expect(!(try await other.isTombstoned(content: row.content)))
    }
}

private actor DeletionProjectionRecorder {
    private(set) var deletedIDs: [String] = []
    func record(id: String, deleted: Bool) {
        if deleted { deletedIDs.append(id) }
    }
}
