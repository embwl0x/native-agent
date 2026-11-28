import Foundation
import NativeAgentCore
import PersistenceCore
import NativeAgentShared
// Blueprint: | `MemoryV2+Recall.swift` | `SwiftNativeMemoryV2`, `recordRecallHits`, `recall`, `readMemoryRecord`: paged recall and delivered-hit credit |

extension SwiftNativeMemoryV2 {

    /// Restore the canonical semantic corpus. Content changes invalidate only that snapshot; keep converging until cancellation.
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
            let epoch = try embedder.embeddingEpoch.rawValue
            if state.activeEpoch == epoch, state.dimensions == embedder.dimensions,
               state.activationFailure?.epoch != epoch { return nil }
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

    /// Page disclosed ranked candidates; only a fully examined first page has an exact relevant total. Overfetching callers disable usage recording and credit
    /// only delivered IDs.
    public func recall(
        _ query: MemoryV2RecallRequest,
        recordingUsage: Bool = true,
        turn: Turn? = nil
    ) async throws -> MemoryV2RecallResponse {
        guard !query.text.isEmpty else { throw MemoryV2Error.invalidQuery }
        let recallStarted = ProcessInfo.processInfo.systemUptime
        let metrics = RecallTimings()
        defer {
            if query.requiresRelevance == true {
                metrics.timings["total_ms"] = metrics.milliseconds(since: recallStarted)
                let detail = metrics.timings.sorted { $0.key < $1.key }
                    .map { "\($0.key)=\(Int($0.value))" }.joined(separator: " ")
                nativeLog("MemoryV2 recall: \(detail)")
            }
        }
        try await ensureCanonicalAttachment()
        metrics.timings["attachment_ms"] = metrics.milliseconds(since: recallStarted)
        guard let storage else { throw MemoryV2Error.storageUnavailable }
        try Task.checkCancellation()
        let vectors = try await embedRecallQuery(query, storage: storage, metrics: metrics)
        let selection = try await selectRecallRows(query, storage: storage, vectors: vectors, metrics: metrics, turn: turn)
        return try await makeRecallResponse(query, storage: storage, selection: selection, topK: vectors.topK,
            storageTopK: vectors.storageTopK, metrics: metrics, recallStarted: recallStarted, recordingUsage: recordingUsage)
    }

    private final class RecallTimings {
        var timings: [String: Double] = [:]

        func milliseconds(since start: Double) -> Double {
            (ProcessInfo.processInfo.systemUptime - start) * 1_000
        }
    }

    private typealias RecallVectors = (qvec: [Float], rewritten: String?, rewrittenEmbedding: (vector: [Float], epoch: MemoryEmbeddingEpoch)?,
        embedded: MemoryEmbeddingBatch, topK: Int, storageTopK: Int, hasUsableVector: Bool)
    private typealias RecallSelection = (disclosed: [ScoredMemoryRecord], rankedCandidates: [ScoredMemoryRecord],
        scored: [ScoredMemoryRecord], disclosureFilteredCount: Int, candidateCount: Int, offset: Int, examinedCount: Int)

    private func embedRecallQuery(_ query: MemoryV2RecallRequest, storage: MemoryStorage, metrics: RecallTimings) async throws -> RecallVectors {
        // Recall reads the published vector space and never builds one: what is missing is named, and its housekeeping flight requested.
        let epochStarted = ProcessInfo.processInfo.systemUptime
        guard let residentEpoch = try residentEmbeddingEpoch() else {
            requestEmbeddingEpochReconcile()
            let failed = embeddingRuntimeSnapshot()?.lastLoadError.map { " Its last load failed: \($0)." } ?? ""
            throw MemoryStorageError.searchFailure("The memory search model is not loaded.\(failed)",
                code: "memory_search_model_not_loaded",
                    instruction: "It loads on its own; recall again shortly. If it keeps failing, Doctor names the load error.")
        }
        let epochState = try await memoryEmbeddingEpochState()
        guard epochState.activeEpoch == residentEpoch.rawValue, epochState.dimensions == embedder?.dimensions else {
            requestEmbeddingEpochReconcile()
            throw Self.recallCorpusConverging
        }
        metrics.timings["epoch_ms"] = metrics.milliseconds(since: epochStarted)
        let embeddingStarted = ProcessInfo.processInfo.systemUptime
        // Embed both conversational voices together and keep each row's better score so neither reading can disappear silently.
        let storeDirectory = await storage.path.deletingLastPathComponent()
        let rewritten = MemoryRecallQueryExpansion.rewrite(
            query.text,
            names: try MemoryRecallQueryExpansion.names(storeDirectory: storeDirectory)
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
        // Judge explicit recall's bounded corpus once; other callers retain their disclosure window without repeated judgment.
        let storageTopK: Int
        if query.requiresRelevance == true || (query.offset ?? 0) > 0 {
            storageTopK = memoryStoredRowCap
        } else {
            storageTopK = (query.surface != nil || query.persona != nil)
                ? min(memoryStoredRowCap, max(topK, topK * 8)) : topK
        }
        // Zero vectors have no direction; returning empty recall would hide unavailable semantics.
        let hasUsableVector = !qvec.isEmpty && qvec.contains { $0 != 0 && $0.isFinite }
        let rewrittenEmbedding: (vector: [Float], epoch: MemoryEmbeddingEpoch)? = rewritten != nil
            && embedded.vectors.count > 1 ? (embedded.vectors[1], embedded.epoch) : nil
        metrics.timings["embedding_ms"] = metrics.milliseconds(since: embeddingStarted)
        try Task.checkCancellation()
        return (qvec, rewritten, rewrittenEmbedding, embedded, topK, storageTopK, hasUsableVector)
    }

    private func selectRecallRows(_ query: MemoryV2RecallRequest, storage: MemoryStorage, vectors: RecallVectors,
                                  metrics: RecallTimings, turn: Turn?) async throws -> RecallSelection {
        let (qvec, rewritten, rewrittenEmbedding, embedded, topK, storageTopK, hasUsableVector) = vectors
        let canonicalStorage = storage
        func disclosedRows(_ rows: [ScoredMemoryRecord]) -> [ScoredMemoryRecord] {
            let now = Date()
            var seen: Set<String> = []
            return rows.sorted { $0.score == $1.score ? $0.record.id < $1.record.id : $0.score > $1.score }.filter { scoredRecord in
                guard MemoryRecallScoring.hasStarted(validFrom: scoredRecord.record.validFrom, at: now),
                      let classification = MemoryRecordDisclosurePolicy.classify(scoredRecord.record, at: now) else {
                    return false
                }
                guard classification.permits(surface: query.surface, personaID: query.persona) else {
                    return false
                }
                let key = MemoryStorage.comparisonKey(scoredRecord.record.text, mode: .recall)
                return key.isEmpty || seen.insert(key).inserted
            }
        }
        // Read BEFORE candidates so a concurrent mutation can only cause a later cache miss, never label an older read with a newer generation.
        let generationStarted = ProcessInfo.processInfo.systemUptime
        let generation: String?
        if query.requiresRelevance == true {
            generation = try await canonicalStorage.recallJudgmentGeneration()
        } else {
            generation = nil
        }
        metrics.timings["generation_ms"] = metrics.milliseconds(since: generationStarted)
        var retrievalStarted = ProcessInfo.processInfo.systemUptime
        guard hasUsableVector else {
            throw MemoryStorageError.searchFailure("The memory search model returned no usable query vector.",
                code: "memory_search_vector_unusable", instruction: "Inspect Doctor's model findings; repair the unusable query vector before searching again.")
        }
        // Keep each voice's full ranking; deduplication and record conversion stop at its requested window, including when disclosure widens it.
        let candidates: MemoryStorage.RecallCache
        do {
            candidates = try await canonicalStorage.recallCandidates(queryEpoch: embedded.epoch)
        } catch let error as MemoryStorageError {
            guard case .embeddingEpochMismatch = error else { throw error }
            requestEmbeddingEpochReconcile()
            throw Self.recallCorpusConverging
        }
        var readings: [(embedding: [Float], text: String?)] = [(qvec, query.text)]
        if let rewritten, let other = rewrittenEmbedding, other.vector.contains(where: { $0 != 0 && $0.isFinite }) {
            readings.append((other.vector, rewritten))
        }
        let ranked = try MemoryStorage.rankedRecall(readings: readings, persona: query.persona, cache: candidates)
        let primaryRanked = ranked[0]
        let rewrittenRanked = ranked.dropFirst().first
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
        metrics.timings["retrieval_ms"] = metrics.milliseconds(since: retrievalStarted)
        metrics.timings["retrieval_passes"] = 1
        try Task.checkCancellation()
        let disclosureStarted = ProcessInfo.processInfo.systemUptime
        var disclosed = disclosedRows(scored)
        var disclosureFilteredCount = scored.count - disclosed.count
        metrics.timings["disclosure_ms"] = metrics.milliseconds(since: disclosureStarted)
        metrics.timings["candidates"] = Double(disclosed.count)
        let candidateCount = disclosed.count
        let offset = min(max(0, query.offset ?? 0), candidateCount)
        disclosed = Array(disclosed.dropFirst(offset))
        let examinedCount = MemoryRecallScoring.relevanceCandidateLimit(topK: topK, count: disclosed.count)
        let rankedCandidates = disclosed
        if query.requiresRelevance == true, !disclosed.isEmpty {
            let relevanceStarted = ProcessInfo.processInfo.systemUptime
            let admitted = try await AdaptiveMemoryPromoter.shared.relevantRecallIDs(query: query.text,
                candidates: disclosed.map {
                    MemoryManagerExistingMemory(id: $0.record.id, content: $0.record.text,
                        kind: $0.record.memoryKind ?? MemoryRecallScoring.kind(of: $0.record.extras))
                }, generation: generation, topK: topK, turn: turn)
            metrics.timings["relevance_ms", default: 0] += metrics.milliseconds(since: relevanceStarted)
            disclosed = disclosed.filter { admitted.contains($0.record.id) }
        }
        // Non-judged callers retain the disclosure refill. Explicit recall already fetched the row cap and never repeats retrieval or judgment.
        if query.requiresRelevance != true, disclosed.count < topK, scored.count >= storageTopK, storageTopK < memoryStoredRowCap {
            retrievalStarted = ProcessInfo.processInfo.systemUptime
            scored = retrieve(memoryStoredRowCap)
            metrics.timings["retrieval_ms", default: 0] += metrics.milliseconds(since: retrievalStarted)
            try Task.checkCancellation()
            let allDisclosed = disclosedRows(scored)
            disclosureFilteredCount = scored.count - allDisclosed.count
            disclosed = Array(allDisclosed.dropFirst(offset))
        }
        return (disclosed, rankedCandidates, scored, disclosureFilteredCount, candidateCount, offset, examinedCount)
    }

    private func makeRecallResponse(_ query: MemoryV2RecallRequest, storage: MemoryStorage, selection: RecallSelection,
                                    topK: Int, storageTopK: Int, metrics: RecallTimings, recallStarted: Double,
                                    recordingUsage: Bool) async throws -> MemoryV2RecallResponse {
        let (disclosed, rankedCandidates, scored, disclosureFilteredCount, candidateCount, offset, examined) = selection
        var examinedCount = examined
        // storageTopK is a wider disclosure candidate window, not the result budget: cut AFTER disclosure at the actual requested size.
        let selectionStarted = ProcessInfo.processInfo.systemUptime
        let sorted = Array(disclosed.sorted { $0.score == $1.score ? $0.record.id < $1.record.id : $0.score > $1.score }.prefix(max(0, topK)))
        // The judge settles the whole prefix through the kth admitted row. If it finds fewer, it examined its entire bounded candidate window. Continue after
        // that prefix, including rejected rows, so even an empty page makes progress without judging the same evidence again.
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
        metrics.timings["selection_ms"] = metrics.milliseconds(since: selectionStarted)
        try Task.checkCancellation()
        let current = try await storage.checkedRecallRows(sorted, surface: query.surface, persona: query.persona,
                                                         recordingUsage: recordingUsage)
        metrics.timings["results"] = Double(current.count)
        let trust = MemoryDataProvenance.reading(dataRoot: storage.dataRoot, current.map { $0.record.extras })
        let hits: [MemoryRecallHit] = current.map { sr in
            let canonicalText = MemoryTextClip.memoryDisplayText(
                sr.record.text,
                kind: sr.record.memoryKind
            )
            let displayText = (MemorySenseProvenance.warning(in: sr.record.extras).map { "[\($0)]\n" } ?? "") + canonicalText
            let content = MemoryTextClip.sentenceClip(displayText, cap: memoryRecallContentCap)
            var extras: [String: JSONValue] = ["id": .string(sr.record.id)]
            // The hit carries the memory's roots as stored; its steer and short form are read from them, never stored beside them.
            if case .object(let metadata)? = sr.record.extras, let roots = metadata[MemoryRoot.key] { extras[MemoryRoot.key] = roots }
            if let origin = MemoryMoments.recallOrigin(source: sr.record.sourceRunId, metadata: sr.record.extras, dataRoot: canonicalDataRoot
                ?? defaultDataRoot()) {
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
            // Carry kind for the renderer's optional provenance marker.
            if let kind = sr.record.memoryKind?
                .trimmingCharacters(in: .whitespacesAndNewlines),
               !kind.isEmpty {
                extras["kind"] = .string(kind)
            }
            // Preserve canonical fact dates independently of storage chronology and current validity.
            if let value = sr.record.validFrom { extras["valid_from"] = .string(value) }
            if let value = sr.record.validTo { extras["valid_to"] = .string(value) }
            if let value = sr.record.observedAt { extras["observed_at"] = .string(value) }
            return MemoryRecallHit(
                score: sr.score,
                sessionId: sr.record.sourceRunId,
                role: nil,
                ts: MemoryDataProvenance.firstKnown(sr.record.extras, trust: trust),
                preview: MemoryTextClip.sentenceClip(displayText, cap: memoryRecallPreviewCap),
                content: content,
                source: "swift-native",
                extras: .object(extras)
            )
        }
        metrics.timings["total_ms"] = metrics.milliseconds(since: recallStarted)
        return MemoryV2RecallResponse(
            hits: hits,
            scored: current,
            total: current.count,
            disclosureFilteredCount: disclosureFilteredCount + sorted.count - current.count,
            timings: metrics.timings,
            capped: capped,
            hasMore: hasMore,
            nextOffset: hasMore ? next : nil
        )
    }

    /// Exact-ID recovery for a previously recalled excerpt. Does not embed, rank, enumerate records, or expose an admin/lineage bypass.
    public func readMemoryRecord(id: String, surface: String) async throws -> MemoryRecord? {
        try await readMemoryRecord(id: id, surface: surface, includingNoncurrent: false)
    }

    package func readMemoryRecord(id: String, surface: String, includingNoncurrent: Bool) async throws -> MemoryRecord? {
        guard let id = Self.exactRecallID(id) else {
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
              includingNoncurrent || MemoryRecallScoring.hasStarted(validFrom: record.validFrom, at: Date()),
              record.id == id,
              let disclosure = MemoryRecordDisclosurePolicy.classify(record, includingNoncurrent: includingNoncurrent),
              disclosure.permits(surface: surface, personaID: nil),
              MemoryCandidateQuality.isDurableCandidate(text: record.text) else { return nil }
        let tombstoned = try await storage.isTombstoned(content: record.text)
        guard !tombstoned else { return nil }
        guard !MemoryStorage.metadataFlag(record.extras, MemoryStorage.pendingAdmissionKey) else {
            throw ToolFailureError("This memory is awaiting admission checks and cannot be recalled yet.", effects: .none,
                nextCall: ToolFailureError.call("app", ["page": .string("memories")]), code: "memory_admission_pending",
                instruction: "Check memory admission progress before recalling this record again.", recovery: .inspect)
        }
        try Task.checkCancellation()
        let checked = try await storage.checkedRecallRows([ScoredMemoryRecord(record: record, score: 0)],
            surface: surface, persona: nil, recordingUsage: false, includingNoncurrent: includingNoncurrent)
        return checked.first?.record
    }

    package func currentReplacementID(for record: MemoryRecord, surface: String) async throws -> String? {
        let metadata = record.extras?.objectValue
        guard let id = metadata?["corrected_by"]?.stringValue ?? metadata?["superseded_by"]?.stringValue,
              Self.exactRecallID(id) == id, id != record.id else { return nil }
        guard let storage else { throw MemoryV2Error.storageUnavailable }
        try Task.checkCancellation()
        return try await storage.currentRecallID(id: id, surface: surface)
    }

    private static func exactRecallID(_ id: String) -> String? {
        let trimmed = id.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty && trimmed.utf8.count <= 512 ? trimmed : nil
    }
}
