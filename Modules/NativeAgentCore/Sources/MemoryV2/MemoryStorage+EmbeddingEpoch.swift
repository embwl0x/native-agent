import Foundation
import GRDB
import NativeAgentCore
import PersistenceCore

extension MemoryStorage {
    /// Derived action vectors share memory's database and vector codec, never
    /// its canonical corpus or recall generation.
    public func actionEmbeddings(epoch: MemoryEmbeddingEpoch) async throws -> [String: [Float]] {
        try await dbPool.read { db in
            var vectors: [String: [Float]] = [:]
            for row in try Row.fetchAll(db, sql: "SELECT text_hash, vector FROM action_embeddings WHERE epoch = ?",
                                       arguments: [epoch.rawValue]) {
                guard let vector = Self.decodeEmbedding(row["vector"]), !vector.isEmpty,
                      vector.allSatisfy(\.isFinite), vector.contains(where: { $0 != 0 }) else {
                    // Derived damage is a miss: the index writer replaces it
                    // from the exact action text, never using a bad vector.
                    continue
                }
                vectors[row["text_hash"]] = vector
            }
            return vectors
        }
    }

    public func writeActionEmbeddings(_ vectors: [String: [Float]], epoch: MemoryEmbeddingEpoch,
                                      retaining hashes: Set<String>? = nil) async throws {
        try await dbPool.write { db in
            for (hash, vector) in vectors {
                try db.execute(sql: "INSERT OR REPLACE INTO action_embeddings (epoch, text_hash, vector) VALUES (?, ?, ?)",
                               arguments: [epoch.rawValue, hash, Self.encodeEmbedding(vector)])
            }
            if let hashes {
                for row in try Row.fetchAll(db, sql: "SELECT epoch, text_hash FROM action_embeddings") {
                    let storedEpoch: String = row["epoch"], hash: String = row["text_hash"]
                    if storedEpoch != epoch.rawValue || !hashes.contains(hash) {
                        try db.execute(sql: "DELETE FROM action_embeddings WHERE epoch = ? AND text_hash = ?",
                                       arguments: [storedEpoch, hash])
                    }
                }
            }
        }
    }

    // MARK: - Embedding epoch activation

    /// Snapshot every canonical text-bearing row. Callers embed this immutable
    /// candidate off the turn path, then pass it back to
    /// `activateEmbeddingEpoch`; activation rejects any intervening drift.
    public func embeddingCorpusSnapshot() async throws -> [MemoryEmbeddingCorpusRow] {
        try await dbPool.read { db in try Self.embeddingCorpus(in: db) }
    }

    public func embeddingEpochState() async throws -> MemoryEmbeddingEpochState {
        try await dbPool.read { db in try Self.embeddingEpochState(in: db) }
    }

    /// Switch all memories, proposals, and tombstones to one vector space in a
    /// single SQLite transaction. Legacy vectors are never stamped in place:
    /// every row is freshly embedded, identity-checked, and content-hash
    /// checked before the canonical switch.
    public func activateEmbeddingEpoch(
        _ epoch: MemoryEmbeddingEpoch,
        staged: [MemoryEmbeddingStagedRow]
    ) async throws -> MemoryEmbeddingEpochActivationReport {
        let activatedAt = Self.nowISO8601()
        let report = try await dbPool.write { db -> MemoryEmbeddingEpochActivationReport in
            let live = try Self.embeddingCorpus(in: db)
            let liveByKey = Dictionary(uniqueKeysWithValues: live.map { (Self.corpusKey($0.kind, $0.id), $0) })
            var stagedByKey: [String: MemoryEmbeddingStagedRow] = [:]
            var dimensions: Int?
            for item in staged {
                let key = Self.corpusKey(item.row.kind, item.row.id)
                guard stagedByKey[key] == nil else {
                    throw MemoryStorageError.embeddingActivationInvalid(.unusableCandidate, "duplicate staged row \(key)")
                }
                guard let current = liveByKey[key], current.contentHash == item.row.contentHash else {
                    throw MemoryStorageError.embeddingActivationInvalid(.corpusDrift, "canonical content drifted for \(key)")
                }
                guard !item.vector.isEmpty else {
                    throw MemoryStorageError.embeddingActivationInvalid(.unusableCandidate, "empty vector for \(key)")
                }
                if let dimensions, dimensions != item.vector.count {
                    throw MemoryStorageError.embeddingActivationInvalid(.unusableCandidate, "mixed vector dimensions")
                }
                dimensions = item.vector.count
                stagedByKey[key] = item
            }
            guard stagedByKey.count == liveByKey.count else {
                let missing = Set(liveByKey.keys).subtracting(stagedByKey.keys).sorted().prefix(3)
                throw MemoryStorageError.embeddingActivationInvalid(
                    .corpusDrift,
                    "candidate covers \(stagedByKey.count)/\(liveByKey.count) rows; missing \(missing.joined(separator: ", "))"
                )
            }

            let prior = try Self.embeddingEpochState(in: db)
            for item in staged {
                try Self.updateEmbedding(
                    in: db,
                    kind: item.row.kind,
                    id: item.row.id,
                    embedding: Self.encodeEmbedding(item.vector),
                    epoch: epoch.rawValue
                )
            }
            try db.execute(sql: """
                UPDATE memory_embedding_state
                SET active_epoch = ?, previous_epoch = ?, activated_at = ?, rollback_available = 0
                WHERE id = 1
            """, arguments: [epoch.rawValue, prior.activeEpoch, activatedAt])

            func count(_ kind: MemoryEmbeddingCorpusKind) -> Int {
                staged.lazy.filter { $0.row.kind == kind }.count
            }
            return MemoryEmbeddingEpochActivationReport(
                epoch: epoch.rawValue,
                memories: count(.memory),
                proposals: count(.proposal),
                tombstones: count(.tombstone),
                previousEpoch: prior.activeEpoch,
                activatedAt: activatedAt
            )
        }
        invalidateRecallCache()
        await DerivedStateInvalidationCenter.shared.publish(DerivedSourceChange(
            namespace: "memory-v2",
            stableID: "embedding-epoch",
            operation: .changed,
            canonicalLocator: path.standardizedFileURL.path,
            reason: "embedding_epoch_activated"
        ))
        return report
    }

    private static func embeddingCorpus(in db: Database) throws -> [MemoryEmbeddingCorpusRow] {
        var result: [MemoryEmbeddingCorpusRow] = []
        // An active row whose vector is owed is the fill's: it lands through
        // the write's own checks, so activation leaves it for the fill.
        result += try Row.fetchAll(db, sql: """
            SELECT id, content FROM memories WHERE embedding IS NOT NULL OR status <> 'active' ORDER BY id
            """).map {
            MemoryEmbeddingCorpusRow(kind: .memory, id: $0["id"], content: $0["content"])
        }
        result += try Row.fetchAll(db, sql: "SELECT id, content FROM proposals ORDER BY id").map {
            MemoryEmbeddingCorpusRow(kind: .proposal, id: $0["id"], content: $0["content"])
        }
        result += try Row.fetchAll(db, sql: "SELECT content_hash, content FROM tombstones ORDER BY content_hash").map {
            MemoryEmbeddingCorpusRow(kind: .tombstone, id: $0["content_hash"], content: $0["content"])
        }
        return result
    }

    static func embeddingEpochState(in db: Database) throws -> MemoryEmbeddingEpochState {
        let row = try Row.fetchOne(db, sql: "SELECT * FROM memory_embedding_state WHERE id = 1")
        return MemoryEmbeddingEpochState(
            activeEpoch: row?["active_epoch"],
            previousEpoch: row?["previous_epoch"],
            activatedAt: row?["activated_at"],
            rollbackAvailable: (row?["rollback_available"] as Int? ?? 0) != 0
        )
    }

    private static func corpusKey(_ kind: MemoryEmbeddingCorpusKind, _ id: String) -> String {
        "\(kind.rawValue):\(id)"
    }

    private static func updateEmbedding(
        in db: Database,
        kind: MemoryEmbeddingCorpusKind,
        id: String,
        embedding: Data?,
        epoch: String?
    ) throws {
        let table: String
        let key: String
        switch kind {
        case .memory: table = "memories"; key = "id"
        case .proposal: table = "proposals"; key = "id"
        case .tombstone: table = "tombstones"; key = "content_hash"
        }
        try db.execute(
            sql: "UPDATE \(table) SET embedding = ?, embedding_epoch = ? WHERE \(key) = ?",
            arguments: [embedding, epoch, id]
        )
        guard db.changesCount == 1 else {
            throw MemoryStorageError.embeddingActivationInvalid(.unusableCandidate, "failed to update \(corpusKey(kind, id))")
        }
    }

    static func requireWritableEpoch(
        in db: Database,
        vector: [Float]?,
        epoch: String?
    ) throws {
        guard vector != nil else { return }
        let active = try embeddingEpochState(in: db).activeEpoch
        guard let active else { return }
        guard epoch == active else {
            throw MemoryStorageError.embeddingEpochMismatch(expected: active, actual: epoch)
        }
    }
}
