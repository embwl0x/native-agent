import Foundation
// Blueprint: | `OrganismResidualRepair.swift` | `OrganismResidualRepair` enum; `combinedPressure`, `opportunity` |

public struct OrganismResidualRepairOpportunity: Sendable, Equatable {
    public var generatedAt: Date
    /// Combine residuals for bounded local repair without a model judgment.
    public var pressure: Double
    public var components: OrganismSleepPressureComponents
    public var fieldUncertaintyResidual: Double
    public var evidenceCount: Int
    public var chargedNodeIDs: [String]
    public var noisyEdgeIDs: [String]
    public var quietUntil: Date?
    public var nextRepairAt: Date?
    public var nextWakeAt: Date?
    public var ready: Bool

    public init(
        generatedAt: Date,
        pressure: Double = 0,
        components: OrganismSleepPressureComponents = .init(),
        fieldUncertaintyResidual: Double = 0,
        evidenceCount: Int = 0,
        chargedNodeIDs: [String] = [],
        noisyEdgeIDs: [String] = [],
        quietUntil: Date? = nil,
        nextRepairAt: Date? = nil,
        nextWakeAt: Date? = nil,
        ready: Bool = false
    ) {
        self.generatedAt = generatedAt
        self.pressure = pressure.finiteClamped01()
        self.components = components
        self.fieldUncertaintyResidual = fieldUncertaintyResidual.finiteClamped01()
        self.evidenceCount = max(0, evidenceCount)
        self.chargedNodeIDs = Array(chargedNodeIDs.prefix(4))
        self.noisyEdgeIDs = Array(noisyEdgeIDs.prefix(4))
        self.quietUntil = quietUntil
        self.nextRepairAt = nextRepairAt
        self.nextWakeAt = nextWakeAt
        self.ready = ready
    }

    public static func empty(at date: Date) -> Self { Self(generatedAt: date) }
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
        at now: Date,
        satisfyWait: Bool = false
    ) -> OrganismResidualRepairOpportunity {
        let lastRepairAt = repairState.lastReceipt?.generatedAt
        let acknowledgedFieldGeneration = repairState.lastReceipt?.sourceFieldGeneration ?? 0
        let hasUnrepairedFieldMutation = field.mutationGeneration > acknowledgedFieldGeneration
        let unresolvedPredictions = ledger.predictions.values.filter {
            $0.status == .violated || $0.status == .expired
        }.sorted { $0.id < $1.id }
        let residuals = unresolvedPredictions.reduce(into: (pressure: 0.0, surprise: 0.0)) { totals, prediction in
            let violated = prediction.status == .violated
            func decayed(_ base: Double) -> Double {
                OrganismAnalyticDecay(valueAtAnchor: base, halfLife: predictionHalfLife,
                    anchoredAt: prediction.lastUpdatedAt).value(at: now)
            }
            totals.pressure += decayed(violated ? max(0.50, prediction.confidence) : max(0.35, prediction.uncertainty))
            totals.surprise += decayed(violated ? max(0.45, prediction.confidence) : max(0.25, prediction.uncertainty))
        }

        // Inspect current tissue and bind exact target ids so delayed source timestamps cannot hide repairable evidence.
        let charged = hasUnrepairedFieldMutation ? Array(field.nodes.values.filter(OrganismDreamRepair.hasRepairableCharge)
            .sorted {
                if $0.charge != $1.charge { return $0.charge > $1.charge }
                return $0.id < $1.id
            }.prefix(4)) : []
        let noisy = hasUnrepairedFieldMutation ? Array(field.edges.values.filter(OrganismDreamRepair.hasRepairableNoise).sorted {
            if $0.uncertainty != $1.uncertainty { return $0.uncertainty > $1.uncertainty }
            return $0.id < $1.id
        }.prefix(4)) : []
        let hasTargets = !charged.isEmpty || !noisy.isEmpty
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
        let derivedContradiction = correctionNode.map { max($0.charge, $0.activation * 0.5) } ?? 0
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
            predictionResidual: min(1, residuals.pressure),
            transitionSurprise: min(1, residuals.surprise),
            contradictionResidual: derivedContradiction,
            fieldChargeResidual: max(fieldCharge, fieldUncertainty),
            calibrationResidual: derivedCalibration
        )
        let measuredPressure = combinedPressure(components)
        let measuredLocalRepairPressure = min(
            1,
            components.predictionResidual + components.fieldChargeResidual + fieldUncertainty
        )
        // Once a bounded repair pass has started for a generation, finish the remaining exact targets even if the aggregate residue drops below the initial
        // arming threshold. Otherwise the fifth-and-later target could remain permanently charged behind a small residual sum.
        let localRepairPressure = repairState.lastReceipt != nil && hasTargets
            ? max(minimumPressure, measuredLocalRepairPressure)
            : measuredLocalRepairPressure
        let evidenceCount = min(32, unresolvedPredictions.count
            + (correctionNode == nil ? 0 : 1)
            + (hasTargets ? 1 : 0)
            + (derivedCalibration > 0 && ledger.lastUpdatedAt != nil ? 1 : 0))

        // Scheduling follows the trusted ingestion anchor. Source event and persisted field timestamps remain provenance, but a future-dated or delayed source
        // clock must never delay/accelerate quiet physiology.
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
        let localEligible = localRepairPressure >= minimumPressure && evidenceCount > 0 && hasTargets
        let localNext = localEligible ? max(now, localQuietUntil) : nil

        let pendingPredictionDue = ledger.predictions.values
            .filter { $0.status == .pending && $0.horizon?.peerJobID == nil && $0.dueAt > now }
            .map(\.dueAt)
            .min()
        // Below threshold, monotonic residual decay cannot create a crossing; only exact pending prediction expiries are worth scheduling. Heat never disarms
        // repair.
        let nextWake = [localNext, pendingPredictionDue].compactMap { $0 }.filter { $0 > now }.min()
        return OrganismResidualRepairOpportunity(
            generatedAt: now,
            pressure: measuredPressure,
            components: components,
            fieldUncertaintyResidual: fieldUncertainty,
            evidenceCount: evidenceCount,
            chargedNodeIDs: charged.map(\.id),
            noisyEdgeIDs: noisy.map(\.id),
            quietUntil: localEligible ? localQuietUntil : nil,
            nextRepairAt: localNext,
            nextWakeAt: nextWake,
            ready: localEligible && (satisfyWait || now >= localQuietUntil)
        )
    }

}
