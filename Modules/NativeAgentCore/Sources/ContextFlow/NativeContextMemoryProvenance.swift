import Context
import Foundation

// Blueprint: | `NativeContextMemoryProvenance.swift` | `NativeContextMemoryProvenance.attach`: advisory reverse lookup on the exact prepared-turn lease; misses never invent record identity |

/// Turn-local accounting for the reverse lookup from selected packet atoms to
/// canonical MemoryV2 record identities. This is advisory diagnostics only:
/// the packet stays identity-free and an index miss never invents provenance.
struct NativeContextMemoryProvenanceResolution: Sendable, Equatable {
    let requestedMemoryAtomCount: Int
    let resolvedMemoryAtomCount: Int

    var unresolvedMemoryAtomCount: Int {
        requestedMemoryAtomCount - resolvedMemoryAtomCount
    }
}

enum NativeContextMemoryProvenance {
    /// Attaches to the exact prepared-turn instance that owns the generation
    /// lease. Rewrapping would be unsafe because it could release the live
    /// generation early; packet bytes and its receipt intentionally do not
    /// change here.
    static func attach(
        to prepared: ContextPreparedTurn,
        index: MemoryAtomRecordIndex
    ) -> NativeContextMemoryProvenanceResolution {
        let packet = prepared.packet
        let memoryAtomIDs = packet.selectedItems.compactMap { item -> ContextAtomID? in
            switch item.pointer.kind {
            case .memory, .correction:
                return item.pointer.atomID
            default:
                return nil
            }
        }
        // The why receipt names every scored candidate's record; only the
        // selected ones count as use.
        let mapping = index.recordMap(
            for: memoryAtomIDs + packet.receipt.candidateScores.map(\.atomID),
            generationID: packet.generationID
        )
        let selected = mapping.filter { memoryAtomIDs.contains($0.key) }
        if !mapping.isEmpty {
            prepared.attachMemoryRecordProvenance(Array(selected.values), atomRecords: mapping)
        }
        return NativeContextMemoryProvenanceResolution(
            requestedMemoryAtomCount: memoryAtomIDs.count,
            resolvedMemoryAtomCount: selected.count
        )
    }
}
