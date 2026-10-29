import SwiftUI
import PersistenceCore
import Desk

// Blueprint: | `DeskNagsPanel.swift` | `DeskNagsPanel`: current nag configuration reads and explicit owner controls through Desk quick actions |

// MARK: - Desk nag controls
//
// Reads use the supplied Desk revision from DeskFacade.readRevision().
// DeskQuickAction.nag* dispatches desk_nag_control; its store owns locked
// mutations, window bumps and unmute drift summaries.

struct DeskNagsPanel: View {
    let items: [DeskItem]
    let selectedHandle: String?
    let selectedTitle: String?
    /// Dispatches the action; Desk refresh supplies the resulting configuration.
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
            // An enabled lane stays silent while the global switch is off.
            Text(DeskNagPanelModel.summary(config, items: items, now: Date()))
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
                Text("Master switch. Off silences all reminders, regardless of each project's settings.")
                    .font(.caption2).foregroundStyle(.tertiary)
            }
        }
        .toggleStyle(.switch)
        .hazeTinted()
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
        Text("Projects")
            .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
        if lanes.isEmpty {
            Text("No live projects on the board yet — a project appears once something is tracked.")
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
                        .hazeTinted()
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
        .hazeTinted()
        .controlSize(.small)
    }
}
