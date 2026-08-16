// iPhone Workshop surface — active tasks, pending approvals, history, and new directed work.
import SwiftUI
import UserNotifications
import NativeAgentShared

// MARK: - WorkshopView (full parity)

struct WorkshopView: View {
    @EnvironmentObject private var bridgeClient: MacBridgeClient
    @StateObject private var store = WorkshopStore()
    @ObservedObject private var sync = iCloudSyncEngine.shared
    @State private var showNewWorkshopTask = false
    @State private var selectedWorkshopTask: WorkshopTaskRecord?

    var body: some View {
        NavigationStack {
            Group {
                if store.isLoading && store.tasks.isEmpty {
                    ProgressView("Loading tasks…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List {
                        // Pending approvals — shown first
                        if !store.pendingApprovals.isEmpty {
                            Section("Pending Approval") {
                                ForEach(store.pendingApprovals) { task in
                                    WorkshopTaskRow(task: task)
                                        .swipeActions(edge: .trailing) {
                                            Button(role: .destructive) {
                                                Task { _ = await store.rejectWorkshopTask(task) }
                                            } label: { Label("Reject", systemImage: "xmark") }
                                        }
                                        .swipeActions(edge: .leading) {
                                            Button {
                                                Task { _ = await store.approveWorkshopTask(task) }
                                            } label: { Label("Approve", systemImage: "checkmark") }
                                                .tint(.green)
                                        }
                                        .onTapGesture { selectedWorkshopTask = task }
                                }
                            }
                        }

                        // Active tasks
                        let active = store.activeTasks
                        if !active.isEmpty {
                            Section("Active (\(active.count))") {
                                ForEach(active) { task in
                                    WorkshopTaskRow(task: task)
                                        .onTapGesture { selectedWorkshopTask = task }
                                }
                            }
                        }

                        // History (done / blocked)
                        let done = store.doneTasks
                        if !done.isEmpty {
                            Section("History") {
                                ForEach(done.prefix(20)) { task in
                                    WorkshopTaskRow(task: task)
                                        .onTapGesture { selectedWorkshopTask = task }
                                }
                            }
                        }

                        if store.tasks.isEmpty {
                            AppEmptyState(
                                title: "No tasks yet",
                                systemImage: "checklist",
                                description: "Your agent proposes tasks when high-value work is worth tracking."
                            )
                            .listRowBackground(Color.clear)
                            .listRowSeparator(.hidden)
                        }
                    }
                    .listStyle(.insetGrouped)
                }
            }
            .navigationTitle("Workshop")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button { showNewWorkshopTask = true } label: {
                        Image(systemName: "plus")
                    }
                }
                ToolbarItem(placement: .navigationBarLeading) {
                    if let syncAt = iCloudSyncEngine.shared.lastSyncAt {
                        SyncBadge(date: syncAt)
                    }
                }
            }
            .refreshable { await store.refresh() }
            .onAppear { Task { await store.refresh() } }
            .onChange(of: sync.workshopTasks) { _, tasks in
                store.applySyncedTasks(tasks)
            }
            .sheet(isPresented: $showNewWorkshopTask) {
                NewWorkshopTaskSheet(store: store)
            }
            .sheet(item: $selectedWorkshopTask) { task in
                WorkshopTaskDetailSheet(task: task, store: store)
            }
        }
        .alert("Error", isPresented: .constant(store.error != nil), actions: {
            Button("OK") { store.error = nil }
        }, message: {
            Text(store.error ?? "")
        })
    }
}

// MARK: - Store

@MainActor
final class WorkshopStore: ObservableObject {
    @Published var tasks: [WorkshopTaskRecord] = []
    @Published var isLoading = false
    @Published var error: String?
    private var hasLoadedTasks = false
    private var knownCompletedIDs = Set<String>()

    var activeTasks: [WorkshopTaskRecord] {
        tasks.filter { ["active", "running", "queued", "paused"].contains($0.status.lowercased()) }
    }

    var pendingApprovals: [WorkshopTaskRecord] {
        tasks.filter { $0.status.lowercased().contains("approval") || $0.phase.lowercased().contains("approval") }
    }

    var doneTasks: [WorkshopTaskRecord] {
        tasks.filter { ["done", "completed", "blocked", "failed", "cancelled"].contains($0.status.lowercased()) }
            .sorted { ($0.completedAt ?? $0.updatedAt ?? $0.createdAt) > ($1.completedAt ?? $1.updatedAt ?? $1.createdAt) }
    }

    func refresh() async {
        isLoading = true
        await iCloudSyncEngine.shared.refreshWorkshopTasksSnapshot()
        let next = iCloudSyncEngine.shared.workshopTasks
        applySyncedTasks(next)
        isLoading = false
    }

    func applySyncedTasks(_ next: [WorkshopTaskRecord]) {
        guard next != tasks else { return }
        notifyForNewCompletions(next)
        tasks = next
    }

    func submitWorkshopTask(title: String, objective: String) async -> Bool {
        do {
            try await iCloudSyncEngine.shared.submitWorkshopTask(title: title, objective: objective)
            await refresh()
            return true
        } catch {
            self.error = error.localizedDescription
            return false
        }
    }

    func approveWorkshopTask(_ task: WorkshopTaskRecord) async -> Bool {
        guard let stepId = task.currentStepId?.trimmingCharacters(in: .whitespacesAndNewlines),
              !stepId.isEmpty,
              stepId.lowercased() != "pending"
        else {
            self.error = "This task snapshot does not include the pending step id yet. Refresh and try again."
            return false
        }
        do {
            try await iCloudSyncEngine.shared.approveStep(executionId: task.id, stepId: stepId)
            await refresh()
            return true
        } catch {
            self.error = error.localizedDescription
            return false
        }
    }

    func rejectWorkshopTask(_ task: WorkshopTaskRecord) async -> Bool {
        guard let stepId = task.currentStepId?.trimmingCharacters(in: .whitespacesAndNewlines),
              !stepId.isEmpty,
              stepId.lowercased() != "pending"
        else {
            self.error = "This task snapshot does not include the pending step id yet. Refresh and try again."
            return false
        }
        do {
            try await iCloudSyncEngine.shared.rejectStep(executionId: task.id, stepId: stepId)
            await refresh()
            return true
        } catch {
            self.error = error.localizedDescription
            return false
        }
    }

    private func notifyForNewCompletions(_ next: [WorkshopTaskRecord]) {
        let completed = next.filter { ["done", "completed"].contains($0.status.lowercased()) }
        let completedIDs = Set(completed.map(\.id))
        defer {
            knownCompletedIDs.formUnion(completedIDs)
            hasLoadedTasks = true
        }
        guard hasLoadedTasks else { return }
        for task in completed where !knownCompletedIDs.contains(task.id) {
            fireWorkshopTaskCompletionNotification(task)
        }
    }

    private func fireWorkshopTaskCompletionNotification(_ task: WorkshopTaskRecord) {
        Task.detached {
            let center = UNUserNotificationCenter.current()
            _ = try? await center.requestAuthorization(options: [.alert, .sound, .badge])
            let content = UNMutableNotificationContent()
            content.title = "Workshop task completed"
            content.body = task.title
            content.sound = .default
            var userInfo = ["screen": "activity", "source": "workshop", "taskId": task.id]
            let eventID = NativeAgentDeviceEventIdentity.notification(userInfo: userInfo)
            userInfo["eventId"] = eventID
            content.userInfo = userInfo
            _ = try? await NativeAgentNotificationEventGate.add(
                content: content, eventID: eventID, trigger: nil, center: center
            )
        }
    }
}

// MARK: - Row + detail

struct WorkshopTaskRow: View {
    let task: WorkshopTaskRecord

    private var isRunning: Bool {
        ["active", "running"].contains(task.status.lowercased())
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                if isRunning {
                    PulsingDot(color: .green)
                }
                Text(task.title)
                    .font(AppFont.section)
                Spacer()
                StatusBadge(status: task.status)
            }
            Text(task.objective)
                .font(AppFont.label)
                .foregroundStyle(.secondary)
                .lineLimit(2)
            if let summary = task.summary {
                Text(summary)
                    .font(AppFont.tag)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
    }
}

struct WorkshopTaskDetailSheet: View {
    let task: WorkshopTaskRecord
    let store: WorkshopStore
    @Environment(\.dismiss) private var dismiss
    @State private var isWorking = false

    var body: some View {
        NavigationStack {
            List {
                Section("Details") {
                    LabeledContent("Status") { StatusBadge(status: task.status) }
                    LabeledContent("Phase", value: task.phase)
                    if let priority = task.priority {
                        LabeledContent("Priority", value: priority)
                    }
                    if let level = task.autonomyLevel {
                        LabeledContent("Autonomy", value: level)
                    }
                }
                Section("Objective") {
                    Text(task.objective)
                        .font(.body)
                }
                if let summary = task.summary {
                    Section("Summary") {
                        Text(summary).font(.callout)
                    }
                }
                Section("Timestamps") {
                    LabeledContent("Created", value: task.createdAt)
                    if let updated = task.updatedAt {
                        LabeledContent("Updated", value: updated)
                    }
                }
                if task.status.lowercased().contains("approval") || task.phase.lowercased().contains("approval") {
                    Section("Actions") {
                        Button("Approve Step") {
                            Task {
                                isWorking = true
                                if await store.approveWorkshopTask(task) { dismiss() }
                                isWorking = false
                            }
                        }
                        .foregroundStyle(.green)
                        .disabled(isWorking)
                        Button("Reject Step", role: .destructive) {
                            Task {
                                isWorking = true
                                if await store.rejectWorkshopTask(task) { dismiss() }
                                isWorking = false
                            }
                        }
                        .disabled(isWorking)
                    }
                }
            }
            .navigationTitle(task.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
        }
    }
}

// MARK: - New Workshop task sheet

struct NewWorkshopTaskSheet: View {
    let store: WorkshopStore
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var objective = ""
    @State private var isSubmitting = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Workshop Task") {
                    TextField("Title", text: $title)
                    TextField("Objective (describe what you want done)", text: $objective, axis: .vertical)
                        .lineLimit(4...8)
                }
                Section {
                    Button("Submit Workshop Task") {
                        Task {
                            isSubmitting = true
                            if await store.submitWorkshopTask(title: title, objective: objective) { dismiss() }
                            isSubmitting = false
                        }
                    }
                    .disabled(title.isEmpty || objective.isEmpty || isSubmitting)
                }
            }
            .navigationTitle("New Workshop Task")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }
}

// MARK: - Shared helpers

struct StatusBadge: View {
    let status: String

    var color: Color {
        switch status.lowercased() {
        case "active", "running", "succeeded": return .green
        case "done", "completed": return .blue
        case "blocked", "failed", "error", "timeout": return .red
        case "queued", "paused": return .orange
        default: return .secondary
        }
    }

    var body: some View {
        Text(status.capitalized)
            .font(.caption)
            .fontWeight(.medium)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.15))
            .foregroundStyle(color)
            .clipShape(Capsule())
    }
}

struct SyncBadge: View {
    let date: Date

    var isStale: Bool { Date().timeIntervalSince(date) > 30 }

    var body: some View {
        if isStale {
            Label(date.formatted(.relative(presentation: .named)), systemImage: "exclamationmark.icloud")
                .font(.caption2)
                .foregroundStyle(.orange)
        }
    }
}
