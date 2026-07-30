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
public struct OrganismResidualRepairOpportunity: Sendable, Equatable {
    public var generatedAt: Date
    /// Preregistered five-residual product used by operational/Dream lanes.
    public var pressure: Double
    /// Existing bounded field-repair signal. Kept distinct because the
    /// preregistered product can contribute at most 0.15 from field charge and
    /// therefore cannot, by itself, reach the proven 0.30 local repair gate.
    public var localRepairPressure: Double
    public var predictionResidual: Double
    public var transitionSurpriseResidual: Double
    public var contradictionResidual: Double
    public var fieldChargeResidual: Double
    public var fieldUncertaintyResidual: Double
    public var calibrationResidual: Double
    public var evidenceCount: Int
    public var evidenceGeneration: String
    public var evidence: [OrganismSleepEvidenceReference]
    public var chargedNodeIDs: [String]
    public var noisyEdgeIDs: [String]
    public var quietUntil: Date?
    public var nextRepairAt: Date?
    public var nextWakeAt: Date?
    public var ready: Bool
    public var resourceInhibited: Bool
    public var lanes: [OrganismSleepLaneOpportunity]

    public init(
        generatedAt: Date,
        pressure: Double = 0,
        localRepairPressure: Double? = nil,
        predictionResidual: Double = 0,
        transitionSurpriseResidual: Double = 0,
        contradictionResidual: Double = 0,
        fieldChargeResidual: Double = 0,
        fieldUncertaintyResidual: Double = 0,
        calibrationResidual: Double = 0,
        evidenceCount: Int = 0,
        evidenceGeneration: String = "none",
        evidence: [OrganismSleepEvidenceReference] = [],
        chargedNodeIDs: [String] = [],
        noisyEdgeIDs: [String] = [],
        quietUntil: Date? = nil,
        nextRepairAt: Date? = nil,
        nextWakeAt: Date? = nil,
        ready: Bool = false,
        resourceInhibited: Bool = false,
        lanes: [OrganismSleepLaneOpportunity] = []
    ) {
        self.generatedAt = generatedAt
        self.pressure = Self.clamp(pressure)
        self.localRepairPressure = Self.clamp(localRepairPressure ?? pressure)
        self.predictionResidual = Self.clamp(predictionResidual)
        self.transitionSurpriseResidual = Self.clamp(transitionSurpriseResidual)
        self.contradictionResidual = Self.clamp(contradictionResidual)
        self.fieldChargeResidual = Self.clamp(fieldChargeResidual)
        self.fieldUncertaintyResidual = Self.clamp(fieldUncertaintyResidual)
        self.calibrationResidual = Self.clamp(calibrationResidual)
        self.evidenceCount = max(0, evidenceCount)
        self.evidenceGeneration = String(evidenceGeneration.prefix(80))
        self.evidence = Array(evidence.prefix(32))
        self.chargedNodeIDs = Array(chargedNodeIDs.prefix(4))
        self.noisyEdgeIDs = Array(noisyEdgeIDs.prefix(4))
        self.quietUntil = quietUntil
        self.nextRepairAt = nextRepairAt
        self.nextWakeAt = nextWakeAt
        self.ready = ready
        self.resourceInhibited = resourceInhibited
        self.lanes = Array(lanes.prefix(OrganismSleepLane.allCases.count))
    }

    public static func empty(at date: Date) -> Self { Self(generatedAt: date) }

    private static func clamp(_ value: Double) -> Double {
        (value.isFinite ? value : 0).clamped01()
    }
}

public enum OrganismResidualRepair {
    public static let minimumPressure = 0.30
    public static let quietInterval: TimeInterval = 2 * 60
    public static let operationalPressure = 0.45
    public static let operationalQuietInterval: TimeInterval = 10 * 60
    public static let operationalRefractoryInterval: TimeInterval = 6 * 60 * 60
    /// The preregistered product formula has a hard maximum of 0.6787 when all
    /// five normalized residuals equal one. A 0.70 gate is therefore
    /// unreachable theater; 0.60 preserves a deliberately high threshold.
    public static let dreamPressure = 0.60
    public static let dreamQuietInterval: TimeInterval = 30 * 60
    public static let dreamRefractoryInterval: TimeInterval = 24 * 60 * 60
    public static let predictionHalfLife: TimeInterval = 6 * 60 * 60
    /// F4-M1 (2026-07-23): bounded re-check cadence used ONLY when resource
    /// inhibition (thermal / low-power) suppressed an otherwise-eligible wake.
    /// Without it, `localNext` and the aggregate `nextWake` both go nil under
    /// inhibition, the deadline runner arms no timer, and re-arm rides only
    /// somatic/system-wake events — so a Mac that cools while idle leaves
    /// residual repair disarmed indefinitely. The fallback wake only re-derives
    /// the opportunity (cheap; no provider), letting the loop self-recover once
    /// pressure clears.
    public static let resourceRecheckInterval: TimeInterval = 5 * 60

    public static func combinedPressure(
        _ components: OrganismSleepPressureComponents,
        weights: OrganismSleepPressureWeights = .preregistered
    ) -> Double {
        let product = (1 - weights.prediction * components.predictionResidual)
            * (1 - weights.transitionSurprise * components.transitionSurprise)
            * (1 - weights.contradiction * components.contradictionResidual)
            * (1 - weights.fieldCharge * components.fieldChargeResidual)
            * (1 - weights.calibration * components.calibrationResidual)
        return (1 - product).clamped01()
    }

    public static func opportunity(
        ledger: OrganismPredictionLedger,
        field: OrganismField,
        repairState: OrganismDreamRepairState,
        lastSignalAt: Date?,
        at now: Date,
        resourcePressure: OrganismResourcePressure = .nominal,
        supplemental: OrganismSupplementalSleepResiduals = .empty,
        weights: OrganismSleepPressureWeights = .preregistered
    ) -> OrganismResidualRepairOpportunity {
        let lastRepairAt = repairState.lastReceipt?.generatedAt
        let acknowledgedFieldGeneration = repairState.lastReceipt?.sourceFieldGeneration ?? 0
        let hasUnrepairedFieldMutation = field.mutationGeneration > acknowledgedFieldGeneration
        let isFinishingBoundedRepair = repairState.lastReceipt != nil && hasUnrepairedFieldMutation
        let unresolvedPredictions = ledger.predictions.values.filter {
            $0.status == .violated || $0.status == .expired
        }.sorted { $0.id < $1.id }
        let predictionResidual = min(1, unresolvedPredictions.reduce(0.0) { total, prediction in
            let base = prediction.status == .violated
                ? max(0.50, prediction.confidence)
                : max(0.35, prediction.uncertainty)
            let decay = OrganismAnalyticDecay(
                valueAtAnchor: base,
                halfLife: predictionHalfLife,
                anchoredAt: prediction.lastUpdatedAt
            )
            return total + decay.value(at: now)
        })
        let derivedSurprise = min(1, unresolvedPredictions.reduce(0.0) { total, prediction in
            let base = prediction.status == .violated
                ? max(0.45, prediction.confidence)
                : max(0.25, prediction.uncertainty)
            let decay = OrganismAnalyticDecay(
                valueAtAnchor: base,
                halfLife: predictionHalfLife,
                anchoredAt: prediction.lastUpdatedAt
            )
            return total + decay.value(at: now)
        })

        // Inspect current tissue directly instead of comparing untrusted source
        // timestamps with a local repair receipt. This makes delayed events
        // visible while the exact IDs causally bind the later operation.
        let charged = hasUnrepairedFieldMutation ? Array(field.nodes.values.filter { $0.charge >= 0.12 }
            .sorted {
                if $0.charge != $1.charge { return $0.charge > $1.charge }
                return $0.id < $1.id
            }.prefix(4)) : []
        let noisy = hasUnrepairedFieldMutation ? Array(field.edges.values.filter {
            $0.uncertainty >= 0.18 || ($0.eligibility >= 0.45 && $0.weight >= 0.12)
        }.sorted {
            if $0.uncertainty != $1.uncertainty { return $0.uncertainty > $1.uncertainty }
            return $0.id < $1.id
        }.prefix(4)) : []
        let allNodes = Array(field.nodes.values)
        let averageCharge = allNodes.isEmpty
            ? 0
            : allNodes.reduce(0.0) { $0 + $1.charge } / Double(allNodes.count)
        let maximumCharge = allNodes.map(\.charge).max() ?? 0
        let highActivationRatio = allNodes.isEmpty
            ? 0
            : Double(allNodes.filter { $0.activation >= 0.80 }.count) / Double(allNodes.count)
        let allEdges = Array(field.edges.values)
        let averageUncertainty = allEdges.isEmpty
            ? 0
            : allEdges.reduce(0.0) { $0 + $1.uncertainty } / Double(allEdges.count)
        let fieldCharge = min(1,
            0.45 * maximumCharge
                + 0.25 * averageCharge
                + 0.20 * averageUncertainty
                + 0.10 * highActivationRatio
        )
        let fieldUncertainty = min(1, noisy.reduce(0.0) {
            $0 + (max($1.uncertainty, $1.eligibility) * 0.14)
        })

        let correctionNode = field.nodes["signal:correctionReceived"]
        let memoryCorrectionNode = field.nodes["signal:memoryCorrected"]
        let derivedContradiction = max(
            correctionNode.map { max($0.charge, $0.activation * 0.5) } ?? 0,
            memoryCorrectionNode.map { max($0.charge, $0.activation * 0.5) } ?? 0
        )
        let resolvedPredictionCount = ledger.predictions.values.filter {
            $0.status == .satisfied || $0.status == .violated || $0.status == .expired
        }.count
        let bodyConfidenceMean = (
            ledger.bodyConfidence.providerPath
                + ledger.bodyConfidence.toolPath
                + ledger.bodyConfidence.phonePath
                + ledger.bodyConfidence.approvalPath
                + ledger.bodyConfidence.workflowPath
        ) / 5
        let derivedCalibration = resolvedPredictionCount == 0
            ? 0
            : min(1, 0.55 * ledger.strategyCaution + 0.45 * (1 - bodyConfidenceMean))
        let components = OrganismSleepPressureComponents(
            predictionResidual: predictionResidual,
            transitionSurprise: max(derivedSurprise, supplemental.transitionSurprise),
            contradictionResidual: max(derivedContradiction, supplemental.contradiction),
            fieldChargeResidual: max(fieldCharge, fieldUncertainty),
            calibrationResidual: max(derivedCalibration, supplemental.calibration)
        )
        let measuredPressure = combinedPressure(components, weights: weights)
        let measuredLocalRepairPressure = min(
            1,
            components.predictionResidual + components.fieldChargeResidual + fieldUncertainty
        )
        // Once a bounded repair pass has started for a generation, finish the
        // remaining exact targets even if the aggregate residue drops below
        // the initial arming threshold. Otherwise the fifth-and-later target
        // could remain permanently charged behind a small residual sum.
        let localRepairPressure = (isFinishingBoundedRepair && !charged.isEmpty)
            || (isFinishingBoundedRepair && !noisy.isEmpty)
            ? max(minimumPressure, measuredLocalRepairPressure)
            : measuredLocalRepairPressure
        let pressure = measuredPressure
        var provenance = unresolvedPredictions.map { prediction in
            OrganismSleepEvidenceReference(
                id: opaqueEvidenceID("prediction|\(prediction.id)|\(prediction.status.rawValue)"),
                kind: .prediction,
                evidenceClass: .exactRuntime,
                observedAt: prediction.lastUpdatedAt,
                expiresAt: prediction.dueAt
            )
        }
        if let correctionNode {
            provenance.append(OrganismSleepEvidenceReference(
                id: opaqueEvidenceID("contradiction|correction|\(field.mutationGeneration)"),
                kind: .contradiction,
                evidenceClass: .exactRuntime,
                observedAt: correctionNode.lastActivatedAt
            ))
        }
        if let memoryCorrectionNode {
            provenance.append(OrganismSleepEvidenceReference(
                id: opaqueEvidenceID("contradiction|memory|\(field.mutationGeneration)"),
                kind: .contradiction,
                evidenceClass: .exactRuntime,
                observedAt: memoryCorrectionNode.lastActivatedAt
            ))
        }
        if hasUnrepairedFieldMutation, !charged.isEmpty || !noisy.isEmpty {
            provenance.append(OrganismSleepEvidenceReference(
                id: opaqueEvidenceID("field|\(field.mutationGeneration)"),
                kind: .fieldCharge,
                evidenceClass: .exactRuntime,
                observedAt: field.lastUpdatedAt ?? now
            ))
        }
        if derivedCalibration > 0, let updated = ledger.lastUpdatedAt {
            provenance.append(OrganismSleepEvidenceReference(
                id: opaqueEvidenceID("calibration|\(Int(updated.timeIntervalSince1970))|\(ledger.violatedCount)|\(ledger.expiredCount)"),
                kind: .calibration,
                evidenceClass: .exactRuntime,
                observedAt: updated
            ))
        }
        provenance.append(contentsOf: supplemental.evidence)
        provenance = Array(Dictionary(grouping: provenance, by: \.id).compactMap { $0.value.first }
            .sorted { $0.id < $1.id }.prefix(32))
        let evidenceGeneration = generationFingerprint(
            evidence: provenance,
            fieldGeneration: field.mutationGeneration
        )
        let evidenceCount = provenance.count
        let repairableFieldEvidenceCount = charged.count + noisy.count

        // Scheduling follows the trusted ingestion anchor. Source event and
        // persisted field timestamps remain provenance, but a future-dated or
        // delayed source clock must never delay/accelerate quiet physiology.
        let trustedIngestionAt = lastSignalAt.flatMap { $0 <= now ? $0 : nil }
        let trustedRepairAt = lastRepairAt.flatMap { $0 <= now ? $0 : nil }
        let fallbackEvidenceAt = ([field.lastUpdatedAt]
            + unresolvedPredictions.map { Optional($0.lastUpdatedAt) })
            .compactMap { $0 }
            .filter { $0 <= now }
            .max()
        let latestEvidenceAt = [trustedIngestionAt, trustedRepairAt].compactMap { $0 }.max()
            ?? fallbackEvidenceAt
        let localQuietUntil = latestEvidenceAt?.addingTimeInterval(quietInterval) ?? now
        let operationalQuietUntil = latestEvidenceAt?.addingTimeInterval(operationalQuietInterval) ?? now
        let dreamQuietUntil = latestEvidenceAt?.addingTimeInterval(dreamQuietInterval) ?? now
        let resourceInhibited = resourcePressure != .nominal
        let localEligible = localRepairPressure >= minimumPressure
            && evidenceCount > 0
            && repairableFieldEvidenceCount > 0
        let localReady = localEligible && !resourceInhibited && now >= localQuietUntil
        let localNext = localEligible && !resourceInhibited ? max(now, localQuietUntil) : nil

        let sameOperationalGeneration = repairState.sleepControl.lastOperationalEvidenceGeneration
            == evidenceGeneration
        let operationalRefractoryUntil = repairState.sleepControl.lastOperationalConsolidationAt?
            .addingTimeInterval(operationalRefractoryInterval)
        let operationalCandidateAt = [operationalQuietUntil, operationalRefractoryUntil]
            .compactMap { $0 }.max() ?? operationalQuietUntil
        let operationalDisposition: OrganismSleepLaneDisposition
        let operationalNext: Date?
        if pressure < operationalPressure || evidenceCount == 0 {
            operationalDisposition = .inactive
            operationalNext = nil
        } else if resourceInhibited {
            operationalDisposition = .resourceInhibited
            operationalNext = nil
        } else if sameOperationalGeneration {
            operationalDisposition = .refractory
            operationalNext = nil
        } else if now < operationalCandidateAt {
            operationalDisposition = operationalRefractoryUntil.map { now < $0 } == true
                ? .refractory : .waitingForQuiet
            operationalNext = operationalCandidateAt
        } else {
            operationalDisposition = .ready
            operationalNext = now
        }

        let dreamRefractoryUntil = repairState.sleepControl.lastProviderDreamAt?
            .addingTimeInterval(dreamRefractoryInterval)
        let dreamCandidateAt = [dreamQuietUntil, dreamRefractoryUntil].compactMap { $0 }.max()
            ?? dreamQuietUntil
        let dreamDisposition: OrganismSleepLaneDisposition
        let dreamNext: Date?
        if pressure < dreamPressure || evidenceCount == 0 {
            dreamDisposition = .inactive
            dreamNext = nil
        } else if resourceInhibited {
            dreamDisposition = .resourceInhibited
            dreamNext = nil
        } else if now < dreamCandidateAt {
            dreamDisposition = dreamRefractoryUntil.map { now < $0 } == true
                ? .refractory : .waitingForQuiet
            dreamNext = dreamCandidateAt
        } else {
            // This is eligibility only. The existing identity-Dream owner must
            // still enforce its provider lease, budget, trust, and approval path.
            dreamDisposition = .providerBudgetGateRequired
            dreamNext = now
        }

        let evidenceClasses = Set(provenance.map(\.evidenceClass))
        let controlledOnly = !provenance.isEmpty
            && evidenceClasses.isSubset(of: [.generated, .frozenControlled])
        let recalibrationDisposition: OrganismSleepLaneDisposition
        if pressure < operationalPressure || supplemental.evidence.isEmpty {
            recalibrationDisposition = .inactive
        } else if resourceInhibited {
            recalibrationDisposition = .resourceInhibited
        } else if !controlledOnly {
            recalibrationDisposition = .privacyGateRequired
        } else if repairState.sleepControl.lastGeneratedEvidenceGeneration == evidenceGeneration {
            recalibrationDisposition = .refractory
        } else if now < operationalQuietUntil {
            recalibrationDisposition = .waitingForQuiet
        } else {
            recalibrationDisposition = .ready
        }

        let lanes = [
            OrganismSleepLaneOpportunity(
                lane: .quietLocalRepair,
                threshold: minimumPressure,
                quietInterval: quietInterval,
                disposition: localEligible
                    ? (resourceInhibited ? .resourceInhibited : (localReady ? .ready : .waitingForQuiet))
                    : .inactive,
                nextEligibleAt: localNext
            ),
            OrganismSleepLaneOpportunity(
                lane: .operationalConsolidation,
                threshold: operationalPressure,
                quietInterval: operationalQuietInterval,
                disposition: operationalDisposition,
                nextEligibleAt: operationalNext
            ),
            OrganismSleepLaneOpportunity(
                lane: .identityDreamProposal,
                threshold: dreamPressure,
                quietInterval: dreamQuietInterval,
                disposition: dreamDisposition,
                nextEligibleAt: dreamNext
            ),
            OrganismSleepLaneOpportunity(
                lane: .generatedFrozenRecalibration,
                threshold: operationalPressure,
                quietInterval: operationalQuietInterval,
                disposition: recalibrationDisposition,
                nextEligibleAt: recalibrationDisposition == .waitingForQuiet ? operationalQuietUntil : nil
            ),
        ]

        let pendingPredictionDue = ledger.predictions.values
            .filter { $0.status == .pending && $0.dueAt > now }
            .map(\.dueAt)
            .min()
        // Only deadlines with a production consumer may wake the resident
        // runtime. Operational consolidation is diagnostic bookkeeping and
        // the identity-Dream lane is eligibility for its existing owner; this
        // read model must not manufacture wakeups for either one.
        let candidateDeadlines = [localNext, pendingPredictionDue, supplemental.nextModelReviewAt]
            .compactMap { $0 }
            .filter { $0 > now }
        // Below threshold, monotonic residual decay cannot create a crossing;
        // only exact pending prediction/model expiries are worth scheduling.
        //
        // F4-M1 (2026-07-23): under resource inhibition BOTH localNext (above)
        // and this aggregate wake were nil'd, so the deadline runner armed no
        // timer and residual repair re-armed only on somatic/system-wake events.
        // A Mac cooling while idle would leave repair disarmed indefinitely.
        // When — and ONLY when — inhibition is the sole reason an otherwise
        // eligible opportunity produced no wake, surface a bounded fallback
        // re-check so the loop re-samples pressure and self-recovers. Never
        // arm LATER than a real exact deadline the uninhibited pass would have.
        // Behavior when NOT inhibited is unchanged.
        let nextWake: Date?
        if resourceInhibited {
            let uninhibitedLocalNext = localEligible ? max(now, localQuietUntil) : nil
            let uninhibitedCandidateDeadlines =
                [uninhibitedLocalNext, pendingPredictionDue, supplemental.nextModelReviewAt]
                    .compactMap { $0 }
                    .filter { $0 > now }
            let wouldWakeAbsentInhibition = localEligible
                || !uninhibitedCandidateDeadlines.isEmpty
            if wouldWakeAbsentInhibition {
                let fallback = now.addingTimeInterval(resourceRecheckInterval)
                nextWake = ([fallback] + uninhibitedCandidateDeadlines).min()
            } else {
                nextWake = nil
            }
        } else {
            nextWake = candidateDeadlines.min()
        }
        return OrganismResidualRepairOpportunity(
            generatedAt: now,
            pressure: pressure,
            localRepairPressure: localRepairPressure,
            predictionResidual: components.predictionResidual,
            transitionSurpriseResidual: components.transitionSurprise,
            contradictionResidual: components.contradictionResidual,
            fieldChargeResidual: components.fieldChargeResidual,
            fieldUncertaintyResidual: fieldUncertainty,
            calibrationResidual: components.calibrationResidual,
            evidenceCount: evidenceCount,
            evidenceGeneration: evidenceGeneration,
            evidence: provenance,
            chargedNodeIDs: charged.map(\.id),
            noisyEdgeIDs: noisy.map(\.id),
            quietUntil: localEligible ? localQuietUntil : nil,
            nextRepairAt: localNext,
            nextWakeAt: nextWake,
            ready: localReady,
            resourceInhibited: resourceInhibited,
            lanes: lanes
        )
    }

    private static func opaqueEvidenceID(_ source: String) -> String {
        SHA256.hash(data: Data(source.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private static func generationFingerprint(
        evidence: [OrganismSleepEvidenceReference],
        fieldGeneration: UInt64
    ) -> String {
        let source = (["field:\(fieldGeneration)"] + evidence.map {
            "\($0.id)|\($0.kind.rawValue)|\($0.evidenceClass.rawValue)|\(Int($0.observedAt.timeIntervalSince1970))"
        }).joined(separator: "\n")
        return opaqueEvidenceID(source)
    }
}

public struct OrganismOperationalConsolidationReceipt: Codable, Sendable, Equatable {
    public var schema: String
    public var generatedAt: Date
    public var evidenceGeneration: String
    public var pressure: Double
    public var evidenceCount: Int
    public var predictionResidual: Double
    public var transitionSurpriseResidual: Double
    public var contradictionResidual: Double
    public var fieldChargeResidual: Double
    public var calibrationResidual: Double
    public var personalModelUpdated: Bool
    public var providerCalled: Bool
    public var promptAuthority: Bool
    public var actionAuthority: Bool

    public init(reading: OrganismResidualRepairOpportunity, generatedAt: Date) {
        self.schema = "organism-operational-consolidation.v1"
        self.generatedAt = generatedAt
        self.evidenceGeneration = reading.evidenceGeneration
        self.pressure = reading.pressure
        self.evidenceCount = reading.evidenceCount
        self.predictionResidual = reading.predictionResidual
        self.transitionSurpriseResidual = reading.transitionSurpriseResidual
        self.contradictionResidual = reading.contradictionResidual
        self.fieldChargeResidual = reading.fieldChargeResidual
        self.calibrationResidual = reading.calibrationResidual
        self.personalModelUpdated = false
        self.providerCalled = false
        self.promptAuthority = false
        self.actionAuthority = false
    }
}

public struct OrganismOperationalConsolidationResult: Sendable, Equatable {
    public var receipt: OrganismOperationalConsolidationReceipt
    public var controlState: OrganismSleepControlState
}

/// Deterministic replay acknowledgement over the exact read. It changes only
/// refractory control state: no personal model, context, memory, identity,
/// prompt, action, or provider state is updated.
public enum OrganismOperationalConsolidator {
    public static func consolidate(
        _ reading: OrganismResidualRepairOpportunity,
        controlState: OrganismSleepControlState,
        at now: Date
    ) -> OrganismOperationalConsolidationResult? {
        guard reading.lanes.first(where: { $0.lane == .operationalConsolidation })?.disposition == .ready,
              !reading.resourceInhibited,
              reading.evidenceCount > 0 else { return nil }
        var next = controlState
        next.lastOperationalConsolidationAt = now
        next.lastOperationalEvidenceGeneration = reading.evidenceGeneration
        let receipt = OrganismOperationalConsolidationReceipt(reading: reading, generatedAt: now)
        next.lastOperationalReceipt = receipt
        return OrganismOperationalConsolidationResult(
            receipt: receipt,
            controlState: next
        )
    }

    /// The identity-Dream owner calls this only after its own provider/budget/
    /// trust path accepted work. Merely becoming pressure-eligible never calls
    /// a provider and never advances the 24-hour refractory control.
    public static func recordingAcceptedIdentityDream(
        in state: OrganismSleepControlState,
        at date: Date
    ) -> OrganismSleepControlState {
        var next = state
        next.lastProviderDreamAt = date
        return next
    }
}

public struct OrganismSleepCalibrationSample: Sendable, Equatable {
    public var evidenceID: String
    public var evidenceClass: OrganismSleepEvidenceClass
    public var predictedProbability: Double
    public var observedSuccess: Bool

    public init(
        evidenceID: String,
        evidenceClass: OrganismSleepEvidenceClass,
        predictedProbability: Double,
        observedSuccess: Bool
    ) {
        self.evidenceID = SHA256.hash(data: Data(evidenceID.utf8))
            .map { String(format: "%02x", $0) }.joined()
        self.evidenceClass = evidenceClass
        self.predictedProbability = (predictedProbability.isFinite ? predictedProbability : 0).clamped01()
        self.observedSuccess = observedSuccess
    }
}

/// No public initializer exists. Only package tests/frozen laboratories may
/// construct this authority; personal runtime traces require Wave 11's
/// ApprovalInbox-bound, versioned privacy artifact and are intentionally not
/// accepted here.
public struct OrganismGeneratedSleepRecalibrationAuthorization: Sendable, Equatable {
    private init() {}
    static let generatedAndFrozen = Self()
}

public enum OrganismGeneratedSleepRecalibrationError: String, Error, Sendable, Equatable {
    case personalEvidenceDenied = "personal_evidence_denied"
    case insufficientEvidence = "insufficient_evidence"
    case pressureLaneNotReady = "pressure_lane_not_ready"
}

public struct OrganismGeneratedSleepRecalibrationArtifact: Codable, Sendable, Equatable {
    public var schema: String
    public var generatedAt: Date
    public var evidenceGeneration: String
    public var sampleCount: Int
    public var scale: Double
    public var brierBefore: Double
    public var brierAfter: Double
    public var evidenceIDs: [String]
    public var generatedOrFrozenOnly: Bool
    public var personalModelUpdated: Bool
    public var productionInfluence: Bool
    public var rollbackRequired: Bool
}

public struct OrganismGeneratedSleepRecalibrationResult: Sendable, Equatable {
    public var artifact: OrganismGeneratedSleepRecalibrationArtifact
    public var controlState: OrganismSleepControlState
}

/// A small deterministic recalibration proof for generated/frozen evidence.
/// The artifact is immutable and advisory; it is never installed into the live
/// predictive body and has no provider, prompt, or action side effects.
public enum OrganismGeneratedSleepRecalibrator {
    public static func recalibrate(
        reading: OrganismResidualRepairOpportunity,
        samples: [OrganismSleepCalibrationSample],
        authorization: OrganismGeneratedSleepRecalibrationAuthorization,
        controlState: OrganismSleepControlState = .empty,
        at now: Date
    ) throws -> OrganismGeneratedSleepRecalibrationResult {
        _ = authorization
        guard reading.lanes.first(where: { $0.lane == .generatedFrozenRecalibration })?.disposition == .ready else {
            throw OrganismGeneratedSleepRecalibrationError.pressureLaneNotReady
        }
        let bounded = Array(samples.prefix(10_000))
        guard bounded.count >= 8 else {
            throw OrganismGeneratedSleepRecalibrationError.insufficientEvidence
        }
        guard bounded.allSatisfy({ $0.evidenceClass == .generated || $0.evidenceClass == .frozenControlled }) else {
            throw OrganismGeneratedSleepRecalibrationError.personalEvidenceDenied
        }
        let meanPrediction = bounded.reduce(0.0) { $0 + $1.predictedProbability } / Double(bounded.count)
        let posteriorObserved = Double(bounded.filter(\.observedSuccess).count + 1) / Double(bounded.count + 2)
        let scale = meanPrediction > 0.000_001
            ? min(1.5, max(0.5, posteriorObserved / meanPrediction))
            : 1
        func brier(scale: Double) -> Double {
            bounded.reduce(0.0) { total, sample in
                let p = (sample.predictedProbability * scale).clamped01()
                let y = sample.observedSuccess ? 1.0 : 0.0
                return total + pow(p - y, 2)
            } / Double(bounded.count)
        }
        let before = brier(scale: 1)
        let after = brier(scale: scale)
        let artifact = OrganismGeneratedSleepRecalibrationArtifact(
            schema: "organism-generated-sleep-recalibration.v1",
            generatedAt: now,
            evidenceGeneration: reading.evidenceGeneration,
            sampleCount: bounded.count,
            scale: scale,
            brierBefore: before,
            brierAfter: after,
            evidenceIDs: Array(Set(bounded.map(\.evidenceID)).sorted().prefix(10_000)),
            generatedOrFrozenOnly: true,
            personalModelUpdated: false,
            productionInfluence: false,
            rollbackRequired: false
        )
        var next = controlState
        next.lastGeneratedRecalibrationAt = now
        next.lastGeneratedEvidenceGeneration = reading.evidenceGeneration
        return OrganismGeneratedSleepRecalibrationResult(
            artifact: artifact,
            controlState: next
        )
    }
}

public struct OrganismCapabilityBelief: Sendable, Equatable, Identifiable {
    public var id: String { kind.rawValue }
    public var kind: OrganismPredictionKind
    public var successLikelihood: Double
    public var uncertainty: Double
    public var evidenceCount: Int
    public var resolvedEvidenceCount: Int
    public var expiredEvidenceCount: Int
    public var freshness: Double
    public var lastEvidenceAt: Date?
}

/// A calibrated self-read over the predictive body. Beta smoothing prevents a
/// single success/failure from becoming certainty; freshness is analytic and
/// the read has no prose, prompt, action, or identity authority.
public enum OrganismCapabilitySelfModel {
    public static let freshnessHalfLife: TimeInterval = 7 * 24 * 60 * 60

    public static func beliefs(
        ledger: OrganismPredictionLedger,
        at now: Date
    ) -> [OrganismCapabilityBelief] {
        OrganismPredictionKind.allCases.map { kind in
            let evidence = ledger.predictions.values.filter { $0.kind == kind }
            let resolved = evidence.filter { $0.status == .satisfied || $0.status == .violated }
            let expired = evidence.filter { $0.status == .expired }
            let successes = resolved.filter { $0.status == .satisfied }.count
            let failures = resolved.filter { $0.status == .violated }.count
            let posterior = Double(successes + 1) / Double(successes + failures + 2)
            let resolutionUncertainty = 1 / sqrt(Double(resolved.count + 1))
            let missingEvidencePenalty = evidence.isEmpty
                ? 0
                : Double(expired.count) / Double(evidence.count)
            let uncertainty = max(resolutionUncertainty, missingEvidencePenalty)
            let last = evidence.map(\.lastUpdatedAt).max()
            let freshness = last.map {
                OrganismAnalyticDecay(
                    valueAtAnchor: 1,
                    halfLife: freshnessHalfLife,
                    anchoredAt: $0
                ).value(at: now)
            } ?? 0
            return OrganismCapabilityBelief(
                kind: kind,
                successLikelihood: (posterior).clamped01(),
                uncertainty: (uncertainty).clamped01(),
                evidenceCount: evidence.count,
                resolvedEvidenceCount: resolved.count,
                expiredEvidenceCount: expired.count,
                freshness: (freshness).clamped01(),
                lastEvidenceAt: last
            )
        }
    }
}
