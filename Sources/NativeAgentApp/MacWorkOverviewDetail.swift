import SwiftUI
import ApprovalTransactions
import NativeAgentShared
import NotificationInbox
import WorkshopExecution

// Blueprint: | `MacWorkOverviewDetail.swift` | `MacWorkOverviewDetail`: canonical work detail and decision actions, never the clipped overview copy |

struct MacWorkOverviewDetail: View {
    @Environment(AppModel.self) private var appModel
    let reference: WorkOverviewReference
    let onDone: () -> Void
    @State private var loaded = false
    @State private var error: String?
    @State private var deciding = false
    @State private var actionFlight = InboxRowActionFlight()
    @State private var group: InboxRelatedGroup?

    private var inboxItem: InboxItemRecord? {
        appModel.engine.inbox.items.first { $0.id == reference.id }
    }
    private var execution: WorkshopExecutionRecord? {
        appModel.engine.desk.board.executions.items.first { $0.id == reference.id }
    }

    private var deskRow: WorkOverviewRow? {
        appModel.engine.desk.board.items.first { $0.handle == reference.id }
            .map { WorkOverviewRead.row(for: $0, now: Date()) }
    }
    private var title: String? {
        if reference.kind == .approval {
            return appModel.engine.approvals.records.first { $0.id == reference.id }?.title
        }
        if reference.kind == .inbox { return inboxItem?.title }
        if reference.kind == .desk { return deskRow?.title }
        return execution?.title
    }

    var body: some View {
        PageSheetHost(title: title, onDone: onDone) {
            if reference.kind == .approval {
                ApprovalsView(focusedID: reference.id)
            } else if reference.kind == .inbox {
                if let item = inboxItem {
                    InboxItemDetailSheet(item: item, onAction: { action in
                        await actionFlight.perform {
                            try await InboxCardActions.perform(item.id, action: action,
                                dataRootOverride: appModel.engine.dataRoot, effects: AppInboxCardActionEffects(inbox: appModel.engine.inbox))
                        }
                    }, onOpenGroup: { group = $0 }, closesOnGroupSelection: false, onClose: onDone)
                } else {
                    Text(error ?? (loaded ? "This note is no longer available." : "Reading the note…"))
                }
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        if let execution {
                            let row = WorkOverviewRead.row(for: execution, now: Date())
                            Text(row.stateLabel(at: Date())).font(.headline)
                            if let location = row.location { Text(location).font(.caption) }
                            // The canonical record, never the clipped copy.
                            Text(WorkOverviewRead.text(for: execution)).textSelection(.enabled)
                            if execution.status == "blocked_on_approval" {
                                HStack {
                                    Button("Deny") { decide(execution, approve: false) }
                                    Button("Approve") { decide(execution, approve: true) }
                                }
                                .disabled(deciding || execution.currentStepId.isEmpty)
                            }
                        } else if reference.kind == .desk, let row = deskRow {
                            Text(row.stateLabel(at: Date())).font(.headline)
                            if let location = row.location { Text(location).font(.caption) }
                            Text(row.detail).textSelection(.enabled)
                            if MobileDeskProjectionBounds.isClipped(row.detail) {
                                Text("This reading copy is cut off.").font(.caption)
                            }
                            if let capturedAt = appModel.engine.desk.board.overview?.capturedAt, !capturedAt.isEmpty {
                                Text("Reading copy captured \(capturedAt)").font(.caption).foregroundStyle(.secondary)
                            }
                        } else {
                            Text(appModel.engine.desk.board.executions.unavailableReason
                                ?? "This decision is no longer available.").foregroundStyle(.secondary)
                        }
                        if let error { Text(error).foregroundStyle(.red) }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading).padding()
                }
            }
        }
        .task(id: reference) {
            if reference.kind == .inbox {
                loaded = false
                await appModel.refreshForSidebarItem(.activity)
                loaded = true
            }
        }
        .sheet(item: $group) { group in
            PageSheetHost(title: group.title, onDone: { self.group = nil }) {
                InboxView(initialGroup: group)
            }
        }
    }

    private func decide(_ execution: WorkshopExecutionRecord, approve: Bool) {
        deciding = true
        Task {
            defer { deciding = false }
            do {
                _ = try await ApprovalExecution.resolveWorkshopStep(
                    executionId: execution.id, stepId: execution.currentStepId,
                    decision: approve ? "approve" : "reject")
                onDone()
            } catch { self.error = UserFacingError.message(error, action: "\(approve ? "approve" : "reject") that step") }
        }
    }
}
