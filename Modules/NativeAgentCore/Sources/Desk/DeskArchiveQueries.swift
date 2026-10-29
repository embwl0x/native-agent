import NativeAgentShared
import Darwin
import Foundation
import PersistenceCore
import NativeAgentCore
import Synchronization
// Blueprint: | `DeskArchiveQueries.swift` | Archival, current-life readings and hierarchy queries |
extension SwiftNativeDeskStore {
    /// archive_item -> append ArchiveRecord(s) to desk_archive.jsonl and exclude
    /// the item (and its whole subtree) from live state. REFUSES any standing
    /// or unfinished item in the subtree; archive records are summaries, not
    /// recoverable snapshots of unfinished work.
    /// Cascade-archives the entire subtree so no live descendant is orphaned.
    /// Runs the whole check-then-write under the ops flock so the refusal can't
    /// race a sibling mutation.
    @discardableResult
    public func archiveItem(_ handle: String) async throws -> ArchiveRecord {
        return try await SwiftNativePersistenceCore.withFileLock(opsPath) {
            var feed = try await readFeedUnlocked()
            let state = Self.compact(base: feed.base, feed.ops)
            guard let item = state.items.first(where: { $0.handle == handle }) else {
                throw DeskError.unknownHandle(handle)
            }
            if item.kind == .standing {
                throw DeskError.archiveRefusedStanding(handle: handle)
            }
            // Validate the whole subtree so archiving cannot orphan a live descendant.
            let subtree = Self.descendants(of: handle, in: state)
            if let standing = subtree.first(where: { $0.kind == .standing }) {
                throw DeskError.archiveRefusedStanding(handle: standing.handle)
            }
            if !item.status.isTerminal {
                throw DeskError.archiveRefusedNonTerminalSelf(handle: handle, status: item.status)
            }
            if let nonTerminal = subtree.first(where: { !$0.status.isTerminal }) {
                throw DeskError.archiveRefusedNonTerminalChild(handle: handle, childHandle: nonTerminal.handle)
            }
            if let unresolved = ([item] + subtree).first(where: { !($0.continuation?.pending.isEmpty ?? true) }) {
                throw DeskError.archiveRefusedUnresolvedContinuation(handle: unresolved.handle)
            }
            let now = DeskClock.commitStamp(notBefore: feed.maxCommittedTs)
            // Existing archive records prevent duplicate receipts after a crash before the archive op.
            let alreadyArchived = Set(try await self.archivedRecords().map(\.handle))
            // Deepest-first (subtree is breadth-first, so reverse it), target
            // LAST: a partial crash then never leaves a parent archived above a
            // still-live child, and record-before-op keeps "never vanished
            // without a record" per node.
            var targetRecord: ArchiveRecord?
            var appendedCanonicalOp = false
            do {
                for node in Array(subtree.reversed()) + [item] {
                    let rec = Self.makeArchiveRecord(node, now: now)
                    if !alreadyArchived.contains(node.handle) {
                        // takeLock: false — the caller already holds the ops
                        // flock, which serializes every archive write.
                        //
                        // The archive receipt is durable before the removing op can commit.
                        try await appendJSONLCapped(
                            rec.toJSON(), to: archivePath, maxLines: JSONLLineCaps.deskArchive,
                            logLabel: SwiftNativeDeskStore.logLabel,
                            takeLock: false,
                            durable: true
                        )
                    }
                    let archiveOp = DeskOp(ts: now, handle: node.handle, body: .archiveItem)
                    // The whole subtree was validated against one locked state.
                    // Append every canonical op first, then reduce once for
                    // compaction while this same flock is held.
                    try await appendOpUnlocked(archiveOp)
                    feed.ops.append(archiveOp)
                    feed.noteAppendedRows(1)
                    appendedCanonicalOp = true
                    if node.handle == handle { targetRecord = rec }
                }
            } catch {
                // The two append-only feeds cannot be one filesystem
                // transaction. Deepest-first keeps a partial commit valid;
                // readers must observe those committed ops even on failure.
                if appendedCanonicalOp {
                    changeBus.emit(StoreChange(store: .desk, path: opsPath))
                }
                throw error
            }
            let archivedState = Self.compact(base: feed.base, feed.ops)
            changeBus.emit(StoreChange(store: .desk, path: opsPath))
            _ = try await compactIfNeededUnlocked(state: archivedState, feed: feed)
            return targetRecord ?? Self.makeArchiveRecord(item, now: now)
        }
    }
    /// Live state reads base and tail under the ops flock so compaction cannot cause double replay.
    /// Replay is memoized on both files' (device, inode, size, mtime_ns) identities.
    ///
    /// Three properties keep this a work skip and never a truth skip:
    ///
    /// 1. **The flock is still taken, and the stat happens INSIDE it.** The
    ///    lock ordering, the blocking behaviour against a concurrent writer,
    ///    and the "no reader may straddle a compaction" guarantee documented
    ///    above are all unchanged. Only the decode+reduce is skipped.
    /// 2. **Compaction invalidates.** It rewrites the base (new mtime/size AND
    ///    a new inode — `writeJSON` is atomic-replace) and truncates the ops
    ///    file to zero. Either half alone changes the stamp.
    /// 3. **A racing non-flock writer cannot poison the memo.** The stamp is
    ///    taken before the read and RE-TAKEN after it; the entry is stored only
    ///    if the two agree, so a write that lands mid-read costs one wasted
    ///    replay rather than caching a torn view.
    ///
    /// The one skipped side effect is `SnapshotTailOpLog.noteIntegrity`'s
    /// stderr line, which is already dedupe-latched per (feed, path, summary)
    /// after its first emission — so a memo hit suppresses nothing the
    /// unmemoized path would have printed a second time.
    public func liveState() async throws -> DeskState {
        try await SwiftNativePersistenceCore.withFileLock(opsPath) {
            let key = Self.memoKey(opsPath)
            let before = Self.feedStamp(opsPath: opsPath, basePath: basePath)
            if let cached = await Self.sharedLiveStateMemo.lookup(key: key, stamp: before) {
                return try inCurrentLife(cached)
            }
            let feed = try await readFeedUnlocked()
            let state = Self.compact(base: feed.base, feed.ops)
            let after = Self.feedStamp(opsPath: opsPath, basePath: basePath)
            if let before, after == before {
                await Self.sharedLiveStateMemo.store(key: key, stamp: before, state: state)
            }
            return try inCurrentLife(state)
        }
    }
    /// `liveState()` without the file lock, for a glance that must not wait:
    /// the feed's stamp is taken before and after the read, and a read that
    /// raced a write throws instead of returning a torn view.
    public func liveStateUnlocked() async throws -> DeskState {
        let key = Self.memoKey(opsPath)
        let before = Self.feedStamp(opsPath: opsPath, basePath: basePath)
        if let cached = await Self.sharedLiveStateMemo.lookup(key: key, stamp: before) { return try inCurrentLife(cached) }
        let feed = try await readFeedUnlocked()
        let state = Self.compact(base: feed.base, feed.ops)
        guard let before, Self.feedStamp(opsPath: opsPath, basePath: basePath) == before else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return try inCurrentLife(state)
    }
    func inCurrentLife(_ saved: DeskState) throws -> DeskState {
        let life = try DataRootLife.current(in: dataRoot)
        var state = saved
        for index in state.items.indices where !state.items[index].status.isTerminal {
            var stopped = false
            if var record = state.items[index].continuation,
               ![.complete, .canceled].contains(record.state), DataRootLife.life(of: record.lifeID) != life {
                record.state = .stopped
                record.reason = DataRootLife.stoppedReason
                state.items[index].continuation = record
                stopped = true
            }
            if let last = state.items[index].refs.lastIndex(where: { if case .step = $0.kind { return true }; return false }),
               case .step(var step) = state.items[index].refs[last].kind, DataRootLife.life(of: step.lifeID) != life {
                step.status = "stopped"
                step.reason = DataRootLife.stoppedReason
                state.items[index].refs[last].kind = .step(step)
                stopped = true
            }
            if stopped {
                state.items[index].status = .blocked
                state.items[index].blockedReason = DataRootLife.stoppedReason
                state.items[index].waitingOn = "owner"
            }
        }
        return state
    }
    /// Process-wide `liveState()` memo. Keyed on the ops path so alternate data
    /// roots (tests, secondary roots, the sweep CLI's root) never collide.
    static let sharedLiveStateMemo = DeskLiveStateMemo()
    /// Resolve symlinks so every path to the same desk shares one memo entry.
    static func memoKey(_ opsPath: URL) -> String {
        opsPath.resolvingSymlinksInPath().path
    }
    /// The feed's identity: a stat-strength stamp for each of the two files a
    /// replay reads. `nil` means at least one file's state is UNKNOWABLE (a
    /// stat that failed for a reason other than "does not exist"), which never
    /// matches a stored stamp and is never stored — that path always replays.
    static func feedStamp(opsPath: URL, basePath: URL) -> DeskLiveStateMemo.FeedStamp? {
        guard let ops = SnapshotTailOpLog.fileStamp(opsPath),
              let base = SnapshotTailOpLog.fileStamp(basePath) else { return nil }
        return DeskLiveStateMemo.FeedStamp(ops: ops, base: base)
    }
    /// All archived item records, in feed (append) order.
    public func archivedRecords() async throws -> [ArchiveRecord] {
        let raw = try await SwiftNativePersistenceCore.readJSONL(archivePath)
        return raw.compactMap { ArchiveRecord.fromJSON($0) }
    }
    /// Every descendant of `handle` (children, grandchildren, …) in `state`,
    /// breadth-first. Cycle-safe: each handle is visited at most once.
    public static func descendants(of handle: String, in state: DeskState, maxDepth: Int = .max) -> [DeskItem] {
        descendants(of: handle, in: Dictionary(grouping: state.items, by: \.parent), maxDepth: maxDepth)
    }
    public static func descendants(of handle: String, in children: [String?: [DeskItem]], maxDepth: Int = .max) -> [DeskItem] {
        var out: [DeskItem] = []
        var seen: Set<String> = [handle]
        var frontier = (children[.some(handle)] ?? []).filter { seen.insert($0.handle).inserted }
        var depth = 0
        while !frontier.isEmpty, depth < maxDepth {
            depth += 1
            out.append(contentsOf: frontier)
            frontier = frontier.flatMap { children[.some($0.handle)] ?? [] }.filter { seen.insert($0.handle).inserted }
        }
        return out
    }
    public static func terminalParentsWithNonTerminalDescendants(in state: DeskState) -> [DeskItem] {
        state.items.filter { $0.status.isTerminal
            && descendants(of: $0.handle, in: state).contains(where: { !$0.status.isTerminal }) }
    }
    /// Count of OPEN (non-terminal) origin=agent pursuits in `state`. The
    /// open-pursuit cap keys on exactly this — a terminal (done/canceled/
    /// abandoned) pursuit doesn't count, but reopening one does (it re-enters
    /// this set).
    static func openAgentPursuitCount(in state: DeskState) -> Int {
        state.items.filter { $0.origin == .agent && $0.kind == .project && !$0.status.isTerminal }.count
    }
    /// Pursuit invariants are enforced at WRITE time on every append
    /// path — create, reopen, and the dedicated openPursuit path all route here.
    ///
    /// - A create with origin=agent MUST be kind=project + carry a valid pursuit
    ///   (required fields present, dossier passes the source-mix gate) and MUST
    ///   NOT breach the open-pursuit cap. The GENERIC path (viaGenericPath) may
    ///   NEVER mint origin=agent at all.
    /// - A set_status REOPEN (non-terminal) of a currently-terminal agent pursuit
    ///   counts against the cap — close/reopen tricks cannot exceed 2 open.
    static func validatePursuitInvariants(
        _ op: DeskOp,
        in state: DeskState,
        viaGenericPath: Bool
    ) throws {
        switch op.body {
        case let .createItem(_, kind, project, _, parent, _, _, _, origin, pursuit, _):
            if viaGenericPath, Self.equivalentDeskText(project) == MyQueue.project {
                throw DeskError.queueCreationRequiresQueuePath
            }
            // A create_item can NEVER mint an agent pursuit — that path is
            // open_pursuit only. An origin=agent create_item is refused
            // regardless of who calls it, but for a top-level MY QUEUE plan.
            guard origin == .agent else { return }   // owner/system creates are unconstrained here
            if !viaGenericPath, kind == .plan, project == MyQueue.project, parent == nil, pursuit == nil { return }
            throw DeskError.genericPathCannotCreateAgent(handle: op.handle)
        case let .openPursuit(_, _, _, _, pursuit, _):
            if viaGenericPath {
                throw DeskError.genericPathCannotCreateAgent(handle: op.handle)
            }
            if let reason = pursuit.validationError() {
                if reason.hasPrefix("dossier") {
                    throw DeskError.pursuitDossierInvalid(reason: reason)
                }
                throw DeskError.pursuitFieldMissing(reason: reason)
            }
            // Cap: this create would be the (N+1)th OPEN pursuit.
            let open = openAgentPursuitCount(in: state)
            if open >= maxOpenAgentPursuits {
                throw DeskError.pursuitCapReached(openCount: open)
            }
        case let .reserveWorkAttempt(attemptId, lane, day, _):
            guard let item = state.items.first(where: { $0.handle == op.handle }),
                  !item.status.isTerminal, item.isPursuit == (lane == .pursuit) else {
                throw DeskError.unknownHandle(op.handle)
            }
            if state.hasWorkSlot(handle: op.handle, id: attemptId) { return }
            if lane == .pursuit {
                guard let expiry = item.pursuitExpiresAt, let admitted = DeskClock.parseISO(op.ts), admitted < expiry else {
                    throw DeskError.workReservationNotReady(handle: op.handle)
                }
            }
            guard item.status != .blocked, DeskSequencing.compute(state).byHandle[op.handle]?.isReady == true else {
                throw DeskError.workReservationNotReady(handle: op.handle)
            }
            let limit = lane == .pursuit ? maxWorkSessionsPerPursuitPerDay : 1
            if state.workSessions(on: day, handle: op.handle) >= limit {
                throw DeskError.workSessionCapReached(scope: lane == .pursuit ? "per-pursuit (2/day)" : "per-owner-item (1/day)",
                    limit: limit, handle: op.handle)
            }
            if state.workSessions(on: day) >= maxWorkSessionsGlobalPerDay {
                throw DeskError.workSessionCapReached(scope: "workshop (6/day)", limit: maxWorkSessionsGlobalPerDay, handle: op.handle)
            }
        case let .completeWorkAttempt(attemptId, _, _, _):
            guard let item = state.items.first(where: { $0.handle == op.handle }),
                  let attempt = item.workAttempts.first(where: { $0.attemptId == attemptId }) else {
                throw DeskError.unknownReservation(reservationId: attemptId, handle: op.handle)
            }
            if attempt.completedAt != nil {
                throw DeskError.reservationAlreadyComplete(reservationId: attemptId, handle: op.handle)
            }
        case let .handOffWorkReceipt(reservationId):
            guard let item = state.items.first(where: { $0.handle == op.handle }) else {
                throw DeskError.unknownHandle(op.handle)
            }
            let completed = item.workAttempts.first(where: { $0.attemptId == reservationId })?.completedAt
            guard completed != nil else {
                throw DeskError.unknownReservation(reservationId: reservationId, handle: op.handle)
            }
        case let .setStatus(status, _, _, _, _, _):
            // Only a REOPEN (terminal → non-terminal) of an agent pursuit is
            // capped. Any other status move on a pursuit is free.
            guard !status.isTerminal,
                  let item = state.items.first(where: { $0.handle == op.handle }),
                  item.origin == .agent, item.kind == .project,
                  item.status.isTerminal else { return }
            // The item is currently terminal (NOT in the open set); reopening it
            // adds it back, so the cap must have room WITHOUT counting it.
            let open = openAgentPursuitCount(in: state)
            if open >= maxOpenAgentPursuits {
                throw DeskError.pursuitCapReached(openCount: open)
            }
        default:
            break
        }
    }
    /// A terminal item cannot own a non-terminal descendant, and a descendant
    /// cannot become non-terminal beneath a terminal ancestor.
    static func validateHierarchyTransition(
        _ op: DeskOp,
        in state: DeskState
    ) throws {
        switch op.body {
        case let .createItem(_, _, _, _, parent, _, _, _, _, _, _):
            guard let parent else { return }
            guard state.items.contains(where: { $0.handle == parent }) else {
                throw DeskError.unknownHandle(parent)
            }
            if let terminal = terminalAncestor(startingAt: parent, in: state) {
                throw DeskError.childRefusedTerminalParent(parentHandle: terminal.handle)
            }
        case let .setStatus(status, _, _, _, _, laneOf):
            if let laneOf {
                guard laneOf != op.handle else {
                    throw DeskError.laneOfSelf(handle: op.handle)
                }
                guard state.items.contains(where: { $0.handle == laneOf }) else {
                    throw DeskError.laneOfUnknown(handle: op.handle, laneOf: laneOf)
                }
            }
            if status.isTerminal {
                try rejectTerminalParentWithOpenDescendant(op.handle, in: state)
            } else if let item = state.items.first(where: { $0.handle == op.handle }),
                      let parent = item.parent,
                      let terminal = terminalAncestor(startingAt: parent, in: state) {
                throw DeskError.nonTerminalStatusRefusedTerminalAncestor(
                    handle: op.handle,
                    ancestorHandle: terminal.handle
                )
            }
        case .vetoPursuit:
            try rejectTerminalParentWithOpenDescendant(op.handle, in: state)
        case .closeItem:
            // A second close is not idempotent: it rewrites the outcome
            // summary, the closedAt stamp, and (done ⇄ canceled) the verdict
            // itself. Refuse it under the ops flock, where the read that
            // decided cannot go stale — a caller's own pre-check can.
            if let item = state.items.first(where: { $0.handle == op.handle }),
               item.status.isTerminal {
                throw DeskError.closeRefusedTerminal(handle: op.handle, status: item.status)
            }
            try rejectTerminalParentWithOpenDescendant(op.handle, in: state)
        case .archiveItem:
            throw DeskError.directArchiveRequiresGuardedPath(handle: op.handle)
        default:
            break
        }
    }
    private static func rejectTerminalParentWithOpenDescendant(
        _ handle: String,
        in state: DeskState
    ) throws {
        if let nonTerminal = descendants(of: handle, in: state).first(where: { !$0.status.isTerminal }) {
            throw DeskError.terminalStatusRefusedNonTerminalChild(
                handle: handle,
                childHandle: nonTerminal.handle
            )
        }
    }
    /// Includes `startingAt` itself, then walks toward the root. Cycle-tolerant
    /// because legacy/hand-authored event feeds are decoded permissively.
    private static func terminalAncestor(startingAt handle: String, in state: DeskState) -> DeskItem? {
        var byHandle = Dictionary(state.items.map { ($0.handle, $0) }, uniquingKeysWith: { first, _ in first })
        var current: String? = handle
        var seen: Set<String> = []
        while let handle = current,
              seen.insert(handle).inserted,
              let item = byHandle.removeValue(forKey: handle) {
            if item.status.isTerminal { return item }
            current = item.parent
        }
        return nil
    }
    /// Build the final archive record for an item (the shared shape used by both
    /// single-item archive and subtree cascade).
    static func makeArchiveRecord(_ item: DeskItem, now: String) -> ArchiveRecord {
        ArchiveRecord(
            handle: item.handle,
            title: item.title,
            project: item.project,
            finalStatus: (item.status == .canceled) ? .canceled : .done,
            openedAt: item.openedAt,
            closedAt: item.closedAt ?? now,
            summary: item.summary ?? "",
            refs: item.liveRefs(limit: 3),
            decisions: [],
            artifacts: [],
            findingKey: item.findingKey
        )
    }
}
