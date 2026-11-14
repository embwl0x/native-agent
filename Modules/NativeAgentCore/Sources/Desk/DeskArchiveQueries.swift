import NativeAgentShared
import Darwin
import Foundation
import PersistenceCore
import NativeAgentCore
import Synchronization
// Blueprint: | `DeskArchiveQueries.swift` | Archival and locked hierarchy queries; partial archive commits preserve receipts; a retried archive replaces its receipt |
extension SwiftNativeDeskStore {
    /// Archive only finished non-standing subtrees: summaries cannot recover unfinished work.
    /// The ops flock keeps validation and deepest-first writes together so no live child is orphaned.
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
            // A handle's receipt is the outcome at the archive that removed it: one left by an interrupted archive is replaced, never kept.
            let archived = try await self.archivedRecords()
            // Deepest-first and receipt-before-op keep partial commits valid and every removal recorded.
            var targetRecord: ArchiveRecord?
            var appendedCanonicalOp = false
            do {
                for node in Array(subtree.reversed()) + [item] {
                    let rec = Self.makeArchiveRecord(node, now: now)
                    let stored = archived.filter { $0.handle == node.handle }
                    // The caller holds the ops flock; make the receipt durable before removing the item.
                    if stored.isEmpty {
                        try await appendJSONLCapped(
                            rec.toJSON(), to: archivePath, maxLines: JSONLLineCaps.deskArchive,
                            logLabel: SwiftNativeDeskStore.logLabel,
                            takeLock: false,
                            durable: true
                        )
                    } else if stored != [rec] {
                        try await replaceArchiveRecord(rec)
                    }
                    let archiveOp = DeskOp(ts: now, handle: node.handle, body: .archiveItem)
                    // Append every validated op before reducing once for compaction under the same flock.
                    try await appendOpUnlocked(archiveOp)
                    feed.ops.append(archiveOp)
                    feed.noteAppendedRows(1)
                    appendedCanonicalOp = true
                    if node.handle == handle { targetRecord = rec }
                }
            } catch {
                // The feeds cannot commit atomically; readers must observe even a partial committed removal.
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
    /// Durably rewrite the archive with `record` in place of every receipt for its handle. The caller holds the ops flock.
    private func replaceArchiveRecord(_ record: ArchiveRecord) async throws {
        let others = try await SwiftNativePersistenceCore.readJSONL(archivePath).filter { ArchiveRecord.fromJSON($0)?.handle != record.handle }
        try SwiftNativePersistenceCore.writeDataAtomicDurable(
            try SwiftNativePersistenceCore.serializeJSONL(others + [record.toJSON()]), to: archivePath)
    }
    /// Memoize replay on both files’ stat identities under the ops flock, preserving compaction isolation.
    /// Atomic base replacement or tail truncation invalidates the memo.
    /// Stamp before and after reading so a racing non-flock writer cannot cache a torn view.
    /// Integrity logging is already deduplicated, so a memo hit hides no new diagnostic.
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
    /// A nonblocking glance rejects a feed changed during the read instead of returning a torn view.
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
    /// Key on the ops path so distinct data roots cannot share replayed state.
    static let sharedLiveStateMemo = DeskLiveStateMemo()
    /// Resolve symlinks so every path to the same desk shares one memo entry.
    static func memoKey(_ opsPath: URL) -> String {
        opsPath.resolvingSymlinksInPath().path
    }
    /// An unknowable stat identity never matches or enters the memo, forcing replay.
    static func feedStamp(opsPath: URL, basePath: URL) -> DeskLiveStateMemo.FeedStamp? {
        guard let ops = SnapshotTailOpLog.fileStamp(opsPath),
              let base = SnapshotTailOpLog.fileStamp(basePath) else { return nil }
        return DeskLiveStateMemo.FeedStamp(ops: ops, base: base)
    }
    /// Malformed archive history fails whole so identity checks cannot silently omit a record.
    public func archivedRecords() async throws -> [ArchiveRecord] {
        let raw = try await SwiftNativePersistenceCore.readJSONL(archivePath)
        var records: [ArchiveRecord] = []
        records.reserveCapacity(raw.count)
        for (index, value) in raw.enumerated() {
            guard let record = ArchiveRecord.fromJSON(value) else {
                throw PersistenceCoreError.ioFailure("""
                    Desk archive history unavailable at \(archivePath.path): record \(index + 1) is not a complete archive record. Original \
                    bytes retained; repair the named record before reading or changing archive history.
                    """)
            }
            records.append(record)
        }
        return records
    }
    /// Visit each handle once so malformed hierarchy cycles cannot hang traversal.
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
    /// Only open agent pursuits consume the cap; reopening a terminal pursuit consumes it again.
    static func openAgentPursuitCount(in state: DeskState) -> Int {
        state.items.filter { $0.origin == .agent && $0.kind == .project && !$0.status.isTerminal }.count
    }
    /// Every create and reopen checks pursuit invariants under the write lock.
    /// Agent projects require valid evidence and capacity; generic creation cannot mint pursuits.
    /// Reopening consumes the same cap so close/reopen cannot bypass it.
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
            // Only open_pursuit may mint a pursuit; generic agent creation is limited to MY QUEUE plans.
            guard origin == .agent else { return }
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
            // Only reopening an agent pursuit consumes new capacity.
            guard !status.isTerminal,
                  let item = state.items.first(where: { $0.handle == op.handle }),
                  item.origin == .agent, item.kind == .project,
                  item.status.isTerminal else { return }
            // A terminal pursuit is outside the open set, so capacity must exist without counting it.
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
            // A second close would overwrite the outcome and timestamp; refuse it against locked state.
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
    /// Include the starting item; visit each ancestor once because authored feeds can contain cycles.
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
    static func makeArchiveRecord(_ item: DeskItem, now: String) -> ArchiveRecord {
        var refs = item.liveRefs(limit: 3)
        if let captured = item.refs.last(where: { if case .step(let step) = $0.kind { return !step.promiseCaptures.isEmpty }; return false }),
           !refs.contains(where: { $0.refId == captured.refId }) { refs.append(captured) }
        return ArchiveRecord(
            handle: item.handle,
            title: item.title,
            project: item.project,
            finalStatus: (item.status == .canceled) ? .canceled : .done,
            openedAt: item.openedAt,
            closedAt: item.closedAt ?? now,
            summary: item.summary ?? "",
            refs: refs,
            decisions: [],
            artifacts: [],
            findingKey: item.findingKey
        )
    }
}
