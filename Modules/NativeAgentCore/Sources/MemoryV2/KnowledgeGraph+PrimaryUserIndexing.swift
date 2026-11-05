import Foundation
import GRDB
import NativeAgentCore
import PersistenceCore
import PersonaEngine
// Blueprint: | `KnowledgeGraph+PrimaryUserIndexing.swift` | `SwiftNativeKnowledgeGraphIndexer`, `profileNames`, `primaryUserName`, `consolidatePrimaryUserEntities`, `removeUnreferencedPrimaryUserRole` |

extension SwiftNativeKnowledgeGraphIndexer {
    struct PrimaryUserConsolidation {
        var entitiesRemoved: Int = 0
        var relationshipsRemoved: Int = 0
    }

    /// Resolve the user identity only from onboarding's canonical profile. Generic or unavailable values retain the role label rather than guessing a person's
    /// name from accepted-memory prose.
    static func primaryUserName(explicit: String?, saved: String?) -> String {
        if let explicit {
            return usableProfileName(explicit, rejecting: ["user", "the user"]) ?? "the user"
        }
        return saved ?? "the user"
    }

    /// Read onboarding's names together so graph extraction and memory query expansion use the same identity and rejection vocabulary.
    public static func profileNames(profileURL: URL) throws -> (agent: String?, user: String?) {
        let data: Data
        do { data = try Data(contentsOf: profileURL) }
        catch let error as CocoaError where error.code == .fileReadNoSuchFile { return (nil, nil) }
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw MemoryStorageError.databaseUnavailable("""
                \(profileURL.path) is not a profile object; repair the saved identity before graph indexing or name expansion.
                """)
        }
        let profile = try PersonaCompiler.decodeProfile(raw: object)
        if let userName = profile.extras["userName"], userName.stringValue == nil {
            throw MemoryStorageError.databaseUnavailable("""
                \(profileURL.path): userName must be a string; repair the saved identity before graph indexing or name expansion.
                """)
        }
        func checkedName(_ raw: String?, key: String, rejecting: Set<String>) throws -> String? {
            guard let raw else { return nil }
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, !rejecting.contains(trimmed.lowercased()) else { return nil }
            guard let name = usableProfileName(raw, rejecting: rejecting) else {
                throw MemoryStorageError.databaseUnavailable("""
                    \(profileURL.path): \(key) is not a usable saved name; repair its length or control characters before indexing.
                    """)
            }
            return name
        }
        return try (
            checkedName(profile.name, key: "name", rejecting: ["assistant", "the assistant", "agent", "the agent"]),
            checkedName(profile.extras["userName"]?.stringValue, key: "userName", rejecting: ["user", "the user"])
        )
    }

    private static func usableProfileName(_ raw: String?, rejecting: Set<String>) -> String? {
        guard let raw else { return nil }
        let trimmed = raw
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              trimmed.count <= 80,
              !rejecting.contains(trimmed.lowercased()),
              trimmed.unicodeScalars.allSatisfy({
                  !CharacterSet.controlCharacters.contains($0)
              }) else {
            return nil
        }
        return trimmed
    }

    private static func primaryUserAliases(
        name: String,
        existingRows: [Row] = []
    ) throws -> [String] {
        var aliases: [String] = ["the user", "User"]
        for row in existingRows {
            if let existingName: String = row["name"] {
                aliases.append(existingName)
            }
            let raw: String? = row["aliases_json"]
            guard let raw else { continue }
            let decoded = try JSONDecoder().decode([String].self, from: Data(raw.utf8))
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

    /// Merge only identities proven to denote the configured primary-user role: exact generic person labels, the exact configured person name, and a derived
    /// concept bearing that exact configured name. Arbitrary manual people and concepts remain untouched.
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
        guard let first = rows.first else { return PrimaryUserConsolidation() }

        func role(_ row: Row) throws -> String? {
            let raw: String? = row["metadata_json"]
            guard case .string(let value)? = try metadataObject(raw)["role"] else {
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

        let canonical = try rows.first(where: { try role($0) == "primary_user" })
            ?? rows.first(where: {
                type($0).lowercased() == "person"
                    && name($0).caseInsensitiveCompare(primaryUserName) == .orderedSame
            })
            ?? rows.first(where: { name($0).lowercased() == "the user" })
            ?? first
        let canonicalID: String = try canonical.decode(forColumn: "id")
        var report = PrimaryUserConsolidation()

        for row in rows {
            let duplicateID: String = try row.decode(forColumn: "id")
            guard duplicateID != canonicalID else { continue }
            let relationships = try Row.fetchAll(db, sql: """
                SELECT id, from_id, to_id, type, weight, mention_count,
                       provenance, metadata_json
                FROM kg_relationships
                WHERE from_id = ? OR to_id = ?
                """, arguments: [duplicateID, duplicateID])
            for relationship in relationships {
                let relationshipID: Int64 = try relationship.decode(forColumn: "id")
                let oldFrom: String = try relationship.decode(forColumn: "from_id")
                let oldTo: String = try relationship.decode(forColumn: "to_id")
                let newFrom = oldFrom == duplicateID ? canonicalID : oldFrom
                let newTo = oldTo == duplicateID ? canonicalID : oldTo
                if newFrom != newTo {
                    let relationshipType: String = try relationship.decode(forColumn: "type")
                    let weight: Double? = relationship["weight"]
                    let mentionCount: Int64 = try relationship.decode(Int64?.self, forColumn: "mention_count") ?? 0
                    let priorCount = try Int64.fetchOne(db, sql: """
                        SELECT COALESCE(mention_count, 0) FROM kg_relationships
                        WHERE from_id = ? AND to_id = ? AND type = ?
                        """, arguments: [newFrom, newTo, relationshipType]) ?? 0
                    let (combinedCount, overflow) = priorCount.addingReportingOverflow(mentionCount)
                    guard !overflow else {
                        throw MemoryStorageError.databaseUnavailable("kg_relationships mention_count overflow while merging row \(relationshipID)")
                    }
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
                          mention_count = ?,
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
                            combinedCount,
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

        let metadata = primaryUserMetadata(
            name: primaryUserName, existing: try metadataObject(canonical["metadata_json"]))
        let aliases = try primaryUserAliases(name: primaryUserName, existingRows: rows)
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

    /// The shared identity comes from the profile, not the last fact indexed. Source evidence belongs to each fact and relationship separately.
    private static func primaryUserMetadata(
        name: String, existing: [String: JSONValue] = [:]
    ) -> [String: JSONValue] {
        var metadata = existing
        for key in ["memory_id", "last_memory_id", "last_memory_source"] {
            metadata.removeValue(forKey: key)
        }
        metadata["role"] = .string("primary_user")
        metadata["embedding_text"] = .string("person: \(name)")
        metadata["indexer"] = .string(indexVersion)
        return metadata
    }

    static func upsertPrimaryUserEntity(
        _ db: Database,
        primaryUserName: String,
        now: String
    ) throws -> String {
        if let row = try Row.fetchOne(db, sql: """
            SELECT id, aliases_json, metadata_json, mention_count
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
            let id: String = try row.decode(forColumn: "id")
            let count: Int64? = try row.decode(forColumn: "mention_count")
            let (nextCount, overflow) = (count ?? 0).addingReportingOverflow(1)
            guard !overflow else {
                throw MemoryStorageError.databaseUnavailable("kg_entities mention_count overflow for row \(id)")
            }
            let metadata = primaryUserMetadata(
                name: primaryUserName, existing: try metadataObject(row["metadata_json"]))
            let aliases = try primaryUserAliases(name: primaryUserName, existingRows: [row])
            let aliasData = try JSONEncoder().encode(aliases)
            try db.execute(sql: """
                UPDATE kg_entities SET
                  name = ?,
                  type = 'person',
                  summary = ?,
                  aliases_json = ?,
                  mention_count = ?,
                  last_seen = ?,
                  metadata_json = ?
                WHERE id = ?
                """, arguments: [
                    primaryUserName,
                    "NativeAgent's primary user.",
                    String(decoding: aliasData, as: UTF8.self),
                    nextCount,
                    now,
                    metadataJSON(metadata),
                    id,
                ])
            return id
        }

        let id = try uniqueEntityID(db)
        let aliases = try primaryUserAliases(name: primaryUserName)
        let aliasData = try JSONEncoder().encode(aliases)
        let metadata = primaryUserMetadata(name: primaryUserName)
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
