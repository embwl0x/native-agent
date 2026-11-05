import NativeAgentShared
import Foundation
import PersistenceCore

// Blueprint: | `DeskSequencing.swift` | `DeskSequencing.compute`: blockedness derives from edges without unblocking writes |

// MARK: - DeskSequencing — the "what's next" derivation (PURE, never stored)
// Derive blockedness from stored edges so settlement releases dependents without a second writer.
// Inject now so every projection uses the same instant.
// Authored feeds can contain cycles despite write gates; bound both graph walks to keep reads responsive.

/// Bound pathological traversal so malformed feeds cannot hang every Desk read.
let deskMaxGraphDepth = 512

public enum DeskSequencing {

    public struct ItemPlan: Sendable, Equatable {
        public var handle: String
        /// Only live nonterminal Desk blockers bind; experience conditions wait for a durable release.
        public var effectiveBlockers: [String]
        public var isDeferred: Bool
        public var isReady: Bool
        /// Cyclic work is unresolvable and must stay visibly unready.
        public var blockedByCycle: Bool
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
        /// Dependency, status and creation time derive next-up order without a second persisted rank.
        public var nextUp: [String]

        public init(byHandle: [String: ItemPlan] = [:], nextUp: [String] = [], children: [String?: [DeskItem]] = [:]) {
            self.byHandle = byHandle
            self.nextUp = nextUp
            self.children = children
        }
    }

    public static let nextUpCap = 5

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

    /// Malformed defer dates cannot silently hide work from both next-up and staleness.
    public static func isDeferred(_ item: DeskItem, now: Date) -> Bool {
        guard let raw = item.deferUntil?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty,
              let until = parseDeferStamp(raw) else { return false }
        return until > now
    }

    /// A local day defers through its end; an ISO instant keeps its exact time.
    public static func parseDeferStamp(_ raw: String) -> Date? {
        if let d = DeskClock.parseDay(raw) { return Calendar.autoupdatingCurrent.date(byAdding: .day, value: 1, to: d) }
        return DeskClock.parseISO(raw)
    }

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

        // Experience waits require a durable release so every Desk reader observes the same condition.
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

        // Ancestor waits propagate to descendants; visited handles keep authored parent cycles finite.
        func ancestorObstructs(_ handle: String) -> Bool {
            var seen: Set<String> = [handle]
            var current = byHandle[handle]?.parent
            var depth = 0
            while let cur = current, depth < deskMaxGraphDepth, seen.insert(cur).inserted {
                depth += 1
                guard let ancestor = byHandle[cur] else { return false }
                if ancestor.status == .blocked || ancestor.requiresOwnerInput || ancestor.blockedReason?.trimmingCharacters(
                    in: .whitespacesAndNewlines).isEmpty == false { return true }
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

    /// Mark only the active-stack suffix when DFS closes a cycle.
    /// Visit each node once and cap depth so malformed graphs cannot hang a read.
    static func cycleNodes(in items: [DeskItem], effectiveBlockers: [String: [String]]) -> Set<String> {
        var visited: Set<String> = []
        var onStack: Set<String> = []
        var stackOrder: [String] = []
        var cyclic: Set<String> = []

        func visit(_ node: String, depth: Int) {
            guard depth <= deskMaxGraphDepth else { return }
            if onStack.contains(node) {
                if let idx = stackOrder.lastIndex(of: node) {
                    for n in stackOrder[idx...] { cyclic.insert(n) }
                }
                return
            }
            if visited.contains(node) {
                // Reaching a cyclic node does not place this caller on that cycle.
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
