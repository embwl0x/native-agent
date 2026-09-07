import Foundation
import GRDB
import PersistenceCore

extension SwiftNativeKnowledgeGraphIndexer {
    /// Rebuild every MemoryV2-owned KG row from the canonical `memories` table
    /// in one database write transaction. This is the convergence boundary for
    /// approved consolidation swaps: it removes additive claims from changed
    /// facts, preserves legacy/manual entities without the indexer provenance
    /// stamp, and snapshots canonical rows under the same SQLite write lock so
    /// a concurrent memory mutation lands either before the rebuild snapshot or
    /// afterward through its ordinary indexing hook — never in a lost window.
    ///
    /// User, 2026-09-06: `producing` false is Settings ▸ "Knowledge graph" off.
    /// The removal half still runs and nothing is re-derived, so the rebuild
    /// RETIRES every indexer-owned node instead of minting a fresh graph — the
    /// same answer the mutation hook gives while the switch is off (it routes
    /// every write as a delete). The gate lives in MemoryV2, which depends on
    /// this module, so it arrives as an argument rather than a read from here.
    /// Default true: every existing caller behaves exactly as before.
    public func rebuildMemoryDerivedGraphFromCanonicalStore(
        producing: Bool = true
    ) async throws -> KnowledgeGraphMemoryRebuildReport {
        let dbPool = try await pool()
        let primaryUserName = resolvedPrimaryUserName()
        return try await dbPool.write { db in
            let memoryTableExists = (try Int.fetchOne(
                db,
                sql: """
                    SELECT COUNT(*) FROM sqlite_master
                    WHERE type = 'table' AND name = 'memories'
                    """
            ) ?? 0) > 0
            guard memoryTableExists else {
                return KnowledgeGraphMemoryRebuildReport(
                    factsIndexed: 0,
                    entitiesRemoved: 0,
                    relationshipsRemoved: 0,
                    indexRowsRemoved: 0
                )
            }

            let rows = try Row.fetchAll(db, sql: """
                SELECT id, content, source, status, created_at, updated_at,
                       metadata_json
                FROM memories
                WHERE status = 'active'
                  AND TRIM(COALESCE(content, '')) <> ''
                  AND lower(COALESCE(NULLIF(TRIM(lifecycle), ''), 'confirmed'))
                        NOT IN ('corrected', 'contradicted', 'deleted')
                  AND id NOT LIKE 'skill-pointer:%'
                ORDER BY id ASC
                """)
            let facts: [KnowledgeGraphMemoryFact] = !producing ? [] : rows.compactMap { row in
                guard let id: String = row["id"],
                      let content: String = row["content"] else { return nil }
                let metadataRaw: String? = row["metadata_json"]
                let metadata = metadataRaw
                    .flatMap { try? JSONValue.parse(Data($0.utf8)) }
                return KnowledgeGraphMemoryFact(
                    id: id,
                    content: content,
                    source: row["source"],
                    status: row["status"] ?? "active",
                    createdAt: row["created_at"] ?? "",
                    updatedAt: row["updated_at"] ?? "",
                    metadata: metadata
                )
            }

            let ownedIndexerPlaceholders = Self.ownedIndexerVersions
                .map { _ in "?" }
                .joined(separator: ", ")
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
            var ownedEntitiesRemoved = db.changesCount
            try db.execute(sql: "DELETE FROM kg_memory_index")
            let indexRowsRemoved = db.changesCount

            let now = Self.nowISO8601()
            let consolidation = if facts.isEmpty {
                try Self.removeUnreferencedPrimaryUserRole(db)
            } else {
                try Self.consolidatePrimaryUserEntities(
                    db,
                    primaryUserName: primaryUserName
                )
            }
            var legacyRelationshipsRemoved = 0
            // A canonical rebuild means "the graph is a function of the rows
            // that exist now". Nodes no indexer stamped (daemon-era imports)
            // used to survive every rebuild because upsertEntity matches by
            // name and touches them, so "Agent" as a concept carried 42 000
            // mentions and "instance_of" edges to User into 2026-09. Nothing
            // about them is derivable from a current row: drop them, with
            // every edge that no indexer wrote. The primary-user hub and the
            // other live writers' own nodes stay. Runs AFTER primary-user
            // consolidation so a legacy "User" row's edges are folded onto the
            // hub first, not dropped as dangling.
            //
            // 2026-09-06: the predicate used to name the two provenance values
            // the residue happened to carry (NULL, `default-concept`), so an
            // import with any OTHER provenance survived — and upsertEntity
            // adopted it by name, bumped mention_count and never stamped it,
            // every rebuild, forever. Ownership is the test now: a row is kept
            // if an indexer owns it or a known foreign writer wrote it (the
            // studio journal, growth distillation, or the legacy importer,
            // which stamps `legacy-import` on everything it lands). Anything
            // else is what the old daemon left behind.
            let foreignPlaceholders = Self.foreignWriterProvenances
                .map { _ in "?" }
                .joined(separator: ", ")
            try db.execute(
                sql: """
                    DELETE FROM kg_relationships
                    WHERE (provenance IS NULL
                           OR provenance NOT IN (\(foreignPlaceholders)))
                      AND json_extract(metadata_json, '$.indexer') IS NULL
                    """,
                arguments: StatementArguments(Self.foreignWriterProvenances)
            )
            legacyRelationshipsRemoved += db.changesCount
            try db.execute(
                sql: """
                    DELETE FROM kg_entities
                    WHERE (provenance IS NULL
                           OR provenance NOT IN (\(foreignPlaceholders)))
                      AND json_extract(metadata_json, '$.\(Self.createdByKey)') IS NULL
                      AND COALESCE(json_extract(metadata_json, '$.role'), '') <> 'primary_user'
                    """,
                arguments: StatementArguments(Self.foreignWriterProvenances)
            )
            ownedEntitiesRemoved += db.changesCount
            try db.execute(sql: """
                DELETE FROM kg_relationships
                WHERE from_id NOT IN (SELECT id FROM kg_entities)
                   OR to_id NOT IN (SELECT id FROM kg_entities)
                """)
            legacyRelationshipsRemoved += db.changesCount
            // The one node that survives a rebuild and is still counted by it.
            // Its per-fact increment used to accumulate across rebuilds, so the
            // hub's mention_count grew without a row to show for it: a rebuild
            // states the count, it does not add to it.
            try db.execute(sql: """
                UPDATE kg_entities SET mention_count = 0
                WHERE COALESCE(json_extract(metadata_json, '$.role'), '') = 'primary_user'
                """)
            for fact in facts {
                let memoryID = fact.id.trimmingCharacters(in: .whitespacesAndNewlines)
                let content = fact.content.trimmingCharacters(in: .whitespacesAndNewlines)
                let contentHash = Self.contentHash("\(Self.indexVersion):\(content)")
                try Self.indexActiveFact(
                    db,
                    fact: fact,
                    memoryID: memoryID,
                    content: content,
                    contentHash: contentHash,
                    now: now,
                    extracted: Self.extractEntities(from: content, knownPeople: knownPeople),
                    primaryUserName: primaryUserName
                )
            }
            return KnowledgeGraphMemoryRebuildReport(
                factsIndexed: facts.count,
                entitiesRemoved: ownedEntitiesRemoved + consolidation.entitiesRemoved,
                relationshipsRemoved: ownedRelationshipsRemoved + legacyRelationshipsRemoved + consolidation.relationshipsRemoved,
                indexRowsRemoved: indexRowsRemoved
            )
        }
    }

    /// B4 (2026-08-28): index the active memories that have NO `kg_memory_index`
    /// row, and only those.
    ///
    /// Why this exists next to `rebuildMemoryDerivedGraphFromCanonicalStore`:
    /// the rebuild is the only batch path, and it is all-or-nothing — it drops
    /// every indexer-owned entity, edge and index row and re-derives the world.
    /// That is correct for a consolidation swap and far too heavy for the drift
    /// this fixes. Indexing hooks are fire-and-forget `Task`s that die with the
    /// process, so a steady residue of unindexed memories accumulates (47 active
    /// memories, stable, measured on the live store 2026-08-28). Those memories
    /// are invisible to every graph-derived surface until something reindexes
    /// them.
    ///
    /// Additive and idempotent: memories that already have an index row are
    /// never touched, so this cannot disturb a healthy graph, and `limit` caps
    /// one pass so a large backlog drains over several runs instead of turning a
    /// routine reconcile into a long write transaction. Returns the number of
    /// memories indexed.
    @discardableResult
    public func backfillMissingMemoryIndexRows(limit: Int = 200) async throws -> Int {
        let cap = max(0, limit)
        guard cap > 0 else { return 0 }
        let dbPool = try await pool()
        let primaryUserName = resolvedPrimaryUserName()
        return try await dbPool.write { db in
            let memoryTableExists = (try Int.fetchOne(
                db,
                sql: """
                    SELECT COUNT(*) FROM sqlite_master
                    WHERE type = 'table' AND name = 'memories'
                    """
            ) ?? 0) > 0
            guard memoryTableExists else { return 0 }
            // Same eligibility predicate as the full rebuild — one definition of
            // "indexable memory", so a backfilled row is byte-identical to the
            // row a rebuild would have written. The only added clause is the
            // missing-index test.
            let rows = try Row.fetchAll(db, sql: """
                SELECT id, content, source, status, created_at, updated_at,
                       metadata_json
                FROM memories
                WHERE status = 'active'
                  AND TRIM(COALESCE(content, '')) <> ''
                  AND lower(COALESCE(NULLIF(TRIM(lifecycle), ''), 'confirmed'))
                        NOT IN ('corrected', 'contradicted', 'deleted')
                  AND id NOT LIKE 'skill-pointer:%'
                  AND NOT EXISTS (
                        SELECT 1 FROM kg_memory_index i WHERE i.memory_id = memories.id
                  )
                ORDER BY id ASC
                LIMIT ?
                """, arguments: [cap])
            guard !rows.isEmpty else { return 0 }
            let now = Self.nowISO8601()
            var indexed = 0
            for row in rows {
                guard let id: String = row["id"],
                      let content: String = row["content"] else { continue }
                let memoryID = id.trimmingCharacters(in: .whitespacesAndNewlines)
                let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !memoryID.isEmpty, !trimmed.isEmpty else { continue }
                let metadataRaw: String? = row["metadata_json"]
                let fact = KnowledgeGraphMemoryFact(
                    id: memoryID,
                    content: content,
                    source: row["source"],
                    status: row["status"] ?? "active",
                    createdAt: row["created_at"] ?? "",
                    updatedAt: row["updated_at"] ?? "",
                    metadata: metadataRaw.flatMap { try? JSONValue.parse(Data($0.utf8)) }
                )
                try Self.indexActiveFact(
                    db,
                    fact: fact,
                    memoryID: memoryID,
                    content: trimmed,
                    contentHash: Self.contentHash("\(Self.indexVersion):\(trimmed)"),
                    now: now,
                    extracted: Self.extractEntities(from: trimmed, knownPeople: knownPeople),
                    primaryUserName: primaryUserName
                )
                indexed += 1
            }
            return indexed
        }
    }

    /// Every provenance value known to have been minted exclusively by this
    /// rebuildable MemoryV2 projection. Unstamped daemon-era and manual rows
    /// remain outside this ownership set and are never deleted here.
    private static let ownedIndexerVersions = [
        "swift-memory-kg-v1",
        "swift-memory-kg-v2",
        "swift-memory-kg-v3",
        // v4 minted the capitalisation-lane junk; it must stay owned or a
        // rebuild can never delete it (reviewer, 2026-09-05).
        "swift-memory-kg-v4",
        indexVersion,
    ]

    /// Stamp the one-time legacy JSON importer puts on every row it lands
    /// (`KnowledgeGraph+SQLite.maybeImportJSON`). 2026-09-06: imported rows kept
    /// whatever provenance the JSON carried — usually none — so the ownership
    /// purge below could not tell hand-written legacy content from daemon-era
    /// residue and dropped it on the first rebuild after an import.
    static let legacyImportProvenance = "legacy-import"

    /// Provenance values other live writers own. A canonical rebuild leaves
    /// their rows alone; every other unstamped row is daemon-era residue it
    /// drops. `studio-journal` is the studio journal
    /// (KnowledgeGraph+StudioRelations), `rem-growth-eviction` the growth
    /// distillation summaries (KnowledgeGraph+GrowthDistillation),
    /// `legacy-import` the one-time JSON import (KnowledgeGraph+SQLite) — none
    /// of the three is derivable from a memory row.
    private static let foreignWriterProvenances = [
        studioProvenance,
        "rem-growth-eviction",
        legacyImportProvenance,
    ]

}
