import CryptoKit
import Foundation
import GRDB
import PersistenceCore

// Blueprint: | `ContextSQLiteMaintenance.swift` | `ContextSQLiteStore` source degradation, ordered feedback persistence, health, pruning and vacuum on its single pool |

extension ContextSQLiteStore {
    public func markSourceDegraded(
        _ sourceID: ContextSourceID,
        error: String
    ) async throws {
        let boundedError = Self.bounded(error, maxUTF8Bytes: 2_048, fallback: "compile failed")
        try await dbPool.write { db in
            try db.execute(
                sql: """
                UPDATE context_sources
                SET health = 'degraded'
                WHERE id = ? AND health != 'removed'
                """,
                arguments: [sourceID.rawValue]
            )
            try db.execute(
                sql: """
                UPDATE context_source_versions
                SET health = 'degraded', last_error = ?
                WHERE source_id = ? AND valid_to_generation IS NULL AND health != 'removed'
                """,
                arguments: [boundedError, sourceID.rawValue]
            )
        }
    }

    /// Exact bounded feedback events rebuild advisory ranking after restart without becoming facts.
    public func recordFeedbackEvent(_ event: ContextFeedbackEvent) async throws {
        try await dbPool.write { db in
            try db.execute(
                sql: """
                INSERT INTO context_feedback_events (
                    id, atom_ids_json, signal_json, time_bucket, evidence_ids_json, created_at,
                    session_id, history_message_fingerprint
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                """,
                arguments: [
                    event.id,
                    try Self.encodeJSON(event.atomIDs),
                    try Self.encodeJSON(event.signal),
                    event.timeBucket,
                    try Self.encodeJSON(event.evidenceIDs),
                    Date().timeIntervalSince1970,
                    event.sessionID,
                    event.historyMessageFingerprint,
                ]
            )
            try db.execute(sql: """
                DELETE FROM context_feedback_events
                WHERE sequence < COALESCE((
                    SELECT sequence FROM context_feedback_events
                    ORDER BY sequence DESC
                    LIMIT 1 OFFSET 4095
                ), 0)
                """)
        }
    }

    // Restore through the writer so in-flight feedback ordinals cannot be reused.
    public func recentFeedbackEvents(limit: Int = 4_096) async throws -> [ContextFeedbackEvent] {
        try await dbPool.write { db in
            let boundedLimit = max(0, min(limit, 4_096))
            let rows = try Row.fetchAll(
                db,
                sql: """
                SELECT id, atom_ids_json, signal_json, time_bucket, evidence_ids_json,
                       session_id, history_message_fingerprint
                FROM context_feedback_events
                ORDER BY sequence ASC
                LIMIT ?
                """,
                arguments: [boundedLimit]
            )
            return try rows.map(Self.decodeFeedbackEvent)
        }
    }

    public func feedbackEventOrdinalHighWaterMark() async throws -> UInt64 {
        try await dbPool.write { db in
            let value = try Int64.fetchOne(
                db,
                sql: "SELECT COALESCE(MAX(sequence), 0) FROM context_feedback_events"
            ) ?? 0
            return UInt64(max(0, value))
        }
    }

    public func healthSnapshot() async throws -> ContextStoreHealthSnapshot {
        try await dbPool.read { db in
            let activeGenerationID = try Int64.fetchOne(
                db,
                sql: "SELECT id FROM context_generations WHERE status = 'completed' ORDER BY id DESC LIMIT 1"
            )
            let healthy = try Self.countSources(health: .healthy, db: db)
            let degraded = try Self.countSources(health: .degraded, db: db)
            let removed = try Self.countSources(health: .removed, db: db)
            let atoms = try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM context_atom_versions WHERE valid_to_generation IS NULL"
            ) ?? 0
            return ContextStoreHealthSnapshot(
                databaseURL: self.databaseURL,
                activeGenerationID: activeGenerationID,
                healthySources: healthy,
                degradedSources: degraded,
                removedSources: removed,
                activeAtoms: atoms
            )
        }
    }

    public func prune(
        retainingLatest generationLimit: Int = 8,
        protectedGenerationIDs: Set<Int64> = []
    ) async throws -> ContextStorePruneResult {
        try await dbPool.write { db in
            let latest = try Int64.fetchAll(
                db,
                sql: """
                SELECT id FROM context_generations
                WHERE status = 'completed'
                ORDER BY id DESC LIMIT ?
                """,
                arguments: [max(1, generationLimit)]
            )
            let kept = Set(latest).union(protectedGenerationIDs).sorted()
            let keptRows = kept.isEmpty ? "SELECT NULL WHERE 0" : "VALUES " + kept.map { _ in "(?)" }.joined(separator: ",")
            let arguments = StatementArguments(kept)
            let deletedVersions = try [
                "context_atom_versions", "context_source_versions", "context_relationship_versions"
            ].map { table in
                try db.execute(
                    sql: """
                    WITH kept(id) AS (\(keptRows))
                    DELETE FROM \(table)
                    WHERE NOT EXISTS (
                        SELECT 1 FROM kept
                        WHERE id >= valid_from_generation
                          AND (valid_to_generation IS NULL OR id <= valid_to_generation)
                    )
                    """,
                    arguments: arguments
                )
                return db.changesCount
            }
            try db.execute(
                sql: """
                WITH kept(id) AS (\(keptRows))
                DELETE FROM context_generations
                WHERE status = 'completed' AND id NOT IN (SELECT id FROM kept)
                """,
                arguments: arguments
            )
            let deletedGenerations = db.changesCount

            // Drop removed source identities once no retained version refers to them.
            try db.execute(sql: """
                DELETE FROM context_sources
                WHERE health = 'removed'
                  AND NOT EXISTS (
                    SELECT 1 FROM context_source_versions
                    WHERE context_source_versions.source_id = context_sources.id
                  )
                """)

            return ContextStorePruneResult(
                deletedGenerations: deletedGenerations,
                deletedAtomVersions: deletedVersions[0],
                deletedSourceVersions: deletedVersions[1],
                deletedRelationshipVersions: deletedVersions[2]
            )
        }
    }

    /// Reclaim pruned disk pages outside a transaction; callers gate this full-file rewrite.
    public func vacuum() async throws {
        try await dbPool.writeWithoutTransaction { db in
            try db.execute(sql: "VACUUM")
        }
    }

    private static func countSources(health: ContextSourceHealth, db: Database) throws -> Int {
        try Int.fetchOne(
            db,
            sql: "SELECT COUNT(*) FROM context_sources WHERE health = ?",
            arguments: [health.rawValue]
        ) ?? 0
    }
}
