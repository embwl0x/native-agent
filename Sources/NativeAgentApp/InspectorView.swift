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
// (TurnInspectorModel.swift). This view only renders cards and owns the
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
                Text("Turn Inspector")
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
                .frame(width: 180)
                .labelsHidden()
            }

            HStack(spacing: NativeAgentSpacing.md) {
                if store.mode == .live {
                    Text("Live readout of everything processed per turn")
                        .font(NativeAgentFont.label)
                        .foregroundStyle(.secondary)
                    Spacer()
                    if store.liveDropCount > 0 {
                        Label("\(store.liveDropCount) dropped", systemImage: "exclamationmark.triangle")
                            .font(NativeAgentFont.tag)
                            .foregroundStyle(.orange)
                            .help("Bus dropped events because the UI consumed too slowly — the turn was never slowed.")
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
                    if store.replaySkipped > 0 {
                        Text("\(store.replaySkipped) unreadable rows skipped")
                            .font(NativeAgentFont.tag)
                            .foregroundStyle(.orange)
                    }
                    Spacer()
                    Text("Replays persisted turns from data/turn_traces")
                        .font(NativeAgentFont.tag)
                        .foregroundStyle(.tertiary)
                }
            }
        }
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        if store.cards.isEmpty {
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
                .foregroundStyle(.tertiary)
            Text(store.mode == .live
                 ? "Waiting for a turn... send the assistant a message to watch it process."
                 : (store.replayFileExists
                    ? "No readable turns recorded for this date."
                    : "No turn trace file for this date."))
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
                VStack(alignment: .leading, spacing: NativeAgentSpacing.xs) {
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
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: NativeAgentRadius.panel, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: NativeAgentRadius.panel, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.07), lineWidth: 1)
        }
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
                .foregroundStyle(.tertiary)
        }
    }
}

// MARK: - EventRowView — one event in a turn

private struct EventRowView: View {
    let row: InspectorEventRow
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
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
                        .foregroundStyle(.tertiary)
                        .monospacedDigit()
                }
                if row.isExpandable {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture { if row.isExpandable { expanded.toggle() } }

            if expanded {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(row.detailLines) { line in
                        HStack(alignment: .top, spacing: NativeAgentSpacing.sm) {
                            Text(line.label)
                                .font(NativeAgentFont.tag)
                                .foregroundStyle(.tertiary)
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
}
