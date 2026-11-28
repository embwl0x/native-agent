import Synchronization
import Foundation
import HashTreeCollections

// Blueprint: | `ContextArena.swift` | `ContextArena`: generations, leases, pressure and post-lock health invalidations |

public enum ContextGenerationSnapshotError: Error, Equatable, Sendable {
    case negativeGeneration
    case emptySourceFingerprint
    case duplicatePersona(ContextPersonaID)
}

/// Immutable, generation-consistent data used for an entire provider/tool loop.
public struct ContextGenerationSnapshot: Sendable, Equatable {
    public private(set) var generationID: Int64
    public private(set) var sourceFingerprint: String
    public private(set) var requiredDocumentMirrors: [RequiredDocumentMirror]
    public private(set) var selectionIndex: TreeDictionary<ContextAtomID, ContextSelectionIndexEntry>
    private(set) var tokenDocFreq: TreeDictionary<String, Int>
    private(set) var vectorIndex: ContextVectorIndex?

    public init(
        generationID: Int64,
        sourceFingerprint: String,
        requiredDocumentMirrors: [RequiredDocumentMirror] = [],
        selectionIndex: [ContextAtomID: ContextSelectionIndexEntry] = [:],
        vectorAtoms: [ContextStoredAtom]? = nil
    ) throws {
        self.generationID = generationID
        self.sourceFingerprint = sourceFingerprint
        self.requiredDocumentMirrors = try Self.validate(generationID, sourceFingerprint, requiredDocumentMirrors)
        self.selectionIndex = TreeDictionary(selectionIndex)
        tokenDocFreq = [:]
        for entry in selectionIndex.values {
            for token in entry.searchableTokens { tokenDocFreq[token, default: 0] += 1 }
        }
        vectorIndex = vectorAtoms.map(ContextVectorIndex.init)
    }

    func patching(generation: ContextGenerationRecord, mirrors: [RequiredDocumentMirror],
                  removedAtomIDs: Set<ContextAtomID>, changedAtoms: [ContextStoredAtom]) throws -> Self {
        var next = self
        next.generationID = generation.id
        next.sourceFingerprint = generation.sourceFingerprint
        next.requiredDocumentMirrors = try Self.validate(generation.id, generation.sourceFingerprint, mirrors)
        let changedIDs = Set(changedAtoms.map(\.draft.id))
        for id in removedAtomIDs.union(changedIDs) {
            if let old = next.selectionIndex.removeValue(forKey: id) {
                for token in old.searchableTokens {
                    let count = next.tokenDocFreq[token, default: 0] - 1
                    next.tokenDocFreq[token] = count == 0 ? nil : count
                }
            }
        }
        for id in removedAtomIDs.subtracting(changedIDs) { next.vectorIndex?.remove(id) }
        for atom in changedAtoms {
            let entry = ContextSelectionIndexEntry(atom: atom.draft)
            next.selectionIndex[atom.draft.id] = entry
            for token in entry.searchableTokens { next.tokenDocFreq[token, default: 0] += 1 }
            next.vectorIndex?.set(atom)
        }
        return next
    }

    private static func validate(_ id: Int64, _ fingerprint: String,
                                 _ mirrors: [RequiredDocumentMirror]) throws -> [RequiredDocumentMirror] {
        guard id >= 0 else { throw ContextGenerationSnapshotError.negativeGeneration }
        guard !fingerprint.isEmpty else { throw ContextGenerationSnapshotError.emptySourceFingerprint }
        var seen = Set<ContextPersonaID>()
        for mirror in mirrors where !seen.insert(mirror.personaID).inserted {
            throw ContextGenerationSnapshotError.duplicatePersona(mirror.personaID)
        }
        return mirrors.sorted { $0.personaID < $1.personaID }
    }

}

public enum ContextArenaPublicationFailure: Error, Equatable, Sendable {
    case generationNotNewer(candidate: Int64, current: Int64)
    case rehydrationGenerationMismatch(candidate: Int64, current: Int64)
    case rehydrationFingerprintMismatch(candidate: String, current: String)
}

public enum ContextArenaPublicationOutcome: Equatable, Sendable {
    case published(generationID: Int64, previousGenerationID: Int64?)
    case rehydrated(generationID: Int64)
    case retainedLastGood(failure: ContextArenaPublicationFailure, generationID: Int64?)
}

public enum ContextArenaPressure: String, Sendable, Codable {
    case normal
    case warning
    case critical
}

public enum ContextArenaError: Error, Equatable, Sendable {
    case noPublishedSnapshot
}

public struct ContextArenaMetrics: Sendable, Equatable {
    public let currentGenerationID: Int64?
    public let activeLeaseCount: Int
    public let pressure: ContextArenaPressure
    public let prewarmingAllowed: Bool
}

/// Explicit release promptly unpins the snapshot; deinitialization still releases an abandoned lease.
public final class ContextGenerationLease: Sendable {
    public let snapshot: ContextGenerationSnapshot

    private let released = Atomic(false)
    private let releaseHandler: @Sendable () -> Void

    fileprivate init(
        snapshot: ContextGenerationSnapshot,
        releaseHandler: @escaping @Sendable () -> Void
    ) {
        self.snapshot = snapshot
        self.releaseHandler = releaseHandler
    }

    public func release() {
        if !released.exchange(true, ordering: .acquiringAndReleasing) {
            releaseHandler()
        }
    }

    deinit {
        release()
    }
}

/// One short-held lock serializes swaps and lease accounting; construct snapshots before taking it.
public final class ContextArena: Sendable {
    public let healthEvents: ContextHealthEvents

    private struct PublishedSnapshot {
        let sequence: UInt64
        let snapshot: ContextGenerationSnapshot
    }

    private struct ActiveSnapshot {
        var leaseCount: Int
    }

    private struct State {
        var current: PublishedSnapshot?
        var nextSequence: UInt64 = 1
        var activeSnapshots: [UInt64: ActiveSnapshot] = [:]
        var pressure: ContextArenaPressure = .normal
        var prewarmingAllowed = true
    }

    private let state = Mutex<State>(State())

    public init(healthEvents: ContextHealthEvents = ContextHealthEvents()) {
        self.healthEvents = healthEvents
    }

    public func currentSnapshot() -> ContextGenerationSnapshot? {
        return state.withLock { $0.current?.snapshot }
    }

    @discardableResult
    public func publish(_ candidate: ContextGenerationSnapshot) -> ContextArenaPublicationOutcome {
        var changed = false
        defer { if changed { healthEvents.signal() } }
        return state.withLock { state in
            if let currentGeneration = state.current?.snapshot.generationID,
               candidate.generationID <= currentGeneration {
                return .retainedLastGood(
                    failure: .generationNotNewer(
                        candidate: candidate.generationID,
                        current: currentGeneration
                    ),
                    generationID: currentGeneration
                )
            }

            let previousGeneration = state.current?.snapshot.generationID
            let published = makePublishedSnapshot(candidate, state: &state)
            state.current = published
            changed = true
            return .published(
                generationID: candidate.generationID,
                previousGenerationID: previousGeneration
            )
        }
    }

    /// Required mirror updates land at every pressure level for the exact published generation and source fingerprint.
    @discardableResult
    public func rehydrate(
        _ candidate: ContextGenerationSnapshot
    ) -> ContextArenaPublicationOutcome {
        var changed = false
        defer { if changed { healthEvents.signal() } }
        return state.withLock { state in
            guard let current = state.current?.snapshot else {
                return .retainedLastGood(
                    failure: .rehydrationGenerationMismatch(
                        candidate: candidate.generationID,
                        current: -1
                    ),
                    generationID: nil
                )
            }
            guard candidate.generationID == current.generationID else {
                return .retainedLastGood(
                    failure: .rehydrationGenerationMismatch(
                        candidate: candidate.generationID,
                        current: current.generationID
                    ),
                    generationID: current.generationID
                )
            }
            guard candidate.sourceFingerprint == current.sourceFingerprint else {
                return .retainedLastGood(
                    failure: .rehydrationFingerprintMismatch(
                        candidate: candidate.sourceFingerprint,
                        current: current.sourceFingerprint
                    ),
                    generationID: current.generationID
                )
            }
            let published = makePublishedSnapshot(candidate, state: &state)
            state.current = published
            changed = true
            return .rehydrated(generationID: candidate.generationID)
        }
    }

    public func acquireSnapshot() throws -> ContextGenerationLease {
        let published = try state.withLock { state -> PublishedSnapshot in
            guard let published = state.current else { throw ContextArenaError.noPublishedSnapshot }
            var active = state.activeSnapshots[published.sequence] ?? ActiveSnapshot(leaseCount: 0)
            active.leaseCount += 1
            state.activeSnapshots[published.sequence] = active
            return published
        }
        healthEvents.signal()

        return ContextGenerationLease(snapshot: published.snapshot) { [weak self] in
            self?.releaseLease(sequence: published.sequence)
        }
    }

    public func applyMemoryPressure(_ pressure: ContextArenaPressure) throws {
        var changed = false
        defer { if changed { healthEvents.signal() } }
        try state.withLock { state in
            guard state.current != nil else {
                throw ContextArenaError.noPublishedSnapshot
            }

            changed = state.pressure != pressure
            state.pressure = pressure
            state.prewarmingAllowed = pressure == .normal
        }
    }

    public func metrics() -> ContextArenaMetrics {
        return state.withLock { state in
            return ContextArenaMetrics(
                currentGenerationID: state.current?.snapshot.generationID,
                activeLeaseCount: state.activeSnapshots.values.reduce(into: 0) {
                    $0 += $1.leaseCount
                },
                pressure: state.pressure,
                prewarmingAllowed: state.prewarmingAllowed
            )
        }
    }

    private func makePublishedSnapshot(_ snapshot: ContextGenerationSnapshot, state: inout State) -> PublishedSnapshot {
        let published = PublishedSnapshot(sequence: state.nextSequence, snapshot: snapshot)
        state.nextSequence &+= 1
        return published
    }

    private func releaseLease(sequence: UInt64) {
        var changed = false
        defer { if changed { healthEvents.signal() } }
        state.withLock { state in
            guard var active = state.activeSnapshots[sequence] else { return }
            active.leaseCount -= 1
            if active.leaseCount == 0 {
                state.activeSnapshots.removeValue(forKey: sequence)
            } else {
                state.activeSnapshots[sequence] = active
            }
            changed = true
        }
    }

}
