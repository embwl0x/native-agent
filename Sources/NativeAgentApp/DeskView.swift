import SwiftUI
import AppKit
import PersistenceCore
import WorkshopExecution

// MARK: - DeskView — the owner's window into the agent's Desk
//
// Agent captures + mutates the desk through chat tools (desk_*); this tab is the
// human-pleasant render of the same live state (SwiftNativeDeskStore.liveState())
// plus its directed execution lane, and a disclosure showing the exact compact
// projection she reads in-context. READ-ONLY by design: User glances, Agent
// maintains.
//
// Sectioned Desk (User, 2026-07-11: "it just shows up like her regular desk did
// — make it into sections"). Directed executions are one lane on the Desk, so
// this surface tells its story top-to-bottom by urgency and ownership:
//   1. Live Activity     — recent `.now` ops only; absent when quiet
//   2. Waiting on you    — approval-blocked executions + blocked/flagged items
//   3. In progress       — delegation families + directed executions
//   4. Her pursuits      — origin=agent self-pursuits, in her own words
//   5. The board         — User/system items, family-grouped as before
//   6. Recently finished — terminal items + recent terminal executions

/// A lane's read outcome — the honesty primitive this surface borrows from
/// `WorkshopReceiptsState` (WorkshopObservatoryPanel.swift:237). `.rows([])`
/// means the lane is genuinely empty; `.unavailable(reason)` means the read
/// failed or the store is corrupt. A failure must NEVER render as emptiness:
/// "Quiet right now", "No tracked GitHub work…" and "The bench is clear" are
/// read as facts about the bench, not as facts about the reader.
enum DeskLaneState<Row: Sendable>: Sendable {
    case unavailable(String)
    case rows([Row])

    static var maxReasonChars: Int { 240 }

    /// Every failure notice on the Desk uses this cap. Keeping the truncation
    /// at the state boundary makes an unreadable store visible without letting
    /// an untrusted error string take over the board.
    static func boundedReason(_ reason: String) -> String {
        String(reason.prefix(maxReasonChars))
    }

    var items: [Row] {
        if case .rows(let rows) = self { return rows }
        return []
    }

    var unavailableReason: String? {
        if case .unavailable(let reason) = self { return reason }
        return nil
    }

    /// A throwing read: the error text IS the reason, bounded.
    static func failed(_ error: any Error) -> DeskLaneState {
        .unavailable(boundedReason("\(error)"))
    }

    /// Silent-zero cross-check, for readers that CANNOT throw.
    /// `SwiftNativeWorkshopRunner.listAll()` swallows an unreadable execution
    /// root and returns `[]`, so the only honest signal available to this
    /// surface is the disk cross-check. The probe is TRI-state on purpose: a
    /// bare count conflated "the root isn't there" (honest zero) with "the root
    /// wouldn't open" (the corrupt-store case this whole check exists to
    /// expose), because both produced 0.
    static func classify(rows: [Row], probe: DeskRecordProbe, noun: String) -> DeskLaneState {
        switch probe {
        case .empty:
            // No store yet — a genuinely empty lane, rows or not.
            return .rows(rows)
        case .unreadable(let detail):
            // The reader could not even enumerate the store. `rows` is [] by
            // construction in that case; saying "empty" here is the exact lie
            // this primitive exists to prevent.
            return .unavailable(
                boundedReason("Couldn't read the \(noun) store — \(detail)"))
        case .records(let recordsOnDisk):
            if rows.isEmpty && recordsOnDisk > 0 {
                return .unavailable("\(recordsOnDisk) \(noun) on disk, none could be read")
            }
            return .rows(rows)
        }
    }
}

/// The GitHub part of Desk's "Needs you" headline. A missing or unreadable
/// command feed is not evidence that no GitHub decision needs User; preserve
/// that distinction instead of folding the failed lane into a reassuring zero.
enum DeskGitHubNeedsUserCount: Equatable, Sendable {
    case measured(Int)
    case unavailable(String)

    init(githubLane: DeskLaneState<GitHubCommandItem>) {
        if let reason = githubLane.unavailableReason {
            self = .unavailable(reason)
        } else {
            self = .measured(githubLane.items.lazy.filter { $0.state == .needsUser }.count)
        }
    }

    var value: Int? {
        if case .measured(let count) = self { return count }
        return nil
    }

    var unavailableReason: String? {
        if case .unavailable(let reason) = self { return reason }
        return nil
    }
}

/// The "In progress" counter must describe the exact rows rendered on the
/// execution bench. An unreadable execution lane is unknown, not an empty
/// bench, so it deliberately has no numeric value for the counter to display.
enum DeskExecutionInProgressCount: Equatable, Sendable {
    case measured(Int)
    case unavailable(String)

    init(
        executionsLane: DeskLaneState<WorkshopExecution.WorkshopExecutionRecord>,
        deskItemsLane: DeskLaneState<DeskItem>? = nil,
        renderedBenchCount: Int,
        renderedProgramFamilyCount: Int = 0
    ) {
        if let reason = executionsLane.unavailableReason {
            self = .unavailable(reason)
        } else if let reason = deskItemsLane?.unavailableReason {
            self = .unavailable(reason)
        } else {
            self = .measured(
                max(0, renderedBenchCount) + max(0, renderedProgramFamilyCount))
        }
    }

    var value: Int? {
        if case .measured(let count) = self { return count }
        return nil
    }

    var unavailableReason: String? {
        if case .unavailable(let reason) = self { return reason }
        return nil
    }
}

/// The GitHub command store owns callback evidence; Desk owns the honest
/// wording of that evidence. A failed callback with no provider detail
/// is still a failure, not a reason to render no second line at all.
enum DeskGitHubCallbackFailurePresentation {
    struct Detail: Equatable, Sendable {
        let message: String
        let noWorkObserved: Bool?
    }

    private static let failedStatuses: Set<String> = [
        "failed", "failure", "error", "stalled", "timeout", "timed_out",
        "canceled", "cancelled", "completed_without_reply",
    ]
    private static let successfulStatuses: Set<String> = ["completed", "ok", "success"]

    static func detail(for item: GitHubCommandItem) -> Detail? {
        let status = (item.lastCallbackStatus ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let error = nonEmpty(item.lastCallbackErrorMessage)
        let noWorkObserved = item.lastCallbackNoWorkObserved

        if failedStatuses.contains(status) {
            return Detail(
                message: error ?? fallbackMessage(for: status),
                noWorkObserved: noWorkObserved
            )
        }

        // A non-success status paired with an error/resend-safety field is
        // conflicting callback evidence. Surface it rather than silently
        // treating an unknown producer spelling as a healthy completion.
        guard !successfulStatuses.contains(status), error != nil || noWorkObserved != nil else {
            return nil
        }
        let statusText = status.isEmpty ? "no usable status" : "status \(status)"
        return Detail(
            message: error ?? "Codex callback returned \(statusText) without an error detail.",
            noWorkObserved: noWorkObserved
        )
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func fallbackMessage(for status: String) -> String {
        switch status {
        case "completed_without_reply":
            return "Codex callback ended without a final result."
        case "stalled":
            return "Codex callback stalled without an error detail."
        case "timeout", "timed_out":
            return "Codex callback timed out without an error detail."
        default:
            return "Codex callback failed without an error detail."
        }
    }
}

/// What a store's record root looked like on disk, for readers that swallow
/// their own failures. Three states, because the count alone cannot tell an
/// absent store from an unopenable one — and only one of those is empty.
enum DeskRecordProbe: Sendable, Equatable {
    /// The root does not exist. Nothing has been written yet: an honest zero.
    case empty
    /// The root exists but could not be enumerated (permissions, corruption,
    /// not-a-directory). NOT zero — unknown.
    case unreadable(String)
    /// The root was enumerated: this many directories actually hold a record
    /// (or are malformed record dirs). Reservation/cancellation leftovers that
    /// legitimately carry no record are NOT counted — counting them turned a
    /// healthy empty bench into a bogus "unavailable" banner.
    case records(Int)
}

/// One rendered line in the "Waiting on you" strip.
struct DeskAttentionLine: Identifiable, Equatable, Sendable {
    enum Shape: Equatable, Sendable {
        /// A full line with its own icon — one item User has to deal with.
        case primary
        /// The GitHub-blocked roll-up header. Carries a count, not an item.
        case groupHeader
        /// An indented bullet under the roll-up.
        case groupChild
    }
    let id: String
    let icon: String
    let text: String
    let shape: Shape
    /// True when USER is the one holding this up — an approval, or a GitHub item
    /// routed to him. Everything else in this strip is blocked on someone or
    /// something else, and rendering all of it at one weight made the section
    /// title a lie: the eye has to land on the rows only he can clear.
    let needsUserDirectly: Bool
}

/// Builds and BOUNDS the "Waiting on you" strip.
///
/// The strip is fed by four op-log-sourced collections (approval-blocked
/// executions, needs-you GitHub items, Desk rows that need eyes, GitHub-blocked
/// desk items). All four grow with the op log, and the enclosing `LazyVStack`
/// only virtualizes its DIRECT children — a nested `VStack` builds every row
/// eagerly on every render regardless of viewport. So the four sources flatten
/// into ONE priority-ordered list that is capped as a whole; capping each source
/// separately would still let the strip grow with the number of sources.
///
/// Nothing is hidden silently — this is the strip that says what is blocked, and
/// a blocked item scrolled out of existence is worse than a long list. The
/// section header carries the honest total, the roll-up header carries its own
/// count even when its children are cut, and everything past the cap is reachable
/// through an explicit reveal — the same contract `finishedSection` already keeps.
enum DeskAttentionStrip {
    /// Rows rendered before the reveal takes over. Matches the finished
    /// section's cap so the two bounded surfaces feel like one rule.
    static let visibleLineCap = 8

    /// The stamped reason GitHubProjectTracking writes on every checks/review-
    /// blocked item; matched verbatim so hand-written reasons that merely
    /// mention GitHub keep their own inline text.
    static let githubStampedBlockedReason =
        "GitHub checks or review state are blocking progress."

    static func isGitHubStampedBlock(_ item: DeskItem) -> Bool {
        item.status == .blocked && item.blockedReason == githubStampedBlockedReason
    }

    // MARK: deterministic bucket order
    //
    // Each sort ends on a unique key (id / itemId / handle) so the comparator is
    // a TOTAL order — `sorted(by:)` is not stable in Swift, so "equal" elements
    // are free to swap between reloads unless the last key separates them.

    static func sortedApprovals(
        _ approvals: [WorkshopExecution.WorkshopExecutionRecord]
    ) -> [WorkshopExecution.WorkshopExecutionRecord] {
        approvals.sorted { l, r in
            if l.createdAt != r.createdAt { return l.createdAt > r.createdAt }
            if l.updatedAt != r.updatedAt { return l.updatedAt > r.updatedAt }
            return l.id < r.id
        }
    }

    static func sortedGitHubItems(_ items: [GitHubCommandItem]) -> [GitHubCommandItem] {
        items.sorted { l, r in
            if l.updatedAt != r.updatedAt { return l.updatedAt > r.updatedAt }
            if l.createdAt != r.createdAt { return l.createdAt > r.createdAt }
            return l.itemId < r.itemId
        }
    }

    static func sortedDeskItems(_ items: [DeskItem]) -> [DeskItem] {
        items.sorted { l, r in
            if l.updatedAt != r.updatedAt { return l.updatedAt > r.updatedAt }
            if l.openedAt != r.openedAt { return l.openedAt > r.openedAt }
            return l.handle < r.handle
        }
    }

    /// Priority order = who is actually being waited on. Approvals first (a
    /// paused execution is the most expensive thing to leave sitting), then the
    /// GitHub items that need User's call, then every other blocked/flagged item
    /// with its own reason, and last the GitHub-blocked roll-up — those are
    /// waiting on GitHub, not on User.
    ///
    /// Every bucket is sorted with a TOTAL order before the cap is applied.
    /// `listAll()` sorts on `createdAt` alone and the desk lanes inherit
    /// directory-enumeration order, so equal timestamps had no tie-breaker: nine
    /// approvals created in the same bucket meant a different one became the
    /// hidden ninth on each reload, with no state change behind it. The strip
    /// must be a function of the data, not of the file system's mood.
    ///
    /// `limit` bounds CONSTRUCTION, not just rendering: past the cap the lines
    /// were still being built (and re-built on every SwiftUI diff) only to be
    /// dropped. Truncating here is exactly `Array(lines().prefix(limit))` —
    /// buckets are emitted in priority order, so a prefix of the built list is
    /// a prefix of the full one.
    static func lines(
        approvals: [WorkshopExecution.WorkshopExecutionRecord],
        githubNeedsYou: [GitHubCommandItem],
        otherAttention: [DeskItem],
        githubBlocked: [DeskItem],
        limit: Int? = nil
    ) -> [DeskAttentionLine] {
        let cap = limit ?? Int.max
        guard cap > 0 else { return [] }
        var out: [DeskAttentionLine] = []
        out.reserveCapacity(
            min(cap, approvals.count + githubNeedsYou.count
                + otherAttention.count + githubBlocked.count + 1))
        for exec in sortedApprovals(approvals) {
            if out.count >= cap { return out }
            out.append(DeskAttentionLine(
                id: "approval:\(exec.id)",
                icon: "checkmark.shield",
                text: "\u{201C}\(exec.title)\u{201D} needs an approval to continue",
                shape: .primary,
                needsUserDirectly: true))
        }
        // One-pointer rule (contract): a needs-User GitHub item gets ONE pointer
        // here; the canonical card lives in GitHub Command below.
        for item in sortedGitHubItems(githubNeedsYou) {
            if out.count >= cap { return out }
            out.append(DeskAttentionLine(
                id: "gh:\(item.itemId)",
                icon: "arrow.triangle.pull",
                text: "\(item.repository) #\(item.number) needs your call — see GitHub Watcher",
                shape: .primary,
                needsUserDirectly: true))
        }
        for item in sortedDeskItems(otherAttention) {
            if out.count >= cap { return out }
            out.append(DeskAttentionLine(
                id: "item:\(item.handle)",
                icon: item.status == .blocked ? "stop.circle"
                    : item.status == .flag ? "flag" : "clock.badge.exclamationmark",
                text: item.status == .blocked
                    ? "\(item.title)\(item.blockedReason.map { " — \($0)" } ?? "")"
                    : "\(item.title)\(item.waitingOn.map { " — waiting on \($0)" } ?? "")",
                shape: .primary,
                needsUserDirectly: false))
        }
        // Taste pass 2026-07-24: GitHub-blocked items all carry the same stamped
        // blockedReason — repeated per row it turned the strip into wallpaper.
        // The header carries the count, so it stays honest even when the cap
        // cuts its children away.
        if !githubBlocked.isEmpty {
            if out.count >= cap { return out }
            out.append(DeskAttentionLine(
                id: "ghblocked:header",
                icon: "stop.circle",
                text: "Blocked on GitHub checks or review · \(githubBlocked.count) — these move when GitHub does",
                shape: .groupHeader,
                needsUserDirectly: false))
            for item in sortedDeskItems(githubBlocked) {
                if out.count >= cap { return out }
                out.append(DeskAttentionLine(
                    id: "ghblocked:\(item.handle)",
                    icon: "circle.fill",
                    text: item.title,
                    shape: .groupChild,
                    needsUserDirectly: false))
            }
        }
        return out
    }

    static func visible(_ lines: [DeskAttentionLine], showingAll: Bool) -> [DeskAttentionLine] {
        showingAll ? lines : Array(lines.prefix(visibleLineCap))
    }

    /// The honest total for the header: things User is waiting on, NOT rendered
    /// rows — the roll-up header is chrome, not an item.
    static func itemCount(_ lines: [DeskAttentionLine]) -> Int {
        lines.filter { $0.shape != .groupHeader }.count
    }

    /// How many ITEMS the cap is currently hiding (0 when everything shows).
    static func hiddenItemCount(_ lines: [DeskAttentionLine], showingAll: Bool) -> Int {
        itemCount(lines) - itemCount(visible(lines, showingAll: showingAll))
    }

    /// Of what's hidden, how much is User personally blocking. Priority order
    /// means this is normally zero — the cap eats the tail, and the tail is the
    /// stuff waiting on someone else. When it ISN'T zero (more than a capful of
    /// approvals), the reveal has to say so out loud instead of reading like a
    /// generic "and some more".
    static func hiddenNeedsUserCount(_ lines: [DeskAttentionLine], showingAll: Bool) -> Int {
        let shownIds = Set(visible(lines, showingAll: showingAll).map(\.id))
        return lines.filter { $0.needsUserDirectly && !shownIds.contains($0.id) }.count
    }

    /// The reveal's exact words. Built here, not in the view, so the honesty of
    /// the collapsed state is a tested property rather than a string literal.
    static func revealLabel(_ lines: [DeskAttentionLine], showingAll: Bool) -> String {
        revealText(
            hiddenItems: hiddenItemCount(lines, showingAll: showingAll),
            totalItems: itemCount(lines),
            hiddenNeedsUser: hiddenNeedsUserCount(lines, showingAll: showingAll),
            showingAll: showingAll)
    }

    static func revealText(
        hiddenItems: Int, totalItems: Int, hiddenNeedsUser: Int, showingAll: Bool
    ) -> String {
        if showingAll { return "Show fewer" }
        let base = "\(hiddenItems) more waiting — show all \(totalItems)"
        return hiddenNeedsUser > 0 ? "\(base) · \(hiddenNeedsUser) need your call" : base
    }

    /// What the view actually needs: the lines it will render, plus the honest
    /// totals for the header and the reveal. Only the VISIBLE lines are built —
    /// the counts are arithmetic on the bucket sizes, so a strip with 400
    /// blocked items constructs 8 strings per render, not 400.
    struct Plan: Equatable, Sendable {
        let visible: [DeskAttentionLine]
        /// Every waiting item, hidden or not. Roll-up header is chrome, excluded.
        let totalItems: Int
        let hiddenItems: Int
        let hiddenNeedsUser: Int

        var isEmpty: Bool { visible.isEmpty }
        func revealLabel(showingAll: Bool) -> String {
            DeskAttentionStrip.revealText(
                hiddenItems: hiddenItems, totalItems: totalItems,
                hiddenNeedsUser: hiddenNeedsUser, showingAll: showingAll)
        }
    }

    static func plan(
        approvals: [WorkshopExecution.WorkshopExecutionRecord],
        githubNeedsYou: [GitHubCommandItem],
        otherAttention: [DeskItem],
        githubBlocked: [DeskItem],
        showingAll: Bool
    ) -> Plan {
        let visible = lines(
            approvals: approvals,
            githubNeedsYou: githubNeedsYou,
            otherAttention: otherAttention,
            githubBlocked: githubBlocked,
            limit: showingAll ? nil : visibleLineCap)
        let totalItems = approvals.count + githubNeedsYou.count
            + otherAttention.count + githubBlocked.count
        let needsUserTotal = approvals.count + githubNeedsYou.count
        return Plan(
            visible: visible,
            totalItems: totalItems,
            hiddenItems: totalItems - itemCount(visible),
            hiddenNeedsUser: needsUserTotal - visible.filter(\.needsUserDirectly).count)
    }
}

private struct DeskViewSnapshot: Sendable {
    let deskState: DeskState?
    let deskError: String?
    let executions: DeskLaneState<WorkshopExecution.WorkshopExecutionRecord>
    let githubItems: DeskLaneState<GitHubCommandItem>
    /// ONE DeskSequencing.compute() per load — never per row. The derivation
    /// walks the whole blocked-on graph plus every parent chain, so calling it
    /// from a row builder would re-run that walk on every SwiftUI diff pass.
    /// It's pure and Sendable, so it rides along in the background snapshot.
    let plan: DeskSequencing.Plan
    /// handle → alias, built from the SAME state the plan came from. The UI
    /// shows operator aliases ("2.1") and never internal handles — same
    /// invariant DeskProjection holds.
    let aliasByHandle: [String: String]
}

/// One owner for GitHub command classification and the sections that render
/// it. Keeping the two lists together prevents a newly-persisted state from
/// being assigned to a bucket that Desk never shows.
enum DeskGitHubBucket: String, CaseIterable, Sendable {
    case actionNeeded = "Action needed"
    case legacyWork = "Finishing prior work"
    case needsUser = "Needs you"
    case waiting = "Waiting upstream"
    case attention = "Attention"
    case resolved = "Recently resolved"

    static let inlineBuckets: [Self] = [.actionNeeded, .legacyWork, .needsUser, .attention]
    static let collapsedBucket: Self = .waiting
    static let resolvedBucket: Self = .resolved
    static let resolvedDisplayLimit = 5

    /// This is intentionally derived from the actual three render branches:
    /// inline sections, the collapsed waiting section, and recent resolution.
    static let renderedBuckets: Set<Self> = Set(inlineBuckets + [collapsedBucket, resolvedBucket])

    static func bucket(for state: GitHubCommandItemState) -> Self {
        switch state {
        case .detected, .needsCodex: return .actionNeeded
        case .codexWorking, .verifying: return .legacyWork
        case .needsUser: return .needsUser
        case .waitingUpstream: return .waiting
        case .attention: return .attention
        case .resolved: return .resolved
        }
    }

    static func displayedCount(matchingCount: Int, in bucket: Self) -> Int {
        bucket == .resolved ? min(max(0, matchingCount), resolvedDisplayLimit) : max(0, matchingCount)
    }
}

/// One presentation projection for a GitHub Watcher bucket. The portfolio pill
/// and the rows beneath it consume this same slice, so a capped resolved
/// history can never claim every historical row is on screen.
struct DeskGitHubPortfolioStrip {
    struct BucketPresentation: Equatable, Sendable {
        let bucket: DeskGitHubBucket
        let matchingCount: Int
        let renderedItems: [GitHubCommandItem]

        var renderedCount: Int { renderedItems.count }
        var isCapped: Bool { renderedCount < matchingCount }

        var label: String {
            isCapped
                ? "\(bucket.rawValue) \(renderedCount) shown of \(matchingCount)"
                : "\(bucket.rawValue) \(renderedCount)"
        }
    }

    static func presentation(
        for bucket: DeskGitHubBucket,
        items: [GitHubCommandItem]
    ) -> BucketPresentation {
        let matching = items.filter { DeskGitHubBucket.bucket(for: $0.state) == bucket }
        let displayedCount = DeskGitHubBucket.displayedCount(
            matchingCount: matching.count,
            in: bucket
        )
        let renderedItems: [GitHubCommandItem]
        if bucket == .resolved {
            renderedItems = Array(matching.sorted { $0.updatedAt > $1.updatedAt }.prefix(displayedCount))
        } else {
            renderedItems = matching
        }
        return BucketPresentation(
            bucket: bucket,
            matchingCount: matching.count,
            renderedItems: renderedItems
        )
    }

    /// The top-level section count follows the same rendered/eligible slices
    /// as the rows and portfolio pills. In particular, capped resolved history
    /// contributes only its visible cap, never the hidden global total.
    static func headerCount(items: [GitHubCommandItem]) -> Int? {
        let count = DeskGitHubBucket.allCases.reduce(into: 0) { result, bucket in
            result += presentation(for: bucket, items: items).renderedCount
        }
        return count > 0 ? count : nil
    }
}

struct DeskView: View {
    @Environment(AppModel.self) private var appModel
    @Environment(\.scenePhase) private var scenePhase
    @State private var items: [DeskItem] = []
    /// The same successful/unavailable Desk read expressed through the shared
    /// lane-honesty primitive. Existing board rows remain retained on a failed
    /// refresh, while freshness-sensitive Live Activity and program families
    /// fail closed instead of presenting retained rows as current.
    @State private var deskItemsLane: DeskLaneState<DeskItem> = .rows([])
    @State private var deskGeneratedTs: String?
    /// Updated only by the existing event/deadline reloader. This gives the
    /// pure freshness projection an explicit clock without adding a SwiftUI
    /// polling timeline.
    @State private var deskPresentationNow = Date()
    // One listAll() scan, sliced client-side — the runner's listActive/
    // listHistory whitelists would make an unknown/corrupt status (e.g. a
    // future "retrying") vanish from BOTH sections. Nothing on this surface
    // may disappear: unknown statuses render on the bench with their raw pill.
    @State private var executionsLane: DeskLaneState<WorkshopExecution.WorkshopExecutionRecord> = .rows([])
    @State private var loadError: String?
    /// False until the first load() actually publishes a snapshot. Empty lanes
    /// before that point mean "nothing has reported", not "nothing exists" —
    /// the empty state is gated on this so it never renders during the initial
    /// read window (no-theater: "clear" is a claim every lane must earn).
    @State private var hasLoadedOnce = false
    @State private var expandedRoots: Set<String> = []
    @State private var showAllFinished = false
    @State private var showAllAttention = false
    /// M12: only the NEWEST load may publish. Two loads race constantly here —
    /// the toolbar refresh, the op-log reloader and the scene-phase change all
    /// call load(), and a slow one landing after a fast one would stomp fresh
    /// items with stale ones. The token is taken on the main actor before the
    /// detached read and checked on the main actor after it.
    @State private var loadGate = LatestAsyncRequestGate()
    // Derived sequencing for the CURRENT items, recomputed only in load().
    @State private var plan: DeskSequencing.Plan = DeskSequencing.Plan()
    @State private var aliasByHandle: [String: String] = [:]
    // W2b: the GitHub Watcher monitoring lane (workshop-github-command.md).
    @State private var githubLane: DeskLaneState<GitHubCommandItem> = .rows([])

    // MARK: W5 — the interaction tier (sweep R4, desk interaction)
    //
    // ADDITIVE BY CONTRACT: with `selectedHandle == nil` every byte of the
    // render below is what it was before this wave. Glance mode is untouched;
    // the action bar, the highlight and the row affordances appear only once
    // User has actually picked something. Agent maintains, User glances — and now
    // User can also act.
    @State private var selectedHandle: String?
    @State private var noteDraft: String = ""
    @State private var showingNoteField = false
    @State private var showingDeferOptions = false
    @FocusState private var noteFieldFocused: Bool
    @State private var showingPalette = false
    @State private var showingNagsPanel = false
    @State private var nagConfig = DeskNagConfig()
    @State private var actionFlight = DeskActionFlight()
    @State private var actionNotice: DeskActionNotice?
    @FocusState private var benchFocused: Bool
    /// Triage-counter navigation (desk-triage-makeover W1): a tapped counter
    /// names its section anchor here; the ScrollViewReader in `body` performs
    /// the scroll — same one-rule pattern as `selectedHandle`.
    @State private var scrollTarget: String?

    /// The mutation seam. Same dispatcher, same `impl_desk_*` functions, same
    /// ledger as the chat tools — see DeskQuickActions.swift.
    private var actionRouter: DeskToolDispatchRouter { DeskToolDispatchRouter(dataRoot: dataRoot) }

    /// Every handle that can take the selection, in render order.
    private var selectionOrder: [String] {
        DeskBoardLayout.selectableHandles(items: items, expandedRoots: expandedRoots)
    }

    private var selectedItem: DeskItem? {
        guard let selectedHandle else { return nil }
        return items.first { $0.handle == selectedHandle }
    }

    /// The palette's pool is every live Desk item plus waiting GitHub watcher
    /// row, not `selectionOrder` — search exists precisely to reach rows that
    /// are collapsed out of sight, and `select(_:)` opens their family before
    /// scrolling. Scoping it to what is already on screen would make ⌘K useless
    /// for exactly the items it is most needed for.
    private var paletteRows: [DeskPaletteRow] {
        activeItems.map(DeskPaletteRow.init(item:))
            + DeskGitHubWaitingRollup.paletteRows(in: githubItems)
    }

    // Lane unwrapping happens in ONE place: every slice below reads rows, and
    // the sections read the reason. A lane that failed contributes zero rows AND
    // renders its own unavailable notice — it never contributes silent emptiness.
    private var allExecutions: [WorkshopExecution.WorkshopExecutionRecord] { executionsLane.items }
    private var githubItems: [GitHubCommandItem] { githubLane.items }
    private var githubNeedsUserCount: DeskGitHubNeedsUserCount {
        DeskGitHubNeedsUserCount(githubLane: githubLane)
    }
    private var laneUnavailable: Bool {
        deskItemsLane.unavailableReason != nil
            || executionsLane.unavailableReason != nil
            || githubLane.unavailableReason != nil
    }

    private var dataRoot: URL { PersistenceCore.defaultDataRoot() }

    private var store: SwiftNativeDeskStore {
        SwiftNativeDeskStore(dataRoot: dataRoot)
    }

    // MARK: section slices

    // W5: the partition itself moved to `DeskBoardLayout` (DeskInteraction.swift)
    // so the selection order is derived from the SAME definition this surface
    // renders from. A second copy would let arrow-down land on a row that isn't
    // on screen — which is exactly how a keyboard surface starts feeling broken.
    private var activeItems: [DeskItem] { DeskBoardLayout.activeItems(items) }
    private var doneItems: [DeskItem] { items.filter { $0.status.isTerminal } }

    private var pursuitRows: [DeskPursuitSectionPresentation.Row] {
        DeskPursuitSectionPresentation.rows(from: activeItems)
    }

    private var watchItems: [DeskItem] { DeskBoardLayout.watches(activeItems) }
    private var boardItems: [DeskItem] { DeskBoardLayout.board(activeItems) }
    private var boardNonGhItems: [DeskItem] { DeskBoardLayout.boardNonGh(boardItems) }
    private var ghByProject: [(project: String, items: [DeskItem])] {
        DeskBoardLayout.ghByProject(boardItems)
    }

    // The collapsed GitHub project roll-up and this strip deliberately share
    // `needsEyes`: a row with an explicit waiting owner must not inflate the
    // roll-up while vanishing from the attention section on the same screen.
    // Pursuits are included as well, rather than being hidden by board-only
    // filtering.
    private var attentionItems: [DeskItem] {
        activeItems.filter(DeskItemPresentation.needsEyes)
    }

    private var githubBlockedAttentionItems: [DeskItem] {
        attentionItems.filter(DeskAttentionStrip.isGitHubStampedBlock)
    }

    private var nonGitHubAttentionItems: [DeskItem] {
        attentionItems.filter { !DeskAttentionStrip.isGitHubStampedBlock($0) }
    }

    /// The strip, flattened + priority-ordered + BOUNDED in one pass. Only the
    /// lines that will actually render are built; the header/reveal counts come
    /// back as arithmetic, so hidden rows cost nothing per SwiftUI diff.
    private var attentionPlan: DeskAttentionStrip.Plan {
        DeskAttentionStrip.plan(
            approvals: approvalExecutions,
            githubNeedsYou: needsUserGitHubItems,
            otherAttention: nonGitHubAttentionItems,
            githubBlocked: githubBlockedAttentionItems,
            showingAll: showAllAttention)
    }

    private var executionSlice: DeskExecutionPresentation.Slice {
        DeskExecutionPresentation.slice(allExecutions)
    }

    private var benchExecutions: [WorkshopExecution.WorkshopExecutionRecord] {
        let ids = Set(executionSlice.benchIDs)
        return allExecutions.filter { ids.contains($0.id) }
    }

    /// Keep the headline tied to the exact collection the bench section
    /// renders; it cannot silently use a separate status/count calculation.
    private var inProgressExecutionCount: DeskExecutionInProgressCount {
        DeskExecutionInProgressCount(
            executionsLane: executionsLane,
            deskItemsLane: deskItemsLane,
            renderedBenchCount: benchExecutions.count,
            renderedProgramFamilyCount: programFamilies.count)
    }

    private var liveActivity: DeskLiveActivityPresentation.State {
        DeskLiveActivityPresentation.make(
            deskItems: deskItemsLane,
            generatedTs: deskGeneratedTs,
            now: deskPresentationNow)
    }

    private var programFamilies: [DeskProgramFamilyPresentation.Family] {
        DeskProgramFamilyPresentation.families(from: deskItemsLane)
    }

    private var approvalExecutions: [WorkshopExecution.WorkshopExecutionRecord] {
        let ids = Set(executionSlice.approvalIDs)
        return allExecutions.filter { ids.contains($0.id) }
    }
    private var recentDoneExecutions: [WorkshopExecution.WorkshopExecutionRecord] {
        let byID = allExecutions.reduce(into: [String: WorkshopExecution.WorkshopExecutionRecord]()) {
            $0[$1.id] = $1
        }
        return executionSlice.recentDoneIDs.compactMap { byID[$0] }
    }

    var body: some View {
        ScrollViewReader { proxy in
            benchScroll
                // Selection drives the scroll for EVERY path that sets it —
                // arrows, a palette match, a blocker pill. One rule, so
                // "select it" and "show it to me" can never diverge.
                .onChange(of: selectedHandle) { _, new in
                    guard let new else { return }
                    withAnimation(.easeInOut(duration: 0.18)) {
                        proxy.scrollTo(new, anchor: .center)
                    }
                }
                .onChange(of: scrollTarget) { _, new in
                    guard let new else { return }
                    withAnimation(.easeInOut(duration: 0.22)) {
                        proxy.scrollTo(new, anchor: .top)
                    }
                    scrollTarget = nil
                }
        }
        .navigationTitle("Desk")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { showingPalette = true } label: { Image(systemName: "command") }
                    .help("Find or act on a desk item (\u{2318}K)")
                    .accessibilityLabel("Find or act on a Desk item")
                    .accessibilityHint("Opens Desk commands and search")
                    .keyboardShortcut("k", modifiers: .command)
            }
            ToolbarItem(placement: .primaryAction) {
                Button { Task { await refreshFromToolbar() } } label: { Image(systemName: "arrow.clockwise") }
                    .help("Refresh the desk")
                    .accessibilityLabel("Refresh Desk")
            }
        }
        .sheet(isPresented: $showingPalette) {
            DeskCommandPaletteView(
                rows: paletteRows,
                selectedHandle: selectedHandle,
                onSelect: { select($0) },
                onCommand: { verb, handle in applyPaletteCommand(verb, handle: handle) },
                isPresented: $showingPalette)
        }
        .task {
            let reloader = DeskLiveReloader.shared
            reloader.setSceneActive(scenePhase == .active)
            if let setupError = reloader.activate(
                paths: [store.opsPath, GitHubCommandStore(dataRoot: dataRoot).opsPath]
            ) { await load() }
            {
                loadError = setupError
                hasLoadedOnce = true
            }
        }
        .onDisappear { DeskLiveReloader.shared.deactivate() }
        .onChange(of: scenePhase) { _, phase in
            DeskLiveReloader.shared.setSceneActive(phase == .active)
        }
    }

    private var benchScroll: some View {
        ScrollView {
            // Lazy: the board's history sections can hold hundreds of rows;
            // only what scrolls into view is built (NEEDS_FIX 4).
            LazyVStack(alignment: .leading, spacing: 18) {
                headerRow

                if let loadError {
                    Label(DeskItemPresentation.boundedLoadFailure(loadError), systemImage: "exclamationmark.triangle")
                        .font(.callout)
                        .foregroundStyle(.orange)
                        .lineLimit(3)
                        .padding(10)
                        .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
                }

                // "The bench is clear" is a claim about the bench. It may only
                // render when every lane actually reported — a failed read is
                // not a clear bench (NORTHSTAR clause 2, no theater). Before the
                // first load() round-trips, nothing has reported yet, so the
                // same clause forbids the claim there too: an 82-item board
                // must not open on "The desk is clear" for two seconds.
                switch DeskHonestyPresentation.boardBody(
                    itemCount: items.count,
                    executionCount: allExecutions.count,
                    githubItemCount: githubItems.count,
                    loadError: loadError,
                    hasLoadedOnce: hasLoadedOnce,
                    hasUnavailableLane: laneUnavailable
                ) {
                case .loading:
                    loadingState
                case .clear:
                    emptyState
                case .populated:
                    liveActivitySection
                    countersStrip
                    attentionSection
                    githubCommandSection
                    benchSection
                    pursuitsSection
                    watchesSection
                    boardSection
                    finishedSection
                }
                // B2.6 (g): debug disclosures (agent projection + raw all-items
                // table) moved to Diagnostics ▸ Cognition (DeskDebugPanels).
                // This surface keeps zero debug chrome.
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        // Keyboard-first mutation — the whole point of this wave. EVERY binding
        // here also has a mouse affordance (the selection bar's buttons, the
        // row taps, the ⌘K toolbar button), so nothing is keyboard-only.
        //
        // The letter keys are guarded on `noteFieldFocused`: with the note field
        // open, "c" is a character User is typing, not a close.
        //
        // The bench takes key focus on appear. Without it the arrows do nothing
        // until User happens to tab into the scroll view, and a keyboard surface
        // that needs a Tab first reads as a keyboard surface that is broken.
        .focusable()
        .focusEffectDisabled()
        .focused($benchFocused)
        .onAppear { benchFocused = true }
        // Pinned action bar: the selected row can be a thousand points down the
        // board, so its affordances live in a bottom inset that is always on
        // screen — not inline at the top where `n` would open a note field User
        // can't see. Renders NOTHING when there is no selection and no notice,
        // so glance mode keeps its exact former geometry.
        .safeAreaInset(edge: .bottom, spacing: 0) { selectionInspector }
        .onKeyPress(.upArrow) { moveSelection(-1) }
        .onKeyPress(.downArrow) { moveSelection(1) }
        .onKeyPress(.escape) {
            guard showingNoteField || showingDeferOptions || selectedHandle != nil
                    || actionNotice != nil else { return .ignored }
            clearInteraction()
            return .handled
        }
        .onKeyPress(keys: [KeyEquivalent("k")], phases: .down) { press in
            // Click-through 2026-08-06: with the bench .focusable holding key
            // focus, the toolbar button's .keyboardShortcut("k", .command)
            // never fired — the focused view swallows the key equivalent. The
            // palette must open from the keyboard (that IS the feature), so
            // handle it here too; the toolbar shortcut stays for when focus
            // is elsewhere.
            guard press.modifiers.contains(.command) else { return .ignored }
            showingPalette = true
            return .handled
        }
        .onKeyPress("c") { quickKey { closeSelected() } }
        .onKeyPress("d") { quickKey { beginDefer() } }
        .onKeyPress("n") { quickKey { beginNote() } }
        .onChange(of: items) { _, _ in
            // A row that closed, collapsed away or was archived must not keep
            // the caret: `c` would then fire on something User can't see.
            selectedHandle = DeskSelection.reconcile(selectedHandle, order: selectionOrder)
        }
        .onChange(of: githubItems) { _, latest in
            // A watcher row can advance while its palette result is open or
            // selected. Once it is no longer waiting, its scroll anchor no
            // longer renders, so drop that reveal-only selection promptly.
            guard let selectedHandle,
                  DeskGitHubWaitingRollup.isPaletteHandle(selectedHandle),
                  DeskGitHubWaitingRollup.revealKeys(
                    forPaletteHandle: selectedHandle, in: latest
                  ).isEmpty
            else { return }
            self.selectedHandle = nil
        }
        // NOTE: the live-reloader activation stays on `body` (with its paired
        // onDisappear/scenePhase handlers). Attaching a second `.task` here
        // would activate the reloader TWICE per appearance — one watcher per
        // view layer, both calling load().
        .task { await refreshNagConfig() }
    }

    // MARK: W5 — keyboard plumbing

    /// A letter shortcut fires only when a row is selected AND the note field
    /// isn't eating keystrokes. Guards on `showingNoteField` (set
    /// SYNCHRONOUSLY by beginNote) as well as the focus binding — focus lands
    /// ~20ms later, and a fast `n`-then-`c` in that window would have closed
    /// the item User was about to annotate (review blocking #3).
    private func quickKey(_ body: () -> Void) -> KeyPress.Result {
        guard selectedHandle != nil, !noteFieldFocused, !showingNoteField,
              !showingDeferOptions else { return .ignored }
        body()
        return .handled
    }

    private func moveSelection(_ delta: Int) -> KeyPress.Result {
        let order = selectionOrder
        guard !order.isEmpty else { return .ignored }
        guard !noteFieldFocused else { return .ignored }
        let next = DeskSelection.move(from: selectedHandle, by: delta, in: order)
        guard next != selectedHandle else { return .handled }
        // Both affordances close on a move: a defer menu or note field left
        // open would now be pointing at a row User just walked away from.
        showingNoteField = false
        showingDeferOptions = false
        noteDraft = ""
        selectedHandle = next
        return .handled
    }

    /// Esc: drop the open affordance first, then the selection. Two escapes to
    /// leave glance mode from a half-typed note, one from a bare selection.
    private func clearInteraction() {
        if showingNoteField || showingDeferOptions {
            showingNoteField = false
            showingDeferOptions = false
            noteDraft = ""
            return
        }
        selectedHandle = nil
        actionNotice = nil
    }

    // MARK: W5 — selection

    /// The ONE way the caret moves. Opens whatever families the row is buried
    /// in first, so `scrollTo` has something to scroll to — a selection that
    /// can't be seen is worse than no selection.
    private func select(_ handle: String) {
        // GitHub waiting rows are watch-only palette targets. They share the
        // actual expansion vocabulary with this rollup, but deliberately do
        // not become a selected DeskItem or gain close/defer/note actions.
        let githubRevealKeys = DeskGitHubWaitingRollup.revealKeys(
            forPaletteHandle: handle, in: githubItems)
        if !githubRevealKeys.isEmpty {
            withAnimation(.easeInOut(duration: 0.15)) {
                for key in githubRevealKeys { expandedRoots.insert(key) }
            }
            showingNoteField = false
            showingDeferOptions = false
            noteDraft = ""
            // The GitHub row carries the matching scroll anchor. It has no
            // DeskItem backing it, so the mutation inspector remains absent.
            selectedHandle = handle
            return
        }
        // Terminal rows are NOT selectable — close/defer/note on something
        // already closed is meaningless, and `finishedSection` shares
        // `groupView` with the board. Glance mode for history stays glance-only.
        guard DeskBoardLayout.activeItems(items).contains(where: { $0.handle == handle })
        else { return }
        let keys = DeskBoardLayout.revealKeys(for: handle, items: items)
        if !keys.isEmpty {
            withAnimation(.easeInOut(duration: 0.15)) {
                for key in keys { expandedRoots.insert(key) }
            }
        }
        showingNoteField = false
        showingDeferOptions = false
        selectedHandle = handle
    }

    /// Row tap: pick it, or drop the selection when it's already the one.
    private func toggleSelection(_ handle: String) {
        if selectedHandle == handle {
            selectedHandle = nil
            showingNoteField = false
            showingDeferOptions = false
        } else {
            select(handle)
        }
    }

    // MARK: W5 — the pinned selection inspector (mouse parity for every shortcut)

    /// The bottom inset. Empty — genuinely zero-height, no divider, no material
    /// — whenever there is nothing selected and nothing to report, which is the
    /// whole of glance mode.
    @ViewBuilder
    private var selectionInspector: some View {
        if selectedItem != nil || actionNotice != nil {
            VStack(alignment: .leading, spacing: 8) {
                Divider()
                actionNoticeRow
                selectionBar
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 12)
            .background(.regularMaterial)
        }
    }

    @ViewBuilder
    private var selectionBar: some View {
        if let item = selectedItem {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    statusPill(item.status)
                    Text(item.title).font(.callout.weight(.semibold)).lineLimit(1)
                    Text(item.alias)
                        .font(.caption2.monospaced()).foregroundStyle(.tertiary)
                    Spacer(minLength: 8)
                    if actionFlight.isInFlight {
                        ProgressView().controlSize(.small)
                    }
                    Button { closeSelected() } label: { Label("Close", systemImage: "checkmark.circle") }
                        .help("Close this item (c)")
                    Button { beginDefer() } label: { Label("Defer", systemImage: "pause.circle") }
                        .help("Park this item (d)")
                    Button { beginNote() } label: { Label("Note", systemImage: "text.bubble") }
                        .help("Add a note (n)")
                    Button { clearInteraction() } label: { Image(systemName: "xmark") }
                        .help("Clear the selection (esc)")
                        .accessibilityLabel("Clear Desk selection")
                }
                .disabled(actionFlight.isInFlight)
                if showingDeferOptions { deferOptionsRow(item) }
                if showingNoteField { noteFieldRow(item) }
                // Refs are an affordance, not glance chrome: they appear on the
                // SELECTED row only. A ref that carries a URL opens; a bare ref
                // (file path, sha, trace id) copies — clicking and getting
                // nothing is the worst of the three outcomes.
                if !item.refs.isEmpty { refsRow(item) }
            }
            .padding(12)
            .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(Color.accentColor.opacity(0.28), lineWidth: 1))
        }
    }

    private func deferOptionsRow(_ item: DeskItem) -> some View {
        HStack(spacing: 8) {
            Text("Park until").font(.caption).foregroundStyle(.secondary)
            ForEach(DeskDeferPreset.allCases) { preset in
                Button(preset.label) {
                    perform(.defer_(handle: item.handle, until: preset.day(from: Date())))
                }
                .controlSize(.small)
            }
            if item.deferUntil?.isEmpty == false {
                Button("Un-park") { perform(.defer_(handle: item.handle, until: nil)) }
                    .controlSize(.small)
            }
            Spacer(minLength: 0)
        }
    }

    private func noteFieldRow(_ item: DeskItem) -> some View {
        HStack(spacing: 8) {
            TextField("Note…", text: $noteDraft)
                .textFieldStyle(.roundedBorder)
                .focused($noteFieldFocused)
                .onSubmit { submitNote(item) }
            Button("Add") { submitNote(item) }
                .disabled(noteDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .keyboardShortcut(.defaultAction)
        }
    }

    private func refsRow(_ item: DeskItem) -> some View {
        HStack(spacing: 6) {
            ForEach(item.refs.sorted { $0.priority < $1.priority }, id: \.refId) { ref in
                let action = DeskRefAffordance.action(for: ref)
                Button {
                    switch action {
                    case .open(let url, _):
                        if let parsed = URL(string: url) { NSWorkspace.shared.open(parsed) }
                    case .copy(let text, _):
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(text, forType: .string)
                        actionNotice = DeskActionNotice(text: "Copied \(text)", isError: false)
                    }
                } label: {
                    Label(
                        action.label,
                        systemImage: action.opensExternally ? "arrow.up.right.square" : "doc.on.doc")
                        .font(.caption2)
                        .lineLimit(1)
                }
                .buttonStyle(.naFeel)
                .foregroundStyle(action.opensExternally ? Color.accentColor : Color.secondary)
                .help(action.opensExternally ? "Open" : "Copy")
            }
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private var actionNoticeRow: some View {
        if let notice = actionNotice {
            let presentation = DeskActionPresentation.notice(isError: notice.isError)
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: presentation.symbol)
                    .font(.caption)
                    .foregroundStyle(presentation.tone == .warning ? Color.orange : Color.green)
                // The TOOL's own words — a confirmation or an honest refusal.
                // The desk never invents a success line the ledger can't back.
                Text(notice.text).font(.caption).lineLimit(3)
                Spacer(minLength: 0)
                Button { actionNotice = nil } label: { Image(systemName: "xmark") }
                    .buttonStyle(.naFeel).foregroundStyle(.tertiary)
                    .accessibilityLabel(notice.isError ? "Dismiss Desk error" : "Dismiss Desk confirmation")
            }
            .padding(10)
            .background(
                (notice.isError ? Color.orange : Color.green).opacity(0.10),
                in: RoundedRectangle(cornerRadius: 8))
        }
    }

    // MARK: W5 — actions

    private func closeSelected() {
        guard let item = selectedItem else { return }
        perform(.close(handle: item.handle, outcome: DeskQuickAction.deskCloseOutcome))
    }

    private func beginDefer() {
        guard selectedHandle != nil else { return }
        showingNoteField = false
        showingDeferOptions.toggle()
    }

    private func beginNote() {
        guard selectedHandle != nil else { return }
        showingDeferOptions = false
        showingNoteField = true
        noteDraft = ""
        // The TextField does not exist yet in THIS render pass, so focusing it
        // synchronously is a no-op and User's next keystroke goes to the bench
        // (where "c" would close the item he was about to annotate). Same
        // one-tick deferral CommandPaletteView.swift already uses for its own
        // re-focus after a clear.
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 20_000_000)
            if showingNoteField { noteFieldFocused = true }
        }
    }

    private func submitNote(_ item: DeskItem) {
        let text = noteDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        perform(.note(handle: item.handle, text: text))
    }

    private func applyPaletteCommand(_ verb: DeskPaletteQuery.Verb, handle: String) {
        guard !actionFlight.isInFlight else {
            actionNotice = DeskActionNotice(
                text: DeskPaletteCommandApplication.actionInFlightMessage,
                isError: true
            )
            return
        }
        switch DeskPaletteCommandApplication.resolve(
            verb: verb,
            handle: handle,
            activeItems: activeItems
        ) {
        case let .dispatch(action):
            select(handle.trimmingCharacters(in: .whitespacesAndNewlines))
            perform(action)
        case let .beginDefer(resolvedHandle):
            select(resolvedHandle)
            showingDeferOptions = true
        case let .beginNote(resolvedHandle):
            select(resolvedHandle)
            beginNote()
        case let .refused(message):
            actionNotice = DeskActionNotice(text: message, isError: true)
        }
    }

    /// Optimistic-then-refresh, the same shape the chat surface uses for a
    /// dispatch (`ChatView+SlashCommands.runDispatchAndRenderReceipt`: show the
    /// pending state immediately, replace it with the real receipt).
    ///
    /// Here the optimistic step edits the LOCAL row so the board reacts on the
    /// same frame as the click, and `load()` afterwards replaces it wholesale
    /// with what the store actually says — including on failure, so a refused
    /// write cannot leave a lie on screen.
    private func perform(_ action: DeskQuickAction) {
        guard !actionFlight.isInFlight else { return }
        actionNotice = nil
        showingNoteField = false
        showingDeferOptions = false
        noteDraft = ""
        // Snapshot BEFORE the local echo: a failed tool result — or a load()
        // that cannot re-read the store — must restore the pre-action truth,
        // or the desk shows an optimistic lie (a row rendered closed that the
        // ledger never closed; review blocking #2).
        let preActionItems = items
        applyOptimistically(action)
        let router = actionRouter
        Task { @MainActor in
            guard let outcome = await actionFlight.perform(action, via: router) else { return }
            actionNotice = DeskActionNotice(text: outcome.message, isError: !outcome.ok)
            let itemsBeforeLoad = items
            await load()
            let reloadedItems = items
            items = DeskOptimisticItemPatch.reconciled(
                preAction: preActionItems,
                optimistic: itemsBeforeLoad,
                reloaded: reloadedItems,
                loadFailed: loadError != nil,
                outcome: outcome,
                action: action)
            await refreshNagConfig()
            selectedHandle = DeskSelection.reconcile(selectedHandle, order: selectionOrder)
            // The note field held key focus; hand it back to the bench or the
            // arrows go dead after the first note User types.
            benchFocused = true
        }
    }

    /// Local echo only. Deliberately narrow: status/park/note are the three
    /// fields whose change User would notice within the frame. Everything
    /// derived (the sequencing plan, the rollups, the attention strip) is left
    /// to `load()` — guessing at a derived value is how an optimistic update
    /// starts disagreeing with the store.
    private func applyOptimistically(_ action: DeskQuickAction) {
        items = DeskOptimisticItemPatch.applying(action, to: items)
    }

    private func refreshNagConfig() async {
        nagConfig = await DeskNagConfigStore(dataRoot: dataRoot).load()
    }

    // MARK: header

    private var headerRow: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text("\(appModel.agentDisplayName)'s Desk").font(.title2.weight(.semibold))
                Text("Projects, commitments, bridge work, and the agent's own pursuits — lined up in one place")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
            Spacer()
            nagsButton
        }
    }

    // MARK: triage counters (desk-triage-makeover W1)
    //
    // The health check: four numbers that answer "what needs me, what's she
    // doing, what am I watching, what's rotting" without reading a single row.
    // Tinted only when nonzero so a calm desk reads calm; each card scrolls to
    // its section. Counts come from the SAME slices the sections render from —
    // a counter may never disagree with the list below it.

    private var needsYouCount: Int? {
        guard let githubCount = githubNeedsUserCount.value else { return nil }
        return approvalExecutions.count + attentionItems.count + githubCount
    }

    private static let staleThresholdDays = DeskItemPresentation.staleThresholdDays

    /// Days since the item was last touched (DeskItem carries one updatedAt;
    /// the motor timestamp is a GitHubCommandItem field, not this type's).
    private func ageDays(_ item: DeskItem) -> Int? {
        guard let date = Self.parseISO(item.updatedAt) else { return nil }
        return Int(deskPresentationNow.timeIntervalSince(date) / 86_400)
    }

    /// Rot = WATCH items untouched past the threshold, minus blocked/flagged
    /// (those already count against "Needs you"). Scoped to the same section
    /// the counter scrolls to (gpt-5.5 HIGH: counting board items the tap
    /// can't reach let the counter disagree with its target — and could aim
    /// at an anchor that never rendered). Non-watch rows still surface their
    /// own rot via the amber chip in `freshnessText`.
    private var staleWatchItems: [DeskItem] {
        watchItems.filter {
            $0.status != .blocked && $0.status != .flag
                && (ageDays($0) ?? 0) >= Self.staleThresholdDays
        }
    }

    // MARK: Live Activity — present only while real Desk ops are recent

    @ViewBuilder
    private var liveActivitySection: some View {
        switch liveActivity {
        case .quiet:
            // Quiet is intentionally zero-height: no idle badge, empty card,
            // or "nothing happening" theater at the top of the Desk.
            EmptyView()
        case .unavailable(let notice):
            sectionHeader("Live Activity", systemImage: "waveform.path.ecg")
            laneUnavailableNotice(title: notice.title, detail: notice.detail)
        case .rows(let content):
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: "waveform.path.ecg")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.blue)
                    Text(DeskSectionHeaderPresentation.label(
                        "Live Activity", count: content.eligibleRowCount))
                        .font(.headline)
                    Spacer(minLength: 8)
                    if content.isStale {
                        Label(content.asOfText, systemImage: "clock.badge.exclamationmark")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.orange)
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Color.orange.opacity(0.12), in: Capsule())
                    } else {
                        Text(content.asOfText)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }

                ForEach(content.rows) { row in
                    liveActivityRow(row)
                }

                if content.overflowCount > 0 {
                    Text("+\(content.overflowCount) more")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .padding(.leading, 30)
                }
            }
            .padding(12)
            .background(Color.blue.opacity(0.07), in: RoundedRectangle(cornerRadius: 10))
            .accessibilityElement(children: .contain)
        }
    }

    private func liveActivityRow(_ row: DeskLiveActivityPresentation.Row) -> some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: row.assigneeSymbol)
                .font(.callout.weight(.semibold))
                .foregroundStyle(.blue)
                .frame(width: 20, height: 20)
                .help(row.assignee)
                .accessibilityLabel("Assigned to \(row.assignee)")
            VStack(alignment: .leading, spacing: 5) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(row.summary)
                        .font(.callout.weight(.medium))
                        .lineLimit(2)
                    Spacer(minLength: 8)
                    Text(row.lastUpdateText)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                if let progress = row.progress {
                    HStack(spacing: 8) {
                        ProgressView(value: Double(progress.done), total: Double(progress.total))
                            .progressViewStyle(.linear)
                        Text("\(progress.done)/\(progress.total)")
                            .font(.caption2.monospacedDigit().weight(.semibold))
                            .foregroundStyle(.secondary)
                        if let note = progress.note {
                            Text(note)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(1).truncationMode(.tail)
                        }
                    }
                }
            }
        }
    }

    private var countersStrip: some View {
        HStack(spacing: 10) {
            triageCounter("Needs you", count: needsYouCount, tint: .red,
                          symbol: "hand.raised", target: "sec-attention",
                          unavailableReason: githubNeedsUserCount.unavailableReason)
            triageCounter("In progress", count: inProgressExecutionCount.value, tint: .blue,
                          symbol: "hammer", target: "sec-bench",
                          unavailableReason: inProgressExecutionCount.unavailableReason)
            triageCounter("Watching", count: watchItems.count, tint: nil,
                          symbol: "binoculars", target: "sec-watch")
            triageCounter("Stale \(Self.staleThresholdDays)d+", count: staleWatchItems.count,
                          tint: .orange, symbol: "hourglass", target: "sec-watch")
        }
    }

    @ViewBuilder
    private func triageCounter(_ label: String, count: Int?, tint: Color?,
                               symbol: String, target: String,
                               unavailableReason: String? = nil) -> some View {
        let active = (count ?? 0) > 0
        let accent = active ? (tint ?? .primary) : Color.secondary
        let accessibilityText = count.map { "\(label): \($0)" }
            ?? unavailableReason.map { "\(label) count unavailable: \($0)" }
            ?? "\(label): count unavailable"
        let counter = VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 5) {
                Image(systemName: symbol).font(.caption2)
                Text(label).font(.caption)
            }
            .foregroundStyle(active && tint != nil ? AnyShapeStyle(accent) : AnyShapeStyle(.secondary))
            Text(count.map(String.init) ?? "—")
                .font(.title3.weight(.semibold))
                .foregroundStyle(active ? AnyShapeStyle(.primary) : AnyShapeStyle(.tertiary))
                .contentTransition(.numericText())
                .accessibilityLabel(unavailableReason.map {
                    "\(label) count unavailable: \($0)"
                } ?? "\(label) \(count ?? 0)")
        }
        .padding(.vertical, 8).padding(.horizontal, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            active && tint != nil ? accent.opacity(0.10) : Color.primary.opacity(0.04),
            in: RoundedRectangle(cornerRadius: 8))
        .contentShape(Rectangle())
        .naInteractive(radius: 8)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityText)

        if active {
            Button {
                scrollTarget = target
            } label: {
                counter
            }
            .buttonStyle(.plain)
            .accessibilityLabel(accessibilityText)
            .accessibilityHint("Moves to the matching Desk items")
        } else {
            counter
        }
    }

    /// C6: User's nag switch, in the UI. It shipped controllable ONLY through the
    /// `desk_nag_control` chat tool — he had to ask Agent to turn his own
    /// pressure on. The icon states the answer without a click: a slashed bell
    /// while muted, a filled one while armed.
    private var nagsButton: some View {
        Button { showingNagsPanel = true } label: {
            Image(systemName: nagBellSymbol)
                .foregroundStyle(nagConfig.isMuted(now: Date())
                                 ? AnyShapeStyle(Color.orange)
                                 : AnyShapeStyle(nagConfig.enabled ? Color.accentColor : Color.secondary))
        }
        .buttonStyle(.naFeel)
        .help("Nagging — what pings you, and when")
        .accessibilityLabel("Nag settings")
        .accessibilityValue(nagAccessibilityValue)
        .accessibilityHint("Shows what can ping you and when")
        .popover(isPresented: $showingNagsPanel, arrowEdge: .bottom) {
            DeskNagsPanel(
                items: items,
                selectedHandle: selectedHandle,
                selectedTitle: selectedItem?.title,
                perform: { perform($0) },
                config: nagConfig,
                isBusy: actionFlight.isInFlight)
        }
    }

    private var nagBellSymbol: String {
        DeskItemPresentation.nagBellSymbol(config: nagConfig, now: Date())
    }

    private var nagAccessibilityValue: String {
        if nagConfig.isMuted(now: Date()) { return "Muted" }
        return nagConfig.enabled ? "On" : "Off"
    }

    private func sectionHeader(_ title: String, count: Int? = nil, systemImage: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: systemImage)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(DeskSectionHeaderPresentation.label(title, count: count))
                .font(.headline).foregroundStyle(.secondary)
        }
        .padding(.top, 4)
    }

    /// The one shape a failed lane renders as. Deliberately NOT styled like the
    /// quiet-lane placeholder: a broken reader has to look different from a
    /// quiet bench at a glance, or the whole distinction is decorative.
    private func laneUnavailableNotice(title: String, detail: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "questionmark.circle")
                .font(.callout).foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.callout.weight(.semibold)).foregroundStyle(.orange)
                Text(detail)
                    .font(.caption).foregroundStyle(.secondary)
                    .lineLimit(3).truncationMode(.tail)
                Text("This is a read failure, not an empty lane — the work may still be there.")
                    .font(.caption2).foregroundStyle(.tertiary)
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .background(Color.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: 8))
    }

    // MARK: empty state

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "checklist").font(.system(size: 34)).foregroundStyle(.tertiary)
            Text("The desk is clear").font(.headline)
            Text("Tell \(appModel.agentDisplayName) \u{201C}keep track of\u{2026}\u{201D} or give the agent a task and it lands here. Self-pursuits appear once something earns repeated attention.")
                .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity).padding(.vertical, 44)
    }

    /// Shown only in the window between first appearance and the first
    /// completed load(). Deliberately quiet — on a populated board this is
    /// visible for a beat or two, and a splashy spinner would flash on every
    /// launch.
    private var loadingState: some View {
        VStack(spacing: 10) {
            ProgressView().controlSize(.small)
            Text("Reading the desk\u{2026}")
                .font(.callout).foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity).padding(.vertical, 44)
    }

    // MARK: section 1 — waiting on you (only when something actually is)
    //
    // A compact attention strip, not duplicate rows: every row that needs eyes
    // keeps its full row (and family context) on the board below — this strip
    // only points at it, plus any execution parked on an approval.

    @ViewBuilder
    private var attentionSection: some View {
        let strip = attentionPlan
        if !strip.isEmpty {
            // The count is on the header, always — so the strip states how much
            // is waiting even in the frame where most of it is collapsed.
            sectionHeader("Waiting on you", count: strip.totalItems, systemImage: "hand.raised")
                .id("sec-attention")
            VStack(alignment: .leading, spacing: 6) {
                ForEach(strip.visible) { line in
                    attentionRow(line)
                }
                if strip.hiddenItems > 0 || showAllAttention {
                    Button {
                        withAnimation(.easeInOut(duration: 0.15)) { showAllAttention.toggle() }
                    } label: {
                        Text(strip.revealLabel(showingAll: showAllAttention))
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.orange)
                    }
                    .buttonStyle(.naFeel)
                    .padding(.top, 2)
                }
            }
            .padding(12)
            .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
        }
    }

    @ViewBuilder
    private func attentionRow(_ line: DeskAttentionLine) -> some View {
        switch line.shape {
        case .primary:
            attentionLine(icon: line.icon, text: line.text, emphasized: line.needsUserDirectly)
        case .groupHeader:
            attentionLine(icon: line.icon, text: line.text)
                .padding(.top, 2)
        case .groupChild:
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: line.icon)
                    .font(.system(size: 5)).foregroundStyle(.secondary)
                Text(line.text).font(.callout).lineLimit(2)
                Spacer(minLength: 0)
            }
            .padding(.leading, 20)
        }
    }

    private func attentionLine(icon: String, text: String, emphasized: Bool = false) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: icon)
                .font(emphasized ? .caption.weight(.semibold) : .caption)
                .foregroundStyle(.orange)
            Text(text)
                .font(emphasized ? .callout.weight(.semibold) : .callout)
                .lineLimit(2)
            Spacer(minLength: 0)
        }
    }

    // MARK: GitHub Watcher — notification-only monitoring (W2b)
    //
    // Directly below Waiting on you, above the bench (contract position).
    // Organized by who has the next move; healthy/waiting PRs collapse.
    // Absent entirely when nothing is tracked — an empty lane is noise.

    private func bucket(_ item: GitHubCommandItem) -> DeskGitHubBucket {
        DeskGitHubBucket.bucket(for: item.state)
    }

    private func ghBucketItems(_ bucket: DeskGitHubBucket) -> [GitHubCommandItem] {
        DeskGitHubPortfolioStrip.presentation(for: bucket, items: githubItems).renderedItems
    }

    private var needsUserGitHubItems: [GitHubCommandItem] { ghBucketItems(.needsUser) }

    @ViewBuilder
    private var githubCommandSection: some View {
        // Always visible (User, 2026-07-12: "this is just my window into
        // checking on what she's got with human eyes") — a monitoring surface
        // that hides itself when quiet reads as missing, not as quiet.
        sectionHeader(
            "GitHub Watcher",
            count: DeskGitHubPortfolioStrip.headerCount(items: githubItems),
            systemImage: "eye")
        switch DeskHonestyPresentation.githubLane(githubLane) {
        case .unavailable(let notice):
            laneUnavailableNotice(title: notice.title, detail: notice.detail)
        case .quiet(let copy):
            Text(copy)
                .font(.callout).foregroundStyle(.tertiary)
                .padding(.leading, 4)
        case .rows:
            ghPortfolioStrip
            ForEach(DeskGitHubBucket.inlineBuckets, id: \.rawValue) { bucket in
                let rows = ghBucketItems(bucket)
                if !rows.isEmpty {
                    ghSubheader(bucket.rawValue, count: rows.count,
                                tinted: bucket == .attention || bucket == .needsUser)
                    ForEach(rows, id: \.itemId) { ghItemRow($0) }
                }
            }
            ghWaitingCollapsed
            let resolved = ghBucketItems(DeskGitHubBucket.resolvedBucket)
            if !resolved.isEmpty {
                ghSubheader(DeskGitHubBucket.resolvedBucket.rawValue, count: resolved.count, tinted: false)
                ForEach(resolved, id: \.itemId) { ghItemRow($0) }
            }
        }
    }

    private var ghPortfolioStrip: some View {
        HStack(spacing: 10) {
            ForEach(DeskGitHubBucket.allCases, id: \.rawValue) { bucket in
                let presentation = DeskGitHubPortfolioStrip.presentation(for: bucket, items: githubItems)
                if presentation.renderedCount > 0 {
                    Text(presentation.label)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(bucket == .attention ? Color.red
                                         : bucket == .needsUser ? .orange : .secondary)
                        .padding(.horizontal, 7).padding(.vertical, 2)
                        .background(Color.primary.opacity(0.06), in: Capsule())
                }
            }
            Spacer(minLength: 0)
        }
    }

    private func ghSubheader(_ title: String, count: Int, tinted: Bool) -> some View {
        Text("\(title)  ·  \(count)")
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(tinted ? AnyShapeStyle(Color.orange) : AnyShapeStyle(.secondary))
            .padding(.top, 2)
    }

    // Waiting upstream: grouped by kind, collapsed by default (contract).
    @ViewBuilder
    private var ghWaitingCollapsed: some View {
        let waiting = ghBucketItems(DeskGitHubBucket.collapsedBucket)
        if !waiting.isEmpty {
            let toggleKey = DeskGitHubWaitingRollup.toggleKey
            let expanded = expandedRoots.contains(toggleKey)
            HStack(spacing: 8) {
                Text("Waiting upstream")
                    .font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                ForEach(GitHubCommandWaitingKind.allCases, id: \.rawValue) { kind in
                    let n = waiting.filter {
                        if case .waitingUpstream(let k) = $0.state { return k == kind }
                        return false
                    }.count
                    if n > 0 {
                        Text("\(DeskGitHubStatePillPresentation.waitingLabel(for: kind)) \(n)")
                            .font(.caption2).foregroundStyle(.tertiary)
                            .padding(.horizontal, 6).padding(.vertical, 1)
                            .background(Color.primary.opacity(0.06), in: Capsule())
                    }
                }
                Spacer(minLength: 4)
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
                    .rotationEffect(.degrees(expanded ? 90 : 0))
            }
            .padding(.vertical, 6).padding(.horizontal, 10)
            .background(Color.primary.opacity(0.03), in: RoundedRectangle(cornerRadius: 8))
            .contentShape(Rectangle())
            .naInteractive(radius: 8)
            .onTapGesture { toggle(toggleKey, expanded: expanded) }
            if expanded {
                ForEach(waiting, id: \.itemId) { ghItemRow($0) }
            }
        }
    }

    private func ghItemRow(_ item: GitHubCommandItem) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                ghStatePill(item)
                Text(item.title.isEmpty ? "\(item.repository) #\(item.number)" : item.title)
                    .font(.body.weight(.medium)).lineLimit(2)
                Spacer(minLength: 4)
                Text(relativeTime(item.motorUpdatedAt ?? item.updatedAt))
                    .font(.caption2).foregroundStyle(.tertiary)
            }
            HStack(spacing: 8) {
                Text("\(item.repository) #\(item.number) · \(item.kind == .pullRequest ? "PR" : "issue")")
                    .font(.caption2.weight(.medium)).foregroundStyle(.tertiary)
                if let blocker = item.blocker {
                    Text("\(blocker.detail) — \(blocker.owner)")
                        .font(.caption).foregroundStyle(.orange)
                        .lineLimit(1).truncationMode(.tail)
                } else if let receipt = item.finalReceipt, !receipt.isEmpty {
                    Text(receipt)
                        .font(.caption).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.tail)
                } else if let last = item.workLog.last {
                    Text(last.summary)
                        .font(.caption).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.tail)
                }
            }
            .padding(.leading, 2)
            // Callback evidence is explicit: an absent provider error does
            // not erase a failed/no-final-result callback from the Desk row.
            if let callbackFailure = DeskGitHubCallbackFailurePresentation.detail(for: item) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(callbackFailure.message)
                        .font(.caption).foregroundStyle(.red)
                        .lineLimit(2).truncationMode(.tail)
                    if let noWork = callbackFailure.noWorkObserved {
                        Text(noWork ? "no work ran — resend safe" : "partial work possible")
                            .font(.caption2)
                            .foregroundStyle(noWork ? Color.secondary : Color.orange)
                    }
                }
                .padding(.leading, 2)
            }
        }
        .padding(.vertical, 8).padding(.horizontal, 10)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
        .id(DeskGitHubWaitingRollup.paletteHandle(for: item))
    }

    private func ghStatePill(_ item: GitHubCommandItem) -> some View {
        let pill = DeskGitHubStatePillPresentation.pill(for: item)
        return Text(pill.label)
            .capsuleTag(statusColor(pill.tone))
    }

    // MARK: section 2 — in progress (delegation programs + directed execution)

    @ViewBuilder
    private var benchSection: some View {
        let renderedCount = programFamilies.count + benchExecutions.count
        sectionHeader("In progress", count: renderedCount == 0 ? nil : renderedCount,
                      systemImage: "hammer")
            .id("sec-bench")
        switch DeskHonestyPresentation.inProgressLane(
            executions: executionsLane,
            deskItems: deskItemsLane,
            hasRenderedRows: renderedCount > 0
        ) {
        case .unavailable(let notice):
            laneUnavailableNotice(title: notice.title, detail: notice.detail)
        case .quiet(let copy):
            Text(copy)
                .font(.callout).foregroundStyle(.tertiary)
                .padding(.leading, 4)
        case .rows:
            ForEach(programFamilies) { family in
                programFamilyView(family)
            }
            ForEach(benchExecutions, id: \.id) { executionRow($0) }
        }
    }

    /// Delegation families are intentionally glance-only. `laneOf` selects
    /// these rows for presentation but creates no Desk selection, mutation,
    /// sequencing, archive, or expansion relationship.
    private func programFamilyView(_ family: DeskProgramFamilyPresentation.Family) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "square.stack.3d.up")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.blue)
                VStack(alignment: .leading, spacing: 2) {
                    Text(family.parentTitle)
                        .font(.body.weight(.semibold))
                        .lineLimit(1)
                    if family.parentSummary != family.parentTitle {
                        Text(family.parentSummary)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2).truncationMode(.tail)
                    }
                }
                Spacer(minLength: 8)
                Text("\(family.lanes.count) lane\(family.lanes.count == 1 ? "" : "s")")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Color.primary.opacity(0.06), in: Capsule())
            }

            ForEach(family.lanes) { lane in
                programLaneRow(lane)
            }
        }
        .padding(.vertical, 9).padding(.horizontal, 10)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
    }

    private func programLaneRow(_ lane: DeskProgramFamilyPresentation.Lane) -> some View {
        HStack(spacing: 7) {
            Label(lane.assignee, systemImage: lane.assigneeSymbol)
                .font(.caption2.weight(.medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Circle()
                .fill(statusColor(DeskStatusTonePresentation.tone(for: lane.status)))
                .frame(width: 7, height: 7)
                .accessibilityLabel(DeskItemPresentation.statusLabel(lane.status))
            Text(lane.title)
                .font(.callout)
                .lineLimit(1).truncationMode(.tail)
            Spacer(minLength: 8)
            if let progress = lane.progress {
                ProgressView(value: Double(progress.done), total: Double(progress.total))
                    .progressViewStyle(.linear)
                    .frame(width: 72)
                Text("\(progress.done)/\(progress.total)")
                    .font(.caption2.monospacedDigit().weight(.semibold))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.leading, 18)
    }

    private func executionRow(_ exec: WorkshopExecution.WorkshopExecutionRecord) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                executionPill(exec.status)
                Text(exec.title)
                    .font(.body.weight(.medium))
                    .lineLimit(2)
                Spacer(minLength: 4)
                Text(relativeTime(exec.updatedAt))
                    .font(.caption2).foregroundStyle(.tertiary)
            }
            if !exec.objective.isEmpty {
                Text(exec.objective)
                    .font(.caption).foregroundStyle(.secondary)
                    .lineLimit(2).truncationMode(.tail)
                    .padding(.leading, 2)
            }
            if let progress = DeskExecutionPresentation.progress(
                status: exec.status,
                planCount: exec.plan.count,
                completedCount: exec.stepsCompleted.count
            ) {
                Text(progress)
                    .font(.caption2.weight(.medium)).foregroundStyle(.tertiary)
                    .padding(.leading, 2)
            }
            if let verification = exec.verification,
               exec.status == "completed" || verification.status == .failed {
                Label(
                    DeskExecutionPresentation.verificationLabel(verification),
                    systemImage: verification.status == .satisfied
                        ? "checkmark.seal.fill"
                        : verification.status == .failed
                            ? "exclamationmark.triangle.fill"
                            : "questionmark.circle"
                )
                .font(.caption2.weight(.medium))
                .foregroundStyle(
                    verification.status == .satisfied
                        ? Color.green
                        : verification.status == .failed ? Color.red : Color.secondary
                )
                .padding(.leading, 2)
            }
        }
        .padding(.vertical, 8).padding(.horizontal, 10)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
    }

    private func executionPill(_ status: String) -> some View {
        let pill = DeskExecutionPresentation.pill(for: status)
        return Text(pill.label)
            .capsuleTag(statusColor(pill.tone))
    }

    // MARK: section 3 — her pursuits (volition surface, in her own words)

    @ViewBuilder
    private var pursuitsSection: some View {
        sectionHeader("Agent pursuits", count: DeskPursuitSectionPresentation.headerCount(for: pursuitRows),
                      systemImage: "sparkles")
        if pursuitRows.isEmpty {
            Text("None yet. A pursuit opens only when the evidence holds — something has to earn the agent's attention more than once.")
                .font(.callout).foregroundStyle(.tertiary)
                .padding(.leading, 4)
        } else {
            ForEach(pursuitRows) { pursuitCard($0) }
        }
    }

    @ViewBuilder
    private func pursuitCard(_ row: DeskPursuitSectionPresentation.Row) -> some View {
        let item = row.item
        switch row.cardState {
        case let .rendered(presentation):
            if let pursuit = item.pursuit {
            VStack(alignment: .leading, spacing: 5) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    statusPill(item.status)
                    Text(presentation.title)
                        .font(.body.weight(.semibold))
                        .lineLimit(2)
                    Spacer(minLength: 4)
                    Text(presentation.sessionLabel)
                        .font(.caption2.weight(.medium)).foregroundStyle(.tertiary)
                }
                Text("\u{201C}\(pursuit.why)\u{201D}")
                    .font(.callout.italic())
                    .foregroundStyle(.secondary)
                    .lineLimit(3).truncationMode(.tail)
                if item.status == .blocked, let hold = presentation.holdLabel {
                    Label(hold, systemImage: "stop.circle")
                        .font(.caption).foregroundStyle(.red)
                        .lineLimit(2)
                } else if let hold = presentation.holdLabel {
                    Label(hold, systemImage: "hourglass")
                        .font(.caption).foregroundStyle(.orange)
                        .lineLimit(1)
                }
                // Pursuits are ordinary desk items to the sequencer — a pursuit
                // can be blocked on an item, parked, or next up like anything
                // else, so it gets the same pills rather than a parallel story.
                sequencingPills(item)
                HStack(spacing: 12) {
                    Label {
                        Text(presentation.doneLabel).lineLimit(1).truncationMode(.tail)
                    } icon: {
                        Image(systemName: "checkmark.circle")
                    }
                    .font(.caption).foregroundStyle(.tertiary)
                    if let last = pursuit.lastWorkedAt {
                        Text("worked \(relativeTime(last))")
                            .font(.caption).foregroundStyle(.tertiary)
                    }
                }
            }
            .padding(.vertical, 10).padding(.horizontal, 12)
            .background(Color.purple.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(selectedHandle == item.handle
                                  ? Color.accentColor.opacity(0.85)
                                  : Color.purple.opacity(0.15),
                                  lineWidth: selectedHandle == item.handle ? 2 : 1)
            )
            .contentShape(Rectangle())
            .naInteractive(radius: 10)
            .onTapGesture { toggleSelection(item.handle) }
            .id(item.handle)
            } else {
                pursuitPayloadUnreadableCard(item)
            }
        case .payloadUnreadable:
            pursuitPayloadUnreadableCard(item)
        case .notPursuit:
            EmptyView()
        }
    }

    private func pursuitPayloadUnreadableCard(_ item: DeskItem) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Label(DeskPursuitSectionPresentation.unreadablePayloadLabel, systemImage: "exclamationmark.triangle")
                .font(.body.weight(.semibold))
                .foregroundStyle(.orange)
            Text(item.title)
                .font(.callout)
                .lineLimit(2)
            Text(DeskPursuitSectionPresentation.unreadablePayloadDetail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(3)
        }
        .padding(.vertical, 10).padding(.horizontal, 12)
        .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(Color.orange.opacity(0.4), lineWidth: 1)
        )
        .accessibilityIdentifier("desk.pursuit.payload-unreadable.\(item.handle)")
        .id(item.handle)
    }

    // MARK: section 4 — waiting & watches (ambient, quieter than active work)

    @ViewBuilder
    private var watchesSection: some View {
        if !watchItems.isEmpty {
            sectionHeader("Waiting & watches", count: watchItems.count, systemImage: "binoculars")
                .id("sec-watch")
            // Stalest-first ordering lives in DeskBoardLayout.watches() so the
            // visible order and the arrow-key selection order can't diverge.
            ForEach(groups(watchItems), id: \.key) { groupView($0, section: "watch") }
        }
    }

    // MARK: section 5 — the board (User/system items, family-grouped; gh collapsed)

    @ViewBuilder
    private var boardSection: some View {
        if !boardItems.isEmpty {
            sectionHeader("The board", count: boardItems.count, systemImage: "list.clipboard")
            ForEach(groups(boardNonGhItems), id: \.key) { groupView($0, section: "board") }
            // GitHub rows collapse to one summary per project — the numbered
            // PR inventory look dies here. The dedicated GitHub Watcher lane
            // (routing state machine) arrives with W1's store; this is only
            // the presentation collapse.
            ForEach(ghByProject, id: \.project) { group in
                ghProjectSummary(group)
            }
        }
    }

    @ViewBuilder
    private func ghProjectSummary(_ group: (project: String, items: [DeskItem])) -> some View {
        let toggleKey = "gh:\(group.project)"
        let expanded = expandedRoots.contains(toggleKey)
        // A collapsed summary must not hide status-critical facts (review
        // finding): count the children that need eyes and say so on the line.
        let needsEyes = DeskItemPresentation.githubProjectNeedsEyes(group.items)
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "arrow.triangle.pull")
                .font(.caption).foregroundStyle(.secondary)
            Text("GitHub · \(group.project)")
                .font(.body.weight(.medium)).foregroundStyle(.secondary)
                .lineLimit(1)
            if needsEyes > 0 {
                Text("\(needsEyes) need\(needsEyes == 1 ? "s" : "") attention")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.orange)
                    .padding(.horizontal, 6).padding(.vertical, 1)
                    .background(Color.orange.opacity(0.14), in: Capsule())
            }
            Spacer(minLength: 4)
            Text("\(group.items.count)")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 6).padding(.vertical, 1)
                .background(Color.primary.opacity(0.08), in: Capsule())
            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
                .rotationEffect(.degrees(expanded ? 90 : 0))
        }
        .padding(.vertical, 8).padding(.horizontal, 10)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
        .contentShape(Rectangle())
        .naInteractive(radius: 8)
        .onTapGesture { toggle(toggleKey, expanded: expanded) }
        if expanded {
            ForEach(group.items, id: \.handle) { child in
                itemRow(child)
                    .contentShape(Rectangle())
                    .onTapGesture { toggleSelection(child.handle) }
            }
        }
    }

    // MARK: section 6 — recently finished (items + executions)

    /// Finished history grows without bound; the section doesn't. Newest
    /// families first, capped, with an explicit reveal — the count in the
    /// header stays the honest total (NEEDS_FIX 4).
    private static let finishedGroupCap = 8

    @ViewBuilder
    private var finishedSection: some View {
        if !doneItems.isEmpty || !recentDoneExecutions.isEmpty {
            let allGroups = groups(doneItems.sorted { $0.updatedAt > $1.updatedAt })
            sectionHeader("Recently finished",
                          count: DeskFinishedPresentation.sectionCount(
                              groupCount: allGroups.count,
                              recentExecutionCount: recentDoneExecutions.count),
                          systemImage: "checkmark.seal")
            ForEach(recentDoneExecutions, id: \.id) { executionRow($0) }
            let visible = DeskItemPresentation.visiblePrefix(
                allGroups, showingAll: showAllFinished, cap: Self.finishedGroupCap)
            ForEach(visible, id: \.key) { groupView($0, section: "done") }
            if allGroups.count > Self.finishedGroupCap {
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) { showAllFinished.toggle() }
                } label: {
                    Text(showAllFinished
                         ? "Show recent only"
                         : "Show all \(allGroups.count) finished")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.naFeel)
                .padding(.leading, 4)
            }
        }
    }

    // MARK: grouped rendering — one row per top-level number, click to expand
    //
    // User's read (2026-07-03): every `.x` sub-item rendered flat made the
    // board "too spread out" — 13 rows where 7 families live. The board now
    // shows one row per top-level number; clicking a family with sub-items
    // reveals them (badge + chevron say there's something to open). A family
    // whose top-level parent isn't in the same section (e.g. the root is
    // already done while sub-items stay active) collapses under a synthetic
    // header that borrows the parent's title from the full item list — the
    // spread came mostly from exactly these orphan families. A lone orphan
    // sub-item renders flat; one row is already compact.

    // W5: the grouping itself lives in `DeskBoardLayout.groups` so the selection
    // order can walk EXACTLY the rows this renders (see DeskInteraction.swift).
    private typealias DeskGroup = DeskBoardLayout.Group

    private func groups(_ list: [DeskItem]) -> [DeskGroup] {
        DeskBoardLayout.groups(list, allItems: items)
    }

    private func toggle(_ toggleKey: String, expanded: Bool) {
        withAnimation(.easeInOut(duration: 0.15)) {
            if expanded { expandedRoots.remove(toggleKey) }
            else { expandedRoots.insert(toggleKey) }
        }
    }

    @ViewBuilder
    private func groupView(_ group: DeskGroup, section: String) -> some View {
        let toggleKey = "\(section):\(group.key)"
        let expanded = expandedRoots.contains(toggleKey)
        if let root = group.root {
            itemRow(root, childCount: group.children.count, expanded: expanded)
                .contentShape(Rectangle())
                .onTapGesture {
                    // W5: one click means both — pick the row AND open the
                    // family. Splitting them would put two hit targets on one
                    // row, and the family chevron was already the whole row.
                    toggleSelection(root.handle)
                    guard !group.children.isEmpty else { return }
                    toggle(toggleKey, expanded: expanded)
                }
            if expanded {
                ForEach(group.children, id: \.handle) { child in
                    itemRow(child)
                        .contentShape(Rectangle())
                        .onTapGesture { toggleSelection(child.handle) }
                }
            }
        } else if group.children.count > 1 {
            orphanFamilyHeader(group, expanded: expanded)
                .contentShape(Rectangle())
                .onTapGesture { toggle(toggleKey, expanded: expanded) }
            if expanded {
                ForEach(group.children, id: \.handle) { child in
                    itemRow(child)
                        .contentShape(Rectangle())
                        .onTapGesture { toggleSelection(child.handle) }
                }
            }
        } else {
            ForEach(group.children, id: \.handle) { child in
                itemRow(child)
                    .contentShape(Rectangle())
                    .onTapGesture { toggleSelection(child.handle) }
            }
        }
    }

    // Collapsible header for a family whose top-level parent isn't in this
    // section — a plain grouping handle, deliberately NOT styled like an item
    // row so it never reads as an item claiming a status.
    private func orphanFamilyHeader(_ group: DeskGroup, expanded: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(group.parentTitle ?? "Sub-items")
                .font(.body.weight(.medium)).foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer(minLength: 4)
            Text("\(group.children.count)")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 6).padding(.vertical, 1)
                .background(Color.primary.opacity(0.08), in: Capsule())
            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
                .rotationEffect(.degrees(expanded ? 90 : 0))
        }
        .padding(.vertical, 8).padding(.horizontal, 10)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
        .naInteractive(radius: 8)
    }

    // MARK: one item row (indented by nesting depth)

    private func itemRow(_ item: DeskItem, childCount: Int = 0, expanded: Bool = false) -> some View {
        let depth = item.alias.filter { $0 == "." }.count
        let sub = subLine(item)
        // Readability pass (2026-07-02): the TITLE leads the row — it was
        // buried after alias/pill/kind·project, so scanning meant skipping
        // three metadata tokens per row. Kind·project demotes to the second
        // line, and the sub-line is bounded so long notes can't wall-of-text
        // the whole board.
        // De-numbered (cockpit v2): raw aliases live in the All-items debug
        // view now — the primary row leads with the title, ends with freshness.
        return VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                statusPill(item.status)
                Text(item.title)
                    .font(.body.weight(.medium))
                    .lineLimit(2)
                Spacer(minLength: 4)
                if item.pinned { Image(systemName: "pin.fill").font(.caption2).foregroundStyle(.orange) }
                freshnessText(item)
                if childCount > 0 {
                    Text("\(childCount)")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6).padding(.vertical, 1)
                        .background(Color.primary.opacity(0.08), in: Capsule())
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                }
            }
            // Surface the KIND too (watch/plan/project/gh/standing) — the
            // status pill alone hides it, so a plan with default `watch`
            // status would read as a generic watch item. Origin appears only
            // when it isn't User's — the honest existing-field proxy for owner.
            Text(item.origin == .owner
                 ? "\(item.kind.rawValue) · \(item.project)"
                 : "\(item.kind.rawValue) · \(item.project) · \(item.origin.rawValue)")
                .font(.caption2.weight(.medium)).foregroundStyle(.tertiary)
                .padding(.leading, 2)
            // Sequencing sits ABOVE the free-text sub-line: blockers, parked
            // dates and campaign progress are status-critical and must not be
            // the thing that truncates away when a note is long.
            sequencingPills(item)
            if !sub.isEmpty {
                Text(sub)
                    .font(.caption).foregroundStyle(.secondary)
                    .lineLimit(3)
                    .truncationMode(.tail)
                    .padding(.leading, 2)
            }
        }
        .padding(.vertical, 8).padding(.horizontal, 10)
        .background(depth == 0 ? Color.primary.opacity(0.04) : Color.clear,
                    in: RoundedRectangle(cornerRadius: 8))
        .selectionHighlight(selectedHandle == item.handle)
        .naInteractive(radius: 8)
        .padding(.leading, CGFloat(depth) * 18)
        // Anchor for `proxy.scrollTo` — arrows, palette matches and blocker
        // pills all land through the same id.
        .id(item.handle)
    }


    private func subLine(_ item: DeskItem) -> String {
        var parts: [String] = []
        // Status-critical facts lead: the sub-line is capped at 3 rendered
        // lines, so if anything truncates it must be summary prose, never
        // the blocked reason or the waiting-on target.
        if item.status == .blocked, let r = item.blockedReason, !r.isEmpty { parts.append("blocked: \(r)") }
        if let waiting = item.waitingOn, !waiting.isEmpty { parts.append("waiting on \(waiting)") }
        if let s = item.summary, !s.isEmpty { parts.append(s) }
        if let last = item.notes.last { parts.append("note: \(last.text)") }
        if !item.refs.isEmpty { parts.append("\(item.refs.count) ref\(item.refs.count == 1 ? "" : "s")") }
        return parts.joined(separator: "  ·  ")
    }

    // MARK: sequencing pills (rollup · blocked-on · deferred · cycle · next)
    //
    // Everything here reads off the ONE plan computed in load() — no row
    // recomputes anything. Copy rules (public-honesty pass): plain English, no
    // internal vocabulary. "waiting on 2.1" not "blockedOn"; "until 2026-08-14"
    // not "deferUntil"; and the rollup says CLOSED, never "done" — the
    // numerator counts canceled children too, and a canceled child was not done.
    // Same word DeskProjection uses, so User's window and Agent's in-context
    // projection can never disagree.

    /// At most this many blocker aliases render inline; the rest collapse to
    /// "+N" so a fan-in of ten blockers can't stretch the row.
    private static let blockerAliasCap = 3

    @ViewBuilder
    private func sequencingPills(_ item: DeskItem) -> some View {
        if let itemPlan = plan.byHandle[item.handle] {
            let pills = DeskSequencingPillPresentation.pills(
                item: item,
                itemPlan: itemPlan,
                isNextUp: plan.nextUp.contains(item.handle),
                aliases: aliasByHandle,
                blockerAliasCap: Self.blockerAliasCap
            )
            if !pills.isEmpty {
                HStack(spacing: 6) {
                    ForEach(pills) { pill in
                        switch pill.kind {
                        case .rollup:
                            Text(pill.text)
                                .capsuleTag(itemPlan.doneCount == itemPlan.totalCount ? .green : .gray)
                                .accessibilityIdentifier("desk.sequencing-pill.rollup")
                        case .blocked:
                            if let targetHandle = pill.targetHandle {
                                Button { select(targetHandle) } label: {
                                    Label(pill.text, systemImage: "arrow.turn.down.right")
                                        .labelStyle(.titleAndIcon)
                                        .lineLimit(1).truncationMode(.tail)
                                        .capsuleTag(.orange)
                                }
                                .buttonStyle(.naFeel)
                                .help("Go to the item this is waiting on")
                                .accessibilityIdentifier("desk.sequencing-pill.blocked")
                            }
                        case .cycle:
                            Text(pill.text)
                                .lineLimit(1).truncationMode(.tail)
                                .capsuleTag(.red)
                                .accessibilityIdentifier("desk.sequencing-pill.cycle")
                        case .deferred:
                            Label(pill.text, systemImage: "pause.circle")
                                .labelStyle(.titleAndIcon)
                                .lineLimit(1)
                                .capsuleTag(.gray)
                                .accessibilityIdentifier("desk.sequencing-pill.deferred")
                        case .nextUp:
                            Label(pill.text, systemImage: "arrow.right.circle.fill")
                                .labelStyle(.titleAndIcon)
                                .lineLimit(1)
                                .capsuleTag(.teal)
                                .accessibilityIdentifier("desk.sequencing-pill.next-up")
                        }
                    }
                    Spacer(minLength: 0)
                }
                .padding(.leading, 2)
            }
        }
    }

    // MARK: status pill

    private func statusPill(_ status: DeskStatus) -> some View {
        Text(DeskItemPresentation.statusLabel(status))
            .capsuleTag(statusColor(DeskStatusTonePresentation.tone(for: status)))
    }

    private func statusColor(_ tone: DeskPresentationTone) -> Color {
        switch tone {
        case .info: .blue
        case .warning: .orange
        case .success: .green
        case .danger: .red
        case .neutral: .gray
        }
    }

    // MARK: relative time

    /// Row freshness (desk-triage-makeover W2): a quiet active item past the
    /// stale threshold trades its tertiary "Nd ago" for an amber "Nd stale"
    /// chip — the same rot the Stale counter counts, visible on the row.
    /// Blocked/flagged rows keep the plain timestamp; their urgency is already
    /// the status pill's job.
    @ViewBuilder
    private func freshnessText(_ item: DeskItem) -> some View {
        let freshness = DeskItemPresentation.freshness(for: item, now: deskPresentationNow)
        if freshness.isStale {
            Text(freshness.text)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.orange)
                .padding(.horizontal, 5).padding(.vertical, 1)
                .background(Color.orange.opacity(0.12), in: Capsule())
        } else {
            Text(freshness.text)
                .font(.caption2).foregroundStyle(.tertiary)
        }
    }

    private func relativeTime(_ iso: String) -> String {
        DeskRelativeTimePresentation.text(forISO: iso, now: deskPresentationNow)
    }

    private static func parseISO(_ raw: String) -> Date? {
        UserDisplayFormatters.parseISOTimestamp(raw)
    }

    // Desk debug disclosures (agent projection + raw all-items table) moved to
    // Diagnostics ▸ Cognition (DeskDebugPanels.swift) — B2.6 (g).

    // MARK: load

    @MainActor private func load() async -> Bool {
        let root = dataRoot
        // M12: taken BEFORE the await, checked after. A load that lost the race
        // publishes nothing at all — not its items, not its lanes, not its
        // error — because a partial publish is the same stomp in slow motion.
        let token = loadGate.begin()
        DeskLiveReloader.shared.traceEvent("load begin token=\(token)")
        let snapshot = await Task.detached(priority: .userInitiated) {
            let deskState: DeskState?
            let deskError: String?
            do {
                deskState = try await SwiftNativeDeskStore(dataRoot: root).liveState()
                deskError = nil
            } catch {
                deskState = nil
                deskError = DeskItemPresentation.loadFailure(error)
            }
            // Execution and GitHub reads stay independent: one broken lane never
            // blanks the other live Workshop projections. But "lenient" used to
            // mean "silent" — a corrupt store returned [] and the surface said
            // "Quiet right now". Each lane now reports rows OR a reason.
            let runner = SwiftNativeWorkshopRunner(root: root)
            let records = await runner.listAll()
            let executions = DeskLaneState.classify(
                rows: records,
                probe: Self.probeExecutionRecords(runner.executionRecordsRoot),
                noun: "execution record(s)")
            let githubItems: DeskLaneState<GitHubCommandItem>
            do {
                githubItems = .rows(try await GitHubCommandStore(dataRoot: root).liveState().items)
            } catch {
                githubItems = .failed(error)
            }
            let plan = deskState.map { DeskSequencing.compute($0, now: Date()) } ?? DeskSequencing.Plan()
            var aliases: [String: String] = [:]
            for item in deskState?.items ?? [] { aliases[item.handle] = item.alias }
            return DeskViewSnapshot(
                deskState: deskState,
                deskError: deskError,
                executions: executions,
                githubItems: githubItems,
                plan: plan,
                aliasByHandle: aliases
            )
        }.value
        DeskLiveReloader.shared.traceEvent("load snapshot done token=\(token) cancelled=\(Task.isCancelled) accepts=\(loadGate.accepts(token))")
        guard !Task.isCancelled, loadGate.accepts(token) else { return false }
        let presentationNow = Date()
        deskPresentationNow = presentationNow
        if let state = snapshot.deskState {
            items = state.items
            deskItemsLane = .rows(state.items)
            deskGeneratedTs = state.generatedTs
            // Plan and alias map are replaced ATOMICALLY with the items they
            // describe — a stale plan against fresh items would name blockers
            // that no longer exist.
            plan = snapshot.plan
            aliasByHandle = snapshot.aliasByHandle
            loadError = nil
        } else {
            loadError = snapshot.deskError
            deskItemsLane = .unavailable(DeskLaneState<DeskItem>.boundedReason(
                snapshot.deskError ?? "The Desk feed could not be read."))
            deskGeneratedTs = nil
        }
        executionsLane = snapshot.executions
        githubLane = snapshot.githubItems
        // Set on ANY accepted publish, error included: a completed load that
        // failed still "reported" (the error banner owns the surface), and the
        // empty-state gate already excludes loadError/lane-unavailable.
        hasLoadedOnce = true
        // One exact semantic deadline through the existing reloader: either
        // the generated snapshot crosses five minutes or the oldest relevant
        // active row crosses thirty. This is not a polling cadence.
        let activity = DeskLiveActivityPresentation.make(
            deskItems: deskItemsLane,
            generatedTs: deskGeneratedTs,
            now: presentationNow)
        DeskLiveReloader.shared.scheduleRefresh(at: activity.nextRefreshAt)
        return true
    }

    @MainActor private func refreshFromToolbar() async {
        let accepted = await load()
        actionNotice = DeskRefreshPresentation.receipt(accepted: accepted)
    }

    /// Ground truth for the silent-zero cross-check: what does the execution
    /// store actually look like on disk, independent of the reader that
    /// swallows its own failures?
    ///
    /// Mirrors `scanAllQueueWorkshopExecutions()` (WorkshopExecution+Runner.swift:1046)
    /// exactly — it counts a `<root>/<id>/` directory iff that directory holds a
    /// record file, which is precisely the marker the runner writes and the
    /// scanner keys on. `ExecutionRecordFile.exists` accepts EITHER name, so an
    /// unmigrated `mission.json` directory still counts as a record (P2-1).
    /// Two states the old bare count got wrong:
    ///   • root unreadable → it returned 0, so the corrupt store rendered as an
    ///     empty bench. That is the ONE case this check exists for.
    ///   • reservation (`.reserved`, no record yet) and cancelled dirs →
    ///     it counted them, so a healthy empty bench got an "unavailable"
    ///     banner. A cleanly-absent record is the runner's own
    ///     crash-safe ordering, not a lost record.
    /// A record dir whose CONTENTS can't be listed still counts: unreadable is
    /// not absent, and that skew is exactly what should surface.
    nonisolated static func probeExecutionRecords(_ root: URL) -> DeskRecordProbe {
        let fm = FileManager.default
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: root.path, isDirectory: &isDirectory) else { return .empty }
        guard isDirectory.boolValue else {
            return .unreadable("execution root is not a directory")
        }
        let entries: [URL]
        do {
            entries = try fm.contentsOfDirectory(
                at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [])
        } catch {
            return .unreadable("\(error.localizedDescription)")
        }
        var count = 0
        for entry in entries {
            // Dot entries are the runner's own bookkeeping (.admission lock).
            guard !entry.lastPathComponent.hasPrefix(".") else { continue }
            guard (try? entry.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
            else { continue }
            if ExecutionRecordFile.exists(in: entry, fileManager: fm) {
                count += 1
            } else if (try? fm.contentsOfDirectory(atPath: entry.path)) == nil {
                // Can't tell whether it holds a record — malformed, count it.
                count += 1
            }
        }
        return .records(count)
    }
}
