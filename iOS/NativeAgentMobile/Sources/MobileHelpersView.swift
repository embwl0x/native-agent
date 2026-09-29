import SwiftUI
import NativeAgentShared

struct MobileHelpersView: View {
    @ObservedObject private var sync = iCloudSyncEngine.shared
    @EnvironmentObject private var pairing: PairingStore
    @State private var error: String?

    var body: some View {
        AlivePage(title: "Helpers", line: "Small jobs, with their own brief and timing.") {
            if !pairing.isPaired { AliveUnpairedReason() }
            if let error = sync.staleSnapshotGroups["helpers_agents"] ?? error {
                AliveSection("Couldn’t refresh helpers") { Text(error).aliveRow() }
            }
            AliveSection("Helpers") {
                NavigationLink("New helper") { MobileHelperEditorView(helperID: nil) }
                    .aliveRow().disabled(!pairing.isPaired)
                if let snapshot = sync.helpersSnapshot {
                    if snapshot.helpers.isEmpty { Text("No helpers yet.").aliveRow() }
                    ForEach(snapshot.helpers) { row in
                        AliveDivider()
                        NavigationLink { MobileHelperDetailView(id: row.id) } label: {
                            AliveRow(row.name, detail: row.status) { AliveChevron() }
                        }.aliveRowButtonStyle()
                    }
                    if snapshot.truncated { Text("Showing the first 100 helpers and agents.").aliveRow() }
                } else {
                    Text("Not yet received from the Mac").aliveRow()
                }
            }
        }
        .macSyncErrorBanner()
        .task { await refresh() }
        .refreshable { await refresh() }
    }

    private func refresh() async {
        error = await sync.refreshHelpersSnapshot() ? nil : "Keep the Mac app open, then pull to refresh."
    }
}

private struct MobileHelperDetailView: View {
    let id: UUID
    @ObservedObject private var sync = iCloudSyncEngine.shared
    @EnvironmentObject private var pairing: PairingStore
    @State private var helper: MobileHelperEdit?
    @State private var busy = false
    @State private var message: String?
    @State private var error: String?
    private var row: MobileHelperRow? { sync.helpersSnapshot?.helpers.first { $0.id == id } }

    var body: some View {
        AlivePage(title: row?.name ?? "Helper", line: row?.status ?? "") {
            if let error { AliveSection("Couldn’t complete the request") { Text(error).aliveRow() } }
            if let message { AliveSection(nil) { Text(message).aliveRow() } }
            if let helper {
                AliveSection("Brief") { Text(helper.brief).textSelection(.enabled).aliveRow() }
            }
            AliveSection("Actions") {
                Button("Run once") { Task { await perform("run_helper") } }.aliveRow()
                if let row, row.canPause {
                    AliveDivider()
                    Button(row.paused ? "Resume" : "Pause") {
                        Task { await perform("pause_helper", extra: ["paused": String(!row.paused)]) }
                    }.aliveRow()
                }
                AliveDivider()
                NavigationLink("Edit") { MobileHelperEditorView(helperID: id) }.aliveRow()
            }.disabled(busy || !pairing.isPaired || helper == nil)
            if busy { ProgressView("Waiting for Mac…").aliveRow() }
        }
        .task { await perform("get_helper") }
        .refreshable { await perform("get_helper") }
    }

    private func perform(_ action: String, extra: [String: String] = [:]) async {
        guard !busy else { return }
        busy = true; error = nil; message = nil
        defer { busy = false }
        do {
            let result = try await sync.helperAction(action, payload: extra.merging(["id": id.uuidString]) { _, new in new })
            helper = result.0; message = result.1["message"]
        } catch { self.error = error.localizedDescription }
    }
}

struct MobileHelperEditorView: View {
    let helperID: UUID?
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var pairing: PairingStore
    @ObservedObject private var sync = iCloudSyncEngine.shared
    @State private var edit = MobileHelperEdit()
    @State private var loaded = false
    @State private var busy = false
    @State private var error: String?
    @State private var clock = Date()
    @State private var weekday = 1
    private var selectedModel: ProviderModelInfo? {
        sync.providers.first { $0.provider_id == edit.provider }?.models.first { $0.id == edit.model }
    }

    var body: some View {
        AlivePage(title: helperID == nil ? "New helper" : "Edit helper", line: "Choose the work, model, timing, and limits.") {
            if let error { AliveSection("Couldn’t save helper") { Text(error).aliveRow() } }
            if !loaded { ProgressView("Loading helper…").aliveRow() }
            AliveSection("Brief") {
                TextField("Name", text: $edit.name).aliveRow()
                AliveDivider()
                TextField("Brief", text: $edit.brief, axis: .vertical).lineLimit(5...12).aliveRow()
            }.disabled(!loaded || busy)
            modelFields.disabled(!loaded || busy)
            timingFields.disabled(!loaded || busy)
            AliveSection("Optional controls") {
                TextField("Output tokens per run", text: $edit.tokens).keyboardType(.numberPad).aliveRow()
                TextField("Seconds per run", text: $edit.seconds).keyboardType(.decimalPad).aliveRow()
                TextField("Daily token reservation", text: $edit.daily).keyboardType(.numberPad).aliveRow()
                Text("Choose execution limits before saving. Output limits do not include hidden reasoning or guarantee billed usage.").aliveRow()
                Toggle("Tell me if", isOn: $edit.tell).aliveRow()
                if edit.tell { TextField("Condition", text: $edit.condition, axis: .vertical).aliveRow() }
            }.disabled(!loaded || busy)
            AliveSection(nil) {
                Button(helperID == nil ? "Create" : "Save") { Task { await save() } }
                    .aliveRow().disabled(!loaded || busy || !pairing.isPaired || edit.name.isEmpty || edit.brief.isEmpty)
                Button("Cancel") { dismiss() }.aliveRow().disabled(busy)
            }
            if busy { ProgressView("Waiting for Mac…").aliveRow() }
        }
        .task { await load() }
    }

    private var modelFields: some View {
        AliveSection("Model") {
            Picker("Provider", selection: $edit.provider) {
                Text("Choose").tag("")
                ForEach(sync.providers.filter { $0.auth_status.state == "ready" }, id: \.provider_id) {
                    Text($0.display_name).tag($0.provider_id)
                }
                if !edit.provider.isEmpty, !sync.providers.contains(where: { $0.provider_id == edit.provider && $0.auth_status.state == "ready" }) {
                    Text(edit.provider + " · unavailable").tag(edit.provider)
                }
            }.aliveRow().onChange(of: edit.provider) { old, _ in
                if loaded, !old.isEmpty { edit.model = ""; edit.think = ""; edit.fast = false }
            }
            Picker("Model", selection: $edit.model) {
                Text("Choose").tag("")
                ForEach(sync.providers.first { $0.provider_id == edit.provider }?.models ?? []) { Text($0.name).tag($0.id) }
                if !edit.model.isEmpty, selectedModel == nil { Text(edit.model + " · unavailable").tag(edit.model) }
            }.aliveRow().onChange(of: edit.model) { old, _ in
                if loaded, !old.isEmpty { edit.think = ""; edit.fast = false }
            }
            Picker("Think", selection: $edit.think) {
                Text("Choose").tag("")
                ForEach(selectedModel?.supported_reasoning_efforts ?? ["low", "medium", "high", "xhigh"], id: \.self) {
                    Text($0.capitalized).tag($0)
                }
            }.aliveRow()
            if selectedModel?.supports_fast == true { Toggle("Fast", isOn: $edit.fast).aliveRow() }
        }
    }

    private var timingFields: some View {
        AliveSection("Timing") {
            Picker("When", selection: $edit.timing) {
                Text("Manual only").tag("manual")
                Text("Daily").tag("daily")
                Text("Weekdays").tag("weekdays")
                Text("Weekly").tag("weekly")
                Text("Every N hours").tag("interval")
                Text("Custom (cron)").tag("cron")
                Text("On an event").tag("event")
            }.aliveRow()
            if ["daily", "weekdays", "weekly"].contains(edit.timing) {
                DatePicker("At", selection: $clock, displayedComponents: .hourAndMinute).aliveRow()
                if edit.timing == "weekly" {
                    Picker("On", selection: $weekday) {
                        ForEach(0..<7, id: \.self) { Text(Calendar.current.weekdaySymbols[$0]).tag($0) }
                    }.aliveRow()
                }
            }
            if edit.timing == "interval" { TextField("Hours between runs", text: $edit.hours).keyboardType(.decimalPad).aliveRow() }
            if edit.timing == "cron" {
                TextField("Schedule (cron)", text: $edit.cron).aliveRow()
                TextField("Time zone", text: $edit.timeZone).aliveRow()
            }
            if edit.timing == "event" {
                Picker("Event", selection: $edit.eventSource) {
                    Text("GitHub issue or pull request").tag("github")
                    Text("Slack message").tag("slack")
                }.aliveRow()
                TextField(edit.eventSource == "github" ? "Repository (owner/repo)" : "Channel ID", text: $edit.eventFilter).aliveRow()
                TextField("Keyword (optional)", text: $edit.eventKeyword).aliveRow()
                Text("Autonomy off holds the event instead of running it.").aliveRow()
            }
        }
    }

    private func load() async {
        guard !loaded else { return }
        _ = await sync.refreshProviderControlsSnapshot()
        do {
            if let helperID { edit = try await sync.helperAction("get_helper", payload: ["id": helperID.uuidString]).0 }
            loaded = true
        } catch { self.error = error.localizedDescription }
    }

    private func save() async {
        guard !busy else { return }
        busy = true; error = nil
        defer { busy = false }
        do {
            var request = edit
            if ["daily", "weekdays", "weekly"].contains(request.timing) {
                let parts = Calendar.current.dateComponents([.hour, .minute], from: clock)
                let days = request.timing == "weekly" ? String(weekday) : request.timing == "weekdays" ? "1-5" : "*"
                request.cron = "\(parts.minute ?? 0) \(parts.hour ?? 0) * * \(days)"
                request.timeZone = TimeZone.current.identifier; request.timing = "cron"
            }
            let payload = String(decoding: try JSONEncoder().encode(request), as: UTF8.self)
            _ = try await sync.helperAction("save_helper", payload: ["edit": payload])
            dismiss()
        } catch { self.error = error.localizedDescription }
    }
}
