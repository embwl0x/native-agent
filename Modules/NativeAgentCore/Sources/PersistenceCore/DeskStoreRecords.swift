import Darwin
import Foundation

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
    case vetoRefusedTerminal(handle: String, status: DeskStatus)
    /// 2026-09-06: closing an item that is ALREADY terminal silently replaced
    /// its outcome — a `canceled` became `done`, and the recorded summary and
    /// closedAt were overwritten by whichever writer arrived last.
    case closeRefusedTerminal(handle: String, status: DeskStatus)
    case workSessionCapReached(scope: String, limit: Int, handle: String)
    case unknownReservation(reservationId: String, handle: String)
    case reservationAlreadyComplete(reservationId: String, handle: String)
    // Sequencing edges (blocked-on / defer).
    case blockedOnUnknown(handle: String, blocker: String)
    case blockedOnSelf(handle: String)
    case blockedOnCycle(handle: String, handles: [String])
    case deferUntilUnparseable(handle: String, value: String)
    case liveActivityMetadataEmpty(field: String)
    case laneOfUnknown(handle: String, laneOf: String)
    case laneOfSelf(handle: String)
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
        case let .vetoRefusedTerminal(handle, status):
            return "desk: cannot veto \(handle) — it is already terminal (status \(status.rawValue))"
        case let .closeRefusedTerminal(handle, status):
            return "desk: cannot close \(handle) — it is already terminal (status \(status.rawValue)); "
                + "reopen it first if the recorded outcome is wrong"
        case let .workSessionCapReached(scope, limit, handle):
            return "desk: work-session cap reached — \(scope) limit \(limit) for \(handle) already met today"
        case let .unknownReservation(reservationId, handle):
            return "desk: no reservation \(reservationId) on \(handle); reserve the slot before completing it"
        case let .reservationAlreadyComplete(reservationId, handle):
            return "desk: reservation \(reservationId) on \(handle) is already complete; a slot completes once"
        case let .blockedOnUnknown(handle, blocker):
            return "desk: cannot block \(handle) on '\(blocker)' — no live item with that handle; blockers point at ITEMS, not prose"
        case .blockedOnSelf(let handle):
            return "desk: \(handle) cannot block itself"
        case let .blockedOnCycle(handle, handles):
            return "desk: that edge would close a blocked-on cycle through \(handles.joined(separator: " → ")) — \(handle) would wait on itself"
        case let .deferUntilUnparseable(handle, value):
            return "desk: cannot defer \(handle) until '\(value)' — expected a yyyy-MM-dd day or a full ISO timestamp"
        case .liveActivityMetadataEmpty(let field):
            return "desk: \(field) must be non-empty when supplied"
        case let .laneOfUnknown(handle, laneOf):
            return "desk: cannot link \(handle) to laneOf \(laneOf) — no live item has that handle"
        case .laneOfSelf(let handle):
            return "desk: \(handle) cannot be its own laneOf parent"
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
    /// What the raw op-log scan could not use — malformed lines and rows whose
    /// op token this build does not know. Compaction REFUSES to run while this
    /// is non-clean (see `SnapshotTailOpLog`'s unknown-row policy): the
    /// truncate would erase exactly the rows we just skipped.
    var integrity: SnapshotTailOpLog.OpLogIntegrity = .clean

    /// The number the compaction threshold is compared against: PHYSICAL rows
    /// in `desk_ops.jsonl`, not decoded ops (gpt-5.5 review 2026-08-02, finding
    /// 2). `fileOpCount` counts what `DeskOp.fromJSON` accepted, so a feed of
    /// 100k rows written by a newer build plus 10 this one understands measured
    /// as 10 — under the threshold, so compaction never ran, so `mayCompact`
    /// never logged the refusal, so the unbounded growth was invisible.
    var compactionRowCount: Int { integrity.feedRowCount(decodedCount: fileOpCount) }

    /// Account for ops this writer just appended to the file under the flock.
    mutating func noteAppendedRows(_ count: Int) {
        fileOpCount += count
        integrity = integrity.appendingRows(count)
    }

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
