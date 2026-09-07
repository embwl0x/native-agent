import CryptoKit
import Foundation

/// Closed-form time law used by organism tissue that should change with wall
/// time without waking on a polling cadence. The stored value remains an
/// anchor; reads derive the present value and, when meaningful, the one exact
/// future threshold crossing worth scheduling.
public struct OrganismAnalyticDecay: Sendable, Equatable {
    public var valueAtAnchor: Double
    public var equilibrium: Double
    public var halfLife: TimeInterval
    public var anchoredAt: Date

    public init(
        valueAtAnchor: Double,
        equilibrium: Double = 0,
        halfLife: TimeInterval,
        anchoredAt: Date
    ) {
        self.valueAtAnchor = Self.finite(valueAtAnchor)
        self.equilibrium = Self.finite(equilibrium)
        self.halfLife = max(0, Self.finite(halfLife))
        self.anchoredAt = anchoredAt
    }

    public func value(at date: Date) -> Double {
        guard halfLife > 0 else { return equilibrium }
        let elapsed = max(0, date.timeIntervalSince(anchoredAt))
        let factor = pow(0.5, elapsed / halfLife)
        return equilibrium + ((valueAtAnchor - equilibrium) * factor)
    }

    /// Returns the first future instant at which a monotonic decay reaches the
    /// threshold. Nil means the threshold is behind the current direction of
    /// travel, already crossed, or the state is constant.
    public func crossingDate(for threshold: Double, after date: Date) -> Date? {
        guard halfLife > 0 else { return nil }
        let current = value(at: date)
        let target = Self.finite(threshold)
        let delta = current - equilibrium
        let targetDelta = target - equilibrium
        guard delta != 0,
              targetDelta != 0,
              (delta > 0) == (targetDelta > 0),
              abs(targetDelta) < abs(delta) else { return nil }
        let interval = halfLife * log2(abs(delta / targetDelta))
        guard interval.isFinite, interval > 0 else { return nil }
        return date.addingTimeInterval(interval)
    }

    private static func finite(_ value: Double) -> Double {
        value.isFinite ? value : 0
    }
}

public enum OrganismSleepEvidenceClass: String, Codable, Sendable, Equatable {
    /// Exact runtime state already owned by the predictive body or organism
    /// field. This may drive bounded local repair, but never model fitting.
    case exactRuntime = "exact_runtime"
    /// Deterministic fixtures generated without personal source material.
    case generated
    /// A fixed-time, immutable provider-transplant/evaluation epoch.
    case frozenControlled = "frozen_controlled"
}

public enum OrganismSleepResidualKind: String, Codable, Sendable, Equatable, CaseIterable {
    case prediction
    case transitionSurprise = "transition_surprise"
    case contradiction
    case fieldCharge = "field_charge"
    case calibration
}

/// Payload-free provenance for one bounded pressure input. `id` is always an
/// opaque digest; raw prediction IDs, field labels, messages, paths, and tool
/// payloads never enter the read model.
public struct OrganismSleepEvidenceReference: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var kind: OrganismSleepResidualKind
    public var evidenceClass: OrganismSleepEvidenceClass
    public var observedAt: Date
    public var expiresAt: Date?

    public init(
        id: String,
        kind: OrganismSleepResidualKind,
        evidenceClass: OrganismSleepEvidenceClass,
        observedAt: Date,
        expiresAt: Date? = nil
    ) {
        self.id = Self.opaqueID(id)
        self.kind = kind
        self.evidenceClass = evidenceClass
        self.observedAt = observedAt
        self.expiresAt = expiresAt
    }

    private static func opaqueID(_ raw: String) -> String {
        SHA256.hash(data: Data(raw.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

/// Optional exact residuals supplied by an immutable generated/frozen
/// evaluation artifact. Production runtime callers do not need this value.
/// The values are read-only inputs and are never persisted as organism truth.
public struct OrganismSupplementalSleepResiduals: Sendable, Equatable {
    public var transitionSurprise: Double
    public var contradiction: Double
    public var calibration: Double
    public var evidence: [OrganismSleepEvidenceReference]
    public var nextModelReviewAt: Date?

    public init(
        transitionSurprise: Double = 0,
        contradiction: Double = 0,
        calibration: Double = 0,
        evidence: [OrganismSleepEvidenceReference] = [],
        nextModelReviewAt: Date? = nil
    ) {
        self.transitionSurprise = Self.clamp(transitionSurprise)
        self.contradiction = Self.clamp(contradiction)
        self.calibration = Self.clamp(calibration)
        self.evidence = Array(evidence.prefix(32))
        self.nextModelReviewAt = nextModelReviewAt
    }

    public static let empty = Self()

    private static func clamp(_ value: Double) -> Double {
        (value.isFinite ? value : 0).clamped01()
    }
}

public struct OrganismSleepPressureComponents: Sendable, Equatable {
    public var predictionResidual: Double
    public var transitionSurprise: Double
    public var contradictionResidual: Double
    public var fieldChargeResidual: Double
    public var calibrationResidual: Double

    public init(
        predictionResidual: Double = 0,
        transitionSurprise: Double = 0,
        contradictionResidual: Double = 0,
        fieldChargeResidual: Double = 0,
        calibrationResidual: Double = 0
    ) {
        self.predictionResidual = Self.clamp(predictionResidual)
        self.transitionSurprise = Self.clamp(transitionSurprise)
        self.contradictionResidual = Self.clamp(contradictionResidual)
        self.fieldChargeResidual = Self.clamp(fieldChargeResidual)
        self.calibrationResidual = Self.clamp(calibrationResidual)
    }

    private static func clamp(_ value: Double) -> Double {
        (value.isFinite ? value : 0).clamped01()
    }
}

public struct OrganismSleepPressureWeights: Sendable, Equatable {
    public var prediction: Double
    public var transitionSurprise: Double
    public var contradiction: Double
    public var fieldCharge: Double
    public var calibration: Double

    public init(
        prediction: Double = 0.30,
        transitionSurprise: Double = 0.25,
        contradiction: Double = 0.20,
        fieldCharge: Double = 0.15,
        calibration: Double = 0.10
    ) {
        self.prediction = Self.clamp(prediction)
        self.transitionSurprise = Self.clamp(transitionSurprise)
        self.contradiction = Self.clamp(contradiction)
        self.fieldCharge = Self.clamp(fieldCharge)
        self.calibration = Self.clamp(calibration)
    }

    public static let preregistered = Self()

    private static func clamp(_ value: Double) -> Double {
        (value.isFinite ? value : 0).clamped01()
    }
}

public enum OrganismSleepLane: String, Codable, Sendable, Equatable, CaseIterable {
    case quietLocalRepair = "quiet_local_repair"
    case operationalConsolidation = "operational_consolidation"
    case identityDreamProposal = "identity_dream_proposal"
    case generatedFrozenRecalibration = "generated_frozen_recalibration"
}

public enum OrganismSleepLaneDisposition: String, Codable, Sendable, Equatable {
    case inactive
    case waitingForQuiet = "waiting_for_quiet"
    case ready
    case refractory
    case resourceInhibited = "resource_inhibited"
    case privacyGateRequired = "privacy_gate_required"
    case providerBudgetGateRequired = "provider_budget_gate_required"
}

public struct OrganismSleepLaneOpportunity: Sendable, Equatable {
    public var lane: OrganismSleepLane
    public var threshold: Double
    public var quietInterval: TimeInterval
    public var disposition: OrganismSleepLaneDisposition
    public var nextEligibleAt: Date?
    public var controlAuthority: Bool

    public init(
        lane: OrganismSleepLane,
        threshold: Double,
        quietInterval: TimeInterval,
        disposition: OrganismSleepLaneDisposition,
        nextEligibleAt: Date? = nil,
        controlAuthority: Bool = false
    ) {
        self.lane = lane
        self.threshold = (threshold).clamped01()
        self.quietInterval = max(0, quietInterval)
        self.disposition = disposition
        self.nextEligibleAt = nextEligibleAt
        self.controlAuthority = controlAuthority
    }
}

/// Refractory bookkeeping only. This is not residual evidence and does not
/// raise pressure. It is persisted solely so restarts cannot replay the same
/// evidence generation or evade the Dream/provider budget.
public struct OrganismSleepControlState: Codable, Sendable, Equatable {
    public var lastOperationalConsolidationAt: Date?
    public var lastOperationalEvidenceGeneration: String?
    public var lastOperationalReceipt: OrganismOperationalConsolidationReceipt?
    public var lastProviderDreamAt: Date?
    public var lastGeneratedRecalibrationAt: Date?
    public var lastGeneratedEvidenceGeneration: String?

    public init(
        lastOperationalConsolidationAt: Date? = nil,
        lastOperationalEvidenceGeneration: String? = nil,
        lastOperationalReceipt: OrganismOperationalConsolidationReceipt? = nil,
        lastProviderDreamAt: Date? = nil,
        lastGeneratedRecalibrationAt: Date? = nil,
        lastGeneratedEvidenceGeneration: String? = nil
    ) {
        self.lastOperationalConsolidationAt = lastOperationalConsolidationAt
        self.lastOperationalEvidenceGeneration = lastOperationalEvidenceGeneration.map { String($0.prefix(80)) }
        self.lastOperationalReceipt = lastOperationalReceipt
        self.lastProviderDreamAt = lastProviderDreamAt
        self.lastGeneratedRecalibrationAt = lastGeneratedRecalibrationAt
        self.lastGeneratedEvidenceGeneration = lastGeneratedEvidenceGeneration.map { String($0.prefix(80)) }
    }

    private enum CodingKeys: String, CodingKey {
        case lastOperationalConsolidationAt, lastOperationalEvidenceGeneration
        case lastOperationalReceipt, lastProviderDreamAt
        case lastGeneratedRecalibrationAt, lastGeneratedEvidenceGeneration
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            lastOperationalConsolidationAt: try container.decodeIfPresent(
                Date.self, forKey: .lastOperationalConsolidationAt
            ),
            lastOperationalEvidenceGeneration: try container.decodeIfPresent(
                String.self, forKey: .lastOperationalEvidenceGeneration
            ),
            lastOperationalReceipt: try container.decodeIfPresent(
                OrganismOperationalConsolidationReceipt.self, forKey: .lastOperationalReceipt
            ),
            lastProviderDreamAt: try container.decodeIfPresent(Date.self, forKey: .lastProviderDreamAt),
            lastGeneratedRecalibrationAt: try container.decodeIfPresent(
                Date.self, forKey: .lastGeneratedRecalibrationAt
            ),
            lastGeneratedEvidenceGeneration: try container.decodeIfPresent(
                String.self, forKey: .lastGeneratedEvidenceGeneration
            )
        )
    }

    public static let empty = Self()
}

/// A local, payload-free read of why quiet repair/consolidation is warranted.
/// It is derived from existing prediction and plastic-field truth; it is not a
/// new affect or memory owner and never schedules a model call by itself.
