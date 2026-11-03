import Foundation
import GRDB
import PersistenceCore

// Blueprint: | `ContextSQLiteSchema.swift` | Current final Context SQLite schema: checked existing tables and direct fresh creation; no historical migration chain |

extension ContextSQLiteStore {
    /// Opening never converts or resets an unavailable store.
    static func openCurrentSchema(_ pool: DatabasePool) throws {
        try pool.write { db in
            let columns: [String: Set<String>] = [
                "context_generations": ["id", "parent_id", "created_at", "reason", "source_fingerprint", "status", "atom_count", "source_count"],
                "context_sources": ["id", "source_hash", "health"],
                "context_source_versions": ["version_key", "source_id", "valid_from_generation", "valid_to_generation", "descriptor_json", "source_hash", "health", "last_error"],
                "context_atom_versions": ["version_key", "atom_id", "source_id", "valid_from_generation", "valid_to_generation", "body", "summary", "payload_json"],
                "context_embeddings": ["atom_version_key", "model_fingerprint", "dimensions", "vector"],
                "context_feedback_events": ["sequence", "id", "atom_ids_json", "signal_json", "time_bucket", "evidence_ids_json", "created_at", "session_id", "history_message_fingerprint"],
            ]
            let present = try columns.keys.filter { try db.tableExists($0) }
            if !present.isEmpty {
                guard present.count == columns.count else {
                    throw ContextFlowStoreError.malformedStoredValue("Context database schema is incomplete. Repair its schema before opening it; its bytes were preserved.")
                }
                for (table, expected) in columns {
                    guard Set(try db.columns(in: table).map(\.name)) == expected else {
                        throw ContextFlowStoreError.malformedStoredValue("Context database table \(table) is not the current schema. Convert this store before opening it; its bytes were preserved.")
                    }
                }
                return
            }
            let tables = try String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%'")
            guard tables.isEmpty else {
                throw ContextFlowStoreError.malformedStoredValue("Context database has an unknown schema. Repair this store before opening it; its bytes were preserved.")
            }
            try db.execute(sql: """
                CREATE TABLE context_generations (
                    id INTEGER PRIMARY KEY, parent_id INTEGER, created_at REAL NOT NULL,
                    reason TEXT NOT NULL, source_fingerprint TEXT NOT NULL,
                    status TEXT NOT NULL CHECK(status IN ('staging', 'completed')),
                    atom_count INTEGER NOT NULL DEFAULT 0, source_count INTEGER NOT NULL DEFAULT 0,
                    FOREIGN KEY(parent_id) REFERENCES context_generations(id) ON DELETE SET NULL
                );
                CREATE INDEX idx_context_generations_created ON context_generations(created_at DESC);
                CREATE TABLE context_sources (
                    id TEXT PRIMARY KEY, source_hash TEXT NOT NULL,
                    health TEXT NOT NULL CHECK(health IN ('healthy', 'degraded', 'removed'))
                );
                CREATE INDEX idx_context_sources_health ON context_sources(health);
                CREATE TABLE context_source_versions (
                    version_key TEXT PRIMARY KEY, source_id TEXT NOT NULL,
                    valid_from_generation INTEGER NOT NULL, valid_to_generation INTEGER,
                    descriptor_json TEXT NOT NULL, source_hash TEXT NOT NULL,
                    health TEXT NOT NULL, last_error TEXT,
                    FOREIGN KEY(source_id) REFERENCES context_sources(id)
                );
                CREATE INDEX idx_context_source_versions_active ON context_source_versions(source_id, valid_from_generation, valid_to_generation);
                CREATE TABLE context_atom_versions (
                    version_key TEXT PRIMARY KEY, atom_id TEXT NOT NULL, source_id TEXT NOT NULL,
                    valid_from_generation INTEGER NOT NULL, valid_to_generation INTEGER,
                    body TEXT NOT NULL, summary TEXT, payload_json TEXT NOT NULL,
                    FOREIGN KEY(source_id) REFERENCES context_sources(id)
                );
                CREATE INDEX idx_context_atom_versions_active ON context_atom_versions(atom_id, valid_from_generation, valid_to_generation);
                CREATE INDEX idx_context_atom_versions_source ON context_atom_versions(source_id, valid_from_generation, valid_to_generation);
                CREATE TABLE context_embeddings (
                    atom_version_key TEXT PRIMARY KEY, model_fingerprint TEXT NOT NULL,
                    dimensions INTEGER NOT NULL, vector BLOB NOT NULL,
                    FOREIGN KEY(atom_version_key) REFERENCES context_atom_versions(version_key) ON DELETE CASCADE
                );
                CREATE TABLE context_feedback_events (
                    sequence INTEGER PRIMARY KEY AUTOINCREMENT, id TEXT NOT NULL UNIQUE,
                    atom_ids_json TEXT NOT NULL, signal_json TEXT NOT NULL,
                    time_bucket INTEGER NOT NULL, evidence_ids_json TEXT NOT NULL,
                    created_at REAL NOT NULL, session_id TEXT, history_message_fingerprint TEXT
                );
                CREATE INDEX idx_context_feedback_events_sequence ON context_feedback_events(sequence);
                """)
        }
    }
}
