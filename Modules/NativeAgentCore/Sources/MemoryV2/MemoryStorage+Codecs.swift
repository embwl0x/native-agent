import Foundation
import NativeAgentShared
import GRDB
import NativeAgentCore
import PersistenceCore
// Blueprint: | `MemoryStorage+Codecs.swift` | `MemoryStorage`: `validateTemporalEvidence`, `contentHash` |

extension MemoryStorage {
    static func validateTemporalEvidence(_ memory: StoredMemory) throws {
        try validateTemporalEvidence(id: memory.id, validFrom: memory.validFrom,
            validTo: memory.validTo, observedAt: memory.observedAt)
    }

    static func validateTemporalEvidence(id: String, validFrom: String?, validTo: String?, observedAt: String?) throws {
        func parsed(_ label: String, _ value: String?) throws -> Date? {
            guard let value else { return nil }
            guard let date = MemoryRecallScoring.parseTimestamp(value) else {
                throw MemoryStorageError.invalidTemporalEvidence("Memory \(id): \(label) is not ISO-8601")
            }
            return date
        }
        let validFrom = try parsed("valid_from", validFrom)
        let validTo = try parsed("valid_to", validTo)
        _ = try parsed("observed_at", observedAt)
        if let validFrom, let validTo, validTo < validFrom {
            throw MemoryStorageError.invalidTemporalEvidence("valid_to precedes valid_from")
        }
    }

    // MARK: - Helpers

    static func contentFingerprint(_ content: String) -> String {
        SHA256Hex.of(utf8: content)
    }

    public static func contentHash(_ s: String) -> String {
        let normalized = comparisonKey(s, mode: .recall)
        return SHA256Hex.of(Data(normalized.utf8))
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

    static func decodeEmbedding(_ data: Data?) throws -> [Float]? {
        guard let data else { return nil }
        guard !data.isEmpty, data.count % 4 == 0 else {
            throw MemoryStorageError.databaseUnavailable("""
                Stored embedding has invalid byte length \(data.count); repair the canonical vector before semantic use.
                """)
        }
        let count = data.count / 4
        var out = [Float](); out.reserveCapacity(count)
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            let base = raw.bindMemory(to: UInt32.self)
            for i in 0..<count {
                out.append(Float(bitPattern: UInt32(littleEndian: base[i])))
            }
        }
        guard out.allSatisfy(\.isFinite) else {
            throw MemoryStorageError.databaseUnavailable("Stored embedding contains a non-finite value; repair the canonical vector before semantic use.")
        }
        return out
    }

    static func encodeMetadata(_ m: JSONValue?) throws -> String? {
        guard let m else { return nil }
        let enc = JSONEncoder()
        return String(decoding: try enc.encode(m), as: UTF8.self)
    }

    static func decodeMetadata(_ s: String?) throws -> JSONValue? {
        guard let s else { return nil }
        return try JSONDecoder().decode(JSONValue.self, from: Data(s.utf8))
    }

    static func decodeMemory(_ row: Row) throws -> StoredMemory {
        var memory = try decodeMemoryProjection(row)
        memory.embedding = try decodeEmbedding(row.decode(forColumn: "embedding"))
        memory.embeddingEpoch = try row.decode(forColumn: "embedding_epoch")
        memory.useCount = try row.decode(forColumn: "use_count") ?? 0
        memory.lastUsedAt = try row.decode(forColumn: "last_used_at")
        return memory
    }

    /// Outward records and person facts consume canonical content and evidence without loading semantic vectors or recall usage.
    static let memoryProjectionColumns = """
        id, content, persona_id, source, confidence, created_at, updated_at, status, lifecycle,
        valid_from, valid_to, observed_at, evidence_json, metadata_json
        """

    static func decodeMemoryProjection(_ row: Row) throws -> StoredMemory {
        let memory = try StoredMemory(
            id: row.decode(forColumn: "id"),
            content: row.decode(forColumn: "content"),
            personaId: row.decode(forColumn: "persona_id"),
            source: row.decode(forColumn: "source"),
            confidence: row.decode(forColumn: "confidence") ?? 1.0,
            createdAt: row.decode(forColumn: "created_at"),
            updatedAt: row.decode(forColumn: "updated_at"),
            status: row.decode(forColumn: "status"),
            lifecycle: row.decode(forColumn: "lifecycle") ?? MemoryLifecycle.confirmed,
            validFrom: row.decode(forColumn: "valid_from"),
            validTo: row.decode(forColumn: "valid_to"),
            observedAt: row.decode(forColumn: "observed_at"),
            evidence: decodeMetadata(row.decode(forColumn: "evidence_json")),
            metadata: decodeMetadata(row.decode(forColumn: "metadata_json"))
        )
        do { try validateTemporalEvidence(memory) }
        catch { throw MemoryStorageError.databaseUnavailable("""
            Memory \(memory.id) has unreadable temporal evidence: \(error.localizedDescription). Repair the saved row before recall.
            """) }
        try requireRoots(memory.metadata, of: "Memory \(memory.id)")
        return memory
    }

    /// Every stored memory and proposal holds readable roots; unreadable provenance requires repair before the store opens.
    static func requireRoots(_ metadata: JSONValue?, of row: String) throws {
        do { _ = try MemoryRoot.roots(in: metadata) }
        catch { throw MemoryStorageError.databaseUnavailable("\(row) has unreadable roots: \(error.localizedDescription). Repair the saved row.") }
    }

    static func decodeProposal(_ row: Row) throws -> StoredProposal {
        let proposal = try StoredProposal(
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
        try requireRoots(proposal.metadata, of: "Proposal \(proposal.id)")
        return proposal
    }
}
