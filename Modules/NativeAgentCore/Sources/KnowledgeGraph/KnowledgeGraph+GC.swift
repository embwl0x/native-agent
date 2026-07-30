// U5 W-C (2026-06-11): first-ever GC path for the SQLite knowledge graph.
//
// Before this file there were ZERO removal paths for kg_entities /
// kg_relationships repo-wide (grep-verified in the U5 audit): deleted
// memories left their extracted entities forever.
//
// ── ORPHAN DEFINITION (verified against the live schema) ────────────────────
// The live schema has NO memory<->entity link table. The only linkage is:
//   - kg_entities.metadata_json.last_memory_id  (most recent sourcing memory,
//     written by the indexer on insert AND touch)
//   - kg_memory_index.memory_id                 (the set of indexed memories;
//     rows are deleted when indexMemory(deleted:) fires)
// `last_memory_id` alone is NOT sufficient: memory A and B can both mention
// an entity, last points at B, B dies, A lives — last-based sweeping would
// destroy a live entity. So orphanhood is a conjunction of FOUR conditions:
//
//   An entity is an orphan candidate iff ALL of:
//   1. metadata_json[created_by_indexer] is present — the entity was PROVABLY
//      created by this indexer from a MemoryV2 memory. Daemon-era JSON imports
//      and pre-stamp rows have unknowable sources and are NEVER swept.
//   2. metadata_json.last_memory_id is present AND not in (caller-supplied
//      live ids ∪ surviving kg_memory_index rows) — its most recent source is
//      gone.
//   3. Re-extraction over the caller-supplied LIVE memory contents does not
//      yield the entity's (type, name) key — no surviving memory still
//      mentions it. This is the load-bearing reconcile; conditions 1-2 are
//      cheap pre-filters and extraction-drift protection.
//   4. The entity is not the stable primary-user role hub.
//
// Sweeping an entity also deletes its incident kg_relationships rows in the
// SAME transaction, plus any dangling edges and stale kg_memory_index rows
// (every add has a remove). A grace window protects kg_memory_index rows
// indexed AFTER the caller snapshotted its live-memory list (the new-memory
// race) from being reconciled away.
//
// ── TRIGGER CONTRACT ─────────────────────────────────────────────────────────
// GC is approval-or-explicit-trigger ONLY. Nothing calls it on a timer; the
// per-plan slot does not exist. The two entry shapes:
//   - dry run (apply: false): pure read, returns the candidate list.
//   - apply: refuses above `approvalThreshold` candidates unless the caller
//     passes `approvedOverThreshold: true` — which a UI may only set after an
//     explicit human confirmation (KnowledgeGraphView's confirmation dialog).
// Threshold default 25 — proposed for review per the plan's open question.

import Foundation
import GRDB
import PersistenceCore

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
    /// True when apply was REFUSED because candidates exceeded the threshold
    /// and `approvedOverThreshold` was false. No mutations were performed.
    public var requiresApproval: Bool
    public var entitiesDeleted: Int
    public var edgesDeleted: Int
    public var staleIndexRowsDeleted: Int
}

extension SwiftNativeKnowledgeGraphIndexer {

    /// Apply-mode refusal threshold: more than this many candidates requires
    /// `approvedOverThreshold: true` (i.e. an explicit human confirmation).
    /// Default proposed in U5 W-C review — the user nods at the number.
    public static let gcDefaultApprovalThreshold = 25

    /// kg_memory_index rows newer than this many seconds are exempt from the
    /// stale-row reconcile and count as live for condition 2 — protects a
    /// memory indexed after the caller snapshotted `liveFacts` (read site:
    /// `scanForOrphans` only; no gate above it).
    public static let gcIndexGraceSeconds: TimeInterval = 60

    /// Sweep orphaned entities. `liveFacts` is the caller's CURRENT memory
    /// list (all statuses welcome; only `active` non-empty facts count as
    /// live, matching the indexer's own active-only rule — an archived
    /// memory's entities become sweepable once its index row reconciles).
    ///
    /// - apply=false: pure read (dry run) — candidates only, no mutations.
    /// - apply=true: deletes candidates + incident edges + dangling edges +
    ///   stale index rows in ONE write transaction, unless the candidate
    ///   count exceeds `approvalThreshold` and `approvedOverThreshold` is
    ///   false (refusal: report.requiresApproval=true, zero mutations).
    public func collectGarbage(
        liveFacts: [KnowledgeGraphMemoryFact],
        apply: Bool = false,
        approvalThreshold: Int = SwiftNativeKnowledgeGraphIndexer.gcDefaultApprovalThreshold,
        approvedOverThreshold: Bool = false
    ) async throws -> KnowledgeGraphGCReport {
        let dbPool = try await gcPool()
        let primaryUserName = resolvedPrimaryUserName()
        let active = liveFacts.filter {
            $0.status == "active"
                && !$0.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        let liveIDs = Set(
            active.map { $0.id.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        )
        // Recompute the live mention-key set from the SAME extraction the
        // indexer writes with (deterministic on content).
        var liveKeys = Set<String>()
        for fact in active {
            let extracted = Self.extractEntities(
                from: fact.content.trimmingCharacters(in: .whitespacesAndNewlines)
            )
            for e in extracted {
                liveKeys.insert("\(e.type.lowercased())|\(e.name.lowercased())")
            }
        }
        // Every indexed fact owns one edge from the stable primary-user role
        // node, even when the fact yields no additional extracted entities.
        // Its display name comes from canonical onboarding identity.
        if !active.isEmpty {
            liveKeys.insert("person|\(primaryUserName.lowercased())")
        }
        // Immutable snapshot for the @Sendable dbPool closures below —
        // capturing the mutated `var` is a Swift 6 Sendable build error
        // (caught at integration, 2026-06-11).
        let liveKeySnapshot = liveKeys

        let graceCutoff = Self.gcISO8601(
            Date().addingTimeInterval(-Self.gcIndexGraceSeconds)
        )

        if !apply {
            return try await dbPool.read { db in
                let scan = try Self.scanForOrphans(
                    db, liveIDs: liveIDs, liveKeys: liveKeySnapshot, graceCutoff: graceCutoff
                )
                return KnowledgeGraphGCReport(
                    candidates: scan.candidates,
                    legacyUntrackedEntities: scan.legacyUntracked,
                    applied: false,
                    requiresApproval: false,
                    entitiesDeleted: 0,
                    edgesDeleted: 0,
                    staleIndexRowsDeleted: 0
                )
            }
        }

        return try await dbPool.write { db in
            // Re-scan INSIDE the write transaction: candidates computed here
            // see every committed index row, so an entity re-mentioned by a
            // memory indexed after the caller's snapshot is protected by its
            // fresh kg_memory_index row (condition 2) + the grace window.
            let scan = try Self.scanForOrphans(
                db, liveIDs: liveIDs, liveKeys: liveKeySnapshot, graceCutoff: graceCutoff
            )
            if scan.candidates.count > approvalThreshold && !approvedOverThreshold {
                return KnowledgeGraphGCReport(
                    candidates: scan.candidates,
                    legacyUntrackedEntities: scan.legacyUntracked,
                    applied: false,
                    requiresApproval: true,
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
                requiresApproval: false,
                entitiesDeleted: orphanIDs.count,
                edgesDeleted: edgesDeleted,
                staleIndexRowsDeleted: staleDeleted
            )
        }
    }

    /// Referential reconcile of kg_memory_index: delete rows whose memory_id
    /// no longer exists in `memories`. Pure bookkeeping — entities and edges
    /// are never touched, so this needs no approval threshold and no
    /// liveFacts snapshot (the subselect checks the live table inside the
    /// same write transaction; a row for an existing memory can never match).
    ///
    /// Why this exists alongside collectGarbage's stale-row sweep
    /// (2026-07-02 audit): the full GC only runs on the approved
    /// consolidation-swap path and the manual KG maintenance button — when
    /// the store is already clean, no swap is ever staged, so index rows
    /// leaked by unflushed delete hooks (the fire-and-forget Task can die
    /// with the process) or by external curation sit forever. The weekly
    /// approved hygiene run calls this so the bookkeeping table reconciles
    /// on the same cadence as everything else. No-op (returns 0) when the
    /// `memories` table is absent (KG-only fixtures).
    public func reconcileStaleMemoryIndexRows() async throws -> Int {
        let dbPool = try await gcPool()
        return try await dbPool.write { db in
            let memoryTableExists = (try Int.fetchOne(
                db,
                sql: """
                    SELECT COUNT(*) FROM sqlite_master
                    WHERE type = 'table' AND name = 'memories'
                    """
            ) ?? 0) > 0
            guard memoryTableExists else { return 0 }
            // NOT EXISTS, not NOT IN: memories.id is TEXT PRIMARY KEY in a
            // rowid table, which SQLite (historical quirk) allows to hold
            // NULL — one NULL id would make a NOT IN subselect match nothing
            // and silently disable the reconcile (gpt-5.5 review, 2026-07-02).
            // A NULL index memory_id can never join a memory; drop it too.
            try db.execute(sql: """
                DELETE FROM kg_memory_index
                WHERE memory_id IS NULL
                   OR NOT EXISTS (
                        SELECT 1 FROM memories m WHERE m.id = kg_memory_index.memory_id
                   )
                """)
            return db.changesCount
        }
    }

    /// Pool access for GC — same shared-cache resolution as indexing, without
    /// creating a missing database (GC against a missing DB is an error).
    private func gcPool() async throws -> DatabasePool {
        try await KnowledgeGraphPoolCache.shared.pool(at: sqlitePath)
    }

    private struct OrphanScan {
        var candidates: [KnowledgeGraphGCCandidate]
        var legacyUntracked: Int
        var staleIndexIDs: [String]
    }

    private static func scanForOrphans(
        _ db: Database,
        liveIDs: Set<String>,
        liveKeys: Set<String>,
        graceCutoff: String
    ) throws -> OrphanScan {
        let memoryTableExists = (try Int.fetchOne(
            db,
            sql: """
                SELECT COUNT(*) FROM sqlite_master
                WHERE type = 'table' AND name = 'memories'
                """
        ) ?? 0) > 0
        let currentActiveIDs: Set<String>
        if memoryTableExists {
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT id FROM memories
                    WHERE status = 'active'
                      AND TRIM(COALESCE(content, '')) <> ''
                    """
            )
            currentActiveIDs = Set(rows.compactMap { row in
                let id: String = row["id"] ?? ""
                let trimmed = id.trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmed.isEmpty ? nil : trimmed
            })
        } else {
            currentActiveIDs = []
        }

        // Index rows: live, grace-kept, or stale. The grace window protects
        // the "memory inserted after caller snapshot, then indexed" race, but
        // only if the referenced memory is still active in the current DB.
        // This lets an approved consolidation swap archive a memory and sweep
        // its fresh-but-now-stale KG row immediately.
        let idxRows = try Row.fetchAll(
            db, sql: "SELECT memory_id, indexed_at FROM kg_memory_index"
        )
        var keptIndexIDs = Set<String>()
        var staleIndexIDs: [String] = []
        for r in idxRows {
            let mid: String = r["memory_id"] ?? ""
            guard !mid.isEmpty else { continue }
            let indexedAt: String = r["indexed_at"] ?? ""
            if liveIDs.contains(mid) {
                keptIndexIDs.insert(mid)
            } else if indexedAt >= graceCutoff
                        && (!memoryTableExists || currentActiveIDs.contains(mid)) {
                // Indexed after (or near) the caller's snapshot — treat as
                // live this pass if the memories table does not exist (unit
                // harness / external KG-only DB) or the row is still active.
                // A later GC sees it as stale if still gone.
                keptIndexIDs.insert(mid)
            } else {
                staleIndexIDs.append(mid)
            }
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
            if liveIDs.contains(lastID) || keptIndexIDs.contains(lastID) { continue }
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

    private static func gcISO8601(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }
}
