import Foundation

// FC7 feedback is deliberately a pure, rebuildable projection. This file has
// no persistence or owning-system dependencies: authority/privacy arrive from
// canonical sources, and durable learning can leave Context only as a proposal.

public enum ContextFeedbackStorageClass: String, Codable, Sendable {
    case rebuildableCache = "rebuildable_cache"
}

public enum ContextCorrectionEffect: String, Codable, Sendable {
    case confirms
    case contradicts
}

public enum ContextTurnOutcome: String, Codable, Sendable {
    case completed
    case confirmed
    case contradicted
    case abandoned
}

public enum ContextFeedbackSignal: Codable, Equatable, Sendable {
    case selection
    case expansion
    case correction(ContextCorrectionEffect)
    case retry
    case outcome(ContextTurnOutcome)
}

/// A turn-time observation. Time is an explicit bucket rather than a wall-clock
/// read so the same canonical seed and event log always rebuild the same state.
public struct ContextFeedbackEvent: Codable, Equatable, Sendable {
    public let id: String
    public let atomIDs: [ContextAtomID]
    public let signal: ContextFeedbackSignal
    public let timeBucket: Int64
    public let evidenceIDs: [String]

    public init(
        id: String,
        atomIDs: [ContextAtomID],
        signal: ContextFeedbackSignal,
        timeBucket: Int64,
        evidenceIDs: [String] = []
    ) {
        self.id = id
        self.atomIDs = Array(Set(atomIDs)).sorted()
        self.signal = signal
        self.timeBucket = timeBucket
        self.evidenceIDs = Array(Set(evidenceIDs)).sorted()
    }

    fileprivate var deterministicFingerprint: String {
        ContextStableID.digest(parts: [
            id,
            String(timeBucket),
            String(describing: signal),
        ] + atomIDs.map(\.rawValue) + evidenceIDs)
    }
}

/// Canonical inputs plus optional compiler defaults. Feedback never mutates the
/// policy fields; a rebuild obtains them again from the current generation.
public struct ContextFeedbackSeed: Codable, Equatable, Sendable {
    public let atomID: ContextAtomID
    public let authority: ContextAuthority
    public let privacy: ContextPrivacy
    public let baseUtility: Double
    public let baseActivation: Double
    public let baseDecay: Double

    public init(
        atomID: ContextAtomID,
        authority: ContextAuthority,
        privacy: ContextPrivacy,
        baseUtility: Double = 0,
        baseActivation: Double = 0,
        baseDecay: Double = 1
    ) {
        self.atomID = atomID
        self.authority = authority
        self.privacy = privacy
        self.baseUtility = Self.clamp(baseUtility, to: -1 ... 1)
        self.baseActivation = Self.clamp(baseActivation, to: -1 ... 1)
        self.baseDecay = Self.clamp(baseDecay, to: 0 ... 1)
    }

    private static func clamp(_ value: Double, to range: ClosedRange<Double>) -> Double {
        min(range.upperBound, max(range.lowerBound, value.isFinite ? value : 0))
    }
}

public struct ContextFeedbackConfiguration: Codable, Equatable, Sendable {
    public let minimumUtility: Double
    public let maximumUtility: Double
    public let retrievalUtilityCap: Double
    public let selectionUtilityDelta: Double
    public let expansionUtilityDelta: Double
    public let utilityRetentionPerBucket: Double
    public let activationRetentionPerBucket: Double
    public let decayRetentionPerBucket: Double

    public init(
        minimumUtility: Double = -1,
        maximumUtility: Double = 1,
        retrievalUtilityCap: Double = 0.18,
        selectionUtilityDelta: Double = 0.01,
        expansionUtilityDelta: Double = 0.025,
        utilityRetentionPerBucket: Double = 0.995,
        activationRetentionPerBucket: Double = 0.82,
        decayRetentionPerBucket: Double = 0.997
    ) {
        let proposedLower = minimumUtility.isFinite ? minimumUtility : -1
        let proposedUpper = maximumUtility.isFinite ? maximumUtility : 1
        self.minimumUtility = min(1, max(-1, min(proposedLower, proposedUpper)))
        self.maximumUtility = min(1, max(-1, max(proposedLower, proposedUpper)))
        self.retrievalUtilityCap = min(1, max(0, retrievalUtilityCap))
        self.selectionUtilityDelta = min(1, max(0, selectionUtilityDelta))
        self.expansionUtilityDelta = min(1, max(0, expansionUtilityDelta))
        self.utilityRetentionPerBucket = min(1, max(0, utilityRetentionPerBucket))
        self.activationRetentionPerBucket = min(1, max(0, activationRetentionPerBucket))
        self.decayRetentionPerBucket = min(1, max(0, decayRetentionPerBucket))
    }
}

public struct ContextFeedbackAtomState: Codable, Equatable, Sendable {
    public let atomID: ContextAtomID
    public let authority: ContextAuthority
    public let privacy: ContextPrivacy
    public let utility: Double
    public let retrievalUtility: Double
    public let temporaryActivation: Double
    public let decay: Double
    public let selectionCount: Int
    public let expansionCount: Int
    public let correctionCount: Int
    public let retryCount: Int
    public let outcomeCount: Int
    public let lastTimeBucket: Int64?

    fileprivate let outcomeUtility: Double
}

public struct ContextFeedbackSnapshot: Codable, Equatable, Sendable {
    public let storageClass: ContextFeedbackStorageClass
    public let states: [ContextFeedbackAtomState]
    public let appliedEventIDs: [String]
    public let throughTimeBucket: Int64?

    public init(
        states: [ContextFeedbackAtomState],
        appliedEventIDs: [String],
        throughTimeBucket: Int64?
    ) {
        storageClass = .rebuildableCache
        self.states = states.sorted { $0.atomID < $1.atomID }
        self.appliedEventIDs = appliedEventIDs.sorted()
        self.throughTimeBucket = throughTimeBucket
    }

    public subscript(atomID: ContextAtomID) -> ContextFeedbackAtomState? {
        states.first { $0.atomID == atomID }
    }
}

public enum ContextFeedbackError: Error, Equatable, Sendable {
    case duplicateSeed(ContextAtomID)
    case duplicateEventID(String)
    case emptyEvent(String)
    case unknownAtom(ContextAtomID)
    case timeBeforeSeed(atomID: ContextAtomID, eventBucket: Int64, stateBucket: Int64)
}

/// Deterministic FC7 utility reducer. Selection and expansion contribute only
/// to the separately capped retrieval component. Corrections, retries, and
/// outcomes affect the bounded outcome component and temporary activation.
public struct ContextFeedbackReducer: Sendable {
    public let configuration: ContextFeedbackConfiguration

    public init(configuration: ContextFeedbackConfiguration = .init()) {
        self.configuration = configuration
    }

    public func rebuild(
        seeds: [ContextFeedbackSeed],
        events: [ContextFeedbackEvent],
        through timeBucket: Int64? = nil
    ) throws -> ContextFeedbackSnapshot {
        var working: [ContextAtomID: MutableState] = [:]
        for seed in seeds.sorted(by: { $0.atomID < $1.atomID }) {
            guard working[seed.atomID] == nil else {
                throw ContextFeedbackError.duplicateSeed(seed.atomID)
            }
            working[seed.atomID] = MutableState(seed: seed, configuration: configuration)
        }

        let ordered = events.sorted {
            if $0.timeBucket != $1.timeBucket { return $0.timeBucket < $1.timeBucket }
            if $0.id != $1.id { return $0.id < $1.id }
            return $0.deterministicFingerprint < $1.deterministicFingerprint
        }
        var eventByID: [String: ContextFeedbackEvent] = [:]
        for event in ordered {
            guard !event.atomIDs.isEmpty else { throw ContextFeedbackError.emptyEvent(event.id) }
            if let prior = eventByID[event.id] {
                guard prior == event else { throw ContextFeedbackError.duplicateEventID(event.id) }
                continue
            }
            eventByID[event.id] = event
            for atomID in event.atomIDs {
                guard var state = working[atomID] else {
                    throw ContextFeedbackError.unknownAtom(atomID)
                }
                try state.apply(event, configuration: configuration)
                working[atomID] = state
            }
        }

        let finalBucket = timeBucket ?? ordered.last?.timeBucket
        if let finalBucket {
            for atomID in working.keys.sorted() {
                guard var state = working[atomID] else { continue }
                try state.advance(to: finalBucket, configuration: configuration)
                working[atomID] = state
            }
        }
        return ContextFeedbackSnapshot(
            states: working.values.map { $0.frozen(configuration: configuration) },
            appliedEventIDs: Array(eventByID.keys),
            throughTimeBucket: finalBucket
        )
    }
}

/// Authority is a primary ordering key. Utility can refine peers at the same
/// authority but can never promote a frequently retrieved weak claim over a
/// stronger one. Privacy remains an eligibility gate, never a score.
public enum ContextFeedbackRanker {
    public static func eligible(
        _ states: [ContextFeedbackAtomState],
        allowedPrivacy: Set<ContextPrivacy>
    ) -> [ContextFeedbackAtomState] {
        states.filter { allowedPrivacy.contains($0.privacy) }.sorted(by: ranksBefore)
    }

    public static func ranksBefore(
        _ lhs: ContextFeedbackAtomState,
        _ rhs: ContextFeedbackAtomState
    ) -> Bool {
        if lhs.authority.rank != rhs.authority.rank {
            return lhs.authority.rank > rhs.authority.rank
        }
        if lhs.utility != rhs.utility { return lhs.utility > rhs.utility }
        if lhs.decay != rhs.decay { return lhs.decay > rhs.decay }
        return lhs.atomID < rhs.atomID
    }
}

private extension ContextFeedbackReducer {
    struct MutableState {
        let atomID: ContextAtomID
        let authority: ContextAuthority
        let privacy: ContextPrivacy
        var outcomeUtility: Double
        var retrievalUtility: Double = 0
        var temporaryActivation: Double
        var decay: Double
        var selectionCount = 0
        var expansionCount = 0
        var correctionCount = 0
        var retryCount = 0
        var outcomeCount = 0
        var lastTimeBucket: Int64?

        init(seed: ContextFeedbackSeed, configuration: ContextFeedbackConfiguration) {
            atomID = seed.atomID
            authority = seed.authority
            privacy = seed.privacy
            outcomeUtility = Self.clamp(
                seed.baseUtility,
                configuration.minimumUtility ... configuration.maximumUtility
            )
            temporaryActivation = Self.clamp(seed.baseActivation, -1 ... 1)
            decay = Self.clamp(seed.baseDecay, 0 ... 1)
        }

        mutating func advance(
            to bucket: Int64,
            configuration: ContextFeedbackConfiguration
        ) throws {
            guard let lastTimeBucket else {
                self.lastTimeBucket = bucket
                return
            }
            guard bucket >= lastTimeBucket else {
                throw ContextFeedbackError.timeBeforeSeed(
                    atomID: atomID,
                    eventBucket: bucket,
                    stateBucket: lastTimeBucket
                )
            }
            let elapsed = bucket - lastTimeBucket
            guard elapsed > 0 else { return }
            outcomeUtility *= pow(configuration.utilityRetentionPerBucket, Double(elapsed))
            retrievalUtility *= pow(configuration.utilityRetentionPerBucket, Double(elapsed))
            temporaryActivation *= pow(configuration.activationRetentionPerBucket, Double(elapsed))
            decay *= pow(configuration.decayRetentionPerBucket, Double(elapsed))
            self.lastTimeBucket = bucket
        }

        mutating func apply(
            _ event: ContextFeedbackEvent,
            configuration: ContextFeedbackConfiguration
        ) throws {
            try advance(to: event.timeBucket, configuration: configuration)
            switch event.signal {
            case .selection:
                selectionCount += 1
                retrievalUtility += configuration.selectionUtilityDelta
                temporaryActivation += 0.06
                decay += 0.015
            case .expansion:
                expansionCount += 1
                retrievalUtility += configuration.expansionUtilityDelta
                temporaryActivation += 0.12
                decay += 0.035
            case .correction(.confirms):
                correctionCount += 1
                outcomeUtility += 0.28
                temporaryActivation += 0.45
                decay += 0.15
            case .correction(.contradicts):
                correctionCount += 1
                outcomeUtility -= 0.45
                temporaryActivation -= 0.75
                decay -= 0.30
            case .retry:
                retryCount += 1
                outcomeUtility -= 0.12
                temporaryActivation -= 0.20
                decay -= 0.10
            case .outcome(.completed):
                // A response merely reaching completion is transport evidence,
                // not evidence that every selected atom helped. Keep the count
                // for replay/diagnostics without manufacturing retrieval value.
                outcomeCount += 1
            case .outcome(.confirmed):
                outcomeCount += 1
                outcomeUtility += 0.16
                temporaryActivation += 0.18
                decay += 0.08
            case .outcome(.contradicted):
                outcomeCount += 1
                outcomeUtility -= 0.30
                temporaryActivation -= 0.45
                decay -= 0.22
            case .outcome(.abandoned):
                outcomeCount += 1
                outcomeUtility -= 0.14
                temporaryActivation -= 0.18
                decay -= 0.12
            }
            retrievalUtility = Self.clamp(
                retrievalUtility,
                0 ... configuration.retrievalUtilityCap
            )
            outcomeUtility = Self.clamp(
                outcomeUtility,
                configuration.minimumUtility ... configuration.maximumUtility
            )
            temporaryActivation = Self.clamp(temporaryActivation, -1 ... 1)
            decay = Self.clamp(decay, 0 ... 1)
        }

        func frozen(configuration: ContextFeedbackConfiguration) -> ContextFeedbackAtomState {
            ContextFeedbackAtomState(
                atomID: atomID,
                authority: authority,
                privacy: privacy,
                utility: Self.clamp(
                    outcomeUtility + retrievalUtility,
                    configuration.minimumUtility ... configuration.maximumUtility
                ),
                retrievalUtility: retrievalUtility,
                temporaryActivation: temporaryActivation,
                decay: decay,
                selectionCount: selectionCount,
                expansionCount: expansionCount,
                correctionCount: correctionCount,
                retryCount: retryCount,
                outcomeCount: outcomeCount,
                lastTimeBucket: lastTimeBucket,
                outcomeUtility: outcomeUtility
            )
        }

        static func clamp(_ value: Double, _ range: ClosedRange<Double>) -> Double {
            min(range.upperBound, max(range.lowerBound, value.isFinite ? value : 0))
        }
    }
}
