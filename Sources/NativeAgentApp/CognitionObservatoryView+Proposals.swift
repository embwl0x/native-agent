// Move-only extraction (tightness Wave C) from CognitionObservatoryView.swift

import SwiftUI
import CognitiveSubstrate

extension CognitionObservatoryView {

    // Standing Views + Schema Proposals rendering moved to CognitionProposalsView
    // (Activity surface, B2.4). Identity Proposals were retired after the
    // liveness audit proved the experimental producer never shipped.

    /// THE READOUT, THEN THE RECEIPTS (2026-09-13).
    ///
    /// The raw ten-event list below answers "what happened", in event order,
    /// with truncated summaries and lineage ids — which is the material a
    /// reader has to reconstruct a week FROM, not an answer to "what changed".
    /// The week's rows go on top: one line per lesson or view, its outcome in
    /// words, and the passage that formed it. Bounded, no charts.
    @ViewBuilder
    func growthWeekReadout(_ week: CognitiveGrowthWeek) -> some View {
        VStack(alignment: .leading, spacing: NativeAgentSpacing.sm) {
            Text("This week")
                .font(.caption.weight(.semibold))
            if week.rows.isEmpty {
                Text("Nothing settled this week.")
                    .font(NativeAgentFont.label)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(week.rows, id: \.id) { row in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(row.line)
                            .font(.caption)
                            .textSelection(.enabled)
                        if !row.originExcerpt.isEmpty {
                            // WHY. The exact line she reflected on, kept with
                            // the view since formation — not a later summary.
                            Text(row.originExcerpt)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                                .textSelection(.enabled)
                        }
                        if row.collapsedEventCount > 0 {
                            Text("\(row.collapsedEventCount) earlier step(s) collapsed · \(row.lineageId)")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
            }
            // WHAT THE LIST IS NOT SHOWING, both kinds, said before the
            // undertone — the same two lines `growthWeekLines` prints. The Mac
            // surface rendered neither, so a capped week looked complete here
            // and an absence of rejections could not be told from rejections
            // not being drawn (Agent, 2026-09-14).
            if week.omittedRowCount > 0 {
                Text("and \(week.omittedRowCount) more this week, not shown")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            if week.hasNoReleases {
                Text("Nothing was rejected or released this week.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            ForEach(Array(week.dispositionTransitions.suffix(3).enumerated()), id: \.offset) { _, move in
                // Which half of the change was time and which was an
                // experience — the two the old artifact could not separate.
                Text(String(
                    format: "undertone %.2f → %.2f (faded %+.2f, %@ moved it %+.2f)",
                    move.before,
                    move.afterContribution,
                    move.afterDecay - move.before,
                    move.source,
                    move.afterContribution - move.afterDecay))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
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
                            Text(CognitionObservatoryPresentation.timelineDateLabel(event))
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
