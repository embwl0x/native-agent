import Foundation
import NativeAgentCore
import PersistenceCore

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

        var out: [String: JSONValue] = [:]

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

    /// Store a new memory record. Refuses (with `.underlying("tombstoned")`) if
    /// the content matches a rejection tombstone — the denylist gate. Otherwise
    /// embeds the content, inserts into storage, and returns the resulting
    /// `MemoryRecord` with its storage-assigned id.
    public func store(
        content: String,
        source: String? = nil,
        metadata: JSONValue? = nil
    ) async throws -> MemoryRecord {
        let content = MemoryTextClip.memoryDisplayText(
            content,
            kind: Self.metadataKind(metadata)
        )
        guard !content.isEmpty else { throw MemoryV2Error.invalidQuery }
        if let reason = MemoryCandidateQuality.rejectionReason(
            text: content,
            source: source,
            kind: Self.metadataKind(metadata)
        ) {
            throw MemoryV2Error.underlying("not durable memory: \(reason)")
        }
        guard let storage else { throw MemoryV2Error.storageUnavailable }
        if try await storage.isTombstoned(content: content) {
            throw MemoryV2Error.underlying("tombstoned: content matches a rejection denylist entry")
        }
        // Taste pass 2026-07-24: write-time exact-duplicate guard. A repeated
        // commit_memory (retry loop, re-asserted fact) used to insert a fresh
        // identical active row each time — 4 copies of one fact landed in 49s
        // on 2026-07-22 and sat visible until the weekly hygiene pass. Same
        // normalization as hygiene's exact-dup collapse, so "duplicate" means
        // one thing. Idempotent: return the existing record and count the
        // re-assertion as corroborating evidence (metadata.recall_count, the
        // same bump mergeProposal applies — a merge is evidence, not access).
        // Checked BEFORE embedding: a duplicate never pays the embed cost.
        let contentKey = MemoryConsolidator.normalizedContentKey(content)
        let existingRows = try await storage.listMemory(kind: nil)
        if let existing = existingRows.first(where: {
            ($0.status ?? "active") == "active"
                && MemoryConsolidator.normalizedContentKey($0.text) == contentKey
        }) {
            var currentCount: Int64 = 0
            if case .object(let m)? = existing.extras {
                if case .int(let n)? = m["recall_count"] { currentCount = n }
                if case .double(let d)? = m["recall_count"] {
                    guard let count = Int64(exactly: d.rounded(.towardZero)) else {
                        throw MemoryStorageError.databaseUnavailable("duplicate write: recall_count is outside Int64 range")
                    }
                    currentCount = count
                }
            }
            // 2026-09-06: match the merge counter's checked failure path;
            // malformed evidence must not trap or overwrite the saved row.
            let (nextCount, overflow) = currentCount.addingReportingOverflow(1)
            guard !overflow else {
                throw MemoryStorageError.databaseUnavailable("duplicate write: recall_count overflow")
            }
            // Unknown patch keys merge into metadata_json (bridge contract).
            var patch: [String: JSONValue] = ["recall_count": .int(nextCount)]
            // gpt-5.5 review A3 (2026-08-02): the collapse itself is deliberate
            // and stays — repetition should be evidence, not clutter. What was
            // WRONG is that the later occurrence lost its identity: two
            // genuinely different events producing the same prose left the row
            // pointing only at the first one, so the second was unrecoverable.
            // The provenance of every occurrence now accumulates alongside the
            // count, bounded, in metadata.
            for (key, value) in Self.duplicateProvenancePatch(
                existing: existing,
                newSource: source,
                newMetadata: metadata
            ) {
                patch[key] = value
            }
            let updated = try await storage.updateMemory(
                id: existing.id,
                patch: .object(patch),
                newEmbedding: nil
            )
            // Reassertions can advance observed dates and provenance even
            // when prose/identity stay unchanged. Match new-record completion
            // so the next prepared context sees the committed evidence.
            await flushDerivedMemoryChanges()
            return updated
        }
        // Embed ONCE; the same vector serves the semantic tombstone gate and
        // the insert. Wave1 T3: a paraphrase of a deleted claim blocks here at
        // write time (the read path never pays); contradictions score below the
        // high threshold and are admitted as new information.
        let embedded = try await embedOneWithEpoch(content)
        if try await storage.matchesTombstone(
            embedding: embedded.vector,
            embeddingEpoch: embedded.epoch
        ) {
            throw MemoryV2Error.underlying("tombstoned: content is a paraphrase of a rejected claim")
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
            id: UUID().uuidString,
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
        let inserted = try await storage.insert(
            record: record,
            embedding: embedded.vector,
            embeddingEpoch: embedded.epoch
        )
        await flushDerivedMemoryChanges()
        return inserted
    }

    /// Convenience tombstone check used by upstream filters (e.g. the chat-fact
    /// promoter) before calling `store(...)`.
    public func isRejected(content: String) async throws -> Bool {
        guard let storage else { throw MemoryV2Error.storageUnavailable }
        return try await storage.isTombstoned(content: content)
    }

    // MARK: - utilities

    static func iso8601Now() -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f.string(from: Date())
    }

    static func metadataKind(_ metadata: JSONValue?) -> String? {
        guard case .object(let obj)? = metadata,
              case .string(let kind)? = obj["kind"] else {
            return nil
        }
        let trimmed = kind.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
