import Foundation
import GRDB
import NativeAgentCore
import PersistenceCore
// Blueprint: | `MemoryV2+Wiring.swift` | `SwiftNativeMemoryV2`: `duplicateProvenancePatch`, `store`, `isRejected` |

// Storage-backed memory writes and duplicate provenance on SwiftNativeMemoryV2.
// Recall and proposals live in their named extensions; value and storage
// contracts live in MemoryV2Contracts.swift.

extension SwiftNativeMemoryV2 {

    // MARK: - Byte-identical collapse: keep the collapse, keep BOTH identities

    /// How many occurrences of one collapsed memory keep their provenance.
    /// Bounded because a lane that repeats forever must not grow one row's
    /// metadata forever; the oldest occurrences fall off, `recall_count` keeps
    /// counting past the cap.
    static let duplicateProvenanceCap = 10

    /// Metadata keys that are POLICY or shape, not the identity of a
    /// particular occurrence. Merging these would just restate the row.
    static let duplicateProvenanceIgnoredKeys: Set<String> = [
        "kind", "permittedSurfaces", "tags", "recall_count", "confidence",
        "importance", "pinned", "source_history", "duplicate_occurrences",
    ]

    /// Byte-identical writes merge provenance so repeats remain traceable to both runs.
    ///
    /// Pure, and deliberately generic: it merges whatever scalar metadata the
    /// new write carries that the row does not already say, plus the new
    /// source, plus the newer observation time. Nothing here knows about
    /// Workshop-specific identity fields.
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

        // 1. Source lineage — every distinct writer of this text, oldest first,
        //    seeded from the row's own `source` so run #1 is never implied away.
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

        // 2. This occurrence's identity: the scalar metadata it carries that the
        //    row does not already say, plus its source.
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
            // A literal re-write of the SAME occurrence (same ids, same times)
            // is a retry, not a second run — count it, don't list it twice.
            if occurrences.last != entry {
                occurrences.append(entry)
                if occurrences.count > duplicateProvenanceCap {
                    occurrences = Array(occurrences.suffix(duplicateProvenanceCap))
                }
                out["duplicate_occurrences"] = .array(occurrences)
            }
        }

        // 3. Observation time: when the newest evidence was observed, not a
        //    new assertion of present validity.
        //    First-class column (`observed_at` maps to observedAt);
        //    only ever moves FORWARD by instant, never by ISO string order:
        //    offsets and fractional seconds need not sort chronologically.
        //    Match new-record alias precedence; an explicit malformed value
        //    must not overwrite canonical observation time.
        var observedAt: String?
        if case .string(let value)? = newMeta["observed_at"] { observedAt = value }
        if case .string(let value)? = newMeta["observedAt"] { observedAt = value }
        if let raw = observedAt,
           let observed = MemoryRecallScoring.parseTimestamp(raw) {
            let current = existing.observedAt.flatMap(MemoryRecallScoring.parseTimestamp)
            if current.map({ observed > $0 }) ?? true {
                out["observed_at"] = .string(raw)
            }
        }
        return out
    }

    /// True when `store` would refuse this content as tombstoned — the exact
    /// denylist hash or a paraphrase of a rejected claim. A caller retrying a
    /// lost write asks first: a rejected claim is settled, not lost.
    public func isTombstoned(content: String, metadata: JSONValue? = nil) async throws -> Bool {
        let metadata = try MemorySenseProvenance.stamping(metadata)
        let content = MemoryTextClip.memoryDisplayText(content, kind: MemoryRecallScoring.kind(of: metadata))
        guard !content.isEmpty else { return false }
        try await ensureCanonicalAttachment()
        guard let storage else { throw MemoryV2Error.storageUnavailable }
        if try await storage.isTombstoned(content: content) { return true }
        // A cold model leaves the paraphrase check to the owed-vector fill.
        guard let embedded = try await residentWriteEmbedding(content) else { return false }
        return try await storage.matchesTombstone(embedding: embedded.vector, embeddingEpoch: embedded.epoch)
    }

    /// The forgotten or rejected claims nearest `text`, closest first, by the
    /// recall query's own embedding: what the memory manager is shown so a
    /// restated forgotten claim is its judgment to skip.
    public func forgottenClaims(near text: String, limit: Int) async throws -> [String] {
        guard !text.isEmpty, limit > 0 else { return [] }
        try await ensureCanonicalAttachment()
        guard let storage else { throw MemoryV2Error.storageUnavailable }
        let embedded = try await embedQueriesWithEpoch([text])
        guard let vector = embedded.vectors.first else { return [] }
        return try await storage.nearestTombstones(embedding: vector, embeddingEpoch: embedded.epoch, limit: limit)
    }

    /// Store a new memory. `memory_tombstoned` refuses forgotten or rejected
    /// content. Cold writes owe admission until their search vector is ready.
    public func store(
        content: String,
        source: String? = nil,
        metadata: JSONValue? = nil,
        supersedes: [String] = [],
        corrects: String? = nil,
        correctionReason: String? = nil,
        id: String? = nil
    ) async throws -> MemoryRecord {
        let metadata = MemoryDataProvenance.stamping(try MemorySenseProvenance.stamping(metadata))
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
            if case .string(let value)? = metaObj["validFrom"] { liftedValidFrom = value }
            if case .string(let value)? = metaObj["valid_to"] { liftedValidTo = value }
            if case .string(let value)? = metaObj["validTo"] { liftedValidTo = value }
            if case .string(let value)? = metaObj["observed_at"] { liftedObservedAt = value }
            if case .string(let value)? = metaObj["observedAt"] { liftedObservedAt = value }
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
            // MemoryKindStamp preserves supplied kinds or defaults to "general" without decay or supersession.
            // Dates are supplied by the writer, never inferred from content.
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
        // Explicit correction uses the same fingerprinted replacement intent
        // as supersession, including admission owed by a cold write. An exact
        // reassertion of its own target remains a duplicate, never a demotion.
        if let corrects, !supersedes.contains(corrects),
           let target = existingRows.first(where: {
               $0.id == corrects && $0.status == "active" && MemoryLifecycle.isRecallEligible($0.lifecycle)
           }), MemoryStorage.comparisonKey(target.content, mode: .canonical) != MemoryStorage.comparisonKey(content, mode: .canonical) {
            superseding.append(SupersedingAcceptance(
                targetId: corrects, expectedContentHash: MemoryStorage.contentHash(target.content),
                reason: correctionReason ?? "explicit correction"))
        }
        if superseding.isEmpty {
            // Reassert exact duplicates before paying for an embedding. The
            // final admission repeats matching under its insertion transaction.
            if let existing = try await storage.admitMemory(
                record,
                insertIfMissing: false, preserveID: id != nil
            ) {
                return MemoryRecord(stored: existing)
            }
        }
        // The write transaction checks this vector against forgotten claims.
        // A cold model owes the vector; its landing passes the same gate.
        let embedded = try await residentWriteEmbedding(content)
        var admitted = record
        if embedded == nil {
            // Saved, admitted only when its vector lands and passes the checks
            // (under its own id when the caller owns it or explicitly
            // supersedes). Corrections retain ordinary duplicate admission.
            admitted.metadata = MemoryStorage.owingAdmission(record.metadata, preservingID: id != nil || !supersedes.isEmpty,
                                                           superseding: superseding)
        }
        admitted.embedding = embedded?.vector
        admitted.embeddingEpoch = embedded?.epoch.rawValue
        let inserted: StoredMemory
        if !supersedes.isEmpty || (embedded == nil && !superseding.isEmpty) {
            inserted = try await storage.insertMemory(admitted, superseding: embedded == nil ? [] : superseding)
        } else {
            guard let saved = try await storage.admitMemory(
                    admitted,
                    insertIfMissing: true, preserveID: id != nil,
                    superseding: embedded == nil ? [] : superseding) else { throw MemoryV2Error.storageUnavailable }
            inserted = saved
        }
        let result = MemoryRecord(stored: inserted)
        return embedded == nil ? owedVector(result) : result
    }

    /// Convenience tombstone check used by upstream filters (e.g. the chat-fact
    /// promoter) before calling `store(...)`.
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
