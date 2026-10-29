import Context
import DreamREMCycle
import Foundation
import Senses
import MemoryV2
import NativeAgentCore
import PersonaEngine
import PersistenceCore
import TurnTrace
import WorkshopExecution
import NativeAgentShared
// Blueprint: | `NativeContextFlowRuntime+QueryEmbedding.swift` | `NativeContextFlowRuntime` query embeddings; primary-first readings, joined tickets, epoch-checked settlement and bounded cache; task ownership stays on the runtime actor |

extension NativeContextFlowRuntime {
    public func beginQueryEmbedding(_ text: String, ownWords: String?) async -> ContextQueryEmbeddingTicket? {
        let epoch = semanticQueryEpoch
        let query = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return nil }
        guard lifecycle == nil else {
            return resolvedConfiguration().mode == .active
                ? ContextQueryEmbeddingTicket(unavailable: "memory search is still starting")
                : nil
        }
        guard let coordinator else {
            return resolvedConfiguration().mode == .active
                ? ContextQueryEmbeddingTicket(unavailable: "memory search is still starting")
                : nil
        }
        guard await coordinator.mode == .active,
              let memory = memoryRuntime else { return nil }
        guard epoch == semanticQueryEpoch, lifecycle == nil, self.coordinator === coordinator,
              !Task.isCancelled else {
            return ContextQueryEmbeddingTicket(unavailable: Self.retiredSemanticQueryCause)
        }
        guard query.utf8.count <= 8 * 1_024 else {
            return ContextQueryEmbeddingTicket(unavailable: "the message is over 8 KB, too long to embed")
        }
        guard let runtime = await memory.embeddingRuntimeSnapshot(),
              runtime.effectiveBackend != ManagedEmbeddingProvider.failClosedBackend,
              runtime.coreMLLoaded
                || runtime.effectiveBackend == ManagedEmbeddingProvider.mockBackend else {
            return ContextQueryEmbeddingTicket(unavailable: "the memory-search model is not loaded")
        }
        // Backend inspection suspends; stop/reload must prevent admission against a drained runtime.
        guard epoch == semanticQueryEpoch, lifecycle == nil, self.coordinator === coordinator,
              !Task.isCancelled else {
            return ContextQueryEmbeddingTicket(unavailable: Self.retiredSemanticQueryCause)
        }
        let normalized = query.split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
            .lowercased()
        // Rewrite only this turn's words with its speaker/addressee; composite queries stay intact.
        let names = MemoryRecallQueryExpansion.names(
            storeDirectory: dataRoot.appendingPathComponent("memory", isDirectory: true)
        )
        let alternateQuery = ownWords == nil ? MemoryRecallQueryExpansion.rewriteIncoming(query, names: names) : nil
        // A follow-up's own words and other voice share the further-readings batch.
        let own = ownWords.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .flatMap { $0.isEmpty || $0 == query || $0.utf8.count > 8 * 1_024 ? nil : $0 }
        let ownTexts = own.map { [$0] + (MemoryRecallQueryExpansion.rewriteIncoming($0, names: names).map { [$0] } ?? []) } ?? []
        // Use the snapshot's vector-space identity without rereading backend/mode files.
        guard let embeddingEpoch = runtime.embeddingEpoch else {
            return ContextQueryEmbeddingTicket(unavailable: "the memory-search model named no vector space")
        }
        let key = ContextStableID.digest(parts: [
            "semantic-query-v2",
            embeddingEpoch,
            normalized,
            alternateQuery ?? "",
        ] + ownTexts)
        if let cached = semanticQueryCache[key] {
            touchSemanticQueryCacheKey(key)
            let ticket = ContextQueryEmbeddingTicket()
            ticket.publish(
                cached.values,
                alternate: cached.alternateValues,
                ownWords: cached.ownWordsValues,
                modelFingerprint: cached.modelFingerprint,
                modelID: cached.modelID
            )
            return ticket
        }
        if let pending = semanticQueryTickets[key] { return pending }

        // Optional semantic queries have bounded admission; overflow proceeds lexically without waiting.
        guard semanticQueryTasks.count < Self.maximumConcurrentSemanticQueries else {
            return ContextQueryEmbeddingTicket(unavailable: "\(Self.maximumConcurrentSemanticQueries) query embeddings are already in flight")
        }
        let ticket = ContextQueryEmbeddingTicket()
        semanticQueryTickets[key] = ticket
        let modelID = runtime.modelId
        let taskID = UUID()
        // Publish primary before the further-readings batch; deadlines use what has landed.
        let secondaryTexts = (alternateQuery.map { [$0] } ?? []) + ownTexts
        semanticQueryTasks[taskID] = Task(priority: .userInitiated) { [weak self, memory] in
            let primary: Result<ContextQueryEmbeddingValue, Error>
            do {
                let batch = try await memory.embedQueriesWithEpoch([query])
                guard let first = batch.vectors.first else { throw MemoryV2Error.underlying("embedder returned no vectors") }
                primary = .success(ContextQueryEmbeddingValue(
                    values: first, modelFingerprint: batch.epoch.rawValue, modelID: modelID
                ))
            } catch {
                primary = .failure(error)
            }
            guard let landed = await self?.completeSemanticQuery(
                key: key, taskID: taskID, epoch: epoch, expectedEmbeddingEpoch: embeddingEpoch,
                value: primary, readingsFollow: !secondaryTexts.isEmpty
            ) else { return }
            // The further readings, in one batch call; a failure leaves the primary alone.
            let readings = try? await memory.embedQueriesWithEpoch(secondaryTexts)
            let usable = readings.flatMap { $0.epoch.rawValue == embeddingEpoch ? $0.vectors : nil } ?? []
            let ownStart = alternateQuery == nil ? 0 : 1
            await self?.completeSemanticQueryReadings(
                key: key, taskID: taskID, epoch: epoch, primary: landed,
                alternate: alternateQuery != nil ? usable.first : nil,
                ownWords: usable.count > ownStart ? Array(usable[ownStart...]) : []
            )
        }
        return ticket
    }

    /// Returns the published primary for further readings, or nil when settled/retired.
    private func completeSemanticQuery(
        key: String,
        taskID: UUID,
        epoch: UInt64,
        expectedEmbeddingEpoch: String,
        value result: Result<ContextQueryEmbeddingValue, Error>,
        readingsFollow: Bool
    ) -> ContextQueryEmbeddingValue? {
        guard epoch == semanticQueryEpoch else { semanticQueryTasks[taskID] = nil; return nil }
        func settle() -> ContextQueryEmbeddingTicket? {
            semanticQueryTasks[taskID] = nil
            return semanticQueryTickets.removeValue(forKey: key)
        }
        let value: ContextQueryEmbeddingValue
        switch result {
        case .failure(let error):
            settle()?.fail("query embedding failed: \(error.localizedDescription)")
            return nil
        case .success(let embedded):
            value = embedded
        }
        guard !value.values.isEmpty, value.values.allSatisfy(\.isFinite) else {
            settle()?.fail("the memory-search model returned an unusable query vector")
            return nil
        }
        guard value.modelFingerprint == expectedEmbeddingEpoch else {
            settle()?.fail("the memory-search model changed while the query embedded")
            return nil
        }
        guard readingsFollow else {
            let ticket = settle()
            cacheSemanticQuery(value, key: key)
            ticket?.publish(value.values, modelFingerprint: value.modelFingerprint, modelID: value.modelID)
            return nil
        }
        // Keep the joinable ticket in flight and cache only after its further readings land.
        semanticQueryTickets[key]?.publish(
            value.values, modelFingerprint: value.modelFingerprint, modelID: value.modelID, readingsFollow: true
        )
        return value
    }

    /// Attach further readings, release waiters and cache the whole value.
    private func completeSemanticQueryReadings(
        key: String,
        taskID: UUID,
        epoch: UInt64,
        primary: ContextQueryEmbeddingValue,
        alternate: [Float]?,
        ownWords: [[Float]]
    ) {
        semanticQueryTasks[taskID] = nil
        guard epoch == semanticQueryEpoch else { return }
        let value = ContextQueryEmbeddingValue(
            values: primary.values, alternateValues: alternate, ownWordsValues: ownWords,
            modelFingerprint: primary.modelFingerprint, modelID: primary.modelID
        )
        let ticket = semanticQueryTickets.removeValue(forKey: key)
        // The first request's ticket carries every reading cached below.
        ticket?.attachReadings(value)
        // Epoch checks above reject changed vector spaces; never cache an incomplete batch.
        guard value.alternateValues != nil || !value.ownWordsValues.isEmpty else { return }
        cacheSemanticQuery(value, key: key)
    }

    private func cacheSemanticQuery(_ value: ContextQueryEmbeddingValue, key: String) {
        semanticQueryCache[key] = value
        touchSemanticQueryCacheKey(key)
        while semanticQueryCacheOrder.count > 32 {
            let evicted = semanticQueryCacheOrder.removeFirst()
            semanticQueryCache[evicted] = nil
        }
    }

    private func touchSemanticQueryCacheKey(_ key: String) {
        semanticQueryCacheOrder.removeAll { $0 == key }
        semanticQueryCacheOrder.append(key)
    }
}
