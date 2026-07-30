import Testing
import Foundation
@testable import MemoryV2
import NativeAgentCore
import PersistenceCore

// MARK: - Factory

@Test func factoryReturnsSwiftNativeByDefault() async throws {
    let impl = makeMemoryV2()
    #expect(impl is SwiftNativeMemoryV2)
}

// 2026-06-06 daemon-bridge retirement: the `makeMemoryV2(nativeBaseURL:)`
// signature was deleted (the daemon URL was never read). The prior test
// `factoryKeepsBaseURLSignatureButIgnoresDaemonURL` asserted the
// param-acceptance contract that's now gone; removed with the bridge.

// MARK: - Codable shape

@Test func MemoryRecord_round_trips_via_Codable_with_extras() throws {
    let rec = MemoryRecord(
        id: "m1",
        text: "the user's favorite color is teal",
        layer: "semantic",
        memoryKind: "preference",
        createdAt: "2026-05-30T12:34:56Z",
        updatedAt: "2026-05-30T13:00:00Z",
        sourceRunId: "run-42",
        status: "active",
        pinned: true,
        confidence: 0.92,
        importance: 0.7,
        tags: ["personal", "color"],
        schemaVersion: 2,
        sourceQuality: 0.88,
        lastUsedAt: "2026-05-30T14:00:00Z",
        decay: .object(["decayScore": .double(0.1)]),
        correction: .object(["current": .bool(true)]),
        correctionHistory: .array([]),
        provenance: .array([.object(["event": .string("created")])]),
        extras: .object(["forward_compat": .int(1)])
    )
    let data = try JSONEncoder().encode(rec)
    let back = try JSONDecoder().decode(MemoryRecord.self, from: data)
    #expect(back == rec)
    let s = String(data: data, encoding: .utf8) ?? ""
    #expect(s.contains("\"createdAt\""))
    #expect(s.contains("\"text\""))
    #expect(s.contains("\"forward_compat\""))
}

@Test func MemoryRecord_decodes_unknown_keys_into_extras() throws {
    let raw = Data("""
    {"id":"m9","text":"hello","layer":"semantic","createdAt":"2026-05-30T00:00:00Z","novelField":42,"anotherNew":"x"}
    """.utf8)
    let rec = try JSONDecoder().decode(MemoryRecord.self, from: raw)
    #expect(rec.id == "m9")
    #expect(rec.text == "hello")
    guard case .object(let extras)? = rec.extras else {
        Issue.record("extras should be object")
        return
    }
    #expect(extras["novelField"] != nil)
    #expect(extras["anotherNew"] != nil)
}

@Test func MemoryRecallQuery_default_k_is_10() throws {
    let q = MemoryRecallQuery(query: "where do I live")
    #expect(q.k == 10)
    #expect(q.kinds == nil)
    #expect(q.tagsFilter == nil)
}

@Test func MemoryRecallQuery_round_trips_with_filters() throws {
    let q = MemoryRecallQuery(query: "hello", k: 5, kinds: ["fact", "pref"], tagsFilter: ["personal"])
    let data = try JSONEncoder().encode(q)
    let back = try JSONDecoder().decode(MemoryRecallQuery.self, from: data)
    #expect(back == q)
    let s = String(data: data, encoding: .utf8) ?? ""
    #expect(s.contains("\"tags_filter\""))
}

@Test func MemoryRecallResult_rawResponse_preserves_unknown_keys() throws {
    let raw: JSONValue = .object([
        "hits": .array([]),
        "query": .string("q-1"),
        "score_floor": .double(0.5),
        "novel": .object(["nested": .int(42)]),
    ])
    let res = MemoryRecallResult(hits: [], records: nil, rawResponse: raw)
    let data = try JSONEncoder().encode(res)
    let back = try JSONDecoder().decode(MemoryRecallResult.self, from: data)
    #expect(back == res)
    #expect(back.rawResponse == raw)
}

@Test func MemoryRecallHit_decodes_session_id_snake_case() throws {
    let raw = Data("""
    {"score":0.81,"session_id":"sess-1","role":"user","ts":"2026-05-30T00:00:00Z","preview":"hello world","source":"chat","rankingSignals":{"bm25":0.4}}
    """.utf8)
    let hit = try JSONDecoder().decode(MemoryRecallHit.self, from: raw)
    #expect(hit.score == 0.81)
    #expect(hit.sessionId == "sess-1")
    #expect(hit.role == "user")
    #expect(hit.preview == "hello world")
    #expect(hit.source == "chat")
}

// MARK: - SwiftNative behavior

private func makeInMemorySwiftNative() -> SwiftNativeMemoryV2 {
    SwiftNativeMemoryV2(
        embedder: MockEmbeddingProvider(dimensions: 32),
        storage: InMemoryMemoryStorage()
    )
}

@Test func swiftNative_store_list_recall_update_and_delete_use_storage() async throws {
    let memory = makeInMemorySwiftNative()
    let stored = try await memory.store(
        content: "user likes espresso",
        source: "unit-test",
        metadata: .object(["kind": .string("preference")])
    )

    let listed = try await memory.listMemory(kind: nil)
    #expect(listed.count == 1)
    #expect(listed[0].id == stored.id)
    #expect(listed[0].text == "user likes espresso")
    #expect(listed[0].sourceRunId == "unit-test")

    let recalled = try await memory.recallMemory(MemoryRecallQuery(query: "espresso", k: 3))
    #expect(recalled.hits.count == 1)
    #expect(recalled.hits[0].preview == "user likes espresso")
    #expect(recalled.hits[0].source == "swift-native")
    if case .object(let raw) = recalled.rawResponse {
        #expect(raw["query"] == .string("espresso"))
    } else {
        Issue.record("expected object rawResponse")
    }

    let updated = try await memory.updateMemory(
        id: stored.id,
        update: .object([
            "content": .string("user likes Swift-native memory"),
            "pinned": .bool(true),
            "confidence": .double(0.82),
        ])
    )
    #expect(updated.text == "user likes Swift-native memory")
    #expect(updated.pinned == true)
    #expect(updated.confidence == 0.82)

    let admin = try await memory.updateMemoryAdmin(
        id: stored.id,
        update: .object(["pinned": .bool(false)])
    )
    #expect(admin.status == .ok)

    let deleted = try await memory.deleteMemory(id: stored.id)
    #expect(deleted.status == .ok)
    let afterDelete = try await memory.listMemory(kind: nil)
    #expect(afterDelete.isEmpty)
}

@Test func swiftNative_listMemoryFiltersByKindOrLayer() async throws {
    let storage = InMemoryMemoryStorage()
    let memory = SwiftNativeMemoryV2(
        embedder: MockEmbeddingProvider(dimensions: 32),
        storage: storage
    )
    _ = try await storage.insert(
        record: MemoryRecord(
            id: "fact-1",
            text: "user likes espresso",
            layer: "semantic",
            memoryKind: "preference",
            createdAt: "2026-06-03T00:00:00Z"
        ),
        embedding: nil
    )
    _ = try await storage.insert(
        record: MemoryRecord(
            id: "episodic-1",
            text: "user mentioned a meeting",
            layer: "episodic",
            createdAt: "2026-06-03T00:00:01Z"
        ),
        embedding: nil
    )

    let preferences = try await memory.listMemory(kind: "preference")
    #expect(preferences.map(\.id) == ["fact-1"])
    let episodic = try await memory.listMemory(kind: "episodic")
    #expect(episodic.map(\.id) == ["episodic-1"])
}

@Test func swiftNative_v2StatusReportsSwiftBackend() async throws {
    let memory = makeInMemorySwiftNative()
    let status = try await memory.v2Status()
    guard case .object(let obj) = status else {
        Issue.record("expected status object")
        return
    }
    #expect(obj["phase"] == .string("B"))
    #expect(obj["backend"] == .string("swift-native"))
    #expect(obj["embedder"] == .string("mock"))
    #expect(obj["dimensions"] == .int(32))
}

@Test func proposalAcceptPromotesIntoActiveMemory() async throws {
    let memory = makeInMemorySwiftNative()
    let proposal = try await memory.propose(
        content: "user prefers native Swift agents",
        source: "unit-test"
    )
    let pending = try await memory.listProposals(status: "pending")
    #expect(pending.map(\.id) == [proposal.id])

    let accepted = try await memory.acceptProposal(id: proposal.id)
    #expect(accepted.id == proposal.id)
    #expect(accepted.text == "user prefers native Swift agents")

    let memories = try await memory.listMemory(kind: nil)
    #expect(memories.map(\.id) == [accepted.id])
    let acceptedProposals = try await memory.listProposals(status: "accepted")
    #expect(acceptedProposals.map(\.id) == [proposal.id])

    do {
        _ = try await memory.acceptProposal(id: proposal.id)
        Issue.record("expected already-resolved proposal to throw")
    } catch {
        // Expected: proposals may only promote once.
    }
}

@Test func proposalRejectWritesTombstoneAndBlocksReentry() async throws {
    let memory = makeInMemorySwiftNative()
    let proposal = try await memory.propose(
        content: "user dislikes this stale fact",
        source: "unit-test"
    )
    let rejected = try await memory.rejectProposal(id: proposal.id, reason: "stale")
    #expect(rejected == true)
    #expect(try await memory.isRejected(content: "USER DISLIKES THIS STALE FACT") == true)

    do {
        _ = try await memory.store(content: "user dislikes this stale fact", source: "unit-test")
        Issue.record("expected tombstoned content to be rejected")
    } catch MemoryV2Error.underlying(let message) {
        #expect(message.contains("tombstoned"))
    } catch {
        Issue.record("unexpected error: \(error)")
    }
}

@Test func recallMemoryAppliesDisclosurePolicyForCallerSurface() async throws {
    // 2026-07-21 audit fix: this lane used to pass NO surface into recall,
    // and permits() treats nil as allow-all — recall was surface-blind.
    let memory = makeInMemorySwiftNative()
    _ = try await memory.store(content: "user likes espresso", source: "unit-test")

    // A default (local_private) memory is hidden from non-local surfaces…
    let slack = try await memory.recallMemory(
        MemoryRecallQuery(query: "espresso", k: 3, surface: "slack")
    )
    #expect(slack.hits.isEmpty)
    // …visible on local-private surfaces…
    let chat = try await memory.recallMemory(
        MemoryRecallQuery(query: "espresso", k: 3, surface: "chat")
    )
    #expect(chat.hits.count == 1)
    // …and surfaceless internal callers keep the allow-all behavior.
    let surfaceless = try await memory.recallMemory(MemoryRecallQuery(query: "espresso", k: 3))
    #expect(surfaceless.hits.count == 1)
}

@Test func MemoryRecallQuery_round_trips_with_surface() throws {
    let q = MemoryRecallQuery(query: "hello", k: 5, surface: "telegram")
    let data = try JSONEncoder().encode(q)
    let back = try JSONDecoder().decode(MemoryRecallQuery.self, from: data)
    #expect(back == q)
    // Absent surface decodes to nil (wire-compatible with pre-surface payloads).
    let legacy = Data("{\"query\":\"hi\",\"k\":2}".utf8)
    let decoded = try JSONDecoder().decode(MemoryRecallQuery.self, from: legacy)
    #expect(decoded.surface == nil)
}

@Test func failClosedEmbedderReportsNotLoadedInSnapshot() async throws {
    // 2026-07-21 audit fix: a fail-closed embedder (modelId "fail-closed")
    // fell into the non-mock fallback branch and reported coreMLLoaded=true
    // while every embed() throws.
    let memory = SwiftNativeMemoryV2(
        embedder: FailClosedEmbeddingProvider(dimensions: 32),
        storage: InMemoryMemoryStorage()
    )
    let snapshot = try #require(await memory.embeddingRuntimeSnapshot())
    #expect(snapshot.effectiveBackend == ManagedEmbeddingProvider.failClosedBackend)
    #expect(snapshot.requestedBackend == ManagedEmbeddingProvider.coreMLBackend)
    #expect(snapshot.coreMLLoaded == false)
    #expect(snapshot.coreMLResourcesAvailable == false)
    #expect(snapshot.modelLoadable == false)
    #expect(snapshot.loadCount == 0)
}
