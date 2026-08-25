// Move-only extraction (tightness Wave C) from SidebarFlattenViews.swift

// PATCH-2026-05-19: ui-pull-together — Activity is the single "needs your
// eyes" landing. It owns counts for approvals, inbox, memory proposals, and
// self-improvement so those queues do not compete as separate primary tabs.
//
//   ActivityView      — links Approvals, proactive Inbox, memory proposals,
//                       and self-improvement proposals from one "the agent wants
//                       your eyes" landing page.  Each section pushes only its
//                       owning queue so proposal buckets do not blend.
//   SlimSettingsView  — the "Settings" tab. Only app-level knobs: pairing,
//                       Telegram config, appearance, memory backend, and
//                       reference/about details. Agent controls live elsewhere.
//   DiagnosticsView   — Advanced-tab landing for Doctor + Status + Runs Log.


import SwiftUI
import Context
import NativeAgentShared
import NativeAgentCore
import CognitiveSubstrate

// MARK: - Activity (merged needs-your-eyes feed)

// PATCH-2026-06-06: activity-flatten — show top pending items inline with
// approve/deny right on the landing page so a 1–2 item queue doesn't force
// a drill-down click. Each section header still drills into its owning
// queue. Inline previews call the same AppModel methods as the full views.
//
// Hidden Cmd+Shift+A / Cmd+Shift+I in ContentView post a NotificationCenter
// signal that ActivityView observes to auto-push into the matching queue.

/// Which sub-queue to auto-push into when ActivityView opens. Posted via
/// `.openActivitySectionRequest` by the Cmd+Shift+A / Cmd+Shift+I shortcuts.
enum ActivitySection: String, Sendable {
    case journey
    case approvals
    case inbox
    case memoryProposals
    case selfImprovement
    // B2.4: the Cognition Observatory's approval panels (standing views + schema
    // proposals) landed here — Activity is the single "needs your eyes" surface.
    case cognitionProposals
}

struct ActivityView: View {
    @Environment(AppModel.self) private var appModel
    @AppStorage(NativeExperiencePreferences.masterKey) private var experienceEnabled = false
    @State private var path = NavigationPath()
    // B2.4: cognition proposals aren't mirrored into AppModel's badge counts;
    // this mounted owner reads the real runtime and consumes its change stream.
    @State private var cognitionSubscription = ActivityCognitionSubscription()

    private var cognitionPending: CognitionProposalsFeed.Pending {
        cognitionSubscription.pending
    }

    private var activityRefreshStatus: AppModel.PanelRefreshStatus? {
        appModel.panelRefreshStatus[.activity]
    }

    private var approvalsPresentation: ActivityQueuePresentation {
        .appModel(
            count: appModel.pendingApprovalsCount,
            requiredEndpoints: ["approvals"],
            refresh: activityRefreshStatus
        )
    }

    private var inboxPresentation: ActivityQueuePresentation {
        .appModel(
            count: appModel.pendingInboxCount,
            requiredEndpoints: ["inbox"],
            refresh: activityRefreshStatus
        )
    }

    private var memoryProposalsPresentation: ActivityQueuePresentation {
        .appModel(
            count: appModel.pendingMemoryProposalsCount,
            requiredEndpoints: ["memory proposals"],
            refresh: activityRefreshStatus
        )
    }

    private var selfImprovementPresentation: ActivityQueuePresentation {
        .appModel(
            count: appModel.pendingSelfImprovementCount,
            requiredEndpoints: ["training proposals", "promotion candidates"],
            refresh: activityRefreshStatus
        )
    }

    private var cognitionPresentation: ActivityQueuePresentation {
        .cognition(count: cognitionPending.count, state: cognitionSubscription.state)
    }

    private var pendingApprovals: [ApprovalRequest] {
        appModel.approvals.filter { $0.status.lowercased() == "pending" }
    }

    private var pendingInbox: [InboxItemRecord] {
        appModel.inboxItems.filter(\.isActivityPending)
    }

    private var pendingMemoryProposals: [MemoryProposalRecord] {
        appModel.memoryProposals.filter { $0.status == "pending" }
    }

    private var pendingTrainingProposals: [TrainingProposalSummary] {
        appModel.trainingProposals.filter(AppModel.isHumanActionableTrainingProposal)
    }

    private var pendingPromotionCandidates: [PromotionCandidateSummary] {
        appModel.promotionCandidates.filter(AppModel.isHumanActionablePromotionCandidate)
    }

    var body: some View {
        NavigationStack(path: $path) {
            List {
                // The status card has a real Activity owner. Keeping it out of
                // Chat preserves the session-first rail while its view-lifetime
                // watcher remains armed whenever Activity is visible.
                LivingStatusPanel()
                    .listRowBackground(Color.clear)

                if experienceEnabled {
                    Section {
                        NavigationLink(value: ActivitySection.journey) {
                            HStack(spacing: 14) {
                                Image(systemName: "point.3.filled.connected.trianglepath.dotted")
                                    .font(.title3)
                                    .foregroundStyle(.purple)
                                    .frame(width: 32)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Native Experience").font(NativeAgentFont.section)
                                    Text("Learning, context, projects, workbench, capabilities, and receipts")
                                        .font(NativeAgentFont.label)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.tertiary)
                            }
                            .padding(.vertical, 4)
                        }
                    } header: {
                        Text("Explore")
                            .font(NativeAgentFont.section)
                    }
                }

                // ── Approvals ────────────────────────────────────────────
                Section {
                    NavigationLink(value: ActivitySection.approvals) {
                        SidebarActivityRow(
                            title: "Approvals",
                            systemImage: "checkmark.shield",
                            tint: .orange,
                            presentation: approvalsPresentation,
                            subtitle: "Tool calls waiting for your go-ahead"
                        )
                    }
                    ForEach(Array(pendingApprovals.prefix(2))) { approval in
                        InlineApprovalPreviewCard(approval: approval) {
                            path.append(ActivitySection.approvals)
                        }
                    }
                    if pendingApprovals.count > 2 {
                        Button {
                            path.append(ActivitySection.approvals)
                        } label: {
                            Label("All \(pendingApprovals.count) approvals →",
                                  systemImage: "arrow.right")
                                .font(NativeAgentFont.label)
                                .foregroundStyle(.orange)
                        }
                        .buttonStyle(.naFeel)
                    }
                } header: {
                    Text("Needs your eyes")
                        .font(NativeAgentFont.section)
                }

                // ── Inbox ────────────────────────────────────────────────
                Section {
                    NavigationLink(value: ActivitySection.inbox) {
                        SidebarActivityRow(
                            title: "Inbox",
                            systemImage: "tray",
                            tint: .blue,
                            presentation: inboxPresentation,
                            subtitle: "Proactive cards from the agent"
                        )
                    }
                    ForEach(Array(pendingInbox.prefix(2))) { item in
                        InlineInboxPreviewCard(item: item, nativeBaseURL: appModel.nativeBaseURL) {
                            path.append(ActivitySection.inbox)
                        }
                    }
                    if pendingInbox.count > 2 {
                        Button {
                            path.append(ActivitySection.inbox)
                        } label: {
                            Label("All \(pendingInbox.count) inbox items →",
                                  systemImage: "arrow.right")
                                .font(NativeAgentFont.label)
                                .foregroundStyle(.blue)
                        }
                        .buttonStyle(.naFeel)
                    }
                }

                // ── Memory Proposals ─────────────────────────────────────
                Section {
                    NavigationLink(value: ActivitySection.memoryProposals) {
                        SidebarActivityRow(
                            title: "Memory Proposals",
                            systemImage: "brain.head.profile",
                            tint: .indigo,
                            presentation: memoryProposalsPresentation,
                            subtitle: "Memories the agent wants to keep"
                        )
                    }
                    ForEach(Array(pendingMemoryProposals.prefix(2))) { proposal in
                        InlineMemoryProposalPreviewCard(proposal: proposal)
                    }
                    if pendingMemoryProposals.count > 2 {
                        Button {
                            path.append(ActivitySection.memoryProposals)
                        } label: {
                            Label("All \(pendingMemoryProposals.count) memory proposals →",
                                  systemImage: "arrow.right")
                                .font(NativeAgentFont.label)
                                .foregroundStyle(.indigo)
                        }
                        .buttonStyle(.naFeel)
                    }
                }

                // ── Self-Improvement ─────────────────────────────────────
                Section {
                    NavigationLink(value: ActivitySection.selfImprovement) {
                        SidebarActivityRow(
                            title: "Self-Improvement",
                            systemImage: "wand.and.stars",
                            tint: .indigo,
                            presentation: selfImprovementPresentation,
                            subtitle: "Harness changes proposed by the agent"
                        )
                    }
                    ForEach(Array(pendingTrainingProposals.prefix(2))) { proposal in
                        InlineSelfImprovementPreviewCard(
                            title: proposal.target_doc,
                            summary: proposal.proposed,
                            tint: .indigo,
                            onView: { path.append(ActivitySection.selfImprovement) }
                        )
                    }
                    if pendingTrainingProposals.count < 2 {
                        // Top up with promotion candidates if there's room.
                        let take = 2 - pendingTrainingProposals.count
                        ForEach(Array(pendingPromotionCandidates.prefix(take))) { candidate in
                            InlineSelfImprovementPreviewCard(
                                title: "Promotion · \(candidate.tier ?? "?")",
                                summary: candidate.reason ?? "Harness staged a promotion candidate.",
                                tint: .indigo,
                                onView: { path.append(ActivitySection.selfImprovement) }
                            )
                        }
                    }
                    if appModel.pendingSelfImprovementCount > 2 {
                        Button {
                            path.append(ActivitySection.selfImprovement)
                        } label: {
                            Label("All \(appModel.pendingSelfImprovementCount) self-improvement items →",
                                  systemImage: "arrow.right")
                                .font(NativeAgentFont.label)
                                .foregroundStyle(.indigo)
                        }
                        .buttonStyle(.naFeel)
                    }
                }

                // ── Cognition Proposals (B2.4: from the retired Observatory) ──
                Section {
                    if case .unavailable(let detail) = cognitionSubscription.state {
                        Label(detail, systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(.orange)
                            .accessibilityIdentifier("activity.cognition-subscription.unavailable")
                    }
                    NavigationLink(value: CognitionSurfaceDispositionPresentation.activityApprovalSection) {
                        SidebarActivityRow(
                            title: "Cognition Proposals",
                            systemImage: "eye",
                            tint: .purple,
                            presentation: cognitionPresentation,
                            subtitle: "Standing views from reflection"
                        )
                    }
                    ForEach(Array(cognitionPending.standingViews.prefix(2)), id: \.id) { view in
                        InlineCognitionProposalCard(
                            proposalID: view.id,
                            title: view.body,
                            subtitle: "standing view — proposed",
                            detail: view.body,
                            onResolve: { approved in
                                await resolveStandingView(view.id, approved: approved)
                            }
                        )
                    }
                    if cognitionPending.count > 2 {
                        Button {
                            path.append(CognitionSurfaceDispositionPresentation.activityApprovalSection)
                        } label: {
                            Label("All \(cognitionPending.count) cognition proposals →",
                                  systemImage: "arrow.right")
                                .font(NativeAgentFont.label)
                                .foregroundStyle(.purple)
                        }
                        .buttonStyle(.naFeel)
                    }
                }
            }
            .listStyle(.inset)
            .navigationTitle("Activity")
            .navigationDestination(for: ActivitySection.self) { section in
                switch section {
                case .journey:          NativeExperienceView()
                case .approvals:        ApprovalsView()
                case .inbox:            InboxView()
                // gpt-5.5 review #2: MemoryView defaults to the Active tab;
                // drilling in from "Memory Proposals" should land on Pending.
                case .memoryProposals:  MemoryView(initialTab: .pending)
                case .selfImprovement:  SelfImprovementView()
                case .cognitionProposals: CognitionProposalsView()
                }
            }
        }
        .task {
            cognitionSubscription.start()
        }
        .onDisappear { cognitionSubscription.stop() }
        .task {
            // gpt-5.5 review #1: when Cmd+Shift+A/I fires from another tab,
            // ContentView stashes the target section on AppModel and switches
            // to .activity. We weren't mounted in time to observe the
            // notification, so consume the stash here and clear it.
            if let raw = appModel.pendingActivitySectionRaw,
               let section = ActivitySection(rawValue: raw) {
                appModel.pendingActivitySectionRaw = nil
                path = NavigationPath()
                path.append(section)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .openActivitySectionRequest)) { note in
            guard let raw = note.object as? String,
                  let section = ActivitySection(rawValue: raw) else { return }
            // Already-mounted path. Also clear the stash so the next .task
            // (e.g. tab toggle) doesn't replay it.
            appModel.pendingActivitySectionRaw = nil
            // Reset to root before appending so back-to-back shortcuts land
            // on the requested destination rather than stacking pushes.
            path = NavigationPath()
            path.append(section)
        }
        .onReceive(NotificationCenter.default.publisher(for: .openActivityRootRequest)) { _ in
            appModel.pendingActivitySectionRaw = nil
            path = NavigationPath()
        }
    }

    // MARK: - Cognition proposals (B2.4)

    private func resolveStandingView(
        _ id: UUID,
        approved: Bool
    ) async -> CognitionProposalActions.ResolveStatus {
        let result = await CognitionProposalActions.resolveWithOutcome(id: id, approved: approved)
        if case .unavailable(let message) = result.status {
            appModel.systemToasts.push(error: "Standing-view review not applied: \(message)")
        } else {
            appModel.systemToasts.push(success: approved ? "Standing view approved and saved." : "Standing view rejected and retired.")
        }
        await cognitionSubscription.refreshNow()
        return result.status
    }

}

enum ActivityQueuePresentation: Equatable {
    struct SidebarStatus: Equatable {
        let text: String
        let systemImage: String?
    }

    case loading
    case unavailable
    case allClear
    case actionable(Int)

    /// The status vocabulary rendered by `SidebarActivityRow`. Keeping this
    /// projection beside the queue state prevents unavailable evidence from
    /// ever borrowing the reassuring all-clear label.
    var sidebarStatus: SidebarStatus {
        switch self {
        case .actionable(let count):
            return SidebarStatus(text: "\(count)", systemImage: nil)
        case .allClear:
            return SidebarStatus(text: "All clear", systemImage: nil)
        case .loading:
            return SidebarStatus(text: "Checking…", systemImage: nil)
        case .unavailable:
            return SidebarStatus(text: "Unavailable", systemImage: "exclamationmark.triangle.fill")
        }
    }

    static func appModel(
        count: Int,
        requiredEndpoints: Set<String>,
        refresh: AppModel.PanelRefreshStatus?
    ) -> ActivityQueuePresentation {
        guard let refresh else { return .loading }
        let failed = Set(refresh.failedEndpoints.map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        })
        let required = Set(requiredEndpoints.map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        })
        guard failed.isDisjoint(with: required) else { return .unavailable }
        return count > 0 ? .actionable(count) : .allClear
    }

    static func cognition(
        count: Int,
        state: ActivityCognitionSubscription.State
    ) -> ActivityQueuePresentation {
        switch state {
        case .active:
            return count > 0 ? .actionable(count) : .allClear
        case .idle:
            return .loading
        case .unavailable, .stopped:
            return .unavailable
        }
    }
}

struct SidebarActivityRow: View {
    let title: String
    let systemImage: String
    let tint: Color
    let presentation: ActivityQueuePresentation
    let subtitle: String

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: systemImage)
                .font(.title3)
                .foregroundStyle(tint)
                .frame(width: 32)

            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(NativeAgentFont.section)
                Text(subtitle)
                    .font(NativeAgentFont.label)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            switch presentation {
            case .actionable:
                Text(presentation.sidebarStatus.text)
                    .font(NativeAgentFont.label)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .background(tint, in: Capsule())
            case .allClear:
                // Taste pass 2026-07-24: "Clear" alone read as a clear-all
                // BUTTON sitting exactly where one would live; "All clear" is
                // unambiguously a status.
                Text(presentation.sidebarStatus.text)
                    .font(NativeAgentFont.tag)
                    .foregroundStyle(.secondary)
            case .loading:
                Text(presentation.sidebarStatus.text)
                    .font(NativeAgentFont.tag)
                    .foregroundStyle(.secondary)
            case .unavailable:
                Label(
                    presentation.sidebarStatus.text,
                    systemImage: presentation.sidebarStatus.systemImage ?? "exclamationmark.triangle.fill"
                )
                    .font(NativeAgentFont.tag)
                    .foregroundStyle(.orange)
            }
        }
        .padding(.vertical, 4)
    }
}
