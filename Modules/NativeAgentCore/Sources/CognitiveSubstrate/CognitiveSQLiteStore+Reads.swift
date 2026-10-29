import Foundation
import GRDB
import PersistenceCore
// Blueprint: | `CognitiveSQLiteStore+Reads.swift` | `CognitiveSQLiteStore`: `loadRestoreBundle`, `loadReceiptRecords` |

extension CognitiveSQLiteStore {
    func loadRestoreBundle(
        artifactFamilies: [CognitiveArtifactFamilyLoad]
    ) async throws -> CognitiveSQLiteRestoreBundle {
        try await dbQueue.read { db in
            var artifacts: [String: [JSONValue]] = [:]
            for family in artifactFamilies {
                artifacts[family.key] = try Self.fetchArtifacts(
                    db,
                    kindPrefix: family.kindPrefix,
                    whole: family.whole,
                    limit: family.limit
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

    public func loadReceiptRecords(limit: Int = 100) async throws -> [CognitiveReceiptRecord] {
        try await dbQueue.read { db in
            let bounded = max(0, min(limit, 500))
            let rows = try Row.fetchAll(
                db,
                sql: """
                SELECT id, kind, payload_json, created_at FROM cognitive_receipts
                ORDER BY created_at DESC, id ASC
                LIMIT ?
                """,
                arguments: [bounded]
            )
            return try rows.map { row in
                let rowID: String = try row.decode(forColumn: "id") ?? "<unknown>"
                guard let id = UUID(uuidString: rowID),
                      let kind: String = try row.decode(forColumn: "kind"),
                      let createdAt: Double = try row.decode(forColumn: "created_at"),
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
                   emotional_valence, emotional_arousal, emotional_warmth, lived_seq
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
            guard let updatedAt: Double = try row.decode(forColumn: "updated_at"), updatedAt.isFinite else {
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
        kindPrefix: String,
        whole: Bool,
        limit: Int
    ) throws -> [JSONValue] {
        // SQLite reads a negative LIMIT as none.
        let bounded = whole ? -1 : max(0, min(limit, 500))
        let rows = try Row.fetchAll(
            db,
            sql: """
            SELECT id, payload_json FROM cognitive_artifacts
            WHERE kind LIKE ?
            ORDER BY updated_at DESC, id ASC
            LIMIT ?
            """,
            arguments: [whole ? kindPrefix : "\(kindPrefix)%", bounded]
        )
        return try rows.map { row in
            let id: String = try row.decode(forColumn: "id") ?? "<unknown>"
            guard let raw: String = try row.decode(forColumn: "payload_json") else {
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
            guard case .object = payload else {
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
        let id: String = try row.decode(forColumn: "id") ?? "<unknown>"
        guard let raw: String = try row.decode(forColumn: "payload_json") else {
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
        let rowID: String = try row.decode(forColumn: "id") ?? "<unknown>"
        guard let idRaw: String = try row.decode(forColumn: "id"),
              let id = UUID(uuidString: idRaw),
              let kindRaw: String = try row.decode(forColumn: "kind"),
              let kind = CognitiveNodeKind(rawValue: kindRaw),
              let type: String = try row.decode(forColumn: "subject_type"),
              let subjectId: String = try row.decode(forColumn: "subject_id"),
              let sourceRaw: String = try row.decode(forColumn: "source_class"),
              let source = CognitiveSourceClass(rawValue: sourceRaw),
              let activation: Double = try row.decode(forColumn: "activation"),
              let salience: Double = try row.decode(forColumn: "salience"),
              let confidence: Double = try row.decode(forColumn: "confidence"),
              let createdAt: Double = try row.decode(forColumn: "created_at"),
              let lastActivatedAt: Double = try row.decode(forColumn: "last_activated_at"),
              let decayHalfLife: Double = try row.decode(forColumn: "decay_half_life"),
              let summary: String = try row.decode(forColumn: "summary"),
              let metadataRaw: String = try row.decode(forColumn: "metadata_json"),
              let emotionalValence: Double = try row.decode(forColumn: "emotional_valence"),
              let emotionalArousal: Double = try row.decode(forColumn: "emotional_arousal"),
              let emotionalWarmth: Double = try row.decode(forColumn: "emotional_warmth") else {
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
        var node = CognitiveNode(
            id: id,
            kind: kind,
            subjectReference: CognitiveSubjectReference(
                type: type,
                id: subjectId,
                label: try row.decode(forColumn: "subject_label")
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
        let lived: Int64? = try row.decode(forColumn: "lived_seq")
        node.livedSeq = lived.map { UInt64(max(0, $0)) }
        return node
    }

    private static func parseJSONStrict(_ raw: String) throws -> JSONValue {
        try JSONValue.parse(Data(raw.utf8))
    }
}
