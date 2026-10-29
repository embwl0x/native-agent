// ── ORPHAN DEFINITION (verified against the live schema) ────────────────────
// The live schema has NO memory<->entity link table. The only linkage is:
//   - kg_entities.metadata_json.last_memory_id  (most recent sourcing memory,
//     written by the indexer on insert AND touch)
//   - kg_memory_index.memory_id                 (the set of indexed memories;
//     reconciled against the canonical facts in the sweep transaction)
// `last_memory_id` alone is NOT sufficient: memory A and B can both mention
// an entity, last points at B, B dies, A lives — last-based sweeping would
// destroy a live entity. So orphanhood is a conjunction of FOUR conditions:
//
//   An entity is an orphan candidate iff ALL of:
//   1. metadata_json[created_by_indexer] is present — the entity was PROVABLY
//      created by this indexer from a MemoryV2 memory. Daemon-era JSON imports
//      and pre-stamp rows have unknowable sources and are NEVER swept.
//   2. metadata_json.last_memory_id is present AND not in the transaction's
//      live memory IDs — its most recent source is gone.
//   3. Re-extraction over the transaction's live memory contents does not
//      yield the entity's (type, name) key — no surviving memory still
//      mentions it. This is the load-bearing reconcile; conditions 1-2 are
//      cheap pre-filters and extraction-drift protection.
//   4. The entity is not the stable primary-user role hub.
//
// Sweeping an entity also deletes its incident kg_relationships rows in the
// SAME transaction, plus any dangling edges and stale kg_memory_index rows
// (every add has a remove). Canonical facts, support and candidates share that
// transaction; preview uses the same scan in a read transaction.
//
// Preview is read-only; apply rechecks the exact reviewed candidate set.

import Foundation
import GRDB
import PersistenceCore
// Blueprint: | `KnowledgeGraph+GC.swift` | Explicit/approved orphan collection retaining source provenance and the primary-user role hub |

public struct KnowledgeGraphGCCandidate: Sendable, Equatable {
    public var id: String
    public var name: String
    public var type: String
    public var mentionCount: Int

    public init(id: String, name: String, type: String, mentionCount: Int) {
        self.id = id
        self.name = name
        self.type = type
        self.mentionCount = mentionCount
    }
}

public struct KnowledgeGraphGCReport: Sendable, Equatable {
    /// Entities that met the orphan definition at scan time.
    public var candidates: [KnowledgeGraphGCCandidate]
    /// Entities GC can never prove orphaned (no created_by_indexer stamp —
    /// daemon-era imports / pre-stamp rows). Reported for visibility only.
    public var legacyUntrackedEntities: Int
    /// True when deletions were performed.
    public var applied: Bool
    public var candidateSetDiverged: Bool
    public var entitiesDeleted: Int
    public var edgesDeleted: Int
    public var staleIndexRowsDeleted: Int
}

extension SwiftNativeKnowledgeGraphIndexer {

    /// Sweep using canonical active, non-empty facts in the scan transaction.
    ///
    /// - apply=false: pure read (dry run) — candidates only, no mutations.
    /// - apply=true: deletes candidates + incident edges + dangling edges +
    ///   stale index rows in ONE write transaction after checking the reviewed IDs.
    public func collectGarbage(
        apply: Bool = false,
        expectedCandidateIDs: Set<String>? = nil
    ) async throws -> KnowledgeGraphGCReport {
        let dbPool = try await pool()
        let primaryUserName = resolvedPrimaryUserName()
        let knownPeople = self.knownPeople
        if !apply {
            return try await dbPool.read { db in
                let scan = try Self.scanForOrphans(
                    db, knownPeople: knownPeople, primaryUserName: primaryUserName
                )
                return KnowledgeGraphGCReport(
                    candidates: scan.candidates,
                    legacyUntrackedEntities: scan.legacyUntracked,
                    applied: false,
                    candidateSetDiverged: false,
                    entitiesDeleted: 0,
                    edgesDeleted: 0,
                    staleIndexRowsDeleted: 0
                )
            }
        }

        return try await dbPool.write { db in
            let scan = try Self.scanForOrphans(
                db, knownPeople: knownPeople, primaryUserName: primaryUserName
            )
            if let expectedCandidateIDs,
               Set(scan.candidates.map(\.id)) != expectedCandidateIDs {
                return KnowledgeGraphGCReport(
                    candidates: scan.candidates,
                    legacyUntrackedEntities: scan.legacyUntracked,
                    applied: false,
                    candidateSetDiverged: true,
                    entitiesDeleted: 0,
                    edgesDeleted: 0,
                    staleIndexRowsDeleted: 0
                )
            }
            var edgesDeleted = 0
            var staleDeleted = 0
            // 1. Stale index rows (deleted memories whose hook never fired).
            for chunk in Self.gcChunks(scan.staleIndexIDs) {
                let qs = Array(repeating: "?", count: chunk.count).joined(separator: ",")
                try db.execute(
                    sql: "DELETE FROM kg_memory_index WHERE memory_id IN (\(qs))",
                    arguments: StatementArguments(chunk)
                )
                staleDeleted += db.changesCount
            }
            // 2. Orphan entities + their incident edges.
            let orphanIDs = scan.candidates.map { $0.id }
            for chunk in Self.gcChunks(orphanIDs) {
                let qs = Array(repeating: "?", count: chunk.count).joined(separator: ",")
                try db.execute(
                    sql: "DELETE FROM kg_relationships WHERE from_id IN (\(qs)) OR to_id IN (\(qs))",
                    arguments: StatementArguments(chunk + chunk)
                )
                edgesDeleted += db.changesCount
                try db.execute(
                    sql: "DELETE FROM kg_entities WHERE id IN (\(qs))",
                    arguments: StatementArguments(chunk)
                )
            }
            // 3. Any dangling edges left by historical paths (read path drops
            //    them on load; remove the rows for real).
            try db.execute(sql: """
                DELETE FROM kg_relationships
                WHERE from_id NOT IN (SELECT id FROM kg_entities)
                   OR to_id NOT IN (SELECT id FROM kg_entities)
                """)
            edgesDeleted += db.changesCount
            return KnowledgeGraphGCReport(
                candidates: scan.candidates,
                legacyUntrackedEntities: scan.legacyUntracked,
                applied: true,
                candidateSetDiverged: false,
                entitiesDeleted: orphanIDs.count,
                edgesDeleted: edgesDeleted,
                staleIndexRowsDeleted: staleDeleted
            )
        }
    }

    private struct OrphanScan {
        var candidates: [KnowledgeGraphGCCandidate]
        var legacyUntracked: Int
        var staleIndexIDs: [String]
    }

    private static func scanForOrphans(
        _ db: Database,
        knownPeople: [String],
        primaryUserName: String
    ) throws -> OrphanScan {
        let rows = try Row.fetchAll(
            db,
            sql: """
                SELECT id, content FROM memories
                WHERE status = 'active'
                  AND TRIM(COALESCE(content, '')) <> ''
                """
        )
        let active = try rows.map { row in
            (id: try row.decode(String.self, forColumn: "id").trimmingCharacters(in: .whitespacesAndNewlines),
             content: try row.decode(String.self, forColumn: "content").trimmingCharacters(in: .whitespacesAndNewlines))
        }.filter { !$0.content.isEmpty }
        let liveIDs = Set(active.map(\.id).filter { !$0.isEmpty })
        // Support uses the indexer's exact extractor and known-person vocabulary.
        var liveKeys = Set<String>()
        for fact in active {
            for entity in Self.extractEntities(from: fact.content, knownPeople: knownPeople) {
                liveKeys.insert("\(entity.type.lowercased())|\(entity.name.lowercased())")
            }
        }
        if !active.isEmpty { liveKeys.insert("person|\(primaryUserName.lowercased())") }

        let idxRows = try Row.fetchAll(
            db, sql: "SELECT memory_id FROM kg_memory_index"
        )
        let staleIndexIDs = idxRows.compactMap { r -> String? in
            let mid: String = r["memory_id"] ?? ""
            return mid.isEmpty || liveIDs.contains(mid) ? nil : mid
        }

        let entityRows = try Row.fetchAll(db, sql: """
            SELECT id, name, type, mention_count, metadata_json FROM kg_entities
            """)
        var candidates: [KnowledgeGraphGCCandidate] = []
        var legacyUntracked = 0
        for r in entityRows {
            let id: String = r["id"] ?? ""
            let name: String = r["name"] ?? ""
            let type: String = r["type"] ?? ""
            guard !id.isEmpty else { continue }
            let meta: [String: JSONValue] = {
                guard let raw: String = r["metadata_json"],
                      let data = raw.data(using: .utf8),
                      let parsed = try? JSONValue.parse(data),
                      case .object(let obj) = parsed else { return [:] }
                return obj
            }()
            // Condition 4: never the stable primary-user role hub. v4 hubs
            // have no creation stamp, but keep the explicit role guard so a
            // future metadata migration cannot make identity sweepable.
            if case .string(let role)? = meta["role"], role == "primary_user" {
                continue
            }
            // Condition 1: provably indexer-created.
            guard meta[createdByKey] != nil else {
                legacyUntracked += 1
                continue
            }
            // Condition 2: most recent source memory gone.
            guard case .string(let lastID)? = meta["last_memory_id"],
                  !lastID.isEmpty else { continue }
            if liveIDs.contains(lastID) { continue }
            // Condition 3: no surviving memory still mentions it.
            if liveKeys.contains("\(type.lowercased())|\(name.lowercased())") { continue }
            let mentions: Int = {
                if let mc: Int64 = r["mention_count"] { return Int(mc) }
                return 0
            }()
            candidates.append(KnowledgeGraphGCCandidate(
                id: id, name: name, type: type, mentionCount: mentions
            ))
        }
        return OrphanScan(
            candidates: candidates,
            legacyUntracked: legacyUntracked,
            staleIndexIDs: staleIndexIDs
        )
    }

    private static func gcChunks(_ ids: [String], size: Int = 500) -> [[String]] {
        guard !ids.isEmpty else { return [] }
        return stride(from: 0, to: ids.count, by: size).map {
            Array(ids[$0..<min($0 + size, ids.count)])
        }
    }

}
