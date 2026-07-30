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
