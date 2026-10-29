// One-hop graph names enrich each disclosed recalled memory.
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
// Blueprint: | `KnowledgeGraph+RelatedEntities.swift` | Bounded one-hop entity reads for already-disclosed memory IDs |

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
            let placeholders = Array(repeating: "(?)", count: factIDs.count)
                .joined(separator: ",")
            // DISTINCT keeps entity identity across parallel edges and directions.
            let entityRows = try Row.fetchAll(db, sql: """
                WITH seeds(fact_id) AS (VALUES \(placeholders))
                SELECT DISTINCT s.fact_id, e.id, e.name, e.last_seen
                FROM seeds s
                JOIN kg_relationships r ON r.from_id = s.fact_id OR r.to_id = s.fact_id
                JOIN kg_entities e ON e.id = CASE WHEN r.from_id = s.fact_id THEN r.to_id ELSE r.from_id END
                WHERE e.id <> ''
                  AND substr(e.id, 1, \(Self.memoryFactIDPrefix.count)) <> '\(Self.memoryFactIDPrefix)'
                  AND COALESCE(json_extract(e.metadata_json, '$.role'), '') <> 'primary_user'
                  AND TRIM(COALESCE(e.name, '')) <> ''
                ORDER BY e.last_seen DESC, e.name ASC
                """, arguments: StatementArguments(factIDs))

            var result: [String: [String]] = [:]
            for row in entityRows {
                let factID: String = row["fact_id"]
                guard let memoryID = factIDToMemoryID[factID],
                      result[memoryID, default: []].count < perMemoryLimit else { continue }
                let name: String = row["name"]
                result[memoryID, default: []].append(name.trimmingCharacters(in: .whitespacesAndNewlines))
            }
            return result
        }
    }

    /// Shared with `memoryFactEntityID(for:)`, which mints ids with this prefix.
    static let memoryFactIDPrefix = "memfact_"
}
