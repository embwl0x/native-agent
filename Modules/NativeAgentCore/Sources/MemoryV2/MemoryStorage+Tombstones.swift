import Foundation
import GRDB
import NativeAgentCore
import PersistenceCore

extension MemoryStorage {
    // MARK: - Tombstones

    public func addTombstone(
        content: String,
        reason: String?,
        embedding: [Float]? = nil,
        embeddingEpoch: String? = nil
    ) async throws {
        try await dbPool.write { db in
            try Self.requireWritableEpoch(in: db, vector: embedding, epoch: embeddingEpoch)
            try Self.upsertTombstone(
                db: db,
                content: content,
                reason: reason,
                embedding: embedding,
                embeddingEpoch: embeddingEpoch
            )
        }
    }

    /// THE single tombstone writer (gpt-5.5 wave1 finding 3: every path must
    /// COALESCE-preserve an existing embedding when the new write carries none —
    /// a plain REPLACE from a nil-embedding caller would wipe the semantic key).
    public func removeTombstone(content: String) async throws {
        let hash = Self.contentHash(content)
        try await dbPool.write { db in
            try db.execute(sql: "DELETE FROM tombstones WHERE content_hash = ?", arguments: [hash])
        }
    }

    static func upsertTombstone(
        db: Database,
        content: String,
        reason: String?,
        embedding: [Float]?,
        embeddingEpoch: String?
    ) throws {
        let hash = contentHash(content)
        try db.execute(sql: """
            INSERT OR REPLACE INTO tombstones
              (content_hash, content, rejected_at, reason, embedding, embedding_epoch)
            VALUES (
              ?, ?, ?, ?,
              COALESCE(?, (SELECT embedding FROM tombstones WHERE content_hash = ?)),
              COALESCE(?, (SELECT embedding_epoch FROM tombstones WHERE content_hash = ?))
            )
        """, arguments: [
            hash, content, nowISO8601(), reason,
            encodeEmbedding(embedding), hash,
            embeddingEpoch, hash,
        ])
    }

    public func isTombstoned(content: String) async throws -> Bool {
        let hash = Self.contentHash(content)
        return try await dbPool.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM tombstones WHERE content_hash = ?", arguments: [hash]) ?? 0 > 0
        }
    }

    /// Semantic tombstone gate (wave1 T3): does this candidate embedding match
    /// any tombstoned claim at/above the threshold? Agent's canon: a deletion is
    /// the CLAIM — only true paraphrases block; contradictions score below the
    /// (high) threshold and are admitted as new information. O(N) over the
    /// tombstone set, which is small and write-path-only (store/accept time).
    /// Legacy tombstones with NULL embeddings are skipped (hash gate covers them).
    public func matchesTombstone(
        embedding query: [Float],
        embeddingEpoch queryEpoch: MemoryEmbeddingEpoch? = nil,
        threshold: Double = memoryTombstoneMatchThreshold
    ) async throws -> Bool {
        try await dbPool.read { db in
            try Self.tombstoneMatch(
                db: db,
                query: query,
                queryEpoch: queryEpoch?.rawValue,
                threshold: threshold
            )
        }
    }

    /// Shared matcher usable both standalone and INSIDE a write transaction
    /// (acceptProposal gates in the same txn — nesting pool calls would hang).
    static func tombstoneMatch(
        db: Database,
        query: [Float],
        queryEpoch: String?,
        threshold: Double
    ) throws -> Bool {
        guard !query.isEmpty else { return false }
        let activeEpoch = try embeddingEpochState(in: db).activeEpoch
        if let activeEpoch, queryEpoch != activeEpoch {
            throw MemoryStorageError.embeddingEpochMismatch(expected: activeEpoch, actual: queryEpoch)
        }
        let qn = l2norm(query)
        guard qn > 0 else { return false }
        var sql = "SELECT embedding FROM tombstones WHERE embedding IS NOT NULL"
        var arguments: StatementArguments = []
        if let activeEpoch {
            sql += " AND embedding_epoch = ?"
            arguments = [activeEpoch]
        }
        let rows = try Row.fetchAll(db, sql: sql, arguments: arguments)
        for row in rows {
            guard let e = decodeEmbedding(row["embedding"]), e.count == query.count else { continue }
            let en = l2norm(e)
            guard en > 0 else { continue }
            var dot: Float = 0
            for i in 0..<e.count { dot += e[i] * query[i] }
            if Double(dot) / (Double(qn) * Double(en)) >= threshold { return true }
        }
        return false
    }

    /// Fill in the semantic key on tombstones that never got one.
    ///
    /// The ordinary delete/reject path calls `addTombstone(content:reason:)`
    /// and lets `embedding` default to nil (both MemoryV2 facades do), while
    /// `tombstoneMatch` selects `WHERE embedding IS NOT NULL`. Every tombstone
    /// written that way is invisible to the semantic forget-gate and blocks
    /// only its own exact content hash — the gate covers a minority of the set.
    ///
    /// This re-embeds them in bounded batches with the SAME embedder the live
    /// write path uses. `content`, `rejected_at` and `reason` are never
    /// rewritten, and an embedding that already exists is never overwritten:
    /// `embedding IS NULL` is re-checked in the UPDATE, so a concurrent real
    /// tombstone write always wins. The 0.92 match threshold is untouched —
    /// this widens what the gate can SEE, not what counts as a match.
    ///
    /// Bounded per call so a large legacy backlog drains over several passes
    /// rather than stalling one. Returns the number of rows filled.
    @discardableResult
    public func backfillTombstoneEmbeddings(
        using embedder: any EmbeddingProvider,
        limit: Int = 64
    ) async throws -> Int {
        let cap = max(0, limit)
        guard cap > 0 else { return 0 }
        let pending = try await dbPool.read { db -> [(hash: String, content: String)] in
            try Row.fetchAll(db, sql: """
                SELECT content_hash, content FROM tombstones
                WHERE embedding IS NULL AND content IS NOT NULL AND content <> ''
                ORDER BY rejected_at DESC
                LIMIT ?
            """, arguments: [cap]).compactMap { row in
                guard let hash: String = row["content_hash"],
                      let content: String = row["content"] else { return nil }
                return (hash, content)
            }
        }
        guard !pending.isEmpty else { return 0 }

        let batch = try await embedder.embedWithEpoch(pending.map(\.content))
        guard batch.vectors.count == pending.count else {
            throw MemoryStorageError.databaseUnavailable(
                "tombstone backfill: embedder returned \(batch.vectors.count) "
                    + "vectors for \(pending.count) rows"
            )
        }
        let epoch = batch.epoch.rawValue

        return try await dbPool.write { db -> Int in
            // Same epoch guard every other embedding write goes through: a
            // vector from the wrong vector space must never land in the store.
            try Self.requireWritableEpoch(in: db, vector: batch.vectors.first, epoch: epoch)
            var written = 0
            for (row, vector) in zip(pending, batch.vectors) {
                guard !vector.isEmpty else { continue }
                try db.execute(sql: """
                    UPDATE tombstones SET embedding = ?, embedding_epoch = ?
                    WHERE content_hash = ? AND embedding IS NULL
                """, arguments: [Self.encodeEmbedding(vector), epoch, row.hash])
                written += db.changesCount
            }
            return written
        }
    }
}
