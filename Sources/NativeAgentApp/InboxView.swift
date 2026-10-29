import BackgroundWork
import ApprovalTransactions
import SwiftUI
import Observation
import NativeAgentShared
import NativeAgentCore
import NotificationInbox
import TriggerScheduler
import DeviceSync

// Blueprint: | `InboxView.swift` | `InboxView`: canonical inbox lanes, digest groups and row actions; unknown sources stay visible |

// MARK: - Models
/// Presentation over the core inbox card (`NativeAgentShared.InboxItemRecord`).
extension InboxItemRecord {
    var severityColor: Color {
        switch severity {
        case "actionable": return .orange
        case "important":  return .blue
        default:           return .secondary
        }
    }

    /// Unrecognized sources stay visible with an explicit unknown badge.

    var sourceIcon: String { presentation?.icon ?? "bell.fill" }

    var sourceBadgeLabel: String { presentation?.badge ?? "SOURCE UNKNOWN" }

    /// The badge said as a word: "MORNING-BRIEF" is "Morning brief".
    var sourceWord: String {
        let label = sourceBadgeLabel
        guard label != "REM" else { return label }
        let words = label.replacingOccurrences(of: "-", with: " ").lowercased()
        return words.prefix(1).uppercased() + words.dropFirst()
    }

    /// "Idea · Actionable" over the detail sheet's title.
    var detailEyebrow: String {
        let level = severity.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !level.isEmpty, level.lowercased() != "info" else { return sourceWord }
        return "\(sourceWord) · \(AdvancedStatusWords.label(level))"
    }
}

extension TriggerConfig: @retroactive Identifiable {
    public var id: String { name }

    var displayName: String {
        switch name {
        case "idle_checkin":     return "Idle check-in"
        case "morning_brief":    return "Morning brief"
        default:                 return Self.humanized(name)
        }
    }

    /// Unnamed IDs read as capitalized words with spaces.
    static func humanized(_ id: String) -> String {
        let words = id.replacingOccurrences(of: "_", with: " ")
            .trimmingCharacters(in: .whitespaces)
        guard let first = words.first else { return id }
        return String(first).uppercased() + words.dropFirst()
    }
}

// MARK: - Full inbox list (accessible from chat header or settings)
/// Inbox lanes filter by the card's addressee.
enum InboxLane: String, CaseIterable, Identifiable {
    case forYou
    case system

    var id: String { rawValue }

    var title: String {
        switch self {
        case .forYou: return "For you"
        case .system: return "System"
        }
    }

    func matches(_ item: InboxItemRecord) -> Bool {
        switch self {
        case .forYou: return item.isForYouLane
        case .system: return item.isSystemLane
        }
    }
}

/// Review Groups selects from the same population the Inbox list renders.
enum InboxReviewGroupSelection {
    static func displayItems(
        items: [InboxItemRecord],
        lane: InboxLane,
        showAll: Bool,
        groupFilter: InboxRelatedGroup?
    ) -> [InboxItemRecord] {
        let base = (showAll ? items : items.filter { !$0.isHiddenFromDefaultInbox })
            .filter { lane.matches($0) }
        guard let groupFilter else { return base }
        return base.filter { groupFilter.matches($0) }
    }
}

/// Segment badges and empty-state pointers count the same unread, default-visible cards.
enum InboxLanePresentation {
    /// Each presentation starts in the human lane with explicit segment order.
    static let initialLane: InboxLane = .forYou
    static let pickerLanes: [InboxLane] = [.forYou, .system]

    static func unreadVisibleCount(in lane: InboxLane, items: [InboxItemRecord]) -> Int {
        items.count {
            lane.matches($0) && $0.isUnread && !$0.isHiddenFromDefaultInbox
        }
    }
}

/// Lane navigation and counts read the shared inbox owner.
struct InboxView: View {
    init(initialGroup: InboxRelatedGroup? = nil) {
        _groupFilter = State(initialValue: initialGroup)
    }

    @Environment(AppModel.self) private var appModel

    private var inbox: InboxFacade { appModel.engine.inbox }
    @State private var inlineCards = InlineInteractionChatBinding()
    @State private var showAll = false
    @State private var groupFilter: InboxRelatedGroup?
    // The inbox opens on the human lane, with the operations feed one click away.
    @State private var lane: InboxLane = InboxLanePresentation.initialLane

    var body: some View {
        let originSessions = Set(inbox.items.compactMap { (try? InlineInteractionDelivery.Pointer(item: $0))?.sessionID })
        VStack(alignment: .leading, spacing: 0) {
            // The surrounding sheet supplies the title.
            HStack(spacing: NativeAgentSpacing.md) {
                // Unread counts stay on the segments so hidden lanes still signal pending notes.
                Picker("Notification category", selection: $lane) {
                    ForEach(InboxLanePresentation.pickerLanes) { candidate in
                        Text(laneLabel(candidate)).tag(candidate)
                    }
                }
                .accessibilityLabel("Notification category")
                .pickerStyle(.segmented)
                .hazeTinted(.segments)
                .labelsHidden()
                .fixedSize()
                Spacer(minLength: 0)
                if inbox.isLoading {
                    ProgressView().controlSize(.small)
                }
                Toggle("Show archived", isOn: $showAll)
                    .toggleStyle(.checkbox)
                    .help("Also show notes you archived or dismissed")
                Button("Refresh") { Task { await load() } }
                    .disabled(inbox.isLoading)
            }
            .font(ShellType.label)
            .padding(.horizontal, NativeAgentSpacing.xl)
            .padding(.vertical, NativeAgentSpacing.md)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: AliveMetrics.sectionSpacing) {
                    if let groupFilter {
                        groupFilterRow(groupFilter)
                    }
                    // Empty lanes point to visible unread notes in the other lane.
                    switch inbox.contentPresentation(hasVisibleItems: !prioritySections.isEmpty) {
                    case .loading:
                        AdvancedWaitingLine("Reading your notes…")
                    case .unavailable:
                        AdvancedEmptyState(
                            title: "Couldn't read your notes",
                            detail: "Try again to see what needs you.",
                            actionTitle: "Try again",
                            action: { Task { await load() } }
                        )
                    case .empty:
                        AdvancedEmptyState(
                            title: lane == .forYou ? "Nothing for you right now" : "No system notes",
                            detail: emptyStateDetail
                        )
                    case .content:
                        if let err = inbox.refreshErrorText {
                            Text(err)
                                .font(ShellType.label)
                                .foregroundStyle(NativeAgentShell.trouble)
                        }
                        // Requests stay above history until resolved, even after reading.
                        if !prioritySections.needsYou.isEmpty {
                            section("Needs you", prioritySections.needsYou, waiting: true)
                        }
                        if !prioritySections.rest.isEmpty {
                            section(prioritySections.needsYou.isEmpty ? nil : lane.title, prioritySections.rest)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(NativeAgentSpacing.xl)
            }
        }
        .task { await load() }
        .task(id: originSessions) {
            for session in originSessions.sorted() {
                guard !Task.isCancelled else { return }
                await appModel.engine.transcripts.refreshCards(in: session)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: InlineInteractionWire.changedNotification)) { event in
            guard let session = event.object as? String, originSessions.contains(session) else { return }
            Task { await appModel.engine.transcripts.refreshCards(in: session) }
        }
        .inlineCardSetup(inlineCards)
    }

    private func groupFilterRow(_ group: InboxRelatedGroup) -> some View {
        HStack(spacing: NativeAgentSpacing.md) {
            VStack(alignment: .leading, spacing: 2) {
                Text(group.title)
                    .font(ShellType.labelSemibold)
                    .foregroundStyle(NativeAgentShell.text)
                Text("\(displayItems.filter { $0.isUnread }.count) unread, \(displayItems.filter { !$0.isUnread }.count) earlier")
                    .font(ShellType.caption)
                    .foregroundStyle(NativeAgentShell.secondary)
            }
            Spacer(minLength: 0)
            Button("Show all notes") { self.groupFilter = nil }
                .controlSize(.small)
        }
        .padding(.horizontal, AliveMetrics.rowInsetH)
        .padding(.vertical, AliveMetrics.rowInsetV)
        .aliveCard()
    }

    private func section(_ title: String?, _ items: [InboxItemRecord], waiting: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: AliveMetrics.eyebrowGap) {
            if let title { AliveEyebrow(title) }
            LazyVStack(alignment: .leading, spacing: NativeAgentSpacing.sm) {
                ForEach(items) { row($0, waiting: waiting) }
            }
        }
    }

    private func row(_ item: InboxItemRecord, waiting: Bool) -> some View {
        InboxListRow(
            item: item,
            interactionBinding: inlineCards,
            waiting: waiting,
            allItems: inbox.items,
            onAction: { Task { await loadAndSync() } },
            onMarkedRead: { markRead(item.id) },
            onSelectGroup: { group in
                groupFilter = group
            }
        )
    }

    private var displayItems: [InboxItemRecord] {
        InboxReviewGroupSelection.displayItems(
            items: inbox.items,
            lane: lane,
            showAll: showAll,
            groupFilter: groupFilter
        )
    }

    /// Shared visibility rules keep System requests reachable by the person they await.
    private var visibleEverywhere: [InboxItemRecord] {
        InboxLanePresentation.pickerLanes.flatMap {
            InboxReviewGroupSelection.displayItems(
                items: inbox.items,
                lane: $0,
                showAll: showAll,
                groupFilter: groupFilter
            )
        }
    }

    private var prioritySections: InboxNeedsYou.Sections {
        InboxNeedsYou.sections(everywhere: visibleEverywhere, lane: displayItems)
    }

    private var emptyStateDetail: String {
        let other: InboxLane = lane == .forYou ? .system : .forYou
        let otherCount = InboxLanePresentation.unreadVisibleCount(in: other, items: inbox.items)
        if otherCount > 0 {
            return "\(otherCount) unread \(otherCount == 1 ? "note is" : "notes are") in \(other.title)."
        }
        return "When I notice something useful, I'll leave it here."
    }

    /// Lane labels count unread visible cards, excluding dismissed cards.
    private func laneLabel(_ candidate: InboxLane) -> String {
        let unread = InboxLanePresentation.unreadVisibleCount(in: candidate, items: inbox.items)
        return unread > 0 ? "\(candidate.title) (\(unread) unread)" : candidate.title
    }

    func load() async {
        do { _ = try await inbox.list() }
        catch { ModuleLog.app("%@", "[inbox] read failed: \(error.localizedDescription)") }
    }

    func loadAndSync() async {
        await load()
        if let sync = appModel.engine.deviceSync { await sync.engine.writeSnapshots() }
    }

    private func markRead(_ id: String) {
        inbox.markRead(id)
    }
}

/// A note opens its detail sheet and signals when it waits on the person.
struct InboxListRow: View {
    @Environment(AppModel.self) private var appModel
    let item: InboxItemRecord
    let interactionBinding: InlineInteractionChatBinding
    var waiting = false
    let allItems: [InboxItemRecord]
    let onAction: () -> Void
    // Successful read actions let the parent publish the committed read through the shared inbox owner.
    let onMarkedRead: () -> Void
    let onSelectGroup: (InboxRelatedGroup) -> Void

    @State private var showDetail = false
    // The shared action flight owns visible busy state and the terminal outcome.
    @State private var actionFlight = InboxRowActionFlight()
    // Failed writes stay visible below the buttons without dismissing the row.
    @State private var actionError: String? = nil

    private var visibleActions: [InboxActionRecord] {
        InboxVisibleActionsPresentation.actions(for: item)
    }

    @ViewBuilder
    var body: some View {
        if item.source == InlineInteractionDelivery.source {
            InteractionInboxCard(item: item, binding: interactionBinding)
        } else {
            ordinaryRow
        }
    }

    private var ordinaryRow: some View {
        VStack(alignment: .leading, spacing: NativeAgentSpacing.md) {
            HStack(alignment: .firstTextBaseline, spacing: NativeAgentSpacing.sm) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(item.title)
                        .font(item.isUnread ? ShellType.bodySemibold : ShellType.body)
                        .foregroundStyle(NativeAgentShell.text)
                    Text(item.summary)
                        .font(ShellType.label)
                        .foregroundStyle(NativeAgentShell.secondary)
                        .lineLimit(2)
                    Text(item.isUnread ? "New · \(item.sourceWord)" : item.sourceWord)
                        .font(ShellType.caption)
                        .foregroundStyle(NativeAgentShell.secondary)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(ShellType.caption)
                    .foregroundStyle(NativeAgentShell.secondary)
                    .accessibilityHidden(true)
            }

            if !visibleActions.isEmpty {
                // Primary actions use native buttons; the rest use the Mac's menu.
                let primary = visibleActions.filter { InboxActionWords.isPrimary($0.id) }
                let others = visibleActions.filter { !InboxActionWords.isPrimary($0.id) }
                HStack(spacing: NativeAgentSpacing.sm) {
                    ForEach(primary, id: \.id) { action in
                        Button(action.label) { runAction(action.id) }
                            .buttonStyle(.borderedProminent)
                            .hazeTinted(.button)
                            .controlSize(.small)
                            .disabled(actionFlight.isInFlight)
                    }
                    if !others.isEmpty {
                        Menu {
                            ForEach(others, id: \.id) { action in
                                Button(action.label) { runAction(action.id) }
                            }
                        } label: {
                            Text(primary.isEmpty ? "Actions" : "More")
                        }
                        .menuStyle(.button)
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .fixedSize()
                        .disabled(actionFlight.isInFlight)
                    }
                }
            }

            if let actionError {
                Text(actionError)
                    .font(ShellType.label)
                    .foregroundStyle(NativeAgentShell.trouble)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, AliveMetrics.rowInsetH)
        .padding(.vertical, AliveMetrics.rowInsetV)
        .aliveCard(waiting: waiting)
        .contentShape(Rectangle())
        .onTapGesture { showDetail = true }
        .sheet(isPresented: $showDetail) {
            InboxItemDetailSheet(
                item: item,
                allItems: allItems,
                onAction: { actionID in
                    await performAction(actionID)
                },
                onOpenGroup: onSelectGroup,
                onClose: { showDetail = false }
            )
            .presentationDetents([.medium, .large])
        }
    }

    private func runAction(_ actionID: String) {
        actionError = nil
        Task { @MainActor in
            let outcome = await performAction(actionID)
            if case .failed = outcome { actionError = InboxActionWords.failure(actionID) }
        }
    }

    /// Row and detail actions share this path; durable success chooses read or resolution callbacks.
    private func performAction(_ actionID: String) async -> InboxRowActionFlight.Outcome {
        let outcome = await actionFlight.perform {
            try await InboxCardActions.perform(item.id, action: actionID,
                dataRootOverride: appModel.engine.dataRoot, effects: AppInboxCardActionEffects(inbox: appModel.engine.inbox))
        }
        if case .succeeded = outcome {
            if actionID == "read" { onMarkedRead() }
            else { onAction() }
        }
        return outcome
    }
}
