import Foundation

// Blueprint: | `ContextArena.swift` | `ContextArena`: generations, leases, pressure and post-lock health invalidations |

public enum ContextGenerationSnapshotError: Error, Equatable, Sendable {
    case negativeGeneration
    case emptySourceFingerprint
    case duplicatePersona(ContextPersonaID)
}

/// Immutable, generation-consistent data used for an entire provider/tool loop.
public struct ContextGenerationSnapshot: Sendable, Equatable {
    public let generationID: Int64
    public let sourceFingerprint: String
    public let requiredDocumentMirrors: [RequiredDocumentMirror]
    public let selectionIndex: [ContextAtomID: ContextSelectionIndexEntry]

    public init(
        generationID: Int64,
        sourceFingerprint: String,
        requiredDocumentMirrors: [RequiredDocumentMirror] = [],
        selectionIndex: [ContextAtomID: ContextSelectionIndexEntry] = [:]
    ) throws {
        guard generationID >= 0 else {
            throw ContextGenerationSnapshotError.negativeGeneration
        }
        guard !sourceFingerprint.isEmpty else {
            throw ContextGenerationSnapshotError.emptySourceFingerprint
        }

        let mirrors = requiredDocumentMirrors.sorted { $0.personaID < $1.personaID }
        var personaIDs = Set<ContextPersonaID>()
        for mirror in mirrors {
            guard personaIDs.insert(mirror.personaID).inserted else {
                throw ContextGenerationSnapshotError.duplicatePersona(mirror.personaID)
            }
        }

        self.generationID = generationID
        self.sourceFingerprint = sourceFingerprint
        self.requiredDocumentMirrors = mirrors
        self.selectionIndex = selectionIndex
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
    public let pinnedGenerations: [Int64: Int]
    public let pressure: ContextArenaPressure
    public let prewarmingAllowed: Bool
}

/// Explicit release promptly unpins the snapshot; deinitialization still releases an abandoned lease.
public final class ContextGenerationLease: @unchecked Sendable {
    public let snapshot: ContextGenerationSnapshot

    private let lock = NSLock()
    private var released = false
    private let releaseHandler: @Sendable () -> Void

    fileprivate init(
        snapshot: ContextGenerationSnapshot,
        releaseHandler: @escaping @Sendable () -> Void
    ) {
        self.snapshot = snapshot
        self.releaseHandler = releaseHandler
    }

    public func release() {
        lock.lock()
        let shouldRelease = !released
        released = true
        lock.unlock()
        if shouldRelease {
            releaseHandler()
        }
    }

    deinit {
        release()
    }
}

/// One short-held lock serializes swaps and lease accounting; construct snapshots before taking it.
public final class ContextArena: @unchecked Sendable {
    public let healthEvents: ContextHealthEvents

    private struct PublishedSnapshot {
        let sequence: UInt64
        let snapshot: ContextGenerationSnapshot
    }

    private struct ActiveSnapshot {
        var leaseCount: Int
        let generationID: Int64
    }

    private struct State {
        var current: PublishedSnapshot?
        var nextSequence: UInt64 = 1
        var activeSnapshots: [UInt64: ActiveSnapshot] = [:]
        var pressure: ContextArenaPressure = .normal
        var prewarmingAllowed = true
    }

    private let lock = NSLock()
    private var state = State()

    public init(healthEvents: ContextHealthEvents = ContextHealthEvents()) {
        self.healthEvents = healthEvents
    }

    public func currentSnapshot() -> ContextGenerationSnapshot? {
        lock.lock()
        defer { lock.unlock() }
        return state.current?.snapshot
    }

    @discardableResult
    public func publish(_ candidate: ContextGenerationSnapshot) -> ContextArenaPublicationOutcome {
        lock.lock()
        var changed = false
        defer { lock.unlock(); if changed { healthEvents.signal() } }

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
        state.current = makePublishedSnapshot(candidate)
        changed = true
        return .published(
            generationID: candidate.generationID,
            previousGenerationID: previousGeneration
        )
    }

    /// Required mirror updates land at every pressure level for the exact published generation and source fingerprint.
    @discardableResult
    public func rehydrate(
        _ candidate: ContextGenerationSnapshot
    ) -> ContextArenaPublicationOutcome {
        lock.lock()
        var changed = false
        defer { lock.unlock(); if changed { healthEvents.signal() } }

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
        state.current = makePublishedSnapshot(candidate)
        changed = true
        return .rehydrated(generationID: candidate.generationID)
    }

    public func acquireSnapshot() throws -> ContextGenerationLease {
        lock.lock()
        guard let published = state.current else {
            lock.unlock()
            throw ContextArenaError.noPublishedSnapshot
        }
        var active = state.activeSnapshots[published.sequence] ?? ActiveSnapshot(
            leaseCount: 0,
            generationID: published.snapshot.generationID
        )
        active.leaseCount += 1
        state.activeSnapshots[published.sequence] = active
        lock.unlock()
        healthEvents.signal()

        return ContextGenerationLease(snapshot: published.snapshot) { [weak self] in
            self?.releaseLease(sequence: published.sequence)
        }
    }

    public func applyMemoryPressure(_ pressure: ContextArenaPressure) throws {
        lock.lock()
        var changed = false
        defer { lock.unlock(); if changed { healthEvents.signal() } }
        guard state.current != nil else {
            throw ContextArenaError.noPublishedSnapshot
        }

        changed = state.pressure != pressure
        state.pressure = pressure
        state.prewarmingAllowed = pressure == .normal
        // Pressure closes optional prewarming without dropping the published generation.
    }

    public func metrics() -> ContextArenaMetrics {
        lock.lock()
        defer { lock.unlock() }
        return ContextArenaMetrics(
            currentGenerationID: state.current?.snapshot.generationID,
            activeLeaseCount: state.activeSnapshots.values.reduce(into: 0) {
                $0 += $1.leaseCount
            },
            pinnedGenerations: pinnedGenerationsLocked(),
            pressure: state.pressure,
            prewarmingAllowed: state.prewarmingAllowed
        )
    }

    private func makePublishedSnapshot(_ snapshot: ContextGenerationSnapshot) -> PublishedSnapshot {
        let published = PublishedSnapshot(sequence: state.nextSequence, snapshot: snapshot)
        state.nextSequence &+= 1
        return published
    }

    private func releaseLease(sequence: UInt64) {
        lock.lock()
        var changed = false
        defer { lock.unlock(); if changed { healthEvents.signal() } }
        guard var active = state.activeSnapshots[sequence] else { return }
        active.leaseCount -= 1
        if active.leaseCount == 0 {
            state.activeSnapshots.removeValue(forKey: sequence)
        } else {
            state.activeSnapshots[sequence] = active
        }
        changed = true
    }

    private func pinnedGenerationsLocked() -> [Int64: Int] {
        state.activeSnapshots.values.reduce(into: [:]) { result, active in
            result[active.generationID, default: 0] += active.leaseCount
        }
    }

}
