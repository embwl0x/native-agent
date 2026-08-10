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
    // this view loads the proposed set directly from the cognition runtime.
    @State private var cognitionPending = CognitionProposalsFeed.Pending()

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
                            count: appModel.pendingApprovalsCount,
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
                        .buttonStyle(.plain)
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
                            count: appModel.pendingInboxCount,
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
                        .buttonStyle(.plain)
                    }
                }

                // ── Memory Proposals ─────────────────────────────────────
                Section {
                    NavigationLink(value: ActivitySection.memoryProposals) {
                        SidebarActivityRow(
                            title: "Memory Proposals",
                            systemImage: "brain.head.profile",
                            tint: .indigo,
                            count: appModel.pendingMemoryProposalsCount,
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
                        .buttonStyle(.plain)
                    }
                }

                // ── Self-Improvement ─────────────────────────────────────
                Section {
                    NavigationLink(value: ActivitySection.selfImprovement) {
                        SidebarActivityRow(
                            title: "Self-Improvement",
                            systemImage: "wand.and.stars",
                            tint: .indigo,
                            count: appModel.pendingSelfImprovementCount,
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
                        .buttonStyle(.plain)
                    }
                }

                // ── Cognition Proposals (B2.4: from the retired Observatory) ──
                Section {
                    NavigationLink(value: ActivitySection.cognitionProposals) {
                        SidebarActivityRow(
                            title: "Cognition Proposals",
                            systemImage: "eye",
                            tint: .purple,
                            count: cognitionPending.count,
                            subtitle: "Standing views & schema proposals from reflection"
                        )
                    }
                    ForEach(Array(cognitionPending.standingViews.prefix(2)), id: \.id) { view in
                        InlineCognitionProposalCard(
                            title: view.body,
                            subtitle: "standing view — proposed",
                            onApprove: { resolveStandingView(view.id, approved: true) },
                            onReject: { resolveStandingView(view.id, approved: false) }
                        )
                    }
                    // Top up with schema proposals if there's room for a preview.
                    if cognitionPending.standingViews.count < 2 {
                        let take = 2 - cognitionPending.standingViews.count
                        ForEach(Array(cognitionPending.schemaProposals.prefix(take)), id: \.id) { proposal in
                            InlineCognitionProposalCard(
                                title: proposal.title,
                                subtitle: "schema proposal — \(proposal.target)",
                                detail: proposal.body,
                                onApprove: { resolveSchemaProposal(proposal.id, accepted: true) },
                                onReject: { resolveSchemaProposal(proposal.id, accepted: false) }
                            )
                        }
                    }
                    if cognitionPending.count > 2 {
                        Button {
                            path.append(ActivitySection.cognitionProposals)
                        } label: {
                            Label("All \(cognitionPending.count) cognition proposals →",
                                  systemImage: "arrow.right")
                                .font(NativeAgentFont.label)
                                .foregroundStyle(.purple)
                        }
                        .buttonStyle(.plain)
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
        .task { await loadCognitionPending() }
        .task {
            // gpt-5.5 review (B2 wave): the root count/previews must track the
            // same change stream the drilled-in view follows, else "needs your
            // eyes" goes stale while Activity sits open. Task cancels with the
            // view, closing the subscription.
            let changes = await NativeCognitionRuntime.shared.changes()
            for await _ in changes {
                await loadCognitionPending()
            }
        }
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

    private func loadCognitionPending() async {
        cognitionPending = await CognitionProposalsFeed.pending()
    }

    private func resolveStandingView(_ id: UUID, approved: Bool) {
        Task {
            await NativeCognitionRuntime.shared.resolveStandingView(id: id, approved: approved)
            await loadCognitionPending()
        }
    }

    private func resolveSchemaProposal(_ id: UUID, accepted: Bool) {
        Task {
            await NativeCognitionRuntime.shared.resolveSchemaProposal(id: id, accepted: accepted)
            await loadCognitionPending()
        }
    }
}

private struct SidebarActivityRow: View {
    let title: String
    let systemImage: String
    let tint: Color
    let count: Int
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

            if count > 0 {
                Text("\(count)")
                    .font(NativeAgentFont.label)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .background(tint, in: Capsule())
            } else {
                // Taste pass 2026-07-24: "Clear" alone read as a clear-all
                // BUTTON sitting exactly where one would live; "All clear" is
                // unambiguously a status.
                Text("All clear")
                    .font(NativeAgentFont.tag)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }
}
