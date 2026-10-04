import SwiftUI
import NativeAgentShared
import NotificationInbox
import WorkshopExecution

struct MacWorkOverviewDetail: View {
    @Environment(AppModel.self) private var appModel
    let row: WorkOverviewRow
    let capturedAt: String
    let onDone: () -> Void
    @State private var inboxItem: InboxItemRecord?
    @State private var execution: WorkshopExecutionRecord?
    @State private var loaded = false
    @State private var error: String?
    @State private var deciding = false
    @State private var actionFlight = InboxRowActionFlight()
    @State private var group: InboxRelatedGroup?

    var body: some View {
        PageSheetHost(title: row.title, onDone: onDone) {
            if row.reference.kind == .approval {
                ApprovalsView(focusedID: row.reference.id)
            } else if row.reference.kind == .inbox {
                if let item = inboxItem {
                    InboxItemDetailSheet(item: item, onAction: { action in
                        await actionFlight.perform {
                            try await appModel.client.inboxAction(item.id, action: action)
                        }
                    }, onOpenGroup: { group = $0 }, closesOnGroupSelection: false, onClose: onDone)
                } else {
                    Text(error ?? (loaded ? "This note is no longer available." : "Reading the note…"))
                }
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        Text(row.stateLabel(at: Date())).font(.headline)
                        if let location = row.location { Text(location).font(.caption) }
                        if let execution {
                            // The canonical record, never the clipped copy.
                            Text(WorkOverviewRead.text(for: execution)).textSelection(.enabled)
                        } else {
                            Text(row.detail).textSelection(.enabled)
                            if MobileDeskProjectionBounds.isClipped(row.detail) {
                                Text("This reading copy is cut off.").font(.caption)
                            }
                            if !capturedAt.isEmpty {
                                Text("Reading copy captured \(capturedAt)").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        if loaded, execution == nil, row.state == "Decision needed" {
                            Text("This decision is no longer available.").foregroundStyle(.secondary)
                        }
                        if let execution, execution.status == "blocked_on_approval" {
                            HStack {
                                Button("Deny") { decide(execution, approve: false) }
                                Button("Approve") { decide(execution, approve: true) }
                            }
                            .disabled(deciding || execution.currentStepId.isEmpty)
                        }
                        if let error { Text(error).foregroundStyle(.red) }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading).padding()
                }
            }
        }
        .sheet(item: $group) { group in
            PageSheetHost(title: group.title, onDone: { self.group = nil }) {
                InboxView(initialGroup: group)
            }
        }
        .task {
            do {
                if row.reference.kind == .inbox {
                    inboxItem = try await appModel.engine.inbox.list().first { $0.id == row.reference.id }
                } else if row.reference.kind == .execution {
                    let board = await appModel.engine.desk.loadBoard()
                    if let reason = board.executions.unavailableReason { error = reason }
                    execution = board.executions.items.first { $0.id == row.reference.id }
                }
            } catch { self.error = error.localizedDescription }
            loaded = true
        }
    }

    private func decide(_ execution: WorkshopExecutionRecord, approve: Bool) {
        deciding = true
        Task {
            defer { deciding = false }
            do {
                if approve {
                    self.execution = try await appModel.client.approveStep(executionId: execution.id, stepId: execution.currentStepId)
                } else {
                    self.execution = try await appModel.client.rejectStep(executionId: execution.id, stepId: execution.currentStepId)
                }
                onDone()
            } catch { self.error = error.localizedDescription }
        }
    }
}
