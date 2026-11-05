import SwiftUI
import AgentConversations
import ApprovalTransactions
import NativeAgentShared
import NotificationInbox

// Blueprint: | `MacWorkOverviewDetail.swift` | Work detail reads canonical work owners; inbox and approval destinations draw the shared Inbox face |

struct MacWorkOverviewDetail: View {
    @Environment(AppModel.self) private var appModel
    let reference: WorkOverviewReference
    let onDone: () -> Void

    private var inboxItem: InboxItemRecord? {
        appModel.engine.inbox.items.first { $0.id == reference.id }
    }
    private var job: AgentJob? {
        guard reference.kind == .execution else { return nil }
        return appModel.engine.desk.board.agentJobs.items.first { $0.id == reference.id }
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
        return job.map { WorkOverviewRead.row(for: $0, now: Date()).title }
    }

    var body: some View {
        PageSheetHost(title: title, onDone: onDone) {
            if reference.kind == .approval || reference.kind == .inbox {
                FacePageView(page: "inbox")
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        if let job {
                            let row = WorkOverviewRead.row(for: job, now: Date())
                            Text(row.stateLabel(at: Date())).font(.headline)
                            if let location = row.location { Text(location).font(.caption) }
                            if let request = job.request { Text("Asking: \(request.title)").font(.subheadline) }
                            Text(WorkOverviewRead.text(for: job)).textSelection(.enabled)
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
                            Text(appModel.engine.desk.board.agentJobs.unavailableReason
                                ?? "This work is no longer available.").foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading).padding()
                }
            }
        }
    }
}
