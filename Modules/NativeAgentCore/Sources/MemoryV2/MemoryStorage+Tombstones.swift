import Foundation
import GRDB
import NativeAgentCore
import PersistenceCore
// Blueprint: | `MemoryStorage+Tombstones.swift` | `MemoryStorage`: forgetting preserves existing vectors; owed vectors land on exact hash/content; semantic consumers name and exclude proven unembeddable claims, await unresolved vectors and retain exact-hash suppression; near-verbatim gate and `nearestTombstones` |

extension MemoryStorage {
    // MARK: - Tombstones

    /// Forgetting copies an existing record's vector without admitting new
    /// semantics. It must commit even when the model or epoch is unavailable;
    /// convergence owns any needed vector replacement.
    /// Preserve an existing embedding when the new write carries none.
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

    func tombstonesOwingVectors(limit: Int, epoch: MemoryEmbeddingEpoch) async throws -> [(hash: String, content: String)] {
        try await dbPool.read { db in
            try Row.fetchAll(db, sql: """
                SELECT content_hash, content FROM tombstones
                WHERE embedding IS NULL AND TRIM(COALESCE(content, '')) <> ''
                  AND NOT EXISTS (SELECT 1 FROM memory_embedding_failures f
                    WHERE f.kind = 'tombstone' AND f.row_id = tombstones.content_hash
                      AND f.content = CAST(tombstones.content AS BLOB) AND f.epoch = ?)
                ORDER BY rowid LIMIT ?
                """, arguments: [epoch.rawValue, max(1, limit)]).map { row -> (hash: String, content: String) in
                    (try row.decode(forColumn: "content_hash"), try row.decode(forColumn: "content"))
                }
        }
    }

    func landOwedTombstoneVector(hash: String, content: String, vector: [Float], epoch: MemoryEmbeddingEpoch) async throws -> Bool {
        try await dbPool.write { db in
            try Self.requireWritableEpoch(in: db, vector: vector, epoch: epoch.rawValue)
            try db.execute(sql: """
                UPDATE tombstones SET embedding = ?, embedding_epoch = ?
                WHERE content_hash = ? AND content = ? AND embedding IS NULL
                """, arguments: [Self.encodeEmbedding(vector), epoch.rawValue, hash, content])
            let landed = db.changesCount > 0
            if landed { try Self.clearEmbeddingFailure(in: db, kind: .tombstone, id: hash) }
            return landed
        }
    }

    /// Absence of a vector is not evidence that the claim was not forgotten.
    /// The canonical convergence flight fills it. A proven per-text failure
    /// is a named semantic gap, not a global admission failure; unresolved
    /// vectors still await convergence. Exact hash suppression always applies.
    static func requireTombstoneVectors(in db: Database) throws {
        for failed in try Row.fetchAll(db, sql: """
            SELECT f.row_id, f.reason FROM memory_embedding_failures f
            JOIN tombstones t ON f.row_id = t.content_hash AND f.content = CAST(t.content AS BLOB)
            JOIN memory_embedding_state s ON s.id = 1 AND s.active_epoch = f.epoch
            WHERE f.kind = 'tombstone' AND t.embedding IS NULL ORDER BY f.row_id
            """) {
            let id: String = try failed.decode(forColumn: "row_id")
            let reason: String = try failed.decode(forColumn: "reason")
            nativeLog("[memory-tombstone] semantic gap %@: %@; exact-hash suppression remains active", id, reason)
        }
        if try Bool.fetchOne(db, sql: """
            SELECT EXISTS(SELECT 1 FROM tombstones
                WHERE embedding IS NULL AND TRIM(COALESCE(content, '')) <> ''
                  AND NOT EXISTS (SELECT 1 FROM memory_embedding_failures f
                    JOIN memory_embedding_state s ON s.id = 1 AND s.active_epoch = f.epoch
                    WHERE f.kind = 'tombstone' AND f.row_id = tombstones.content_hash
                      AND f.content = CAST(tombstones.content AS BLOB)))
            """) == true {
            throw MemoryStorageError.searchFailure("Forgotten claims are awaiting their search vectors.",
                code: "memory_search_index_updating", instruction: "Allow memory search convergence to finish before comparing forgotten claims again.")
        }
    }

    static func requireNotTombstoned(_ memory: StoredMemory, in db: Database) throws {
        let exactMatch = try Int.fetchOne(
            db, sql: "SELECT COUNT(*) FROM tombstones WHERE content_hash = ?",
            arguments: [contentHash(memory.content)]
        ) ?? 0 > 0
        if exactMatch { throw MemoryStorageError.tombstoned(memory.id) }
        if let embedding = memory.embedding,
           try tombstoneMatch(
               db: db, content: memory.content, query: embedding, queryEpoch: memory.embeddingEpoch
           ) {
            throw MemoryStorageError.tombstoned(memory.id)
        }
    }

    /// Semantic admission blocks paraphrases at a high cosine threshold while admitting contradictions.
    /// Scan the tombstone set only on writes (store/accept).
    /// Unresolved vectors await convergence; proven unembeddable rows are named gaps.
    public func matchesTombstone(
        content: String,
        embedding query: [Float],
        embeddingEpoch queryEpoch: MemoryEmbeddingEpoch? = nil
    ) async throws -> Bool {
        try await dbPool.read { db in
            try Self.tombstoneMatch(
                db: db,
                content: content,
                query: query,
                queryEpoch: queryEpoch?.rawValue
            )
        }
    }

    /// The forgotten claims nearest `query`, closest first, in the active
    /// vector space: what the memory manager is shown beside the memories it
    /// may update, so "is this the same claim" is judged, not thresholded.
    public func nearestTombstones(
        embedding query: [Float],
        embeddingEpoch queryEpoch: MemoryEmbeddingEpoch?,
        limit: Int
    ) async throws -> [String] {
        guard !query.isEmpty, limit > 0 else { return [] }
        return try await dbPool.read { db in
            try Self.requireTombstoneVectors(in: db)
            let activeEpoch = try Self.embeddingEpochState(in: db).activeEpoch
            if let activeEpoch, queryEpoch?.rawValue != activeEpoch {
                throw MemoryStorageError.embeddingEpochMismatch(expected: activeEpoch, actual: queryEpoch?.rawValue)
            }
            var sql = "SELECT content, embedding FROM tombstones WHERE embedding IS NOT NULL"
            var arguments: StatementArguments = []
            if let activeEpoch {
                sql += " AND embedding_epoch = ?"
                arguments = [activeEpoch]
            }
            var scored: [(content: String, cosine: Double)] = []
            for row in try Row.fetchAll(db, sql: sql, arguments: arguments) {
                guard let e = try Self.decodeEmbedding(row.decode(forColumn: "embedding")), e.count == query.count else {
                    throw MemoryStorageError.databaseUnavailable("Rejection vector dimensions do not match the active memory model; repair the tombstone before semantic admission.")
                }
                guard let content: String = try row.decode(forColumn: "content") else { continue }
                scored.append((content: content, cosine: VectorMath.cosine(query, e)))
            }
            return scored.sorted { $0.cosine > $1.cosine }.prefix(limit).map(\.content)
        }
    }

    /// Shared matcher usable both standalone and INSIDE a write transaction
    /// (acceptProposal gates in the same txn — nesting pool calls would hang).
    static func tombstoneMatch(
        db: Database,
        content: String,
        query: [Float],
        queryEpoch: String?
    ) throws -> Bool {
        guard !query.isEmpty else { return false }
        try requireTombstoneVectors(in: db)
        let activeEpoch = try embeddingEpochState(in: db).activeEpoch
        if let activeEpoch, queryEpoch != activeEpoch {
            throw MemoryStorageError.embeddingEpochMismatch(expected: activeEpoch, actual: queryEpoch)
        }
        var sql = "SELECT content, embedding FROM tombstones WHERE embedding IS NOT NULL"
        var arguments: StatementArguments = []
        if let activeEpoch {
            sql += " AND embedding_epoch = ?"
            arguments = [activeEpoch]
        }
        let rows = try Row.fetchAll(db, sql: sql, arguments: arguments)
        for row in rows {
            guard let e = try decodeEmbedding(row.decode(forColumn: "embedding")), e.count == query.count else {
                throw MemoryStorageError.databaseUnavailable("Rejection vector dimensions do not match the active memory model; repair the tombstone before semantic admission.")
            }
            let forgotten: String = try row.decode(forColumn: "content")
            if semanticDuplicate(content, forgotten, similarity: VectorMath.cosine(query, e)) { return true }
        }
        return false
    }

}
