import Foundation
import NativeAgentCore
import PersistenceCore
@testable import MemoryV2

/// In-memory `MemoryV2Storage` stub for migrator unit tests that don't want
/// a temp sqlite file. 2026-07-21 audit fix: moved here from
/// `Sources/MemoryV2/MemoryV2+Migration.swift` — it was cutover residue in
/// the shipped module (its own comment said the integration round deletes
/// it), but the MigrationTests suite pins it, so it lives in the test target
/// where it belongs.
actor InMemoryMemoryStorageStub: MemoryV2Storage {
    private var memories: [String: (MemoryRecord, [Float])] = [:]
    private var proposals: [String: JSONValue] = [:]
    private var tombstones: Set<String> = []

    init() {}

    func memoryExists(id: String) async throws -> Bool { memories[id] != nil }
    func insertMemory(_ record: MemoryRecord, embedding: [Float]) async throws {
        memories[record.id] = (record, embedding)
    }
    func upsertMemory(_ record: MemoryRecord, embedding: [Float]) async throws -> Bool {
        let inserted = memories[record.id] == nil
        memories[record.id] = (record, embedding)
        return inserted
    }
    func proposalExists(id: String) async throws -> Bool { proposals[id] != nil }
    func insertProposal(id: String, raw: JSONValue) async throws { proposals[id] = raw }
    func deleteProposal(id: String) async throws -> Bool {
        proposals.removeValue(forKey: id) != nil
    }
    func tombstoneExists(_ key: String) async throws -> Bool { tombstones.contains(key) }
    func insertTombstone(_ key: String) async throws { tombstones.insert(key) }

    func snapshot() -> (memories: Int, proposals: Int, tombstones: Int) {
        (memories.count, proposals.count, tombstones.count)
    }

    func memorySnapshot(id: String) -> MemoryRecord? {
        memories[id]?.0
    }
}
