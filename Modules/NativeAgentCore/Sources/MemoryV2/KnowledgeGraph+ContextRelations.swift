// Expose bounded, ranked entity-to-entity claims as selectable context, never injection. Exclude structural memory edges to avoid projecting memory text twice.
// Return entity names only at the memory projection's privacy/surface tier.

import Foundation
import GRDB
import PersistenceCore
import NativeAgentShared
// Blueprint: | `KnowledgeGraph+ContextRelations.swift` | Bounded typed entity relations with disclosure and provenance evidence |

public struct KnowledgeGraphContextRelation: Sendable, Equatable {
    public let subjectID: String
    public let subject: String
    public let predicate: String
    public let objectID: String
    public let object: String
    public let weight: Double
    public let mentionCount: Int
    /// Edges have no timestamp; use the fresher endpoint only after validating both, with nil for absent or unavailable evidence.
    public let lastSeen: String?
    /// Canonical endpoint validation failure; no sibling date can conceal it.
    public let sourceDateFailure: String?
    /// Keep the edge's own provenance: studio claims name `studio-journal`; memory-derived edges leave it nil.
    public let provenance: String?
    /// Studio claims retain journal entry IDs as evidence under the same reader, caps and endpoint scoping.
    public let journalEntryIDs: [String]
    /// The memory that last asserted this edge (`last_memory_id`); nil for an edge no memory wrote. The projection checks its disclosure and tracks it.
    public let memoryID: String?
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

    /// Structural mentions edges are plumbing rather than claims and must not be projected.
    static let structuralRelationType = "mentions"

    /// Evidence-first ordering keeps best-attested edges under caps; per-subject limits stop a hub consuming the whole budget. Missing storage means nothing
    /// indexed; unreadable storage throws.
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
        // Read a bounded superset so the per-subject cap has something to choose from without ever streaming the whole edge table.
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
