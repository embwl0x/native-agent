import NativeAgentShared
import Darwin
import Foundation
import PersistenceCore
import NativeAgentCore
import Synchronization
// Blueprint: | `DeskDependencyTransitions.swift` | Dependencies, hierarchy settlement and locked revalidation |
extension SwiftNativeDeskStore {
    /// setBlockedOn — REPLACE the whole blocker set for `handle`. Blockers are
    /// stable handles of LIVE items or exp:<id> (the chat lane resolves first).
    /// A named wait replaces prose blocking and may carry her reason as a note.
    /// Validated UNDER THE OPS FLOCK against ops-derived live state so a refusal
    /// can't race a sibling close: unknown blocker, self-block, and any edge that
    /// would close a cycle are all refused.
    ///
    /// The ts is minted INSIDE the lock via commitStamp — a defaulted timestamp
    /// parameter would be evaluated at the call site BEFORE the lock and could
    /// commit behind a later-issued stamp (the trap this file documents).
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
            let op = DeskOp(
                ts: DeskClock.commitStamp(notBefore: feed.maxCommittedTs),
                handle: handle,
                body: .setBlockedOn(handles: proposed)
            )
            var committed = try await appendAndRecompactUnlocked(op, feed: feed).feed
            var bodies: [DeskOpBody] = []
            if waiting {
                bodies.append(.setStatus(status: item.status == .blocked ? .next : item.status,
                    blockedReason: nil, waitingOn: nil, progress: item.progress, assignee: item.assignee, laneOf: item.laneOf))
            }
            if let note { bodies.append(.appendNote(text: note, author: "agent")) }
            for body in bodies {
                let next = DeskOp(ts: DeskClock.commitStamp(notBefore: committed.maxCommittedTs), handle: handle, body: body)
                committed = try await appendAndRecompactUnlocked(next, feed: committed).feed
            }
            return op
        }
    }
    /// setDeferUntil — park `handle` until a day (`yyyy-MM-dd`) or ISO stamp.
    /// nil / empty CLEARS. An unparseable value is REFUSED rather than stored:
    /// the read side treats an unparseable defer as NOT deferred (never park an
    /// item forever silently), so accepting one here would quietly no-op.
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
                ts: DeskClock.commitStamp(notBefore: feed.maxCommittedTs),
                handle: handle,
                body: .setDeferUntil(until: value)
            )
            _ = try await appendAndRecompactUnlocked(op, feed: feed)
            return op
        }
    }
    /// Trim, drop empties, dedup — preserving FIRST-SEEN order so the stored set
    /// reads back the way the operator named it.
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
    /// Settled conditions come off the item as it is now, under the ops lock,
    /// so a wait committed meanwhile is never overwritten; the note says why.
    public func releaseBlockers(_ handle: String, removing settled: Set<String>, note: String, author: String) async throws {
        try await SwiftNativePersistenceCore.withFileLock(opsPath) {
            var feed = try await readFeedUnlocked()
            let state = Self.compact(base: feed.base, feed.ops)
            guard let item = state.items.first(where: { $0.handle == handle }),
                  item.blockedOn.contains(where: settled.contains) else { return }
            for body in [DeskOpBody.setBlockedOn(handles: item.blockedOn.filter { !settled.contains($0) }),
                         .appendNote(text: note, author: author)] {
                let op = DeskOp(ts: DeskClock.commitStamp(notBefore: feed.maxCommittedTs), handle: handle, body: body)
                feed = try await appendAndRecompactUnlocked(op, feed: feed).feed
            }
        }
    }
    /// Write-time gate for a proposed blocker set: every Desk blocker must be a live
    /// item; experience conditions are checked by their caller. Desk edges cannot close a cycle in
    /// the PROSPECTIVE graph (live edges with this item's edges replaced by the
    /// proposal). A cycle is unresolvable — nothing in it can ever become ready.
    static func validateBlockedOn(handle: String, proposed: [String], in state: DeskState) throws {
        let liveHandles = Set(state.items.map(\.handle))
        for blocker in proposed {
            if blocker.hasPrefix("exp:"), blocker.count > 4 { continue }
            if blocker == handle { throw DeskError.blockedOnSelf(handle: handle) }
            guard liveHandles.contains(blocker) else {
                throw DeskError.blockedOnUnknown(handle: handle, blocker: blocker)
            }
        }
        var edges: [String: [String]] = [:]
        for item in state.items { edges[item.handle] = item.blockedOn.filter { !$0.hasPrefix("exp:") } }
        edges[handle] = proposed.filter { !$0.hasPrefix("exp:") }
        // Is `handle` reachable FROM any proposed blocker? If so the proposal
        // closes a loop. DFS carries the path so the refusal can name it, and is
        // bounded by both a visited set (existing cycles elsewhere in the graph
        // can't hang it) and a depth cap.
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
    /// close_item -> status=done (or canceled), closedAt=now, summary=outcomeSummary.
    @discardableResult
    public func closeItem(_ handle: String, outcomeSummary: String, canceled: Bool = false) async throws -> DeskOp {
        let status: DeskStatus = canceled ? .canceled : .done
        return try await appendValidated(DeskOp(handle: handle, body: .closeItem(outcomeSummary: outcomeSummary, status: status)))
    }
    /// Settle only the most recently linked Workshop execution, under the same
    /// lock that admits new references and lifecycle changes.
    public func settleWorkshopExecution(
        _ handle: String, executionId: String, note: String, status: DeskStatus,
        summary: String, waitingOn: String? = nil, latestExecutionId: String? = nil
    ) async throws -> Bool {
        try await SwiftNativePersistenceCore.withFileLock(opsPath) {
            var feed = try await readFeedUnlocked()
            var state = Self.compact(base: feed.base, feed.ops)
            guard let item = state.items.first(where: { $0.handle == handle }) else { return false }
            let executions = item.refs.compactMap { ref -> String? in
                if case .trace(let id, "workshop_execution") = ref.kind { return id }
                return nil
            }
            guard executions.contains(executionId) else { return false }
            let latest = latestExecutionId ?? executions.last
            guard latest == executionId else { return true }
            if !item.notes.contains(where: { $0.text == note }) {
                var op = DeskOp(handle: handle, body: .appendNote(text: note))
                op.ts = DeskClock.commitStamp(notBefore: feed.maxCommittedTs)
                (state, feed) = try await appendAndRecompactUnlocked(op, feed: feed)
            }
            guard !item.status.isTerminal else { return true }
            if status == .done, let continuation = item.continuation,
               ![.complete, .canceled].contains(continuation.state) { return true }
            var op = DeskOp(handle: handle, body: status == .blocked
                ? .setStatus(status: .blocked, blockedReason: summary, waitingOn: waitingOn,
                             progress: nil, assignee: nil, laneOf: nil)
                : .closeItem(outcomeSummary: summary, status: status))
            try Self.validateHierarchyTransition(op, in: state)
            try Self.validatePursuitInvariants(op, in: state, viaGenericPath: false)
            op.ts = DeskClock.commitStamp(notBefore: feed.maxCommittedTs)
            _ = try await appendAndRecompactUnlocked(op, feed: feed)
            return true
        }
    }
    /// Under the ops flock, close only a nonterminal item with matching updatedAt; otherwise return false.
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
            var op = DeskOp(handle: handle, body: .closeItem(outcomeSummary: outcomeSummary, status: status))
            try Self.validateHierarchyTransition(op, in: state)
            try Self.validatePursuitInvariants(op, in: state, viaGenericPath: false)
            op.ts = DeskClock.commitStamp(notBefore: feed.maxCommittedTs)
            _ = try await appendAndRecompactUnlocked(op, feed: feed)
            return true
        }
    }
    /// Close a pursuit only when the exact completed reservation durably owns a
    /// typed `goal_satisfied` outcome and the item has not changed since the
    /// caller verified its handle-scoped artifacts. This is the sole automatic
    /// completion path; prose is never interpreted as completion evidence.
    @discardableResult
    public func closePursuitIfGoalSatisfied(
        _ handle: String,
        reservationId: String,
        expectedUpdatedAt: String,
        outcomeSummary: String
    ) async throws -> Bool {
        try await SwiftNativePersistenceCore.withFileLock(opsPath) {
            let feed = try await readFeedUnlocked()
            let state = Self.compact(base: feed.base, feed.ops)
            guard let item = state.items.first(where: { $0.handle == handle }) else {
                throw DeskError.unknownHandle(handle)
            }
            guard item.isPursuit, !item.status.isTerminal,
                  item.updatedAt == expectedUpdatedAt,
                  let reservation = item.workAttempts.first(where: {
                      $0.lane == .pursuit && $0.attemptId == reservationId
                  }),
                  reservation.completedAt != nil,
                  reservation.disposition == .goalSatisfied else {
                return false
            }
            var op = DeskOp(
                handle: handle,
                body: .closeItem(outcomeSummary: outcomeSummary, status: .done)
            )
            try Self.validateHierarchyTransition(op, in: state)
            try Self.validatePursuitInvariants(op, in: state, viaGenericPath: false)
            op.ts = DeskClock.commitStamp(notBefore: feed.maxCommittedTs)
            _ = try await appendAndRecompactUnlocked(op, feed: feed)
            return true
        }
    }
    /// Repair legacy contradictory projections without rewriting the canonical
    /// feed. Each terminal parent that still owns a non-terminal descendant is
    /// reopened to its last recorded non-terminal status with a new set_status
    /// event. The original terminal event remains in the log for audit/replay.
    ///
    /// This is explicit rather than hidden in liveState(): reads stay pure, and
    /// the app-owned runtime can decide when to perform a migration/recovery pass.
    @discardableResult
    public func reconcileTerminalParentsWithNonTerminalDescendants() async throws -> [DeskOp] {
        try await SwiftNativePersistenceCore.withFileLock(opsPath) {
            var feed = try await readFeedUnlocked()
            var state = Self.compact(base: feed.base, feed.ops)
            // DeskState is parent-before-descendant. Reopen outer terminal
            // parents first so a nested repair never sits beneath a terminal
            // ancestor while its compensating event is appended.
            let candidates = Self.terminalParentsWithNonTerminalDescendants(in: state)
            var repairs: [DeskOp] = []
            for candidate in candidates {
                guard let live = state.items.first(where: { $0.handle == candidate.handle }),
                      live.status.isTerminal,
                      Self.descendants(of: live.handle, in: state).contains(where: { !$0.status.isTerminal }) else {
                    continue
                }
                let prior = Self.foldLastNonTerminal(seed: feed.base?.lastNonTerminal ?? [:], ops: feed.ops)[live.handle]
                    ?? DeskNonTerminalRecord(status: .watch, blockedReason: nil, waitingOn: nil)
                let repair = DeskOp(
                    ts: DeskClock.commitStamp(notBefore: feed.maxCommittedTs),
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
                let committed = try await appendAndRecompactUnlocked(repair, feed: feed)
                repairs.append(repair)
                feed = committed.feed
                state = committed.state
            }
            return repairs
        }
    }
    /// markNotified — stamp notify.lastNotifiedAt (a notification was attempted).
    /// Does NOT bump updatedAt; the notify loop calls this after ATTEMPTING
    /// delivery (v1 stamps after attempt, not delivery-success) so the same
    /// change can't fan out into duplicate pings.
    @discardableResult
    public func markNotified(_ handle: String, at: String = DeskClock.nowISO()) async throws -> DeskOp {
        try await appendValidated(DeskOp(handle: handle, body: .markNotified(at: at)))
    }
    /// Stamp notify.lastNotifiedAt only for matching updatedAt, keeping newer content eligible; return whether stamped.
    @discardableResult
    public func markNotifiedIfUnchanged(_ handle: String, expectedUpdatedAt: String, at: String? = nil) async throws -> Bool {
        try await SwiftNativePersistenceCore.withFileLock(opsPath) {
            let feed = try await readFeedUnlocked()
            let state = Self.compact(base: feed.base, feed.ops)
            guard let item = state.items.first(where: { $0.handle == handle }),
                  item.updatedAt == expectedUpdatedAt else { return false }
            // Default stamp is minted HERE, inside the flock — a default-argument
            // stamp is evaluated at the call site, before the lock, where it can
            // misorder against a mutation racing for the same lock.
            let stamp = at ?? DeskClock.commitStamp(notBefore: feed.maxCommittedTs)
            _ = try await appendAndRecompactUnlocked(
                DeskOp(ts: stamp, handle: handle, body: .markNotified(at: stamp)),
                feed: feed
            )
            return true
        }
    }
}
