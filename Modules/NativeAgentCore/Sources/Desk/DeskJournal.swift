import NativeAgentShared
import Darwin
import Foundation
import PersistenceCore
import NativeAgentCore
import Synchronization
// Blueprint: | `DeskJournal.swift` | Locked event feed append, integrity and compaction |
extension SwiftNativeDeskStore {
    /// Append and compact under the canonical feed lock.
    @discardableResult
    public func append(_ op: DeskOp) async throws -> DeskOp {
        try await SwiftNativePersistenceCore.withFileLock(opsPath) {
            let feed = try await readFeedUnlocked()
            let state = Self.compact(base: feed.base, feed.ops)
            try Self.validateHierarchyTransition(op, in: state)
            try Self.validatePursuitInvariants(op, in: state, viaGenericPath: true)
            _ = try await appendAndRecompactUnlocked(op, feed: feed)
        }
        return op
    }
    /// Validate a live item's mutation and stamp it under the ops lock.
    /// Explicit todo starts another life's stopped continuation fresh.
    @discardableResult
    func appendValidated(_ op: DeskOp) async throws -> DeskOp {
        try await SwiftNativePersistenceCore.withFileLock(opsPath) {
            var feed = try await readFeedUnlocked()
            let state = Self.compact(base: feed.base, feed.ops)
            guard state.items.contains(where: { $0.handle == op.handle }) else {
                throw DeskError.unknownHandle(op.handle)
            }
            try Self.validateHierarchyTransition(op, in: state)
            try Self.validatePursuitInvariants(op, in: state, viaGenericPath: false)
            if case .setStatus(.todo, _, _, _, _, _) = op.body,
               let item = state.items.first(where: { $0.handle == op.handle }) {
                if var record = item.continuation, ![.complete, .canceled].contains(record.state),
                   try !DataRootLife.isCurrent(record.lifeID, in: dataRoot) {
                    record.lifeID = try DataRootLife.current(in: dataRoot)
                    record.state = .ready
                    record.reason = nil
                    record.runID = UUID().uuidString
                    record.revision = UUID().uuidString
                    record.originRunID = record.runID
                    record.pending = []
                    record.settled = []
                    record.response = nil
                    record.resumeCount = 0
                    record.nextRunAt = Date()
                    let fresh = DeskOp(ts: DeskClock.commitStamp(notBefore: feed.maxCommittedTs), handle: op.handle,
                                       body: .setContinuation(record: record))
                    feed = try await appendAndRecompactUnlocked(fresh, feed: feed).feed
                }
                if var step = item.step, try !DataRootLife.isCurrent(step.lifeID, in: dataRoot) {
                    step.lifeID = try DataRootLife.current(in: dataRoot)
                    step.status = nil
                    step.reason = nil
                    let fresh = DeskOp(ts: DeskClock.commitStamp(notBefore: feed.maxCommittedTs), handle: op.handle,
                                       body: .addRef(ref: DeskRef(kind: .step(step))))
                    feed = try await appendAndRecompactUnlocked(fresh, feed: feed).feed
                }
            }
            var stamped = op
            stamped.ts = DeskClock.commitStamp(notBefore: feed.maxCommittedTs)
            _ = try await appendAndRecompactUnlocked(stamped, feed: feed)
            return stamped
        }
    }
    /// Append one canonical op, reduce the state, then run the
    /// end-of-transaction compaction check. The canonical truth is base+tail:
    /// an op only ever leaves the tail by being folded into the base snapshot
    /// first, so a live item can never vanish and a retired alias can never be
    /// reused (the original "UNCAPPED" contract, now bounded by compaction).
    /// The caller already holds the ops flock. Returns the committed state plus
    /// the updated feed so multi-op transactions (reconcile) can continue from
    /// a post-compaction view without re-reading the disk.
    @discardableResult
    func appendAndRecompactUnlocked(
        _ op: DeskOp,
        feed: DeskFeed
    ) async throws -> (state: DeskState, feed: DeskFeed) {
        switch op.body {
        case let .setNotify(policy), let .openPursuit(_, _, _, _, _, policy):
            let supported: Set<String> = ["state_change", "blocked", "done", "explicit"]
            for trigger in policy.on {
                let normalized = trigger.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                if !normalized.isEmpty, !supported.contains(normalized) {
                    throw DeskError.notifyTriggerUnsupported(trigger)
                }
            }
        default:
            break
        }
        try await appendOpUnlocked(op)
        changeBus.emit(StoreChange(store: .desk, path: opsPath))
        // `integrity` CARRIES FORWARD: this is the post-append view of the SAME
        // file, so the rows the read could not decode are still in it. Dropping
        // it here would hand `compactIfNeededUnlocked` a clean-looking feed and
        // defeat the unknown-row gate on exactly the append that trips the
        // threshold — the one path the gate exists for.
        var next = DeskFeed(
            base: feed.base, ops: feed.ops + [op],
            fileOpCount: feed.fileOpCount, integrity: feed.integrity
        )
        next.noteAppendedRows(1)
        let state = Self.compact(base: next.base, next.ops)
        if let newBase = try await compactIfNeededUnlocked(state: state, feed: next) {
            // Compaction ran ⇒ the gate passed ⇒ the rewritten feed is clean.
            next = DeskFeed(base: newBase, ops: [], fileOpCount: 0, integrity: .clean)
        }
        return (state, next)
    }
    func appendOpUnlocked(_ op: DeskOp) async throws {
        // Reject projections read before or during the awaited write, even if it throws.
        Self.truthRevision.withLock { $0 += 1 }
        defer { Self.truthRevision.withLock { $0 += 1 } }
        try await SwiftNativePersistenceCore.appendJSONLDurable(op.toJSON(), to: opsPath)
    }
    /// Read the op tail plus the accounting of what the scan threw away.
    /// `DeskOp.fromJSON` returns nil for an op token this build does not know
    /// (DeskModels' tolerant `default:` arm) — tolerant on READ, but the count
    /// has to survive to `compactIfNeededUnlocked`, which would otherwise
    /// snapshot state folded without those rows and then delete them.
    func readOpsWithIntegrityUnlocked() async throws -> (ops: [DeskOp], integrity: SnapshotTailOpLog.OpLogIntegrity) {
        let (raw, report) = try await SwiftNativePersistenceCore.readJSONLReporting(opsPath)
        let ops = raw.compactMap { DeskOp.fromJSON($0) }
        let integrity = SnapshotTailOpLog.OpLogIntegrity(
            malformedLineCount: report.malformedLineCount,
            undecodableRowCount: raw.count - ops.count,
            trailingPartialLine: report.trailingPartialLine,
            physicalRowCount: report.physicalLineCount
        )
        SnapshotTailOpLog.noteIntegrity(integrity, feed: Self.logLabel, path: opsPath)
        return (ops, integrity)
    }
    /// The Doctor surface reports undecodable rows and feed growth when compaction is blocked.
    public func opLogHealth() async throws -> SnapshotTailOpLog.OpLogHealth {
        let integrity = try await opLogIntegrity()
        return SnapshotTailOpLog.OpLogHealth(
            feed: Self.logLabel,
            path: opsPath,
            physicalRowCount: integrity.physicalRowCount,
            byteCount: SnapshotTailOpLog.OpLogHealth.fileSize(opsPath),
            compactionThreshold: opsCompactionThreshold,
            integrity: integrity
        )
    }
    /// The readable counter behind the log line: what the desk's op-log feed
    /// currently cannot decode. Zero on a healthy desk. Non-zero means
    /// compaction is (correctly) refusing to run and the feed is growing —
    /// surface it rather than letting "the desk looks fine" be the only signal.
    public func opLogIntegrity() async throws -> SnapshotTailOpLog.OpLogIntegrity {
        try await readOpsWithIntegrityUnlocked().integrity
    }
    /// Reads the replayable feed: compaction base (if any) + the ops that
    /// FOLLOW it. Ops are read FIRST, base second — a cross-process reader
    /// racing a compaction then sees (old base, full ops), (new base, full
    /// ops → prefix dropped below), or (new base, truncated ops); never the
    /// state-losing (old base, truncated ops). The prefix drop also heals a
    /// crash between base write and op-log truncate: the stale full op-log
    /// simply replays as its post-base suffix. A base file that EXISTS but
    /// does not decode throws — replaying from the tail alone would silently
    /// blank every compacted item.
    func readFeedUnlocked() async throws -> DeskFeed {
        let (ops, integrity) = try await readOpsWithIntegrityUnlocked()
        try Self.validateAliasDomain(base: nil, ops: ops)
        let fileOpCount = ops.count
        guard FileManager.default.fileExists(atPath: basePath.path) else {
            return DeskFeed(base: nil, ops: ops, fileOpCount: fileOpCount, integrity: integrity)
        }
        // Read bytes directly to distinguish retryable I/O errors from parse/decode corruption.
        guard let baseData = try? Data(contentsOf: basePath) else {
            throw DeskError.compactionBaseUnreadable(path: basePath.path)
        }
        guard let raw = try? JSONValue.parse(baseData), raw != .null,
              let base = DeskCompactionBase.fromJSON(raw) else {
            throw DeskError.compactionBaseCorrupt(path: basePath.path)
        }
        try Self.validateAliasDomain(base: base, ops: ops)
        // Keep only ops after lastCompactedOpId; an absent id leaves the tail unchanged.
        let tail = SnapshotTailOpLog.dropCompactedPrefix(
            ops, lastCompactedOpId: base.lastCompactedOpId, id: { $0.opId }
        )
        return DeskFeed(base: base, ops: tail, fileOpCount: fileOpCount, integrity: integrity)
    }
    /// Snapshot+truncate once the op-log file crosses the threshold. The
    /// caller holds the ops flock and passes the just-committed state plus the
    /// POST-append feed (tail includes the ops just written). Base is written
    /// atomically BEFORE the truncate; the replay prefix-drop makes the
    /// in-between crash window safe (never lost, never double-applied).
    /// Returns the new base when compaction ran, nil otherwise.
    func compactIfNeededUnlocked(
        state: DeskState,
        feed: DeskFeed
    ) async throws -> DeskCompactionBase? {
        // PHYSICAL rows, not decoded ops — see `DeskFeed.compactionRowCount`.
        guard feed.compactionRowCount >= opsCompactionThreshold else { return nil }
        // Refuse compaction before the last-op guard so even wholly undecodable feeds report without erasing rows.
        guard SnapshotTailOpLog.mayCompact(feed.integrity, feed: Self.logLabel, path: opsPath) else { return nil }
        guard let lastOpId = feed.ops.last?.opId, !lastOpId.isEmpty else { return nil }
        let liveHandles = Set(state.items.map(\.handle))
        // Alias high-water survives per LIVE parent scope ("" = top level,
        // always kept). An archived parent can never receive new children
        // (createItem refuses an unknown handle), so its entry is dead weight.
        let aliasHighWater = Self.foldAliasHighWater(seed: feed.base?.aliasHighWater ?? [:], ops: feed.ops)
            .filter { $0.key.isEmpty || liveHandles.contains($0.key) }
        // The reconcile repair only ever reopens LIVE items — prune the rest.
        let lastNonTerminal = Self.foldLastNonTerminal(seed: feed.base?.lastNonTerminal ?? [:], ops: feed.ops)
            .filter { liveHandles.contains($0.key) }
        let base = DeskCompactionBase(
            state: state,
            aliasHighWater: aliasHighWater,
            lastNonTerminal: lastNonTerminal,
            lastCompactedOpId: lastOpId,
            compactedAt: DeskClock.nowISO(),
            compactedOpCount: feed.fileOpCount
        )
        // Snapshot-BEFORE-truncate via the shared engine. Desk keeps an EMPTY
        // tail: its canonical truth is base + ops-that-follow, and semantic reads
        // take the flock (liveState), so no kept tail is needed for consistency.
        try await SnapshotTailOpLog.commitCompaction(
            baseJSON: base.toJSON(), tailRows: [],
            basePath: basePath, opsPath: opsPath
        )
        return base
    }
    /// Fold create-op aliases into the per-parent high-water map:
    /// top-level aliases parse as whole integers,
    /// child aliases by their trailing component; open_pursuit creates draw
    /// from the top-level sequence and count against it.
    static func foldAliasHighWater(seed: [String: Int], ops: [DeskOp]) -> [String: Int] {
        var highWater = seed
        func bump(_ key: String, seq: Int?) {
            guard let seq else { return }
            highWater[key] = max(highWater[key] ?? 0, seq)
        }
        for op in ops {
            switch op.body {
            case let .createItem(alias, _, _, _, parent, _, _, _, _, _, _):
                if let parent {
                    bump(parent, seq: alias.split(separator: ".").last.flatMap { Int($0) })
                } else {
                    bump("", seq: Int(alias))
                }
            case let .openPursuit(alias, _, _, _, _, _):
                bump("", seq: Int(alias))
            default:
                break
            }
        }
        return highWater
    }
    /// Fold "last recorded non-terminal status" per handle:
    /// a create seeds `.watch`, a non-terminal
    /// set_status records itself, everything else is ignored.
    static func foldLastNonTerminal(
        seed: [String: DeskNonTerminalRecord],
        ops: [DeskOp]
    ) -> [String: DeskNonTerminalRecord] {
        var records = seed
        for op in ops {
            switch op.body {
            case .createItem, .openPursuit:
                records[op.handle] = DeskNonTerminalRecord(status: .watch, blockedReason: nil, waitingOn: nil)
            case let .setStatus(status, blockedReason, waitingOn, _, _, _) where !status.isTerminal:
                records[op.handle] = DeskNonTerminalRecord(status: status, blockedReason: blockedReason, waitingOn: waitingOn)
            default:
                break
            }
        }
        return records
    }
}
