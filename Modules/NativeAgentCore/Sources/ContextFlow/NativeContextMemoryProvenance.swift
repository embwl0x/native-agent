import Context
import Foundation

// Blueprint: | `NativeContextMemoryProvenance.swift` | `NativeContextMemoryProvenance.attach`: advisory lookup on the exact lease |

/// Provenance is advisory: keep the packet identity-free and never invent a record identity for an index miss.
struct NativeContextMemoryProvenanceResolution: Sendable, Equatable {
    let requestedMemoryAtomCount: Int
    let resolvedMemoryAtomCount: Int

    var unresolvedMemoryAtomCount: Int {
        requestedMemoryAtomCount - resolvedMemoryAtomCount
    }
}

enum NativeContextMemoryProvenance {
    /// Attach to the exact prepared-turn lease; rewrapping could release its live generation early.
    static func attach(
        to prepared: ContextPreparedTurn
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
        // The why receipt includes all scored candidates; only selected records count as use.
        let requested = Set(memoryAtomIDs + packet.receipt.candidateScores.map(\.atomID))
        let records = Dictionary(prepared.generation.sources.compactMap { source -> (ContextSourceID, String)? in
            guard source.descriptor.owner == MemoryContext.owner,
                  let recordID = MemoryContext.recordID(inLocator: source.descriptor.canonicalLocator) else { return nil }
            return (source.descriptor.id, recordID)
        }, uniquingKeysWith: { first, _ in first })
        let mapping = Dictionary(prepared.generation.atoms.compactMap { atom -> (ContextAtomID, String)? in
            guard atom.validToGeneration == nil, requested.contains(atom.draft.id),
                  let recordID = records[atom.draft.sourceID] else { return nil }
            return (atom.draft.id, recordID)
        }, uniquingKeysWith: { first, _ in first })
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
