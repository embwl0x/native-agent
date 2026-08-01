import Foundation

// MARK: - SwiftNativeDeskStore — append-under-flock event store for Agent Desk
//
// Mirrors SwiftNativeTaskLedger EXACTLY: stateless (all state on disk), every
// mutation is an op appended under the events-feed flock, and the derived
// state.json is RECOMPACTED FROM OPS IN THE SAME LOCK so the materialized view
// can never lag a committed append and a concurrent recompaction can't race.
//
// STORE PATHS (under <dataRoot>/desk/):
//   • desk_ops.jsonl   (+ .lock) — append-only op events. The canonical TRUTH
//     is base+tail: dropping an old op is only ever done by compaction, which
//     first snapshots the FULL reduced state (plus the ledgers that live in
//     raw op history) into desk_ops_base.json.
//   • desk_ops_base.json         — compaction snapshot the replay seeds from.
//   • desk_state.json            — derived materialized state (rebuilt in-lock).
//   • desk_archive.jsonl         — append-only archived item records, capped
//     at newest-5000 via appendJSONLCapped (audit 2026-07-21 — it was the
//     module's only uncapped JSONL; the op-log base+tail is the truth, the
//     archive feed is receipt-class display/idempotency data).
//
// OP-LOG COMPACTION (mirrors GitHubCommandStore, audit round 2 F1): once the
// feed crosses `opsCompactionThreshold` lines, the end of the locked write
// transaction snapshots the reduced state into the base and truncates the
// op-log atomically. Replay = base + ops that FOLLOW `lastCompactedOpId`.
// Reads take ops FIRST, base SECOND, and prefix-drop via `lastCompactedOpId`,
// so a crash between base-write and truncate is healed (never lost, never
// double-applied). Three ledgers live in RAW op history, not DeskState, and
// ride the base explicitly:
//   1. aliasHighWater — nextAlias scans every create ever made (incl. archived
//      items') so an alias is NEVER reused; truncation without the high-water
//      map would resurrect retired aliases.
//   2. lastNonTerminal — the reconcile repair's "reopen to last recorded
//      non-terminal status" target.
//   3. the Lamport commit-stamp floor — commitStamp must floor on the BASE's
//      generatedTs once the tail is truncated, or a second writer process
//      could stamp behind compacted ops.

public enum DeskError: Error, LocalizedError, Sendable, Equatable {
    case unknownHandle(String)
    case terminalStatusRefusedNonTerminalChild(handle: String, childHandle: String)
    case childRefusedTerminalParent(parentHandle: String)
    case nonTerminalStatusRefusedTerminalAncestor(handle: String, ancestorHandle: String)
    case directArchiveRequiresGuardedPath(handle: String)
    case archiveRefusedNonTerminalChild(handle: String, childHandle: String)
    case archiveRefusedStanding(handle: String)
    case archiveRefusedNonTerminalSelf(handle: String, status: DeskStatus)
    // Pursuit invariants (H2 / M7).
    case pursuitCapReached(openCount: Int)
    case pursuitFieldMissing(reason: String)
    case pursuitDossierInvalid(reason: String)
    case agentOriginRequiresPursuit(handle: String)
    case genericPathCannotCreateAgent(handle: String)
    case notAPursuit(handle: String)
    case workSessionCapReached(scope: String, limit: Int, handle: String)
    case unknownReservation(reservationId: String, handle: String)
    case reservationAlreadyComplete(reservationId: String, handle: String)
    /// The compaction base exists on disk but does not decode. Replaying from
    /// the tail alone would silently blank every compacted item, so reads FAIL
    /// LOUD instead (fail-loud over fail-over).
    case compactionBaseCorrupt(path: String)
    /// The compaction base exists but its BYTES could not be read (transient IO:
    /// EMFILE burst, a not-yet-materialized iCloud dataless file). Distinct from
    /// compactionBaseCorrupt so a retryable IO error is never laundered into a
    /// permanent corruption verdict that bricks every read AND write
    /// (2026-07-31 sweep wave 2; same fix landed in TaskLedger/GitHubCommand).
    case compactionBaseUnreadable(path: String)

    public var errorDescription: String? {
        switch self {
        case .unknownHandle(let h):
            return "desk: no item with handle \(h)"
        case let .terminalStatusRefusedNonTerminalChild(handle, childHandle):
            return "desk: cannot close \(handle) — child \(childHandle) is not terminal (done/canceled)"
        case .childRefusedTerminalParent(let parentHandle):
            return "desk: cannot add a child under terminal parent \(parentHandle); reopen the parent first"
        case let .nonTerminalStatusRefusedTerminalAncestor(handle, ancestorHandle):
            return "desk: cannot reopen \(handle) while ancestor \(ancestorHandle) is terminal; reopen the ancestor first"
        case .directArchiveRequiresGuardedPath(let handle):
            return "desk: cannot append archive op directly for \(handle); use archiveItem so archive guards and records are preserved"
        case let .archiveRefusedNonTerminalChild(handle, childHandle):
            return "desk: cannot archive \(handle) — child \(childHandle) is not terminal (done/canceled)"
        case .archiveRefusedStanding(let h):
            return "desk: cannot archive standing item \(h) (MVP)"
        case let .archiveRefusedNonTerminalSelf(handle, status):
            return "desk: cannot archive \(handle) — item is not terminal (status \(status.rawValue)); close it first"
        case .pursuitCapReached(let openCount):
            return "desk: cap reached — \(openCount) open self-pursuits already (max 2); close or abandon one before opening or reopening another"
        case .pursuitFieldMissing(let reason):
            return "desk: pursuit refused — \(reason)"
        case .pursuitDossierInvalid(let reason):
            return "desk: pursuit evidence refused — \(reason)"
        case .agentOriginRequiresPursuit(let handle):
            return "desk: an origin=agent item (\(handle)) must be kind=project and carry a valid pursuit dossier"
        case .genericPathCannotCreateAgent(let handle):
            return "desk: the generic add-item path cannot create an origin=agent pursuit (\(handle)); use openPursuit"
        case .notAPursuit(let handle):
            return "desk: \(handle) is not a self-pursuit (origin=agent, kind=project)"
        case let .workSessionCapReached(scope, limit, handle):
            return "desk: work-session cap reached — \(scope) limit \(limit) for \(handle) already met today"
        case let .unknownReservation(reservationId, handle):
            return "desk: no reservation \(reservationId) on \(handle); reserve the slot before completing it"
        case let .reservationAlreadyComplete(reservationId, handle):
            return "desk: reservation \(reservationId) on \(handle) is already complete; a slot completes once"
        case .compactionBaseCorrupt(let path):
            return "desk: compaction base at \(path) exists but does not decode — refusing to replay from the tail alone (that would silently drop every compacted item)"
        case .compactionBaseUnreadable(let path):
            return "desk: compaction base at \(path) exists but its bytes could not be read (transient IO) — retry rather than treating the desk as corrupt"
        }
    }
}

/// "Last recorded non-terminal status" for one item — the reconcile repair's
/// reopen target. Lives in the compaction base because it is derived from RAW
/// op history (a terminal item's pre-terminal status is not in DeskState).
struct DeskNonTerminalRecord: Sendable, Equatable {
    var status: DeskStatus
    var blockedReason: String?
    var waitingOn: String?

    func toJSON() -> JSONValue {
        var obj: [String: JSONValue] = ["status": .string(status.rawValue)]
        if let blockedReason, !blockedReason.isEmpty { obj["blockedReason"] = .string(blockedReason) }
        if let waitingOn, !waitingOn.isEmpty { obj["waitingOn"] = .string(waitingOn) }
        return .object(obj)
    }

    static func fromJSON(_ value: JSONValue) -> DeskNonTerminalRecord? {
        guard case .object(let obj) = value,
              case .string(let raw)? = obj["status"],
              let status = DeskStatus(rawValue: raw) else { return nil }
        func str(_ k: String) -> String? {
            if case .string(let s)? = obj[k] { return s }
            return nil
        }
        return DeskNonTerminalRecord(status: status, blockedReason: str("blockedReason"), waitingOn: str("waitingOn"))
    }
}

/// The op-log's compaction snapshot. `state` is the FULL reduced desk state
/// through `lastCompactedOpId`; `aliasHighWater` and `lastNonTerminal` carry
/// the two ledgers that live in raw op history rather than in DeskState.
/// Replay seeds from it and applies only ops that follow `lastCompactedOpId`.
struct DeskCompactionBase: Sendable {
    let state: DeskState
    /// Highest create-op alias seq ever assigned per parent scope ("" = top
    /// level, otherwise the parent handle). nextAlias takes max(highWater,
    /// tail creates) + 1 so a retired alias is never reused after truncation.
    let aliasHighWater: [String: Int]
    /// handle → last recorded non-terminal status (reconcile's reopen target).
    let lastNonTerminal: [String: DeskNonTerminalRecord]
    let lastCompactedOpId: String
    let compactedAt: String
    let compactedOpCount: Int

    func toJSON() -> JSONValue {
        .object([
            "version": .int(1),
            "state": state.toJSON(),
            "aliasHighWater": .object(aliasHighWater.mapValues { .int(Int64($0)) }),
            "lastNonTerminal": .object(lastNonTerminal.mapValues { $0.toJSON() }),
            "lastCompactedOpId": .string(lastCompactedOpId),
            "compactedAt": .string(compactedAt),
            "compactedOpCount": .int(Int64(compactedOpCount)),
        ])
    }

    /// STRICT decode — any malformed row fails the whole base, and the caller
    /// throws rather than replaying from the tail alone. The ledger maps are
    /// REQUIRED keys (the writer always emits them, even empty): a base
    /// missing them would decode "valid" with empty ledgers and silently
    /// reuse retired aliases / degrade reconcile repairs to `.watch`
    /// (gpt-5.5 compaction review HIGH).
    static func fromJSON(_ value: JSONValue) -> DeskCompactionBase? {
        guard case .object(let obj) = value,
              let stateVal = obj["state"], let state = DeskState.fromJSON(stateVal),
              // ROUND-TRIP GATE. The shared decoders are deliberately tolerant
              // (unknown ref kinds skipped, wrong-typed string arrays → []),
              // which is right for forward-compat readers but wrong for the
              // base — after the truncate this snapshot is the ONLY copy, so a
              // tolerated-then-DROPPED field (a shrunken notify.on, a lost
              // citation list, a future version's extra key) means the decode
              // did NOT faithfully reproduce the snapshot → corrupt, fail loud.
              //
              // The gate is DECODE-STABILITY + SHAPE-PRESERVATION, not byte
              // identity. Byte identity was wrong: the store's own MIGRATION
              // vocabulary legitimately rewrites values on decode — the retired
              // private origin raw value maps to `.agent` (DeskOrigin
              // .decodePersisted) and re-encodes as "agent", and Pursuit's
              // init clamps maxSessions/maxDays into range. A base carrying
              // either failed the identity check, so fromJSON returned nil and
              // readFeedUnlocked threw compactionBaseCorrupt — bricking EVERY
              // desk read and write on launch with no degradation path.
              // Normalization is not corruption; DROPPED DATA is. So:
              //   1. re-encode, decode again, re-encode — the two encodings must
              //      match, i.e. normalization applied once is a FIXED POINT
              //      (a decoder that keeps changing its mind is not trustworthy
              //      as the sole surviving copy);
              //   2. the encoding must have the SAME SHAPE as the tree on disk
              //      — same object key sets, same array counts, recursively.
              // (2) is what preserves the fail-loud contract: a value the
              // decoder normalizes in place (origin, a clamped bound) keeps the
              // key and passes; anything the decoder cannot represent —
              // an unknown extra field, a dropped ref, a collapsed notify.on —
              // changes the shape and still fails loud.
              deskBaseRoundTripIsFaithful(decoded: state, onDisk: stateVal),
              case .string(let lastCompactedOpId)? = obj["lastCompactedOpId"],
              !lastCompactedOpId.isEmpty,
              case .string(let compactedAt)? = obj["compactedAt"],
              case .object(let hw)? = obj["aliasHighWater"],
              case .object(let lnt)? = obj["lastNonTerminal"] else { return nil }
        var aliasHighWater: [String: Int] = [:]
        for (k, v) in hw {
            guard case .int(let i) = v else { return nil }
            aliasHighWater[k] = Int(i)
        }
        var lastNonTerminal: [String: DeskNonTerminalRecord] = [:]
        for (k, v) in lnt {
            guard let rec = DeskNonTerminalRecord.fromJSON(v) else { return nil }
            lastNonTerminal[k] = rec
        }
        var compactedOpCount = 0
        if case .int(let c)? = obj["compactedOpCount"] { compactedOpCount = Int(c) }
        return DeskCompactionBase(
            state: state,
            aliasHighWater: aliasHighWater,
            lastNonTerminal: lastNonTerminal,
            lastCompactedOpId: lastCompactedOpId,
            compactedAt: compactedAt,
            compactedOpCount: compactedOpCount
        )
    }
}

/// The compaction base's round-trip gate (see `DeskCompactionBase.fromJSON`).
/// True when re-encoding the decoded state is FAITHFUL to the tree on disk:
///
///   1. DECODE-STABILITY — decoding the re-encoded tree and encoding it again
///      reproduces the same tree. Normalization applied once must be a fixed
///      point, so whatever the decoder rewrote it has now finished rewriting.
///   2. SHAPE-PRESERVATION — the re-encoded tree has the same object key sets,
///      the same array counts, and the same scalar JSON kinds as the tree on
///      disk, recursively. Only scalar VALUES may differ.
///
/// (2) is the fail-loud half. The store's migration vocabulary rewrites scalars
/// in place (the retired origin raw value → "agent"; a Pursuit bound clamped
/// into range) and that is a faithful read of an intact snapshot. Everything
/// the decoder cannot represent — an unknown extra key, a skipped ref, a
/// wrong-typed `notify.on` that collapses to [] and drops the key, a scalar
/// whose TYPE the decoder had to coerce — changes the shape and is refused.
func deskBaseRoundTripIsFaithful(decoded state: DeskState, onDisk: JSONValue) -> Bool {
    let encoded = state.toJSON()
    guard let restable = DeskState.fromJSON(encoded), restable.toJSON() == encoded else { return false }
    return deskJSONShapeMatches(encoded, onDisk)
}

/// Recursive shape equality: same object key sets, same array counts, same
/// scalar kinds. Scalar payloads are compared EXCEPT under the named migration
/// keys — the only places the decoder legitimately rewrites a value in place
/// (retired origin raw value → "agent"; Pursuit bounds clamped into range).
/// Everything else must round-trip byte-faithful: without this allowlist, any
/// unknown enum token that decodes to a default (a future notify.level, a
/// future cadence.mode) would be silently rewritten in the only surviving
/// base snapshot (gpt-5.5 wave review, 2026-07-31).
private let deskScalarMigrationKeys: Set<String> = ["origin", "maxSessions", "maxDays"]

private func deskJSONShapeMatches(_ a: JSONValue, _ b: JSONValue, key: String? = nil) -> Bool {
    switch (a, b) {
    case let (.object(ao), .object(bo)):
        guard Set(ao.keys) == Set(bo.keys) else { return false }
        for (k, av) in ao {
            guard let bv = bo[k], deskJSONShapeMatches(av, bv, key: k) else { return false }
        }
        return true
    case let (.array(aa), .array(ba)):
        guard aa.count == ba.count else { return false }
        return zip(aa, ba).allSatisfy { deskJSONShapeMatches($0, $1, key: key) }
    case (.null, .null):
        return true
    case (.bool, .bool), (.int, .int), (.double, .double), (.string, .string):
        if a == b { return true }
        return key.map { deskScalarMigrationKeys.contains($0) } ?? false
    default:
        return false
    }
}

/// One consistent read of the replayable feed: compaction base (if any), the
/// tail ops that FOLLOW it, and the raw op-log line count (pre prefix-drop —
/// the compaction threshold keys on actual file size).
struct DeskFeed: Sendable {
    let base: DeskCompactionBase?
    var ops: [DeskOp]
    var fileOpCount: Int

    /// Newest committed timestamp across base + tail — the Lamport floor every
    /// commit stamp must clear. After a truncate the tail can be empty; without
    /// the base's generatedTs a second writer process could stamp BEHIND
    /// compacted ops and break commit-order == timestamp-order.
    var maxCommittedTs: String? {
        let tailMax = ops.map(\.ts).max()
        let baseTs: String? = base.flatMap { $0.state.generatedTs.isEmpty ? nil : $0.state.generatedTs }
        switch (tailMax, baseTs) {
        case let (t?, b?): return max(t, b)
        case let (t?, nil): return t
        case let (nil, b?): return b
        default: return nil
        }
    }
}

public struct SwiftNativeDeskStore: Sendable {
    public static let logLabel = "DeskStore"
    /// Default archive-grace window for done items (48h) before they become
    /// sweep-eligible.
    public static let defaultArchiveGrace: TimeInterval = 48 * 60 * 60

    /// HARD CAPS (store-enforced, not prompt-enforced) — the Workshop budget.
    /// ≤2 OPEN self-pursuits at once; ≤2 work sessions per pursuit per day;
    /// ≤6 workshop work sessions per day across all pursuits.
    public static let maxOpenAgentPursuits = 2
    public static let maxWorkSessionsPerPursuitPerDay = 2
    public static let maxWorkSessionsGlobalPerDay = 6

    public let dataRoot: URL
    public let persistence: any PersistenceCoreProtocol
    private let changeBus: StoreChangeBus
    /// Op-log lines that trigger a snapshot+truncate at the end of the next
    /// locked write transaction (mirrors GitHubCommandStore). Injectable for
    /// tests.
    let opsCompactionThreshold: Int

    public init(
        dataRoot: URL,
        persistence: any PersistenceCoreProtocol = SwiftNativePersistenceCore(),
        changeBus: StoreChangeBus = .shared,
        opsCompactionThreshold: Int = 2_048
    ) {
        self.dataRoot = dataRoot
        self.persistence = persistence
        self.changeBus = changeBus
        self.opsCompactionThreshold = max(2, opsCompactionThreshold)
    }

    private var deskDir: URL { dataRoot.appendingPathComponent("desk", isDirectory: true) }
    /// `<dataRoot>/desk/desk_ops.jsonl`.
    public var opsPath: URL { deskDir.appendingPathComponent("desk_ops.jsonl") }
    /// `<dataRoot>/desk/desk_ops_base.json` — the compaction snapshot the
    /// op-log replays FROM. Written atomically BEFORE the op-log truncate; a
    /// crash between the two is healed by the replay prefix-drop.
    public var basePath: URL { deskDir.appendingPathComponent("desk_ops_base.json") }
    /// `<dataRoot>/desk/desk_state.json`.
    public var statePath: URL { deskDir.appendingPathComponent("desk_state.json") }
    /// `<dataRoot>/desk/desk_archive.jsonl`.
    public var archivePath: URL { deskDir.appendingPathComponent("desk_archive.jsonl") }

    // MARK: - Op append (mirrors SwiftNativeTaskLedger.append)

    /// Append one op under the ops-feed flock, then recompact the derived state
    /// file IN THE SAME LOCK.
    @discardableResult
    public func append(_ op: DeskOp) async throws -> DeskOp {
        try await persistence.withFileLock(opsPath) {
            let feed = try await readFeedUnlocked()
            let state = Self.compact(base: feed.base, feed.ops)
            try Self.validateHierarchyTransition(op, in: state, allowArchive: false)
            try Self.validatePursuitInvariants(op, in: state, viaGenericPath: true)
            _ = try await appendAndRecompactUnlocked(op, feed: feed)
        }
        return op
    }

    /// Append an op that targets an EXISTING LIVE item — validates the handle
    /// under the flock and throws `unknownHandle` if it is missing or archived,
    /// so a mutation on a bad handle can't silently no-op (gpt-5.5 review HIGH).
    /// The op's ts is RE-STAMPED here, inside the flock, with a commit stamp
    /// past the newest committed ts — a ts minted at op construction can stall
    /// before the lock and commit BEHIND a notify CAS stamp, so the evaluator
    /// would see updatedAt <= lastNotifiedAt and swallow the change
    /// (gpt-5.5 review HIGH).
    @discardableResult
    private func appendValidated(_ op: DeskOp) async throws -> DeskOp {
        try await persistence.withFileLock(opsPath) {
            let feed = try await readFeedUnlocked()
            let state = Self.compact(base: feed.base, feed.ops)
            guard state.items.contains(where: { $0.handle == op.handle }) else {
                throw DeskError.unknownHandle(op.handle)
            }
            try Self.validateHierarchyTransition(op, in: state, allowArchive: false)
            try Self.validatePursuitInvariants(op, in: state, viaGenericPath: false)
            var stamped = op
            stamped.ts = DeskClock.commitStamp(notBefore: feed.maxCommittedTs)
            _ = try await appendAndRecompactUnlocked(stamped, feed: feed)
            return stamped
        }
    }

    /// Append one canonical op, rebuild + write the derived state, then run the
    /// end-of-transaction compaction check. The canonical truth is base+tail:
    /// an op only ever leaves the tail by being folded into the base snapshot
    /// first, so a live item can never vanish and a retired alias can never be
    /// reused (the original "UNCAPPED" contract, now bounded by compaction).
    /// The caller already holds the ops flock. Returns the committed state plus
    /// the updated feed so multi-op transactions (reconcile) can continue from
    /// a post-compaction view without re-reading the disk.
    @discardableResult
    private func appendAndRecompactUnlocked(
        _ op: DeskOp,
        feed: DeskFeed
    ) async throws -> (state: DeskState, feed: DeskFeed) {
        try await persistence.appendJSONL(op.toJSON(), to: opsPath)
        changeBus.emit(StoreChange(store: .desk, path: opsPath))
        var next = DeskFeed(base: feed.base, ops: feed.ops + [op], fileOpCount: feed.fileOpCount + 1)
        let state = Self.compact(base: next.base, next.ops)
        try await persistence.writeJSON(state.toJSON(), to: statePath)
        if let newBase = try await compactIfNeededUnlocked(state: state, feed: next) {
            next = DeskFeed(base: newBase, ops: [], fileOpCount: 0)
        }
        return (state, next)
    }

    /// Read all ops in the FILE (no lock, no base). JSONL appends are
    /// line-atomic via O_APPEND so a reader sees whole lines. Post-compaction
    /// this is only the tail (plus a stale prefix in the crash window) — use
    /// `readFeedUnlocked`/`liveState` for anything semantic.
    public func readOpsUnlocked() async throws -> [DeskOp] {
        let raw = try await persistence.readJSONL(opsPath)
        return raw.compactMap { DeskOp.fromJSON($0) }
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
        let ops = try await readOpsUnlocked()
        let fileOpCount = ops.count
        guard FileManager.default.fileExists(atPath: basePath.path) else {
            return DeskFeed(base: nil, ops: ops, fileOpCount: fileOpCount)
        }
        // Read the bytes directly so a transient IO failure (EMFILE, a dataless
        // iCloud file) throws a RETRYABLE error instead of collapsing to the
        // readJSON default that then reads as permanent corruption (2026-07-31
        // sweep wave 2). Only a genuine parse/decode failure is corruption.
        guard let baseData = try? Data(contentsOf: basePath) else {
            throw DeskError.compactionBaseUnreadable(path: basePath.path)
        }
        guard let raw = try? JSONValue.parse(baseData), raw != .null,
              let base = DeskCompactionBase.fromJSON(raw) else {
            throw DeskError.compactionBaseCorrupt(path: basePath.path)
        }
        // Prefix-drop via the shared snapshot+tail engine (byte-identical to the
        // old inline `lastIndex` scan): keep only the ops that FOLLOW the base's
        // lastCompactedOpId. Absent id → genesis/already-tail → ops unchanged.
        let tail = SnapshotTailOpLog.dropCompactedPrefix(
            ops, lastCompactedOpId: base.lastCompactedOpId, id: { $0.opId }
        )
        return DeskFeed(base: base, ops: tail, fileOpCount: fileOpCount)
    }

    /// Snapshot+truncate once the op-log file crosses the threshold. The
    /// caller holds the ops flock and passes the just-committed state plus the
    /// POST-append feed (tail includes the ops just written). Base is written
    /// atomically BEFORE the truncate; the replay prefix-drop makes the
    /// in-between crash window safe (never lost, never double-applied).
    /// Returns the new base when compaction ran, nil otherwise.
    private func compactIfNeededUnlocked(
        state: DeskState,
        feed: DeskFeed
    ) async throws -> DeskCompactionBase? {
        guard feed.fileOpCount >= opsCompactionThreshold,
              let lastOpId = feed.ops.last?.opId, !lastOpId.isEmpty else { return nil }
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
            basePath: basePath, opsPath: opsPath, persistence: persistence
        )
        return base
    }

    /// Fold create-op aliases into the per-parent high-water map. Mirrors
    /// nextAlias's counting: top-level aliases parse as whole integers,
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
            case let .createItem(alias, _, _, _, parent, _, _, _):
                if let parent {
                    bump(parent, seq: alias.split(separator: ".").last.flatMap { Int($0) })
                } else {
                    bump("", seq: Int(alias))
                }
            case let .openPursuit(alias, _, _, _, _):
                bump("", seq: Int(alias))
            default:
                break
            }
        }
        return highWater
    }

    /// Fold "last recorded non-terminal status" per handle. Mirrors
    /// lastNonTerminalStatus: a create seeds `.watch`, a non-terminal
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
            case let .setStatus(status, blockedReason, waitingOn) where !status.isTerminal:
                records[op.handle] = DeskNonTerminalRecord(status: status, blockedReason: blockedReason, waitingOn: waitingOn)
            default:
                break
            }
        }
        return records
    }

    // MARK: - High-level mutations (each appends exactly one op)

    /// Create an item. Generates a stable handle and assigns the next monotonic
    /// alias among the parent's siblings — done UNDER THE FLOCK so two
    /// concurrent creates can't collide on an alias. Returns the created item.
    @discardableResult
    public func createItem(
        kind: DeskKind,
        project: String,
        title: String,
        parent: String? = nil,
        summary: String? = nil
    ) async throws -> DeskItem {
        return try await persistence.withFileLock(opsPath) {
            let feed = try await readFeedUnlocked()
            let priorState = Self.compact(base: feed.base, feed.ops)
            // Resolve the parent's alias (if any) so a child alias nests under it.
            // Validate against LIVE state — not just the create-op history — so a
            // child can't be created under an archived/aged-out parent and then
            // dangle as an orphan.
            var parentAlias: String?
            if let parent {
                guard let live = priorState.items.first(where: { $0.handle == parent }) else {
                    throw DeskError.unknownHandle(parent)
                }
                guard !live.status.isTerminal else {
                    throw DeskError.childRefusedTerminalParent(parentHandle: parent)
                }
                parentAlias = live.alias
            }
            let alias = Self.nextAlias(parentHandle: parent, parentAlias: parentAlias, base: feed.base, ops: feed.ops)
            let handle = DeskClock.newHandle()
            // The generic create path is HARD-PINNED to origin=.owner with no
            // pursuit (H2) — an origin=agent pursuit can ONLY be minted through
            // openPursuit, which builds the create op with a validated dossier.
            let op = DeskOp(ts: DeskClock.commitStamp(notBefore: feed.maxCommittedTs), handle: handle, body: .createItem(
                alias: alias, kind: kind, project: project, title: title, parent: parent, summary: summary,
                origin: .owner, pursuit: nil
            ))
            try Self.validateHierarchyTransition(op, in: priorState, allowArchive: false)
            try Self.validatePursuitInvariants(op, in: priorState, viaGenericPath: true)
            let committedState = try await appendAndRecompactUnlocked(op, feed: feed).state
            guard let created = committedState.items.first(where: { $0.handle == handle }) else {
                throw DeskError.unknownHandle(handle)
            }
            return created
        }
    }

    /// add_child(parentHandle, kind?, title) = create_item with the parent set.
    /// Child kind defaults to the parent's kind; project is inherited.
    @discardableResult
    public func addChild(parentHandle: String, kind: DeskKind? = nil, title: String) async throws -> DeskItem {
        // Locked read (liveState) so the kind/project inheritance can't come
        // from a compaction-racing stale snapshot; createItem re-validates the
        // parent under its own lock before committing.
        guard let parent = try await liveState().items.first(where: { $0.handle == parentHandle }) else {
            throw DeskError.unknownHandle(parentHandle)
        }
        return try await createItem(
            kind: kind ?? parent.kind,
            project: parent.project,
            title: title,
            parent: parentHandle
        )
    }

    /// openPursuit — the ONLY path to an origin=agent item (H2). Creates a
    /// kind=project pursuit carrying a validated dossier on the create op payload
    /// (M10). REFUSES on: a missing required field, an invalid/friction-only
    /// dossier (M7), or the open-pursuit cap (≤2 open self-pursuits). All checks
    /// run UNDER THE FLOCK against ops-derived state so a refusal can't race a
    /// sibling create. Returns the store's honest error on refusal.
    @discardableResult
    public func openPursuit(
        project: String,
        title: String,
        pursuit: Pursuit,
        summary: String? = nil
    ) async throws -> DeskItem {
        return try await persistence.withFileLock(opsPath) {
            let feed = try await readFeedUnlocked()
            let alias = Self.nextAlias(parentHandle: nil, parentAlias: nil, base: feed.base, ops: feed.ops)
            let handle = DeskClock.newHandle()
            let op = DeskOp(
                ts: DeskClock.commitStamp(notBefore: feed.maxCommittedTs),
                handle: handle,
                body: .openPursuit(
                    alias: alias, project: project, title: title,
                    summary: summary, pursuit: pursuit
                )
            )
            let state = Self.compact(base: feed.base, feed.ops)
            try Self.validateHierarchyTransition(op, in: state, allowArchive: false)
            // Not viaGenericPath — this IS the dedicated path; still fully gated
            // on fields + dossier + the open-pursuit cap.
            try Self.validatePursuitInvariants(op, in: state, viaGenericPath: false)
            let after = try await appendAndRecompactUnlocked(op, feed: feed).state
            guard let created = after.items.first(where: { $0.handle == handle }) else {
                throw DeskError.unknownHandle(handle)
            }
            return created
        }
    }

    /// reserveWorkSession — INTERNAL API (no chat tool; H5 groundwork). Reserve
    /// one durable work slot on a pursuit. IDEMPOTENT per (handle, day, slot):
    /// a repeat returns the SAME reservation id without a new op or a cap charge.
    /// REFUSES when the pursuit already has 2 reservations today, or the whole
    /// workshop already has 6 today — both counted from the ops feed, never a
    /// mutable counter. Returns the reservation id.
    @discardableResult
    public func reserveWorkSession(_ handle: String, day: String, slot: String) async throws -> String {
        try await persistence.withFileLock(opsPath) {
            let feed = try await readFeedUnlocked()
            let state = Self.compact(base: feed.base, feed.ops)
            guard let item = state.items.first(where: { $0.handle == handle }) else {
                throw DeskError.unknownHandle(handle)
            }
            guard item.isPursuit else { throw DeskError.notAPursuit(handle: handle) }
            let reservationId = DeskClock.reservationId(handle: handle, day: day, slot: slot)
            // Idempotent short-circuit: the exact slot already exists → no charge.
            if item.pursuit?.reservations.contains(where: { $0.reservationId == reservationId }) == true {
                return reservationId
            }
            let op = DeskOp(
                ts: DeskClock.commitStamp(notBefore: feed.maxCommittedTs),
                handle: handle,
                body: .reserveWorkSession(reservationId: reservationId, day: day, slot: slot)
            )
            // Single gate: the caps live in validatePursuitInvariants so the
            // generic append path enforces them identically (H1).
            try Self.validatePursuitInvariants(op, in: state, viaGenericPath: false)
            _ = try await appendAndRecompactUnlocked(op, feed: feed)
            return reservationId
        }
    }

    /// completeWorkSession — INTERNAL API. Close out a reserved slot with a work
    /// receipt (appended as a note on the pursuit). REFUSES an unknown
    /// reservation id (a receipt must ride a real reservation — H5).
    @discardableResult
    public func completeWorkSession(_ handle: String, reservationId: String, receipt: String) async throws -> DeskOp {
        try await persistence.withFileLock(opsPath) {
            let feed = try await readFeedUnlocked()
            let state = Self.compact(base: feed.base, feed.ops)
            guard let item = state.items.first(where: { $0.handle == handle }) else {
                throw DeskError.unknownHandle(handle)
            }
            guard item.isPursuit else { throw DeskError.notAPursuit(handle: handle) }
            let op = DeskOp(
                ts: DeskClock.commitStamp(notBefore: feed.maxCommittedTs),
                handle: handle,
                body: .completeWorkSession(reservationId: reservationId, receipt: receipt)
            )
            // Single gate: reservation-exists AND not-already-complete live in
            // the validator so the generic append path enforces them too.
            try Self.validatePursuitInvariants(op, in: state, viaGenericPath: false)
            _ = try await appendAndRecompactUnlocked(op, feed: feed)
            return op
        }
    }

    /// appendWorkReceipt — desk_work_log's store method. Append a plain work
    /// receipt note to a pursuit (no reservation needed — Agent logging progress
    /// from chat). REFUSES a non-pursuit target so work receipts stay pursuit-scoped.
    @discardableResult
    public func appendWorkReceipt(_ handle: String, receipt: String) async throws -> DeskOp {
        try await persistence.withFileLock(opsPath) {
            let feed = try await readFeedUnlocked()
            let state = Self.compact(base: feed.base, feed.ops)
            guard let item = state.items.first(where: { $0.handle == handle }) else {
                throw DeskError.unknownHandle(handle)
            }
            guard item.isPursuit else { throw DeskError.notAPursuit(handle: handle) }
            let op = DeskOp(
                ts: DeskClock.commitStamp(notBefore: feed.maxCommittedTs),
                handle: handle,
                body: .workLog(receipt: receipt)
            )
            _ = try await appendAndRecompactUnlocked(op, feed: feed)
            return op
        }
    }

    @discardableResult
    public func setStatus(_ handle: String, status: DeskStatus, blockedReason: String? = nil, waitingOn: String? = nil) async throws -> DeskOp {
        try await appendValidated(DeskOp(handle: handle, body: .setStatus(status: status, blockedReason: blockedReason, waitingOn: waitingOn)))
    }

    @discardableResult
    public func updateTitle(_ handle: String, title: String? = nil, summary: String? = nil) async throws -> DeskOp {
        try await appendValidated(DeskOp(handle: handle, body: .updateTitle(title: title, summary: summary)))
    }

    @discardableResult
    public func addRef(_ handle: String, ref: DeskRef) async throws -> DeskOp {
        try await appendValidated(DeskOp(handle: handle, body: .addRef(ref: ref)))
    }

    @discardableResult
    public func updateRef(_ handle: String, refId: String, cachedFields: [String: JSONValue]) async throws -> DeskOp {
        try await appendValidated(DeskOp(handle: handle, body: .updateRef(refId: refId, cachedFields: cachedFields)))
    }

    @discardableResult
    public func appendNote(_ handle: String, text: String) async throws -> DeskOp {
        try await appendValidated(DeskOp(handle: handle, body: .appendNote(text: text)))
    }

    @discardableResult
    public func setCadence(_ handle: String, cadence: Cadence) async throws -> DeskOp {
        try await appendValidated(DeskOp(handle: handle, body: .setCadence(cadence: cadence)))
    }

    @discardableResult
    public func setNotify(_ handle: String, policy: NotifyPolicy) async throws -> DeskOp {
        try await appendValidated(DeskOp(handle: handle, body: .setNotify(policy: policy)))
    }

    /// close_item -> status=done (or canceled), closedAt=now, summary=outcomeSummary.
    @discardableResult
    public func closeItem(_ handle: String, outcomeSummary: String, canceled: Bool = false) async throws -> DeskOp {
        let status: DeskStatus = canceled ? .canceled : .done
        return try await appendValidated(DeskOp(handle: handle, body: .closeItem(outcomeSummary: outcomeSummary, status: status)))
    }

    /// CAS close for operator sweeps (2026-07-21 audit): re-read the item
    /// UNDER the ops flock and close only if it is still live and untouched
    /// since the caller planned (updatedAt equality). DeskSweepCLI's staleness
    /// guard previously ran as a separate liveState() read before closeItem —
    /// a TOCTOU window in which a concurrent mutation between the two
    /// transactions got stomped. Returns false (no op appended) when the item
    /// changed or reached a terminal state since planning.
    @discardableResult
    public func closeItemIfUnchanged(_ handle: String, expectedUpdatedAt: String, outcomeSummary: String, canceled: Bool = false) async throws -> Bool {
        try await persistence.withFileLock(opsPath) {
            let feed = try await readFeedUnlocked()
            let state = Self.compact(base: feed.base, feed.ops)
            guard let item = state.items.first(where: { $0.handle == handle }) else {
                throw DeskError.unknownHandle(handle)
            }
            guard !item.status.isTerminal, item.updatedAt == expectedUpdatedAt else { return false }
            let status: DeskStatus = canceled ? .canceled : .done
            var op = DeskOp(handle: handle, body: .closeItem(outcomeSummary: outcomeSummary, status: status))
            try Self.validateHierarchyTransition(op, in: state, allowArchive: false)
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
        try await persistence.withFileLock(opsPath) {
            var feed = try await readFeedUnlocked()
            var state = Self.compact(base: feed.base, feed.ops)
            // DeskState is parent-before-descendant. Reopen outer terminal
            // parents first so a nested repair never sits beneath a terminal
            // ancestor while its compensating event is appended.
            let candidates = state.items.filter { item in
                item.status.isTerminal
                    && Self.descendants(of: item.handle, in: state).contains(where: { !$0.status.isTerminal })
            }

            var repairs: [DeskOp] = []
            for candidate in candidates {
                guard let live = state.items.first(where: { $0.handle == candidate.handle }),
                      live.status.isTerminal,
                      Self.descendants(of: live.handle, in: state).contains(where: { !$0.status.isTerminal }) else {
                    continue
                }
                let prior = Self.lastNonTerminalStatus(for: live.handle, base: feed.base, in: feed.ops)
                let repair = DeskOp(
                    ts: DeskClock.commitStamp(notBefore: feed.maxCommittedTs),
                    handle: live.handle,
                    body: .setStatus(
                        status: prior.status,
                        blockedReason: prior.blockedReason,
                        waitingOn: prior.waitingOn
                    )
                )
                try Self.validateHierarchyTransition(repair, in: state, allowArchive: false)
                // A legacy/corrupt feed could hold a terminal agent pursuit with
                // an open child; reopening it here must still respect the
                // open-pursuit cap (2026-07-11 review MED). If reopening would
                // breach the cap, skip the repair (leave the contradiction, which
                // a User-facing digest surfaces) rather than mint a 3rd pursuit.
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

    /// CAS variant for the notify loop: stamp notify.lastNotifiedAt ONLY if the
    /// item's updatedAt still equals the version that was notified. If a content
    /// change landed since (updatedAt advanced), DON'T stamp — leave the item
    /// eligible so the next tick pings the NEWER state instead of swallowing it
    /// (gpt-5.5 notify review HIGH). Returns whether it stamped.
    @discardableResult
    public func markNotifiedIfUnchanged(_ handle: String, expectedUpdatedAt: String, at: String? = nil) async throws -> Bool {
        try await persistence.withFileLock(opsPath) {
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

    // MARK: - Archive

    /// archive_item -> append ArchiveRecord(s) to desk_archive.jsonl and exclude
    /// the item (and its whole subtree) from live state. REFUSES a standing item
    /// (MVP), REFUSES a non-terminal item, and REFUSES while ANY descendant
    /// (child, grandchild, …) is non-terminal — then cascade-archives the entire
    /// terminal subtree so no live descendant is ever orphaned by its parent
    /// leaving live state. Runs the whole check-then-write under the ops flock so
    /// the refusal can't race a sibling mutation.
    @discardableResult
    public func archiveItem(_ handle: String) async throws -> ArchiveRecord {
        return try await persistence.withFileLock(opsPath) {
            var feed = try await readFeedUnlocked()
            let state = Self.compact(base: feed.base, feed.ops)
            guard let item = state.items.first(where: { $0.handle == handle }) else {
                throw DeskError.unknownHandle(handle)
            }
            if item.kind == .standing {
                throw DeskError.archiveRefusedStanding(handle: handle)
            }
            // The item itself must be terminal — archiving an active item and
            // recording it as `.done` would be a false final record.
            if !item.status.isTerminal {
                throw DeskError.archiveRefusedNonTerminalSelf(handle: handle, status: item.status)
            }
            // Recurse the WHOLE subtree, not just direct children (gpt-5.5 review
            // HIGH — a terminal child with a non-terminal grandchild slipped past
            // a direct-only check and orphaned the live grandchild).
            let subtree = Self.descendants(of: handle, in: state)
            if let nonTerminal = subtree.first(where: { !$0.status.isTerminal }) {
                throw DeskError.archiveRefusedNonTerminalChild(handle: handle, childHandle: nonTerminal.handle)
            }
            let now = DeskClock.commitStamp(notBefore: feed.maxCommittedTs)
            // Idempotency: never double-write a record for a handle that already
            // has one — a retry after a crash between the record append and the
            // archive op (gpt-5.5 review MEDIUM).
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
                        try await appendJSONLCapped(
                            rec.toJSON(), to: archivePath, using: persistence,
                            maxLines: JSONLLineCaps.deskArchive,
                            logLabel: SwiftNativeDeskStore.logLabel,
                            takeLock: false
                        )
                    }
                    let archiveOp = DeskOp(ts: now, handle: node.handle, body: .archiveItem)
                    // The whole subtree was validated against one locked state.
                    // Append every canonical op first, then fold/write the derived
                    // state once; the previous per-node recompaction was O(K×N)
                    // and wrote K transient projections that no reader could see
                    // while this same flock was held.
                    try await persistence.appendJSONL(archiveOp.toJSON(), to: opsPath)
                    feed.ops.append(archiveOp)
                    feed.fileOpCount += 1
                    appendedCanonicalOp = true
                    if node.handle == handle { targetRecord = rec }
                }
            } catch {
                // The two append-only feeds cannot be one filesystem
                // transaction. Deepest-first keeps a partial commit valid, and
                // this repair makes the materialized view match every canonical
                // op already durably appended before rethrowing the real error.
                if appendedCanonicalOp {
                    do {
                        let repairFeed = try await readFeedUnlocked()
                        let repairedState = Self.compact(base: repairFeed.base, repairFeed.ops)
                        try await persistence.writeJSON(repairedState.toJSON(), to: statePath)
                        changeBus.emit(StoreChange(store: .desk, path: opsPath))
                    } catch let repairError {
                        FileHandle.standardError.write(Data(
                            "DeskStore: partial archive projection repair failed: \(repairError)\n".utf8
                        ))
                    }
                }
                throw error
            }
            let archivedState = Self.compact(base: feed.base, feed.ops)
            try await persistence.writeJSON(archivedState.toJSON(), to: statePath)
            changeBus.emit(StoreChange(store: .desk, path: opsPath))
            _ = try await compactIfNeededUnlocked(state: archivedState, feed: feed)
            return targetRecord ?? Self.makeArchiveRecord(item, now: now)
        }
    }

    /// archiveSweep — RETURN the handles eligible for archival (TERMINAL — done
    /// OR canceled — not pinned, past the grace window, terminal children only,
    /// not standing). Does NOT mutate anything; a background loop decides whether
    /// to call archiveItem on each. Pure query (state read + deterministic
    /// predicate).
    ///
    /// The guard is `status.isTerminal`, matching archiveItem (which accepts any
    /// terminal item) and makeArchiveRecord (which maps `.canceled` to a canceled
    /// final record). A `.done`-only guard stranded every canceled top-level item
    /// in live state forever — never swept, and (before the matching projection
    /// fix) never capped, so canceled rows accumulated at the lowest aliases and
    /// pushed live work off the 25-item desk. Both terminal paths stamp closedAt
    /// (close_item always; set_status when `status.isTerminal`), so the grace
    /// window below is well-defined for canceled rows too.
    public func archiveSweep(now: Date = Date(), grace: TimeInterval = SwiftNativeDeskStore.defaultArchiveGrace) async throws -> [String] {
        let state = try await liveState()
        return state.items.compactMap { item -> String? in
            guard item.parent == nil else { return nil }       // only sweep top-level
            guard item.status.isTerminal, !item.pinned else { return nil }
            guard item.kind != .standing else { return nil }
            guard let closedAt = item.closedAt, let closed = DeskClock.parseISO(closedAt) else { return nil }
            guard now.timeIntervalSince(closed) >= grace else { return nil }
            // Parent cannot archive with a non-terminal DESCENDANT (recursive —
            // matches archiveItem's subtree check).
            if Self.descendants(of: item.handle, in: state).contains(where: { !$0.status.isTerminal }) { return nil }
            return item.handle
        }
    }

    // MARK: - Queries

    /// The current live materialized state, recompacted from the replayable
    /// feed — base + tail — (always current; does not read the cached
    /// state.json). Reads UNDER THE FLOCK: an unlocked reader can race a
    /// compaction into (stale ops snapshot, new base) — the base's
    /// lastCompactedOpId is absent from the stale snapshot, so no prefix-drop
    /// happens and old ops replay on top of a base that already contains them
    /// (gpt-5.5 compaction review HIGH). The ops-first ordering in
    /// readFeedUnlocked only protects readers whose two reads are not
    /// separated by a full append+compact cycle; the lock closes the rest.
    public func liveState() async throws -> DeskState {
        try await persistence.withFileLock(opsPath) {
            let feed = try await readFeedUnlocked()
            return Self.compact(base: feed.base, feed.ops)
        }
    }

    /// All archived item records, in feed (append) order.
    public func archivedRecords() async throws -> [ArchiveRecord] {
        let raw = try await persistence.readJSONL(archivePath)
        return raw.compactMap { ArchiveRecord.fromJSON($0) }
    }

    /// Every descendant of `handle` (children, grandchildren, …) in `state`,
    /// breadth-first. Cycle-safe: each handle is visited at most once.
    static func descendants(of handle: String, in state: DeskState) -> [DeskItem] {
        var out: [DeskItem] = []
        var seen: Set<String> = [handle]
        var frontier = state.children(of: handle).filter { seen.insert($0.handle).inserted }
        while !frontier.isEmpty {
            out.append(contentsOf: frontier)
            frontier = frontier.flatMap { state.children(of: $0.handle) }.filter { seen.insert($0.handle).inserted }
        }
        return out
    }

    /// Recompute a pursuit's derived counters from its reservation ledger — pure
    /// (no wall clock): `workSessionsToday` = reservations sharing the NEWEST
    /// reservation day (lexicographic max on yyyy-MM-dd). The authoritative daily
    /// cap still counts from the ops feed; this field is the display denorm.
    static func recomputePursuitCounters(_ p: inout Pursuit) {
        guard let newestDay = p.reservations.map(\.day).max() else {
            p.workSessionsToday = 0
            return
        }
        p.workSessionsToday = p.reservations.filter { $0.day == newestDay }.count
    }

    /// Count of OPEN (non-terminal) origin=agent pursuits in `state`. The
    /// open-pursuit cap keys on exactly this — a terminal (done/canceled/
    /// abandoned) pursuit doesn't count, but reopening one does (it re-enters
    /// this set).
    static func openAgentPursuitCount(in state: DeskState) -> Int {
        state.items.filter { $0.origin == .agent && $0.kind == .project && !$0.status.isTerminal }.count
    }

    /// HARD pursuit invariants (H2 / M7), enforced at WRITE time on every append
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
        case let .createItem(_, _, _, _, _, _, origin, _):
            // A create_item can NEVER mint an agent pursuit — that path is
            // open_pursuit only (H2). An origin=agent create_item is refused
            // regardless of who calls it.
            guard origin == .agent else { return }   // owner/system creates are unconstrained here
            throw DeskError.genericPathCannotCreateAgent(handle: op.handle)

        case let .openPursuit(_, _, _, _, pursuit):
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

        case let .reserveWorkSession(reservationId, day, _):
            // Gate the GENERIC append path too (H1, 2026-07-11 review): the caps
            // used to live only in the dedicated reserveWorkSession() method, so
            // a raw append(.reserveWorkSession) bypassed them. An exact-duplicate
            // reservation id is idempotent (compaction dedups) — allowed. A NEW
            // reservation must clear both caps and target a live pursuit.
            guard let item = state.items.first(where: { $0.handle == op.handle }),
                  item.isPursuit, let p = item.pursuit else {
                throw DeskError.notAPursuit(handle: op.handle)
            }
            if p.reservations.contains(where: { $0.reservationId == reservationId }) { return }
            if p.reservations.filter({ $0.day == day }).count >= maxWorkSessionsPerPursuitPerDay {
                throw DeskError.workSessionCapReached(scope: "per-pursuit (2/day)", limit: maxWorkSessionsPerPursuitPerDay, handle: op.handle)
            }
            let global = state.items.reduce(0) { $0 + ($1.pursuit?.reservations.filter { $0.day == day }.count ?? 0) }
            if global >= maxWorkSessionsGlobalPerDay {
                throw DeskError.workSessionCapReached(scope: "workshop (6/day)", limit: maxWorkSessionsGlobalPerDay, handle: op.handle)
            }

        case let .completeWorkSession(reservationId, _):
            guard let item = state.items.first(where: { $0.handle == op.handle }),
                  item.isPursuit, let p = item.pursuit else {
                throw DeskError.notAPursuit(handle: op.handle)
            }
            guard let res = p.reservations.first(where: { $0.reservationId == reservationId }) else {
                throw DeskError.unknownReservation(reservationId: reservationId, handle: op.handle)
            }
            // Double-complete guard (2026-07-11 review MED): a completed slot
            // can't be re-closed into a duplicate work receipt.
            if res.completedAt != nil {
                throw DeskError.reservationAlreadyComplete(reservationId: reservationId, handle: op.handle)
            }

        case let .setStatus(status, _, _):
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
    private static func validateHierarchyTransition(
        _ op: DeskOp,
        in state: DeskState,
        allowArchive: Bool
    ) throws {
        switch op.body {
        case let .createItem(_, _, _, _, parent, _, _, _):
            guard let parent else { return }
            guard state.items.contains(where: { $0.handle == parent }) else {
                throw DeskError.unknownHandle(parent)
            }
            if let terminal = terminalAncestor(startingAt: parent, in: state) {
                throw DeskError.childRefusedTerminalParent(parentHandle: terminal.handle)
            }

        case let .setStatus(status, _, _):
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

        case .closeItem:
            try rejectTerminalParentWithOpenDescendant(op.handle, in: state)

        case .archiveItem:
            if !allowArchive {
                throw DeskError.directArchiveRequiresGuardedPath(handle: op.handle)
            }

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
        var byHandle = Dictionary(uniqueKeysWithValues: state.items.map { ($0.handle, $0) })
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

    private static func lastNonTerminalStatus(
        for handle: String,
        base: DeskCompactionBase?,
        in ops: [DeskOp]
    ) -> (status: DeskStatus, blockedReason: String?, waitingOn: String?) {
        // Seed from the compaction base's ledger — the pre-terminal history of
        // a compacted item lives only there; without it a repair would degrade
        // to `.watch` regardless of what the item was before it closed.
        var result: (DeskStatus, String?, String?) = base?.lastNonTerminal[handle]
            .map { ($0.status, $0.blockedReason, $0.waitingOn) } ?? (.watch, nil, nil)
        for op in ops where op.handle == handle {
            switch op.body {
            case .createItem:
                result = (.watch, nil, nil)
            case let .setStatus(status, blockedReason, waitingOn) where !status.isTerminal:
                result = (status, blockedReason, waitingOn)
            default:
                break
            }
        }
        return result
    }

    /// Build the final archive record for an item (the shared shape used by both
    /// single-item archive and subtree cascade).
    // MARK: - Per-item history caps (notes / refs)

    /// Newest N notes retained per item. Notes are an append-only per-item log
    /// (append_note, plus a receipt per completed work session / work_log), and
    /// the WHOLE item tree is re-serialized + fsynced on every desk op AND baked
    /// into the compaction base — so an uncapped note list makes the feed O(n²)
    /// over its life, defeating the exact cost compaction exists to bound.
    /// Readers only ever want the recent tail: the projection and DeskView read
    /// `notes.last`, the Workshop panel reads them newest-first.
    public static let notesCap = 200

    /// Max refs retained per item. Same write-amplification argument as notes.
    public static let refsCap = 64

    /// Append a note, evicting the OLDEST beyond `notesCap`.
    static func appendNoteCapped(_ item: inout DeskItem, _ note: DeskNote) {
        item.notes.append(note)
        if item.notes.count > notesCap {
            item.notes.removeFirst(item.notes.count - notesCap)
        }
    }

    /// Append a ref, evicting the LEAST IMPORTANT beyond `refsCap` — by the
    /// model's own `DeskRefKind.priority` ranking (the same one liveRefs sorts
    /// by), oldest-first among equals. Deliberately NOT a plain `suffix`: gh
    /// pr/issue refs (priority 0/1) are an item's tracking IDENTITY —
    /// GitHubProjectTracking matches and retires desk rows by them — so a
    /// newest-N cap would silently orphan a tracked row behind a flood of
    /// low-priority note/trace refs. Survivors keep insertion order.
    static func appendRefCapped(_ item: inout DeskItem, _ ref: DeskRef) {
        item.refs.append(ref)
        guard item.refs.count > refsCap else { return }
        let overflow = item.refs.count - refsCap
        // gh_pr / gh_issue refs are the row's TRACKING IDENTITY —
        // GitHubProjectTracking matches and retires a desk row by the exact
        // presence of that ref. Evicting one (even under a flood of newer,
        // equal-priority gh refs) orphans the tracked row and duplicates it on
        // the next observation (gpt-5.5 wave-2 review). So they are NEVER
        // eviction victims: overflow is drawn only from the non-tracking kinds,
        // and if tracking refs alone exceed the cap the array is allowed to
        // exceed it rather than lose an identity.
        func isTrackingRef(_ r: DeskRef) -> Bool {
            switch r.kind {
            case .ghPr, .ghIssue: return true
            default: return false
            }
        }
        let victims = Set(
            item.refs.enumerated()
                .filter { !isTrackingRef($0.element) }
                .sorted { a, b in
                    a.element.priority == b.element.priority
                        ? a.offset < b.offset
                        : a.element.priority > b.element.priority
                }
                .prefix(overflow)
                .map(\.offset)
        )
        item.refs = item.refs.enumerated().filter { !victims.contains($0.offset) }.map(\.element)
    }

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
            artifacts: []
        )
    }

    // MARK: - Alias assignment (monotonic, per-parent, never reused)

    /// Next monotonic alias among the siblings of `parentHandle`. Scans ALL
    /// create ops (not just live items) so an alias is NEVER reused after a
    /// sibling closes OR archives, and seeds from the compaction base's
    /// aliasHighWater so the guarantee survives an op-log truncate. Counts
    /// BOTH create_item and open_pursuit creates — pursuits draw from the same
    /// top-level sequence (they used to be invisible to this scan, which let
    /// the next createItem REUSE a pursuit's alias — duplicate depth-0 alias).
    /// Top-level (parentHandle == nil) yields "N"; children yield
    /// "<parentAlias>.<M>", both starting at 1.
    static func nextAlias(parentHandle: String?, parentAlias: String?, base: DeskCompactionBase? = nil, ops: [DeskOp]) -> String {
        let siblingAliases: [String] = ops.compactMap { op in
            switch op.body {
            case .createItem(let alias, _, _, _, let parent, _, _, _):
                return parent == parentHandle ? alias : nil
            case .openPursuit(let alias, _, _, _, _):
                return parentHandle == nil ? alias : nil
            default:
                return nil
            }
        }
        let highWater = base?.aliasHighWater[parentHandle ?? ""] ?? 0
        if let parentAlias {
            let prefix = parentAlias + "."
            let maxSeq = siblingAliases.compactMap { a -> Int? in
                guard a.hasPrefix(prefix) else { return nil }
                return Int(a.dropFirst(prefix.count))
            }.max() ?? 0
            return "\(parentAlias).\(max(maxSeq, highWater) + 1)"
        } else {
            let maxSeq = siblingAliases.compactMap { Int($0) }.max() ?? 0
            return "\(max(maxSeq, highWater) + 1)"
        }
    }

    // MARK: - Compaction (pure fold — rebuild MUST equal in-memory fold)

    /// Fold the op stream into the live DeskState. Ops apply in FILE ORDER:
    /// create_item seeds an item; later ops mutate by handle; archive_item
    /// removes it from the live set. A mutation whose create aged out (orphan)
    /// is tolerated (skipped). Items are returned in alias order — top-level by
    /// numeric seq, each immediately followed by its children in child-seq order
    /// (orphaned-parent live items appended last).
    public static func compact(_ ops: [DeskOp]) -> DeskState {
        compact(base: nil, ops)
    }

    /// Fold seeded from a compaction base: the base's items ARE the reduced
    /// state through `lastCompactedOpId`, so the tail ops apply on top exactly
    /// as if the compacted prefix had just been replayed. A tail mutation
    /// targeting a handle the base no longer carries (archived before the
    /// snapshot) is skipped by the same orphan tolerance as always.
    static func compact(base: DeskCompactionBase?, _ ops: [DeskOp]) -> DeskState {
        var byHandle: [String: DeskItem] = [:]
        var createOrder: [String] = []
        var archived: Set<String> = []
        if let base {
            for item in base.state.items {
                byHandle[item.handle] = item
                createOrder.append(item.handle)
            }
        }

        for op in ops {
            switch op.body {
            case let .createItem(alias, kind, project, title, parent, summary, origin, pursuit):
                if byHandle[op.handle] == nil { createOrder.append(op.handle) }
                byHandle[op.handle] = DeskItem(
                    handle: op.handle, alias: alias, parent: parent, kind: kind,
                    status: .watch, project: project, title: title, summary: summary,
                    cadence: Cadence(), notify: NotifyPolicy(),
                    openedAt: op.ts, updatedAt: op.ts,
                    origin: origin, pursuit: pursuit
                )
            case let .openPursuit(alias, project, title, summary, pursuit):
                // Dedicated agent-pursuit create (H2). Same materialization as a
                // create_item pinned to origin=.agent/kind=.project.
                if byHandle[op.handle] == nil { createOrder.append(op.handle) }
                byHandle[op.handle] = DeskItem(
                    handle: op.handle, alias: alias, parent: nil, kind: .project,
                    status: .watch, project: project, title: title, summary: summary,
                    cadence: Cadence(), notify: NotifyPolicy(),
                    openedAt: op.ts, updatedAt: op.ts,
                    origin: .agent, pursuit: pursuit
                )
            case let .setStatus(status, blockedReason, waitingOn):
                guard var item = byHandle[op.handle] else { continue }
                item.status = status
                item.blockedReason = blockedReason
                item.waitingOn = waitingOn
                // A terminal status reached via set_status (not close_item) still
                // needs closedAt, or archiveSweep + the "archives in" countdown
                // skip it forever (gpt-5.5 review HIGH). A non-terminal status
                // re-opens the row, so clear any stale closedAt.
                if status.isTerminal {
                    if item.closedAt == nil { item.closedAt = op.ts }
                } else {
                    item.closedAt = nil
                }
                item.updatedAt = op.ts
                byHandle[op.handle] = item
            case let .updateTitle(title, summary):
                guard var item = byHandle[op.handle] else { continue }
                if let title, !title.isEmpty { item.title = title }
                // Empty summary is a NO-OP (mirrors title, and the encode that
                // omits empty strings) — NOT a clear. The old `isEmpty ? nil`
                // clear could never round-trip: the encode dropped the empty
                // string, so the clear was silently lost (gpt-5.5 review HIGH).
                if let summary, !summary.isEmpty { item.summary = summary }
                item.updatedAt = op.ts
                byHandle[op.handle] = item
            case let .addRef(ref):
                guard var item = byHandle[op.handle] else { continue }
                Self.appendRefCapped(&item, ref)
                item.updatedAt = op.ts
                byHandle[op.handle] = item
            case let .updateRef(refId, cachedFields):
                guard var item = byHandle[op.handle] else { continue }
                if let idx = item.refs.firstIndex(where: { $0.refId == refId }) {
                    item.refs[idx].kind = item.refs[idx].kind.applyingCachedFields(cachedFields)
                    item.updatedAt = op.ts
                }
                byHandle[op.handle] = item
            case let .appendNote(text):
                guard var item = byHandle[op.handle] else { continue }
                Self.appendNoteCapped(&item, DeskNote(ts: op.ts, text: text))
                item.updatedAt = op.ts
                byHandle[op.handle] = item
            case let .setCadence(cadence):
                guard var item = byHandle[op.handle] else { continue }
                item.cadence = cadence
                item.updatedAt = op.ts
                byHandle[op.handle] = item
            case let .setNotify(policy):
                guard var item = byHandle[op.handle] else { continue }
                item.notify = policy
                item.updatedAt = op.ts
                byHandle[op.handle] = item
            case let .closeItem(outcomeSummary, status):
                guard var item = byHandle[op.handle] else { continue }
                item.status = status
                item.summary = outcomeSummary
                item.closedAt = op.ts
                item.updatedAt = op.ts
                byHandle[op.handle] = item
            case let .markNotified(at):
                // Stamps notify.lastNotifiedAt ONLY — deliberately does NOT bump
                // updatedAt, so a notification can't masquerade as a content
                // change and re-trigger itself (notify-evaluator idempotency).
                guard var item = byHandle[op.handle] else { continue }
                item.notify.lastNotifiedAt = at
                byHandle[op.handle] = item
            case .archiveItem:
                archived.insert(op.handle)
            case let .reserveWorkSession(reservationId, day, slot):
                // Only pursuits carry a reservation ledger; a reserve op on a
                // non-pursuit is tolerated (skipped). Dedup by id so a replayed
                // reserve op is idempotent — the caps count DISTINCT rows.
                guard var item = byHandle[op.handle], var p = item.pursuit else { continue }
                if !p.reservations.contains(where: { $0.reservationId == reservationId }) {
                    p.reservations.append(WorkReservation(reservationId: reservationId, day: day, slot: slot, reservedAt: op.ts))
                }
                Self.recomputePursuitCounters(&p)
                item.pursuit = p
                item.updatedAt = op.ts
                byHandle[op.handle] = item
            case let .completeWorkSession(reservationId, receipt):
                guard var item = byHandle[op.handle], var p = item.pursuit else { continue }
                if let idx = p.reservations.firstIndex(where: { $0.reservationId == reservationId }) {
                    p.reservations[idx].receipt = receipt
                    p.reservations[idx].completedAt = op.ts
                }
                Self.appendNoteCapped(&item, DeskNote(ts: op.ts, text: receipt))
                p.lastWorkedAt = op.ts
                Self.recomputePursuitCounters(&p)
                item.pursuit = p
                item.updatedAt = op.ts
                byHandle[op.handle] = item
            case let .workLog(receipt):
                guard var item = byHandle[op.handle], var p = item.pursuit else { continue }
                Self.appendNoteCapped(&item, DeskNote(ts: op.ts, text: receipt))
                p.lastWorkedAt = op.ts
                item.pursuit = p
                item.updatedAt = op.ts
                byHandle[op.handle] = item
            }
        }

        let live = createOrder.compactMap { byHandle[$0] }.filter { !archived.contains($0.handle) }
        let ordered = orderByAlias(live)
        // DETERMINISTIC fold: the rev stamp is the newest of (last op ts, base
        // stamp) — NOT wall-clock — so the same feed always folds to an equal
        // DeskState and state.json never drifts on a no-op recompaction. The
        // max matters: the raw append path does not restamp, so a tail op can
        // carry a ts OLDER than the base; taking just ops.last would regress
        // generatedTs, and if that state became the next base an empty-tail
        // maxCommittedTs would floor future commit stamps on the stale value
        // (gpt-5.5 compaction review MED — Lamport floor regression).
        let revision = [ops.last?.ts, base?.state.generatedTs].compactMap { $0 }.max() ?? ""
        return DeskState(items: ordered, generatedTs: revision)
    }

    /// Trailing numeric component of an alias ("2" -> 2, "2.10" -> 10). Defaults
    /// to a large sentinel so a malformed alias sorts last (never crashes).
    static func aliasSeq(_ alias: String) -> Int {
        Int(alias.split(separator: ".").last.map(String.init) ?? "") ?? Int.max
    }

    /// Order live items into render order via DEPTH-FIRST descent: each item is
    /// immediately followed by its whole subtree (children, grandchildren, …),
    /// siblings in child-seq order. Roots are the top-level items (parent nil)
    /// plus orphans (parent not in the live set). A final pass appends anything
    /// still unemitted (a parent cycle / unreachable node) so NO live item is
    /// ever dropped from the materialized state.
    static func orderByAlias(_ live: [DeskItem]) -> [DeskItem] {
        let liveHandles = Set(live.map { $0.handle })
        let byParent = Dictionary(grouping: live, by: { $0.parent ?? "" })
        var result: [DeskItem] = []
        var emitted: Set<String> = []

        func emit(_ items: [DeskItem]) {
            for item in items.sorted(by: { aliasSeq($0.alias) < aliasSeq($1.alias) }) {
                if emitted.contains(item.handle) { continue }
                result.append(item); emitted.insert(item.handle)
                emit(byParent[item.handle] ?? [])
            }
        }

        let roots = live.filter { item in
            guard let parent = item.parent else { return true }   // top-level
            return !liveHandles.contains(parent)                  // orphan
        }
        emit(roots)
        // Cycle / unreachable guard — never silently drop a live item.
        for item in live where !emitted.contains(item.handle) {
            result.append(item); emitted.insert(item.handle)
        }
        return result
    }
}
