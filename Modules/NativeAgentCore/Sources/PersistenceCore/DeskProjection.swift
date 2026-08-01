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
// TOP-LEVEL ITEM (alias order)
//   `<alias> <token2> <project> · <title>[ · <summary>][ · <now|next child>]`
//   `[ · refs:N][ · stale:<dur>][ · archives in <dur>][ · <level>/event]`
//   • token2 = the STATUS, except when status is the neutral default `.watch`,
//     where the KIND renders instead (reconciles the build plan's literal
//     `<status>` with its ground-truth sample, where a freshly-created plan/gh
//     item shows its kind, and an explicitly-stated status — now/next/done/… —
//     shows the status). Children always render the status.
//   • child highlight: the most-actionable active child (a `now` child wins over
//     a `next` child) collapses inline as `<status> <title>`.
//   • children LIST (indented two spaces) renders only when the item has ≥2
//     children; a single child stays collapsed in the highlight.
//   • one optional note line renders only for a high-signal item (status blocked
//     or flag) with a latest note: `  note: <text>`.
//
// CAPS: ≤25 top-level live items; among TERMINAL (done + canceled) show ≤3
// most-recent; refs
// summarized as `refs:N` (the optional inline form is not rendered — priority
// ordering is exposed via DeskItem.liveRefs for consumers); per-item live render
// ≤3 refs in priority order.

public enum DeskProjection {

    public static let topLevelCap = 25
    public static let doneCap = 3

    public static func render(
        _ state: DeskState,
        now: Date = Date(),
        archiveGrace: TimeInterval = SwiftNativeDeskStore.defaultArchiveGrace
    ) -> String {
        var lines: [String] = []
        lines.append("desk · owner · rev \(state.generatedTs) · stale ok")
        lines.append("status: watch · flag · now · next · todo · done · blocked")

        for item in cappedTopLevel(state) {
            lines.append(renderTopLevel(item, in: state, now: now, archiveGrace: archiveGrace))
            if let note = noteLine(item) { lines.append(note) }
            // Children list only when the item has ≥2 children.
            // List children when there are ≥2, OR a lone child the parent line's
            // now/next highlight does NOT already surface — so a single
            // blocked/todo child is never hidden, but a single now/next child
            // collapsed inline isn't duplicated (gpt-5.5 review + Agent's sample,
            // where item 4's single `next` child shows only in the highlight).
            let kids = state.children(of: item.handle)
            let listKids = kids.count >= 2 || (kids.count == 1 && childHighlight(item, in: state) == nil)
            if listKids {
                for kid in kids.sorted(by: { SwiftNativeDeskStore.aliasSeq($0.alias) < SwiftNativeDeskStore.aliasSeq($1.alias) }) {
                    lines.append("  \(kid.alias) \(kid.status.rawValue) \(kid.title)")
                }
            }
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - Top-level selection + caps

    /// Top-level items in alias order, with the terminal-cap and 25-item cap
    /// applied.
    ///
    /// The recency cap counts TERMINAL items (done AND canceled), not `.done`
    /// alone. Canceled rows are closed work with the same zero live signal as
    /// done rows; when only `.done` was capped, canceled top-level items were
    /// unbounded here, sat at the lowest aliases, and `prefix(topLevelCap)`
    /// filled with them until live work fell off the desk entirely.
    static func cappedTopLevel(_ state: DeskState) -> [DeskItem] {
        let top = state.topLevel  // already in alias order from compact
        // Keep all non-terminal; among terminal keep the ≤3 most-recent (by closedAt).
        let terminal = top.filter { $0.status.isTerminal }
        let keepTerminal: Set<String>
        if terminal.count > doneCap {
            let recent = terminal.sorted { ($0.closedAt ?? $0.updatedAt) > ($1.closedAt ?? $1.updatedAt) }.prefix(doneCap)
            keepTerminal = Set(recent.map { $0.handle })
        } else {
            keepTerminal = Set(terminal.map { $0.handle })
        }
        let filtered = top.filter { !$0.status.isTerminal || keepTerminal.contains($0.handle) }
        return Array(filtered.prefix(topLevelCap))
    }

    // MARK: - One top-level line

    static func renderTopLevel(_ item: DeskItem, in state: DeskState, now: Date, archiveGrace: TimeInterval) -> String {
        let token2 = (item.status == .watch) ? item.kind.rawValue : item.status.rawValue
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
        if let highlight = childHighlight(item, in: state) {
            segs.append(highlight)
        }
        // refs:N only when 3+ (0–2 stay off the compact line; the full set lives
        // in the store + tab). gpt-5.5 review: spec is ">= 3", was rendering
        // refs:1 / refs:2.
        if item.refs.count >= 3 {
            segs.append("refs:\(item.refs.count)")
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
    static func childHighlight(_ item: DeskItem, in state: DeskState) -> String? {
        let kids = state.children(of: item.handle)
            .sorted { SwiftNativeDeskStore.aliasSeq($0.alias) < SwiftNativeDeskStore.aliasSeq($1.alias) }
        if let nowChild = kids.first(where: { $0.status == .now }) {
            return "now \(nowChild.title)"
        }
        if let nextChild = kids.first(where: { $0.status == .next }) {
            return "next \(nextChild.title)"
        }
        return nil
    }

    /// One high-signal note line, only for a blocked/flagged item with a note.
    static func noteLine(_ item: DeskItem) -> String? {
        guard item.status == .blocked || item.status == .flag, let last = item.notes.last else { return nil }
        return "  note: \(last.text)"
    }

    // MARK: - Staleness / archive countdown

    /// `stale:<dur>` when the item's cadence.lastRefreshAt is older than its
    /// staleAfter window. nil when no lastRefreshAt / staleAfter, or still fresh.
    static func staleSegment(_ item: DeskItem, now: Date) -> String? {
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
