import Dispatch
import Foundation

public enum ContextPrewarmHintKind: String, CaseIterable, Codable, Sendable, Comparable {
    case session
    case workshopExecution = "mission" // compatibility wire ID
    case cognitive
    case organism

    public static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

public struct ContextPrewarmScope: Hashable, Codable, Sendable, Comparable {
    public let kind: ContextPrewarmHintKind
    public let id: String

    public init(kind: ContextPrewarmHintKind, id: String) {
        self.kind = kind
        self.id = id
    }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        if lhs.kind != rhs.kind { return lhs.kind < rhs.kind }
        return lhs.id < rhs.id
    }
}

/// A store pointer and cost estimate only. Prewarm never carries text,
/// selection state, policy decisions, or authority.
public struct ContextPrewarmCandidate: Equatable, Sendable {
    public let atomID: ContextAtomID
    public let generationID: Int64
    public let sourceFingerprint: String
    public let estimatedByteCount: Int
    public let likelihood: Double

    public init(
        atomID: ContextAtomID,
        generationID: Int64,
        sourceFingerprint: String,
        estimatedByteCount: Int,
        likelihood: Double
    ) {
        self.atomID = atomID
        self.generationID = generationID
        self.sourceFingerprint = sourceFingerprint
        self.estimatedByteCount = estimatedByteCount
        self.likelihood = likelihood
    }
}

public struct ContextPrewarmHintMetadata: Equatable, Sendable {
    public let scope: ContextPrewarmScope
    public let eventID: String
    public let revision: Int64
    public let priority: Int
    public let candidates: [ContextPrewarmCandidate]

    public init(
        scope: ContextPrewarmScope,
        eventID: String,
        revision: Int64,
        priority: Int = 0,
        candidates: [ContextPrewarmCandidate]
    ) {
        self.scope = scope
        self.eventID = eventID
        self.revision = revision
        self.priority = priority
        self.candidates = candidates
    }
}

public struct ContextPrewarmCancellation: Equatable, Sendable {
    public let scope: ContextPrewarmScope
    public let eventID: String
    public let revision: Int64

    public init(scope: ContextPrewarmScope, eventID: String, revision: Int64) {
        self.scope = scope
        self.eventID = eventID
        self.revision = revision
    }
}

public enum ContextPrewarmEvent: Equatable, Sendable {
    case hint(ContextPrewarmHintMetadata)
    case cancel(ContextPrewarmCancellation)
}

private enum ContextPrewarmLimits {
    static let hardMaximumAtomsPerHint = 64
    static let maximumQueuedHints = 32
    static let maximumTrackedScopes = 128
    static let maximumAtomsPerHint = 16
    static let maximumBytesPerHint = 2 * 1_048_576
    static let maximumPlanningNanoseconds: UInt64 = 5_000_000
    static let maximumUsefulnessReceipts = 128
}

public struct ContextPrewarmClock: Sendable {
    private let readNanoseconds: @Sendable () -> UInt64

    public init(readNanoseconds: @escaping @Sendable () -> UInt64) {
        self.readNanoseconds = readNanoseconds
    }

    public func nowNanoseconds() -> UInt64 {
        readNanoseconds()
    }

    public static let continuous = ContextPrewarmClock {
        DispatchTime.now().uptimeNanoseconds
    }
}

public enum ContextPrewarmRejection: Equatable, Sendable {
    case emptyScope
    case emptyEventID
    case negativeRevision
    case invalidCandidateCount(Int)
    case noUsableCandidates
}

public enum ContextPrewarmSubmissionOutcome: Equatable, Sendable {
    case accepted
    case deduplicated(intoEventID: String)
    case cancelled
    case stale(latestRevision: Int64)
    case suppressed(ContextArenaPressure)
    case rejected(ContextPrewarmRejection)
}

public struct ContextPrewarmPlanItem: Equatable, Sendable {
    public let candidate: ContextPrewarmCandidate
    public let cause: ContextPrewarmScope
    public let causeEventID: String
    public let causeRevision: Int64
}

/// Advisory store pointers only. Selection and TrustCenter remain separate,
/// mandatory downstream operations.
public struct ContextPrewarmPlan: Equatable, Sendable {
    public let id: String
    public let items: [ContextPrewarmPlanItem]
    public let estimatedByteCount: Int
}

public enum ContextPrewarmPlanningOutcome: Equatable, Sendable {
    case planned
    case empty
    case timeBounded
    case suppressed(ContextArenaPressure)
}

public struct ContextPrewarmPlanningReceipt: Equatable, Sendable {
    public let outcome: ContextPrewarmPlanningOutcome
    public let plan: ContextPrewarmPlan?
    public let consideredAtomCount: Int
    public let droppedAtomCount: Int
    public let elapsedNanoseconds: UInt64
    public let remainingQueueCount: Int
}

public struct ContextPrewarmUsefulnessReceipt: Equatable, Sendable {
    public let requestedAtomCount: Int
    public let warmedAtomCount: Int
    public let usefulAtomCount: Int
    public let usefulness: Double
}

/// Event-driven only: submit, processNext, and receipt recording perform all
/// work synchronously on actor calls. The planner creates no tasks or timers.
public actor ContextPrewarmPlanner {
    private struct CandidateKey: Hashable, Comparable {
        let atomID: ContextAtomID
        let generationID: Int64
        let sourceFingerprint: String

        static func < (lhs: Self, rhs: Self) -> Bool {
            if lhs.atomID != rhs.atomID { return lhs.atomID < rhs.atomID }
            if lhs.generationID != rhs.generationID { return lhs.generationID < rhs.generationID }
            return lhs.sourceFingerprint < rhs.sourceFingerprint
        }
    }

    private struct QueuedHint: Equatable, Sendable {
        let metadata: ContextPrewarmHintMetadata
        let droppedAtomCount: Int
    }

    private struct LatestState: Sendable {
        let revision: Int64
        let eventID: String
        let cancelled: Bool
        let ordinal: UInt64
    }

    private let clock: ContextPrewarmClock
    private var pressure: ContextArenaPressure = .normal
    private var queue: [ContextPrewarmScope: QueuedHint] = [:]
    private var latest: [ContextPrewarmScope: LatestState] = [:]
    private var retainedUsefulnessReceiptCount = 0
    private var stateOrdinal: UInt64 = 0

    public init(clock: ContextPrewarmClock = .continuous) {
        self.clock = clock
    }

    @discardableResult
    public func submit(_ event: ContextPrewarmEvent) -> ContextPrewarmSubmissionOutcome {
        switch event {
        case .cancel(let cancellation):
            return cancel(cancellation)
        case .hint(let metadata):
            return submit(metadata)
        }
    }

    public func setResourcePressure(_ newPressure: ContextArenaPressure) {
        pressure = newPressure
        if newPressure != .normal {
            queue.removeAll(keepingCapacity: true)
            for (scope, state) in Array(latest) where !state.cancelled {
                latest[scope] = LatestState(
                    revision: state.revision,
                    eventID: state.eventID,
                    cancelled: true,
                    ordinal: nextOrdinal()
                )
            }
        }
    }

    public func processNext() -> ContextPrewarmPlanningReceipt {
        guard pressure == .normal else {
            return ContextPrewarmPlanningReceipt(
                outcome: .suppressed(pressure),
                plan: nil,
                consideredAtomCount: 0,
                droppedAtomCount: 0,
                elapsedNanoseconds: 0,
                remainingQueueCount: queue.count
            )
        }
        guard let hint = queue.values.sorted(by: Self.hintRanksBefore).first else {
            return ContextPrewarmPlanningReceipt(
                outcome: .empty,
                plan: nil,
                consideredAtomCount: 0,
                droppedAtomCount: 0,
                elapsedNanoseconds: 0,
                remainingQueueCount: 0
            )
        }
        queue[hint.metadata.scope] = nil

        let started = clock.nowNanoseconds()
        var items: [ContextPrewarmPlanItem] = []
        var byteCount = 0
        var considered = 0
        var dropped = hint.droppedAtomCount
        var hitTimeBound = false

        for candidate in hint.metadata.candidates {
            let elapsed = Self.elapsed(since: started, now: clock.nowNanoseconds())
            if elapsed >= ContextPrewarmLimits.maximumPlanningNanoseconds {
                hitTimeBound = true
                break
            }
            considered += 1
            items.append(ContextPrewarmPlanItem(
                candidate: candidate,
                cause: hint.metadata.scope,
                causeEventID: hint.metadata.eventID,
                causeRevision: hint.metadata.revision
            ))
            byteCount += candidate.estimatedByteCount
        }
        if hitTimeBound {
            dropped += hint.metadata.candidates.count - considered
        }

        let elapsed = Self.elapsed(since: started, now: clock.nowNanoseconds())
        guard !items.isEmpty else {
            return ContextPrewarmPlanningReceipt(
                outcome: hitTimeBound ? .timeBounded : .empty,
                plan: nil,
                consideredAtomCount: considered,
                droppedAtomCount: dropped,
                elapsedNanoseconds: elapsed,
                remainingQueueCount: queue.count
            )
        }

        let id = ContextStableID.digest(parts: [
            hint.metadata.scope.kind.rawValue,
            hint.metadata.scope.id,
            hint.metadata.eventID,
            String(hint.metadata.revision),
        ] + items.flatMap {
            [
                $0.candidate.atomID.rawValue,
                String($0.candidate.generationID),
                $0.candidate.sourceFingerprint,
            ]
        })
        let plan = ContextPrewarmPlan(id: id, items: items, estimatedByteCount: byteCount)
        return ContextPrewarmPlanningReceipt(
            outcome: hitTimeBound ? .timeBounded : .planned,
            plan: plan,
            consideredAtomCount: considered,
            droppedAtomCount: dropped,
            elapsedNanoseconds: elapsed,
            remainingQueueCount: queue.count
        )
    }

    /// Revalidate immediately before loading. A newer event, cancellation, or
    /// pressure transition invalidates the affected advisory items.
    public func validate(_ plan: ContextPrewarmPlan) -> [ContextPrewarmPlanItem] {
        let valid: [ContextPrewarmPlanItem]
        if pressure == .normal {
            valid = plan.items.filter { item in
                guard let state = latest[item.cause] else { return false }
                return !state.cancelled
                    && state.revision == item.causeRevision
                    && state.eventID == item.causeEventID
            }
        } else {
            valid = []
        }
        return valid
    }

    public func validPlanIDs(_ plans: [ContextPrewarmPlan]) -> Set<String> {
        Set(plans.filter { !validate($0).isEmpty }.map(\.id))
    }

    @discardableResult
    public func recordUsefulness(
        for plan: ContextPrewarmPlan,
        warmedAtomIDs: Set<ContextAtomID>,
        independentlySelectedAtomIDs: Set<ContextAtomID>
    ) -> ContextPrewarmUsefulnessReceipt {
        let requested = Set(plan.items.map(\.candidate.atomID))
        let warmed = requested.intersection(warmedAtomIDs)
        let useful = warmed.intersection(independentlySelectedAtomIDs)
        retainedUsefulnessReceiptCount = min(
            ContextPrewarmLimits.maximumUsefulnessReceipts, retainedUsefulnessReceiptCount + 1
        )
        return ContextPrewarmUsefulnessReceipt(
            requestedAtomCount: requested.count,
            warmedAtomCount: warmed.count,
            usefulAtomCount: useful.count,
            usefulness: warmed.isEmpty ? 0 : Double(useful.count) / Double(warmed.count)
        )
    }

    public func usefulnessReceiptCount() -> Int {
        retainedUsefulnessReceiptCount
    }

    public func pendingHintCount() -> Int {
        queue.count
    }

    private func submit(
        _ metadata: ContextPrewarmHintMetadata
    ) -> ContextPrewarmSubmissionOutcome {
        if pressure != .normal {
            return .suppressed(pressure)
        }
        if metadata.scope.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return .rejected(.emptyScope)
        }
        if metadata.eventID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return .rejected(.emptyEventID)
        }
        if metadata.revision < 0 {
            return .rejected(.negativeRevision)
        }
        if metadata.candidates.count > ContextPrewarmLimits.hardMaximumAtomsPerHint * 4 {
            return .rejected(.invalidCandidateCount(metadata.candidates.count))
        }

        let normalized = normalize(metadata)
        guard !normalized.metadata.candidates.isEmpty else {
            return .rejected(.noUsableCandidates)
        }

        if let state = latest[metadata.scope] {
            if metadata.revision < state.revision {
                return .stale(latestRevision: state.revision)
            }
            if metadata.revision == state.revision {
                guard !state.cancelled else {
                    return .stale(latestRevision: state.revision)
                }
                if let existing = queue[metadata.scope] {
                    let merged = merge(existing, normalized)
                    queue[metadata.scope] = merged
                    let mergedEventID = merged.metadata.eventID
                    latest[metadata.scope] = LatestState(
                        revision: metadata.revision,
                        eventID: mergedEventID,
                        cancelled: false,
                        ordinal: nextOrdinal()
                    )
                    enforceQueueBound()
                    return .deduplicated(intoEventID: mergedEventID)
                }
                return .deduplicated(intoEventID: state.eventID)
            }
        }

        queue[metadata.scope] = normalized
        latest[metadata.scope] = LatestState(
            revision: metadata.revision,
            eventID: normalized.metadata.eventID,
            cancelled: false,
            ordinal: nextOrdinal()
        )
        enforceQueueBound()
        pruneLatestState()
        return .accepted
    }

    private func cancel(
        _ cancellation: ContextPrewarmCancellation
    ) -> ContextPrewarmSubmissionOutcome {
        if cancellation.scope.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return .rejected(.emptyScope)
        }
        if cancellation.eventID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return .rejected(.emptyEventID)
        }
        if cancellation.revision < 0 {
            return .rejected(.negativeRevision)
        }
        if let state = latest[cancellation.scope], cancellation.revision < state.revision {
            return .stale(latestRevision: state.revision)
        }
        queue.removeValue(forKey: cancellation.scope)
        latest[cancellation.scope] = LatestState(
            revision: cancellation.revision,
            eventID: cancellation.eventID,
            cancelled: true,
            ordinal: nextOrdinal()
        )
        pruneLatestState()
        return .cancelled
    }

    private func normalize(_ metadata: ContextPrewarmHintMetadata) -> QueuedHint {
        var candidates: [CandidateKey: ContextPrewarmCandidate] = [:]
        for candidate in metadata.candidates {
            guard candidate.generationID >= 0,
                  !candidate.atomID.rawValue.isEmpty,
                  !candidate.sourceFingerprint.isEmpty,
                  candidate.estimatedByteCount > 0,
                  candidate.likelihood.isFinite,
                  candidate.likelihood >= 0,
                  candidate.likelihood <= 1
            else {
                continue
            }
            let key = CandidateKey(
                atomID: candidate.atomID,
                generationID: candidate.generationID,
                sourceFingerprint: candidate.sourceFingerprint
            )
            if let existing = candidates[key] {
                candidates[key] = Self.candidateRanksBefore(candidate, existing)
                    ? candidate
                    : existing
            } else {
                candidates[key] = candidate
            }
        }

        let ranked = candidates.values.sorted(by: Self.candidateRanksBefore)
        var accepted: [ContextPrewarmCandidate] = []
        var bytes = 0
        for candidate in ranked {
            guard accepted.count < ContextPrewarmLimits.maximumAtomsPerHint,
                  candidate.estimatedByteCount <= ContextPrewarmLimits.maximumBytesPerHint - bytes
            else {
                continue
            }
            accepted.append(candidate)
            bytes += candidate.estimatedByteCount
        }
        return QueuedHint(
            metadata: ContextPrewarmHintMetadata(
                scope: metadata.scope,
                eventID: metadata.eventID,
                revision: metadata.revision,
                priority: metadata.priority,
                candidates: accepted
            ),
            droppedAtomCount: metadata.candidates.count - accepted.count
        )
    }

    private func merge(_ lhs: QueuedHint, _ rhs: QueuedHint) -> QueuedHint {
        let merged = normalize(ContextPrewarmHintMetadata(
            scope: lhs.metadata.scope,
            eventID: min(lhs.metadata.eventID, rhs.metadata.eventID),
            revision: lhs.metadata.revision,
            priority: max(lhs.metadata.priority, rhs.metadata.priority),
            candidates: lhs.metadata.candidates + rhs.metadata.candidates
        ))
        return QueuedHint(
            metadata: merged.metadata,
            droppedAtomCount: merged.droppedAtomCount
                + lhs.droppedAtomCount
                + rhs.droppedAtomCount
        )
    }

    private func enforceQueueBound() {
        let ranked = queue.values.sorted(by: Self.hintRanksBefore)
        let retained = ranked.prefix(ContextPrewarmLimits.maximumQueuedHints)
        let retainedScopes = Set(retained.map(\.metadata.scope))
        for scope in queue.keys where !retainedScopes.contains(scope) {
            queue[scope] = nil
        }
    }

    private func pruneLatestState() {
        guard latest.count > ContextPrewarmLimits.maximumTrackedScopes else { return }
        let queuedScopes = Set(queue.keys)
        let removable = latest
            .filter { !queuedScopes.contains($0.key) }
            .sorted { lhs, rhs in
                if lhs.value.ordinal != rhs.value.ordinal {
                    return lhs.value.ordinal < rhs.value.ordinal
                }
                return lhs.key < rhs.key
            }
        for entry in removable.prefix(latest.count - ContextPrewarmLimits.maximumTrackedScopes) {
            latest[entry.key] = nil
        }
    }

    private func nextOrdinal() -> UInt64 {
        stateOrdinal &+= 1
        return stateOrdinal
    }

    private static func candidateRanksBefore(
        _ lhs: ContextPrewarmCandidate,
        _ rhs: ContextPrewarmCandidate
    ) -> Bool {
        if lhs.likelihood != rhs.likelihood { return lhs.likelihood > rhs.likelihood }
        if lhs.estimatedByteCount != rhs.estimatedByteCount {
            return lhs.estimatedByteCount < rhs.estimatedByteCount
        }
        let lhsKey = CandidateKey(
            atomID: lhs.atomID,
            generationID: lhs.generationID,
            sourceFingerprint: lhs.sourceFingerprint
        )
        let rhsKey = CandidateKey(
            atomID: rhs.atomID,
            generationID: rhs.generationID,
            sourceFingerprint: rhs.sourceFingerprint
        )
        return lhsKey < rhsKey
    }

    private static func hintRanksBefore(_ lhs: QueuedHint, _ rhs: QueuedHint) -> Bool {
        if lhs.metadata.priority != rhs.metadata.priority {
            return lhs.metadata.priority > rhs.metadata.priority
        }
        if lhs.metadata.revision != rhs.metadata.revision {
            return lhs.metadata.revision > rhs.metadata.revision
        }
        if lhs.metadata.scope != rhs.metadata.scope {
            return lhs.metadata.scope < rhs.metadata.scope
        }
        return lhs.metadata.eventID < rhs.metadata.eventID
    }

    private static func elapsed(since start: UInt64, now: UInt64) -> UInt64 {
        guard now >= start else { return UInt64.max }
        return now - start
    }
}
