import CryptoKit
import Foundation
import GRDB
import PersistenceCore

// Blueprint: | `ContextSQLiteCodecs.swift` | `ContextSQLiteStore` persisted atom payloads, row decoding, JSON dates and vector bytes |

extension ContextSQLiteStore {
    struct PersistedAtomPayload: Codable {
        let id: ContextAtomID
        let sourceID: ContextSourceID
        let kind: ContextAtomKind
        let headingPath: [String]
        let sourceRange: ContextSourceRange
        let sourceHash: String
        let authority: ContextAuthority
        let confidence: Double
        let freshness: ContextFreshness
        let privacy: ContextPrivacy
        let permittedSurfaces: Set<ContextSurface>
        let injectionPolicy: ContextInjectionPolicy
        let contentRole: ContextContentRole
        let entities: [ContextEntity]
        let triggers: [String]
        let activation: Double
        let recentUsefulness: Double
        let decayState: Double

        init(atom: ContextAtomDraft) {
            id = atom.id
            sourceID = atom.sourceID
            kind = atom.kind
            headingPath = atom.headingPath
            sourceRange = atom.sourceRange
            sourceHash = atom.sourceHash
            authority = atom.authority
            confidence = atom.confidence
            freshness = atom.freshness
            privacy = atom.privacy
            permittedSurfaces = atom.permittedSurfaces
            injectionPolicy = atom.injectionPolicy
            contentRole = atom.contentRole
            entities = atom.entities
            triggers = atom.triggers
            activation = atom.activation
            recentUsefulness = atom.recentUsefulness
            decayState = atom.decayState
        }
    }

    static func decodeSource(_ row: Row) throws -> ContextStoredSource {
        guard let descriptorJSON: String = row["descriptor_json"],
              let sourceHash: String = row["source_hash"],
              let healthRaw: String = row["health"],
              let health = ContextSourceHealth(rawValue: healthRaw),
              let validFrom: Int64 = row["valid_from_generation"] else {
            throw ContextFlowStoreError.malformedStoredValue("source")
        }
        let descriptor: ContextSourceDescriptor = try decodeJSON(descriptorJSON)
        let validTo: Int64? = row["valid_to_generation"]
        let lastError: String? = row["last_error"]
        return ContextStoredSource(
            descriptor: descriptor,
            sourceHash: sourceHash,
            health: health,
            lastError: lastError,
            validFromGeneration: validFrom,
            validToGeneration: validTo
        )
    }

    static func decodeAtom(_ row: Row) throws -> ContextStoredAtom {
        guard let versionKey: String = row["version_key"],
              let body: String = row["body"],
              let payloadJSON: String = row["payload_json"],
              let validFrom: Int64 = row["valid_from_generation"] else {
            throw ContextFlowStoreError.malformedStoredValue("atom")
        }
        let payload: PersistedAtomPayload = try decodeJSON(payloadJSON)
        let summary: String? = row["summary"]
        let validTo: Int64? = row["valid_to_generation"]
        let modelFingerprint: String? = row["model_fingerprint"]
        let dimensions: Int? = row["dimensions"]
        let vectorData: Data? = row["vector"]
        let embedding: ContextEmbedding?
        if let modelFingerprint, let dimensions, let vectorData {
            let values = try decodeVector(vectorData, expectedCount: dimensions)
            embedding = ContextEmbedding(modelFingerprint: modelFingerprint, values: values)
        } else {
            embedding = nil
        }
        let draft = ContextAtomDraft(
            id: payload.id,
            sourceID: payload.sourceID,
            kind: payload.kind,
            headingPath: payload.headingPath,
            sourceRange: payload.sourceRange,
            sourceHash: payload.sourceHash,
            body: body,
            deterministicSummary: summary,
            authority: payload.authority,
            confidence: payload.confidence,
            freshness: payload.freshness,
            privacy: payload.privacy,
            permittedSurfaces: payload.permittedSurfaces,
            injectionPolicy: payload.injectionPolicy,
            contentRole: payload.contentRole,
            entities: payload.entities,
            triggers: payload.triggers,
            activation: payload.activation,
            recentUsefulness: payload.recentUsefulness,
            decayState: payload.decayState,
            embedding: embedding
        )
        return ContextStoredAtom(
            versionKey: versionKey,
            draft: draft,
            validFromGeneration: validFrom,
            validToGeneration: validTo
        )
    }

    static func decodeRelationship(_ row: Row) throws -> ContextStoredRelationship {
        guard let versionKey: String = row["version_key"],
              let payloadJSON: String = row["payload_json"],
              let validFrom: Int64 = row["valid_from_generation"] else {
            throw ContextFlowStoreError.malformedStoredValue("relationship")
        }
        let draft: ContextRelationshipDraft = try decodeJSON(payloadJSON)
        let validTo: Int64? = row["valid_to_generation"]
        return ContextStoredRelationship(
            versionKey: versionKey,
            draft: draft,
            validFromGeneration: validFrom,
            validToGeneration: validTo
        )
    }

    static func decodeFeedbackEvent(_ row: Row) throws -> ContextFeedbackEvent {
        guard let id: String = row["id"],
              let atomIDsJSON: String = row["atom_ids_json"],
              let signalJSON: String = row["signal_json"],
              let timeBucket: Int64 = row["time_bucket"],
              let evidenceIDsJSON: String = row["evidence_ids_json"] else {
            throw ContextFlowStoreError.malformedStoredValue("feedback_event")
        }
        return ContextFeedbackEvent(
            id: id,
            atomIDs: try decodeJSON(atomIDsJSON),
            signal: try decodeJSON(signalJSON),
            timeBucket: timeBucket,
            evidenceIDs: try decodeJSON(evidenceIDsJSON),
            sessionID: try row.decode(forColumn: "session_id"),
            historyMessageFingerprint: try row.decode(forColumn: "history_message_fingerprint")
        )
    }

    static func encodeJSON<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return String(decoding: try encoder.encode(value), as: UTF8.self)
    }

    private static func decodeJSON<T: Decodable>(_ string: String) throws -> T {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return try decoder.decode(T.self, from: Data(string.utf8))
    }

    static func encodeVector(_ values: [Float]) -> Data {
        values.withUnsafeBufferPointer { Data(buffer: $0) }
    }

    private static func decodeVector(_ data: Data, expectedCount: Int) throws -> [Float] {
        guard expectedCount >= 0,
              data.count % MemoryLayout<Float>.stride == 0,
              expectedCount == data.count / MemoryLayout<Float>.stride else {
            throw ContextFlowStoreError.malformedStoredValue("embedding")
        }
        var values = [Float](repeating: 0, count: expectedCount)
        _ = values.withUnsafeMutableBytes { destination in
            data.copyBytes(to: destination)
        }
        return values
    }
}
