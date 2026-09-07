// Projects accepted MemoryV2 facts into a conservative local entity set in
// memory.sqlite kg_entities/kg_relationships. The `embedding_text` metadata
// field is part of the shared search/tool payload contract.

import CryptoKit
import Foundation
import GRDB
import PersistenceCore

public struct KnowledgeGraphMemoryFact: Sendable, Equatable {
    public var id: String
    public var content: String
    public var source: String?
    public var status: String
    public var createdAt: String
    public var updatedAt: String
    public var metadata: JSONValue?

    public init(
        id: String,
        content: String,
        source: String? = nil,
        status: String = "active",
        createdAt: String,
        updatedAt: String,
        metadata: JSONValue? = nil
    ) {
        self.id = id
        self.content = content
        self.source = source
        self.status = status
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.metadata = metadata
    }
}

public struct KnowledgeGraphExtractedEntity: Sendable, Equatable {
    public var name: String
    public var type: String
    public var summary: String

    public init(name: String, type: String, summary: String) {
        self.name = name
        self.type = type
        self.summary = summary
    }
}

public struct KnowledgeGraphMemoryRebuildReport: Sendable, Equatable {
    public let factsIndexed: Int
    public let entitiesRemoved: Int
    public let relationshipsRemoved: Int
    public let indexRowsRemoved: Int

    public init(
        factsIndexed: Int,
        entitiesRemoved: Int,
        relationshipsRemoved: Int,
        indexRowsRemoved: Int
    ) {
        self.factsIndexed = factsIndexed
        self.entitiesRemoved = entitiesRemoved
        self.relationshipsRemoved = relationshipsRemoved
        self.indexRowsRemoved = indexRowsRemoved
    }
}

public actor SwiftNativeKnowledgeGraphIndexer {
    private enum IndexingControl: Error {
        case requiresCanonicalRebuild
    }
    // v5, 2026-09-05: names come from the on-device name tagger, not from
    // capitalisation. Every row re-indexes on its next touch or a rebuild.
    static let indexVersion = "swift-memory-kg-v5"
    /// U5 W-C: stamped into metadata_json ON INSERT ONLY (never by touch
    /// updates) so GC can PROVE an entity was created by this indexer from a
    /// MemoryV2 memory. Entities lacking the stamp (daemon-era JSON imports,
    /// pre-stamp indexer rows) have unknowable source memories against the
    /// live schema and are never swept.
    static let createdByKey = "created_by_indexer"

    /// Internal (not private): the GC extension lives in KnowledgeGraph+GC.swift.
    let sqlitePath: URL
    /// Canonical onboarding identity source for the stable primary-user role
    /// node. It is reread once per indexing/rebuild/GC operation so onboarding
    /// and profile renames take effect without restarting, never once per fact.
    private let explicitPrimaryUserName: String?
    private let primaryUserProfileURL: URL
    /// The primary user's name, resolved once at init so the synchronous
    /// extractor inside the database closures can name them as a person.
    /// Internal, not private: GC (KnowledgeGraph+GC.swift) must extract with
    /// the SAME list the indexer wrote with, from this one resolver
    /// (2026-09-06 — see `collectGarbage`).
    nonisolated let knownPeople: [String]

    /// U5 W-C re-entry fix, layer 1: per-memory-id serialization. The actor is
    /// re-entrant at every await, and the call site
    /// (MemoryV2+SharedInstance.attachKnowledgeGraphHook) spawns an unordered
    /// Task per mutation — so two indexMemory calls for the SAME id could
    /// interleave across the old read-hash/write gap and double-count
    /// mentions. Each id gets a task chain: a new call awaits the previous
    /// call's completion before running. Lifecycle: `perIDPending` counts
    /// in-flight calls per id; when it drains to 0 both dictionary entries are
    /// removed (every add has a remove).
    private var perIDTails: [String: Task<Void, Never>] = [:]
    private var perIDPending: [String: Int] = [:]

    /// The pool now resolves lazily through the shared KnowledgeGraphPoolCache
    /// (one pool per path process-wide, invalidated on file replace). The
    /// schema-ensure runs at pool creation inside the cache. NOTE: unlike the
    /// pre-U5 eager open, an unopenable database throws at first USE, not at
    /// init — callers that `try?` the init and swallow per-call errors see the
    /// same net behavior, one open later.
    public init(memorySQLitePath: URL, primaryUserName: String? = nil) throws {
        try FileManager.default.createDirectory(
            at: memorySQLitePath.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        self.sqlitePath = memorySQLitePath
        self.explicitPrimaryUserName = primaryUserName
        self.primaryUserProfileURL = memorySQLitePath.deletingLastPathComponent()
            .appendingPathComponent("profile.json")
        let resolved = Self.resolvePrimaryUserName(
            explicit: primaryUserName,
            profileURL: self.primaryUserProfileURL
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        // The agent is a person in her own graph. Without her name here the
        // tagger filed "Agent" as a concept in one row and a person in the
        // next, and every rebuild kept both.
        let agent = Self.resolveAgentName(profileURL: self.primaryUserProfileURL)
        var people: [String] = []
        if !resolved.isEmpty, resolved.lowercased() != "the user" { people.append(resolved) }
        if let agent, !people.contains(where: { $0.lowercased() == agent.lowercased() }) {
            people.append(agent)
        }
        // The builder agents the app itself delegates to (see the bridge
        // lanes and `delegateName(forTool:)`): named peers, not places.
        for peer in Self.builtInPeerAgents where !people.contains(where: { $0.lowercased() == peer.lowercased() }) {
            people.append(peer)
        }
        self.knownPeople = people
    }

    private static let builtInPeerAgents = ["Claude", "Codex"]

    /// The configured agent name from the persona profile beside the store,
    /// nil when the profile is missing or the name is unusable.
    private static func resolveAgentName(profileURL: URL) -> String? {
        guard let data = try? Data(contentsOf: profileURL),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let raw = object["name"] as? String else { return nil }
        let trimmed = raw
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 80,
              !["assistant", "the assistant", "agent", "the agent"].contains(trimmed.lowercased()),
              trimmed.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) })
        else { return nil }
        return trimmed
    }

    /// Resolve the shared pool. The indexer never creates memory.sqlite:
    /// a bare DatabasePool open here minted a store with an EMPTY
    /// grdb_migrations ledger, and MemoryStorage's next init replayed its
    /// migrations against the existing kg tables and bricked the chain
    /// (stable-failure #4 / Desk 751.7). MemoryStorage owns creation; a
    /// missing file means there is nothing to index yet and the caller
    /// fails loud with `.databaseMissing`.
    func pool() async throws -> DatabasePool {
        try await KnowledgeGraphPoolCache.shared.pool(at: sqlitePath)
    }

    public func indexMemory(_ fact: KnowledgeGraphMemoryFact, deleted: Bool = false) async throws {
        let memoryID = fact.id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !memoryID.isEmpty else { return }

        // Enqueue onto this id's chain. The prologue (read tail, bump pending,
        // publish new tail) has NO suspension points, so it is atomic with
        // respect to the actor — concurrent callers serialize in arrival order.
        let predecessor = perIDTails[memoryID]
        perIDPending[memoryID, default: 0] += 1
        let work = Task<Result<Void, any Error>, Never> { [predecessor] in
            _ = await predecessor?.value
            let result: Result<Void, any Error>
            do {
                try await self.performIndex(fact, memoryID: memoryID, deleted: deleted)
                result = .success(())
            } catch {
                result = .failure(error)
            }
            self.finishChained(memoryID: memoryID)
            return result
        }
        perIDTails[memoryID] = Task { _ = await work.value }
        // `work` is non-throwing, so this await is not a cancellation point:
        // the chain entry ALWAYS completes and cleans up, even if our caller
        // is cancelled while waiting.
        if case .failure(let error) = await work.value { throw error }
    }

    /// Chain bookkeeping — runs on the actor after each chained call finishes.
    private func finishChained(memoryID: String) {
        let remaining = (perIDPending[memoryID] ?? 1) - 1
        if remaining <= 0 {
            perIDPending.removeValue(forKey: memoryID)
            perIDTails.removeValue(forKey: memoryID)
        } else {
            perIDPending[memoryID] = remaining
        }
    }

    private func performIndex(
        _ fact: KnowledgeGraphMemoryFact,
        memoryID: String,
        deleted: Bool
    ) async throws {
        let dbPool = try await pool()
        let primaryUserName = resolvedPrimaryUserName()
        do {
            try await dbPool.write { db in
                // Hook payloads are wake hints, not authority. In the production
                // database MemoryV2 and KG share this exact transaction domain,
                // so re-read the canonical row now. A delayed update task that
                // arrives after a delete can no longer resurrect stale entities.
                let hasMemoryTable = (try Int.fetchOne(db, sql: """
                    SELECT COUNT(*) FROM sqlite_master
                    WHERE type = 'table' AND name = 'memories'
                    """) ?? 0) > 0
                let canonicalFact: KnowledgeGraphMemoryFact?
                if deleted {
                    // 2026-09-06: the caller's `deleted` is authority in BOTH
                    // branches. It used to be read only when there was no
                    // memories table, so the production hook's "graph disabled
                    // — retire this node" (MemoryV2+SharedInstance) reread the
                    // live row and indexed it anyway: committing a memory with
                    // the Knowledge graph switch off still minted nodes and
                    // edges. Retire the node, never index.
                    canonicalFact = nil
                } else if hasMemoryTable {
                    let columns = Set(try Row.fetchAll(
                        db, sql: "PRAGMA table_info(memories)"
                    ).compactMap { row -> String? in row["name"] })
                    let requiredColumns: Set<String> = ["id", "content", "status"]
                    guard requiredColumns.isSubset(of: columns) else {
                        let missing = requiredColumns.subtracting(columns).sorted()
                        throw KnowledgeGraphReadError.storeUnreadable(
                            "memories table is missing required columns: \(missing.joined(separator: ", "))"
                        )
                    }
                    canonicalFact = try Row.fetchOne(
                        db,
                        sql: "SELECT * FROM memories WHERE id = ?",
                        arguments: [memoryID]
                    ).flatMap { row -> KnowledgeGraphMemoryFact? in
                            let content: String = row["content"] ?? ""
                            let status: String = row["status"] ?? ""
                            // v5 introduced lifecycle; supported older/minimal
                            // stores mean confirmed when the column is absent.
                            // If it is present, the canonical row remains the
                            // authority and corrected/contradicted/deleted facts
                            // stay excluded.
                            let lifecycle: String = columns.contains("lifecycle")
                                ? (row["lifecycle"] ?? "confirmed")
                                : "confirmed"
                            let recallExcludedLifecycle: Set<String> = [
                                "corrected", "contradicted", "deleted",
                            ]
                            guard status == "active",
                                  !recallExcludedLifecycle.contains(
                                    lifecycle.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                                  ),
                                  !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                                return nil
                            }
                            let metadata: JSONValue? = if columns.contains("metadata_json") {
                                (row["metadata_json"] as String?).flatMap {
                                    try? JSONValue.parse(Data($0.utf8))
                                }
                            } else {
                                fact.metadata
                            }
                            return KnowledgeGraphMemoryFact(
                                id: row["id"] ?? memoryID,
                                content: content,
                                source: columns.contains("source") ? row["source"] : fact.source,
                                status: status,
                                createdAt: columns.contains("created_at")
                                    ? (row["created_at"] ?? "") : fact.createdAt,
                                updatedAt: columns.contains("updated_at")
                                    ? (row["updated_at"] ?? "") : fact.updatedAt,
                                metadata: metadata
                            )
                        }
                } else if fact.status != "active"
                            || fact.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    canonicalFact = nil
                } else {
                    canonicalFact = fact
                }

                guard let canonicalFact else {
                    try Self.deleteMemoryFactEntity(db, memoryID: memoryID)
                    try db.execute(
                        sql: "DELETE FROM kg_memory_index WHERE memory_id = ?",
                        arguments: [memoryID]
                    )
                    return
                }

                let content = canonicalFact.content
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let contentHash = Self.contentHash("\(Self.indexVersion):\(content)")
                let now = Self.nowISO8601()
                let extracted = Self.extractEntities(from: content, knownPeople: knownPeople)

                // U5 W-C re-entry fix, layer 2: the hash check runs INSIDE the
                // same write transaction as the upserts. A changed hash cannot
                // be incrementally overlaid: that would retain entities/edges
                // extracted from the old claim. Escape the transaction and run
                // an exact canonical rebuild instead.
                let existingHash = try String.fetchOne(
                    db,
                    sql: "SELECT content_hash FROM kg_memory_index WHERE memory_id = ?",
                    arguments: [memoryID]
                )
                guard existingHash != contentHash else { return }
                if existingHash != nil { throw IndexingControl.requiresCanonicalRebuild }
                try Self.indexActiveFact(
                    db,
                    fact: canonicalFact,
                    memoryID: memoryID,
                    content: content,
                    contentHash: contentHash,
                    now: now,
                    extracted: extracted,
                    primaryUserName: primaryUserName
                )
            }
        } catch IndexingControl.requiresCanonicalRebuild {
            _ = try await rebuildMemoryDerivedGraphFromCanonicalStore()
        }
    }

    func resolvedPrimaryUserName() -> String {
        Self.resolvePrimaryUserName(
            explicit: explicitPrimaryUserName,
            profileURL: primaryUserProfileURL
        )
    }

    static func indexActiveFact(
        _ db: Database,
        fact: KnowledgeGraphMemoryFact,
        memoryID: String,
        content: String,
        contentHash: String,
        now: String,
        extracted: [KnowledgeGraphExtractedEntity],
        primaryUserName: String
    ) throws {
        let userID = try upsertPrimaryUserEntity(
            db,
            primaryUserName: primaryUserName,
            now: now,
            fact: fact
        )
        let factID = try upsertMemoryFactEntity(
            db,
            memoryID: memoryID,
            content: content,
            now: now,
            fact: fact
        )
        try upsertRelationship(
            db,
            fromID: userID,
            toID: factID,
            type: factRelationshipType(fact),
            now: now,
            fact: fact
        )

        if !extracted.isEmpty {
            var entityIDs: [String] = []
            entityIDs.reserveCapacity(extracted.count)
            for entity in extracted {
                let entityID = try upsertEntity(
                    db,
                    name: entity.name,
                    type: entity.type,
                    summary: entity.summary,
                    now: now,
                    fact: fact
                )
                if entityID != userID && entityID != factID {
                    entityIDs.append(entityID)
                }
            }

            for entityID in entityIDs {
                try upsertRelationship(
                    db,
                    fromID: userID,
                    toID: entityID,
                    type: "mentions",
                    now: now,
                    fact: fact
                )
                try upsertRelationship(
                    db,
                    fromID: factID,
                    toID: entityID,
                    type: "mentions",
                    now: now,
                    fact: fact
                )
            }
        }

        try db.execute(sql: """
            INSERT INTO kg_memory_index (memory_id, content_hash, indexed_at, index_version)
            VALUES (?, ?, ?, ?)
            ON CONFLICT(memory_id) DO UPDATE SET
              content_hash = excluded.content_hash,
              indexed_at = excluded.indexed_at,
              index_version = excluded.index_version
            """, arguments: [memoryID, contentHash, now, indexVersion])
    }

    /// One stable fact node per MemoryV2 row. Entity/edge extraction is still
    /// useful, but this node is the source-backed meaning unit Agent can search
    /// and then trace back to the exact memory row.
    private static func upsertMemoryFactEntity(
        _ db: Database,
        memoryID: String,
        content: String,
        now: String,
        fact: KnowledgeGraphMemoryFact
    ) throws -> String {
        let id = memoryFactEntityID(for: memoryID)
        let kind = metadataString(fact.metadata, "kind") ?? "fact"
        let compact = compactWhitespace(content)
        let title = "\(factTitleLabel(kind)): \(clip(compact, limit: 96))"
        let summary = "Memory fact: \(clip(compact, limit: 700))"
        var metadata: [String: JSONValue] = [
            "embedding_text": .string("\(kind): \(clip(compact, limit: 260))"),
            "memory_id": .string(memoryID),
            "last_memory_id": .string(memoryID),
            "indexer": .string(indexVersion),
            createdByKey: .string(indexVersion),
            "fact_kind": .string(kind),
        ]
        if let source = fact.source { metadata["last_memory_source"] = .string(source) }

        if try Row.fetchOne(db, sql: "SELECT id FROM kg_entities WHERE id = ?", arguments: [id]) != nil {
            try db.execute(sql: """
                UPDATE kg_entities SET
                  name = ?,
                  type = 'fact',
                  summary = ?,
                  mention_count = COALESCE(mention_count, 0) + 1,
                  last_seen = ?,
                  metadata_json = ?
                WHERE id = ?
                """, arguments: [title, summary, now, metadataJSON(metadata), id])
            return id
        }

        try db.execute(sql: """
            INSERT INTO kg_entities
              (id, name, type, summary, aliases_json, mention_count,
               first_seen, last_seen, provenance, metadata_json)
            VALUES (?, ?, 'fact', ?, ?, ?, ?, ?, ?, ?)
            """, arguments: [
                id, title, summary, "[]", 1, now, now,
                "memory-fact",
                metadataJSON(metadata),
            ])
        return id
    }

    private static func deleteMemoryFactEntity(_ db: Database, memoryID: String) throws {
        let id = memoryFactEntityID(for: memoryID)
        try db.execute(
            sql: "DELETE FROM kg_relationships WHERE from_id = ? OR to_id = ?",
            arguments: [id, id]
        )
        try db.execute(sql: "DELETE FROM kg_entities WHERE id = ?", arguments: [id])
    }

    /// Stable graph identity for the source-backed node derived from one
    /// canonical MemoryV2 row. The external memory id stays in node metadata;
    /// this opaque graph id prevents arbitrary user ids from becoming graph
    /// storage keys while allowing projections to prove they show that row.
    public nonisolated static func memoryFactEntityID(for memoryID: String) -> String {
        "memfact_" + String(contentHash(memoryID).prefix(16))
    }

    private static func factRelationshipType(_ fact: KnowledgeGraphMemoryFact) -> String {
        let kind = metadataString(fact.metadata, "kind")?.lowercased()
        switch kind {
        case "preference": return "prefers"
        case "identity", "user_fact", "attribute": return "describes"
        case "relationship": return "relationship"
        case "goal": return "wants"
        case "decision": return "decided"
        case "schedule": return "scheduled_for"
        case "project", "operational", "milestone": return "tracks"
        default:
            let lower = fact.content.lowercased()
            if lower.contains("prefer") || lower.contains("favorite") || lower.contains("favourite") {
                return "prefers"
            }
            if lower.contains("want") || lower.contains("need") {
                return "wants"
            }
            if lower.contains("decided") || lower.contains("decision") || lower.contains("should") {
                return "decided"
            }
            return "remembers"
        }
    }

    private static func factTitleLabel(_ kind: String) -> String {
        switch kind.lowercased() {
        case "preference": return "Preference"
        case "identity": return "Identity"
        case "relationship": return "Relationship"
        case "goal": return "Goal"
        case "decision": return "Decision"
        case "project": return "Project"
        case "operational": return "Operational"
        case "milestone": return "Milestone"
        case "schedule": return "Schedule"
        default: return "Fact"
        }
    }

    private static func metadataString(_ metadata: JSONValue?, _ key: String) -> String? {
        guard case .object(let obj)? = metadata,
              case .string(let value)? = obj[key] else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func compactWhitespace(_ text: String) -> String {
        text.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Idempotent kg_* schema completion for an EXISTING file. Internal so the
    /// shared KnowledgeGraphPoolCache can run it once per pool open.
    ///
    /// Ownership (stable-failure #4 / Desk 751.7, 2026-08-27): MemoryStorage's
    /// migrator is the schema owner for every store it creates
    /// (v2_knowledge_graph + v8_kg_memory_index), and the KnowledgeGraph side
    /// NEVER creates memory.sqlite itself — the pool cache throws
    /// `.databaseMissing` and the indexer's create-on-missing fallback is gone.
    /// That removal is what closed the brick path (a graph-first bare file had
    /// an empty grdb_migrations ledger, so MemoryStorage's next init replayed
    /// v2 against the existing tables and the whole chain failed). This
    /// IF NOT EXISTS completion remains for stores the migrator never owned:
    /// hand-built test fixtures and minimal/legacy stores, which the module
    /// deliberately tolerates for reads and hook-driven indexing.
    static func ensureSchema(_ pool: DatabasePool) throws {
        try pool.write { db in
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS kg_entities (
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
                CREATE INDEX IF NOT EXISTS idx_kg_entities_type ON kg_entities(type);
                CREATE INDEX IF NOT EXISTS idx_kg_entities_last_seen ON kg_entities(last_seen);

                CREATE TABLE IF NOT EXISTS kg_relationships (
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
                CREATE INDEX IF NOT EXISTS idx_kg_rel_from ON kg_relationships(from_id);
                CREATE INDEX IF NOT EXISTS idx_kg_rel_to ON kg_relationships(to_id);

                CREATE TABLE IF NOT EXISTS kg_memory_index (
                  memory_id TEXT PRIMARY KEY,
                  content_hash TEXT NOT NULL,
                  indexed_at TEXT NOT NULL,
                  index_version TEXT NOT NULL
                );
                """)
        }
    }

    static func upsertEntity(
        _ db: Database,
        name: String,
        type: String,
        summary: String,
        now: String,
        fact: KnowledgeGraphMemoryFact
    ) throws -> String {
        if let row = try Row.fetchOne(db, sql: """
            SELECT id, metadata_json FROM kg_entities
            WHERE lower(name) = lower(?) AND lower(type) = lower(?)
            ORDER BY mention_count DESC, last_seen DESC
            LIMIT 1
            """, arguments: [name, type]) {
            let id: String = row["id"]
            var metadata = metadataObject(row["metadata_json"])
            metadata["embedding_text"] = .string("\(type): \(name)")
            metadata["last_memory_id"] = .string(fact.id)
            if let source = fact.source { metadata["last_memory_source"] = .string(source) }
            metadata["indexer"] = .string(indexVersion)
            try db.execute(sql: """
                UPDATE kg_entities SET
                  mention_count = COALESCE(mention_count, 0) + 1,
                  last_seen = ?,
                  summary = ?,
                  metadata_json = ?
                WHERE id = ?
                """, arguments: [now, summary, metadataJSON(metadata), id])
            return id
        }

        let id = try uniqueEntityID(db)
        let metadata: [String: JSONValue] = [
            "embedding_text": .string("\(type): \(name)"),
            "last_memory_id": .string(fact.id),
            "last_memory_source": fact.source.map(JSONValue.string) ?? .null,
            "indexer": .string(indexVersion),
            // U5 W-C: creation provenance — INSERT-only, never re-stamped by
            // the touch/update path above. GC's orphan definition requires it.
            createdByKey: .string(indexVersion),
        ]
        try db.execute(sql: """
            INSERT INTO kg_entities
              (id, name, type, summary, aliases_json, mention_count,
               first_seen, last_seen, provenance, metadata_json)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """, arguments: [
                id, name, type, summary, "[]", 1, now, now,
                type == "concept" ? "default-concept" : nil,
                metadataJSON(metadata),
            ])
        return id
    }

    private static func upsertRelationship(
        _ db: Database,
        fromID: String,
        toID: String,
        type: String,
        now: String,
        fact: KnowledgeGraphMemoryFact
    ) throws {
        guard fromID != toID else { return }
        if let row = try Row.fetchOne(db, sql: """
            SELECT id, weight, metadata_json FROM kg_relationships
            WHERE from_id = ? AND to_id = ? AND type = ?
            LIMIT 1
            """, arguments: [fromID, toID, type]) {
            let id: Int64 = row["id"]
            let oldWeight: Double = row["weight"] ?? 0.5
            var metadata = metadataObject(row["metadata_json"])
            if metadata["first_seen"] == nil { metadata["first_seen"] = .string(now) }
            metadata["last_seen"] = .string(now)
            metadata["last_memory_id"] = .string(fact.id)
            metadata["indexer"] = .string(indexVersion)
            try db.execute(sql: """
                UPDATE kg_relationships SET
                  weight = ?,
                  mention_count = COALESCE(mention_count, 0) + 1,
                  provenance = COALESCE(provenance, ?),
                  metadata_json = ?
                WHERE id = ?
                """, arguments: [
                    min(1.0, oldWeight + 0.05),
                    type == "mentions" ? "default-mentions" : nil,
                    metadataJSON(metadata),
                    id,
                ])
            return
        }

        let metadata: [String: JSONValue] = [
            "first_seen": .string(now),
            "last_seen": .string(now),
            "last_memory_id": .string(fact.id),
            "indexer": .string(indexVersion),
        ]
        try db.execute(sql: """
            INSERT INTO kg_relationships
              (from_id, to_id, type, weight, mention_count, provenance, metadata_json)
            VALUES (?, ?, ?, ?, ?, ?, ?)
            """, arguments: [
                fromID, toID, type, 0.5, 1,
                type == "mentions" ? "default-mentions" : nil,
                metadataJSON(metadata),
            ])
    }

    static func uniqueEntityID(_ db: Database) throws -> String {
        while true {
            let id = String(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(8)).lowercased()
            let exists = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM kg_entities WHERE id = ?", arguments: [id]) ?? 0
            if exists == 0 { return id }
        }
    }

    static func metadataObject(_ raw: String?) -> [String: JSONValue] {
        guard let raw, let data = raw.data(using: .utf8),
              let parsed = try? JSONValue.parse(data),
              case .object(let obj) = parsed else {
            return [:]
        }
        return obj
    }

    static func metadataJSON(_ metadata: [String: JSONValue]) -> String? {
        guard !metadata.isEmpty,
              let data = try? JSONValue.object(metadata).serializedData(pretty: false) else {
            return nil
        }
        return String(decoding: data, as: UTF8.self)
    }

    static func contentHash(_ text: String) -> String {
        let digest = SHA256.hash(data: Data(text.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    static func nowISO8601() -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: Date())
    }

    static func clip(_ text: String, limit: Int) -> String {
        if text.count <= limit { return text }
        let idx = text.index(text.startIndex, offsetBy: limit)
        return String(text[..<idx]).trimmingCharacters(in: .whitespacesAndNewlines)
    }


}
