// Preserve the writer's newest-started-first turn-summary order; this surface reads no event stream or content previews.
import SwiftUI
import NativeAgentShared
// Blueprint: | `TurnInspectorView.swift` | Turn summary presentation reads the shared sync projection directly |

enum TurnInspectorPresentation {
    enum ContentState: Equatable {
        case unpublished
        case emptyPublished
        case content(truncated: Bool, visibleCount: Int, totalCount: Int)
    }

    static func contentState(for file: TurnSummaryFile?) -> ContentState {
        guard let file else { return .unpublished }
        let visibleCount = file.summaries.count
        let totalCount = max(file.totalTurnsSeen, visibleCount)
        guard visibleCount > 0 || isTruncated(
            writerMarkedTruncated: file.truncated,
            visibleCount: visibleCount,
            totalCount: totalCount
        ) else { return .emptyPublished }
        return .content(
            truncated: isTruncated(
                writerMarkedTruncated: file.truncated,
                visibleCount: visibleCount,
                totalCount: totalCount
            ),
            visibleCount: visibleCount,
            totalCount: totalCount
        )
    }

    static func isTruncated(
        writerMarkedTruncated: Bool,
        visibleCount: Int,
        totalCount: Int
    ) -> Bool {
        writerMarkedTruncated || totalCount > visibleCount
    }

    static func truncationNotice(visibleCount: Int, totalCount: Int) -> String {
        "Showing \(visibleCount) of \(totalCount) turns (oldest dropped for sync size)."
    }

    static func plainDuration(wallMs: Int) -> String? {
        guard wallMs >= 0 else { return nil }
        let seconds = Int((Double(wallMs) / 1000).rounded())
        if wallMs < 1000 { return "under a second" }
        if seconds < 90 { return AliveWords.count(seconds, "second") }
        return AliveWords.count(Int((Double(seconds) / 60).rounded()), "minute")
    }


}


struct TurnInspectorView: View {
    private let sync = iCloudSyncEngine.shared

    var body: some View {
        AlivePage(title: "Turns", line: "How my recent replies went.", freshnessGroup: "turn_summaries") {
            switch TurnInspectorPresentation.contentState(for: file) {
            case .content(let truncated, let visibleCount, let totalCount):
                AliveSection(
                    "Newest first",
                    footer: truncated
                        ? TurnInspectorPresentation.truncationNotice(visibleCount: visibleCount, totalCount: totalCount)
                        : nil
                ) {
                    ForEach(Array((file?.summaries ?? []).enumerated()), id: \.element.id) { index, summary in
                        if index > 0 { AliveDivider() }
                        TurnSummaryRow(summary: summary)
                    }
                }
            case .unpublished:
                AliveCalmState(
                    title: "No turns here yet",
                    line: "The Mac hasn’t published a turn summary to this iPhone yet."
                )
            case .emptyPublished:
                AliveCalmState(
                    title: "No turns yet",
                    line: "The latest summary from the Mac has no turns in it."
                )
            }
        }
        .macSyncErrorBanner()
        .task { await sync.refreshTurnSummariesSnapshot() }
        .refreshable { await sync.refreshTurnSummariesSnapshot() }
    }
}

// MARK: - Row

private struct TurnSummaryRow: View {
    let summary: TurnSummaryRecord

    private var plainLine: String {
        let took = TurnInspectorPresentation.plainDuration(wallMs: summary.wallMs)
        let replied = summary.kinds.contains { $0.key.contains("reply") && $0.value > 0 }
        let tools = summary.kinds.filter { $0.key.hasPrefix("tool") }.values.reduce(Optional(0)) { total, count in
            guard let total, count >= 0 else { return nil }
            let (sum, overflow) = total.addingReportingOverflow(count)
            return overflow ? nil : sum
        }
        var line = took.map { replied ? "Replied in \($0)" : "Took \($0)" } ?? (replied ? "Replied" : "Worked")
        if let tools, tools > 0 {
            line += ", with \(AliveWords.count(tools, "tool event", spelled: true))"
        } else if tools == nil {
            line += ", with an invalid tool event count"
        }
        return line + "."
    }

    private var measures: String {
        var parts: [String] = []
        if let tokens = summary.llmTokens, tokens >= 0 {
            parts.append(AliveWords.count(tokens, "token"))
        }
        if let ttft = summary.ttftMs, ttft >= 0 {
            parts.append("first word in \(ttft) ms")
        }
        parts.append(eventsLine)
        return parts.joined(separator: " · ")
    }

    private var eventsLine: String {
        let count = summary.eventCount >= 0 ? AliveWords.count(summary.eventCount, "event") : "Events unknown"
        guard !summary.kinds.isEmpty else { return count }
        let ordered = summary.kinds.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
        let visible = ordered.prefix(6).map { AliveWords.count($0.value, AliveWords.humanized($0.key).lowercased()) }
        let more = ordered.count > 6 ? ", +\(ordered.count - 6) more" : ""
        return "\(count): " + visible.joined(separator: ", ") + more
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline) {
                Text(summary.surface.flatMap { $0.isEmpty ? nil : $0 } ?? "Turn")
                    .font(.body)
                    .foregroundStyle(AlivePalette.text)
                Spacer(minLength: 8)
                Text(summary.startedAt, style: .time)
                    .font(.subheadline)
                    .foregroundStyle(AlivePalette.secondary)
            }
            Text(plainLine)
                .font(.subheadline)
                .foregroundStyle(AlivePalette.text)
                .fixedSize(horizontal: false, vertical: true)
            Text(measures)
                .font(.footnote)
                .foregroundStyle(AlivePalette.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .aliveRow()
        .accessibilityElement(children: .combine)
    }
}

extension TurnInspectorView {
    private var file: TurnSummaryFile? {
        #if DEBUG
        if MobileDesignSamples.screen != nil {
            do {
                let summaries = MobileDesignSamples.rows([TurnSummaryRecord]()) + (try Self.moreDesignTurns())
                return TurnSummaryFile(summaries: summaries, totalTurnsSeen: summaries.count)
            } catch {
                SystemToastCenter.shared.push(error: "Turn sample is unavailable: \(error.localizedDescription)")
                return nil
            }
        }
        #endif
        return iCloudSyncEngine.shared.turnSummaries
    }

    #if DEBUG
    private static func moreDesignTurns() throws -> [TurnSummaryRecord] {
        try JSONDecoder().decode(
        [TurnSummaryRecord].self,
        from: Data(#"""
        [{"id":"design-turn-2","surface":"Mac chat","startedAt":809998200,"lastAt":809998224,"eventCount":31,"wallMs":24100,"llmTokens":5820,"ttftMs":610,"kinds":{"reply":1,"tool":9,"thinking":3}},
         {"id":"design-turn-3","surface":"Desk task","startedAt":809994600,"lastAt":809994603,"eventCount":5,"wallMs":2900,"llmTokens":380,"ttftMs":290,"kinds":{"reply":1}}]
        """#.utf8)
        )
    }
    #endif

}
