// Turn Inspector W4 — iOS read-only inspector.
//
// Renders the per-turn SUMMARY records the Mac writes into the iCloud snapshot
// (`turn_summaries.json`). Read-only by design: no event stream, no content —
// only time, surface, event count, tokens, ttft, duration, and the per-kind mix.
// Functional-first (W5 is the pizzazz wave). Newest turn on top (the Mac lane
// already orders newest-started-first; we render as-given).
import SwiftUI
import NativeAgentShared

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

    /// How long, the way a person says it: "under a second", "8 seconds",
    /// "2 minutes". Nil when unknown.
    static func plainDuration(wallMs: Int) -> String? {
        guard wallMs >= 0 else { return nil }
        let seconds = Int((Double(wallMs) / 1000).rounded())
        if wallMs < 1000 { return "under a second" }
        if seconds < 90 { return AliveWords.count(seconds, "second") }
        return AliveWords.count(Int((Double(seconds) / 60).rounded()), "minute")
    }

    static func durationText(wallMs: Int) -> String {
        guard wallMs >= 0 else { return "Unknown" }
        let seconds = Double(wallMs) / 1000.0
        return seconds < 1 ? "\(wallMs) ms" : String(format: "%.1f s", seconds)
    }

    private static func nonnegativeText(_ value: Int?) -> String {
        guard let value, value >= 0 else { return "Unknown" }
        return String(value)
    }

    private static func millisecondsText(_ value: Int?) -> String {
        guard let value, value >= 0 else { return "Unknown" }
        return "\(value) ms"
    }

    static func kindsText(_ kinds: [String: Int]) -> String {
        let ordered = kinds
            .sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
        let visible = ordered.prefix(6).map { "\($0.key) ×\($0.value)" }.joined(separator: " · ")
        return ordered.count > 6 ? "\(visible) · +\(ordered.count - 6) more" : visible
    }

    static func metrics(for summary: TurnSummaryRecord) -> [(value: String, label: String)] {
        var result: [(value: String, label: String)] = [
            (value: nonnegativeText(summary.eventCount), label: "events"),
            (value: durationText(wallMs: summary.wallMs), label: "wall"),
        ]
        result.append((value: nonnegativeText(summary.llmTokens), label: "tok"))
        result.append((value: millisecondsText(summary.ttftMs), label: "ttft"))
        return result
    }

}


struct TurnInspectorView: View {
    @StateObject private var store = TurnInspectorStore()
    @ObservedObject private var sync = iCloudSyncEngine.shared

    var body: some View {
        AlivePage(title: "Turns", line: "How my recent replies went.", freshnessGroup: "turn_summaries") {
            switch TurnInspectorPresentation.contentState(for: store.file) {
            case .content(let truncated, let visibleCount, let totalCount):
                AliveSection(
                    "Newest first",
                    footer: truncated
                        ? TurnInspectorPresentation.truncationNotice(visibleCount: visibleCount, totalCount: totalCount)
                        : nil
                ) {
                    ForEach(Array((store.file?.summaries ?? []).enumerated()), id: \.element.id) { index, summary in
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
        .onAppear { Task { await store.refresh() } }
        .refreshable { await store.refresh() }
        .onChange(of: sync.turnSummaries) { _, file in
            store.applySyncedFile(file)
        }
    }
}

// MARK: - Row

private struct TurnSummaryRow: View {
    let summary: TurnSummaryRecord

    /// What happened and how long, in plain words: "Replied in 8 seconds,
    /// with two tool events."
    private var plainLine: String {
        let took = TurnInspectorPresentation.plainDuration(wallMs: summary.wallMs)
        // Kinds arrive as "reply" or "chat.reply", "tool" or "tool.call".
        let replied = summary.kinds.contains { $0.key.contains("reply") && $0.value > 0 }
        let tools = summary.kinds.filter { $0.key.hasPrefix("tool") }.values.reduce(0, +)
        var line = took.map { replied ? "Replied in \($0)" : "Took \($0)" } ?? (replied ? "Replied" : "Worked")
        if tools > 0 {
            line += ", with \(AliveWords.count(tools, "tool event", spelled: true))"
        }
        return line + "."
    }

    /// The numbers, second: tokens, time to the first word, the event mix.
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

    /// "12 events: 2 tools, 1 reply".
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

// MARK: - Store

@MainActor
final class TurnInspectorStore: ObservableObject {
    @Published var file: TurnSummaryFile?

    func refresh() async {
        #if DEBUG
        if MobileDesignSamples.screen != nil {
            file = try! JSONDecoder().decode(TurnSummaryFile.self, from: Data("{}".utf8))
            file?.summaries = MobileDesignSamples.rows([TurnSummaryRecord]()) + Self.moreDesignTurns
            file?.totalTurnsSeen = file?.summaries.count ?? 0
            return
        }
        #endif
        await iCloudSyncEngine.shared.refreshTurnSummariesSnapshot()
        file = iCloudSyncEngine.shared.turnSummaries
    }

    #if DEBUG
    private static let moreDesignTurns: [TurnSummaryRecord] = try! JSONDecoder().decode(
        [TurnSummaryRecord].self,
        from: Data(#"""
        [{"id":"design-turn-2","surface":"Mac chat","startedAt":809998200,"lastAt":809998224,"eventCount":31,"wallMs":24100,"llmTokens":5820,"ttftMs":610,"kinds":{"reply":1,"tool":9,"thinking":3}},
         {"id":"design-turn-3","surface":"Desk task","startedAt":809994600,"lastAt":809994603,"eventCount":5,"wallMs":2900,"llmTokens":380,"ttftMs":290,"kinds":{"reply":1}}]
        """#.utf8)
    )
    #endif

    func applySyncedFile(_ next: TurnSummaryFile?) {
        file = next
    }
}
