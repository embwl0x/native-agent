// Stop at one hop and exclude fact nodes and the primary-user hub: a second hop through that hub would reach nearly the whole graph. Callers must supply
// disclosed memory IDs because this reader does no disclosure filtering; group names by source memory to preserve that decision.

import Foundation
import GRDB
// Blueprint: | `KnowledgeGraph+RelatedEntities.swift` | Bounded one-hop entity reads for already-disclosed memory IDs |

extension SwiftNativeKnowledgeGraphIndexer {

    /// Bound each memory's entity payload and keep freshest names first when truncated. Unknown or unindexed memories have no result.
    public func relatedEntityNames(
        forMemoryIDs memoryIDs: [String],
        perMemoryLimit: Int = 8
    ) async throws -> [String: [String]] {
        let seeds = memoryIDs
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !seeds.isEmpty, perMemoryLimit > 0 else { return [:] }
        // The memory→node mapping is a one-way hash, so build the forward map once and use it to attribute each edge back to its memory.
        let factIDToMemoryID: [String: String] = {
            var map: [String: String] = [:]
            for memoryID in seeds {
                map[Self.memoryFactEntityID(for: memoryID)] = memoryID
            }
            return map
        }()
        let factIDs = Array(factIDToMemoryID.keys)
        // Read through the shared owner without creating a missing database.
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

    /// Share the prefix minted by `memoryFactEntityID(for:)`.
    static let memoryFactIDPrefix = "memfact_"
}
