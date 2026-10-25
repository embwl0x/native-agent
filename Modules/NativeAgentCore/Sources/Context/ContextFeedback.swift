import Foundation

// Blueprint: | `ContextFeedback.swift` | `ContextFeedbackReducer`: deterministic rebuildable utility projection from explicit-bucket feedback and canonical seeds |

// FC7 feedback is deliberately a pure, rebuildable projection. This file has
// no persistence or owning-system dependencies: authority/privacy arrive from
// canonical sources, and durable learning can leave Context only as a proposal.

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

/// Canonical scoring inputs rebuilt from the current generation.
public struct ContextFeedbackSeed: Codable, Equatable, Sendable {
    public let atomID: ContextAtomID
    public let baseUtility: Double
    public let baseActivation: Double
    public let baseDecay: Double

    public init(
        atomID: ContextAtomID,
        baseUtility: Double = 0,
        baseActivation: Double = 0,
        baseDecay: Double = 1
    ) {
        self.atomID = atomID
        self.baseUtility = Self.clamp(baseUtility, to: -1 ... 1)
        self.baseActivation = Self.clamp(baseActivation, to: -1 ... 1)
        self.baseDecay = Self.clamp(baseDecay, to: 0 ... 1)
    }

    private static func clamp(_ value: Double, to range: ClosedRange<Double>) -> Double {
        min(range.upperBound, max(range.lowerBound, value.isFinite ? value : 0))
    }
}

private struct ContextFeedbackConfiguration: Sendable {
    public let minimumUtility: Double = -1
    public let maximumUtility: Double = 1
    public let retrievalUtilityCap: Double = 0.18
    public let expansionUtilityDelta: Double = 0.025
    public let utilityRetentionPerBucket: Double = 0.995
    public let activationRetentionPerBucket: Double = 0.82
    public let decayRetentionPerBucket: Double = 0.997
}

public struct ContextFeedbackAtomState: Equatable, Sendable {
    public let atomID: ContextAtomID
    public let utility: Double
    public let temporaryActivation: Double
    public let decay: Double
}

public struct ContextFeedbackSnapshot: Equatable, Sendable {
    public let states: [ContextFeedbackAtomState]

    public init(states: [ContextFeedbackAtomState]) {
        self.states = states.sorted { $0.atomID < $1.atomID }
    }
}

public enum ContextFeedbackError: Error, Equatable, Sendable {
    case duplicateSeed(ContextAtomID)
    case duplicateEventID(String)
    case emptyEvent(String)
    case unknownAtom(ContextAtomID)
    case timeBeforeSeed(atomID: ContextAtomID, eventBucket: Int64, stateBucket: Int64)
}

/// Deterministic FC7 utility reducer. Expansion contributes only to the
/// separately capped retrieval component. Corrections, retries, and
/// outcomes affect the bounded outcome component and temporary activation.
public struct ContextFeedbackReducer: Sendable {
    private let configuration = ContextFeedbackConfiguration()

    public init() {}

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
            states: working.values.map { $0.frozen(configuration: configuration) }
        )
    }
}

private extension ContextFeedbackReducer {
    struct MutableState {
        let atomID: ContextAtomID
        var outcomeUtility: Double
        var retrievalUtility: Double = 0
        var temporaryActivation: Double
        var decay: Double
        var lastTimeBucket: Int64?

        init(seed: ContextFeedbackSeed, configuration: ContextFeedbackConfiguration) {
            atomID = seed.atomID
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
                break
            case .expansion:
                retrievalUtility += configuration.expansionUtilityDelta
                temporaryActivation += 0.12
                decay += 0.035
            case .correction(.confirms):
                outcomeUtility += 0.28
                temporaryActivation += 0.45
                decay += 0.15
            case .correction(.contradicts):
                outcomeUtility -= 0.45
                temporaryActivation -= 0.75
                decay -= 0.30
            case .retry:
                outcomeUtility -= 0.12
                temporaryActivation -= 0.20
                decay -= 0.10
            case .outcome(.completed):
                break
            case .outcome(.confirmed):
                outcomeUtility += 0.16
                temporaryActivation += 0.18
                decay += 0.08
            case .outcome(.contradicted):
                outcomeUtility -= 0.30
                temporaryActivation -= 0.45
                decay -= 0.22
            case .outcome(.abandoned):
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
                utility: Self.clamp(
                    outcomeUtility + retrievalUtility,
                    configuration.minimumUtility ... configuration.maximumUtility
                ),
                temporaryActivation: temporaryActivation,
                decay: decay
            )
        }

        static func clamp(_ value: Double, _ range: ClosedRange<Double>) -> Double {
            min(range.upperBound, max(range.lowerBound, value.isFinite ? value : 0))
        }
    }
}
