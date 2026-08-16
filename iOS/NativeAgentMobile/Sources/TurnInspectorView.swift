// Turn Inspector W4 — iOS read-only inspector.
//
// Renders the per-turn SUMMARY records the Mac writes into the iCloud snapshot
// (`turn_summaries.json`). Read-only by design: no event stream, no content —
// only time, surface, event count, tokens, ttft, duration, and the per-kind mix.
// Functional-first (W5 is the pizzazz wave). Newest turn on top (the Mac lane
// already orders newest-started-first; we render as-given).
import SwiftUI
import NativeAgentShared

struct TurnInspectorView: View {
    @StateObject private var store = TurnInspectorStore()
    @ObservedObject private var sync = iCloudSyncEngine.shared

    var body: some View {
        List {
            if let file = store.file, !file.summaries.isEmpty {
                if file.truncated {
                    Section {
                        Text("Showing \(file.summaries.count) of \(file.totalTurnsSeen) turns (oldest dropped for sync size).")
                            .font(AppFont.label)
                            .foregroundStyle(.secondary)
                            .listRowSeparator(.hidden)
                    }
                }
                Section {
                    ForEach(file.summaries) { summary in
                        TurnSummaryRow(summary: summary)
                    }
                } header: {
                    Label("Turns", systemImage: "list.bullet.rectangle")
                        .font(AppFont.section)
                }
            } else {
                AppEmptyState(
                    title: "No turns yet",
                    systemImage: "waveform.path.ecg",
                    description: "Per-turn summaries appear here after \(sync.agentDisplayName) processes a turn on the Mac and syncs."
                )
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
            }
        }
        .navigationTitle("Turn Inspector")
        .navigationBarTitleDisplayMode(.inline)
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

    private var durationText: String {
        let s = Double(summary.wallMs) / 1000.0
        if s < 1 { return "\(summary.wallMs) ms" }
        return String(format: "%.1f s", s)
    }

    private var kindsText: String {
        // Stable, compact "kind ×count" list, sorted by count desc then name.
        summary.kinds
            .sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
            .map { "\(shortKind($0.key)) ×\($0.value)" }
            .joined(separator: " · ")
    }

    private func shortKind(_ k: String) -> String {
        if let dot = k.firstIndex(of: ".") { return String(k[k.index(after: dot)...]) }
        return k
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(summary.startedAt, style: .time)
                    .font(AppFont.label)
                Spacer()
                if let surface = summary.surface, !surface.isEmpty {
                    Text(surface)
                        .font(AppFont.tag)
                        .foregroundStyle(.secondary)
                }
            }
            HStack(spacing: 12) {
                metric("\(summary.eventCount)", "events")
                metric(durationText, "wall")
                if let tokens = summary.llmTokens {
                    metric("\(tokens)", "tok")
                }
                if let ttft = summary.ttftMs {
                    metric("\(ttft) ms", "ttft")
                }
            }
            if !summary.kinds.isEmpty {
                Text(kindsText)
                    .font(AppFont.mono)
                    .foregroundStyle(.tertiary)
                    .lineLimit(2)
            }
        }
        .padding(.vertical, 2)
    }

    private func metric(_ value: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(value).font(AppFont.label)
            Text(label).font(AppFont.tag).foregroundStyle(.secondary)
        }
    }
}

// MARK: - Store

@MainActor
final class TurnInspectorStore: ObservableObject {
    @Published var file: TurnSummaryFile?

    func refresh() async {
        await iCloudSyncEngine.shared.refreshTurnSummariesSnapshot()
        file = iCloudSyncEngine.shared.turnSummaries
    }

    func applySyncedFile(_ next: TurnSummaryFile?) {
        file = next
    }
}
