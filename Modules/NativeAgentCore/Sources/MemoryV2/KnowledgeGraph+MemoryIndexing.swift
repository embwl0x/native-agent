// Project accepted facts into canonical graph tables; `embedding_text` is part of the shared search/tool payload contract.

import CryptoKit
import Foundation
import NativeAgentShared
import GRDB
import NativeAgentCore
import PersistenceCore
// Blueprint: | `KnowledgeGraph+MemoryIndexing.swift` | `KnowledgeGraphMemoryFact`: canonical indexing and fenced reconciliation |

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
        let id = try row.decode(String.self, forColumn: "id")
        let validFrom = try row.decode(String?.self, forColumn: "valid_from")
        let validTo = try row.decode(String?.self, forColumn: "valid_to")
        try MemoryStorage.validateTemporalEvidence(id: id, validFrom: validFrom, validTo: validTo, observedAt: nil)
        guard MemoryRecordDisclosurePolicy.isTemporallyEligible(validTo: validTo, at: Date()) else { return nil }
        let metadata = try row.decode(String?.self, forColumn: "metadata_json")
        self.init(
            id: id,
            content: try row.decode(String.self, forColumn: "content"),
            source: try row.decode(String?.self, forColumn: "source"),
            status: try row.decode(String?.self, forColumn: "status") ?? "active",
            createdAt: try row.decode(String?.self, forColumn: "created_at") ?? "",
            updatedAt: try row.decode(String?.self, forColumn: "updated_at") ?? "",
            metadata: try metadata.map { try JSONValue.parse(Data($0.utf8)) },
            validFrom: validFrom, validTo: validTo
        )
    }
}

public struct KnowledgeGraphExtractedEntity: Sendable, Equatable {
    public var name: String
    public var type: String
    public var summary: String
    /// Other names the facts state this entity goes by; a later mention of one meets this entity.
    public var aliases: [String]

    public init(name: String, type: String, summary: String, aliases: [String] = []) {
        self.name = name
        self.type = type
        self.summary = summary
        self.aliases = aliases
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
    // The ownership stamp is stable; fact fingerprints identify derivation changes.
    static let indexVersion = "swift-memory-kg-v5"
    /// Insert-only metadata_json provenance proves indexer ownership for GC; unstamped entities are never swept.
    static let createdByKey = "created_by_indexer"

    /// Internal visibility lets GC share the indexer's ownership stamp.
    let sqlitePath: URL
    /// Reread canonical onboarding identity once per operation, never per fact, so profile renames take effect without restart.
    private let explicitPrimaryUserName: String?
    private let primaryUserProfileURL: URL

    private var projectionGeneration = 0
    private var reconciledProjectionGeneration: Int?
    private var projectionProducing: Bool?

    public func markProjectionDirty() {
        projectionGeneration += 1
    }

    public func reconcileProjectionIfNeeded(producing: Bool) async throws {
        // Check canonical fingerprints on every operation: retained indexers cannot assume profile identity stayed unchanged.
        projectionGeneration += 1
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
            // A superseded startup rebuild can finish after retirement. Its completion must repair the current mode rather than certify it.
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
    }

    struct ExtractionIdentity: Sendable {
        let primaryUserName: String
        let knownPeople: [String]
        /// Every name the agent's contacts are written as (lowercased) to that contact's own name: each is an agent.
        let knownAgents: [String: String]
        /// Each contact's own name (lowercased) to its id (`peer:<id>`): the agent entity under that name links to that contact.
        let contactIDs: [String: String]
        let fingerprint: String
    }

    func resolvedExtractionIdentity() throws -> ExtractionIdentity {
        let profileNames = try Self.profileNames(profileURL: primaryUserProfileURL)
        let resolved = Self.primaryUserName(explicit: explicitPrimaryUserName, saved: profileNames.user)
        // Recognize the agent's own name as a person.
        let agent = profileNames.agent
        var people: [String] = []
        if !resolved.isEmpty, resolved.lowercased() != "the user" { people.append(resolved) }
        if let agent, !people.contains(where: { $0.lowercased() == agent.lowercased() }) {
            people.append(agent)
        }
        // The agent's contacts, read once for this pass, and the app-delegated builders are agents, never people, places or concepts.
        let peersURL = sqlitePath.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("agents/peers.json")
        let contacts = try Self.contactNames(peersURL: peersURL, taken: Set((people + Self.builtInPeerAgents).map { $0.lowercased() }))
        var agents = contacts.names
        for peer in Self.builtInPeerAgents where agents[peer.lowercased()] == nil { agents[peer.lowercased()] = peer }
        for person in people { agents[person.lowercased()] = nil }
        let fields: [String?] = [profileNames.agent, profileNames.user, explicitPrimaryUserName,
                      agents.keys.sorted().map { $0 + "=" + (agents[$0] ?? "") }.joined(separator: ";"),
                      contacts.ids.keys.sorted().map { $0 + "=" + (contacts.ids[$0] ?? "") }.joined(separator: ";")]
        let fingerprint = Self.contentHash(fields.map { field in
            field.map { "\($0.utf8.count):\($0)" } ?? "unset"
        }.joined(separator: "|"))
        return ExtractionIdentity(primaryUserName: resolved, knownPeople: people, knownAgents: agents, contactIDs: contacts.ids,
                                  fingerprint: fingerprint)
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
        // MemoryStorage orders the hooks; reconciliation owns retirement when production is disabled, so subsequent mutations have nothing to do.
        guard !memoryID.isEmpty, producing else { return }
        let dbPool = try await pool()
        let identity = try resolvedExtractionIdentity()
        do {
            try await dbPool.write { db in
                // Hook payloads only wake the owner; reread canonical rows in the shared transaction domain so a delayed update cannot resurrect a deleted
                // claim.
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
                let contentHash = Self.factFingerprint(canonicalFact, content: content, identity: identity)
                // Check hashes inside the upsert transaction; changed claims require canonical rebuilding so old entities and edges cannot survive an overlay.
                let existingHash = try String.fetchOne(
                    db,
                    sql: "SELECT content_hash FROM kg_memory_index WHERE memory_id = ?",
                    arguments: [memoryID]
                )
                guard existingHash != contentHash else { return }
                if existingHash != nil { throw IndexingControl.requiresCanonicalRebuild }
                let found = Self.namesIn(content, knownPeople: identity.knownPeople, knownAgents: identity.knownAgents)
                let aliases = try Self.storedAliases(db)
                // A fact stating two names are one changes what earlier facts' names meet, so the graph is rederived with it.
                let one = { (name: String) in aliases[name.lowercased()]?.name.lowercased() ?? name.lowercased() }
                if Self.statedAliasPairs(in: content, names: found.map(\.name)).contains(where: { one($0.0) != one($0.1) }) {
                    throw IndexingControl.requiresCanonicalRebuild
                }
                try Self.indexActiveFact(
                    db,
                    fact: canonicalFact,
                    memoryID: memoryID,
                    content: content,
                    contentHash: contentHash,
                    now: Self.nowISO8601(),
                    extracted: Self.resolvingAliases(found, in: content, aliases: aliases, knownPeople: identity.knownPeople,
                                                     knownAgents: identity.knownAgents),
                    primaryUserName: identity.primaryUserName,
                    contactIDs: identity.contactIDs
                )
            }
        } catch IndexingControl.requiresCanonicalRebuild {
            // Eligibility can change while acquiring the rebuild transaction. Its canonical read decides removal; never carry an exclusion.
            _ = try await rebuildMemoryDerivedGraphFromCanonicalStore(producing: true, identity: identity)
        }
    }

    static func indexActiveFact(
        _ db: Database,
        fact: KnowledgeGraphMemoryFact,
        memoryID: String,
        content: String,
        contentHash: String,
        now: String,
        extracted: [KnowledgeGraphExtractedEntity],
        primaryUserName: String,
        contactIDs: [String: String]
    ) throws {
        let userID = try upsertPrimaryUserEntity(
            db,
            primaryUserName: primaryUserName,
            now: now
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
                    aliases: entity.aliases,
                    contactID: entity.type == "agent" ? contactIDs[entity.name.lowercased()] : nil,
                    now: now,
                    fact: fact
                )
                if entityID != userID && entityID != factID {
                    entityIDs.append(entityID)
                }
            }

            let personEdge = personRelation(fact, person: try personNames(db, userID: userID))
            for entityID in entityIDs {
                try upsertRelationship(
                    db,
                    fromID: userID,
                    toID: entityID,
                    type: personEdge,
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

    /// One source-backed fact node per memory row makes searchable meaning traceable to its exact canonical record.
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

    /// Hash memory IDs into stable graph IDs so arbitrary user IDs cannot become graph keys; retain the external ID as projection evidence.
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
        default: return "remembers"
        }
    }

    /// The person's edge to each thing a memory names says what the memory is to the person: `in_memory_from` when one of its roots is the
    /// person telling it, unsteered; otherwise `in_memory_about` (the agent noticed or inferred it, someone else told it, or nothing recorded
    /// who did). A memory's subject is not its speaker, so a memory about the person never reads as the person mentioning the thing.
    static func personRelation(_ fact: KnowledgeGraphMemoryFact, person: Set<String>) -> String {
        tellers(fact).contains { person.contains($0) } ? "in_memory_from" : "in_memory_about"
    }

    /// The names a memory's unsteered `told` roots give its teller, lowercased: what the person's edge is derived from.
    static func tellers(_ fact: KnowledgeGraphMemoryFact) -> [String] {
        guard case .held(let roots) = MemoryRoot.reading(fact.metadata) else { return [] }
        return Set(roots.filter { $0.how == .told && $0.through.isEmpty }.compactMap { $0.by?.lowercased() }).sorted()
    }

    /// The person by identity, not by the profile's current name: the primary-user entity's name and every name it has carried (its aliases
    /// keep a renamed profile's former name), and the roots' word for an unnamed person. Lowercased.
    static func personNames(_ db: Database, userID: String) throws -> Set<String> {
        var names: Set<String> = [MemoryDataProvenance.unnamedPerson]
        guard let row = try Row.fetchOne(db, sql: "SELECT name, aliases_json FROM kg_entities WHERE id = ?", arguments: [userID]) else {
            return names
        }
        if let name: String = row["name"] { names.insert(name.lowercased()) }
        if let raw: String = row["aliases_json"] {
            for alias in try JSONDecoder().decode([String].self, from: Data(raw.utf8)) { names.insert(alias.lowercased()) }
        }
        return names
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
        aliases: [String] = [],
        contactID: String? = nil,
        now: String,
        fact: KnowledgeGraphMemoryFact
    ) throws -> String {
        if let row = try Row.fetchOne(db, sql: """
            SELECT id, metadata_json, mention_count, aliases_json FROM kg_entities
            WHERE lower(name) = lower(?) AND lower(type) = lower(?)
            ORDER BY mention_count DESC, last_seen DESC
            LIMIT 1
            """, arguments: [name, type]) {
            let id: String = try row.decode(forColumn: "id")
            var metadata = try metadataObject(row.decode(forColumn: "metadata_json"))
            // indexActiveFact already updated this profile-backed hub. A name extracted from the fact must not overwrite it with fact content,
            // but a name a fact states the person goes by joins the hub's aliases, which the hub keeps.
            if metadata["role"]?.stringValue == "primary_user" {
                let stored: String? = row["aliases_json"]
                var names = try JSONDecoder().decode([String].self, from: Data((stored ?? "[]").utf8))
                let added = aliases.filter { alias in !names.contains { $0.lowercased() == alias.lowercased() } }
                if !added.isEmpty {
                    names += added
                    try db.execute(sql: "UPDATE kg_entities SET aliases_json = ? WHERE id = ?", arguments: [aliasesJSON(names), id])
                }
                return id
            }
            let count: Int64? = try row.decode(forColumn: "mention_count")
            let (nextCount, overflow) = (count ?? 0).addingReportingOverflow(1)
            guard !overflow else {
                throw MemoryStorageError.databaseUnavailable("kg_entities mention_count overflow for row \(id)")
            }
            metadata["embedding_text"] = .string("\(type): \(name)")
            metadata["last_memory_id"] = .string(fact.id)
            if let source = fact.source { metadata["last_memory_source"] = .string(source) }
            metadata["indexer"] = .string(indexVersion)
            // An agent entity naming one of the agent's contacts carries that contact's id; the next pass derives it again.
            metadata["contact_id"] = contactID.map(JSONValue.string)
            // Stated aliases join only this indexer's own entities, which a rebuild rederives; another owner's names stay its own.
            var known: [String]?
            if !aliases.isEmpty, metadata[createdByKey]?.stringValue == indexVersion {
                let stored: String? = row["aliases_json"]
                var names = try JSONDecoder().decode([String].self, from: Data((stored ?? "[]").utf8))
                for alias in aliases where !names.contains(where: { $0.lowercased() == alias.lowercased() }) { names.append(alias) }
                known = names
            }
            try db.execute(sql: """
                UPDATE kg_entities SET
                  mention_count = ?,
                  last_seen = ?,
                  summary = ?,
                  metadata_json = ?,
                  aliases_json = COALESCE(?, aliases_json)
                WHERE id = ?
                """, arguments: [nextCount, now, summary, metadataJSON(metadata), known.map(aliasesJSON), id])
            return id
        }

        let id = try uniqueEntityID(db)
        var metadata: [String: JSONValue] = [
            "embedding_text": .string("\(type): \(name)"),
            "last_memory_id": .string(fact.id),
            "last_memory_source": fact.source.map(JSONValue.string) ?? .null,
            "indexer": .string(indexVersion),
            // Stamp creation provenance only on insert; GC relies on its ownership claim.
            createdByKey: .string(indexVersion),
        ]
        if let contactID { metadata["contact_id"] = .string(contactID) }
        try db.execute(sql: """
            INSERT INTO kg_entities
              (id, name, type, summary, aliases_json, mention_count,
               first_seen, last_seen, provenance, metadata_json)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """, arguments: [
                id, name, type, summary, aliasesJSON(aliases), 1, now, now,
                type == "concept" ? "default-concept" : nil,
                metadataJSON(metadata),
            ])
        return id
    }

    static func aliasesJSON(_ aliases: [String]) -> String {
        String(decoding: (try? JSONEncoder().encode(aliases.sorted())) ?? Data("[]".utf8), as: UTF8.self)
    }

    /// The aliases earlier facts stated, as this indexer stored them on its own entities, so a later fact naming only an alias meets the
    /// same entity.
    static func storedAliases(_ db: Database) throws -> StatedAliases {
        var aliases: StatedAliases = [:]
        for row in try Row.fetchAll(db, sql: """
            SELECT name, type, aliases_json FROM kg_entities
            WHERE (json_extract(metadata_json, '$.\(createdByKey)') = ? OR json_extract(metadata_json, '$.role') = 'primary_user')
              AND COALESCE(aliases_json, '[]') <> '[]'
            """, arguments: [indexVersion]) {
            let name: String = try row.decode(forColumn: "name")
            let type: String = try row.decode(forColumn: "type")
            let written: String = try row.decode(forColumn: "aliases_json")
            for alias in try JSONDecoder().decode([String].self, from: Data(written.utf8)) {
                aliases[alias.lowercased()] = (name, type, alias)
            }
        }
        return aliases
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
            var metadata = try metadataObject(row["metadata_json"])
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
                    structuralRelationTypes.contains(type) ? "default-mentions" : nil,
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
                structuralRelationTypes.contains(type) ? "default-mentions" : nil,
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

    static func metadataObject(_ raw: String?) throws -> [String: JSONValue] {
        guard let raw else { return [:] }
        guard case .object(let obj) = try JSONValue.parse(Data(raw.utf8)) else {
            throw MemoryStorageError.databaseUnavailable("Knowledge graph metadata_json is not an object; repair the row before reading or changing it.")
        }
        return obj
    }

    static func metadataJSON(_ metadata: [String: JSONValue]) throws -> String? {
        guard !metadata.isEmpty else { return nil }
        let data = try JSONValue.object(metadata).serializedData(pretty: false)
        return String(decoding: data, as: UTF8.self)
    }

    static func contentHash(_ text: String) -> String {
        let digest = SHA256.hash(data: Data(text.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    static func factFingerprint(_ fact: KnowledgeGraphMemoryFact, content: String, identity: ExtractionIdentity) -> String {
        let kind = metadataString(fact.metadata, "kind") ?? "fact"
        // The person's edge is derived from the memory's tellers (and the person's names, in identity), so a telling added later re-derives
        // it on the next pass.
        let fields = [indexVersion, "canonical-profile-hub-declared-kind-language-stated-alias-contact-link-v5", identity.fingerprint,
                      kind, fact.validFrom ?? "", fact.validTo ?? "", content, "tellers:" + tellers(fact).joined(separator: "\n")]
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
