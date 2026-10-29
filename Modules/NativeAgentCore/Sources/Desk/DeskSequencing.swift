import NativeAgentShared
import Foundation
import PersistenceCore

// Blueprint: | `DeskSequencing.swift` | `DeskSequencing.compute`: derived blockedness, cycles and subtree plans from stored edges; unblocking never writes a separate operation |

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
        /// was archived, or simply isn't in live state DOES NOT BLOCK. An exp:
        /// condition blocks until its settlement is written back (MyQueueReady.release).
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
        public var children: [String?: [DeskItem]]
        /// Ready handles, desk-wide, best-first. Capped at `nextUpCap`.
        /// Derived from dependency edges + status + creation time — there is
        /// deliberately NO manual rank field anywhere in the Desk.
        public var nextUp: [String]

        public init(byHandle: [String: ItemPlan] = [:], nextUp: [String] = [], children: [String?: [DeskItem]] = [:]) {
            self.byHandle = byHandle
            self.nextUp = nextUp
            self.children = children
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

    /// A bare `yyyy-MM-dd` defers through that day in the Mac's zone; ISO stamps keep their time.
    public static func parseDeferStamp(_ raw: String) -> Date? {
        if let d = DeskClock.parseDay(raw) { return Calendar.autoupdatingCurrent.date(byAdding: .day, value: 1, to: d) }
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
        let children = Dictionary(grouping: items, by: \.parent)
        var byHandle: [String: DeskItem] = [:]
        byHandle.reserveCapacity(items.count)
        for item in items { byHandle[item.handle] = item }

        // A blocker only blocks while it is LIVE and NON-TERMINAL. Absent from
        // live state (archived, never existed, aged out) → does not block. THIS
        // is the cascade. An experience condition blocks until its release is
        // written onto the item, so every reader of the Desk sees the same wait.
        func blocks(_ handle: String) -> Bool {
            if handle.hasPrefix("exp:") { return true }
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

        // An item is not actionable while an ANCESTOR is deferred, effectively
        // blocked, or waiting on owner input.
        // Cycle-safe: parent chains can loop in a hand-authored feed.
        func ancestorObstructs(_ handle: String) -> Bool {
            var seen: Set<String> = [handle]
            var current = byHandle[handle]?.parent
            var depth = 0
            while let cur = current, depth < deskMaxGraphDepth, seen.insert(cur).inserted {
                depth += 1
                guard let ancestor = byHandle[cur] else { return false }
                if ancestor.status == .blocked || ancestor.requiresOwnerInput || ancestor.blockedReason?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false { return true }
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
            let descendants = SwiftNativeDeskStore.descendants(of: item.handle, in: children, maxDepth: deskMaxGraphDepth)
            let ready = !item.status.isTerminal && item.status != .blocked
                && !item.requiresOwnerInput
                && item.blockedReason?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false
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
                doneCount: descendants.filter { $0.status.isTerminal }.count,
                totalCount: descendants.count
            )
        }

        // nextUp: status rank, then blocker count, then openedAt, then alias seq.
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
        return Plan(byHandle: plans, nextUp: Array(ordered.prefix(nextUpCap).map(\.handle)), children: children)
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
            for next in effectiveBlockers[node] ?? [] where !next.hasPrefix("exp:") {
                visit(next, depth: depth + 1)
            }
            onStack.remove(node)
            stackOrder.removeLast()
        }

        for item in items { visit(item.handle, depth: 0) }
        return cyclic
    }

}
