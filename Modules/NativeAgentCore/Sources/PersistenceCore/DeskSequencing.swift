import Foundation

// MARK: - DeskSequencing — the "what's next" derivation (PURE, never stored)
//
// The Desk answers "what exists"; this answers "what's next".
//
// THE LOAD-BEARING DECISION: blockedness is COMPUTED from the stored edge set on
// every read. Nothing here is persisted, and no op is ever written to "unblock"
// an item. That is the whole auto-unblock cascade: when a blocker reaches a
// terminal status (or is archived out of live state), every dependent becomes
// ready on the very next read — with no writer running, no background loop, and
// no op to fire. A derived `isBlocked` FIELD on DeskItem would have to be
// maintained by a writer and would rot exactly the way `blockedReason` prose
// rots. So: edges are stored, blockedness is derived.
//
// Everything here is pure and deterministic — `now` is injected, no wall clock
// is read inside — so the projection and its tests are reproducible.
//
// CYCLE SAFETY IS MANDATORY, not defensive politeness. The write path
// (SwiftNativeDeskStore.validateBlockedOn) refuses an edge that closes a cycle,
// but a hand-authored feed, a legacy feed, or another process sharing the flock
// can still put one on disk. A hang here would freeze EVERY desk_read, so both
// graph walks (blocked-on edges and parent chains) carry a visited set AND a
// depth cap.

/// Defensive traversal bound for both the blocked-on graph and parent chains.
/// Far above any real desk; it exists so a pathological feed degrades into a
/// wrong-but-finite answer instead of a hang.
let deskMaxGraphDepth = 512

public enum DeskSequencing {

    /// The derived sequencing facts for one item.
    public struct ItemPlan: Sendable, Equatable {
        public var handle: String
        /// Live, NON-TERMINAL blockers only. A blocker that closed, was canceled,
        /// was archived, or simply isn't in live state DOES NOT BLOCK.
        public var effectiveBlockers: [String]
        /// `deferUntil` parses AND is strictly in the future.
        public var isDeferred: Bool
        public var isReady: Bool
        /// This item sits ON a cycle in the blocked-on graph — unresolvable, so
        /// never ready, and surfaced in the projection rather than hidden.
        public var blockedByCycle: Bool
        /// Whole descendant subtree (all depths), self EXCLUDED.
        public var doneCount: Int
        public var totalCount: Int

        public init(
            handle: String,
            effectiveBlockers: [String] = [],
            isDeferred: Bool = false,
            isReady: Bool = false,
            blockedByCycle: Bool = false,
            doneCount: Int = 0,
            totalCount: Int = 0
        ) {
            self.handle = handle
            self.effectiveBlockers = effectiveBlockers
            self.isDeferred = isDeferred
            self.isReady = isReady
            self.blockedByCycle = blockedByCycle
            self.doneCount = doneCount
            self.totalCount = totalCount
        }
    }

    public struct Plan: Sendable, Equatable {
        public var byHandle: [String: ItemPlan]
        /// Ready handles, desk-wide, best-first. Capped at `nextUpCap`.
        /// Derived from dependency edges + status + creation time — there is
        /// deliberately NO manual rank field anywhere in the Desk.
        public var nextUp: [String]

        public init(byHandle: [String: ItemPlan] = [:], nextUp: [String] = []) {
            self.byHandle = byHandle
            self.nextUp = nextUp
        }
    }

    public static let nextUpCap = 5

    /// Status ordering for `nextUp`: the operator's own triage vocabulary is the
    /// rank. now > next > flag > todo > watch > anything else.
    static func statusRank(_ status: DeskStatus) -> Int {
        switch status {
        case .now: return 0
        case .next: return 1
        case .flag: return 2
        case .todo: return 3
        case .watch: return 4
        default: return 5
        }
    }

    /// True when `item.deferUntil` parses AND is strictly after `now`.
    ///
    /// An UNPARSEABLE value is treated as NOT deferred. Parking an item forever
    /// because someone typed a bad date is the worse failure: it would vanish
    /// silently from `nextUp` and be suppressed from staleness at the same time.
    public static func isDeferred(_ item: DeskItem, now: Date) -> Bool {
        guard let raw = item.deferUntil?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty,
              let until = parseDeferStamp(raw) else { return false }
        return until > now
    }

    /// Parse a defer stamp: a bare `yyyy-MM-dd` UTC day (which means the END of
    /// that day — an item parked "until 2026-08-05" is still parked during the
    /// 5th) or a full ISO timestamp.
    static func parseDeferStamp(_ raw: String) -> Date? {
        let day = DateFormatter()
        day.locale = Locale(identifier: "en_US_POSIX")
        day.timeZone = TimeZone(identifier: "UTC")
        day.dateFormat = "yyyy-MM-dd"
        if let d = day.date(from: raw) { return d.addingTimeInterval(86_400) }
        return DeskClock.parseISO(raw)
    }

    /// The `yyyy-MM-dd` day a defer stamp lands on, for display. nil if
    /// unparseable.
    public static func deferDisplayDay(_ raw: String) -> String? {
        DeskClock.normalizedDay(raw.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    // MARK: - compute

    public static func compute(_ state: DeskState, now: Date = Date()) -> Plan {
        let items = state.items
        var byHandle: [String: DeskItem] = [:]
        byHandle.reserveCapacity(items.count)
        for item in items { byHandle[item.handle] = item }

        // A blocker only blocks while it is LIVE and NON-TERMINAL. Absent from
        // live state (archived, never existed, aged out) → does not block. THIS
        // is the cascade.
        func blocks(_ handle: String) -> Bool {
            guard let item = byHandle[handle] else { return false }
            return !item.status.isTerminal
        }

        var effectiveBlockers: [String: [String]] = [:]
        var deferred: [String: Bool] = [:]
        for item in items {
            effectiveBlockers[item.handle] = item.blockedOn.filter { $0 != item.handle && blocks($0) }
            deferred[item.handle] = isDeferred(item, now: now)
        }

        let onCycle = cycleNodes(in: items, effectiveBlockers: effectiveBlockers)

        // Children index for the subtree rollup.
        var childrenOf: [String: [String]] = [:]
        for item in items {
            guard let parent = item.parent, byHandle[parent] != nil else { continue }
            childrenOf[parent, default: []].append(item.handle)
        }

        // An item is not actionable while an ANCESTOR is deferred or effectively
        // blocked — you can't start a child of a parked or blocked parent.
        // Cycle-safe: parent chains can loop in a hand-authored feed.
        func ancestorObstructs(_ handle: String) -> Bool {
            var seen: Set<String> = [handle]
            var current = byHandle[handle]?.parent
            var depth = 0
            while let cur = current, depth < deskMaxGraphDepth, seen.insert(cur).inserted {
                depth += 1
                guard let ancestor = byHandle[cur] else { return false }
                if deferred[cur] == true { return true }
                if !(effectiveBlockers[cur] ?? []).isEmpty { return true }
                if onCycle.contains(cur) { return true }
                current = ancestor.parent
            }
            return false
        }

        var plans: [String: ItemPlan] = [:]
        plans.reserveCapacity(items.count)
        for item in items {
            let blockers = effectiveBlockers[item.handle] ?? []
            let isDef = deferred[item.handle] ?? false
            let cyc = onCycle.contains(item.handle)
            let rollup = subtreeRollup(item.handle, childrenOf: childrenOf, byHandle: byHandle)
            let ready = !item.status.isTerminal
                && blockers.isEmpty
                && !isDef
                && !cyc
                && !ancestorObstructs(item.handle)
            plans[item.handle] = ItemPlan(
                handle: item.handle,
                effectiveBlockers: blockers,
                isDeferred: isDef,
                isReady: ready,
                blockedByCycle: cyc,
                doneCount: rollup.done,
                totalCount: rollup.total
            )
        }

        // nextUp: status rank, then blocker count, then openedAt, then alias seq.
        // No manual rank field — dependency edges + creation time is enough
        // (Agent's #4).
        let ready = items.filter { plans[$0.handle]?.isReady == true }
        let ordered = ready.sorted { a, b in
            let ra = statusRank(a.status), rb = statusRank(b.status)
            if ra != rb { return ra < rb }
            let ba = plans[a.handle]?.effectiveBlockers.count ?? 0
            let bb = plans[b.handle]?.effectiveBlockers.count ?? 0
            if ba != bb { return ba < bb }
            if a.openedAt != b.openedAt { return a.openedAt < b.openedAt }
            let sa = SwiftNativeDeskStore.aliasSeq(a.alias), sb = SwiftNativeDeskStore.aliasSeq(b.alias)
            if sa != sb { return sa < sb }
            return a.handle < b.handle
        }
        return Plan(byHandle: plans, nextUp: Array(ordered.prefix(nextUpCap).map(\.handle)))
    }

    // MARK: - Graph internals

    /// Every node that sits ON a cycle in the effective blocked-on graph.
    ///
    /// Memoized iterative-free DFS with an ON-STACK set: when an edge lands on a
    /// node that is currently on the stack, the whole stack suffix from that node
    /// is a cycle and is marked. The visited set guarantees each node is expanded
    /// once, so the walk TERMINATES on any input; the depth cap is the second
    /// belt for a pathologically deep (non-cyclic) chain.
    static func cycleNodes(in items: [DeskItem], effectiveBlockers: [String: [String]]) -> Set<String> {
        var visited: Set<String> = []
        var onStack: Set<String> = []
        var stackOrder: [String] = []
        var cyclic: Set<String> = []

        func visit(_ node: String, depth: Int) {
            guard depth <= deskMaxGraphDepth else { return }
            if onStack.contains(node) {
                // Mark the suffix of the current path starting at `node`.
                if let idx = stackOrder.lastIndex(of: node) {
                    for n in stackOrder[idx...] { cyclic.insert(n) }
                }
                return
            }
            if visited.contains(node) {
                // Already fully expanded. If it was found cyclic, a node feeding
                // INTO it is not itself on that cycle — only reachability, which
                // the effective-blocker check already handles.
                return
            }
            visited.insert(node)
            onStack.insert(node)
            stackOrder.append(node)
            for next in effectiveBlockers[node] ?? [] {
                visit(next, depth: depth + 1)
            }
            onStack.remove(node)
            stackOrder.removeLast()
        }

        for item in items { visit(item.handle, depth: 0) }
        return cyclic
    }

    /// (done, total) over the item's WHOLE descendant subtree, self excluded.
    /// Everything in `byHandle` is live (archived items are not in DeskState), so
    /// "non-archived" is the whole set. Cycle-safe via a visited set.
    static func subtreeRollup(
        _ handle: String,
        childrenOf: [String: [String]],
        byHandle: [String: DeskItem]
    ) -> (done: Int, total: Int) {
        var done = 0
        var total = 0
        var seen: Set<String> = [handle]
        var frontier = childrenOf[handle] ?? []
        var depth = 0
        while !frontier.isEmpty, depth < deskMaxGraphDepth {
            depth += 1
            var next: [String] = []
            for child in frontier {
                guard seen.insert(child).inserted, let item = byHandle[child] else { continue }
                total += 1
                if item.status.isTerminal { done += 1 }
                next.append(contentsOf: childrenOf[child] ?? [])
            }
            frontier = next
        }
        return (done, total)
    }
}
