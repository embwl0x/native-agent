import Foundation
import GRDB
import NativeAgentCore
import PersistenceCore
// Blueprint: | `MemoryV2+Wiring.swift` | `SwiftNativeMemoryV2`: `duplicateProvenancePatch`, `store`, `isRejected` |


extension SwiftNativeMemoryV2 {

    // MARK: - Byte-identical collapse: keep the collapse, keep BOTH identities

    /// Bound duplicate previews so repeats cannot grow metadata forever. recall_count continues past the cap; correction totals use canonical
    /// correction_occurrences only.
    static let duplicateProvenanceCap = 10

    /// Policy and shape keys cannot identify a distinct occurrence.
    static let duplicateProvenanceIgnoredKeys: Set<String> = [
        "kind", "permittedSurfaces", "tags", "recall_count", "confidence",
        "importance", "pinned", "source_history", "duplicate_occurrences",
    ]

    /// Merge scalar occurrence metadata, source and newer observation time generically so byte-identical repeats retain both origins.
    static func duplicateProvenancePatch(
        existing: MemoryRecord,
        newSource: String?,
        newMetadata: JSONValue?
    ) -> [String: JSONValue] {
        func scalar(_ value: JSONValue) -> JSONValue? {
            switch value {
            case .string(let s): return .string(String(s.prefix(200)))
            case .int, .double, .bool: return value
            default: return nil
            }
        }
        var extras: [String: JSONValue] = [:]
        if case .object(let m)? = existing.extras { extras = m }
        var newMeta: [String: JSONValue] = [:]
        if case .object(let m)? = newMetadata { newMeta = m }
        let source = (newSource ?? "").trimmingCharacters(in: .whitespacesAndNewlines)

        var out = MemorySenseProvenance.merging(existing: existing.extras, incoming: newMetadata)
        out.merge(MemoryDataProvenance.merging(existing: existing.extras, incoming: newMetadata)) { _, value in value }
        var peerSources: [JSONValue] = []
        for metadata in [extras, newMeta] {
            if case .array(let values)? = metadata["peer_data_sources"] {
                for value in values where !peerSources.contains(value) { peerSources.append(value) }
            }
        }
        if !peerSources.isEmpty { out["peer_data_sources"] = .array(peerSources) }

        // Seed source lineage from the row's own source so its first writer cannot disappear.
        var sources: [String] = []
        if case .array(let arr)? = extras["source_history"] {
            sources = arr.compactMap { if case .string(let s) = $0 { return s } else { return nil } }
        }
        if sources.isEmpty, let first = existing.sourceRunId, !first.isEmpty {
            sources = [first]
        }
        if !source.isEmpty, !sources.contains(source) {
            sources.append(source)
        }
        if sources.count > duplicateProvenanceCap {
            sources = Array(sources.suffix(duplicateProvenanceCap))
        }
        if !sources.isEmpty {
            out["source_history"] = .array(sources.map { .string($0) })
        }

        // Carry source and new scalar metadata as this occurrence's identity.
        var identity: [String: JSONValue] = [:]
        for (key, value) in newMeta where !duplicateProvenanceIgnoredKeys.contains(key) {
            guard let value = scalar(value) else { continue }
            if extras[key] == value { continue }
            identity[key] = value
        }
        if !source.isEmpty { identity["source"] = .string(source) }
        if !identity.isEmpty {
            var occurrences: [JSONValue] = []
            if case .array(let arr)? = extras["duplicate_occurrences"] { occurrences = arr }
            let entry = JSONValue.object(identity)
            // Identical occurrence IDs and times mean retry: count it without listing a second run.
            if occurrences.last != entry {
                occurrences.append(entry)
                if occurrences.count > duplicateProvenanceCap {
                    occurrences = Array(occurrences.suffix(duplicateProvenanceCap))
                }
                out["duplicate_occurrences"] = .array(occurrences)
            }
        }

        // Move observed_at forward by instant, never ISO string order; offsets and fractional seconds can sort differently. Malformed supplied time cannot
        // overwrite canonical evidence.
        var observedAt: String?
        if case .string(let value)? = newMeta["observed_at"] { observedAt = value }
        if let raw = observedAt,
           let observed = MemoryRecallScoring.parseTimestamp(raw) {
            let current = existing.observedAt.flatMap(MemoryRecallScoring.parseTimestamp)
            if current.map({ observed > $0 }) ?? true {
                out["observed_at"] = .string(raw)
            }
        }
        return out
    }

    /// Check tombstones before retrying an uncertain write: rejected claims are settled rather than lost.
    public func isTombstoned(content: String, metadata: JSONValue? = nil) async throws -> Bool {
        let content = MemoryTextClip.memoryDisplayText(content, kind: MemoryRecallScoring.kind(of: metadata))
        guard !content.isEmpty else { return false }
        try await ensureCanonicalAttachment()
        guard let storage else { throw MemoryV2Error.storageUnavailable }
        if try await storage.isTombstoned(content: content) { return true }
        // A cold model leaves the paraphrase check to the owed-vector fill.
        guard let embedded = try await residentWriteEmbedding(content) else { return false }
        return try await storage.matchesTombstone(content: content, embedding: embedded.vector, embeddingEpoch: embedded.epoch)
    }

    /// Show nearest forgotten claims under the recall embedding so the manager judges restated denials.
    public func forgottenClaims(near text: String, limit: Int) async throws -> [String] {
        guard !text.isEmpty, limit > 0 else { return [] }
        try await ensureCanonicalAttachment()
        guard let storage else { throw MemoryV2Error.storageUnavailable }
        let embedded = try await embedQueriesWithEpoch([text])
        guard let vector = embedded.vectors.first else { return [] }
        return try await storage.nearestTombstones(embedding: vector, embeddingEpoch: embedded.epoch, limit: limit)
    }

    /// Tombstones refuse forgotten claims; cold writes stay unadmitted until their vector is ready.
    public func store(
        content: String,
        source: String? = nil,
        metadata: JSONValue? = nil,
        supersedes: [String] = [],
        corrects: String? = nil,
        correctionReason: String? = nil,
        id: String? = nil,
        context: MemoryWriteContext
    ) async throws -> MemoryRecord {
        let metadata = try context.stamping(metadata)
        let content = MemoryTextClip.memoryDisplayText(
            content,
            kind: MemoryRecallScoring.kind(of: metadata)
        )
        guard !content.isEmpty else { throw MemoryV2Error.invalidQuery }
        if let reason = MemoryCandidateQuality.rejectionReason(
            text: content,
            source: source,
            kind: MemoryRecallScoring.kind(of: metadata)
        ) {
            throw MemoryV2Error.rejectedCandidate(reason)
        }
        try await ensureCanonicalAttachment()
        guard let storage else { throw MemoryV2Error.storageUnavailable }
        if try await storage.isTombstoned(content: content) {
            throw MemoryV2Error.forgottenContent("Content matches a forgotten or rejected memory.")
        }
        let now = Self.iso8601Now()
        var liftedConfidence: Double?
        var liftedValidFrom: String?
        var liftedValidTo: String?
        var liftedObservedAt: String?
        var liftedEvidence: JSONValue?
        if case .object(let metaObj)? = metadata {
            if case .double(let c)? = metaObj["confidence"] { liftedConfidence = c }
            if case .string(let value)? = metaObj["valid_from"] { liftedValidFrom = value }
            if case .string(let value)? = metaObj["valid_to"] { liftedValidTo = value }
            if case .string(let value)? = metaObj["observed_at"] { liftedObservedAt = value }
            liftedEvidence = metaObj["evidence"]
        }
        let record = StoredMemory(
            // A caller-owned id preserves one lesson origin per proposal and rejects racing inserts on the primary key.
            id: id ?? UUID().uuidString,
            content: content,
            personaId: MemoryV2Defaults.personaID,
            source: source,
            confidence: liftedConfidence ?? 1,
            createdAt: now,
            updatedAt: now,
            validFrom: liftedValidFrom,
            validTo: liftedValidTo,
            observedAt: liftedObservedAt,
            evidence: liftedEvidence,
            // MemoryKindStamp preserves supplied kinds or defaults to "general" without decay or supersession. Dates are supplied by the writer, never inferred
            // from content.
            metadata: MemoryKindStamp.stampingDefaultKind(metadata)
        )
        let targetIDs = Set(supersedes + [corrects].compactMap { $0 })
        let existingRows = try await storage.memories(ids: Array(targetIDs))
        var superseding = try Set(supersedes).sorted().map { id in
            guard let row = existingRows.first(where: {
                $0.id == id && $0.status == "active"
                    && MemoryLifecycle.isRecallEligible($0.lifecycle)
            }) else {
                throw MemoryV2Error.staleSupersession("Memory to supersede is missing or no longer active: \(id)")
            }
            return SupersedingAcceptance(
                targetId: id, expectedContentHash: MemoryStorage.contentHash(row.content),
                reason: "explicit supersession")
        }
        // Share fingerprinted replacement intent with supersession, including cold admission; reasserting the exact target is duplicate evidence, never
        // demotion.
        if let corrects, !supersedes.contains(corrects),
           let target = existingRows.first(where: {
               $0.id == corrects && $0.status == "active" && MemoryLifecycle.isRecallEligible($0.lifecycle)
           }), MemoryStorage.comparisonKey(target.content, mode: .canonical) != MemoryStorage.comparisonKey(content, mode: .canonical) {
            superseding.append(SupersedingAcceptance(
                targetId: corrects, expectedContentHash: MemoryStorage.contentHash(target.content),
                reason: correctionReason ?? "explicit correction"))
        }
        if superseding.isEmpty {
            // Reassert exact duplicates before paying for an embedding. The final admission repeats matching under its insertion transaction.
            if let existing = try await storage.admitMemory(
                record,
                insertIfMissing: false, preserveID: id != nil, context: context
            ) {
                return MemoryRecord(stored: existing)
            }
        }
        // The write transaction checks this vector against forgotten claims. A cold model owes the vector; its landing passes the same gate.
        let embedded = try await residentWriteEmbedding(content)
        var admitted = record
        if embedded == nil {
            // Cold admission preserves caller-owned or replacement identity; corrections still use ordinary duplicate checks.
            admitted.metadata = MemoryStorage.owingAdmission(record.metadata, preservingID: id != nil || !supersedes.isEmpty,
                                                           superseding: superseding)
        }
        admitted.embedding = embedded?.vector
        admitted.embeddingEpoch = embedded?.epoch.rawValue
        let inserted: StoredMemory
        if !supersedes.isEmpty || (embedded == nil && !superseding.isEmpty) {
            inserted = try await storage.insertMemory(admitted, superseding: embedded == nil ? [] : superseding, context: context)
        } else {
            guard let saved = try await storage.admitMemory(
                    admitted,
                    insertIfMissing: true, preserveID: id != nil,
                    superseding: embedded == nil ? [] : superseding, context: context) else { throw MemoryV2Error.storageUnavailable }
            inserted = saved
        }
        let result = MemoryRecord(stored: inserted)
        return embedded == nil ? owedVector(result) : result
    }

    /// Upstream filters share the store's tombstone decision.
    public func isRejected(content: String) async throws -> Bool {
        try await ensureCanonicalAttachment()
        guard let storage else { throw MemoryV2Error.storageUnavailable }
        return try await storage.isTombstoned(content: content)
    }

    // MARK: - utilities

    static func iso8601Now() -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f.string(from: Date())
    }

}
