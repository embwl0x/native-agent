import Foundation

public struct OrganismPersistentState: Codable, Sendable, Equatable {
    public var schemaVersion: Int
    public var savedAt: Date
    public var chemicalState: ChemicalState
    public var bodySchema: BodySchema
    public var field: OrganismField
    public var predictionLedger: OrganismPredictionLedger
    public var dreamRepairState: OrganismDreamRepairState
    public var reflexState: OrganismReflexState
    public var signalCount: Int
    public var lastSignalAt: Date?

    public init(
        schemaVersion: Int = 1,
        savedAt: Date,
        chemicalState: ChemicalState = .neutral,
        bodySchema: BodySchema = .neutral,
        field: OrganismField = .empty,
        predictionLedger: OrganismPredictionLedger = .empty,
        dreamRepairState: OrganismDreamRepairState = .empty,
        reflexState: OrganismReflexState = .empty,
        signalCount: Int = 0,
        lastSignalAt: Date? = nil
    ) {
        self.schemaVersion = max(1, schemaVersion)
        self.savedAt = savedAt
        self.chemicalState = chemicalState
        self.bodySchema = bodySchema
        self.field = field
        self.predictionLedger = predictionLedger
        self.dreamRepairState = dreamRepairState
        self.reflexState = reflexState
        self.signalCount = max(0, signalCount)
        self.lastSignalAt = lastSignalAt
    }

    public func decayed(
        at now: Date,
        limits: OrganismPersistenceLimits = .defaults,
        settleBodySchema: Bool = true
    ) -> OrganismPersistentState {
        let elapsedHours = max(0, now.timeIntervalSince(savedAt) / 3_600)
        guard elapsedHours > 0 else { return self }
        let boundedHours = min(elapsedHours, limits.maximumDecayHours)

        var next = self
        next.savedAt = now
        next.chemicalState = decayedChemistry(chemicalState, hours: boundedHours)
        next.bodySchema = settleBodySchema ? settledBodySchema(bodySchema) : bodySchema
        next.field = decayedField(field, hours: boundedHours, limits: limits)
        next.predictionLedger = decayedPredictions(predictionLedger, now: now, hours: boundedHours, limits: limits)
        next.reflexState = boundedReflexes(reflexState, limits: limits)
        next.signalCount = min(max(0, signalCount), limits.maximumSignalCount)
        return next
    }

    private func decayedChemistry(_ state: ChemicalState, hours: Double) -> ChemicalState {
        let quick = pow(0.78, hours)
        let slow = pow(0.92, hours)
        let neutral = ChemicalState.neutral
        func towardZero(_ value: Double, factor: Double = quick) -> Double {
            ChemicalState.clamp(value * factor)
        }
        func towardNeutral(_ value: Double, neutral neutralValue: Double, factor: Double = slow) -> Double {
            ChemicalState.clamp(neutralValue + ((value - neutralValue) * factor))
        }
        return ChemicalState(
            warmth: towardZero(state.warmth, factor: slow),
            vigilance: towardZero(state.vigilance),
            curiosity: towardZero(state.curiosity, factor: slow),
            fatigue: towardZero(state.fatigue),
            coherence: towardNeutral(state.coherence, neutral: neutral.coherence),
            agency: towardZero(state.agency, factor: slow),
            tenderness: towardZero(state.tenderness, factor: slow),
            confidence: towardNeutral(state.confidence, neutral: neutral.confidence),
            novelty: towardZero(state.novelty),
            urgency: towardZero(state.urgency)
        )
    }

    private func settledBodySchema(_ body: BodySchema) -> BodySchema {
        var next = body
        next.resourcePressure = .nominal
        return next
    }

    private func decayedField(
        _ field: OrganismField,
        hours: Double,
        limits: OrganismPersistenceLimits
    ) -> OrganismField {
        let activationFactor = pow(0.82, hours)
        let chargeFactor = pow(0.90, hours)
        let eligibilityFactor = pow(0.65, hours)
        var next = field
        next.nodes = field.nodes.mapValues { node in
            var copy = node
            copy.activation = OrganismNode.clamp01(copy.activation * activationFactor)
            copy.charge = OrganismNode.clamp01(copy.charge * chargeFactor)
            return copy
        }
        next.edges = field.edges.mapValues { edge in
            var copy = edge
            copy.eligibility = OrganismNode.clamp01(copy.eligibility * eligibilityFactor)
            copy.uncertainty = OrganismNode.clamp01(copy.uncertainty + (0.01 * min(hours, 12)))
            return copy
        }
        next.nodes = Dictionary(uniqueKeysWithValues: next.nodes.values
            .sorted {
                if $0.activation != $1.activation { return $0.activation > $1.activation }
                if $0.charge != $1.charge { return $0.charge > $1.charge }
                return $0.id < $1.id
            }
            .prefix(limits.maximumPersistedNodes)
            .map { ($0.id, $0) })
        let keptNodeIDs = Set(next.nodes.keys)
        next.edges = Dictionary(uniqueKeysWithValues: next.edges.values
            .filter { keptNodeIDs.contains($0.sourceID) && keptNodeIDs.contains($0.targetID) }
            .sorted {
                if $0.weight != $1.weight { return $0.weight > $1.weight }
                if $0.eligibility != $1.eligibility { return $0.eligibility > $1.eligibility }
                return $0.id < $1.id
            }
            .prefix(limits.maximumPersistedEdges)
            .map { ($0.id, $0) })
        return next
    }

    private func decayedPredictions(
        _ ledger: OrganismPredictionLedger,
        now: Date,
        hours: Double,
        limits: OrganismPersistenceLimits
    ) -> OrganismPredictionLedger {
        var next = ledger
        next.peripheralUncertainty = OrganismBodyConfidence.clamp(next.peripheralUncertainty * pow(0.84, hours))
        next.strategyCaution = OrganismBodyConfidence.clamp(next.strategyCaution * pow(0.82, hours))
        var expiredKinds: [OrganismPredictionKind] = []
        let decayed = next.predictions.values.map { prediction -> OrganismPrediction in
                var copy = prediction
                if copy.status == .pending && copy.dueAt < now {
                    copy.status = .expired
                    copy.lastUpdatedAt = now
                    expiredKinds.append(copy.kind)
                }
                copy.uncertainty = OrganismBodyConfidence.clamp(copy.uncertainty * pow(0.94, hours))
                return copy
            }
        // An expiry found by the restart/idle sweep is the same evidence the
        // live sweep records (OrganismPredictiveBody.expireOverdue). Flipping
        // the row without the counters meant every expectation that ran out
        // across a restart or a sleep gap was silently dropped from the
        // cumulative outcome evidence — and the capability self-read, which now
        // prefers outcomeCountsByKind over the bounded reservoir, then read
        // more certain than the evidence warranted. The row is only counted on
        // the tick that flips it: later sweeps see .expired and skip it.
        // Forget the elapsed window BEFORE stamping evidence dated `now`: the
        // expiry this sweep just found is fresh and must not be decayed by the
        // same window that aged everything preceding it.
        next.outcomeCountsByKind = next.outcomeCountsByKind
            .map { forgottenOutcomeCounts($0, at: now, hours: hours) }
        for kind in expiredKinds.sorted(by: { $0.rawValue < $1.rawValue }) {
            next.expiredCount += 1
            OrganismPredictiveBody.recordOutcome(.expired, kind: kind, at: now, ledger: &next)
        }
        next.predictions = Dictionary(uniqueKeysWithValues: OrganismPredictionRetention
            .bounded(decayed, maximum: limits.maximumPersistedPredictions)
            .map { ($0.id, $0) })
        next.lastUpdatedAt = now
        return next
    }

    /// Cumulative outcome evidence was the one organism quantity that never
    /// moved with the clock, so after thousands of clean runs no real
    /// regression could shift `successLikelihood` and a bad stretch's
    /// missing-evidence penalty never relaxed. The lifetime Int tallies stay
    /// untouched as the receipt; the fractional weights the capability read
    /// reasons from forget on the same 7-day half-life that read already uses
    /// for freshness, so evidence weight and evidence freshness fade together
    /// instead of a belief reading certain from outcomes it calls stale.
    private func forgottenOutcomeCounts(
        _ counts: [String: OrganismPredictionOutcomeCounts],
        at now: Date,
        hours: Double
    ) -> [String: OrganismPredictionOutcomeCounts] {
        let halfLifeHours = OrganismCapabilitySelfModel.evidenceHalfLife / 3_600
        guard hours > 0, halfLifeHours > 0 else { return counts }
        let factor = pow(0.5, hours / halfLifeHours)
        return counts.mapValues { count in
            var next = count
            guard let weights = count.weights else {
                // First tick after upgrade: `effectiveWeights(at:)` already
                // ages the legacy tally all the way to `now`, so applying this
                // window's factor on top would decay the same elapsed time
                // twice.
                next.weights = count.effectiveWeights(at: now)
                return next
            }
            next.weights = OrganismPredictionOutcomeWeights(
                satisfied: weights.satisfied * factor,
                violated: weights.violated * factor,
                expired: weights.expired * factor
            )
            return next
        }
    }

    private func boundedReflexes(
        _ state: OrganismReflexState,
        limits: OrganismPersistenceLimits
    ) -> OrganismReflexState {
        var next = state
        next.observations = Dictionary(uniqueKeysWithValues: state.observations.values
            .sorted(by: reflexSort)
            .prefix(limits.maximumPersistedReflexes)
            .map { ($0.id, $0) })
        next.candidates = Dictionary(uniqueKeysWithValues: state.candidates.values
            .sorted(by: reflexSort)
            .prefix(limits.maximumPersistedReflexes)
            .map { ($0.id, $0) })
        next.reviewReceipts = Array(state.reviewReceipts.suffix(limits.maximumPersistedReflexReviewReceipts))
        return next
    }

    private func reflexSort(_ lhs: OrganismReflexCandidate, _ rhs: OrganismReflexCandidate) -> Bool {
        if (lhs.retiredAt == nil) != (rhs.retiredAt == nil) { return lhs.retiredAt == nil }
        if lhs.reviewRequired != rhs.reviewRequired { return lhs.reviewRequired && !rhs.reviewRequired }
        if lhs.confidence != rhs.confidence { return lhs.confidence > rhs.confidence }
        if lhs.lastUpdatedAt != rhs.lastUpdatedAt { return lhs.lastUpdatedAt > rhs.lastUpdatedAt }
        return lhs.id < rhs.id
    }

}

public struct OrganismPersistenceLimits: Sendable, Equatable {
    public var maximumDecayHours: Double
    public var maximumPersistedNodes: Int
    public var maximumPersistedEdges: Int
    public var maximumPersistedPredictions: Int
    public var maximumPersistedReflexes: Int
    public var maximumPersistedReflexReviewReceipts: Int
    public var maximumSignalCount: Int

    public init(
        maximumDecayHours: Double = 72,
        maximumPersistedNodes: Int = 96,
        maximumPersistedEdges: Int = 192,
        maximumPersistedPredictions: Int = 96,
        maximumPersistedReflexes: Int = 64,
        maximumPersistedReflexReviewReceipts: Int = 128,
        maximumSignalCount: Int = 1_000_000
    ) {
        self.maximumDecayHours = max(0, maximumDecayHours)
        self.maximumPersistedNodes = max(0, maximumPersistedNodes)
        self.maximumPersistedEdges = max(0, maximumPersistedEdges)
        self.maximumPersistedPredictions = max(0, maximumPersistedPredictions)
        self.maximumPersistedReflexes = max(0, maximumPersistedReflexes)
        self.maximumPersistedReflexReviewReceipts = max(0, maximumPersistedReflexReviewReceipts)
        self.maximumSignalCount = max(0, maximumSignalCount)
    }

    public static let defaults = OrganismPersistenceLimits()
}
