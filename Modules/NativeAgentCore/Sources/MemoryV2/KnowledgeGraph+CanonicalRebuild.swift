import Foundation
import GRDB
import PersistenceCore
// Blueprint: | `KnowledgeGraph+CanonicalRebuild.swift` | `SwiftNativeKnowledgeGraphIndexer`: `rebuildMemoryDerivedGraphFromCanonicalStore`, `reconcileMemoryIndexFingerprints` |

extension SwiftNativeKnowledgeGraphIndexer {
    /// Rebuild every MemoryV2-owned KG row from the canonical `memories` table
    /// in one database write transaction. It removes additive claims from changed
    /// facts, preserves independently owned entities without the indexer provenance
    /// stamp, and snapshots canonical rows under the same SQLite write lock so
    /// a concurrent memory mutation lands either before the rebuild snapshot or
    /// afterward through its ordinary indexing hook — never in a lost window.
    ///
    /// With production off, retire owned rows without rederiving them. The
    /// reconciler supplies one checked mode for the complete transaction.
    public func rebuildMemoryDerivedGraphFromCanonicalStore(
        producing: Bool = true
    ) async throws -> KnowledgeGraphMemoryRebuildReport {
        try await rebuildMemoryDerivedGraphFromCanonicalStore(
            producing: producing, identity: resolvedExtractionIdentity())
    }

    func rebuildMemoryDerivedGraphFromCanonicalStore(
        producing: Bool, identity: ExtractionIdentity
    ) async throws -> KnowledgeGraphMemoryRebuildReport {
        let dbPool = try await pool()
        return try await dbPool.write { db in
            // A cold write awaiting admission (MemoryV2's `admission_pending`)
            // is not a fact until its vector lands; its landing re-indexes it.
            let rows = try Row.fetchAll(db, sql: """
                SELECT id, content, source, status, created_at, updated_at,
                       metadata_json, valid_from, valid_to
                FROM memories
                WHERE status = 'active'
                  AND TRIM(COALESCE(content, '')) <> ''
                  AND lower(COALESCE(NULLIF(TRIM(lifecycle), ''), 'confirmed'))
                        NOT IN \(MemoryLifecycle.recallExcludedSQL)
                  AND json_extract(metadata_json, '$.admission_pending') IS NOT 1
                ORDER BY id ASC
                """)
            let facts = try (producing ? rows : []).compactMap { try KnowledgeGraphMemoryFact(row: $0) }

            let ownedIndexerPlaceholders = Self.ownedIndexerVersions
                .map { _ in "?" }
                .joined(separator: ", ")
            // Clear memory-derived summaries on foreign-owned entities before
            // surviving facts rederive them, including when production is off.
            try db.execute(sql: """
                UPDATE kg_entities SET summary = NULL,
                    metadata_json = json_remove(metadata_json,
                        '$.last_memory_id', '$.last_memory_source', '$.embedding_text', '$.indexer')
                WHERE json_extract(metadata_json, '$.indexer') IN (\(ownedIndexerPlaceholders))
                  AND json_extract(metadata_json, '$.\(Self.createdByKey)') IS NULL
                """, arguments: StatementArguments(Self.ownedIndexerVersions))
            let provenanceSubquery = """
                SELECT id FROM kg_entities
                WHERE json_extract(metadata_json, '$.\(Self.createdByKey)')
                      IN (\(ownedIndexerPlaceholders))
                """
            try db.execute(
                sql: """
                    DELETE FROM kg_relationships
                    WHERE from_id IN (\(provenanceSubquery))
                       OR to_id IN (\(provenanceSubquery))
                       OR json_extract(metadata_json, '$.indexer')
                          IN (\(ownedIndexerPlaceholders))
                    """,
                arguments: StatementArguments(
                    Self.ownedIndexerVersions
                        + Self.ownedIndexerVersions
                        + Self.ownedIndexerVersions
                )
            )
            let ownedRelationshipsRemoved = db.changesCount
            try db.execute(
                sql: """
                    DELETE FROM kg_entities
                    WHERE json_extract(metadata_json, '$.\(Self.createdByKey)')
                          IN (\(ownedIndexerPlaceholders))
                    """,
                arguments: StatementArguments(Self.ownedIndexerVersions)
            )
            let ownedEntitiesRemoved = db.changesCount
            try db.execute(sql: "DELETE FROM kg_memory_index")
            let indexRowsRemoved = db.changesCount

            let now = Self.nowISO8601()
            let consolidation = if facts.isEmpty {
                try Self.removeUnreferencedPrimaryUserRole(db)
            } else {
                try Self.consolidatePrimaryUserEntities(
                    db,
                    primaryUserName: identity.primaryUserName
                )
            }
            var danglingRelationshipsRemoved = 0
            try db.execute(sql: """
                DELETE FROM kg_relationships
                WHERE from_id NOT IN (SELECT id FROM kg_entities)
                   OR to_id NOT IN (SELECT id FROM kg_entities)
                """)
            danglingRelationshipsRemoved += db.changesCount
            // Reset the surviving primary-user hub's count before deriving it from current facts.
            try db.execute(sql: """
                UPDATE kg_entities SET mention_count = 0
                WHERE COALESCE(json_extract(metadata_json, '$.role'), '') = 'primary_user'
                """)
            for fact in facts {
                let memoryID = fact.id.trimmingCharacters(in: .whitespacesAndNewlines)
                let content = fact.content.trimmingCharacters(in: .whitespacesAndNewlines)
                let contentHash = Self.factFingerprint(fact, content: content, identity: identity)
                try Self.indexActiveFact(
                    db,
                    fact: fact,
                    memoryID: memoryID,
                    content: content,
                    contentHash: contentHash,
                    now: now,
                    extracted: Self.extractEntities(from: content, knownPeople: identity.knownPeople),
                    primaryUserName: identity.primaryUserName
                )
            }
            return KnowledgeGraphMemoryRebuildReport(
                factsIndexed: facts.count,
                entitiesRemoved: ownedEntitiesRemoved + consolidation.entitiesRemoved,
                relationshipsRemoved: ownedRelationshipsRemoved + danglingRelationshipsRemoved + consolidation.relationshipsRemoved,
                indexRowsRemoved: indexRowsRemoved
            )
        }
    }

    /// Check the complete canonical fingerprint set, including existing rows.
    /// Drift rebuilds under the canonical write lock so stale derived claims
    /// are removed as well as missing ones restored.
    @discardableResult
    public func reconcileMemoryIndexFingerprints() async throws -> Int {
        let identity = try resolvedExtractionIdentity()
        let dbPool = try await pool()
        let drift = try await dbPool.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT m.id, m.content, m.source, m.status, m.created_at,
                       m.updated_at, m.metadata_json, m.valid_from, m.valid_to, i.content_hash
                FROM memories m LEFT JOIN kg_memory_index i ON i.memory_id = m.id
                WHERE m.status = 'active'
                  AND TRIM(COALESCE(m.content, '')) <> ''
                  AND lower(COALESCE(NULLIF(TRIM(m.lifecycle), ''), 'confirmed'))
                        NOT IN \(MemoryLifecycle.recallExcludedSQL)
                  AND json_extract(m.metadata_json, '$.admission_pending') IS NOT 1
                ORDER BY m.id
                """)
            let facts = try rows.compactMap { row -> (fact: KnowledgeGraphMemoryFact, hash: String?)? in
                guard let fact = try KnowledgeGraphMemoryFact(row: row) else { return nil }
                return (fact, try row.decode(String?.self, forColumn: "content_hash"))
            }
            let indexCount = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM kg_memory_index") ?? 0
            if indexCount != facts.count { return true }
            return facts.contains { fact, hash in
                hash != Self.factFingerprint(
                    fact, content: fact.content.trimmingCharacters(in: .whitespacesAndNewlines), identity: identity
                )
            }
        }
        guard drift else { return 0 }
        return try await rebuildMemoryDerivedGraphFromCanonicalStore(producing: true, identity: identity).factsIndexed
    }

    /// Projection stamps identify the rows rebuilt from MemoryV2.
    private static let ownedIndexerVersions = [indexVersion]

}
