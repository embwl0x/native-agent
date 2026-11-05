// Read canonical memory.sqlite through the owning MemoryStorage pool. Missing and unreadable canonical storage throw. Reconstruct the JSONValue envelopes
// KnowledgeGraphStore readers expect.

import Foundation
import NativeAgentShared
import GRDB
import NativeAgentCore
import PersistenceCore
// Blueprint: | `KnowledgeGraph+SQLite.swift` | checked canonical SQLite reads and strict bounded graph serialization |

public enum KnowledgeGraphSQLiteLoadError: Error, Sendable {
    case databaseMissing(String)
    /// Existing unreadable storage is an error, never a healthy empty graph.
    case unreadable(path: String, detail: String)
}

extension KnowledgeGraphStore {

    public static let sqlitePageSize = 100
    /// Search is a prompt/UI projection, not an export surface. Candidate SQL is capped before Swift applies the deterministic ranker.
    public static let sqliteSearchCandidateLimit = 2_000
    public static let sqliteSearchQueryMaximumBytes = 4 * 1_024
    public static let sqliteSearchQueryMaximumTokens = 32
    /// A malformed or hub-like graph must not turn one page/entity read into an unbounded prompt/UI payload. Complete snapshots retain the full edge set.
    public static let sqliteIncidentEdgeLimit = 2_000
    public static let sqliteCompleteSnapshotRelationshipLimit = 100_000

    /// Use the indexer's ISO-8601 shape for lexicographic recency ordering; Z and +00:00 differ only after seconds, and ranking never depends on a subsecond
    /// tie.
    static func orderingTimestamp(_ date: Date) -> String {
        NativeTimestampFormat.fractionalZulu(date)
    }

    /// Read counts, rows and incident edges in one transaction so the envelope cannot mix graph generations.
    public static func pageFromMemoryV2(
        memoryDir: URL,
        page: Int
    ) async throws -> JSONValue {
        let clampedPage = max(0, page)
        // An overflowing offset returns an empty page after the checked store read.
        let (offset, offsetOverflow) = clampedPage.multipliedReportingOverflow(by: sqlitePageSize)
        return try await withPreparedPool(
            memoryDir: memoryDir
        ) { pool in
            try await pool.read { db in
                let totalEntities = try Int.fetchOne(
                    db, sql: "SELECT COUNT(*) FROM kg_entities"
                ) ?? 0
                let totalEdges = try Int.fetchOne(db, sql: """
                    SELECT COUNT(*)
                    FROM kg_relationships r
                    JOIN kg_entities source ON source.id = r.from_id
                    JOIN kg_entities target ON target.id = r.to_id
                    """) ?? 0
                let rows = offsetOverflow ? [] : try Row.fetchAll(db, sql: """
                    SELECT id, name, type, summary, aliases_json, mention_count,
                           first_seen, last_seen, provenance, metadata_json
                    FROM kg_entities
                    ORDER BY id
                    LIMIT ? OFFSET ?
                    """, arguments: [sqlitePageSize, offset])
                let entities = try rows.compactMap(entityValue)
                let ids = entities.compactMap { value -> String? in
                    guard case .object(let object) = value,
                          case .string(let id)? = object["id"] else { return nil }
                    return id
                }
                let edges: [JSONValue]
                if ids.isEmpty {
                    edges = []
                } else {
                    let placeholders = Array(repeating: "?", count: ids.count)
                        .joined(separator: ",")
                    var edgeArguments: [DatabaseValueConvertible] = ids
                    edgeArguments.append(contentsOf: ids)
                    edgeArguments.append(sqliteIncidentEdgeLimit)
                    let edgeRows = try Row.fetchAll(db, sql: """
                        SELECT r.from_id, r.to_id, r.type, r.weight,
                               r.mention_count, r.provenance, r.metadata_json
                        FROM kg_relationships r
                        JOIN kg_entities source ON source.id = r.from_id
                        JOIN kg_entities target ON target.id = r.to_id
                        WHERE r.from_id IN (\(placeholders))
                           OR r.to_id IN (\(placeholders))
                        ORDER BY r.from_id, r.to_id, r.type
                        LIMIT ?
                        """, arguments: StatementArguments(edgeArguments))
                    edges = try edgeRows.compactMap(edgeValue)
                }
                return .object([
                    "entities": .array(entities),
                    "edges": .array(edges),
                    "total_entities": .int(Int64(totalEntities)),
                    "total_edges": .int(Int64(totalEdges)),
                    "page": .int(Int64(clampedPage)),
                ])
            }
        }
    }

    /// Prefilter by the same matcher before exact Swift ranking; cap well above shipped result limits to bound generic queries.
    public static func searchFromMemoryV2(
        memoryDir: URL,
        query: String,
        now: Date = Date()
    ) async throws -> JSONValue {
        let qLower = query.lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard qLower.utf8.count <= sqliteSearchQueryMaximumBytes else {
            throw KnowledgeGraphReadError.queryLimitExceeded(
                maximumBytes: sqliteSearchQueryMaximumBytes,
                maximumTokens: sqliteSearchQueryMaximumTokens
            )
        }
        let tokens = knowledgeGraphNameTokens(query).sorted()
        guard !qLower.isEmpty || !tokens.isEmpty else {
            return .object(["results": .array([])])
        }
        guard tokens.count <= sqliteSearchQueryMaximumTokens else {
            throw KnowledgeGraphReadError.queryLimitExceeded(
                maximumBytes: sqliteSearchQueryMaximumBytes,
                maximumTokens: sqliteSearchQueryMaximumTokens
            )
        }
        let needles: [String] = (qLower.isEmpty ? [] : [qLower])
            + tokens.filter { $0 != qLower }
        return try await withPreparedPool(
            memoryDir: memoryDir
        ) { pool in
            try await pool.read { db in
                // GRDB's built-in function uses the same Unicode lowercasing as the Swift ranker; SQLite lower() only folds ASCII.
                let haystack = "swiftLowercaseString(coalesce(name, '') || ' ' || coalesce(aliases_json, '') || ' ' || coalesce(summary, ''))"
                let nameHaystack = "swiftLowercaseString(coalesce(name, '') || ' ' || coalesce(aliases_json, ''))"
                let clauses = Array(repeating: "instr(\(haystack), ?) > 0", count: needles.count)
                    .joined(separator: " OR ")
                var arguments: [DatabaseValueConvertible] = needles
                // Before the candidate cap, order by match class, recency, then id so weaker matches cannot displace stronger ones. Clamp missing, future and
                // malformed timestamps to oldest, matching the Swift reranker's recency rule.
                arguments.append(qLower)
                arguments.append(qLower)
                arguments.append(Self.orderingTimestamp(now))
                arguments.append(sqliteSearchCandidateLimit)
                let rows = try Row.fetchAll(db, sql: """
                    SELECT id, name, type, summary, aliases_json, mention_count,
                           first_seen, last_seen, provenance, metadata_json
                    FROM kg_entities
                    WHERE \(clauses)
                    ORDER BY CASE
                        WHEN instr(\(nameHaystack), ?) > 0 THEN 0
                        WHEN instr(\(haystack), ?) > 0 THEN 1
                        ELSE 2
                    END,
                    CASE
                        WHEN last_seen IS NULL OR last_seen > ? THEN ''
                        ELSE last_seen
                    END DESC,
                    id
                    LIMIT ?
                    """, arguments: StatementArguments(arguments))
                let values = try rows.compactMap(entityValue)
                var entities: [String: JSONValue] = [:]
                var order: [String] = []
                for value in values {
                    guard case .object(let object) = value,
                          case .string(let id)? = object["id"] else { continue }
                    entities[id] = value
                    order.append(id)
                }
                let candidates = KnowledgeGraphStore(
                    entities: entities,
                    entityOrder: order
                )
                return .object([
                    // Both ranking stages share ONE clock, so a row can never be "fresh" to the prefilter and "future" to the reranker.
                    "results": .array(candidates.searchEntities(query, now: now))
                ])
            }
        }
    }

    /// Read one entity, its incident edges, and its neighbors in one bounded transaction. Unknown ids are explicit; unreadable SQLite propagates.
    public static func entityFromMemoryV2(
        memoryDir: URL,
        id: String
    ) async throws -> KnowledgeGraphEntityResult {
        try await withPreparedPool(
            memoryDir: memoryDir
        ) { pool in
            try await pool.read { db in
                try entityFromSQLite(db, id: id)
            }
        }
    }

    /// Only a successfully absent entity is omitted; source faults fail the batch.
    public static func entitiesFromMemoryV2(
        memoryDir: URL, ids: [String]
    ) async throws -> [String: JSONValue] {
        try await withPreparedPool(memoryDir: memoryDir) { pool in
            try await pool.read { db in
                var entities: [String: JSONValue] = [:]
                for id in ids {
                    guard case .found(.object(let envelope)) = try entityFromSQLite(db, id: id),
                          let entity = envelope["entity"], entity != .null else { continue }
                    entities[id] = entity
                }
                return entities
            }
        }
    }

    private static func entityFromSQLite(_ db: Database, id: String) throws -> KnowledgeGraphEntityResult {
        guard let row = try Row.fetchOne(db, sql: """
            SELECT id, name, type, summary, aliases_json, mention_count,
                   first_seen, last_seen, provenance, metadata_json
            FROM kg_entities WHERE id = ?
            """, arguments: [id]),
            let entity = try entityValue(row) else {
            return .notFound
        }
        let edgeRows = try Row.fetchAll(db, sql: """
            SELECT r.from_id, r.to_id, r.type, r.weight,
                   r.mention_count, r.provenance, r.metadata_json
            FROM kg_relationships r
            JOIN kg_entities source ON source.id = r.from_id
            JOIN kg_entities target ON target.id = r.to_id
            WHERE r.from_id = ? OR r.to_id = ?
            ORDER BY r.from_id, r.to_id, r.type
            LIMIT ?
            """, arguments: [id, id, sqliteIncidentEdgeLimit + 1])
        guard edgeRows.count <= sqliteIncidentEdgeLimit else {
            throw KnowledgeGraphReadError.relationshipLimitExceeded(sqliteIncidentEdgeLimit)
        }
        let edges = try edgeRows.compactMap(edgeValue)
        let neighborRows = try Row.fetchAll(db, sql: """
            SELECT id, name, type, summary, aliases_json, mention_count,
                   first_seen, last_seen, provenance, metadata_json
            FROM kg_entities
            WHERE id IN (
                SELECT CASE WHEN r.from_id = ? THEN r.to_id ELSE r.from_id END
                FROM kg_relationships r
                JOIN kg_entities source ON source.id = r.from_id
                JOIN kg_entities target ON target.id = r.to_id
                WHERE r.from_id = ? OR r.to_id = ?
                ORDER BY r.from_id, r.to_id, r.type
                LIMIT ?
            )
            ORDER BY id
            LIMIT ?
            """, arguments: [
                id, id, id,
                sqliteIncidentEdgeLimit, sqliteIncidentEdgeLimit,
            ])
        var neighbors: [String: JSONValue] = [:]
        for value in try neighborRows.compactMap(entityValue) {
            guard case .object(let object) = value,
                  case .string(let neighborID)? = object["id"] else { continue }
            neighbors[neighborID] = value
        }
        return .found(.object([
            "entity": entity,
            "edges": .array(edges),
            "neighbors": .object(neighbors),
        ]))
    }

    /// Materialize the complete export/iCloud projection in one read transaction so pages cannot mix generations; retain the `maxPages` safety bound.
    public static func completeSnapshotFromMemoryV2(
        memoryDir: URL,
        maxPages: Int,
        surface: String? = nil,
        personaID: String? = nil
    ) async throws -> JSONValue {
        let pageLimit = max(1, maxPages)
        return try await withPreparedPool(
            memoryDir: memoryDir
        ) { pool in
            try await pool.read { db in
                // The audience decision and graph rows share this read transaction; a concurrent privacy edit cannot split them.
                let disclosure: KnowledgeGraphMemoryDisclosure?
                if let surface {
                    let records = try Row.fetchAll(db, sql: "SELECT * FROM memories")
                        .map(MemoryStorage.decodeMemory).map(MemoryRecord.init(stored:))
                    disclosure = KnowledgeGraphMemoryDisclosure(
                        records: records, surface: surface, personaID: personaID)
                } else {
                    disclosure = nil
                }
                let total = try Int.fetchOne(
                    db, sql: "SELECT COUNT(*) FROM kg_entities"
                ) ?? 0
                let (capacity, overflow) = pageLimit.multipliedReportingOverflow(by: sqlitePageSize)
                guard overflow || total <= capacity else {
                    throw KnowledgeGraphReadError.paginationLimitExceeded(pageLimit)
                }
                let relationshipTotal = try Int.fetchOne(
                    db, sql: "SELECT COUNT(*) FROM kg_relationships"
                ) ?? 0
                guard relationshipTotal <= sqliteCompleteSnapshotRelationshipLimit else {
                    throw KnowledgeGraphReadError.relationshipLimitExceeded(
                        sqliteCompleteSnapshotRelationshipLimit
                    )
                }
                let entities = try Row.fetchAll(db, sql: """
                    SELECT id, name, type, summary, aliases_json, mention_count,
                           first_seen, last_seen, provenance, metadata_json
                    FROM kg_entities ORDER BY id
                    """).compactMap(entityValue).filter { disclosure?.permits($0) ?? true }
                let entityIDs = Set(entities.compactMap { $0.objectValue?["id"]?.stringValue })
                let edges = try Row.fetchAll(db, sql: """
                    SELECT r.from_id, r.to_id, r.type, r.weight,
                           r.mention_count, r.provenance, r.metadata_json
                    FROM kg_relationships r
                    JOIN kg_entities source ON source.id = r.from_id
                    JOIN kg_entities target ON target.id = r.to_id
                    WHERE source.id != '' AND target.id != ''
                    ORDER BY r.from_id, r.to_id, r.type
                    """).compactMap(edgeValue).filter { value in
                        guard disclosure?.permits(value) ?? true,
                              let object = value.objectValue,
                              let from = object["from"]?.stringValue,
                              let to = object["to"]?.stringValue else { return false }
                        return entityIDs.contains(from) && entityIDs.contains(to)
                    }
                return .object([
                    "entities": .array(entities),
                    "edges": .array(edges),
                    "total_entities": .int(Int64(entities.count)),
                    "total_edges": .int(Int64(edges.count)),
                    "page": .int(0),
                ])
            }
        }
    }

    static func withPreparedPool<T: Sendable>(
        memoryDir: URL,
        operation: @Sendable (DatabasePool) async throws -> T
    ) async throws -> T {
        do {
            let pool = try await preparedPool(
                memoryDir: memoryDir
            )
            return try await operation(pool)
        } catch KnowledgeGraphPoolCache.PoolError.databaseMissing(let path) {
            throw KnowledgeGraphSQLiteLoadError.databaseMissing(path)
        } catch let error as KnowledgeGraphSQLiteLoadError {
            throw error
        } catch let error as KnowledgeGraphReadError {
            throw error
        } catch let error as ToolFailureError {
            throw error
        } catch {
            throw KnowledgeGraphSQLiteLoadError.unreadable(
                path: memoryDir.appendingPathComponent("memory.sqlite").path,
                detail: String(describing: error)
            )
        }
    }

    private static func preparedPool(
        memoryDir: URL
    ) async throws -> DatabasePool {
        let sqlitePath = memoryDir.appendingPathComponent("memory.sqlite")
        let pool = try await KnowledgeGraphPoolCache.shared.pool(at: sqlitePath)
        let dataRoot = memoryDir.deletingLastPathComponent()
        if try MemoryPolicyGate.knowledgeGraphEnabled(dataRoot: dataRoot) {
            let indexer = try SwiftNativeKnowledgeGraphIndexer(memorySQLitePath: sqlitePath)
            try await indexer.reconcileMemoryIndexFingerprints()
        }
        return pool
    }

    private static func entityValue(_ row: Row) throws -> JSONValue? {
        let id: String = row["id"] ?? ""
        guard !id.isEmpty else { return nil }
        var object: [String: JSONValue] = ["id": .string(id)]
        if let value: String = row["name"] { object["name"] = .string(value) }
        if let value: String = row["type"] { object["type"] = .string(value) }
        if let value: String = row["summary"] { object["summary"] = .string(value) }
        if let encoded: String = row["aliases_json"] {
            let aliases = try JSONDecoder().decode([String].self, from: Data(encoded.utf8))
            object["aliases"] = .array(aliases.map(JSONValue.string))
        }
        if let value: Int64 = row["mention_count"] { object["mention_count"] = .int(value) }
        if let value: String = row["first_seen"] { object["first_seen"] = .string(value) }
        if let value: String = row["last_seen"] { object["last_seen"] = .string(value) }
        if let value: String = row["provenance"] { object["provenance"] = .string(value) }
        try mergeMetadata(row["metadata_json"], into: &object)
        return .object(object)
    }

    private static func edgeValue(_ row: Row) throws -> JSONValue? {
        let from: String = row["from_id"] ?? ""
        let to: String = row["to_id"] ?? ""
        let type: String = row["type"] ?? ""
        guard !from.isEmpty, !to.isEmpty, !type.isEmpty else { return nil }
        var object: [String: JSONValue] = [
            "from": .string(from),
            "to": .string(to),
            "type": .string(type),
        ]
        if let value: Double = row["weight"] { object["weight"] = .double(value) }
        if let value: Int64 = row["mention_count"] { object["mention_count"] = .int(value) }
        if let value: String = row["provenance"] { object["provenance"] = .string(value) }
        try mergeMetadata(row["metadata_json"], into: &object)
        return .object(object)
    }

    private static func mergeMetadata(_ encoded: String?, into object: inout [String: JSONValue]) throws {
        let metadata = try SwiftNativeKnowledgeGraphIndexer.metadataObject(encoded)
        for (key, value) in metadata where object[key] == nil {
            object[key] = value
        }
        // Presentation reads are bounded; audits read the complete SQLite citations directly rather than this display projection.
        if object["from"] != nil, case .array(let citations)? = object["studio_entry_ids"] {
            object["studio_entry_ids"] = .array(Array(citations.prefix(24)))
            object["studio_entry_count"] = .int(Int64(citations.count))
            object["studio_entry_ids_truncated"] = .bool(citations.count > 24)
        }
    }

}
