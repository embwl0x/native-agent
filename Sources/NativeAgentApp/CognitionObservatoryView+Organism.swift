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
