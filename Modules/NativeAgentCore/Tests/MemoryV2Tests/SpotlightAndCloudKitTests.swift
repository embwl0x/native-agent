import Testing
import Foundation
@testable import MemoryV2

// Cross-cutting wiring tests that exercise the Spotlight indexer and the
// CloudKit sync coordinator together against the MemoryRecord shape. The
// per-component behavior is covered exhaustively in SpotlightTests and
// CloudKitTests; this suite locks the contract that a record originating
// from MemoryRecord can flow into both surfaces without lossy conversion.

@Suite("MemoryV2 Spotlight + CloudKit integration wiring")
struct SpotlightAndCloudKitTests {

    private func tempDir() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("MemoryV2WiringTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func makeMemoryRecord(id: String, text: String, kind: String? = nil) -> MemoryRecord {
        MemoryRecord(
            id: id,
            text: text,
            memoryKind: kind,
            createdAt: "2026-01-01T00:00:00Z",
            updatedAt: "2026-01-01T00:00:01Z"
        )
    }

    // MARK: MemoryRecord -> SpotlightItem wiring

    @Test func memoryRecord_flows_into_spotlight_indexer_preserving_text_and_kind() async throws {
        let client = MockSpotlightIndexClient()
        let indexer = SwiftNativeMemoryIndexer(client: client)
        let rec = makeMemoryRecord(id: "m1", text: "remember the milk", kind: "user")
        try await indexer.indexRecord(id: rec.id, text: rec.text, kind: rec.memoryKind)
        let snap = await client.snapshot()
        let item = try #require(snap["m1"])
        #expect(item.contentDescription == "remember the milk")
        #expect(item.keywords == ["user"])
        #expect(item.domainIdentifier == "memory.nativeagent")
    }

    @Test func reindexAll_walks_memory_set_and_indexes_each() async throws {
        let client = MockSpotlightIndexClient()
        let indexer = SwiftNativeMemoryIndexer(client: client)
        let records = (0..<10).map { makeMemoryRecord(id: "m\($0)", text: "text-\($0)", kind: "feedback") }
        try await indexer.indexBatch(records.map { (id: $0.id, text: $0.text, kind: $0.memoryKind) })
        let snap = await client.snapshot()
        #expect(snap.count == 10)
        for r in records {
            #expect(snap[r.id]?.contentDescription == r.text)
        }
    }

    @Test func removeIndex_via_indexer_deletes_from_underlying_store() async throws {
        let client = MockSpotlightIndexClient()
        let indexer = SwiftNativeMemoryIndexer(client: client)
        let rec = makeMemoryRecord(id: "m1", text: "hi", kind: nil)
        try await indexer.indexRecord(id: rec.id, text: rec.text, kind: rec.memoryKind)
        try await indexer.remove(id: rec.id)
        let snap = await client.snapshot()
        #expect(snap["m1"] == nil)
    }

    // MARK: MemoryRecord -> CloudKitMemoryRecord conversion

    @Test func memoryRecord_to_cloudkit_record_preserves_fields() async throws {
        let rec = makeMemoryRecord(id: "m1", text: "hello", kind: "user")
        let wire = CloudKitMemoryRecord(
            id: rec.id,
            text: rec.text,
            kind: rec.memoryKind,
            createdAt: rec.createdAt,
            updatedAt: rec.updatedAt ?? rec.createdAt
        )
        #expect(wire.id == "m1")
        #expect(wire.text == "hello")
        #expect(wire.kind == "user")
        #expect(wire.createdAt == rec.createdAt)
        #expect(wire.updatedAt == rec.updatedAt)
    }

    @Test func push_through_coordinator_stamps_records_and_advances_sync_state() async throws {
        let dir = try tempDir()
        let mock = MockCloudKitSync()
        let coord = SwiftNativeMemoryCloudSync(sync: mock, storePath: dir)
        let rec = makeMemoryRecord(id: "m1", text: "hello", kind: nil)
        let wire = CloudKitMemoryRecord(
            id: rec.id, text: rec.text, kind: rec.memoryKind,
            createdAt: rec.createdAt, updatedAt: rec.updatedAt ?? rec.createdAt
        )
        let stamped = try await coord.syncPush(records: [wire])
        #expect(stamped.count == 1)
        #expect(stamped[0].modificationDate != nil)
        let state = try await coord.loadSyncState()
        #expect(state.lastPushAt != nil)
    }

    @Test func pull_through_coordinator_filters_by_lastPullAt_window() async throws {
        let dir = try tempDir()
        let mock = MockCloudKitSync()
        let coord = SwiftNativeMemoryCloudSync(sync: mock, storePath: dir)
        let r1 = CloudKitMemoryRecord(id: "a", text: "alpha", kind: nil, createdAt: "2026-01-01T00:00:00Z", updatedAt: "2026-01-01T00:00:00Z")
        _ = try await mock.push([r1])
        let first = try await coord.syncPull()
        #expect(first.count == 1)
        // Push a second record; the coordinator advanced lastPullAt with a 30s overlap,
        // so a subsequent pull should still return both records (overlap window covers r1).
        let r2 = CloudKitMemoryRecord(id: "b", text: "beta", kind: nil, createdAt: "2026-01-01T00:00:00Z", updatedAt: "2026-01-01T00:00:00Z")
        _ = try await mock.push([r2])
        let second = try await coord.syncPull()
        #expect(second.contains(where: { $0.id == "b" }))
    }

    @Test func conflict_resolution_picks_newer_updatedAt() async throws {
        let dir = try tempDir()
        let coord = SwiftNativeMemoryCloudSync(sync: MockCloudKitSync(), storePath: dir)
        let local = CloudKitMemoryRecord(id: "m1", text: "local", kind: nil,
                                          createdAt: "2026-01-01T00:00:00Z",
                                          updatedAt: "2026-01-02T00:00:00Z")
        let server = CloudKitMemoryRecord(id: "m1", text: "server", kind: nil,
                                           createdAt: "2026-01-01T00:00:00Z",
                                           updatedAt: "2026-01-01T12:00:00Z")
        let winner = coord.resolveConflict(local: local, server: server)
        #expect(winner.text == "local")
    }

    @Test func account_status_propagates_through_mock() async throws {
        let mock = MockCloudKitSync()
        await mock.setSimulateAccountStatus("noAccount")
        #expect(await mock.accountStatus() == "noAccount")
    }
}
