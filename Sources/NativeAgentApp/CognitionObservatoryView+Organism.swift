import Foundation

// Blueprint: | `CognitionObservatoryView+Organism.swift` | Observatory organism panel: read-only kernel rows distinguish off, empty, stale and malformed readings |
// Move-only extraction (tightness Wave C) from CognitionObservatoryView.swift

import Cognition
import SwiftUI
import CognitiveSubstrate
import Context
import PersistenceCore

extension CognitionObservatoryView {

    @ViewBuilder
    func organism(_ snapshot: OrganismSnapshot) -> some View {
        let presentation = CognitionObservatoryOrganismPresentation(snapshot: snapshot)
        switch presentation.state {
        case .live:
            VStack(alignment: .leading, spacing: NativeAgentSpacing.sm) {
                HStack {
                    StatusBadge(text: presentation.statusText, status: presentation.statusKind)
                    Text(presentation.sampledAtText)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(presentation.signalCountText)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                labeledRow("Last signal", presentation.lastSignalText)
            if let line = presentation.bodyLine, !line.isEmpty {
                Text(line)
                    .font(.caption)
                    .textSelection(.enabled)
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 190), spacing: NativeAgentSpacing.md)], spacing: NativeAgentSpacing.sm) {
                organismRows(presentation.chemicalRows)
            }
            Divider()
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 190), spacing: NativeAgentSpacing.md)], spacing: NativeAgentSpacing.sm) {
                organismRows(presentation.fieldRows)
            }
            Divider()
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 190), spacing: NativeAgentSpacing.md)], spacing: NativeAgentSpacing.sm) {
                organismRows(presentation.predictionRows)
            }
            Divider()
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 190), spacing: NativeAgentSpacing.md)], spacing: NativeAgentSpacing.sm) {
                organismRows(presentation.dreamRepairRows)
            }
            Divider()
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 190), spacing: NativeAgentSpacing.md)], spacing: NativeAgentSpacing.sm) {
                organismRows(presentation.bodyRows)
            }
            }
        case .disabled, .unavailable, .absent:
            ObservatoryNoticeRow(
                icon: "eye.slash",
                tint: .secondary,
                title: "Body readout unavailable",
                detail: presentation.unavailableReason ?? "No organism body readout is available."
            )
        }
    }

    @ViewBuilder
    private func organismRows(_ rows: [CognitionObservatoryOrganismPresentation.Row]) -> some View {
        ForEach(rows) { row in
            labeledRow(row.label, row.value)
        }
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
    let bodyRows: [Row]

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
            bodyRows = []
            return
        }

        guard snapshot.enabled else {
            state = .disabled("Moods, energy, and a clock of my own are off in Settings — there is no live body readout.")
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
            bodyRows = []
            return
        }

        guard snapshot.observatorySampleIsCurrent(now: now, maximumSampleAge: maximumSampleAge) else {
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
            bodyRows = []
            return
        }

        guard snapshot.observatoryValuesAreValid else {
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
            bodyRows = []
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
            Self.decimal("Residual repair pressure", snapshot.residualRepairOpportunity.pressure),
            .init(label: "Residual evidence", value: "\(snapshot.residualRepairOpportunity.evidenceCount)"),
            .init(label: "Residual repair ready", value: snapshot.residualRepairOpportunity.ready ? "yes" : "no"),
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

    private static func decimal(_ label: String, _ value: Double) -> Row {
        Row(label: label, value: String(format: "%.2f", value))
    }

    private static func optionalDate(_ value: Date?) -> String {
        value.map { $0.formatted(date: .omitted, time: .shortened) } ?? "absent"
    }
}
