import AppKit
import SwiftUI
import Senses
import EngineRuntime
// Blueprint: | `SensesView.swift` | `SensesView`; engine Senses projection, lifecycle controls and native share picker |


struct SensesView: View {
    @Environment(AppModel.self) private var appModel
    private var state: SensesFacade { appModel.engine.senses }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AliveMetrics.sectionSpacing) {
                Text("These are the ways I read your apps, files, sites and streams.")
                    .font(ShellType.label)
                    .foregroundStyle(NativeAgentShell.secondary)
                if let error = state.readError {
                    Text(error).font(ShellType.label).foregroundStyle(NativeAgentShell.trouble)
                }
                if let error = state.error {
                    Text(error).font(ShellType.label).foregroundStyle(NativeAgentShell.trouble)
                }
                AdvancedSection(title: "Senses", card: .single) {
                    if !state.loaded {
                        AdvancedWaitingLine("Reading senses…")
                    } else if !state.isWired {
                        AdvancedEmptyState(title: "Senses are not connected yet.")
                    } else if state.records.isEmpty, state.readError == nil {
                        AdvancedEmptyState(title: "No senses yet.")
                    } else {
                        LazyVStack(alignment: .leading, spacing: 12) {
                            ForEach(state.records, id: \.id) { record in
                                if let surfaceName = state.surfaceNames[record.corner] {
                                    senseRow(record, surfaceName: surfaceName)
                                }
                                if record.id != state.records.last?.id { Divider() }
                            }
                        }
                    }
                }
                AdvancedSection(title: "Just changed", card: .single) {
                    if state.news.isEmpty {
                        Text("No recent changes.")
                    }
                    ForEach(Array(state.news.enumerated()), id: \.offset) { _, news in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(news.summary)
                            Text("\(news.senseID) · v\(news.version)")
                                .font(ShellType.caption).foregroundStyle(NativeAgentShell.secondary)
                        }
                    }
                }
            }
            .font(ShellType.label)
            .padding(.bottom, 32)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .navigationTitle("Senses")
        .quietReadTask(live: false) { await state.refresh() }
    }

    private func senseRow(_ record: SenseRecord, surfaceName: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle(isOn: Binding(get: { record.status == .on }, set: { enabled in
                Task { await state.setEnabled(enabled, record: record) }
            })) {
                Text("\(surfaceName) · v\(record.version)")
                    .font(ShellType.labelMedium)
            }
            .toggleStyle(.switch)
            .disabled(record.status == .draft || state.saving.contains(record.id))
            .accessibilityIdentifier("senses.switch.\(record.id)")
            HStack {
                Text(record.status == .unavailable ? "Unavailable" : record.status == .draft ? "Not ready yet" : record.status == .on ? "On" : "Off")
                Text(origin(record.origin))
                Text("\(record.uses) uses · \(record.corrections) corrections")
            }
            .foregroundStyle(NativeAgentShell.secondary)
            if let reason = record.unavailableReason { Text(reason).foregroundStyle(NativeAgentShell.secondary) }
            HStack {
                Text("Last use:")
                if let lastUsed = record.lastUsedAt { Text(lastUsed, style: .relative) }
                else { Text("Never") }
                Spacer()
                Text(cost(record))
            }
            .font(ShellType.caption).foregroundStyle(NativeAgentShell.secondary)
            if record.language != .native {
                Button("Share sense…") {
                    Task {
                        await state.export(record) {
                            let panel = NSSavePanel()
                            panel.title = "Share sense"
                            panel.nameFieldStringValue = "\(record.id).sense.json"
                            return panel.runModal() == .OK ? panel.url : nil
                        }
                    }
                }
                    .disabled(state.saving.contains(record.id))
                    .accessibilityIdentifier("senses.share.\(record.id)")
            }
        }
        .textSelection(.enabled)
    }

    private func cost(_ record: SenseRecord) -> String {
        if record.origin == .builtIn && record.version == 1 { return "Growth cost: $0" }
        guard let cost = record.growthCostUSD, cost.isFinite, cost >= 0 else {
            return "Growth cost: not recorded"
        }
        return "Growth cost: " + cost.formatted(.currency(code: "USD"))
    }

    private func origin(_ origin: SenseOrigin) -> String {
        switch origin { case .builtIn: "Built in"; case .grown: "Grown"; case .shared: "Shared" }
    }

}
