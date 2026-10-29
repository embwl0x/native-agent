// On the backfill trigger, check every journal relation against a graph edge citing its entry.
// Report mismatches without repairing the graph or blocking recall.
// Canon recurrence counts later journal entries corroborated by graph edges.
// Both operations are read-only against the graph.

import Foundation
import GRDB
import PersistenceCore
import Studio
// Blueprint: | `KnowledgeGraph+StudioRelationAudit.swift` | Checked Studio relation audit and reconciliation evidence |

/// One relation the journal asserts that the graph does not carry back.
public struct StudioRelationMismatch: Sendable, Equatable {
    public enum Reason: String, Sendable, Equatable {
        /// No edge of that type exists between the two works at all.
        case edgeMissing = "edge_missing"
        /// The edge exists but does not cite this entry as a source, so the
        /// claim's provenance points somewhere else.
        case entryNotCited = "entry_not_cited"
    }

    public var entryID: String
    public var relationKind: String
    public var fromWork: String
    public var toWork: String
    public var reason: Reason

    public init(
        entryID: String, relationKind: String,
        fromWork: String, toWork: String, reason: Reason
    ) {
        self.entryID = entryID
        self.relationKind = relationKind
        self.fromWork = fromWork
        self.toWork = toWork
        self.reason = reason
    }

    public func toJSON() -> JSONValue {
        .object([
            "entry_id": .string(entryID),
            "relation": .string(relationKind),
            "from_work": .string(fromWork),
            "to_work": .string(toWork),
            "reason": .string(reason.rawValue),
        ])
    }
}

public struct StudioRelationAuditReport: Sendable, Equatable {
    /// False when there is no `memory.sqlite` yet. A graph that has not been
    /// born cannot be inconsistent with anything.
    public var graphAvailable: Bool
    public var relationsChecked: Int
    /// A later entry about the SAME work, deepening an earlier one. The
    /// derivation deliberately writes no self-loop for these, so they are
    /// counted and excused rather than reported as missing.
    public var selfRelations: Int
    /// Relations naming an entry the journal does not contain. A fact about the
    /// journal, not a graph defect — reported separately so the two never blur.
    public var unresolvedRelations: Int
    public var mismatches: [StudioRelationMismatch]

    public static let unavailable = StudioRelationAuditReport(
        graphAvailable: false, relationsChecked: 0, selfRelations: 0,
        unresolvedRelations: 0, mismatches: []
    )

    /// Bound on how many mismatches one report carries. The count stays exact;
    /// the list is evidence, not a log.
    public static let maximumReportedMismatches = 20

    public var isConsistent: Bool { mismatches.isEmpty }

    public init(
        graphAvailable: Bool,
        relationsChecked: Int,
        selfRelations: Int,
        unresolvedRelations: Int,
        mismatches: [StudioRelationMismatch]
    ) {
        self.graphAvailable = graphAvailable
        self.relationsChecked = relationsChecked
        self.selfRelations = selfRelations
        self.unresolvedRelations = unresolvedRelations
        self.mismatches = Array(mismatches.prefix(Self.maximumReportedMismatches))
    }

    public func toJSON() -> JSONValue {
        .object([
            "graph_available": .bool(graphAvailable),
            "relations_checked": .int(Int64(relationsChecked)),
            "self_relations": .int(Int64(selfRelations)),
            "unresolved_relations": .int(Int64(unresolvedRelations)),
            "consistent": .bool(isConsistent),
            "mismatches": .array(mismatches.map { $0.toJSON() }),
        ])
    }
}

extension SwiftNativeKnowledgeGraphIndexer {

    /// Every studio edge the graph holds, as
    /// `(fromNodeKey, toNodeKey, type) → citing journal entry ids`.
    ///
    /// Endpoints use title + creator from `created_by`, including rows with title-only `studio_node_key` stamps.
    ///
    /// Restricted to `provenance = studio-journal`, so a same-named memory edge
    /// can never be mistaken for one of her claims.
    func studioEdgeCitations() async throws -> [StudioEdgeKey: Set<String>]? {
        let dbPool: DatabasePool
        do {
            dbPool = try await KnowledgeGraphPoolCache.shared.pool(at: sqlitePath)
        } catch KnowledgeGraphPoolCache.PoolError.databaseMissing {
            return nil
        }
        let creatorRelation = Self.studioCreatedByRelationType
        // Convert database-owned rows before crossing the async boundary.
        return try await dbPool.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT ef.name AS from_name, ef.type AS from_type,
                       (SELECT c.name FROM kg_relationships cr
                          JOIN kg_entities c ON c.id = cr.to_id
                         WHERE cr.from_id = ef.id AND cr.type = ?
                         LIMIT 1) AS from_creator,
                       et.name AS to_name, et.type AS to_type,
                       (SELECT c.name FROM kg_relationships cr
                          JOIN kg_entities c ON c.id = cr.to_id
                         WHERE cr.from_id = et.id AND cr.type = ?
                         LIMIT 1) AS to_creator,
                       r.type AS type,
                       json_extract(r.metadata_json, '$.studio_entry_ids') AS entry_ids
                FROM kg_relationships r
                JOIN kg_entities ef ON ef.id = r.from_id
                JOIN kg_entities et ON et.id = r.to_id
                WHERE r.provenance = ?
                """, arguments: [creatorRelation, creatorRelation, Self.studioProvenance])
            var result: [StudioEdgeKey: Set<String>] = [:]
            for row in rows {
                let from = Self.studioEndpointKey(
                    name: row["from_name"] ?? "", type: row["from_type"] ?? "",
                    creator: row["from_creator"]
                )
                let to = Self.studioEndpointKey(
                    name: row["to_name"] ?? "", type: row["to_type"] ?? "",
                    creator: row["to_creator"]
                )
                let type = Self.studioClean(row["type"] ?? "").lowercased()
                guard !from.isEmpty, !to.isEmpty, !type.isEmpty else { continue }
                let key = StudioEdgeKey(from: from, to: to, type: type)
                result[key, default: []].formUnion(Self.studioParseEntryIDs(row["entry_ids"]))
            }
            return result
        }
    }

    /// A graph row, keyed the way the writer keys the node it came from.
    static func studioEndpointKey(name: String, type: String, creator: String?) -> String {
        let cleanName = studioClean(name)
        let cleanType = studioClean(type).lowercased()
        guard !cleanName.isEmpty, !cleanType.isEmpty else { return "" }
        guard cleanType == studioWorkEntityType else {
            return studioNodeKey(type: cleanType, name: cleanName)
        }
        return studioWorkNodeKey(title: cleanName, creator: studioClean(creator ?? ""))
    }

    /// THE GUARD. Every relation on every entry must be carried by an edge that
    /// cites that entry. Reports; never repairs; never blocks anything.
    public func auditStudioRelations(
        _ entries: [StudioJournalEntry]
    ) async throws -> StudioRelationAuditReport {
        guard let citations = try await studioEdgeCitations() else { return .unavailable }
        var workByEntry: [String: (key: String, title: String)] = [:]
        for entry in entries {
            let title = Self.studioClean(entry.work.title)
            guard !title.isEmpty else { continue }
            // Self-relations compare title + creator so same-title works by different creators remain distinct.
            let creator = Self.studioClean(entry.work.creator ?? "")
            workByEntry[entry.id] = (
                Self.studioWorkNodeKey(title: title, creator: creator), title
            )
        }
        var checked = 0
        var selfRelations = 0
        var unresolved = 0
        var mismatches: [StudioRelationMismatch] = []
        for entry in entries {
            guard let from = workByEntry[entry.id] else { continue }
            for relation in entry.relations {
                guard let to = workByEntry[relation.entryId] else {
                    unresolved += 1
                    continue
                }
                guard from.key != to.key else {
                    selfRelations += 1
                    continue
                }
                checked += 1
                let key = StudioEdgeKey(
                    from: from.key, to: to.key, type: relation.kind.rawValue.lowercased()
                )
                guard let citing = citations[key] else {
                    mismatches.append(StudioRelationMismatch(
                        entryID: entry.id, relationKind: relation.kind.rawValue,
                        fromWork: from.title, toWork: to.title, reason: .edgeMissing
                    ))
                    continue
                }
                if !citing.contains(entry.id) {
                    mismatches.append(StudioRelationMismatch(
                        entryID: entry.id, relationKind: relation.kind.rawValue,
                        fromWork: from.title, toWork: to.title, reason: .entryNotCited
                    ))
                }
            }
        }
        return StudioRelationAuditReport(
            graphAvailable: true,
            relationsChecked: checked,
            selfRelations: selfRelations,
            unresolvedRelations: unresolved,
            mismatches: mismatches
        )
    }

    /// Canon evidence counts strictly later journal entries cited by `studio-journal` edges.
    /// Work identity is title + creator from the target entry.
    /// `recallCounts` comes from the studio store's bounded production-pull counter, not the graph.
    public func studioCanonEvidence(
        entries: [StudioJournalEntry],
        recallCounts: [String: (count: Int, lastAt: String)]
    ) async throws -> [StudioCanonWorkEvidence] {
        let citations = try await studioEdgeCitations() ?? [:]
        var byCanonKey: [String: StudioCanonWorkEvidence] = [:]
        // entry id → the work it is about, keyed the way the canon keys works
        // AND the way the graph keys its nodes.
        var workByEntry: [String: (canonKey: String, nodeKey: String)] = [:]

        for entry in entries {
            let title = Self.studioClean(entry.work.title)
            guard !title.isEmpty else { continue }
            let creator = Self.studioClean(entry.work.creator ?? "")
            let canonKey = StudioCanonLaw.workKey(
                title: title, creator: creator.isEmpty ? nil : creator
            )
            workByEntry[entry.id] = (
                canonKey, Self.studioWorkNodeKey(title: title, creator: creator)
            )
            var row = byCanonKey[canonKey] ?? StudioCanonWorkEvidence(
                title: title, creator: creator.isEmpty ? nil : creator
            )
            row.lastActivityAt = max(row.lastActivityAt, entry.recordedAt)
            byCanonKey[canonKey] = row
        }

        var recurrence: [String: Set<String>] = [:]
        let entriesByID = Dictionary(entries.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for entry in entries {
            guard let from = workByEntry[entry.id] else { continue }
            for relation in entry.relations {
                guard relation.kind == .deepens || relation.kind == .echoes else { continue }
                guard let target = entriesByID[relation.entryId],
                      let to = workByEntry[relation.entryId] else { continue }
                // Two entries about the same work are not that work recurring.
                guard from.canonKey != to.canonKey else { continue }
                // LATER, strictly. An entry that predates what it links to is a
                // forward reference, not a return.
                guard entry.recordedAt > target.recordedAt else { continue }
                // And the graph has to carry the claim, citing this entry.
                let edge = StudioEdgeKey(
                    from: from.nodeKey, to: to.nodeKey, type: relation.kind.rawValue
                )
                guard citations[edge]?.contains(entry.id) == true else { continue }
                recurrence[to.canonKey, default: []].insert(entry.id)
            }
        }
        for (canonKey, entryIDs) in recurrence {
            guard var row = byCanonKey[canonKey] else { continue }
            row.recurrenceEntryIDs = entryIDs.sorted()
            byCanonKey[canonKey] = row
        }
        for (canonKey, hits) in recallCounts {
            guard var row = byCanonKey[canonKey] else { continue }
            row.recallHits = hits.count
            row.lastActivityAt = max(row.lastActivityAt, hits.lastAt)
            byCanonKey[canonKey] = row
        }
        return byCanonKey.values.sorted { $0.workKey < $1.workKey }
    }

    static func studioFold(_ value: String) -> String {
        studioClean(value).folding(
            options: [.caseInsensitive, .diacriticInsensitive],
            locale: Locale(identifier: "en_US_POSIX")
        )
    }

    static func studioParseEntryIDs(_ raw: String?) -> Set<String> {
        guard let raw, !raw.isEmpty, let data = raw.data(using: .utf8),
              let parsed = try? JSONValue.parse(data),
              case .array(let items) = parsed else { return [] }
        var result = Set<String>()
        for item in items {
            guard case .string(let value) = item else { continue }
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { result.insert(trimmed) }
        }
        return result
    }
}

/// The studio edge identity shared by derivation, audit and canon evidence.
/// Endpoints are node keys (type, folded name, and a work's creator), never
/// SQL row IDs, which may be reused from memory indexing.
public struct StudioEdgeKey: Hashable, Sendable {
    public let from: String
    public let to: String
    public let type: String

    public init(from: String, to: String, type: String) {
        self.from = from
        self.to = to
        self.type = type
    }
}
