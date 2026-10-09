import Foundation
import NativeAgentCore
import PersistenceCore

extension SwiftNativeMemoryV2 {

    /// Restore the canonical semantic corpus before serving recall. Content
    /// changes invalidate only that snapshot; keep converging until cancellation.
    @discardableResult
    public func reconcileMemoryEmbeddingEpoch() async throws -> MemoryEmbeddingEpochActivationReport? {
        try await ensureCanonicalAttachment()
        guard let embedder else { throw MemoryV2Error.storageUnavailable }
        guard storage is MemoryStorageBridge else { return nil }
        try await warmUpEmbedder()
        while true {
            try Task.checkCancellation()
            let state = try await memoryEmbeddingEpochState()
            if state.activeEpoch == embedder.embeddingEpoch.rawValue { return nil }
            do {
                return try await reindexAllMemoryEmbeddingsForCurrentProvider()
            } catch let error as MemoryStorageError {
                guard case .embeddingActivationInvalid(.corpusDrift, _) = error else { throw error }
            }
        }
    }

    /// Access-signal bump for records served OUTSIDE the recall lane (the
    /// fluid-context serve path, task #42). Same storage write as recall's
    /// fire-and-forget bump; unwired actors fail closed like every other
    /// storage-backed method.
    public func recordRecallHits(ids: [String]) async throws {
        try await ensureCanonicalAttachment()
        guard let storage else { throw MemoryV2Error.storageUnavailable }
        try await storage.recordRecallHits(ids: ids)
    }

    /// Embed the query via the wired `EmbeddingProvider` (MiniLM on the Neural
    /// Engine in production), then ask `MemoryStorage` for the top-K nearest
    /// records by cosine. Hits are sorted by score descending; `total` reflects
    /// how many records the storage layer returned (≤ topK).
    ///
    /// User, 2026-09-06: `recordingUsage` false suppresses the access bump below
    /// for callers that RETRIEVE more than they DELIVER — the Mac memory
    /// search asks for 50 rows on every keystroke pause and shows whatever
    /// subset it can map, so crediting the recall set made browsing your own
    /// store look like the agent using every row in it, and use_count is the
    /// signal that vetoes eviction. Those callers report what they actually
    /// delivered with `recordRecallHits(ids:)`. Default true: every existing
    /// caller behaves exactly as before.
    public func recall(
        _ query: MemoryV2RecallRequest,
        recordingUsage: Bool = true
    ) async throws -> MemoryV2RecallResponse {
        guard !query.text.isEmpty else { throw MemoryV2Error.invalidQuery }
        let recallStarted = ProcessInfo.processInfo.systemUptime
        var timings: [String: Double] = [:]
        func milliseconds(since start: Double) -> Double {
            (ProcessInfo.processInfo.systemUptime - start) * 1_000
        }
        defer {
            if query.requiresRelevance == true {
                timings["total_ms"] = milliseconds(since: recallStarted)
                let detail = timings.sorted { $0.key < $1.key }
                    .map { "\($0.key)=\(Int($0.value))" }.joined(separator: " ")
                nativeLog("MemoryV2 recall: \(detail)")
            }
        }
        try await ensureCanonicalAttachment()
        timings["attachment_ms"] = milliseconds(since: recallStarted)
        guard let storage else { throw MemoryV2Error.storageUnavailable }
        try Task.checkCancellation()
        let epochStarted = ProcessInfo.processInfo.systemUptime
        let reindexed = try await reconcileMemoryEmbeddingEpoch()
        timings["epoch_ms"] = milliseconds(since: epochStarted)
        timings["reindexed"] = reindexed == nil ? 0 : 1
        let embeddingStarted = ProcessInfo.processInfo.systemUptime
        let queryEmbedding: (vector: [Float], epoch: MemoryEmbeddingEpoch)? =
            try await embedOneWithEpoch(query.text)
        try Task.checkCancellation()
        let qvec = queryEmbedding?.vector ?? []
        let topK = max(1, query.topK)
        // Explicit recall judges the bounded corpus in one pass rather than
        // paying for a small window and then judging a refill. Other callers
        // retain their wider disclosure window. SQLite scans/sorts the same
        // canonical set either way; only the retained window changes.
        let storageTopK: Int
        if query.requiresRelevance == true {
            storageTopK = memoryStoredRowCap
        } else {
            storageTopK = (query.surface != nil || query.persona != nil)
                ? min(memoryStoredRowCap, max(topK, topK * 8)) : topK
        }
        var usedKeywordFallback = false
        // Immutable copies for the retrieval closure below: a nested async
        // function that captured the mutable locals directly is a data-race
        // error under strict concurrency.
        let resolvedQueryEmbedding = queryEmbedding

        // A vector of all zeros is what a not-yet-warm embedder returns; it has
        // no direction, so cosine recall would return [] just as surely as a
        // thrown error would.
        let hasUsableVector = !qvec.isEmpty && qvec.contains { $0 != 0 && $0.isFinite }
        // The same question in the other voice ("me" → the agent's name,
        // "you" → the user's), asked alongside the original; a row keeps the
        // better of its two scores. See MemoryRecallQueryExpansion.
        let storeDirectory = await (storage as? MemoryStorageBridge)?.path.deletingLastPathComponent()
        let rewritten = storeDirectory.flatMap { directory in
            MemoryRecallQueryExpansion.rewrite(
                query.text,
                names: MemoryRecallQueryExpansion.names(storeDirectory: directory)
            )
        }
        // The other voice costs ONE embedder round-trip per recall, not one
        // per pass (User, 2026-09-06): computing it inside `retrieve` meant the
        // refill below asked the Neural Engine for the same rewritten question
        // a second time, on the exact turns where recall was already short.
        let rewrittenEmbedding: (vector: [Float], epoch: MemoryEmbeddingEpoch)?
        if let rewritten, resolvedQueryEmbedding != nil, hasUsableVector {
            rewrittenEmbedding = try? await embedOneWithEpoch(rewritten)
        } else {
            rewrittenEmbedding = nil
        }
        timings["embedding_ms"] = milliseconds(since: embeddingStarted)
        try Task.checkCancellation()
        // One retrieval at a given candidate-window size. Hoisted out of the
        // straight-line code (User, 2026-09-06) purely so the refill below can
        // re-ask the same lane wider; the lane selection itself is unchanged.
        func retrieve(
            _ window: Int, loggingKeywordFallback: Bool
        ) async throws -> (hits: [ScoredMemoryRecord], usedKeywordFallback: Bool) {
            if let queryEmbedding = resolvedQueryEmbedding, hasUsableVector {
                var keywordFallback = false
                func dense(
                    _ text: String, _ vector: [Float], _ epoch: MemoryEmbeddingEpoch
                ) async throws -> (hits: [ScoredMemoryRecord], usedKeywordFallback: Bool) {
                    func read(_ vector: [Float], _ epoch: MemoryEmbeddingEpoch) async throws
                        -> (hits: [ScoredMemoryRecord], usedKeywordFallback: Bool) {
                        if let hybrid = storage as? any HybridMemoryStorageProtocol {
                            return try await hybrid.recallReportingKeywordFallback(
                                embedding: vector, embeddingEpoch: epoch, queryText: text,
                                topK: window, persona: query.persona
                            )
                        }
                        return (try await storage.recall(
                            embedding: vector, embeddingEpoch: epoch,
                            topK: window, persona: query.persona
                        ), false)
                    }
                    do {
                        return try await read(vector, epoch)
                    } catch let error as MemoryStorageError {
                        guard case .embeddingEpochMismatch = error else { throw error }
                        try await reconcileMemoryEmbeddingEpoch()
                        let repaired = try await embedOneWithEpoch(text)
                        return try await read(repaired.vector, repaired.epoch)
                    }
                }
                let written = try await dense(query.text, qvec, queryEmbedding.epoch)
                if written.usedKeywordFallback { keywordFallback = true }
                var merged = written.hits
                if let rewritten,
                   let other = rewrittenEmbedding,
                   other.vector.contains(where: { $0 != 0 && $0.isFinite }) {
                    try Task.checkCancellation()
                    let expanded = try await dense(rewritten, other.vector, other.epoch)
                    if expanded.usedKeywordFallback { keywordFallback = true }
                    var best: [String: ScoredMemoryRecord] = [:]
                    for hit in merged + expanded.hits {
                        if let existing = best[hit.record.id], existing.score >= hit.score { continue }
                        best[hit.record.id] = hit
                    }
                    merged = Array(best.values)
                }
                return (merged, keywordFallback)
            }
            throw MemoryV2Error.underlying("Semantic recall is unavailable: the embedding query has no usable vector.")
        }
        func disclosedRows(_ rows: [ScoredMemoryRecord]) -> [ScoredMemoryRecord] {
            var seen: Set<String> = []
            return rows.sorted { $0.score > $1.score }.filter { scoredRecord in
                guard let classification = MemoryRecordDisclosurePolicy.classify(scoredRecord.record) else {
                    return false
                }
                guard classification.permits(surface: query.surface, personaID: query.persona) else {
                    return false
                }
                let key = MemoryStorage.normalizedRecallContent(scoredRecord.record.text)
                return key.isEmpty || seen.insert(key).inserted
            }
        }
        // Read BEFORE candidates so a concurrent mutation can only cause a
        // later cache miss, never label an older read with a newer generation.
        let generationStarted = ProcessInfo.processInfo.systemUptime
        let generation: String?
        if query.requiresRelevance == true, let bridge = storage as? MemoryStorageBridge {
            generation = try await bridge.underlyingStorage().recallJudgmentGeneration()
        } else {
            generation = nil
        }
        timings["generation_ms"] = milliseconds(since: generationStarted)
        var retrievalStarted = ProcessInfo.processInfo.systemUptime
        var retrieved = try await retrieve(storageTopK, loggingKeywordFallback: true)
        timings["retrieval_ms"] = milliseconds(since: retrievalStarted)
        timings["retrieval_passes"] = 1
        usedKeywordFallback = retrieved.usedKeywordFallback
        var scored = retrieved.hits
        try Task.checkCancellation()
        let disclosureStarted = ProcessInfo.processInfo.systemUptime
        var disclosed = disclosedRows(scored)
        var disclosureFilteredCount = scored.count - disclosed.count
        timings["disclosure_ms"] = milliseconds(since: disclosureStarted)
        timings["candidates"] = Double(disclosed.count)
        if query.requiresRelevance == true, !disclosed.isEmpty {
            let relevanceStarted = ProcessInfo.processInfo.systemUptime
            let admitted = try await AdaptiveMemoryPromoter.shared.relevantRecallIDs(query: query.text,
                candidates: disclosed.map {
                    MemoryManagerExistingMemory(id: $0.record.id, content: $0.record.text,
                        kind: $0.record.memoryKind ?? MemoryRecallScoring.kind(of: $0.record.extras))
                }, generation: generation, topK: topK)
            timings["relevance_ms", default: 0] += milliseconds(since: relevanceStarted)
            disclosed = disclosed.filter { admitted.contains($0.record.id) }
        }
        // Non-judged callers retain the disclosure refill. Explicit recall
        // already fetched the row cap and never repeats retrieval or judgment.
        if disclosed.count < topK, scored.count >= storageTopK, storageTopK < memoryStoredRowCap {
            retrievalStarted = ProcessInfo.processInfo.systemUptime
            retrieved = try await retrieve(memoryStoredRowCap, loggingKeywordFallback: false)
            timings["retrieval_ms", default: 0] += milliseconds(since: retrievalStarted)
            timings["retrieval_passes", default: 0] += 1
            usedKeywordFallback = usedKeywordFallback || retrieved.usedKeywordFallback
            scored = retrieved.hits
            try Task.checkCancellation()
            disclosed = disclosedRows(scored)
            disclosureFilteredCount = scored.count - disclosed.count
        }
        // storageTopK is a wider disclosure candidate window, not the result
        // budget. Reapply the existing skill-hint share AFTER disclosure at
        // the actual requested size so hints cannot consume the entire answer.
        let selectionStarted = ProcessInfo.processInfo.systemUptime
        let sorted = MemoryRecallScoring.selectRecallResults(
            from: disclosed.sorted { $0.score > $1.score }, limit: topK
        ) {
            MemoryRecallScoring.isSkillRecallHint(
                id: $0.record.id,
                kind: $0.record.memoryKind ?? MemoryRecallScoring.kind(of: $0.record.extras)
            )
        }.sorted { $0.score > $1.score }
        timings["selection_ms"] = milliseconds(since: selectionStarted)
        timings["results"] = Double(sorted.count)
        // Dead-lane alarm (2026-07-24): `persona` is an exact-equality filter
        // over RECORD persona ids (configured agent names). A
        // caller that hands it a persona SLOT id can never match a row, so the
        // whole recall lane silently returns nothing. Only fires on the zero-hit
        // path, at most once per (persona, surface), and only after proving the
        // persona filter — not disclosure, not an empty store — is to blame.
        // Not on the keyword-fallback path: that diagnostic probes the DENSE
        // lane, and a cold-embedder turn is not evidence of a persona-id
        // mismatch. It would fire a false alarm on every first-turn recall.
        if query.persona != nil, (query.requiresRelevance == true ? scored.isEmpty : sorted.isEmpty), !usedKeywordFallback,
           let queryEmbedding {
            await reportPersonaRecallStarvation(
                query: query,
                personaFilteredCandidateCount: scored.count,
                embedding: qvec,
                epoch: queryEmbedding.epoch,
                storage: storage
            )
        }
        // Fire-and-forget access bump: record that these memories were used,
        // AFTER we've computed the answer, WITHOUT awaiting — so recall's read
        // latency is unchanged (Agent's zero-read-cost constraint). This is the
        // signal that stops archiveStale from evicting hot-but-never-merged
        // memories as "unused" (#0).
        try Task.checkCancellation()
        let usedIds = recordingUsage ? sorted.map { $0.record.id } : []
        if !usedIds.isEmpty {
            let storageRef = storage
            Task {
                do {
                    try await storageRef.recordRecallHits(ids: usedIds)
                } catch {
                    // Don't swallow silently: use_count is eviction-protective
                    // (gpt-5.5 review finding 3). A dropped bump self-heals on
                    // any later recall within the 365d window, so logging (not
                    // retry machinery) is the proportionate response here.
                    FileHandle.standardError.write(
                        Data("MemoryV2: recall-hit bump failed for \(usedIds.count) ids: \(error)\n".utf8)
                    )
                }
            }
        }
        // U3 wave-1 item 1: carry the FULL text (sentence-safe capped) on
        // every hit — the 200-char preview was the felt truncation. Pure
        // output shaping on rows already selected: ranking and row set are
        // untouched, and no extra storage round-trip happens (zero added
        // read latency).
        let hits: [MemoryRecallHit] = sorted.map { sr in
            let canonicalText = MemoryTextClip.memoryDisplayText(
                sr.record.text,
                kind: sr.record.memoryKind
            )
            let displayText = (MemorySenseProvenance.warning(in: sr.record.extras).map { "[\($0)]\n" } ?? "") + canonicalText
            let content = MemoryTextClip.sentenceClip(displayText, cap: memoryRecallContentCap)
            // Sweep R4 A4: the prompt renderer stamps a compact
            // `[YYYY-MM-DD, kind]` provenance marker on each recalled row so the
            // model can tell a stale fact from a fresh correction. `ts` was
            // already carried; the kind rides in the free-form `extras` bag
            // (documented as the landing spot for extra keys) rather than a new
            // struct field, so the hit shape is unchanged.
            var extras: [String: JSONValue] = ["id": .string(sr.record.id)]
            extras.merge(MemoryDataProvenance.fields(in: sr.record.extras)) { _, value in value }
            if let origin = MemoryMoments.recallOrigin(source: sr.record.sourceRunId, metadata: sr.record.extras) {
                extras["origin"] = origin
            }
            if let warning = MemorySenseProvenance.warning(in: sr.record.extras) {
                extras["sense_warning"] = .string(warning)
            }
            if case .object(let metadata)? = sr.record.extras, let versions = metadata["sense_versions"] {
                extras["sense_versions"] = versions
            }
            if content.count < displayText.count {
                extras["content_truncated"] = .bool(true)
                extras["full_content_chars"] = .int(Int64(displayText.count))
            }
            if let kind = sr.record.memoryKind?
                .trimmingCharacters(in: .whitespacesAndNewlines),
               !kind.isEmpty {
                extras["kind"] = .string(kind)
            }
            // Descriptive canonical dates, not storage chronology or a
            // validity-now decision. Explicit recall needs the same dated
            // fact context that the automatic memory projection retains.
            if let value = sr.record.validFrom { extras["valid_from"] = .string(value) }
            if let value = sr.record.validTo { extras["valid_to"] = .string(value) }
            if let value = sr.record.observedAt { extras["observed_at"] = .string(value) }
            // How the fact came to be known (commit_memory's `provenance` /
            // `provenance_by`). Carried verbatim so recall can tell "I checked
            // this" from "someone told me"; absent on rows written before it.
            if case .object(let metadata)? = sr.record.extras {
                if let sources = metadata["untrusted_sources"] { extras["untrusted_sources"] = sources }
                for key in ["provenance", "provenance_by"] {
                    if case .string(let value)? = metadata[key], !value.isEmpty {
                        extras[key] = .string(value)
                    }
                }
            }
            return MemoryRecallHit(
                score: sr.score,
                sessionId: sr.record.sourceRunId,
                role: nil,
                ts: sr.record.createdAt,
                preview: MemoryTextClip.sentenceClip(displayText, cap: memoryRecallPreviewCap),
                content: content,
                source: usedKeywordFallback ? "swift-native-keyword-fallback" : "swift-native",
                rankingSignals: nil,
                extras: .object(extras)
            )
        }
        timings["total_ms"] = milliseconds(since: recallStarted)
        return MemoryV2RecallResponse(
            hits: hits,
            scored: sorted,
            total: sorted.count,
            disclosureFilteredCount: disclosureFilteredCount,
            timings: timings
        )
    }

    /// Exact-ID recovery for a previously recalled excerpt. Does not embed,
    /// rank, enumerate records, or expose an admin/lineage bypass.
    public func readMemoryRecord(id: String, persona: String? = nil, surface: String) async throws -> MemoryRecord? {
        let id = id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty, id.utf8.count <= 512 else { throw MemoryV2Error.invalidQuery }
        try await ensureCanonicalAttachment()
        guard let lookup = storage as? any MemoryRecordLookupStorage else {
            throw MemoryV2Error.storageUnavailable
        }
        try Task.checkCancellation()
        guard let record = try await lookup.lookupMemoryRecord(id: id),
              record.id == id,
              persona == nil || record.personaId == persona,
              let disclosure = MemoryRecordDisclosurePolicy.classify(record),
              disclosure.permits(surface: surface, personaID: persona),
              MemoryCandidateQuality.isDurableCandidate(
                text: record.text, source: record.sourceRunId, kind: record.memoryKind
              ) else { return nil }
        let tombstoned = try await lookup.isTombstoned(content: record.text)
        guard !tombstoned else { return nil }
        try Task.checkCancellation()
        return record
    }

    /// Zero-hit path: decide whether the PERSONA FILTER specifically emptied
    /// this recall, and say so at most once per (persona, surface).
    ///
    /// The original probe only proved "the unfiltered store has a candidate",
    /// which is true in two perfectly healthy situations and made the alarm a
    /// wolf-cry. Both are now ruled out before anything is logged:
    ///
    ///   1. SURFACE DISCLOSURE emptied the recall. `scored` is the
    ///      persona-filtered, pre-disclosure candidate set. If it is NON-empty
    ///      the persona filter matched rows just fine and disclosure dropped
    ///      them — a different subsystem, and not a dead lane. Stay quiet.
    ///   2. NOTHING DISCLOSABLE exists anyway. The unfiltered probe is run
    ///      through the SAME `MemoryRecordDisclosurePolicy` gate as the real
    ///      recall. If no probe row would have been disclosable to this
    ///      surface/persona, the persona filter cost the caller nothing.
    ///
    /// What survives both gates is provable: rows exist, they are disclosable
    /// here, and the persona filter matched none of them. That is the claim the
    /// message now makes — it names the record persona ids it actually saw and
    /// offers the slot-id diagnosis as the leading explanation rather than
    /// asserting it. (A brand-new agent-name persona with no rows yet is
    /// observationally identical inside one recall; the once-per-signature memo
    /// keeps that case to a single line instead of a per-call stream.)
    private func reportPersonaRecallStarvation(
        query: MemoryV2RecallRequest,
        personaFilteredCandidateCount: Int,
        embedding: [Float],
        epoch: MemoryEmbeddingEpoch?,
        storage: any MemoryStorageProtocol
    ) async {
        guard let persona = query.persona else { return }
        // Gate 1 — the persona filter DID match rows; disclosure emptied the
        // result. Not this diagnostic's business.
        guard personaFilteredCandidateCount == 0 else { return }
        // Bound: a tool loop repeating the same starving recall used to print an
        // error on every call. Same shape as
        // ContextFlowCoordinator.PrecoverageFailureReporter — one line per
        // distinct signature, not one per turn.
        //
        // HONEST SCOPE (gpt-5.5 review 2026-07-24 LOW): this bounds the LOG, and
        // it bounds the probe only once a signature has actually REPORTED — the
        // insert happens after a disclosable probe row is found. A repeat recall
        // whose probe keeps finding nothing disclosable (e.g. wrong-vocabulary
        // persona on a surface with no permitted rows) stays correctly silent but
        // re-pays the probe each call. Left as-is deliberately: post-2026-07-24
        // policy `memoryRecallPersonaFilter` always returns nil, so reaching here
        // at all requires a caller that bypasses the helper with a non-nil
        // persona — rare enough that memoizing a never-reported signature would
        // trade a real diagnostic for an imaginary saving.
        let signature = "\(persona)|\(query.surface ?? "nil")"
        guard !reportedStarvationSignatures.contains(signature) else { return }

        let probe: [ScoredMemoryRecord]
        do {
            if let hybrid = storage as? any HybridMemoryStorageProtocol {
                probe = try await hybrid.recall(
                    embedding: embedding,
                    embeddingEpoch: epoch,
                    queryText: query.text,
                    topK: personaStarvationProbeTopK,
                    persona: nil
                )
            } else {
                probe = try await storage.recall(
                    embedding: embedding,
                    embeddingEpoch: epoch,
                    topK: personaStarvationProbeTopK,
                    persona: nil
                )
            }
        } catch {
            return
        }
        // Gate 2 — the same disclosure gate the real recall applies, asked with
        // `personaID: nil` on purpose. `permits` enforces persona equality
        // ITSELF, so passing the queried persona here would fold the very cause
        // we are trying to isolate back into the test and make the alarm
        // unreachable. Nil asks the one question that is left: would SURFACE
        // disclosure have released this row?
        let disclosable = probe.filter { scoredRecord in
            guard let classification = MemoryRecordDisclosurePolicy.classify(scoredRecord.record) else {
                return false
            }
            return classification.permits(surface: query.surface, personaID: nil)
        }
        guard !disclosable.isEmpty else { return }

        let observedPersonaIDs = Set(disclosable.map { $0.record.personaId ?? "nil" }).sorted()
        reportedStarvationSignatures.insert(signature)
        emitDiagnostic(
            "[memory-v2] ERROR persona recall starvation: persona filter "
            + "\"\(persona)\" (surface \(query.surface ?? "nil")) matched 0 records while "
            + "\(disclosable.count) disclosable row(s) sit in the store under persona id(s) "
            + "[\(observedPersonaIDs.joined(separator: ", "))]. Disclosure is not the cause — "
            + "the persona filter is. Record persona ids are agent names; if \"\(persona)\" is "
            + "a persona SLOT id, this lane can never fill."
        )
    }

}
