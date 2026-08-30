import Testing
import Foundation
@testable import MemoryV2

// Wiring tests that preserve the MemoryRecord shape through the live
// Spotlight indexer. Per-component behavior is covered in SpotlightTests.

@Suite("MemoryV2 Spotlight integration wiring")
struct SpotlightWiringTests {

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

}
