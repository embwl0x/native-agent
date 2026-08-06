import SwiftUI
import PersistenceCore

// MARK: - DeskNagsPanel — User's nag switch, in the UI (C6)
//
// Sweep R4 W5. NagConfig/NagEvaluator shipped with control ONLY via the
// `desk_nag_control` chat tool: User had to ASK Agent to turn his own pressure
// on. This popover is the switch itself.
//
// READS come straight off `DeskNagConfigStore.load()` — the same file the tool
// reads, no cache. WRITES go through `DeskQuickAction.nag*`, which dispatches
// `desk_nag_control` and therefore lands in `impl_desk_nag_control`: same
// flock, same window-bump semantics, same unmute drift digest. Nothing here
// touches DeskNagConfig directly.

struct DeskNagsPanel: View {
    let items: [DeskItem]
    let selectedHandle: String?
    let selectedTitle: String?
    /// Fires the action and, when it lands, hands back the refreshed config.
    let perform: (DeskQuickAction) -> Void
    let config: DeskNagConfig
    let isBusy: Bool

    private var lanes: [DeskNagLane] { DeskNagPanelModel.lanes(items: items, config: config) }

    private var selectedItemScopeOn: Bool {
        guard let selectedHandle else { return false }
        return config.scopes.first { $0.kind == .item && $0.id == selectedHandle }?.enabled ?? false
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            Divider()
            globalRow
            muteRow
            Divider()
            lanesSection
            if let selectedHandle, let selectedTitle {
                Divider()
                selectedItemRow(handle: selectedHandle, title: selectedTitle)
            }
        }
        .padding(16)
        .frame(width: 380)
        .disabled(isBusy)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("Nagging").font(.headline)
            // The honest state line, including the "armed but silent" case —
            // a lane switched on under a global OFF pings nothing, and letting
            // User believe otherwise is the one failure this panel must not have.
            Text(DeskNagPanelModel.summary(config, lanes: lanes, now: Date()))
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var globalRow: some View {
        Toggle(isOn: Binding(
            get: { config.enabled },
            set: { perform(.nagGlobal(on: $0)) }
        )) {
            VStack(alignment: .leading, spacing: 1) {
                Text("Nag me").font(.callout.weight(.medium))
                Text("Master switch. Off means nothing pings, whatever the lanes say.")
                    .font(.caption2).foregroundStyle(.tertiary)
            }
        }
        .toggleStyle(.switch)
    }

    @ViewBuilder
    private var muteRow: some View {
        let muted = config.isMuted(now: Date())
        HStack(spacing: 8) {
            Image(systemName: muted ? "bell.slash.fill" : "bell")
                .font(.callout)
                .foregroundStyle(muted ? Color.orange : Color.secondary)
            if muted {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Snoozed").font(.callout.weight(.medium))
                    Text("Unmuting reports everything that drifted while you were quiet.")
                        .font(.caption2).foregroundStyle(.tertiary)
                }
                Spacer(minLength: 4)
                Button("Wake up") { perform(.nagUnmute) }
            } else {
                Text("Snooze").font(.callout.weight(.medium))
                Spacer(minLength: 4)
                Menu("Snooze…") {
                    ForEach(DeskNagPanelModel.snoozeOptions(from: Date())) { option in
                        Button(option.label) { perform(.nagMute(until: option.until)) }
                    }
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }
        }
    }

    @ViewBuilder
    private var lanesSection: some View {
        Text("Lanes")
            .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
        if lanes.isEmpty {
            Text("No live projects on the board yet — a lane appears once something is tracked.")
                .font(.caption).foregroundStyle(.tertiary)
        } else {
            // Bounded like every other desk list: a desk with 40 projects must
            // not turn this popover into a scroll marathon.
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(lanes) { lane in
                        Toggle(isOn: Binding(
                            get: { lane.enabled },
                            set: { perform(.nagProject(project: lane.project, on: $0)) }
                        )) {
                            HStack(spacing: 6) {
                                Text(lane.project).font(.callout).lineLimit(1)
                                Text("\(lane.itemCount)")
                                    .font(.caption2.weight(.semibold))
                                    .foregroundStyle(.tertiary)
                            }
                        }
                        .toggleStyle(.switch)
                        .controlSize(.small)
                    }
                }
            }
            .frame(maxHeight: 180)
        }
    }

    private func selectedItemRow(handle: String, title: String) -> some View {
        Toggle(isOn: Binding(
            get: { selectedItemScopeOn },
            set: { perform(.nagItem(handle: handle, on: $0)) }
        )) {
            VStack(alignment: .leading, spacing: 1) {
                Text("Just this item").font(.callout.weight(.medium))
                Text(title).font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
            }
        }
        .toggleStyle(.switch)
        .controlSize(.small)
    }
}
