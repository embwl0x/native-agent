// R5 — in-actor recall candidate cache + data_version net.
//
// These tests prove three things about the fast-recall cache added to
// MemoryStorage:
//   1. Ranking is byte-identical to the pre-cache scan loop (equivalence oracle,
//      exact id+score sequence) for both recall() and nearestActiveNeighbor().
//   2. Every in-actor mutation path invalidates the cache (generation belt), AND
//      an out-of-band consolidation swap invalidates it via the PRAGMA
//      data_version net — even though it never touches the actor.
//   3. The cache actually serves repeat recalls without re-querying
//      (recallCacheRebuildCount increments exactly once per candidate-set change).
//
// The equivalence oracle is a verbatim copy of the pre-cache scan loop. It uses
// nil-kind rows on purpose: decayFactor is time-dependent ONLY for the decaying
// kinds (volatile/project/operational), and both the oracle and recall() sample
// Date() a few microseconds apart, so exact score equality is only achievable
// with decay ≡ 1.0. The cache change is orthogonal to decay (both old and new
// compute it fresh per call), so nil-kind rows isolate exactly what the cache
// touches: candidate selection, norm precompute, BM25, dedup, and ordering.

import Testing
import Foundation
import ApprovalInbox
import GRDB
import KnowledgeGraph
@testable import MemoryV2
import NativeAgentCore

// MARK: - Oracle (verbatim copy of the pre-cache scan loop)

private func oracleL2Norm(_ v: [Float]) -> Float {
    var s: Float = 0
    for x in v { s += x * x }
    return s.squareRoot()
}

private func oracleNormalizedContent(_ content: String) -> String {
    content
        .lowercased()
        .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        .trimmingCharacters(in: .whitespacesAndNewlines)
}

private func oracleUnique(
    _ scored: [(StoredMemory, Double)],
    limit: Int
) -> [(id: String, score: Double)] {
    let cappedLimit = max(0, limit)
    guard cappedLimit > 0 else { return [] }
    var seen: Set<String> = []
    var out: [(id: String, score: Double)] = []
    for (memory, similarity) in scored {
        let key = oracleNormalizedContent(memory.content)
        if !key.isEmpty {
            guard seen.insert(key).inserted else { continue }
        }
        out.append((id: memory.id, score: similarity))
        if out.count >= cappedLimit { break }
    }
    return out
}

/// The pre-R5 recall scan loop, copied verbatim. `all` MUST be in insertion
/// order — which equals rowid order, and the production cache rebuild now pins
/// `ORDER BY rowid` explicitly (review fix 2026-07-01), so this oracle's order
/// assumption is enforced by the SQL rather than left to the query planner.
private func oracleRecall(
    _ all: [StoredMemory],
    query: [Float],
    queryText: String?,
    topK: Int,
    persona: String?
) -> [(id: String, score: Double)] {
    let candidates = all.filter { m in
        m.embedding != nil
            && m.status == "active"
            && !MemoryLifecycle.recallExcluded.contains(m.lifecycle)
            && (persona == nil || m.personaId == persona)
    }
    let queryNorm = oracleL2Norm(query)
    guard queryNorm > 0 else { return [] }
    let now = Date()
    let lexicalScores = MemoryRecallScoring.normalizedBM25Scores(
        query: queryText,
        documents: candidates.map(\.content)
    )
    var scored: [(StoredMemory, Double)] = []
    for (idx, m) in candidates.enumerated() {
        guard let e = m.embedding, e.count == query.count else { continue }
        let n = oracleL2Norm(e)
        guard n > 0 else { continue }
        var dot: Float = 0
        for i in 0..<e.count { dot += e[i] * query[i] }
        let sim = Double(dot) / (Double(queryNorm) * Double(n))
        let lexicalBoost = (idx < lexicalScores.count)
            ? memoryBM25LexicalBoost * lexicalScores[idx]
            : 0
        let decay = MemoryRecallScoring.decayFactor(
            kind: MemoryRecallScoring.kind(of: m.metadata),
            updatedAt: m.updatedAt,
            now: now
        )
        scored.append((m, (sim + lexicalBoost) * decay * MemoryLifecycle.rankingFactor(m.lifecycle)))
    }
    scored.sort { $0.1 > $1.1 }
    return oracleUnique(scored, limit: topK)
}

private func oracleNearest(
    _ all: [StoredMemory],
    query: [Float],
    excluding excludedId: String?
) -> (id: String, cosine: Double)? {
    let candidates = all.filter { m in
        m.embedding != nil
            && m.status == "active"
            && !MemoryLifecycle.recallExcluded.contains(m.lifecycle)
            && (excludedId == nil || m.id != excludedId)
    }
    let queryNorm = oracleL2Norm(query)
    guard queryNorm > 0 else { return nil }
    var best: (StoredMemory, Double)? = nil
    for m in candidates {
        guard let e = m.embedding, e.count == query.count else { continue }
        let n = oracleL2Norm(e)
        guard n > 0 else { continue }
        var dot: Float = 0
        for i in 0..<e.count { dot += e[i] * query[i] }
        let cosine = Double(dot) / (Double(queryNorm) * Double(n))
        if best == nil || cosine > best!.1 { best = (m, cosine) }
    }
    return best.map { (id: $0.0.id, cosine: $0.1) }
}

// MARK: - Seed corpus

/// ~50 mixed rows: 3 personas, all lifecycles (eligible + excluded), nil-embedding,
/// zero-vector, mismatched-dim, duplicate content (dedup), BM25 keyword overlap.
/// nil kind throughout so decay ≡ 1.0 (see file header). Returned in insertion
/// order so the oracle's rowid assumption holds.
private func seedCorpus() -> [StoredMemory] {
    let personas = ["NativeAgent", "Agent", "Other"]
    let eligibleLifecycles = [
        MemoryLifecycle.confirmed, MemoryLifecycle.inferred,
        MemoryLifecycle.temporary, MemoryLifecycle.stale,
    ]
    let excludedLifecycles = [
        MemoryLifecycle.corrected, MemoryLifecycle.contradicted, MemoryLifecycle.deleted,
    ]
    let words = ["teal", "garlic", "opus", "pigeon", "swift", "memory", "recall", "cache"]
    var rows: [StoredMemory] = []
    for i in 0..<50 {
        let persona = personas[i % personas.count]
        // Mix eligible + excluded lifecycles.
        let lifecycle: String = (i % 7 == 0)
            ? excludedLifecycles[(i / 7) % excludedLifecycles.count]
            : eligibleLifecycles[i % eligibleLifecycles.count]
        let w1 = words[i % words.count]
        let w2 = words[(i * 3 + 1) % words.count]
        // Every 11th row duplicates an earlier row's content to exercise dedup.
        let content = (i % 11 == 5 && i >= 11)
            ? rows[i - 11].content
            : "row \(i) about \(w1) and \(w2) fact"

        var embedding: [Float]? = [
            Float((i % 5) + 1) * 0.1,
            Float((i % 3) + 1) * 0.2,
            Float((i % 7) + 1) * 0.05,
            Float((i % 4) + 1) * 0.15,
        ]
        if i % 13 == 3 { embedding = nil }                 // nil embedding
        else if i % 17 == 4 { embedding = [0, 0, 0, 0] }   // zero vector
        else if i % 19 == 6 { embedding = [0.3, 0.7, 0.1] } // mismatched dim (3 vs 4)

        rows.append(StoredMemory(
            id: String(format: "row-%03d", i),
            content: content,
            personaId: persona,
            source: "seed",
            embedding: embedding,
            status: "active",
            lifecycle: lifecycle,
            metadata: nil,               // nil kind → decay 1.0
            useCount: Int64(i % 4)
        ))
    }
    return rows
}

private func makeSeededStore() async throws -> (MemoryStorage, [StoredMemory]) {
    let store = try MemoryStorage()
    let rows = seedCorpus()
    for r in rows { _ = try await store.insertMemory(r) }
    return (store, rows)
}

// MARK: - Tests

@Suite("RecallCache", .serialized)
struct RecallCacheTests {

    // 1. Equivalence oracle — exact id+score sequence for varied queries.
    @Test func recall_matches_oracle_exactly() async throws {
        let (store, rows) = try await makeSeededStore()
        let queries: [(q: [Float], text: String?, persona: String?)] = [
            ([1, 0, 0, 0], nil, nil),
            ([0.2, 0.6, 0.1, 0.3], "teal garlic fact", nil),
            ([0.5, 0.5, 0.5, 0.5], "swift memory recall", "NativeAgent"),
            ([0.1, 0.9, 0.0, 0.2], "opus pigeon", "Agent"),
            ([0.3, 0.3, 0.3, 0.3], nil, "Other"),
            ([0.0, 0.0, 0.0, 1.0], "cache fact row", nil),
        ]
        for (q, text, persona) in queries {
            for topK in [1, 5, 25] {
                let got = try await store.recall(
                    embedding: q, queryText: text, topK: topK, persona: persona)
                let want = oracleRecall(rows, query: q, queryText: text, topK: topK, persona: persona)
                #expect(got.count == want.count, "count mismatch q=\(q) topK=\(topK) persona=\(String(describing: persona))")
                for (g, w) in zip(got, want) {
                    #expect(g.memory.id == w.id, "id mismatch: \(g.memory.id) != \(w.id)")
                    #expect(g.similarity == w.score, "score mismatch on \(g.memory.id): \(g.similarity) != \(w.score)")
                }
            }
        }
    }

    // 1b. nearestActiveNeighbor — raw cosine + excluding, exact match.
    @Test func nearestActiveNeighbor_matches_oracle_exactly() async throws {
        let (store, rows) = try await makeSeededStore()
        let cases: [(q: [Float], excl: String?)] = [
            ([1, 0, 0, 0], nil),
            ([0.2, 0.6, 0.1, 0.3], nil),
            ([0.2, 0.6, 0.1, 0.3], "row-001"),
            ([0.5, 0.5, 0.5, 0.5], "row-000"),
            ([0.0, 0.0, 0.0, 0.0], nil),   // zero query → nil
        ]
        for (q, excl) in cases {
            let got = try await store.nearestActiveNeighbor(embedding: q, excluding: excl)
            let want = oracleNearest(rows, query: q, excluding: excl)
            #expect(got?.memory.id == want?.id, "nearest id mismatch q=\(q) excl=\(String(describing: excl))")
            #expect(got?.cosine == want?.cosine, "nearest cosine mismatch q=\(q)")
        }
    }

    // 1c. Order-sensitivity: equal-score ties + duplicate-content dedup are the
    // two behaviors scan order can silently change (review finding 2026-07-01).
    // Identical embeddings force exact score ties; near-identical contents force
    // a dedup-key collision — the winner is decided purely by scan order, which
    // is now pinned to rowid. Rebuild path (first call) and cache-hit path
    // (second call) must both match the oracle's insertion-order result.
    @Test func recall_orderSensitiveTiesAndDedup_matchOracleOnBothCachePaths() async throws {
        let store = try MemoryStorage()
        let e: [Float] = [0, 1, 0, 0]
        let rows = [
            StoredMemory(id: "tie-a", content: "alpha distinct fact", embedding: e),
            StoredMemory(id: "tie-b", content: "beta distinct fact", embedding: e),
            StoredMemory(id: "dup-1", content: "User's favorite color is teal", embedding: e),
            StoredMemory(id: "dup-2", content: "user's  favorite color is TEAL", embedding: e),
        ]
        var inserted: [StoredMemory] = []
        for r in rows { inserted.append(try await store.insertMemory(r)) }

        let want = oracleRecall(inserted, query: e, queryText: nil, topK: 10, persona: nil)
        let rebuild = try await store.recall(embedding: e, topK: 10).map(\.memory.id)
        let cacheHit = try await store.recall(embedding: e, topK: 10).map(\.memory.id)
        #expect(rebuild == want.map(\.id))
        #expect(cacheHit == rebuild)
        // Dedup collision: exactly one of dup-1/dup-2 survives — the earlier rowid.
        #expect(rebuild.contains("dup-1"))
        #expect(!rebuild.contains("dup-2"))
    }

    // 2a. add-visible: a newly inserted embedded row shows up in the next recall.
    @Test func invalidation_add_visible() async throws {
        let store = try MemoryStorage()
        _ = try await store.recall(embedding: [1, 0, 0, 0], topK: 5)  // prime empty cache
        let fresh = StoredMemory(id: "fresh", content: "brand new teal fact", embedding: [1, 0, 0, 0])
        _ = try await store.insertMemory(fresh)
        let ids = try await store.recall(embedding: [1, 0, 0, 0], topK: 5).map(\.memory.id)
        #expect(ids.contains("fresh"))
    }

    // 2b. delete-gone.
    @Test func invalidation_delete_gone() async throws {
        let store = try MemoryStorage()
        let m = StoredMemory(id: "doomed", content: "soon deleted teal fact", embedding: [1, 0, 0, 0])
        _ = try await store.insertMemory(m)
        #expect(try await store.recall(embedding: [1, 0, 0, 0], topK: 5).contains { $0.memory.id == "doomed" })
        _ = try await store.deleteMemory(id: "doomed")
        #expect(try await store.recall(embedding: [1, 0, 0, 0], topK: 5).isEmpty)
    }

    // 2c. lifecycle-corrected → excluded via updateMemory.
    @Test func invalidation_lifecycle_corrected_excluded() async throws {
        let store = try MemoryStorage()
        let m = StoredMemory(id: "corrigible", content: "correctable teal fact", embedding: [1, 0, 0, 0])
        _ = try await store.insertMemory(m)
        #expect(try await store.recall(embedding: [1, 0, 0, 0], topK: 5).contains { $0.memory.id == "corrigible" })
        _ = try await store.updateMemory(id: "corrigible", patch: MemoryPatch(lifecycle: MemoryLifecycle.corrected))
        #expect(try await store.recall(embedding: [1, 0, 0, 0], topK: 5).isEmpty)
    }

    // 2d. archiveIfStillUnused + archiveSuperseded → excluded.
    @Test func invalidation_archive_paths_excluded() async throws {
        let store = try MemoryStorage()
        let a = StoredMemory(id: "arch-unused", content: "unused archive fact", embedding: [1, 0, 0, 0])
        let b = StoredMemory(id: "arch-superseded", content: "superseded fact", embedding: [0, 1, 0, 0])
        let c = StoredMemory(id: "newer", content: "newer superseding fact", embedding: [0, 1, 0, 0])
        _ = try await store.insertMemory(a)
        _ = try await store.insertMemory(b)
        _ = try await store.insertMemory(c)

        #expect(try await store.recall(embedding: [1, 0, 0, 0], topK: 5).contains { $0.memory.id == "arch-unused" })
        #expect(try await store.archiveIfStillUnused(id: "arch-unused"))
        #expect(!(try await store.recall(embedding: [1, 0, 0, 0], topK: 5).contains { $0.memory.id == "arch-unused" }))

        #expect(try await store.recall(embedding: [0, 1, 0, 0], topK: 5).contains { $0.memory.id == "arch-superseded" })
        #expect(try await store.archiveSuperseded(id: "arch-superseded", by: "newer"))
        #expect(!(try await store.recall(embedding: [0, 1, 0, 0], topK: 5).contains { $0.memory.id == "arch-superseded" }))
    }

    // 2e. recordRecallHits → next recall reflects bumped useCount (cache holds StoredMemory).
    @Test func invalidation_recordRecallHits_bumps_useCount() async throws {
        let store = try MemoryStorage()
        let m = StoredMemory(id: "hit-me", content: "recall hit fact", embedding: [1, 0, 0, 0])
        _ = try await store.insertMemory(m)
        let before = try await store.recall(embedding: [1, 0, 0, 0], topK: 5).first { $0.memory.id == "hit-me" }
        #expect(before?.memory.useCount == 0)
        try await store.recordRecallHits(ids: ["hit-me"])
        let after = try await store.recall(embedding: [1, 0, 0, 0], topK: 5).first { $0.memory.id == "hit-me" }
        #expect(after?.memory.useCount == 1)
    }

    // 2f. acceptProposal → promoted row visible.
    @Test func invalidation_acceptProposal_visible() async throws {
        let store = try MemoryStorage()
        _ = try await store.recall(embedding: [1, 0, 0, 0], topK: 5)  // prime
        let p = StoredProposal(id: "prop", content: "promotable teal fact", embedding: [1, 0, 0, 0])
        _ = try await store.insertProposal(p)
        _ = try await store.acceptProposal(id: "prop")
        let ids = try await store.recall(embedding: [1, 0, 0, 0], topK: 5).map(\.memory.id)
        #expect(ids.contains("prop"))
    }

    // 3. THE CRUX: an out-of-band consolidation swap must be caught by the
    //    data_version net, even though it runs on its own DatabaseQueue and never
    //    touches the actor. Generation is untouched across the swap; the ONLY
    //    thing that forces the rebuild is data_version.
    @Test func invalidation_consolidation_swap_data_version_net() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("recallcache-swap-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let storage = try MemoryStorage(dataRoot: root)
        let memA = StoredMemory(content: "the user's favorite color is teal blue", embedding: [1, 0, 0, 0])
        let memB = StoredMemory(content: "Agent runs on the NativeAgent macOS app", embedding: [0, 1, 0, 0])
        _ = try await storage.insertMemory(memA)
        _ = try await storage.insertMemory(memB)
        let proposal = StoredProposal(
            content: "the user ships fast and verifies empirically",
            source: "gate-test",
            embedding: [0, 0, 1, 0],
            metadata: .object(["durability_score": .double(0.91)])
        )
        _ = try await storage.insertProposal(proposal)

        let probes = MemoryProbeSet(topK: 5, probes: [
            MemoryProbe(id: "q1", question: "What is the user's favorite color?",
                        expectAnySubstring: ["favorite color is teal"]),
            MemoryProbe(id: "q2", question: "Where does Agent run?",
                        expectAnySubstring: ["NativeAgent macOS app"]),
        ])
        let embedder = KeyedEmbedder(table: [
            "What is the user's favorite color?": [1, 0, 0, 0],
            "Where does Agent run?": [0, 1, 0, 0],
        ])
        let consolidator = MemoryConsolidator(storage: storage, embedder: embedder, probeSet: probes)

        let outcome = try await consolidator.consolidateGated()
        guard case .staged(let approvalId, _, _, _) = outcome else {
            Issue.record("expected .staged, got \(outcome)")
            return
        }

        // Prime the live actor's cache with the PRE-swap candidate set. The
        // proposal is not yet an active memory, so it must be absent.
        let preHits = try await storage.recall(embedding: [0, 0, 1, 0], topK: 5)
        #expect(!preHits.contains { $0.memory.content == proposal.content },
                "proposal must not be an active memory before the swap")
        let rebuildsBefore = await storage.recallCacheRebuildCount

        // Approve + reconcile: the out-of-band DatabaseQueue swap replaces the
        // memories table on the live file. Generation is NOT bumped (the actor
        // never sees it) — only data_version changes.
        _ = try await SwiftNativeApprovalInbox(root: root).resolve(
            approvalId, decision: .approved, decidedBy: "recallcache-test")
        let outcomes = await MemoryConsolidationGate.reconcile(dataRoot: root)
        #expect(outcomes.contains { if case .applied = $0 { return true }; return false })

        // Next recall MUST reflect the swapped-in row — proving the data_version
        // net fired for the static, actor-blind writer.
        let postHits = try await storage.recall(embedding: [0, 0, 1, 0], topK: 5)
        #expect(postHits.first?.memory.content == proposal.content,
                "data_version net must surface the swapped-in proposal row")
        let rebuildsAfter = await storage.recallCacheRebuildCount
        #expect(rebuildsAfter == rebuildsBefore + 1,
                "the ONLY post-swap rebuild must be the data_version-driven one")
    }

    // 4. No-requery sanity: two identical recalls over 2000 rows rebuild exactly
    //    once; a mutation forces exactly one more rebuild.
    @Test func cache_serves_repeat_recalls_without_requery() async throws {
        let store = try MemoryStorage()
        for i in 0..<2000 {
            _ = try await store.insertMemory(StoredMemory(
                id: String(format: "big-%04d", i),
                content: "bulk row \(i) swift memory",
                embedding: [Float(i % 5) * 0.1 + 0.1, Float(i % 3) * 0.2 + 0.1,
                            Float(i % 7) * 0.05 + 0.05, Float(i % 4) * 0.15 + 0.1]
            ))
        }
        // First recall builds the cache once.
        _ = try await store.recall(embedding: [0.3, 0.3, 0.2, 0.4], topK: 10)
        let afterFirst = await store.recallCacheRebuildCount
        // Second recall (different query, same candidate set) must be served from cache.
        _ = try await store.recall(embedding: [0.9, 0.1, 0.0, 0.2], queryText: "swift memory", topK: 10)
        let afterSecond = await store.recallCacheRebuildCount
        #expect(afterSecond == afterFirst, "second recall must not re-query (served from cache)")

        // A mutation invalidates; the next recall rebuilds exactly once more.
        _ = try await store.insertMemory(StoredMemory(
            id: "big-new", content: "one more swift memory row", embedding: [0.5, 0.5, 0.5, 0.5]))
        _ = try await store.recall(embedding: [0.5, 0.5, 0.5, 0.5], topK: 10)
        let afterMutation = await store.recallCacheRebuildCount
        #expect(afterMutation == afterSecond + 1, "mutation must force exactly one rebuild")
    }
}
