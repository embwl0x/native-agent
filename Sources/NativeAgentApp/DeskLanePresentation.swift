import SwiftUI
import AppKit
import BackgroundLoops
import PersistenceCore
import WorkshopExecution

/// HER HOUR, on the Desk — personality-depth item 9.
///
/// One line, at the bottom, saying what she did with the hour that was hers. It
/// is a TRACE, not a task: it has no action, no count, no badge, and it never
/// becomes a row User has to clear. The lane writes no desk ops (Agent's veto —
/// her aesthetic life is not board work), so this reads the lane's own bounded
/// file directly and renders its newest entry.
///
/// ABSENT when the lane is not installed. Not "off", not a placeholder, not a
/// zero — absent, exactly the way the lane itself is absent when the switch is
/// off. A Desk that shows "Her hour: disabled" would be advertising a feature at
/// a man who turned it off.
enum DeskHerHourPresentation {
    enum State: Sendable, Equatable {
        case absent
        /// Her own closing line, plus how long ago. Nothing else: no verdict,
        /// no outcome adjective we chose, no progress.
        case line(text: String, symbol: String)
    }

    /// The whole rule. Pure, so the Desk's claim about her hour is testable
    /// without a running app or an installed lane.
    static func state(
        installed: Bool,
        entry: StudioWanderLane.TraceEntry?,
        now: Date
    ) -> State {
        guard installed, let entry else { return .absent }
        let words = entry.line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !words.isEmpty else { return .absent }
        let when = DeskRelativeTimePresentation.text(forISO: entry.at, now: now)
        return .line(text: "\(bounded(words)) · \(when)", symbol: symbol(entry.outcome))
    }

    /// Icons, not labels. The three endings are equal in standing — a decline is
    /// not a lesser outcome — so none of them gets a word here that ranks it.
    static func symbol(_ outcome: StudioWanderLane.Outcome) -> String {
        switch outcome {
        case .chose: return "eye"
        case .declined: return "moon.zzz"
        case .noArtifact: return "eye.slash"
        }
    }

    static let maximumCharacters = 160

    private static func bounded(_ value: String) -> String {
        guard value.count > maximumCharacters else { return value }
        return String(value.prefix(maximumCharacters - 1)) + "…"
    }
}

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
                // ONE predicate (Core's OwnerAttentionPolicy): a row whose
                // waitingOn names User is his to clear and is emphasized as
                // such; a row blocked on CI or a sibling item is not.
                needsUserDirectly: OwnerAttentionPolicy.waitsOnOwner(item)))
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
        /// Of `totalItems`, the ones actually waiting on USER — the number the
        /// "Waiting on you" label is allowed to carry (Core's
        /// `OwnerAttentionPolicy`). The rest are blocked on something else.
        let waitingOnYouItems: Int
        let hiddenItems: Int
        let hiddenNeedsUser: Int

        /// Blocked on someone/something that is not User. Shown with its own
        /// label so the strip never charges these to him.
        var blockedItems: Int { max(0, totalItems - waitingOnYouItems) }

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
        let needsUserTotal = OwnerAttentionPolicy.waitingOnOwnerCount(
            approvalsWaiting: approvals.count,
            ownerDecisionItems: OwnerAttentionPolicy.ownerDecisionCount(in: otherAttention)
                + OwnerAttentionPolicy.ownerDecisionCount(in: githubBlocked),
            externalOwnerItems: githubNeedsYou.count)
        return Plan(
            visible: visible,
            totalItems: totalItems,
            waitingOnYouItems: needsUserTotal,
            hiddenItems: totalItems - itemCount(visible),
            hiddenNeedsUser: needsUserTotal - visible.filter(\.needsUserDirectly).count)
    }
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
