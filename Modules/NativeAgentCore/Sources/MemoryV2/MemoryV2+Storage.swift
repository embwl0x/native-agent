// Canonical memories, proposals, and rejection tombstones in
// <dataRoot>/memory/memory.sqlite, owned by the MemoryStorage actor.

import Foundation
import GRDB
import NativeAgentShared
import NativeAgentCore
import PersistenceCore
// Blueprint: | `MemoryV2+Storage.swift` | `MemoryStorage` actor, shared database pool and canonical mutations; bounded admission and eviction, transactional duplicate/supersession writes, scalar `statusCounts` and checked `curationPage` |

// MARK: - MemoryStorage actor

/// Owns memory.sqlite's schema (including kg_*). Local backup and export take
/// SQLite snapshots, never journal sidecars; PrivacyMap: memory. The phone
/// receives active-memory, proposal and graph projections, never these files.
public actor MemoryStorage {
    // Same-module storage extensions share this pool rather than reopening
    // the database.
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
    /// Ordered projection lanes resolve canonical eligibility when they run.
    /// A hook queued after suspension carries identity, never stale intent.
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
        config.busyMode = .timeout(2)
        // Limit retained WAL size to 4 MB on every pool connection.
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

    /// Delete the least valuable rows until the table satisfies `limit`.
    /// Capacity eviction is forgetting, not rejection, so it intentionally does
    /// not create tombstones. Call only while already holding the canonical
    /// SQLite write transaction.
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
        // Correction and supersession are history, never capacity eviction, and so is a memory
        // a pending replacement will demote once admitted. Refuse admission
        // when retaining them leaves too few disposable rows.
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
        // The row being admitted is never its own eviction: refuse instead,
        // so the caller's transaction rolls back whole.
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

    /// Lower ranks are evicted first. Archived and recall-excluded rows are
    /// disposable before active tissue; temporary/stale facts precede ordinary
    /// confirmed facts; pinned and identity memories are protected until every
    /// other class is exhausted. If protected rows alone exceed the hard cap,
    /// their oldest rows are still evicted so the bound remains real.
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

    /// Duplicate matching and evidence accumulation share the insertion write
    /// transaction, so simultaneous stores cannot lose counts or provenance.
    public func admitMemory(
        _ memory: StoredMemory, insertIfMissing: Bool, preserveID: Bool,
        superseding: [SupersedingAcceptance] = []
    ) async throws -> StoredMemory? {
        var stamped = memory
        stamped.metadata = try MemorySenseProvenance.stamping(stamped.metadata)
        let memory = stamped
        let result = try await dbPool.write { db -> (StoredMemory?, [StoredMemory], [StoredMemory]) in
            try Self.requireNotTombstoned(memory, in: db)
            let rows = try Row.fetchAll(db, sql: """
                SELECT * FROM memories WHERE status = 'active'
                    AND lifecycle NOT IN \(MemoryLifecycle.recallExcludedSQL)
                    AND (? = 0 OR id = ?)
                ORDER BY rowid
            """, arguments: [preserveID, memory.id]).map(Self.decodeMemory)
            if let row = try Self.admissionDuplicate(of: memory, among: rows, in: db) {
                let saved = try Self.foldDuplicate(memory, into: row, in: db)
                let demoted = try superseding.filter { $0.targetId != saved.id }
                    .map { try Self.demoteSuperseded($0, by: saved, in: db) }
                return (saved, [], demoted)
            }
            guard insertIfMissing else { return (nil, [], []) }
            try Self.validateTemporalEvidence(memory)
            try Self.requireWritableEpoch(in: db, vector: memory.embedding, epoch: memory.embeddingEpoch)
            try Self.executeMemoryInsert(memory, in: db)
            let demoted = try superseding.map { try Self.demoteSuperseded($0, by: memory, in: db) }
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

    /// Admission's duplicate rule, shared by a warm write and an owed vector
    /// landing: the same text in the same scope, or (with a vector) a recent
    /// near-paraphrase in the same scope that is not a correction.
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

    /// Marks a vector-less row written with a caller-owned id until it lands.
    static let preservesIDKey = "admission_preserves_id"
    /// A cold write is saved but not admitted until its vector lands and
    /// passes the checks; a turn withholds it until then.
    public static let pendingAdmissionKey = "admission_pending"
    /// What a cold replacement demotes once admitted; until then those stay as they are.
    static let pendingSupersedesKey = "admission_supersedes"

    static func owingAdmission(_ metadata: JSONValue?, preservingID: Bool,
                               superseding: [SupersedingAcceptance] = []) -> JSONValue {
        var object: [String: JSONValue] = [:]
        if case .object(let current)? = metadata { object = current }
        object[pendingAdmissionKey] = .bool(true)
        if preservingID { object[preservesIDKey] = .bool(true) }
        if !superseding.isEmpty {
            object[pendingSupersedesKey] = .array(superseding.map {
                .object(["id": .string($0.targetId), "hash": .string($0.expectedContentHash), "reason": .string($0.reason)])
            })
        }
        return .object(object)
    }

    public static func owedSupersessions(_ metadata: JSONValue?) -> [SupersedingAcceptance] {
        guard case .object(let object)? = metadata, case .array(let rows)? = object[pendingSupersedesKey] else { return [] }
        return rows.compactMap { row in
            guard case .object(let fields) = row, case .string(let id)? = fields["id"],
                  case .string(let hash)? = fields["hash"], case .string(let reason)? = fields["reason"] else { return nil }
            return SupersedingAcceptance(targetId: id, expectedContentHash: hash, reason: reason)
        }
    }

    public static func metadataFlag(_ metadata: JSONValue?, _ key: String) -> Bool {
        if case .object(let object)? = metadata, object[key] == .bool(true) { return true }
        return false
    }

    /// The incoming write becomes evidence on the row it duplicates. An owed
    /// row folding late also carries its own lineage and occurrences across.
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
        // Explicit scope replaces scope only on the same text, never
        // on a merely similar record. Omission retains the old scope.
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
        row.metadata = MemoryDataProvenance.preserving(
            existing: memory.metadata, incoming: .object(metadata))
        row.updatedAt = Self.nowISO8601()
        try Self.validateTemporalEvidence(row)
        try db.execute(sql: """
            UPDATE memories SET metadata_json = ?, observed_at = ?, updated_at = ? WHERE id = ?
        """, arguments: [Self.encodeMetadata(row.metadata), row.observedAt, row.updatedAt, row.id])
        guard let saved = try Row.fetchOne(db, sql: "SELECT * FROM memories WHERE id = ?", arguments: [row.id]).map(Self.decodeMemory) else {
            throw MemoryStorageError.databaseUnavailable("committed memory is missing")
        }
        return saved
    }

    @discardableResult
    public func insertMemory(
        _ memory: StoredMemory,
        superseding: [SupersedingAcceptance] = []
    ) async throws -> StoredMemory {
        var stamped = memory
        stamped.metadata = try MemorySenseProvenance.stamping(stamped.metadata)
        let memory = stamped
        let (saved, demoted, evicted) = try await dbPool.write { db -> (StoredMemory, [StoredMemory], [StoredMemory]) in
            try Self.requireNotTombstoned(memory, in: db)
            try Self.validateTemporalEvidence(memory)
            try Self.requireWritableEpoch(
                in: db,
                vector: memory.embedding,
                epoch: memory.embeddingEpoch
            )
            try Self.executeMemoryInsert(memory, in: db)
            let demoted = try superseding.map { try Self.demoteSuperseded($0, by: memory, in: db) }
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

    /// Runs inside the caller's write transaction.
    static func executeMemoryInsert(_ memory: StoredMemory, in db: Database) throws {
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
    }

    /// Active rows whose vector is owed, oldest first.
    public func memoriesOwingVectors(limit: Int) async throws -> [(id: String, content: String)] {
        try await dbPool.read { db in
            try Row.fetchAll(db, sql: """
                SELECT id, content FROM memories
                WHERE embedding IS NULL AND status = 'active' AND TRIM(COALESCE(content, '')) <> ''
                ORDER BY rowid LIMIT ?
                """, arguments: [max(1, limit)]).map { ($0["id"], $0["content"]) }
        }
    }

    enum OwedVectorLanding { case landed, archived(reason: String), superseded }

    /// An owed vector lands through the same checks a warm write passes, in
    /// one transaction on the row's exact words (a newer write always wins):
    /// a paraphrase of a rejected claim, or a duplicate admission would have
    /// collapsed, is archived with its reason in the row instead of landing.
    func landOwedVector(id: String, content: String, vector: [Float],
                        epoch: MemoryEmbeddingEpoch) async throws -> OwedVectorLanding {
        let (outcome, changed) = try await dbPool.write { db -> (OwedVectorLanding, [StoredMemory]) in
            guard var owed = try Row.fetchOne(db, sql: """
                SELECT * FROM memories WHERE id = ? AND embedding IS NULL AND content = ? AND status = 'active'
                """, arguments: [id, content]).map(Self.decodeMemory) else { return (.superseded, []) }
            try Self.requireWritableEpoch(in: db, vector: vector, epoch: epoch.rawValue)
            owed.embedding = vector
            owed.embeddingEpoch = epoch.rawValue
            var reason: String?
            var folded: StoredMemory?
            var demoted: [StoredMemory] = []
            // A caller-owned id (one lesson origin per proposal) is admitted
            // as itself, never folded into another row, as its warm write was.
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
            // An admitted replacement demotes what it replaces now, all or none,
            // as its warm write would have; one that changed or left meanwhile
            // refuses it, as a warm write is refused.
            let supersessions = Self.owedSupersessions(owed.metadata)
            if reason == nil || folded != nil, !supersessions.isEmpty {
                let replacement = folded ?? owed
                do {
                    try db.inSavepoint {
                        demoted = try supersessions.filter { $0.targetId != replacement.id }
                            .map { try Self.demoteSuperseded($0, by: replacement, in: db) }
                        return .commit
                    }
                } catch {
                    reason = "a memory it was to replace changed or left before its owed vector landed: \(error)"
                }
            }
            guard let reason else {
                try db.execute(sql: """
                    UPDATE memories SET embedding = ?, embedding_epoch = ?,
                        metadata_json = json_remove(metadata_json, '$.\(Self.preservesIDKey)', '$.\(Self.pendingAdmissionKey)',
                            '$.\(Self.pendingSupersedesKey)')
                    WHERE id = ?
                    """, arguments: [Self.encodeEmbedding(vector), epoch.rawValue, id])
                // Admitted now: the projections that withheld it publish it.
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
        invalidateRecallCache()
        for row in changed {
            pokeUserMDRegen(persona: row.personaId)
            await pokeProjectionHooks(row)
        }
        return outcome
    }

    /// One primary-key lookup of exactly these rows, unfiltered.
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

    /// A conditional edit skips a row whose approved original has changed.
    public func updateMemory(
        id: String, patch: MemoryPatch, expectedContent: String? = nil,
        onlyIf: (@Sendable (StoredMemory) -> Bool)? = nil
    ) async throws -> StoredMemory? {
        let turnProvenance = try MemorySenseProvenance.stamping(nil)
        let turnDataProvenance = MemoryDataProvenance.stamping(nil)
        let (updated, demoted) = try await dbPool.write { db -> (StoredMemory?, [StoredMemory]) in
            guard var existing = try Row.fetchOne(db, sql: "SELECT * FROM memories WHERE id = ?", arguments: [id]).map(Self.decodeMemory) else {
                return (nil, [])
            }
            if let expectedContent, existing.content != expectedContent { return (nil, []) }
            if let onlyIf, !onlyIf(existing) { return (nil, []) }
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
            // Reactivating a record reopens its truth interval. Correction
            // lineage stays in metadata; a closed interval cannot stay current.
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
            existing.metadata = MemoryDataProvenance.preserving(existing: priorMetadata, incoming: existing.metadata)
            existing.metadata = MemoryDataProvenance.preserving(existing: turnDataProvenance, incoming: existing.metadata)
            let provenance = MemorySenseProvenance.merging(existing: existing.metadata, incoming: turnProvenance)
            if !provenance.isEmpty {
                var metadata: [String: JSONValue] = [:]
                if case .object(let current)? = existing.metadata { metadata = current }
                metadata.merge(provenance) { _, incoming in incoming }
                existing.metadata = .object(metadata)
            }
            if owesVector {
                // New words without a vector owe one (the old vector described
                // the old words) and wait for admission as a cold insert does,
                // under this row's own id.
                existing.embedding = nil
                existing.embeddingEpoch = nil
                existing.metadata = Self.owingAdmission(existing.metadata, preservingID: true)
            }
            var demoted: [StoredMemory] = []
            let admittingOwedVector = existing.status == "active" && existing.embedding != nil
                && Self.metadataFlag(priorMetadata, Self.pendingAdmissionKey)
            if patch.content != nil || patch.embedding != nil || admittingOwedVector {
                try Self.requireNotTombstoned(existing, in: db)
            }
            if admittingOwedVector {
                // An active row awaiting admission that now has its vector is
                // admitted here, with its landing's checks, so it never stays withheld.
                demoted = try Self.owedSupersessions(priorMetadata).map { try Self.demoteSuperseded($0, by: existing, in: db) }
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
                    demoted)
        }
        for u in [updated].compactMap({ $0 }) + demoted {
            invalidateRecallCache()
            pokeUserMDRegen(persona: u.personaId)
            await pokeProjectionHooks(u)
        }
        return updated
    }

    @discardableResult
    public func deleteMemory(id: String) async throws -> Bool {
        // Fetch the row first so the Spotlight + USER.md hooks can fire
        // with the actual persona/content even after deletion.
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

    /// `keepingGraduated`: the Memories page keeps a graduated lesson in view
    /// as history; every other "active" read is recall's and leaves it out.
    public func listMemories(
        persona: String? = nil,
        status: String? = "active",
        limit: Int? = nil,
        keepingGraduated: Bool = false
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

    /// Check disclosure over small ordered projections; decode full rows only
    /// for this page, within the same SQLite read transaction.
    public func curationPage(
        archived: Bool, kind: String?, surface: String, persona: String?, newestFirst: Bool,
        afterKey: (String, String)?, afterID: String?, offset: Int, limit: Int
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
            var foundAfterID = false
            while let row = try cursor.next() {
                let record = MemoryRecord(stored: try StoredMemory(
                    id: row.decode(forColumn: "id"), content: "",
                    personaId: row.decode(forColumn: "persona_id"),
                    createdAt: row.decode(forColumn: "created_at"),
                    status: row.decode(forColumn: "status"),
                    lifecycle: row.decode(forColumn: "lifecycle") ?? MemoryLifecycle.confirmed,
                    validTo: row.decode(forColumn: "valid_to"),
                    metadata: Self.decodeMetadata(row.decode(forColumn: "metadata_json"))
                ))
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
                if afterKey == nil, !foundAfterID, record.id == afterID {
                    foundAfterID = true
                    start = total
                    ids.removeAll()
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

    /// Scalar status counts keep lifecycle and JSON boolean pin semantics.
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

    /// Atomically increment use_count and stamp last_used_at for returned recall hits.
    /// Usage is access, not content: updated_at and recall_generation stay unchanged.
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
