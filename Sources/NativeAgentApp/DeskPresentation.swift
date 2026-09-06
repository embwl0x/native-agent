import Foundation
import PersistenceCore
import WorkshopExecution

// MARK: - Desk presentation facts
//
// These are deliberately value-only descriptions of the state that DeskView
// renders.  Store and runner code retain ownership of truth; this layer makes
// the final translation into a human claim executable without inspecting a
// SwiftUI body in tests.

enum DeskPresentationTone: Sendable, Equatable {
    case neutral
    case info
    case success
    case warning
    case danger
}

/// One semantic color vocabulary for every status-bearing Desk row. The view
/// translates these tones to SwiftUI colors once; board items, delegation
/// lanes, directed executions, and GitHub watcher rows never keep independent
/// color switches that can drift apart.
enum DeskStatusTonePresentation {
    static func tone(for status: DeskStatus) -> DeskPresentationTone {
        switch status {
        case .now, .next: .info
        case .blocked: .danger
        case .flag: .warning
        case .done: .success
        case .todo, .watch, .canceled: .neutral
        }
    }
}

/// Shared relative-time vocabulary for every timestamp rendered on Desk rows.
/// Callers provide the frozen presentation clock, which keeps tests and exact
/// freshness boundaries deterministic without introducing a timer.
enum DeskRelativeTimePresentation {
    static func text(forISO raw: String, now: Date) -> String {
        guard let date = UserDisplayFormatters.parseISOTimestamp(raw) else {
            return "unknown"
        }
        return text(for: date, now: now)
    }

    static func text(for date: Date, now: Date) -> String {
        let seconds = max(0, now.timeIntervalSince(date))
        switch seconds {
        case ..<90: return "just now"
        case ..<3_600: return "\(Int(seconds / 60))m ago"
        case ..<86_400: return "\(Int(seconds / 3_600))h ago"
        default: return "\(Int(seconds / 86_400))d ago"
        }
    }
}

/// Counts are glance aids, not zero-state metrics. A quiet section keeps its
/// plain title; a populated section uses the same compact label everywhere.
enum DeskSectionHeaderPresentation {
    static func label(_ title: String, count: Int?) -> String {
        guard let count, count > 0 else { return title }
        return "\(title) · \(count)"
    }
}

/// The Desk's reader-facing truth state.  This is deliberately separate from
/// row layout: a successful empty read is quiet, while an unavailable read is
/// a visible uncertainty and prevents the whole board from claiming it is
/// clear.  DeskView consumes this projection directly so the wording and the
/// no-silent-zero rule are testable without mounting SwiftUI.
enum DeskHonestyPresentation {
    struct UnavailableNotice: Equatable, Sendable {
        let title: String
        let detail: String
    }

    enum LaneBody: Equatable, Sendable {
        case unavailable(UnavailableNotice)
        case quiet(String)
        case rows
    }

    enum BoardBody: Equatable, Sendable {
        case loading
        case clear
        case populated
    }

    static let githubQuietCopy =
        "The watcher is quiet. Tracked GitHub changes appear here and notify you when attention is needed; nothing starts automatically."
    static let executionQuietCopy = "Quiet right now — nothing running."

    static func githubLane(_ lane: DeskLaneState<GitHubCommandItem>) -> LaneBody {
        if let reason = lane.unavailableReason {
            return .unavailable(UnavailableNotice(
                title: "GitHub Watcher state unavailable",
                detail: reason))
        }
        return lane.items.isEmpty ? .quiet(githubQuietCopy) : .rows
    }

    static func executionLane(
        _ lane: DeskLaneState<WorkshopExecution.WorkshopExecutionRecord>,
        hasRenderedBenchRows: Bool
    ) -> LaneBody {
        if let reason = lane.unavailableReason {
            return .unavailable(UnavailableNotice(
                title: "Execution lane unavailable",
                detail: reason))
        }
        return hasRenderedBenchRows ? .rows : .quiet(executionQuietCopy)
    }

    /// "In progress" is fed by both Workshop executions and Desk program
    /// families. A failed read from either owner makes the combined section
    /// unknown; rendering the other owner's empty result as "Quiet" would be
    /// the same silent-zero failure `DeskLaneState` exists to prevent.
    static func inProgressLane(
        executions: DeskLaneState<WorkshopExecution.WorkshopExecutionRecord>,
        deskItems: DeskLaneState<DeskItem>,
        hasRenderedRows: Bool
    ) -> LaneBody {
        if let reason = executions.unavailableReason {
            return .unavailable(UnavailableNotice(
                title: "Execution lane unavailable",
                detail: reason))
        }
        if let reason = deskItems.unavailableReason {
            return .unavailable(UnavailableNotice(
                title: "Desk program state unavailable",
                detail: reason))
        }
        return hasRenderedRows ? .rows : .quiet(executionQuietCopy)
    }

    static func boardBody(
        itemCount: Int,
        executionCount: Int,
        githubItemCount: Int,
        loadError: String?,
        hasLoadedOnce: Bool,
        hasUnavailableLane: Bool
    ) -> BoardBody {
        guard itemCount == 0,
              executionCount == 0,
              githubItemCount == 0,
              loadError == nil,
              !hasUnavailableLane
        else {
            return .populated
        }
        return hasLoadedOnce ? .clear : .loading
    }
}

// MARK: - Live Activity

/// The pure, value-only model behind Desk's glancing Live Activity header.
/// Canonical Desk rows remain the sole truth; this projection neither writes
/// status nor promotes `laneOf` into the real `parent` hierarchy.
enum DeskLiveActivityPresentation {
    static let defaultActiveWindow: TimeInterval = 30 * 60
    static let staleAfter: TimeInterval = 5 * 60
    static let visibleRowCap = 4
    private static let boundaryEpsilon: TimeInterval = 0.001

    struct Progress: Sendable, Equatable {
        let done: Int
        let total: Int
        let note: String?

        var fraction: Double { Double(done) / Double(total) }
    }

    struct Row: Identifiable, Sendable, Equatable {
        let id: String
        let summary: String
        let assignee: String
        let assigneeSymbol: String
        let lastUpdateText: String
        let progress: Progress?
    }

    struct Content: Sendable, Equatable {
        let rows: [Row]
        let overflowCount: Int
        let asOfText: String
        let isStale: Bool
        /// The next semantic boundary only: snapshot becomes stale or one
        /// active row ages out. DeskLiveReloader sleeps to this exact instant;
        /// there is no periodic freshness timer.
        let nextRefreshAt: Date?

        /// Every row eligible for this section, including the deterministic
        /// overflow disclosed by "+N more". This is never a hidden store total.
        var eligibleRowCount: Int { rows.count + overflowCount }
    }

    enum State: Sendable, Equatable {
        case unavailable(DeskHonestyPresentation.UnavailableNotice)
        case quiet
        case rows(Content)

        var nextRefreshAt: Date? {
            guard case .rows(let content) = self else { return nil }
            return content.nextRefreshAt
        }
    }

    static func make(
        deskItems: DeskLaneState<DeskItem>,
        generatedTs: String?,
        now: Date,
        activeWindow: TimeInterval = defaultActiveWindow,
        rowCap: Int = visibleRowCap,
        staleLimit: TimeInterval = staleAfter
    ) -> State {
        if let reason = deskItems.unavailableReason {
            return .unavailable(.init(title: "Live Activity unavailable", detail: reason))
        }

        let window = max(0, activeWindow)
        let candidates = deskItems.items.compactMap { item -> (DeskItem, Date)? in
            guard item.status == .now,
                  let updated = UserDisplayFormatters.parseISOTimestamp(item.updatedAt)
            else { return nil }
            // Future stamps are treated as zero-age rather than being allowed
            // to manufacture a negative relative time.
            guard max(0, now.timeIntervalSince(updated)) <= window else { return nil }
            return (item, updated)
        }.sorted { left, right in
            if left.1 != right.1 { return left.1 > right.1 }
            if left.0.updatedAt != right.0.updatedAt {
                return left.0.updatedAt > right.0.updatedAt
            }
            return left.0.handle < right.0.handle
        }

        // Blank slate and ordinary quiet state collapse completely, including
        // a blank generatedTs from an empty canonical feed.
        guard !candidates.isEmpty else { return .quiet }

        guard let generatedTs,
              let generatedAt = UserDisplayFormatters.parseISOTimestamp(generatedTs)
        else {
            return .unavailable(.init(
                title: "Live Activity unavailable",
                detail: "The Desk snapshot has no readable generated timestamp."))
        }

        let limit = max(0, staleLimit)
        let snapshotAge = max(0, now.timeIntervalSince(generatedAt))
        let stale = snapshotAge > limit
        let cap = max(0, rowCap)
        let visible = candidates.prefix(cap).map { item, updated in
            Row(
                id: item.handle,
                summary: humanSummary(item),
                assignee: assigneeLabel(item.assignee),
                assigneeSymbol: assigneeSymbol(item.assignee),
                lastUpdateText: "last update \(DeskRelativeTimePresentation.text(for: updated, now: now))",
                progress: item.progress.map {
                    Progress(done: $0.done, total: $0.total, note: $0.note)
                }
            )
        }

        var boundaries = candidates.compactMap { _, updated -> Date? in
            let expiry = updated.addingTimeInterval(window + boundaryEpsilon)
            return expiry > now ? expiry : nil
        }
        if !stale {
            let staleBoundary = generatedAt.addingTimeInterval(limit + boundaryEpsilon)
            if staleBoundary > now { boundaries.append(staleBoundary) }
        }

        return .rows(Content(
            rows: visible,
            overflowCount: max(0, candidates.count - visible.count),
            asOfText: "as of \(DeskRelativeTimePresentation.text(for: generatedAt, now: now))",
            isStale: stale,
            nextRefreshAt: boundaries.min()
        ))
    }

    static func relativeAge(_ date: Date, now: Date) -> String {
        DeskRelativeTimePresentation.text(for: date, now: now)
    }

    static func humanSummary(_ item: DeskItem) -> String {
        let summary = item.summary?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let summary, !summary.isEmpty { return summary }
        let title = item.title.trimmingCharacters(in: .whitespacesAndNewlines)
        return title.isEmpty ? "Untitled desk item" : title
    }

    static func assigneeLabel(_ value: String?) -> String {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let trimmed, !trimmed.isEmpty else { return "Unassigned" }
        return trimmed
    }

    static func assigneeSymbol(_ value: String?) -> String {
        switch value?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "codex": return "chevron.left.forwardslash.chevron.right"
        case "claude": return "sparkles"
        case "agent": return "brain.head.profile"
        default: return "person.crop.circle"
        }
    }
}

// MARK: - Delegation program families

/// `laneOf` is intentionally consumed only here, as a read model. Canonical
/// `DeskItem.parent`, sequencing, archive guards, and board grouping remain
/// untouched; a delegation family is visual context, not a second hierarchy.
enum DeskProgramFamilyPresentation {
    struct Lane: Identifiable, Sendable, Equatable {
        let id: String
        let title: String
        let assignee: String
        let assigneeSymbol: String
        let status: DeskStatus
        let progress: DeskLiveActivityPresentation.Progress?
    }

    struct Family: Identifiable, Sendable, Equatable {
        let id: String
        let parentTitle: String
        let parentSummary: String
        let lanes: [Lane]
        fileprivate let newestUpdate: Date?
    }

    static func families(from deskItems: DeskLaneState<DeskItem>) -> [Family] {
        guard deskItems.unavailableReason == nil else { return [] }
        return families(from: deskItems.items)
    }

    static func families(from items: [DeskItem]) -> [Family] {
        // A canonical store cannot produce duplicate handles, but this is a UI
        // projection over durable bytes: retaining the first row is safer than
        // trapping if a damaged/manual fixture reaches the presentation seam.
        let byHandle = items.reduce(into: [String: DeskItem]()) { result, item in
            if result[item.handle] == nil { result[item.handle] = item }
        }
        var lanesByParent: [String: [DeskItem]] = [:]
        for item in items {
            guard let raw = item.laneOf?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !raw.isEmpty,
                  raw != item.handle,
                  byHandle[raw] != nil
            else { continue }
            lanesByParent[raw, default: []].append(item)
        }

        return items.compactMap { parent -> Family? in
            guard let lanes = lanesByParent[parent.handle], !lanes.isEmpty,
                  parent.status == .now || lanes.contains(where: { $0.status == .now })
            else { return nil }
            let newest = ([parent] + lanes)
                .compactMap { UserDisplayFormatters.parseISOTimestamp($0.updatedAt) }
                .max()
            return Family(
                id: parent.handle,
                parentTitle: parent.title,
                parentSummary: DeskLiveActivityPresentation.humanSummary(parent),
                lanes: lanes.map { lane in
                    Lane(
                        id: lane.handle,
                        title: DeskLiveActivityPresentation.humanSummary(lane),
                        assignee: DeskLiveActivityPresentation.assigneeLabel(lane.assignee),
                        assigneeSymbol: DeskLiveActivityPresentation.assigneeSymbol(lane.assignee),
                        status: lane.status,
                        progress: lane.progress.map {
                            .init(done: $0.done, total: $0.total, note: $0.note)
                        }
                    )
                },
                newestUpdate: newest
            )
        }.sorted { left, right in
            if left.newestUpdate != right.newestUpdate {
                return (left.newestUpdate ?? .distantPast) > (right.newestUpdate ?? .distantPast)
            }
            return left.id < right.id
        }
    }
}

enum DeskExecutionPresentation {
    struct Pill: Sendable, Equatable {
        let label: String
        let tone: DeskPresentationTone
    }

    struct Slice: Sendable, Equatable {
        let benchIDs: [String]
        let approvalIDs: [String]
        let recentDoneIDs: [String]
    }

    private static let terminalStatuses: Set<String> = ["completed", "failed", "cancelled"]

    /// Unknown states belong on the bench rather than silently disappearing.
    static func slice(_ executions: [WorkshopExecution.WorkshopExecutionRecord]) -> Slice {
        let approval = executions.filter { $0.status == "blocked_on_approval" }
        let bench = executions.filter {
            $0.status != "blocked_on_approval" && !terminalStatuses.contains($0.status)
        }
        let recent = Array(executions
            .filter { terminalStatuses.contains($0.status) }
            .sorted { $0.updatedAt > $1.updatedAt })
        return Slice(
            benchIDs: bench.map(\.id),
            approvalIDs: approval.map(\.id),
            recentDoneIDs: recent.map(\.id))
    }

    static func pill(for status: String) -> Pill {
        switch status {
        case "running": return Pill(label: "running", tone: .info)
        case "queued": return Pill(label: "queued", tone: .neutral)
        case "blocked_on_approval": return Pill(label: "needs approval", tone: .warning)
        case "completed": return Pill(label: "done", tone: .success)
        case "failed": return Pill(label: "failed", tone: .danger)
        case "cancelled": return Pill(label: "cancelled", tone: .neutral)
        default:
            let human = status.replacingOccurrences(of: "_", with: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return Pill(label: human.isEmpty ? "unknown status" : "unknown: \(human)", tone: .neutral)
        }
    }

    static func progress(status: String, planCount: Int, completedCount: Int) -> String? {
        guard status == "running", planCount > 0 else { return nil }
        return "step \(min(max(completedCount + 1, 1), planCount)) of \(planCount)"
    }

    static func verificationLabel(_ verification: WorkshopVerificationRecord) -> String {
        switch verification.status {
        case .satisfied:
            let methods = verification.methods.map { method in
                switch method {
                case "exact_output": return "exact output"
                case "file_bytes": return "file bytes"
                default: return method.replacingOccurrences(of: "_", with: " ")
                }
            }.filter { !$0.isEmpty }.joined(separator: " + ")
            return methods.isEmpty ? "verified" : "verified: \(methods)"
        case .failed:
            return "verification failed"
        case .unverified:
            return "completed; outcome not independently verified"
        }
    }
}

enum DeskItemPresentation {
    struct BlockedPill: Sendable, Equatable {
        let text: String
        let targetHandle: String
    }

    static func statusLabel(_ status: DeskStatus) -> String {
        status.displayLabel
    }

    static func nagBellSymbol(config: DeskNagConfig, now: Date) -> String {
        if config.isMuted(now: now) { return "bell.slash" }
        return config.enabled ? "bell.fill" : "bell"
    }

    /// A blocker with no live alias is not actionable UI.  The rendered pill
    /// and its navigation target therefore come from the same resolved list.
    static func blockedPill(
        plan: DeskSequencing.ItemPlan,
        aliases: [String: String],
        cap: Int = 3
    ) -> BlockedPill? {
        let resolved = plan.effectiveBlockers.compactMap { handle in
            aliases[handle].map { (handle: handle, alias: $0) }
        }
        guard let first = resolved.first else { return nil }
        let shown = resolved.prefix(max(cap, 1)).map(\.alias).joined(separator: ", ")
        let overflow = resolved.count - min(resolved.count, max(cap, 1))
        return BlockedPill(
            text: "waiting on \(shown)" + (overflow > 0 ? " +\(overflow)" : ""),
            targetHandle: first.handle)
    }

    static func visiblePrefix<T>(_ values: [T], showingAll: Bool, cap: Int = 8) -> [T] {
        showingAll ? values : Array(values.prefix(max(cap, 0)))
    }

    /// The one Desk-wide definition of a row requiring attention. An explicit
    /// waiting owner is meaningful state even when the row is neither blocked
    /// nor flagged, so summaries and the attention strip must share this rule.
    static func needsEyes(_ item: DeskItem) -> Bool {
        item.status == .blocked || item.status == .flag || (item.waitingOn?.isEmpty == false)
    }

    static func githubProjectNeedsEyes(_ items: [DeskItem]) -> Int {
        items.lazy.filter(needsEyes).count
    }

    static func paletteTargetIsActionable(_ handle: String, activeHandles: Set<String>) -> Bool {
        activeHandles.contains(handle)
    }

    /// The whole-board store failure is rendered next to lane failures, so it
    /// shares their precise bounded-error contract instead of creating a second
    /// arbitrary limit at the top of the Desk.
    static func boundedLoadFailure(_ detail: String) -> String {
        DeskLaneState<DeskItem>.boundedReason(detail)
    }

    /// Maps the actual Desk-store read failure into the banner's visible,
    /// bounded state. A custom error may provide no localized detail; that is
    /// still a failure, never an empty or clear desk.
    static func loadFailure(_ error: any Error) -> String {
        let detail = error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        let visibleDetail = detail.isEmpty
            ? "The storage read failed without details."
            : detail
        return boundedLoadFailure("Couldn't load the bench: \(visibleDetail)")
    }

    struct Freshness: Sendable, Equatable {
        let text: String
        let isStale: Bool
        let isKnown: Bool
    }

    static let staleThresholdDays = 7

    /// The row's timestamp claim. A malformed timestamp is unknown, never
    /// fresh; blocked and flagged rows retain a plain age because their status
    /// already carries the urgent signal.
    static func freshness(for item: DeskItem, now: Date) -> Freshness {
        guard let date = UserDisplayFormatters.parseISOTimestamp(item.updatedAt) else {
            return Freshness(text: "unknown", isStale: false, isKnown: false)
        }
        let seconds = max(0, now.timeIntervalSince(date))
        let days = Int(seconds / 86_400)
        let plain = DeskRelativeTimePresentation.text(for: date, now: now)
        let stale = days >= staleThresholdDays
            && item.status != .blocked && item.status != .flag && !item.status.isTerminal
        return Freshness(text: stale ? "\(days)d stale" : plain, isStale: stale, isKnown: true)
    }

    struct PursuitCard: Sendable, Equatable {
        let title: String
        let sessionLabel: String
        let holdLabel: String?
        let doneLabel: String
    }

    /// The pursuits lane includes every self-authored project, including a
    /// legacy/corrupt row whose optional `pursuit` payload could not decode.
    /// The latter gets an explicit integrity card instead of disappearing
    /// behind a section count.
    enum PursuitCardState: Sendable, Equatable {
        case rendered(PursuitCard)
        case payloadUnreadable
        case notPursuit
    }

    static func pursuitCardState(for item: DeskItem) -> PursuitCardState {
        guard DeskBoardLayout.isPursuitLaneItem(item) else { return .notPursuit }
        guard let card = pursuitCard(for: item) else { return .payloadUnreadable }
        return .rendered(card)
    }

    static func pursuitCard(for item: DeskItem) -> PursuitCard? {
        guard let pursuit = item.pursuit else { return nil }
        let holdLabel: String?
        if item.status == .blocked, let reason = item.blockedReason, !reason.isEmpty {
            holdLabel = reason
        } else if let waiting = item.waitingOn, !waiting.isEmpty {
            holdLabel = "waiting on \(waiting)"
        } else {
            holdLabel = nil
        }
        return PursuitCard(
            title: pursuit.privateName ?? item.title,
            sessionLabel: "\(pursuit.reservations.count)/\(pursuit.maxSessions) sessions",
            holdLabel: holdLabel,
            doneLabel: pursuit.doneLooksLike)
    }
}

/// The exact rows an Agent pursuits header counts and renders. A row that
/// survived the Desk state decoder but lost its optional pursuit payload still
/// appears here as a visible integrity warning, so the count cannot claim a
/// card that the section drops.
enum DeskPursuitSectionPresentation {
    static let unreadablePayloadLabel = "Pursuit payload unreadable"
    static let unreadablePayloadDetail = "This self-authored project could not be rendered as a pursuit. Repair its saved pursuit payload before acting on it."

    struct Row: Identifiable, Sendable, Equatable {
        let item: DeskItem
        let cardState: DeskItemPresentation.PursuitCardState

        var id: String { item.handle }
    }

    static func rows(from activeItems: [DeskItem]) -> [Row] {
        DeskBoardLayout.pursuits(activeItems).map { item in
            Row(item: item, cardState: DeskItemPresentation.pursuitCardState(for: item))
        }
    }

    static func headerCount(for rows: [Row]) -> Int? {
        rows.isEmpty ? nil : rows.count
    }
}

/// The owner's Veto control on a Desk pursuit row (Fable 5.1 sweep item 36).
///
/// Veto is owner authority over something the agent opened for herself, so it
/// belongs on the row User already reads — not behind the developer gate in
/// Diagnostics ▸ Cognition ▸ Desk, where it used to live beside a second copy
/// of this same pursuit list. The store-side mutation is unchanged
/// (`WorkshopObservatoryVetoHandler` → `SwiftNativeDeskStore.vetoPursuit`);
/// only the surface moved.
///
/// The action closure is required at construction — the same rule the mounted
/// observatory button held: an enabled Veto control can never silently discard
/// an owner decision because an embedding route forgot to wire it.
struct DeskPursuitVetoControl {
    /// Handles whose veto is awaiting its durable outcome.
    let pendingHandles: Set<String>
    let onVeto: (String) -> Void

    static let help = "Close this pursuit (canceled) with a user-vetoed note."

    func isDisabled(_ handle: String) -> Bool {
        WorkshopObservatoryVetoPresentation.buttonIsDisabled(
            handle: handle, pendingHandles: pendingHandles)
    }

    func trigger(_ handle: String) {
        onVeto(handle)
    }
}

/// What the Desk says after a veto settles. Every outcome gets a line — a
/// refused write must never look like a completed one.
enum DeskPursuitVetoNotice {
    static func receipt(for outcome: WorkshopObservatoryVetoHandler.Outcome) -> DeskActionNotice {
        switch outcome {
        case .completed:
            return DeskActionNotice(text: "Pursuit vetoed and closed.", isError: false)
        case .alreadyVetoed:
            return DeskActionNotice(text: "Pursuit was already vetoed.", isError: false)
        case .inFlight:
            return DeskActionNotice(text: "That veto is still being written.", isError: false)
        case .failed(let detail):
            return DeskActionNotice(text: "Veto failed: \(detail)", isError: true)
        }
    }
}

/// Score, budget and the recorded reason a pursuit row carries next to its
/// Veto control — the facts an owner needs to veto on. Folded by the SAME pure
/// projection the observatory used (`WorkshopPursuitRow.from`), so moving the
/// control did not fork the numbers behind it.
enum DeskPursuitVetoRationale {
    static func row(for item: DeskItem, now: Date) -> WorkshopPursuitRow? {
        guard item.pursuit != nil else { return nil }
        return WorkshopPursuitRow.from(item: item, now: now)
    }

    /// "score 1.83" — nil when the pursuit payload gave no score, so the row
    /// says nothing rather than showing a misleading 0.
    static func scoreLabel(_ score: WorkshopScoreView?) -> String? {
        guard let score else { return nil }
        return "score \(String(format: "%.2f", score.total))"
    }

    /// "2/3 sessions · 1/2 today" — the two hard caps the pursuit lives under.
    static func budgetLabel(_ budget: WorkshopBudget?) -> String? {
        guard let budget else { return nil }
        return "\(budget.sessionsUsed)/\(budget.maxSessions) sessions · "
            + "\(budget.todayCount)/\(budget.perDayCap) today"
    }

    /// Her most recent recorded "chose: …" rationale, stripped of the marker.
    static func reasonLabel(_ rationale: String?) -> String? {
        guard let rationale else { return nil }
        let trimmed = rationale
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let body = trimmed.hasPrefix(WorkshopPursuitRow.choiceMarker)
            ? String(trimmed.dropFirst(WorkshopPursuitRow.choiceMarker.count))
            : trimmed
        let cleaned = body.trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? nil : cleaned
    }
}

/// Human vocabulary for the GitHub Watcher state pill. Persisted enum names
/// are machine identifiers and must never become a visible fallback label.
enum DeskGitHubStatePillPresentation {
    struct Pill: Equatable {
        let label: String
        let tone: DeskPresentationTone
    }

    static let stalledCallbackStatus = "stalled"

    static func pill(for item: GitHubCommandItem) -> Pill {
        switch item.state {
        case .detected, .needsCodex:
            return Pill(label: "Action needed", tone: .warning)
        case .codexWorking:
            return Pill(label: "Codex working", tone: .info)
        case .verifying:
            return Pill(label: "Verifying", tone: .info)
        case .needsUser:
            return Pill(label: "Needs you", tone: .warning)
        case let .waitingUpstream(kind):
            return Pill(label: waitingLabel(for: kind), tone: .neutral)
        case let .attention(reason):
            return attentionPill(reason: reason, callbackStatus: item.lastCallbackStatus)
        case .resolved:
            return Pill(label: "Resolved", tone: .success)
        }
    }

    static func waitingLabel(for kind: GitHubCommandWaitingKind) -> String {
        switch kind {
        case .review: return "Waiting for review"
        case .ci: return "Waiting for checks"
        case .maintainer: return "Waiting for maintainer"
        case .readyToMerge: return "Ready to merge"
        }
    }

    private static func attentionPill(
        reason: GitHubCommandAttentionReason,
        callbackStatus: String?
    ) -> Pill {
        let label: String
        switch reason {
        case .dispatchFailed: label = "Dispatch failed"
        case .codexFailed:
            label = normalizedCallbackStatus(callbackStatus) == stalledCallbackStatus
                ? "Codex stalled"
                : "Codex no result"
        case .verificationFailed: label = "GitHub still actionable"
        case .verificationReadFailed: label = "GitHub verification unreadable"
        case .callbackOverdue: label = "Codex stalled"
        case .codexBusy: label = "Legacy Codex retry"
        case .stale: label = "Stale observation"
        case .contradictoryState: label = "State needs review"
        }
        return Pill(label: label, tone: .danger)
    }

    private static func normalizedCallbackStatus(_ status: String?) -> String {
        status?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
    }
}

/// The ordered status-critical facts rendered above a Desk row's free-text
/// detail. The board and pursuits share this exact projection, so a blocker
/// never becomes navigable in one lane but inert or absent in the other.
enum DeskSequencingPillPresentation {
    enum Kind: String, Sendable, Equatable {
        case rollup
        case blocked
        case cycle
        case deferred
        case nextUp
    }

    struct Pill: Identifiable, Sendable, Equatable {
        let kind: Kind
        let text: String
        let targetHandle: String?

        var id: String { kind.rawValue }
    }

    static func pills(
        item: DeskItem,
        itemPlan: DeskSequencing.ItemPlan,
        isNextUp: Bool,
        aliases: [String: String],
        blockerAliasCap: Int = 3
    ) -> [Pill] {
        var result: [Pill] = []
        if itemPlan.totalCount > 0 {
            result.append(Pill(
                kind: .rollup,
                text: "\(itemPlan.doneCount)/\(itemPlan.totalCount) closed",
                targetHandle: nil
            ))
        }
        if let blocked = DeskItemPresentation.blockedPill(
            plan: itemPlan,
            aliases: aliases,
            cap: blockerAliasCap
        ) {
            result.append(Pill(
                kind: .blocked,
                text: blocked.text,
                targetHandle: blocked.targetHandle
            ))
        }
        if itemPlan.blockedByCycle {
            result.append(Pill(
                kind: .cycle,
                text: "⚠ these block each other",
                targetHandle: nil
            ))
        }
        if itemPlan.isDeferred {
            let day = item.deferUntil.flatMap(DeskSequencing.deferDisplayDay)
            result.append(Pill(
                kind: .deferred,
                text: day.map { "until \($0)" } ?? "deferred; date unavailable",
                targetHandle: nil
            ))
        }
        if isNextUp {
            result.append(Pill(kind: .nextUp, text: "start here", targetHandle: nil))
        }
        return result
    }
}

enum DeskActionPresentation {
    struct Notice: Sendable, Equatable {
        let symbol: String
        let tone: DeskPresentationTone
    }

    static func notice(isError: Bool) -> Notice {
        isError
            ? Notice(symbol: "exclamationmark.triangle", tone: .warning)
            : Notice(symbol: "checkmark.circle", tone: .success)
    }
}

enum DeskFinishedPresentation {
    static func sectionCount(groupCount: Int, recentExecutionCount: Int) -> Int {
        max(groupCount, 0) + max(recentExecutionCount, 0)
    }
}
