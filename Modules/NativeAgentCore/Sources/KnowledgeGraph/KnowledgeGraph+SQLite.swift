// F6 (eval E06 fix-2): SQLite-backed loader for KnowledgeGraphStore.
//
// Round-3 F3 added kg_entities + kg_relationships tables to the MemoryV2
// migration as additive groundwork but never flipped the reader, leaving
// the source of truth on <root>/memory/knowledge_graph.json. This file
// flips it: the reader queries memory.sqlite directly through the shared
// KnowledgeGraphPoolCache, and on the first call (no `.kg_migrated_to_sqlite_v1`
// sentinel + empty tables + JSON file present) it ingests the JSON into
// SQLite once and stamps the sentinel.
//
// U5 W-C (2026-06-11):
//   - The pool is no longer constructed fresh per query — it resolves through
//     KnowledgeGraphPoolCache (one pool per path, invalidated on file replace).
//   - `loadFromMemoryV2` now THROWS instead of returning an empty store on
//     failure. Empty-vs-error: a MISSING database is `.databaseMissing` (the
//     reader legitimately falls back to the JSON file); an EXISTING database
//     that cannot be opened or read is `.unreadable` — an ERROR that must
//     surface to the user, never render as an empty-but-healthy graph and
//     never fall back to a stale JSON snapshot (resurrected-entities bug).
//   - `sqliteHasAnyEntities` deleted — zero callers repo-wide (cutover
//     residue; it was also a fresh-pool-per-call site).
//
// Row shapes are reconstructed into the SAME JSONValue envelopes
// KnowledgeGraphStore expects so allEntities / searchEntities / neighbors /
// hasEntity keep working unchanged (and the Mac decode models continue to
// decode the result identically).

import Foundation
import GRDB
import PersistenceCore

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

    /// Load from `<memoryDir>/memory.sqlite` (kg_entities + kg_relationships).
    /// If the tables are empty AND `jsonImportPath` exists AND the sentinel
    /// `<memoryDir>/.kg_migrated_to_sqlite_v1` is missing, ingest the JSON
    /// file once and stamp the sentinel.
    ///
    /// Throws `KnowledgeGraphSQLiteLoadError.databaseMissing` when the DB file
    /// does not exist, and `.unreadable` on any open/read failure. It NEVER
    /// returns a fabricated empty store on failure (U5 W-C empty-vs-error).
    public static func loadFromMemoryV2(
        memoryDir: URL,
        jsonImportPath: URL?
    ) async throws -> KnowledgeGraphStore {
        do {
            let pool = try await preparedPool(
                memoryDir: memoryDir,
                jsonImportPath: jsonImportPath
            )
            return try await readFromPool(pool)
        } catch KnowledgeGraphPoolCache.PoolError.databaseMissing(let path) {
            throw KnowledgeGraphSQLiteLoadError.databaseMissing(path)
        } catch let error as KnowledgeGraphSQLiteLoadError {
            throw error
        } catch {
            throw KnowledgeGraphSQLiteLoadError.unreadable(
                path: memoryDir.appendingPathComponent("memory.sqlite").path,
                detail: String(describing: error)
            )
        }
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
        let offset = clampedPage * sqlitePageSize
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
                let rows = try Row.fetchAll(db, sql: """
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
        query: String
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
                let haystack = "lower(coalesce(name, '') || ' ' || coalesce(aliases_json, '') || ' ' || coalesce(summary, ''))"
                let nameHaystack = "lower(coalesce(name, '') || ' ' || coalesce(aliases_json, ''))"
                let clauses = Array(repeating: "instr(\(haystack), ?) > 0", count: needles.count)
                    .joined(separator: " OR ")
                var arguments: [DatabaseValueConvertible] = needles
                // Preserve the legacy Swift ranker's most important ordering
                // before applying the candidate cap. Ordering only by id could
                // discard an exact name match merely because its id sorted
                // after 2,000 weaker summary/token matches.
                arguments.append(qLower)
                arguments.append(qLower)
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
                    END, id
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
                    "results": .array(candidates.searchEntities(query))
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
                    """, arguments: [id, id, sqliteIncidentEdgeLimit])
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
        }
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
                guard total <= pageLimit * sqlitePageSize else {
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
                return try storeFromDatabase(db).allEntities(
                    page: 0,
                    pageSize: max(total, 1)
                )
            }
        }
    }

    private static func withPreparedPool<T: Sendable>(
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
        return pool
    }

    private static func readFromPool(_ pool: DatabasePool) async throws -> KnowledgeGraphStore {
        try await pool.read { db in
            try storeFromDatabase(db)
        }
    }

    private static func storeFromDatabase(_ db: Database) throws -> KnowledgeGraphStore {
            // Entities — fetch in stable id order (PRIMARY KEY) for deterministic
            // pagination. Daemon's JSON-derived ordering was insertion-order; the
            // SQLite cutover trades that for lexicographic id order, which
            // matches the no-import-yet fallback path KnowledgeGraphStore.normalize
            // uses when entityKeyOrder is nil.
            let entityRows = try Row.fetchAll(db, sql: """
                SELECT id, name, type, summary, aliases_json, mention_count,
                       first_seen, last_seen, provenance, metadata_json
                FROM kg_entities ORDER BY id
                """)
            var entities: [String: JSONValue] = [:]
            var entityOrder: [String] = []
            for r in entityRows {
                let id: String = r["id"] ?? ""
                guard !id.isEmpty else { continue }
                var obj: [String: JSONValue] = [:]
                obj["id"] = .string(id)
                if let name: String = r["name"] { obj["name"] = .string(name) }
                if let type: String = r["type"] { obj["type"] = .string(type) }
                if let s: String = r["summary"] { obj["summary"] = .string(s) }
                if let aliasesStr: String = r["aliases_json"],
                   let aliasesData = aliasesStr.data(using: .utf8),
                   let aliases = try? JSONValue.parse(aliasesData) {
                    obj["aliases"] = aliases
                }
                if let mc: Int64 = r["mention_count"] { obj["mention_count"] = .int(mc) }
                if let fs: String = r["first_seen"] { obj["first_seen"] = .string(fs) }
                if let ls: String = r["last_seen"] { obj["last_seen"] = .string(ls) }
                if let prov: String = r["provenance"] { obj["provenance"] = .string(prov) }
                if let metaStr: String = r["metadata_json"],
                   let metaData = metaStr.data(using: .utf8),
                   let meta = try? JSONValue.parse(metaData),
                   case .object(let mobj) = meta {
                    for (k, v) in mobj where obj[k] == nil { obj[k] = v }
                }
                entities[id] = .object(obj)
                entityOrder.append(id)
            }
            let edgeRows = try Row.fetchAll(db, sql: """
                SELECT from_id, to_id, type, weight, mention_count, provenance, metadata_json
                FROM kg_relationships
                ORDER BY from_id, to_id, type
                """)
            let entityIds = Set(entities.keys)
            var edges: [JSONValue] = []
            for r in edgeRows {
                let fromId: String = r["from_id"] ?? ""
                let toId: String = r["to_id"] ?? ""
                let type: String = r["type"] ?? ""
                guard !fromId.isEmpty, !toId.isEmpty, !type.isEmpty else { continue }
                guard entityIds.contains(fromId), entityIds.contains(toId) else { continue }
                var obj: [String: JSONValue] = [
                    "from": .string(fromId),
                    "to": .string(toId),
                    "type": .string(type),
                ]
                if let w: Double = r["weight"] { obj["weight"] = .double(w) }
                if let mc: Int64 = r["mention_count"] { obj["mention_count"] = .int(mc) }
                if let prov: String = r["provenance"] { obj["provenance"] = .string(prov) }
                if let metaStr: String = r["metadata_json"],
                   let metaData = metaStr.data(using: .utf8),
                   let meta = try? JSONValue.parse(metaData),
                   case .object(let mobj) = meta {
                    for (k, v) in mobj where obj[k] == nil { obj[k] = v }
                }
                edges.append(.object(obj))
            }
        return KnowledgeGraphStore(
            entities: entities,
            entityOrder: entityOrder,
            edges: edges,
            commitSeq: 0
        )
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
    }

    private static func maybeImportJSON(
        pool: DatabasePool,
        jsonPath: URL,
        sentinelPath: URL
    ) async throws {
        // Already non-empty? Stamp the sentinel and skip import — the SQLite
        // tables are presumably the source of truth from a prior boot.
        let alreadyHas = try await pool.read { db in
            (try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM kg_entities") ?? 0) > 0
        }
        if alreadyHas {
            // The sentinel is part of the migration commit boundary. If it
            // cannot be persisted, fail closed: swallowing this write could
            // let a later empty authoritative graph re-import stale JSON.
            try SwiftNativePersistenceCore.writeDataAtomicDurable(Data(), to: sentinelPath)
            return
        }
        // Nothing to import? Still write the sentinel so subsequent boots skip
        // this check entirely.
        guard FileManager.default.fileExists(atPath: jsonPath.path) else {
            try SwiftNativePersistenceCore.writeDataAtomicDurable(Data(), to: sentinelPath)
            return
        }
        // Existing-but-unreadable is never the same as an intentionally empty
        // legacy graph. A permissive load here used to stamp the one-way marker
        // over repairable JSON corruption.
        let jsonStore = try KnowledgeGraphStore.loadChecked(path: jsonPath)
        guard !jsonStore.entities.isEmpty || !jsonStore.edges.isEmpty else {
            try SwiftNativePersistenceCore.writeDataAtomicDurable(Data(), to: sentinelPath)
            return
        }
        try await pool.write { db in
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
                let mentionCount: Int64 = {
                    if case .int(let i)? = e["mention_count"] { return i }
                    if case .double(let d)? = e["mention_count"] { return Int64(d) }
                    return 0
                }()
                let firstSeen: String? = {
                    if case .string(let s)? = e["first_seen"] { return s }; return nil
                }()
                let lastSeen: String? = {
                    if case .string(let s)? = e["last_seen"] { return s }; return nil
                }()
                let provenance: String? = {
                    if case .string(let s)? = e["provenance"] { return s }; return nil
                }()
                // Metadata bag — everything not modeled as a column.
                let metaKnown: Set<String> = [
                    "id", "name", "type", "summary", "aliases", "mention_count",
                    "first_seen", "last_seen", "provenance",
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
                let mc: Int64 = {
                    if case .int(let i)? = e["mention_count"] { return i }
                    if case .double(let d)? = e["mention_count"] { return Int64(d) }
                    return 0
                }()
                let provenance: String? = {
                    if case .string(let s)? = e["provenance"] { return s }; return nil
                }()
                let edgeKnown: Set<String> = [
                    "from", "to", "type", "weight", "mention_count", "provenance",
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
