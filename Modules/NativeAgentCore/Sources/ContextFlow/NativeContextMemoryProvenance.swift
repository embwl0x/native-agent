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
        // The why receipt names every scored candidate's record; only the
        // selected ones count as use.
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
