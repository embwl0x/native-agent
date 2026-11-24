import Foundation
import NativeAgentShared
import GRDB
import HashTreeCollections
import NativeAgentCore
import PersistenceCore
// Blueprint: | `MemoryStorage+Tombstones.swift` | `MemoryStorage`: exact/semantic suppression and owed vectors |

extension MemoryStorage {
    // MARK: - Tombstones

    /// Forgetting copies an existing record's vector without admitting new semantics. It must commit even when the model or epoch is unavailable; convergence
    /// owns any needed vector replacement. Preserve an existing embedding when the new write carries none.
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
            hash, content, NativeTimestampFormat.fractionalZulu(Date()), reason,
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

    /// Absence of a vector is not evidence that the claim was not forgotten. The canonical convergence flight fills it. A proven per-text failure is a named
    /// semantic gap, not a global admission failure; unresolved vectors still await convergence. Exact hash suppression always applies.
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

    static func requireNotTombstoned(_ memory: StoredMemory, in db: Database, cached: TombstoneIndex?) throws {
        let exactMatch = try Int.fetchOne(
            db, sql: "SELECT COUNT(*) FROM tombstones WHERE content_hash = ?",
            arguments: [contentHash(memory.content)]
        ) ?? 0 > 0
        if exactMatch { throw MemoryStorageError.tombstoned(memory.id) }
        if let embedding = memory.embedding,
           try tombstoneMatch(
               db: db, content: memory.content, query: embedding, cached: cached, queryEpoch: memory.embeddingEpoch
           ) {
            throw MemoryStorageError.tombstoned(memory.id)
        }
    }

    /// Unresolved vectors await convergence; proven unembeddable rows are named gaps.
    public func matchesTombstone(
        content: String,
        embedding query: [Float],
        embeddingEpoch queryEpoch: MemoryEmbeddingEpoch? = nil
    ) async throws -> Bool {
        let cached = try await readTombstoneIndex()
        return try await dbPool.read { db in
            try Self.tombstoneMatch(
                db: db,
                content: content,
                query: query,
                cached: cached, queryEpoch: queryEpoch?.rawValue
            )
        }
    }

    /// Shared matcher usable both standalone and INSIDE a write transaction (acceptProposal gates in the same txn — nesting pool calls would hang).
    static func tombstoneMatch(
        db: Database,
        content: String,
        query: [Float],
        cached: TombstoneIndex?,
        queryEpoch: String?
    ) throws -> Bool {
        guard !query.isEmpty else { return false }
        try requireTombstoneVectors(in: db)
        let activeEpoch = try embeddingEpochState(in: db).activeEpoch
        if let activeEpoch, queryEpoch != activeEpoch {
            throw MemoryStorageError.embeddingEpochMismatch(expected: activeEpoch, actual: queryEpoch)
        }
        let index = try loadTombstoneIndex(in: db, epoch: activeEpoch, cached: cached)
        let matrix = index.matrices[query.count]
        let scores = VectorReading(query).flatMap { reading in matrix?.score([reading]).cosines.first }
        for (i, entry) in index.entries.enumerated() {
            guard entry.width == query.count else {
                throw MemoryStorageError.databaseUnavailable("""
                    Rejection vector dimensions do not match the active memory model; repair the tombstone before semantic admission.
                    """)
            }
            if let row = matrix?.index[i], let scores, scores[row] >= memoryNearVerbatimSimilarity,
               semanticDuplicate(content, entry.content, similarity: scores[row]) { return true }
        }
        if let failure = index.failure { throw failure }
        return false
    }

    struct TombstoneIndex: Sendable {
        let generation: Int64
        let epoch: String?
        let entries: [(content: String, width: Int)]
        let matrices: [Int: VectorMatrix<Int>]
        let failure: (any Error)?
    }

    func readTombstoneIndex() async throws -> TombstoneIndex {
        let cached = tombstoneIndex
        return try await tombstoneRead.read {
            try await dbPool.read { db in
                try Self.loadTombstoneIndex(in: db, epoch: Self.embeddingEpochState(in: db).activeEpoch, cached: cached)
            }
        } publish: { tombstoneIndex = $0 }
    }

    private static func loadTombstoneIndex(in db: Database, epoch: String?, cached: TombstoneIndex?) throws -> TombstoneIndex {
        guard let generation = try Int64.fetchOne(db, sql: "SELECT value FROM memory_metadata WHERE key = 'tombstone_generation'") else {
            throw MemoryStorageError.databaseUnavailable("Tombstone generation is missing.")
        }
        if let cached, cached.generation == generation, cached.epoch == epoch { return cached }
        var sql = "SELECT content, embedding FROM tombstones WHERE embedding IS NOT NULL"
        var arguments: StatementArguments = []
        if let epoch {
            sql += " AND embedding_epoch = ?"
            arguments = [epoch]
        }
        var entries: [(content: String, width: Int)] = []
        var vectors: [(Int, VectorReading)] = []
        var failure: (any Error)?
        let cursor = try Row.fetchCursor(db, sql: sql, arguments: arguments)
        while let row = try cursor.next() {
            do {
                guard let values = try decodeEmbedding(row.decode(forColumn: "embedding")) else {
                    throw MemoryStorageError.databaseUnavailable("Missing rejection vector.")
                }
                let content: String = try row.decode(forColumn: "content")
                if let reading = VectorReading(values) { vectors.append((entries.count, reading)) }
                entries.append((content, values.count))
            } catch {
                failure = error
                break
            }
        }
        return TombstoneIndex(generation: generation, epoch: epoch, entries: entries,
                              matrices: VectorMatrix.grouped(vectors, centering: false), failure: failure)
    }
}
