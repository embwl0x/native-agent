import NativeAgentShared
import Darwin
import Foundation
import PersistenceCore
import NativeAgentCore
import Synchronization
// Blueprint: | `DeskDependencyTransitions.swift` | Dependencies, hierarchy settlement and locked revalidation |
extension SwiftNativeDeskStore {
    /// Replace the blocker set under the ops flock so validation cannot race a close.
    /// Reject unknown, self or cyclic Desk edges; timestamp inside the lock to preserve commit order.
    @discardableResult
    public func setBlockedOn(_ handle: String, blockers: [String], waiting: Bool = false, note: String? = nil) async throws -> DeskOp {
        try await SwiftNativePersistenceCore.withFileLock(opsPath) {
            let feed = try await readFeedUnlocked()
            let state = Self.compact(base: feed.base, feed.ops)
            guard let item = state.items.first(where: { $0.handle == handle }) else {
                throw DeskError.unknownHandle(handle)
            }
            let proposed = Self.normalizeBlockers(blockers)
            try Self.validateBlockedOn(handle: handle, proposed: proposed, in: state)
            var bodies: [DeskOpBody] = [.setBlockedOn(handles: proposed)]
            if waiting {
                bodies.append(.setStatus(status: item.status == .blocked ? .next : item.status,
                    blockedReason: nil, waitingOn: nil, progress: item.progress, assignee: item.assignee, laneOf: item.laneOf))
            }
            if let note { bodies.append(.appendNote(text: note, author: "agent")) }
            let ops = bodies.map { DeskOp(handle: handle, body: $0) }
            return try await commitUnlocked(ops, feed: feed).ops[0]
        }
    }
    /// Reject malformed defer dates because readers treat them as not deferred, making a write silently ineffective.
    @discardableResult
    public func setDeferUntil(_ handle: String, until: String?) async throws -> DeskOp {
        try await SwiftNativePersistenceCore.withFileLock(opsPath) {
            let feed = try await readFeedUnlocked()
            let state = Self.compact(base: feed.base, feed.ops)
            guard state.items.contains(where: { $0.handle == handle }) else {
                throw DeskError.unknownHandle(handle)
            }
            let trimmed = until?.trimmingCharacters(in: .whitespacesAndNewlines)
            let value: String? = (trimmed?.isEmpty == false) ? trimmed : nil
            if let value, !DeskClock.isParseableDate(value) {
                throw DeskError.deferUntilUnparseable(handle: handle, value: value)
            }
            let op = DeskOp(
                handle: handle,
                body: .setDeferUntil(until: value)
            )
            return try await commitUnlocked([op], feed: feed).ops[0]
        }
    }
    /// Preserve first-seen order so the stored set reads back as named.
    static func normalizeBlockers(_ raw: [String]) -> [String] {
        var seen: Set<String> = []
        var out: [String] = []
        for candidate in raw {
            let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, seen.insert(trimmed).inserted else { continue }
            out.append(trimmed)
        }
        return out
    }
    /// Remove settled waits under the lock so a concurrently committed wait survives.
    public func releaseBlockers(_ handle: String, removing settled: Set<String>, note: String, author: String) async throws {
        try await SwiftNativePersistenceCore.withFileLock(opsPath) {
            let feed = try await readFeedUnlocked()
            let state = Self.compact(base: feed.base, feed.ops)
            guard let item = state.items.first(where: { $0.handle == handle }),
                  item.blockedOn.contains(where: settled.contains) else { return }
            let ops = [
                DeskOp(handle: handle, body: .setBlockedOn(handles: item.blockedOn.filter { !settled.contains($0) })),
                DeskOp(handle: handle, body: .appendNote(text: note, author: author)),
            ]
            try await commitUnlocked(ops, feed: feed)
        }
    }
    /// Validate the prospective graph: every Desk blocker is live and no edge closes an unresolvable cycle.
    static func validateBlockedOn(handle: String, proposed: [String], in state: DeskState) throws {
        let liveHandles = Set(state.items.map(\.handle))
        for blocker in proposed {
            if blocker.hasPrefix("exp:"), blocker.count > 4 { continue }
            if blocker == handle { throw DeskError.blockedOnSelf(handle: handle) }
            guard liveHandles.contains(blocker) else {
                throw DeskError.blockedOnUnknown(handle: handle, blocker: blocker)
            }
        }
        // An item needs its blockers and its unfinished children (it cannot finish before them), the same rule
        // `DeskSequencing.compute` reads: an edge that closes a cycle in what items need never clears.
        var edges: [String: [String]] = [:]
        for item in state.items { edges[item.handle] = item.blockedOn.filter { !$0.hasPrefix("exp:") } }
        edges[handle] = proposed.filter { !$0.hasPrefix("exp:") }
        for item in state.items where !item.status.isTerminal {
            if let parent = item.parent { edges[parent, default: []].append(item.handle) }
        }
        // Carry a bounded DFS path so refusals name cycles without hanging on malformed graphs.
        for start in proposed where !start.hasPrefix("exp:") {
            var seen: Set<String> = []
            var path: [String] = []
            func reachesTarget(_ node: String, depth: Int) -> Bool {
                guard depth <= deskMaxGraphDepth else { return false }
                if node == handle {
                    path.append(node)
                    return true
                }
                guard seen.insert(node).inserted else { return false }
                path.append(node)
                for next in edges[node] ?? [] where reachesTarget(next, depth: depth + 1) {
                    return true
                }
                path.removeLast()
                return false
            }
            if reachesTarget(start, depth: 0) {
                throw DeskError.blockedOnCycle(handle: handle, handles: [handle] + path)
            }
        }
    }
    @discardableResult
    public func closeItem(_ handle: String, outcomeSummary: String, canceled: Bool = false) async throws -> DeskOp {
        let status: DeskStatus = canceled ? .canceled : .done
        return try await appendValidated(DeskOp(handle: handle, body: .closeItem(outcomeSummary: outcomeSummary, status: status)))
    }
    /// Match updatedAt under the lock so a stale close cannot settle newer work.
    @discardableResult
    public func closeItemIfUnchanged(_ handle: String, expectedUpdatedAt: String, outcomeSummary: String, canceled: Bool = false) async throws -> Bool {
        try await SwiftNativePersistenceCore.withFileLock(opsPath) {
            let feed = try await readFeedUnlocked()
            let state = Self.compact(base: feed.base, feed.ops)
            guard let item = state.items.first(where: { $0.handle == handle }) else {
                throw DeskError.unknownHandle(handle)
            }
            guard !item.status.isTerminal, item.updatedAt == expectedUpdatedAt else { return false }
            let status: DeskStatus = canceled ? .canceled : .done
            let op = DeskOp(handle: handle, body: .closeItem(outcomeSummary: outcomeSummary, status: status))
            try Self.validateHierarchyTransition(op, in: state)
            try Self.validatePursuitInvariants(op, in: state, viaGenericPath: false)
            try await commitUnlocked([op], feed: feed)
            return true
        }
    }
    /// Reopen contradictory terminal ancestors with compensating events, preserving canonical history.
    /// Recovery is explicit so liveState remains a pure read.
    @discardableResult
    public func reconcileTerminalParentsWithNonTerminalDescendants() async throws -> [DeskOp] {
        try await SwiftNativePersistenceCore.withFileLock(opsPath) {
            let feed = try await readFeedUnlocked()
            var state = Self.compact(base: feed.base, feed.ops)
            // Reopen outer ancestors first so each staged repair respects hierarchy invariants.
            let candidates = Self.terminalParentsWithNonTerminalDescendants(in: state)
            var repairs: [DeskOp] = []
            for candidate in candidates {
                guard let live = state.items.first(where: { $0.handle == candidate.handle }),
                      live.status.isTerminal,
                      Self.descendants(of: live.handle, in: state).contains(where: { !$0.status.isTerminal }) else {
                    continue
                }
                let prior = Self.foldLastNonTerminal(seed: feed.base?.lastNonTerminal ?? [:], ops: feed.ops + repairs)[live.handle]
                    ?? DeskNonTerminalRecord(status: .watch, blockedReason: nil, waitingOn: nil)
                let repair = DeskOp(
                    handle: live.handle,
                    body: .setStatus(
                        status: prior.status,
                        blockedReason: prior.blockedReason,
                        waitingOn: prior.waitingOn,
                        progress: nil,
                        assignee: nil,
                        laneOf: nil
                    )
                )
                try Self.validateHierarchyTransition(repair, in: state)
                // Reopening a pursuit respects the open-pursuit cap; a refused repair stays visible in the digest.
                do {
                    try Self.validatePursuitInvariants(repair, in: state, viaGenericPath: false)
                } catch DeskError.pursuitCapReached {
                    continue
                }
                repairs.append(repair)
                state = Self.compact(base: feed.base, feed.ops + repairs)
            }
            guard !repairs.isEmpty else { return [] }
            return try await commitUnlocked(repairs, feed: feed).ops
        }
    }
    /// Stamp notification attempts without changing updatedAt so one change cannot fan out into duplicate pings.
    @discardableResult
    public func markNotified(_ handle: String, at: String = DeskClock.nowISO()) async throws -> DeskOp {
        try await appendValidated(DeskOp(handle: handle, body: .markNotified(at: at)))
    }
    /// Match updatedAt so stamping an old notification leaves newer content eligible.
    @discardableResult
    public func markNotifiedIfUnchanged(_ handle: String, expectedUpdatedAt: String) async throws -> Bool {
        try await SwiftNativePersistenceCore.withFileLock(opsPath) {
            let feed = try await readFeedUnlocked()
            let state = Self.compact(base: feed.base, feed.ops)
            guard let item = state.items.first(where: { $0.handle == handle }),
                  item.updatedAt == expectedUpdatedAt else { return false }
            // Mint the stamp inside the flock so it cannot precede a mutation that wins the lock.
            let stamp = DeskClock.commitStamp(notBefore: feed.maxCommittedTs)
            try await commitUnlocked(
                [DeskOp(handle: handle, body: .markNotified(at: stamp))],
                feed: feed
            )
            return true
        }
    }
}
