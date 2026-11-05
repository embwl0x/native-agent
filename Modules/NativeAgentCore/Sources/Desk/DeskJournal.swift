import NativeAgentShared
import Darwin
import Foundation
import PersistenceCore
import NativeAgentCore
import Synchronization
// Blueprint: | `DeskJournal.swift` | Locked event feed append, integrity and compaction |
extension SwiftNativeDeskStore {
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
    /// Validate and stamp under the lock; explicit todo starts another life’s stopped work fresh.
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
    /// The caller holds the ops flock; fold tail ops into the base before removing them so items and aliases survive.
    /// Return the post-compaction feed so multi-op transactions continue from the committed view.
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
        // Carry physical row accounting forward because every retained row passed admission.
        var next = DeskFeed(
            base: feed.base, ops: feed.ops + [op],
            fileOpCount: feed.fileOpCount, integrity: feed.integrity
        )
        next.noteAppendedRows(1)
        let state = Self.compact(base: next.base, next.ops)
        if let newBase = try await compactIfNeededUnlocked(state: state, feed: next) {
            next = DeskFeed(base: newBase, ops: [], fileOpCount: 0, integrity: .clean)
        }
        return (state, next)
    }
    func appendOpUnlocked(_ op: DeskOp) async throws {
        try DeskOp.requireComplete([op])
        // Reject projections read before or during the awaited write, even if it throws.
        Self.truthRevision.withLock { $0 += 1 }
        defer { Self.truthRevision.withLock { $0 += 1 } }
        try await SwiftNativePersistenceCore.appendJSONLDurable(op.toJSON(), to: opsPath)
    }
    /// Require the complete retained feed before alias allocation, finding lookup, mutation or compaction.
    func readOpsWithIntegrityUnlocked() async throws -> (ops: [DeskOp], integrity: SnapshotTailOpLog.OpLogIntegrity) {
        let (raw, report) = try await SwiftNativePersistenceCore.readJSONLReporting(opsPath)
        guard report.malformedLineCount == 0, !report.trailingPartialLine else {
            throw DeskError.journalUnavailable(path: opsPath.path,
                reason: "\(report.malformedLineCount) malformed lines; partial tail: \(report.trailingPartialLine)")
        }
        var ops: [DeskOp] = []
        for (index, row) in raw.enumerated() {
            guard let op = DeskOp.fromJSON(row) else {
                throw DeskError.journalUnavailable(path: opsPath.path,
                    reason: "record \(index + 1) (\(row.objectValue?["op"]?.stringValue ?? "missing op")) does not decode")
            }
            ops.append(op)
        }
        let integrity = SnapshotTailOpLog.OpLogIntegrity(
            malformedLineCount: report.malformedLineCount,
            undecodableRowCount: raw.count - ops.count,
            trailingPartialLine: report.trailingPartialLine,
            physicalRowCount: report.physicalLineCount
        )
        SnapshotTailOpLog.noteIntegrity(integrity, feed: Self.logLabel, path: opsPath)
        return (ops, integrity)
    }
    public func opLogHealth() async throws -> SnapshotTailOpLog.OpLogHealth {
        let integrity = try await opLogIntegrity()
        return SnapshotTailOpLog.OpLogHealth(
            feed: Self.logLabel,
            path: opsPath,
            physicalRowCount: integrity.physicalRowCount,
            byteCount: try SnapshotTailOpLog.OpLogHealth.fileSize(opsPath),
            compactionThreshold: opsCompactionThreshold,
            integrity: integrity
        )
    }
    /// Diagnostics retain undecodable-row evidence while functional reads and mutations stay unavailable.
    public func opLogIntegrity() async throws -> SnapshotTailOpLog.OpLogIntegrity {
        let (rows, report) = try await SwiftNativePersistenceCore.readJSONLReporting(opsPath)
        return SnapshotTailOpLog.OpLogIntegrity(
            malformedLineCount: report.malformedLineCount,
            undecodableRowCount: rows.reduce(0) { $0 + (DeskOp.fromJSON($1) == nil ? 1 : 0) },
            trailingPartialLine: report.trailingPartialLine,
            physicalRowCount: report.physicalLineCount)
    }
    /// Read ops before the base so a compaction race cannot pair an old base with a truncated tail.
    /// Prefix-drop prevents duplicate replay after a crash between base write and truncation.
    /// An existing malformed base must fail because tail-only replay would lose compacted items.
    func readFeedUnlocked() async throws -> DeskFeed {
        let (ops, integrity) = try await readOpsWithIntegrityUnlocked()
        try Self.validateAliasDomain(base: nil, ops: ops)
        let fileOpCount = ops.count
        guard FileManager.default.fileExists(atPath: basePath.path) else {
            return DeskFeed(base: nil, ops: ops, fileOpCount: fileOpCount, integrity: integrity)
        }
        // Keep retryable byte-read failures distinct from decoded corruption.
        guard let baseData = try? Data(contentsOf: basePath) else {
            throw DeskError.compactionBaseUnreadable(path: basePath.path)
        }
        guard let raw = try? JSONValue.parse(baseData), raw != .null,
              let base = DeskCompactionBase.fromJSON(raw) else {
            throw DeskError.compactionBaseCorrupt(path: basePath.path)
        }
        try Self.validateAliasDomain(base: base, ops: ops)
        // An absent compacted-op ID leaves the tail intact to avoid dropping unseen work.
        let tail = SnapshotTailOpLog.dropCompactedPrefix(
            ops, lastCompactedOpId: base.lastCompactedOpId, id: { $0.opId }
        )
        return DeskFeed(base: base, ops: tail, fileOpCount: fileOpCount, integrity: integrity)
    }
    /// With the ops flock held, write the base atomically before truncation.
    /// Replay prefix-drop makes a crash between them safe against loss and duplicate application.
    func compactIfNeededUnlocked(
        state: DeskState,
        feed: DeskFeed
    ) async throws -> DeskCompactionBase? {
        guard feed.compactionRowCount >= opsCompactionThreshold else { return nil }
        // Refuse compaction before the last-op guard so even wholly undecodable feeds report without erasing rows.
        guard SnapshotTailOpLog.mayCompact(feed.integrity, feed: Self.logLabel, path: opsPath) else { return nil }
        guard let lastOpId = feed.ops.last?.opId, !lastOpId.isEmpty else { return nil }
        let liveHandles = Set(state.items.map(\.handle))
        // Keep alias high-water for live parents and top level so aliases are never reused.
        let aliasHighWater = Self.foldAliasHighWater(seed: feed.base?.aliasHighWater ?? [:], ops: feed.ops)
            .filter { $0.key.isEmpty || liveHandles.contains($0.key) }
        // Only live items can be reopened, so other repair targets need no retained entry.
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
        // Locked reads and base-plus-following-ops replay require no retained tail.
        try await SnapshotTailOpLog.commitCompaction(
            baseJSON: base.toJSON(), tailRows: [],
            basePath: basePath, opsPath: opsPath
        )
        return base
    }
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

extension DeskOp {
    /// The journal keeps only ops that read back as themselves. A transaction checks every op before it writes the first, so a refused op
    /// never leaves its siblings half-written (a queue item without its step).
    static func requireComplete(_ ops: [DeskOp]) throws {
        for op in ops {
            let encoded = op.toJSON()
            guard let decoded = DeskOp.fromJSON(encoded), decoded.toJSON() == encoded else { throw DeskError.invalidOperation(token: op.op) }
        }
    }
}
