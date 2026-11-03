import Foundation

// Blueprint: | `ContextPreparedTurn+CameToMind.swift` | `cameToMind(by:embedding:excluding:limit:)`: ambient standout configured by `ambientStandoutDeviations`, conversation rest and canonical point-of-use verification on the turn's lease, minus what it already holds |

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

public struct ContextAmbientRecallResult: Sendable {
    public let items: [ContextPacketItem]
    public let unavailable: [ContextDegradedSourceNotice]
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
