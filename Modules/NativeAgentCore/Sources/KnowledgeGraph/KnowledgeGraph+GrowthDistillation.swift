import Foundation
import GRDB

extension SwiftNativeKnowledgeGraphIndexer {
    /// Store one REM GROWTH eviction in the authoritative SQLite graph.
    ///
    /// This is deliberately an operation on the existing KnowledgeGraph owner,
    /// not a Dream/REM-side graph store. The one-time legacy JSON import is
    /// completed before the write, and a stable caller-supplied id makes a
    /// retry after a partial GROWTH-file commit an idempotent upsert.
    /// Does a distilled GROWTH-eviction node with this id stand in the graph?
    /// The eviction history uses it as the corroborating witness for an
    /// interrupted splice: the node is written before the GROWTH.md rewrite,
    /// so a passage missing from the file WITH its node present really was
    /// evicted, while a missing passage and no node is an unreadable file.
    public func growthDistillationExists(id: String) async throws -> Bool {
        let boundedID = id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !boundedID.isEmpty else { return false }
        let dbPool = try await KnowledgeGraphPoolCache.shared.pool(at: sqlitePath)
        let count: Int? = try await dbPool.read { db in
            try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM kg_entities WHERE id = ?",
                arguments: [boundedID]
            )
        }
        return (count ?? 0) > 0
    }

    public func upsertGrowthDistillation(
        id: String,
        summary: String,
        sourceLines: Int,
        createdAt: String,
        legacyJSONPath: URL?
    ) async throws {
        let boundedID = id.trimmingCharacters(in: .whitespacesAndNewlines)
        let boundedSummary = String(
            summary.trimmingCharacters(in: .whitespacesAndNewlines).prefix(400)
        )
        let boundedCreatedAt = createdAt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !boundedID.isEmpty, !boundedSummary.isEmpty, !boundedCreatedAt.isEmpty else {
            throw NSError(
                domain: "KnowledgeGraph.GrowthDistillation",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey:
                    "growth distillation requires non-empty id, summary, and timestamp"]
            )
        }

        let memoryDirectory = sqlitePath.deletingLastPathComponent()
        _ = try await KnowledgeGraphStore.loadFromMemoryV2(
            memoryDir: memoryDirectory,
            jsonImportPath: legacyJSONPath
        )
        let dbPool = try await KnowledgeGraphPoolCache.shared.pool(at: sqlitePath)
        let name = String(boundedSummary.prefix(80))
        let lineCount = max(0, sourceLines)
        try await dbPool.write { db in
            try db.execute(sql: """
                INSERT INTO kg_entities
                  (id, name, type, summary, aliases_json, mention_count,
                   first_seen, last_seen, provenance, metadata_json)
                VALUES (?, ?, 'growth_distillation', ?, '[]', ?, ?, ?,
                        'rem-growth-eviction', NULL)
                ON CONFLICT(id) DO UPDATE SET
                  name = excluded.name,
                  type = excluded.type,
                  summary = excluded.summary,
                  aliases_json = excluded.aliases_json,
                  mention_count = excluded.mention_count,
                  last_seen = excluded.last_seen,
                  provenance = excluded.provenance
                """, arguments: [
                    boundedID,
                    name,
                    boundedSummary,
                    lineCount,
                    boundedCreatedAt,
                    boundedCreatedAt,
                ])
        }
    }
}
