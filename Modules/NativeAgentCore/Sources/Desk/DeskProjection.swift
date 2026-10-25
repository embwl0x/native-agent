import Foundation
import PersistenceCore
// Blueprint: | `DeskProjection.swift` | `DeskBoardLayout`, `DeskPaletteRow`, `DeskPaletteQuery`, `DeskFuzzy`, `DeskPaletteCommandApplication`, `DeskQuickAction`, `DeskRefAction`, `DeskRefAffordance`; attention, freshness and date interpretation |

// MARK: - DeskProjection — pure DeskState -> compact text renderer
//
// The rendered text is a PROJECTION, never the source of truth. Pure +
// deterministic: `now` is injected so staleness / archive-grace countdowns are
// reproducible in tests.
//
// HEADER
//   Line 1: `desk · owner · rev <ISO> · stale ok`
//   Line 2: `status: watch · flag · now · next · todo · done · blocked`
//
// TOP-LEVEL ITEM (open, most recently active first)
//   `<alias> <token2> <project> · <title>[ · <summary>][ · <now|next child>]`
//   `[ · refs:N][ · ⚑ drift:<kind>][ · stale:<dur>][ · archive eligible [in <dur>]]`
//   `[ · <level>/event]`
//   • token2 = the STATUS, except when status is the neutral default `.watch`,
//     where the KIND renders instead (reconciles the build plan's literal
//     `<status>` with its ground-truth sample, where a freshly-created plan/gh
//     item shows its kind, and an explicitly-stated status — now/next/done/… —
//     shows the status). Children always render the status.
//   • child highlight: the most-actionable active child (a `now` child wins over
//     a `next` child) collapses inline as `<status> <title>`.
//   • children LIST (indented two spaces) renders only when the item has ≥2
//     children; a single child stays collapsed in the highlight.
//   • one optional note line renders for a high-signal item (status blocked or
//     flag) with a latest note, or for ANY item whose latest note is a drift
//     flag: `  note: <text>`.
//
// CAPS: ≤25 top-level live items; among TERMINAL (done + canceled) show ≤3
// most-recent; refs
// summarized as `refs:N` (the optional inline form is not rendered — priority
// ordering is exposed via DeskItem.liveRefs for consumers); per-item live render
// ≤3 refs in priority order.

public enum DeskProjection {

    public static let topLevelCap = 25
    public static let doneCap = 3

    /// Aliases shown inline on a `blocked-on` segment before collapsing to `+N`.
    public static let blockedOnAliasCap = 3

    public static func render(
        _ state: DeskState,
        now: Date = Date(),
        archiveGrace: TimeInterval = SwiftNativeDeskStore.defaultArchiveGrace
    ) -> String {
        let plan = DeskSequencing.compute(state, now: now)
        var lines: [String] = []
        lines.append("desk · owner · rev \(state.generatedTs) · stale ok")
        // `held` is not a status anyone can set — it is this renderer saying a
        // now/next row is blocked or deferred. Named here so the token is never
        // a mystery on a row.
        lines.append("status: " + DeskStatus.allCases.map(\.displayLabel).joined(separator: " · ")
            + " · held (derived: now/next that is blocked or deferred)")

        for item in cappedTopLevel(state) {
            lines.append(renderTopLevel(item, in: state, now: now, archiveGrace: archiveGrace, plan: plan))
            if let note = noteLine(item) { lines.append(note) }
            // Children list only when the item has ≥2 children.
            // List children when there are ≥2, OR a lone child the parent line's
            // now/next highlight does NOT already surface — so a single
            // blocked/todo child is never hidden, but a single now/next child
            // collapsed inline isn't duplicated (gpt-5.5 review + Agent's sample,
            // where item 4's single `next` child shows only in the highlight).
            let kids = state.children(of: item.handle)
            let listKids = kids.count >= 2 || (kids.count == 1 && childHighlight(item, in: state, plan: plan) == nil)
            if listKids {
                for kid in kids.sorted(by: { SwiftNativeDeskStore.aliasSeq($0.alias) < SwiftNativeDeskStore.aliasSeq($1.alias) }) {
                    var kidSegs = ["  \(kid.alias) \(kid.status == .watch ? kid.status.rawValue : statusToken(kid, plan: plan)) \(kid.title)"]
                    kidSegs.append(contentsOf: sequencingSegments(kid, in: state, plan: plan, includeRollup: false))
                    lines.append(kidSegs.joined(separator: " · "))
                }
            }
        }

        // "what's next" — the answer this whole surface exists for. Rendered as
        // ALIASES (invariant 2: the projection never shows a handle).
        let nextUp = plan.nextUp.compactMap { h in state.items.first { $0.handle == h } }
        if !nextUp.isEmpty {
            lines.append("next up:")
            for item in nextUp {
                lines.append("  \(item.alias) \(item.status.rawValue) \(item.title)")
            }
        }
        return lines.joined(separator: "\n")
    }

    /// The status token a row shows.
    ///
    /// A HELD item is never presented as active work. `now`/`next` is a claim
    /// that this is what is being done, and the sequencing layer already knows
    /// it cannot be: a live blocker, a cycle, a future `deferUntil`, or a held
    /// ancestor. Those rows used to read `now` while the very same line carried
    /// `blocked-on 658` — the board overstating what is in flight (lane1
    /// finding 5). The token now reads `held` and the existing segments still
    /// say WHY. Nothing is stored: this is derived on every render, so the hold
    /// lifting restores the row's own status with no writer involved.
    static func statusToken(_ item: DeskItem, plan: DeskSequencing.Plan) -> String {
        let base = (item.status == .watch) ? item.kind.rawValue : item.status.rawValue
        guard item.status == .now || item.status == .next,
              let itemPlan = plan.byHandle[item.handle], !itemPlan.isReady else { return base }
        return "held"
    }

    // MARK: - Sequencing segments (blocked-on / deferred / cycle / rollup)

    /// The derived sequencing segments for one row, in render order. Blockers are
    /// rendered as the ALIASES the operator sees, never the internal handles.
    /// Public: desk_breakdown composes its numbered-plan reply from these same
    /// segments so the tool reply and the projection can never disagree.
    public static func sequencingSegments(
        _ item: DeskItem,
        in state: DeskState,
        plan: DeskSequencing.Plan,
        includeRollup: Bool
    ) -> [String] {
        guard let itemPlan = plan.byHandle[item.handle] else { return [] }
        var segs: [String] = []
        if includeRollup, itemPlan.totalCount > 0 {
            // "closed", not "done": the numerator counts every TERMINAL
            // descendant (done AND canceled) — it measures work remaining,
            // and claiming a canceled child as "done" would be a false label.
            segs.append("\(itemPlan.doneCount)/\(itemPlan.totalCount) closed")
        }
        if !itemPlan.effectiveBlockers.isEmpty {
            let aliases = itemPlan.effectiveBlockers.compactMap { h in
                state.items.first { $0.handle == h }?.alias
            }
            if !aliases.isEmpty {
                let shown = aliases.prefix(blockedOnAliasCap).joined(separator: ",")
                let overflow = aliases.count - min(aliases.count, blockedOnAliasCap)
                segs.append("blocked-on \(shown)" + (overflow > 0 ? "+\(overflow)" : ""))
            }
        }
        if itemPlan.blockedByCycle {
            segs.append("⚠ blocked-on cycle")
        }
        if itemPlan.isDeferred, let raw = item.deferUntil,
           let day = DeskSequencing.deferDisplayDay(raw) {
            segs.append("deferred until \(day)")
        }
        return segs
    }

    // MARK: - Top-level selection + caps

    /// Top-level items for the board: OPEN items most-recently-active first,
    /// then the ≤3 most recently closed, capped at 25. Lowest-number-first
    /// hid all new work once the desk passed 25 open items (Agent, 2026-09-24).
    ///
    /// The recency cap counts TERMINAL items (done AND canceled), not `.done`
    /// alone — canceled rows are closed work with the same zero live signal.
    public static func cappedTopLevel(_ state: DeskState) -> [DeskItem] {
        let top = state.topLevel
        let open = top.filter { !$0.status.isTerminal }
            .map { (item: $0, active: lastActive($0, in: state)) }
            .sorted { $0.active != $1.active ? $0.active > $1.active : $0.item.handle < $1.item.handle }
            .map(\.item)
        let closed = top.filter { $0.status.isTerminal }
            .sorted { ($0.closedAt ?? $0.updatedAt) > ($1.closedAt ?? $1.updatedAt) }
            .prefix(doneCap)
        return Array((open + closed).prefix(topLevelCap))
    }

    /// Newest `updatedAt` across the item and its whole subtree — a campaign
    /// whose steps are being worked is active even if its own row is not.
    public static func lastActive(_ item: DeskItem, in state: DeskState) -> String {
        SwiftNativeDeskStore.descendants(of: item.handle, in: state).map(\.updatedAt).max()
            .map { max($0, item.updatedAt) } ?? item.updatedAt
    }

    // MARK: - One top-level line

    static func renderTopLevel(
        _ item: DeskItem,
        in state: DeskState,
        now: Date,
        archiveGrace: TimeInterval,
        plan: DeskSequencing.Plan
    ) -> String {
        let token2 = statusToken(item, plan: plan)
        var segs: [String] = ["\(item.alias) \(token2) \(item.project)", item.title]

        // Origin marker (additive): a self-authored pursuit reads as hers, with
        // her private name when she gave it one. User-origin items render unchanged.
        if item.isPursuit {
            if let priv = item.pursuit?.privateName, !priv.isEmpty {
                segs.append("✦pursuit “\(priv)”")
            } else {
                segs.append("✦pursuit")
            }
        } else if item.origin == .system {
            segs.append("⚙system")
        }
        if let summary = item.summary, !summary.isEmpty {
            segs.append(summary)
        }
        if let highlight = childHighlight(item, in: state, plan: plan) {
            segs.append(highlight)
        }
        // Parent progress DERIVES from the subtree (Agent's #2 — never a field
        // she hand-maintains), plus the blocked-on / cycle / deferred markers.
        segs.append(contentsOf: sequencingSegments(item, in: state, plan: plan, includeRollup: true))
        // refs:N only when 3+ (0–2 stay off the compact line; the full set lives
        // in the store + tab). gpt-5.5 review: spec is ">= 3", was rendering
        // refs:1 / refs:2.
        if item.refs.count >= 3 {
            segs.append("refs:\(item.refs.count)")
        }
        if let drift = driftSegment(item) {
            segs.append(drift)
        }
        if let stale = staleSegment(item, now: now) {
            segs.append(stale)
        }
        if let archives = archiveCountdown(item, in: state, now: now, archiveGrace: archiveGrace) {
            segs.append(archives)
        }
        if item.cadence.mode == .event {
            segs.append("\(item.notify.level.rawValue)/event")
        }
        return segs.joined(separator: " · ")
    }

    /// The most-actionable active child collapsed inline (`now` wins over
    /// `next`). nil when no now/next child exists.
    static func childHighlight(_ item: DeskItem, in state: DeskState, plan: DeskSequencing.Plan) -> String? {
        let kids = state.children(of: item.handle)
            .sorted { SwiftNativeDeskStore.aliasSeq($0.alias) < SwiftNativeDeskStore.aliasSeq($1.alias) }
        // "the most-actionable active child" — a held child is not actionable,
        // so it cannot be the one the parent line advertises (lane1 finding 5).
        func startable(_ kid: DeskItem) -> Bool {
            return plan.byHandle[kid.handle]?.isReady ?? true
        }
        if let nowChild = kids.first(where: { $0.status == .now && startable($0) }) {
            return "now \(nowChild.title)"
        }
        if let nextChild = kids.first(where: { $0.status == .next && startable($0) }) {
            return "next \(nextChild.title)"
        }
        return nil
    }

    /// `⚑ drift:<kind>` when the LAST thing that happened to this item was the
    /// observation lane noticing reality disagreed with the board.
    ///
    /// DERIVED from the note trail, never a stored flag — which is the whole
    /// reason Wave 5 writes drift as a marker-prefixed note instead of a state
    /// field. Any newer note (a receipt, a human note, the next drift) replaces
    /// this segment, so there is no bit that can stay stuck ON after reality
    /// moves back. `hasPrefix`, not `contains`: a note quoting the marker inside
    /// its own text must not be able to fake a flag.
    static func driftSegment(_ item: DeskItem) -> String? {
        // Strict parse (exact `⚑ drift[` + a kind that is a real DeskDriftKind),
        // so human prose that merely opens with the marker cannot render a
        // fabricated kind. The kind alone is what fits the compact line; the
        // phrase and evidence live in the note line below it.
        guard let last = item.notes.last,
              let kind = DeskObservationEvaluator.driftKind(inNote: last.text) else { return nil }
        return "\(DeskObservationEvaluator.driftMarker):\(kind.rawValue)"
    }

    /// One high-signal note line: a blocked/flagged item's latest note, or — for
    /// an item of ANY status — a drift flag the desk just raised. Drift is the
    /// desk contradicting itself out loud; hiding it behind a status filter would
    /// make the loudest thing it can say the quietest thing it renders.
    static func noteLine(_ item: DeskItem) -> String? {
        guard let last = item.notes.last else { return nil }
        let isDrift = DeskObservationEvaluator.driftKind(inNote: last.text) != nil
        guard item.status == .blocked || item.status == .flag || isDrift else { return nil }
        return "  note: \(last.text)"
    }

    // MARK: - Staleness / archive countdown

    /// `stale:<dur>` when the item's cadence.lastRefreshAt is older than its
    /// staleAfter window. nil when no lastRefreshAt / staleAfter, or still fresh.
    static func staleSegment(_ item: DeskItem, now: Date) -> String? {
        // A DEFERRED item is parked on purpose — it is not neglected, and
        // flagging it stale is the exact noise the defer field exists to kill
        // (Agent's #3). Checked from the item itself so the suppression holds
        // for every caller of staleSegment, plan or no plan.
        guard !DeskSequencing.isDeferred(item, now: now) else { return nil }
        guard let lastRaw = item.cadence.lastRefreshAt,
              let last = DeskClock.parseISO(lastRaw),
              let staleAfter = item.cadence.staleAfter,
              let threshold = parseDuration(staleAfter) else { return nil }
        let elapsed = now.timeIntervalSince(last)
        guard elapsed > threshold else { return nil }
        return "stale:\(humanDuration(elapsed))"
    }

    /// Archival eligibility after the grace window; archival is explicit.
    static func archiveCountdown(_ item: DeskItem, in state: DeskState, now: Date, archiveGrace: TimeInterval) -> String? {
        guard item.status.isTerminal, item.kind != .standing, !item.pinned,
              item.continuation?.pending.isEmpty ?? true,
              let closedRaw = item.closedAt, let closed = DeskClock.parseISO(closedRaw) else { return nil }
        guard !SwiftNativeDeskStore.descendants(of: item.handle, in: state).contains(where: {
            $0.kind == .standing || !$0.status.isTerminal || !($0.continuation?.pending.isEmpty ?? true)
        }) else { return nil }
        let remaining = archiveGrace - now.timeIntervalSince(closed)
        return remaining > 0 ? "archive eligible in \(humanDuration(remaining))" : "archive eligible"
    }

    // MARK: - Duration helpers

    /// Compact human duration: < 1h → "<n>m", < 1d → "<n>h", else "<n>d".
    /// Rounds to the nearest unit so a value sitting on a bucket boundary (e.g.
    /// a full 48h grace window) renders cleanly and is robust to the sub-second
    /// drift of an ISO round-trip rather than tipping a day down by 1ms.
    static func humanDuration(_ seconds: TimeInterval) -> String {
        let s = max(0, seconds)
        if s < 3600 { return String(format: "%.0f", (s / 60).rounded()) + "m" }
        if s < 86_400 { return String(format: "%.0f", (s / 3600).rounded()) + "h" }
        return String(format: "%.0f", (s / 86_400).rounded()) + "d"
    }

    /// Parse a duration string like "30m" / "2h" / "1d" into seconds.
    static func parseDuration(_ s: String) -> TimeInterval? {
        let trimmed = s.trimmingCharacters(in: .whitespaces)
        guard let unit = trimmed.last, let integer = Int(trimmed.dropLast()), integer > 0 else { return nil }
        let value = TimeInterval(integer)
        let seconds: TimeInterval
        switch unit {
        case "s": seconds = value
        case "m": seconds = value * 60
        case "h": seconds = value * 3600
        case "d": seconds = value * 86_400
        default: return nil
        }
        return seconds.isFinite ? seconds : nil
    }
}

// MARK: - The full record (one exact item)

/// What the folder holds, for the ONE item that was asked for by name.
///
/// The compact projection above is a board: it deliberately drops everything
/// that does not fit a line — the summary past its cut, every ref but a count,
/// the dependency edges as aliases, and every note but the latest one of a
/// blocked row. That is right for a board and wrong for "what did we decide on
/// Tuesday": an exact read is someone opening the project folder, so this
/// renders the contents. Pure text over the same state, nothing stored.
public extension DeskProjection {
    static func renderRecord(
        _ item: DeskItem,
        in state: DeskState,
        noteCap: Int = 30
    ) -> String {
        var lines: [String] = []
        func alias(_ handle: String) -> String {
            state.items.first { $0.handle == handle }?.alias ?? handle
        }
        func titleOf(_ handle: String) -> String {
            state.items.first { $0.handle == handle }?.title ?? "(not on the live desk)"
        }
        func statusOf(_ handle: String) -> String {
            state.items.first { $0.handle == handle }?.status.rawValue ?? "gone"
        }

        lines.append("record \(item.alias) · \(item.kind.rawValue) · \(item.status.rawValue)")
        lines.append("  project: \(item.project)")
        lines.append("  title: \(item.title)")
        if let summary = item.summary, !summary.isEmpty { lines.append("  summary: \(summary)") }
        if let parent = item.parent { lines.append("  under: \(alias(parent)) \(titleOf(parent))") }
        if let assignee = item.assignee, !assignee.isEmpty { lines.append("  assignee: \(assignee)") }
        if let reason = item.blockedReason, !reason.isEmpty { lines.append("  blocked because: \(reason)") }
        if let waiting = item.waitingOn, !waiting.isEmpty { lines.append("  waiting on: \(waiting)") }
        if let deferUntil = item.deferUntil, !deferUntil.isEmpty { lines.append("  deferred until: \(deferUntil)") }
        lines.append("  opened \(item.openedAt) · updated \(item.updatedAt)"
            + (item.closedAt.map { " · closed \($0)" } ?? ""))

        // Dependencies BOTH ways. A stored blockedOn edge says what this item
        // waits for; the reverse scan says who is waiting on IT, which is the
        // half that is invisible from the item's own row.
        if !item.blockedOn.isEmpty {
            lines.append("  depends on:")
            for handle in item.blockedOn {
                lines.append("    \(alias(handle)) \(statusOf(handle)) \(titleOf(handle))")
            }
        }
        let dependents = state.items.filter { $0.blockedOn.contains(item.handle) }
        if !dependents.isEmpty {
            lines.append("  blocks:")
            for dep in dependents {
                lines.append("    \(dep.alias) \(dep.status.rawValue) \(dep.title)")
            }
        }
        let kids = state.children(of: item.handle)
            .sorted { SwiftNativeDeskStore.aliasSeq($0.alias) < SwiftNativeDeskStore.aliasSeq($1.alias) }
        if !kids.isEmpty {
            lines.append("  parts:")
            for kid in kids {
                lines.append("    \(kid.alias) \(kid.status.rawValue) \(kid.title)")
            }
        }

        if !item.refs.isEmpty {
            lines.append("  refs (\(item.refs.count)):")
            for ref in item.refs.sorted(by: { $0.priority < $1.priority }) {
                lines.append("    \(refLine(ref))")
            }
        }

        if !item.notes.isEmpty {
            let shown = item.notes.suffix(max(0, noteCap))
            let hidden = item.notes.count - shown.count
            var header = "  notes (\(item.notes.count), oldest first"
            if hidden > 0 { header += "; \(hidden) earlier not shown" }
            lines.append(header + "):")
            for note in shown {
                lines.append("    \(note.ts) \(note.text)")
            }
        }
        return lines.joined(separator: "\n")
    }

    /// One ref as a line. Identity fields first, cached labels after, so a
    /// stale cached title can never hide the thing it points at.
    static func refLine(_ ref: DeskRef) -> String {
        switch ref.kind {
        case let .file(path, line, label):
            return "file \(path)" + (line.map { ":\($0)" } ?? "") + (label.map { " — \($0)" } ?? "")
        case let .commit(sha, repo, label, status):
            return "commit \(sha)" + (repo.map { " in \($0)" } ?? "")
                + (label.map { " — \($0)" } ?? "") + (status.map { " (\($0))" } ?? "")
        case let .ghIssue(repo, number, title, status):
            return "issue \(repo)#\(number)" + (title.map { " — \($0)" } ?? "")
                + (status.map { " (\($0))" } ?? "")
        case let .ghPr(repo, number, title, status, checks):
            return "pr \(repo)#\(number)" + (title.map { " — \($0)" } ?? "")
                + (status.map { " (\($0))" } ?? "") + (checks.map { " checks \($0)" } ?? "")
        case let .url(url, title):
            return "url \(url)" + (title.map { " — \($0)" } ?? "")
        case let .agent(name, handoffId, sessionId):
            return "agent \(name)" + (handoffId.map { " handoff \($0)" } ?? "")
                + (sessionId.map { " session \($0)" } ?? "")
        case let .approval(id, status):
            return "approval \(id)" + (status.map { " (\($0))" } ?? "")
        case let .trace(id, kind):
            return "trace \(id)" + (kind.map { " (\($0))" } ?? "")
        case let .note(text):
            return "note \(text)"
        case let .step(step):
            return "queued \(step.when)" + (step.card.map { " \($0)" } ?? "") + ": \(step.words)"
                + (step.action.map { " · then \($0)" } ?? "")
                + (step.source.map { " · inferred from \"\($0)\"" } ?? "")
                + (step.peers + step.elevated).map { " · from \($0)'s turn" }.joined()
        }
    }
}

public enum DeskBoardLayout {

    // MARK: partition
    //
    // Disjoint + exhaustive over the active items: the self-authored project
    // lane claims first, even when its optional payload could not be decoded.
    // That malformed row must stay visible as an integrity warning rather than
    // silently becoming ordinary board work. Watches and board both negate the
    // same lane predicate, so pursuits ∪ watches ∪ board == activeItems.

    public static func isWatchShaped(_ item: DeskItem) -> Bool {
        item.kind == .watch || item.status == .watch
    }

    public static func activeItems(_ items: [DeskItem]) -> [DeskItem] {
        items.filter { !$0.status.isTerminal }
    }

    public static func isPursuitLaneItem(_ item: DeskItem) -> Bool {
        item.origin == .agent && item.kind == .project
    }

    public static func watches(_ active: [DeskItem]) -> [DeskItem] {
        // Stalest first (desk-triage-makeover W2) — sorted HERE so rendering,
        // arrow-key selection order, and reveal keys all share one definition
        // (gpt-5.5 HIGH: sorting only the render path desynced ↓ from the
        // visible list). Unparseable timestamps sort last; ties break on the
        // raw timestamp string, then handle, so equal-date rows can't jitter
        // between loads (gpt-5.5 MED: `sorted` is not stable).
        active.filter { !isPursuitLaneItem($0) && isWatchShaped($0) }
            .sorted { a, b in
                let da = DeskProjection.parseTimestamp(a.updatedAt) ?? .distantFuture
                let db = DeskProjection.parseTimestamp(b.updatedAt) ?? .distantFuture
                if da != db { return da < db }
                if a.updatedAt != b.updatedAt { return a.updatedAt < b.updatedAt }
                return a.handle < b.handle
            }
    }

}

public struct DeskPaletteRow: Identifiable, Equatable, Sendable {
    public let handle: String
    public let alias: String
    public let title: String
    public let project: String
    public let status: String

    public var id: String { handle }

    /// What the query matches against: the visible number, the title and the
    /// project — everything User can actually read on the row.
    public var haystack: String { "\(alias) \(title) \(project)" }

    public init(
        handle: String,
        alias: String,
        title: String,
        project: String,
        status: String
    ) {
        self.handle = handle
        self.alias = alias
        self.title = title
        self.project = project
        self.status = status
    }

    public init(item: DeskItem) {
        self.init(
            handle: item.handle,
            alias: item.alias,
            title: item.title,
            project: item.project,
            status: item.status.rawValue)
    }
}

public enum DeskFuzzy {
    /// Match quality, LOWER is better. nil = no match at all.
    ///   0 exact · 1 prefix · 2 word-boundary prefix · 3 substring · 4 subsequence
    ///
    /// Ranked rather than boolean because a bare subsequence match ("dsk" ->
    /// "desk") is genuinely weaker than a prefix, and an unranked filter puts
    /// the accidental match above the obvious one.
    public static func rank(query: String, candidate: String) -> Int? {
        let q = query.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        let c = candidate.lowercased()
        guard !q.isEmpty else { return 0 }
        if c == q { return 0 }
        if c.hasPrefix(q) { return 1 }
        if c.split(separator: " ").contains(where: { $0.hasPrefix(q) }) { return 2 }
        if c.contains(q) { return 3 }
        return isSubsequence(q, of: c) ? 4 : nil
    }

    public static func isSubsequence(_ needle: String, of haystack: String) -> Bool {
        var it = haystack.makeIterator()
        for ch in needle {
            var found = false
            while let next = it.next() {
                if next == ch { found = true; break }
            }
            if !found { return false }
        }
        return true
    }

    /// Best matches first. Ties break on title length then handle, so the list
    /// is a TOTAL order — `sorted(by:)` is not stable in Swift, and a palette
    /// whose rows swap under an unchanged query is unusable.
    public static func filter(_ rows: [DeskPaletteRow], query: String, limit: Int = 12) -> [DeskPaletteRow] {
        let scored: [(row: DeskPaletteRow, rank: Int)] = rows.compactMap { row in
            guard let r = rank(query: query, candidate: row.haystack) else { return nil }
            return (row, r)
        }
        let sorted = scored.sorted { l, r in
            if l.rank != r.rank { return l.rank < r.rank }
            if l.row.title.count != r.row.title.count { return l.row.title.count < r.row.title.count }
            return l.row.handle < r.row.handle
        }
        return Array(sorted.prefix(limit).map(\.row))
    }
}

public struct DeskPaletteQuery: Equatable, Sendable {
    public enum Verb: String, CaseIterable, Sendable {
        case close
        case deferItem = "defer"
        case note

        public var actionLabel: String {
            switch self {
            case .close: return "Close"
            case .deferItem: return "Defer"
            case .note: return "Add note"
            }
        }
    }

    public var verb: Verb?
    public var query: String

    public static func parse(_ raw: String) -> DeskPaletteQuery {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return DeskPaletteQuery(verb: nil, query: "") }
        let parts = trimmed.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
        let head = String(parts[0]).lowercased()
        guard let verb = Verb(rawValue: head) else {
            return DeskPaletteQuery(verb: nil, query: trimmed)
        }
        let rest = parts.count > 1
            ? String(parts[1]).trimmingCharacters(in: .whitespacesAndNewlines)
            : ""
        return DeskPaletteQuery(verb: verb, query: rest)
    }
}

public enum DeskPaletteCommandApplication {
    public enum Resolution: Equatable, Sendable {
        case dispatch(DeskQuickAction)
        case beginDefer(handle: String)
        case beginNote(handle: String)
        case refused(String)
    }

    public static let actionInFlightMessage = "Another Desk action is still in progress."

    public static func resolve(
        verb: DeskPaletteQuery.Verb,
        handle rawHandle: String,
        activeItems: [DeskItem]
    ) -> Resolution {
        let handle = rawHandle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !handle.isEmpty else {
            return .refused("Palette command was not applied: no Desk item was selected.")
        }
        guard let item = activeItems.first(where: { $0.handle == handle }) else {
            return .refused("Palette command was not applied: that item is no longer active.")
        }
        switch verb {
        case .close:
            let expectedUpdatedAt = item.updatedAt.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !expectedUpdatedAt.isEmpty else {
                return .refused(
                    "Palette command was not applied: the item's current version is unavailable."
                )
            }
            return .dispatch(.closeIfCurrent(
                handle: handle,
                outcome: DeskQuickAction.deskCloseOutcome,
                expectedUpdatedAt: expectedUpdatedAt
            ))
        case .deferItem:
            // Choosing Defer only opens its date choices. It has not changed
            // the store yet, so calling it successful here would be a lie.
            return .beginDefer(handle: handle)
        case .note:
            // Likewise, the note is not an effect until non-empty text is
            // submitted through DeskQuickAction.note.
            return .beginNote(handle: handle)
        }
    }
}

public enum DeskRefAction: Equatable, Sendable {
    case open(url: String, label: String)
    case copy(text: String, label: String)

    public var label: String {
        switch self {
        case .open(_, let label): return label
        case .copy(_, let label): return label
        }
    }

    public var opensExternally: Bool {
        if case .open = self { return true }
        return false
    }
}

public enum DeskRefAffordance {
    public static func action(for ref: DeskRef) -> DeskRefAction {
        switch ref.kind {
        case let .ghPr(repo, number, title, _, _):
            return .open(
                url: "https://github.com/\(repo)/pull/\(number)",
                label: title?.isEmpty == false ? title! : "\(repo) #\(number)")
        case let .ghIssue(repo, number, title, _):
            return .open(
                url: "https://github.com/\(repo)/issues/\(number)",
                label: title?.isEmpty == false ? title! : "\(repo) #\(number)")
        case let .url(url, title):
            return .open(url: url, label: title?.isEmpty == false ? title! : url)
        case let .commit(sha, repo, label, _):
            if let repo, !repo.isEmpty {
                return .open(
                    url: "https://github.com/\(repo)/commit/\(sha)",
                    label: label?.isEmpty == false ? label! : String(sha.prefix(8)))
            }
            return .copy(text: sha, label: label?.isEmpty == false ? label! : String(sha.prefix(8)))
        case let .file(path, line, label):
            let text = line.map { "\(path):\($0)" } ?? path
            return .copy(text: text, label: label?.isEmpty == false ? label! : text)
        case let .agent(name, handoffId, sessionId):
            return .copy(text: handoffId ?? sessionId ?? name, label: name)
        case let .approval(id, _):
            return .copy(text: id, label: "approval \(id.prefix(8))")
        case let .trace(id, kind):
            return .copy(text: id, label: kind.map { "\($0) \(id.prefix(8))" } ?? "trace \(id.prefix(8))")
        case let .note(text):
            return .copy(text: text, label: text)
        case let .step(step):
            return .copy(text: step.words, label: "queued " + step.when)
        }
    }
}

extension DeskProjection {
    public static func parseTimestamp(_ raw: String) -> Date? {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        return (try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(trimmed))
            ?? (try? Date.ISO8601FormatStyle().parse(trimmed))
    }
}

public enum DeskQuickAction: Equatable, Sendable {
    case close(handle: String, outcome: String)
    /// Palette closes bind to the row version observed while resolving the
    /// palette result. A later change must refuse at the store boundary rather
    /// than let Enter acknowledge a different row state as this close.
    case closeIfCurrent(handle: String, outcome: String, expectedUpdatedAt: String)
    case setStatus(handle: String, status: DeskStatus)
    case defer_(handle: String, until: String?)
    case note(handle: String, text: String)
    case nagGlobal(on: Bool)
    case nagProject(project: String, on: Bool)
    case nagItem(handle: String, on: Bool)
    case nagMute(until: String?)
    case nagUnmute

    /// The default outcome summary for a one-keystroke close. `desk_close`
    /// REFUSES an empty `outcome_summary`, and the honest thing to record is
    /// where the close came from — not an invented outcome.
    public static let deskCloseOutcome = "Closed from the desk."

    public var tool: String {
        switch self {
        case .close, .closeIfCurrent: return "desk_close"
        case .setStatus: return "desk_set_status"
        case .defer_: return "desk_defer"
        case .note: return "desk_note"
        case .nagGlobal, .nagProject, .nagItem, .nagMute, .nagUnmute: return "desk_nag_control"
        }
    }

    public var input: [String: JSONValue] {
        switch self {
        case let .close(handle, outcome):
            return ["handle": .string(handle), "outcome_summary": .string(outcome)]
        case let .closeIfCurrent(handle, outcome, expectedUpdatedAt):
            return [
                "handle": .string(handle),
                "outcome_summary": .string(outcome),
                "expected_updated_at": .string(expectedUpdatedAt),
            ]
        case let .setStatus(handle, status):
            return ["handle": .string(handle), "status": .string(status.rawValue)]
        case let .defer_(handle, until):
            // An EMPTY `until` is how desk_defer clears a park — the same
            // encoding the chat tool documents, not a second convention.
            return ["handle": .string(handle), "until": .string(until ?? "")]
        case let .note(handle, text):
            return ["handle": .string(handle), "text": .string(text)]
        case let .nagGlobal(on):
            return ["action": .string(on ? "enable" : "disable"), "scope_kind": .string("global")]
        case let .nagProject(project, on):
            return [
                "action": .string(on ? "enable" : "disable"),
                "scope_kind": .string("project"),
                "scope_id": .string(project),
            ]
        case let .nagItem(handle, on):
            return [
                "action": .string(on ? "enable" : "disable"),
                "scope_kind": .string("item"),
                "scope_id": .string(handle),
            ]
        case let .nagMute(until):
            var input: [String: JSONValue] = ["action": .string("mute")]
            if let until, !until.isEmpty { input["until"] = .string(until) }
            return input
        case .nagUnmute:
            return ["action": .string("unmute")]
        }
    }

}

extension DeskProjection {
    public static func needsEyes(_ item: DeskItem) -> Bool {
        item.status == .blocked || item.status == .flag || (item.waitingOn?.isEmpty == false)
    }
}

extension DeskProjection {
    public static let staleThresholdDays = 7

    public static func freshness(_ item: DeskItem, now: Date) -> (date: Date?, days: Int, isStale: Bool) {
        guard let date = parseTimestamp(item.updatedAt) else { return (nil, 0, false) }
        let days = Int(max(0, now.timeIntervalSince(date)) / 86_400)
        let stale = days >= staleThresholdDays
            && item.status != .blocked && item.status != .flag && !item.status.isTerminal
        return (date, days, stale)
    }
}
