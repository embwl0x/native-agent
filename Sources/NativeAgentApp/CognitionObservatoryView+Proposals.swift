import NativeAgentShared
import SwiftUI
import CognitiveSubstrate

// Blueprint: | `CognitionObservatoryView+Proposals.swift` | Observatory growth-week and developmental timeline: readout/receipt presentation from current cognition state |

extension CognitionObservatoryView {

    // REM lineage renders in CognitionProposalsView on the Activity surface.

    /// Weekly lessons, outcomes and forming passages precede the raw event receipts.
    @ViewBuilder
    func growthWeekReadout(_ week: CognitiveGrowthWeek) -> some View {
        VStack(alignment: .leading, spacing: NativeAgentSpacing.sm) {
            Text("This week")
                .font(.caption.weight(.semibold))
            if week.projection.status != .ready {
                Text("Growth week \(week.projection.status.rawValue): \(week.projection.error?.message ?? week.projection.status.rawValue)")
                    .font(.caption).foregroundStyle(.secondary)
            }
            ForEach(week.projection.face?.sections ?? []) { section in
                ForEach(section.rows) { row in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(row.title).font(.caption).textSelection(.enabled)
                        if let detail = row.detail, !detail.isEmpty {
                            Text(detail).font(.caption2).foregroundStyle(.secondary).lineLimit(2).textSelection(.enabled)
                        }
                        if let value = row.value, !value.isEmpty {
                            Text(value).font(.caption2).foregroundStyle(.tertiary)
                        }
                    }
                }
            }
            Divider()
        }
    }

    @ViewBuilder
    func developmentalTimeline(
        _ events: [CognitiveDevelopmentalTimelineEvent],
        week: CognitiveGrowthWeek
    ) -> some View {
            growthWeekReadout(week)
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
                            Text(CognitionTimelinePresentation.timelineDateLabel(event))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
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

enum CognitionTimelinePresentation {
    static func timelineDateLabel(_ event: CognitiveDevelopmentalTimelineEvent) -> String {
        "recorded \(event.occurredAt.formatted(date: .abbreviated, time: .shortened))"
    }
}
