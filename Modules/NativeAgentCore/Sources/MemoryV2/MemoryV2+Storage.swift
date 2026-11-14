// MemoryStorage alone owns canonical memories, proposals and rejection tombstones.

import Foundation
import GRDB
import NativeAgentShared
import NativeAgentCore
import PersistenceCore
// Blueprint: | `MemoryV2+Storage.swift` | `MemoryStorage`, `statusCounts`, `curationPage`: canonical mutations and bounded curation |

// MARK: - MemoryStorage actor

/// Owns memory.sqlite's schema (including kg_*). Local backup and export take SQLite snapshots, never journal sidecars; PrivacyMap: memory. The phone receives
/// active-memory, proposal and graph projections, never these files.
public actor MemoryStorage {
    // Same-module storage extensions share this pool rather than reopening the database.
    let dbPool: DatabasePool
    public let path: URL
    let memoryLimit: Int
    var startupBoundEvictions: [StoredMemory]
    var replayedStartupUserProjection = false
    var replayedStartupSpotlightProjection = false
    var replayedStartupKnowledgeGraphProjection = false
    var userMDGenerator: UserMDGenerator?
    var spotlightHook: (@Sendable (StoredMemory, Bool) async -> Void)?
    public private(set) var spotlightProjectionFailure: String?

    func recordSpotlightProjectionFailure(_ message: String?) {
        spotlightProjectionFailure = message
        if let message { nativeLog("MemoryV2 Spotlight: %@", message) }
    }
    var knowledgeGraphHook: (@Sendable (String) async -> Void)?
    /// Ordered projection lanes resolve canonical eligibility when they run. A hook queued after suspension carries identity, never stale intent.
    var spotlightProjectionTail: Task<Void, Never>?
    var knowledgeGraphProjectionTail: Task<Void, Never>?
    var userMDProjectionTail: Task<Void, Never>?
    var spotlightProjectionID: UUID?
    var knowledgeGraphProjectionID: UUID?
    var userMDProjectionID: UUID?
    var projectionsClosed = false

    // MARK: - Recall candidate cache
    // Canonical recall_generation excludes usage and graph-only writes.
    var recallCache: RecallCache?
    let recallRead = LatestRead()

    public init(dataRoot: URL, memoryLimit: Int = memoryStoredRowCap) throws {
        let dir = dataRoot.appendingPathComponent("memory", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let path = dir.appendingPathComponent("memory.sqlite")
        self.path = path
        var config = Configuration()
        config.foreignKeysEnabled = true
        config.busyMode = .immediateError
        // Bound retained WAL to 4 MB on every connection.
        config.prepareDatabase { db in
            try db.execute(sql: "PRAGMA journal_size_limit = 4194304")
            // Match Swift's cursor comparisons, including Unicode identifiers.
            db.add(collation: DatabaseCollation("memory_curation_order") { lhs, rhs in
                lhs == rhs ? .orderedSame : lhs < rhs ? .orderedAscending : .orderedDescending
            })
        }
        let pool = try DatabasePool(path: path.path, configuration: config)
        try MemoryStorage.migrator.migrate(pool)
        try pool.read { db in
            try Self.requireSemanticIntegrity(in: db)
        }
        let boundedLimit = max(1, memoryLimit)
        let startupEvictions = try pool.write { db in
            let evicted = try Self.pruneMemoriesToBound(in: db, limit: boundedLimit)
            try Self.pruneTerminalProposals(in: db)
            return evicted
        }
        self.dbPool = pool
        self.memoryLimit = boundedLimit
        self.startupBoundEvictions = startupEvictions
        Self.publishStartupBoundEvictions(startupEvictions, memoryPath: path)
    }

    // MARK: - Hard memory bound

    /// Evict under the canonical write transaction; capacity forgetting creates no rejection tombstones.
    @discardableResult
    static func pruneMemoriesToBound(
        in db: Database,
        limit: Int = memoryStoredRowCap,
        preservingIDs: Set<String> = []
    ) throws -> [StoredMemory] {
        let boundedLimit = max(1, limit)
        let count = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM memories") ?? 0
        let overflow = count - boundedLimit
        guard overflow > 0 else { return [] }
        // Corrections, supersession history and pending replacement targets are not capacity victims; refuse admission if disposable capacity is insufficient.
        let rows = try Row.fetchAll(db, sql: """
            SELECT * FROM memories
            WHERE json_extract(metadata_json, '$.superseded_by') IS NULL
              AND json_extract(metadata_json, '$.corrected_by') IS NULL
              AND id NOT IN (SELECT json_extract(owed.value, '$.id')
                             FROM memories p, json_each(p.metadata_json, '$.\(pendingSupersedesKey)') owed
                             WHERE json_extract(owed.value, '$.id') IS NOT NULL)
        """).map(Self.decodeMemory)

        let ordered = rows.sorted { lhs, rhs in
            let lhsRank = retentionEvictionRank(lhs)
            let rhsRank = retentionEvictionRank(rhs)
            if lhsRank != rhsRank { return lhsRank < rhsRank }
            let lhsUse = lhs.lastUsedAt ?? lhs.updatedAt
            let rhsUse = rhs.lastUsedAt ?? rhs.updatedAt
            if lhsUse != rhsUse { return lhsUse < rhsUse }
            if lhs.createdAt != rhs.createdAt { return lhs.createdAt < rhs.createdAt }
            return lhs.id < rhs.id
        }
        // The row being admitted is never its own eviction: refuse instead, so the caller's transaction rolls back whole.
        let evicted = Array(ordered.filter { !preservingIDs.contains($0.id) }.prefix(overflow))
        guard evicted.count == overflow else { throw MemoryStorageError.capacityExceeded }
        // Admission must not trade protected tissue for a lower-priority row.
        if evicted.contains(where: { retentionEvictionRank($0) == 4 }),
           rows.contains(where: {
               preservingIDs.contains($0.id) && retentionEvictionRank($0) < 4
           }) {
            throw MemoryStorageError.capacityExceeded
        }
        guard !evicted.isEmpty else { return [] }
        let placeholders = Array(repeating: "?", count: evicted.count).joined(separator: ",")
        try db.execute(
            sql: "DELETE FROM memories WHERE id IN (\(placeholders))",
            arguments: StatementArguments(evicted.map(\.id))
        )
        return evicted
    }

    /// Evict excluded and archived rows before temporary/stale facts, then ordinary facts. Protect pinned and identity rows until no other class remains;
    /// oldest protected rows still yield when the hard cap requires it.
    private static func retentionEvictionRank(_ memory: StoredMemory) -> Int {
        if memory.status != "active" { return 0 }
        let lifecycle = MemoryLifecycle.normalized(memory.lifecycle)
        if MemoryLifecycle.recallExcluded.contains(lifecycle) { return 1 }
        if lifecycle == MemoryLifecycle.temporary
            || lifecycle == MemoryLifecycle.inferred
            || lifecycle == MemoryLifecycle.stale {
            return 2
        }
        if case .object(let metadata)? = memory.metadata {
            if case .bool(true)? = metadata["pinned"] { return 4 }
            if case .string(let kind)? = metadata["kind"],
               kind.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "identity" {
                return 4
            }
        }
        return 3
    }

    func handleBoundEvictions(_ evicted: [StoredMemory]) async {
        guard !evicted.isEmpty else { return }
        invalidateRecallCache()
        for persona in Set(evicted.map(\.personaId)) { pokeUserMDRegen(persona: persona) }
        for memory in evicted {
            pokeSpotlight(memory)
            pokeKnowledgeGraph(memory.id)
            await pokeDerivedState(memory, deleted: true)
        }
    }

    // MARK: - Memory CRUD

    /// Duplicate matching and evidence accumulation share the insertion write transaction, so simultaneous stores cannot lose counts or roots. The
    /// memory arrives stamped with its roots by `SwiftNativeMemoryV2.store`.
    public func admitMemory(
        _ memory: StoredMemory, insertIfMissing: Bool, preserveID: Bool,
        superseding: [SupersedingAcceptance] = []
    ) async throws -> StoredMemory? {
        _ = try MemoryRoot.roots(in: memory.metadata)
        let result = try await dbPool.write { db -> (StoredMemory?, [StoredMemory], [StoredMemory]) in
            try Self.requireWritableEpoch(in: db, vector: memory.embedding, epoch: memory.embeddingEpoch)
            try Self.requireNotTombstoned(memory, in: db)
            let rows = try Row.fetchAll(db, sql: """
                SELECT * FROM memories WHERE status = 'active'
                    AND lifecycle NOT IN \(MemoryLifecycle.recallExcludedSQL)
                    AND (? = 0 OR id = ?)
                ORDER BY rowid
            """, arguments: [preserveID, memory.id]).map(Self.decodeMemory)
            if let row = try Self.admissionDuplicate(of: memory, among: rows, in: db) {
                var saved = try Self.foldDuplicate(memory, into: row, in: db)
                let demoted = try superseding.filter { $0.targetId != saved.id }
                    .map { try Self.demoteSuperseded($0, by: &saved, in: db) }
                return (saved, [], demoted)
            }
            guard insertIfMissing else { return (nil, [], []) }
            try Self.validateTemporalEvidence(memory)
            try Self.executeMemoryInsert(memory, in: db)
            var replacement = memory
            let demoted = try superseding.map { try Self.demoteSuperseded($0, by: &replacement, in: db) }
            let evicted = try Self.pruneMemoriesToBound(in: db, limit: memoryLimit, preservingIDs: [memory.id])
            guard let saved = try Row.fetchOne(db, sql: "SELECT * FROM memories WHERE id = ?", arguments: [memory.id]).map(Self.decodeMemory) else {
                throw MemoryStorageError.databaseUnavailable("committed memory is missing")
            }
            return (saved, evicted, demoted)
        }
        if let row = result.0 {
            invalidateRecallCache()
            pokeUserMDRegen(persona: row.personaId)
            await pokeProjectionHooks(row)
        }
        for row in result.2 { await pokeProjectionHooks(row) }
        await handleBoundEvictions(result.1)
        return result.0
    }

    /// Warm writes and owed-vector landing share duplicate admission: same text and scope, or a recent same-scope near-paraphrase that is not a correction.
    static func admissionDuplicate(of memory: StoredMemory, among rows: [StoredMemory],
                                   in db: Database) throws -> StoredMemory? {
        let now = Date()
        let rows = rows.filter { MemoryRecordDisclosurePolicy.isTemporallyEligible(validTo: $0.validTo, at: now) }
        let incoming = MemoryRecord(stored: memory)
        let scope = MemoryRecordDisclosurePolicy.classify(incoming)
        let scopeKey = Self.disclosureScopeKey(personaId: memory.personaId, metadata: memory.metadata)
        let key = Self.comparisonKey(memory.content, mode: .canonical)
        var duplicate = rows.sorted { $0.createdAt > $1.createdAt }.first {
            scope != nil && Self.disclosureScopeKey(personaId: $0.personaId, metadata: $0.metadata) == scopeKey
                && Self.comparisonKey($0.content, mode: .canonical) == key
        }
        if duplicate == nil, !MemoryRecallScoring.isExplicitCorrection(memory.metadata),
           let vector = memory.embedding, let epoch = memory.embeddingEpoch, !epoch.isEmpty {
            let activeEpoch = try Self.embeddingEpochState(in: db).activeEpoch
            if activeEpoch == nil || activeEpoch == epoch {
                let nearest = rows.filter { Self.comparableEpochs($0.embeddingEpoch, epoch) && $0.embedding != nil }
                    .map { (row: $0, cosine: VectorMath.cosine(vector, $0.embedding)) }
                    .max { $0.cosine < $1.cosine }
                if let nearest, Self.semanticDuplicate(nearest.row.content, memory.content, similarity: nearest.cosine),
                   !MemoryRecallScoring.isExplicitCorrection(nearest.row.metadata),
                   scope != nil,
                   Self.disclosureScopeKey(personaId: nearest.row.personaId, metadata: nearest.row.metadata) == scopeKey,
                   let created = MemoryRecallScoring.parseTimestamp(nearest.row.createdAt),
                   now.timeIntervalSince(created) < 24 * 3600 {
                    duplicate = nearest.row
                }
            }
        }
        return duplicate
    }

    /// Preserve caller-owned identity until vector admission.
    static let preservesIDKey = "admission_preserves_id"
    /// A cold write is saved but not admitted until its vector lands and passes the checks; a turn withholds it until then.
    public static let pendingAdmissionKey = "admission_pending"
    /// Cold replacements leave their targets intact until admission.
    static let pendingSupersedesKey = "admission_supersedes"

    static func owingAdmission(_ metadata: JSONValue?, preservingID: Bool,
                               superseding: [SupersedingAcceptance] = []) -> JSONValue {
        var object: [String: JSONValue] = [:]
        if case .object(let current)? = metadata { object = current }
        object[pendingAdmissionKey] = .bool(true)
        if preservingID { object[preservesIDKey] = .bool(true) }
        if !superseding.isEmpty {
            object[pendingSupersedesKey] = .array(superseding.map {
                .object(["id": .string($0.targetId), "hash": .string($0.expectedContentHash), "reason": .string($0.reason),
                         "restatesOwnPast": .bool($0.restatesOwnPast)])
            })
        }
        return .object(object)
    }

    public static func owedSupersessions(_ metadata: JSONValue?) throws -> [SupersedingAcceptance] {
        guard case .object(let object)? = metadata, let pending = object[pendingSupersedesKey] else { return [] }
        guard case .array(let rows) = pending else { throw MemoryV2Error.staleSupersession("Unreadable owed supersession intent.") }
        return try rows.map { row in
            guard case .object(let fields) = row, case .string(let id)? = fields["id"],
                  case .string(let hash)? = fields["hash"], case .string(let reason)? = fields["reason"],
                  case .bool(let restatesOwnPast)? = fields["restatesOwnPast"] else {
                throw MemoryV2Error.staleSupersession("Owed supersession lacks readable restatement intent; review it before admission.")
            }
            return SupersedingAcceptance(targetId: id, expectedContentHash: hash, reason: reason,
                                         restatesOwnPast: restatesOwnPast)
        }
    }

    public static func metadataFlag(_ metadata: JSONValue?, _ key: String) -> Bool {
        if case .object(let object)? = metadata, object[key] == .bool(true) { return true }
        return false
    }

    /// The incoming write becomes evidence on the row it duplicates. An owed row folding late also carries its own lineage and occurrences across.
    static func foldDuplicate(_ memory: StoredMemory, into existing: StoredMemory, in db: Database,
                              carryingHistory: Bool = false) throws -> StoredMemory {
        var row = existing
        let key = Self.comparisonKey(memory.content, mode: .canonical)
        if memory.embedding == nil {
            try Self.requireNotTombstoned(row, in: db)
        }
        var metadata: [String: JSONValue] = [:]
        if case .object(let existing)? = row.metadata { metadata = existing }
        var count: Int64 = 0
        if case .int(let value)? = metadata["recall_count"] { count = value }
        if case .double(let value)? = metadata["recall_count"] {
            guard let value = Int64(exactly: value.rounded(.towardZero)) else {
                throw MemoryStorageError.databaseUnavailable("duplicate write: recall_count is outside Int64 range")
            }
            count = value
        }
        let (next, overflow) = count.addingReportingOverflow(1)
        guard !overflow else {
            throw MemoryStorageError.databaseUnavailable("duplicate write: recall_count overflow")
        }
        var patch = SwiftNativeMemoryV2.duplicateProvenancePatch(
            existing: MemoryRecord(stored: row), newSource: memory.source, newMetadata: memory.metadata)
        // Explicit scope replaces scope only on the same text, never on a merely similar record. Omission retains the old scope.
        if Self.comparisonKey(row.content, mode: .canonical) == key,
           case .object(let incoming)? = memory.metadata,
           case .array(let topics)? = incoming["context_topics"], !topics.isEmpty {
            patch["context_topics"] = .array(topics)
        }
        for (key, value) in patch {
            if key == "observed_at", case .string(let observed) = value {
                row.observedAt = observed
            } else {
                metadata[key] = value
            }
        }
        metadata["recall_count"] = .int(next)
        if carryingHistory, case .object(let own)? = memory.metadata {
            for key in ["source_history", "duplicate_occurrences"] {
                guard case .array(let carried)? = own[key] else { continue }
                var merged: [JSONValue] = []
                if case .array(let kept)? = metadata[key] { merged = kept }
                for value in carried where !merged.contains(value) { merged.append(value) }
                metadata[key] = .array(Array(merged.suffix(SwiftNativeMemoryV2.duplicateProvenanceCap)))
            }
        }
        // A duplicate must retain the complete incoming provenance or refuse the write.
        let held = try MemoryRoot.roots(in: existing.metadata)
        let incoming = try MemoryRoot.roots(in: memory.metadata)
        let principals = (held + incoming).flatMap(\.through)
        let trust = MemoryDataProvenance.reading([], principals: principals)
        if !MemoryDataProvenance.steering(principals, trust: trust).isEmpty {
            guard let first = MemoryRoot.firstKnown(held.map { MemoryDataProvenance.presented($0, trust: trust) })?.date else {
                throw MemoryStorageError.databaseUnavailable("duplicate write: the held roots have no readable first-known time")
            }
            for root in incoming {
                guard let at = root.date else {
                    throw MemoryStorageError.databaseUnavailable("duplicate write: an incoming root has no readable time")
                }
                guard root.how != .remembered, at >= first else {
                    throw MemoryStorageError.databaseUnavailable(
                        "duplicate write: incoming provenance restates the agent's past across an untrusted source boundary"
                    )
                }
            }
        }
        row.metadata = MemoryRoot.setting(MemoryRoot.union([held, incoming]), in: .object(metadata))
        row.updatedAt = Self.nowISO8601()
        try Self.validateTemporalEvidence(row)
        try db.execute(sql: """
            UPDATE memories SET metadata_json = ?, observed_at = ?, updated_at = ? WHERE id = ?
        """, arguments: [Self.encodeMetadata(row.metadata), row.observedAt, row.updatedAt, row.id])
        try Self.recordCorrectionOccurrence(metadata: memory.metadata, rowID: memory.id, createdAt: memory.createdAt,
                                           on: row.id, in: db)
        if carryingHistory, memory.id != row.id {
            // Move the full record, never the bounded metadata preview. The same origin already on the survivor remains one occurrence.
            if try Row.fetchOne(db, sql: """
                SELECT 1 FROM correction_occurrences a JOIN correction_occurrences b ON a.origin_id = b.origin_id
                WHERE a.memory_id = ? AND b.memory_id = ?
                  AND (a.occurred_at IS NOT b.occurred_at OR a.session_id IS NOT b.session_id OR a.history IS NOT b.history)
                LIMIT 1
                """, arguments: [memory.id, row.id]) != nil {
                throw MemoryStorageError.invalidTemporalEvidence("duplicate corrections disagree about the same occurrence")
            }
            try db.execute(sql: """
                INSERT INTO correction_occurrences (memory_id, origin_id, at, occurred_at, session_id, history)
                SELECT ?, origin_id, at, occurred_at, session_id, history
                FROM correction_occurrences WHERE memory_id = ?
                ON CONFLICT(memory_id, origin_id) DO NOTHING
                """, arguments: [row.id, memory.id])
            try db.execute(sql: "DELETE FROM correction_occurrences WHERE memory_id = ?", arguments: [memory.id])
        }
        guard let saved = try Row.fetchOne(db, sql: "SELECT * FROM memories WHERE id = ?", arguments: [row.id]).map(Self.decodeMemory) else {
            throw MemoryStorageError.databaseUnavailable("committed memory is missing")
        }
        return saved
    }

    /// The memory arrives stamped with its roots by `SwiftNativeMemoryV2.store`.
    @discardableResult
    public func insertMemory(
        _ memory: StoredMemory,
        superseding: [SupersedingAcceptance] = []
    ) async throws -> StoredMemory {
        _ = try MemoryRoot.roots(in: memory.metadata)
        let (saved, demoted, evicted) = try await dbPool.write { db -> (StoredMemory, [StoredMemory], [StoredMemory]) in
            try Self.requireNotTombstoned(memory, in: db)
            try Self.validateTemporalEvidence(memory)
            try Self.requireWritableEpoch(
                in: db,
                vector: memory.embedding,
                epoch: memory.embeddingEpoch
            )
            try Self.executeMemoryInsert(memory, in: db)
            var replacement = memory
            let demoted = try superseding.map { try Self.demoteSuperseded($0, by: &replacement, in: db) }
            let evicted = try Self.pruneMemoriesToBound(
                in: db,
                limit: memoryLimit,
                preservingIDs: [memory.id]
            )
            guard let saved = try Row.fetchOne(db, sql: "SELECT * FROM memories WHERE id = ?", arguments: [memory.id]).map(Self.decodeMemory) else {
                throw MemoryStorageError.databaseUnavailable("committed memory is missing")
            }
            return (saved, demoted, evicted)
        }
        invalidateRecallCache()
        pokeUserMDRegen(persona: memory.personaId)
        await pokeProjectionHooks(saved)
        for predecessor in demoted {
            pokeUserMDRegen(persona: predecessor.personaId)
            await pokeProjectionHooks(predecessor)
        }
        await handleBoundEvictions(evicted)
        return saved
    }

    /// Stay inside the caller's write transaction.
    static func executeMemoryInsert(_ memory: StoredMemory, in db: Database, recordCorrection: Bool = true) throws {
        try db.execute(sql: """
            INSERT INTO memories
              (id, content, persona_id, source, confidence,
               created_at, updated_at, embedding, status, metadata_json,
               use_count, last_used_at, lifecycle, embedding_epoch,
               valid_from, valid_to, observed_at, evidence_json)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        """, arguments: [
            memory.id, memory.content, memory.personaId, memory.source, memory.confidence,
            memory.createdAt, memory.updatedAt,
            Self.encodeEmbedding(memory.embedding),
            memory.status,
            Self.encodeMetadata(memory.metadata),
            memory.useCount, memory.lastUsedAt,
            MemoryLifecycle.normalized(memory.lifecycle),
            memory.embeddingEpoch,
            memory.validFrom, memory.validTo, memory.observedAt,
            Self.encodeMetadata(memory.evidence)
        ])
        if recordCorrection {
            try Self.recordCorrectionOccurrence(metadata: memory.metadata, rowID: memory.id, createdAt: memory.createdAt,
                                               on: memory.id, in: db)
        }
    }

    public func memoriesOwingVectors(limit: Int, epoch: MemoryEmbeddingEpoch,
                                    afterRowID: Int64? = nil) async throws -> [(rowID: Int64, id: String, content: String)] {
        try await dbPool.read { db in
            try Row.fetchAll(db, sql: """
                SELECT rowid AS row_id, id, content FROM memories
                WHERE embedding IS NULL AND status = 'active' AND TRIM(COALESCE(content, '')) <> ''
                  AND (? IS NULL OR rowid > ?)
                  AND NOT EXISTS (SELECT 1 FROM memory_embedding_failures f
                    WHERE f.kind = 'memory' AND f.row_id = memories.id
                      AND f.content = CAST(memories.content AS BLOB) AND f.epoch = ?)
                ORDER BY rowid LIMIT ?
                """, arguments: [afterRowID, afterRowID, epoch.rawValue, max(1, limit)])
                .map { row in
                    (try row.decode(forColumn: "row_id"), try row.decode(forColumn: "id"), try row.decode(forColumn: "content"))
                }
        }
    }

    enum OwedVectorLanding { case landed, archived(reason: String), unreadable(reason: String), superseded }

    /// Land owed vectors under warm-write checks in one exact-content transaction. Newer writes win; rejected paraphrases and collapsed duplicates retain their
    /// archival reason. Unreadable supersession intent leaves the row and its targets untouched.
    func landOwedVector(id: String, content: String, vector: [Float],
                        epoch: MemoryEmbeddingEpoch) async throws -> OwedVectorLanding {
        let (outcome, changed) = try await dbPool.write { db -> (OwedVectorLanding, [StoredMemory]) in
            guard var owed = try Row.fetchOne(db, sql: """
                SELECT * FROM memories WHERE id = ? AND embedding IS NULL AND content = ? AND status = 'active'
                """, arguments: [id, content]).map(Self.decodeMemory) else { return (.superseded, []) }
            try Self.requireWritableEpoch(in: db, vector: vector, epoch: epoch.rawValue)
            let supersessions: [SupersedingAcceptance]
            do {
                supersessions = try Self.owedSupersessions(owed.metadata)
            } catch let error as ToolFailureError where error.code == "memory_supersession_stale" {
                return (.unreadable(reason: error.message), [])
            }
            owed.embedding = vector
            owed.embeddingEpoch = epoch.rawValue
            var reason: String?
            var folded: StoredMemory?
            var demoted: [StoredMemory] = []
            // Preserve caller-owned IDs through admission, matching warm-write identity.
            let preservesID = Self.metadataFlag(owed.metadata, Self.preservesIDKey)
            do {
                try Self.requireNotTombstoned(owed, in: db)
            } catch MemoryStorageError.tombstoned {
                reason = "a rejected claim, found when its owed vector landed"
            }
            if reason == nil, !preservesID {
                let others = try Row.fetchAll(db, sql: """
                    SELECT * FROM memories WHERE status = 'active' AND id <> ?
                        AND lifecycle NOT IN \(MemoryLifecycle.recallExcludedSQL) ORDER BY rowid
                    """, arguments: [id]).map(Self.decodeMemory)
                if let duplicate = try Self.admissionDuplicate(of: owed, among: others, in: db) {
                    folded = try Self.foldDuplicate(owed, into: duplicate, in: db, carryingHistory: true)
                    reason = "folded into \(duplicate.id), a duplicate found when its owed vector landed"
                }
            }
            // Admit replacements and demote unchanged targets atomically; target drift refuses the replacement.
            if reason == nil || folded != nil, !supersessions.isEmpty {
                var replacement = folded ?? owed
                do {
                    try db.inSavepoint {
                        demoted = try supersessions.filter { $0.targetId != replacement.id }
                            .map { try Self.demoteSuperseded($0, by: &replacement, in: db) }
                        return .commit
                    }
                    if folded != nil { folded = replacement } else { owed = replacement }
                } catch let error as ToolFailureError where error.code == "memory_restatement_steered" {
                    // This refusal must undo any duplicate fold too; no part of a refused own-past write may survive.
                    throw error
                } catch {
                    reason = "a memory it was to replace changed or left before its owed vector landed: \(error)"
                }
            }
            guard let reason else {
                try Self.clearEmbeddingFailure(in: db, kind: .memory, id: id)
                try db.execute(sql: """
                    UPDATE memories SET embedding = ?, embedding_epoch = ?,
                        metadata_json = json_remove(metadata_json, '$.\(Self.preservesIDKey)', '$.\(Self.pendingAdmissionKey)',
                            '$.\(Self.pendingSupersedesKey)')
                    WHERE id = ?
                    """, arguments: [Self.encodeEmbedding(vector), epoch.rawValue, id])
                let landed = try Row.fetchOne(db, sql: "SELECT * FROM memories WHERE id = ?", arguments: [id])
                    .map(Self.decodeMemory)
                return (.landed, [landed].compactMap { $0 } + demoted)
            }
            var metadata: [String: JSONValue] = [:]
            if case .object(let current)? = owed.metadata { metadata = current }
            metadata["archived_reason"] = .string(reason)
            try db.execute(sql: """
                UPDATE memories SET status = 'archived', updated_at = ?, metadata_json = ? WHERE id = ?
                """, arguments: [Self.nowISO8601(), Self.encodeMetadata(.object(metadata)), id])
            let archived = try Row.fetchOne(db, sql: "SELECT * FROM memories WHERE id = ?", arguments: [id])
                .map(Self.decodeMemory)
            return (.archived(reason: reason), [archived, folded].compactMap { $0 } + demoted)
        }
        guard !changed.isEmpty else { return outcome }
        invalidateRecallCache()
        for row in changed {
            pokeUserMDRegen(persona: row.personaId)
            await pokeProjectionHooks(row)
        }
        return outcome
    }

    public func memories(ids: [String]) async throws -> [StoredMemory] {
        guard !ids.isEmpty else { return [] }
        return try await dbPool.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM memories WHERE id IN (\(Array(repeating: "?", count: ids.count).joined(separator: ",")))",
                             arguments: StatementArguments(ids)).map(Self.decodeMemory)
        }
    }

    public func memory(id: String) async throws -> StoredMemory? {
        try await dbPool.read { db in
            guard let row = try Row.fetchOne(db, sql: "SELECT * FROM memories WHERE id = ?", arguments: [id]) else {
                return nil
            }
            return try Self.decodeMemory(row)
        }
    }

    /// A conditional edit skips a row whose approved original has changed. An edit that leaves the row as it is writes nothing and says so.
    public func updateMemory(
        id: String, patch: MemoryPatch, expectedContent: String? = nil,
        onlyIf: (@Sendable (StoredMemory) -> Bool)? = nil,
        context: MemoryWriteContext
    ) async throws -> (memory: StoredMemory, changed: Bool)? {
        let turnProvenance = try MemorySenseProvenance.stamping(nil, reads: context.senseReads)
        let (updated, changed, demoted) = try await dbPool.write { db -> (StoredMemory?, Bool, [StoredMemory]) in
            guard var existing = try Row.fetchOne(db, sql: "SELECT * FROM memories WHERE id = ?", arguments: [id]).map(Self.decodeMemory) else {
                return (nil, false, [])
            }
            if let expectedContent, existing.content != expectedContent { return (nil, false, []) }
            if let onlyIf, !onlyIf(existing) { return (nil, false, []) }
            let prior = existing
            let priorMetadata = existing.metadata
            let contentChanged = patch.content.map { $0 != existing.content } == true
            let owesVector = contentChanged && patch.embedding == nil
            if let c = patch.content { existing.content = c }
            if let s = patch.source { existing.source = s }
            if let conf = patch.confidence { existing.confidence = conf }
            if let e = patch.embedding { existing.embedding = e }
            if patch.embedding != nil { existing.embeddingEpoch = patch.embeddingEpoch }
            if let st = patch.status { existing.status = st }
            if let lifecycle = patch.lifecycle { existing.lifecycle = MemoryLifecycle.normalized(lifecycle) }
            if let validFrom = patch.validFrom { existing.validFrom = validFrom }
            // Reactivating a record reopens its truth interval. Correction lineage stays in metadata; a closed interval cannot stay current.
            if patch.status == "active", MemoryLifecycle.isRecallEligible(existing.lifecycle) {
                existing.validTo = nil
            }
            if let validTo = patch.validTo { existing.validTo = validTo }
            if let observedAt = patch.observedAt { existing.observedAt = observedAt }
            if let evidence = patch.evidence { existing.evidence = evidence }
            if let m = patch.metadata { existing.metadata = m }
            if let merge = patch.metadataMerge, !merge.isEmpty {
                var metadata: [String: JSONValue] = [:]
                if case .object(let current)? = existing.metadata { metadata = current }
                if merge["pinned"] == .bool(true), metadata["pinned"] != .bool(true) {
                    let kind: String? = if case .string(let value)? = metadata["kind"] { value } else { nil }
                    if let refusal = UserMDGenerator.pinFailure(kind: kind) {
                        throw refusal
                    }
                    let last = try Int64.fetchOne(db, sql: """
                        SELECT MAX(CAST(json_extract(metadata_json, '$.pinned_order') AS INTEGER)) FROM memories
                    """) ?? 0
                    let (next, overflow) = last.addingReportingOverflow(1)
                    guard !overflow else { throw MemoryStorageError.pinOrderExhausted }
                    metadata["pinned_order"] = .int(next)
                }
                for (key, value) in merge { metadata[key] = value }
                existing.metadata = .object(metadata)
            }
            // A content edit keeps the writer's named date; words cannot move it.
            existing.metadata = try MemorySenseProvenance.preserving(existing: priorMetadata, incoming: existing.metadata)
            let priorRoots = try MemoryRoot.roots(in: priorMetadata)
            let roots = try Self.rewrittenRoots(prior: priorRoots, patch: patch, contentChanged: contentChanged, context: context)
            existing.metadata = MemoryRoot.setting(roots, in: existing.metadata)
            if patch.restating != nil, roots != priorRoots, let first = MemoryRoot.firstKnown(roots)?.at {
                // A restatement that changes the roots moves the memory's truth start and observation to when the agent first knew it.
                existing.validFrom = first
                existing.observedAt = first
            }
            let provenance = MemorySenseProvenance.merging(existing: existing.metadata, incoming: turnProvenance)
            if !provenance.isEmpty {
                var metadata: [String: JSONValue] = [:]
                if case .object(let current)? = existing.metadata { metadata = current }
                metadata.merge(provenance) { _, incoming in incoming }
                existing.metadata = .object(metadata)
            }
            if owesVector {
                // Changed words invalidate their old vector; retain this row's identity while owing new-vector admission.
                existing.embedding = nil
                existing.embeddingEpoch = nil
                existing.metadata = Self.owingAdmission(existing.metadata, preservingID: true)
            }
            var demoted: [StoredMemory] = []
            let admittingOwedVector = existing.status == "active" && existing.embedding != nil
                && Self.metadataFlag(priorMetadata, Self.pendingAdmissionKey)
            if Self.unchanged(prior, existing) { return (prior, false, []) }
            if patch.content != nil || patch.embedding != nil || admittingOwedVector {
                try Self.requireNotTombstoned(existing, in: db)
            }
            if admittingOwedVector {
                // Available vectors must pass landing checks before an active pending row becomes visible.
                demoted = try Self.owedSupersessions(priorMetadata).map { try Self.demoteSuperseded($0, by: &existing, in: db) }
                if case .object(var metadata)? = existing.metadata {
                    for key in [Self.pendingAdmissionKey, Self.preservesIDKey, Self.pendingSupersedesKey] { metadata[key] = nil }
                    existing.metadata = .object(metadata)
                }
            }
            existing.updatedAt = Self.nowISO8601()
            try Self.validateTemporalEvidence(existing)
            try Self.requireWritableEpoch(
                in: db,
                vector: patch.embedding,
                epoch: patch.embeddingEpoch
            )
            try db.execute(sql: """
                UPDATE memories SET
                  content = ?, source = ?, confidence = ?,
                  updated_at = ?, embedding = ?, embedding_epoch = ?, status = ?, lifecycle = ?,
                  valid_from = ?, valid_to = ?, observed_at = ?, evidence_json = ?, metadata_json = ?
                WHERE id = ?
            """, arguments: [
                existing.content, existing.source, existing.confidence,
                existing.updatedAt,
                Self.encodeEmbedding(existing.embedding),
                existing.embeddingEpoch,
                existing.status,
                existing.lifecycle,
                existing.validFrom,
                existing.validTo,
                existing.observedAt,
                Self.encodeMetadata(existing.evidence),
                Self.encodeMetadata(existing.metadata),
                existing.id
            ])
            return (try Row.fetchOne(db, sql: "SELECT * FROM memories WHERE id = ?", arguments: [existing.id]).map(Self.decodeMemory),
                    true, demoted)
        }
        guard let updated else { return nil }
        guard changed else { return (updated, false) }
        for u in [updated] + demoted {
            invalidateRecallCache()
            pokeUserMDRegen(persona: u.personaId)
            await pokeProjectionHooks(u)
        }
        return (updated, true)
    }

    /// Restatements retain every carried root; an untrusted turn retains every held root.
    /// A telling matching a held root keeps its attribution and instant. Other tellings use this write's attested provenance.
    /// Changed words add the writer's root; other edits retain their roots.
    static func rewrittenRoots(prior held: [MemoryRoot], patch: MemoryPatch, contentChanged: Bool,
                               context: MemoryWriteContext) throws -> [MemoryRoot] {
        var roots = held
        if let restating = patch.restating {
            let restated = restating.map { telling in held.first { Self.restates(telling, $0) } ?? context.rooting(telling) }
            let turnSteered = !MemoryDataProvenance.steering(context.through).isEmpty
            let kept = turnSteered ? held : held.filter { !$0.through.isEmpty }
            roots = MemoryRoot.union([kept, restated])
        }
        guard contentChanged else { return roots }
        return MemoryRoot.union([roots, [try context.root()]])
    }

    /// A telling names this held root: the same how and by, and no since or the same instant as its time.
    static func restates(_ telling: MemoryRoot.Telling, _ root: MemoryRoot) -> Bool {
        guard telling.how == root.how, telling.by?.lowercased() == root.by?.lowercased() else { return false }
        guard let since = telling.since else { return true }
        return root.date.map { abs($0.timeIntervalSince(since)) < 0.001 } ?? false
    }

    /// The row an edit would write is the row already stored: same words, standing, times, evidence, metadata and vector state.
    static func unchanged(_ prior: StoredMemory, _ next: StoredMemory) -> Bool {
        prior.content == next.content && prior.source == next.source && prior.confidence == next.confidence
            && prior.status == next.status && prior.lifecycle == next.lifecycle && prior.validFrom == next.validFrom
            && prior.validTo == next.validTo && prior.observedAt == next.observedAt && prior.evidence == next.evidence
            && prior.metadata == next.metadata && prior.embeddingEpoch == next.embeddingEpoch
            && (prior.embedding == nil) == (next.embedding == nil)
    }

    @discardableResult
    public func deleteMemory(id: String) async throws -> Bool {
        // Read before deletion so projection hooks retain the actual persona and content.
        let result: (deleted: Bool, row: StoredMemory?) = try await dbPool.write { db in
            let row = try Row.fetchOne(db, sql: "SELECT * FROM memories WHERE id = ?", arguments: [id]).map(Self.decodeMemory)
            try db.execute(sql: "DELETE FROM memories WHERE id = ?", arguments: [id])
            let deleted = db.changesCount > 0
            if deleted, let row {
                // Preserve the deleted memory's embedding so the tombstone blocks paraphrases.
                try Self.upsertTombstone(
                    db: db, content: row.content, reason: "deleted_memory",
                    embedding: row.embedding,
                    embeddingEpoch: row.embeddingEpoch
                )
            }
            return (deleted, row)
        }
        if result.deleted, let row = result.row {
            invalidateRecallCache()
            pokeUserMDRegen(persona: row.personaId)
            pokeSpotlight(row)
            pokeKnowledgeGraph(row.id)
            await pokeDerivedState(row, deleted: true)
        }
        return result.deleted
    }

    /// Keep graduated lessons visible as Memories-page history, outside active recall.
    public func listMemories(
        persona: String? = nil,
        status: String? = "active",
        limit: Int? = nil,
        keepingGraduated: Bool = false,
        pinnedOnly: Bool = false
    ) async throws -> [StoredMemory] {
        try await dbPool.read { db in
            var sql = "SELECT * FROM memories WHERE 1=1"
            var args: [DatabaseValueConvertible] = []
            if let persona { sql += " AND persona_id = ?"; args.append(persona) }
            if let status { sql += " AND status = ?"; args.append(status) }
            if status == "active" {
                sql += " AND (lifecycle NOT IN \(MemoryLifecycle.recallExcludedSQL)"
                    + (keepingGraduated ? " OR lifecycle = '\(MemoryLifecycle.graduated)')" : ")")
            }
            if pinnedOnly { sql += " AND json_extract(metadata_json, '$.pinned') = 1" }
            sql += " ORDER BY created_at DESC"
            if let limit { sql += " LIMIT ?"; args.append(limit) }
            let rows = try Row.fetchAll(db, sql: sql, arguments: StatementArguments(args))
            return try rows.map(Self.decodeMemory)
        }
    }

    /// Archived, corrected and graduated rows remain available for recovery.
    public static func isRecoverable(_ record: MemoryRecord) -> Bool {
        let lifecycle = MemoryLifecycle.normalized(record.lifecycle)
        return lifecycle == MemoryLifecycle.corrected || lifecycle == MemoryLifecycle.graduated
            || (record.status == "archived" && MemoryLifecycle.isRecallEligible(lifecycle))
    }

    /// Check disclosure over small ordered projections; decode full rows only for this page, within the same SQLite read transaction.
    public func curationPage(
        archived: Bool, kind: String?, surface: String, persona: String?, newestFirst: Bool,
        afterKey: (String, String)?, offset: Int, limit: Int
    ) async throws -> (records: [MemoryRecord], total: Int, nextOffset: Int) {
        try await dbPool.read { db in
            let direction = newestFirst ? "DESC" : "ASC"
            let order = "created_at COLLATE memory_curation_order \(direction), id COLLATE memory_curation_order \(direction)"
            let cursor = try Row.fetchCursor(db, sql: """
                SELECT id, persona_id, created_at, status, lifecycle, metadata_json, valid_to
                FROM memories ORDER BY \(order)
                """)
            var ids: [String] = []
            var total = 0
            var start = afterKey == nil ? offset : 0
            while let row = try cursor.next() {
                let stored = try StoredMemory(
                    id: row.decode(forColumn: "id"), content: "",
                    personaId: row.decode(forColumn: "persona_id"),
                    createdAt: row.decode(forColumn: "created_at"),
                    status: row.decode(forColumn: "status"),
                    lifecycle: row.decode(forColumn: "lifecycle") ?? MemoryLifecycle.confirmed,
                    validTo: row.decode(forColumn: "valid_to"),
                    metadata: Self.decodeMetadata(row.decode(forColumn: "metadata_json"))
                )
                try Self.validateTemporalEvidence(stored)
                let record = MemoryRecord(stored: stored)
                guard archived ? Self.isRecoverable(record)
                    : record.status == "active" && MemoryLifecycle.isRecallEligible(record.lifecycle)
                        && !Self.metadataFlag(record.extras, Self.pendingAdmissionKey)
                        && MemoryRecordDisclosurePolicy.isTemporallyEligible(validTo: record.validTo, at: Date()),
                    kind == nil || record.memoryKind == kind,
                    MemoryRecordDisclosurePolicy.classify(
                        personaID: record.personaId, status: archived ? "active" : record.status,
                        lifecycle: archived ? nil : record.lifecycle, tags: record.tags, metadata: record.extras
                    )?.permits(surface: surface, personaID: persona) == true else { continue }
                let index = total
                total += 1
                if let key = afterKey,
                   newestFirst ? (record.createdAt, record.id) >= key : (record.createdAt, record.id) <= key {
                    start += 1
                    continue
                }
                if index >= start, ids.count < limit { ids.append(record.id) }
            }
            let records = try ids.isEmpty ? [] : Row.fetchAll(db,
                sql: "SELECT * FROM memories WHERE id IN (\(ids.map { _ in "?" }.joined(separator: ","))) ORDER BY \(order)",
                arguments: StatementArguments(ids)
            ).map(Self.decodeMemory).map(MemoryRecord.init(stored:))
            return (records, total, start + records.count)
        }
    }

    /// Share lifecycle and JSON boolean pin semantics in scalar counts.
    public func statusCounts() async throws -> (memories: Int, active: Int, pinned: Int, pendingProposals: Int) {
        try await dbPool.read { db in
            guard let row = try Row.fetchOne(db, sql: """
                SELECT COUNT(*) AS memories,
                    COUNT(CASE WHEN status = 'active'
                        AND lifecycle NOT IN \(MemoryLifecycle.recallExcludedSQL) THEN 1 END) AS active,
                    COUNT(CASE WHEN json_type(metadata_json, '$.pinned') = 'true' THEN 1 END) AS pinned,
                    (SELECT COUNT(*) FROM proposals WHERE status = 'pending') AS pending
                FROM memories
                """) else { throw MemoryStorageError.databaseUnavailable("Memory status aggregate is missing") }
            return (row["memories"], row["active"], row["pinned"], row["pending"])
        }
    }

    /// Atomically increment use_count and stamp last_used_at for returned recall hits. Usage is access, not content: updated_at and recall_generation stay
    /// unchanged.
    public func recordRecallHits(ids: [String], at when: String = MemoryStorage.nowISO8601()) async throws {
        guard !ids.isEmpty else { return }
        try await dbPool.write { db in
            let placeholders = Array(repeating: "?", count: ids.count).joined(separator: ", ")
            if let id = try String.fetchOne(db, sql:
                "SELECT id FROM memories WHERE id IN (\(placeholders)) AND (typeof(use_count) != 'integer' OR use_count = ?) LIMIT 1",
                arguments: StatementArguments(ids.map { $0.databaseValue } + [Int64.max.databaseValue])) {
                throw MemoryStorageError.databaseUnavailable("memories use_count overflow or invalid counter for row \(id)")
            }
            var args: [DatabaseValueConvertible] = [when]
            args.append(contentsOf: ids)
            try db.execute(
                sql: "UPDATE memories SET use_count = use_count + 1, last_used_at = ? WHERE id IN (\(placeholders))",
                arguments: StatementArguments(args)
            )
        }
        // Candidate reuse returns its cached snapshot without refreshing usage columns.
    }

}
