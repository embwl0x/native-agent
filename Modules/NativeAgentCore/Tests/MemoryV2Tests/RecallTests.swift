import Testing
import Foundation
@testable import MemoryV2
import NativeAgentCore
import PersistenceCore

// Phase B wiring smoke: SwiftNativeMemoryV2 composed with MockEmbeddingProvider
// + InMemoryMemoryStorage exercises store/recall/update/delete/proposal/tombstone
// end-to-end without booting the daemon or the real Core ML model.

private func makeActor() -> (SwiftNativeMemoryV2, InMemoryMemoryStorage, MockEmbeddingProvider) {
    let embedder = MockEmbeddingProvider(dimensions: 384)
    let storage = InMemoryMemoryStorage()
    let actor = SwiftNativeMemoryV2(embedder: embedder, storage: storage)
    return (actor, storage, embedder)
}

@Test func wiring_store_then_recall_returns_top_hit() async throws {
    let (mem, _, _) = makeActor()
    _ = try await mem.store(content: "the user's favorite color is teal", source: "test")
    _ = try await mem.store(content: "Pasta tastes better with garlic", source: "test")
    let result = try await mem.recall(MemoryV2RecallRequest(text: "the user's favorite color is teal", topK: 2))
    #expect(result.total == 2)
    #expect(result.hits.first?.preview.contains("teal") == true)
    // Self-recall: cosine of identical text against itself must be 1.0 (within fp noise).
    #expect((result.hits.first?.score ?? 0) > 0.99)
}

@Test func wiring_recall_empty_query_throws() async throws {
    let (mem, _, _) = makeActor()
    do {
        _ = try await mem.recall(MemoryV2RecallRequest(text: "", topK: 5))
        Issue.record("expected throw")
    } catch MemoryV2Error.invalidQuery {
        // pass
    }
}

/// Deliberately cancellation-unaware suspension, modeling a provider/storage
/// operation that finishes after its caller has stopped. No sleeps or polling.
private actor RecallCancellationGate {
    private var entered = false
    private var arrival: CheckedContinuation<Void, Never>?
    private var release: CheckedContinuation<Void, Never>?

    func pause() async {
        entered = true
        arrival?.resume()
        arrival = nil
        await withCheckedContinuation { release = $0 }
    }

    func waitUntilEntered() async {
        if entered { return }
        await withCheckedContinuation { arrival = $0 }
    }

    func open() {
        release?.resume()
        release = nil
    }
}

private struct RecallCancellationEmbedder: EmbeddingProvider {
    enum ResultMode: Sendable, CaseIterable { case transientCancellation, zero, dense }
    let dimensions = 2
    let modelId = "recall-cancellation-fixture"
    let mode: ResultMode
    var gate: RecallCancellationGate? = nil

    func embed(_ texts: [String]) async throws -> [[Float]] {
        if let gate { await gate.pause() }
        switch mode {
        case .transientCancellation: throw CancellationError()
        case .zero: return texts.map { _ in [0, 0] }
        case .dense: return texts.map { _ in [1, 0] }
        }
    }
}

private actor RecallCancellationStorage: KeywordRecallStorageProtocol {
    private(set) var denseCalls = 0
    private(set) var keywordCalls = 0
    private(set) var usageCalls = 0
    let gate: RecallCancellationGate?

    init(gate: RecallCancellationGate? = nil) { self.gate = gate }

    private func hits() async -> [ScoredMemoryRecord] {
        if let gate { await gate.pause() }
        return [ScoredMemoryRecord(record: MemoryRecord(
            id: "orchard-fact", text: "Orchard watering is measured.",
            createdAt: "2026-08-01T00:00:00Z"
        ), score: 0.9)]
    }
    func recall(embedding: [Float], topK: Int, persona: String?) async throws -> [ScoredMemoryRecord] {
        denseCalls += 1
        return await hits()
    }
    func recallByKeyword(queryText: String, topK: Int, persona: String?) async throws -> [ScoredMemoryRecord] {
        keywordCalls += 1
        return await hits()
    }
    func recordRecallHits(ids: [String]) async throws { usageCalls += 1 }

    // Unused write/proposal doors stay inert and fail loudly in this fixture.
    func listMemory(kind: String?) async throws -> [MemoryRecord] { [] }
    func insert(record: MemoryRecord, embedding: [Float]?) async throws -> MemoryRecord { throw MemoryV2Error.storageUnavailable }
    func updateMemory(id: String, patch: JSONValue, newEmbedding: [Float]?) async throws -> MemoryRecord { throw MemoryV2Error.storageUnavailable }
    func deleteMemory(id: String) async throws -> Bool { throw MemoryV2Error.storageUnavailable }
    func isTombstoned(content: String) async throws -> Bool { false }
    func recordTombstone(content: String, reason: String?) async throws { throw MemoryV2Error.storageUnavailable }
    func insertProposal(_ proposal: ProposalRecord, embedding: [Float]?) async throws { throw MemoryV2Error.storageUnavailable }
    func getProposal(id: String) async throws -> ProposalRecord? { nil }
    func acceptProposal(id: String) async throws -> MemoryRecord { throw MemoryV2Error.storageUnavailable }
    func updateProposalStatus(id: String, status: String, rejectionReason: String?) async throws { throw MemoryV2Error.storageUnavailable }
    func updateProposalMetadata(id: String, metadata: JSONValue?) async throws -> ProposalRecord { throw MemoryV2Error.storageUnavailable }
    func listProposals(status: String?) async throws -> [ProposalRecord] { [] }
}

@Test(arguments: RecallCancellationEmbedder.ResultMode.allCases)
private func wiring_canceled_embedding_does_not_start_retrieval(
    mode: RecallCancellationEmbedder.ResultMode
) async throws {
    let gate = RecallCancellationGate()
    let storage = RecallCancellationStorage()
    let memory = SwiftNativeMemoryV2(
        embedder: RecallCancellationEmbedder(mode: mode, gate: gate), storage: storage
    )
    let task = Task { try await memory.recall(MemoryV2RecallRequest(text: "orchard", topK: 1)) }
    await gate.waitUntilEntered()
    task.cancel()
    await gate.open()
    do {
        _ = try await task.value
        Issue.record("canceled recall returned a result")
    } catch is CancellationError {}
    #expect(await storage.denseCalls == 0)
    #expect(await storage.keywordCalls == 0)
    #expect(await storage.usageCalls == 0)
}

@Test(arguments: [RecallCancellationEmbedder.ResultMode.zero, .dense])
private func wiring_canceled_retrieval_does_not_return_hits_or_record_usage(
    mode: RecallCancellationEmbedder.ResultMode
) async throws {
    let gate = RecallCancellationGate()
    let storage = RecallCancellationStorage(gate: gate)
    let memory = SwiftNativeMemoryV2(embedder: RecallCancellationEmbedder(mode: mode), storage: storage)
    let task = Task { try await memory.recall(MemoryV2RecallRequest(text: "orchard", topK: 1)) }
    await gate.waitUntilEntered()
    task.cancel()
    await gate.open()
    do {
        _ = try await task.value
        Issue.record("canceled recall returned a result")
    } catch is CancellationError {}
    #expect(await storage.usageCalls == 0)
}

@Test(arguments: [RecallCancellationEmbedder.ResultMode.transientCancellation, .zero])
private func wiring_uncanceled_cold_embedder_preserves_keyword_fallback(
    mode: RecallCancellationEmbedder.ResultMode
) async throws {
    let storage = RecallCancellationStorage()
    let memory = SwiftNativeMemoryV2(embedder: RecallCancellationEmbedder(mode: mode), storage: storage)
    let result = try await memory.recall(MemoryV2RecallRequest(text: "orchard", topK: 1))
    #expect(result.hits.count == 1)
    let hit = try #require(result.hits.first)
    guard case .object(let extras)? = hit.extras else {
        Issue.record("missing recall identity metadata")
        return
    }
    #expect(extras["id"] == .string("orchard-fact"))
    #expect(await storage.keywordCalls == 1)
    #expect(await storage.denseCalls == 0)
}

@Test func wiring_recall_preserves_only_explicit_canonical_temporal_fields() async throws {
    let (mem, storage, embedder) = makeActor()
    let query = "The studio opens at nine."
    let vector = try #require(try await embedder.embed([query]).first)
    let canonical = MemoryRecord(
        id: "dated-fact", text: query,
        createdAt: "2026-07-01T00:00:00Z",
        validFrom: "2026-03-01T00:00:00Z",
        validTo: "2026-05-31T23:59:59Z",
        observedAt: "2026-06-01T12:00:00Z",
        evidence: .object(["private_detail": .string("not part of the recall date projection")])
    )
    _ = try await storage.insert(record: canonical, embedding: vector)
    let response = try await mem.recall(MemoryV2RecallRequest(text: query, topK: 1))
    let hit = try #require(response.hits.first)
    guard case .object(let extras)? = hit.extras else {
        Issue.record("missing recall metadata")
        return
    }
    #expect(extras["valid_from"] == .string("2026-03-01T00:00:00Z"))
    #expect(extras["valid_to"] == .string("2026-05-31T23:59:59Z"))
    #expect(extras["observed_at"] == .string("2026-06-01T12:00:00Z"))
    #expect(extras["evidence"] == nil)
    #expect(hit.content == query)
    #expect(hit.ts == "2026-07-01T00:00:00Z")

    let (undatedMemory, _, _) = makeActor()
    _ = try await undatedMemory.store(content: query, source: "fixture")
    let undated = try await undatedMemory.recall(MemoryV2RecallRequest(text: query, topK: 1))
    guard case .object(let undatedExtras)? = undated.hits.first?.extras else {
        Issue.record("missing undated recall metadata")
        return
    }
    #expect(undatedExtras["valid_from"] == nil)
    #expect(undatedExtras["valid_to"] == nil)
    #expect(undatedExtras["observed_at"] == nil)
}

@Test func wiring_recall_labels_the_exact_per_hit_excerpt_boundary() async throws {
    let (mem, storage, embedder) = makeActor()
    let query = "Orchard watering instructions"
    let fullText = String(repeating: "The orchard needs measured watering. ", count: 80)
    let vector = try #require(try await embedder.embed([query]).first)
    _ = try await storage.insert(record: MemoryRecord(
        id: "long-fact", text: fullText, createdAt: "2026-08-01T00:00:00Z"
    ), embedding: vector)
    let response = try await mem.recall(MemoryV2RecallRequest(text: query, topK: 1))
    let hit = try #require(response.hits.first)
    let content = try #require(hit.content)
    let displayText = MemoryTextClip.memoryDisplayText(fullText)
    #expect(content.count <= memoryRecallContentCap)
    #expect(content.count < displayText.count)
    #expect(displayText.hasPrefix(content))
    guard case .object(let extras)? = hit.extras else {
        Issue.record("missing excerpt metadata")
        return
    }
    #expect(extras["content_truncated"] == .bool(true))
    #expect(extras["full_content_chars"] == .int(Int64(displayText.count)))
    #expect(response.scored.first?.record.text == fullText)
}

@Test func wiring_store_rejects_tombstoned_content() async throws {
    let (mem, storage, _) = makeActor()
    try await storage.recordTombstone(content: "the user lives in Mars", reason: "wrong")
    do {
        _ = try await mem.store(content: "the user lives in Mars", source: "test")
        Issue.record("expected throw")
    } catch MemoryV2Error.underlying(let msg) {
        #expect(msg.contains("tombstoned"))
    }
    #expect(try await mem.isRejected(content: "the user lives in Mars") == true)
    #expect(try await mem.isRejected(content: "the user lives in Boston") == false)
}

@Test func wiring_updateMemory_with_new_text_reembeds() async throws {
    let (mem, _, _) = makeActor()
    let rec = try await mem.store(content: "original content", source: nil)
    let updated = try await mem.updateMemory(id: rec.id, update: .object(["text": .string("brand new content body")]))
    #expect(updated.text == "brand new content body")
    // recall on the new text should beat recall on the old text after re-embed.
    let r = try await mem.recall(MemoryV2RecallRequest(text: "brand new content body", topK: 1))
    #expect(r.hits.first?.preview.contains("brand new") == true)
    #expect((r.hits.first?.score ?? 0) > 0.99)
}

@Test func wiring_deleteMemory_removes_record() async throws {
    let (mem, _, _) = makeActor()
    let rec = try await mem.store(content: "ephemeral fact", source: nil)
    let del = try await mem.deleteMemory(id: rec.id)
    #expect(del.status == .ok)
    let r = try await mem.recall(MemoryV2RecallRequest(text: "ephemeral fact", topK: 5))
    #expect(r.total == 0)
    #expect(try await mem.isRejected(content: "ephemeral fact") == true)
    do {
        _ = try await mem.store(content: "ephemeral fact", source: nil)
        Issue.record("expected deleted memory content to be tombstoned")
    } catch MemoryV2Error.underlying(let msg) {
        #expect(msg.contains("tombstoned"))
    }
}

@Test func wiring_proposal_accept_promotes_to_record() async throws {
    let (mem, _, _) = makeActor()
    let p = try await mem.propose(content: "the user prefers tabs over spaces", source: "chat")
    #expect(p.status == "pending")
    let pending = try await mem.listProposals(status: "pending")
    #expect(pending.count == 1)
    let rec = try await mem.acceptProposal(id: p.id)
    #expect(rec.id == p.id)
    #expect(rec.text == "the user prefers tabs over spaces")
    let accepted = try await mem.listProposals(status: "accepted")
    #expect(accepted.count == 1)
    // Recall should now surface the accepted fact.
    let r = try await mem.recall(MemoryV2RecallRequest(text: "the user prefers tabs over spaces", topK: 1))
    #expect((r.hits.first?.score ?? 0) > 0.99)
}

@Test func wiring_proposal_reject_writes_tombstone() async throws {
    let (mem, _, _) = makeActor()
    let p = try await mem.propose(content: "the user lives on the moon", source: "chat")
    _ = try await mem.rejectProposal(id: p.id, reason: "obviously wrong")
    let rejected = try await mem.listProposals(status: "rejected")
    #expect(rejected.count == 1)
    #expect(rejected.first?.rejectionReason == "obviously wrong")
    // Tombstone gate must now block re-store of the same content.
    do {
        _ = try await mem.store(content: "the user lives on the moon", source: nil)
        Issue.record("expected throw")
    } catch MemoryV2Error.underlying(let msg) {
        #expect(msg.contains("tombstoned"))
    }
}

@Test func wiring_proposal_accept_after_tombstone_rejects() async throws {
    let (mem, storage, _) = makeActor()
    let p = try await mem.propose(content: "stale claim", source: nil)
    // Tombstone lands AFTER the proposal was queued — acceptance must still bounce.
    try await storage.recordTombstone(content: "stale claim", reason: "denylisted")
    do {
        _ = try await mem.acceptProposal(id: p.id)
        Issue.record("expected throw")
    } catch MemoryV2Error.underlying(let msg) {
        #expect(msg.contains("tombstoned"))
    }
    let rejected = try await mem.listProposals(status: "rejected")
    #expect(rejected.count == 1)
}

@Test func wiring_unwired_actor_throws_storageUnavailable() async throws {
    let mem = SwiftNativeMemoryV2()
    do {
        _ = try await mem.recall(MemoryV2RecallRequest(text: "anything", topK: 3))
        Issue.record("expected throw")
    } catch MemoryV2Error.storageUnavailable {
        // pass — the bare test initializer has no storage/embedder wiring.
    }
}
