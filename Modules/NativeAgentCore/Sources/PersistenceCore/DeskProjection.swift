import Foundation

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
//   `[ · refs:N][ · ⚑ drift:<kind>][ · stale:<dur>][ · archives in <dur>]`
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
        archiveGrace: TimeInterval = SwiftNativeDeskStore.defaultArchiveGrace,
        plan injectedPlan: DeskSequencing.Plan? = nil
    ) -> String {
        // The plan is DERIVED here so every existing call site keeps working and
        // automatically gains the sequencing segments; it is injectable purely so
        // tests can pin a plan without reconstructing state.
        let plan = injectedPlan ?? DeskSequencing.compute(state, now: now)
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
        if item.origin == .agent {
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
        // Terminal, not `.done` alone — canceled rows are swept on the same
        // grace clock (archiveSweep), so they get the same countdown.
        if item.status.isTerminal, let archives = archiveCountdown(item, now: now, archiveGrace: archiveGrace) {
            segs.append(archives)
        }
        if item.cadence.mode == .event {
            segs.append("\(item.notify.level.rawValue)/event")
        }
        return segs.joined(separator: " · ")
    }

    /// The most-actionable active child collapsed inline (`now` wins over
    /// `next`). nil when no now/next child exists.
    static func childHighlight(_ item: DeskItem, in state: DeskState, plan: DeskSequencing.Plan? = nil) -> String? {
        let kids = state.children(of: item.handle)
            .sorted { SwiftNativeDeskStore.aliasSeq($0.alias) < SwiftNativeDeskStore.aliasSeq($1.alias) }
        // "the most-actionable active child" — a held child is not actionable,
        // so it cannot be the one the parent line advertises (lane1 finding 5).
        func startable(_ kid: DeskItem) -> Bool {
            guard let plan else { return true }
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

    /// `archives in <dur>` for a done item still inside its grace window.
    static func archiveCountdown(_ item: DeskItem, now: Date, archiveGrace: TimeInterval) -> String? {
        guard !item.pinned, let closedRaw = item.closedAt, let closed = DeskClock.parseISO(closedRaw) else { return nil }
        let remaining = archiveGrace - now.timeIntervalSince(closed)
        guard remaining > 0 else { return nil }
        return "archives in \(humanDuration(remaining))"
    }

    // MARK: - Duration helpers

    /// Compact human duration: < 1h → "<n>m", < 1d → "<n>h", else "<n>d".
    /// Rounds to the nearest unit so a value sitting on a bucket boundary (e.g.
    /// a full 48h grace window) renders cleanly and is robust to the sub-second
    /// drift of an ISO round-trip rather than tipping a day down by 1ms.
    static func humanDuration(_ seconds: TimeInterval) -> String {
        let s = max(0, seconds)
        if s < 3600 { return "\(Int((s / 60).rounded()))m" }
        if s < 86_400 { return "\(Int((s / 3600).rounded()))h" }
        return "\(Int((s / 86_400).rounded()))d"
    }

    /// Parse a duration string like "30m" / "2h" / "1d" into seconds.
    static func parseDuration(_ s: String) -> TimeInterval? {
        let trimmed = s.trimmingCharacters(in: .whitespaces)
        guard let unit = trimmed.last, let value = Int(trimmed.dropLast()) else { return nil }
        switch unit {
        case "s": return TimeInterval(value)
        case "m": return TimeInterval(value * 60)
        case "h": return TimeInterval(value * 3600)
        case "d": return TimeInterval(value * 86_400)
        default: return nil
        }
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
    /// Notes shown on a record before the older ones are counted instead.
    static var recordNoteCap: Int { 30 }

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
        }
    }
}
