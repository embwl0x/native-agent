import Foundation
import GRDB
import NativeAgentCore
import PersistenceCore

extension SwiftNativeKnowledgeGraphIndexer {
    struct PrimaryUserConsolidation {
        var entitiesRemoved: Int = 0
        var relationshipsRemoved: Int = 0
    }

    /// Resolve the user identity only from onboarding's canonical profile.
    /// Generic or unavailable values retain the role label rather than
    /// guessing a person's name from accepted-memory prose.
    static func resolvePrimaryUserName(explicit: String?, profileURL: URL) -> String {
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
    static func consolidatePrimaryUserEntities(
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

    static func removeUnreferencedPrimaryUserRole(
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

    static func upsertPrimaryUserEntity(
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
}
