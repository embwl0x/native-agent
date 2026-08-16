// Move-only extraction (tightness Wave C) from CognitionObservatoryView.swift

import SwiftUI
import CognitiveSubstrate

extension CognitionObservatoryView {

    // Standing Views + Schema Proposals rendering moved to CognitionProposalsView
    // (Activity surface, B2.4). Identity Proposals were retired after the
    // liveness audit proved the experimental producer never shipped.

    @ViewBuilder
    func developmentalTimeline(_ events: [CognitiveDevelopmentalTimelineEvent]) -> some View {
            if events.isEmpty {
                Text("No developmental timeline events.")
                    .font(NativeAgentFont.label)
                    .foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: NativeAgentSpacing.sm) {
                    ForEach(Array(events.prefix(10)), id: \.id) { event in
                        VStack(alignment: .leading, spacing: 4) {
                            Text("\(event.kind.rawValue): \(event.title)")
                                .font(.caption.weight(.semibold))
                            Text(event.summary)
                                .font(.caption)
                                .lineLimit(3)
                                .textSelection(.enabled)
                            Text(event.lineageId)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        Divider()
                    }
                }
            }
    }
}
