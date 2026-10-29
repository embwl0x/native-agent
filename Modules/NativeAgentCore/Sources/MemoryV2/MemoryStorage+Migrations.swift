import Foundation
import GRDB
// Blueprint: | `MemoryStorage+Migrations.swift` | `MemoryStorage.migrator`; registered GRDB schema migrations |

extension MemoryStorage {
    // MARK: - Migrator

    static var migrator: DatabaseMigrator {
        var m = DatabaseMigrator()
        m.registerMigration("v1_initial") { db in
            try db.execute(sql: """
                CREATE TABLE memories (
                  id TEXT PRIMARY KEY,
                  content TEXT NOT NULL,
                  persona_id TEXT NOT NULL DEFAULT 'NativeAgent',
                  source TEXT,
                  confidence REAL DEFAULT 1.0,
                  created_at TEXT NOT NULL,
                  updated_at TEXT NOT NULL,
                  embedding BLOB,
                  status TEXT NOT NULL DEFAULT 'active',
                  metadata_json TEXT
                );
                CREATE INDEX idx_memories_persona ON memories(persona_id, status);
                CREATE INDEX idx_memories_created ON memories(created_at);
                CREATE INDEX idx_memories_source ON memories(source);

                CREATE TABLE proposals (
                  id TEXT PRIMARY KEY,
                  content TEXT NOT NULL,
                  persona_id TEXT NOT NULL DEFAULT 'NativeAgent',
                  source TEXT,
                  staged_at TEXT NOT NULL,
                  status TEXT NOT NULL DEFAULT 'pending',
                  resolved_at TEXT,
                  rejection_reason TEXT,
                  embedding BLOB,
                  metadata_json TEXT
                );
                CREATE INDEX idx_proposals_status ON proposals(status, staged_at);

                CREATE TABLE tombstones (
                  content_hash TEXT PRIMARY KEY,
                  content TEXT NOT NULL,
                  rejected_at TEXT NOT NULL,
                  reason TEXT
                );
                CREATE INDEX idx_tombstones_rejected ON tombstones(rejected_at);
            """)
        }
        m.registerMigration("v2_knowledge_graph") { db in
            try db.execute(sql: """
                CREATE TABLE kg_entities (
                  id TEXT PRIMARY KEY,
                  name TEXT NOT NULL,
                  type TEXT NOT NULL DEFAULT 'concept',
                  summary TEXT,
                  aliases_json TEXT,
                  mention_count INTEGER DEFAULT 0,
                  first_seen TEXT,
                  last_seen TEXT,
                  provenance TEXT,
                  metadata_json TEXT
                );
                CREATE INDEX idx_kg_entities_type ON kg_entities(type);
                CREATE INDEX idx_kg_entities_last_seen ON kg_entities(last_seen);

                CREATE TABLE kg_relationships (
                  id INTEGER PRIMARY KEY AUTOINCREMENT,
                  from_id TEXT NOT NULL,
                  to_id TEXT NOT NULL,
                  type TEXT NOT NULL,
                  weight REAL,
                  mention_count INTEGER DEFAULT 0,
                  provenance TEXT,
                  metadata_json TEXT,
                  UNIQUE(from_id, to_id, type)
                );
                CREATE INDEX idx_kg_rel_from ON kg_relationships(from_id);
                CREATE INDEX idx_kg_rel_to ON kg_relationships(to_id);
            """)
        }
        // v3: recall counters default to 0/NULL; a real use_count column permits atomic increments.
        m.registerMigration("v3_recall_counters") { db in
            try db.execute(sql: """
                ALTER TABLE memories ADD COLUMN use_count INTEGER NOT NULL DEFAULT 0;
                ALTER TABLE memories ADD COLUMN last_used_at TEXT;
                CREATE INDEX idx_memories_last_used ON memories(last_used_at);
            """)
        }
        // v4: tombstone embeddings block paraphrases; NULL preserves exact-hash-only matching.
        m.registerMigration("v4_tombstone_embeddings") { db in
            try db.execute(sql: "ALTER TABLE tombstones ADD COLUMN embedding BLOB;")
        }
        // v5: status tracks storage state; lifecycle tracks fact quality and defaults existing rows to confirmed.
        m.registerMigration("v5_memory_lifecycle") { db in
            try db.execute(sql: """
                ALTER TABLE memories ADD COLUMN lifecycle TEXT NOT NULL DEFAULT 'confirmed';
                CREATE INDEX idx_memories_lifecycle ON memories(lifecycle);
            """)
        }
        // v6: vector identity remains unverified until atomic full-corpus activation; migration never guesses provenance.
        m.registerMigration("v6_embedding_epochs") { db in
            try db.execute(sql: """
                ALTER TABLE memories ADD COLUMN embedding_epoch TEXT;
                ALTER TABLE proposals ADD COLUMN embedding_epoch TEXT;
                ALTER TABLE tombstones ADD COLUMN embedding_epoch TEXT;
                CREATE INDEX idx_memories_embedding_epoch ON memories(embedding_epoch);
                CREATE INDEX idx_proposals_embedding_epoch ON proposals(embedding_epoch);
                CREATE INDEX idx_tombstones_embedding_epoch ON tombstones(embedding_epoch);

                CREATE TABLE memory_embedding_state (
                  id INTEGER PRIMARY KEY CHECK (id = 1),
                  active_epoch TEXT,
                  previous_epoch TEXT,
                  activated_at TEXT,
                  rollback_available INTEGER NOT NULL DEFAULT 0
                );
                INSERT INTO memory_embedding_state (id) VALUES (1);

                CREATE TABLE memory_embedding_previous (
                  kind TEXT NOT NULL,
                  row_id TEXT NOT NULL,
                  content_hash TEXT NOT NULL,
                  embedding BLOB,
                  embedding_epoch TEXT,
                  PRIMARY KEY (kind, row_id)
                );
            """)
        }
        // v7: nullable temporal validity and evidence lineage. Additive only;
        // no historical row is assigned invented dates or evidence.
        m.registerMigration("v7_temporal_evidence") { db in
            try db.execute(sql: """
                ALTER TABLE memories ADD COLUMN valid_from TEXT;
                ALTER TABLE memories ADD COLUMN valid_to TEXT;
                ALTER TABLE memories ADD COLUMN observed_at TEXT;
                ALTER TABLE memories ADD COLUMN evidence_json TEXT;
                CREATE INDEX idx_memories_valid_from ON memories(valid_from);
                CREATE INDEX idx_memories_valid_to ON memories(valid_to);
                CREATE INDEX idx_memories_observed_at ON memories(observed_at);
            """)
        }
        // v8: migrations own every kg_* table; IF NOT EXISTS adopts existing kg_memory_index tables.
        // KnowledgeGraph verifies schema without creating tables.
        m.registerMigration("v8_kg_memory_index") { db in
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS kg_memory_index (
                  memory_id TEXT PRIMARY KEY,
                  content_hash TEXT NOT NULL,
                  indexed_at TEXT NOT NULL,
                  index_version TEXT NOT NULL
                );
            """)
        }
        // The embedding rollback lane had no caller; its retained-vector copy
        // table is dropped rather than kept filling on every activation.
        m.registerMigration("v9_drop_embedding_previous") { db in
            try db.execute(sql: "DROP TABLE IF EXISTS memory_embedding_previous")
        }
        // Preserve the retired consolidation schema in migration history.
        m.registerMigration("v10_consolidation_applied") { db in
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS consolidation_applied (
                  run_id TEXT PRIMARY KEY,
                  applied_at TEXT NOT NULL
                )
            """)
        }
        // Keep the first core choice after every pinned row is unpinned or
        // deleted. Triggers cover every writer in the pin's own transaction.
        m.registerMigration("v11_user_core_chosen") { db in
            try db.execute(sql: """
                CREATE TABLE memory_metadata (
                  key TEXT NOT NULL PRIMARY KEY,
                  value INTEGER NOT NULL
                );
                INSERT INTO memory_metadata (key, value)
                SELECT 'user_core_chosen', 1 WHERE EXISTS (
                  SELECT 1 FROM memories
                  WHERE json_extract(metadata_json, '$.pinned') = 1
                     OR json_extract(metadata_json, '$.pinned_order') IS NOT NULL
                );
                CREATE TRIGGER memory_user_core_chosen_insert
                AFTER INSERT ON memories
                WHEN json_extract(NEW.metadata_json, '$.pinned') = 1
                BEGIN
                  INSERT OR IGNORE INTO memory_metadata (key, value)
                  VALUES ('user_core_chosen', 1);
                END;
                CREATE TRIGGER memory_user_core_chosen_update
                AFTER UPDATE OF metadata_json ON memories
                WHEN json_extract(NEW.metadata_json, '$.pinned') = 1
                BEGIN
                  INSERT OR IGNORE INTO memory_metadata (key, value)
                  VALUES ('user_core_chosen', 1);
                END;
            """)
        }
        m.registerMigration("v12_sense_memory_provenance") { db in
            try db.execute(sql: """
                CREATE TABLE memory_wrong_sense_versions (
                  sense_id TEXT NOT NULL,
                  version INTEGER NOT NULL,
                  PRIMARY KEY (sense_id, version)
                );
                CREATE TRIGGER memory_sense_wrong_insert AFTER INSERT ON memories
                WHEN EXISTS (
                  SELECT 1 FROM json_each(NEW.metadata_json, '$.sense_versions') ref
                  JOIN memory_wrong_sense_versions wrong
                    ON wrong.sense_id = json_extract(ref.value, '$.sense_id')
                   AND wrong.version = json_extract(ref.value, '$.version')
                )
                BEGIN
                  UPDATE memories SET metadata_json = json_set(metadata_json, '$.sense_version_later_wrong', json('true')) WHERE id = NEW.id;
                END;
                CREATE TRIGGER memory_sense_wrong_update AFTER UPDATE OF metadata_json ON memories
                WHEN COALESCE(json_extract(NEW.metadata_json, '$.sense_version_later_wrong'), 0) != 1
                  AND EXISTS (
                    SELECT 1 FROM json_each(NEW.metadata_json, '$.sense_versions') ref
                    JOIN memory_wrong_sense_versions wrong
                      ON wrong.sense_id = json_extract(ref.value, '$.sense_id')
                     AND wrong.version = json_extract(ref.value, '$.version')
                  )
                BEGIN
                  UPDATE memories SET metadata_json = json_set(metadata_json, '$.sense_version_later_wrong', json('true')) WHERE id = NEW.id;
                END;
                """)
        }
        // Contact sessions use agent-; standing helpers use bot-. Repair the
        // old user-seat label from that canonical source, never from acceptance.
        m.registerMigration("v13_peer_moment_origin") { db in
            for table in ["memories", "proposals"] {
                try db.execute(sql: """
                    UPDATE \(table)
                    SET metadata_json = json_set(metadata_json, '$.author', 'peer')
                    WHERE json_valid(metadata_json)
                      AND json_extract(metadata_json, '$.author') = 'user'
                      AND (json_extract(metadata_json, '$.lane') = 'moment'
                           OR json_extract(metadata_json, '$.kind') = 'moment')
                      AND (source GLOB 'moment-promoter:agent-?*'
                           OR source GLOB 'moment-promoter:bot-?*');
                    """)
            }
        }
        // Relevance judgments belong to one canonical corpus. Access counters
        // do not change its meaning; every other memory mutation advances it.
        m.registerMigration("v14_recall_judgment_generation") { db in
            try db.execute(sql: """
                INSERT INTO memory_metadata (key, value) VALUES ('recall_generation', 0);
                CREATE TRIGGER memory_recall_generation_insert AFTER INSERT ON memories
                BEGIN
                  UPDATE memory_metadata SET value = value + 1 WHERE key = 'recall_generation';
                END;
                CREATE TRIGGER memory_recall_generation_delete AFTER DELETE ON memories
                BEGIN
                  UPDATE memory_metadata SET value = value + 1 WHERE key = 'recall_generation';
                END;
                CREATE TRIGGER memory_recall_generation_update
                AFTER UPDATE OF id, content, persona_id, source, confidence, created_at, updated_at,
                  embedding, embedding_epoch, status, metadata_json, lifecycle,
                  valid_from, valid_to, observed_at, evidence_json ON memories
                BEGIN
                  UPDATE memory_metadata SET value = value + 1 WHERE key = 'recall_generation';
                END;
                """)
        }
        // Repair rows imported after v13, including interrupted older imports.
        // New imports normalize at their persistence boundary after this runs.
        m.registerMigration("v15_imported_peer_moment_origin") { db in
            for table in ["memories", "proposals"] {
                try db.execute(sql: """
                    UPDATE \(table)
                    SET metadata_json = json_set(metadata_json, '$.author', 'peer')
                    WHERE json_valid(metadata_json)
                      AND json_extract(metadata_json, '$.author') = 'user'
                      AND (json_extract(metadata_json, '$.lane') = 'moment'
                           OR json_extract(metadata_json, '$.kind') = 'moment')
                      AND (source GLOB 'moment-promoter:agent-?*'
                           OR source GLOB 'moment-promoter:bot-?*');
                    """)
            }
        }
        m.registerMigration("v16_action_embeddings") { db in
            try db.execute(sql: """
                CREATE TABLE action_embeddings (
                  epoch TEXT NOT NULL,
                  text_hash TEXT NOT NULL,
                  vector BLOB NOT NULL,
                  PRIMARY KEY (epoch, text_hash)
                );
                """)
        }
        return m
    }

}
