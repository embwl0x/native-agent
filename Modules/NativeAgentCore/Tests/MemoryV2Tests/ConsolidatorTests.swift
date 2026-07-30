// Swift-native cutover mem-m6: tests for the slow weekly MemoryConsolidator path.

import Foundation
import Testing
@testable import MemoryV2
import NativeAgentCore

@Suite("MemoryConsolidator")
struct MemoryConsolidatorTests {

    // MARK: - helpers

    private func makeStore() throws -> MemoryStorage {
        try MemoryStorage()
    }

    /// 4-dim unit-vector helper for deterministic cosine sims.
    private func vec(_ a: Float, _ b: Float, _ c: Float, _ d: Float) -> [Float] {
        [a, b, c, d]
    }

    @Test func autoAcceptsAboveDurabilityThreshold() async throws {
        let store = try makeStore()
        let p = StoredProposal(
            content: "the user prefers Opus 4.8 for impl work",
            source: "consolidator-test",
            embedding: vec(1, 0, 0, 0),
            metadata: .object(["durability_score": .double(0.91)])
        )
        _ = try await store.insertProposal(p)

        let consolidator = MemoryConsolidator(storage: store)
        let report = try await consolidator.consolidateDestructively()

        #expect(report.processed == 1)
        #expect(report.autoAccepted == 1)
        #expect(report.pendingForReview == 0)
        #expect(report.duplicatesMerged == 0)

        let mems = try await store.listMemories()
        #expect(mems.contains(where: { $0.id == p.id && $0.status == "active" }))
    }

    @Test func leavesPendingBelowDurabilityThreshold() async throws {
        let store = try makeStore()
        let p = StoredProposal(
            content: "weak signal — needs human eyes",
            source: "consolidator-test",
            embedding: vec(0, 1, 0, 0),
            metadata: .object(["durability_score": .double(0.42)])
        )
        _ = try await store.insertProposal(p)

        let report = try await MemoryConsolidator(storage: store).consolidateDestructively()
        #expect(report.processed == 1)
        #expect(report.pendingForReview == 1)
        #expect(report.autoAccepted == 0)

        let pending = try await store.listProposals(status: "pending")
        #expect(pending.contains(where: { $0.id == p.id }))
        let mems = try await store.listMemories()
        #expect(mems.isEmpty)
    }

    @Test func leavesPendingWhenNoDurabilityScore() async throws {
        let store = try makeStore()
        let p = StoredProposal(
            content: "no durability score on this one",
            source: "consolidator-test",
            embedding: vec(0, 0, 1, 0)
        )
        _ = try await store.insertProposal(p)

        let report = try await MemoryConsolidator(storage: store).consolidateDestructively()
        #expect(report.processed == 1)
        #expect(report.pendingForReview == 1)
        #expect(report.autoAccepted == 0)
    }

    @Test func dedupsHighSimilarityProposalAgainstActiveMemory() async throws {
        let store = try makeStore()
        // Existing active memory.
        let mem = StoredMemory(
            content: "the user uses Claude persona for Opus",
            source: "chat",
            embedding: vec(1, 0, 0, 0),
            status: "active"
        )
        _ = try await store.insertMemory(mem)
        // Near-identical proposal (same vector → cosine = 1.0).
        let p = StoredProposal(
            content: "the user uses Claude persona for Opus model",
            source: "consolidator-test",
            embedding: vec(1, 0, 0, 0),
            metadata: .object(["durability_score": .double(0.99)])
        )
        _ = try await store.insertProposal(p)

        let report = try await MemoryConsolidator(storage: store).consolidateDestructively()
        #expect(report.duplicatesMerged == 1)
        #expect(report.autoAccepted == 0)

        let pending = try await store.listProposals(status: "pending")
        #expect(pending.isEmpty)
        let merged = try await store.listProposals(status: "merged")
        #expect(merged.contains(where: { $0.id == p.id }))

        // Older memory's recall_count bumped to 1.
        let bumped = try await store.memory(id: mem.id)
        guard case .object(let meta)? = bumped?.metadata,
              case .int(let n)? = meta["recall_count"] else {
            Issue.record("expected metadata.recall_count to be set after merge")
            return
        }
        #expect(n == 1)
    }

    @Test func skipsTombstonedProposal() async throws {
        let store = try makeStore()
        let content = "this fact was rejected before"
        try await store.addTombstone(content: content, reason: "user said no")
        let p = StoredProposal(
            content: content,
            source: "consolidator-test",
            embedding: vec(0, 1, 0, 0),
            metadata: .object(["durability_score": .double(0.99)])
        )
        _ = try await store.insertProposal(p)

        let report = try await MemoryConsolidator(storage: store).consolidateDestructively()
        #expect(report.processed == 1)
        #expect(report.autoAccepted == 0)
        #expect(report.duplicatesMerged == 0)
        #expect(report.pendingForReview == 0)

        let rejected = try await store.listProposals(status: "rejected")
        #expect(rejected.contains(where: { $0.id == p.id }))
        let mems = try await store.listMemories()
        #expect(mems.isEmpty)
    }

    @Test func rejectsNonDurableRuntimeStateBeforeAutoAccept() async throws {
        let store = try makeStore()
        let p = StoredProposal(
            content: "user's session context is reset",
            source: "adaptive-promoter:test",
            embedding: vec(0, 1, 0, 0),
            metadata: .object([
                "durability_score": .double(0.99),
                "kind": .string("fact"),
            ])
        )
        _ = try await store.insertProposal(p)

        let report = try await MemoryConsolidator(storage: store).consolidateDestructively()
        #expect(report.processed == 1)
        #expect(report.autoAccepted == 0)
        #expect(report.pendingForReview == 0)

        let rejected = try await store.listProposals(status: "rejected")
        #expect(rejected.contains(where: { proposal in
            proposal.id == p.id
                && (proposal.rejectionReason?.contains("non-durable proposal") ?? false)
        }))
        let tombstoned = try await store.isTombstoned(content: p.content)
        #expect(tombstoned == true)
        let mems = try await store.listMemories()
        #expect(mems.isEmpty)
    }

    @Test func archivesActiveNonDurableSemanticFragments() async throws {
        let store = try makeStore()
        for idx in 1...3 {
            _ = try await store.insertMemory(StoredMemory(
                id: "semantic-fragment-\(idx)",
                content: "user likes app interfaces to feel",
                source: "adaptive-promoter:test",
                confidence: 0.8,
                embedding: vec(0, 1, 0, 0),
                status: "active",
                metadata: .object(["kind": .string("preference")])
            ))
        }

        let report = try await MemoryConsolidator(storage: store).consolidateDestructively()
        #expect(report.staleArchived == 3)
        #expect(report.errors.isEmpty)

        let actives = try await store.listMemories(status: "active")
        #expect(!actives.contains(where: { $0.content == "user likes app interfaces to feel" }))

        let archived = try await store.listMemories(status: "archived")
        let fragments = archived.filter { $0.content == "user likes app interfaces to feel" }
        #expect(fragments.count == 3)
        for memory in fragments {
            guard case .object(let meta)? = memory.metadata,
                  case .string(let reason)? = meta["hygiene_archive_reason"] else {
                Issue.record("expected semantic fragment archive provenance")
                continue
            }
            #expect(reason.contains("incomplete semantic fragment"))
        }
    }

    @Test func archivesDuplicateActiveSemanticMemoriesKeepsBest() async throws {
        let store = try makeStore()
        let old = isoStringDaysAgo(30)
        _ = try await store.insertMemory(StoredMemory(
            id: "semantic-dup-old",
            content: "user prefers direct answers",
            source: "adaptive-promoter:test",
            confidence: 0.7,
            createdAt: old,
            updatedAt: old,
            embedding: vec(1, 0, 0, 0),
            status: "active",
            metadata: .object(["kind": .string("preference")])
        ))
        _ = try await store.insertMemory(StoredMemory(
            id: "semantic-dup-best",
            content: "the user prefers direct answers",
            source: "adaptive-promoter:test",
            confidence: 0.9,
            embedding: vec(1, 0, 0, 0),
            status: "active",
            metadata: .object(["kind": .string("preference")])
        ))

        let report = try await MemoryConsolidator(storage: store).consolidateDestructively()
        #expect(report.duplicatesMerged == 1)
        #expect(report.errors.isEmpty)

        let activeIds = Set(try await store.listMemories(status: "active").map(\.id))
        #expect(activeIds.contains("semantic-dup-best"))
        #expect(!activeIds.contains("semantic-dup-old"))

        let archivedOld = try await store.listMemories(status: "archived")
            .first(where: { $0.id == "semantic-dup-old" })
        guard case .object(let meta)? = archivedOld?.metadata,
              case .string(let duplicateOf)? = meta["duplicate_of"] else {
            Issue.record("expected duplicate archive provenance")
            return
        }
        #expect(duplicateOf == "semantic-dup-best")
    }

    @Test func archivesStaleUnusedMemory() async throws {
        let store = try makeStore()
        // 400-day-old memory with no recall_count.
        let old = isoStringDaysAgo(400)
        let stale = StoredMemory(
            id: "stale-1",
            content: "ancient never-recalled fact",
            createdAt: old,
            updatedAt: old,
            status: "active"
        )
        _ = try await store.insertMemory(stale)
        // Fresh memory should stay active.
        let fresh = StoredMemory(
            id: "fresh-1",
            content: "today's fact",
            status: "active"
        )
        _ = try await store.insertMemory(fresh)
        // Old memory with recall_count > 0 (merge corroboration) stays active.
        let oldButUsed = StoredMemory(
            id: "old-used",
            content: "old but recalled",
            createdAt: old,
            updatedAt: old,
            status: "active",
            metadata: .object(["recall_count": .int(3)])
        )
        _ = try await store.insertMemory(oldButUsed)
        // #0: old memory with use_count > 0 (recall access) but recall_count == 0
        // must ALSO survive — the keystone fix. Before this, a hot-but-never-
        // merged memory read as "unused" and got archived (silent data loss).
        let oldButRecalled = StoredMemory(
            id: "old-recalled",
            content: "old, never merged, but recalled often",
            createdAt: old,
            updatedAt: old,
            status: "active",
            useCount: 5
        )
        _ = try await store.insertMemory(oldButRecalled)

        let report = try await MemoryConsolidator(storage: store).consolidateDestructively()
        #expect(report.staleArchived == 1)

        let actives = try await store.listMemories(status: "active")
        let activeIds = Set(actives.map(\.id))
        #expect(activeIds.contains("fresh-1"))
        #expect(activeIds.contains("old-used"))
        #expect(activeIds.contains("old-recalled"))
        #expect(!activeIds.contains("stale-1"))

        let archived = try await store.listMemories(status: "archived")
        #expect(archived.contains(where: { $0.id == "stale-1" }))
    }

    @Test func archiveIfStillUnusedVetoesWhenRecallLandsAfterSnapshot() async throws {
        // TOCTOU guard (gpt-5.5 review finding 1): a recall bump that lands
        // AFTER the consolidator's snapshot but BEFORE the archive write must
        // veto the eviction — the conditional UPDATE re-checks use_count.
        let store = try makeStore()
        let old = isoStringDaysAgo(400)
        _ = try await store.insertMemory(StoredMemory(
            id: "racy-1", content: "old fact, recalled mid-sweep",
            createdAt: old, updatedAt: old, status: "active"
        ))
        // Simulate the race: snapshot would have seen use_count == 0; a recall
        // bump lands before the archive write fires.
        try await store.recordRecallHits(ids: ["racy-1"])
        let archived = try await store.archiveIfStillUnused(id: "racy-1")
        #expect(archived == false)
        let m = try await store.memory(id: "racy-1")
        #expect(m?.status == "active")

        // And a genuinely untouched one still archives through the same gate.
        _ = try await store.insertMemory(StoredMemory(
            id: "dead-1", content: "old fact, truly unused",
            createdAt: old, updatedAt: old, status: "active"
        ))
        let archivedDead = try await store.archiveIfStillUnused(id: "dead-1")
        #expect(archivedDead == true)
        let d = try await store.memory(id: "dead-1")
        #expect(d?.status == "archived")
    }

    @Test func recordRecallHitsBumpsUseCountAndLastUsed() async throws {
        let store = try makeStore()
        _ = try await store.insertMemory(StoredMemory(id: "m1", content: "fact one", status: "active"))
        _ = try await store.insertMemory(StoredMemory(id: "m2", content: "fact two", status: "active"))

        // Two recalls of m1, one of m2.
        try await store.recordRecallHits(ids: ["m1", "m2"], at: "2026-06-09T00:00:00.000Z")
        try await store.recordRecallHits(ids: ["m1"], at: "2026-06-09T01:00:00.000Z")

        let m1 = try await store.memory(id: "m1")
        let m2 = try await store.memory(id: "m2")
        #expect(m1?.useCount == 2)
        #expect(m1?.lastUsedAt == "2026-06-09T01:00:00.000Z")
        #expect(m2?.useCount == 1)
        // A recall must NOT touch updated_at (access != mutation; would corrupt
        // recency ranking + reset the stale clock).
        #expect(m1?.updatedAt != "2026-06-09T01:00:00.000Z")
    }

    @Test func decayFactorIsKindScopedAndRankOnly() async throws {
        let now = ISO8601DateFormatter().string(from: Date())
        // Volatile fact 60 days old → exactly one half-life ≈ 0.5.
        let sixtyAgo = isoStringDaysAgo(60)
        let v = MemoryRecallScoring.decayFactor(kind: "volatile", updatedAt: sixtyAgo)
        #expect(v > 0.45 && v < 0.55)
        // Identity (exempt) and nil-kind (legacy) → no decay.
        #expect(MemoryRecallScoring.decayFactor(kind: "identity", updatedAt: sixtyAgo) == 1.0)
        #expect(MemoryRecallScoring.decayFactor(kind: nil, updatedAt: sixtyAgo) == 1.0)
        // Fresh volatile → ~1.0. Unparseable timestamp → exempt, not crash.
        #expect(MemoryRecallScoring.decayFactor(kind: "volatile", updatedAt: now) > 0.99)
        #expect(MemoryRecallScoring.decayFactor(kind: "volatile", updatedAt: "garbage") == 1.0)
    }

    @Test func recallRanksFreshVolatileAboveStaleVolatileAtEqualCosine() async throws {
        let store = try makeStore()
        let vec: [Float] = [1, 0, 0]
        let old = isoStringDaysAgo(120)  // two half-lives → ~0.25x
        _ = try await store.insertMemory(StoredMemory(
            id: "stale-vol", content: "old project note",
            createdAt: old, updatedAt: old,
            embedding: vec, status: "active",
            metadata: .object(["kind": .string("project")])
        ))
        _ = try await store.insertMemory(StoredMemory(
            id: "fresh-vol", content: "fresh project note",
            embedding: vec, status: "active",
            metadata: .object(["kind": .string("project")])
        ))
        // Old IDENTITY fact at the same cosine must be unaffected by age.
        _ = try await store.insertMemory(StoredMemory(
            id: "old-identity", content: "user's name is the user",
            createdAt: old, updatedAt: old,
            embedding: vec, status: "active",
            metadata: .object(["kind": .string("identity")])
        ))
        let hits = try await store.recall(embedding: vec, topK: 3)
        let order = hits.map(\.memory.id)
        #expect(order.first != "stale-vol")           // decayed below the others
        #expect(order.last == "stale-vol")
        #expect(hits.first(where: { $0.memory.id == "old-identity" })?.similarity ?? 0 > 0.99)
        // Decay shapes RANK only — the stale row is still present (existence
        // untouched), just demoted.
        #expect(order.contains("stale-vol"))
    }

    @Test func supersessionArchivesOlderSingleValuedFactOnly() async throws {
        let store = try makeStore()
        // Two location facts, same topic (cosine 1.0), different ages →
        // newer supersedes older. Older is ARCHIVED with provenance, not deleted.
        let old = isoStringDaysAgo(30)
        _ = try await store.insertMemory(StoredMemory(
            id: "loc-old", content: "user lives in Example County",
            createdAt: old, updatedAt: old,
            embedding: [1, 0, 0], status: "active",
            metadata: .object(["kind": .string("location")])
        ))
        _ = try await store.insertMemory(StoredMemory(
            id: "loc-new", content: "user lives in Austin",
            embedding: [0.9, 0.43, 0], status: "active",
            metadata: .object(["kind": .string("location")])
        ))
        // Two preference facts (multi-valued kind) — must coexist.
        _ = try await store.insertMemory(StoredMemory(
            id: "pref-a", content: "user likes tea",
            createdAt: old, updatedAt: old,
            embedding: [0, 1, 0], status: "active",
            metadata: .object(["kind": .string("preference")])
        ))
        _ = try await store.insertMemory(StoredMemory(
            id: "pref-b", content: "user likes green tea",
            embedding: [0, 0.99, 0.14], status: "active",
            metadata: .object(["kind": .string("preference")])
        ))

        _ = try await MemoryConsolidator(storage: store).consolidateDestructively()

        let actives = Set(try await store.listMemories(status: "active").map(\.id))
        #expect(actives.contains("loc-new"))
        #expect(!actives.contains("loc-old"))
        #expect(actives.contains("pref-a"))
        #expect(actives.contains("pref-b"))

        let archived = try await store.listMemories(status: "archived")
        let locOld = archived.first(where: { $0.id == "loc-old" })
        #expect(locOld != nil)  // archived, NOT deleted
        if case .object(let meta)? = locOld?.metadata, case .string(let by)? = meta["superseded_by"] {
            #expect(by == "loc-new")
        } else {
            Issue.record("superseded provenance missing")
        }
    }

    @Test func supersessionRespectsCosineFloor() async throws {
        // Same single-valued kind but UNRELATED topics (below the floor) must
        // coexist — the mechanism guard against kind-label collisions.
        let store = try makeStore()
        let old = isoStringDaysAgo(30)
        _ = try await store.insertMemory(StoredMemory(
            id: "emp-role", content: "user works as a designer",
            createdAt: old, updatedAt: old,
            embedding: [1, 0, 0], status: "active",
            metadata: .object(["kind": .string("employment")])
        ))
        _ = try await store.insertMemory(StoredMemory(
            id: "emp-co", content: "user works at Apple",
            embedding: [0.2, 0.98, 0], status: "active",  // cosine 0.2 < floor
            metadata: .object(["kind": .string("employment")])
        ))
        _ = try await MemoryConsolidator(storage: store).consolidateDestructively()
        let actives = Set(try await store.listMemories(status: "active").map(\.id))
        #expect(actives.contains("emp-role"))
        #expect(actives.contains("emp-co"))
    }

    // MARK: - utility

    private func isoStringDaysAgo(_ days: Int) -> String {
        let d = Date().addingTimeInterval(-Double(days) * 86_400)
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.string(from: d)
    }
}
