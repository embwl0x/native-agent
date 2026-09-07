import Foundation
import NativeAgentCore
import PersistenceCore

// MARK: - InMemoryMemoryStorage (test fixture)
//
// A trivial in-memory `MemoryStorageProtocol` for tests and any callsite that
// wants to exercise the actor before m1's SQLite-backed `MemoryStorage` lands.
// NOT for production use.
public actor InMemoryMemoryStorage: MemoryStorageProtocol, MemoryRecordLookupStorage, MomentProposalCountingStorage {
    private var records: [String: MemoryRecord] = [:]
    private var embeddings: [String: [Float]] = [:]
    private var personas: [String: String] = [:]
    private var tombstones: Set<String> = []
    private var proposals: [String: ProposalRecord] = [:]
    private var proposalEmbeddings: [String: [Float]] = [:]

    public init() {}

    func lookupMemoryRecord(id: String) async throws -> MemoryRecord? { records[id] }

    public func listMemory(kind: String?) async throws -> [MemoryRecord] {
        let all = Array(records.values)
        guard let kind else { return all }
        return all.filter { $0.memoryKind == kind || $0.layer == kind }
    }

    public func insert(record: MemoryRecord, embedding: [Float]?) async throws -> MemoryRecord {
        records[record.id] = record
        if let embedding { embeddings[record.id] = embedding }
        if let persona = record.personaId { personas[record.id] = persona }
        else { personas.removeValue(forKey: record.id) }
        return record
    }

    public func updateMemory(id: String, patch: JSONValue, newEmbedding: [Float]?) async throws -> MemoryRecord {
        guard var rec = records[id] else { throw MemoryV2Error.recordNotFound }
        if case .object(let obj) = patch {
            if case .string(let s)? = obj["text"] { rec.text = s }
            if case .string(let s)? = obj["content"] { rec.text = s }
            if case .string(let s)? = obj["status"] { rec.status = s }
            if case .double(let d)? = obj["confidence"] { rec.confidence = d }
            if case .int(let i)? = obj["confidence"] { rec.confidence = Double(i) }
            if case .string(let s)? = obj["validFrom"] { rec.validFrom = s }
            if case .string(let s)? = obj["valid_from"] { rec.validFrom = s }
            if case .string(let s)? = obj["validTo"] { rec.validTo = s }
            if case .string(let s)? = obj["valid_to"] { rec.validTo = s }
            if case .string(let s)? = obj["observed_at"] { rec.observedAt = s }
            if case .string(let s)? = obj["observedAt"] { rec.observedAt = s }
            if let evidence = obj["evidence"] { rec.evidence = evidence }
            // UNTYPED KEYS FOLLOW THE SQLITE CONTRACT, NOT A WIDER ONE.
            //
            // This fixture used to merge EVERY untyped key into `extras`, while
            // `MemoryStorageBridge` (production SQLite) merges only
            // `MemoryPatchContract.untypedPassthroughKeys` and DROPS the rest.
            // So `patch(["foo": "bar"])` persisted here and vanished there — a
            // test could pass against behaviour production does not have, which
            // is exactly how the `recall_count` no-op survived (2026-07-24).
            // The SQLite side is the contract; the allowlist is shared so the
            // two cannot drift again (gpt-5.5 review, 2026-08-02).
            let passthrough = obj.filter {
                MemoryPatchContract.untypedPassthroughKeys.contains($0.key)
            }
            if !passthrough.isEmpty {
                var meta: [String: JSONValue] = [:]
                if case .object(let m)? = rec.extras { meta = m }
                for (k, v) in passthrough { meta[k] = v }
                rec.extras = .object(meta)
                // …and surfaced back into the typed slots the same way
                // `MemoryStorageBridge.toMemoryRecord` surfaces them, so a
                // read-back through the fixture matches a read-back through
                // SQLite instead of only agreeing about storage.
                if case .bool(let b)? = passthrough["pinned"] { rec.pinned = b }
                if case .double(let d)? = passthrough["importance"] { rec.importance = d }
                if case .int(let i)? = passthrough["importance"] { rec.importance = Double(i) }
                if case .array(let arr)? = passthrough["tags"] {
                    let strings = arr.compactMap { value -> String? in
                        if case .string(let t) = value { return t } else { return nil }
                    }
                    if !strings.isEmpty { rec.tags = strings }
                }
            }
        }
        rec.updatedAt = ISO8601DateFormatter().string(from: Date())
        records[id] = rec
        if let newEmbedding { embeddings[id] = newEmbedding }
        return rec
    }

    public func deleteMemory(id: String) async throws -> Bool {
        let removed = records.removeValue(forKey: id)
        if let removed {
            tombstones.insert(Self.normalize(removed.text))
        }
        embeddings.removeValue(forKey: id)
        personas.removeValue(forKey: id)
        return removed != nil
    }

    public func recall(embedding: [Float], topK: Int, persona: String?) async throws -> [ScoredMemoryRecord] {
        var scored: [ScoredMemoryRecord] = []
        for (id, vec) in embeddings {
            if let persona, personas[id] != persona { continue }
            guard let rec = records[id] else { continue }
            let s = Self.cosine(embedding, vec)
            scored.append(ScoredMemoryRecord(record: rec, score: Double(s)))
        }
        return Array(scored.sorted { $0.score > $1.score }.prefix(max(0, topK)))
    }

    public func isTombstoned(content: String) async throws -> Bool {
        tombstones.contains(Self.normalize(content))
    }

    public func recordTombstone(content: String, reason: String?) async throws {
        _ = reason
        tombstones.insert(Self.normalize(content))
    }

    public func insertProposal(_ proposal: ProposalRecord, embedding: [Float]? = nil) async throws {
        proposals[proposal.id] = proposal
        if let embedding {
            proposalEmbeddings[proposal.id] = embedding
        } else {
            proposalEmbeddings.removeValue(forKey: proposal.id)
        }
    }

    public func getProposal(id: String) async throws -> ProposalRecord? {
        proposals[id]
    }

    public func acceptReviewedMoment(id: String, review: ReviewedMomentAcceptance) async throws -> MemoryRecord {
        guard var proposal = proposals[id], proposal.status == "pending",
              proposal.content == review.expectedContent, MemoryMoments.isMoment(proposal.metadata) else {
            throw MemoryV2Error.recordNotFound
        }
        guard !tombstones.contains(Self.normalize(review.content)) else {
            throw MemoryV2Error.underlying("tombstoned reviewed moment")
        }
        if let reason = MemoryCandidateQuality.rejectionReason(
            text: review.content, source: proposal.source, kind: MemoryMoments.kind
        ) { throw MemoryV2Error.underlying(reason) }
        let now = ISO8601DateFormatter().string(from: Date())
        let record = MemoryRecord(id: id, text: review.content, layer: "semantic",
            memoryKind: MemoryMoments.kind, createdAt: now, updatedAt: now,
            sourceRunId: proposal.source, status: "active")
        records[id] = record
        embeddings[id] = review.embedding
        proposal.status = "accepted"
        proposals[id] = proposal
        return record
    }

    public func acceptProposal(id: String) async throws -> MemoryRecord {
        guard var proposal = proposals[id] else { throw MemoryV2Error.recordNotFound }
        guard proposal.status == "pending" else {
            throw MemoryV2Error.underlying("proposal already resolved: \(id)")
        }
        let now = ISO8601DateFormatter().string(from: Date())
        let record = MemoryRecord(
            id: proposal.id,
            text: proposal.content,
            layer: "semantic",
            memoryKind: nil,
            createdAt: now,
            updatedAt: now,
            sourceRunId: proposal.source,
            status: "active"
        )
        records[record.id] = record
        if let embedding = proposalEmbeddings[id] {
            embeddings[record.id] = embedding
        }
        proposal.status = "accepted"
        proposals[id] = proposal
        return record
    }

    public func updateProposalStatus(id: String, status: String, rejectionReason: String?) async throws {
        guard var p = proposals[id] else { throw MemoryV2Error.recordNotFound }
        p.status = status
        if let rejectionReason { p.rejectionReason = rejectionReason }
        proposals[id] = p
    }

    public func updateProposalMetadata(id: String, metadata: JSONValue?) async throws -> ProposalRecord {
        guard var p = proposals[id], p.status == "pending" else {
            throw MemoryV2Error.recordNotFound
        }
        p.metadata = metadata
        proposals[id] = p
        return p
    }

    public func countMomentProposals(status: String?) async throws -> Int {
        proposals.values
            .filter { status == nil || $0.status == status }
            .filter { MemoryMoments.isMoment($0.metadata) }
            .count
    }

    public func listProposals(status: String?) async throws -> [ProposalRecord] {
        let all = Array(proposals.values)
        guard let status else { return all }
        return all.filter { $0.status == status }
    }

    private static func normalize(_ s: String) -> String {
        s.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private static func cosine(_ a: [Float], _ b: [Float]) -> Float {
        let n = min(a.count, b.count)
        guard n > 0 else { return 0 }
        var dot: Float = 0, na: Float = 0, nb: Float = 0
        for i in 0..<n {
            dot += a[i] * b[i]; na += a[i] * a[i]; nb += b[i] * b[i]
        }
        let d = sqrtf(na) * sqrtf(nb)
        return d > 0 ? dot / d : 0
    }
}

/// The warm-up-race failure class that may degrade to keyword recall: a
/// cancelled in-flight predict (transient by the runtime's own
/// classification — it deliberately does NOT evict the model on these) or an
/// empty batch from a provider that hasn't produced vectors yet. Everything
/// else — the runtime's "model unavailable, reinstall" load error, dimension
/// mismatches, provider faults — is a broken dense lane and must propagate
/// loudly, not hide behind lexical hits.
func memoryV2IsColdEmbedderFailure(_ error: Error) -> Bool {
    if error is CancellationError { return true }
    if case MemoryV2Error.underlying(let message) = error,
       message.contains("no vectors") {
        return true
    }
    return false
}
