// Only indexer-created entities with a missing latest source, no surviving extracted mention and no primary-user role are orphan candidates. The latest-source
// stamp alone cannot prove orphanhood because other memories may still mention an entity. Reconcile support, candidates, incident edges, dangling edges and
// stale index rows in one canonical transaction. Preview reads only; apply rechecks the exact reviewed set.

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
    public var candidates: [KnowledgeGraphGCCandidate]
    /// Entities without creation ownership evidence; reported, never swept.
    public var untrackedEntities: Int
    public var applied: Bool
    public var candidateSetDiverged: Bool
    public var entitiesDeleted: Int
    public var edgesDeleted: Int
    public var staleIndexRowsDeleted: Int
}

extension SwiftNativeKnowledgeGraphIndexer {

    /// Preview reads canonical facts without mutation; apply rechecks reviewed IDs and removes candidates, incident/dangling edges and stale index rows in one
    /// write transaction.
    public func collectGarbage(
        apply: Bool = false,
        expectedCandidateIDs: Set<String>? = nil
    ) async throws -> KnowledgeGraphGCReport {
        let dbPool = try await pool()
        let identity = try resolvedExtractionIdentity()
        let primaryUserName = identity.primaryUserName
        let knownPeople = identity.knownPeople
        if !apply {
            return try await dbPool.read { db in
                let scan = try Self.scanForOrphans(
                    db, knownPeople: knownPeople, primaryUserName: primaryUserName
                )
                return KnowledgeGraphGCReport(
                    candidates: scan.candidates,
                    untrackedEntities: scan.untracked,
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
                    untrackedEntities: scan.untracked,
                    applied: false,
                    candidateSetDiverged: true,
                    entitiesDeleted: 0,
                    edgesDeleted: 0,
                    staleIndexRowsDeleted: 0
                )
            }
            var edgesDeleted = 0
            var staleDeleted = 0
            for chunk in Self.gcChunks(scan.staleIndexIDs) {
                let qs = Array(repeating: "?", count: chunk.count).joined(separator: ",")
                try db.execute(
                    sql: "DELETE FROM kg_memory_index WHERE memory_id IN (\(qs))",
                    arguments: StatementArguments(chunk)
                )
                staleDeleted += db.changesCount
            }
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
            try db.execute(sql: """
                DELETE FROM kg_relationships
                WHERE from_id NOT IN (SELECT id FROM kg_entities)
                   OR to_id NOT IN (SELECT id FROM kg_entities)
                """)
            edgesDeleted += db.changesCount
            return KnowledgeGraphGCReport(
                candidates: scan.candidates,
                untrackedEntities: scan.untracked,
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
        var untracked: Int
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
        var untracked = 0
        for r in entityRows {
            let id: String = r["id"] ?? ""
            let name: String = r["name"] ?? ""
            let type: String = r["type"] ?? ""
            guard !id.isEmpty else { continue }
            let meta = try Self.metadataObject(r["metadata_json"])
            // Always protect the primary-user role hub, even if its creation metadata changes.
            if case .string(let role)? = meta["role"], role == "primary_user" {
                continue
            }
            guard meta[createdByKey] != nil else {
                untracked += 1
                continue
            }
            guard case .string(let lastID)? = meta["last_memory_id"],
                  !lastID.isEmpty else { continue }
            if liveIDs.contains(lastID) { continue }
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
            untracked: untracked,
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
