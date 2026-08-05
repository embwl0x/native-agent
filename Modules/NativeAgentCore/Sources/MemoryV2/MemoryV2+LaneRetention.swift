// MemoryV2 lane retention — the bounded, tombstone-free primitives a WRITING
// LANE needs to keep its own rows in check.
//
// WHY THIS EXISTS (gpt-5.5 review A2/A4, 2026-08-02):
//
// A lane that writes one row per event (Workshop executions, and any lane like
// it) has to bound itself — MemoryV2's own removes do not cover it: capacity
// eviction only fires above 2,000 rows and the stale-archive pass is gated
// behind two human approvals. Before this file the Workshop lane bounded itself
// with `deleteMemory`, and deletion MINTS A CONTENT TOMBSTONE
// (`MemoryV2+Storage.deleteMemory` → `upsertTombstone`). A tombstone is a
// statement that a claim was REJECTED. Applying it to a row evicted for AGE is
// a category error with a real failure: rerun the same execution to the same
// outcome six months later, the narrative is byte-identical, and `store()`
// refuses it as "tombstoned" — the lane silently stops remembering repeats.
//
// So: retirement is an ARCHIVE (status flips to `archived`, no tombstone, the
// row stays walkable for lineage), and enumeration is a two-column bounded
// query instead of a full active-store scan plus in-Swift metadata filtering.

import Foundation
import GRDB

/// Identity-only view of a stored memory: enough to order and retire a lane's
/// own rows, with none of the decode cost of a full record (no embedding blob,
/// no metadata JSON parse).
public struct MemoryLaneHandle: Sendable, Equatable {
    public let id: String
    /// ISO-8601, so lexicographic order IS chronological order.
    public let createdAt: String
    public let source: String?

    public init(id: String, createdAt: String, source: String?) {
        self.id = id
        self.createdAt = createdAt
        self.source = source
    }
}

extension MemoryStorageProtocol {
    /// Default (fixture) implementation: derive handles from `listMemory`.
    /// Correct but unbounded — the SQLite bridge overrides it with a real
    /// query. Kept as a protocol REQUIREMENT (declared in
    /// `MemoryStorageProtocol`) rather than extension-only for the reason the
    /// `matchesTombstone` comment already records: through
    /// `any MemoryStorageProtocol` an extension-only method always dispatches
    /// to the default and the override goes inert.
    public func memoryHandles(sourcePrefix: String, limit: Int?) async throws -> [MemoryLaneHandle] {
        let rows = try await listMemory(kind: nil)
            .filter { ($0.status ?? "active") == "active" }
            .filter { ($0.sourceRunId ?? "").hasPrefix(sourcePrefix) }
            .sorted { $0.createdAt > $1.createdAt }
        let bounded = limit.map { Array(rows.prefix(max(0, $0))) } ?? rows
        return bounded.map {
            MemoryLaneHandle(id: $0.id, createdAt: $0.createdAt, source: $0.sourceRunId)
        }
    }
}

extension SwiftNativeMemoryV2 {
    /// Newest-first identity handles for one lane's rows, ACTIVE only, bounded
    /// by `limit`. The retention-sweep read path — never the recall path.
    public func memoryHandles(sourcePrefix: String, limit: Int? = nil) async throws -> [MemoryLaneHandle] {
        guard let storage else { throw MemoryV2Error.storageUnavailable }
        return try await storage.memoryHandles(sourcePrefix: sourcePrefix, limit: limit)
    }

    /// Retire a row out of the active set WITHOUT a rejection tombstone: flips
    /// `status` to `archived` and nothing else. Goes through the ordinary
    /// update path, which re-embeds and consults the tombstone gates ONLY when
    /// the patch changes content — this one does not, so it costs no embed and
    /// mints no denylist entry.
    ///
    /// Returns the archived record.
    @discardableResult
    public func archiveMemory(id: String) async throws -> MemoryRecord {
        try await updateMemory(id: id, update: .object(["status": .string("archived")]))
    }
}

extension MemoryStorage {
    /// Two-column, indexed, LIMITed lane enumeration. Replaces "SELECT * every
    /// active row, decode all of it, filter in Swift" on a hot path
    /// (gpt-5.5 review A4). Lifecycle-terminal rows are excluded on the same
    /// grounds `listMemories` excludes them.
    public func laneHandles(sourcePrefix: String, limit: Int?) async throws -> [MemoryLaneHandle] {
        // LIKE-escape the caller's prefix so a `%`/`_` in a lane id can never
        // widen the match beyond that lane.
        let escaped = sourcePrefix
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_")
        return try await dbPool.read { db in
            var sql = """
                SELECT id, created_at, source FROM memories
                WHERE source LIKE ? ESCAPE '\\'
                  AND status = 'active'
                  AND lifecycle NOT IN ('corrected', 'contradicted', 'deleted')
                ORDER BY created_at DESC, id DESC
            """
            var args: [DatabaseValueConvertible] = [escaped + "%"]
            if let limit {
                sql += " LIMIT ?"
                args.append(max(0, limit))
            }
            let rows = try Row.fetchAll(db, sql: sql, arguments: StatementArguments(args))
            return rows.map { row in
                MemoryLaneHandle(
                    id: row["id"],
                    createdAt: row["created_at"],
                    source: row["source"]
                )
            }
        }
    }
}
