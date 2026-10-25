import DoctorChecks
import NativeAgentCore
import PersistenceCore
import Foundation
import Observation
import TurnTrace
import SwiftUI

// Blueprint: | `InspectorView.swift` | `InspectorView` and `TurnInspectorStore`: per-window live/replay selection over engine traces with separate requested/displayed date provenance |

// MARK: - Turn Inspector W3 — the Mac "Inspector" tab
//
// Cards and replay reads come from the engine's trace projection. Each
// window owns only its mode, selected replay date and presentation result.

struct InspectorView: View {
    let feed: TurnInspectorFeed
    @State private var store = TurnInspectorStore()

    var body: some View {
        VStack(alignment: .leading, spacing: NativeAgentSpacing.md) {
            header
            Divider()
            content
        }
        .padding(NativeAgentSpacing.lg)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .task {
            store.start(feed: feed)
        }
        .onDisappear {
            store.stop()
        }
    }

    // MARK: Header — mode picker + per-mode controls

    private var header: some View {
        VStack(alignment: .leading, spacing: NativeAgentSpacing.sm) {
            HStack(spacing: NativeAgentSpacing.md) {
                Text("Chat turn details")
                    .font(NativeAgentFont.title)
                Spacer()
                Picker("", selection: Binding(
                    get: { store.mode },
                    set: { store.setMode($0) }
                )) {
                    ForEach(TurnInspectorStore.Mode.allCases) { m in
                        Text(m.rawValue).tag(m)
                    }
                }
                .pickerStyle(.segmented)
                .hazeTinted(.segments)
                .frame(width: 180)
                .labelsHidden()
            }

            HStack(spacing: NativeAgentSpacing.md) {
                if store.mode == .live {
                    Text("What happens during each message, as it happens")
                        .font(NativeAgentFont.label)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Clear", systemImage: "trash") { store.clearLive() }
                        .controlSize(.small)
                } else {
                    DatePicker(
                        "Date",
                        selection: Binding(
                            get: { store.replayDate },
                            set: { newDate in Task { await store.loadReplay(for: newDate) } }
                        ),
                        displayedComponents: .date
                    )
                    .datePickerStyle(.field)
                    .labelsHidden()
                    if store.replayLoading {
                        ProgressView().controlSize(.small)
                    }
                    Text(store.replayPresentation.statusText)
                        .font(NativeAgentFont.label)
                        .foregroundStyle(.secondary)
                    if store.replaySkipped > 0 {
                        Text("\(store.replaySkipped) unreadable rows skipped")
                            .font(NativeAgentFont.tag)
                            .foregroundStyle(.orange)
                    }
                    if let issue = store.replayReadIssue {
                        Text(issue).font(NativeAgentFont.tag).foregroundStyle(.orange)
                    }
                    Spacer()
                    Text("Shows saved turns from an earlier day")
                        .font(NativeAgentFont.tag)
                        .foregroundStyle(NativeAgentShell.secondary)
                }
            }
        }
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        if store.mode == .live, let issue = feed.readIssue {
            Text(issue).foregroundStyle(.orange)
        }
        if store.mode == .replay, store.cards.isEmpty, store.replayPresentation.isLoading {
            ProgressView(store.replayPresentation.statusText)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if store.cards.isEmpty {
            emptyState
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: NativeAgentSpacing.md) {
                    ForEach(store.cards) { card in
                        TurnCardView(card: card)
                    }
                }
                .padding(.vertical, NativeAgentSpacing.xs)
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: NativeAgentSpacing.sm) {
            Image(systemName: store.mode == .live ? "waveform.path.ecg" : "calendar.badge.clock")
                .font(.largeTitle)
                .foregroundStyle(NativeAgentShell.secondary)
            Text(store.mode == .live
                 ? "Waiting for a turn — send a message to watch it happen."
                 : (store.replayReadIssue ?? (store.replayFileExists
                    ? "No readable turns recorded for this date."
                    : "Nothing was saved for this date.")))
                .font(NativeAgentFont.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - TurnCardView — one turn

private struct TurnCardView: View {
    let card: InspectorTurnCard
    @State private var expanded = true

    var body: some View {
        VStack(alignment: .leading, spacing: NativeAgentSpacing.sm) {
            DisclosureGroup(isExpanded: $expanded) {
                LazyVStack(alignment: .leading, spacing: NativeAgentSpacing.xs) {
                    ForEach(card.rows) { row in
                        EventRowView(row: row)
                    }
                }
                .padding(.top, NativeAgentSpacing.xs)
            } label: {
                summaryLine
                    .togglesDisclosure($expanded)
            }
        }
        .padding(NativeAgentSpacing.md)
        // Alive glass (2026-09-23): a fill, never glass, on the content layer.
        .aliveCard(radius: NativeAgentRadius.panel)
    }

    private var summaryLine: some View {
        HStack(spacing: NativeAgentSpacing.sm) {
            if let surface = card.surface {
                StatusBadge(text: surface, status: "info")
            }
            Text("\(card.eventCount) events")
                .font(NativeAgentFont.label)
            if let tokens = card.llmTokens {
                Label("\(tokens) tok", systemImage: "cpu")
                    .font(NativeAgentFont.tag)
                    .foregroundStyle(.secondary)
            }
            if let ttft = card.ttftMs {
                Label("\(ttft)ms ttft", systemImage: "bolt")
                    .font(NativeAgentFont.tag)
                    .foregroundStyle(.secondary)
            }
            Label("\(card.wallMs)ms", systemImage: "clock")
                .font(NativeAgentFont.tag)
                .foregroundStyle(.secondary)
            Spacer()
            Text(card.id.prefix(8))
                .font(NativeAgentFont.mono)
                .foregroundStyle(NativeAgentShell.secondary)
        }
    }
}

// MARK: - EventRowView — one event in a turn

private struct EventRowView: View {
    let row: InspectorEventRow
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            if row.isExpandable {
                Button {
                    expanded.toggle()
                } label: {
                    eventHeader
                }
                .buttonStyle(.plain)
                .accessibilityValue(expanded ? "Expanded" : "Collapsed")
                .accessibilityHint(expanded ? "Collapses event details" : "Shows event details")
            } else {
                eventHeader
            }

            if expanded {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(row.detailLines) { line in
                        HStack(alignment: .top, spacing: NativeAgentSpacing.sm) {
                            Text(line.label)
                                .font(NativeAgentFont.tag)
                                .foregroundStyle(NativeAgentShell.secondary)
                                .frame(width: 96, alignment: .leading)
                            Text(line.value)
                                .font(NativeAgentFont.mono)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
                .padding(.leading, 22)
                .padding(.vertical, 2)
            }
        }
    }

    private var eventHeader: some View {
        HStack(spacing: NativeAgentSpacing.sm) {
            InlineStatusDot(status: row.status.themeStatus)
            Text(row.kindChip)
                .font(NativeAgentFont.tag)
                .foregroundStyle(.secondary)
                .frame(width: 78, alignment: .leading)
            Text(row.title)
                .font(NativeAgentFont.label)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
            if let ms = row.durationMs {
                Text("\(ms)ms")
                    .font(NativeAgentFont.tag)
                    .foregroundStyle(NativeAgentShell.secondary)
                    .monospacedDigit()
            }
            if row.isExpandable {
                Image(systemName: expanded ? "chevron.down" : "chevron.right")
                    .font(.caption2)
                    .foregroundStyle(NativeAgentShell.secondary)
            }
        }
        .contentShape(Rectangle())
    }
}


/// Requested replay dates and displayed evidence have separate provenance.
/// A slow read may retain useful cards, but never relabel them as the new day.
enum TurnInspectorReplayPresentation: Equatable {
    case loading(requested: Date, retained: Date?)
    case loaded(Date)

    static func resolve(requested: Date, loaded: Date?, isLoading: Bool) -> Self {
        guard !isLoading, let loaded else { return .loading(requested: requested, retained: loaded) }
        return .loaded(loaded)
    }

    var isLoading: Bool {
        if case .loading = self { return true }
        return false
    }

    var statusText: String {
        switch self {
        case let .loading(requested, retained):
            let loading = "Loading the turns from \(requested.formatted(date: .abbreviated, time: .omitted))…"
            guard let retained else { return loading }
            return "\(loading) Showing the turns from \(retained.formatted(date: .abbreviated, time: .omitted))."
        case let .loaded(date):
            return "Showing the turns from \(date.formatted(date: .abbreviated, time: .omitted))."
        }
    }
}

// Each window keeps its mode, replay selection and display filter.
@MainActor
@Observable
final class TurnInspectorStore {
    enum Mode: String, CaseIterable, Identifiable {
        case live = "Live"
        case replay = "Replay"
        var id: String { rawValue }
    }

    private(set) var mode: Mode = .live
    var cards: [InspectorTurnCard] {
        if mode == .replay { return replayCards }
        return feed?.cards(after: clearBefore) ?? []
    }
    private var clearBefore: Date?
    private var replayCards: [InspectorTurnCard] = []
    private(set) var replayDate = Date()
    private(set) var replaySkipped = 0
    private(set) var replayLoading = false
    private(set) var replayFileExists = true
    private(set) var replayLoadedDate: Date?
    @ObservationIgnored private let replayRead = LatestRead()
    private(set) var replayReadIssue: String?
    private(set) var feed: TurnInspectorFeed?

    var replayPresentation: TurnInspectorReplayPresentation {
        .resolve(requested: replayDate, loaded: replayLoadedDate, isLoading: replayLoading)
    }

    func start(feed: TurnInspectorFeed) {
        self.feed = feed
        feed.start()
        TurnInspectorDoctor.active = self
    }

    func stop() {
        if TurnInspectorDoctor.active === self { TurnInspectorDoctor.active = nil }
    }

    func setMode(_ newMode: Mode) {
        guard newMode != mode else { return }
        mode = newMode
        if newMode == .replay { Task { await loadReplay(for: replayDate) } }
    }

    func clearLive() { clearBefore = Date() }

    /// The engine returns grouped evidence; only this window's newest selection
    /// may publish it, so overlapping replay dates cannot relabel old cards.
    func loadReplay(for date: Date) async {
        guard let feed else { return }
        replayDate = date
        replayLoading = true
        _ = await replayRead.read { () -> Result<(exists: Bool, report: JSONLReadReport, cards: [InspectorTurnCard]), Error> in
            do { return Result.success(try await feed.loadReplay(for: date)) }
            catch { return Result<(exists: Bool, report: JSONLReadReport, cards: [InspectorTurnCard]), Error>.failure(error) }
        } publish: { result in
            switch result {
            case .success(let read):
                replayCards = read.cards
                replayFileExists = read.exists
                replaySkipped = read.report.malformedLineCount
                replayReadIssue = read.report.trailingPartialLine ? "The final trace row is incomplete." : nil
                replayLoadedDate = date
            case .failure(let error): replayReadIssue = error.localizedDescription
            }
            replayLoading = false
        }
    }
}


@MainActor
enum TurnInspectorDoctor {
    static weak var active: TurnInspectorStore?

    static func check() -> CheckResult {
        InspectorFeedHealth.check(
            isOpen: active != nil, observationActive: active?.feed?.observationActive ?? false
        )
    }

    static func repairDeadSink() -> DoctorRepairAttempt {
        guard let feed = active?.feed, !feed.observationActive else {
            return .unverified("Repair skipped: Inspector trace observation is already active or the page is closed.")
        }
        feed.stop()
        feed.start()
        return .completed("Completed: re-armed Inspector trace observation; its state will be confirmed on the next Doctor read.")
    }
}
