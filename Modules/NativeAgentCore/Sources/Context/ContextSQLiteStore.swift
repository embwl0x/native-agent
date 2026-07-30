import CryptoKit
import Foundation
import GRDB

public struct ContextStoreHealthSnapshot: Sendable, Equatable {
    public let databaseURL: URL
    public let activeGenerationID: Int64?
    public let healthySources: Int
    public let degradedSources: Int
    public let removedSources: Int
    public let activeAtoms: Int

    public init(
        databaseURL: URL,
        activeGenerationID: Int64?,
        healthySources: Int,
        degradedSources: Int,
        removedSources: Int,
        activeAtoms: Int
    ) {
        self.databaseURL = databaseURL
        self.activeGenerationID = activeGenerationID
        self.healthySources = healthySources
        self.degradedSources = degradedSources
        self.removedSources = removedSources
        self.activeAtoms = activeAtoms
    }
}

/// Rebuildable ContextFlow storage. Canonical persona, memory, skill, and
/// project sources remain authoritative; this actor only publishes immutable
/// derived generations.
public actor ContextSQLiteStore {
    public let databaseURL: URL
    private let dbQueue: DatabaseQueue

    public init(dataRoot: URL) throws {
        let directory = dataRoot.appendingPathComponent("context", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try self.init(databaseURL: directory.appendingPathComponent("context.sqlite"))
    }

    public init(databaseURL: URL) throws {
        let directory = databaseURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        self.databaseURL = databaseURL

        var configuration = Configuration()
        configuration.foreignKeysEnabled = true
        configuration.busyMode = .timeout(2)
        configuration.prepareDatabase { db in
            try db.execute(sql: "PRAGMA journal_size_limit = 4194304")
        }
        self.dbQueue = try DatabaseQueue(path: databaseURL.path, configuration: configuration)
        try Self.migrator.migrate(dbQueue)
    }

    // MARK: - Publication

    @discardableResult
    public func publish(_ draft: ContextGenerationDraft) async throws -> ContextGenerationRecord {
        try Self.validate(draft)

        return try await dbQueue.write { db in
            let parentID = try Int64.fetchOne(
                db,
                sql: "SELECT id FROM context_generations WHERE status = 'completed' ORDER BY id DESC LIMIT 1"
            )
            let generationID = (parentID ?? 0) + 1
            let createdAt = draft.createdAt.timeIntervalSince1970
            let reason = Self.bounded(draft.reason, maxUTF8Bytes: 512, fallback: "source_change")

            try db.execute(
                sql: """
                INSERT INTO context_generations (
                    id, parent_id, created_at, reason, source_fingerprint,
                    status, atom_count, source_count
                ) VALUES (?, ?, ?, ?, '', 'staging', 0, 0)
                """,
                arguments: [generationID, parentID, createdAt, reason]
            )

            let affected = Set(draft.changedSources.map(\.descriptor.id)).union(draft.removedSourceIDs)
            for sourceID in affected.sorted() {
                let activeAtomIDs = try String.fetchAll(
                    db,
                    sql: """
                    SELECT atom_id FROM context_atom_versions
                    WHERE source_id = ? AND valid_to_generation IS NULL
                    """,
                    arguments: [sourceID.rawValue]
                )
                for atomID in activeAtomIDs {
                    try db.execute(
                        sql: """
                        UPDATE context_relationship_versions
                        SET valid_to_generation = ?
                        WHERE valid_to_generation IS NULL
                          AND (source_atom_id = ? OR target_atom_id = ?)
                        """,
                        arguments: [generationID - 1, atomID, atomID]
                    )
                }
                try db.execute(
                    sql: """
                    UPDATE context_atom_versions
                    SET valid_to_generation = ?
                    WHERE source_id = ? AND valid_to_generation IS NULL
                    """,
                    arguments: [generationID - 1, sourceID.rawValue]
                )
                try db.execute(
                    sql: """
                    UPDATE context_source_versions
                    SET valid_to_generation = ?
                    WHERE source_id = ? AND valid_to_generation IS NULL
                    """,
                    arguments: [generationID - 1, sourceID.rawValue]
                )
            }

            for sourceID in draft.removedSourceIDs.sorted() {
                try db.execute(
                    sql: """
                    UPDATE context_sources
                    SET health = 'removed', last_error = NULL, updated_at = ?
                    WHERE id = ?
                    """,
                    arguments: [createdAt, sourceID.rawValue]
                )
            }

            for source in draft.changedSources.sorted(by: { $0.descriptor.id < $1.descriptor.id }) {
                let descriptorJSON = try Self.encodeJSON(source.descriptor)
                let surfaceJSON = try Self.encodeJSON(source.descriptor.permittedSurfaces.sorted())
                try db.execute(
                    sql: """
                    INSERT INTO context_sources (
                        id, descriptor_json, owner, kind, canonical_locator,
                        authority, privacy, permitted_surfaces_json,
                        injection_policy, source_hash, health, last_error, updated_at
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 'healthy', NULL, ?)
                    ON CONFLICT(id) DO UPDATE SET
                        descriptor_json = excluded.descriptor_json,
                        owner = excluded.owner,
                        kind = excluded.kind,
                        canonical_locator = excluded.canonical_locator,
                        authority = excluded.authority,
                        privacy = excluded.privacy,
                        permitted_surfaces_json = excluded.permitted_surfaces_json,
                        injection_policy = excluded.injection_policy,
                        source_hash = excluded.source_hash,
                        health = 'healthy',
                        last_error = NULL,
                        updated_at = excluded.updated_at
                    """,
                    arguments: [
                        source.descriptor.id.rawValue,
                        descriptorJSON,
                        source.descriptor.owner,
                        source.descriptor.kind.rawValue,
                        source.descriptor.canonicalLocator,
                        source.descriptor.authority.rawValue,
                        source.descriptor.privacy.rawValue,
                        surfaceJSON,
                        source.descriptor.injectionPolicy.rawValue,
                        source.sourceHash,
                        createdAt,
                    ]
                )

                let sourceVersionKey = Self.versionKey(
                    stableID: source.descriptor.id.rawValue,
                    generationID: generationID
                )
                try db.execute(
                    sql: """
                    INSERT INTO context_source_versions (
                        version_key, source_id, valid_from_generation,
                        valid_to_generation, descriptor_json, source_hash,
                        health, last_error
                    ) VALUES (?, ?, ?, NULL, ?, ?, 'healthy', NULL)
                    """,
                    arguments: [
                        sourceVersionKey,
                        source.descriptor.id.rawValue,
                        generationID,
                        descriptorJSON,
                        source.sourceHash,
                    ]
                )

                for atom in source.atoms.sorted(by: { $0.id < $1.id }) {
                    if let owner: String = try String.fetchOne(
                        db,
                        sql: """
                        SELECT source_id FROM context_atom_versions
                        WHERE atom_id = ? AND valid_to_generation IS NULL
                        LIMIT 1
                        """,
                        arguments: [atom.id.rawValue]
                    ), owner != source.descriptor.id.rawValue {
                        throw ContextFlowStoreError.duplicateAtom(atom.id.rawValue)
                    }

                    let versionKey = Self.versionKey(
                        stableID: atom.id.rawValue,
                        generationID: generationID
                    )
                    let payload = PersistedAtomPayload(atom: atom)
                    let payloadJSON = try Self.encodeJSON(payload)
                    let expiresAt = atom.freshness.expiresAt?.timeIntervalSince1970
                    try db.execute(
                        sql: """
                        INSERT INTO context_atom_versions (
                            version_key, atom_id, source_id,
                            valid_from_generation, valid_to_generation,
                            kind, source_hash, authority, privacy,
                            injection_policy, content_role, expires_at,
                            body, summary, payload_json
                        ) VALUES (?, ?, ?, ?, NULL, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                        """,
                        arguments: [
                            versionKey,
                            atom.id.rawValue,
                            atom.sourceID.rawValue,
                            generationID,
                            atom.kind.rawValue,
                            atom.sourceHash,
                            atom.authority.rawValue,
                            atom.privacy.rawValue,
                            atom.injectionPolicy.rawValue,
                            atom.contentRole.rawValue,
                            expiresAt,
                            atom.body,
                            atom.deterministicSummary,
                            payloadJSON,
                        ]
                    )

                    if let embedding = atom.embedding {
                        try db.execute(
                            sql: """
                            INSERT INTO context_embeddings (
                                atom_version_key, model_fingerprint, dimensions, vector
                            ) VALUES (?, ?, ?, ?)
                            """,
                            arguments: [
                                versionKey,
                                embedding.modelFingerprint,
                                embedding.values.count,
                                Self.encodeVector(embedding.values),
                            ]
                        )
                    }

                    try db.execute(
                        sql: """
                        INSERT INTO context_fts (
                            version_key, body, summary, headings, entities, triggers
                        ) VALUES (?, ?, ?, ?, ?, ?)
                        """,
                        arguments: [
                            versionKey,
                            atom.body,
                            atom.deterministicSummary ?? "",
                            atom.headingPath.joined(separator: " / "),
                            atom.entities.map(\.label).joined(separator: " "),
                            atom.triggers.joined(separator: " "),
                        ]
                    )
                }
            }

            for source in draft.changedSources.sorted(by: { $0.descriptor.id < $1.descriptor.id }) {
                for relationship in source.relationships.sorted(by: { $0.id < $1.id }) {
                    guard try Self.activeAtomExists(relationship.sourceAtomID, db: db) else {
                        throw ContextFlowStoreError.relationshipSourceMissing(
                            relationship.sourceAtomID.rawValue
                        )
                    }
                    guard try Self.activeAtomExists(relationship.targetAtomID, db: db) else {
                        throw ContextFlowStoreError.relationshipTargetMissing(
                            relationship.targetAtomID.rawValue
                        )
                    }
                    let versionKey = Self.versionKey(
                        stableID: relationship.id.rawValue,
                        generationID: generationID
                    )
                    try db.execute(
                        sql: """
                        INSERT INTO context_relationship_versions (
                            version_key, relationship_id, source_atom_id,
                            target_atom_id, kind, weight, provenance,
                            valid_from_generation, valid_to_generation, payload_json
                        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, NULL, ?)
                        """,
                        arguments: [
                            versionKey,
                            relationship.id.rawValue,
                            relationship.sourceAtomID.rawValue,
                            relationship.targetAtomID.rawValue,
                            relationship.kind,
                            relationship.weight,
                            relationship.provenance,
                            generationID,
                            try Self.encodeJSON(relationship),
                        ]
                    )
                }
            }

            let sourceFingerprint = try Self.currentSourceFingerprint(db: db)
            let atomCount = try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM context_atom_versions WHERE valid_to_generation IS NULL"
            ) ?? 0
            let sourceCount = try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM context_sources WHERE health != 'removed'"
            ) ?? 0

            try db.execute(
                sql: """
                UPDATE context_generations
                SET source_fingerprint = ?, status = 'completed',
                    atom_count = ?, source_count = ?
                WHERE id = ?
                """,
                arguments: [sourceFingerprint, atomCount, sourceCount, generationID]
            )
            try db.execute(
                sql: """
                INSERT INTO context_meta (key, value) VALUES ('active_generation', ?)
                ON CONFLICT(key) DO UPDATE SET value = excluded.value
                """,
                arguments: [String(generationID)]
            )

            let receipt = ContextStoreReceipt(
                kind: .compile,
                generationID: generationID,
                summary: "published context generation",
                details: [
                    "changed_sources": String(draft.changedSources.count),
                    "removed_sources": String(draft.removedSourceIDs.count),
                    "atoms": String(atomCount),
                ],
                createdAt: draft.createdAt
            )
            try Self.insertReceipt(receipt, db: db)

            return ContextGenerationRecord(
                id: generationID,
                parentID: parentID,
                createdAt: draft.createdAt,
                reason: reason,
                sourceFingerprint: sourceFingerprint,
                atomCount: atomCount,
                sourceCount: sourceCount
            )
        }
    }

    public func activeGeneration() async throws -> ContextGenerationRecord? {
        try await dbQueue.read { db in
            guard let id = try Int64.fetchOne(
                db,
                sql: "SELECT id FROM context_generations WHERE status = 'completed' ORDER BY id DESC LIMIT 1"
            ) else { return nil }
            return try Self.generation(id: id, db: db)
        }
    }

    public func loadActiveGeneration() async throws -> ContextStoredGeneration? {
        guard let generation = try await activeGeneration() else { return nil }
        return try await loadGeneration(id: generation.id)
    }

    public func loadGeneration(id: Int64) async throws -> ContextStoredGeneration {
        try await dbQueue.read { db in
            guard let generation = try Self.generation(id: id, db: db) else {
                throw ContextFlowStoreError.generationNotFound(id)
            }

            let sourceRows = try Row.fetchAll(
                db,
                sql: """
                SELECT descriptor_json, source_hash, health, last_error,
                       valid_from_generation, valid_to_generation
                FROM context_source_versions
                WHERE valid_from_generation <= ?
                  AND (valid_to_generation IS NULL OR valid_to_generation >= ?)
                  AND health != 'removed'
                ORDER BY source_id ASC
                """,
                arguments: [id, id]
            )
            let sources = try sourceRows.map(Self.decodeSource)

            let atomRows = try Row.fetchAll(
                db,
                sql: """
                SELECT a.version_key, a.atom_id, a.source_id,
                       a.valid_from_generation, a.valid_to_generation,
                       a.body, a.summary, a.payload_json,
                       e.model_fingerprint, e.dimensions, e.vector
                FROM context_atom_versions a
                LEFT JOIN context_embeddings e ON e.atom_version_key = a.version_key
                WHERE a.valid_from_generation <= ?
                  AND (a.valid_to_generation IS NULL OR a.valid_to_generation >= ?)
                ORDER BY a.source_id ASC, a.atom_id ASC
                """,
                arguments: [id, id]
            )
            let atoms = try atomRows.map(Self.decodeAtom)

            let relationshipRows = try Row.fetchAll(
                db,
                sql: """
                SELECT version_key, payload_json, valid_from_generation, valid_to_generation
                FROM context_relationship_versions
                WHERE valid_from_generation <= ?
                  AND (valid_to_generation IS NULL OR valid_to_generation >= ?)
                ORDER BY relationship_id ASC
                """,
                arguments: [id, id]
            )
            let relationships = try relationshipRows.map(Self.decodeRelationship)

            return ContextStoredGeneration(
                generation: generation,
                sources: sources,
                atoms: atoms,
                relationships: relationships
            )
        }
    }

    // MARK: - Health, failures, and receipts

    public func markSourceDegraded(
        _ sourceID: ContextSourceID,
        error: String,
        at date: Date = Date()
    ) async throws {
        let boundedError = Self.bounded(error, maxUTF8Bytes: 2_048, fallback: "compile failed")
        try await dbQueue.write { db in
            try db.execute(
                sql: """
                UPDATE context_sources
                SET health = 'degraded', last_error = ?, updated_at = ?
                WHERE id = ? AND health != 'removed'
                """,
                arguments: [boundedError, date.timeIntervalSince1970, sourceID.rawValue]
            )
            try db.execute(
                sql: """
                INSERT INTO context_compile_failures (source_id, error, created_at)
                VALUES (?, ?, ?)
                """,
                arguments: [sourceID.rawValue, boundedError, date.timeIntervalSince1970]
            )
            try Self.insertReceipt(
                ContextStoreReceipt(
                    kind: .degraded,
                    summary: "context source compile failed",
                    details: ["source_id": sourceID.rawValue, "error": boundedError],
                    createdAt: date
                ),
                db: db
            )
        }
    }

    public func recordReceipt(_ receipt: ContextStoreReceipt) async throws {
        try await dbQueue.write { db in
            try Self.insertReceipt(receipt, db: db)
        }
    }

    public func recentReceipts(limit: Int = 100) async throws -> [ContextStoreReceipt] {
        try await dbQueue.read { db in
            let boundedLimit = max(0, min(limit, 500))
            let rows = try Row.fetchAll(
                db,
                sql: """
                SELECT id, kind, generation_id, summary, details_json, created_at
                FROM context_receipts
                ORDER BY created_at DESC, id ASC
                LIMIT ?
                """,
                arguments: [boundedLimit]
            )
            return try rows.map(Self.decodeReceipt)
        }
    }

    public func healthSnapshot() async throws -> ContextStoreHealthSnapshot {
        try await dbQueue.read { db in
            let activeGenerationID = try Int64.fetchOne(
                db,
                sql: "SELECT id FROM context_generations WHERE status = 'completed' ORDER BY id DESC LIMIT 1"
            )
            let healthy = try Self.countSources(health: .healthy, db: db)
            let degraded = try Self.countSources(health: .degraded, db: db)
            let removed = try Self.countSources(health: .removed, db: db)
            let atoms = try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM context_atom_versions WHERE valid_to_generation IS NULL"
            ) ?? 0
            return ContextStoreHealthSnapshot(
                databaseURL: self.databaseURL,
                activeGenerationID: activeGenerationID,
                healthySources: healthy,
                degradedSources: degraded,
                removedSources: removed,
                activeAtoms: atoms
            )
        }
    }

    // MARK: - Rebuild and retention

    public func resetDerivedState() async throws {
        try await dbQueue.write { db in
            try db.execute(sql: "DELETE FROM context_fts")
            try db.execute(sql: "DELETE FROM context_embeddings")
            try db.execute(sql: "DELETE FROM context_relationship_versions")
            try db.execute(sql: "DELETE FROM context_atom_versions")
            try db.execute(sql: "DELETE FROM context_source_versions")
            try db.execute(sql: "DELETE FROM context_receipts")
            try db.execute(sql: "DELETE FROM context_compile_failures")
            try db.execute(sql: "DELETE FROM context_sources")
            try db.execute(sql: "DELETE FROM context_generations")
            try db.execute(sql: "DELETE FROM context_meta")
        }
    }

    public func prune(
        retainingLatest generationLimit: Int = 8,
        protectedGenerationIDs: Set<Int64> = [],
        receiptLimit: Int = 10_000
    ) async throws -> ContextStorePruneResult {
        try await dbQueue.write { db in
            let activeID = try Int64.fetchOne(
                db,
                sql: "SELECT id FROM context_generations WHERE status = 'completed' ORDER BY id DESC LIMIT 1"
            )
            let latest = try Int64.fetchAll(
                db,
                sql: """
                SELECT id FROM context_generations
                WHERE status = 'completed'
                ORDER BY id DESC LIMIT ?
                """,
                arguments: [max(1, generationLimit)]
            )
            var kept = Set(latest).union(protectedGenerationIDs)
            if let activeID { kept.insert(activeID) }

            let atomRows = try Row.fetchAll(
                db,
                sql: "SELECT version_key, valid_from_generation, valid_to_generation FROM context_atom_versions"
            )
            let deadAtomKeys = atomRows.compactMap { row -> String? in
                guard let key: String = row["version_key"],
                      let start: Int64 = row["valid_from_generation"] else { return nil }
                let end: Int64? = row["valid_to_generation"]
                return Self.interval(start: start, end: end, intersects: kept) ? nil : key
            }
            for key in deadAtomKeys {
                try db.execute(sql: "DELETE FROM context_fts WHERE version_key = ?", arguments: [key])
                try db.execute(sql: "DELETE FROM context_atom_versions WHERE version_key = ?", arguments: [key])
            }

            let deadSourceKeys = try Self.unusedVersionKeys(
                table: "context_source_versions",
                keyColumn: "version_key",
                kept: kept,
                db: db
            )
            for key in deadSourceKeys {
                try db.execute(
                    sql: "DELETE FROM context_source_versions WHERE version_key = ?",
                    arguments: [key]
                )
            }

            let deadRelationshipKeys = try Self.unusedVersionKeys(
                table: "context_relationship_versions",
                keyColumn: "version_key",
                kept: kept,
                db: db
            )
            for key in deadRelationshipKeys {
                try db.execute(
                    sql: "DELETE FROM context_relationship_versions WHERE version_key = ?",
                    arguments: [key]
                )
            }

            let allGenerations = try Int64.fetchAll(
                db,
                sql: "SELECT id FROM context_generations WHERE status = 'completed'"
            )
            let deadGenerations = allGenerations.filter { !kept.contains($0) }
            for id in deadGenerations {
                try db.execute(sql: "DELETE FROM context_generations WHERE id = ?", arguments: [id])
            }

            let boundedReceiptLimit = max(0, receiptLimit)
            let receiptIDs = try String.fetchAll(
                db,
                sql: """
                SELECT id FROM context_receipts
                ORDER BY created_at DESC, id ASC
                LIMIT -1 OFFSET ?
                """,
                arguments: [boundedReceiptLimit]
            )
            for id in receiptIDs {
                try db.execute(sql: "DELETE FROM context_receipts WHERE id = ?", arguments: [id])
            }

            return ContextStorePruneResult(
                deletedGenerations: deadGenerations.count,
                deletedAtomVersions: deadAtomKeys.count,
                deletedSourceVersions: deadSourceKeys.count,
                deletedRelationshipVersions: deadRelationshipKeys.count,
                deletedReceipts: receiptIDs.count
            )
        }
    }

    /// A5.5(b): reclaim the disk that `prune()`'s DELETEs freed. SQLite keeps
    /// deleted rows' pages in the file as a free-list — the file never shrinks
    /// without a VACUUM (or auto_vacuum, which this DB does not set). prune()
    /// bounds the ROW count; this bounds the on-disk FILE size. VACUUM cannot run
    /// inside a transaction, so it goes through `writeWithoutTransaction` (the
    /// regular `write` wrapper opens a transaction). Caller gates the cadence —
    /// VACUUM rewrites the whole file, so it runs far less often than prune.
    public func vacuum() async throws {
        try await dbQueue.writeWithoutTransaction { db in
            try db.execute(sql: "VACUUM")
        }
    }

    // MARK: - Validation

    private static func validate(_ draft: ContextGenerationDraft) throws {
        guard !draft.changedSources.isEmpty || !draft.removedSourceIDs.isEmpty else {
            throw ContextFlowStoreError.emptyGeneration
        }

        var sourceIDs = Set<ContextSourceID>()
        var atomIDs = Set<ContextAtomID>()
        for source in draft.changedSources {
            guard sourceIDs.insert(source.descriptor.id).inserted else {
                throw ContextFlowStoreError.duplicateSource(source.descriptor.id.rawValue)
            }
            if draft.removedSourceIDs.contains(source.descriptor.id) {
                throw ContextFlowStoreError.sourceRemovedAndChanged(source.descriptor.id.rawValue)
            }
            for atom in source.atoms {
                guard atom.sourceID == source.descriptor.id else {
                    throw ContextFlowStoreError.atomSourceMismatch(
                        atomID: atom.id.rawValue,
                        expectedSourceID: source.descriptor.id.rawValue
                    )
                }
                guard atomIDs.insert(atom.id).inserted else {
                    throw ContextFlowStoreError.duplicateAtom(atom.id.rawValue)
                }
            }
            let localAtomIDs = Set(source.atoms.map(\.id))
            for relationship in source.relationships where !localAtomIDs.contains(relationship.sourceAtomID) {
                throw ContextFlowStoreError.relationshipSourceMissing(
                    relationship.sourceAtomID.rawValue
                )
            }
        }
    }

    // MARK: - Migration

    private static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("context_flow_v1") { db in
            try db.execute(sql: """
                CREATE TABLE context_meta (
                    key TEXT PRIMARY KEY,
                    value TEXT NOT NULL
                );

                CREATE TABLE context_generations (
                    id INTEGER PRIMARY KEY,
                    parent_id INTEGER,
                    created_at REAL NOT NULL,
                    reason TEXT NOT NULL,
                    source_fingerprint TEXT NOT NULL,
                    status TEXT NOT NULL CHECK(status IN ('staging', 'completed')),
                    atom_count INTEGER NOT NULL DEFAULT 0,
                    source_count INTEGER NOT NULL DEFAULT 0,
                    FOREIGN KEY(parent_id) REFERENCES context_generations(id) ON DELETE SET NULL
                );
                CREATE INDEX idx_context_generations_created
                    ON context_generations(created_at DESC);

                CREATE TABLE context_sources (
                    id TEXT PRIMARY KEY,
                    descriptor_json TEXT NOT NULL,
                    owner TEXT NOT NULL,
                    kind TEXT NOT NULL,
                    canonical_locator TEXT NOT NULL,
                    authority TEXT NOT NULL,
                    privacy TEXT NOT NULL,
                    permitted_surfaces_json TEXT NOT NULL,
                    injection_policy TEXT NOT NULL,
                    source_hash TEXT NOT NULL,
                    health TEXT NOT NULL CHECK(health IN ('healthy', 'degraded', 'removed')),
                    last_error TEXT,
                    updated_at REAL NOT NULL
                );
                CREATE INDEX idx_context_sources_health ON context_sources(health, kind);

                CREATE TABLE context_source_versions (
                    version_key TEXT PRIMARY KEY,
                    source_id TEXT NOT NULL,
                    valid_from_generation INTEGER NOT NULL,
                    valid_to_generation INTEGER,
                    descriptor_json TEXT NOT NULL,
                    source_hash TEXT NOT NULL,
                    health TEXT NOT NULL,
                    last_error TEXT,
                    FOREIGN KEY(source_id) REFERENCES context_sources(id)
                );
                CREATE INDEX idx_context_source_versions_active
                    ON context_source_versions(source_id, valid_from_generation, valid_to_generation);

                CREATE TABLE context_atom_versions (
                    version_key TEXT PRIMARY KEY,
                    atom_id TEXT NOT NULL,
                    source_id TEXT NOT NULL,
                    valid_from_generation INTEGER NOT NULL,
                    valid_to_generation INTEGER,
                    kind TEXT NOT NULL,
                    source_hash TEXT NOT NULL,
                    authority TEXT NOT NULL,
                    privacy TEXT NOT NULL,
                    injection_policy TEXT NOT NULL,
                    content_role TEXT NOT NULL,
                    expires_at REAL,
                    body TEXT NOT NULL,
                    summary TEXT,
                    payload_json TEXT NOT NULL,
                    FOREIGN KEY(source_id) REFERENCES context_sources(id)
                );
                CREATE INDEX idx_context_atom_versions_active
                    ON context_atom_versions(atom_id, valid_from_generation, valid_to_generation);
                CREATE INDEX idx_context_atom_versions_source
                    ON context_atom_versions(source_id, valid_from_generation, valid_to_generation);
                CREATE INDEX idx_context_atom_versions_eligibility
                    ON context_atom_versions(privacy, injection_policy, expires_at);

                CREATE TABLE context_embeddings (
                    atom_version_key TEXT PRIMARY KEY,
                    model_fingerprint TEXT NOT NULL,
                    dimensions INTEGER NOT NULL,
                    vector BLOB NOT NULL,
                    FOREIGN KEY(atom_version_key) REFERENCES context_atom_versions(version_key)
                        ON DELETE CASCADE
                );

                CREATE TABLE context_relationship_versions (
                    version_key TEXT PRIMARY KEY,
                    relationship_id TEXT NOT NULL,
                    source_atom_id TEXT NOT NULL,
                    target_atom_id TEXT NOT NULL,
                    kind TEXT NOT NULL,
                    weight REAL NOT NULL,
                    provenance TEXT NOT NULL,
                    valid_from_generation INTEGER NOT NULL,
                    valid_to_generation INTEGER,
                    payload_json TEXT NOT NULL
                );
                CREATE INDEX idx_context_relationship_source
                    ON context_relationship_versions(source_atom_id, valid_from_generation, valid_to_generation);
                CREATE INDEX idx_context_relationship_target
                    ON context_relationship_versions(target_atom_id, valid_from_generation, valid_to_generation);

                CREATE TABLE context_conflicts (
                    id TEXT PRIMARY KEY,
                    generation_id INTEGER NOT NULL,
                    status TEXT NOT NULL,
                    payload_json TEXT NOT NULL,
                    created_at REAL NOT NULL,
                    updated_at REAL NOT NULL,
                    FOREIGN KEY(generation_id) REFERENCES context_generations(id) ON DELETE CASCADE
                );

                CREATE TABLE context_receipts (
                    id TEXT PRIMARY KEY,
                    kind TEXT NOT NULL,
                    generation_id INTEGER,
                    summary TEXT NOT NULL,
                    details_json TEXT NOT NULL,
                    created_at REAL NOT NULL,
                    FOREIGN KEY(generation_id) REFERENCES context_generations(id) ON DELETE SET NULL
                );
                CREATE INDEX idx_context_receipts_created
                    ON context_receipts(created_at DESC, kind);

                CREATE TABLE context_compile_failures (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    source_id TEXT NOT NULL,
                    error TEXT NOT NULL,
                    created_at REAL NOT NULL
                );
                CREATE INDEX idx_context_compile_failures_source
                    ON context_compile_failures(source_id, created_at DESC);

                CREATE VIRTUAL TABLE context_fts USING fts5(
                    version_key UNINDEXED,
                    body,
                    summary,
                    headings,
                    entities,
                    triggers,
                    tokenize = 'unicode61'
                );
                """)
        }
        return migrator
    }

    // MARK: - Row encoding

    private struct PersistedAtomPayload: Codable {
        let id: ContextAtomID
        let sourceID: ContextSourceID
        let kind: ContextAtomKind
        let headingPath: [String]
        let sourceRange: ContextSourceRange
        let sourceHash: String
        let authority: ContextAuthority
        let confidence: Double
        let freshness: ContextFreshness
        let privacy: ContextPrivacy
        let permittedSurfaces: Set<ContextSurface>
        let injectionPolicy: ContextInjectionPolicy
        let contentRole: ContextContentRole
        let entities: [ContextEntity]
        let triggers: [String]
        let activation: Double
        let recentUsefulness: Double
        let decayState: Double

        init(atom: ContextAtomDraft) {
            id = atom.id
            sourceID = atom.sourceID
            kind = atom.kind
            headingPath = atom.headingPath
            sourceRange = atom.sourceRange
            sourceHash = atom.sourceHash
            authority = atom.authority
            confidence = atom.confidence
            freshness = atom.freshness
            privacy = atom.privacy
            permittedSurfaces = atom.permittedSurfaces
            injectionPolicy = atom.injectionPolicy
            contentRole = atom.contentRole
            entities = atom.entities
            triggers = atom.triggers
            activation = atom.activation
            recentUsefulness = atom.recentUsefulness
            decayState = atom.decayState
        }
    }

    private static func decodeSource(_ row: Row) throws -> ContextStoredSource {
        guard let descriptorJSON: String = row["descriptor_json"],
              let sourceHash: String = row["source_hash"],
              let healthRaw: String = row["health"],
              let health = ContextSourceHealth(rawValue: healthRaw),
              let validFrom: Int64 = row["valid_from_generation"] else {
            throw ContextFlowStoreError.malformedStoredValue("source")
        }
        let descriptor: ContextSourceDescriptor = try decodeJSON(descriptorJSON)
        let validTo: Int64? = row["valid_to_generation"]
        let lastError: String? = row["last_error"]
        return ContextStoredSource(
            descriptor: descriptor,
            sourceHash: sourceHash,
            health: health,
            lastError: lastError,
            validFromGeneration: validFrom,
            validToGeneration: validTo
        )
    }

    private static func decodeAtom(_ row: Row) throws -> ContextStoredAtom {
        guard let versionKey: String = row["version_key"],
              let body: String = row["body"],
              let payloadJSON: String = row["payload_json"],
              let validFrom: Int64 = row["valid_from_generation"] else {
            throw ContextFlowStoreError.malformedStoredValue("atom")
        }
        let payload: PersistedAtomPayload = try decodeJSON(payloadJSON)
        let summary: String? = row["summary"]
        let validTo: Int64? = row["valid_to_generation"]
        let modelFingerprint: String? = row["model_fingerprint"]
        let dimensions: Int? = row["dimensions"]
        let vectorData: Data? = row["vector"]
        let embedding: ContextEmbedding?
        if let modelFingerprint, let dimensions, let vectorData {
            let values = try decodeVector(vectorData, expectedCount: dimensions)
            embedding = ContextEmbedding(modelFingerprint: modelFingerprint, values: values)
        } else {
            embedding = nil
        }
        let draft = ContextAtomDraft(
            id: payload.id,
            sourceID: payload.sourceID,
            kind: payload.kind,
            headingPath: payload.headingPath,
            sourceRange: payload.sourceRange,
            sourceHash: payload.sourceHash,
            body: body,
            deterministicSummary: summary,
            authority: payload.authority,
            confidence: payload.confidence,
            freshness: payload.freshness,
            privacy: payload.privacy,
            permittedSurfaces: payload.permittedSurfaces,
            injectionPolicy: payload.injectionPolicy,
            contentRole: payload.contentRole,
            entities: payload.entities,
            triggers: payload.triggers,
            activation: payload.activation,
            recentUsefulness: payload.recentUsefulness,
            decayState: payload.decayState,
            embedding: embedding
        )
        return ContextStoredAtom(
            versionKey: versionKey,
            draft: draft,
            validFromGeneration: validFrom,
            validToGeneration: validTo
        )
    }

    private static func decodeRelationship(_ row: Row) throws -> ContextStoredRelationship {
        guard let versionKey: String = row["version_key"],
              let payloadJSON: String = row["payload_json"],
              let validFrom: Int64 = row["valid_from_generation"] else {
            throw ContextFlowStoreError.malformedStoredValue("relationship")
        }
        let draft: ContextRelationshipDraft = try decodeJSON(payloadJSON)
        let validTo: Int64? = row["valid_to_generation"]
        return ContextStoredRelationship(
            versionKey: versionKey,
            draft: draft,
            validFromGeneration: validFrom,
            validToGeneration: validTo
        )
    }

    private static func decodeReceipt(_ row: Row) throws -> ContextStoreReceipt {
        guard let idRaw: String = row["id"],
              let id = UUID(uuidString: idRaw),
              let kindRaw: String = row["kind"],
              let kind = ContextReceiptKind(rawValue: kindRaw),
              let summary: String = row["summary"],
              let detailsJSON: String = row["details_json"],
              let createdAt: Double = row["created_at"] else {
            throw ContextFlowStoreError.malformedStoredValue("receipt")
        }
        let generationID: Int64? = row["generation_id"]
        let details: [String: String] = try decodeJSON(detailsJSON)
        return ContextStoreReceipt(
            id: id,
            kind: kind,
            generationID: generationID,
            summary: summary,
            details: details,
            createdAt: Date(timeIntervalSince1970: createdAt)
        )
    }

    // MARK: - SQL helpers

    private static func generation(id: Int64, db: Database) throws -> ContextGenerationRecord? {
        guard let row = try Row.fetchOne(
            db,
            sql: """
            SELECT id, parent_id, created_at, reason, source_fingerprint,
                   atom_count, source_count
            FROM context_generations
            WHERE id = ? AND status = 'completed'
            """,
            arguments: [id]
        ) else { return nil }
        guard let generationID: Int64 = row["id"],
              let createdAt: Double = row["created_at"],
              let reason: String = row["reason"],
              let fingerprint: String = row["source_fingerprint"],
              let atomCount: Int = row["atom_count"],
              let sourceCount: Int = row["source_count"] else {
            throw ContextFlowStoreError.malformedStoredValue("generation")
        }
        let parentID: Int64? = row["parent_id"]
        return ContextGenerationRecord(
            id: generationID,
            parentID: parentID,
            createdAt: Date(timeIntervalSince1970: createdAt),
            reason: reason,
            sourceFingerprint: fingerprint,
            atomCount: atomCount,
            sourceCount: sourceCount
        )
    }

    private static func activeAtomExists(_ id: ContextAtomID, db: Database) throws -> Bool {
        try Bool.fetchOne(
            db,
            sql: """
            SELECT EXISTS(
                SELECT 1 FROM context_atom_versions
                WHERE atom_id = ? AND valid_to_generation IS NULL
            )
            """,
            arguments: [id.rawValue]
        ) ?? false
    }

    private static func currentSourceFingerprint(db: Database) throws -> String {
        let rows = try Row.fetchAll(
            db,
            sql: """
            SELECT id, source_hash FROM context_sources
            WHERE health != 'removed'
            ORDER BY id ASC
            """
        )
        var hasher = SHA256()
        for row in rows {
            guard let id: String = row["id"], let hash: String = row["source_hash"] else {
                throw ContextFlowStoreError.malformedStoredValue("source_fingerprint")
            }
            hasher.update(data: Data(id.utf8))
            hasher.update(data: Data([0]))
            hasher.update(data: Data(hash.utf8))
            hasher.update(data: Data([10]))
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func countSources(health: ContextSourceHealth, db: Database) throws -> Int {
        try Int.fetchOne(
            db,
            sql: "SELECT COUNT(*) FROM context_sources WHERE health = ?",
            arguments: [health.rawValue]
        ) ?? 0
    }

    private static func insertReceipt(_ receipt: ContextStoreReceipt, db: Database) throws {
        try db.execute(
            sql: """
            INSERT INTO context_receipts (
                id, kind, generation_id, summary, details_json, created_at
            ) VALUES (?, ?, ?, ?, ?, ?)
            """,
            arguments: [
                receipt.id.uuidString,
                receipt.kind.rawValue,
                receipt.generationID,
                bounded(receipt.summary, maxUTF8Bytes: 1_024, fallback: "context receipt"),
                try encodeJSON(receipt.details),
                receipt.createdAt.timeIntervalSince1970,
            ]
        )
    }

    private static func unusedVersionKeys(
        table: String,
        keyColumn: String,
        kept: Set<Int64>,
        db: Database
    ) throws -> [String] {
        let allowedTables = Set(["context_source_versions", "context_relationship_versions"])
        guard allowedTables.contains(table), keyColumn == "version_key" else { return [] }
        let rows = try Row.fetchAll(
            db,
            sql: "SELECT \(keyColumn), valid_from_generation, valid_to_generation FROM \(table)"
        )
        return rows.compactMap { row in
            guard let key: String = row[keyColumn],
                  let start: Int64 = row["valid_from_generation"] else { return nil }
            let end: Int64? = row["valid_to_generation"]
            return interval(start: start, end: end, intersects: kept) ? nil : key
        }
    }

    private static func interval(start: Int64, end: Int64?, intersects kept: Set<Int64>) -> Bool {
        kept.contains { generation in
            generation >= start && (end == nil || generation <= end!)
        }
    }

    private static func versionKey(stableID: String, generationID: Int64) -> String {
        stableID + "@" + String(generationID)
    }

    private static func encodeJSON<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(value)
        guard let string = String(data: data, encoding: .utf8) else {
            throw ContextFlowStoreError.malformedStoredValue("json_encode")
        }
        return string
    }

    private static func decodeJSON<T: Decodable>(_ string: String) throws -> T {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        guard let data = string.data(using: .utf8) else {
            throw ContextFlowStoreError.malformedStoredValue("json_decode")
        }
        return try decoder.decode(T.self, from: data)
    }

    private static func encodeVector(_ values: [Float]) -> Data {
        values.withUnsafeBufferPointer { Data(buffer: $0) }
    }

    private static func decodeVector(_ data: Data, expectedCount: Int) throws -> [Float] {
        guard expectedCount >= 0,
              data.count == expectedCount * MemoryLayout<Float>.stride else {
            throw ContextFlowStoreError.malformedStoredValue("embedding")
        }
        var values = [Float](repeating: 0, count: expectedCount)
        _ = values.withUnsafeMutableBytes { destination in
            data.copyBytes(to: destination)
        }
        return values
    }

    private static func bounded(_ value: String, maxUTF8Bytes: Int, fallback: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return fallback }
        guard trimmed.utf8.count > maxUTF8Bytes else { return trimmed }
        var result = ""
        result.reserveCapacity(maxUTF8Bytes)
        for scalar in trimmed.unicodeScalars {
            let next = result + String(scalar)
            if next.utf8.count > maxUTF8Bytes { break }
            result = next
        }
        return result
    }
}
