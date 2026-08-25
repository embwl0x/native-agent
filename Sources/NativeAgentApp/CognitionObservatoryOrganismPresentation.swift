import Foundation
import CognitiveSubstrate

/// The control contract for the Organism toggle in Cognition Observatory.
/// Keeping its availability and selected state in this shared presentation
/// seam lets the view and its behavioral coverage agree without depending on
/// an AppKit representation of a SwiftUI Toggle.
struct CognitionObservatoryOrganismControlPresentation: Equatable, Sendable {
    static let label = "Organism body kernel"

    let isEnabled: Bool
    let isOn: Bool

    init(cognitiveSubstrateEnabled: Bool, organismKernelEnabled: Bool) {
        self.isEnabled = cognitiveSubstrateEnabled
        self.isOn = organismKernelEnabled
    }
}

/// Read-only mapping for the mounted Organism Body panel. The kernel owns the
/// snapshot; this presentation layer makes the difference between a real empty
/// body, an off kernel, and a stale or malformed sample visible to the operator.
struct CognitionObservatoryOrganismPresentation: Equatable, Sendable {
    struct Row: Identifiable, Equatable, Sendable {
        let label: String
        let value: String

        var id: String { label }
        var text: String { "\(label): \(value)" }
    }

    enum State: Equatable, Sendable {
        case live
        case disabled(String)
        case unavailable(String)
        case absent(String)
    }

    let state: State
    let statusText: String
    let statusKind: String
    let sampledAtText: String
    let signalCountText: String
    let lastSignalText: String
    let bodyLine: String?
    let chemicalRows: [Row]
    let fieldRows: [Row]
    let predictionRows: [Row]
    let dreamRepairRows: [Row]
    let reflexRows: [Row]
    let bodyRows: [Row]
    let reflexCandidates: [OrganismReflexCandidate]

    init(
        snapshot: OrganismSnapshot?,
        now: Date = Date(),
        maximumSampleAge: TimeInterval = 5 * 60
    ) {
        guard let snapshot else {
            state = .absent("No organism body snapshot has arrived yet.")
            statusText = "Unavailable"
            statusKind = "warn"
            sampledAtText = "sample absent"
            signalCountText = "absent"
            lastSignalText = "absent"
            bodyLine = nil
            chemicalRows = []
            fieldRows = []
            predictionRows = []
            dreamRepairRows = []
            reflexRows = []
            bodyRows = []
            reflexCandidates = []
            return
        }

        guard snapshot.enabled else {
            state = .disabled("Organism body kernel is off — no live body readout is available.")
            statusText = "Off"
            statusKind = "warn"
            sampledAtText = "body readout off"
            signalCountText = "absent"
            lastSignalText = "absent"
            bodyLine = nil
            chemicalRows = []
            fieldRows = []
            predictionRows = []
            dreamRepairRows = []
            reflexRows = []
            bodyRows = []
            reflexCandidates = []
            return
        }

        let age = now.timeIntervalSince(snapshot.generatedAt)
        guard snapshot.generatedAt.timeIntervalSinceReferenceDate.isFinite,
              now.timeIntervalSinceReferenceDate.isFinite,
              age >= -60,
              age <= maximumSampleAge else {
            state = .unavailable("The last organism body sample is stale or has an invalid timestamp; refresh it before reading these values.")
            statusText = "Unavailable"
            statusKind = "warn"
            sampledAtText = "sample stale"
            signalCountText = "absent"
            lastSignalText = "absent"
            bodyLine = nil
            chemicalRows = []
            fieldRows = []
            predictionRows = []
            dreamRepairRows = []
            reflexRows = []
            bodyRows = []
            reflexCandidates = []
            return
        }

        let numericValues = [
            snapshot.chemicalState.warmth,
            snapshot.chemicalState.vigilance,
            snapshot.chemicalState.coherence,
            snapshot.chemicalState.confidence,
            snapshot.chemicalState.fatigue,
            snapshot.chemicalState.agency,
            snapshot.fieldSummary.strongestEdgeWeight,
            snapshot.fieldSummary.totalCharge,
            snapshot.fieldSummary.averageUncertainty,
            snapshot.predictionSummary.peripheralUncertainty,
            snapshot.predictionSummary.strategyCaution,
            snapshot.predictionSummary.bodyConfidence.toolPath,
            snapshot.predictionSummary.bodyConfidence.providerPath,
            snapshot.predictionSummary.bodyConfidence.phonePath,
            snapshot.residualRepairOpportunity.pressure,
            snapshot.reflexSummary.highestConfidence,
        ]
        guard numericValues.allSatisfy(\.isFinite) else {
            state = .unavailable("The organism body sample contains an invalid value and is withheld.")
            statusText = "Unavailable"
            statusKind = "warn"
            sampledAtText = "sample invalid"
            signalCountText = "absent"
            lastSignalText = "absent"
            bodyLine = nil
            chemicalRows = []
            fieldRows = []
            predictionRows = []
            dreamRepairRows = []
            reflexRows = []
            bodyRows = []
            reflexCandidates = []
            return
        }

        state = .live
        statusText = "Enabled"
        statusKind = "ok"
        sampledAtText = "sampled \(snapshot.generatedAt.formatted(date: .omitted, time: .shortened))"
        signalCountText = "\(snapshot.signalCount) signals"
        lastSignalText = Self.optionalDate(snapshot.lastSignalAt)
        bodyLine = snapshot.projectedBodyLine?.trimmingCharacters(in: .whitespacesAndNewlines)
        chemicalRows = [
            Self.decimal("Warmth", snapshot.chemicalState.warmth),
            Self.decimal("Vigilance", snapshot.chemicalState.vigilance),
            Self.decimal("Coherence", snapshot.chemicalState.coherence),
            Self.decimal("Confidence", snapshot.chemicalState.confidence),
            Self.decimal("Fatigue", snapshot.chemicalState.fatigue),
            Self.decimal("Agency", snapshot.chemicalState.agency),
        ]
        fieldRows = [
            .init(label: "Field nodes", value: "\(snapshot.fieldSummary.nodeCount)"),
            .init(label: "Field edges", value: "\(snapshot.fieldSummary.edgeCount)"),
            Self.decimal("Strongest link", snapshot.fieldSummary.strongestEdgeWeight),
            Self.decimal("Total charge", snapshot.fieldSummary.totalCharge),
            Self.decimal("Uncertainty", snapshot.fieldSummary.averageUncertainty),
        ]
        if let belief = snapshot.bodySchema.providerPathBelief {
            predictionRows = [
                .init(label: "Predictions pending", value: "\(snapshot.predictionSummary.pendingCount)"),
                .init(label: "Prediction errors", value: "\(snapshot.predictionSummary.violatedCount)"),
                .init(label: "Expired predictions", value: "\(snapshot.predictionSummary.expiredCount)"),
                Self.decimal("Peripheral uncertainty", snapshot.predictionSummary.peripheralUncertainty),
                Self.decimal("Strategy caution", snapshot.predictionSummary.strategyCaution),
                Self.decimal("Tool confidence", snapshot.predictionSummary.bodyConfidence.toolPath),
                Self.decimal("Provider confidence", snapshot.predictionSummary.bodyConfidence.providerPath),
                Self.decimal("Phone confidence", snapshot.predictionSummary.bodyConfidence.phonePath),
                .init(label: "Provider belief", value: belief.state.rawValue),
                Self.decimal("Provider belief estimate", belief.estimate),
                Self.decimal("Provider belief uncertainty", belief.uncertainty),
                Self.decimal("Provider evidence freshness", belief.freshness),
            ]
        } else {
            predictionRows = [
                .init(label: "Predictions pending", value: "\(snapshot.predictionSummary.pendingCount)"),
                .init(label: "Prediction errors", value: "\(snapshot.predictionSummary.violatedCount)"),
                .init(label: "Expired predictions", value: "\(snapshot.predictionSummary.expiredCount)"),
                Self.decimal("Peripheral uncertainty", snapshot.predictionSummary.peripheralUncertainty),
                Self.decimal("Strategy caution", snapshot.predictionSummary.strategyCaution),
                Self.decimal("Tool confidence", snapshot.predictionSummary.bodyConfidence.toolPath),
                Self.decimal("Provider confidence", snapshot.predictionSummary.bodyConfidence.providerPath),
                Self.decimal("Phone confidence", snapshot.predictionSummary.bodyConfidence.phonePath),
                .init(label: "Provider belief", value: "absent"),
                .init(label: "Provider belief estimate", value: "absent"),
                .init(label: "Provider belief uncertainty", value: "absent"),
                .init(label: "Provider evidence freshness", value: "absent"),
            ]
        }
        dreamRepairRows = [
            .init(label: "Dream repairs", value: "\(snapshot.dreamRepairSummary.receiptCount)"),
            .init(label: "Last repair ops", value: "\(snapshot.dreamRepairSummary.lastOperationCount)"),
            .init(label: "Softened nodes", value: "\(snapshot.dreamRepairSummary.softenedNodes)"),
            .init(label: "Warm links", value: "\(snapshot.dreamRepairSummary.strengthenedEdges)"),
            .init(label: "Noisy links", value: "\(snapshot.dreamRepairSummary.weakenedEdges)"),
            .init(label: "Flags", value: "\(snapshot.dreamRepairSummary.flaggedContradictions)"),
            .init(label: "View proposals", value: "\(snapshot.dreamRepairSummary.proposedStandingViews)"),
            Self.decimal("Residual repair pressure", snapshot.residualRepairOpportunity.pressure),
            .init(label: "Residual evidence", value: "\(snapshot.residualRepairOpportunity.evidenceCount)"),
            .init(label: "Residual repair ready", value: snapshot.residualRepairOpportunity.ready ? "yes" : "no"),
        ]
        reflexRows = [
            .init(label: "Reflex candidates", value: "\(snapshot.reflexSummary.candidateCount)"),
            .init(label: "Need review", value: "\(snapshot.reflexSummary.reviewRequiredCount)"),
            .init(label: "Low risk", value: "\(snapshot.reflexSummary.lowRiskCount)"),
            .init(label: "Confirm", value: "\(snapshot.reflexSummary.confirmRequiredCount)"),
            .init(label: "High risk", value: "\(snapshot.reflexSummary.highRiskCount)"),
            Self.decimal("Highest confidence", snapshot.reflexSummary.highestConfidence),
        ]
        bodyRows = [
            .init(label: "Mac awake", value: snapshot.bodySchema.macAwake ? "yes" : "no"),
            .init(label: "iPhone reachable", value: snapshot.bodySchema.iPhoneReachable ? "yes" : "no"),
            .init(label: "Providers", value: snapshot.bodySchema.providersHealthy ? "healthy" : "attention"),
            .init(label: "Memory", value: snapshot.bodySchema.memoryHealthy ? "healthy" : "attention"),
            .init(label: "Dreams", value: snapshot.bodySchema.dreamHealthy ? "healthy" : "attention"),
            .init(label: "Tools", value: snapshot.bodySchema.toolHandsAvailable ? "available" : "unavailable"),
            .init(label: "Approvals", value: snapshot.bodySchema.approvalChannelsOpen ? "open" : "closed"),
            .init(label: "Notifications", value: snapshot.bodySchema.notificationPathHealthy ? "healthy" : "attention"),
            .init(label: "Resource pressure", value: snapshot.bodySchema.resourcePressure.rawValue),
        ]
        reflexCandidates = snapshot.reflexCandidates
    }

    var collapsedHint: String {
        switch state {
        case .live:
            if let bodyLine, !bodyLine.isEmpty {
                return bodyLine.replacingOccurrences(of: "- Body: ", with: "")
            }
            return "no body line"
        case .disabled:
            return "off"
        case .unavailable:
            return "unavailable"
        case .absent:
            return "waiting"
        }
    }

    var unavailableReason: String? {
        switch state {
        case .live: nil
        case .disabled(let reason), .unavailable(let reason), .absent(let reason): reason
        }
    }

    var renderedRowText: [String] {
        guard case .live = state else { return [] }
        return ([Row(label: "Last signal", value: lastSignalText)]
            + chemicalRows + fieldRows + predictionRows + dreamRepairRows + reflexRows + bodyRows
        ).map(\.text)
    }

    private static func decimal(_ label: String, _ value: Double) -> Row {
        Row(label: label, value: String(format: "%.2f", value))
    }

    private static func optionalDate(_ value: Date?) -> String {
        value.map { $0.formatted(date: .omitted, time: .shortened) } ?? "absent"
    }
}
