// Swift-native Knowledge Graph writer for MemoryV2 facts.
//
// The retired daemon grew the KG by running entity extraction after turns, then
// calling KnowledgeGraph.merge_entity/add_edge. This writer keeps that ownership
// in Swift: accepted memories are reduced to a conservative local entity set and
// written into memory.sqlite kg_entities/kg_relationships. It preserves the old
// `embedding_text` convention in metadata_json so search/tool payloads expose the
// same field shape the migrated daemon graph already has.

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
    private static let indexVersion = "swift-memory-kg-v4"
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
    }

    /// Resolve the shared pool, creating the database file on first use (the
    /// indexer is a WRITER, so unlike the read path it may create the file —
    /// matching the pre-U5 eager-open behavior).
    private func pool() async throws -> DatabasePool {
        do {
            return try await KnowledgeGraphPoolCache.shared.pool(at: sqlitePath)
        } catch KnowledgeGraphPoolCache.PoolError.databaseMissing {
            // First write against a fresh path: create the file, then cache it.
            var config = Configuration()
            config.foreignKeysEnabled = true
            config.busyMode = .timeout(2)
            _ = try DatabasePool(path: sqlitePath.path, configuration: config)
            return try await KnowledgeGraphPoolCache.shared.pool(at: sqlitePath)
        }
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
        if deleted {
            try await dbPool.write { db in
                try Self.deleteMemoryFactEntity(db, memoryID: memoryID)
                try db.execute(sql: "DELETE FROM kg_memory_index WHERE memory_id = ?", arguments: [memoryID])
            }
            return
        }

        let content = fact.content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard fact.status == "active", !content.isEmpty else { return }

        let contentHash = Self.contentHash("\(Self.indexVersion):\(content)")
        let now = Self.nowISO8601()
        let extracted = Self.extractEntities(from: content)
        let primaryUserName = resolvedPrimaryUserName()
        do {
            try await dbPool.write { db in
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
                    fact: fact,
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

    /// Rebuild every MemoryV2-owned KG row from the canonical `memories` table
    /// in one database write transaction. This is the convergence boundary for
    /// approved consolidation swaps: it removes additive claims from changed
    /// facts, preserves legacy/manual entities without the indexer provenance
    /// stamp, and snapshots canonical rows under the same SQLite write lock so
    /// a concurrent memory mutation lands either before the rebuild snapshot or
    /// afterward through its ordinary indexing hook — never in a lost window.
    public func rebuildMemoryDerivedGraphFromCanonicalStore() async throws -> KnowledgeGraphMemoryRebuildReport {
        let dbPool = try await pool()
        let primaryUserName = resolvedPrimaryUserName()
        return try await dbPool.write { db in
            let memoryTableExists = (try Int.fetchOne(
                db,
                sql: """
                    SELECT COUNT(*) FROM sqlite_master
                    WHERE type = 'table' AND name = 'memories'
                    """
            ) ?? 0) > 0
            guard memoryTableExists else {
                return KnowledgeGraphMemoryRebuildReport(
                    factsIndexed: 0,
                    entitiesRemoved: 0,
                    relationshipsRemoved: 0,
                    indexRowsRemoved: 0
                )
            }

            let rows = try Row.fetchAll(db, sql: """
                SELECT id, content, source, status, created_at, updated_at,
                       metadata_json
                FROM memories
                WHERE status = 'active'
                  AND TRIM(COALESCE(content, '')) <> ''
                  AND lower(COALESCE(NULLIF(TRIM(lifecycle), ''), 'confirmed'))
                        NOT IN ('corrected', 'contradicted', 'deleted')
                  AND id NOT LIKE 'skill-pointer:%'
                ORDER BY id ASC
                """)
            let facts: [KnowledgeGraphMemoryFact] = rows.compactMap { row in
                guard let id: String = row["id"],
                      let content: String = row["content"] else { return nil }
                let metadataRaw: String? = row["metadata_json"]
                let metadata = metadataRaw
                    .flatMap { try? JSONValue.parse(Data($0.utf8)) }
                return KnowledgeGraphMemoryFact(
                    id: id,
                    content: content,
                    source: row["source"],
                    status: row["status"] ?? "active",
                    createdAt: row["created_at"] ?? "",
                    updatedAt: row["updated_at"] ?? "",
                    metadata: metadata
                )
            }

            let ownedIndexerPlaceholders = Self.ownedIndexerVersions
                .map { _ in "?" }
                .joined(separator: ", ")
            let provenanceSubquery = """
                SELECT id FROM kg_entities
                WHERE json_extract(metadata_json, '$.\(Self.createdByKey)')
                      IN (\(ownedIndexerPlaceholders))
                """
            try db.execute(
                sql: """
                    DELETE FROM kg_relationships
                    WHERE from_id IN (\(provenanceSubquery))
                       OR to_id IN (\(provenanceSubquery))
                       OR json_extract(metadata_json, '$.indexer')
                          IN (\(ownedIndexerPlaceholders))
                    """,
                arguments: StatementArguments(
                    Self.ownedIndexerVersions
                        + Self.ownedIndexerVersions
                        + Self.ownedIndexerVersions
                )
            )
            let ownedRelationshipsRemoved = db.changesCount
            try db.execute(
                sql: """
                    DELETE FROM kg_entities
                    WHERE json_extract(metadata_json, '$.\(Self.createdByKey)')
                          IN (\(ownedIndexerPlaceholders))
                    """,
                arguments: StatementArguments(Self.ownedIndexerVersions)
            )
            let ownedEntitiesRemoved = db.changesCount
            try db.execute(sql: "DELETE FROM kg_memory_index")
            let indexRowsRemoved = db.changesCount

            let now = Self.nowISO8601()
            let consolidation = if facts.isEmpty {
                try Self.removeUnreferencedPrimaryUserRole(db)
            } else {
                try Self.consolidatePrimaryUserEntities(
                    db,
                    primaryUserName: primaryUserName
                )
            }
            for fact in facts {
                let memoryID = fact.id.trimmingCharacters(in: .whitespacesAndNewlines)
                let content = fact.content.trimmingCharacters(in: .whitespacesAndNewlines)
                let contentHash = Self.contentHash("\(Self.indexVersion):\(content)")
                try Self.indexActiveFact(
                    db,
                    fact: fact,
                    memoryID: memoryID,
                    content: content,
                    contentHash: contentHash,
                    now: now,
                    extracted: Self.extractEntities(from: content),
                    primaryUserName: primaryUserName
                )
            }
            return KnowledgeGraphMemoryRebuildReport(
                factsIndexed: facts.count,
                entitiesRemoved: ownedEntitiesRemoved + consolidation.entitiesRemoved,
                relationshipsRemoved: ownedRelationshipsRemoved + consolidation.relationshipsRemoved,
                indexRowsRemoved: indexRowsRemoved
            )
        }
    }

    func resolvedPrimaryUserName() -> String {
        Self.resolvePrimaryUserName(
            explicit: explicitPrimaryUserName,
            profileURL: primaryUserProfileURL
        )
    }

    private static func indexActiveFact(
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

    public nonisolated static func extractEntities(from content: String) -> [KnowledgeGraphExtractedEntity] {
        let summary = "Mentioned in memory: \(clip(content, limit: 220))"
        var ordered: [KnowledgeGraphExtractedEntity] = []
        var seen: Set<String> = []

        func add(_ rawName: String, forcedType: String? = nil) {
            guard let name = cleanEntityName(canonicalFileEntityName(rawName)) else { return }
            let type = forcedType ?? inferType(name)
            let key = "\(type)|\(name.lowercased())"
            guard !seen.contains(key) else { return }
            seen.insert(key)
            ordered.append(KnowledgeGraphExtractedEntity(name: name, type: type, summary: summary))
        }

        for term in knownTerms {
            // 2026-07-21 audit: the bare caseInsensitive substring match had
            // no word boundary, so "Apple" matched "pineapple" (and any
            // other word containing a known term). Match on word boundaries
            // instead. (Diacritic-insensitivity is dropped with the move to
            // NSRegularExpression — no known term carries diacritics.)
            if knownTermMentioned(term.name, in: content) {
                add(term.name, forcedType: term.type)
            }
        }

        for match in regexCaptures(#"`([^`]{2,80})`"#, in: content) {
            add(match)
        }
        for match in regexMatches(#"\b[A-Za-z0-9_./-]+\.(?:app|md|json|swift|sqlite|mlpackage|mlmodelc)\b"#, in: content) {
            add(match)
        }
        for match in regexMatches(#"\b[A-Z]{2,8}\b"#, in: content) {
            guard shouldPromoteGenericCandidate(match, in: content) else { continue }
            add(match)
        }
        for match in regexMatches(#"\b[A-Z][A-Za-z0-9_+\-/]*(?:\s+[A-Z][A-Za-z0-9_+\-/]*){0,3}\b"#, in: content) {
            guard shouldPromoteGenericCandidate(match, in: content) else { continue }
            add(match)
        }

        return Array(ordered.prefix(24))
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
        let id = memoryFactEntityID(memoryID)
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
        let id = memoryFactEntityID(memoryID)
        try db.execute(
            sql: "DELETE FROM kg_relationships WHERE from_id = ? OR to_id = ?",
            arguments: [id, id]
        )
        try db.execute(sql: "DELETE FROM kg_entities WHERE id = ?", arguments: [id])
    }

    private static func memoryFactEntityID(_ memoryID: String) -> String {
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

    /// Idempotent kg_* schema. Internal (was private) so the shared
    /// KnowledgeGraphPoolCache can run it once per pool creation.
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

    private struct PrimaryUserConsolidation {
        var entitiesRemoved: Int = 0
        var relationshipsRemoved: Int = 0
    }

    /// Resolve the user identity only from onboarding's canonical profile.
    /// Generic or unavailable values retain the role label rather than
    /// guessing a person's name from accepted-memory prose.
    private static func resolvePrimaryUserName(explicit: String?, profileURL: URL) -> String {
        let raw: String? = {
            if let explicit { return explicit }
            guard let data = try? Data(contentsOf: profileURL),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return nil
            }
            return object["userName"] as? String
        }()
        guard let raw else { return "the user" }
        let trimmed = raw
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              trimmed.count <= 80,
              !["user", "the user"].contains(trimmed.lowercased()),
              trimmed.unicodeScalars.allSatisfy({
                  !CharacterSet.controlCharacters.contains($0)
              }) else {
            return "the user"
        }
        return trimmed
    }

    private static func primaryUserAliases(
        name: String,
        existingRows: [Row] = []
    ) -> [String] {
        var aliases: [String] = ["the user", "User"]
        for row in existingRows {
            if let existingName: String = row["name"] {
                aliases.append(existingName)
            }
            let raw: String? = row["aliases_json"]
            guard let raw,
                  let data = raw.data(using: .utf8),
                  let decoded = try? JSONDecoder().decode([String].self, from: data) else {
                continue
            }
            aliases.append(contentsOf: decoded)
        }
        var seen: Set<String> = []
        return aliases.compactMap { raw in
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty,
                  trimmed.caseInsensitiveCompare(name) != .orderedSame else {
                return nil
            }
            let key = trimmed.lowercased()
            guard seen.insert(key).inserted else { return nil }
            return trimmed
        }
    }

    /// Merge only identities proven to denote the configured primary-user
    /// role: exact generic person labels, the exact configured person name,
    /// and a derived concept bearing that exact configured name. Arbitrary
    /// manual people and concepts remain untouched.
    private static func consolidatePrimaryUserEntities(
        _ db: Database,
        primaryUserName: String
    ) throws -> PrimaryUserConsolidation {
        let configuredLower = primaryUserName.lowercased()
        let rows = try Row.fetchAll(db, sql: """
            SELECT id, name, type, summary, aliases_json, mention_count,
                   first_seen, last_seen, provenance, metadata_json
            FROM kg_entities
            WHERE (
                lower(type) = 'person'
                AND (
                    lower(name) IN ('user', 'the user', ?)
                    OR json_extract(metadata_json, '$.role') = 'primary_user'
                )
            ) OR (
                lower(type) = 'concept'
                AND lower(name) = ?
                AND json_extract(metadata_json, '$.indexer') LIKE 'swift-memory-kg-%'
            )
            ORDER BY mention_count DESC, last_seen DESC
            """, arguments: [configuredLower, configuredLower])
        guard !rows.isEmpty else { return PrimaryUserConsolidation() }

        func role(_ row: Row) -> String? {
            let raw: String? = row["metadata_json"]
            guard case .string(let value)? = metadataObject(raw)["role"] else {
                return nil
            }
            return value
        }
        func name(_ row: Row) -> String {
            let value: String? = row["name"]
            return value ?? ""
        }
        func type(_ row: Row) -> String {
            let value: String? = row["type"]
            return value ?? ""
        }

        let canonical = rows.first(where: { role($0) == "primary_user" })
            ?? rows.first(where: {
                type($0).lowercased() == "person"
                    && name($0).caseInsensitiveCompare(primaryUserName) == .orderedSame
            })
            ?? rows.first(where: { name($0).lowercased() == "the user" })
            ?? rows[0]
        let canonicalID: String = canonical["id"]
        var report = PrimaryUserConsolidation()

        for row in rows {
            let duplicateID: String = row["id"]
            guard duplicateID != canonicalID else { continue }
            let relationships = try Row.fetchAll(db, sql: """
                SELECT id, from_id, to_id, type, weight, mention_count,
                       provenance, metadata_json
                FROM kg_relationships
                WHERE from_id = ? OR to_id = ?
                """, arguments: [duplicateID, duplicateID])
            for relationship in relationships {
                let relationshipID: Int64 = relationship["id"]
                let oldFrom: String = relationship["from_id"]
                let oldTo: String = relationship["to_id"]
                let newFrom = oldFrom == duplicateID ? canonicalID : oldFrom
                let newTo = oldTo == duplicateID ? canonicalID : oldTo
                if newFrom != newTo {
                    let relationshipType: String = relationship["type"]
                    let weight: Double? = relationship["weight"]
                    let mentionCount: Int = relationship["mention_count"] ?? 0
                    let provenance: String? = relationship["provenance"]
                    let metadataJSON: String? = relationship["metadata_json"]
                    try db.execute(sql: """
                        INSERT INTO kg_relationships
                          (from_id, to_id, type, weight, mention_count, provenance, metadata_json)
                        VALUES (?, ?, ?, ?, ?, ?, ?)
                        ON CONFLICT(from_id, to_id, type) DO UPDATE SET
                          weight = MAX(
                            COALESCE(kg_relationships.weight, 0),
                            COALESCE(excluded.weight, 0)
                          ),
                          mention_count = COALESCE(kg_relationships.mention_count, 0)
                            + COALESCE(excluded.mention_count, 0),
                          provenance = COALESCE(
                            kg_relationships.provenance,
                            excluded.provenance
                          ),
                          metadata_json = COALESCE(
                            kg_relationships.metadata_json,
                            excluded.metadata_json
                          )
                        """, arguments: [
                            newFrom, newTo, relationshipType, weight, mentionCount,
                            provenance, metadataJSON,
                        ])
                }
                try db.execute(
                    sql: "DELETE FROM kg_relationships WHERE id = ?",
                    arguments: [relationshipID]
                )
                report.relationshipsRemoved += db.changesCount
            }
            try db.execute(
                sql: "DELETE FROM kg_entities WHERE id = ?",
                arguments: [duplicateID]
            )
            report.entitiesRemoved += db.changesCount
        }

        var metadata = metadataObject(canonical["metadata_json"])
        metadata["role"] = .string("primary_user")
        metadata["embedding_text"] = .string("person: \(primaryUserName)")
        metadata["indexer"] = .string(indexVersion)
        let aliases = primaryUserAliases(name: primaryUserName, existingRows: rows)
        let aliasData = try JSONEncoder().encode(aliases)
        let aliasJSON = String(decoding: aliasData, as: UTF8.self)
        try db.execute(sql: """
            UPDATE kg_entities SET
              name = ?,
              type = 'person',
              summary = ?,
              aliases_json = ?,
              mention_count = 0,
              metadata_json = ?
            WHERE id = ?
            """, arguments: [
                primaryUserName,
                "NativeAgent's primary user.",
                aliasJSON,
                metadataJSON(metadata),
                canonicalID,
            ])
        return report
    }

    private static func removeUnreferencedPrimaryUserRole(
        _ db: Database
    ) throws -> PrimaryUserConsolidation {
        let roleIDs = try String.fetchAll(db, sql: """
            SELECT id FROM kg_entities
            WHERE json_extract(metadata_json, '$.role') = 'primary_user'
              AND NOT EXISTS (
                SELECT 1 FROM kg_relationships
                WHERE from_id = kg_entities.id OR to_id = kg_entities.id
              )
            """)
        guard !roleIDs.isEmpty else { return PrimaryUserConsolidation() }
        let placeholders = roleIDs.map { _ in "?" }.joined(separator: ", ")
        try db.execute(
            sql: "DELETE FROM kg_entities WHERE id IN (\(placeholders))",
            arguments: StatementArguments(roleIDs)
        )
        return PrimaryUserConsolidation(entitiesRemoved: db.changesCount)
    }

    private static func upsertPrimaryUserEntity(
        _ db: Database,
        primaryUserName: String,
        now: String,
        fact: KnowledgeGraphMemoryFact
    ) throws -> String {
        if let row = try Row.fetchOne(db, sql: """
            SELECT id, aliases_json, metadata_json
            FROM kg_entities
            WHERE lower(type) = 'person'
              AND (
                json_extract(metadata_json, '$.role') = 'primary_user'
                OR lower(name) IN (lower(?), 'user', 'the user')
              )
            ORDER BY
              CASE WHEN json_extract(metadata_json, '$.role') = 'primary_user'
                   THEN 0 ELSE 1 END,
              mention_count DESC
            LIMIT 1
            """, arguments: [primaryUserName]) {
            let id: String = row["id"]
            var metadata = metadataObject(row["metadata_json"])
            metadata["role"] = .string("primary_user")
            metadata["embedding_text"] = .string("person: \(primaryUserName)")
            metadata["last_memory_id"] = .string(fact.id)
            if let source = fact.source { metadata["last_memory_source"] = .string(source) }
            metadata["indexer"] = .string(indexVersion)
            let aliases = primaryUserAliases(name: primaryUserName, existingRows: [row])
            let aliasData = try JSONEncoder().encode(aliases)
            try db.execute(sql: """
                UPDATE kg_entities SET
                  name = ?,
                  type = 'person',
                  summary = ?,
                  aliases_json = ?,
                  mention_count = COALESCE(mention_count, 0) + 1,
                  last_seen = ?,
                  metadata_json = ?
                WHERE id = ?
                """, arguments: [
                    primaryUserName,
                    "NativeAgent's primary user.",
                    String(decoding: aliasData, as: UTF8.self),
                    now,
                    metadataJSON(metadata),
                    id,
                ])
            return id
        }

        let id = try uniqueEntityID(db)
        let aliases = primaryUserAliases(name: primaryUserName)
        let aliasData = try JSONEncoder().encode(aliases)
        let metadata: [String: JSONValue] = [
            "role": .string("primary_user"),
            "embedding_text": .string("person: \(primaryUserName)"),
            "last_memory_id": .string(fact.id),
            "last_memory_source": fact.source.map(JSONValue.string) ?? .null,
            "indexer": .string(indexVersion),
        ]
        try db.execute(sql: """
            INSERT INTO kg_entities
              (id, name, type, summary, aliases_json, mention_count,
               first_seen, last_seen, provenance, metadata_json)
            VALUES (?, ?, 'person', ?, ?, 1, ?, ?, NULL, ?)
            """, arguments: [
                id,
                primaryUserName,
                "NativeAgent's primary user.",
                String(decoding: aliasData, as: UTF8.self),
                now,
                now,
                metadataJSON(metadata),
            ])
        return id
    }

    private static func upsertEntity(
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

    private static func uniqueEntityID(_ db: Database) throws -> String {
        while true {
            let id = String(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(8)).lowercased()
            let exists = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM kg_entities WHERE id = ?", arguments: [id]) ?? 0
            if exists == 0 { return id }
        }
    }

    private static func metadataObject(_ raw: String?) -> [String: JSONValue] {
        guard let raw, let data = raw.data(using: .utf8),
              let parsed = try? JSONValue.parse(data),
              case .object(let obj) = parsed else {
            return [:]
        }
        return obj
    }

    private static func metadataJSON(_ metadata: [String: JSONValue]) -> String? {
        guard !metadata.isEmpty,
              let data = try? JSONValue.object(metadata).serializedData(pretty: false) else {
            return nil
        }
        return String(decoding: data, as: UTF8.self)
    }

    private static func contentHash(_ text: String) -> String {
        let digest = SHA256.hash(data: Data(text.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private static func nowISO8601() -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: Date())
    }

    private static func regexMatches(_ pattern: String, in text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.matches(in: text, range: range).compactMap { match in
            guard let r = Range(match.range(at: 0), in: text) else { return nil }
            return String(text[r])
        }
    }

    /// Whole-word, case-insensitive mention check for `knownTerms`. Word
    /// boundaries keep "Apple" from firing inside "pineapple" while still
    /// matching "Apple's" / "(Apple)". All known terms start and end with a
    /// word character, so `\b…\b` is the correct frame.
    private static func knownTermMentioned(_ term: String, in content: String) -> Bool {
        let pattern = "\\b" + NSRegularExpression.escapedPattern(for: term) + "\\b"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return false
        }
        let range = NSRange(content.startIndex..<content.endIndex, in: content)
        return regex.firstMatch(in: content, range: range) != nil
    }

    private static func regexCaptures(_ pattern: String, in text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.matches(in: text, range: range).compactMap { match in
            guard match.numberOfRanges > 1,
                  let r = Range(match.range(at: 1), in: text) else {
                return nil
            }
            return String(text[r])
        }
    }

    private static func cleanEntityName(_ raw: String) -> String? {
        let collapsed = raw
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: ".,;:!?()[]{}\"'"))
        guard !collapsed.isEmpty, collapsed.count <= 80 else { return nil }
        let lower = collapsed.lowercased()
        guard !entityStopwords.contains(lower) else { return nil }
        guard collapsed.rangeOfCharacter(from: .letters) != nil else { return nil }
        let wordCount = collapsed.split(separator: " ").count
        guard wordCount <= 4 else { return nil }
        return collapsed
    }

    /// Persona-document paths and their bare filenames are one entity. Keep
    /// this deliberately narrow: collapsing arbitrary same-basename paths
    /// would merge unrelated source files from different repositories.
    private static func canonicalFileEntityName(_ raw: String) -> String {
        let normalized = raw.replacingOccurrences(of: "\\", with: "/")
        let basename = normalized.split(separator: "/").last.map(String.init) ?? normalized
        let upper = basename.uppercased()
        return canonicalPersonaDocuments[upper] ?? raw
    }

    /// Known terms, quoted spans, and file paths are extracted first. For the
    /// generic capitalized-token fallback, one unknown occurrence is not
    /// enough evidence when it is only sentence-initial or all-caps emphasis.
    /// Repetition keeps user-selected names and unfamiliar acronyms available
    /// without adding a model call.
    private static func shouldPromoteGenericCandidate(_ candidate: String, in content: String) -> Bool {
        let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        let tokens = trimmed.split(whereSeparator: \.isWhitespace).map(String.init)
        if tokens.count > 1 {
            // Generic title-case spans may contain an acronym inflected as a
            // verb ("Codex SSHes"). Reject that deterministic shape without
            // adding a POS model, while preserving proper names whose leading
            // token is itself an acronym ("SSH Bridge").
            return !tokens.dropFirst().contains(where: isAcronymInflectedToken)
        }

        // A stem already represented by a canonical persona-document mention
        // must not become a second concept entity (SOUL + SOUL.md).
        let upper = trimmed.uppercased()
        if canonicalPersonaDocuments["\(upper).MD"] != nil,
           knownTermMentioned("\(upper).md", in: content) {
            return false
        }

        let ranges = wholeTermRanges(trimmed, in: content)
        guard !ranges.isEmpty else { return false }
        if ranges.count > 1 { return true }

        let letters = trimmed.unicodeScalars.filter {
            CharacterSet.letters.contains($0)
        }
        let isAllCaps = !letters.isEmpty && letters.allSatisfy {
            CharacterSet.uppercaseLetters.contains($0)
        }
        if isAllCaps && trimmed.count >= 2 { return false }

        return !isSentenceInitial(ranges[0], in: content)
    }

    private static func isAcronymInflectedToken(_ token: String) -> Bool {
        guard let regex = try? NSRegularExpression(pattern: #"^[A-Z]{2,}[a-z]+$"#) else {
            return false
        }
        let range = NSRange(token.startIndex..<token.endIndex, in: token)
        return regex.firstMatch(in: token, range: range) != nil
    }

    private static func wholeTermRanges(_ term: String, in content: String) -> [NSRange] {
        let pattern = "\\b" + NSRegularExpression.escapedPattern(for: term) + "\\b"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return []
        }
        let range = NSRange(content.startIndex..<content.endIndex, in: content)
        return regex.matches(in: content, range: range).map(\.range)
    }

    private static func isSentenceInitial(_ range: NSRange, in content: String) -> Bool {
        guard let swiftRange = Range(range, in: content) else { return false }
        let prefix = content[..<swiftRange.lowerBound]
        if prefix.isEmpty { return true }

        let linePrefix = prefix.split(separator: "\n", omittingEmptySubsequences: false).last ?? ""
        let lineTrimmed = linePrefix.trimmingCharacters(in: .whitespaces)
        if lineTrimmed.isEmpty || lineTrimmed.allSatisfy({ "-*•>#_".contains($0) }) {
            return true
        }
        // Numbered/lettered list markers are sentence starts too, including
        // compact inline lists such as "(3) Empty... (4) Ordinary...".
        // Without this boundary the generic capitalized-token fallback minted
        // the first word after each marker as a concept.
        let markerRange = NSRange(lineTrimmed.startIndex..<lineTrimmed.endIndex, in: lineTrimmed)
        if Self.listItemPrefixRegex.firstMatch(
            in: lineTrimmed,
            range: markerRange
        ) != nil {
            return true
        }

        let ignorable = CharacterSet.whitespaces
            .union(CharacterSet(charactersIn: "\"'“”‘’*_>()[]{}"))
        var cursor = prefix.endIndex
        while cursor > prefix.startIndex {
            let previous = prefix.index(before: cursor)
            if String(prefix[previous]).unicodeScalars.allSatisfy({ ignorable.contains($0) }) {
                cursor = previous
                continue
            }
            return ".!?".contains(prefix[previous])
        }
        return true
    }

    private static func inferType(_ name: String) -> String {
        let lower = name.lowercased()
        if ["user", "the user", "assistant", "the assistant"].contains(lower) {
            return "person"
        }
        if ["nativeagent", "openclaw", "hermes", "clawdeck"].contains(lower) {
            return "project"
        }
        if lower.hasSuffix(".md") || lower.hasSuffix(".json") || lower.hasSuffix(".swift")
            || lower.hasSuffix(".app") || lower.hasSuffix(".sqlite")
            || ["swift", "coreml", "core ml", "macos", "telegram", "openai", "anthropic", "tradingview", "apns", "mcp"].contains(lower) {
            return "tool"
        }
        if lower == "apple" { return "organization" }
        if lower.contains("launch") || lower.contains("sunday") || lower.contains("rem cycle") {
            return "event"
        }
        return "concept"
    }

    private static func clip(_ text: String, limit: Int) -> String {
        if text.count <= limit { return text }
        let idx = text.index(text.startIndex, offsetBy: limit)
        return String(text[..<idx]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static let knownTerms: [(name: String, type: String)] = [
        ("NativeAgent", "project"),
        ("Assistant", "person"),
        ("User", "person"),
        ("Swift", "tool"),
        ("CoreML", "tool"),
        ("Core ML", "tool"),
        ("Apple", "organization"),
        ("macOS", "tool"),
        ("Telegram", "tool"),
        ("OpenAI", "tool"),
        ("Anthropic", "tool"),
        ("TradingView", "tool"),
        ("APNS", "tool"),
        ("MCP", "tool"),
        ("Hermes", "project"),
        ("OpenClaw", "project"),
        ("ClawDeck", "project"),
        ("SOUL.md", "tool"),
        ("VOICE.md", "tool"),
        ("USER.md", "tool"),
        ("GROWTH.md", "tool"),
        ("AGENTS.md", "tool"),
    ]

    private static let canonicalPersonaDocuments: [String: String] = [
        "SOUL.MD": "SOUL.md",
        "VOICE.MD": "VOICE.md",
        "USER.MD": "USER.md",
        "GROWTH.MD": "GROWTH.md",
        "AGENTS.MD": "AGENTS.md",
    ]

    /// Every provenance value known to have been minted exclusively by this
    /// rebuildable MemoryV2 projection. Unstamped daemon-era and manual rows
    /// remain outside this ownership set and are never deleted here.
    private static let ownedIndexerVersions = [
        "swift-memory-kg-v1",
        "swift-memory-kg-v2",
        "swift-memory-kg-v3",
        indexVersion,
    ]

    private static let listItemPrefixRegex = try! NSRegularExpression(
        pattern: #"(?:^|[\s;:])(?:\([0-9]{1,3}\)|[0-9]{1,3}[.)]|\([A-Za-z]\)|[A-Za-z][.)]|[-*•>])$"#
    )

    private static let entityStopwords: Set<String> = [
        "a", "an", "and", "are", "as", "at", "but", "for", "from", "how",
        "i", "i'm", "im", "in", "is", "it", "its", "listen", "no", "not", "of",
        "ok", "okay", "on", "or", "so", "that", "the", "then", "there",
        "this", "to", "we", "what", "when", "why", "yeah", "yes", "you",
        "your", "user", "the user",
        // 2026-07-02 audit: the daemon-era extractor let bare pronouns
        // become concept entities ("You" ×8, "We" ×4, "He" ×1 purged from
        // the live graph). The list above already blocked we/you; close
        // the rest of the pronoun class so no capture path can mint one.
        "he", "she", "her", "him", "his", "hers", "they", "them", "their",
        "theirs", "us", "our", "ours", "me", "my", "mine", "these", "those",
        // 2026-07-21 audit: the capitalized-phrase regex mints any
        // sentence-initial capitalized word as an entity, so calendar words
        // and sentence-initial imperative/filler words became junk concept
        // entities ("Today", "Remember", "Update", "Monday", "January").
        // Same whole-phrase lowercase match as the pronoun class above — a
        // word here can never be minted as a standalone entity, but a real
        // multi-word name containing it ("May Lee") still can.
        // Days + months (full and common abbreviated forms).
        "monday", "tuesday", "wednesday", "thursday", "friday", "saturday",
        "sunday", "january", "february", "march", "april", "may", "june",
        "july", "august", "september", "october", "november", "december",
        "jan", "feb", "mar", "apr", "jun", "jul", "aug", "sep", "sept",
        "oct", "nov", "dec",
        // Relative-day + sentence-initial filler/imperatives.
        "today", "tomorrow", "yesterday", "tonight", "now", "next",
        "last", "first", "finally", "also", "just", "still", "again",
        "remember", "reminder", "update", "updated", "note", "noted",
        "todo", "fyi", "btw",
        // Fresh-install evidence (2026-07-25): repetition alone must not
        // rehabilitate common sentence-leading verbs, emphasis adjectives,
        // or spelled-out counts as named entities. Multiword names remain
        // unaffected because stopwords are matched against the whole phrase.
        "do", "done", "expected", "hard", "nightly", "rewrote",
        "one", "two", "three", "four", "five", "six",
        "seven", "eight", "nine", "ten", "eleven", "twelve",
    ]
}
