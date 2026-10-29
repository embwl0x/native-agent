// Activity previews use shared queue actions and WorkOverview's attention counts before list bounds.
import SwiftUI
import NativeAgentShared

// Activity's current drill-in queue.
enum ActivitySection: String, CaseIterable, Hashable {
    case approvals
    case inbox
    case memoryProposals
    case selfImprovement
}

/// Activity's queue affordances. Attention counts arrive from the Mac overview.
enum ActivityScreenPresentation {
    enum SectionCountState: Equatable {
        case unavailable
        case clear
        case pending(Int)
    }

    static func sectionCountState(for count: Int?) -> SectionCountState {
        guard let count else { return .unavailable }
        return count > 0 ? .pending(count) : .clear
    }

    /// Signed, paired iOS may decide owner cards regardless of origin or flags.
    /// Studio canon belongs to Agent; the Mac enforces the same exception.
    static func canDecideRemotely(action: String) -> Bool {
        action != "studio.canon"
    }

    /// Notification-open suppression is consumed once. Leaving the latch set
    /// after a cancelled appearance would otherwise skip the next real refresh.
    static func shouldRefreshOnAppear(skipInitialRefresh: inout Bool) -> Bool {
        guard skipInitialRefresh else { return true }
        skipInitialRefresh = false
        return false
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
    @StateObject private var memoryStore = MemoryStore()
    private let sync = iCloudSyncEngine.shared
    @Binding var skipInitialRefresh: Bool
    @Binding var navigationTarget: ActivitySection?

    @State private var path = NavigationPath()
    // Inbox previews open the item's detail sheet directly, without nesting navigation stacks.
    @State private var inboxDetailItemID: String?

    init(
        skipInitialRefresh: Binding<Bool> = .constant(false),
        navigationTarget: Binding<ActivitySection?> = .constant(nil)
    ) {
        self._skipInitialRefresh = skipInitialRefresh
        self._navigationTarget = navigationTarget
    }

    // MARK: - Pending slices

    private var pendingInbox: [InboxItemRecord] {
        MobileDesignSamples.rows(sync.inboxItems).filter {
            let status = $0.status.lowercased()
            return status == "unread" || status == "active"
        }
    }

    private var pendingMemoryProposals: [MemoryProposalRecord] {
        sync.memoryProposals.filter(\.isPending)
    }

    /// Empty arrays before the first completed snapshot are an absence of
    /// evidence, not proof that a section is clear. The engine's shared
    /// `lastSyncAt` is not that evidence: a provider-catalog update alone sets
    /// it, and the transport carries approvals, the inbox and the memory
    /// proposals in different groups. So each section waits for ITS OWN queue
    /// to arrive before zero is rendered as the distinct "Clear" state.
    private var isDesignSample: Bool { MobileDesignSamples.screen != nil }

    private var pendingApprovalsCount: Int? {
        guard let overview = sync.workOverview, overview.unavailable.isEmpty,
              let counts = overview.needsYouCounts else { return nil }
        return counts[.approval] ?? 0
    }

    private var pendingInboxCount: Int? {
        guard let overview = sync.workOverview, overview.unavailable.isEmpty,
              let counts = overview.needsYouCounts else { return nil }
        return counts[.inbox] ?? 0
    }

    private var pendingMemoryProposalsCount: Int? {
        (sync.memoryProposalsSnapshotLoaded || isDesignSample) ? pendingMemoryProposals.count : nil
    }

    /// The page's one line, and the only place sync state is said.
    private var headerLine: String {
        sync.workOverview?.headline ?? "The overview is unavailable. Refresh from your Mac to read it."
    }

    // MARK: - Body

    var body: some View {
        NavigationStack(path: $path) {
            AlivePage(title: "Activity", line: headerLine, style: .root) {
                // The inboxes come first, always (User, 10-18: approvals sat a
                // long scroll down, under work that only needs reading).
                AliveSection("Everything") { queueRows }
                MobileWorkOverviewView()
                if !pendingMemoryProposals.isEmpty {
                    AliveSection("Other reviews", surface: .waiting) {
                        ForEach(Array(pendingMemoryProposals.prefix(2).enumerated()), id: \.element.id) { index, item in
                            if index > 0 { AliveDivider() }
                            InlineMemoryProposalPreviewCard(proposal: item, store: memoryStore)
                        }
                    }
                }
            }
            // Render sync errors from existing sync and bridge state without polling.
            .macSyncErrorBanner()
            .navigationDestination(for: ActivitySection.self) { section in
                // Destinations share Activity's NavigationStack and must not embed another.
                switch section {
                case .approvals:
                    ApprovalsView()
                        .environmentObject(approvalsStore)
                case .inbox:
                    InboxView(embedInNavigationStack: false)
                        .environmentObject(inboxStore)
                case .memoryProposals:
                    MemoryView(
                        initialSegment: .proposals,
                        embedInNavigationStack: false
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
            // Activity and Inbox share InboxDetailSheet for full item rendering.
            .sheet(isPresented: Binding(get: { inboxDetailItemID != nil }, set: { if !$0 { inboxDetailItemID = nil } })) {
                if let id = inboxDetailItemID {
                InboxDetailSheet(
                    itemID: id,
                    onOpenGroup: { _ in
                        // Group filtering only makes sense inside InboxView;
                        // here we just close the sheet so the user can drill
                        // through Activity → Inbox if they want that view.
                        inboxDetailItemID = nil
                    },
                    onDone: { inboxDetailItemID = nil }
                )
                }
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
        case "inboxItem": inboxDetailItemID = pendingInbox.first?.id
        default: break
        }
    }

    // MARK: - Pieces

    @ViewBuilder
    private var queueRows: some View {
        ActivityQueueRow(section: .approvals, title: "Approvals",
                         line: "What I'll do once you say yes", count: pendingApprovalsCount)
        AliveDivider()
        ActivityQueueRow(section: .inbox, title: "Inbox",
                         line: "Notes that need you", count: pendingInboxCount)
        AliveDivider()
        ActivityQueueRow(section: .memoryProposals, title: "Memories to keep",
                         line: "What I'd like to remember", count: pendingMemoryProposalsCount)
        AliveDivider()
        ActivityQueueRow(section: .selfImprovement, title: "Improvements",
                         line: "Managed on your Mac", count: nil)
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

/// Memory proposal with Remember / Skip, submitted through MemoryStore.
private struct InlineMemoryProposalPreviewCard: View {
    let proposal: MemoryProposalRecord
    @ObservedObject var store: MemoryStore

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
        Task {
            do {
                guard let result = await store.performMemoryProposalDecision(proposal, approve: approve) else {
                    decisionState = .ready
                    return
                }
                try result.get()
                if approve {
                    SystemToastCenter.shared.push(success: "Memory accepted")
                } else {
                    SystemToastCenter.shared.push(info: "Memory rejected")
                }
                decisionState = InlineMemoryProposalDecisionPresentation.submitted(approve: approve)
                await iCloudSyncEngine.shared.refreshActivitySnapshot()
            } catch {
                if case SyncError.responseUnconfirmed = error {
                    decisionState = InlineMemoryProposalDecisionPresentation.submitted(approve: approve)
                    SystemToastCenter.shared.push(info: "Decision sent; still waiting on the Mac")
                    await iCloudSyncEngine.shared.refreshActivitySnapshot()
                } else {
                    decisionState = .failed("Failed: \(error.localizedDescription)")
                }
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
