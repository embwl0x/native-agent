import Foundation
import GRDB
import NativeAgentCore
import PersistenceCore
// Blueprint: | `MemoryV2+Wiring.swift` | `SwiftNativeMemoryV2`: `duplicateProvenancePatch`, `store`, `isRejected` |

extension MemoryStorage {
    /// Both retelling lanes merge evidence against the row under its write lock.
    func recordRetelling(id: String, pending: Bool, source: String, metadata: [String: JSONValue]) async throws {
        let incoming = pending ? JSONValue.object(metadata)
            : MemoryDataProvenance.stamping(try MemorySenseProvenance.stamping(.object(metadata)))
        let updated = try await dbPool.write { db -> StoredMemory? in
            func merge(_ current: MemoryRecord) throws -> (metadata: [String: JSONValue], observedAt: String?) {
                var patch = SwiftNativeMemoryV2.duplicateProvenancePatch(
                    existing: current, newSource: source, newMetadata: incoming)
                let count: Int64?
                if case .object(let fields)? = current.extras, case .int(let value)? = fields["recall_count"] {
                    count = value
                } else {
                    count = Int64(exactly: (MemoryMoments.metadataNumber(current.extras, "recall_count") ?? 0).rounded(.towardZero))
                }
                guard let count, count < Int64.max else {
                    throw MemoryStorageError.databaseUnavailable("retelling: recall_count is outside incrementable Int64 range")
                }
                patch["recall_count"] = .int(count + 1)
                let observed: String? = if case .string(let value)? = patch["observed_at"] { value } else { nil }
                if !pending { patch["observed_at"] = nil }
                var merged: [String: JSONValue] = [:]
                if case .object(let existing)? = current.extras { merged = existing }
                merged.merge(patch) { _, new in new }
                return (merged, observed)
            }
            if pending {
                guard let row = try Row.fetchOne(db, sql: """
                    SELECT * FROM proposals WHERE id = ? AND status IN ('pending', 'superseded')
                    """, arguments: [id]).map(Self.decodeProposal) else { return nil }
                let current = MemoryRecord(id: row.id, text: row.content, createdAt: row.stagedAt,
                                           sourceRunId: row.source, extras: row.metadata)
                let merged = try merge(current)
                try db.execute(sql: "UPDATE proposals SET metadata_json = ? WHERE id = ?",
                               arguments: [Self.encodeMetadata(.object(merged.metadata)), id])
                return nil
            }
            guard var current = try Row.fetchOne(db, sql: "SELECT * FROM memories WHERE id = ?", arguments: [id])
                .map(Self.decodeMemory) else { throw MemoryV2Error.recordNotFound }
            let merged = try merge(MemoryRecord(stored: current))
            if let observed = merged.observedAt { current.observedAt = observed }
            current.metadata = .object(merged.metadata)
            current.updatedAt = Self.nowISO8601()
            try Self.validateTemporalEvidence(current)
            try db.execute(sql: "UPDATE memories SET metadata_json = ?, observed_at = ?, updated_at = ? WHERE id = ?",
                           arguments: [Self.encodeMetadata(current.metadata), current.observedAt, current.updatedAt, id])
            return current
        }
        if let updated {
            invalidateRecallCache()
            pokeUserMDRegen(persona: updated.personaId)
            await pokeProjectionHooks(updated)
        }
    }
}

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

    /// What to patch onto an existing row when a byte-identical write lands, so
    /// the repeat is traceable to BOTH runs (gpt-5.5 review A3).
    ///
    /// Pure, and deliberately generic: it merges whatever scalar metadata the
    /// new write carries that the row does not already say, plus the new
    /// source, plus the newer observation time. Nothing here knows about
    /// Workshop — an execution's `workshop_execution_id` / `workshop_status` are
    /// just the first caller's identity fields.
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
        //    First-class column (the bridge maps `observed_at` → observedAt);
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

    /// One event, one moment (10-10): a retelling of `row` joins it as evidence
    /// — this telling's source, quote and session as duplicate provenance, and
    /// one more `recall_count` — on the kept memory, or on the proposal still
    /// waiting on her. The row's own text and quote are untouched.
    func recordRetelling(
        of row: MemoryRecord, pending: Bool, source: String, metadata: [String: JSONValue]
    ) async throws {
        try await ensureCanonicalAttachment()
        guard let storage else { throw MemoryV2Error.storageUnavailable }
        let canonical = await storage.underlyingStorage()
        try await canonical.recordRetelling(id: row.id, pending: pending, source: source, metadata: metadata)
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

    /// Store a new memory. `memory_tombstoned` refuses forgotten or rejected
    /// content. Cold writes owe admission until their search vector is ready.
    public func store(
        content: String,
        source: String? = nil,
        metadata: JSONValue? = nil,
        supersedes: [String] = [],
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
        // commit_memory review fix (2026-06-11): lift confidence/importance/
        // tags out of caller metadata into the record's FIRST-CLASS fields —
        // the SQLite bridge reads record.confidence (?? 1.0) and recall
        // surfaces the fields, not the extras blob. Absent in metadata →
        // nil, exactly as before (additive; no caller behavior change).
        var liftedConfidence: Double?
        var liftedImportance: Double?
        var liftedTags: [String]?
        var liftedValidFrom: String?
        var liftedValidTo: String?
        var liftedObservedAt: String?
        var liftedEvidence: JSONValue?
        if case .object(let metaObj)? = metadata {
            if case .double(let c)? = metaObj["confidence"] { liftedConfidence = c }
            if case .double(let i)? = metaObj["importance"] { liftedImportance = i }
            if case .array(let t)? = metaObj["tags"] {
                let strings = t.compactMap { v -> String? in
                    if case .string(let s) = v { return s } else { return nil }
                }
                if !strings.isEmpty { liftedTags = strings }
            }
            if case .string(let value)? = metaObj["valid_from"] { liftedValidFrom = value }
            if case .string(let value)? = metaObj["validFrom"] { liftedValidFrom = value }
            if case .string(let value)? = metaObj["valid_to"] { liftedValidTo = value }
            if case .string(let value)? = metaObj["validTo"] { liftedValidTo = value }
            if case .string(let value)? = metaObj["observed_at"] { liftedObservedAt = value }
            if case .string(let value)? = metaObj["observedAt"] { liftedObservedAt = value }
            liftedEvidence = metaObj["evidence"]
        }
        let record = MemoryRecord(
            // A caller-owned id (Phase 5 C1: one lesson origin per proposal)
            // makes a racing second insert fail on the primary key.
            id: id ?? UUID().uuidString,
            text: content,
            layer: "semantic",
            memoryKind: nil,
            personaId: MemoryV2Defaults.personaID,
            lifecycle: MemoryLifecycle.confirmed,
            createdAt: now,
            updatedAt: now,
            sourceRunId: source,
            status: "active",
            confidence: liftedConfidence,
            importance: liftedImportance,
            tags: liftedTags,
            validFrom: liftedValidFrom,
            validTo: liftedValidTo,
            observedAt: liftedObservedAt,
            evidence: liftedEvidence,
            // U3 wave-2 item 5a — every new write carries metadata.kind.
            // Caller-provided kinds pass through verbatim; absent a signal,
            // the semantics-neutral default ("general", decayFactor 1.0,
            // no supersession) is stamped. See MemoryKindStamp.
            // Item 5 follow-up (2026-09-02): if her own words point at a
            // moment, the atom carries it. Deterministic, silent when
            // ambiguous, and never overwriting a caller's own `due_at` — see
            // MemoryV2+DueDateStamp.swift. This is what gives the forward
            // register a source for "the user's stated plans"; without it a
            // spoken "tomorrow around nine" was durable prose she could recall
            // and nothing she could look toward.
            extras: MemoryDueDateStamp.stamping(
                MemoryKindStamp.stampingDefaultKind(metadata),
                text: content
            )
        )
        let existingRows: [MemoryRecord]
        if supersedes.isEmpty { existingRows = [] }
        else { existingRows = try await storage.listMemory(kind: nil) }
        let superseding = try Set(supersedes).sorted().map { id in
            guard let row = existingRows.first(where: {
                $0.id == id && ($0.status ?? "active") == "active"
                    && MemoryLifecycle.isRecallEligible($0.lifecycle)
            }) else {
                throw MemoryV2Error.staleSupersession("Memory to supersede is missing or no longer active: \(id)")
            }
            return SupersedingAcceptance(
                targetId: id, expectedContentHash: MemoryStorage.contentHash(row.text),
                reason: "explicit supersession")
        }
        if superseding.isEmpty {
            // Reassert exact duplicates before paying for an embedding. The
            // final admission repeats matching under its insertion transaction.
            if let existing = try await storage.admit(
                record: record, embedding: nil, embeddingEpoch: nil,
                insertIfMissing: false, preserveID: id != nil
            ) {
                return existing
            }
        }
        // Embed ONCE; the same vector serves the semantic tombstone gate and
        // the insert. Wave1 T3: a paraphrase of a deleted claim blocks here at
        // write time (the read path never pays); contradictions score below the
        // high threshold and are admitted as new information. A cold model
        // owes the vector instead, and the fill applies the same gate.
        let embedded = try await residentWriteEmbedding(content)
        if let embedded, try await storage.matchesTombstone(
            embedding: embedded.vector,
            embeddingEpoch: embedded.epoch
        ) {
            throw MemoryV2Error.forgottenContent("Content paraphrases a forgotten or rejected memory.")
        }
        var admitted = record
        if embedded == nil {
            // Saved, admitted only when its vector lands and passes the checks
            // (under its own id when the caller owns it). A replacement is
            // admitted as itself and demotes what it replaces only then.
            admitted.extras = MemoryStorage.owingAdmission(record.extras, preservingID: id != nil || !superseding.isEmpty,
                                                           superseding: superseding)
        }
        let inserted: MemoryRecord
        if !superseding.isEmpty {
            inserted = try await storage.insert(record: admitted, embedding: embedded?.vector,
                                              embeddingEpoch: embedded?.epoch, superseding: embedded == nil ? [] : superseding)
        } else {
            guard let saved = try await storage.admit(
                    record: admitted, embedding: embedded?.vector, embeddingEpoch: embedded?.epoch,
                    insertIfMissing: true, preserveID: id != nil) else { throw MemoryV2Error.storageUnavailable }
            inserted = saved
        }
        return embedded == nil ? owedVector(inserted) : inserted
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
