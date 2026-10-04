import SwiftUI
import NativeAgentShared

/// Both phone landing pages render the Mac's projection, without reconstructing
/// asks from unread counts or work from open-item counts.
struct MobileWorkOverviewView: View {
    @ObservedObject private var sync = iCloudSyncEngine.shared
    @State private var selected: WorkOverviewRow?

    private var deadlines: [Date] {
        [Date()] + (sync.workOverview?.now ?? []).compactMap {
            DeskActivityState.movementDate($0.movementAt)?.addingTimeInterval(DeskActivityState.movementWindow)
        }.filter { $0 > Date() }.sorted()
    }

    var body: some View {
        TimelineView(.explicit(deadlines)) { context in
            if let overview = sync.workOverview {
                ForEach(overview.unavailable, id: \.self) { AliveFootnote($0) }
                section("Now", rows: overview.now, now: context.date)
                section("Needs you", rows: overview.needsYou, now: context.date, waiting: true)
                if let overflow = overview.needsYouOverflow { AliveFootnote(overflow) }
                section("Recently done", rows: overview.recentlyDone, now: context.date)
                if overview.omittedNow > 0 || overview.omittedRecentlyDone > 0 {
                    AliveFootnote("\(overview.omittedNow) other work items and \(overview.omittedRecentlyDone) older results remain in Desk tasks and history.")
                }
                AliveFootnote("Reading copy captured \(AliveWords.relative(overview.capturedAt) ?? overview.capturedAt).")
            } else {
                AliveFootnote("The overview is unavailable. Refresh from your Mac to read it.")
            }
        }
        .sheet(item: $selected) { row in
            MobileWorkOverviewDetail(row: row, capturedAt: sync.workOverview?.capturedAt ?? "")
        }
    }

    private func section(_ title: String, rows: [WorkOverviewRow], now: Date, waiting: Bool = false) -> some View {
        AliveSection(title, surface: waiting ? .waiting : .card) {
            if rows.isEmpty { Text("Nothing here.").foregroundStyle(AlivePalette.secondary).aliveRow() }
            ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                if index > 0 { AliveDivider() }
                Button { selected = row } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(row.title).font(.headline).foregroundStyle(AlivePalette.text)
                            Text(row.summary).font(.subheadline).foregroundStyle(AlivePalette.secondary).lineLimit(3)
                            Text([row.stateLabel(at: now), row.location].compactMap { $0 }.joined(separator: " · "))
                                .font(.caption).foregroundStyle(AlivePalette.secondary)
                        }
                        .multilineTextAlignment(.leading)
                        Spacer(minLength: 8)
                        AliveChevron()
                    }
                    .aliveRow().contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }
}

private struct MobileWorkOverviewDetail: View {
    let row: WorkOverviewRow
    let capturedAt: String
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var pairingStore: PairingStore
    @EnvironmentObject private var bridgeClient: MacBridgeClient
    @ObservedObject private var sync = iCloudSyncEngine.shared
    @StateObject private var approvals = ApprovalsStore()
    @StateObject private var workshop = WorkshopStore()
    @StateObject private var inbox = InboxStore()
    @State private var deskError: String?
    @State private var group: InboxRelatedGroup?
    @State private var inboxDetail: InboxItemRecord?

    var body: some View {
        Group {
            switch row.reference.kind {
            case .desk:
                if let item = sync.deskItems.first(where: { $0.handle == row.reference.id }) {
                    MobileDeskItemDetail(item: item, errorMessage: $deskError)
                        .alert("Desk", isPresented: Binding(
                            get: { deskError != nil },
                            set: { if !$0 { deskError = nil } }
                        )) {
                            Button("OK") { deskError = nil }
                        } message: {
                            Text(deskError ?? "")
                        }
                } else {
                    unavailable("This Desk item is unavailable in the current snapshot.\n\nReading copy:\n\(row.detail)")
                }
            case .approval:
                NavigationStack {
                    ScrollView {
                        if let approval = approvals.approvals.first(where: { $0.id == row.reference.id }) {
                            if approval.status.lowercased() == "pending" {
                                ApprovalCard(approval: approval, isDeciding: approvals.decidingApprovalIDs.contains(approval.id)) { decision in
                                    Task { await approvals.decide(id: approval.id, decision: decision,
                                        client: bridgeClient, pairingStore: pairingStore) }
                                }
                                .padding()
                            } else {
                                ResolvedRow(approval: approval).padding()
                            }
                        } else { Text("This decision is unavailable in the current snapshot.").padding() }
                        if let error = approvals.bannerError { Text(error).foregroundStyle(.red).padding() }
                    }
                    .navigationTitle(row.title)
                    .toolbar { Button("Done") { dismiss() } }
                }
            case .inbox:
                if let item = inbox.items.first(where: { $0.id == row.reference.id }) {
                    NavigationStack {
                        ScrollView {
                            InboxCardRow(item: item, onAction: { action in
                                Task { await inbox.performAction(id: item.id, actionID: action,
                                    client: bridgeClient, pairingStore: pairingStore) }
                            }, onView: { inboxDetail = item })
                            .padding()
                            if let error = inbox.bannerError { Text(error).foregroundStyle(.red).padding() }
                        }
                        .navigationTitle(row.title)
                        .toolbar { Button("Done") { dismiss() } }
                    }
                } else { unavailable("This note is unavailable in the current snapshot.") }
            case .execution:
                if row.state == "Decision needed",
                   let task = sync.workshopTasks.first(where: { $0.id == row.reference.id }) {
                    WorkshopTaskDetailSheet(task: task, store: workshop)
                        .alert("Error", isPresented: .constant(workshop.error != nil), actions: {
                            Button("OK") { workshop.error = nil }
                        }, message: {
                            Text(workshop.error ?? "")
                        })
                } else {
                    NavigationStack {
                        ScrollView {
                            VStack(alignment: .leading, spacing: 12) {
                                Text(row.stateLabel(at: Date())).font(.headline)
                                if let location = row.location { Text(location).font(.caption) }
                                Text(row.detail).textSelection(.enabled)
                                if row.state == "Decision needed" {
                                    AliveFootnote("This decision is unavailable in the current snapshot. Refresh from your Mac to check it.")
                                }
                                if MobileDeskProjectionBounds.isClipped(row.detail) {
                                    AliveFootnote("This reading copy is cut off. The full record remains on the Mac.")
                                }
                                AliveFootnote("Reading copy captured \(capturedAt).")
                            }.frame(maxWidth: .infinity, alignment: .leading).padding()
                        }
                        .navigationTitle(row.title)
                        .toolbar { Button("Done") { dismiss() } }
                    }
                }
            }
        }
        .sheet(item: $inboxDetail) { item in
            InboxDetailSheet(item: item, allItems: inbox.items,
                onOpenGroup: { group = $0 }, onDone: { inboxDetail = nil })
                .sheet(item: $group) { group in
                    InboxView(initialGroup: group).environmentObject(inbox)
                }
        }
        .task {
            if row.reference.kind == .approval { await sync.refreshApprovalsSnapshot() }
            approvals.applySyncedApprovalsFromSnapshot(animated: false, notifyNewPending: false)
            workshop.applySyncedTasks(sync.workshopTasks)
            inbox.applySyncedInboxFromSnapshot(animated: false, notifyNewArrivals: false)
        }
        .onChange(of: sync.approvals) { approvals.applySyncedApprovalsFromSnapshot(animated: false, notifyNewPending: false) }
        .onChange(of: sync.workshopTasks) { workshop.applySyncedTasks(sync.workshopTasks) }
        .onChange(of: sync.inboxItems) { inbox.applySyncedInboxFromSnapshot(animated: false, notifyNewArrivals: false) }
    }

    private func unavailable(_ text: String) -> some View {
        NavigationStack {
            Text(text).padding().toolbar { Button("Done") { dismiss() } }
        }
    }
}
