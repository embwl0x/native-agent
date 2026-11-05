import Foundation
import GRDB
import NativeAgentShared
import NativeAgentCore
import PersistenceCore
// Blueprint: | `MemoryStorage+Recall.swift` | `MemoryStorage`, `invalidateRecallCache`, `rankedRecall`, `recall` |

extension MemoryStorage {
    struct RecallCandidate: Sendable {
        let memory: StoredMemory
        let lexicalDocument: MemoryRecallScoring.LexicalDocument
    }
    struct RecallCache: Sendable {
        let candidates: [RecallCandidate]
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

    /// Committed invalidation fences older reads; canonical generation detects other connections.
    func invalidateRecallCache() {
        recallRead.write { recallCache = nil }
    }

    /// Cache by canonical corpus generation, reading epoch and generation before candidates; a racing write may cause a miss but cannot relabel an old
    /// snapshot.
    func recallCandidates(
        queryEpoch: MemoryEmbeddingEpoch?
    ) async throws -> [RecallCandidate] {
        let snapshot = try await recallRead.read {
            let (activeEpoch, corpusGeneration) = try await dbPool.read { db in
                let epoch = try Self.embeddingEpochState(in: db).activeEpoch
                let version = try Self.recallJudgmentGeneration(in: db)
                return (epoch, version)
            }
            if let activeEpoch, queryEpoch?.rawValue != activeEpoch {
                throw MemoryStorageError.embeddingEpochMismatch(
                    expected: activeEpoch, actual: queryEpoch?.rawValue
                )
            }
            if let cache = recallCache,
               cache.corpusGeneration == corpusGeneration,
               cache.embeddingEpoch == activeEpoch {
                return cache
            }
            // One rowid-ordered query preserves equal-score tie-breaking, dedup preference, and BM25 document indices across query-planner choices.
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
                    return RecallCandidate(
                        memory: m,
                        lexicalDocument: MemoryRecallScoring.LexicalDocument(m.content)
                    )
                }
            }
            return RecallCache(
                candidates: candidates,
                corpusGeneration: corpusGeneration,
                embeddingEpoch: activeEpoch
            )
        } publish: { snapshot in
            // Bound resident decoded vectors; larger corpora are read per invocation.
            recallCache = snapshot.candidates.count <= 50_000 ? snapshot : nil
        }
        return snapshot.candidates
    }

    // MARK: - Recall (hybrid dense + lexical sweep)

    static func rankedRecall(
        embedding query: [Float],
        queryText: String?,
        persona: String?,
        candidates allCandidates: [RecallCandidate]
    ) throws -> [(memory: StoredMemory, similarity: Double)] {
        // Filtering preserves canonical row order and BM25 document alignment.
        let candidates = persona == nil
            ? allCandidates
            : allCandidates.filter { $0.memory.personaId == persona }
        // A directionless query cannot honestly answer semantic recall.
        guard VectorMath.cosine(query, query) > 0 else {
            throw MemoryStorageError.embeddingActivationInvalid(
                .unusableCandidate, "semantic recall query has no usable vector"
            )
        }
        let now = Date()
        let rawLexicalScores = MemoryRecallScoring.bm25Scores(
            queryTerms: MemoryRecallScoring.lexicalContentTerms(queryText),
            documents: candidates.map { ($0.lexicalDocument.termCounts, $0.lexicalDocument.length) }
        )
        let maxLexicalScore = rawLexicalScores.max() ?? 0
        let lexicalScores = rawLexicalScores.map { maxLexicalScore > 0 ? $0 / maxLexicalScore : 0 }
        var dense: [(index: Int, memory: StoredMemory, similarity: Double)] = []
        dense.reserveCapacity(candidates.count)
        for (idx, candidate) in candidates.enumerated() {
            let m = candidate.memory
            guard let e = m.embedding, e.count == query.count else { continue }
            guard VectorMath.cosine(e, e) > 0 else { continue }
            dense.append((index: idx, memory: m, similarity: VectorMath.cosine(e, query)))
        }
        let lexicalWeight = MemoryRecallScoring.lexicalBoostWeight(denseSimilarities: dense.map(\.similarity))
        var scored: [(StoredMemory, Double)] = []
        scored.reserveCapacity(dense.count)
        for (idx, m, sim) in dense {
            let lexicalBoost = (idx < lexicalScores.count)
                ? lexicalWeight * lexicalScores[idx]
                : 0
            // Recency only breaks near-ties; kinds without decay retain full relevance.
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
        // Run stateful deduplication once with early stop; lazy prefix can traverse twice and lose rows through `seen`.
        var out: [(memory: StoredMemory, similarity: Double)] = []
        for candidate in scored {
            let key = comparisonKey(candidate.0.content, mode: .recall)
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

}
