import NativeAgentShared
import Foundation
import NativeAgentCore
import PersistenceCore
// Blueprint: | `DeskText.swift` | `DeskPage`: compact board and exact-record text, sequencing segments, duration and archive presentation |

// MARK: - DeskPage — pure DeskState -> compact text renderer
// State is authoritative; inject now so presentation ages consistently.

public enum DeskPage {

    public static let topLevelCap = 25
    public static let doneCap = 3

    public static let blockedOnAliasCap = 3

    public static func render(
        _ state: DeskState,
        now: Date = Date(),
        archiveGrace: TimeInterval = SwiftNativeDeskStore.defaultArchiveGrace
    ) -> String {
        let plan = DeskSequencing.compute(state, now: now)
        var lines: [String] = []
        lines.append("desk · owner · rev \(state.generatedTs) · stale ok")
        lines.append("status: " + DeskStatus.allCases.map(\.displayLabel).joined(separator: " · ")
            + " · held (derived: now/next that is blocked or deferred)")

        for item in cappedTopLevel(plan.children) {
            lines.append(renderTopLevel(item, in: state, now: now, archiveGrace: archiveGrace, plan: plan))
            if let note = noteLine(item) { lines.append(note) }
            let kids = plan.children[item.handle] ?? []
            let listKids = kids.count >= 2 || (kids.count == 1 && childHighlight(item, plan: plan) == nil)
            if listKids {
                for kid in kids.sorted(by: { SwiftNativeDeskStore.aliasSeq($0.alias) < SwiftNativeDeskStore.aliasSeq($1.alias) }) {
                    var kidSegs = ["  \(kid.alias) \(kid.status == .watch ? kid.status.rawValue : statusToken(kid, plan: plan)) \(kid.title)"]
                    kidSegs.append(contentsOf: sequencingSegments(kid, in: state, plan: plan, includeRollup: false))
                    lines.append(kidSegs.joined(separator: " · "))
                }
            }
        }

        // Present view-local aliases, never internal handles.
        let nextUp = plan.nextUp.compactMap { h in state.items.first { $0.handle == h } }
        if !nextUp.isEmpty {
            lines.append("next up:")
            for item in nextUp {
                lines.append("  \(item.alias) \(item.statusDescription) \(item.title)")
            }
        }
        return lines.joined(separator: "\n")
    }

    static func statusToken(_ item: DeskItem, plan: DeskSequencing.Plan) -> String {
        if !item.status.isTerminal, item.waitingOn?.isEmpty == false { return item.statusDescription }
        let base = (item.status == .watch) ? item.kind.rawValue : item.status.rawValue
        guard item.status == .now || item.status == .next,
              let itemPlan = plan.byHandle[item.handle], !itemPlan.isReady else { return base }
        return "held"
    }

    // MARK: - Sequencing segments (blocked-on / deferred / cycle / rollup)

    public static func sequencingSegments(
        _ item: DeskItem,
        in state: DeskState,
        plan: DeskSequencing.Plan,
        includeRollup: Bool
    ) -> [String] {
        guard let itemPlan = plan.byHandle[item.handle] else { return [] }
        var segs: [String] = []
        if includeRollup, itemPlan.totalCount > 0 {
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

    /// Cap recent closed rows across both done and canceled work because each has zero live signal.
    public static func cappedTopLevel(_ children: [String?: [DeskItem]]) -> [DeskItem] {
        let top = children[nil] ?? []
        let open = top.filter { !$0.status.isTerminal }
            .map { (item: $0, active: lastActive($0, in: children)) }
            .sorted { $0.active != $1.active ? $0.active > $1.active : $0.item.handle < $1.item.handle }
            .map(\.item)
        let closed = top.filter { $0.status.isTerminal }
            .sorted { ($0.closedAt ?? $0.updatedAt) > ($1.closedAt ?? $1.updatedAt) }
            .prefix(doneCap)
        return Array((open + closed).prefix(topLevelCap))
    }

    /// Descendant activity keeps a parent active even without a direct touch.
    public static func lastActive(_ item: DeskItem, in children: [String?: [DeskItem]]) -> String {
        SwiftNativeDeskStore.descendants(of: item.handle, in: children).map(\.updatedAt).max()
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
        if let highlight = childHighlight(item, plan: plan) {
            segs.append(highlight)
        }
        segs.append(contentsOf: sequencingSegments(item, in: state, plan: plan, includeRollup: true))
        if item.refs.count >= 3 {
            segs.append("refs:\(item.refs.count)")
        }
        if let stale = staleSegment(item, now: now) {
            segs.append(stale)
        }
        if let archives = archiveCountdown(item, in: plan.children, now: now, archiveGrace: archiveGrace) {
            segs.append(archives)
        }
        if item.cadence.mode == .event {
            segs.append("\(item.notify.level.rawValue)/event")
        }
        return segs.joined(separator: " · ")
    }

    static func childHighlight(_ item: DeskItem, plan: DeskSequencing.Plan) -> String? {
        let kids = (plan.children[item.handle] ?? []).filter { plan.byHandle[$0.handle]?.isReady ?? true }
            .sorted { SwiftNativeDeskStore.aliasSeq($0.alias) < SwiftNativeDeskStore.aliasSeq($1.alias) }
        if let nowChild = kids.first(where: { $0.status == .now }) {
            return "now \(nowChild.title)"
        }
        if let nextChild = kids.first(where: { $0.status == .next }) {
            return "next \(nextChild.title)"
        }
        return nil
    }

    static func noteLine(_ item: DeskItem) -> String? {
        guard let last = item.notes.last else { return nil }
        guard item.status == .blocked || item.status == .flag else { return nil }
        return "  note: \(last.text)"
    }

    // MARK: - Staleness / archive countdown

    static func staleSegment(_ item: DeskItem, now: Date) -> String? {
        // Deferred work suppresses staleness consistently across callers.
        guard !DeskSequencing.isDeferred(item, now: now) else { return nil }
        guard let lastRaw = item.cadence.lastRefreshAt,
              let last = DeskClock.parseISO(lastRaw),
              let staleAfter = item.cadence.staleAfter,
              let threshold = parseDuration(staleAfter) else { return nil }
        let elapsed = now.timeIntervalSince(last)
        guard elapsed > threshold else { return nil }
        return "stale:\(humanDuration(elapsed))"
    }

    /// Eligibility does not archive work; archival remains explicit.
    static func archiveCountdown(_ item: DeskItem, in children: [String?: [DeskItem]], now: Date, archiveGrace: TimeInterval) -> String? {
        guard item.status.isTerminal, item.kind != .standing, !item.pinned,
              item.continuation?.pending.isEmpty ?? true,
              let closedRaw = item.closedAt, let closed = DeskClock.parseISO(closedRaw) else { return nil }
        guard !SwiftNativeDeskStore.descendants(of: item.handle, in: children).contains(where: {
            $0.kind == .standing || !$0.status.isTerminal || !($0.continuation?.pending.isEmpty ?? true)
        }) else { return nil }
        let remaining = archiveGrace - now.timeIntervalSince(closed)
        return remaining > 0 ? "archive eligible in \(humanDuration(remaining))" : "archive eligible"
    }

    // MARK: - Duration helpers

    /// Round to the nearest unit so ISO drift cannot tip a boundary down by a millisecond.
    static func humanDuration(_ seconds: TimeInterval) -> String {
        let s = max(0, seconds)
        if s < 3600 { return String(format: "%.0f", (s / 60).rounded()) + "m" }
        if s < 86_400 { return String(format: "%.0f", (s / 3600).rounded()) + "h" }
        return String(format: "%.0f", (s / 86_400).rounded()) + "d"
    }

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

public extension DeskPage {
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

        lines.append("record \(item.alias) · \(item.kind.rawValue) · \(item.statusDescription)")
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

        // Reverse edges reveal who waits on this item, which its own dependencies cannot show.
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
                lines.append("    \(dep.alias) \(dep.statusDescription) \(dep.title)")
            }
        }
        let kids = state.children(of: item.handle)
            .sorted { SwiftNativeDeskStore.aliasSeq($0.alias) < SwiftNativeDeskStore.aliasSeq($1.alias) }
        if !kids.isEmpty {
            lines.append("  parts:")
            for kid in kids {
                lines.append("    \(kid.alias) \(kid.statusDescription) \(kid.title)")
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

    /// Render identity first so stale cached labels cannot hide the actual destination.
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
                + (step.actionText.map { " · habit \($0)" } ?? "")
                + (step.source.map { " · inferred from \"\($0)\"" } ?? "")
                + (step.peers + step.elevated).map { " · from \($0)'s turn" }.joined()
        }
    }
}
