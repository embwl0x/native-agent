import Foundation
import GRDB
import NativeAgentCore
import PersistenceCore
// Blueprint: | `MemoryStorage+EmbeddingEpoch.swift` | `MemoryStorage`: atomic corpus activation and per-item failures |

extension MemoryStorage {
    /// Derived action vectors share memory's database and vector codec, never its canonical corpus or recall generation.
    public func actionEmbeddings(epoch: MemoryEmbeddingEpoch) async throws -> [String: [Float]] {
        try await dbPool.read { db in
            var vectors: [String: [Float]] = [:]
            for row in try Row.fetchAll(db, sql: "SELECT text_hash, vector FROM action_embeddings WHERE epoch = ?",
                                       arguments: [epoch.rawValue]) {
                guard let vector = try Self.decodeEmbedding(row["vector"]), !vector.isEmpty,
                      vector.allSatisfy(\.isFinite), vector.contains(where: { $0 != 0 }) else {
                    // Derived damage is a miss: the index writer replaces it from the exact action text, never using a bad vector.
                    continue
                }
                vectors[row["text_hash"]] = vector
            }
            return vectors
        }
    }

    public func actionEmbeddingFailures(epoch: MemoryEmbeddingEpoch) async throws -> [String: String] {
        try await dbPool.read { db in
            var failures: [String: String] = [:]
            for row in try Row.fetchAll(db, sql: "SELECT text_hash, reason FROM action_embedding_failures WHERE epoch = ?", arguments: [epoch.rawValue]) {
                failures[try row.decode(forColumn: "text_hash")] = try row.decode(forColumn: "reason")
            }
            return failures
        }
    }

    public func writeActionEmbeddings(_ items: [String: MemoryEmbeddingItem], epoch: MemoryEmbeddingEpoch,
                                      retaining hashes: Set<String>? = nil) async throws {
        try await dbPool.write { db in
            for (hash, item) in items {
                switch item {
                case .vector(let vector):
                    try VectorMath.requireUsable(vector)
                    try db.execute(sql: "INSERT OR REPLACE INTO action_embeddings (epoch, text_hash, vector) VALUES (?, ?, ?)",
                                   arguments: [epoch.rawValue, hash, Self.encodeEmbedding(vector)])
                    try db.execute(sql: "DELETE FROM action_embedding_failures WHERE epoch = ? AND text_hash = ?", arguments: [epoch.rawValue, hash])
                case .unembeddable(let reason):
                    try db.execute(sql: "DELETE FROM action_embeddings WHERE epoch = ? AND text_hash = ?", arguments: [epoch.rawValue, hash])
                    try db.execute(sql: "INSERT OR REPLACE INTO action_embedding_failures (epoch, text_hash, reason, recorded_at) VALUES (?, ?, ?, ?)",
                                   arguments: [epoch.rawValue, hash, reason, Self.nowISO8601()])
                }
            }
            if let hashes {
                let retained = String(decoding: try JSONEncoder().encode(hashes), as: UTF8.self)
                try db.execute(sql: """
                    DELETE FROM action_embeddings
                    WHERE epoch <> ? OR text_hash NOT IN (SELECT value FROM json_each(?))
                    """, arguments: [epoch.rawValue, retained])
                try db.execute(sql: """
                    DELETE FROM action_embedding_failures
                    WHERE epoch <> ? OR text_hash NOT IN (SELECT value FROM json_each(?))
                    """, arguments: [epoch.rawValue, retained])
            }
        }
    }

    // MARK: - Embedding epoch activation

    /// Snapshot every canonical text-bearing row. Callers embed this immutable candidate off the turn path, then pass it back to `activateEmbeddingEpoch`;
    /// activation rejects any intervening drift.
    public func embeddingCorpusSnapshot() async throws -> [MemoryEmbeddingCorpusRow] {
        try await dbPool.read { db in try Self.embeddingCorpus(in: db) }
    }

    public func embeddingEpochState() async throws -> MemoryEmbeddingEpochState {
        try await dbPool.read { db in try Self.embeddingEpochState(in: db) }
    }

    /// Switch memories, proposals and tombstones atomically after identity and content-hash checks on every prediction. Never stamp unverified vectors in
    /// place; unusable rows lose their vector and retain their named error.
    public func activateEmbeddingEpoch(
        _ epoch: MemoryEmbeddingEpoch,
        dimensions: Int,
        staged: [MemoryEmbeddingStagedRow],
        activationProbe: [Float]?
    ) async throws -> MemoryEmbeddingEpochActivationReport {
        let activatedAt = Self.nowISO8601()
        let outcome = try await dbPool.write { db -> Result<MemoryEmbeddingEpochActivationReport, MemoryStorageError> in
            let prior = try Self.embeddingEpochState(in: db)
            let live = try Self.embeddingCorpus(in: db)
            let liveByKey = Dictionary(uniqueKeysWithValues: live.map { (Self.corpusKey($0.kind, $0.id), $0) })
            var stagedByKey: [String: MemoryEmbeddingStagedRow] = [:]
            guard dimensions > 0 else {
                throw MemoryStorageError.embeddingActivationInvalid(.unusableCandidate, "invalid provider dimensions")
            }
            for item in staged {
                let key = Self.corpusKey(item.row.kind, item.row.id)
                guard stagedByKey[key] == nil else {
                    throw MemoryStorageError.embeddingActivationInvalid(.unusableCandidate, "duplicate staged row \(key)")
                }
                guard let current = liveByKey[key], current.contentHash == item.row.contentHash else {
                    throw MemoryStorageError.embeddingActivationInvalid(.corpusDrift, "canonical content drifted for \(key)")
                }
                if case .vector(let vector) = item.result {
                    do { try VectorMath.requireUsable(vector, dimensions: dimensions) }
                    catch {
                        throw MemoryStorageError.embeddingActivationInvalid(.unusableCandidate, "\(key): \(error.localizedDescription)")
                    }
                }
                stagedByKey[key] = item
            }
            guard stagedByKey.count == liveByKey.count else {
                let missing = Set(liveByKey.keys).subtracting(stagedByKey.keys).sorted().prefix(3)
                throw MemoryStorageError.embeddingActivationInvalid(
                    .corpusDrift,
                    "candidate covers \(stagedByKey.count)/\(liveByKey.count) rows; missing \(missing.joined(separator: ", "))"
                )
            }

            if live.isEmpty {
                guard let activationProbe else {
                    throw MemoryStorageError.embeddingActivationInvalid(.unusableCandidate, "empty corpus has no activation probe")
                }
                do { try VectorMath.requireUsable(activationProbe, dimensions: dimensions) }
                catch { throw MemoryStorageError.embeddingActivationInvalid(.unusableCandidate, "activation probe: \(error.localizedDescription)") }
            } else if !staged.contains(where: { if case .vector = $0.result { return true }; return false }) {
                let reason = """
                    The memory search model produced no usable vectors for \(live.count) canonical rows. Inspect Doctor's coreml_embedder finding and repair \
                    the model before rebuilding; no epoch was activated.
                    """
                // Commit the refusal, not the candidate. Throwing inside this transaction would erase the fact Doctor must judge.
                try db.execute(sql: """
                    UPDATE memory_embedding_state SET refused_epoch = ?, refusal_reason = ?, refused_at = ? WHERE id = 1
                    """, arguments: [epoch.rawValue, reason, activatedAt])
                return .failure(.embeddingActivationInvalid(.unusableCandidate, reason))
            }

            for item in staged {
                let vector: [Float]?
                switch item.result {
                case .vector(let value):
                    vector = value
                    try Self.clearEmbeddingFailure(in: db, kind: item.row.kind, id: item.row.id)
                case .unembeddable(let reason):
                    vector = nil
                    try Self.writeEmbeddingFailure(in: db, row: item.row, epoch: epoch, reason: reason)
                }
                try Self.updateEmbedding(
                    in: db,
                    kind: item.row.kind,
                    id: item.row.id,
                    embedding: Self.encodeEmbedding(vector),
                    epoch: epoch.rawValue
                )
            }
            try db.execute(sql: """
                UPDATE memory_embedding_state
                SET active_epoch = ?, previous_epoch = ?, activated_at = ?, dimensions = ?,
                    refused_epoch = NULL, refusal_reason = NULL, refused_at = NULL
                WHERE id = 1
            """, arguments: [epoch.rawValue, prior.activeEpoch, activatedAt, dimensions])

            func count(_ kind: MemoryEmbeddingCorpusKind) -> Int {
                staged.lazy.filter { $0.row.kind == kind }.count
            }
            return .success(MemoryEmbeddingEpochActivationReport(
                epoch: epoch.rawValue,
                memories: count(.memory),
                proposals: count(.proposal),
                tombstones: count(.tombstone),
                unembeddable: staged.filter { if case .unembeddable = $0.result { return true }; return false }.count,
                previousEpoch: prior.activeEpoch,
                activatedAt: activatedAt
            ))
        }
        let report = try outcome.get()
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
        // An active row whose vector is owed is the fill's: it lands through the write's own checks, so activation leaves it for the fill.
        result += try Row.fetchAll(db, sql: """
            SELECT id, content FROM memories WHERE embedding IS NOT NULL OR status <> 'active' ORDER BY id
            """).map {
            try MemoryEmbeddingCorpusRow(kind: .memory, id: $0.decode(forColumn: "id"), content: $0.decode(forColumn: "content"))
        }
        result += try Row.fetchAll(db, sql: "SELECT id, content FROM proposals ORDER BY id").map {
            try MemoryEmbeddingCorpusRow(kind: .proposal, id: $0.decode(forColumn: "id"), content: $0.decode(forColumn: "content"))
        }
        result += try Row.fetchAll(db, sql: "SELECT content_hash, content FROM tombstones ORDER BY content_hash").map {
            try MemoryEmbeddingCorpusRow(kind: .tombstone, id: $0.decode(forColumn: "content_hash"), content: $0.decode(forColumn: "content"))
        }
        return result
    }

    static func embeddingEpochState(in db: Database) throws -> MemoryEmbeddingEpochState {
        guard let row = try Row.fetchOne(db, sql: "SELECT * FROM memory_embedding_state WHERE id = 1") else {
            throw MemoryStorageError.databaseUnavailable("Memory embedding state is missing")
        }
        let refusedEpoch: String? = try row.decode(forColumn: "refused_epoch")
        let refusalReason: String? = try row.decode(forColumn: "refusal_reason")
        let refusedAt: String? = try row.decode(forColumn: "refused_at")
        let activationFailure: MemoryEmbeddingActivationFailure?
        if let refusedEpoch, let refusalReason, let refusedAt {
            activationFailure = MemoryEmbeddingActivationFailure(epoch: refusedEpoch, reason: refusalReason, recordedAt: refusedAt)
        } else {
            guard refusedEpoch == nil, refusalReason == nil, refusedAt == nil else {
                throw MemoryStorageError.databaseUnavailable("Memory embedding activation refusal is incomplete")
            }
            activationFailure = nil
        }
        return MemoryEmbeddingEpochState(
            activeEpoch: row["active_epoch"],
            dimensions: row["dimensions"],
            previousEpoch: row["previous_epoch"],
            activatedAt: row["activated_at"],
            activationFailure: activationFailure
        )
    }

    private static func corpusKey(_ kind: MemoryEmbeddingCorpusKind, _ id: String) -> String {
        "\(kind.rawValue):\(id)"
    }

    /// A recorded failure belongs only to these exact bytes in this space. A changed/deleted row cannot acquire a late prediction's verdict.
    func recordUnembeddable(_ row: MemoryEmbeddingCorpusRow, epoch: MemoryEmbeddingEpoch, reason: String) async throws -> Bool {
        try await dbPool.write { db in
            let state = try Self.embeddingEpochState(in: db)
            guard state.activeEpoch == epoch.rawValue else {
                throw MemoryStorageError.embeddingEpochMismatch(expected: epoch.rawValue, actual: state.activeEpoch)
            }
            let table = row.kind == .tombstone ? "tombstones" : (row.kind == .proposal ? "proposals" : "memories")
            let key = row.kind == .tombstone ? "content_hash" : "id"
            let activeOnly = row.kind == .memory ? " AND status = 'active'" : ""
            guard let content = try String.fetchOne(db, sql: "SELECT content FROM \(table) WHERE \(key) = ? AND embedding IS NULL\(activeOnly)", arguments: [row
                .id]),
                  Data(content.utf8) == Data(row.content.utf8) else { return false }
            try Self.writeEmbeddingFailure(in: db, row: row, epoch: epoch, reason: reason)
            return true
        }
    }

    private static func writeEmbeddingFailure(in db: Database, row: MemoryEmbeddingCorpusRow,
                                              epoch: MemoryEmbeddingEpoch, reason: String) throws {
        try db.execute(sql: """
            INSERT OR REPLACE INTO memory_embedding_failures (kind, row_id, content, epoch, reason, recorded_at)
            VALUES (?, ?, ?, ?, ?, ?)
            """, arguments: [row.kind.rawValue, row.id, Data(row.content.utf8), epoch.rawValue, reason, nowISO8601()])
    }

    static func clearEmbeddingFailure(in db: Database, kind: MemoryEmbeddingCorpusKind, id: String) throws {
        try db.execute(sql: "DELETE FROM memory_embedding_failures WHERE kind = ? AND row_id = ?", arguments: [kind.rawValue, id])
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
        guard let vector else { return }
        try VectorMath.requireUsable(vector)
        let state = try embeddingEpochState(in: db)
        guard let active = state.activeEpoch, let dimensions = state.dimensions else {
            throw MemoryStorageError.searchFailure("Memory search awaits a validated epoch and dimensions.",
                code: "memory_search_index_updating", instruction: """
                    Allow memory search convergence to activate the selected model; inspect Doctor if it cannot complete.
                    """)
        }
        guard epoch == active else {
            throw MemoryStorageError.embeddingEpochMismatch(expected: active, actual: epoch)
        }
        try VectorMath.requireUsable(vector, dimensions: dimensions)
    }
}
