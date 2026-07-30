// Swift-native Knowledge Graph forget mutation.
//
// `memory.sqlite` is the authoritative live graph store. The JSON mutation is
// retained only for a true pre-SQLite fixture/install; the presence of SQLite
// forbids fallback even when its graph is empty or the database is unreadable.

import Foundation
import GRDB
import NativeAgentCore
import PersistenceCore

// MARK: - Forget-write client protocol

public protocol KnowledgeGraphForgetClient: Sendable {
    /// POST /v1/knowledge_graph/forget — remove the entity and its incident
    /// relationships from the authoritative Knowledge Graph store.
    ///
    /// When `<dataRoot>/memory/memory.sqlite` exists it is authoritative, even
    /// when its graph is empty. JSON is a guarded pre-SQLite compatibility path
    /// only. An existing unreadable SQLite store fails closed and must never
    /// fall back to stale JSON.
    /// Returns a body byte-faithful to `forget_entity`:
    ///   - unknown id  → {"error": "not_found"}
    ///   - success     → {"ok": true, "forgotten": <id>, "reason": <reason>}
    func forgetEntity(entityId: String, reason: String) async throws -> JSONValue
}

// MARK: - SwiftNative impl

public final class SwiftNativeKnowledgeGraphForgetClient: KnowledgeGraphForgetClient {
    /// Absolute path to `<dataRoot>/memory/knowledge_graph.json`. Its parent is
    /// also the canonical location of `memory.sqlite`.
    public let graphPath: URL
    private let persistence: SwiftNativePersistenceCore

    public init(
        graphPath: URL,
        persistence: SwiftNativePersistenceCore = SwiftNativePersistenceCore()
    ) {
        self.graphPath = graphPath
        self.persistence = persistence
    }

    public func forgetEntity(entityId: String, reason: String) async throws -> JSONValue {
        let memoryDirectory = graphPath.deletingLastPathComponent()
        let sqlitePath = memoryDirectory.appendingPathComponent("memory.sqlite")
        if FileManager.default.fileExists(atPath: sqlitePath.path) {
            do {
                return try await forgetSQLiteEntity(
                    entityId: entityId,
                    reason: reason,
                    memoryDirectory: memoryDirectory,
                    sqlitePath: sqlitePath
                )
            } catch KnowledgeGraphPoolCache.PoolError.databaseMissing {
                // This invocation already observed SQLite ownership. A later
                // removal/replacement race must fail closed instead of
                // reviving the pre-migration writer.
                throw KnowledgeGraphSQLiteLoadError.unreadable(
                    path: sqlitePath.path,
                    detail: "authoritative database disappeared during forget"
                )
            } catch KnowledgeGraphSQLiteLoadError.databaseMissing {
                throw KnowledgeGraphSQLiteLoadError.unreadable(
                    path: sqlitePath.path,
                    detail: "authoritative database disappeared during migration check"
                )
            } catch let error as KnowledgeGraphSQLiteLoadError {
                throw error
            } catch {
                throw KnowledgeGraphSQLiteLoadError.unreadable(
                    path: sqlitePath.path,
                    detail: String(describing: error)
                )
            }
        }
        return try await forgetLegacyJSONEntity(entityId: entityId, reason: reason)
    }

    /// SQLite is the live graph's single mutation owner. The load call is
    /// intentionally first: it completes the one-time JSON import (or stamps
    /// the migration sentinel when SQLite already has rows) before the delete.
    /// Without that ordering an empty migrated database could report
    /// `not_found`, then import the supposedly forgotten legacy entity on the
    /// next read.
    private func forgetSQLiteEntity(
        entityId: String,
        reason: String,
        memoryDirectory: URL,
        sqlitePath: URL
    ) async throws -> JSONValue {
        _ = try await KnowledgeGraphStore.loadFromMemoryV2(
            memoryDir: memoryDirectory,
            jsonImportPath: graphPath
        )
        let pool = try await KnowledgeGraphPoolCache.shared.pool(at: sqlitePath)
        return try await pool.write { db in
            let exists = (try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM kg_entities WHERE id = ?",
                arguments: [entityId]
            ) ?? 0) > 0
            guard exists else {
                return .object(["error": .string("not_found")])
            }

            // Entity, relationship, and their embedded provenance disappear in
            // one SQLite transaction. `kg_memory_index` deliberately remains:
            // it indexes canonical MemoryV2 facts, not individual graph nodes.
            // Deleting a source-memory index row here would falsely claim the
            // memory was never indexed and invite immediate entity resurrection.
            try db.execute(
                sql: "DELETE FROM kg_relationships WHERE from_id = ? OR to_id = ?",
                arguments: [entityId, entityId]
            )
            try db.execute(sql: "DELETE FROM kg_entities WHERE id = ?", arguments: [entityId])

            return .object([
                "ok": .bool(true),
                "forgotten": .string(entityId),
                "reason": .string(reason),
            ])
        }
    }

    /// Pre-migration compatibility only. Once `memory.sqlite` exists this path
    /// is unreachable by design.
    private func forgetLegacyJSONEntity(entityId: String, reason: String) async throws -> JSONValue {
        // ONE cross-process flock acquisition wraps the read-modify-write, the twin
        // of the daemon's `with file_lock(self._path)` in `_flush_locked`. The
        // daemon's forget holds its in-process `self._lock` across the read AND the
        // write; we hold the flock across the parse+mutate+write for the same
        // read-modify-write atomicity at the FILE level.
        try await persistence.withFileLock(graphPath) { [persistence, graphPath] () -> JSONValue in
            let sqlitePath = graphPath.deletingLastPathComponent()
                .appendingPathComponent("memory.sqlite")
            guard !FileManager.default.fileExists(atPath: sqlitePath.path) else {
                throw KnowledgeGraphSQLiteLoadError.unreadable(
                    path: sqlitePath.path,
                    detail: "authoritative database appeared before legacy forget"
                )
            }
            // Read+parse the current file. A missing/empty/corrupt file parses to
            // the empty-graph skeleton (matching Python `_load`'s boot skeleton),
            // in which `entity_id not in entities` → not_found.
            let raw = await persistence.readJSON(
                graphPath,
                defaultValue: .object(["entities": .object([:]), "edges": .array([]), "version": .int(1)])
            )
            guard case .object(var doc) = raw else {
                // A non-object root cannot contain the entity → not_found, matching
                // the daemon (whose `_data` is always the object skeleton).
                return .object(["error": .string("not_found")])
            }

            // entities map.
            var entities: [String: JSONValue]
            if case .object(let e)? = doc["entities"] { entities = e } else { entities = [:] }

            // Daemon: `if entity_id not in self._data["entities"]: return not_found`.
            // The check is on the dict KEY (string), exactly the route's entity_id.
            guard entities[entityId] != nil else {
                return .object(["error": .string("not_found")])
            }

            // Delete the entity.
            entities.removeValue(forKey: entityId)

            // Filter edges: keep iff `from != entity_id AND to != entity_id`.
            // Daemon compares the RAW endpoint value with `!=` against the string
            // entity_id; a non-string endpoint never equals it, so it is KEPT
            // (the orphan it would create is a separate load-time concern the
            // daemon does not touch here). We mirror with raw JSONValue equality.
            var edges: [JSONValue]
            if case .array(let arr)? = doc["edges"] { edges = arr } else { edges = [] }
            let idValue = JSONValue.string(entityId)
            edges = edges.filter { edge in
                guard case .object(let e) = edge else {
                    // Non-object edge: the daemon's `e.get("from")` would raise, but
                    // edges are always dicts in practice; keep it (cannot reference
                    // the id) rather than silently dropping data.
                    return true
                }
                let from = e["from"] ?? .null
                let to = e["to"] ?? .null
                return from != idValue && to != idValue
            }

            doc["entities"] = .object(entities)
            doc["edges"] = .array(edges)

            // Bump + stamp `_commit_seq` exactly as `_flush_locked` (L317-318):
            // read the current value with the daemon's `max(0, int(... or 0))`
            // semantics, increment, and stamp the new value into the bytes being
            // written. This keeps the SwiftNative reader's freshness sandwich
            // coherent (the file's seq advances on every write, as the daemon's does).
            let currentSeq = Self.commitSeq(from: doc["_commit_seq"])
            doc["_commit_seq"] = .int(Int64(currentSeq + 1))

            // Atomic rewrite under the held flock (PersistenceCore.writeJSON does
            // temp-write + atomic replace; the flock makes it mutually exclusive
            // with the daemon's `_flush_locked` write).
            try await persistence.writeJSON(.object(doc), to: graphPath)

            // Return body byte-faithful to forget_entity's success path
            //.
            return .object([
                "ok": .bool(true),
                "forgotten": .string(entityId),
                "reason": .string(reason),
            ])
        }
    }

    /// Mirror the daemon's `_commit_seq` restore semantics
    /// or 0))`):
    /// an int → itself (clamped ≥0), a double → floored, a numeric string → parsed,
    /// anything else / missing → 0. Used to read the current seq before the bump.
    static func commitSeq(from v: JSONValue?) -> Int {
        switch v {
        case .some(.int(let i)): return max(0, Int(i))
        case .some(.double(let d)): return max(0, Int(d))
        case .some(.string(let s)): return max(0, Int(s) ?? 0)
        default: return 0
        }
    }
}

public enum KnowledgeGraphForgetError: Error, Sendable, Equatable {
    /// Knowledge graph writes were explicitly disabled by policy.
    case flagDisabled
}

// MARK: - Factory

/// Returns the SwiftNative forget-write client. `graphPath` is injectable for
/// tests; production callers omit it and get the default
/// `<dataRoot>/memory/knowledge_graph.json`.
public func makeKnowledgeGraphForgetClient(
    graphPath: URL? = nil
) -> any KnowledgeGraphForgetClient {
    return SwiftNativeKnowledgeGraphForgetClient(
        graphPath: graphPath ?? SwiftNativeKnowledgeGraphReader.defaultPath()
    )
}
