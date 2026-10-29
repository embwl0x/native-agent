import Foundation

// Blueprint: | `ContextPreparedTurn+CameToMind.swift` | `cameToMind(by:embedding:excluding:limit:)`: a moment's words as one more reading of the turn's own need, so what they reads or what happens brings memories to mind by the rule their message does (two deviations, rest, their disclosure), minus what the turn already holds |

extension NeedSignal {
    /// The same need, asked of a moment: what she just read or what just
    /// happened, in place of the message. Her authorization, rest state and
    /// embedding model stay the turn's; nothing else of the message rides along.
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

extension ContextPreparedTurn {
    /// What a moment brings to mind: the memories its words single out among
    /// hers, by the turn's own rule, that this turn does not already hold.
    /// Empty when nothing stands out; a moment owes her nothing.
    public func cameToMind(
        by text: String,
        embedding: ContextQueryEmbeddingValue,
        excluding: Set<ContextAtomID> = [],
        limit: Int
    ) -> [ContextPacketItem] {
        guard limit > 0, !text.isEmpty,
              let picked = try? ContextSelector(memoryStandout: ContextSelectionConfiguration.ambientStandoutDeviations).select(
                need.moment(text, embedding: embedding, limit: limit),
                from: generation, pinnedTo: lease.snapshot
              ) else { return [] }
        let held = Set(packet.selectedItems.map(\.pointer.atomID)).union(excluding)
        return Array(picked.selectedItems.lazy
            .filter { $0.pointer.kind == .memory && !held.contains($0.pointer.atomID) }
            .prefix(limit))
    }
}
