import Foundation

// Blueprint: | `ContextArena.swift` | `ContextArena`: bounded resident generations, immutable snapshot leases, serialized publication and pressure trimming |

public enum ContextArenaBudget: Int, CaseIterable, Sendable, Codable {
    case mib32 = 32
    case mib64 = 64
    case mib96 = 96
    case mib128 = 128
    case mib256 = 256

    public static let `default`: Self = .mib96

    public var byteLimit: Int {
        rawValue * 1_048_576
    }
}

public enum ContextArenaTier: String, Sendable, Codable {
    case hot
    case warm
}

public struct ContextArenaEntryKey: Hashable, Comparable, Sendable {
    public let namespace: String
    public let id: String
    public let sourceFingerprint: String
    public let generationID: Int64

    public init(namespace: String, id: String, sourceFingerprint: String, generationID: Int64) {
        self.namespace = namespace
        self.id = id
        self.sourceFingerprint = sourceFingerprint
        self.generationID = generationID
    }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        if lhs.namespace != rhs.namespace { return lhs.namespace < rhs.namespace }
        if lhs.id != rhs.id { return lhs.id < rhs.id }
        if lhs.generationID != rhs.generationID { return lhs.generationID < rhs.generationID }
        return lhs.sourceFingerprint < rhs.sourceFingerprint
    }
}

public enum ContextArenaEntryError: Error, Equatable, Sendable {
    case emptyNamespace
    case emptyID
    case emptySourceFingerprint
    case negativeGeneration
    case negativeRetentionPriority
    case logicalByteOverflow
}

/// A store-independent resident value. The fixed overhead and every payload
/// component are accounted deterministically.
public struct ContextArenaEntry: Sendable, Equatable {
    public let key: ContextArenaEntryKey
    public let tier: ContextArenaTier
    public let text: String
    public let summary: String?
    public let metadata: Data
    public let vector: [Float]
    public let retentionPriority: Int
    public let logicalByteCount: Int

    public init(
        key: ContextArenaEntryKey,
        tier: ContextArenaTier,
        text: String = "",
        summary: String? = nil,
        metadata: Data = Data(),
        vector: [Float] = [],
        retentionPriority: Int = 0
    ) throws {
        guard !key.namespace.isEmpty else { throw ContextArenaEntryError.emptyNamespace }
        guard !key.id.isEmpty else { throw ContextArenaEntryError.emptyID }
        guard !key.sourceFingerprint.isEmpty else {
            throw ContextArenaEntryError.emptySourceFingerprint
        }
        guard key.generationID >= 0 else { throw ContextArenaEntryError.negativeGeneration }
        guard retentionPriority >= 0 else {
            throw ContextArenaEntryError.negativeRetentionPriority
        }

        let vectorBytes = vector.count.multipliedReportingOverflow(by: MemoryLayout<Float>.stride)
        guard !vectorBytes.overflow else { throw ContextArenaEntryError.logicalByteOverflow }
        let components = [
            96,
            key.namespace.utf8.count,
            key.id.utf8.count,
            key.sourceFingerprint.utf8.count,
            text.utf8.count,
            summary?.utf8.count ?? 0,
            metadata.count,
            vectorBytes.partialValue,
        ]
        var total = 0
        for component in components {
            let addition = total.addingReportingOverflow(component)
            guard !addition.overflow else { throw ContextArenaEntryError.logicalByteOverflow }
            total = addition.partialValue
        }

        self.key = key
        self.tier = tier
        self.text = text
        self.summary = summary
        self.metadata = metadata
        self.vector = vector
        self.retentionPriority = retentionPriority
        self.logicalByteCount = total
    }
}

public enum ContextGenerationSnapshotError: Error, Equatable, Sendable {
    case negativeGeneration
    case emptySourceFingerprint
    case duplicatePersona(ContextPersonaID)
    case duplicateEntryKey(ContextArenaEntryKey)
    case tierMismatch(key: ContextArenaEntryKey, expected: ContextArenaTier)
    case entryGenerationMismatch(key: ContextArenaEntryKey, expected: Int64)
    case logicalByteOverflow
}

/// Immutable, generation-consistent data used for an entire provider/tool loop.
public struct ContextGenerationSnapshot: Sendable, Equatable {
    public let generationID: Int64
    public let sourceFingerprint: String
    public let requiredDocumentMirrors: [RequiredDocumentMirror]
    public let hotEntries: [ContextArenaEntry]
    public let warmEntries: [ContextArenaEntry]
    public let selectionIndex: [ContextAtomID: ContextSelectionIndexEntry]
    public let hotLogicalByteCount: Int
    public let logicalByteCount: Int

    public init(
        generationID: Int64,
        sourceFingerprint: String,
        requiredDocumentMirrors: [RequiredDocumentMirror] = [],
        hotEntries: [ContextArenaEntry] = [],
        warmEntries: [ContextArenaEntry] = [],
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

        let sortedHot = hotEntries.sorted { $0.key < $1.key }
        let sortedWarm = warmEntries.sorted { $0.key < $1.key }
        var entryKeys = Set<ContextArenaEntryKey>()
        for (entries, expectedTier) in [(sortedHot, ContextArenaTier.hot), (sortedWarm, .warm)] {
            for entry in entries {
                guard entry.tier == expectedTier else {
                    throw ContextGenerationSnapshotError.tierMismatch(
                        key: entry.key,
                        expected: expectedTier
                    )
                }
                guard entry.key.generationID == generationID else {
                    throw ContextGenerationSnapshotError.entryGenerationMismatch(
                        key: entry.key,
                        expected: generationID
                    )
                }
                guard entryKeys.insert(entry.key).inserted else {
                    throw ContextGenerationSnapshotError.duplicateEntryKey(entry.key)
                }
            }
        }

        let snapshotOverhead = 128 + sourceFingerprint.utf8.count
        let hotComponents = [snapshotOverhead]
            + mirrors.map(\.logicalByteCount)
            + sortedHot.map(\.logicalByteCount)
            + selectionIndex.values.map(\.logicalByteCount)
        let warmComponents = sortedWarm.map(\.logicalByteCount)
        let hotBytes = try Self.checkedSum(hotComponents)
        let warmBytes = try Self.checkedSum(warmComponents)
        let totalBytes = try Self.checkedSum([hotBytes, warmBytes])

        self.generationID = generationID
        self.sourceFingerprint = sourceFingerprint
        self.requiredDocumentMirrors = mirrors
        self.hotEntries = sortedHot
        self.warmEntries = sortedWarm
        self.selectionIndex = selectionIndex
        self.hotLogicalByteCount = hotBytes
        self.logicalByteCount = totalBytes
    }

    fileprivate func retainingWarmEntries(_ retained: [ContextArenaEntry]) throws -> Self {
        try Self(
            generationID: generationID,
            sourceFingerprint: sourceFingerprint,
            requiredDocumentMirrors: requiredDocumentMirrors,
            hotEntries: hotEntries,
            warmEntries: retained,
            selectionIndex: selectionIndex
        )
    }

    private static func checkedSum(_ values: [Int]) throws -> Int {
        var total = 0
        for value in values {
            let addition = total.addingReportingOverflow(value)
            guard !addition.overflow else {
                throw ContextGenerationSnapshotError.logicalByteOverflow
            }
            total = addition.partialValue
        }
        return total
    }
}

public enum ContextArenaPublicationFailure: Error, Equatable, Sendable {
    case generationNotNewer(candidate: Int64, current: Int64)
    case rehydrationGenerationMismatch(candidate: Int64, current: Int64)
    case rehydrationFingerprintMismatch(candidate: String, current: String)
    case prewarmingDisabled(ContextArenaPressure)
    case logicalBudgetExceeded(actual: Int, limit: Int)
    case hotTierLimitExceeded(actual: Int, limit: Int)
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
    case invalidHotTierLimit
}

public struct ContextArenaTrimReceipt: Sendable, Equatable {
    public let pressure: ContextArenaPressure
    public let beforeLogicalBytes: Int
    public let afterLogicalBytes: Int
    public let evictedWarmEntryKeys: [ContextArenaEntryKey]
    public let pinnedGenerations: [Int64: Int]
}

public struct ContextArenaMetrics: Sendable, Equatable {
    public let budget: ContextArenaBudget
    public let hotTierByteLimit: Int
    public let currentGenerationID: Int64?
    public let currentLogicalBytes: Int
    public let residentLogicalBytes: Int
    public let activeLeaseCount: Int
    public let pinnedGenerations: [Int64: Int]
    public let pressure: ContextArenaPressure
    public let prewarmingAllowed: Bool
}

/// Idempotent pin for one immutable snapshot. Explicit release is preferred;
/// deinitialization is a final safety net.
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

/// Bounded logical RAM arena. All swaps and lease accounting are serialized by
/// one short-held lock; snapshot construction happens before that lock is taken.
public final class ContextArena: @unchecked Sendable {
    public static let defaultHotTierByteLimit = 16 * 1_048_576

    public let budget: ContextArenaBudget
    public let hotTierByteLimit: Int

    private struct PublishedSnapshot {
        let sequence: UInt64
        let snapshot: ContextGenerationSnapshot
    }

    private struct ActiveSnapshot {
        var leaseCount: Int
        let generationID: Int64
        let logicalByteCount: Int
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

    public init(
        budget: ContextArenaBudget = .default,
        hotTierByteLimit: Int = ContextArena.defaultHotTierByteLimit
    ) throws {
        guard hotTierByteLimit > 0,
              hotTierByteLimit <= Self.defaultHotTierByteLimit,
              hotTierByteLimit <= budget.byteLimit
        else {
            throw ContextArenaError.invalidHotTierLimit
        }
        self.budget = budget
        self.hotTierByteLimit = hotTierByteLimit
    }

    public func currentSnapshot() -> ContextGenerationSnapshot? {
        lock.lock()
        defer { lock.unlock() }
        return state.current?.snapshot
    }

    @discardableResult
    public func publish(_ candidate: ContextGenerationSnapshot) -> ContextArenaPublicationOutcome {
        lock.lock()
        defer { lock.unlock() }

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
        if let failure = publicationBudgetFailure(candidate) {
            return .retainedLastGood(
                failure: failure,
                generationID: state.current?.snapshot.generationID
            )
        }

        let previousGeneration = state.current?.snapshot.generationID
        state.current = makePublishedSnapshot(candidate)
        return .published(
            generationID: candidate.generationID,
            previousGenerationID: previousGeneration
        )
    }

    /// Restores evicted warm entries without inventing a new durable store
    /// generation. This is valid only for the exact currently published source
    /// fingerprint and while normal-pressure prewarming is allowed.
    @discardableResult
    public func rehydrate(
        _ candidate: ContextGenerationSnapshot
    ) -> ContextArenaPublicationOutcome {
        lock.lock()
        defer { lock.unlock() }

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
        guard state.prewarmingAllowed else {
            return .retainedLastGood(
                failure: .prewarmingDisabled(state.pressure),
                generationID: current.generationID
            )
        }
        if let failure = publicationBudgetFailure(candidate) {
            return .retainedLastGood(
                failure: failure,
                generationID: current.generationID
            )
        }

        state.current = makePublishedSnapshot(candidate)
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
            generationID: published.snapshot.generationID,
            logicalByteCount: published.snapshot.logicalByteCount
        )
        active.leaseCount += 1
        state.activeSnapshots[published.sequence] = active
        lock.unlock()

        return ContextGenerationLease(snapshot: published.snapshot) { [weak self] in
            self?.releaseLease(sequence: published.sequence)
        }
    }

    @discardableResult
    public func applyMemoryPressure(_ pressure: ContextArenaPressure) throws -> ContextArenaTrimReceipt {
        lock.lock()
        defer { lock.unlock() }
        guard let current = state.current else {
            throw ContextArenaError.noPublishedSnapshot
        }

        state.pressure = pressure
        state.prewarmingAllowed = pressure == .normal
        let before = current.snapshot
        let retainedWarm: [ContextArenaEntry]

        switch pressure {
        case .normal:
            retainedWarm = before.warmEntries
        case .warning:
            let target = budget.byteLimit / 2
            var projectedBytes = before.logicalByteCount
            var retainedKeys = Set(before.warmEntries.map(\.key))
            let evictionOrder = before.warmEntries.sorted(by: Self.shouldEvictBefore)
            for entry in evictionOrder where projectedBytes > target {
                retainedKeys.remove(entry.key)
                projectedBytes -= entry.logicalByteCount
            }
            retainedWarm = before.warmEntries.filter { retainedKeys.contains($0.key) }
        case .critical:
            retainedWarm = []
        }

        let retainedKeys = Set(retainedWarm.map(\.key))
        let evicted = before.warmEntries
            .filter { !retainedKeys.contains($0.key) }
            .map(\.key)
        let after: ContextGenerationSnapshot
        if evicted.isEmpty {
            after = before
        } else {
            after = try before.retainingWarmEntries(retainedWarm)
            state.current = makePublishedSnapshot(after)
        }

        return ContextArenaTrimReceipt(
            pressure: pressure,
            beforeLogicalBytes: before.logicalByteCount,
            afterLogicalBytes: after.logicalByteCount,
            evictedWarmEntryKeys: evicted,
            pinnedGenerations: pinnedGenerationsLocked()
        )
    }

    public func metrics() -> ContextArenaMetrics {
        lock.lock()
        defer { lock.unlock() }
        let currentSequence = state.current?.sequence
        let retainedBytes = state.activeSnapshots.reduce(into: 0) { result, item in
            if item.key != currentSequence {
                result += item.value.logicalByteCount
            }
        }
        let currentBytes = state.current?.snapshot.logicalByteCount ?? 0
        return ContextArenaMetrics(
            budget: budget,
            hotTierByteLimit: hotTierByteLimit,
            currentGenerationID: state.current?.snapshot.generationID,
            currentLogicalBytes: currentBytes,
            residentLogicalBytes: currentBytes + retainedBytes,
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

    private func publicationBudgetFailure(
        _ candidate: ContextGenerationSnapshot
    ) -> ContextArenaPublicationFailure? {
        if candidate.hotLogicalByteCount > hotTierByteLimit {
            return .hotTierLimitExceeded(
                actual: candidate.hotLogicalByteCount,
                limit: hotTierByteLimit
            )
        }
        if candidate.logicalByteCount > budget.byteLimit {
            return .logicalBudgetExceeded(
                actual: candidate.logicalByteCount,
                limit: budget.byteLimit
            )
        }
        return nil
    }

    private func releaseLease(sequence: UInt64) {
        lock.lock()
        defer { lock.unlock() }
        guard var active = state.activeSnapshots[sequence] else { return }
        active.leaseCount -= 1
        if active.leaseCount == 0 {
            state.activeSnapshots.removeValue(forKey: sequence)
        } else {
            state.activeSnapshots[sequence] = active
        }
    }

    private func pinnedGenerationsLocked() -> [Int64: Int] {
        state.activeSnapshots.values.reduce(into: [:]) { result, active in
            result[active.generationID, default: 0] += active.leaseCount
        }
    }

    private static func shouldEvictBefore(_ lhs: ContextArenaEntry, _ rhs: ContextArenaEntry) -> Bool {
        if lhs.retentionPriority != rhs.retentionPriority {
            return lhs.retentionPriority < rhs.retentionPriority
        }
        return lhs.key < rhs.key
    }
}
