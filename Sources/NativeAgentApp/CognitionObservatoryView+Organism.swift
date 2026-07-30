// Move-only extraction (tightness Wave C) from CognitionObservatoryView.swift

import SwiftUI
import CognitiveSubstrate
import Context
import PersistenceCore

extension CognitionObservatoryView {

    func organism(_ snapshot: OrganismSnapshot) -> some View {
        VStack(alignment: .leading, spacing: NativeAgentSpacing.sm) {
            HStack {
                StatusBadge(text: snapshot.enabled ? "Enabled" : "Off", status: snapshot.enabled ? "ok" : "warn")
                if let lastSignalAt = snapshot.lastSignalAt {
                    Text("last signal \(lastSignalAt.formatted(date: .omitted, time: .shortened))")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text("\(snapshot.signalCount) signals")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            if let line = snapshot.projectedBodyLine, !line.isEmpty {
                Text(line)
                    .font(.caption)
                    .textSelection(.enabled)
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 190), spacing: NativeAgentSpacing.md)], spacing: NativeAgentSpacing.sm) {
                labeledValue("Warmth", snapshot.chemicalState.warmth)
                labeledValue("Vigilance", snapshot.chemicalState.vigilance)
                labeledValue("Coherence", snapshot.chemicalState.coherence)
                labeledValue("Confidence", snapshot.chemicalState.confidence)
                labeledValue("Fatigue", snapshot.chemicalState.fatigue)
                labeledValue("Agency", snapshot.chemicalState.agency)
            }
            Divider()
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 190), spacing: NativeAgentSpacing.md)], spacing: NativeAgentSpacing.sm) {
                labeledRow("Field nodes", "\(snapshot.fieldSummary.nodeCount)")
                labeledRow("Field edges", "\(snapshot.fieldSummary.edgeCount)")
                labeledValue("Strongest link", snapshot.fieldSummary.strongestEdgeWeight)
                labeledValue("Total charge", snapshot.fieldSummary.totalCharge)
                labeledValue("Uncertainty", snapshot.fieldSummary.averageUncertainty)
            }
            Divider()
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 190), spacing: NativeAgentSpacing.md)], spacing: NativeAgentSpacing.sm) {
                labeledRow("Predictions pending", "\(snapshot.predictionSummary.pendingCount)")
                labeledRow("Prediction errors", "\(snapshot.predictionSummary.violatedCount)")
                labeledRow("Expired predictions", "\(snapshot.predictionSummary.expiredCount)")
                labeledValue("Peripheral uncertainty", snapshot.predictionSummary.peripheralUncertainty)
                labeledValue("Strategy caution", snapshot.predictionSummary.strategyCaution)
                labeledValue("Tool confidence", snapshot.predictionSummary.bodyConfidence.toolPath)
                labeledValue("Provider confidence", snapshot.predictionSummary.bodyConfidence.providerPath)
                labeledValue("Phone confidence", snapshot.predictionSummary.bodyConfidence.phonePath)
                if let providerBelief = snapshot.bodySchema.providerPathBelief {
                    labeledRow("Provider belief", providerBelief.state.rawValue)
                    labeledValue("Provider belief estimate", providerBelief.estimate)
                    labeledValue("Provider belief uncertainty", providerBelief.uncertainty)
                    labeledValue("Provider evidence freshness", providerBelief.freshness)
                }
            }
            Divider()
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 190), spacing: NativeAgentSpacing.md)], spacing: NativeAgentSpacing.sm) {
                labeledRow("Dream repairs", "\(snapshot.dreamRepairSummary.receiptCount)")
                labeledRow("Last repair ops", "\(snapshot.dreamRepairSummary.lastOperationCount)")
                labeledRow("Softened nodes", "\(snapshot.dreamRepairSummary.softenedNodes)")
                labeledRow("Warm links", "\(snapshot.dreamRepairSummary.strengthenedEdges)")
                labeledRow("Noisy links", "\(snapshot.dreamRepairSummary.weakenedEdges)")
                labeledRow("Flags", "\(snapshot.dreamRepairSummary.flaggedContradictions)")
                labeledRow("View proposals", "\(snapshot.dreamRepairSummary.proposedStandingViews)")
                labeledValue("Residual repair pressure", snapshot.residualRepairOpportunity.pressure)
                labeledRow("Residual evidence", "\(snapshot.residualRepairOpportunity.evidenceCount)")
                labeledRow("Residual repair ready", snapshot.residualRepairOpportunity.ready ? "yes" : "no")
            }
            Divider()
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 190), spacing: NativeAgentSpacing.md)], spacing: NativeAgentSpacing.sm) {
                labeledRow("Reflex candidates", "\(snapshot.reflexSummary.candidateCount)")
                labeledRow("Need review", "\(snapshot.reflexSummary.reviewRequiredCount)")
                labeledRow("Low risk", "\(snapshot.reflexSummary.lowRiskCount)")
                labeledRow("Confirm", "\(snapshot.reflexSummary.confirmRequiredCount)")
                labeledRow("High risk", "\(snapshot.reflexSummary.highRiskCount)")
                labeledValue("Highest confidence", snapshot.reflexSummary.highestConfidence)
            }
            if !snapshot.reflexCandidates.isEmpty {
                VStack(alignment: .leading, spacing: NativeAgentSpacing.xs) {
                    ForEach(snapshot.reflexCandidates.prefix(4)) { candidate in
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: NativeAgentSpacing.xs) {
                                StatusBadge(
                                    text: candidate.trustClass.rawValue,
                                    status: candidate.trustClass == .highRisk ? "warn" : "ok"
                                )
                                Text("\(candidate.evidenceCount) evidence")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                Text("confidence \(String(format: "%.2f", candidate.confidence))")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            Text(candidate.pattern)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                                .lineLimit(3)
                            HStack(spacing: NativeAgentSpacing.xs) {
                                if candidate.reviewRequired {
                                    Button("Approve", systemImage: "checkmark.circle") {
                                        Task {
                                            _ = await NativeCognitionRuntime.shared.reviewOrganismReflexCandidate(
                                                id: candidate.id,
                                                decision: .approve,
                                                note: "Approved from Cognition Observatory",
                                                reviewedBy: "operator",
                                                source: "mac_observatory"
                                            )
                                            await refresh()
                                        }
                                    }
                                    .disabled(candidate.trustClass != .lowRisk)
                                    Button("Retire", systemImage: "xmark.circle") {
                                        Task {
                                            _ = await NativeCognitionRuntime.shared.reviewOrganismReflexCandidate(
                                                id: candidate.id,
                                                decision: .retire,
                                                note: "Retired from Cognition Observatory",
                                                reviewedBy: "operator",
                                                source: "mac_observatory"
                                            )
                                            await refresh()
                                        }
                                    }
                                } else if candidate.autoActivationAllowed {
                                    Label("Approved low-risk", systemImage: "checkmark.seal")
                                        .font(.caption2)
                                        .foregroundStyle(.green)
                                }
                            }
                            .font(.caption2)
                        }
                    }
                }
            }
            Divider()
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 190), spacing: NativeAgentSpacing.md)], spacing: NativeAgentSpacing.sm) {
                labeledRow("Mac awake", yesNo(snapshot.bodySchema.macAwake))
                labeledRow("iPhone reachable", yesNo(snapshot.bodySchema.iPhoneReachable))
                labeledRow("Providers", health(snapshot.bodySchema.providersHealthy))
                labeledRow("Memory", health(snapshot.bodySchema.memoryHealthy))
                labeledRow("Dreams", health(snapshot.bodySchema.dreamHealthy))
                labeledRow("Tools", snapshot.bodySchema.toolHandsAvailable ? "available" : "unavailable")
                labeledRow("Approvals", snapshot.bodySchema.approvalChannelsOpen ? "open" : "closed")
                labeledRow("Notifications", health(snapshot.bodySchema.notificationPathHealthy))
                labeledRow("Resource pressure", snapshot.bodySchema.resourcePressure.rawValue)
            }
        }
    }

    private func yesNo(_ value: Bool) -> String {
        value ? "yes" : "no"
    }

    private func health(_ value: Bool) -> String {
        value ? "healthy" : "attention"
    }
}
