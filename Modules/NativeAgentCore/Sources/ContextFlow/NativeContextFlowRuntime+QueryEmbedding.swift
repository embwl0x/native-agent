import Context
import DreamREMCycle
import Foundation
import Senses
import MemoryV2
import NativeAgentCore
import PersonaEngine
import PersistenceCore
import TurnTrace
import NativeAgentShared
// Blueprint: | `NativeContextFlowRuntime+QueryEmbedding.swift` | `NativeContextFlowRuntime`: actor-owned joined embeddings and epoch-checked cache |

extension NativeContextFlowRuntime {
    public func beginQueryEmbedding(_ text: String, ownWords: String?, turn: Turn) async -> ContextQueryEmbeddingTicket? {
        let epoch = semanticQueryEpoch
        let query = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return nil }
        let configuration: NativeContextFlowConfiguration
        do { configuration = try resolvedConfiguration().get() }
        catch { return ContextQueryEmbeddingTicket(unavailable: error.localizedDescription) }
        guard lifecycle == nil else {
            return configuration.mode == .active
                ? ContextQueryEmbeddingTicket(unavailable: "memory search is still starting")
                : nil
        }
        guard let coordinator else {
            return configuration.mode == .active
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
        let names: MemoryRecallQueryExpansion.Names
        do {
            names = try MemoryRecallQueryExpansion.names(
                storeDirectory: dataRoot.appendingPathComponent("memory", isDirectory: true))
        } catch {
            return ContextQueryEmbeddingTicket(
                unavailable: "Saved identity is unreadable: \(error.localizedDescription). Repair memory/profile.json before name-aware recall.")
        }
        let alternateQuery = ownWords == nil ? MemoryRecallQueryExpansion.rewriteIncoming(query, names: names, turn: turn) : nil
        // A follow-up's own words and other voice share the further-readings batch.
        let own = ownWords.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .flatMap { $0.isEmpty || $0 == query ? nil : $0 }
        if let own, own.utf8.count > 8 * 1_024 {
            return ContextQueryEmbeddingTicket(unavailable: "The follow-up's own words exceed the semantic reader's 8 KB bound.")
        }
        let ownTexts = own.map { [$0] + (MemoryRecallQueryExpansion.rewriteIncoming($0, names: names, turn: turn).map { [$0] } ?? []) } ?? []
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

        // Bounded admission reports unavailable; it never substitutes lexical recall.
        guard semanticQueryTasks.count < Self.maximumConcurrentSemanticQueries else {
            return ContextQueryEmbeddingTicket(unavailable: "\(Self.maximumConcurrentSemanticQueries) query embeddings are already in flight")
        }
        let ticket = ContextQueryEmbeddingTicket()
        semanticQueryTickets[key] = ticket
        let modelID = runtime.modelId
        let taskID = UUID()
        let texts = [query] + (alternateQuery.map { [$0] } ?? []) + ownTexts
        semanticQueryTasks[taskID] = Task(priority: .userInitiated) { [weak self, memory] in
            let result: Result<ContextQueryEmbeddingValue, Error>
            do {
                let batch = try await memory.embedQueriesWithEpoch(texts)
                guard batch.epoch.rawValue == embeddingEpoch, batch.vectors.count == texts.count,
                      let primary = batch.vectors.first else {
                    throw NativeSemanticQueryError(detail: "The query batch has incomplete readings or a changed vector space.")
                }
                let ownStart = alternateQuery == nil ? 1 : 2
                let value = ContextQueryEmbeddingValue(
                    values: primary,
                    alternateValues: alternateQuery == nil ? nil : batch.vectors[1],
                    ownWordsValues: Array(batch.vectors.dropFirst(ownStart)),
                    modelFingerprint: batch.epoch.rawValue, modelID: modelID)
                guard value.isUsable else {
                    throw NativeSemanticQueryError(detail: "The query batch contains malformed readings.")
                }
                result = .success(value)
            } catch { result = .failure(error) }
            await self?.completeSemanticQuery(key: key, taskID: taskID, epoch: epoch, result: result)
        }
        return ticket
    }

    private func completeSemanticQuery(
        key: String, taskID: UUID, epoch: UInt64,
        result: Result<ContextQueryEmbeddingValue, Error>
    ) {
        semanticQueryTasks[taskID] = nil
        guard epoch == semanticQueryEpoch else { return }
        let ticket = semanticQueryTickets.removeValue(forKey: key)
        switch result {
        case .failure(let error):
            ticket?.fail("Query embedding failed: \(error.localizedDescription)")
        case .success(let value):
            cacheSemanticQuery(value, key: key)
            ticket?.publish(value.values, alternate: value.alternateValues, ownWords: value.ownWordsValues,
                            modelFingerprint: value.modelFingerprint, modelID: value.modelID)
        }
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
