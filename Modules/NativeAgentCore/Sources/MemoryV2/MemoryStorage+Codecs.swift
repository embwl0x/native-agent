import CryptoKit
import Foundation
import GRDB
import NativeAgentCore
import PersistenceCore

extension MemoryStorage {
    static func validateTemporalEvidence(_ memory: StoredMemory) throws {
        func parsed(_ label: String, _ value: String?) throws -> Date? {
            guard let value else { return nil }
            guard let date = MemoryRecallScoring.parseTimestamp(value) else {
                throw MemoryStorageError.invalidTemporalEvidence("\(label) is not ISO-8601")
            }
            return date
        }
        let validFrom = try parsed("valid_from", memory.validFrom)
        let validTo = try parsed("valid_to", memory.validTo)
        _ = try parsed("observed_at", memory.observedAt)
        if let validFrom, let validTo, validTo < validFrom {
            throw MemoryStorageError.invalidTemporalEvidence("valid_to precedes valid_from")
        }
    }

    // MARK: - Helpers

    public static func contentHash(_ s: String) -> String {
        let normalized = s.lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        let digest = SHA256.hash(data: Data(normalized.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    public static func nowISO8601() -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.string(from: Date())
    }

    static func l2norm(_ v: [Float]) -> Float {
        var s: Float = 0
        for x in v { s += x * x }
        return s.squareRoot()
    }

    static func metadataString(
        _ object: [String: JSONValue],
        _ key: String,
        fallback: String
    ) -> String? {
        if case .string(let value)? = object[key] { return value }
        if case .string(let value)? = object[fallback] { return value }
        return nil
    }

    static func encodeEmbedding(_ e: [Float]?) -> Data? {
        guard let e else { return nil }
        var out = Data(capacity: e.count * 4)
        for f in e {
            var le = f.bitPattern.littleEndian
            withUnsafeBytes(of: &le) { out.append(contentsOf: $0) }
        }
        return out
    }

    static func decodeEmbedding(_ data: Data?) -> [Float]? {
        guard let data, data.count % 4 == 0 else { return nil }
        let count = data.count / 4
        var out = [Float](); out.reserveCapacity(count)
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            let base = raw.bindMemory(to: UInt32.self)
            for i in 0..<count {
                out.append(Float(bitPattern: UInt32(littleEndian: base[i])))
            }
        }
        return out
    }

    static func encodeMetadata(_ m: JSONValue?) -> String? {
        guard let m else { return nil }
        let enc = JSONEncoder()
        guard let data = try? enc.encode(m), let s = String(data: data, encoding: .utf8) else { return nil }
        return s
    }

    private static func decodeMetadata(_ s: String?) -> JSONValue? {
        guard let s, let data = s.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(JSONValue.self, from: data)
    }

    static func decodeMemory(_ row: Row) throws -> StoredMemory {
        try StoredMemory(
            id: row.decode(forColumn: "id"),
            content: row.decode(forColumn: "content"),
            personaId: row.decode(forColumn: "persona_id"),
            source: row.decode(forColumn: "source"),
            confidence: row.decode(forColumn: "confidence") ?? 1.0,
            createdAt: row.decode(forColumn: "created_at"),
            updatedAt: row.decode(forColumn: "updated_at"),
            embedding: decodeEmbedding(row.decode(forColumn: "embedding")),
            embeddingEpoch: row.decode(forColumn: "embedding_epoch"),
            status: row.decode(forColumn: "status"),
            lifecycle: row.decode(forColumn: "lifecycle") ?? MemoryLifecycle.confirmed,
            validFrom: row.decode(forColumn: "valid_from"),
            validTo: row.decode(forColumn: "valid_to"),
            observedAt: row.decode(forColumn: "observed_at"),
            evidence: decodeMetadata(row.decode(forColumn: "evidence_json")),
            metadata: decodeMetadata(row.decode(forColumn: "metadata_json")),
            useCount: row.decode(forColumn: "use_count") ?? 0,
            lastUsedAt: row.decode(forColumn: "last_used_at")
        )
    }

    static func decodeProposal(_ row: Row) throws -> StoredProposal {
        try StoredProposal(
            id: row.decode(forColumn: "id"),
            content: row.decode(forColumn: "content"),
            personaId: row.decode(forColumn: "persona_id"),
            source: row.decode(forColumn: "source"),
            stagedAt: row.decode(forColumn: "staged_at"),
            status: row.decode(forColumn: "status"),
            resolvedAt: row.decode(forColumn: "resolved_at"),
            rejectionReason: row.decode(forColumn: "rejection_reason"),
            embedding: decodeEmbedding(row.decode(forColumn: "embedding")),
            embeddingEpoch: row.decode(forColumn: "embedding_epoch"),
            metadata: decodeMetadata(row.decode(forColumn: "metadata_json"))
        )
    }
}
