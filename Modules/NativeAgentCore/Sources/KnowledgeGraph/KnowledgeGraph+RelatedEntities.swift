// B4 (2026-08-28): the graph half of the recalled-memory "related:" line.
//
// A recalled memory arrives at the prompt renderer as its own text and nothing
// else, even though the indexer has already extracted its entities and wired
// them into the graph. This file exposes exactly one hop of that structure —
// memory id → its memory-fact node → the entities that node mentions — so the
// caller can append a single compact line naming them.
//
// ── SCOPE, AND WHY IT STOPS AT ONE HOP ───────────────────────────────────────
// Every indexed fact is also wired to the stable primary-user hub
// (`indexActiveFact`: user→fact, user→entity, fact→entity). That hub touches
// essentially the whole graph, so a second hop — or a first hop that forgets to
// exclude the hub — degenerates into "every entity we have ever seen". The hub
// and the memory-fact nodes are therefore excluded from results, leaving only
// the entities the seed memories actually mention.
//
// ── PRIVACY ──────────────────────────────────────────────────────────────────
// This function does NO disclosure filtering and must never be handed
// unfiltered memory ids. It is keyed by memory id and returns results grouped
// per memory precisely so the caller can seed it with already-disclosed recall
// hits and keep each memory's entities attached to that memory's disclosure
// decision. Names returned for memory X were extracted from memory X's own
// text, so disclosing them alongside X's text reveals nothing X did not.

import Foundation
import GRDB

extension SwiftNativeKnowledgeGraphIndexer {

    /// One-hop entity names for each of `memoryIDs`, keyed by memory id.
    ///
    /// Ordering is recency-first (`last_seen DESC`, then name) so a caller that
    /// truncates keeps the freshest entities. `perMemoryLimit` bounds the work
    /// and the payload; memories with no indexed entities are simply absent from
    /// the result. Unknown ids are not an error.
    public func relatedEntityNames(
        forMemoryIDs memoryIDs: [String],
        perMemoryLimit: Int = 8
    ) async throws -> [String: [String]] {
        let seeds = memoryIDs
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !seeds.isEmpty, perMemoryLimit > 0 else { return [:] }
        // The memory→node mapping is a one-way hash, so build the forward map
        // once and use it to attribute each edge back to its memory.
        // Immutable snapshot for the @Sendable pool closure below — capturing
        // the mutated `var` is a Swift 6 Sendable build error (same trap as
        // `liveKeySnapshot` in KnowledgeGraph+GC.swift).
        let factIDToMemoryID: [String: String] = {
            var map: [String: String] = [:]
            for memoryID in seeds {
                map[Self.memoryFactEntityID(for: memoryID)] = memoryID
            }
            return map
        }()
        let factIDs = Array(factIDToMemoryID.keys)
        // Same shared-cache resolution the indexing and GC paths use; the read
        // never creates a missing database.
        let dbPool = try await KnowledgeGraphPoolCache.shared.pool(at: sqlitePath)
        return try await dbPool.read { db in
            let placeholders = Array(repeating: "?", count: factIDs.count)
                .joined(separator: ",")
            let edgeRows = try Row.fetchAll(db, sql: """
                SELECT from_id, to_id FROM kg_relationships
                WHERE from_id IN (\(placeholders)) OR to_id IN (\(placeholders))
                """, arguments: StatementArguments(factIDs + factIDs))

            // fact node -> the neighbour ids it touches.
            var neighborsByFact: [String: Set<String>] = [:]
            var allNeighborIDs = Set<String>()
            for row in edgeRows {
                let from: String = row["from_id"] ?? ""
                let to: String = row["to_id"] ?? ""
                for (factID, otherID) in [(from, to), (to, from)]
                where factIDToMemoryID[factID] != nil {
                    // Never the seed itself, and never another memory-fact node:
                    // a fact node's "name" is a rendering of the memory text, so
                    // emitting one would duplicate memory content into a line
                    // that is supposed to add entities.
                    guard !otherID.isEmpty, !otherID.hasPrefix(Self.memoryFactIDPrefix)
                    else { continue }
                    neighborsByFact[factID, default: []].insert(otherID)
                    allNeighborIDs.insert(otherID)
                }
            }
            guard !allNeighborIDs.isEmpty else { return [:] }

            // Resolve names in one pass, dropping the primary-user hub. Ordered
            // recency-first so a truncating caller keeps the freshest entities.
            let idList = Array(allNeighborIDs)
            let namePlaceholders = Array(repeating: "?", count: idList.count)
                .joined(separator: ",")
            let entityRows = try Row.fetchAll(db, sql: """
                SELECT id, name FROM kg_entities
                WHERE id IN (\(namePlaceholders))
                  AND COALESCE(json_extract(metadata_json, '$.role'), '') <> 'primary_user'
                  AND TRIM(COALESCE(name, '')) <> ''
                ORDER BY last_seen DESC, name ASC
                """, arguments: StatementArguments(idList))

            var nameByID: [String: String] = [:]
            var rankByID: [String: Int] = [:]
            for (rank, row) in entityRows.enumerated() {
                let id: String = row["id"] ?? ""
                let name: String = row["name"] ?? ""
                guard !id.isEmpty else { continue }
                nameByID[id] = name.trimmingCharacters(in: .whitespacesAndNewlines)
                rankByID[id] = rank
            }

            var result: [String: [String]] = [:]
            for (factID, neighborIDs) in neighborsByFact {
                guard let memoryID = factIDToMemoryID[factID] else { continue }
                let names = neighborIDs
                    .filter { nameByID[$0] != nil }
                    .sorted { (rankByID[$0] ?? .max) < (rankByID[$1] ?? .max) }
                    .prefix(perMemoryLimit)
                    .compactMap { nameByID[$0] }
                if !names.isEmpty { result[memoryID] = names }
            }
            return result
        }
    }

    /// Shared with `memoryFactEntityID(for:)`, which mints ids with this prefix.
    static let memoryFactIDPrefix = "memfact_"
}
