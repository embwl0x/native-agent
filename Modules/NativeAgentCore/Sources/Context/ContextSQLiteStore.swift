import CryptoKit
import Foundation
import GRDB
import PersistenceCore

// Blueprint: | `ContextSQLiteStore.swift` | `ContextSQLiteStore`: derived immutable Context generations, feedback, health and pruning; canonical sources remain authoritative |

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

/// Rebuildable ContextFlow generations; canonical persona, memory, skill and project sources stay authoritative.
/// Storage: local backup excludes this derived SQLite store; off-disk backup
/// includes it. No data export or phone sync; PrivacyMap category: context.
public actor ContextSQLiteStore {
    public static let diskStorageOwner = DiskStorageOwner.retained(id: "context", roots: ["context"],
        policy: "Kept to keep recall available; this active derived index cannot be safely dropped during cleanup.")

    public let databaseURL: URL
    let dbPool: DatabasePool

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
        // The WAL pool lets turn-path reads run beside publication, pruning and vacuum.
        self.dbPool = try DatabasePool(path: databaseURL.path, configuration: configuration)
        try Self.migrator.migrate(dbPool)
    }

    @discardableResult
    public func publish(_ draft: ContextGenerationDraft) async throws -> ContextGenerationRecord {
        try Self.validate(draft)

        return try await dbPool.write { db in
            let parentID = try Int64.fetchOne(
                db,
                sql: "SELECT id FROM context_generations WHERE status = 'completed' ORDER BY id DESC LIMIT 1"
            )
            let (generationID, overflow) = (parentID ?? 0).addingReportingOverflow(1)
            guard !overflow, generationID > 0 else {
                throw ContextFlowStoreError.malformedStoredValue("generation id exhausted or invalid")
            }
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
                try db.execute(
                    sql: """
                    UPDATE context_relationship_versions
                    SET valid_to_generation = ?
                    WHERE valid_to_generation IS NULL
                      AND EXISTS (
                        SELECT 1 FROM context_atom_versions AS atom
                        WHERE atom.source_id = ? AND atom.valid_to_generation IS NULL
                          AND (atom.atom_id = context_relationship_versions.source_atom_id
                            OR atom.atom_id = context_relationship_versions.target_atom_id)
                      )
                    """,
                    arguments: [generationID - 1, sourceID.rawValue]
                )
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
                    SET health = 'removed'
                    WHERE id = ?
                    """,
                    arguments: [sourceID.rawValue]
                )
            }

            for source in draft.changedSources.sorted(by: { $0.descriptor.id < $1.descriptor.id }) {
                let descriptorJSON = try Self.encodeJSON(source.descriptor)
                try db.execute(
                    sql: """
                    INSERT INTO context_sources (id, source_hash, health)
                    VALUES (?, ?, 'healthy')
                    ON CONFLICT(id) DO UPDATE SET
                        source_hash = excluded.source_hash,
                        health = 'healthy'
                    """,
                    arguments: [source.descriptor.id.rawValue, source.sourceHash]
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
                    try db.execute(
                        sql: """
                        INSERT INTO context_atom_versions (
                            version_key, atom_id, source_id,
                            valid_from_generation, valid_to_generation,
                            body, summary, payload_json
                        ) VALUES (?, ?, ?, ?, NULL, ?, ?, ?)
                        """,
                        arguments: [
                            versionKey,
                            atom.id.rawValue,
                            atom.sourceID.rawValue,
                            generationID,
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
                            target_atom_id, valid_from_generation, valid_to_generation, payload_json
                        ) VALUES (?, ?, ?, ?, ?, NULL, ?)
                        """,
                        arguments: [
                            versionKey,
                            relationship.id.rawValue,
                            relationship.sourceAtomID.rawValue,
                            relationship.targetAtomID.rawValue,
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

    // Baseline reads use the writer to wait for in-flight publication.
    public func activeGeneration() async throws -> ContextGenerationRecord? {
        try await dbPool.write { db in
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
        try await dbPool.write { db in
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
            var atomIDs = Set<ContextAtomID>()
            for atom in atoms {
                guard atomIDs.insert(atom.draft.id).inserted else {
                    throw ContextFlowStoreError.duplicateAtom(atom.draft.id.rawValue)
                }
            }

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

    private static func versionKey(stableID: String, generationID: Int64) -> String {
        stableID + "@" + String(generationID)
    }

    static func bounded(_ value: String, maxUTF8Bytes: Int, fallback: String) -> String {
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
