import Foundation
import GRDB
import NativeAgentCore
import PersistenceCore

extension MemoryStorage {
    struct RecallCandidate {
        let memory: StoredMemory
        let norm: Float            // precomputed Self.l2norm(embedding) — bit-identical to per-turn recompute
    }
    struct RecallCache {
        let candidates: [RecallCandidate]
        let generation: Int
        let dataVersion: Int64
        let embeddingEpoch: String?
    }
    // MARK: - Recall candidate cache

    /// Bump the in-actor cache generation and drop the cached candidates. Called
    /// after every successful in-actor write that changes the `memories` table.
    /// recallCandidates() also checks data_version for writes by other connections.
    func invalidateRecallCache() {
        recallGeneration += 1
        recallCache = nil
    }

    /// The decoded, norm-precomputed active-embedded candidate set for ALL
    /// personas, rebuilt from SQL only when the table changed. Persona /
    /// `excluding` filtering is applied per-call by the callers, so recall and
    /// nearestActiveNeighbor share ONE cache (persona/excluding are the only
    /// per-call SQL variations and both are pure row filters that preserve the
    /// underlying rowid scan order — behaviour stays identical to the old
    /// per-call scan). Norms are precomputed with the EXISTING scalar l2norm so
    /// cached norms are bit-identical to the old per-turn recompute.
    /// `epochMismatch` is the caller's cue that the dense lane cannot answer
    /// at all: the query vector lives in a different space from the canonical
    /// corpus. An empty candidate list alone was indistinguishable from an
    /// empty store, so `recall` returned silence for the rest of a process
    /// whose launch re-embedding had failed (2026-09-06).
    private func recallCandidates(
        queryEpoch: MemoryEmbeddingEpoch?
    ) async throws -> (candidates: [RecallCandidate], epochMismatch: Bool) {
        let activeEpoch = try await dbPool.read { db in
            try Self.embeddingEpochState(in: db).activeEpoch
        }
        if let activeEpoch, queryEpoch?.rawValue != activeEpoch {
            return ([], true)
        }
        // Read data_version BEFORE fetching candidates: this guarantees the
        // recorded version is never NEWER than the candidate snapshot, so a
        // write racing between the two reads (actor reentrancy) can only cause a
        // harmless extra rebuild next time — never a stale-serving false match.
        let liveDataVersion = try await versionProbe.read { db in
            try Int64.fetchOne(db, sql: "PRAGMA data_version") ?? 0
        }
        if let cache = recallCache,
           cache.generation == recallGeneration,
           cache.dataVersion == liveDataVersion,
           cache.embeddingEpoch == activeEpoch {
            return (cache.candidates, false)
        }
        // One rowid-ordered query preserves equal-score tie-breaking, dedup
        // preference, and BM25 document indices across query-planner choices.
        let candidates = try await dbPool.read { db -> [RecallCandidate] in
            var sql = """
                SELECT * FROM memories
                WHERE embedding IS NOT NULL
                  AND status = 'active'
                  AND lifecycle NOT IN ('corrected', 'contradicted', 'deleted')
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
                return RecallCandidate(memory: m, norm: norm)
            }
        }
        // Growth guard: the cache holds the fully-decoded candidate set
        // (embeddings included). At Agent-scale (10³–10⁴ rows ≈ tens of MB)
        // that's the point of R5; past it, skip caching rather than balloon
        // resident memory — recall stays correct via the per-call scan path.
        if candidates.count <= 50_000 {
            recallCache = RecallCache(
                candidates: candidates,
                generation: recallGeneration,
                dataVersion: liveDataVersion,
                embeddingEpoch: activeEpoch
            )
        } else {
            recallCache = nil
        }
        recallCacheRebuildCount += 1
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
        try await recallReportingKeywordFallback(
            embedding: query,
            embeddingEpoch: queryEpoch,
            queryText: queryText,
            topK: topK,
            persona: persona
        ).hits
    }

    /// The same recall, plus whether the dense lane was unusable and the answer
    /// actually came from the keyword lane.
    ///
    /// 2026-09-06: the degrade-to-lexical decision is made here, below the layer
    /// that owns provenance, so `MemoryV2.recall` had no way to know it happened
    /// — keyword hits went out labelled `swift-native`, `search_kg` called them
    /// meaning matches, and the dense-lane starvation diagnostic could fire on a
    /// lane that never ran. The caller reads the flag and labels honestly.
    public func recallReportingKeywordFallback(
        embedding query: [Float],
        embeddingEpoch queryEpoch: MemoryEmbeddingEpoch? = nil,
        queryText: String? = nil,
        topK: Int,
        persona: String? = nil
    ) async throws -> (hits: [(memory: StoredMemory, similarity: Double)], usedKeywordFallback: Bool) {
        // R5: pull the shared cached candidate set, then apply the persona
        // filter in-memory. A single-persona equality filter over the full
        // rowid-ordered scan yields the same rows in the same order the old
        // persona-clause SQL returned, so BM25 idx alignment + ranking stay
        // byte-identical.
        let scan = try await recallCandidates(queryEpoch: queryEpoch)
        // 2026-09-06: the query vector is in a different space from the
        // canonical corpus (a failed launch re-embedding leaves the provider on
        // the new model and the store on the old epoch). The dense lane has
        // nothing to say; the lexical lane still answers exact text, so degrade
        // to it instead of returning silence until the next relaunch.
        guard !scan.epochMismatch else {
            return (try await recallByKeyword(
                queryText: queryText, topK: topK, persona: persona
            ), true)
        }
        let allCandidates = scan.candidates
        let candidates = persona == nil
            ? allCandidates
            : allCandidates.filter { $0.memory.personaId == persona }
        let queryNorm = Self.l2norm(query)
        // Sweep R4 A5: a COLD embedder (MiniLM not yet warm on the Neural
        // Engine — reliably the state on the first message after launch) hands
        // us a zero/empty vector, and this used to return [] — total recall
        // silence with nothing but a trace flag to show for it. Degrade to the
        // lexical lane instead: a keyword ranking is worse than semantic, and
        // enormously better than nothing.
        guard queryNorm > 0 else {
            return (try await recallByKeyword(
                queryText: queryText, topK: topK, persona: persona
            ), true)
        }
        let now = Date()
        let lexicalScores = MemoryRecallScoring.normalizedBM25Scores(
            query: queryText,
            documents: candidates.map(\.memory.content)
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
                    * MemoryRecallScoring.useCountFactor(m.useCount)
            ))
        }
        scored.sort { $0.1 > $1.1 }
        return (Self.uniqueRecallResults(scored, limit: topK), false)
    }

    // MARK: - Keyword recall fallback (sweep R4, finding A5)

    /// Lexical-only recall for when NO usable query embedding exists (cold
    /// embedder, embedder failure, epoch mismatch). Selection is a
    /// case-insensitive LIKE over active rows for any query token; ranking is
    /// the SAME normalized BM25 the hybrid lane already blends in, times the
    /// same lifecycle factor. Crucially this does NOT require `embedding IS NOT
    /// NULL`, so it also answers on a store whose vectors have not been
    /// backfilled yet.
    ///
    /// Callers mark these rows as fallback-sourced (see `MemoryV2.recall`) so
    /// the trace never presents keyword hits as semantic ones.
    public func recallByKeyword(
        queryText: String?,
        topK: Int,
        persona: String? = nil
    ) async throws -> [(memory: StoredMemory, similarity: Double)] {
        guard topK > 0 else { return [] }
        // 2026-09-06: the LIKE prefilter takes the same stopword-filtered terms
        // the BM25 scorer below uses. It used to select on every token, so on a
        // busy store the 400-row cap filled with rows that merely contained
        // "what"/"does"/"me" and the rows carrying the content terms never
        // reached the ranker. An all-stopword query gets no keyword signal.
        let tokens = MemoryRecallScoring.lexicalContentTerms(queryText)
        guard !tokens.isEmpty else { return [] }
        // Rank across the bounded canonical corpus: an earlier matching row
        // must not exclude a newer answer before BM25 gets to score it.
        let candidateCap = memoryStoredRowCap
        let candidates = try await dbPool.read { db -> [StoredMemory] in
            var sql = """
                SELECT * FROM memories
                WHERE status = 'active'
                  AND lifecycle NOT IN ('corrected', 'contradicted', 'deleted')
            """
            var arguments: [DatabaseValueConvertible] = []
            if let persona {
                sql += " AND persona_id = ?"
                arguments.append(persona)
            }
            // SQLite LIKE folds only ASCII case, while lexicalTokens and
            // BM25 use Swift Unicode lowercasing. GRDB installs this exact
            // String.lowercased() function on every database connection.
            // Match the scorer before the existing bounded candidate cutoff.
            let likeClauses = tokens.map { _ in "swiftLowercaseString(content) LIKE ? ESCAPE '\\'" }
            sql += " AND (" + likeClauses.joined(separator: " OR ") + ")"
            for token in tokens {
                arguments.append("%" + Self.escapedLikePattern(token) + "%")
            }
            sql += " ORDER BY rowid LIMIT ?"
            arguments.append(candidateCap)
            let rows = try Row.fetchAll(
                db, sql: sql, arguments: StatementArguments(arguments)
            )
            return try rows.map(Self.decodeMemory)
        }
        guard !candidates.isEmpty else { return [] }
        let lexicalScores = MemoryRecallScoring.normalizedBM25Scores(
            query: queryText,
            documents: candidates.map(\.content)
        )
        let now = Date()
        var scored: [(StoredMemory, Double)] = []
        scored.reserveCapacity(candidates.count)
        for (idx, memory) in candidates.enumerated() {
            let lexical = idx < lexicalScores.count ? lexicalScores[idx] : 0
            guard lexical > 0 else { continue }
            let decay = MemoryRecallScoring.recallRecencyFactor(
                kind: MemoryRecallScoring.kind(of: memory.metadata),
                updatedAt: memory.updatedAt,
                now: now
            )
            scored.append((
                memory,
                lexical
                    * decay
                    * MemoryLifecycle.rankingFactor(memory.lifecycle)
                    * MemoryRecallScoring.useCountFactor(memory.useCount)
            ))
        }
        scored.sort { $0.1 > $1.1 }
        return Self.uniqueRecallResults(scored, limit: topK)
    }

    /// Escape LIKE wildcards in a user-derived token so a query containing `%`
    /// or `_` cannot widen the prefilter into a full scan-and-match.
    private static func escapedLikePattern(_ token: String) -> String {
        token
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_")
    }

    /// U3 wave-2 item 4: top-1 nearest ACTIVE neighbor by RAW cosine — the
    /// same candidate scan as recall but WITHOUT the kind-scoped decay
    /// shaping, so the shadow dedup ledger records true geometry. (recall's
    /// score is sim * decayFactor; once kinds start carrying half-lives that
    /// product would silently contaminate the threshold-validation data.)
    /// WRITE-path helper only — the recall read path is untouched.
    /// `excluding` skips one row id at the SQL layer: the shadow observation
    /// runs detached AFTER the insert (fix-round finding 2), so the scan
    /// must not pair the just-inserted row with itself.
    public func nearestActiveNeighbor(
        embedding query: [Float],
        embeddingEpoch queryEpoch: MemoryEmbeddingEpoch? = nil,
        excluding excludedId: String? = nil
    ) async throws -> (memory: StoredMemory, cosine: Double)? {
        // R5: shared cached candidate set, `excluding` applied in-memory. The
        // full rowid-ordered scan minus one id is the same order the old
        // `id != ?` SQL returned, so the strict-`>` first-seen-wins tie-break on
        // raw cosine is preserved.
        let allCandidates = try await recallCandidates(queryEpoch: queryEpoch).candidates
        let candidates = excludedId == nil
            ? allCandidates
            : allCandidates.filter { $0.memory.id != excludedId }
        let queryNorm = Self.l2norm(query)
        guard queryNorm > 0 else { return nil }
        var best: (StoredMemory, Double)? = nil
        for candidate in candidates {
            let m = candidate.memory
            guard let e = m.embedding, e.count == query.count else { continue }
            let n = candidate.norm
            guard n > 0 else { continue }
            var dot: Float = 0
            for i in 0..<e.count { dot += e[i] * query[i] }
            let cosine = Double(dot) / (Double(queryNorm) * Double(n))
            if best == nil || cosine > best!.1 { best = (m, cosine) }
        }
        return best.map { (memory: $0.0, cosine: $0.1) }
    }

    private static func uniqueRecallResults(
        _ scored: [(StoredMemory, Double)],
        limit: Int
    ) -> [(memory: StoredMemory, similarity: Double)] {
        let cappedLimit = max(0, limit)
        guard cappedLimit > 0 else { return [] }
        var seen: Set<String> = []
        // Lazy uniqueness retains the prior early stop: do not normalize an
        // entire corpus when the bounded result has already been filled.
        let unique = scored.lazy.filter { candidate in
            let key = normalizedRecallContent(candidate.0.content)
            if !key.isEmpty {
                return seen.insert(key).inserted
            }
            return true
        }
        return MemoryRecallScoring.selectRecallResults(from: unique, limit: cappedLimit) {
            MemoryRecallScoring.isSkillRecallHint(
                id: $0.0.id, kind: MemoryRecallScoring.kind(of: $0.0.metadata)
            )
        }
    }

    private static func normalizedRecallContent(_ content: String) -> String {
        content
            .lowercased()
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
