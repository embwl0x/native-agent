import Foundation
import GRDB
import NativeAgentCore
import PersistenceCore

extension MemoryStorage {
    // MARK: - Embedding epoch activation

    /// Snapshot every canonical text-bearing row. Callers embed this immutable
    /// candidate off the turn path, then pass it back to
    /// `activateEmbeddingEpoch`; activation rejects any intervening drift.
    public func embeddingCorpusSnapshot() async throws -> [MemoryEmbeddingCorpusRow] {
        try await dbPool.read { db in try Self.embeddingCorpus(in: db) }
    }

    /// Transactionally consistent evaluation copy. The returned store has its
    /// own root and can be freely probed; canonical live rows and access
    /// counters cannot be mutated by the lab.
    public func frozenCopy(at dataRoot: URL) throws -> MemoryStorage {
        let destinationDirectory = dataRoot.appendingPathComponent("memory", isDirectory: true)
        try FileManager.default.createDirectory(
            at: destinationDirectory,
            withIntermediateDirectories: true
        )
        let destination = destinationDirectory.appendingPathComponent("memory.sqlite")
        guard !FileManager.default.fileExists(atPath: destination.path) else {
            throw MemoryStorageError.databaseUnavailable("frozen-copy destination already exists")
        }
        try MemoryConsolidationGate.onlineBackup(from: path, to: destination)
        return try MemoryStorage(dataRoot: dataRoot, memoryLimit: memoryLimit)
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
            try db.execute(sql: "DELETE FROM memory_embedding_previous")
            for row in live {
                let existing = try Self.embeddingPayload(in: db, kind: row.kind, id: row.id)
                try db.execute(sql: """
                    INSERT INTO memory_embedding_previous
                      (kind, row_id, content_hash, embedding, embedding_epoch)
                    VALUES (?, ?, ?, ?, ?)
                """, arguments: [
                    row.kind.rawValue, row.id, row.contentHash,
                    existing.embedding, existing.epoch,
                ])
            }
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
                SET active_epoch = ?, previous_epoch = ?, activated_at = ?, rollback_available = 1
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
        await DerivedStateInvalidationCenter.shared.flush()
        return report
    }

    /// Immediate rollback lane retained for post-activation verification. It
    /// refuses if any canonical row was added, removed, or edited after the
    /// switch; a backup/repair workflow is required once reality has moved on.
    public func rollbackEmbeddingEpochActivation() async throws -> MemoryEmbeddingEpochState {
        let state = try await dbPool.write { db -> MemoryEmbeddingEpochState in
            let currentState = try Self.embeddingEpochState(in: db)
            guard currentState.rollbackAvailable else {
                throw MemoryStorageError.embeddingActivationInvalid(.unusableCandidate, "no retained prior epoch")
            }
            let live = try Self.embeddingCorpus(in: db)
            let previous = try Row.fetchAll(db, sql: """
                SELECT kind, row_id, content_hash, embedding, embedding_epoch
                FROM memory_embedding_previous
            """)
            let liveKeys = Set(live.map { Self.corpusKey($0.kind, $0.id) })
            let previousKeys = Set(try previous.map { row in
                guard let kind = MemoryEmbeddingCorpusKind(rawValue: row["kind"] as String) else {
                    throw MemoryStorageError.embeddingActivationInvalid(.unusableCandidate, "unknown retained row kind")
                }
                return Self.corpusKey(kind, row["row_id"] as String)
            })
            guard liveKeys == previousKeys else {
                throw MemoryStorageError.embeddingActivationInvalid(.corpusDrift, "canonical row set changed after activation")
            }
            let liveByKey = Dictionary(uniqueKeysWithValues: live.map { (Self.corpusKey($0.kind, $0.id), $0) })
            for row in previous {
                guard let kind = MemoryEmbeddingCorpusKind(rawValue: row["kind"] as String) else {
                    throw MemoryStorageError.embeddingActivationInvalid(.unusableCandidate, "unknown retained row kind")
                }
                let id: String = row["row_id"]
                let key = Self.corpusKey(kind, id)
                guard liveByKey[key]?.contentHash == (row["content_hash"] as String) else {
                    throw MemoryStorageError.embeddingActivationInvalid(.corpusDrift, "canonical content changed for \(key)")
                }
                try Self.updateEmbedding(
                    in: db,
                    kind: kind,
                    id: id,
                    embedding: row["embedding"],
                    epoch: row["embedding_epoch"]
                )
            }
            try db.execute(sql: """
                UPDATE memory_embedding_state
                SET active_epoch = previous_epoch,
                    previous_epoch = NULL,
                    activated_at = ?,
                    rollback_available = 0
                WHERE id = 1
            """, arguments: [Self.nowISO8601()])
            try db.execute(sql: "DELETE FROM memory_embedding_previous")
            return try Self.embeddingEpochState(in: db)
        }
        invalidateRecallCache()
        return state
    }

    private static func embeddingCorpus(in db: Database) throws -> [MemoryEmbeddingCorpusRow] {
        var result: [MemoryEmbeddingCorpusRow] = []
        result += try Row.fetchAll(db, sql: "SELECT id, content FROM memories ORDER BY id").map {
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

    private static func embeddingPayload(
        in db: Database,
        kind: MemoryEmbeddingCorpusKind,
        id: String
    ) throws -> (embedding: Data?, epoch: String?) {
        let table: String
        let key: String
        switch kind {
        case .memory: table = "memories"; key = "id"
        case .proposal: table = "proposals"; key = "id"
        case .tombstone: table = "tombstones"; key = "content_hash"
        }
        guard let row = try Row.fetchOne(
            db,
            sql: "SELECT embedding, embedding_epoch FROM \(table) WHERE \(key) = ?",
            arguments: [id]
        ) else {
            throw MemoryStorageError.embeddingActivationInvalid(.unusableCandidate, "missing canonical row \(corpusKey(kind, id))")
        }
        return (row["embedding"], row["embedding_epoch"])
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
