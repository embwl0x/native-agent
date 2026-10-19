import DoctorChecks
import Foundation
import Observation
import TurnTrace
import SwiftUI
import PersistenceCore

// MARK: - Turn Inspector W3 — the Mac "Inspector" tab
//
// A live cascading per-turn timeline (subscribe to TurnTraceBus on open,
// unsubscribe on close) + a replay mode that loads a persisted per-day
// turn_traces JSONL. FUNCTIONAL FIRST — plain panel styling matching the
// app's existing Advanced surfaces (DoctorView etc.); the graphical pizzazz
// mode is W5, user-gated.
//
// All grouping/ordering/summary logic lives in TurnInspectorGrouping
// (TurnTraceReadProjection.swift). This view renders cards and owns the
// subscription lifecycle via TurnInspectorStore.

struct InspectorView: View {
    @State private var store = TurnInspectorStore()

    var body: some View {
        VStack(alignment: .leading, spacing: NativeAgentSpacing.md) {
            header
            Divider()
            content
        }
        .padding(NativeAgentSpacing.lg)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        // Lifecycle: subscribe on open, UNSUBSCRIBE on close (no leaked sinks).
        .task {
            store.start()
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
                    if let dropLabel = TurnInspectorLiveDropPresentation.label(
                        for: store.liveDropCountState
                    ) {
                        Label(dropLabel, systemImage: "exclamationmark.triangle")
                            .font(NativeAgentFont.tag)
                            .foregroundStyle(.orange)
                            .help("Some steps were dropped because this page could not keep up. An unavailable count means the feed ended before it could be measured. The message itself was never slowed down.")
                    }
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
                 : (store.replayFileExists
                    ? "No readable turns recorded for this date."
                    : "Nothing was saved for this date."))
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


/// The inspector must distinguish a quiet live feed from one that lost events
/// under its own backpressure. Keep the visible wording in the same boundary
/// that owns the bus-derived count so zero and invalid values never render a
/// misleading warning chip.
enum TurnInspectorLiveDropPresentation {
    static func label(for dropCount: Int) -> String? {
        guard dropCount > 0 else { return nil }
        return "\(dropCount) steps dropped"
    }

    static func label(for state: TurnInspectorLiveDropState) -> String? {
        switch state {
        case .measured(let dropCount):
            return label(for: dropCount)
        case .unavailable:
            return "dropped steps unavailable"
        }
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

// Tab lifecycle, selected replay date and coalesced presentation of core evidence.

@MainActor
@Observable
final class TurnInspectorStore {

    enum Mode: String, CaseIterable, Identifiable {
        case live = "Live"
        case replay = "Replay"
        var id: String { rawValue }
    }

    // MARK: Observed state

    private(set) var mode: Mode = .live
    /// Newest-turn-first cards for the current mode's events.
    private(set) var cards: [InspectorTurnCard] = []
    /// Live drop count from the bus subscription (slow-consumer signal), with
    /// its availability: an unknown count is never rendered as zero.
    var liveDropCountState: TurnInspectorLiveDropState { feed.liveDropCountState }
    var liveSinkActive: Bool { feed.liveSinkActive }
    /// Replay diagnostics.
    private(set) var replayDate: Date = Date()
    private(set) var replaySkipped: Int = 0
    private(set) var replayLoading = false
    private(set) var replayFileExists = true
    private(set) var replayLoadedDate: Date?

    var replayPresentation: TurnInspectorReplayPresentation {
        .resolve(requested: replayDate, loaded: replayLoadedDate, isLoading: replayLoading)
    }

    private let feed: TurnInspectorFeed

    init(dataRootOverride: URL? = nil) {
        feed = TurnInspectorFeed(dataRootOverride: dataRootOverride)
        feed.onEventsChanged = { [weak self] in
            guard let self, self.mode == .live else { return }
            self.scheduleCardsRefresh()
        }
    }

    func start() {
        if feed.start() { TurnInspectorDoctor.active = self }
    }

    func stop() {
        if TurnInspectorDoctor.active === self { TurnInspectorDoctor.active = nil }
        feed.stop()
        flushPendingCardsRefresh()
    }

    // MARK: Mode switching

    func setMode(_ newMode: Mode) {
        guard newMode != mode else { return }
        // A live-ingest debounce still in flight would fire under the NEW mode
        // and regroup the wrong source. Drop it; both branches below recompute.
        cancelPendingCardsRefresh()
        mode = newMode
        cards = []
        if newMode == .replay {
            // Live cards are not evidence from this replay date. Restore only
            // the last loaded replay while its refresh is pending.
            recomputeCards()
            Task { await loadReplay(for: replayDate) }
        } else {
            recomputeCards()
        }
    }

    func clearLive() {
        // User-initiated: the list must empty NOW, not up to a debounce later.
        cancelPendingCardsRefresh()
        feed.clearLive()
        if mode == .live { recomputeCards() }
    }

    // MARK: Replay

    /// Load the persisted per-day file for `date`, off the main actor, and
    /// regroup. Parse failures are skipped (counted), an absent file is an
    /// empty (not error) state. A generation token guards against overlapping
    /// loads (rapid date changes) applying out of order — only the NEWEST
    /// in-flight load is allowed to mutate state.
    func loadReplay(for date: Date) async {
        if mode == .replay {
            groupingTask?.cancel()
            groupingGeneration &+= 1
        }
        replayDate = date
        replayLoading = true
        guard let result = await feed.loadReplay(for: date) else { return }
        replayFileExists = result.exists
        replaySkipped = result.skipped
        if mode == .replay {
            // Same reason as `setMode`: a live-ingest debounce landing after
            // this would regroup with the wrong source.
            cancelPendingCardsRefresh()
            recomputeCards { [weak self] in
                self?.replayLoadedDate = date
                self?.replayLoading = false
            }
        } else {
            replayLoadedDate = date
            replayLoading = false
        }
    }

    // MARK: Card recompute

    /// Coalesce card rendering while the feed retains each incoming event.
    private static let cardsDebounceSeconds: TimeInterval = 0.1
    private var cardsRefreshScheduled = false
    private var cardsRefreshTask: Task<Void, Never>?

    private func scheduleCardsRefresh() {
        guard !cardsRefreshScheduled else { return }
        cardsRefreshScheduled = true
        cardsRefreshTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.cardsDebounceSeconds * 1_000_000_000))
            guard let self, !Task.isCancelled else { return }
            self.cardsRefreshTask = nil
            self.cardsRefreshScheduled = false
            self.recomputeCards()
        }
    }

    /// Drop a pending window without regrouping. The caller is about to
    /// recompute (or replace the source) itself.
    private func cancelPendingCardsRefresh() {
        cardsRefreshTask?.cancel()
        cardsRefreshTask = nil
        cardsRefreshScheduled = false
    }

    /// Drop a pending window and apply it immediately.
    private func flushPendingCardsRefresh() {
        guard cardsRefreshScheduled else { return }
        cancelPendingCardsRefresh()
        recomputeCards()
    }

    @ObservationIgnored private var groupedEvents: [String: [TurnTraceEvent]] = [:]
    @ObservationIgnored private var groupingTask: Task<Void, Never>?
    @ObservationIgnored private var groupingGeneration: UInt64 = 0

    private func recomputeCards(onPublish: (@MainActor () -> Void)? = nil) {
        groupingTask?.cancel()
        groupingGeneration &+= 1
        let generation = groupingGeneration
        let source = (mode == .live) ? feed.liveEvents : feed.replayEvents
        guard !source.isEmpty else {
            groupedEvents = [:]
            cards = []
            onPublish?()
            return
        }
        let previous = groupedEvents
        let retained = cards
        groupingTask = Task { [weak self] in
            let worker = Task.detached(priority: .userInitiated) {
                TurnInspectorGrouping.updating(source, previous: previous, cards: retained)
            }
            let result = await withTaskCancellationHandler {
                await worker.value
            } onCancel: {
                worker.cancel()
            }
            guard let self, !Task.isCancelled, generation == self.groupingGeneration else { return }
            self.groupedEvents = result.events
            if self.cards != result.cards { self.cards = result.cards }
            self.groupingTask = nil
            onPublish?()
        }
    }
}


@MainActor
enum TurnInspectorDoctor {
    static weak var active: TurnInspectorStore?

    static func check() -> CheckResult {
        InspectorFeedHealth.check(
            isOpen: active != nil, sinkActive: active?.liveSinkActive ?? false,
            dropCount: dropCount
        )
    }

    private static var dropCount: Int? {
        guard let store = active, case .measured(let count) = store.liveDropCountState else { return nil }
        return count
    }

    static func repairDeadSink() -> DoctorRepairAttempt {
        guard let store = active, InspectorFeedHealth.canRepair(isOpen: true, dropCount: dropCount) else {
            return .unverified("Repair skipped: the Inspector sink is no longer terminated.")
        }
        store.stop()
        store.start()
        return .completed("Completed: restarted the Inspector subscription task; the sink will be confirmed on the next Doctor read.")
    }
}
