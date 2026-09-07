import Foundation
import CryptoKit

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
        let dreamEligible = pressure >= dreamPressure && evidenceCount > 0
        if !dreamEligible {
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
        // runtime. Operational consolidation is still diagnostic bookkeeping and
        // manufactures no wakeup.
        //
        // The identity-Dream lane ACQUIRED a production consumer on 2026-09-01
        // (NORTHSTAR clause 4, sweep item 39): the cognition runtime now fires
        // the same DreamCycleRunner path the 03:30 job uses when this lane says
        // a dream is due, so 03:30 is the integrity fallback rather than the
        // mechanism. Its eligibility boundary — the end of the 30-minute quiet
        // window, or of the 24-hour refractory — is therefore a real deadline
        // something waits on, not a manufactured one. When the lane is ALREADY
        // eligible `dreamNext` is `now`, and the `> now` filter below keeps that
        // from arming a zero-delay timer: the consumer acts on the reading it
        // already holds instead of spinning against itself.
        let candidateDeadlines = [localNext, dreamNext, pendingPredictionDue, supplemental.nextModelReviewAt]
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
            // The dream lane's consumer (see candidateDeadlines above) needs the
            // same self-recovery: a Mac that cools while a dream is pending must
            // re-sample instead of staying disarmed until an unrelated event.
            let uninhibitedDreamNext = dreamEligible ? max(now, dreamCandidateAt) : nil
            let uninhibitedCandidateDeadlines =
                [uninhibitedLocalNext, uninhibitedDreamNext, pendingPredictionDue, supplemental.nextModelReviewAt]
                    .compactMap { $0 }
                    .filter { $0 > now }
            let wouldWakeAbsentInhibition = localEligible
                || dreamEligible
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
