// The graph half of clause-6 reach: typed relations as SELECTABLE context.
//
// `KnowledgeGraph+RelatedEntities.swift` answers "what does this recalled
// memory touch?" for Context-off recall's `related:`
// garnish. This file answers the question the resident index needs instead:
// "what typed edges does the graph hold, ranked, so the selector can pull the
// ones this message is actually about?" Nothing here injects anything; it hands
// the projection a bounded, ordered list and stops.
//
// ── WHY ENTITY→ENTITY ONLY ───────────────────────────────────────────────────
// `indexActiveFact` writes user-to-fact and structural mentions edges, excluded
// here so memory text is not projected twice. Typed entity-to-entity claims
// from Studio or imported graph data remain selectable under the same caps.
//
// ── PRIVACY ──────────────────────────────────────────────────────────────────
// Entity NAMES only — never a memory body, never a fact node. The projection
// publishes these at the same privacy/surface tier the memory lane defaults to.

import Foundation
import GRDB
import PersistenceCore
import NativeAgentShared
// Blueprint: | `KnowledgeGraph+ContextRelations.swift` | Bounded typed entity relations with disclosure and provenance evidence |

/// One typed entity→entity edge, resolved to names.
public struct KnowledgeGraphContextRelation: Sendable, Equatable {
    public let subjectID: String
    public let subject: String
    public let predicate: String
    public let objectID: String
    public let object: String
    public let weight: Double
    public let mentionCount: Int
    /// ISO-8601 `last_seen` of the fresher endpoint after validating both;
    /// nil when absent or unavailable. Edges have no timestamp of their own.
    public let lastSeen: String?
    /// Canonical endpoint validation failure; no sibling date can conceal it.
    public let sourceDateFailure: String?
    /// The edge's `provenance` column — who claims it. Memory-derived edges
    /// leave this nil; a studio edge says `studio-journal`.
    public let provenance: String?
    /// Journal entry ids asserting this edge, from
    /// `metadata_json.studio_entry_ids`. Empty for every non-studio edge.
    ///
    /// Studio claims retain their journal evidence under the same reader, caps and endpoint scoping.
    public let journalEntryIDs: [String]
    /// The memory that last asserted this edge (`last_memory_id`); nil for an
    /// edge no memory wrote. The projection checks its disclosure and tracks it.
    public let memoryID: String?
    /// That memory's version (`updated_at`) when the edge was read.
    public let memoryVersion: String?

    public init(
        subjectID: String,
        subject: String,
        predicate: String,
        objectID: String,
        object: String,
        weight: Double,
        mentionCount: Int,
        lastSeen: String?,
        sourceDateFailure: String? = nil,
        provenance: String? = nil,
        journalEntryIDs: [String] = [],
        memoryID: String? = nil,
        memoryVersion: String? = nil
    ) {
        self.subjectID = subjectID
        self.subject = subject
        self.predicate = predicate
        self.objectID = objectID
        self.object = object
        self.weight = weight
        self.mentionCount = mentionCount
        self.lastSeen = lastSeen
        self.sourceDateFailure = sourceDateFailure
        self.provenance = provenance
        self.journalEntryIDs = journalEntryIDs
        self.memoryID = memoryID
        self.memoryVersion = memoryVersion
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
        if try MemoryPolicyGate.knowledgeGraphEnabled(
            dataRoot: sqlitePath.deletingLastPathComponent().deletingLastPathComponent()) {
            _ = try await reconcileMemoryIndexFingerprints()
        }
        let prefix = Self.memoryFactIDPrefix
        // Read a bounded superset so the per-subject cap has something to
        // choose from without ever streaming the whole edge table.
        let readLimit = min(4_096, min(4_096, total) * 8)
        // Keep GRDB rows on the database executor; return only Sendable values.
        return try await dbPool.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT
                    r.from_id AS from_id, r.to_id AS to_id, r.type AS type,
                    COALESCE(r.weight, 0.5) AS weight,
                    COALESCE(r.mention_count, 0) AS mention_count,
                    ef.name AS from_name, et.name AS to_name,
                    ef.last_seen AS from_seen, et.last_seen AS to_seen,
                    r.provenance AS provenance,
                    json_extract(r.metadata_json, '$.studio_entry_ids') AS studio_entry_ids,
                    json_extract(r.metadata_json, '$.last_memory_id') AS memory_id,
                    (SELECT COALESCE(m.updated_at, m.created_at) FROM memories m
                     WHERE m.id = json_extract(r.metadata_json, '$.last_memory_id')) AS memory_version
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
                var dates: [Date] = []
                var dateFailures: [String] = []
                for (id, column) in [(subjectID, "from_seen"), (objectID, "to_seen")] {
                    let stored: DatabaseValue = row[column]
                    if stored.isNull { continue }
                    guard case .string(let raw) = stored.storage,
                          let date = NativeTimestampFormat.parseISO8601FractionalFirst(raw) else {
                        dateFailures.append("Graph entity \(id) has an invalid last_seen date; repair its canonical record.")
                        continue
                    }
                    dates.append(date)
                }
                let dateFailure = dateFailures.isEmpty ? nil : dateFailures.joined(separator: " ")
                let seen = dateFailure == nil ? dates.max().map(NativeTimestampFormat.fractionalZulu) : nil
                result.append(KnowledgeGraphContextRelation(
                    subjectID: subjectID,
                    subject: subject,
                    predicate: predicate,
                    objectID: objectID,
                    object: object,
                    weight: (row["weight"] as Double?) ?? 0.5,
                    mentionCount: (row["mention_count"] as Int?) ?? 0,
                    lastSeen: seen,
                    sourceDateFailure: dateFailure,
                    provenance: {
                        let value = Self.trimmed(row["provenance"])
                        return value.isEmpty ? nil : value
                    }(),
                    journalEntryIDs: Array(try Self.studioParseEntryIDs(row["studio_entry_ids"]).sorted().prefix(24)),
                    memoryID: {
                        let value = Self.trimmed(row["memory_id"])
                        return value.isEmpty ? nil : value
                    }(),
                    memoryVersion: row["memory_version"]
                ))
            }
            return result
        }
    }

    private static func trimmed(_ value: String?) -> String {
        (value ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

}
