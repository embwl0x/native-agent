// Expose bounded, ranked entity-to-entity claims as selectable context, never injection. Exclude structural memory edges to avoid projecting memory text twice.
// Return entity names only at the memory projection's privacy/surface tier.

import SenseCore
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

    /// Structural edges are plumbing rather than claims and must not be projected: a memory naming a thing, and the person's edge to each
    /// thing a memory names (`personRelation`).
    static let structuralRelationTypes = ["mentions", "in_memory_about", "in_memory_from"]

    /// Evidence-first ordering keeps best-attested edges under caps; per-subject limits stop a hub consuming the whole budget. Missing storage means nothing
    /// indexed; unreadable storage throws.
    public func contextRelations(
        perSubjectLimit: Int = 4,
        maximumRelations: Int = 192
    ) async throws -> [KnowledgeGraphContextRelation] {
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
            try await reconcileMemoryIndexFingerprints()
        }
        return try await dbPool.read { db in
            try Self.indexedContextRelations(in: db, perSubject: max(1, perSubjectLimit), total: total)
        }
    }

    package struct AssociationMention: Sendable {
        package let memory: String
        package let entity: String
        package let entitySource: String?
    }

    package static func associationInputs(storage: MemoryStorage, perSubject: Int, total: Int) async throws
        -> (relations: [KnowledgeGraphContextRelation], mentions: [AssociationMention], sources: [String: String], studio: Set<StudioEdgeKey>) {
        let path = storage.path
        let identity = try resolvedExtractionIdentity(sqlitePath: path,
            profileURL: path.deletingLastPathComponent().appendingPathComponent("profile.json"), explicitPrimaryUserName: nil)
        let (relations, mentions, sources, studioKeys) = try await storage.dbPool.read { db in
            guard try !Self.contextIndexDrift(in: db, identity: identity) else {
                throw MemoryV2Error.underlying("Knowledge graph association awaits canonical reconciliation.")
            }
            let relations = try Self.indexedContextRelations(in: db, perSubject: perSubject, total: total)
            let mentions = try Row.fetchAll(db, sql: """
                SELECT f.id AS fact, json_extract(f.metadata_json, '$.memory_id') AS memory,
                       e.id AS entity, json_extract(e.metadata_json, '$.last_memory_id') AS source
                FROM kg_relationships r
                JOIN kg_entities f ON f.id = r.from_id
                JOIN kg_entities e ON e.id = r.to_id
                WHERE r.type = 'mentions' AND f.type = 'fact'
                  AND json_extract(f.metadata_json, '$.memory_id') = json_extract(r.metadata_json, '$.last_memory_id')
                  AND json_extract(f.metadata_json, '$.last_memory_id') = json_extract(f.metadata_json, '$.memory_id')
                  AND json_extract(e.metadata_json, '$.memory_id') IS NULL
                ORDER BY memory, entity
                """).compactMap { row -> AssociationMention? in
                    let memory: String = try row.decode(forColumn: "memory")
                    let fact: String = try row.decode(forColumn: "fact")
                    guard fact == Self.memoryFactEntityID(for: memory) else { return nil }
                    return try AssociationMention(memory: memory, entity: row.decode(forColumn: "entity"),
                                                  entitySource: row.decode(forColumn: "source"))
                }
            let ids = Set(relations.flatMap { [$0.subjectID, $0.objectID] })
            let keys = String(decoding: try JSONEncoder().encode(ids), as: UTF8.self)
            let endpoints = try Row.fetchAll(db, sql: """
                SELECT id, json_extract(metadata_json, '$.last_memory_id') AS source,
                       json_extract(metadata_json, '$.studio_node_key') AS studio
                FROM kg_entities WHERE id IN (SELECT value FROM json_each(?))
                """, arguments: [keys])
            var sources: [String: String] = [:], studio: [String: String] = [:]
            for row in endpoints {
                let id: String = try row.decode(forColumn: "id")
                sources[id] = try row.decode(forColumn: "source")
                studio[id] = try row.decode(forColumn: "studio")
            }
            return (relations, mentions, sources, studio)
        }
        var studio: Set<StudioEdgeKey> = []
        if relations.contains(where: { $0.provenance == studioProvenance }) {
            let entries = try await SwiftNativeStudioStore(dataRoot: path.deletingLastPathComponent().deletingLastPathComponent())
                .journalEntriesIncludingArchive()
            let claims = deriveStudioGraph(from: entries.filter { !$0.correctionsUnreadable }).edges
            for r in relations where r.provenance == studioProvenance && !r.journalEntryIDs.isEmpty {
                guard let from = studioKeys[r.subjectID], let to = studioKeys[r.objectID],
                      let ids = claims[StudioEdgeKey(from: from, to: to, type: r.predicate)],
                      r.mentionCount == ids.count, r.journalEntryIDs == Array(ids.sorted().prefix(24)) else { continue }
                studio.insert(StudioEdgeKey(from: r.subjectID, to: r.objectID, type: r.predicate))
            }
        }
        return (relations, mentions, sources, studio)
    }

    private static func indexedContextRelations(in db: Database, perSubject: Int, total: Int) throws -> [KnowledgeGraphContextRelation] {
        let prefix = Self.memoryFactIDPrefix
        // Read a bounded superset so the per-subject cap has something to choose from without ever streaming the whole edge table.
        let readLimit = min(4_096, min(4_096, total) * 8)
        // Keep GRDB rows on the database executor; return only Sendable values.
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
            WHERE r.type NOT IN (\(Self.structuralRelationTypes.map { _ in "?" }.joined(separator: ", ")))
              AND SUBSTR(r.from_id, 1, ?) <> ?
              AND SUBSTR(r.to_id, 1, ?) <> ?
              AND TRIM(COALESCE(r.type, '')) <> ''
              AND TRIM(COALESCE(ef.name, '')) <> ''
              AND TRIM(COALESCE(et.name, '')) <> ''
              AND r.from_id <> r.to_id
            ORDER BY mention_count DESC, weight DESC,
                     from_name ASC, type ASC, to_name ASC
            LIMIT ?
            """, arguments: StatementArguments(Self.structuralRelationTypes) + [
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

    private static func trimmed(_ value: String?) -> String {
        (value ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

}
