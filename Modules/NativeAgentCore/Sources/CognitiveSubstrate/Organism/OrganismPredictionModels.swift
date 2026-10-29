import Foundation
// Blueprint: | `OrganismPredictionModels.swift` | Shared prediction rows, ledger, body confidence and cumulative outcome evidence |

public enum OrganismPredictionKind: String, Codable, Sendable, Equatable, CaseIterable {
    case toolCompletion
    case providerCompletion
    case phoneDelivery
    case approvalResolution
    case workflowAdvance
    /// Semantic expectations concern how work lands and affect strategy, never body capability beliefs.
    case semanticExpectation

    /// The substrate chooses words for what she is waiting to find out, never exposing Swift case names.
    public var humanLabel: String {
        switch self {
        case .toolCompletion: return "a tool to finish"
        case .providerCompletion: return "a reply to come back"
        case .phoneDelivery: return "a message to reach him"
        case .approvalResolution: return "your approval"
        case .workflowAdvance: return "the work to move on"
        case .semanticExpectation: return "how that landed"
        }
    }
}

public enum OrganismPredictionStatus: String, Codable, Sendable, Equatable, CaseIterable {
    case pending
    case satisfied
    case violated
    case expired
}

public struct OrganismBodyConfidence: Codable, Sendable, Equatable {
    public var providerPath: Double
    public var toolPath: Double
    public var phonePath: Double
    public var approvalPath: Double
    public var workflowPath: Double

    public init(
        providerPath: Double = 0.5,
        toolPath: Double = 0.5,
        phonePath: Double = 0.5,
        approvalPath: Double = 0.5,
        workflowPath: Double = 0.5
    ) {
        self.providerPath = Self.clamp(providerPath)
        self.toolPath = Self.clamp(toolPath)
        self.phonePath = Self.clamp(phonePath)
        self.approvalPath = Self.clamp(approvalPath)
        self.workflowPath = Self.clamp(workflowPath)
    }

    public static let neutral = OrganismBodyConfidence()

    static func clamp(_ value: Double) -> Double {
        (value).clamped01()
    }
}

public struct OrganismPrediction: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var kind: OrganismPredictionKind
    public var sourceOrgan: String
    public var createdAt: Date
    public var dueAt: Date
    public var status: OrganismPredictionStatus
    public var confidence: Double
    public var uncertainty: Double
    public var evidenceCount: Int
    public var lastUpdatedAt: Date
    /// Session and completion turn for semantic rows only; other kinds are
    /// correlation-keyed. An absent wire key decodes as nil.
    public var semanticScope: OrganismSemanticScope?
    /// Only semantic-expectation rows may carry a horizon; an absent wire key decodes as nil.
    public var horizon: OrganismHorizonExpectation?

    public init(
        id: String,
        kind: OrganismPredictionKind,
        sourceOrgan: String,
        createdAt: Date,
        dueAt: Date,
        status: OrganismPredictionStatus = .pending,
        confidence: Double = 0.5,
        uncertainty: Double = 0.5,
        evidenceCount: Int = 1,
        lastUpdatedAt: Date,
        semanticScope: OrganismSemanticScope? = nil,
        horizon: OrganismHorizonExpectation? = nil
    ) {
        // Correlated operational identities can occupy 124 characters.
        self.id = String(id.trimmingCharacters(in: .whitespacesAndNewlines).prefix(128))
        self.kind = kind
        self.sourceOrgan = String(sourceOrgan.trimmingCharacters(in: .whitespacesAndNewlines).prefix(80))
        self.createdAt = createdAt
        self.dueAt = dueAt
        self.status = status
        self.confidence = OrganismBodyConfidence.clamp(confidence)
        self.uncertainty = OrganismBodyConfidence.clamp(uncertainty)
        self.evidenceCount = max(0, evidenceCount)
        self.lastUpdatedAt = lastUpdatedAt
        // Scope belongs to the semantic lane alone; no other kind can grow one.
        self.semanticScope = kind == .semanticExpectation
            ? semanticScope.flatMap { $0.isUsable ? $0 : nil }
            : nil
        // Same discipline for the horizon payload: only the family that shares
        // the semantic kind may carry it, so no other lane can grow a row.
        self.horizon = kind == .semanticExpectation ? horizon : nil
    }
}

/// Time-forgotten counterpart of the lifetime outcome tallies. Fractional
/// because the organism clock ticks at second granularity: integer counters
/// cannot carry an exponential decay without either starving (a one-second
/// tick never removes half a unit) or bleeding at a rate set by signal
/// frequency instead of wall time.
public struct OrganismPredictionOutcomeWeights: Codable, Sendable, Equatable {
    public var satisfied: Double
    public var violated: Double
    public var expired: Double

    public init(satisfied: Double = 0, violated: Double = 0, expired: Double = 0) {
        self.satisfied = Self.clamp(satisfied)
        self.violated = Self.clamp(violated)
        self.expired = Self.clamp(expired)
    }

    private static func clamp(_ value: Double) -> Double {
        value.isFinite ? max(0, value) : 0
    }
}

/// Cumulative, per-capability outcome evidence. Unlike the bounded prediction
/// reservoir, these counters are not a display sample and therefore remain a
/// valid basis for Agent's capability self-read after old rows are evicted.
public struct OrganismPredictionOutcomeCounts: Codable, Sendable, Equatable {
    public var satisfied: Int
    public var violated: Int
    public var expired: Int
    public var lastEvidenceAt: Date?
    /// Lifetime counts stay monotone; weights forget on the organism clock.
    /// An absent wire key seeds weights from the lifetime tally.
    public var weights: OrganismPredictionOutcomeWeights?

    public init(
        satisfied: Int = 0,
        violated: Int = 0,
        expired: Int = 0,
        lastEvidenceAt: Date? = nil,
        weights: OrganismPredictionOutcomeWeights? = nil
    ) {
        self.satisfied = max(0, satisfied)
        self.violated = max(0, violated)
        self.expired = max(0, expired)
        self.lastEvidenceAt = lastEvidenceAt
        self.weights = weights
    }

    /// Recorded weights, or the lifetime tally seeded for a state written
    /// before forgetting existed. The seed is discounted by the age of
    /// `lastEvidenceAt`, because decay only ever runs forward from the upgrade:
    /// an undiscounted seed would let months-old evidence read as if all of it
    /// had landed at restore, contradicting the staleness the same record
    /// reports. Full strength only when the state carries no evidence date to
    /// age it against.
    public func effectiveWeights(at date: Date) -> OrganismPredictionOutcomeWeights {
        if let weights { return weights }
        var factor: Double = 1
        if let lastEvidenceAt {
            let elapsed: Double = max(0, date.timeIntervalSince(lastEvidenceAt))
            let halfLife: Double = OrganismCapabilitySelfModel.evidenceHalfLife
            factor = pow(0.5, elapsed / halfLife)
        }
        return OrganismPredictionOutcomeWeights(
            satisfied: Double(satisfied) * factor,
            violated: Double(violated) * factor,
            expired: Double(expired) * factor
        )
    }
}

public struct OrganismPredictionSummary: Codable, Sendable, Equatable {
    public var pendingCount: Int
    public var satisfiedCount: Int
    public var violatedCount: Int
    public var expiredCount: Int
    public var averagePendingConfidence: Double
    public var averagePendingUncertainty: Double
    public var peripheralUncertainty: Double
    public var strategyCaution: Double
    public var bodyConfidence: OrganismBodyConfidence
    public var lastViolationAt: Date?

    public init(
        pendingCount: Int = 0,
        satisfiedCount: Int = 0,
        violatedCount: Int = 0,
        expiredCount: Int = 0,
        averagePendingConfidence: Double = 0,
        averagePendingUncertainty: Double = 0,
        peripheralUncertainty: Double = 0,
        strategyCaution: Double = 0,
        bodyConfidence: OrganismBodyConfidence = .neutral,
        lastViolationAt: Date? = nil
    ) {
        self.pendingCount = max(0, pendingCount)
        self.satisfiedCount = max(0, satisfiedCount)
        self.violatedCount = max(0, violatedCount)
        self.expiredCount = max(0, expiredCount)
        self.averagePendingConfidence = OrganismBodyConfidence.clamp(averagePendingConfidence)
        self.averagePendingUncertainty = OrganismBodyConfidence.clamp(averagePendingUncertainty)
        self.peripheralUncertainty = OrganismBodyConfidence.clamp(peripheralUncertainty)
        self.strategyCaution = OrganismBodyConfidence.clamp(strategyCaution)
        self.bodyConfidence = bodyConfidence
        self.lastViolationAt = lastViolationAt
    }

    public static let empty = OrganismPredictionSummary()
}

public struct OrganismPredictionLedger: Codable, Sendable, Equatable {
    public var predictions: [String: OrganismPrediction]
    public var satisfiedCount: Int
    public var violatedCount: Int
    public var expiredCount: Int
    public var peripheralUncertainty: Double
    public var strategyCaution: Double
    public var bodyConfidence: OrganismBodyConfidence
    public var lastUpdatedAt: Date?
    public var lastViolationAt: Date?
    /// Feeling-bearing misses have their own clock; infrastructure misses
    /// still update the operational violation clock above.
    public var lastFeltViolationAt: Date?
    /// Nil means per-kind totals are unavailable; the bounded reservoir is no outcome sample.
    public var outcomeCountsByKind: [String: OrganismPredictionOutcomeCounts]?
    /// At most one felt resolution per prediction kind per hour, keyed by
    /// `OrganismPredictionKind` raw value. An absent wire key decodes as nil.
    public var lastResolutionFeltAt: [String: Date]?

    public init(
        predictions: [String: OrganismPrediction] = [:],
        satisfiedCount: Int = 0,
        violatedCount: Int = 0,
        expiredCount: Int = 0,
        peripheralUncertainty: Double = 0,
        strategyCaution: Double = 0,
        bodyConfidence: OrganismBodyConfidence = .neutral,
        lastUpdatedAt: Date? = nil,
        lastViolationAt: Date? = nil,
        lastFeltViolationAt: Date? = nil,
        outcomeCountsByKind: [String: OrganismPredictionOutcomeCounts]? = nil
    ) {
        self.predictions = predictions
        self.satisfiedCount = max(0, satisfiedCount)
        self.violatedCount = max(0, violatedCount)
        self.expiredCount = max(0, expiredCount)
        self.peripheralUncertainty = OrganismBodyConfidence.clamp(peripheralUncertainty)
        self.strategyCaution = OrganismBodyConfidence.clamp(strategyCaution)
        self.bodyConfidence = bodyConfidence
        self.lastUpdatedAt = lastUpdatedAt
        self.lastViolationAt = lastViolationAt
        self.lastFeltViolationAt = lastFeltViolationAt
        self.outcomeCountsByKind = outcomeCountsByKind
    }

    public static let empty = OrganismPredictionLedger()

    public func summary() -> OrganismPredictionSummary {
        let pending = predictions.values.filter { $0.status == .pending }
        let averageConfidence = pending.isEmpty
            ? 0
            : pending.reduce(0) { $0 + $1.confidence } / Double(pending.count)
        let averageUncertainty = pending.isEmpty
            ? 0
            : pending.reduce(0) { $0 + $1.uncertainty } / Double(pending.count)
        return OrganismPredictionSummary(
            pendingCount: pending.count,
            satisfiedCount: satisfiedCount,
            violatedCount: violatedCount,
            expiredCount: expiredCount,
            averagePendingConfidence: averageConfidence,
            averagePendingUncertainty: averageUncertainty,
            peripheralUncertainty: peripheralUncertainty,
            strategyCaution: strategyCaution,
            bodyConfidence: bodyConfidence,
            lastViolationAt: lastViolationAt
        )
    }
}
