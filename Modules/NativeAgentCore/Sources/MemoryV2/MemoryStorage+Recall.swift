import Foundation
import GRDB
import NativeAgentCore
import PersistenceCore

extension MemoryStorage {
    struct RecallCandidate {
        var memory: StoredMemory
        let norm: Float            // precomputed Self.l2norm(embedding) — bit-identical to per-turn recompute
        let lexicalDocument: MemoryRecallScoring.LexicalDocument
    }
    struct RecallCache {
        let candidates: [RecallCandidate]
        let generation: Int
        let corpusGeneration: Int64
        let embeddingEpoch: String?
    }
    // MARK: - Recall candidate cache

    public func recallJudgmentGeneration() async throws -> String {
        let generation = try await dbPool.read { db in
            try Self.recallJudgmentGeneration(in: db)
        }
        return "\(path.path):\(generation)"
    }

    private static func recallJudgmentGeneration(in db: Database) throws -> Int64 {
        guard let value = try Int64.fetchOne(db, sql:
            "SELECT value FROM memory_metadata WHERE key = 'recall_generation'") else {
            throw MemoryStorageError.databaseUnavailable("Recall generation is missing.")
        }
        return value
    }

    /// Local invalidation fences cache installation across actor reentrancy.
    /// The canonical generation also detects writes by other connections.
    func invalidateRecallCache() {
        recallGeneration += 1
        recallCache = nil
    }

    /// Reuse decoded vectors and lexical documents while the canonical corpus
    /// generation is unchanged. Read its epoch, generation and fresh usage
    /// together before candidates: a racing write can only cause a later miss,
    /// never label an older candidate snapshot with a newer generation.
    private func recallCandidates(
        queryEpoch: MemoryEmbeddingEpoch?
    ) async throws -> (candidates: [RecallCandidate], epochMismatch: Bool) {
        let generation = recallGeneration
        let (activeEpoch, corpusGeneration, usage) = try await dbPool.read { db in
            let epoch = try Self.embeddingEpochState(in: db).activeEpoch
            let version = try Self.recallJudgmentGeneration(in: db)
            let rows = try Row.fetchAll(db, sql: """
                SELECT id, use_count, last_used_at FROM memories
                WHERE embedding IS NOT NULL AND status = 'active'
                  AND lifecycle NOT IN \(MemoryLifecycle.recallExcludedSQL)
                """)
            let usage = Dictionary(uniqueKeysWithValues: rows.map { row in
                (row["id"] as String, (row["use_count"] as Int64, row["last_used_at"] as String?))
            })
            return (epoch, version, usage)
        }
        if let activeEpoch, queryEpoch?.rawValue != activeEpoch {
            return ([], true)
        }
        func refreshed(_ candidates: [RecallCandidate]) -> [RecallCandidate] {
            candidates.map { candidate in
                var candidate = candidate
                if let counters = usage[candidate.memory.id] {
                    candidate.memory.useCount = counters.0
                    candidate.memory.lastUsedAt = counters.1
                }
                return candidate
            }
        }
        if let cache = recallCache,
           cache.generation == recallGeneration,
           cache.corpusGeneration == corpusGeneration,
           cache.embeddingEpoch == activeEpoch {
            return (refreshed(cache.candidates), false)
        }
        // One rowid-ordered query preserves equal-score tie-breaking, dedup
        // preference, and BM25 document indices across query-planner choices.
        let candidates = try await dbPool.read { db -> [RecallCandidate] in
            var sql = """
                SELECT * FROM memories
                WHERE embedding IS NOT NULL
                  AND status = 'active'
                  AND lifecycle NOT IN \(MemoryLifecycle.recallExcludedSQL)
            """
            var arguments: StatementArguments = []
            if let activeEpoch {
                sql += " AND embedding_epoch = ?"
                arguments = [activeEpoch]
            }
            sql += " ORDER BY rowid"
            let rows = try Row.fetchAll(db, sql: sql, arguments: arguments)
            return try rows.map { row in
                let m = try Self.decodeMemory(row)
                let norm = m.embedding.map(Self.l2norm) ?? 0
                return RecallCandidate(
                    memory: m, norm: norm,
                    lexicalDocument: MemoryRecallScoring.LexicalDocument(m.content)
                )
            }
        }
        // Growth guard: the cache holds the fully-decoded candidate set
        // (embeddings included). At Agent-scale (10³–10⁴ rows ≈ tens of MB)
        // that's the point of R5; past it, skip caching rather than balloon
        // resident memory — recall stays correct via the per-call scan path.
        if candidates.count <= 50_000, generation == recallGeneration {
            recallCache = RecallCache(
                candidates: candidates,
                generation: generation,
                corpusGeneration: corpusGeneration,
                embeddingEpoch: activeEpoch
            )
        } else {
            recallCache = nil
        }
        return (candidates, false)
    }

    // MARK: - Recall (hybrid dense + lexical sweep)

    public func recall(
        embedding query: [Float],
        embeddingEpoch queryEpoch: MemoryEmbeddingEpoch? = nil,
        queryText: String? = nil,
        topK: Int,
        persona: String? = nil
    ) async throws -> [(memory: StoredMemory, similarity: Double)] {
        Self.uniqueRecallResults(try await rankedRecall(
            embedding: query, embeddingEpoch: queryEpoch, queryText: queryText, persona: persona
        ), limit: topK)
    }

    func rankedRecall(
        embedding query: [Float],
        embeddingEpoch queryEpoch: MemoryEmbeddingEpoch?,
        queryText: String?,
        persona: String?
    ) async throws -> [(memory: StoredMemory, similarity: Double)] {
        // R5: pull the shared cached candidate set, then apply the persona
        // filter in-memory. A single-persona equality filter over the full
        // rowid-ordered scan yields the same rows in the same order the old
        // persona-clause SQL returned, so BM25 idx alignment + ranking stay
        // byte-identical.
        let scan = try await recallCandidates(queryEpoch: queryEpoch)
        // The canonical embedding owner repairs mismatches before retrying recall.
        guard !scan.epochMismatch else {
            let state = try await embeddingEpochState()
            throw MemoryStorageError.embeddingEpochMismatch(
                expected: state.activeEpoch ?? "unknown", actual: queryEpoch?.rawValue
            )
        }
        let allCandidates = scan.candidates
        let candidates = persona == nil
            ? allCandidates
            : allCandidates.filter { $0.memory.personaId == persona }
        let queryNorm = Self.l2norm(query)
        // A directionless query cannot honestly answer semantic recall.
        guard queryNorm > 0 else {
            throw MemoryStorageError.embeddingActivationInvalid(
                .unusableCandidate, "semantic recall query has no usable vector"
            )
        }
        let now = Date()
        let lexicalScores = MemoryRecallScoring.normalizedBM25Scores(
            query: queryText,
            lexicalDocuments: candidates.map(\.lexicalDocument)
        )
        var scored: [(StoredMemory, Double)] = []
        scored.reserveCapacity(candidates.count)
        for (idx, candidate) in candidates.enumerated() {
            let m = candidate.memory
            guard let e = m.embedding, e.count == query.count else { continue }
            let n = candidate.norm
            guard n > 0 else { continue }
            var dot: Float = 0
            for i in 0..<e.count { dot += e[i] * query[i] }
            let sim = Double(dot) / (Double(queryNorm) * Double(n))
            let lexicalBoost = (idx < lexicalScores.count)
                ? memoryBM25LexicalBoost * lexicalScores[idx]
                : 0
            // Recency may break near-ties, never erase semantic relevance.
            // Exempt kinds and legacy nil-kind records retain factor 1.0.
            let decay = MemoryRecallScoring.recallRecencyFactor(
                kind: MemoryRecallScoring.kind(of: m.metadata),
                updatedAt: m.updatedAt,
                now: now
            )
            scored.append((
                m,
                (sim + lexicalBoost)
                    * decay
                    * MemoryLifecycle.rankingFactor(m.lifecycle)
            ))
        }
        scored.sort { $0.1 > $1.1 }
        return scored
    }

    static func uniqueRecallResults(
        _ scored: [(StoredMemory, Double)],
        limit: Int
    ) -> [(memory: StoredMemory, similarity: Double)] {
        let cappedLimit = max(0, limit)
        guard cappedLimit > 0 else { return [] }
        var seen: [String: [MemoryDisclosureClassification?]] = [:]
        // One pass with an early stop: `seen` makes this predicate stateful,
        // so it must never run twice over the same rows (a lazy filter's
        // `prefix` walks it once for `count` and again to copy — 10-10 crash).
        var out: [(memory: StoredMemory, similarity: Double)] = []
        for candidate in scored {
            let key = normalizedRecallContent(candidate.0.content)
            if !key.isEmpty {
                let scope = MemoryRecordDisclosurePolicy.classify(MemoryRecord(stored: candidate.0))
                if seen[key]?.contains(scope) ?? false { continue }
                seen[key, default: []].append(scope)
            }
            out.append((memory: candidate.0, similarity: candidate.1))
            if out.count >= cappedLimit { break }
        }
        return out
    }

    static func normalizedRecallContent(_ content: String) -> String {
        content
            .lowercased()
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
