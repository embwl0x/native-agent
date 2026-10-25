import BackgroundWork
import ApprovalTransactions

// Blueprint: | `InboxView.swift` | `InboxView`: canonical inbox lanes, digest groups, details and single-flight row actions; unknown sources stay visible |
// PATCH-2026-05-07: proactive-inbox-1 InboxView — proactive inbox card strip
import SwiftUI
import Observation
import NativeAgentShared
import NativeAgentCore
import NotificationInbox
import TriggerScheduler
import DeviceSync

// MARK: - Models

/// Presentation over the core inbox card (`NotificationInbox.InboxItemRecord`).
extension InboxItemRecord {
    var severityColor: Color {
        switch severity {
        case "actionable": return .orange
        case "important":  return .blue
        default:           return .secondary
        }
    }

    /// Everything else — deliberately the DEFAULT. An unrecognized source is a
    /// card nobody has classified yet; putting it in front of User is the
    /// recoverable error, hiding it in a lane he does not open is not.

    var sourceIcon: String { presentation.icon }

    var sourceBadgeLabel: String { presentation.badge }

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

    /// An id with no spelled-out name still reads as words: underscores become
    /// spaces and the first letter is capitalized.
    static func humanized(_ id: String) -> String {
        let words = id.replacingOccurrences(of: "_", with: " ")
            .trimmingCharacters(in: .whitespaces)
        guard let first = words.first else { return id }
        return String(first).uppercased() + words.dropFirst()
    }
}

// MARK: - Notes capsule (fluid glass A2: one notice lane)

/// Unread notes as one small glass capsule in the chat header, shown only
/// while something is unread. It opens a list, newest first; a row opens the
/// note's detail and its actions. Nothing stacks over the transcript.
struct InboxNotesCapsule: View {
    let items: [InboxItemRecord]
    let onAction: @MainActor (String, String) async throws -> Void

    @State private var showsList = false
    @State private var selectedItem: InboxItemRecord?
    @State private var actionFlight = InboxRowActionFlight()

    private static let rowHeight: CGFloat = 44

    var body: some View {
        // Newest first: the inbox already lists that way.
        let unread = items.filter(\.isUnread)
        ZStack {
            if !unread.isEmpty {
                Button { showsList.toggle() } label: {
                    Text("\(unread.count) \(unread.count == 1 ? "update" : "updates")")
                        .font(ShellType.label)
                        .foregroundStyle(NativeAgentShell.secondary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 2)
                        .houseSurface(in: Capsule(), interactive: true)
                }
                .buttonStyle(.plain)
                .help("Unread notes")
                .accessibilityLabel("\(unread.count) unread \(unread.count == 1 ? "update" : "updates")")
                .accessibilityIdentifier("chat.notes.capsule")
                .transition(NativeAgentMotion.fade)
                .popover(isPresented: $showsList, arrowEdge: .bottom) {
                    list(unread)
                }
            }
        }
        .sheet(item: $selectedItem) { item in
            InboxItemDetailSheet(
                item: item,
                allItems: items,
                onAction: { actionID in
                    await actionFlight.perform {
                        try await onAction(item.id, actionID)
                    }
                },
                onClose: { selectedItem = nil }
            )
            .presentationDetents([.medium, .large])
        }
    }

    private func list(_ unread: [InboxItemRecord]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Updates")
                    .font(ShellType.labelSemibold)
                Spacer()
                // Marked read, they stay in Notifications; nothing is lost.
                Button("Mark all read") {
                    showsList = false
                    let ids = unread.map(\.id)
                    Task { for id in ids { try? await onAction(id, "read") } }
                }
                .buttonStyle(.link)
                .font(ShellType.label)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(unread) { item in
                        Button {
                            showsList = false
                            // Let the popover close before the sheet opens.
                            DispatchQueue.main.async { selectedItem = item }
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: item.sourceIcon)
                                    .foregroundStyle(item.severityColor)
                                    .frame(width: 16)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(item.title)
                                        .font(ShellType.labelSemibold)
                                        .lineLimit(1)
                                    Text(item.summary)
                                        .font(ShellType.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                                Spacer(minLength: 0)
                            }
                            .padding(.horizontal, 12)
                            .frame(height: Self.rowHeight)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .frame(height: min(CGFloat(unread.count), 8) * Self.rowHeight)
        }
        .frame(width: 320)
    }
}

// MARK: - Detail sheet

/// One note, read in full: what it is, what it says, the files and related
/// notes it points at, and its actions along the bottom. The shell's type and
/// the alive kit's cards on the sheet; a failed action is one line above the
/// buttons, not an alert.
struct InboxItemDetailSheet: View {
    let item: InboxItemRecord
    var allItems: [InboxItemRecord] = []
    let onAction: @MainActor (String) async -> InboxRowActionFlight.Outcome
    var onOpenGroup: ((InboxRelatedGroup) -> Void)? = nil
    var closesOnGroupSelection = true
    let onClose: () -> Void

    @State private var isActing = false
    @State private var actionError: String?

    private var visibleActions: [InboxActionRecord] {
        InboxVisibleActionsPresentation.actions(for: item)
    }

    private var relatedGroups: [InboxRelatedGroup] {
        InboxDigestGroupProjection.groups(item: item, allItems: allItems)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: AliveMetrics.sectionSpacing) {
                    VStack(alignment: .leading, spacing: NativeAgentSpacing.sm) {
                        AliveEyebrow(item.detailEyebrow)
                        Text(item.title)
                            .font(ShellType.title)
                            .foregroundStyle(NativeAgentShell.text)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityAddTraits(.isHeader)
                        Text(item.summary)
                            .font(ShellType.body)
                            .foregroundStyle(NativeAgentShell.text)
                            .fixedSize(horizontal: false, vertical: true)
                        if let detail = item.detail, !detail.isEmpty {
                            Text(detail)
                                .font(ShellType.label)
                                .foregroundStyle(NativeAgentShell.secondary)
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }

                    if let paths = item.related_paths, !paths.isEmpty {
                        VStack(alignment: .leading, spacing: AliveMetrics.eyebrowGap) {
                            AliveEyebrow("Files")
                            AliveGroupCard {
                                ForEach(paths.prefix(5), id: \.self) { path in
                                    Text(path)
                                        .font(ShellType.code)
                                        .foregroundStyle(NativeAgentShell.secondary)
                                        .textSelection(.enabled)
                                }
                            }
                        }
                    }

                    if let onOpenGroup, !relatedGroups.isEmpty {
                        VStack(alignment: .leading, spacing: AliveMetrics.eyebrowGap) {
                            AliveEyebrow("Related notes")
                            AliveGroupCard {
                                ForEach(relatedGroups) { group in
                                    Button {
                                        onOpenGroup(group)
                                        if closesOnGroupSelection { onClose() }
                                    } label: {
                                        HStack(spacing: NativeAgentSpacing.sm) {
                                            VStack(alignment: .leading, spacing: 2) {
                                                Text(group.title)
                                                    .font(ShellType.labelMedium)
                                                    .foregroundStyle(NativeAgentShell.text)
                                                    .multilineTextAlignment(.leading)
                                                Text("\(group.displayCount) \(group.displayCount == 1 ? "note" : "notes")")
                                                    .font(ShellType.caption)
                                                    .foregroundStyle(NativeAgentShell.secondary)
                                            }
                                            Spacer(minLength: 0)
                                            Image(systemName: "chevron.right")
                                                .font(ShellType.caption)
                                                .foregroundStyle(NativeAgentShell.secondary)
                                                .accessibilityHidden(true)
                                        }
                                        .contentShape(Rectangle())
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(NativeAgentSpacing.xl)
            }
            Divider()
            VStack(alignment: .leading, spacing: NativeAgentSpacing.md) {
                if let actionError {
                    Text(actionError)
                        .font(ShellType.label)
                        .foregroundStyle(NativeAgentShell.trouble)
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack(spacing: NativeAgentSpacing.sm) {
                    // `.onAppear` below already marks the item read when the
                    // sheet opens; Close only closes.
                    Button("Close") { onClose() }
                        .keyboardShortcut(.cancelAction)
                    Spacer(minLength: 0)
                    ForEach(visibleActions.filter { !InboxActionWords.isPrimary($0.id) }, id: \.id) { action in
                        Button(action.label) { perform(action.id, closesOnSuccess: true) }
                            .disabled(isActing)
                    }
                    ForEach(visibleActions.filter { InboxActionWords.isPrimary($0.id) }, id: \.id) { action in
                        Button(action.label) { perform(action.id, closesOnSuccess: true) }
                            .buttonStyle(.borderedProminent)
                            .hazeTinted(.button)
                            .disabled(isActing)
                    }
                }
                .controlSize(.large)
            }
            .padding(.horizontal, NativeAgentSpacing.xl)
            .padding(.vertical, NativeAgentSpacing.lg)
        }
        .frame(minWidth: 460, idealWidth: 560, minHeight: 320, idealHeight: 480)
        .animation(NativeAgentMotion.standard, value: actionError)
        .onAppear { perform("read", closesOnSuccess: false) }
    }

    private func perform(_ actionID: String, closesOnSuccess: Bool) {
        guard !isActing else { return }
        isActing = true
        actionError = nil
        Task { @MainActor in
            defer { isActing = false }
            let outcome = await onAction(actionID)
            switch InboxDetailActionPresentation.effect(
                for: outcome,
                closesOnSuccess: closesOnSuccess
            ) {
            case .dismiss:
                onClose()
            case .showError:
                actionError = InboxActionWords.failure(actionID)
            case .keepOpen:
                break
            }
        }
    }

}

/// What a note's action buttons say, and what a failed one says: what didn't
/// happen and what to do, never the writer's own error text.
enum InboxActionWords {
    static func isPrimary(_ actionID: String) -> Bool {
        actionID == "act" || actionID == "approve" || actionID == "open_approvals" || actionID == "repair"
    }

    static func failure(_ actionID: String) -> String {
        let what: String
        switch actionID {
        case "read": what = "mark this note read"
        case "archive": what = "archive this note"
        case "dismiss": what = "dismiss this note"
        case "approve": what = "approve this"
        case "reject", "deny": what = "decline this"
        default: what = "do that"
        }
        return "Couldn't \(what). Try again in a moment."
    }
}

/// A sheet only dismisses after its action's durable write succeeds. Failures
/// stay mounted with the error so an inbox card cannot falsely disappear.
enum InboxDetailActionPresentation {
    enum Effect: Equatable {
        case keepOpen
        case dismiss
        case showError(String)
    }

    static func effect(
        for outcome: InboxRowActionFlight.Outcome,
        closesOnSuccess: Bool
    ) -> Effect {
        switch outcome {
        case .succeeded: return closesOnSuccess ? .dismiss : .keepOpen
        case .failed(let message): return .showError(message)
        case .dropped: return .keepOpen
        }
    }
}


// MARK: - Full inbox list (accessible from chat header or settings)

/// W6/G12 — the two reading lanes. Not a filter over severity or status: a
/// filter over *who the card is addressed to*.
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

/// Production seam for the value emitted by a Review Groups button and the
/// same list population InboxView renders. Keeping it here prevents a group
/// selection from becoming a detail-sheet-only presentation effect.
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

/// One population definition for every Inbox lane count visible at once.  The
/// segment badge and the empty-state pointer both describe unread, default-
/// visible cards; using different filters made a quiet lane claim it had work
/// while its own badge said nothing.
enum InboxLanePresentation {
    /// Inbox navigation is view-local, so every fresh presentation must begin
    /// in the human lane. Keep the default and segment order explicit instead
    /// of inheriting declaration order from `CaseIterable`.
    static let initialLane: InboxLane = .forYou
    static let pickerLanes: [InboxLane] = [.forYou, .system]

    static func unreadVisibleCount(in lane: InboxLane, items: [InboxItemRecord]) -> Int {
        items.count {
            lane.matches($0) && $0.isUnread && !$0.isHiddenFromDefaultInbox
        }
    }
}

/// The two locations that talk about another inbox lane must use one bounded
/// population: visible unread cards. This is a rendered truth contract, not a
/// second inbox state owner.
struct InboxView: View {
    init(initialGroup: InboxRelatedGroup? = nil) {
        _groupFilter = State(initialValue: initialGroup)
    }

    @Environment(AppModel.self) private var appModel

    private var inbox: InboxFacade { appModel.engine.inbox }
    @State private var showAll = false
    @State private var groupFilter: InboxRelatedGroup?
    // G12: defaults to the human lane. The operations feed is one click away,
    // it is just no longer the thing User's day opens with.
    @State private var lane: InboxLane = InboxLanePresentation.initialLane


    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // The sheet around this page already says what it is; one row of
            // controls, then the notes.
            HStack(spacing: NativeAgentSpacing.md) {
                // G12: the segmented control. Unread counts live ON the
                // segments so the System lane is never a silent hiding place.
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
                    // Lane-aware: an empty "For you" lane with a full System
                    // lane says which lane is empty and points at the other.
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
                        // Outstanding requests sit above notification history
                        // and stay there once read. Only resolving them clears
                        // them.
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
            waiting: waiting,
            allItems: inbox.items,
            dataRootOverride: appModel.dataRootOverride,
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

    /// The same visibility rules, across every lane, so a request filed under
    /// System still reaches the person it is waiting on.
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

    /// Unread count per lane, over the same visibility rules the list uses —
    /// a dismissed card must not inflate the segment it sits behind.
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

/// Serializes the direct action buttons on an inbox row.  Keeping the complete
/// success/failure branch here means the visible row can neither double-submit
/// a slow action nor present a failed write as a resolved card.
@MainActor @Observable
final class InboxRowActionFlight {
    enum Outcome: Equatable {
        case dropped
        case succeeded
        case failed(message: String)
    }

    private(set) var isInFlight = false

    func perform(operation: @escaping @MainActor () async throws -> Void) async -> Outcome {
        guard !isInFlight else { return .dropped }
        isInFlight = true
        defer { isInFlight = false }

        do {
            try await operation()
            return .succeeded
        } catch {
            // The writer's text goes to the log; the page says what to do.
            ModuleLog.app("%@", "[inbox] action failed: \(error.localizedDescription)")
            return .failed(message: "That didn't go through. Try again in a moment.")
        }
    }
}

/// Applies the one visible success consequence after an inbox write settles.
/// The inline buttons and detail sheet both call `performAction(_:)`, which
/// uses this owner; a failed/dropped write has no route to a local read patch
/// or a resolved-row reload.
@MainActor
enum InboxRowActionCompletion {
    @discardableResult
    static func apply(
        _ outcome: InboxRowActionFlight.Outcome,
        actionID: String,
        onResolved: () -> Void,
        onMarkedRead: () -> Void
    ) -> InboxRowActionFlight.Outcome {
        guard case .succeeded = outcome else { return outcome }
        if actionID == "read" {
            onMarkedRead()
        } else {
            onResolved()
        }
        return outcome
    }
}

/// One note on the Inbox page: an alive card, with the soft teal top only
/// when it waits on the person. Tapping it opens the detail sheet.
struct InboxListRow: View {
    @Environment(AppModel.self) private var appModel
    let item: InboxItemRecord
    var waiting = false
    let allItems: [InboxItemRecord]
    let dataRootOverride: URL?
    let onAction: () -> Void
    // ui-honesty 2026-06-10: fired after a successful "read" action so the
    // parent can publish the committed read through the shared inbox owner.
    let onMarkedRead: () -> Void
    let onSelectGroup: (InboxRelatedGroup) -> Void

    @State private var showDetail = false
    // The shared action flight owns the row's visible busy state and terminal
    // outcome, rather than relying on a button-local best-effort guard.
    @State private var actionFlight = InboxRowActionFlight()
    // A failed action stays visible as one line under the row's buttons; the
    // row never dismisses on a write that didn't land.
    @State private var actionError: String? = nil

    private var visibleActions: [InboxActionRecord] {
        InboxVisibleActionsPresentation.actions(for: item)
    }

    @ViewBuilder
    var body: some View {
        if item.source == InlineInteractionDelivery.source {
            InteractionInboxCard(item: item)
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
                // One main button, the rest in the Mac's own menu (User 09-27:
                // all controls native; no sideways-scrolling button strip).
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

    /// The only native-client action path for both inline row buttons and the
    /// detail sheet. Success callbacks are deliberately chosen here, after the
    /// durable write, so the two surfaces cannot drift on read vs. resolution.
    private func performAction(_ actionID: String) async -> InboxRowActionFlight.Outcome {
        let outcome = await actionFlight.perform {
            try await InboxCardActions.perform(item.id, action: actionID,
                dataRootOverride: dataRootOverride, effects: AppInboxCardActionEffects(inbox: appModel.engine.inbox))
        }
        return InboxRowActionCompletion.apply(
            outcome,
            actionID: actionID,
            onResolved: onAction,
            onMarkedRead: onMarkedRead
        )
    }
}
