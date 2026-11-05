import Foundation

// Blueprint: | `ContextPreparedTurn+CameToMind.swift` | `cameToMind(by:embedding:excluding:limit:)`, `ambientStandoutDeviations` |

extension NeedSignal {
    /// A moment replaces only the query: retain the turn's authorization, rest state and embedding model.
    func moment(_ text: String, embedding: ContextQueryEmbeddingValue, limit: Int) -> NeedSignal {
        NeedSignal(
            message: text,
            surface: surface,
            origin: origin,
            authorization: authorization,
            sessionID: sessionID,
            memoryReachability: memoryReachability,
            servedTurnsAgo: servedTurnsAgo,
            deletedAtomIDs: deletedAtomIDs,
            tombstonedAtomIDs: tombstonedAtomIDs,
            staleRuntimeAtomIDs: staleRuntimeAtomIDs,
            secretBearingAtomIDs: secretBearingAtomIDs,
            queryEmbedding: embedding.values,
            alternateQueryEmbedding: embedding.alternateValues,
            queryEmbeddingModelFingerprint: embedding.modelFingerprint,
            queryEmbeddingModelID: embedding.modelID,
            availableGenerationID: availableGenerationID,
            characterBudget: 2_000,
            memoryAtomRowLimit: limit
        )
    }
}

public struct ContextAmbientRecallResult: Sendable {
    public let items: [ContextPacketItem]
    public let unavailable: [ContextDegradedSourceNotice]
}

extension ContextPreparedTurn {
    /// Apply the turn's relevance rule without duplicating held memories; nothing standing out is a valid empty result.
    public func cameToMind(
        by text: String,
        embedding: ContextQueryEmbeddingValue,
        excluding: Set<ContextAtomID> = [],
        limit: Int
    ) async throws -> ContextAmbientRecallResult {
        guard limit > 0, !text.isEmpty else { return ContextAmbientRecallResult(items: [], unavailable: []) }
        let picked = try ContextSelector(memoryStandout: ContextSelectionConfiguration.ambientStandoutDeviations).select(
                need.moment(text, embedding: embedding, limit: limit),
                from: generation, pinnedTo: lease.snapshot,
                sourceReadFailures: packet.degradedSources
              )
        let held = Set(packet.selectedItems.map(\.pointer.atomID)).union(excluding)
        let candidates = Array(picked.selectedItems.lazy
            .filter { $0.pointer.kind == .memory && !held.contains($0.pointer.atomID) }
            .prefix(limit))
        var verified: [ContextPacketItem] = []
        var unavailable = picked.degradedSources
        for item in candidates {
            let check = await verify(item.pointer)
            unavailable += check.unverified
            if !check.atomIDs.contains(item.pointer.atomID), check.unverified.isEmpty { verified.append(item) }
        }
        return ContextAmbientRecallResult(items: verified, unavailable: unavailable)
    }
}
