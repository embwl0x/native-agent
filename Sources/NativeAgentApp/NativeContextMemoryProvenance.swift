import Context
import Foundation

/// Turn-local accounting for the reverse lookup from selected packet atoms to
/// canonical MemoryV2 record identities. This is advisory diagnostics only:
/// the packet stays identity-free and an index miss never invents provenance.
struct NativeContextMemoryProvenanceResolution: Sendable, Equatable {
    let requestedMemoryAtomCount: Int
    let resolvedMemoryAtomCount: Int
    let packetUnchanged: Bool

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
        let packetBeforeAttachment = prepared.packet
        let memoryAtomIDs = packetBeforeAttachment.selectedItems.compactMap { item -> ContextAtomID? in
            switch item.pointer.kind {
            case .memory, .correction:
                return item.pointer.atomID
            default:
                return nil
            }
        }
        let recordIDs = index.recordIDs(for: memoryAtomIDs)
        if !recordIDs.isEmpty {
            prepared.attachMemoryRecordProvenance(recordIDs)
        }
        return NativeContextMemoryProvenanceResolution(
            requestedMemoryAtomCount: memoryAtomIDs.count,
            resolvedMemoryAtomCount: recordIDs.count,
            packetUnchanged: prepared.packet == packetBeforeAttachment
        )
    }
}
