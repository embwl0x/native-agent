import Testing
import Foundation
@testable import MemoryV2

@Suite("MemoryV2 Spotlight indexer (Phase C)")
struct SpotlightTests {

    // MARK: MockSpotlightIndexClient

    @Test func mockSpotlight_index_then_snapshot_returns_items() async throws {
        let c = MockSpotlightIndexClient()
        let a = SpotlightItem(id: "1", title: "t1", contentDescription: "d1", keywords: ["k"], domainIdentifier: "dom.a")
        let b = SpotlightItem(id: "2", title: "t2", contentDescription: "d2", keywords: [], domainIdentifier: "dom.a")
        try await c.index([a, b])
        let snap = await c.snapshot()
        #expect(snap.count == 2)
        #expect(snap["1"] == a)
        #expect(snap["2"] == b)
    }

    @Test func mockSpotlight_delete_removes_item() async throws {
        let c = MockSpotlightIndexClient()
        let a = SpotlightItem(id: "1", title: "t", contentDescription: "d", keywords: [], domainIdentifier: "dom.a")
        try await c.index([a])
        try await c.delete(ids: ["1"])
        let snap = await c.snapshot()
        #expect(snap["1"] == nil)
    }

    @Test func mockSpotlight_deleteAll_with_domain_removes_matching() async throws {
        let c = MockSpotlightIndexClient()
        try await c.index([
            SpotlightItem(id: "1", title: "t", contentDescription: "d", keywords: [], domainIdentifier: "dom.a"),
            SpotlightItem(id: "2", title: "t", contentDescription: "d", keywords: [], domainIdentifier: "dom.a"),
        ])
        try await c.deleteAll(domainIdentifier: "dom.a")
        let snap = await c.snapshot()
        #expect(snap.isEmpty)
    }

    @Test func mockSpotlight_deleteAll_preserves_other_domain() async throws {
        let c = MockSpotlightIndexClient()
        try await c.index([
            SpotlightItem(id: "1", title: "t", contentDescription: "d", keywords: [], domainIdentifier: "dom.a"),
            SpotlightItem(id: "2", title: "t", contentDescription: "d", keywords: [], domainIdentifier: "dom.b"),
        ])
        try await c.deleteAll(domainIdentifier: "dom.a")
        let snap = await c.snapshot()
        #expect(snap.count == 1)
        #expect(snap["2"]?.domainIdentifier == "dom.b")
    }

    @Test func mockSpotlight_deleteAll_recursively_matches_subdomains() async throws {
        let c = MockSpotlightIndexClient()
        try await c.index([
            SpotlightItem(id: "1", title: "t", contentDescription: "d", keywords: [], domainIdentifier: "memory.nativeagent"),
            SpotlightItem(id: "2", title: "t", contentDescription: "d", keywords: [], domainIdentifier: "memory.nativeagent.child"),
            SpotlightItem(id: "3", title: "t", contentDescription: "d", keywords: [], domainIdentifier: "memory.nativeagent.child.deep"),
            SpotlightItem(id: "4", title: "t", contentDescription: "d", keywords: [], domainIdentifier: "memory.other"),
        ])
        try await c.deleteAll(domainIdentifier: "memory.nativeagent")
        let snap = await c.snapshot()
        #expect(snap["1"] == nil)
        #expect(snap["2"] == nil)
        #expect(snap["3"] == nil)
        #expect(snap["4"]?.domainIdentifier == "memory.other")
    }

    @Test func mockSpotlight_concurrent_index_no_corruption() async throws {
        let c = MockSpotlightIndexClient()
        await withTaskGroup(of: Void.self) { group in
            for i in 0..<100 {
                group.addTask {
                    let item = SpotlightItem(
                        id: "id-\(i)",
                        title: "t",
                        contentDescription: "d",
                        keywords: [],
                        domainIdentifier: "dom.x"
                    )
                    try? await c.index([item])
                }
            }
        }
        let snap = await c.snapshot()
        #expect(snap.count == 100)
    }

    // MARK: SwiftNativeMemoryIndexer

    @Test func memoryIndexer_indexRecord_creates_spotlight_item_with_title_truncated_to_80_chars() async throws {
        let c = MockSpotlightIndexClient()
        let idx = SwiftNativeMemoryIndexer(client: c)
        let longText = String(repeating: "x", count: 200)
        try await idx.indexRecord(id: "r1", text: longText, kind: nil)
        let snap = await c.snapshot()
        let item = try #require(snap["r1"])
        #expect(item.title.count == 80)
        #expect(item.contentDescription == longText)
    }

    @Test func memoryIndexer_indexBatch_indexes_all_records() async throws {
        let c = MockSpotlightIndexClient()
        let idx = SwiftNativeMemoryIndexer(client: c)
        try await idx.indexBatch([
            (id: "a", text: "alpha", kind: nil),
            (id: "b", text: "beta", kind: "user"),
            (id: "c", text: "gamma", kind: "feedback"),
        ])
        let snap = await c.snapshot()
        #expect(snap.count == 3)
        #expect(snap["a"]?.contentDescription == "alpha")
        #expect(snap["b"]?.keywords == ["user"])
        #expect(snap["c"]?.keywords == ["feedback"])
    }

    @Test func memoryIndexer_indexRecord_kind_becomes_single_keyword() async throws {
        let c = MockSpotlightIndexClient()
        let idx = SwiftNativeMemoryIndexer(client: c)
        try await idx.indexRecord(id: "r1", text: "hi", kind: "project")
        let snap = await c.snapshot()
        #expect(snap["r1"]?.keywords == ["project"])
    }

    @Test func memoryIndexer_indexRecord_nil_kind_empty_keywords() async throws {
        let c = MockSpotlightIndexClient()
        let idx = SwiftNativeMemoryIndexer(client: c)
        try await idx.indexRecord(id: "r1", text: "hi", kind: nil)
        let snap = await c.snapshot()
        #expect(snap["r1"]?.keywords == [])
    }

    @Test func memoryIndexer_remove_then_snapshot_excludes_id() async throws {
        let c = MockSpotlightIndexClient()
        let idx = SwiftNativeMemoryIndexer(client: c)
        try await idx.indexRecord(id: "r1", text: "hi", kind: nil)
        try await idx.remove(id: "r1")
        let snap = await c.snapshot()
        #expect(snap["r1"] == nil)
    }

    @Test func memoryIndexer_removeAll_clears_only_its_domain() async throws {
        let c = MockSpotlightIndexClient()
        let idx = SwiftNativeMemoryIndexer(client: c, domain: "memory.nativeagent")
        try await idx.indexRecord(id: "r1", text: "hi", kind: nil)
        // Add an item from a different domain directly via the client.
        try await c.index([SpotlightItem(id: "other", title: "t", contentDescription: "d", keywords: [], domainIdentifier: "other.domain")])
        try await idx.removeAll()
        let snap = await c.snapshot()
        #expect(snap["r1"] == nil)
        #expect(snap["other"] != nil)
    }
}
