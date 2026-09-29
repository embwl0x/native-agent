// iPhone Workshop surface — active tasks, pending approvals, history, and new directed work.
import SwiftUI
import UserNotifications
import NativeAgentShared

// MARK: - WorkshopView (full parity)

/// Desk tasks, in the Desk board's language (DeskView.swift): a serif door
/// and one sentence, what needs your yes in the haze-lit card with its two
/// answers on the row, what I'm working on as one card each, and a quiet
/// card of what finished.
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

    private var presentation: WorkshopContentPresentation {
        WorkshopContentPresentation.state(
            tasks: MobileDesignSamples.rows(store.tasks),
            isLoading: store.isLoading,
            loadError: store.loadError
        )
    }

    private var workshopContent: some View {
        AlivePage(title: "Desk tasks", line: headerLine, freshnessGroup: "workshop_tasks") {
            Button { showNewWorkshopTask = true } label: { AliveTitleControlLabel(systemImage: "plus") }
                .buttonStyle(.plain)
                .accessibilityLabel("Add Desk task")
        } content: {
            if notifiedTaskUnavailable {
                MobileDeskTaskUnavailableNotice()
            }
            switch presentation {
            case .loading:
                AliveCalmState(title: "Checking your tasks…", line: "Reading them from your Mac.", showsProgress: true)
            case .unavailable(let message):
                AliveCalmState(title: "Tasks haven't arrived yet.", line: message, actionTitle: "Try again") {
                    Task { await store.refresh() }
                }
            case .empty:
                AliveCalmState(
                    title: "Nothing on the bench.",
                    line: "Hand me something to do and it lands here while I work through it.",
                    actionTitle: "Give me a task"
                ) { showNewWorkshopTask = true }
            case .content:
                workshopList
            }
        }
        .macSyncErrorBanner()
        .refreshable { await store.refresh() }
        .task {
            if let sample = MobileDeskSample.tasks, store.tasks.isEmpty {
                store.applySyncedTasks(sample)
                if MobileDeskSample.mode == "taskdetail" { selectedWorkshopTask = sample.first }
                if MobileDeskSample.mode == "tasknew" { showNewWorkshopTask = true }
                return
            }
            await store.refresh()
            guard !Task.isCancelled, !didResolveNotifiedTask, let notifiedTaskID else { return }
            didResolveNotifiedTask = true
            selectedWorkshopTask = store.tasks.first { $0.id == notifiedTaskID }
            notifiedTaskUnavailable = selectedWorkshopTask == nil
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

    /// "One running. One needs your yes."
    private var headerLine: String? {
        guard presentation == .content else { return nil }
        let running = MobileDesignSamples.rows(store.activeTasks).count
        let asks = store.pendingApprovals.count
        var line = running == 0 ? "Nothing running." : "\(AliveWords.spelled(running)) running."
        if asks > 0 { line += " \(AliveWords.spelled(asks)) \(asks == 1 ? "needs" : "need") your yes." }
        return line
    }

    @ViewBuilder
    private var workshopList: some View {
        if !store.pendingApprovals.isEmpty {
            AliveSection("Waiting on you", surface: .waiting) {
                ForEach(Array(store.pendingApprovals.enumerated()), id: \.element.id) { index, task in
                    if index > 0 { AliveDivider() }
                    approvalRow(task)
                }
            }
        }

        let active = MobileDesignSamples.rows(store.activeTasks)
        if !active.isEmpty {
            AliveSection("What I'm working on", surface: .none) {
                ForEach(active) { task in
                    workshopTaskButton(task) {
                        WorkshopTaskRow(task: task)
                            .aliveRow()
                            .aliveCard()
                    }
                }
            }
        }

        let done = store.doneTasks
        if !done.isEmpty {
            AliveSection("Finished") {
                ForEach(Array(done.prefix(20).enumerated()), id: \.element.id) { index, task in
                    if index > 0 { AliveDivider() }
                    workshopTaskButton(task) {
                        HStack(spacing: 12) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(task.title)
                                    .font(.body)
                                    .foregroundStyle(AlivePalette.text)
                                    .lineLimit(2)
                                    .multilineTextAlignment(.leading)
                                Text([DeskStatusWords.word(for: task.status),
                                      AliveWords.relative(task.completedAt ?? task.updatedAt)]
                                    .compactMap { $0 }.joined(separator: " · "))
                                    .font(.footnote)
                                    .foregroundStyle(AlivePalette.secondary)
                            }
                            Spacer(minLength: 8)
                            AliveChevron()
                        }
                        .aliveRow()
                    }
                }
            }
        }
    }

    /// The task, and its two answers on the row. Swiping a card is not a
    /// thing a card does; the buttons say what they do.
    private func approvalRow(_ task: WorkshopTaskRecord) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            workshopTaskButton(task) {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    AliveWaitingDot()
                    VStack(alignment: .leading, spacing: 3) {
                        Text(task.title)
                            .font(.headline)
                            .foregroundStyle(AlivePalette.text)
                            .multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)
                        Text(task.summary ?? task.objective)
                            .font(.subheadline)
                            .foregroundStyle(AlivePalette.secondary)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                    }
                    Spacer(minLength: 8)
                    AliveChevron()
                }
            }
            HStack(spacing: 10) {
                Button {
                    Task { _ = await store.approveWorkshopTask(task) }
                } label: { Text("Approve").frame(minWidth: 72) }
                    .alivePrimaryButton()
                Button(role: .destructive) {
                    Task { _ = await store.rejectWorkshopTask(task) }
                } label: { Text("Reject").frame(minWidth: 72) }
                    .aliveSecondaryButton()
            }
            .font(.subheadline.weight(.semibold))
            .buttonBorderShape(.capsule)
            .padding(.leading, 20)
        }
        .aliveRow()
    }

    private func workshopTaskButton<Label: View>(
        _ task: WorkshopTaskRecord, @ViewBuilder label: () -> Label
    ) -> some View {
        Button {
            selectedWorkshopTask = task
        } label: {
            label().contentShape(Rectangle())
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
            .foregroundStyle(AlivePalette.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .aliveCard()
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
        // Screenshot fixtures (-deskSample) never send anything to the Mac.
        if MobileDeskSample.mode != nil { return false }
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
        // Screenshot fixtures (-deskSample) never send anything to the Mac.
        if MobileDeskSample.mode != nil { return false }
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

/// One task in motion: a plain status word, the name, what it's for, and
/// where it has got to. The card around it is the caller's.
struct WorkshopTaskRow: View {
    let task: WorkshopTaskRecord

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                DeskStatusMark(status: task.status)
                Text(DeskStatusWords.word(for: task.status))
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(AlivePalette.text)
                Spacer(minLength: 8)
                if let updated = AliveWords.relative(task.updatedAt ?? task.createdAt) {
                    Text(updated)
                        .font(.footnote)
                        .foregroundStyle(AlivePalette.secondary)
                }
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(task.title)
                    .font(.headline)
                    .foregroundStyle(AlivePalette.text)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                Text(task.objective)
                    .font(.subheadline)
                    .foregroundStyle(AlivePalette.secondary)
                    .lineLimit(3)
                    .multilineTextAlignment(.leading)
            }
            if let summary = task.summary, !summary.isEmpty {
                Text(summary)
                    .font(.footnote)
                    .foregroundStyle(AlivePalette.secondary)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .contentShape(Rectangle())
    }
}

struct WorkshopTaskDetailSheet: View {
    let task: WorkshopTaskRecord
    let store: WorkshopStore
    @Environment(\.dismiss) private var dismiss
    @State private var isWorking = false

    private var needsApproval: Bool {
        task.status.lowercased().contains("approval") || task.phase.lowercased().contains("approval")
    }

    var body: some View {
        NavigationStack {
            AlivePage(title: task.title, line: needsApproval ? "Needs your yes" : DeskStatusWords.word(for: task.status), style: .pushed) {

                if needsApproval {
                    HStack(spacing: 10) {
                        Button {
                            Task {
                                isWorking = true
                                if await store.approveWorkshopTask(task) { dismiss() }
                                isWorking = false
                            }
                        } label: {
                            Text("Approve Step").frame(maxWidth: .infinity)
                        }
                        .alivePrimaryButton()
                        Button(role: .destructive) {
                            Task {
                                isWorking = true
                                if await store.rejectWorkshopTask(task) { dismiss() }
                                isWorking = false
                            }
                        } label: {
                            Text("Reject Step").frame(maxWidth: .infinity)
                        }
                        .aliveSecondaryButton()
                    }
                    .font(.body.weight(.semibold))
                    .controlSize(.large)
                    .disabled(isWorking)
                    .aliveListRow()
                }

                AliveSection("What it's for") {
                    Text(task.objective)
                        .font(.body)
                        .lineSpacing(3)
                        .foregroundStyle(AlivePalette.text)
                        .fixedSize(horizontal: false, vertical: true)
                        .aliveRow()
                }

                if let summary = task.summary, !summary.isEmpty {
                    AliveSection("Where it's got to") {
                        Text(summary)
                            .font(.body)
                            .lineSpacing(3)
                            .foregroundStyle(AlivePalette.text)
                            .fixedSize(horizontal: false, vertical: true)
                            .aliveRow()
                    }
                }

                AliveCard {
                    AliveValueRow(label: "Phase", value: AliveWords.humanized(task.phase))
                    if let priority = task.priority {
                        AliveDivider()
                        AliveValueRow(label: "Priority", value: priority.capitalized)
                    }
                    if let level = task.autonomyLevel {
                        AliveDivider()
                        AliveValueRow(label: "Autonomy", value: level.capitalized)
                    }
                    AliveDivider()
                    AliveValueRow(label: "Created", value: AliveWords.readable(task.createdAt))
                    if let updated = task.updatedAt {
                        AliveDivider()
                        AliveValueRow(label: "Updated", value: AliveWords.readable(updated))
                    }
                }
            }
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
            AlivePage(title: "New task", line: "Say what you want done. I'll take it from there.", style: .pushed) {
                AliveCard {
                    TextField("Title", text: $title)
                        .font(.headline)
                        .aliveRow()
                    AliveDivider()
                    TextField("Objective (describe what you want done)", text: $objective, axis: .vertical)
                        .lineLimit(4...8)
                        .aliveRow()
                }
                .foregroundStyle(AlivePalette.text)
                .disabled(submission != nil)

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
                    HStack(spacing: 8) {
                        if isSubmitting {
                            ProgressView()
                                .controlSize(.small)
                                .tint(.white)
                                .accessibilityHidden(true)
                        }
                        Text(isSubmitting ? "Submitting Desk Task…" : (submission == nil ? "Submit Desk Task" : "Retry Desk Task"))
                    }
                    .font(.body.weight(.semibold))
                    .frame(maxWidth: .infinity)
                }
                .alivePrimaryButton()
                .controlSize(.large)
                .disabled(title.isEmpty || objective.isEmpty || isSubmitting)
                .accessibilityLabel(isSubmitting ? "Submitting Desk task" : (submission == nil ? "Submit Desk task" : "Retry Desk task"))
            }
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
        Text(DeskStatusWords.word(for: status))
            .font(.caption)
            .fontWeight(.medium)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(NativeAgentMobileTheme.Colors.quietFill)
            .foregroundStyle(NativeAgentMobileTheme.Colors.readingSecondary)
            .clipShape(Capsule())
    }
}
