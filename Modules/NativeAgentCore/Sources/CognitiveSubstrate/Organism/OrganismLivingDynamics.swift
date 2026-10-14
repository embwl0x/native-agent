import CryptoKit
import Foundation

/// Closed-form time law used by organism tissue that should change with wall
/// time without waking on a polling cadence. The stored value remains an
/// anchor; reads derive the present value.
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

public enum OrganismSleepLane: String, Codable, Sendable, Equatable, CaseIterable {
    case quietLocalRepair = "quiet_local_repair"
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
    public var lastProviderDreamAt: Date?
    public var lastGeneratedRecalibrationAt: Date?
    public var lastGeneratedEvidenceGeneration: String?

    public init(
        lastProviderDreamAt: Date? = nil,
        lastGeneratedRecalibrationAt: Date? = nil,
        lastGeneratedEvidenceGeneration: String? = nil
    ) {
        self.lastProviderDreamAt = lastProviderDreamAt
        self.lastGeneratedRecalibrationAt = lastGeneratedRecalibrationAt
        self.lastGeneratedEvidenceGeneration = lastGeneratedEvidenceGeneration.map { String($0.prefix(80)) }
    }

    private enum CodingKeys: String, CodingKey {
        case lastProviderDreamAt
        case lastGeneratedRecalibrationAt, lastGeneratedEvidenceGeneration
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
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
