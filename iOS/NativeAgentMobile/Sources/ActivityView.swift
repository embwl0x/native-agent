// PATCH-2026-05-10: sidebar-flatten — top-level "Activity" tab that merges
// Approvals + Inbox + Memory Proposals + Self-Improvement proposals into one
// "needs your eyes" landing.
//
// PATCH-2026-06-06: activity-flatten iOS parity — show top 2 pending items
// per section inline with approve/deny right on the landing page (mirrors
// the Mac SidebarFlattenViews ActivityView). Each section header still
// drills into its owning queue. Inline cards call the same iCloudSyncEngine
// action methods as the full views.
//
// Counts come from:
//   • ApprovalsStore  — tabBadge (pending count)
//   • InboxStore      — tabBadge (unread count)
//   • iCloudSyncEngine.memoryProposals
//   • iCloudSyncEngine.trainingProposals + .promotionCandidates
import SwiftUI
import NativeAgentShared

// Which sub-queue ActivityView is currently drilled into. iOS doesn't have
// the Cmd+Shift shortcuts that Mac uses, but keeping the enum keeps the
// navigation pattern symmetric and ready for deep-link plumbing.
enum ActivitySection: String, CaseIterable, Hashable {
    case approvals
    case inbox
    case memoryProposals
    case selfImprovement
}

/// The one presentation seam for the Activity tab and its badge. Keeping the
/// count and affordance rules here prevents the tab from telling a different
/// story than the four rows it opens.
enum ActivityScreenPresentation {
    struct Counts: Equatable {
        let approvals: Int
        let inbox: Int
        let memoryProposals: Int
        let selfImprovement: Int

        var total: Int { approvals + inbox + memoryProposals + selfImprovement }
    }

    enum SectionCountState: Equatable {
        case unavailable
        case clear
        case pending(Int)
    }

    static func sectionCountState(for count: Int?) -> SectionCountState {
        guard let count else { return .unavailable }
        return count > 0 ? .pending(count) : .clear
    }

    /// Activity's Memory Proposals drill-in must enter the corresponding
    /// segment, rather than the Memories default used by the root tab.
    static func memoryInitialSegment(for section: ActivitySection) -> MemoryView.MemorySegment {
        switch section {
        case .memoryProposals: return .proposals
        case .approvals, .inbox, .selfImprovement: return .memories
        }
    }

    static func counts(
        storedApprovals: Int,
        snapshotApprovals: [ApprovalRequest],
        storedInbox: Int,
        snapshotInbox: [InboxItemRecord],
        memoryProposals: [MemoryProposalRecord],
        trainingProposals: [TrainingProposalSummary],
        promotionCandidates: [PromotionCandidateSummary]
    ) -> Counts {
        counts(
            storedApprovals: storedApprovals,
            snapshotApprovalsPending: snapshotApprovals.filter { $0.status.lowercased() == "pending" }.count,
            storedInbox: storedInbox,
            snapshotInboxPending: snapshotInbox.filter {
                let status = $0.status.lowercased()
                return status == "unread" || status == "active"
            }.count,
            memoryProposalsPending: memoryProposals.filter(\.isPending).count,
            trainingProposalsPending: trainingProposals.filter(\.isHumanActionable).count,
            promotionCandidatesPending: promotionCandidates.filter(\.isHumanActionable).count
        )
    }

    static func counts(
        storedApprovals: Int,
        snapshotApprovalsPending: Int,
        storedInbox: Int,
        snapshotInboxPending: Int,
        memoryProposalsPending: Int,
        trainingProposalsPending: Int,
        promotionCandidatesPending: Int
    ) -> Counts {
        Counts(
            approvals: max(storedApprovals, snapshotApprovalsPending),
            inbox: max(storedInbox, snapshotInboxPending),
            memoryProposals: memoryProposalsPending,
            selfImprovement: trainingProposalsPending + promotionCandidatesPending
        )
    }

    /// A partial approval record must never unlock a remote decision. Older
    /// snapshots without these fields remain readable, but are Mac-only until
    /// the canonical authority explicitly says the decision is resolvable.
    static func canDecideRemotely(localOnly: Bool?, remoteResolvable: Bool?) -> Bool {
        localOnly == false && remoteResolvable == true
    }

    /// Preserve wire order for ordinary actions, but make a resolving action
    /// reachable even when a writer reorders the action array.
    static func visibleInboxActions(_ actions: [InboxActionRecord], limit: Int = 2) -> [InboxActionRecord] {
        let actionable = actions.filter { $0.id != "view" && $0.id != "read" }
        let primary = actionable.filter { isPrimaryInboxAction($0.id) }
        let secondary = actionable.filter { !isPrimaryInboxAction($0.id) }
        return Array((primary + secondary).prefix(limit))
    }

    static func isPrimaryInboxAction(_ actionID: String) -> Bool {
        ["act", "approve", "open_approvals", "repair"].contains(actionID)
    }

    static func showsOverflow(total: Int, visibleCount: Int = 2) -> Bool {
        total > visibleCount
    }

    /// Notification-open suppression is consumed once. Leaving the latch set
    /// after a cancelled appearance would otherwise skip the next real refresh.
    static func shouldRefreshOnAppear(skipInitialRefresh: inout Bool) -> Bool {
        guard skipInitialRefresh else { return true }
        skipInitialRefresh = false
        return false
    }

    /// Activity owns the surrounding NavigationStack, so every pushed queue
    /// must render as its content rather than creating a stack that can bounce
    /// the destination back to the Activity list.
    static func destinationEmbedsNavigationStack(for _: ActivitySection) -> Bool {
        false
    }

    /// A review request from another iOS surface must open the queue that can
    /// actually resolve it, rather than merely switching to Activity's summary.
    static func activityDestination(for notificationScreen: String) -> ActivitySection? {
        switch notificationScreen.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "approvals": return .approvals
        default: return nil
        }
    }
}

/// An action response and the next published snapshot arrive independently.
/// Once the user has decided an inline memory proposal, retain that decision
/// state until the row disappears from the Mac-owned snapshot so a stale row
/// cannot invite a duplicate accept/reject action.
enum InlineMemoryProposalDecisionPresentation {
    enum Decision: Equatable {
        case accept
        case reject
    }

    enum State: Equatable {
        case ready
        case deciding
        case awaitingPublication(Decision)
        case failed(String)

        var canDecide: Bool {
            switch self {
            case .ready, .failed: return true
            case .deciding, .awaitingPublication: return false
            }
        }

        var showsProgress: Bool {
            if case .deciding = self { return true }
            return false
        }

        var feedback: (message: String, isError: Bool)? {
            switch self {
            case .ready, .deciding:
                return nil
            case .awaitingPublication(.accept):
                return ("Accepted; waiting for the Mac/iCloud snapshot.", false)
            case .awaitingPublication(.reject):
                return ("Rejected; waiting for the Mac/iCloud snapshot.", false)
            case let .failed(message):
                return (message, true)
            }
        }
    }

    static func submitted(approve: Bool) -> State {
        .awaitingPublication(approve ? .accept : .reject)
    }
}

struct ActivityView: View {
    @EnvironmentObject private var approvalsStore: ApprovalsStore
    @EnvironmentObject private var inboxStore: InboxStore
    @ObservedObject private var sync = iCloudSyncEngine.shared
    @Binding var skipInitialRefresh: Bool
    @Binding var navigationTarget: ActivitySection?

    @State private var path = NavigationPath()
    // 2026-06-07: the inline inbox preview's "More" button used to push
    // ActivitySection.inbox onto `path`, which renders an InboxView() that
    // declares its OWN NavigationStack at the root. Pushing one
    // NavigationStack inside another's navigationDestination interacts
    // poorly with refresh-driven state churn on this branch — the user's
    // symptom was the destination flashing in then bouncing back to
    // Activity before he could read the dream. Avoid the fragile nested
    // navigation entirely: the user actually wants to *read* the dream,
    // not navigate to a list, so "More" now presents InboxDetailSheet
    // directly with the item.
    @State private var inboxDetailItem: InboxItemRecord?

    init(
        skipInitialRefresh: Binding<Bool> = .constant(false),
        navigationTarget: Binding<ActivitySection?> = .constant(nil)
    ) {
        self._skipInitialRefresh = skipInitialRefresh
        self._navigationTarget = navigationTarget
    }

    // MARK: - Pending slices

    private var pendingApprovals: [ApprovalRequest] {
        sync.approvals.filter { $0.status.lowercased() == "pending" }
    }

    private var pendingInbox: [InboxItemRecord] {
        sync.inboxItems.filter {
            let status = $0.status.lowercased()
            return status == "unread" || status == "active"
        }
    }

    private var pendingMemoryProposals: [MemoryProposalRecord] {
        sync.memoryProposals.filter(\.isPending)
    }

    private var pendingTrainingProposals: [TrainingProposalSummary] {
        sync.trainingProposals.filter(\.isHumanActionable)
    }

    private var pendingPromotionCandidates: [PromotionCandidateSummary] {
        sync.promotionCandidates.filter(\.isHumanActionable)
    }

    /// Empty arrays before the first completed snapshot are an absence of
    /// evidence, not proof that a section is clear. Once the engine has a
    /// measured snapshot, zero is rendered as the distinct "Clear" state.
    private var hasMeasuredActivityProjection: Bool {
        sync.lastSyncAt != nil
    }

    private var pendingApprovalsCount: Int? {
        hasMeasuredActivityProjection ? activityCounts.approvals : nil
    }

    private var pendingInboxCount: Int? {
        hasMeasuredActivityProjection ? activityCounts.inbox : nil
    }

    private var pendingMemoryProposalsCount: Int? {
        hasMeasuredActivityProjection ? activityCounts.memoryProposals : nil
    }

    private var pendingSelfImprovementCount: Int? {
        hasMeasuredActivityProjection ? activityCounts.selfImprovement : nil
    }

    private var activityCounts: ActivityScreenPresentation.Counts {
        ActivityScreenPresentation.counts(
            storedApprovals: approvalsStore.pendingCount,
            snapshotApprovals: sync.approvals,
            storedInbox: inboxStore.activeCount,
            snapshotInbox: sync.inboxItems,
            memoryProposals: sync.memoryProposals,
            trainingProposals: sync.trainingProposals,
            promotionCandidates: sync.promotionCandidates
        )
    }

    // MARK: - Body

    var body: some View {
        NavigationStack(path: $path) {
            List {
                approvalsSection
                inboxSection
                memoryProposalsSection
                selfImprovementSection
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Activity")
            // Sweep R4 C11.3 / C11.4 — render-only surfacing of state this
            // screen's own `sync` engine and the shared bridge client already
            // publish. No new polling.
            .macSyncErrorBanner()
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    MacStatusChip()
                }
            }
            .navigationDestination(for: ActivitySection.self) { section in
                // `embedInNavigationStack: false` — these destinations live
                // INSIDE Activity's NavigationStack; if they wrap themselves
                // in another one, the destination renders briefly then pops
                // back, leaving the user staring at a blank slide-out.
                // AutonomyView already doesn't wrap, so it's unchanged here.
                switch section {
                case .approvals:
                    ApprovalsView(
                        embedInNavigationStack: ActivityScreenPresentation.destinationEmbedsNavigationStack(for: .approvals)
                    )
                                            .environmentObject(approvalsStore)
                case .inbox:
                    InboxView(
                        embedInNavigationStack: ActivityScreenPresentation.destinationEmbedsNavigationStack(for: .inbox)
                    )
                                            .environmentObject(inboxStore)
                case .memoryProposals:
                    MemoryView(
                        initialSegment: ActivityScreenPresentation.memoryInitialSegment(for: section),
                        embedInNavigationStack: ActivityScreenPresentation.destinationEmbedsNavigationStack(for: .memoryProposals)
                    )
                case .selfImprovement:
                    AutonomyView()
                }
            }
            .refreshable {
                await sync.refreshActivitySnapshot()
            }
            .task {
                if !ActivityScreenPresentation.shouldRefreshOnAppear(skipInitialRefresh: &skipInitialRefresh) {
                    return
                }
                await sync.refreshActivitySnapshot()
            }
            .onChange(of: navigationTarget) { _, section in
                openRequestedSection(section)
            }
            .onAppear {
                openRequestedSection(navigationTarget)
            }
            // 2026-06-07: dream-card "More" → read the full dream right here.
            // Reuses InboxDetailSheet (the same sheet InboxView presents),
            // so dream / detail rendering stays consistent across both
            // surfaces.
            .sheet(item: $inboxDetailItem) { item in
                InboxDetailSheet(
                    item: item,
                    allItems: sync.inboxItems,
                    onOpenGroup: { _ in
                        // Group filtering only makes sense inside InboxView;
                        // here we just close the sheet so the user can drill
                        // through Activity → Inbox if they want that view.
                        inboxDetailItem = nil
                    },
                    onDone: { inboxDetailItem = nil }
                )
            }
        }
    }

    private func openRequestedSection(_ section: ActivitySection?) {
        guard let section else { return }
        path = NavigationPath()
        path.append(section)
        navigationTarget = nil
    }

    // MARK: - Sections

    @ViewBuilder
    private var approvalsSection: some View {
        Section {
            NavigationLink(value: ActivitySection.approvals) {
                ActivityCardRow(
                    title: "Approvals",
                    subtitle: "Tool calls waiting on you",
                    systemImage: "checkmark.shield",
                    tint: .orange,
                    count: pendingApprovalsCount
                )
            }
            ForEach(Array(pendingApprovals.prefix(2))) { approval in
                InlineApprovalPreviewCard(approval: approval) {
                    path.append(ActivitySection.approvals)
                }
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
            }
            if ActivityScreenPresentation.showsOverflow(total: pendingApprovals.count) {
                Button {
                    path.append(ActivitySection.approvals)
                } label: {
                    Label("All \(pendingApprovals.count) approvals", systemImage: "arrow.right")
                        .font(AppFont.label)
                        .foregroundStyle(.orange)
                }
                .buttonStyle(.plain)
            }
        } header: {
            Text("Needs your eyes").font(AppFont.section)
        }
    }

    @ViewBuilder
    private var inboxSection: some View {
        Section {
            NavigationLink(value: ActivitySection.inbox) {
                ActivityCardRow(
                    title: "Inbox",
                    subtitle: "Proactive cards from \(sync.personality?.name ?? "your agent")",
                    systemImage: "tray",
                    tint: .blue,
                    count: pendingInboxCount
                )
            }
            ForEach(Array(pendingInbox.prefix(2))) { item in
                InlineInboxPreviewCard(item: item) {
                    // 2026-06-07: present the detail sheet directly with
                    // the tapped item instead of pushing onto the parent
                    // NavigationPath — see comment on inboxDetailItem.
                    inboxDetailItem = item
                }
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
            }
            if ActivityScreenPresentation.showsOverflow(total: pendingInbox.count) {
                Button {
                    path.append(ActivitySection.inbox)
                } label: {
                    Label("All \(pendingInbox.count) inbox items", systemImage: "arrow.right")
                        .font(AppFont.label)
                        .foregroundStyle(.blue)
                }
                .buttonStyle(.plain)
            }
        }
    }

    @ViewBuilder
    private var memoryProposalsSection: some View {
        Section {
            NavigationLink(value: ActivitySection.memoryProposals) {
                ActivityCardRow(
                    title: "Memory Proposals",
                    subtitle: "Memories the agent wants to keep",
                    systemImage: "brain.head.profile",
                    tint: .purple,
                    count: pendingMemoryProposalsCount
                )
            }
            ForEach(Array(pendingMemoryProposals.prefix(2))) { proposal in
                InlineMemoryProposalPreviewCard(proposal: proposal)
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
            }
            if ActivityScreenPresentation.showsOverflow(total: pendingMemoryProposals.count) {
                Button {
                    path.append(ActivitySection.memoryProposals)
                } label: {
                    Label("All \(pendingMemoryProposals.count) memory proposals", systemImage: "arrow.right")
                        .font(AppFont.label)
                        .foregroundStyle(.purple)
                }
                .buttonStyle(.plain)
            }
        }
    }

    @ViewBuilder
    private var selfImprovementSection: some View {
        Section {
            NavigationLink(value: ActivitySection.selfImprovement) {
                ActivityCardRow(
                    title: "Self-Improvement",
                    subtitle: "Harness changes proposed by the agent",
                    systemImage: "wand.and.stars",
                    tint: .pink,
                    count: pendingSelfImprovementCount
                )
            }
            // Show top 2 training proposals; top up with promotion candidates
            // if we have fewer than 2 trainings.
            let trainings = Array(pendingTrainingProposals.prefix(2))
            ForEach(trainings) { proposal in
                InlineSelfImprovementPreviewCard(
                    title: proposal.targetDoc ?? proposal.title,
                    summary: proposal.proposed ?? proposal.rationale ?? "Training proposal.",
                    tint: .pink
                ) {
                    path.append(ActivitySection.selfImprovement)
                }
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
            }
            if trainings.count < 2 {
                let take = 2 - trainings.count
                ForEach(Array(pendingPromotionCandidates.prefix(take))) { candidate in
                    InlineSelfImprovementPreviewCard(
                        title: "Promotion \u{00b7} \(candidate.source ?? "candidate")",
                        summary: candidate.title,
                        tint: .pink
                    ) {
                        path.append(ActivitySection.selfImprovement)
                    }
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
                }
            }
            if let total = pendingSelfImprovementCount,
               ActivityScreenPresentation.showsOverflow(total: total) {
                Button {
                    path.append(ActivitySection.selfImprovement)
                } label: {
                    Label("All \(total) self-improvement items", systemImage: "arrow.right")
                        .font(AppFont.label)
                        .foregroundStyle(.pink)
                }
                .buttonStyle(.plain)
            }
        }
    }
}

// MARK: - Inline preview cards

/// Compact approval card with Approve / Deny / View. Mirrors the Mac
/// `InlineApprovalPreviewCard` but uses iCloudSyncEngine.shared for the
/// decision call (iOS has no AppModel).
private struct InlineApprovalPreviewCard: View {
    @EnvironmentObject private var approvalsStore: ApprovalsStore
    let approval: ApprovalRequest
    var onView: () -> Void

    @State private var isDeciding = false
    @State private var decisionStatusText: String?
    @State private var decisionStatusIsError = false

    private var isMacOnly: Bool {
        !ActivityScreenPresentation.canDecideRemotely(
            localOnly: approval.localOnly,
            remoteResolvable: approval.remoteResolvable
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "exclamationmark.shield.fill")
                    .foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 2) {
                    Text(approval.title.isEmpty ? approval.action : approval.title)
                        .font(AppFont.section)
                        .lineLimit(1)
                    Text(approval.action)
                        .font(AppFont.label)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                Text(approval.risk.uppercased())
                    .font(AppFont.tag)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(.orange, in: Capsule())
            }
            if let reason = approval.reason, !reason.isEmpty {
                Text(reason)
                    .font(AppFont.body)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            if let decisionStatusText {
                Text(decisionStatusText)
                    .font(.caption)
                    .foregroundStyle(decisionStatusIsError ? .red : .orange)
            }
            if isMacOnly {
                Label("Review this one on the Mac app", systemImage: "macwindow.badge.exclamationmark")
                    .font(AppFont.label)
                    .foregroundStyle(.orange)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack(spacing: 8) {
                if !isMacOnly {
                    Button {
                        decide(approve: true)
                    } label: {
                        Label("Approve", systemImage: "checkmark")
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.regular)
                    .tint(.green)
                    .disabled(isDeciding)

                    Button {
                        decide(approve: false)
                    } label: {
                        Label("Deny", systemImage: "xmark")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.regular)
                    .tint(.red)
                    .disabled(isDeciding)
                }

                Button {
                    onView()
                } label: {
                    Label("View", systemImage: "arrow.up.right.square")
                }
                .buttonStyle(.bordered)
                .controlSize(.regular)
                .disabled(isDeciding)

                if isDeciding {
                    ProgressView().controlSize(.small)
                }
                Spacer()
            }
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 12)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.orange.opacity(0.25), lineWidth: 1)
        }
    }

    private func decide(approve: Bool) {
        isDeciding = true
        decisionStatusText = nil
        decisionStatusIsError = false
        let id = approval.id
        Task {
            do {
                if approve {
                    _ = try await iCloudSyncEngine.shared.approveApproval(id: id)
                    iOSSystemToastCenter.shared.push(success: "Approval approved")
                } else {
                    _ = try await iCloudSyncEngine.shared.rejectApproval(id: id)
                    iOSSystemToastCenter.shared.push(info: "Approval denied")
                }
                await iCloudSyncEngine.shared.refreshActivitySnapshot()
                // gpt-5.5 review finding #3: re-hydrate the shared store so
                // the tab badge + parent ActivityView count drop in lockstep
                // with the inline preview disappearing.
                approvalsStore.applySyncedApprovalsFromSnapshot(animated: false, notifyNewPending: false)
            } catch {
                if iCloudSyncEngine.isMacResponseTimeout(error) {
                    decisionStatusText = "Decision sent; waiting for Mac/iCloud to publish the result."
                    decisionStatusIsError = false
                    iOSSystemToastCenter.shared.push(info: "Decision sent; still waiting on the Mac")
                    await iCloudSyncEngine.shared.refreshActivitySnapshot()
                    approvalsStore.applySyncedApprovalsFromSnapshot(animated: false, notifyNewPending: false)
                } else {
                    decisionStatusText = "Failed: \(error.localizedDescription)"
                    decisionStatusIsError = true
                }
            }
            isDeciding = false
        }
    }
}

/// Compact inbox card showing the top two non-`view`/`read` actions plus a
/// "More" button. The owning Activity view passes a callback that presents
/// the InboxDetailSheet directly with this card's item (the previous "drill
/// into InboxView" wiring bounced on iOS — see ActivityView.inboxDetailItem).
private struct InlineInboxPreviewCard: View {
    @EnvironmentObject private var inboxStore: InboxStore
    let item: InboxItemRecord
    var onMore: () -> Void

    @State private var runningActionID: String?
    @State private var errorText: String?

    private var topActions: [InboxActionRecord] {
        ActivityScreenPresentation.visibleInboxActions(item.actions)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: item.sourceIcon)
                    .foregroundStyle(item.severityColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.title)
                        .font(AppFont.section)
                        .lineLimit(1)
                    Text(item.sourceBadgeLabel)
                        .font(AppFont.tag)
                        .foregroundStyle(item.severityColor)
                }
                Spacer()
                Text(item.severity.uppercased())
                    .font(AppFont.tag)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(item.severityColor, in: Capsule())
            }
            if !item.summary.isEmpty {
                Text(item.summary)
                    .font(AppFont.body)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            if let errorText {
                Text(errorText)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
            HStack(spacing: 8) {
                ForEach(topActions, id: \.id) { action in
                    if ActivityScreenPresentation.isPrimaryInboxAction(action.id) {
                        Button {
                            runAction(action.id)
                        } label: {
                            Text(action.label)
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.regular)
                        .tint(.blue)
                        .disabled(runningActionID != nil)
                    } else {
                        Button {
                            runAction(action.id)
                        } label: {
                            Text(action.label)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.regular)
                        .disabled(runningActionID != nil)
                    }
                }
                Button {
                    onMore()
                } label: {
                    Label("More", systemImage: "ellipsis")
                }
                .buttonStyle(.bordered)
                .controlSize(.regular)
                .disabled(runningActionID != nil)

                if runningActionID != nil {
                    ProgressView().controlSize(.small)
                }
                Spacer()
            }
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 12)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(item.severityColor.opacity(0.25), lineWidth: 1)
        }
    }

    private func runAction(_ actionID: String) {
        runningActionID = actionID
        errorText = nil
        let id = item.id
        Task {
            do {
                _ = try await iCloudSyncEngine.shared.inboxAction(itemId: id, actionId: actionID)
                await iCloudSyncEngine.shared.refreshActivitySnapshot()
                // gpt-5.5 review finding #3: re-hydrate the shared store so
                // the tab badge stays consistent with the inline card's
                // disappearance.
                inboxStore.applySyncedInboxFromSnapshot(animated: false, notifyNewArrivals: false)
            } catch {
                errorText = "Action failed: \(error.localizedDescription)"
            }
            runningActionID = nil
        }
    }
}

/// Compact memory-proposal card with Accept / Reject. Calls the same
/// iCloudSyncEngine methods as the full Memory view.
private struct InlineMemoryProposalPreviewCard: View {
    let proposal: MemoryProposalRecord

    @State private var decisionState: InlineMemoryProposalDecisionPresentation.State = .ready

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "brain.head.profile")
                    .foregroundStyle(.purple)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Memory proposal")
                        .font(AppFont.section)
                    if let layer = proposal.layer, !layer.isEmpty {
                        Text(layer)
                            .font(AppFont.label)
                            .foregroundStyle(.secondary)
                    }
                    Text(proposal.evidenceSummary)
                        .font(AppFont.label)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            Text(proposal.displayText ?? proposal.text)
                .font(AppFont.body)
                .lineLimit(3)
                .textSelection(.enabled)
            if let feedback = decisionState.feedback {
                Text(feedback.message)
                    .font(.caption)
                    .foregroundStyle(feedback.isError ? .red : .purple)
            }
            HStack(spacing: 8) {
                Button {
                    decide(approve: true)
                } label: {
                    Label("Accept", systemImage: "checkmark")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
                .tint(.purple)
                .disabled(!decisionState.canDecide)

                Button {
                    decide(approve: false)
                } label: {
                    Label("Reject", systemImage: "xmark")
                }
                .buttonStyle(.bordered)
                .controlSize(.regular)
                .tint(.red)
                .disabled(!decisionState.canDecide)

                if decisionState.showsProgress {
                    ProgressView().controlSize(.small)
                }
                Spacer()
            }
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 12)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.purple.opacity(0.25), lineWidth: 1)
        }
    }

    private func decide(approve: Bool) {
        guard decisionState.canDecide else { return }
        decisionState = .deciding
        let id = proposal.id
        Task {
            do {
                if approve {
                    _ = try await iCloudSyncEngine.shared.approveMemoryProposal(proposalId: id)
                    iOSSystemToastCenter.shared.push(success: "Memory accepted")
                } else {
                    _ = try await iCloudSyncEngine.shared.rejectMemoryProposal(proposalId: id)
                    iOSSystemToastCenter.shared.push(info: "Memory rejected")
                }
                decisionState = InlineMemoryProposalDecisionPresentation.submitted(approve: approve)
                await iCloudSyncEngine.shared.refreshActivitySnapshot()
            } catch {
                if iCloudSyncEngine.isMacResponseTimeout(error) {
                    decisionState = InlineMemoryProposalDecisionPresentation.submitted(approve: approve)
                    iOSSystemToastCenter.shared.push(info: "Decision sent; still waiting on the Mac")
                    await iCloudSyncEngine.shared.refreshActivitySnapshot()
                } else {
                    decisionState = .failed("Failed: \(error.localizedDescription)")
                }
            }
        }
    }
}

/// Compact self-improvement card. View-only — actual approve/reject lives
/// in the Autonomy view because the proposal types fan out into multiple
/// buckets (training, promotion candidates).
private struct InlineSelfImprovementPreviewCard: View {
    let title: String
    let summary: String
    let tint: Color
    var onView: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "wand.and.stars")
                    .foregroundStyle(tint)
                Text(title)
                    .font(AppFont.section)
                    .lineLimit(1)
                Spacer()
            }
            Text(summary)
                .font(AppFont.body)
                .foregroundStyle(.secondary)
                .lineLimit(3)
            Label("Apply changes on the Mac", systemImage: "macwindow.badge.exclamationmark")
                .font(AppFont.label)
                .foregroundStyle(.secondary)
            HStack(spacing: 8) {
                Button {
                    onView()
                } label: {
                    Label("View", systemImage: "arrow.up.right.square")
                }
                .buttonStyle(.bordered)
                .controlSize(.regular)
                Spacer()
            }
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 12)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(tint.opacity(0.25), lineWidth: 1)
        }
    }
}

// MARK: - Drill-down row (kept from the previous ActivityView)

private struct ActivityCardRow: View {
    let title: String
    let subtitle: String
    let systemImage: String
    let tint: Color
    let count: Int?

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: systemImage)
                .font(.title3)
                .foregroundStyle(tint)
                .frame(width: 32)

            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(AppFont.section)
                Text(subtitle)
                    .font(AppFont.label)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            switch ActivityScreenPresentation.sectionCountState(for: count) {
            case .pending(let count):
                Text("\(count)")
                    .font(AppFont.label)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .background(tint, in: Capsule())
            case .clear:
                Text("Clear")
                    .font(AppFont.tag)
                    .foregroundStyle(.secondary)
            case .unavailable:
                Text("Syncing")
                    .font(AppFont.tag)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }
}
