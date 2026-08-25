// Move-only extraction (tightness Wave C) from CognitionObservatoryView.swift

import SwiftUI
import CognitiveSubstrate
import Context
import PersistenceCore

extension CognitionObservatoryView {

    @ViewBuilder
    func affect(_ presentation: CognitionObservatoryAffectPresentation) -> some View {
        VStack(alignment: .leading, spacing: NativeAgentSpacing.sm) {
            switch presentation.state {
            case .live:
                Text("Raw steering signals for \(dependencies.agentDisplayName)'s next-turn tone and attention. Low usually means calm, not absent.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 190), spacing: NativeAgentSpacing.md)], spacing: NativeAgentSpacing.sm) {
                    ForEach(presentation.axes, id: \.label) { axis in
                        labeledValue(axis.label, axis.value)
                    }
                }
                Text(presentation.capsuleWarmthNote)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            case let .disabled(reason), let .unavailable(reason), let .absent(reason):
                ObservatoryNoticeRow(
                    icon: "eye.slash",
                    tint: .secondary,
                    title: "Affect readout unavailable",
                    detail: reason
                )
            }
        }
    }
}
