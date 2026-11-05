import Foundation
import GRDB
// Blueprint: | `KnowledgeGraph+GrowthDistillation.swift` | Independent REM/GROWTH provenance through the canonical graph store |

extension SwiftNativeKnowledgeGraphIndexer {
    /// Use the authoritative graph and a stable caller-supplied ID for idempotent eviction writes. Write the node before splicing GROWTH.md: only a
    /// corroborating node proves a missing passage was evicted; without it, the file is unreadable.
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
        createdAt: String
    ) async throws {
        let boundedID = id.trimmingCharacters(in: .whitespacesAndNewlines)
        // The distillation bounds its summary and keeps its locator whole after it.
        let boundedSummary = summary.trimmingCharacters(in: .whitespacesAndNewlines)
        let boundedCreatedAt = createdAt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !boundedID.isEmpty, !boundedSummary.isEmpty, !boundedCreatedAt.isEmpty else {
            throw NSError(
                domain: "KnowledgeGraph.GrowthDistillation",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey:
                    "growth distillation requires non-empty id, summary, and timestamp"]
            )
        }

        let dbPool = try await KnowledgeGraphStore.withPreparedPool(
            memoryDir: sqlitePath.deletingLastPathComponent()
        ) { $0 }
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
