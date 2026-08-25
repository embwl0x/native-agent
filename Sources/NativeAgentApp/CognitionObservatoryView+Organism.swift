// Move-only extraction (tightness Wave C) from CognitionObservatoryView.swift

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
                organismRows(presentation.reflexRows)
            }
            if !presentation.reflexCandidates.isEmpty {
                VStack(alignment: .leading, spacing: NativeAgentSpacing.xs) {
                    ForEach(presentation.reflexCandidates.prefix(4)) { candidate in
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
                                        guard reflexReviewsInFlight.insert(candidate.id).inserted else { return }
                                        Task {
                                            defer { reflexReviewsInFlight.remove(candidate.id) }
                                            let result = await CognitionObservatoryActions.reviewReflex(
                                                runtime: runtime,
                                                id: candidate.id,
                                                decision: .approve,
                                                note: "Approved from Cognition Observatory",
                                                reviewedBy: "operator",
                                                source: "mac_observatory"
                                            )
                                            reportReflexReview(result.outcome, action: "Approve")
                                            await refresh()
                                        }
                                    }
                                    .disabled(candidate.trustClass != .lowRisk || reflexReviewsInFlight.contains(candidate.id))
                                    Button("Retire", systemImage: "xmark.circle") {
                                        guard reflexReviewsInFlight.insert(candidate.id).inserted else { return }
                                        Task {
                                            defer { reflexReviewsInFlight.remove(candidate.id) }
                                            let result = await CognitionObservatoryActions.reviewReflex(
                                                runtime: runtime,
                                                id: candidate.id,
                                                decision: .retire,
                                                note: "Retired from Cognition Observatory",
                                                reviewedBy: "operator",
                                                source: "mac_observatory"
                                            )
                                            reportReflexReview(result.outcome, action: "Retire")
                                            await refresh()
                                        }
                                    }
                                    .disabled(reflexReviewsInFlight.contains(candidate.id))
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
                organismRows(presentation.bodyRows)
            }
            }
        case .disabled, .unavailable, .absent:
            ObservatoryNoticeRow(
                icon: "eye.slash",
                tint: .secondary,
                title: "Organism body readout unavailable",
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

    private func reportReflexReview(_ outcome: OrganismReflexReviewApplyOutcome, action: String) {
        if outcome.applied {
            dependencies.systemToasts.push(success: "\(action) reflex review saved.")
        } else {
            dependencies.systemToasts.push(error: "\(action) reflex review failed: \(outcome.error ?? outcome.status.rawValue)")
        }
    }
}
