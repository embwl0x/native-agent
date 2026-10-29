import Foundation
import NativeAgentCore
import PersistenceCore
import NativeAgentShared
// Blueprint: | `MemoryV2+Recall.swift` | `SwiftNativeMemoryV2`: `recordRecallHits`, counted/capped candidate-paged `recall`, `readMemoryRecord`; invocation-local ranked voices reused for disclosure refill |

extension SwiftNativeMemoryV2 {

    /// Restore the canonical semantic corpus. Content changes invalidate only
    /// that snapshot; keep converging until cancellation.
    @discardableResult
    func reconcileMemoryEmbeddingEpoch() async throws -> MemoryEmbeddingEpochActivationReport? {
        try await ensureCanonicalAttachment()
        guard let embedder else {
            throw MemoryStorageError.searchFailure("No memory search model is attached.",
                code: "memory_search_model_unavailable", instruction: "Inspect Doctor's memory search model findings before searching again.")
        }
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

    static let recallCorpusConverging = ToolFailureError(
        "Memory search is updating saved memories for the current memory search model.", effects: .none,
        nextCall: ToolFailureError.call("app", ["page": .string("memories")]), code: "memory_search_index_updating",
        instruction: "Check memory search progress before recalling again.", recovery: .inspect
    )

    /// Records served outside recall use the same access write; unwired storage fails closed.
    public func recordRecallHits(ids: [String]) async throws {
        try await ensureCanonicalAttachment()
        guard let storage else { throw MemoryV2Error.storageUnavailable }
        try await storage.recordRecallHits(ids: ids)
    }

    /// Embed the query via the wired `EmbeddingProvider` (bge on the Neural
    /// Engine in production), then ask `MemoryStorage` for the top-K nearest
    /// records by cosine. Pages walk disclosed ranked candidates; only a fully
    /// examined first page claims an exact relevant total.
    ///
    /// Callers retrieving more than they deliver set `recordingUsage` false and report delivered ids with `recordRecallHits(ids:)`.
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
        // Recall reads the published vector space and never builds one: what
        // is missing is named, and its housekeeping flight requested.
        let epochStarted = ProcessInfo.processInfo.systemUptime
        guard let residentEpoch = residentEmbeddingEpoch() else {
            requestEmbeddingEpochReconcile()
            let failed = embeddingRuntimeSnapshot()?.lastLoadError.map { " Its last load failed: \($0)." } ?? ""
            throw MemoryStorageError.searchFailure("The memory search model is not loaded.\(failed)",
                code: "memory_search_model_not_loaded", instruction: "It loads on its own; recall again shortly. If it keeps failing, Doctor names the load error.")
        }
        guard try await memoryEmbeddingEpochState().activeEpoch == residentEpoch.rawValue else {
            requestEmbeddingEpochReconcile()
            throw Self.recallCorpusConverging
        }
        timings["epoch_ms"] = milliseconds(since: epochStarted)
        let embeddingStarted = ProcessInfo.processInfo.systemUptime
        // The same question in the other voice ("me" → the agent's name,
        // "you" → the user's), asked alongside the original; a row keeps the
        // better of its two scores. See MemoryRecallQueryExpansion. Both
        // voices share one embed, so neither can silently go missing.
        let storeDirectory = await storage.path.deletingLastPathComponent()
        let rewritten = MemoryRecallQueryExpansion.rewrite(
            query.text,
            names: MemoryRecallQueryExpansion.names(storeDirectory: storeDirectory)
        )
        guard let embedder else {
            throw MemoryStorageError.searchFailure("No memory search model is attached.",
                code: "memory_search_model_unavailable", instruction: "Inspect Doctor's memory search model findings before searching again.")
        }
        let embedded = try await embedder.embedQueriesWithEpoch([query.text] + (rewritten.map { [$0] } ?? []))
        guard let qvec = embedded.vectors.first else {
            throw MemoryStorageError.searchFailure("The memory search model returned no query vectors.",
                code: "memory_search_vectors_missing", instruction: "Inspect Doctor's model findings; repair the missing query vectors before searching again.")
        }
        try Task.checkCancellation()
        let topK = min(memoryStoredRowCap, max(1, query.topK))
        // Explicit recall judges the bounded corpus in one pass rather than
        // paying for a small window and then judging a refill. Other callers
        // retain their wider disclosure window. SQLite scans/sorts the same
        // canonical set either way; only the retained window changes.
        let storageTopK: Int
        if query.requiresRelevance == true || (query.offset ?? 0) > 0 {
            storageTopK = memoryStoredRowCap
        } else {
            storageTopK = (query.surface != nil || query.persona != nil)
                ? min(memoryStoredRowCap, max(topK, topK * 8)) : topK
        }
        // A vector of all zeros is what a not-yet-warm embedder returns; it has
        // no direction, so cosine recall would return [] just as surely as a
        // thrown error would.
        let hasUsableVector = !qvec.isEmpty && qvec.contains { $0 != 0 && $0.isFinite }
        let rewrittenEmbedding: (vector: [Float], epoch: MemoryEmbeddingEpoch)? = rewritten != nil
            && embedded.vectors.count > 1 ? (embedded.vectors[1], embedded.epoch) : nil
        timings["embedding_ms"] = milliseconds(since: embeddingStarted)
        try Task.checkCancellation()
        let canonicalStorage = storage
        func disclosedRows(_ rows: [ScoredMemoryRecord]) -> [ScoredMemoryRecord] {
            var seen: Set<String> = []
            return rows.sorted { $0.score == $1.score ? $0.record.id < $1.record.id : $0.score > $1.score }.filter { scoredRecord in
                guard let classification = MemoryRecordDisclosurePolicy.classify(scoredRecord.record) else {
                    return false
                }
                guard classification.permits(surface: query.surface, personaID: query.persona) else {
                    return false
                }
                let key = MemoryStorage.comparisonKey(scoredRecord.record.text, mode: .recall)
                return key.isEmpty || seen.insert(key).inserted
            }
        }
        // Read BEFORE candidates so a concurrent mutation can only cause a
        // later cache miss, never label an older read with a newer generation.
        let generationStarted = ProcessInfo.processInfo.systemUptime
        let generation: String?
        if query.requiresRelevance == true {
            generation = try await canonicalStorage.recallJudgmentGeneration()
        } else {
            generation = nil
        }
        timings["generation_ms"] = milliseconds(since: generationStarted)
        var retrievalStarted = ProcessInfo.processInfo.systemUptime
        guard hasUsableVector else {
            throw MemoryStorageError.searchFailure("The memory search model returned no usable query vector.",
                code: "memory_search_vector_unusable", instruction: "Inspect Doctor's model findings; repair the unusable query vector before searching again.")
        }
        // Keep each voice's full ranking; deduplication and record conversion
        // stop at its requested window, including when disclosure widens it.
        let candidates: [MemoryStorage.RecallCandidate]
        do {
            candidates = try await canonicalStorage.recallCandidates(queryEpoch: embedded.epoch)
        } catch let error as MemoryStorageError {
            guard case .embeddingEpochMismatch = error else { throw error }
            requestEmbeddingEpochReconcile()
            throw Self.recallCorpusConverging
        }
        let primaryRanked = try MemoryStorage.rankedRecall(
            embedding: qvec, queryText: query.text, persona: query.persona, candidates: candidates)
        let rewrittenRanked: [(memory: StoredMemory, similarity: Double)]?
        if let rewritten,
           let other = rewrittenEmbedding,
           other.vector.contains(where: { $0 != 0 && $0.isFinite }) {
            try Task.checkCancellation()
            rewrittenRanked = try MemoryStorage.rankedRecall(
                embedding: other.vector, queryText: rewritten, persona: query.persona, candidates: candidates)
        } else {
            rewrittenRanked = nil
        }
        func retrieve(_ window: Int) -> [ScoredMemoryRecord] {
            func unique(_ ranked: [(memory: StoredMemory, similarity: Double)]) -> [ScoredMemoryRecord] {
                MemoryStorage.uniqueRecallResults(ranked, limit: window).map {
                    ScoredMemoryRecord(record: MemoryRecord(stored: $0.memory), score: $0.similarity)
                }
            }
            let primary = unique(primaryRanked)
            guard let rewrittenRanked else { return primary }
            var best: [String: ScoredMemoryRecord] = [:]
            for hit in primary + unique(rewrittenRanked) {
                if let existing = best[hit.record.id], existing.score >= hit.score { continue }
                best[hit.record.id] = hit
            }
            return Array(best.values)
        }
        var scored = retrieve(storageTopK)
        timings["retrieval_ms"] = milliseconds(since: retrievalStarted)
        timings["retrieval_passes"] = 1
        try Task.checkCancellation()
        let disclosureStarted = ProcessInfo.processInfo.systemUptime
        var disclosed = disclosedRows(scored)
        var disclosureFilteredCount = scored.count - disclosed.count
        timings["disclosure_ms"] = milliseconds(since: disclosureStarted)
        timings["candidates"] = Double(disclosed.count)
        let candidateCount = disclosed.count
        let offset = min(max(0, query.offset ?? 0), candidateCount)
        disclosed = Array(disclosed.dropFirst(offset))
        var examinedCount = MemoryRecallScoring.relevanceCandidateLimit(topK: topK, count: disclosed.count)
        let rankedCandidates = disclosed
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
        if query.requiresRelevance != true, disclosed.count < topK, scored.count >= storageTopK, storageTopK < memoryStoredRowCap {
            retrievalStarted = ProcessInfo.processInfo.systemUptime
            scored = retrieve(memoryStoredRowCap)
            timings["retrieval_ms", default: 0] += milliseconds(since: retrievalStarted)
            try Task.checkCancellation()
            let allDisclosed = disclosedRows(scored)
            disclosureFilteredCount = scored.count - allDisclosed.count
            disclosed = Array(allDisclosed.dropFirst(offset))
        }
        // storageTopK is a wider disclosure candidate window, not the result
        // budget: cut AFTER disclosure at the actual requested size.
        let selectionStarted = ProcessInfo.processInfo.systemUptime
        let sorted = Array(disclosed.sorted { $0.score == $1.score ? $0.record.id < $1.record.id : $0.score > $1.score }.prefix(max(0, topK)))
        // The judge settles the whole prefix through the kth admitted row.
        // If it finds fewer, it examined its entire bounded candidate window.
        // Continue after that prefix, including rejected rows, so even an empty
        // page makes progress without judging the same evidence again.
        let next: Int
        let hasMore: Bool
        let capped: Bool
        if query.requiresRelevance == true {
            if sorted.count == topK, let last = sorted.last,
               let index = rankedCandidates.firstIndex(where: { $0.record.id == last.record.id }) {
                examinedCount = index + 1
            }
            next = offset + examinedCount
            hasMore = next < candidateCount
            capped = offset > 0 || hasMore
        } else {
            next = offset + sorted.count
            hasMore = sorted.count < disclosed.count || scored.count >= storageTopK && storageTopK < memoryStoredRowCap
            capped = offset > 0 || hasMore
        }
        timings["selection_ms"] = milliseconds(since: selectionStarted)
        timings["results"] = Double(sorted.count)
        // Record access after computing recall without awaiting; scoring and capacity retention use it, but disuse never archives rows.
        try Task.checkCancellation()
        let usedIds = recordingUsage ? sorted.map { $0.record.id } : []
        if !usedIds.isEmpty {
            let storageRef = storage
            Task {
                do {
                    try await storageRef.recordRecallHits(ids: usedIds)
                } catch {
                    // Log failed access bumps without retries; recalls within 365 days restore eviction protection.
                    FileHandle.standardError.write(
                        Data("MemoryV2: recall-hit bump failed for \(usedIds.count) ids: \(error)\n".utf8)
                    )
                }
            }
        }
        // Shape full text on selected hits without changing ranking, row selection or storage reads.
        let hits: [MemoryRecallHit] = sorted.map { sr in
            let canonicalText = MemoryTextClip.memoryDisplayText(
                sr.record.text,
                kind: sr.record.memoryKind
            )
            let displayText = (MemorySenseProvenance.warning(in: sr.record.extras).map { "[\($0)]\n" } ?? "") + canonicalText
            let content = MemoryTextClip.sentenceClip(displayText, cap: memoryRecallContentCap)
            var extras: [String: JSONValue] = ["id": .string(sr.record.id)]
            extras.merge(MemoryDataProvenance.fields(in: sr.record.extras)) { _, value in value }
            if let origin = MemoryMoments.recallOrigin(source: sr.record.sourceRunId, metadata: sr.record.extras, dataRoot: canonicalDataRoot ?? defaultDataRoot()) {
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
            // Carry kind in extras for the renderer's optional provenance marker.
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
                source: "swift-native",
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
            timings: timings,
            capped: capped,
            hasMore: hasMore,
            nextOffset: hasMore ? next : nil
        )
    }

    /// Exact-ID recovery for a previously recalled excerpt. Does not embed,
    /// rank, enumerate records, or expose an admin/lineage bypass.
    public func readMemoryRecord(id: String, persona: String? = nil, surface: String) async throws -> MemoryRecord? {
        let id = id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty, id.utf8.count <= 512 else {
            throw ToolFailureError("Memory id must contain 1–512 UTF-8 bytes.", argumentPath: "memory_id",
                accepted: "an existing memory id, at most 512 UTF-8 bytes", effects: .none,
                nextCall: ToolFailureError.call("app", ["action": .string("memory.list")]),
                code: "memory_id_invalid", status: .refused,
                instruction: "Correct memory_id in the original call.", recovery: .correctArguments)
        }
        try await ensureCanonicalAttachment()
        guard let storage else { throw MemoryV2Error.storageUnavailable }
        try Task.checkCancellation()
        guard let record = try await storage.memory(id: id).map(MemoryRecord.init(stored:)),
              record.id == id,
              persona == nil || record.personaId == persona,
              let disclosure = MemoryRecordDisclosurePolicy.classify(record),
              disclosure.permits(surface: surface, personaID: persona),
              MemoryCandidateQuality.isDurableCandidate(
                text: record.text, source: record.sourceRunId, kind: record.memoryKind
              ) else { return nil }
        let tombstoned = try await storage.isTombstoned(content: record.text)
        guard !tombstoned else { return nil }
        guard !MemoryStorage.metadataFlag(record.extras, MemoryStorage.pendingAdmissionKey) else {
            throw ToolFailureError("This memory is awaiting admission checks and cannot be recalled yet.", effects: .none,
                nextCall: ToolFailureError.call("app", ["page": .string("memories")]), code: "memory_admission_pending",
                instruction: "Check memory admission progress before recalling this record again.", recovery: .inspect)
        }
        try Task.checkCancellation()
        return record
    }

}
