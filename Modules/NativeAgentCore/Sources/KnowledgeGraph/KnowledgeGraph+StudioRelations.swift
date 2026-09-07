// The studio journal's relations, become KNOWLEDGE-GRAPH EDGES.
//
// Desk 903 phase 3, in the agent's own words: "Relations become KG edges; kill
// the mini-graph outright. Works and creators become entities once; edges carry
// the journal entry id as provenance; same selection rule as the other 94."
//
// ── WHAT THIS WRITES ─────────────────────────────────────────────────────────
// From the append-only journal:
//   • one entity per WORK      (type `work`)    — deduped by name, written once
//   • one entity per CREATOR   (type `creator`) — deduped by name, written once
//   • work —created_by→ creator
//   • work —deepens|contradicts|revises|echoes→ work, from an entry's typed link
//     to an EARLIER ENTRY, resolved to that entry's work
// Every edge names the journal entries that assert it, in
// `metadata_json.studio_entry_ids`, so the causal chain is auditable back to the
// judgment that made the claim. That is the provenance requirement.
//
// ── WHY IT IS A FULL RE-DERIVE, NOT AN INCREMENT ─────────────────────────────
// `indexStudioJournal` takes the WHOLE journal and is idempotent: it SETS the
// edge's entry-id list, mention count and weight rather than incrementing them.
// The journal is a curated life record — a few entries a week — so reading it
// whole is honest and cheap (the store says the same about `readJournal`), and
// an idempotent writer means the one-shot backfill and the per-append update are
// the SAME operation. There is no dual-write period and no drift to reconcile.
//
// ── NO SCORE ─────────────────────────────────────────────────────────────────
// `weight` here is EVIDENCE COUNT, not taste: how many distinct entries assert
// this edge, mapped into the band the graph's own ordering expects. No judgment
// is ranked against another, and nothing about a work's stance touches it.
//
// ── WHY THESE ROWS SURVIVE THE MEMORY LANES ──────────────────────────────────
// The memory indexer's rebuild deletes what it owns by
// `metadata_json.indexer IN (swift-memory-kg-*)`; GC's orphan scan only
// considers entities that carry a `last_memory_id`; the stale sweep only
// considers entities with `provenance IS NULL`. Studio rows carry the studio
// indexer stamp, no `last_memory_id`, and an explicit provenance — so all three
// memory-side lanes step over them instead of collecting a life record as
// garbage.

import CryptoKit
import Foundation
import GRDB
import PersistenceCore

/// What one indexing pass actually wrote. Returned so the caller can say it out
/// loud rather than assert it.
public struct StudioGraphIndexReport: Sendable, Equatable {
    /// False when there is no `memory.sqlite` yet — a fresh install with no
    /// memory has no graph to write into, which is not an error.
    public var graphAvailable: Bool
    public var worksIndexed: Int
    public var creatorsIndexed: Int
    public var edgesWritten: Int
    /// Relations naming an entry the journal does not contain. Kept as a COUNT
    /// rather than dropped silently: a dangling link is a fact about the
    /// journal, not something to invent an endpoint for.
    public var unresolvedRelations: Int

    public static let unavailable = StudioGraphIndexReport(
        graphAvailable: false, worksIndexed: 0, creatorsIndexed: 0,
        edgesWritten: 0, unresolvedRelations: 0
    )
}

/// One typed studio edge, derived in Swift before any SQL runs.
struct StudioDerivedEdge: Hashable {
    let fromKey: String
    let toKey: String
    let type: String
}

extension SwiftNativeKnowledgeGraphIndexer {

    /// Stamp on every studio-written row. Deliberately NOT a `swift-memory-kg-*`
    /// version, so the memory rebuild's owned-row delete cannot reach these.
    public static let studioIndexVersion = "swift-studio-kg-v1"
    /// `kg_entities.provenance` / `kg_relationships.provenance` for studio rows.
    /// Also what keeps them out of the stale-entity sweep.
    public static let studioProvenance = "studio-journal"
    public static let studioWorkEntityType = "work"
    public static let studioCreatorEntityType = "creator"
    public static let studioCreatedByRelationType = "created_by"
    /// Bound on how many entry ids one edge records. An edge asserted by more
    /// entries than this is still one edge; the list is provenance, not a log.
    static let studioMaximumEntryIDsPerEdge = 24

    /// Re-derive the whole studio subgraph from the journal.
    ///
    /// Idempotent: calling it twice with the same entries leaves the same rows.
    /// A missing `memory.sqlite` returns `.unavailable` rather than throwing —
    /// the indexer never creates that file, and a journal write must not fail
    /// because the graph has not been born yet.
    @discardableResult
    public func indexStudioJournal(
        _ entries: [StudioJournalEntry],
        now: Date = Date()
    ) async throws -> StudioGraphIndexReport {
        let derived = Self.deriveStudioGraph(from: entries)
        guard !derived.works.isEmpty else { return StudioGraphIndexReport(
            graphAvailable: true, worksIndexed: 0, creatorsIndexed: 0,
            edgesWritten: 0, unresolvedRelations: derived.unresolvedRelations
        ) }
        let dbPool: DatabasePool
        do {
            dbPool = try await KnowledgeGraphPoolCache.shared.pool(at: sqlitePath)
        } catch KnowledgeGraphPoolCache.PoolError.databaseMissing {
            return .unavailable
        }
        let stamp = KnowledgeGraphStore.orderingTimestamp(now)
        let works = derived.works
        let creators = derived.creators
        let edges = derived.edges
        let unresolved = derived.unresolvedRelations

        // User, 2026-09-06: every id this pass could mint deterministically. The
        // name+type fallback must never hand one key the row that IS another
        // key's derived id — after a migration off the title-only key, the
        // first creator can be sitting on the legacy row while the second holds
        // its derived one, and the fallback (ORDER BY mention_count) would then
        // pick that derived row for the wrong key on a later pass. Both keys
        // would resolve to one id and the edge between them would die at the
        // `fromID != toID` guard below.
        let reservedDerivedIDs = Set(
            (Array(works.keys) + Array(creators.keys)).map(Self.studioEntityID(forKey:))
        )
        return try await dbPool.write { db in
            var idByKey: [String: String] = [:]
            for key in works.keys.sorted() {
                guard let work = works[key] else { continue }
                idByKey[key] = try Self.upsertStudioEntity(
                    db,
                    key: key,
                    name: work.name,
                    type: Self.studioWorkEntityType,
                    summary: work.summary,
                    mentionCount: work.entryIDs.count,
                    firstSeen: work.firstSeen,
                    lastSeen: work.lastSeen,
                    now: stamp,
                    claimedIDs: Set(idByKey.values),
                    reservedDerivedIDs: reservedDerivedIDs
                )
            }
            for key in creators.keys.sorted() {
                guard let creator = creators[key] else { continue }
                idByKey[key] = try Self.upsertStudioEntity(
                    db,
                    key: key,
                    name: creator.name,
                    type: Self.studioCreatorEntityType,
                    summary: nil,
                    mentionCount: creator.entryIDs.count,
                    firstSeen: creator.firstSeen,
                    lastSeen: creator.lastSeen,
                    now: stamp,
                    claimedIDs: Set(idByKey.values),
                    reservedDerivedIDs: reservedDerivedIDs
                )
            }
            var edgesWritten = 0
            var creatorIDsByWorkID: [String: Set<String>] = [:]
            // Work keys whose derived creator edges did NOT all get written
            // (an id this pass could not resolve without stealing another
            // key's). Their existing edges are the only record of that
            // creator, so the cleanup below leaves them alone.
            var incompleteCreatorWorkKeys = Set<String>()
            for edge in edges.keys.sorted(by: {
                ($0.fromKey, $0.toKey, $0.type) < ($1.fromKey, $1.toKey, $1.type)
            }) {
                guard let fromID = idByKey[edge.fromKey],
                      let toID = idByKey[edge.toKey],
                      fromID != toID,
                      let entryIDs = edges[edge] else {
                    if edge.type == Self.studioCreatedByRelationType {
                        incompleteCreatorWorkKeys.insert(edge.fromKey)
                    }
                    continue
                }
                try Self.upsertStudioRelationship(
                    db,
                    fromID: fromID,
                    toID: toID,
                    type: edge.type,
                    entryIDs: entryIDs,
                    now: stamp
                )
                if edge.type == Self.studioCreatedByRelationType {
                    creatorIDsByWorkID[fromID, default: []].insert(toID)
                }
                edgesWritten += 1
            }
            // User, 2026-09-06: a work re-keyed off the title-only identity gets
            // its former node back through the name/type fallback — and that
            // node still carries the `created_by` edges the old identity minted.
            // This pass re-derives the WHOLE journal, so the creators it just
            // linked are the work's creators; any other studio-written
            // `created_by` edge out of that node names a creator the current
            // identity does not have. Studio-written only, by the indexer stamp:
            // a creator edge another writer put there is not this pass's to
            // retire.
            for key in works.keys.sorted() {
                guard let workID = idByKey[key],
                      !incompleteCreatorWorkKeys.contains(key) else { continue }
                let keep = Array(creatorIDsByWorkID[workID] ?? []).sorted()
                let keepPlaceholders = keep.map { _ in "?" }.joined(separator: ", ")
                try db.execute(
                    sql: """
                        DELETE FROM kg_relationships
                        WHERE from_id = ?
                          AND type = ?
                          AND json_extract(metadata_json, '$.indexer') = ?
                          \(keep.isEmpty ? "" : "AND to_id NOT IN (\(keepPlaceholders))")
                        """,
                    arguments: StatementArguments(
                        [workID, Self.studioCreatedByRelationType, Self.studioIndexVersion] + keep
                    )
                )
            }
            return StudioGraphIndexReport(
                graphAvailable: true,
                worksIndexed: works.count,
                creatorsIndexed: creators.count,
                edgesWritten: edgesWritten,
                unresolvedRelations: unresolved
            )
        }
    }

    // MARK: - Encounter intake (desk 903 phase 1)

    /// Works the graph holds that the journal has never answered.
    ///
    /// The second intake source: "a KG work entity with no journal entry." It is
    /// a live query over `kg_entities`, not a stub — it returns rows the moment
    /// a work reaches the graph from anywhere other than the journal (a memory
    /// naming one, a future museum lane). While the journal is the only writer
    /// of `work` entities it returns nothing, and that is the correct answer,
    /// not a missing feature: no intake means no encounter, by design.
    ///
    /// `journaledWorks` are `SwiftNativeStudioStore.journaledWorkIdentity`
    /// keys — title BY SOMEONE, folded — from the journal. The caller owns the
    /// journal, this owns the graph, and neither reaches into the other.
    public func unjournaledWorkCandidates(
        journaledWorks: Set<String>,
        limit: Int = 20
    ) async throws -> [StudioEncounterCandidate] {
        guard limit > 0 else { return [] }
        let dbPool: DatabasePool
        do {
            dbPool = try await KnowledgeGraphPoolCache.shared.pool(at: sqlitePath)
        } catch KnowledgeGraphPoolCache.PoolError.databaseMissing {
            return []
        }
        let workType = Self.studioWorkEntityType
        let creatorRelation = Self.studioCreatedByRelationType
        let rows = try dbPool.read { db in
            try Row.fetchAll(db, sql: """
                SELECT e.id AS id, e.name AS name, e.first_seen AS first_seen,
                       (SELECT c.name FROM kg_relationships r
                          JOIN kg_entities c ON c.id = r.to_id
                         WHERE r.from_id = e.id AND r.type = ?
                         LIMIT 1) AS creator
                FROM kg_entities e
                WHERE lower(e.type) = lower(?)
                  AND TRIM(COALESCE(e.name, '')) <> ''
                ORDER BY e.first_seen ASC, e.id ASC
                LIMIT ?
                """, arguments: [creatorRelation, workType, limit * 4])
        }
        var candidates: [StudioEncounterCandidate] = []
        for row in rows {
            guard candidates.count < limit else { break }
            let name = Self.studioClean(row["name"] ?? "")
            guard !name.isEmpty else { continue }
            let creator = (row["creator"] as String?).map(Self.studioClean)
            // User, 2026-09-06: title BY SOMEONE. Suppressing on the folded title
            // alone hid a work she has never answered because a different work
            // by a different creator shares its title.
            guard !journaledWorks.contains(SwiftNativeStudioStore.journaledWorkIdentity(
                title: name, creator: creator)) else { continue }
            candidates.append(StudioEncounterCandidate(
                source: .unjournaledWork,
                title: name,
                creator: creator,
                originID: row["id"] ?? name,
                noticedAt: Self.studioClean(row["first_seen"] ?? "")
            ))
        }
        return candidates
    }

    // MARK: - Pure derivation

    struct StudioNode {
        var name: String
        var summary: String?
        var entryIDs: [String] = []
        var firstSeen: String = ""
        var lastSeen: String = ""
    }

    struct StudioDerivedGraph {
        var works: [String: StudioNode] = [:]
        var creators: [String: StudioNode] = [:]
        var edges: [StudioDerivedEdge: [String]] = [:]
        var unresolvedRelations = 0
    }

    /// Journal → nodes and typed edges. PURE: no I/O, no clock, no SQL. The
    /// whole shape of the studio subgraph is decided here so it can be tested
    /// without a database.
    static func deriveStudioGraph(from entries: [StudioJournalEntry]) -> StudioDerivedGraph {
        var graph = StudioDerivedGraph()
        // entry id → the work key that entry is ABOUT. A relation names an
        // earlier ENTRY; the edge it becomes is between the two WORKS, because
        // an entry is one act of judgment and the work is what persists.
        var workKeyByEntry: [String: String] = [:]

        for entry in entries {
            let title = studioClean(entry.work.title)
            guard !title.isEmpty else { continue }
            let creatorName = studioClean(entry.work.creator ?? "")
            let workKey = studioWorkNodeKey(title: title, creator: creatorName)
            workKeyByEntry[entry.id] = workKey

            var work = graph.works[workKey] ?? StudioNode(
                name: title,
                summary: studioClean(entry.work.medium ?? "").isEmpty
                    ? nil
                    : studioClean(entry.work.medium ?? "")
            )
            work.entryIDs.append(entry.id)
            work.firstSeen = work.firstSeen.isEmpty
                ? entry.recordedAt
                : min(work.firstSeen, entry.recordedAt)
            work.lastSeen = max(work.lastSeen, entry.recordedAt)
            if work.summary == nil, !studioClean(entry.work.medium ?? "").isEmpty {
                work.summary = studioClean(entry.work.medium ?? "")
            }
            graph.works[workKey] = work

            guard !creatorName.isEmpty else { continue }
            let creatorKey = studioNodeKey(type: studioCreatorEntityType, name: creatorName)
            var creator = graph.creators[creatorKey] ?? StudioNode(name: creatorName, summary: nil)
            creator.entryIDs.append(entry.id)
            creator.firstSeen = creator.firstSeen.isEmpty
                ? entry.recordedAt
                : min(creator.firstSeen, entry.recordedAt)
            creator.lastSeen = max(creator.lastSeen, entry.recordedAt)
            graph.creators[creatorKey] = creator
            graph.edges[
                StudioDerivedEdge(
                    fromKey: workKey, toKey: creatorKey, type: studioCreatedByRelationType
                ),
                default: []
            ].append(entry.id)
        }

        for entry in entries {
            guard let fromKey = workKeyByEntry[entry.id] else { continue }
            for relation in entry.relations {
                guard let toKey = workKeyByEntry[relation.entryId] else {
                    graph.unresolvedRelations += 1
                    continue
                }
                // A later entry about the SAME work deepening an earlier one is
                // a real and common shape, but the graph has no self-loops: the
                // relation survives as the entry's own provenance line, and the
                // edge would say nothing the entity does not already say.
                guard fromKey != toKey else { continue }
                graph.edges[
                    StudioDerivedEdge(fromKey: fromKey, toKey: toKey, type: relation.kind.rawValue),
                    default: []
                ].append(entry.id)
            }
        }

        for key in graph.edges.keys {
            graph.edges[key] = Array(
                studioUnique(graph.edges[key] ?? []).prefix(studioMaximumEntryIDsPerEdge)
            )
        }
        return graph
    }

    /// User, 2026-09-06: a WORK is a title BY SOMEONE, not a title. Keying works
    /// on the title alone merged two unrelated works that happen to share one
    /// ("Untitled", "Study", a remake and its original) into a single node —
    /// and a relation drawn between them came out as `fromKey == toKey` and was
    /// silently dropped by the self-loop guard, so the one edge that recorded
    /// the connection disappeared. Creator is the discriminator; medium/date
    /// stay OUT of the key because they are optional per entry, and a work
    /// journaled once with a medium and once without would split into two nodes
    /// — the same wrong-identity failure in the other direction.
    static func studioWorkNodeKey(title: String, creator: String) -> String {
        studioNodeKey(type: studioWorkEntityType, name: title)
            + "|" + studioFold(creator)
    }

    /// Stable node key: type + case/diacritic-folded name. Two entries about
    /// "the green ray" and "The Green Ray" are one work.
    static func studioNodeKey(type: String, name: String) -> String {
        "\(type.lowercased())|\(studioFold(name))"
    }

    /// Deterministic entity id derived from the node key, so re-indexing after a
    /// row was deleted mints the SAME id rather than a second node for one work.
    static func studioEntityID(forKey key: String) -> String {
        let digest = SHA256.hash(data: Data(key.utf8))
        return "studio_" + digest.map { String(format: "%02x", $0) }.joined().prefix(16)
    }

    static func studioClean(_ value: String) -> String {
        value.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func studioUnique(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.filter { seen.insert($0).inserted }
    }

    // MARK: - SQL

    /// Upsert by the DETERMINISTIC id, then fall back to a name+type match so a
    /// work the memory lane already knows under another id is reused rather than
    /// duplicated.
    ///
    /// Returns nil when no id can be used for this key without stealing one
    /// another key already resolved to in this pass. The caller then holds no id
    /// for the key and its edges are skipped — a missing edge is recoverable on
    /// the next re-derive; two works collapsed into one node is not.
    private static func upsertStudioEntity(
        _ db: Database,
        key: String,
        name: String,
        type: String,
        summary: String?,
        mentionCount: Int,
        firstSeen: String,
        lastSeen: String,
        now: String,
        claimedIDs: Set<String>,
        reservedDerivedIDs: Set<String>
    ) throws -> String? {
        let derivedID = studioEntityID(forKey: key)
        let derivedRowExists = try Row.fetchOne(
            db, sql: "SELECT id FROM kg_entities WHERE id = ?", arguments: [derivedID]
        ) != nil
        // User, 2026-09-06: claiming applies to EVERY branch, not just the
        // fallback. Two keys resolving to one id re-collapses the nodes and the
        // edge between them dies at the `fromID != toID` guard.
        if derivedRowExists, claimedIDs.contains(derivedID) { return nil }
        let existingID: String? = try {
            if derivedRowExists { return derivedID }
            let row = try Row.fetchOne(db, sql: """
                SELECT id FROM kg_entities
                WHERE lower(name) = lower(?) AND lower(type) = lower(?)
                ORDER BY mention_count DESC, last_seen DESC
                LIMIT 1
                """, arguments: [name, type])
            // The name+type fallback exists to reuse a row the memory lane
            // already minted for this work. It must not hand this key a row
            // another node has already claimed in this pass, nor one that IS
            // another key's derived id — that row belongs to that key even when
            // this pass reaches it first.
            guard let id: String = row?["id"],
                  !claimedIDs.contains(id),
                  !reservedDerivedIDs.contains(id) else { return nil }
            return id
        }()
        let metadata = studioMetadataJSON([
            "indexer": .string(studioIndexVersion),
            createdByKey: .string(studioIndexVersion),
            "studio_node_key": .string(key),
        ])
        guard let existingID else {
            try db.execute(sql: """
                INSERT INTO kg_entities
                    (id, name, type, summary, aliases_json, mention_count,
                     first_seen, last_seen, provenance, metadata_json)
                VALUES (?, ?, ?, ?, NULL, ?, ?, ?, ?, ?)
                """, arguments: [
                    derivedID, name, type, summary, mentionCount,
                    firstSeen.isEmpty ? now : firstSeen,
                    lastSeen.isEmpty ? now : lastSeen,
                    studioProvenance, metadata,
                ])
            return derivedID
        }
        // SET, never increment — this pass re-derives the whole journal, so an
        // increment would inflate on every append.
        try db.execute(sql: """
            UPDATE kg_entities
            SET name = ?, mention_count = ?,
                summary = COALESCE(?, summary),
                first_seen = COALESCE(NULLIF(first_seen, ''), ?),
                last_seen = ?,
                provenance = COALESCE(provenance, ?),
                metadata_json = ?
            WHERE id = ?
            """, arguments: [
                name, mentionCount, summary,
                firstSeen.isEmpty ? now : firstSeen,
                lastSeen.isEmpty ? now : lastSeen,
                studioProvenance, metadata, existingID,
            ])
        return existingID
    }

    private static func upsertStudioRelationship(
        _ db: Database,
        fromID: String,
        toID: String,
        type: String,
        entryIDs: [String],
        now: String
    ) throws {
        let metadata = studioMetadataJSON([
            "indexer": .string(studioIndexVersion),
            "studio_entry_ids": .array(entryIDs.map { .string($0) }),
            "last_seen": .string(now),
        ])
        // Evidence count, not taste: 0.5 for one entry asserting the edge,
        // rising to 1.0 at ten. Deterministic, so a re-derive is a no-op.
        let weight = min(1.0, 0.5 + 0.05 * Double(max(0, entryIDs.count - 1)))
        try db.execute(sql: """
            INSERT INTO kg_relationships
                (from_id, to_id, type, weight, mention_count, provenance, metadata_json)
            VALUES (?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(from_id, to_id, type) DO UPDATE SET
                weight = excluded.weight,
                mention_count = excluded.mention_count,
                provenance = COALESCE(kg_relationships.provenance, excluded.provenance),
                metadata_json = excluded.metadata_json
            """, arguments: [
                fromID, toID, type, weight, entryIDs.count, studioProvenance, metadata,
            ])
    }

    private static func studioMetadataJSON(_ object: [String: JSONValue]) -> String {
        (try? JSONValue.object(object).serialize(pretty: false)) ?? "{}"
    }
}
