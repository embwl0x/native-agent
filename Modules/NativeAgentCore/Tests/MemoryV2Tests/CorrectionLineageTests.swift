import Testing
import Foundation
import NativeAgentCore
import PersistenceCore
@testable import MemoryV2

// R13: first-class correction lineage. markCorrected must, in ONE
// transaction, flip lifecycle to 'corrected' (recall-excluded), stamp
// queryable corrected_by/corrected_at (+ reason), and append to the
// correction_history chain — while refusing rows that aren't eligible.
@Suite struct CorrectionLineageTests {

    private func makeStorage() throws -> MemoryStorage {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("correction-lineage-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return try MemoryStorage(dataRoot: root)
    }

    private func metaObject(_ m: StoredMemory?) -> [String: JSONValue] {
        if case .object(let o)? = m?.metadata { return o }
        return [:]
    }

    @Test func markCorrectedStampsLineageAndExcludesFromRecall() async throws {
        let storage = try makeStorage()
        let old = StoredMemory(content: "user's favorite color is teal", embedding: [1, 0, 0, 0])
        let new = StoredMemory(content: "user's favorite color is orange", embedding: [0.9, 0.1, 0, 0])
        _ = try await storage.insertMemory(old)
        _ = try await storage.insertMemory(new)

        let applied = try await storage.markCorrected(
            id: old.id, by: new.id, reason: "user said orange, not teal"
        )
        #expect(applied)

        let row = try #require(try await storage.memory(id: old.id))
        #expect(row.lifecycle == MemoryLifecycle.corrected)
        let meta = metaObject(row)
        #expect(meta["corrected_by"] == .string(new.id))
        #expect(meta["corrected_at"] != nil)
        #expect(meta["correction_reason"] == .string("user said orange, not teal"))
        guard case .array(let history)? = meta["correction_history"], history.count == 1 else {
            Issue.record("expected one correction_history entry"); return
        }

        // Corrected rows drop out of recall; the new fact still surfaces.
        let hits = try await storage.recall(embedding: [1, 0, 0, 0], queryText: "favorite color", topK: 5, persona: nil)
        #expect(!hits.contains { $0.memory.id == old.id })
        #expect(hits.contains { $0.memory.id == new.id })
    }

    @Test func doubleCorrectionOfSameRowIsRefused() async throws {
        let storage = try makeStorage()
        let old = StoredMemory(content: "fact v1", embedding: [1, 0, 0, 0])
        let v2 = StoredMemory(content: "fact v2", embedding: [0, 1, 0, 0])
        let v3 = StoredMemory(content: "fact v3", embedding: [0, 0, 1, 0])
        for m in [old, v2, v3] { _ = try await storage.insertMemory(m) }

        #expect(try await storage.markCorrected(id: old.id, by: v2.id))
        // Already lifecycle-terminal — a second correction of the SAME row is
        // a refusal, not a silent history rewrite.
        #expect(!(try await storage.markCorrected(id: old.id, by: v3.id)))
        let meta = metaObject(try await storage.memory(id: old.id))
        #expect(meta["corrected_by"] == .string(v2.id))
    }

    @Test func correctionChainLinksThroughIntermediateRows() async throws {
        let storage = try makeStorage()
        let v1 = StoredMemory(content: "chain v1", embedding: [1, 0, 0, 0])
        let v2 = StoredMemory(content: "chain v2", embedding: [0, 1, 0, 0])
        let v3 = StoredMemory(content: "chain v3", embedding: [0, 0, 1, 0])
        for m in [v1, v2, v3] { _ = try await storage.insertMemory(m) }

        #expect(try await storage.markCorrected(id: v1.id, by: v2.id))
        #expect(try await storage.markCorrected(id: v2.id, by: v3.id))

        // Walk the chain v1 → v2 → v3 through corrected_by pointers.
        let m1 = metaObject(try await storage.memory(id: v1.id))
        let m2 = metaObject(try await storage.memory(id: v2.id))
        #expect(m1["corrected_by"] == .string(v2.id))
        #expect(m2["corrected_by"] == .string(v3.id))
        // Only the head of the chain stays recallable.
        let hits = try await storage.recall(embedding: [0, 0, 1, 0], queryText: "chain", topK: 5, persona: nil)
        #expect(hits.contains { $0.memory.id == v3.id })
        #expect(!hits.contains { $0.memory.id == v1.id || $0.memory.id == v2.id })
    }

    @Test func correctedRowsAreExcludedFromBridgeListMemory() async throws {
        // Review HIGH: listMemory feeds dream context + re-embedding — a
        // corrected fact must not leak back through the list path either.
        // Exercises the PRODUCTION MemoryStorageBridge existential path.
        let storage = try makeStorage()
        let bridge = MemoryStorageBridge(storage: storage)
        let old = StoredMemory(content: "list-path old fact", embedding: [1, 0, 0, 0])
        let new = StoredMemory(content: "list-path new fact", embedding: [0, 1, 0, 0])
        _ = try await storage.insertMemory(old)
        _ = try await storage.insertMemory(new)
        #expect(try await bridge.markCorrected(id: old.id, by: new.id, reason: nil))
        let listed = try await bridge.listMemory(kind: nil)
        #expect(!listed.contains { $0.id == old.id })
        #expect(listed.contains { $0.id == new.id })
    }

    @Test func unknownIdIsRefusedWithoutSideEffects() async throws {
        let storage = try makeStorage()
        let new = StoredMemory(content: "lonely new fact", embedding: [1, 0, 0, 0])
        _ = try await storage.insertMemory(new)
        #expect(!(try await storage.markCorrected(id: "no-such-id", by: new.id)))
    }
}
