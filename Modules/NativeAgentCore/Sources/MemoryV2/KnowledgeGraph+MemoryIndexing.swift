// Projects accepted MemoryV2 facts into a conservative local entity set in
// memory.sqlite kg_entities/kg_relationships. The `embedding_text` metadata
// field is part of the shared search/tool payload contract.

import CryptoKit
import Foundation
import NativeAgentShared
import GRDB
import NativeAgentCore
import PersistenceCore
// Blueprint: | `KnowledgeGraph+MemoryIndexing.swift` | `KnowledgeGraphMemoryFact`; ID-only canonical indexing and generation/mode-fenced projection reconciliation |

public struct KnowledgeGraphMemoryFact: Sendable, Equatable {
    public var id: String
    public var content: String
    public var source: String?
    public var status: String
    public var createdAt: String
    public var updatedAt: String
    public var metadata: JSONValue?
    public var validFrom: String?
    public var validTo: String?

    public init(
        id: String,
        content: String,
        source: String? = nil,
        status: String = "active",
        createdAt: String,
        updatedAt: String,
        metadata: JSONValue? = nil,
        validFrom: String? = nil,
        validTo: String? = nil
    ) {
        self.id = id
        self.content = content
        self.source = source
        self.status = status
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.metadata = metadata
        self.validFrom = validFrom
        self.validTo = validTo
    }

    init?(row: Row) throws {
        let validTo = try row.decode(String?.self, forColumn: "valid_to")
        guard MemoryRecordDisclosurePolicy.isTemporallyEligible(validTo: validTo, at: Date()) else { return nil }
        let metadata = try row.decode(String?.self, forColumn: "metadata_json")
        self.init(
            id: try row.decode(String.self, forColumn: "id"),
            content: try row.decode(String.self, forColumn: "content"),
            source: try row.decode(String?.self, forColumn: "source"),
            status: try row.decode(String?.self, forColumn: "status") ?? "active",
            createdAt: try row.decode(String?.self, forColumn: "created_at") ?? "",
            updatedAt: try row.decode(String?.self, forColumn: "updated_at") ?? "",
            metadata: metadata.flatMap { try? JSONValue.parse(Data($0.utf8)) },
            validFrom: try row.decode(String?.self, forColumn: "valid_from"), validTo: validTo
        )
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
    // v5 uses the on-device name tagger; rows re-index on their next touch or rebuild.
    static let indexVersion = "swift-memory-kg-v5"
    /// Insert-only metadata_json provenance proves indexer ownership for GC; unstamped entities are never swept.
    static let createdByKey = "created_by_indexer"

    /// Internal (not private): the GC extension lives in KnowledgeGraph+GC.swift.
    let sqlitePath: URL
    /// Canonical onboarding identity source for the stable primary-user role
    /// node. It is reread once per indexing/rebuild/GC operation so onboarding
    /// and profile renames take effect without restarting, never once per fact.
    private let explicitPrimaryUserName: String?
    private let primaryUserProfileURL: URL
    /// Resolve known people once at init; indexing and GC share this list for synchronous extraction.
    nonisolated let knownPeople: [String]

    private var projectionGeneration = 0
    private var reconciledProjectionGeneration: Int?
    private var projectionProducing: Bool?

    public func markProjectionDirty() {
        projectionGeneration += 1
    }

    public func reconcileProjectionIfNeeded(producing: Bool) async throws {
        if projectionProducing != producing {
            projectionProducing = producing
            projectionGeneration += 1
        }
        while reconciledProjectionGeneration != projectionGeneration {
            let generation = projectionGeneration
            if projectionProducing == true {
                _ = try await reconcileMemoryIndexFingerprints()
            } else {
                _ = try await rebuildMemoryDerivedGraphFromCanonicalStore(producing: false)
            }
            // A superseded startup rebuild can finish after retirement. Its
            // completion must repair the current mode rather than certify it.
            reconciledProjectionGeneration = projectionGeneration == generation ? generation : nil
        }
    }

    /// Resolve MemoryStorage's pool lazily; an unreadable database throws on first use, not initialization.
    public init(memorySQLitePath: URL, primaryUserName: String? = nil) throws {
        try FileManager.default.createDirectory(
            at: memorySQLitePath.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        self.sqlitePath = memorySQLitePath
        self.explicitPrimaryUserName = primaryUserName
        self.primaryUserProfileURL = memorySQLitePath.deletingLastPathComponent()
            .appendingPathComponent("profile.json")
        let profileNames = Self.profileNames(profileURL: self.primaryUserProfileURL)
        let resolved = if let primaryUserName {
            Self.resolvePrimaryUserName(explicit: primaryUserName, profileURL: self.primaryUserProfileURL)
        } else {
            profileNames.user ?? "the user"
        }
        // The agent's own name always identifies a person in her graph.
        let agent = profileNames.agent
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

    /// Resolve the owner's pool without creating memory.sqlite; a missing file throws `.databaseMissing`.
    func pool() async throws -> DatabasePool {
        try await KnowledgeGraphPoolCache.shared.pool(at: sqlitePath)
    }

    public func indexMemory(
        _ id: String, producing: Bool = true
    ) async throws {
        let memoryID = id.trimmingCharacters(in: .whitespacesAndNewlines)
        // MemoryStorage orders the hooks; reconciliation owns retirement when
        // production is disabled, so subsequent mutations have nothing to do.
        guard !memoryID.isEmpty, producing else { return }
        let dbPool = try await pool()
        let primaryUserName = resolvedPrimaryUserName()
        do {
            try await dbPool.write { db in
                // Hook payloads are wake hints, not authority. In the production
                // database MemoryV2 and KG share this exact transaction domain,
                // so re-read the canonical row now. A delayed update task that
                // arrives after a delete can no longer resurrect stale entities.
                let canonicalFact = try Row.fetchOne(db, sql: """
                    SELECT id, content, source, status, lifecycle, created_at, updated_at,
                           metadata_json, valid_from, valid_to
                    FROM memories WHERE id = ? AND status = 'active'
                      AND json_extract(metadata_json, '$.admission_pending') IS NOT 1
                    """, arguments: [memoryID])
                    .flatMap { row -> KnowledgeGraphMemoryFact? in
                        guard MemoryLifecycle.isRecallEligible(try row.decode(String?.self, forColumn: "lifecycle")),
                              let fact = try KnowledgeGraphMemoryFact(row: row),
                              !fact.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
                        return fact
                    }

                guard let canonicalFact else {
                    throw IndexingControl.requiresCanonicalRebuild
                }

                let content = canonicalFact.content
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let contentHash = Self.factFingerprint(canonicalFact, content: content)
                // The hash check shares the upserts' write transaction. A
                // changed hash cannot be incrementally overlaid: entities and
                // edges from the old claim would survive. Escape the transaction and run
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
                    now: Self.nowISO8601(),
                    extracted: Self.extractEntities(from: content, knownPeople: knownPeople),
                    primaryUserName: primaryUserName
                )
            }
        } catch IndexingControl.requiresCanonicalRebuild {
            // Eligibility can change while acquiring the rebuild transaction.
            // Its canonical read decides removal; never carry an exclusion.
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

        if let row = try Row.fetchOne(db, sql: "SELECT id, mention_count FROM kg_entities WHERE id = ?", arguments: [id]) {
            let count: Int64? = try row.decode(forColumn: "mention_count")
            let (nextCount, overflow) = (count ?? 0).addingReportingOverflow(1)
            guard !overflow else {
                throw MemoryStorageError.databaseUnavailable("kg_entities mention_count overflow for row \(id)")
            }
            try db.execute(sql: """
                UPDATE kg_entities SET
                  name = ?,
                  type = 'fact',
                  summary = ?,
                  mention_count = ?,
                  last_seen = ?,
                  metadata_json = ?
                WHERE id = ?
                """, arguments: [title, summary, nextCount, now, metadataJSON(metadata), id])
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

    static func upsertEntity(
        _ db: Database,
        name: String,
        type: String,
        summary: String,
        now: String,
        fact: KnowledgeGraphMemoryFact
    ) throws -> String {
        if let row = try Row.fetchOne(db, sql: """
            SELECT id, metadata_json, mention_count FROM kg_entities
            WHERE lower(name) = lower(?) AND lower(type) = lower(?)
            ORDER BY mention_count DESC, last_seen DESC
            LIMIT 1
            """, arguments: [name, type]) {
            let id: String = try row.decode(forColumn: "id")
            let count: Int64? = try row.decode(forColumn: "mention_count")
            let (nextCount, overflow) = (count ?? 0).addingReportingOverflow(1)
            guard !overflow else {
                throw MemoryStorageError.databaseUnavailable("kg_entities mention_count overflow for row \(id)")
            }
            var metadata = metadataObject(try row.decode(forColumn: "metadata_json"))
            metadata["embedding_text"] = .string("\(type): \(name)")
            metadata["last_memory_id"] = .string(fact.id)
            if let source = fact.source { metadata["last_memory_source"] = .string(source) }
            metadata["indexer"] = .string(indexVersion)
            try db.execute(sql: """
                UPDATE kg_entities SET
                  mention_count = ?,
                  last_seen = ?,
                  summary = ?,
                  metadata_json = ?
                WHERE id = ?
                """, arguments: [nextCount, now, summary, metadataJSON(metadata), id])
            return id
        }

        let id = try uniqueEntityID(db)
        let metadata: [String: JSONValue] = [
            "embedding_text": .string("\(type): \(name)"),
            "last_memory_id": .string(fact.id),
            "last_memory_source": fact.source.map(JSONValue.string) ?? .null,
            "indexer": .string(indexVersion),
            // Stamp creation provenance only on insert; GC relies on its ownership claim.
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
            SELECT id, weight, metadata_json, mention_count FROM kg_relationships
            WHERE from_id = ? AND to_id = ? AND type = ?
            LIMIT 1
            """, arguments: [fromID, toID, type]) {
            let id: Int64 = try row.decode(forColumn: "id")
            let count: Int64? = try row.decode(forColumn: "mention_count")
            let (nextCount, overflow) = (count ?? 0).addingReportingOverflow(1)
            guard !overflow else {
                throw MemoryStorageError.databaseUnavailable("kg_relationships mention_count overflow for row \(id)")
            }
            let oldWeight: Double = row["weight"] ?? 0.5
            var metadata = metadataObject(row["metadata_json"])
            if metadata["first_seen"] == nil { metadata["first_seen"] = .string(now) }
            metadata["last_seen"] = .string(now)
            metadata["last_memory_id"] = .string(fact.id)
            metadata["indexer"] = .string(indexVersion)
            try db.execute(sql: """
                UPDATE kg_relationships SET
                  weight = ?,
                  mention_count = ?,
                  provenance = COALESCE(provenance, ?),
                  metadata_json = ?
                WHERE id = ?
                """, arguments: [
                    min(1.0, oldWeight + 0.05),
                    nextCount,
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

    static func factFingerprint(_ fact: KnowledgeGraphMemoryFact, content: String) -> String {
        let kind = metadataString(fact.metadata, "kind") ?? "fact"
        let fields = [indexVersion, kind, fact.validFrom ?? "", fact.validTo ?? "", content]
        return contentHash(fields.map { "\($0.utf8.count):\($0)" }.joined())
    }

    static func nowISO8601() -> String {
        NativeTimestampFormat.fractionalZulu(Date())
    }

    static func clip(_ text: String, limit: Int) -> String {
        if text.count <= limit { return text }
        let idx = text.index(text.startIndex, offsetBy: limit)
        return String(text[..<idx]).trimmingCharacters(in: .whitespacesAndNewlines)
    }


}
