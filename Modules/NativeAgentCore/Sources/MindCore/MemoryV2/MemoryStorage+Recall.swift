import Foundation
import GRDB
import HashTreeCollections
import NativeAgentShared
import NativeAgentCore
import PersistenceCore
// Blueprint: | `MemoryStorage+Recall.swift` | `MemoryStorage`, `invalidateRecallCache`, `rankedRecall`, `recall` |

extension MemoryStorage {
    struct RecallCache: Sendable {
        let candidates: [StoredMemory]
        let lexical: MemoryRecallScoring.LexicalIndex
        let matrices: [Int: VectorMatrix<Int>]
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

    /// Cache by active epoch and canonical corpus generation. A miss reads the epoch, generation and candidates in one snapshot; the query is checked
    /// against the epoch of the candidates it is given.
    func recallCandidates(
        queryEpoch: MemoryEmbeddingEpoch?
    ) async throws -> RecallCache {
        let snapshot = try await recallRead.read {
            let (activeEpoch, corpusGeneration) = try await dbPool.read { db in
                let epoch = try Self.embeddingEpochState(in: db).activeEpoch
                let version = try Self.recallJudgmentGeneration(in: db)
                return (epoch, version)
            }
            let found = if let cache = recallCache,
               cache.corpusGeneration == corpusGeneration,
               cache.embeddingEpoch == activeEpoch {
                cache
            } else {
                // One rowid-ordered query preserves equal-score tie-breaking, dedup preference, and BM25 document indices across query-planner choices.
                try await dbPool.read { db -> RecallCache in
                    let activeEpoch = try Self.embeddingEpochState(in: db).activeEpoch
                    let corpusGeneration = try Self.recallJudgmentGeneration(in: db)
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
                    let candidates = try rows.map(Self.decodeMemory)
                    let documents = candidates.map { MemoryRecallScoring.LexicalDocument($0.content) }
                    let vectors = candidates.enumerated().compactMap { index, candidate -> (Int, VectorReading)? in
                        guard let values = candidate.embedding, let vector = VectorReading(values) else { return nil }
                        return (index, vector)
                    }
                    return RecallCache(
                        candidates: candidates,
                        lexical: MemoryRecallScoring.LexicalIndex(documents.map { ($0.termCounts, $0.length) }),
                        matrices: VectorMatrix.grouped(vectors, centering: false),
                        corpusGeneration: corpusGeneration,
                        embeddingEpoch: activeEpoch
                    )
                }
            }
            if let epoch = found.embeddingEpoch, queryEpoch?.rawValue != epoch {
                throw MemoryStorageError.embeddingEpochMismatch(expected: epoch, actual: queryEpoch?.rawValue)
            }
            return found
        } publish: { snapshot in
            // Bound resident decoded vectors; larger corpora are read per invocation.
            recallCache = snapshot.candidates.count <= 50_000 ? snapshot : nil
        }
        return snapshot
    }

    // MARK: - Recall (hybrid dense + lexical sweep)

    static func rankedRecall(
        readings: [(embedding: [Float], text: String?)],
        persona: String?,
        cache: RecallCache
    ) throws -> [[(memory: StoredMemory, similarity: Double)]] {
        let vectors = try readings.map { reading in
            guard let vector = VectorReading(reading.embedding) else {
                throw MemoryStorageError.embeddingActivationInvalid(
                    .unusableCandidate, "semantic recall query has no usable vector"
                )
            }
            return vector
        }
        let candidates = cache.candidates.enumerated().filter { persona == nil || $0.element.personaId == persona }
        let now = Date()
        let lexicalRows = persona.map { _ in Set(candidates.map(\.offset)) }
        let groups = Dictionary(grouping: vectors.indices, by: { vectors[$0].width })
        var rankings = readings.map { _ in [(memory: StoredMemory, similarity: Double)]() }
        for (width, indices) in groups {
            guard let matrix = cache.matrices[width] else { continue }
            let batch = matrix.score(indices.map { vectors[$0] })
            for (column, index) in indices.enumerated() {
                try Task.checkCancellation()
                let lexical = cache.lexical.scores(
                    queryTerms: MemoryRecallScoring.lexicalContentTerms(readings[index].text), rows: lexicalRows)
                let dense = candidates.compactMap { entry -> (Int, StoredMemory, Double)? in
                    guard let row = matrix.index[entry.offset] else { return nil }
                    return (entry.offset, entry.element, batch.cosines[column][row])
                }
                rankings[index] = rank(dense, lexical: lexical, now: now)
            }
        }
        return rankings
    }

    private static func rank(_ dense: [(Int, StoredMemory, Double)], lexical rawLexicalScores: [Double], now: Date)
        -> [(memory: StoredMemory, similarity: Double)] {
        let maxLexicalScore = rawLexicalScores.max() ?? 0
        let lexicalScores = rawLexicalScores.map { maxLexicalScore > 0 ? $0 / maxLexicalScore : 0 }
        let lexicalWeight = MemoryRecallScoring.lexicalBoostWeight(denseSimilarities: dense.map { $0.2 })
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
