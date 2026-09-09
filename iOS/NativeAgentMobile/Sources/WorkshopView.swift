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
    @State private var notifiedTaskUnavailable = false
    @State private var didResolveNotifiedTask = false
    private let notifiedTaskID: String?
    /// `false` when pushed as a NavigationLink destination from another
    /// NavigationStack (the More hub). Nesting NavigationStacks makes the
    /// destination render and immediately pop back — the same trap
    /// SkillsToolsView and MemoryView already avoid this way.
    private let embedInNavigationStack: Bool

    init(embedInNavigationStack: Bool = true, notifiedTaskID: String? = nil) {
        self.embedInNavigationStack = embedInNavigationStack
        self.notifiedTaskID = notifiedTaskID
    }

    var body: some View {
        if embedInNavigationStack {
            NavigationStack { workshopContent }
                .alert("Error", isPresented: .constant(store.error != nil), actions: {
                    Button("OK") { store.error = nil }
                }, message: {
                    Text(store.error ?? "")
                })
        } else {
            workshopContent
                .alert("Error", isPresented: .constant(store.error != nil), actions: {
                    Button("OK") { store.error = nil }
                }, message: {
                    Text(store.error ?? "")
                })
        }
    }

    private var workshopContent: some View {
        Group {
                switch WorkshopContentPresentation.state(
                    tasks: MobileDesignSamples.rows(store.tasks),
                    isLoading: store.isLoading,
                    loadError: store.loadError
                ) {
                case .loading:
                    ProgressView("Loading tasks…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                case .unavailable(let message):
                    MobileReadingEmptyState(
                        title: "Desk tasks unavailable",
                        systemImage: "icloud.slash",
                        kind: .unavailable,
                        description: message,
                        action: (
                            title: "Try Again",
                            systemImage: "arrow.clockwise",
                            handler: { Task { await store.refresh() } }
                        )
                    )
                case .empty, .content:
                    workshopList
                }
            }
            .mobileReadingScreen()
            .navigationTitle("Desk tasks")
            .macSyncErrorBanner()
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button { showNewWorkshopTask = true } label: {
                        Image(systemName: "plus")
                    }
                    .accessibilityLabel("Add Desk task")
                }
                ToolbarItem(placement: .navigationBarLeading) {
                    if let syncAt = iCloudSyncEngine.shared.lastSyncAt {
                        SyncBadge(date: syncAt)
                    }
                }
            }
            .refreshable { await store.refresh() }
            .task {
                await store.refresh()
                guard !Task.isCancelled, !didResolveNotifiedTask, let notifiedTaskID else { return }
                didResolveNotifiedTask = true
                selectedWorkshopTask = store.tasks.first { $0.id == notifiedTaskID }
                notifiedTaskUnavailable = selectedWorkshopTask == nil
            }
            .safeAreaInset(edge: .top) {
                if notifiedTaskUnavailable {
                    MobileDeskTaskUnavailableNotice()
                }
            }
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

    private var workshopList: some View {
        List {
            if !store.pendingApprovals.isEmpty {
                Section("Pending Approval") {
                    ForEach(store.pendingApprovals) { task in
                        workshopTaskButton(task)
                            .swipeActions(edge: .trailing) {
                                Button(role: .destructive) {
                                    Task { _ = await store.rejectWorkshopTask(task) }
                                } label: { Label("Reject", systemImage: "xmark") }
                            }
                            .swipeActions(edge: .leading) {
                                Button {
                                    Task { _ = await store.approveWorkshopTask(task) }
                                } label: { Label("Approve", systemImage: "checkmark") }
                                    .tint(NativeAgentMobileTheme.Colors.accentText)
                            }
                    }
                }
            }

            let active = MobileDesignSamples.rows(store.activeTasks)
            if !active.isEmpty {
                Section("Active (\(active.count))") {
                    ForEach(active) { task in workshopTaskButton(task) }
                }
            }

            let done = store.doneTasks
            if !done.isEmpty {
                Section("History") {
                    ForEach(done.prefix(20)) { task in workshopTaskButton(task) }
                }
            }

            if MobileDesignSamples.rows(store.tasks).isEmpty {
                MobileReadingEmptyState(
                    title: "No tasks yet",
                    systemImage: "checklist",
                    kind: .empty,
                    description: "Your agent proposes tasks when high-value work is worth tracking."
                )
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
            }
        }
        .listStyle(.insetGrouped)
    }

    private func workshopTaskButton(_ task: WorkshopTaskRecord) -> some View {
        Button {
            selectedWorkshopTask = task
        } label: {
            WorkshopTaskRow(task: task)
        }
        .buttonStyle(.plain)
        .accessibilityHint("Opens Desk task details")
    }
}

// MARK: - Store

struct MobileDeskTaskUnavailableNotice: View {
    var body: some View {
        Text("This task is unavailable in the current snapshot. Showing the loaded Desk tasks.")
            .font(.callout)
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(NativeAgentMobileTheme.Colors.canvas)
    }
}

enum WorkshopContentPresentation: Equatable {
    case loading
    case unavailable(String)
    case empty
    case content

    static func state(
        tasks: [WorkshopTaskRecord],
        isLoading: Bool,
        loadError: String?
    ) -> WorkshopContentPresentation {
        guard tasks.isEmpty else { return .content }
        if isLoading { return .loading }
        if let loadError, !loadError.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return .unavailable(loadError)
        }
        return .empty
    }
}

@MainActor
final class WorkshopStore: ObservableObject {
    @Published var tasks: [WorkshopTaskRecord] = []
    @Published var isLoading = false
    @Published var error: String?
    @Published private(set) var loadError: String?

    var activeTasks: [WorkshopTaskRecord] {
        tasks.filter { task in
            let status = task.status.lowercased()
            let isAwaitingApproval = status.contains("approval")
                || task.phase.lowercased().contains("approval")
            return ["active", "running", "queued", "paused"].contains(status)
                && !isAwaitingApproval
        }
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
        defer { isLoading = false }
        await iCloudSyncEngine.shared.refreshWorkshopTasksSnapshot()
        let next = iCloudSyncEngine.shared.workshopTasks
        applySyncedTasks(next)
        loadError = next.isEmpty ? iCloudSyncEngine.shared.syncError : nil
    }

    func applySyncedTasks(_ next: [WorkshopTaskRecord]) {
        if next != tasks { tasks = next }
        if !next.isEmpty { loadError = nil }
    }

    func submitWorkshopTask(
        title: String, objective: String,
        submission: InboxAction? = nil,
        intentionalNewRequest: Bool = false,
        onReplacement: ((InboxAction) -> Void)? = nil
    ) async -> Bool {
        do {
            try await iCloudSyncEngine.shared.submitWorkshopTask(
                title: title, objective: objective, submission: submission,
                intentionalNewRequest: intentionalNewRequest,
                onReplacement: onReplacement
            )
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

}

/// Shared snapshot observer for Workshop completion alerts. It is deliberately
/// independent of WorkshopView, because iOS receives workshop snapshots while
/// Activity, Chat, or another tab is on screen.
@MainActor
final class WorkshopCompletionNotificationTracker {
    static let shared = WorkshopCompletionNotificationTracker()

    private var hasBaseline = false
    private var knownCompletedIDs = Set<String>()
    private let notify: @MainActor (WorkshopTaskRecord) -> Void

    init(notify: (@MainActor (WorkshopTaskRecord) -> Void)? = nil) {
        self.notify = notify ?? { task in
            WorkshopCompletionNotificationTracker.post(task)
        }
    }

    func apply(_ next: [WorkshopTaskRecord]) {
        let completed = next.filter { ["done", "completed"].contains($0.status.lowercased()) }
        let completedIDs = Set(completed.map(\.id))
        defer {
            knownCompletedIDs.formUnion(completedIDs)
            hasBaseline = true
        }
        guard hasBaseline else { return }
        for task in completed where !knownCompletedIDs.contains(task.id) {
            notify(task)
        }
    }

    private static func post(_ task: WorkshopTaskRecord) {
        Task.detached {
            let center = UNUserNotificationCenter.current()
            _ = try? await center.requestAuthorization(options: [.alert, .sound, .badge])
            let content = UNMutableNotificationContent()
            content.title = "Desk task completed"
            content.body = task.title
            content.sound = .default
            // Routes to the tab that actually hosts Workshop (More). Before
            // the screen was mounted this said "activity", which opened a tab
            // with no Workshop on it.
            var userInfo = ["screen": "workshop", "source": "workshop", "taskId": task.id]
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
            MobileAdaptiveRow {
                if isRunning {
                    Image(systemName: "circle.fill").font(.caption2).foregroundStyle(.secondary)
                }
                Text(task.title)
                    .font(.headline)
                Spacer()
                StatusBadge(status: task.status)
            }
            Text(task.objective)
                .font(.callout)
                .foregroundStyle(NativeAgentMobileTheme.Colors.readingSecondary)
                .fixedSize(horizontal: false, vertical: true)
            if let summary = task.summary {
                Text(summary)
                    .font(.caption)
                    .foregroundStyle(NativeAgentMobileTheme.Colors.readingSecondary)
                    .fixedSize(horizontal: false, vertical: true)
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
                        .foregroundStyle(.secondary)
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
            .mobileReadingScreen()
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

// MARK: - New Desk task sheet

struct NewWorkshopTaskSheet: View {
    let store: WorkshopStore
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var objective = ""
    @State private var isSubmitting = false
    // 2026-09-06: one sheet submission owns one action across uncertain sends.
    // A new sheet is an explicitly new task, even with identical wording.
    @State private var submission: InboxAction?

    var body: some View {
        NavigationStack {
            Form {
                Section("Desk Task") {
                    TextField("Title", text: $title)
                    TextField("Objective (describe what you want done)", text: $objective, axis: .vertical)
                        .lineLimit(4...8)
                }
                .disabled(submission != nil)
                Section {
                    Button {
                        Task {
                            guard !isSubmitting else { return }
                            isSubmitting = true
                            // 2026-09-06: only the first send from this sheet is a new request.
                            let intentionalNewRequest = submission == nil
                            if submission == nil {
                                submission = .make(action: "submitWorkshopTask", payload: [
                                    "title": title, "objective": objective
                                ])
                            }
                            if await store.submitWorkshopTask(
                                title: title, objective: objective, submission: submission,
                                intentionalNewRequest: intentionalNewRequest,
                                onReplacement: { submission = $0 }
                            ) { dismiss() }
                            isSubmitting = false
                        }
                    } label: {
                        MobileAdaptiveRow(spacing: 8) {
                            if isSubmitting {
                                ProgressView()
                                    .controlSize(.small)
                                    .accessibilityHidden(true)
                            }
                            Text(isSubmitting ? "Submitting Desk Task…" : (submission == nil ? "Submit Desk Task" : "Retry Desk Task"))
                        }
                    }
                    .disabled(title.isEmpty || objective.isEmpty || isSubmitting)
                    .accessibilityLabel(isSubmitting ? "Submitting Desk task" : (submission == nil ? "Submit Desk task" : "Retry Desk task"))
                }
            }
            .mobileReadingScreen()
            .navigationTitle("New Desk Task")
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
            .background(NativeAgentMobileTheme.Colors.quietFill)
            .foregroundStyle(NativeAgentMobileTheme.Colors.readingSecondary)
            .clipShape(Capsule())
    }
}

struct SyncBadge: View {
    let date: Date

    static func isStale(date: Date, now: Date = Date()) -> Bool {
        MobileSnapshotFreshnessPresentation.isStale(lastSyncedAt: date, now: now)
    }

    var isStale: Bool { Self.isStale(date: date) }

    var body: some View {
        if isStale {
            Label(date.formatted(.relative(presentation: .named)), systemImage: "exclamationmark.icloud")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }
}
