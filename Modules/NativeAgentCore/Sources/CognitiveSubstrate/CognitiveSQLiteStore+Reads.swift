import Foundation
import GRDB
import PersistenceCore

extension CognitiveSQLiteStore {
    public func loadNodes() async throws -> [CognitiveNode] {
        try await dbQueue.read { db in
            try Self.fetchNodesWithDecayAnchors(db).nodes
        }
    }

    func loadRestoreBundle(
        artifactFamilies: [CognitiveArtifactFamilyLoad]
    ) async throws -> CognitiveSQLiteRestoreBundle {
        try await dbQueue.read { db in
            var artifacts: [String: [JSONValue]] = [:]
            for family in artifactFamilies {
                artifacts[family.key] = try Self.fetchArtifacts(
                    db,
                    kindPrefix: family.kindPrefix,
                    limit: family.limit,
                    requireObjectPayload: true
                )
            }
            let restoredNodes = try Self.fetchNodesWithDecayAnchors(db)
            return CognitiveSQLiteRestoreBundle(
                nodes: restoredNodes.nodes,
                nodeDecayAnchors: restoredNodes.decayAnchors,
                artifacts: artifacts
            )
        }
    }

    public func loadArtifacts(kindPrefix: String? = nil, limit: Int = 100) async throws -> [JSONValue] {
        try await dbQueue.read { db in
            try Self.fetchArtifacts(
                db,
                kindPrefix: kindPrefix,
                limit: limit,
                requireObjectPayload: false
            )
        }
    }

    public func loadReceipts(kindPrefix: String? = nil, limit: Int = 100) async throws -> [JSONValue] {
        try await dbQueue.read { db in
            let bounded = max(0, min(limit, 500))
            let rows: [Row]
            if let kindPrefix {
                rows = try Row.fetchAll(
                    db,
                    sql: """
                    SELECT id, payload_json FROM cognitive_receipts
                    WHERE kind LIKE ?
                    ORDER BY created_at DESC, id ASC
                    LIMIT ?
                    """,
                    arguments: ["\(kindPrefix)%", bounded]
                )
            } else {
                rows = try Row.fetchAll(
                    db,
                    sql: """
                    SELECT id, payload_json FROM cognitive_receipts
                    ORDER BY created_at DESC, id ASC
                    LIMIT ?
                    """,
                    arguments: [bounded]
                )
            }
            return try rows.map { row in
                try Self.receiptPayload(from: row)
            }
        }
    }

    public func loadReceiptRecords(kindPrefix: String? = nil, limit: Int = 100) async throws -> [CognitiveReceiptRecord] {
        try await dbQueue.read { db in
            let bounded = max(0, min(limit, 500))
            let rows: [Row]
            if let kindPrefix {
                rows = try Row.fetchAll(
                    db,
                    sql: """
                    SELECT id, kind, payload_json, created_at FROM cognitive_receipts
                    WHERE kind LIKE ?
                    ORDER BY created_at DESC, id ASC
                    LIMIT ?
                    """,
                    arguments: ["\(kindPrefix)%", bounded]
                )
            } else {
                rows = try Row.fetchAll(
                    db,
                    sql: """
                    SELECT id, kind, payload_json, created_at FROM cognitive_receipts
                    ORDER BY created_at DESC, id ASC
                    LIMIT ?
                    """,
                    arguments: [bounded]
                )
            }
            return try rows.map { row in
                let rowID: String = row["id"] ?? "<unknown>"
                guard let id = UUID(uuidString: rowID),
                      let kind: String = row["kind"],
                      let createdAt: Double = row["created_at"],
                      createdAt.isFinite else {
                    throw CognitiveSQLiteReadError.malformedRow(
                        table: "cognitive_receipts",
                        id: rowID,
                        detail: "one or more required fields are invalid"
                    )
                }
                return CognitiveReceiptRecord(
                    id: id,
                    kind: kind,
                    payload: try Self.receiptPayload(from: row),
                    createdAt: Date(timeIntervalSince1970: createdAt)
                )
            }
        }
    }

    public func schemaMarkers() async throws -> [String: String] {
        try await dbQueue.read { db in
            let rows = try Row.fetchAll(db, sql: "SELECT name, value FROM cognitive_schema_markers")
            var out: [String: String] = [:]
            for row in rows {
                if let name: String = row["name"], let value: String = row["value"] {
                    out[name] = value
                }
            }
            return out
        }
    }

    private static func fetchNodesWithDecayAnchors(
        _ db: Database
    ) throws -> (nodes: [CognitiveNode], decayAnchors: [UUID: Date]) {
        let rows = try Row.fetchAll(
            db,
            sql: """
            SELECT id, kind, subject_type, subject_id, subject_label,
                   activation, salience, confidence, source_class,
                   created_at, last_activated_at, decay_half_life,
                   summary, metadata_json, updated_at,
                   emotional_valence, emotional_arousal, emotional_warmth
            FROM cognitive_nodes
            ORDER BY salience DESC, activation DESC, last_activated_at DESC, id ASC
            """
        )
        var nodes: [CognitiveNode] = []
        var decayAnchors: [UUID: Date] = [:]
        nodes.reserveCapacity(rows.count)
        decayAnchors.reserveCapacity(rows.count)
        for row in rows {
            let node = try node(from: row)
            guard let updatedAt: Double = row["updated_at"], updatedAt.isFinite else {
                throw CognitiveSQLiteReadError.malformedRow(
                    table: "cognitive_nodes",
                    id: node.id.uuidString,
                    detail: "updated_at is missing or nonfinite"
                )
            }
            nodes.append(node)
            decayAnchors[node.id] = Date(timeIntervalSince1970: updatedAt)
        }
        return (nodes, decayAnchors)
    }

    private static func fetchArtifacts(
        _ db: Database,
        kindPrefix: String?,
        limit: Int,
        requireObjectPayload: Bool
    ) throws -> [JSONValue] {
        let bounded = max(0, min(limit, 500))
        let rows: [Row]
        if let kindPrefix {
            rows = try Row.fetchAll(
                db,
                sql: """
                SELECT id, payload_json FROM cognitive_artifacts
                WHERE kind LIKE ?
                ORDER BY updated_at DESC, id ASC
                LIMIT ?
                """,
                arguments: ["\(kindPrefix)%", bounded]
            )
        } else {
            rows = try Row.fetchAll(
                db,
                sql: """
                SELECT id, payload_json FROM cognitive_artifacts
                ORDER BY updated_at DESC, id ASC
                LIMIT ?
                """,
                arguments: [bounded]
            )
        }
        return try rows.map { row in
            let id: String = row["id"] ?? "<unknown>"
            guard let raw: String = row["payload_json"] else {
                throw CognitiveSQLiteReadError.malformedRow(
                    table: "cognitive_artifacts",
                    id: id,
                    detail: "payload_json is missing"
                )
            }
            let payload: JSONValue
            do {
                payload = try parseJSONStrict(raw)
            } catch {
                throw CognitiveSQLiteReadError.malformedRow(
                    table: "cognitive_artifacts",
                    id: id,
                    detail: "payload_json is not valid JSON"
                )
            }
            if requireObjectPayload, case .object = payload {
                return payload
            }
            if requireObjectPayload {
                throw CognitiveSQLiteReadError.malformedRow(
                    table: "cognitive_artifacts",
                    id: id,
                    detail: "payload_json is not an object"
                )
            }
            return payload
        }
    }

    private static func receiptPayload(from row: Row) throws -> JSONValue {
        let id: String = row["id"] ?? "<unknown>"
        guard let raw: String = row["payload_json"] else {
            throw CognitiveSQLiteReadError.malformedRow(
                table: "cognitive_receipts",
                id: id,
                detail: "payload_json is missing"
            )
        }
        do {
            return try parseJSONStrict(raw)
        } catch {
            throw CognitiveSQLiteReadError.malformedRow(
                table: "cognitive_receipts",
                id: id,
                detail: "payload_json is not valid JSON"
            )
        }
    }

    private static func node(from row: Row) throws -> CognitiveNode {
        let rowID: String = row["id"] ?? "<unknown>"
        guard let idRaw: String = row["id"],
              let id = UUID(uuidString: idRaw),
              let kindRaw: String = row["kind"],
              let kind = CognitiveNodeKind(rawValue: kindRaw),
              let type: String = row["subject_type"],
              let subjectId: String = row["subject_id"],
              let sourceRaw: String = row["source_class"],
              let source = CognitiveSourceClass(rawValue: sourceRaw),
              let activation: Double = row["activation"],
              let salience: Double = row["salience"],
              let confidence: Double = row["confidence"],
              let createdAt: Double = row["created_at"],
              let lastActivatedAt: Double = row["last_activated_at"],
              let decayHalfLife: Double = row["decay_half_life"],
              let summary: String = row["summary"],
              let metadataRaw: String = row["metadata_json"],
              let emotionalValence: Double = row["emotional_valence"],
              let emotionalArousal: Double = row["emotional_arousal"],
              let emotionalWarmth: Double = row["emotional_warmth"] else {
            throw CognitiveSQLiteReadError.malformedRow(
                table: "cognitive_nodes",
                id: rowID,
                detail: "one or more required fields are invalid"
            )
        }
        let metadataPayload: JSONValue
        do {
            metadataPayload = try parseJSONStrict(metadataRaw)
        } catch {
            throw CognitiveSQLiteReadError.malformedRow(
                table: "cognitive_nodes",
                id: rowID,
                detail: "metadata_json is not valid JSON"
            )
        }
        guard case .object(let metadata) = metadataPayload else {
            throw CognitiveSQLiteReadError.malformedRow(
                table: "cognitive_nodes",
                id: rowID,
                detail: "metadata_json is not an object"
            )
        }
        return CognitiveNode(
            id: id,
            kind: kind,
            subjectReference: CognitiveSubjectReference(
                type: type,
                id: subjectId,
                label: row["subject_label"]
            ),
            activation: activation,
            salience: salience,
            confidence: confidence,
            sourceClass: source,
            createdAt: Date(timeIntervalSince1970: createdAt),
            lastActivatedAt: Date(timeIntervalSince1970: lastActivatedAt),
            decayHalfLife: decayHalfLife,
            summary: summary,
            metadata: metadata,
            emotionalValence: emotionalValence,
            emotionalArousal: emotionalArousal,
            emotionalWarmth: emotionalWarmth
        )
    }

    private static func parseJSONStrict(_ raw: String) throws -> JSONValue {
        try JSONValue.parse(Data(raw.utf8))
    }
}
