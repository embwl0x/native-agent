// Canonical memories, proposals, and rejection tombstones in
// <dataRoot>/memory/memory.sqlite, owned by the MemoryStorage actor.

import Foundation
import GRDB
import NativeAgentCore
import PersistenceCore

// MARK: - MemoryStorage actor

public actor MemoryStorage {
    // Same-module storage extensions share this pool rather than reopening
    // the database.
    let dbPool: DatabasePool
    public let path: URL
    let memoryLimit: Int
    private var startupBoundEvictions: [StoredMemory]
    private var replayedStartupUserProjection = false
    private var replayedStartupSpotlightProjection = false
    private var replayedStartupKnowledgeGraphProjection = false
    private var userMDGenerator: UserMDGenerator?
    private var spotlightHook: (@Sendable (StoredMemory, Bool) async -> Void)?
    private var knowledgeGraphHook: (@Sendable (StoredMemory, Bool) async -> Void)?
    /// Ordered, bounded projection lanes. Canonical SQLite mutations enter this
    /// actor in order; each lane preserves that order across asynchronous index
    /// I/O so a late update cannot land after a newer delete and resurrect it.
    private var spotlightProjectionTail: Task<Void, Never>?
    private var knowledgeGraphProjectionTail: Task<Void, Never>?

    // MARK: - Recall candidate cache
    // Recall and nearest-neighbor queries share decoded active embeddings and
    // precomputed norms. Reuse requires both the in-actor mutation generation
    // and SQLite data_version to match. The latter detects writes by other
    // connections, including the consolidation table swap.
    //
    // data_version is comparable only on the SAME connection. This dedicated
    // queue keeps the sequence stable across pool reads. Counter-only writes
    // use this connection: SQLite does not change its own data_version, while
    // ALL other connections' commits remain visible to the version net.
    let versionProbe: DatabaseQueue
    var recallCache: RecallCache?
    var recallGeneration: Int = 0
    /// Test-only observability (internal, reached via @testable): how many
    /// times the candidate cache was (re)built from SQL. A cache hit does NOT bump it.
    var recallCacheRebuildCount: Int = 0

    /// Attach a USER.md generator so mutations debounce-regenerate the file.
    public func attachUserMDGenerator(_ generator: UserMDGenerator) {
        self.userMDGenerator = generator
        if !replayedStartupUserProjection {
            replayedStartupUserProjection = true
            for persona in Set(startupBoundEvictions.map(\.personaId)) {
                pokeUserMDRegen(persona: persona)
            }
        }
    }

    /// Install a Spotlight-index hook. Fires for every insert/update/
    /// acceptProposal/archive/delete with `deleted` derived from final row
    /// projection eligibility.
    public func attachSpotlightHook(
        _ hook: @escaping @Sendable (StoredMemory, Bool) async -> Void
    ) {
        self.spotlightHook = hook
        if !replayedStartupSpotlightProjection {
            replayedStartupSpotlightProjection = true
            for evicted in startupBoundEvictions { pokeSpotlight(evicted, deleted: true) }
        }
    }

    /// Install a Knowledge Graph indexing hook. Fires for every insert/update/
    /// acceptProposal/archive/delete with `deleted` derived from final row
    /// projection eligibility.
    public func attachKnowledgeGraphHook(
        _ hook: @escaping @Sendable (StoredMemory, Bool) async -> Void
    ) {
        self.knowledgeGraphHook = hook
        if !replayedStartupKnowledgeGraphProjection {
            replayedStartupKnowledgeGraphProjection = true
            for evicted in startupBoundEvictions { pokeKnowledgeGraph(evicted, deleted: true) }
        }
    }

    func pokeUserMDRegen(persona: String) {
        guard let gen = userMDGenerator else { return }
        Task { try? await gen.requestRegeneration(persona: persona) }
    }

    private func pokeSpotlight(_ stored: StoredMemory, deleted: Bool) {
        guard let hook = spotlightHook else { return }
        let prior = spotlightProjectionTail
        spotlightProjectionTail = Task {
            await prior?.value
            await hook(stored, deleted)
        }
    }

    private func pokeKnowledgeGraph(_ stored: StoredMemory, deleted: Bool) {
        guard let hook = knowledgeGraphHook else { return }
        let prior = knowledgeGraphProjectionTail
        knowledgeGraphProjectionTail = Task {
            await prior?.value
            await hook(stored, deleted)
        }
    }

    /// Wait through every projection scheduled before this call. New canonical
    /// mutations may enqueue later work while the actor is suspended; those
    /// belong to a later flush boundary.
    func flushProjectionHooks() async {
        let spotlight = spotlightProjectionTail
        let knowledgeGraph = knowledgeGraphProjectionTail
        await spotlight?.value
        await knowledgeGraph?.value
    }

    private func pokeDerivedState(_ stored: StoredMemory, deleted: Bool) async {
        let change = DerivedSourceChange(
            namespace: "memory-v2",
            stableID: stored.id,
            operation: deleted ? .removed : .changed,
            canonicalLocator: path.standardizedFileURL.path,
            reason: deleted ? "memory_projection_removed" : "memory_projection_changed"
        )
        await DerivedStateInvalidationCenter.shared.publish(change)
    }

    private static func projectionEligible(_ stored: StoredMemory) -> Bool {
        stored.status == "active" && MemoryLifecycle.isRecallEligible(stored.lifecycle)
    }

    func pokeProjectionHooks(_ stored: StoredMemory) async {
        let deleted = !Self.projectionEligible(stored)
        pokeSpotlight(stored, deleted: deleted)
        pokeKnowledgeGraph(stored, deleted: deleted)
        await pokeDerivedState(stored, deleted: deleted)
    }

    public init(dataRoot: URL, memoryLimit: Int = memoryStoredRowCap) throws {
        let dir = dataRoot.appendingPathComponent("memory", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let path = dir.appendingPathComponent("memory.sqlite")
        self.path = path
        var config = Configuration()
        config.foreignKeysEnabled = true
        config.busyMode = .timeout(2)
        // Bound the WAL: without a journal_size_limit the -wal file persists
        // at its high-water mark after checkpoints (observed 2026-07-02: 3 MB
        // WAL against a 1.5 MB database). 4 MB never truncates mid-burst at
        // Agent-scale but stops unbounded high-water growth. Set via
        // prepareDatabase so every pool connection carries it.
        config.prepareDatabase { db in
            try db.execute(sql: "PRAGMA journal_size_limit = 4194304")
        }
        let pool = try DatabasePool(path: path.path, configuration: config)
        try Self.adoptLedgerlessGraphStoreIfNeeded(pool)
        try MemoryStorage.migrator.migrate(pool)
        try pool.read { db in
            try Self.requireSemanticIntegrity(in: db)
        }
        let boundedLimit = max(1, memoryLimit)
        let startupEvictions = try pool.write { db in
            try Self.pruneMemoriesToBound(in: db, limit: boundedLimit)
        }
        self.dbPool = pool
        self.memoryLimit = boundedLimit
        self.startupBoundEvictions = startupEvictions
        // Dedicated single connection for the recall-cache data_version net.
        self.versionProbe = try DatabaseQueue(path: path.path, configuration: config)
        Self.publishStartupBoundEvictions(startupEvictions, memoryPath: path)
    }

    /// Ephemeral store for tests.
    public init(
        inMemoryName: String = "MemoryStorage-\(UUID().uuidString)",
        memoryLimit: Int = memoryStoredRowCap
    ) throws {
        let safeName = inMemoryName
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: ":", with: "_")
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(safeName)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let path = dir.appendingPathComponent("memory.sqlite")
        self.path = path
        var config = Configuration()
        config.foreignKeysEnabled = true
        config.busyMode = .timeout(2)
        let pool = try DatabasePool(path: path.path, configuration: config)
        try MemoryStorage.migrator.migrate(pool)
        try pool.read { db in
            try Self.requireSemanticIntegrity(in: db)
        }
        let boundedLimit = max(1, memoryLimit)
        let startupEvictions = try pool.write { db in
            try Self.pruneMemoriesToBound(in: db, limit: boundedLimit)
        }
        self.dbPool = pool
        self.memoryLimit = boundedLimit
        self.startupBoundEvictions = startupEvictions
        // Dedicated single connection for the recall-cache data_version net.
        self.versionProbe = try DatabaseQueue(path: path.path, configuration: config)
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
        let rows = try Row.fetchAll(db, sql: "SELECT * FROM memories").map(Self.decodeMemory)

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
        var evicted = Array(ordered.filter { !preservingIDs.contains($0.id) }.prefix(overflow))
        if evicted.count < overflow {
            let already = Set(evicted.map(\.id))
            evicted += ordered.filter { !already.contains($0.id) }.prefix(overflow - evicted.count)
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

    private static func publishStartupBoundEvictions(
        _ evicted: [StoredMemory],
        memoryPath: URL
    ) {
        guard !evicted.isEmpty else { return }
        NSLog("MemoryV2 bound: pruned %d overflow row(s) while opening %@",
              evicted.count, memoryPath.lastPathComponent)
        Task {
            for memory in evicted {
                await DerivedStateInvalidationCenter.shared.publish(DerivedSourceChange(
                    namespace: "memory-v2",
                    stableID: memory.id,
                    operation: .removed,
                    canonicalLocator: memoryPath.standardizedFileURL.path,
                    reason: "memory_capacity_evicted_on_open"
                ))
            }
            await recordBoundEvictions(evicted, memoryPath: memoryPath, reason: "store_open")
        }
    }

    func handleBoundEvictions(_ evicted: [StoredMemory], reason: String) async {
        guard !evicted.isEmpty else { return }
        invalidateRecallCache()
        for persona in Set(evicted.map(\.personaId)) { pokeUserMDRegen(persona: persona) }
        for memory in evicted {
            pokeSpotlight(memory, deleted: true)
            pokeKnowledgeGraph(memory, deleted: true)
            await pokeDerivedState(memory, deleted: true)
        }
        await Self.recordBoundEvictions(evicted, memoryPath: path, reason: reason)
    }

    static func recordBoundEvictions(
        _ evicted: [StoredMemory],
        memoryPath: URL,
        reason: String
    ) async {
        guard !evicted.isEmpty else { return }
        let receipt: JSONValue = .object([
            "id": .string(UUID().uuidString.lowercased()),
            "kind": .string("memory.capacity_eviction"),
            "reason": .string(reason),
            "count": .int(Int64(evicted.count)),
            "memoryIds": .array(evicted.prefix(100).map { .string($0.id) }),
            "createdAt": .string(nowISO8601()),
        ])
        let receiptPath = memoryPath.deletingLastPathComponent()
            .appendingPathComponent("retention_receipts.jsonl")
        do {
            try await appendJSONLCapped(
                receipt,
                to: receiptPath,
                using: SwiftNativePersistenceCore(),
                maxLines: JSONLLineCaps.memoryRetentionReceipts,
                logLabel: "MemoryV2.retention"
            )
        } catch {
            NSLog("MemoryV2 bound: retention receipt failed: %@", String(describing: error))
        }
    }

    // MARK: - Memory CRUD

    @discardableResult
    public func insertMemory(_ memory: StoredMemory) async throws -> StoredMemory {
        let evicted = try await dbPool.write { db -> [StoredMemory] in
            try Self.validateTemporalEvidence(memory)
            try Self.requireWritableEpoch(
                in: db,
                vector: memory.embedding,
                epoch: memory.embeddingEpoch
            )
            try Self.executeMemoryInsert(memory, in: db)
            return try Self.pruneMemoriesToBound(
                in: db,
                limit: memoryLimit,
                preservingIDs: [memory.id]
            )
        }
        invalidateRecallCache()
        pokeUserMDRegen(persona: memory.personaId)
        await pokeProjectionHooks(memory)
        await handleBoundEvictions(evicted, reason: "insert")
        return memory
    }

    /// The row INSERT, shared by `insertMemory` and `importLegacyMemory` so the
    /// two cannot drift apart. Runs inside the caller's write transaction.
    private static func executeMemoryInsert(_ memory: StoredMemory, in db: Database) throws {
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

    /// What `importLegacyMemory` did with a legacy row.
    public enum LegacyImportOutcome: Sendable {
        case inserted
        /// The canonical row existed but held no content, so it was refreshed
        /// from the legacy source.
        case refreshedEmpty
        /// The canonical row exists and holds content — the live store wins.
        case skippedExisting
    }

    /// Land one legacy memory: insert if absent, refresh only if the canonical
    /// row is empty, otherwise leave the live row alone.
    ///
    /// 2026-09-06: MemoryV2Migrator used to decide this OUTSIDE the write —
    /// check existence, embed, then upsert. Two problems, both fixed here by
    /// making the decision part of the transaction. (a) The gap between the
    /// check and the write is real: the app starts the memory coordinator
    /// before migration runs, so a live writer can land a row that the upsert
    /// then overwrites with legacy text. (b) A bare existence check has no
    /// repair path — a blank or half-written canonical row was never refreshed,
    /// and the one-way completion sentinel made that permanent.
    public func importLegacyMemory(_ memory: StoredMemory) async throws -> LegacyImportOutcome {
        let result = try await dbPool.write { db -> (LegacyImportOutcome, [StoredMemory]) in
            let existing = try Row.fetchOne(
                db,
                sql: "SELECT * FROM memories WHERE id = ?",
                arguments: [memory.id]
            ).map(Self.decodeMemory)
            if let existing {
                guard existing.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    return (.skippedExisting, [])
                }
                try Self.requireWritableEpoch(
                    in: db,
                    vector: memory.embedding,
                    epoch: memory.embeddingEpoch
                )
                try db.execute(sql: """
                    UPDATE memories SET
                      content = ?, source = ?, confidence = ?, updated_at = ?,
                      embedding = ?, embedding_epoch = ?, status = ?, metadata_json = ?
                    WHERE id = ?
                """, arguments: [
                    memory.content, memory.source, memory.confidence, memory.updatedAt,
                    Self.encodeEmbedding(memory.embedding),
                    memory.embeddingEpoch,
                    memory.status,
                    Self.encodeMetadata(memory.metadata),
                    memory.id
                ])
                return (.refreshedEmpty, [])
            }
            try Self.validateTemporalEvidence(memory)
            try Self.requireWritableEpoch(
                in: db,
                vector: memory.embedding,
                epoch: memory.embeddingEpoch
            )
            try Self.executeMemoryInsert(memory, in: db)
            let evicted = try Self.pruneMemoriesToBound(
                in: db,
                limit: memoryLimit,
                preservingIDs: [memory.id]
            )
            return (.inserted, evicted)
        }
        guard result.0 != .skippedExisting else { return result.0 }
        invalidateRecallCache()
        pokeUserMDRegen(persona: memory.personaId)
        await pokeProjectionHooks(memory)
        if !result.1.isEmpty {
            await handleBoundEvictions(result.1, reason: "insert")
        }
        return result.0
    }

    public func memory(id: String) async throws -> StoredMemory? {
        try await dbPool.read { db in
            guard let row = try Row.fetchOne(db, sql: "SELECT * FROM memories WHERE id = ?", arguments: [id]) else {
                return nil
            }
            return try Self.decodeMemory(row)
        }
    }

    public func updateMemory(id: String, patch: MemoryPatch) async throws -> StoredMemory? {
        let updated = try await dbPool.write { db -> StoredMemory? in
            guard var existing = try Row.fetchOne(db, sql: "SELECT * FROM memories WHERE id = ?", arguments: [id]).map(Self.decodeMemory) else {
                return nil
            }
            if let c = patch.content { existing.content = c }
            if let s = patch.source { existing.source = s }
            if let conf = patch.confidence { existing.confidence = conf }
            if let e = patch.embedding { existing.embedding = e }
            if patch.embedding != nil { existing.embeddingEpoch = patch.embeddingEpoch }
            if let st = patch.status { existing.status = st }
            if let lifecycle = patch.lifecycle { existing.lifecycle = MemoryLifecycle.normalized(lifecycle) }
            if let validFrom = patch.validFrom { existing.validFrom = validFrom }
            if let validTo = patch.validTo { existing.validTo = validTo }
            if let observedAt = patch.observedAt { existing.observedAt = observedAt }
            if let evidence = patch.evidence { existing.evidence = evidence }
            if let m = patch.metadata { existing.metadata = m }
            if let merge = patch.metadataMerge, !merge.isEmpty {
                var metadata: [String: JSONValue] = [:]
                if case .object(let current)? = existing.metadata { metadata = current }
                for (key, value) in merge { metadata[key] = value }
                existing.metadata = .object(metadata)
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
            return existing
        }
        if let u = updated {
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
                // Carry the deleted memory's own embedding into the tombstone so
                // the semantic gate can block paraphrased resurrections (wave1 T2).
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
            pokeSpotlight(row, deleted: true)
            pokeKnowledgeGraph(row, deleted: true)
            await pokeDerivedState(row, deleted: true)
        }
        return result.deleted
    }

    public func listMemories(
        persona: String? = nil,
        status: String? = "active",
        limit: Int? = nil
    ) async throws -> [StoredMemory] {
        try await dbPool.read { db in
            var sql = "SELECT * FROM memories WHERE 1=1"
            var args: [DatabaseValueConvertible] = []
            if let persona { sql += " AND persona_id = ?"; args.append(persona) }
            if let status { sql += " AND status = ?"; args.append(status) }
            if status == "active" {
                sql += " AND lifecycle NOT IN ('corrected', 'contradicted', 'deleted')"
            }
            sql += " ORDER BY created_at DESC"
            if let limit { sql += " LIMIT ?"; args.append(limit) }
            let rows = try Row.fetchAll(db, sql: sql, arguments: StatementArguments(args))
            return try rows.map(Self.decodeMemory)
        }
    }

    /// Archive a memory ONLY if it is still active and still has use_count == 0
    /// at write time. Closes the TOCTOU between the consolidator's snapshot
    /// read and its archive write: a recall bump landing in that window must
    /// veto the eviction (gpt-5.5 review finding 1). recall_count needs no
    /// re-check here — it is only mutated by the consolidator itself, which is
    /// single-flighted; use_count is the only concurrent writer.
    /// Returns true when the row was actually archived.
    @discardableResult
    public func archiveIfStillUnused(id: String) async throws -> Bool {
        let archivedRow = try await dbPool.write { db -> StoredMemory? in
            try db.execute(
                sql: """
                    UPDATE memories SET status = 'archived', updated_at = ?
                    WHERE id = ? AND status = 'active' AND use_count = 0
                """,
                arguments: [Self.nowISO8601(), id]
            )
            guard db.changesCount > 0 else { return nil }
            return try Row.fetchOne(db, sql: "SELECT * FROM memories WHERE id = ?", arguments: [id])
                .map(Self.decodeMemory)
        }
        // Same side-effect hooks updateMemory fires — without these the
        // archived memory would stay in Spotlight/KG/USER.md as if active.
        if let row = archivedRow {
            invalidateRecallCache()
            pokeUserMDRegen(persona: row.personaId)
            await pokeProjectionHooks(row)
        }
        return archivedRow != nil
    }

    /// Record that these memories were just returned by recall — bump
    /// `use_count` and stamp `last_used_at`. ONE atomic UPDATE so concurrent
    /// recalls can't lose increments. Called fire-and-forget AFTER recall
    /// returns its hits, so it adds nothing to read latency (Agent's zero-read-
    /// cost constraint). No-op on empty input. Does NOT touch updated_at — a
    /// recall is access, not a content mutation, and bumping updated_at would
    /// corrupt recency ranking and reset the stale-age clock.
    public func recordRecallHits(ids: [String], at when: String = MemoryStorage.nowISO8601()) async throws {
        guard !ids.isEmpty else { return }
        try await versionProbe.write { db in
            let placeholders = Array(repeating: "?", count: ids.count).joined(separator: ", ")
            var args: [DatabaseValueConvertible] = [when]
            args.append(contentsOf: ids)
            try db.execute(
                sql: "UPDATE memories SET use_count = use_count + 1, last_used_at = ? WHERE id IN (\(placeholders))",
                arguments: StatementArguments(args)
            )
        }
        // Recall refreshes these two mutable columns on the same connection
        // as its version check; decoded text/vectors remain reusable.
    }

    /// Wave1 S-lane: archive an older single-valued fact superseded by a newer
    /// one. ARCHIVE, never delete — supersession is demotion, not erasure
    /// (Agent's canon). Provenance {superseded_by, superseded_at} lands in
    /// metadata. Conditional on still-active so a concurrent change vetoes.
    @discardableResult
    public func archiveSuperseded(id: String, by newerId: String) async throws -> Bool {
        let archivedRow = try await dbPool.write { db -> StoredMemory? in
            guard var row = try Row.fetchOne(db, sql: "SELECT * FROM memories WHERE id = ? AND status = 'active'", arguments: [id]).map(Self.decodeMemory) else {
                return nil
            }
            var meta: [String: JSONValue] = [:]
            if case .object(let existing)? = row.metadata { meta = existing }
            meta["superseded_by"] = .string(newerId)
            meta["superseded_at"] = .string(Self.nowISO8601())
            row.metadata = .object(meta)
            row.status = "archived"
            row.updatedAt = Self.nowISO8601()
            try db.execute(sql: """
                UPDATE memories SET status = 'archived', updated_at = ?, metadata_json = ?
                WHERE id = ? AND status = 'active'
            """, arguments: [row.updatedAt, Self.encodeMetadata(row.metadata), id])
            return db.changesCount > 0 ? row : nil
        }
        if let row = archivedRow {
            invalidateRecallCache()
            pokeUserMDRegen(persona: row.personaId)
            await pokeProjectionHooks(row)
        }
        return archivedRow != nil
    }

    /// R13: first-class correction lineage. Marks `id` CORRECTED by `newerId`
    /// in ONE transaction: lifecycle → 'corrected' (recall-excluded via
    /// MemoryLifecycle.recallExcluded), queryable corrected_by/corrected_at
    /// (+ optional reason) in metadata, and an append-only correction_history
    /// entry so repeated corrections keep their full chain. Status is left
    /// untouched — lifecycle is the single source of correction state, and
    /// correction is demotion, not erasure (same canon as supersession).
    /// Conditional on the row being active and not already lifecycle-terminal;
    /// returns false when either endpoint is no longer eligible.
    ///
    /// `supersededBy` rides the SAME transaction for callers (the supersession
    /// lint) whose provenance is a retirement record rather than a replacement
    /// fact. Writing it separately could leave a demoted row with no pointer to
    /// what demoted it, and nothing rereads a corrected row to repair that.
    @discardableResult
    public func markCorrected(
        id: String,
        by newerId: String,
        reason: String? = nil,
        supersededBy: String? = nil
    ) async throws -> Bool {
        // A deduplicated reassertion can resolve to the original record. It
        // must not retire that sole fact or create a self-referential lineage.
        guard id != newerId else { return false }
        let correctedRow = try await dbPool.write { db -> StoredMemory? in
            // The replacement may have changed after store/dedup returned.
            // Check it inside this same transaction so retiring the old fact
            // cannot leave lineage pointing to a missing or retired record.
            guard let replacement = try Row.fetchOne(
                db, sql: "SELECT * FROM memories WHERE id = ?", arguments: [newerId]
            ).map(Self.decodeMemory), Self.projectionEligible(replacement) else {
                return nil
            }
            guard var row = try Row.fetchOne(db, sql: """
                SELECT * FROM memories
                WHERE id = ? AND status = 'active'
                  AND lifecycle NOT IN ('corrected', 'contradicted', 'deleted')
            """, arguments: [id]).map(Self.decodeMemory) else {
                return nil
            }
            let now = Self.nowISO8601()
            var meta: [String: JSONValue] = [:]
            if case .object(let existing)? = row.metadata { meta = existing }
            meta["corrected_by"] = .string(newerId)
            meta["corrected_at"] = .string(now)
            if let reason, !reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                meta["correction_reason"] = .string(reason)
            }
            var history: [JSONValue] = []
            if case .array(let existing)? = meta["correction_history"] { history = existing }
            history.append(.object([
                "by": .string(newerId),
                "at": .string(now),
                "reason": reason.map { JSONValue.string($0) } ?? .null,
            ]))
            meta["correction_history"] = .array(history)
            if let supersededBy { meta["superseded_by"] = .string(supersededBy) }
            row.metadata = .object(meta)
            row.lifecycle = MemoryLifecycle.corrected
            row.updatedAt = now
            try db.execute(sql: """
                UPDATE memories SET lifecycle = ?, updated_at = ?, metadata_json = ?
                WHERE id = ? AND status = 'active'
                  AND lifecycle NOT IN ('corrected', 'contradicted', 'deleted')
            """, arguments: [row.lifecycle, row.updatedAt, Self.encodeMetadata(row.metadata), id])
            return db.changesCount > 0 ? row : nil
        }
        if let row = correctedRow {
            invalidateRecallCache()
            pokeUserMDRegen(persona: row.personaId)
            await pokeProjectionHooks(row)
        }
        return correctedRow != nil
    }
}
