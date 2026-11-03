import NativeAgentShared
import Darwin
import Foundation
import PersistenceCore
// Blueprint: | `DeskStoreRecords.swift` | `DeskError` enum |

public enum DeskError: Error, LocalizedError, Sendable, Equatable {
    case unknownHandle(String)
    case findingArchived(handle: String)
    case terminalStatusRefusedNonTerminalChild(handle: String, childHandle: String)
    case childRefusedTerminalParent(parentHandle: String)
    case nonTerminalStatusRefusedTerminalAncestor(handle: String, ancestorHandle: String)
    case directArchiveRequiresGuardedPath(handle: String)
    case archiveRefusedNonTerminalChild(handle: String, childHandle: String)
    case archiveRefusedStanding(handle: String)
    case archiveRefusedNonTerminalSelf(handle: String, status: DeskStatus)
    case archiveRefusedUnresolvedContinuation(handle: String)
    case archiveRefusedPendingMigration(handle: String)
    case queueCreationRequiresQueuePath
    // Pursuit invariants.
    case pursuitCapReached(openCount: Int)
    case pursuitFieldMissing(reason: String)
    case pursuitDossierInvalid(reason: String)
    case genericPathCannotCreateAgent(handle: String)
    case notAPursuit(handle: String)
    case vetoRefusedTerminal(handle: String, status: DeskStatus)
    /// Terminal outcomes, summaries and closure timestamps cannot be overwritten.
    case closeRefusedTerminal(handle: String, status: DeskStatus)
    case workSessionCapReached(scope: String, limit: Int, handle: String)
    case unknownReservation(reservationId: String, handle: String)
    case reservationAlreadyComplete(reservationId: String, handle: String)
    case workReservationNotReady(handle: String)
    // Sequencing edges (blocked-on / defer).
    case blockedOnUnknown(handle: String, blocker: String)
    case blockedOnSelf(handle: String)
    case blockedOnCycle(handle: String, handles: [String])
    case deferUntilUnparseable(handle: String, value: String)
    case notifyTriggerUnsupported(String)
    case liveActivityMetadataEmpty(field: String)
    case laneOfUnknown(handle: String, laneOf: String)
    case laneOfSelf(handle: String)
    /// The compaction base exists on disk but does not decode. Replaying from
    /// the tail alone would silently blank every compacted item, so reads FAIL
    /// LOUD instead (fail-loud over fail-over).
    case compactionBaseCorrupt(path: String)
    /// Unreadable bytes remain a retryable I/O error, distinct from a corrupt compaction base.
    case compactionBaseUnreadable(path: String)
    case journalUnavailable(path: String, reason: String)
    case invalidOperation(token: String)

    public var errorDescription: String? {
        switch self {
        case .unknownHandle(let h):
            return "desk: no item with handle \(h)"
        case .findingArchived(let handle):
            return "desk: this finding already belongs to archived item \(handle); review its history instead of filing it again"
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
        case .archiveRefusedUnresolvedContinuation(let handle):
            return "desk: cannot archive \(handle) — its continuation has unfinished steps; verify them through their domains first"
        case .archiveRefusedPendingMigration(let handle):
            return "desk: cannot archive \(handle) while its scheduled-intention migration is unfinished; repair the launch migration first"
        case .queueCreationRequiresQueuePath:
            return "desk: use queue.add to add a step to my queue so its readiness and origin are preserved"
        case .pursuitCapReached(let openCount):
            return "desk: cap reached — \(openCount) open self-pursuits already (max 2); close or abandon one before opening or reopening another"
        case .pursuitFieldMissing(let reason):
            return "desk: pursuit refused — \(reason)"
        case .pursuitDossierInvalid(let reason):
            return "desk: pursuit evidence refused — \(reason)"
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
        case .workReservationNotReady(let handle):
            return "desk: cannot reserve work on \(handle); inspect its pursuit lifetime and resolve its or its ancestor's blockers, owner input, or deferral first"
        case let .blockedOnUnknown(handle, blocker):
            return "desk: cannot block \(handle) on '\(blocker)' — no live item with that handle; blockers point at ITEMS, not prose"
        case .blockedOnSelf(let handle):
            return "desk: \(handle) cannot block itself"
        case let .blockedOnCycle(handle, handles):
            return "desk: that edge would close a blocked-on cycle through \(handles.joined(separator: " → ")) — \(handle) would wait on itself"
        case let .deferUntilUnparseable(handle, value):
            return "desk: cannot defer \(handle) until '\(value)' — expected a yyyy-MM-dd day or a full ISO timestamp"
        case .notifyTriggerUnsupported(let trigger):
            return "desk: unsupported notification trigger '\(trigger)'; use state_change, blocked, done, or explicit (alone for a one-time announcement)"
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
        case let .journalUnavailable(path, reason):
            return "desk: journal at \(path) is unavailable: \(reason). Preserve the file and reconcile the named record to the current writer's shape before replaying."
        case .invalidOperation(let token):
            return "desk: \(token) does not encode a complete current operation; no journal row was written. Repair its arguments at the mutation owner."
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
              let status = DeskStatus(rawValue: raw), !status.isTerminal,
              DeskJSON.optionalStringsAreValid(obj, keys: ["blockedReason", "waitingOn"]) else { return nil }
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

    /// Compaction-base decode requires every row and ledger key; the tail cannot replace missing data.
    static func fromJSON(_ value: JSONValue) -> DeskCompactionBase? {
        guard case .object(let obj) = value,
              case .int(1)? = obj["version"],
              let stateVal = obj["state"], let state = DeskState.fromJSON(stateVal),
              // The sole surviving snapshot must preserve every stored value.
              deskBaseRoundTripIsFaithful(decoded: state, onDisk: stateVal),
              case .string(let lastCompactedOpId)? = obj["lastCompactedOpId"],
              !lastCompactedOpId.isEmpty,
              case .string(let compactedAt)? = obj["compactedAt"],
              case .object(let hw)? = obj["aliasHighWater"],
              case .object(let lnt)? = obj["lastNonTerminal"],
              case .int(let rawCount)? = obj["compactedOpCount"], rawCount >= 0,
              let compactedOpCount = Int(exactly: rawCount) else { return nil }
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

/// The current snapshot preserves its exact JSON tree. No scalar migration,
/// synthesized ledger or clamped saved bound is admitted here.
func deskBaseRoundTripIsFaithful(decoded state: DeskState, onDisk: JSONValue) -> Bool {
    state.toJSON() == onDisk
}

/// One consistent read of the replayable feed: compaction base (if any), the
/// tail ops that FOLLOW it, and the raw op-log line count (pre prefix-drop —
/// the compaction threshold keys on actual file size).
struct DeskFeed: Sendable {
    let base: DeskCompactionBase?
    var ops: [DeskOp]
    var fileOpCount: Int
    /// Physical feed integrity. Functional reads require every row before a
    /// feed is returned; diagnostics may report rejected records separately.
    var integrity: SnapshotTailOpLog.OpLogIntegrity = .clean

    /// Compaction thresholds count physical `desk_ops.jsonl` rows, including undecodable ops.
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
