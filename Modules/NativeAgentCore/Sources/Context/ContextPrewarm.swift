import Dispatch
import Foundation

public enum ContextPrewarmHintKind: String, CaseIterable, Codable, Sendable, Comparable {
    case session
    case desk
    case workshopExecution = "mission" // compatibility wire ID
    case file
    case toolResult = "tool_result"
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

public struct ContextSessionPrewarmHint: Equatable, Sendable {
    public let metadata: ContextPrewarmHintMetadata

    public init(
        sessionID: String,
        eventID: String,
        revision: Int64,
        priority: Int = 0,
        candidates: [ContextPrewarmCandidate]
    ) {
        self.metadata = ContextPrewarmHintMetadata(
            scope: ContextPrewarmScope(kind: .session, id: sessionID),
            eventID: eventID,
            revision: revision,
            priority: priority,
            candidates: candidates
        )
    }
}

public struct ContextDeskPrewarmHint: Equatable, Sendable {
    public let metadata: ContextPrewarmHintMetadata

    public init(
        deskID: String,
        eventID: String,
        revision: Int64,
        priority: Int = 0,
        candidates: [ContextPrewarmCandidate]
    ) {
        self.metadata = ContextPrewarmHintMetadata(
            scope: ContextPrewarmScope(kind: .desk, id: deskID),
            eventID: eventID,
            revision: revision,
            priority: priority,
            candidates: candidates
        )
    }
}

public struct ContextWorkshopPrewarmHint: Equatable, Sendable {
    public let metadata: ContextPrewarmHintMetadata

    public init(
        executionID: String,
        eventID: String,
        revision: Int64,
        priority: Int = 0,
        candidates: [ContextPrewarmCandidate]
    ) {
        self.metadata = ContextPrewarmHintMetadata(
            scope: ContextPrewarmScope(kind: .workshopExecution, id: executionID),
            eventID: eventID,
            revision: revision,
            priority: priority,
            candidates: candidates
        )
    }
}

public struct ContextFilePrewarmHint: Equatable, Sendable {
    public let sourceID: ContextSourceID
    public let contentFingerprint: String
    public let metadata: ContextPrewarmHintMetadata

    public init(
        sourceID: ContextSourceID,
        contentFingerprint: String,
        eventID: String,
        revision: Int64,
        priority: Int = 0,
        candidates: [ContextPrewarmCandidate]
    ) {
        self.sourceID = sourceID
        self.contentFingerprint = contentFingerprint
        self.metadata = ContextPrewarmHintMetadata(
            scope: ContextPrewarmScope(kind: .file, id: sourceID.rawValue),
            eventID: eventID,
            revision: revision,
            priority: priority,
            candidates: candidates
        )
    }
}

public struct ContextToolResultPrewarmHint: Equatable, Sendable {
    public let resultFingerprint: String
    public let metadata: ContextPrewarmHintMetadata

    public init(
        toolCallID: String,
        resultFingerprint: String,
        eventID: String,
        revision: Int64,
        priority: Int = 0,
        candidates: [ContextPrewarmCandidate]
    ) {
        self.resultFingerprint = resultFingerprint
        self.metadata = ContextPrewarmHintMetadata(
            scope: ContextPrewarmScope(kind: .toolResult, id: toolCallID),
            eventID: eventID,
            revision: revision,
            priority: priority,
            candidates: candidates
        )
    }
}

public struct ContextCognitivePrewarmHint: Equatable, Sendable {
    public let activationID: String
    public let metadata: ContextPrewarmHintMetadata

    public init(
        workspaceID: String,
        activationID: String,
        eventID: String,
        revision: Int64,
        priority: Int = 0,
        candidates: [ContextPrewarmCandidate]
    ) {
        self.activationID = activationID
        self.metadata = ContextPrewarmHintMetadata(
            scope: ContextPrewarmScope(kind: .cognitive, id: workspaceID),
            eventID: eventID,
            revision: revision,
            priority: priority,
            candidates: candidates
        )
    }
}

public struct ContextOrganismPrewarmHint: Equatable, Sendable {
    public let metadata: ContextPrewarmHintMetadata

    public init(
        predictionID: String,
        eventID: String,
        revision: Int64,
        priority: Int = 0,
        candidates: [ContextPrewarmCandidate]
    ) {
        self.metadata = ContextPrewarmHintMetadata(
            scope: ContextPrewarmScope(kind: .organism, id: predictionID),
            eventID: eventID,
            revision: revision,
            priority: priority,
            candidates: candidates
        )
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
    case session(ContextSessionPrewarmHint)
    case desk(ContextDeskPrewarmHint)
    case workshopExecution(ContextWorkshopPrewarmHint)
    case file(ContextFilePrewarmHint)
    case toolResult(ContextToolResultPrewarmHint)
    case cognitive(ContextCognitivePrewarmHint)
    case organism(ContextOrganismPrewarmHint)
    case cancel(ContextPrewarmCancellation)

    fileprivate var metadata: ContextPrewarmHintMetadata? {
        switch self {
        case .session(let hint): hint.metadata
        case .desk(let hint): hint.metadata
        case .workshopExecution(let hint): hint.metadata
        case .file(let hint): hint.metadata
        case .toolResult(let hint): hint.metadata
        case .cognitive(let hint): hint.metadata
        case .organism(let hint): hint.metadata
        case .cancel: nil
        }
    }
}

public enum ContextPrewarmLimitsError: Error, Equatable, Sendable {
    case invalidQueueLimit
    case invalidTrackedScopeLimit
    case invalidAtomLimit
    case invalidByteLimit
    case invalidTimeLimit
    case invalidReceiptLimit
}

public struct ContextPrewarmLimits: Equatable, Sendable {
    public static let hardMaximumQueuedHints = 256
    public static let hardMaximumTrackedScopes = 1_024
    public static let hardMaximumAtomsPerHint = 64
    public static let hardMaximumAtomsPerPlan = 128
    public static let hardMaximumBytesPerHint = 8 * 1_048_576
    public static let hardMaximumBytesPerPlan = 16 * 1_048_576
    public static let hardMaximumPlanningNanoseconds: UInt64 = 50_000_000
    public static let hardMaximumUsefulnessReceipts = 1_024

    public let maximumQueuedHints: Int
    public let maximumTrackedScopes: Int
    public let maximumAtomsPerHint: Int
    public let maximumAtomsPerPlan: Int
    public let maximumBytesPerHint: Int
    public let maximumBytesPerPlan: Int
    public let maximumPlanningNanoseconds: UInt64
    public let maximumUsefulnessReceipts: Int

    public init(
        maximumQueuedHints: Int = 32,
        maximumTrackedScopes: Int = 128,
        maximumAtomsPerHint: Int = 16,
        maximumAtomsPerPlan: Int = 32,
        maximumBytesPerHint: Int = 2 * 1_048_576,
        maximumBytesPerPlan: Int = 4 * 1_048_576,
        maximumPlanningNanoseconds: UInt64 = 5_000_000,
        maximumUsefulnessReceipts: Int = 128
    ) throws {
        guard (1...Self.hardMaximumQueuedHints).contains(maximumQueuedHints) else {
            throw ContextPrewarmLimitsError.invalidQueueLimit
        }
        guard (maximumQueuedHints...Self.hardMaximumTrackedScopes).contains(maximumTrackedScopes) else {
            throw ContextPrewarmLimitsError.invalidTrackedScopeLimit
        }
        guard (1...Self.hardMaximumAtomsPerHint).contains(maximumAtomsPerHint),
              (1...Self.hardMaximumAtomsPerPlan).contains(maximumAtomsPerPlan)
        else {
            throw ContextPrewarmLimitsError.invalidAtomLimit
        }
        guard (1...Self.hardMaximumBytesPerHint).contains(maximumBytesPerHint),
              (1...Self.hardMaximumBytesPerPlan).contains(maximumBytesPerPlan)
        else {
            throw ContextPrewarmLimitsError.invalidByteLimit
        }
        guard (1...Self.hardMaximumPlanningNanoseconds).contains(maximumPlanningNanoseconds) else {
            throw ContextPrewarmLimitsError.invalidTimeLimit
        }
        guard (1...Self.hardMaximumUsefulnessReceipts).contains(maximumUsefulnessReceipts) else {
            throw ContextPrewarmLimitsError.invalidReceiptLimit
        }

        self.maximumQueuedHints = maximumQueuedHints
        self.maximumTrackedScopes = maximumTrackedScopes
        self.maximumAtomsPerHint = maximumAtomsPerHint
        self.maximumAtomsPerPlan = maximumAtomsPerPlan
        self.maximumBytesPerHint = maximumBytesPerHint
        self.maximumBytesPerPlan = maximumBytesPerPlan
        self.maximumPlanningNanoseconds = maximumPlanningNanoseconds
        self.maximumUsefulnessReceipts = maximumUsefulnessReceipts
    }
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

public struct ContextPrewarmSubmissionReceipt: Equatable, Sendable {
    public let eventID: String
    public let scope: ContextPrewarmScope
    public let outcome: ContextPrewarmSubmissionOutcome
    public let supersededEventIDs: [String]
    public let evictedEventIDs: [String]
    public let acceptedAtomCount: Int
    public let acceptedByteCount: Int
    public let droppedAtomCount: Int
    public let queueCount: Int
}

public struct ContextPrewarmPressureReceipt: Equatable, Sendable {
    public let pressure: ContextArenaPressure
    public let cancelledEventIDs: [String]
    public let queueCount: Int
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

    public var canAlterSelection: Bool { false }
    public var canGrantAuthority: Bool { false }
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

public struct ContextPrewarmValidationReceipt: Equatable, Sendable {
    public let planID: String
    public let validItems: [ContextPrewarmPlanItem]
    public let invalidatedItems: [ContextPrewarmPlanItem]
    public let pressure: ContextArenaPressure
}

public struct ContextPrewarmUsefulnessReceipt: Equatable, Sendable {
    public let id: String
    public let ordinal: UInt64
    public let planID: String
    public let requestedAtomIDs: [ContextAtomID]
    public let warmedAtomIDs: [ContextAtomID]
    public let independentlySelectedAtomIDs: [ContextAtomID]
    public let usefulAtomIDs: [ContextAtomID]
    public let unusedWarmedAtomIDs: [ContextAtomID]
    public let usefulness: Double
    public let selectionWasObservedOnly: Bool
    public let authorityGranted: Bool
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
        let byteCount: Int
    }

    private struct LatestState: Sendable {
        let revision: Int64
        let eventID: String
        let cancelled: Bool
        let ordinal: UInt64
    }

    public let limits: ContextPrewarmLimits
    private let clock: ContextPrewarmClock
    private var pressure: ContextArenaPressure = .normal
    private var queue: [ContextPrewarmScope: QueuedHint] = [:]
    private var latest: [ContextPrewarmScope: LatestState] = [:]
    private var usefulnessReceipts: [ContextPrewarmUsefulnessReceipt] = []
    private var stateOrdinal: UInt64 = 0
    private var usefulnessOrdinal: UInt64 = 0

    public init(
        limits: ContextPrewarmLimits,
        clock: ContextPrewarmClock = .continuous
    ) {
        self.limits = limits
        self.clock = clock
    }

    public init(clock: ContextPrewarmClock = .continuous) {
        self.limits = try! ContextPrewarmLimits()
        self.clock = clock
    }

    @discardableResult
    public func submit(_ event: ContextPrewarmEvent) -> ContextPrewarmSubmissionReceipt {
        switch event {
        case .cancel(let cancellation):
            return cancel(cancellation)
        default:
            guard let metadata = event.metadata else {
                preconditionFailure("non-cancellation event must carry metadata")
            }
            return submit(metadata)
        }
    }

    @discardableResult
    public func setResourcePressure(
        _ newPressure: ContextArenaPressure
    ) -> ContextPrewarmPressureReceipt {
        pressure = newPressure
        let cancelled = newPressure == .normal
            ? []
            : latest.values.filter { !$0.cancelled }.map(\.eventID).sorted()
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
        return ContextPrewarmPressureReceipt(
            pressure: newPressure,
            cancelledEventIDs: cancelled,
            queueCount: queue.count
        )
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
            if elapsed >= limits.maximumPlanningNanoseconds {
                hitTimeBound = true
                break
            }
            considered += 1
            guard items.count < limits.maximumAtomsPerPlan else {
                dropped += 1
                continue
            }
            guard candidate.estimatedByteCount <= limits.maximumBytesPerPlan - byteCount else {
                dropped += 1
                continue
            }
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
    public func validate(_ plan: ContextPrewarmPlan) -> ContextPrewarmValidationReceipt {
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
        let validSet = Set(valid.map(Self.itemIdentity))
        let invalidated = plan.items.filter { !validSet.contains(Self.itemIdentity($0)) }
        return ContextPrewarmValidationReceipt(
            planID: plan.id,
            validItems: valid,
            invalidatedItems: invalidated,
            pressure: pressure
        )
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
        let unused = warmed.subtracting(useful)
        usefulnessOrdinal &+= 1
        let receiptID = ContextStableID.digest(parts: [
            plan.id,
            String(usefulnessOrdinal),
        ] + warmed.sorted().map(\.rawValue) + useful.sorted().map(\.rawValue))
        let receipt = ContextPrewarmUsefulnessReceipt(
            id: receiptID,
            ordinal: usefulnessOrdinal,
            planID: plan.id,
            requestedAtomIDs: requested.sorted(),
            warmedAtomIDs: warmed.sorted(),
            independentlySelectedAtomIDs: independentlySelectedAtomIDs.sorted(),
            usefulAtomIDs: useful.sorted(),
            unusedWarmedAtomIDs: unused.sorted(),
            usefulness: warmed.isEmpty ? 0 : Double(useful.count) / Double(warmed.count),
            selectionWasObservedOnly: true,
            authorityGranted: false
        )
        usefulnessReceipts.append(receipt)
        if usefulnessReceipts.count > limits.maximumUsefulnessReceipts {
            usefulnessReceipts.removeFirst(
                usefulnessReceipts.count - limits.maximumUsefulnessReceipts
            )
        }
        return receipt
    }

    public func recentUsefulnessReceipts() -> [ContextPrewarmUsefulnessReceipt] {
        usefulnessReceipts
    }

    public func pendingHintCount() -> Int {
        queue.count
    }

    public func currentPressure() -> ContextArenaPressure {
        pressure
    }

    private func submit(
        _ metadata: ContextPrewarmHintMetadata
    ) -> ContextPrewarmSubmissionReceipt {
        if pressure != .normal {
            return receipt(
                metadata: metadata,
                outcome: .suppressed(pressure),
                queueCount: queue.count
            )
        }
        if metadata.scope.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return receipt(metadata: metadata, outcome: .rejected(.emptyScope))
        }
        if metadata.eventID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return receipt(metadata: metadata, outcome: .rejected(.emptyEventID))
        }
        if metadata.revision < 0 {
            return receipt(metadata: metadata, outcome: .rejected(.negativeRevision))
        }
        if metadata.candidates.count > ContextPrewarmLimits.hardMaximumAtomsPerHint * 4 {
            return receipt(
                metadata: metadata,
                outcome: .rejected(.invalidCandidateCount(metadata.candidates.count))
            )
        }

        let normalized = normalize(metadata)
        guard !normalized.metadata.candidates.isEmpty else {
            return receipt(
                metadata: metadata,
                outcome: .rejected(.noUsableCandidates),
                droppedAtomCount: metadata.candidates.count
            )
        }

        if let state = latest[metadata.scope] {
            if metadata.revision < state.revision {
                return receipt(
                    metadata: normalized.metadata,
                    outcome: .stale(latestRevision: state.revision),
                    acceptedAtomCount: normalized.metadata.candidates.count,
                    acceptedByteCount: normalized.byteCount,
                    droppedAtomCount: normalized.droppedAtomCount
                )
            }
            if metadata.revision == state.revision {
                guard !state.cancelled else {
                    return receipt(
                        metadata: normalized.metadata,
                        outcome: .stale(latestRevision: state.revision)
                    )
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
                    let evicted = enforceQueueBound()
                    return receipt(
                        metadata: merged.metadata,
                        outcome: .deduplicated(intoEventID: mergedEventID),
                        evictedEventIDs: evicted,
                        acceptedAtomCount: merged.metadata.candidates.count,
                        acceptedByteCount: merged.byteCount,
                        droppedAtomCount: merged.droppedAtomCount,
                        queueCount: queue.count
                    )
                }
                return receipt(
                    metadata: normalized.metadata,
                    outcome: .deduplicated(intoEventID: state.eventID),
                    acceptedAtomCount: normalized.metadata.candidates.count,
                    acceptedByteCount: normalized.byteCount,
                    droppedAtomCount: normalized.droppedAtomCount
                )
            }
        }

        let superseded = queue.removeValue(forKey: metadata.scope).map {
            [$0.metadata.eventID]
        } ?? []
        queue[metadata.scope] = normalized
        latest[metadata.scope] = LatestState(
            revision: metadata.revision,
            eventID: normalized.metadata.eventID,
            cancelled: false,
            ordinal: nextOrdinal()
        )
        let evicted = enforceQueueBound()
        pruneLatestState()
        return receipt(
            metadata: normalized.metadata,
            outcome: .accepted,
            supersededEventIDs: superseded,
            evictedEventIDs: evicted,
            acceptedAtomCount: normalized.metadata.candidates.count,
            acceptedByteCount: normalized.byteCount,
            droppedAtomCount: normalized.droppedAtomCount,
            queueCount: queue.count
        )
    }

    private func cancel(
        _ cancellation: ContextPrewarmCancellation
    ) -> ContextPrewarmSubmissionReceipt {
        let metadata = ContextPrewarmHintMetadata(
            scope: cancellation.scope,
            eventID: cancellation.eventID,
            revision: cancellation.revision,
            candidates: []
        )
        if cancellation.scope.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return receipt(metadata: metadata, outcome: .rejected(.emptyScope))
        }
        if cancellation.eventID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return receipt(metadata: metadata, outcome: .rejected(.emptyEventID))
        }
        if cancellation.revision < 0 {
            return receipt(metadata: metadata, outcome: .rejected(.negativeRevision))
        }
        if let state = latest[cancellation.scope], cancellation.revision < state.revision {
            return receipt(
                metadata: metadata,
                outcome: .stale(latestRevision: state.revision)
            )
        }
        let removed = queue.removeValue(forKey: cancellation.scope)
        latest[cancellation.scope] = LatestState(
            revision: cancellation.revision,
            eventID: cancellation.eventID,
            cancelled: true,
            ordinal: nextOrdinal()
        )
        pruneLatestState()
        return receipt(
            metadata: metadata,
            outcome: .cancelled,
            supersededEventIDs: removed.map { [$0.metadata.eventID] } ?? [],
            queueCount: queue.count
        )
    }

    private func normalize(_ metadata: ContextPrewarmHintMetadata) -> QueuedHint {
        var candidates: [CandidateKey: ContextPrewarmCandidate] = [:]
        var invalidCount = 0
        for candidate in metadata.candidates {
            guard candidate.generationID >= 0,
                  !candidate.atomID.rawValue.isEmpty,
                  !candidate.sourceFingerprint.isEmpty,
                  candidate.estimatedByteCount > 0,
                  candidate.likelihood.isFinite,
                  candidate.likelihood >= 0,
                  candidate.likelihood <= 1
            else {
                invalidCount += 1
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
            guard accepted.count < limits.maximumAtomsPerHint,
                  candidate.estimatedByteCount <= limits.maximumBytesPerHint - bytes
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
            droppedAtomCount: invalidCount + metadata.candidates.count - invalidCount - accepted.count,
            byteCount: bytes
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
                + rhs.droppedAtomCount,
            byteCount: merged.byteCount
        )
    }

    private func enforceQueueBound() -> [String] {
        let ranked = queue.values.sorted(by: Self.hintRanksBefore)
        let retained = ranked.prefix(limits.maximumQueuedHints)
        let retainedScopes = Set(retained.map(\.metadata.scope))
        let evicted = ranked
            .filter { !retainedScopes.contains($0.metadata.scope) }
            .map(\.metadata.eventID)
            .sorted()
        for scope in queue.keys where !retainedScopes.contains(scope) {
            queue[scope] = nil
        }
        return evicted
    }

    private func pruneLatestState() {
        guard latest.count > limits.maximumTrackedScopes else { return }
        let queuedScopes = Set(queue.keys)
        let removable = latest
            .filter { !queuedScopes.contains($0.key) }
            .sorted { lhs, rhs in
                if lhs.value.ordinal != rhs.value.ordinal {
                    return lhs.value.ordinal < rhs.value.ordinal
                }
                return lhs.key < rhs.key
            }
        for entry in removable.prefix(latest.count - limits.maximumTrackedScopes) {
            latest[entry.key] = nil
        }
    }

    private func nextOrdinal() -> UInt64 {
        stateOrdinal &+= 1
        return stateOrdinal
    }

    private func receipt(
        metadata: ContextPrewarmHintMetadata,
        outcome: ContextPrewarmSubmissionOutcome,
        supersededEventIDs: [String] = [],
        evictedEventIDs: [String] = [],
        acceptedAtomCount: Int = 0,
        acceptedByteCount: Int = 0,
        droppedAtomCount: Int = 0,
        queueCount: Int? = nil
    ) -> ContextPrewarmSubmissionReceipt {
        ContextPrewarmSubmissionReceipt(
            eventID: metadata.eventID,
            scope: metadata.scope,
            outcome: outcome,
            supersededEventIDs: supersededEventIDs.sorted(),
            evictedEventIDs: evictedEventIDs.sorted(),
            acceptedAtomCount: acceptedAtomCount,
            acceptedByteCount: acceptedByteCount,
            droppedAtomCount: droppedAtomCount,
            queueCount: queueCount ?? queue.count
        )
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

    private static func itemIdentity(_ item: ContextPrewarmPlanItem) -> String {
        [
            item.cause.kind.rawValue,
            item.cause.id,
            item.causeEventID,
            String(item.causeRevision),
            item.candidate.atomID.rawValue,
            String(item.candidate.generationID),
            item.candidate.sourceFingerprint,
        ].joined(separator: "\u{1F}")
    }
}
