import CryptoKit
import Foundation
import GRDB
import PersistenceCore

// Blueprint: | `ContextSQLiteSchema.swift` | `ContextSQLiteStore` schema: unchanged migration identities and SQLite definitions |

extension ContextSQLiteStore {
    static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("context_flow_v1") { db in
            try db.execute(sql: """
                CREATE TABLE context_meta (
                    key TEXT PRIMARY KEY,
                    value TEXT NOT NULL
                );

                CREATE TABLE context_generations (
                    id INTEGER PRIMARY KEY,
                    parent_id INTEGER,
                    created_at REAL NOT NULL,
                    reason TEXT NOT NULL,
                    source_fingerprint TEXT NOT NULL,
                    status TEXT NOT NULL CHECK(status IN ('staging', 'completed')),
                    atom_count INTEGER NOT NULL DEFAULT 0,
                    source_count INTEGER NOT NULL DEFAULT 0,
                    FOREIGN KEY(parent_id) REFERENCES context_generations(id) ON DELETE SET NULL
                );
                CREATE INDEX idx_context_generations_created
                    ON context_generations(created_at DESC);

                CREATE TABLE context_sources (
                    id TEXT PRIMARY KEY,
                    descriptor_json TEXT NOT NULL,
                    owner TEXT NOT NULL,
                    kind TEXT NOT NULL,
                    canonical_locator TEXT NOT NULL,
                    authority TEXT NOT NULL,
                    privacy TEXT NOT NULL,
                    permitted_surfaces_json TEXT NOT NULL,
                    injection_policy TEXT NOT NULL,
                    source_hash TEXT NOT NULL,
                    health TEXT NOT NULL CHECK(health IN ('healthy', 'degraded', 'removed')),
                    last_error TEXT,
                    updated_at REAL NOT NULL
                );
                CREATE INDEX idx_context_sources_health ON context_sources(health, kind);

                CREATE TABLE context_source_versions (
                    version_key TEXT PRIMARY KEY,
                    source_id TEXT NOT NULL,
                    valid_from_generation INTEGER NOT NULL,
                    valid_to_generation INTEGER,
                    descriptor_json TEXT NOT NULL,
                    source_hash TEXT NOT NULL,
                    health TEXT NOT NULL,
                    last_error TEXT,
                    FOREIGN KEY(source_id) REFERENCES context_sources(id)
                );
                CREATE INDEX idx_context_source_versions_active
                    ON context_source_versions(source_id, valid_from_generation, valid_to_generation);

                CREATE TABLE context_atom_versions (
                    version_key TEXT PRIMARY KEY,
                    atom_id TEXT NOT NULL,
                    source_id TEXT NOT NULL,
                    valid_from_generation INTEGER NOT NULL,
                    valid_to_generation INTEGER,
                    kind TEXT NOT NULL,
                    source_hash TEXT NOT NULL,
                    authority TEXT NOT NULL,
                    privacy TEXT NOT NULL,
                    injection_policy TEXT NOT NULL,
                    content_role TEXT NOT NULL,
                    expires_at REAL,
                    body TEXT NOT NULL,
                    summary TEXT,
                    payload_json TEXT NOT NULL,
                    FOREIGN KEY(source_id) REFERENCES context_sources(id)
                );
                CREATE INDEX idx_context_atom_versions_active
                    ON context_atom_versions(atom_id, valid_from_generation, valid_to_generation);
                CREATE INDEX idx_context_atom_versions_source
                    ON context_atom_versions(source_id, valid_from_generation, valid_to_generation);
                CREATE INDEX idx_context_atom_versions_eligibility
                    ON context_atom_versions(privacy, injection_policy, expires_at);

                CREATE TABLE context_embeddings (
                    atom_version_key TEXT PRIMARY KEY,
                    model_fingerprint TEXT NOT NULL,
                    dimensions INTEGER NOT NULL,
                    vector BLOB NOT NULL,
                    FOREIGN KEY(atom_version_key) REFERENCES context_atom_versions(version_key)
                        ON DELETE CASCADE
                );

                CREATE TABLE context_relationship_versions (
                    version_key TEXT PRIMARY KEY,
                    relationship_id TEXT NOT NULL,
                    source_atom_id TEXT NOT NULL,
                    target_atom_id TEXT NOT NULL,
                    kind TEXT NOT NULL,
                    weight REAL NOT NULL,
                    provenance TEXT NOT NULL,
                    valid_from_generation INTEGER NOT NULL,
                    valid_to_generation INTEGER,
                    payload_json TEXT NOT NULL
                );
                CREATE INDEX idx_context_relationship_source
                    ON context_relationship_versions(source_atom_id, valid_from_generation, valid_to_generation);
                CREATE INDEX idx_context_relationship_target
                    ON context_relationship_versions(target_atom_id, valid_from_generation, valid_to_generation);

                CREATE TABLE context_conflicts (
                    id TEXT PRIMARY KEY,
                    generation_id INTEGER NOT NULL,
                    status TEXT NOT NULL,
                    payload_json TEXT NOT NULL,
                    created_at REAL NOT NULL,
                    updated_at REAL NOT NULL,
                    FOREIGN KEY(generation_id) REFERENCES context_generations(id) ON DELETE CASCADE
                );

                CREATE TABLE context_receipts (
                    id TEXT PRIMARY KEY,
                    kind TEXT NOT NULL,
                    generation_id INTEGER,
                    summary TEXT NOT NULL,
                    details_json TEXT NOT NULL,
                    created_at REAL NOT NULL,
                    FOREIGN KEY(generation_id) REFERENCES context_generations(id) ON DELETE SET NULL
                );
                CREATE INDEX idx_context_receipts_created
                    ON context_receipts(created_at DESC, kind);

                CREATE TABLE context_compile_failures (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    source_id TEXT NOT NULL,
                    error TEXT NOT NULL,
                    created_at REAL NOT NULL
                );
                CREATE INDEX idx_context_compile_failures_source
                    ON context_compile_failures(source_id, created_at DESC);

                """)
        }
        // Drop the unqueried duplicate atom index from existing stores.
        migrator.registerMigration("context_feedback_events_v2") { db in
            try db.execute(sql: "DROP TABLE IF EXISTS context_fts")
            try db.execute(sql: """
                CREATE TABLE context_feedback_events (
                    sequence INTEGER PRIMARY KEY AUTOINCREMENT,
                    id TEXT NOT NULL UNIQUE,
                    atom_ids_json TEXT NOT NULL,
                    signal_json TEXT NOT NULL,
                    time_bucket INTEGER NOT NULL,
                    evidence_ids_json TEXT NOT NULL,
                    created_at REAL NOT NULL
                );
                CREATE INDEX idx_context_feedback_events_sequence
                    ON context_feedback_events(sequence);
                """)
        }
        migrator.registerMigration("context_receipt_kind_retention_v3") { db in
            try db.execute(sql: """
                CREATE INDEX IF NOT EXISTS idx_context_receipts_kind_created_id
                    ON context_receipts(kind, created_at DESC, id ASC);
                """)
        }
        // Version payloads own source policy, atom eligibility and relationships.
        migrator.registerMigration("context_payload_ownership_v4") { db in
            try db.execute(sql: """
                DROP TABLE context_meta;
                DROP TABLE context_compile_failures;
                DROP TABLE context_conflicts;
                DROP INDEX idx_context_sources_health;
                DROP INDEX idx_context_atom_versions_eligibility;
                ALTER TABLE context_sources DROP COLUMN descriptor_json;
                ALTER TABLE context_sources DROP COLUMN owner;
                ALTER TABLE context_sources DROP COLUMN kind;
                ALTER TABLE context_sources DROP COLUMN canonical_locator;
                ALTER TABLE context_sources DROP COLUMN authority;
                ALTER TABLE context_sources DROP COLUMN privacy;
                ALTER TABLE context_sources DROP COLUMN permitted_surfaces_json;
                ALTER TABLE context_sources DROP COLUMN injection_policy;
                ALTER TABLE context_sources DROP COLUMN last_error;
                ALTER TABLE context_sources DROP COLUMN updated_at;
                CREATE INDEX idx_context_sources_health ON context_sources(health);
                ALTER TABLE context_atom_versions DROP COLUMN kind;
                ALTER TABLE context_atom_versions DROP COLUMN source_hash;
                ALTER TABLE context_atom_versions DROP COLUMN authority;
                ALTER TABLE context_atom_versions DROP COLUMN privacy;
                ALTER TABLE context_atom_versions DROP COLUMN injection_policy;
                ALTER TABLE context_atom_versions DROP COLUMN content_role;
                ALTER TABLE context_atom_versions DROP COLUMN expires_at;
                ALTER TABLE context_relationship_versions DROP COLUMN kind;
                ALTER TABLE context_relationship_versions DROP COLUMN weight;
                ALTER TABLE context_relationship_versions DROP COLUMN provenance;
                """)
        }
        migrator.registerMigration("context_drop_receipts_v5") { db in
            try db.execute(sql: "DROP TABLE context_receipts")
        }
        migrator.registerMigration("context_feedback_conversation_v6") { db in
            try db.execute(sql: """
                ALTER TABLE context_feedback_events ADD COLUMN session_id TEXT;
                ALTER TABLE context_feedback_events ADD COLUMN history_message_fingerprint TEXT;
                """)
        }
        return migrator
    }
}
