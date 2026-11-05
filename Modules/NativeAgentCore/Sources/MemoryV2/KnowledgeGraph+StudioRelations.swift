// Derive work identity from title plus creator and cite asserting journal entry IDs on every edge. Rederive the whole bounded journal with SET semantics so
// appends and backfill stay idempotent. Weight counts evidence, never taste. Studio provenance, its distinct indexer stamp and absence of `last_memory_id` keep
// these rows outside memory rebuild, orphan GC and stale-entity deletion.

import CryptoKit
import Foundation
import GRDB
import PersistenceCore
import Studio
// Blueprint: | `KnowledgeGraph+StudioRelations.swift` | Studio journal relation publication with its own provenance |

/// Return actual write counts so callers can report evidence.
public struct StudioGraphIndexReport: Sendable, Equatable {
    /// Missing memory storage means graph projection is unavailable, not a failed journal write.
    public var graphAvailable: Bool
    public var worksIndexed: Int
    public var creatorsIndexed: Int
    public var edgesWritten: Int
    /// Count dangling journal links explicitly; missing entries cannot supply invented endpoints.
    public var unresolvedRelations: Int

    public static let unavailable = StudioGraphIndexReport(
        graphAvailable: false, worksIndexed: 0, creatorsIndexed: 0,
        edgesWritten: 0, unresolvedRelations: 0
    )
}

extension SwiftNativeKnowledgeGraphIndexer {

    /// Use a distinct studio stamp so memory rebuild's owned-row deletion cannot reach these rows.
    public static let studioIndexVersion = "swift-studio-kg-v1"
    /// Explicit studio provenance keeps these rows outside stale-entity deletion.
    public static let studioProvenance = "studio-journal"
    public static let studioWorkEntityType = "work"
    public static let studioCreatorEntityType = "creator"
    public static let studioCreatedByRelationType = "created_by"
    /// Rederive idempotently while the caller holds the journal flock through commit, preventing stale evidence from overwriting newer entries. Missing memory
    /// storage returns unavailable; this writer never creates it.
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

        // Reserve every derived id so name/type matching cannot assign another key's node.
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
            // Unresolved creator IDs must retain existing edges because those edges may be the only record of the creator.
            var incompleteCreatorWorkKeys = Set<String>()
            for edge in edges.keys.sorted(by: {
                ($0.from, $0.to, $0.type) < ($1.from, $1.to, $1.type)
            }) {
                guard let fromID = idByKey[edge.from],
                      let toID = idByKey[edge.to],
                      fromID != toID,
                      let entryIDs = edges[edge] else {
                    if edge.type == Self.studioCreatedByRelationType {
                        incompleteCreatorWorkKeys.insert(edge.from)
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
            // Retire only studio-owned created_by edges absent from this work's current creators.
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

    // MARK: - Encounter intake

    /// Query graph works without journal encounters using title-plus-creator keys supplied by the journal owner. Empty intake is valid when every graph work is
    /// already journaled.
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
        // Convert database-owned rows before crossing the async boundary.
        return try await dbPool.read { db in
            let rows = try Row.fetchCursor(db, sql: """
                SELECT e.id AS id, e.name AS name, e.first_seen AS first_seen,
                       (SELECT c.name FROM kg_relationships r
                          JOIN kg_entities c ON c.id = r.to_id
                         WHERE r.from_id = e.id AND r.type = ?
                         LIMIT 1) AS creator
                FROM kg_entities e
                WHERE lower(e.type) = lower(?)
                  AND TRIM(COALESCE(e.name, '')) <> ''
                ORDER BY e.first_seen ASC, e.id ASC
                """, arguments: [creatorRelation, workType])
            var candidates: [StudioEncounterCandidate] = []
            while candidates.count < limit, let row = try rows.next() {
                let name = Self.studioClean(row["name"] ?? "")
                guard !name.isEmpty else { continue }
                let creator = (row["creator"] as String?).map(Self.studioClean)
                // Suppress by title + creator so same-title works remain distinct.
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
        var edges: [StudioEdgeKey: [String]] = [:]
        var unresolvedRelations = 0
    }

    /// Derive journal nodes and edges without I/O, clocks or SQL so storage cannot alter their identity.
    static func deriveStudioGraph(from entries: [StudioJournalEntry]) -> StudioDerivedGraph {
        var graph = StudioDerivedGraph()
        // Entry relations become work edges because judgments are acts while work identity persists.
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
                StudioEdgeKey(
                    from: workKey, to: creatorKey, type: studioCreatedByRelationType
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
                // Keep same-work deepening as journal provenance: a self-loop adds no evidence beyond the entity.
                guard fromKey != toKey else { continue }
                graph.edges[
                    StudioEdgeKey(from: fromKey, to: toKey, type: relation.kind.rawValue),
                    default: []
                ].append(entry.id)
            }
        }

        for key in Array(graph.edges.keys) {
            graph.edges[key] = studioUnique(graph.edges[key] ?? [])
        }
        return graph
    }

    /// Work identity is title plus creator; medium and date never split it.
    static func studioWorkNodeKey(title: String, creator: String) -> String {
        studioNodeKey(type: studioWorkEntityType, name: title)
            + "|" + studioFold(creator)
    }

    /// Fold case and diacritics so spelling variants identify one node.
    static func studioNodeKey(type: String, name: String) -> String {
        "\(type.lowercased())|\(studioFold(name))"
    }

    /// Derive IDs from stable keys so reindexing cannot duplicate a deleted-and-recreated work.
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

    /// Resolve deterministic IDs and existing name/type identities without stealing another key's node. Skip unresolved edges: later derivation can repair
    /// missing evidence, but merging distinct works loses identity.
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
        // Reject IDs another key already owns on every resolution path.
        if derivedRowExists, claimedIDs.contains(derivedID) { return nil }
        let existingID: String? = try {
            if derivedRowExists { return derivedID }
            let row = try Row.fetchOne(db, sql: """
                SELECT id FROM kg_entities
                WHERE lower(name) = lower(?) AND lower(type) = lower(?)
                ORDER BY mention_count DESC, last_seen DESC
                LIMIT 1
                """, arguments: [name, type])
            // Name/type reuse must respect claimed and reserved derived IDs so visitation order cannot merge distinct keys.
            guard let id: String = row?["id"],
                  !claimedIDs.contains(id),
                  !reservedDerivedIDs.contains(id) else { return nil }
            return id
        }()
        let metadata = try studioMetadataJSON([
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
        // SET, never increment — this pass re-derives the whole journal, so an increment would inflate on every append.
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
        let metadata = try studioMetadataJSON([
            "indexer": .string(studioIndexVersion),
            "studio_entry_ids": .array(entryIDs.map { .string($0) }),
            "last_seen": .string(now),
        ])
        // Evidence count, not taste: 0.5 for one entry asserting the edge, rising to 1.0 at ten. Deterministic, so a re-derive is a no-op.
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

    private static func studioMetadataJSON(_ object: [String: JSONValue]) throws -> String {
        try JSONValue.object(object).serialize(pretty: false)
    }
}
