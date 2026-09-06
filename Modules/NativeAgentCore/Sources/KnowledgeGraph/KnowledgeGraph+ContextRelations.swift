// The graph half of clause-6 reach: typed relations as SELECTABLE context.
//
// `KnowledgeGraph+RelatedEntities.swift` answers "what does this recalled
// memory touch?" and only exists for the legacy recall lane's `related:`
// garnish. This file answers the question the resident index needs instead:
// "what typed edges does the graph hold, ranked, so the selector can pull the
// ones this message is actually about?" Nothing here injects anything; it hands
// the projection a bounded, ordered list and stops.
//
// ── WHY ENTITY→ENTITY ONLY ───────────────────────────────────────────────────
// `indexActiveFact` writes three shapes of edge:
//   1. user --<typed>--> memory-fact node   (prefers / decided / wants / …)
//   2. user --mentions--> entity, fact --mentions--> entity  (structural)
//   3. entity --<typed>--> entity           (works_on / owns / knows / …)
// Only (3) says something the memory lane cannot already say. A memory-fact
// node's NAME is a rendering of the memory's own text, so projecting (1) would
// duplicate a memory atom's body into a second atom competing for the same
// packet slot; (2) is the indexer's own plumbing, present on essentially every
// entity pair, and carries no meaning to select on. Both are excluded here
// rather than downstream so the caps below bound real triples.
//
// ── PRIVACY ──────────────────────────────────────────────────────────────────
// Entity NAMES only — never a memory body, never a fact node. The projection
// publishes these at the same privacy/surface tier the memory lane defaults to.

import Foundation
import GRDB
import PersistenceCore

/// One typed entity→entity edge, resolved to names.
public struct KnowledgeGraphContextRelation: Sendable, Equatable {
    public let subjectID: String
    public let subject: String
    public let predicate: String
    public let objectID: String
    public let object: String
    public let weight: Double
    public let mentionCount: Int
    /// ISO-8601 `last_seen` of the fresher endpoint; nil when neither carries
    /// one. Edges have no timestamp of their own.
    public let lastSeen: String?
    /// The edge's `provenance` column — who claims it. Memory-derived edges
    /// leave this nil; a studio edge says `studio-journal`.
    public let provenance: String?
    /// Journal entry ids asserting this edge, from
    /// `metadata_json.studio_entry_ids`. Empty for every non-studio edge.
    ///
    /// Studio edges are selectable exactly like the other 94 — same reader,
    /// same caps, same endpoint scoping. What they carry EXTRA is the entry
    /// that made the claim, so "this work deepens that one" can be traced back
    /// to the judgment she actually wrote instead of standing as an unsourced
    /// assertion in the graph.
    public let journalEntryIDs: [String]

    public init(
        subjectID: String,
        subject: String,
        predicate: String,
        objectID: String,
        object: String,
        weight: Double,
        mentionCount: Int,
        lastSeen: String?,
        provenance: String? = nil,
        journalEntryIDs: [String] = []
    ) {
        self.subjectID = subjectID
        self.subject = subject
        self.predicate = predicate
        self.objectID = objectID
        self.object = object
        self.weight = weight
        self.mentionCount = mentionCount
        self.lastSeen = lastSeen
        self.provenance = provenance
        self.journalEntryIDs = journalEntryIDs
    }
}

extension SwiftNativeKnowledgeGraphIndexer {

    /// Structural edge type written by `indexActiveFact` for every extracted
    /// entity. It is plumbing, not a claim, and is never projected.
    static let structuralRelationType = "mentions"

    /// Bounded, deterministically ordered typed relations for the resident
    /// context index.
    ///
    /// Ordering is evidence-first (`mention_count` desc, then `weight` desc,
    /// then a stable name/type tiebreak) so the caps keep the best-attested
    /// edges. `perSubjectLimit` bounds how much one hub entity — User touches
    /// most of the graph — can spend of `maximumRelations`.
    ///
    /// A missing database is an empty graph, not an error: nothing has been
    /// indexed yet. A genuinely unreadable one throws, and the caller decides.
    public func contextRelations(
        perSubjectLimit: Int = 4,
        maximumRelations: Int = 192
    ) async throws -> [KnowledgeGraphContextRelation] {
        let perSubject = max(1, perSubjectLimit)
        let total = max(0, maximumRelations)
        guard total > 0 else { return [] }
        let dbPool: DatabasePool
        do {
            dbPool = try await KnowledgeGraphPoolCache.shared.pool(at: sqlitePath)
        } catch KnowledgeGraphPoolCache.PoolError.databaseMissing {
            return []
        }
        let prefix = Self.memoryFactIDPrefix
        // Read a bounded superset so the per-subject cap has something to
        // choose from without ever streaming the whole edge table.
        let readLimit = min(4_096, total * 8)
        let rows = try await dbPool.read { db in
            try Row.fetchAll(db, sql: """
                SELECT
                    r.from_id AS from_id, r.to_id AS to_id, r.type AS type,
                    COALESCE(r.weight, 0.5) AS weight,
                    COALESCE(r.mention_count, 0) AS mention_count,
                    ef.name AS from_name, et.name AS to_name,
                    ef.last_seen AS from_seen, et.last_seen AS to_seen,
                    r.provenance AS provenance,
                    json_extract(r.metadata_json, '$.studio_entry_ids') AS studio_entry_ids
                FROM kg_relationships r
                JOIN kg_entities ef ON ef.id = r.from_id
                JOIN kg_entities et ON et.id = r.to_id
                WHERE r.type <> ?
                  AND SUBSTR(r.from_id, 1, ?) <> ?
                  AND SUBSTR(r.to_id, 1, ?) <> ?
                  AND TRIM(COALESCE(r.type, '')) <> ''
                  AND TRIM(COALESCE(ef.name, '')) <> ''
                  AND TRIM(COALESCE(et.name, '')) <> ''
                  AND r.from_id <> r.to_id
                ORDER BY mention_count DESC, weight DESC,
                         from_name ASC, type ASC, to_name ASC
                LIMIT ?
                """, arguments: [
                    Self.structuralRelationType,
                    prefix.count, prefix,
                    prefix.count, prefix,
                    readLimit,
                ])
        }

        var perSubjectCount: [String: Int] = [:]
        var result: [KnowledgeGraphContextRelation] = []
        for row in rows {
            guard result.count < total else { break }
            let subjectID: String = row["from_id"] ?? ""
            let objectID: String = row["to_id"] ?? ""
            let subject = Self.trimmed(row["from_name"])
            let object = Self.trimmed(row["to_name"])
            let predicate = Self.trimmed(row["type"])
            guard !subjectID.isEmpty, !objectID.isEmpty,
                  !subject.isEmpty, !object.isEmpty, !predicate.isEmpty else { continue }
            guard perSubjectCount[subjectID, default: 0] < perSubject else { continue }
            perSubjectCount[subjectID, default: 0] += 1
            let seen = [Self.trimmed(row["from_seen"]), Self.trimmed(row["to_seen"])]
                .filter { !$0.isEmpty }
                .max()
            result.append(KnowledgeGraphContextRelation(
                subjectID: subjectID,
                subject: subject,
                predicate: predicate,
                objectID: objectID,
                object: object,
                weight: (row["weight"] as Double?) ?? 0.5,
                mentionCount: (row["mention_count"] as Int?) ?? 0,
                lastSeen: seen,
                provenance: {
                    let value = Self.trimmed(row["provenance"])
                    return value.isEmpty ? nil : value
                }(),
                journalEntryIDs: Self.studioEntryIDs(row["studio_entry_ids"])
            ))
        }
        return result
    }

    private static func trimmed(_ value: String?) -> String {
        (value ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// `json_extract` hands back the raw JSON text of an array. A malformed or
    /// absent value is an EMPTY provenance list, never an invented one.
    private static func studioEntryIDs(_ raw: String?) -> [String] {
        guard let raw, !raw.isEmpty, let data = raw.data(using: .utf8),
              let parsed = try? JSONValue.parse(data),
              case .array(let items) = parsed else { return [] }
        return items.compactMap {
            guard case .string(let value) = $0 else { return nil }
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
    }
}
