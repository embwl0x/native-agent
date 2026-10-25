import Foundation
import CryptoKit
// Blueprint: | `OrganismResidualRepair.swift` | `OrganismResidualRepair` enum; `combinedPressure`, `opportunity` |

public struct OrganismResidualRepairOpportunity: Sendable, Equatable {
    public var generatedAt: Date
    /// Preregistered five-residual product used by Dream/recalibration lanes.
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
    public static let predictionHalfLife: TimeInterval = 6 * 60 * 60

    public static func combinedPressure(
        _ components: OrganismSleepPressureComponents
    ) -> Double {
        let product = (1 - 0.30 * components.predictionResidual)
            * (1 - 0.25 * components.transitionSurprise)
            * (1 - 0.20 * components.contradictionResidual)
            * (1 - 0.15 * components.fieldChargeResidual)
            * (1 - 0.10 * components.calibrationResidual)
        return (1 - product).clamped01()
    }

    public static func opportunity(
        ledger: OrganismPredictionLedger,
        field: OrganismField,
        repairState: OrganismDreamRepairState,
        lastSignalAt: Date?,
        at now: Date
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
            transitionSurprise: derivedSurprise,
            contradictionResidual: derivedContradiction,
            fieldChargeResidual: max(fieldCharge, fieldUncertainty),
            calibrationResidual: derivedCalibration
        )
        let measuredPressure = combinedPressure(components)
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
        let localEligible = localRepairPressure >= minimumPressure
            && evidenceCount > 0
            && repairableFieldEvidenceCount > 0
        let localReady = localEligible && now >= localQuietUntil
        let localNext = localEligible ? max(now, localQuietUntil) : nil

        let lanes = [
            OrganismSleepLaneOpportunity(
                lane: .quietLocalRepair,
                threshold: minimumPressure,
                quietInterval: quietInterval,
                disposition: localEligible
                    ? (localReady ? .ready : .waitingForQuiet)
                    : .inactive,
                nextEligibleAt: localNext
            ),
        ]

        let pendingPredictionDue = ledger.predictions.values
            .filter { $0.status == .pending && $0.dueAt > now }
            .map(\.dueAt)
            .min()
        let candidateDeadlines = [localNext, pendingPredictionDue]
            .compactMap { $0 }
            .filter { $0 > now }
        // Below threshold, monotonic residual decay cannot create a crossing;
        // only exact pending prediction expiries are worth scheduling.
        //
        // She is always on (User 10-24): heat never disarms her repair.
        let nextWake = candidateDeadlines.min()
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
