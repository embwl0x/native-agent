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

    /// Signed, paired iOS may decide owner cards regardless of origin or flags.
    /// Studio canon belongs to Agent; the Mac enforces the same exception.
    static func canDecideRemotely(action: String) -> Bool {
        action != "studio.canon"
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
    @EnvironmentObject private var bridgeClient: MacBridgeClient
    @EnvironmentObject private var pairingStore: PairingStore
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
        MobileDesignSamples.rows(sync.approvals).filter { $0.status.lowercased() == "pending" }
    }

    private var pendingInbox: [InboxItemRecord] {
        MobileDesignSamples.rows(sync.inboxItems).filter {
            let status = $0.status.lowercased()
            return status == "unread" || status == "active"
        }
    }

    private var pendingMemoryProposals: [MemoryProposalRecord] {
        sync.memoryProposals.filter(\.isPending)
    }

    private var pendingTrainingProposals: [TrainingProposalSummary] {
        MobileDesignSamples.rows(sync.trainingProposals).filter(\.isHumanActionable)
    }

    private var pendingPromotionCandidates: [PromotionCandidateSummary] {
        sync.promotionCandidates.filter(\.isHumanActionable)
    }

    /// Empty arrays before the first completed snapshot are an absence of
    /// evidence, not proof that a section is clear. The engine's shared
    /// `lastSyncAt` is not that evidence: a provider-catalog update alone sets
    /// it, and the transport carries approvals, the inbox and the memory
    /// proposals in different groups. So each section waits for ITS OWN queue
    /// to arrive before zero is rendered as the distinct "Clear" state.
    private var isDesignSample: Bool { MobileDesignSamples.screen != nil }

    private var pendingApprovalsCount: Int? {
        (sync.approvalsSnapshotLoaded || isDesignSample) ? activityCounts.approvals : nil
    }

    private var pendingInboxCount: Int? {
        (sync.inboxSnapshotLoaded || isDesignSample) ? activityCounts.inbox : nil
    }

    private var pendingMemoryProposalsCount: Int? {
        (sync.memoryProposalsSnapshotLoaded || isDesignSample) ? activityCounts.memoryProposals : nil
    }

    private var pendingSelfImprovementCount: Int? {
        (sync.selfImprovementSnapshotPublishedAt != nil || isDesignSample)
            ? activityCounts.selfImprovement : nil
    }

    private var activityCounts: ActivityScreenPresentation.Counts {
        ActivityScreenPresentation.counts(
            storedApprovals: approvalsStore.pendingCount,
            snapshotApprovals: MobileDesignSamples.rows(sync.approvals),
            storedInbox: inboxStore.activeCount,
            snapshotInbox: MobileDesignSamples.rows(sync.inboxItems),
            memoryProposals: sync.memoryProposals,
            trainingProposals: MobileDesignSamples.rows(sync.trainingProposals),
            promotionCandidates: sync.promotionCandidates
        )
    }

    /// The first two of each queue, in one list, so the landing can answer
    /// them in place. Each queue's full list is one row further down.
    private var waitingItems: [ActivityWaitingItem] {
        var items: [ActivityWaitingItem] = pendingApprovals.prefix(2).map { .approval($0) }
        items += pendingInbox.prefix(2).map { .inbox($0) }
        items += pendingMemoryProposals.prefix(2).map { .memory($0) }
        let trainings = pendingTrainingProposals.prefix(2)
        items += trainings.map { .training($0) }
        items += pendingPromotionCandidates.prefix(2 - trainings.count).map { .promotion($0) }
        return items
    }

    /// The page's one line, and the only place sync state is said.
    private var headerLine: String {
        let known = [pendingApprovalsCount, pendingInboxCount, pendingMemoryProposalsCount, pendingSelfImprovementCount]
        let total = known.compactMap { $0 }.reduce(0, +)
        if total > 0 {
            return total == 1
                ? "One thing is waiting on you."
                : "\(AliveWords.spelled(total)) things are waiting on you."
        }
        if known.contains(where: { $0 == nil }) {
            return pairingStore.usesICloudTransport
                ? "Checking with your Mac for anything new."
                : "Pair with your Mac and what needs you will show up here."
        }
        return "Nothing needs you right now."
    }

    // MARK: - Body

    var body: some View {
        NavigationStack(path: $path) {
            AlivePage(title: "Activity", line: headerLine, style: .root) {
                let items = waitingItems
                if !items.isEmpty {
                    AliveSection("Waiting for you", surface: .waiting) {
                        ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                            if index > 0 { AliveDivider() }
                            waitingRow(item)
                        }
                    }
                }
                AliveSection("Everything") { queueRows }
            }
            // Sweep R4 C11.3 / C11.4 — render-only surfacing of state this
            // screen's own `sync` engine and the shared bridge client already
            // publish. No new polling.
            .macSyncErrorBanner()
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
                openDesignSampleScreen()
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

    /// Screenshot fixtures only (DEBUG `-designScreen`): open the queue or
    /// sheet a design pass asked for, since a simulator cannot be tapped.
    private func openDesignSampleScreen() {
        switch MobileDesignSamples.screen {
        case "approvals": openRequestedSection(.approvals)
        case "inbox": openRequestedSection(.inbox)
        case "inboxItem": inboxDetailItem = pendingInbox.first
        default: break
        }
    }

    // MARK: - Pieces

    @ViewBuilder
    private func waitingRow(_ item: ActivityWaitingItem) -> some View {
        switch item {
        case .approval(let approval):
            InlineApprovalPreviewCard(approval: approval) {
                path.append(ActivitySection.approvals)
            }
        case .inbox(let inboxItem):
            InlineInboxPreviewCard(item: inboxItem) {
                // 2026-06-07: present the detail sheet directly with the
                // tapped item instead of pushing onto the parent
                // NavigationPath — see comment on inboxDetailItem.
                inboxDetailItem = inboxItem
            }
        case .memory(let proposal):
            InlineMemoryProposalPreviewCard(proposal: proposal)
        case .training(let proposal):
            InlineSelfImprovementPreviewCard(
                title: proposal.title,
                summary: proposal.proposed ?? proposal.rationale ?? ""
            ) {
                path.append(ActivitySection.selfImprovement)
            }
        case .promotion(let candidate):
            InlineSelfImprovementPreviewCard(
                title: candidate.title,
                summary: "Something I learned that I'd like to make part of how I work."
            ) {
                path.append(ActivitySection.selfImprovement)
            }
        }
    }

    @ViewBuilder
    private var queueRows: some View {
        ActivityQueueRow(section: .approvals, title: "Approvals",
                         line: "What I'll do once you say yes", count: pendingApprovalsCount)
        AliveDivider()
        ActivityQueueRow(section: .inbox, title: "Inbox",
                         line: "Things I noticed for you", count: pendingInboxCount)
        AliveDivider()
        ActivityQueueRow(section: .memoryProposals, title: "Memories to keep",
                         line: "What I'd like to remember", count: pendingMemoryProposalsCount)
        AliveDivider()
        ActivityQueueRow(section: .selfImprovement, title: "Improvements",
                         line: "Changes I'd make to how I work", count: pendingSelfImprovementCount)
    }
}

private enum ActivityWaitingItem: Identifiable {
    case approval(ApprovalRequest)
    case inbox(InboxItemRecord)
    case memory(MemoryProposalRecord)
    case training(TrainingProposalSummary)
    case promotion(PromotionCandidateSummary)

    var id: String {
        switch self {
        case .approval(let value): return "approval-\(value.id)"
        case .inbox(let value): return "inbox-\(value.id)"
        case .memory(let value): return "memory-\(value.id)"
        case .training(let value): return "training-\(value.id)"
        case .promotion(let value): return "promotion-\(value.id)"
        }
    }
}

// MARK: - Waiting rows

/// One row inside the "Waiting for you" card: the dot, what kind of thing it
/// is, what it says, and the answers.
private struct ActivityWaitingRow<Actions: View>: View {
    let kind: String
    let title: String
    var detail: String? = nil
    var note: String? = nil
    var noteIsError = false
    @ViewBuilder var actions: () -> Actions

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            AliveWaitingDot()
            VStack(alignment: .leading, spacing: 5) {
                Text(kind)
                    .font(.caption)
                    .foregroundStyle(AlivePalette.secondary)
                Text(title)
                    .font(.body.weight(.medium))
                    .foregroundStyle(AlivePalette.text)
                    .fixedSize(horizontal: false, vertical: true)
                if let detail, !detail.isEmpty {
                    Text(detail)
                        .font(.subheadline)
                        .foregroundStyle(AlivePalette.secondary)
                        .lineLimit(4)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let note, !note.isEmpty {
                    Text(note)
                        .font(.footnote)
                        .foregroundStyle(noteIsError ? NativeAgentMobileTheme.Colors.trouble : AlivePalette.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                actions()
                    .padding(.top, 6)
            }
        }
        .aliveRow()
    }
}

/// Approval with Approve / Deny in place. Mirrors the Mac
/// `InlineApprovalPreviewCard` but uses iCloudSyncEngine.shared for the
/// decision call (iOS has no AppModel).
private struct InlineApprovalPreviewCard: View {
    @EnvironmentObject private var approvalsStore: ApprovalsStore
    @EnvironmentObject private var pairingStore: PairingStore
    @EnvironmentObject private var bridgeClient: MacBridgeClient
    @ObservedObject private var bridge = iCloudBridge.shared
    let approval: ApprovalRequest
    var onView: () -> Void

    @State private var isDeciding = false
    @State private var decisionStatusText: String?
    @State private var decisionStatusIsError = false

    private var canSendDecision: Bool {
        pairingStore.isICloudSigned && bridge.available && bridgeClient.bridgeStatus != .deviceOffline
    }

    private var isAgentDecision: Bool {
        !ActivityScreenPresentation.canDecideRemotely(action: approval.action)
    }

    private var kind: String {
        let risk = approval.risk.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return risk.isEmpty ? "Before I go ahead" : "Before I go ahead · \(risk) risk"
    }

    private var note: String? {
        if let decisionStatusText { return decisionStatusText }
        if isAgentDecision { return ApprovalText.agentDecision }
        if !canSendDecision { return "Pair with your Mac to answer from here." }
        return nil
    }

    var body: some View {
        ActivityWaitingRow(
            kind: kind,
            title: ApprovalText.title(approval),
            detail: approval.reason.map(ApprovalText.readable).flatMap { $0.isEmpty ? nil : $0 }
                ?? ApprovalText.kind(approval.action),
            note: note,
            noteIsError: decisionStatusIsError
        ) {
            AliveActionRow {
                if !isAgentDecision {
                    Button("Approve") { decide(approve: true) }
                        .alivePrimaryButton()
                        .disabled(isDeciding || !canSendDecision)
                    Button("Deny") { decide(approve: false) }
                        .aliveSecondaryButton()
                        .disabled(isDeciding || !canSendDecision)
                }
                Button("Details") { onView() }
                    .aliveSecondaryButton()
                if isDeciding {
                    ProgressView().controlSize(.small)
                }
            }
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
                    decisionStatusText = ApprovalBannerPresentation.pendingDecisionMessage
                    decisionStatusIsError = false
                    iOSSystemToastCenter.shared.push(info: "Decision unconfirmed; check again after reconnecting")
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

/// Inbox card with its top two actions plus "Read". The owning Activity view
/// passes a callback that presents the InboxDetailSheet directly with this
/// card's item (the previous "drill into InboxView" wiring bounced on iOS —
/// see ActivityView.inboxDetailItem).
private struct InlineInboxPreviewCard: View {
    @EnvironmentObject private var inboxStore: InboxStore
    let item: InboxItemRecord
    var onMore: () -> Void

    @State private var runningActionID: String?
    @State private var errorText: String?

    private var topActions: [InboxActionRecord] {
        ActivityScreenPresentation.visibleInboxActions(item.actions)
    }

    private var kind: String {
        item.relativeCreatedAt.isEmpty ? item.sourceWords : "\(item.sourceWords) · \(item.relativeCreatedAt)"
    }

    var body: some View {
        ActivityWaitingRow(kind: kind, title: item.title, detail: item.summary,
                           note: errorText, noteIsError: true) {
            AliveActionRow {
                ForEach(topActions, id: \.id) { action in
                    if ActivityScreenPresentation.isPrimaryInboxAction(action.id) {
                        Button(action.label) { runAction(action.id) }
                            .alivePrimaryButton()
                            .disabled(runningActionID != nil)
                    } else {
                        Button(action.label) { runAction(action.id) }
                            .aliveSecondaryButton()
                            .disabled(runningActionID != nil)
                    }
                }
                Button("Read") { onMore() }
                    .aliveSecondaryButton()
                    .disabled(runningActionID != nil)
                if runningActionID != nil {
                    ProgressView().controlSize(.small)
                }
            }
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

/// Memory proposal with Remember / Skip. Calls the same iCloudSyncEngine
/// methods as the full Memory view.
private struct InlineMemoryProposalPreviewCard: View {
    let proposal: MemoryProposalRecord

    @State private var decisionState: InlineMemoryProposalDecisionPresentation.State = .ready

    var body: some View {
        ActivityWaitingRow(
            kind: "Worth remembering · \(proposal.evidenceSummary.lowercased())",
            title: proposal.displayText ?? proposal.text,
            note: decisionState.feedback?.message,
            noteIsError: decisionState.feedback?.isError ?? false
        ) {
            AliveActionRow {
                Button("Remember") { decide(approve: true) }
                    .alivePrimaryButton()
                    .disabled(!decisionState.canDecide)
                Button("Skip") { decide(approve: false) }
                    .aliveSecondaryButton()
                    .disabled(!decisionState.canDecide)
                if decisionState.showsProgress {
                    ProgressView().controlSize(.small)
                }
            }
        }
        .textSelection(.enabled)
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

/// Self-improvement proposal. View-only — approve/reject lives in the
/// Autonomy view because the proposal types fan out into multiple buckets
/// (training, promotion candidates).
private struct InlineSelfImprovementPreviewCard: View {
    let title: String
    let summary: String
    var onView: () -> Void

    var body: some View {
        ActivityWaitingRow(kind: "A change to how I work", title: title, detail: summary,
                           note: "You decide this one on your Mac.") {
            AliveActionRow {
                Button("Details") { onView() }
                    .aliveSecondaryButton()
            }
        }
    }
}

// MARK: - Queue row

/// One row of the "Everything" card: the queue's name, one line, and how
/// many wait there. While a queue has not arrived it says nothing; the page
/// line already says the phone is still checking.
private struct ActivityQueueRow: View {
    let section: ActivitySection
    let title: String
    let line: String
    let count: Int?

    var body: some View {
        NavigationLink(value: section) {
            AliveRow(title, detail: line) {
                switch ActivityScreenPresentation.sectionCountState(for: count) {
                case .pending(let count):
                    HStack(spacing: 7) {
                        AliveWaitingDot()
                        Text(count == 1 ? "1 waiting" : "\(count) waiting")
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(AlivePalette.text)
                    }
                case .clear:
                    Text("Clear")
                        .font(.subheadline)
                        .foregroundStyle(AlivePalette.secondary)
                case .unavailable:
                    EmptyView()
                }
                AliveChevron()
            }
        }
        .aliveRowButtonStyle()
    }
}
