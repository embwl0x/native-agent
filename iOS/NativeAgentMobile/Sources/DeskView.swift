import SwiftUI
import NativeAgentShared

/// iPhone projection of the Mac-owned, event-sourced Desk. All writes travel
/// through the existing signed action channel; iOS never owns a second Desk.
struct MobileDeskView: View {
    @ObservedObject private var sync = iCloudSyncEngine.shared
    @State private var selectedItem: MobileDeskItem?
    @State private var showingNewItem = false
    @State private var errorMessage: String?

    private var waitingOnYou: [MobileDeskItem] {
        sync.deskItems.filter { $0.requiresOwnerInput && !Self.isTerminal($0.status) }
    }

    private var active: [MobileDeskItem] {
        sync.deskItems.filter { !Self.isTerminal($0.status) && !$0.requiresOwnerInput }
    }

    private var history: [MobileDeskItem] {
        sync.deskItems.filter { Self.isTerminal($0.status) }
    }

    var body: some View {
        List {
            if !waitingOnYou.isEmpty {
                Section("Waiting on You") {
                    ForEach(waitingOnYou) { item in deskRow(item) }
                }
            }
            if !active.isEmpty {
                Section("Active") {
                    ForEach(active) { item in deskRow(item) }
                }
            }
            if !history.isEmpty {
                Section("History") {
                    ForEach(history.prefix(40)) { item in deskRow(item) }
                }
            }
            if sync.deskItems.isEmpty {
                AppEmptyState(
                    title: "Your Desk is clear",
                    systemImage: "rectangle.3.group",
                    description: "Items tracked on the Mac will appear here. You can also add one from your iPhone."
                )
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Desk")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { showingNewItem = true } label: { Image(systemName: "plus") }
                    .accessibilityLabel("Add Desk item")
            }
            ToolbarItem(placement: .navigationBarLeading) {
                if let syncAt = sync.lastSyncAt { SyncBadge(date: syncAt) }
            }
        }
        .refreshable { await sync.refreshDeskSnapshot() }
        .task { await sync.refreshDeskSnapshot() }
        .sheet(item: $selectedItem) { item in
            MobileDeskItemDetail(item: item, errorMessage: $errorMessage)
        }
        .sheet(isPresented: $showingNewItem) {
            NewMobileDeskItemSheet(errorMessage: $errorMessage)
        }
        .alert("Desk", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK") { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    @ViewBuilder
    private func deskRow(_ item: MobileDeskItem) -> some View {
        Button { selectedItem = item } label: {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: Self.icon(for: item.status))
                    .foregroundStyle(Self.color(for: item.status))
                    .frame(width: 22)
                VStack(alignment: .leading, spacing: 4) {
                    Text(item.title).font(AppFont.body).foregroundStyle(.primary)
                    HStack(spacing: 6) {
                        Text(item.alias).font(AppFont.mono)
                        Text(item.project).lineLimit(1)
                        Text(item.status.uppercased())
                    }
                    .font(AppFont.tag)
                    .foregroundStyle(.secondary)
                    if let reason = item.blockedReason, !reason.isEmpty {
                        Text(reason).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    }
                }
                Spacer(minLength: 0)
                if item.pinned { Image(systemName: "pin.fill").font(.caption).foregroundStyle(.secondary) }
            }
        }
        .buttonStyle(.plain)
    }

    fileprivate static func isTerminal(_ status: String) -> Bool {
        status == "done" || status == "canceled"
    }

    fileprivate static func icon(for status: String) -> String {
        switch status {
        case "done": "checkmark.circle.fill"
        case "canceled": "xmark.circle"
        case "blocked": "exclamationmark.octagon.fill"
        case "now": "bolt.circle.fill"
        case "next": "arrow.right.circle.fill"
        case "flag": "flag.fill"
        default: "circle"
        }
    }

    fileprivate static func color(for status: String) -> Color {
        switch status {
        case "done": .green
        case "canceled": .secondary
        case "blocked": .red
        case "now": NativeAgentPalette.agentAccent
        case "next": .blue
        case "flag": .orange
        default: .secondary
        }
    }
}

private struct MobileDeskItemDetail: View {
    let item: MobileDeskItem
    @Binding var errorMessage: String?
    @Environment(\.dismiss) private var dismiss
    @State private var note = ""
    @State private var isWorking = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LabeledContent("Project", value: item.project)
                    LabeledContent("Kind", value: item.kind.capitalized)
                    LabeledContent("Status", value: item.status.capitalized)
                    if let summary = item.summary, !summary.isEmpty { Text(summary) }
                    if let reason = item.blockedReason, !reason.isEmpty {
                        LabeledContent("Blocked", value: reason)
                    }
                    if let waiting = item.waitingOn, !waiting.isEmpty {
                        LabeledContent("Waiting on", value: waiting)
                    }
                }
                Section("Move") {
                    Picker("Status", selection: Binding(
                        get: { item.status },
                        set: { status in Task { await changeStatus(status) } }
                    )) {
                        ForEach(Self.allowedStatuses(for: item.status), id: \.self) {
                            Text($0.capitalized).tag($0)
                        }
                    }
                    .disabled(isWorking)
                }
                if !item.recentNotes.isEmpty {
                    Section("Recent Notes") {
                        ForEach(Array(item.recentNotes.enumerated()), id: \.offset) { _, note in
                            VStack(alignment: .leading, spacing: 3) {
                                Text(note.text)
                                Text(note.timestamp).font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                Section("Add Note") {
                    TextField("What changed?", text: $note, axis: .vertical)
                        .lineLimit(2...6)
                    Button("Add Note") { Task { await addNote() } }
                        .disabled(isWorking || note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .navigationTitle(item.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }

    private func changeStatus(_ status: String) async {
        guard status != item.status else { return }
        isWorking = true
        defer { isWorking = false }
        do {
            _ = try await iCloudSyncEngine.shared.setDeskItemStatus(handle: item.handle, status: status)
            await iCloudSyncEngine.shared.refreshDeskSnapshot()
            dismiss()
        } catch { errorMessage = error.localizedDescription }
    }

    private static func allowedStatuses(for current: String) -> [String] {
        var statuses = ["watch", "flag", "now", "next", "todo", "done", "canceled"]
        // Blocking carries reason/ownership semantics and is deliberately set
        // on the Mac. Preserve an existing blocked selection without offering
        // a reasonless transition from the phone.
        if current == "blocked" { statuses.insert("blocked", at: 0) }
        return statuses
    }

    private func addNote() async {
        let clean = note.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }
        isWorking = true
        defer { isWorking = false }
        do {
            _ = try await iCloudSyncEngine.shared.appendDeskItemNote(handle: item.handle, text: clean)
            note = ""
            await iCloudSyncEngine.shared.refreshDeskSnapshot()
            dismiss()
        } catch { errorMessage = error.localizedDescription }
    }
}

private struct NewMobileDeskItemSheet: View {
    @Binding var errorMessage: String?
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var project = "General"
    @State private var summary = ""
    @State private var kind = "plan"
    @State private var isSaving = false

    var body: some View {
        NavigationStack {
            Form {
                TextField("Title", text: $title)
                TextField("Project", text: $project)
                Picker("Kind", selection: $kind) {
                    ForEach(["plan", "project", "watch", "gh", "standing"], id: \.self) {
                        Text($0.capitalized).tag($0)
                    }
                }
                TextField("Summary (optional)", text: $summary, axis: .vertical).lineLimit(2...6)
            }
            .navigationTitle("New Desk Item")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") { Task { await save() } }
                        .disabled(isSaving || title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || project.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }

    private func save() async {
        isSaving = true
        defer { isSaving = false }
        do {
            _ = try await iCloudSyncEngine.shared.createDeskItem(
                kind: kind,
                project: project.trimmingCharacters(in: .whitespacesAndNewlines),
                title: title.trimmingCharacters(in: .whitespacesAndNewlines),
                summary: summary.trimmingCharacters(in: .whitespacesAndNewlines)
            )
            await iCloudSyncEngine.shared.refreshDeskSnapshot()
            dismiss()
        } catch { errorMessage = error.localizedDescription }
    }
}
