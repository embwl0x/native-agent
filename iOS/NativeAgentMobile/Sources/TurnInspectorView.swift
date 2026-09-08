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
        List {
            switch TurnInspectorPresentation.contentState(for: store.file) {
            case .content(let truncated, let visibleCount, let totalCount):
                if truncated {
                    Section {
                        Text(TurnInspectorPresentation.truncationNotice(
                            visibleCount: visibleCount,
                            totalCount: totalCount
                        ))
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .listRowSeparator(.hidden)
                    }
                }
                Section {
                    ForEach(store.file?.summaries ?? []) { summary in
                        TurnSummaryRow(summary: summary)
                    }
                } header: {
                    Label("Turns", systemImage: "list.bullet.rectangle")
                        .font(.headline)
                }
            case .unpublished:
                MobileReadingEmptyState(
                    title: "Turn summaries unavailable",
                    systemImage: "waveform.path.ecg",
                    kind: .unavailable,
                    description: "The Mac has not published a turn-summary snapshot yet."
                )
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
            case .emptyPublished:
                MobileReadingEmptyState(
                    title: "No turns yet",
                    systemImage: "waveform.path.ecg",
                    kind: .empty,
                    description: "The latest published snapshot contains no turns."
                )
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
            }
        }
        .mobileReadingScreen()
        .navigationTitle("Turn Inspector")
        .macSyncErrorBanner()
        // E6: freshness of the Mac snapshot behind these turns.
        .macSnapshotFreshnessBadge()
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .top, spacing: 0) {
                MacStatusChip().frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 16)
            }
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

    private var kindsText: String {
        TurnInspectorPresentation.kindsText(summary.kinds)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            MobileAdaptiveRow {
                Text(summary.startedAt, style: .time)
                    .font(.callout)
                Spacer()
                if let surface = summary.surface, !surface.isEmpty {
                    Text(surface)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            MobileAdaptiveRow(spacing: 12) {
                ForEach(TurnInspectorPresentation.metrics(for: summary), id: \.label) { metric in
                    self.metric(metric.value, metric.label)
                }
            }
            if !summary.kinds.isEmpty {
                Text(kindsText)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel("Event kinds: \(kindsText)")
            }
        }
        .padding(.vertical, 2)
    }

    private func metric(_ value: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(value).font(.callout)
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
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
            file?.summaries = MobileDesignSamples.rows([TurnSummaryRecord]())
            file?.totalTurnsSeen = 1
            return
        }
        #endif
        await iCloudSyncEngine.shared.refreshTurnSummariesSnapshot()
        file = iCloudSyncEngine.shared.turnSummaries
    }

    func applySyncedFile(_ next: TurnSummaryFile?) {
        file = next
    }
}
