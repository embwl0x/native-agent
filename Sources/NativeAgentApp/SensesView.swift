import AppKit
import SwiftUI
import Senses

/// These owners have no complete push invalidation contract yet. Sample only
/// while the page is visible; no file paths or private ledger format are assumed.
@MainActor
@Observable
final class SensesSurfaceState {
    var records: [SenseRecord] = []
    var surfaceNames: [SenseCorner: String] = [:]
    var news: [SenseNews] = []
    var interactiveView: SenseInteractiveView?
    var isWired = false
    var loaded = false
    var saving: Set<String> = []
    /// A switch or share that failed; the read's own failure is `readError`,
    /// cleared by the next good read.
    var error: String?
    var readError: String?
    @ObservationIgnored private var refreshGeneration = 0

    func refresh() async {
        refreshGeneration &+= 1
        let generation = refreshGeneration
        let hub = SensesHub.shared
        let wired = hub.registry != nil
        if isWired != wired { isWired = wired }
        async let news = SenseNewsBoard.shared.latest(limit: SenseNewsBoard.capacity)
        async let view = SenseNewsBoard.shared.interactiveView()
        do {
            let (sorted, names) = try await hub.presentationRecords()
            guard generation == refreshGeneration, !Task.isCancelled else { return }
            if self.records != sorted { self.records = sorted }
            if surfaceNames != names { surfaceNames = names }
            if readError != nil { readError = nil }
        } catch {
            guard generation == refreshGeneration, !Task.isCancelled else { return }
            let message = "Senses registry unavailable: \(error.localizedDescription)"
            if readError != message { readError = message }
        }
        let latest = Array((await news).prefix(12))
        let nextView = await view
        guard generation == refreshGeneration, !Task.isCancelled else { return }
        if self.news != latest { self.news = latest }
        if let view = nextView, view.isCurrent(in: self.records) {
            if interactiveView != view { interactiveView = view }
        } else {
            if interactiveView != nil { interactiveView = nil }
        }
        if !loaded { loaded = true }
    }

    func observe() async {
        while !Task.isCancelled {
            await refresh()
            do { try await Task.sleep(for: .seconds(5)) } catch { return }
        }
    }

    func setEnabled(_ enabled: Bool, record: SenseRecord) async {
        guard saving.insert(record.id).inserted else { return }
        defer { saving.remove(record.id) }
        guard let registry = SensesHub.shared.registry as? any SenseRegistryManaging else {
            error = "Senses are not connected yet."
            return
        }
        do {
            _ = try await registry.setStatus(id: record.id, version: record.version, status: enabled ? .on : .off,
                                             preview: false, ownerAuthorized: true)
            error = nil
        } catch {
            self.error = "I couldn't save this switch: \(error.localizedDescription)"
        }
        await refresh()
    }

    /// Called only by User's native Share button and destination picker.
    func export(_ record: SenseRecord) async {
        guard saving.insert(record.id).inserted else { return }
        defer { saving.remove(record.id) }
        guard let registry = SensesHub.shared.registry as? any SenseRegistryManaging else {
            error = "Senses are not connected yet."
            return
        }
        let panel = NSSavePanel()
        panel.title = "Share sense"
        panel.nameFieldStringValue = "\(record.id).sense.json"
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        do {
            _ = try await registry.exportBundle(id: record.id, to: destination, userApproved: true)
            error = nil
        } catch {
            self.error = "I couldn't share this sense: \(error.localizedDescription)"
        }
    }
}

struct SensesView: View {
    @State private var state = SensesSurfaceState()

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
        .liveTask { await state.observe() }
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
                Button("Share sense…") { Task { await state.export(record) } }
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
