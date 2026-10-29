// Read canonical memory.sqlite through the owning MemoryStorage pool.
// Import JSON once into empty tables, committing completion with the rows in memory_metadata.
// The `.kg_migrated_to_sqlite_v1` file sentinel remains a compatibility fast path.
// A missing database permits JSON reads; unreadable existing SQLite throws.
// Reconstruct the JSONValue envelopes KnowledgeGraphStore readers expect.

import Foundation
import NativeAgentShared
import GRDB
import NativeAgentCore
import PersistenceCore
// Blueprint: | `KnowledgeGraph+SQLite.swift` | Checked prepared-pool boundary and shared entity/edge serialization; legacy import rechecks eligibility and records durable completion in its row-write transaction; batched entity reads retain per-entity relationship limits and failures in one transaction |

/// Typed empty-vs-error result classes for the SQLite KG load path.
public enum KnowledgeGraphSQLiteLoadError: Error, Sendable {
    /// memory.sqlite does not exist — a legitimate "no SQLite store yet"
    /// state (fresh install, test fixture). The reader falls back to JSON.
    case databaseMissing(String)
    /// memory.sqlite EXISTS but could not be opened or read. This is an
    /// ERROR state: the caller must surface it, not fabricate healthy-empty.
    case unreadable(path: String, detail: String)
}

extension KnowledgeGraphStore {

    /// Ordinary graph pages are fixed at the retired route's 100-row size.
    public static let sqlitePageSize = 100
    /// Search is a prompt/UI projection, not an export surface. Candidate SQL
    /// is capped before Swift applies the legacy deterministic ranker.
    public static let sqliteSearchCandidateLimit = 2_000
    public static let sqliteSearchQueryMaximumBytes = 4 * 1_024
    public static let sqliteSearchQueryMaximumTokens = 32
    /// A malformed or hub-like graph must not turn one page/entity read into an
    /// unbounded prompt/UI payload. Complete snapshots retain the full edge set.
    public static let sqliteIncidentEdgeLimit = 2_000
    public static let sqliteCompleteSnapshotRelationshipLimit = 100_000

    /// The "now" the SQL recency ordering compares `last_seen` against, rendered
    /// in the same ISO-8601 shape the indexer writes so the comparison is a
    /// plain lexicographic one. Stored values carry either a `Z` or a `+00:00`
    /// suffix; those differ only after the seconds field, so ordering by string
    /// agrees with ordering by instant everywhere except a sub-second tie, which
    /// no ranking decision rests on.
    static func orderingTimestamp(_ date: Date) -> String {
        NativeTimestampFormat.fractionalZulu(date)
    }

    /// Read one bounded page directly from SQLite. The entity count, page rows,
    /// incident edges, and edge total share one GRDB read transaction, so the
    /// envelope cannot mix graph generations.
    public static func pageFromMemoryV2(
        memoryDir: URL,
        jsonImportPath: URL?,
        page: Int
    ) async throws -> JSONValue {
        let clampedPage = max(0, page)
        // An overflowing offset returns an empty page after the checked store read.
        let (offset, offsetOverflow) = clampedPage.multipliedReportingOverflow(by: sqlitePageSize)
        return try await withPreparedPool(
            memoryDir: memoryDir,
            jsonImportPath: jsonImportPath
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
                let entities = rows.compactMap(entityValue)
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
                    edges = edgeRows.compactMap(edgeValue)
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

    /// Read only SQL candidates that can satisfy the legacy name/alias/summary
    /// matcher, then apply the exact Swift ranker to those rows. The SQL cap is
    /// deliberately much larger than every shipped consumer's result cap
    /// (10–50) while preventing a generic query from materializing the graph.
    public static func searchFromMemoryV2(
        memoryDir: URL,
        jsonImportPath: URL?,
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
            memoryDir: memoryDir,
            jsonImportPath: jsonImportPath
        ) { pool in
            try await pool.read { db in
                // GRDB's built-in function uses the same Unicode lowercasing
                // as the Swift ranker; SQLite lower() only folds ASCII.
                let haystack = "swiftLowercaseString(coalesce(name, '') || ' ' || coalesce(aliases_json, '') || ' ' || coalesce(summary, ''))"
                let nameHaystack = "swiftLowercaseString(coalesce(name, '') || ' ' || coalesce(aliases_json, ''))"
                let clauses = Array(repeating: "instr(\(haystack), ?) > 0", count: needles.count)
                    .joined(separator: " OR ")
                var arguments: [DatabaseValueConvertible] = needles
                // Before the candidate cap, order by match class, recency, then id so weaker matches cannot displace stronger ones.
                // Clamp missing, future and malformed timestamps to oldest, matching the Swift reranker's recency rule.
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
                let values = rows.compactMap(entityValue)
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
                    entityOrder: order,
                    edges: []
                )
                return .object([
                    // Both ranking stages share ONE clock, so a row can never be
                    // "fresh" to the prefilter and "future" to the reranker.
                    "results": .array(candidates.searchEntities(query, now: now))
                ])
            }
        }
    }

    /// Read one entity, its incident edges, and its neighbors in one bounded
    /// transaction. Unknown ids are explicit; unreadable SQLite propagates.
    public static func entityFromMemoryV2(
        memoryDir: URL,
        jsonImportPath: URL?,
        id: String
    ) async throws -> KnowledgeGraphEntityResult {
        try await withPreparedPool(
            memoryDir: memoryDir,
            jsonImportPath: jsonImportPath
        ) { pool in
            try await pool.read { db in
                try entityFromSQLite(db, id: id)
            }
        }
    }

    /// Per-entity failures stay local to the recalled row, as in single reads.
    public static func entitiesFromMemoryV2(
        memoryDir: URL, jsonImportPath: URL?, ids: [String]
    ) async throws -> [String: JSONValue] {
        try await withPreparedPool(memoryDir: memoryDir, jsonImportPath: jsonImportPath) { pool in
            try await pool.read { db in
                var entities: [String: JSONValue] = [:]
                for id in ids {
                    guard case .found(.object(let envelope))? = try? entityFromSQLite(db, id: id),
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
            let entity = entityValue(row) else {
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
        let edges = edgeRows.compactMap(edgeValue)
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
        for value in neighborRows.compactMap(entityValue) {
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

    /// Materialize the canonical export/iCloud projection in exactly one GRDB
    /// read transaction. `maxPages` retains the prior safety contract while
    /// avoiding hundreds of separately versioned page reads.
    public static func completeSnapshotFromMemoryV2(
        memoryDir: URL,
        jsonImportPath: URL?,
        maxPages: Int
    ) async throws -> JSONValue {
        let pageLimit = max(1, maxPages)
        return try await withPreparedPool(
            memoryDir: memoryDir,
            jsonImportPath: jsonImportPath
        ) { pool in
            try await pool.read { db in
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
                    """).compactMap(entityValue)
                let edges = try Row.fetchAll(db, sql: """
                    SELECT r.from_id, r.to_id, r.type, r.weight,
                           r.mention_count, r.provenance, r.metadata_json
                    FROM kg_relationships r
                    JOIN kg_entities source ON source.id = r.from_id
                    JOIN kg_entities target ON target.id = r.to_id
                    WHERE source.id != '' AND target.id != ''
                    ORDER BY r.from_id, r.to_id, r.type
                    """).compactMap(edgeValue)
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
        jsonImportPath: URL?,
        operation: @Sendable (DatabasePool) async throws -> T
    ) async throws -> T {
        do {
            let pool = try await preparedPool(
                memoryDir: memoryDir,
                jsonImportPath: jsonImportPath
            )
            return try await operation(pool)
        } catch KnowledgeGraphPoolCache.PoolError.databaseMissing(let path) {
            throw KnowledgeGraphSQLiteLoadError.databaseMissing(path)
        } catch let error as KnowledgeGraphSQLiteLoadError {
            throw error
        } catch let error as KnowledgeGraphReadError {
            throw error
        } catch {
            throw KnowledgeGraphSQLiteLoadError.unreadable(
                path: memoryDir.appendingPathComponent("memory.sqlite").path,
                detail: String(describing: error)
            )
        }
    }

    private static func preparedPool(
        memoryDir: URL,
        jsonImportPath: URL?
    ) async throws -> DatabasePool {
        let sqlitePath = memoryDir.appendingPathComponent("memory.sqlite")
        let sentinelPath = memoryDir.appendingPathComponent(".kg_migrated_to_sqlite_v1")
        let pool = try await KnowledgeGraphPoolCache.shared.pool(at: sqlitePath)
        if let jsonPath = jsonImportPath,
           !FileManager.default.fileExists(atPath: sentinelPath.path) {
            try await maybeImportJSON(
                pool: pool,
                jsonPath: jsonPath,
                sentinelPath: sentinelPath
            )
        }
        let dataRoot = memoryDir.deletingLastPathComponent()
        if MemoryPolicyGate.knowledgeGraphEnabled(dataRoot: dataRoot) {
            let indexer = try SwiftNativeKnowledgeGraphIndexer(memorySQLitePath: sqlitePath)
            try await indexer.reconcileMemoryIndexFingerprints()
        }
        return pool
    }

    private static func entityValue(_ row: Row) -> JSONValue? {
        let id: String = row["id"] ?? ""
        guard !id.isEmpty else { return nil }
        var object: [String: JSONValue] = ["id": .string(id)]
        if let value: String = row["name"] { object["name"] = .string(value) }
        if let value: String = row["type"] { object["type"] = .string(value) }
        if let value: String = row["summary"] { object["summary"] = .string(value) }
        if let encoded: String = row["aliases_json"],
           let data = encoded.data(using: .utf8),
           let value = try? JSONValue.parse(data) {
            object["aliases"] = value
        }
        if let value: Int64 = row["mention_count"] { object["mention_count"] = .int(value) }
        if let value: String = row["first_seen"] { object["first_seen"] = .string(value) }
        if let value: String = row["last_seen"] { object["last_seen"] = .string(value) }
        if let value: String = row["provenance"] { object["provenance"] = .string(value) }
        mergeMetadata(row["metadata_json"], into: &object)
        return .object(object)
    }

    private static func edgeValue(_ row: Row) -> JSONValue? {
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
        mergeMetadata(row["metadata_json"], into: &object)
        return .object(object)
    }

    private static func mergeMetadata(_ encoded: String?, into object: inout [String: JSONValue]) {
        guard let encoded,
              let data = encoded.data(using: .utf8),
              let value = try? JSONValue.parse(data),
              case .object(let metadata) = value else { return }
        for (key, value) in metadata where object[key] == nil {
            object[key] = value
        }
        // Presentation reads are bounded; audits read the complete SQLite
        // citations directly rather than this display projection.
        if object["from"] != nil, case .array(let citations)? = object["studio_entry_ids"] {
            object["studio_entry_ids"] = .array(Array(citations.prefix(24)))
            object["studio_entry_count"] = .int(Int64(citations.count))
            object["studio_entry_ids_truncated"] = .bool(citations.count > 24)
        }
    }

    private static func importedMentionCount(_ e: [String: JSONValue], jsonPath: URL) throws -> Int64 {
        if case .int(let i)? = e["mention_count"] { return i }
        if case .double(let d)? = e["mention_count"] {
            guard let count = Int64(exactly: d.rounded(.towardZero)) else {
                throw KnowledgeGraphJSONLoadError.unreadable(
                    path: jsonPath.path,
                    detail: "mention_count cannot be represented as Int64"
                )
            }
            return count
        }
        return 0
    }

    private static func maybeImportJSON(
        pool: DatabasePool,
        jsonPath: URL,
        sentinelPath: URL
    ) async throws {
        // This read only avoids loading obsolete JSON. Eligibility is checked
        // again under the import's write transaction, together with its durable
        // completion marker (which survives a later authoritative empty graph).
        let alreadyHas = try await pool.read { db in
            try Bool.fetchOne(db, sql: """
                SELECT EXISTS(SELECT 1 FROM kg_entities)
                    OR EXISTS(SELECT 1 FROM memory_metadata WHERE key = 'kg_legacy_import_completed')
                """) ?? false
        }
        // Existing-but-unreadable is never the same as an intentionally empty
        // legacy graph. Do not stamp completion over repairable corruption.
        let jsonStore: KnowledgeGraphStore?
        if !alreadyHas, FileManager.default.fileExists(atPath: jsonPath.path) {
            jsonStore = try KnowledgeGraphStore.loadChecked(path: jsonPath)
        } else {
            jsonStore = nil
        }
        try await pool.write { db in
            guard !(try Bool.fetchOne(db, sql: """
                SELECT EXISTS(SELECT 1 FROM memory_metadata WHERE key = 'kg_legacy_import_completed')
                """) ?? false) else { return }
            let eligible = !(try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM kg_entities)") ?? false)
            // Rolled back with any failed import; committed even when there is
            // no legacy file or canonical indexing has already won admission.
            try db.execute(sql: """
                INSERT INTO memory_metadata (key, value) VALUES ('kg_legacy_import_completed', 1)
                """)
            guard eligible, let jsonStore else { return }
            for id in jsonStore.entityOrder {
                guard case .object(let e)? = jsonStore.entities[id] else { continue }
                let name: String = {
                    if case .string(let s)? = e["name"] { return s }; return id
                }()
                let type: String = {
                    if case .string(let s)? = e["type"] { return s }; return "concept"
                }()
                let summary: String? = {
                    if case .string(let s)? = e["summary"] { return s }; return nil
                }()
                let aliasesJson: String? = {
                    if let a = e["aliases"], case .array = a {
                        return try? String(decoding: a.serializedData(pretty: false), as: UTF8.self)
                    }
                    return nil
                }()
                let mentionCount = try importedMentionCount(e, jsonPath: jsonPath)
                let firstSeen: String? = {
                    if case .string(let s)? = e["first_seen"] { return s }; return nil
                }()
                let lastSeen: String? = {
                    if case .string(let s)? = e["last_seen"] { return s }; return nil
                }()
                // Stamp import provenance so canonical rebuilds retain these rows; preserve original provenance in metadata.
                let provenance = SwiftNativeKnowledgeGraphIndexer.legacyImportProvenance
                // Metadata bag — everything not modeled as a column.
                let metaKnown: Set<String> = [
                    "id", "name", "type", "summary", "aliases", "mention_count",
                    "first_seen", "last_seen",
                ]
                var meta: [String: JSONValue] = [:]
                for (k, v) in e where !metaKnown.contains(k) { meta[k] = v }
                let metaJson: String? = meta.isEmpty ? nil : {
                    try? String(decoding: JSONValue.object(meta).serializedData(pretty: false), as: UTF8.self)
                }()
                try db.execute(sql: """
                    INSERT OR IGNORE INTO kg_entities
                      (id, name, type, summary, aliases_json, mention_count,
                       first_seen, last_seen, provenance, metadata_json)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """, arguments: [
                        id, name, type, summary, aliasesJson, mentionCount,
                        firstSeen, lastSeen, provenance, metaJson,
                    ])
            }
            for edge in jsonStore.edges {
                guard case .object(let e) = edge else { continue }
                guard case .string(let from)? = e["from"],
                      case .string(let to)? = e["to"],
                      case .string(let type)? = e["type"] else { continue }
                let weight: Double? = {
                    if case .double(let d)? = e["weight"] { return d }
                    if case .int(let i)? = e["weight"] { return Double(i) }
                    return nil
                }()
                let mc = try importedMentionCount(e, jsonPath: jsonPath)
                // Same stamp as the entities above, for the same reason.
                let provenance = SwiftNativeKnowledgeGraphIndexer.legacyImportProvenance
                let edgeKnown: Set<String> = [
                    "from", "to", "type", "weight", "mention_count",
                ]
                var meta: [String: JSONValue] = [:]
                for (k, v) in e where !edgeKnown.contains(k) { meta[k] = v }
                let metaJson: String? = meta.isEmpty ? nil : {
                    try? String(decoding: JSONValue.object(meta).serializedData(pretty: false), as: UTF8.self)
                }()
                try db.execute(sql: """
                    INSERT OR IGNORE INTO kg_relationships
                      (from_id, to_id, type, weight, mention_count, provenance, metadata_json)
                    VALUES (?, ?, ?, ?, ?, ?, ?)
                    """, arguments: [from, to, type, weight, mc, provenance, metaJson])
            }
        }
        try SwiftNativePersistenceCore.writeDataAtomicDurable(Data(), to: sentinelPath)
    }
}
