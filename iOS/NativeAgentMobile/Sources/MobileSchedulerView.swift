import SwiftUI
import NativeAgentShared

struct MobileSchedulerView: View {
    @ObservedObject private var sync = iCloudSyncEngine.shared
    @EnvironmentObject private var pairingStore: PairingStore
    @State private var showingCreate = false

    var body: some View {
        AlivePage(title: "Scheduler", line: "Things set to happen later on your Mac.", freshnessGroup: "scheduler") {
            if !pairingStore.isPaired { AliveUnpairedReason() }
            if let error = sync.schedulerError {
                AliveSection("Schedule unavailable") { Text(error).aliveRow() }
            }
            if let snapshot = sync.schedulerSnapshot {
                if snapshot.jobs.isEmpty {
                    AliveCalmState(title: "No scheduled jobs", line: "Create a job to set something to happen later.")
                } else {
                    AliveSection("Jobs") {
                        ForEach(Array(snapshot.jobs.enumerated()), id: \.element.id) { index, job in
                            if index > 0 { AliveDivider() }
                            NavigationLink {
                                MobileSchedulerJobDetail(jobID: job.id)
                            } label: {
                                AliveRow(job.name, detail: "\(job.kind) · \(job.schedulerState)\n\(job.schedule)\nNext run: \(job.enabled ? schedulerDate(job.nextRunAt) : "Not scheduled")\nLast run: \(schedulerDate(job.lastRunAt)) · \(job.lastRunStatus ?? "Not run yet")") {
                                    AliveChevron()
                                }
                            }
                            .aliveRowButtonStyle()
                        }
                    }
                }
            } else if sync.schedulerError == nil {
                ProgressView("Loading schedule").aliveRow()
            }
            AliveSection("Create") {
                Button("Create job") { showingCreate = true }
                    .disabled(!pairingStore.isPaired)
                    .aliveRow()
            }
        }
        .macSyncErrorBanner()
        .task { await sync.refreshSchedulerSnapshot() }
        .refreshable { await sync.refreshSchedulerSnapshot() }
        .sheet(isPresented: $showingCreate) {
            NavigationStack { MobileSchedulerCreateView() }
                .environmentObject(pairingStore)
        }
    }
}

private struct MobileSchedulerJobDetail: View {
    let jobID: String
    @ObservedObject private var sync = iCloudSyncEngine.shared
    @EnvironmentObject private var pairingStore: PairingStore
    @State private var saving = false
    @State private var confirmingCancel = false
    @State private var failure: String?
    @State private var receipt: String?

    private var job: MobileSchedulerJob? {
        sync.schedulerSnapshot?.jobs.first { $0.id == jobID }
    }

    var body: some View {
        AlivePage(title: job?.name ?? "Scheduled job", line: "Schedule and last run from your Mac.", freshnessGroup: "scheduler") {
            if let job {
                AliveSection("Schedule") {
                    LabeledContent("Kind", value: job.kind).aliveRow()
                    LabeledContent("Status", value: job.schedulerState).aliveRow()
                    Text(job.schedule).aliveRow()
                    LabeledContent("Next run", value: job.enabled ? schedulerDate(job.nextRunAt) : "Not scheduled").aliveRow()
                    LabeledContent("Last run", value: schedulerDate(job.lastRunAt)).aliveRow()
                    LabeledContent("Last status", value: job.lastRunStatus ?? "Not run yet").aliveRow()
                }
                AliveSection("Controls") {
                    Toggle("Enabled", isOn: Binding(
                        get: { job.enabled },
                        set: { enabled in change(enabled ? "resume_scheduler_job" : "pause_scheduler_job") }
                    ))
                    .hazeTinted()
                    .disabled(saving || !pairingStore.isPaired)
                    .aliveRow()
                    Button("Cancel job", role: .destructive) { confirmingCancel = true }
                        .disabled(saving || !pairingStore.isPaired)
                        .aliveRow()
                    if saving { ProgressView("Saving…").aliveRow() }
                    if let receipt { Text(receipt).aliveRow() }
                }
            } else {
                AliveCalmState(title: "Job unavailable", line: "This job is no longer in the Mac’s published schedule.")
            }
            if let failure {
                AliveSection("Could not change job") { Text(failure).aliveRow() }
            }
            if let error = sync.schedulerError {
                AliveSection("Schedule unavailable") { Text(error).aliveRow() }
            }
        }
        .macSyncErrorBanner()
        .refreshable { await sync.refreshSchedulerSnapshot() }
        .confirmationDialog("Cancel job?", isPresented: $confirmingCancel, titleVisibility: .visible) {
            Button("Cancel job", role: .destructive) { change("cancel_scheduler_job") }
            Button("Keep job", role: .cancel) { }
        } message: {
            Text("This stops future runs of this job. It does not stop a run already in progress.")
        }
    }

    private func change(_ action: String) {
        guard !saving, pairingStore.isPaired else { return }
        saving = true
        failure = nil
        receipt = nil
        Task { @MainActor in
            do {
                let recovered = try await sync.changeSchedulerJob(action: action, payload: ["id": jobID])
                receipt = "\(recovered.name) is \(recovered.schedulerState.lowercased()) on the Mac."
            } catch {
                failure = error.localizedDescription
            }
            saving = false
        }
    }

}

private func schedulerDate(_ value: String?) -> String {
    guard let value, !value.isEmpty else { return "Not available" }
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    let fractional = formatter.date(from: value)
    formatter.formatOptions = [.withInternetDateTime]
    guard let date = fractional ?? formatter.date(from: value) else { return value }
    return date.formatted(date: .abbreviated, time: .shortened)
}

private struct MobileSchedulerCreateView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var pairingStore: PairingStore
    @State private var name = ""
    @State private var kind = "notify"
    @State private var interval = "3600"
    @State private var message = ""
    @State private var saving = false
    @State private var failure: String?

    private var valid: Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 160,
              let seconds = Int64(interval), (60...315_360_000).contains(seconds) else { return false }
        return kind != "notify" || (!message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && message.count <= 1000)
    }

    var body: some View {
        AlivePage(title: "Create job", line: "Your Mac saves and runs this schedule.") {
            AliveSection("Job") {
                TextField("Name", text: $name).aliveRow()
                Picker("Kind", selection: $kind) {
                    Text("Notification").tag("notify")
                    Text("Reflection").tag("dream")
                    Text("REM consolidation").tag("rem")
                    Text("Self-improvement").tag("improve")
                }
                .aliveRow()
                TextField("Interval (seconds)", text: $interval)
                    .keyboardType(.numberPad)
                    .aliveRow()
                if kind == "notify" {
                    TextField("Notification message", text: $message, axis: .vertical).aliveRow()
                }
            }
            if let failure {
                AliveSection("Could not create job") { Text(failure).aliveRow() }
            }
            AliveSection("Save") {
                Button("Create job") { create() }
                    .disabled(!valid || saving || !pairingStore.isPaired)
                    .aliveRow()
                if saving { ProgressView("Saving…").aliveRow() }
            }
        }
        .disabled(saving)
        .interactiveDismissDisabled(saving)
        .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.disabled(saving) } }
    }

    private func create() {
        guard valid, !saving, pairingStore.isPaired else { return }
        saving = true
        failure = nil
        Task { @MainActor in
            do {
                _ = try await iCloudSyncEngine.shared.changeSchedulerJob(
                    action: "create_scheduler_job",
                    payload: ["name": name, "kind": kind, "interval_seconds": interval, "message": message]
                )
                dismiss()
            } catch {
                failure = error.localizedDescription
            }
            saving = false
        }
    }
}

private extension MobileSchedulerJob {
    var schedulerState: String {
        if cancelledAt != nil { return "Cancelled" }
        return enabled ? "Enabled" : "Paused"
    }
}
