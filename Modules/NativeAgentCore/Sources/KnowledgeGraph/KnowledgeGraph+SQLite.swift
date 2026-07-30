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
        let sqlitePath = memoryDir.appendingPathComponent("memory.sqlite")
        let sentinelPath = memoryDir.appendingPathComponent(".kg_migrated_to_sqlite_v1")
        do {
            let pool = try await KnowledgeGraphPoolCache.shared.pool(at: sqlitePath)
            // One-time JSON -> SQLite import.
            if let jsonPath = jsonImportPath,
               !FileManager.default.fileExists(atPath: sentinelPath.path) {
                try await maybeImportJSON(
                    pool: pool,
                    jsonPath: jsonPath,
                    sentinelPath: sentinelPath
                )
            }
            return try await readFromPool(pool)
        } catch KnowledgeGraphPoolCache.PoolError.databaseMissing(let path) {
            throw KnowledgeGraphSQLiteLoadError.databaseMissing(path)
        } catch let error as KnowledgeGraphSQLiteLoadError {
            throw error
        } catch {
            throw KnowledgeGraphSQLiteLoadError.unreadable(
                path: sqlitePath.path,
                detail: String(describing: error)
            )
        }
    }

    private static func readFromPool(_ pool: DatabasePool) async throws -> KnowledgeGraphStore {
        return try await pool.read { db in
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
            try Data().write(to: sentinelPath, options: .atomic)
            return
        }
        // Nothing to import? Still write the sentinel so subsequent boots skip
        // this check entirely.
        guard FileManager.default.fileExists(atPath: jsonPath.path) else {
            try Data().write(to: sentinelPath, options: .atomic)
            return
        }
        let jsonStore = KnowledgeGraphStore.load(path: jsonPath)
        guard !jsonStore.entities.isEmpty || !jsonStore.edges.isEmpty else {
            try Data().write(to: sentinelPath, options: .atomic)
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
        try Data().write(to: sentinelPath, options: .atomic)
    }
}
