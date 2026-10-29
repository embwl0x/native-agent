import NativeAgentShared
import Darwin
import Foundation
import PersistenceCore
import NativeAgentCore
import Synchronization
// Blueprint: | `DeskStore.swift` | `SwiftNativeDeskStore` struct; process-wide `currentRevision` advances before and after each awaited canonical append under the ops lock; `continuation`, `setContinuation`, `heldBy` (nonacquiring hold read); keyed system findings persist findingKey through create, compaction and archive, preserve closure and person ownership under their filing lock; explicit reopening refreshes evidence in that transaction or files anew after archive, with opt-in ref replacement on the same `updateTitle` op; terminalParentsWithNonTerminalDescendants is the pure Doctor/repair selection, with mutation-time revalidation under the ops lock; resumable work retains DataRootLife; other-life (no stamp = first life) work reads stopped/restored and explicit resumption starts fresh |
//
// Canonical state is base + ops, with every mutation appended under the
// ops-feed flock so replay and compaction cannot race a committed append.
//
// STORE PATHS (under <dataRoot>/desk/):
//   • desk_ops.jsonl   (+ .lock) — append-only op events. The canonical TRUTH
//     is base+tail: dropping an old op is only ever done by compaction, which
//     first snapshots the FULL reduced state (plus the ledgers that live in
//     raw op history) into desk_ops_base.json.
//   • desk_ops_base.json         — compaction snapshot the replay seeds from.
//   • desk_archive.jsonl         — display/idempotency receipts capped at newest-5000 via appendJSONLCapped.
//
// OP-LOG COMPACTION: once the feed crosses `opsCompactionThreshold` lines, the locked write
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
/// Owns desk_ops JSONL/base v1, ArchiveRecord JSONL and DeskHold JSON.
/// Coverage: excluded from local backups and production export; off-disk includes
/// desk/. Phone sync projects items/bounds/details, not archive or holds;
/// PrivacyMap lists the tree.
public struct SwiftNativeDeskStore: Sendable {
    public struct CreateResult: Sendable, Equatable {
        public let item: DeskItem
        public let reusedEquivalent: Bool
        public init(item: DeskItem, reusedEquivalent: Bool) {
            self.item = item
            self.reusedEquivalent = reusedEquivalent
        }
    }
    public static let logLabel = "DeskStore"
    /// Shared by every store instance; admission reads it without Desk I/O.
    static let truthRevision = Mutex<UInt64>(0)
    public static var currentRevision: UInt64 { truthRevision.withLock { $0 } }
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
    let changeBus: StoreChangeBus
    /// Op-log lines that trigger a snapshot+truncate at the end of the next
    /// locked write transaction (mirrors GitHubCommandStore).
    let opsCompactionThreshold = 2_048
    public init(
        dataRoot: URL,
        changeBus: StoreChangeBus = .shared
    ) {
        self.dataRoot = dataRoot
        self.changeBus = changeBus
    }
    var deskDir: URL { dataRoot.appendingPathComponent("desk", isDirectory: true) }
    /// `<dataRoot>/desk/desk_ops.jsonl`.
    public var opsPath: URL { deskDir.appendingPathComponent("desk_ops.jsonl") }
    /// `<dataRoot>/desk/desk_ops_base.json` — the compaction snapshot the
    /// op-log replays FROM. Written atomically BEFORE the op-log truncate; a
    /// crash between the two is healed by the replay prefix-drop.
    public var basePath: URL { deskDir.appendingPathComponent("desk_ops_base.json") }
    /// `<dataRoot>/desk/desk_archive.jsonl`.
    public var archivePath: URL { deskDir.appendingPathComponent("desk_archive.jsonl") }
    public func continuation(_ handle: String) async throws -> DeskContinuation? {
        try await SwiftNativePersistenceCore.withFileLock(opsPath) {
            let feed = try await readFeedUnlocked()
            guard feed.integrity.isClean else { throw DeskContinuationError.unsafe }
            return try inCurrentLife(Self.compact(base: feed.base, feed.ops)).items.first { $0.handle == handle }?.continuation
        }
    }
    /// Commit a continuation revision (CAS). A newly blocked continuation
    /// also stops and asks on the task itself: status blocked, waiting on the
    /// owner. Reopening the task re-checks pending steps through their domain.
    public func setContinuation(_ handle: String, expectedRevision: String?, record: DeskContinuation,
                                requiresActive: Bool = false) async throws {
        guard DeskContinuation.fromJSON(record.toJSON()) != nil else { throw DeskContinuationError.unsafe }
        try await SwiftNativePersistenceCore.withFileLock(opsPath) {
            var feed = try await readFeedUnlocked()
            guard feed.integrity.isClean else { throw DeskContinuationError.unsafe }
            let state = Self.compact(base: feed.base, feed.ops)
            guard let item = state.items.first(where: { $0.handle == handle }),
                  item.continuation?.revision == expectedRevision else { throw DeskContinuationError.conflict }
            guard !item.status.isTerminal || item.continuation != nil else {
                throw DeskContinuationError.conflict
            }
            if requiresActive {
                guard item.status != .blocked, !item.requiresOwnerInput,
                      DeskSequencing.compute(state).byHandle[item.handle]?.isReady == true else {
                    throw DeskContinuationError.parked
                }
            }
            if record.state == .blocked, !item.status.isTerminal,
               item.status != .blocked || !item.requiresOwnerInput {
                let ask = DeskOp(ts: DeskClock.commitStamp(notBefore: feed.maxCommittedTs), handle: handle,
                    body: .setStatus(status: .blocked,
                        blockedReason: "Continuation stopped (\(record.reason ?? "blocked")). Check the unfinished step through its own domain, then set this task back to todo to continue, or cancel it.",
                        waitingOn: "owner", progress: nil, assignee: nil, laneOf: nil))
                try Self.validateHierarchyTransition(ask, in: state)
                try Self.validatePursuitInvariants(ask, in: state, viaGenericPath: true)
                let committed = try await appendAndRecompactUnlocked(ask, feed: feed)
                feed = committed.feed
            }
            let op = DeskOp(ts: DeskClock.commitStamp(notBefore: feed.maxCommittedTs),
                            handle: handle, body: .setContinuation(record: record))
            _ = try await appendAndRecompactUnlocked(op, feed: feed)
        }
    }
    /// Next monotonic alias among the siblings of `parentHandle`. Scans ALL
    /// create ops (not just live items) so an alias is NEVER reused after a
    /// sibling closes OR archives, and seeds from the compaction base's
    /// aliasHighWater so the guarantee survives an op-log truncate. Counts
    /// BOTH create_item and open_pursuit creates — pursuits draw from the same
    /// top-level sequence (they used to be invisible to this scan, which let
    /// the next createItem REUSE a pursuit's alias — duplicate depth-0 alias).
    /// Top-level (parentHandle == nil) yields "N"; children yield
    /// "<parentAlias>.<M>", both starting at 1.
    static func validateAliasDomain(base: DeskCompactionBase?, ops: [DeskOp]) throws {
        var aliases = base?.state.items.map(\.alias) ?? []
        for op in ops {
            switch op.body {
            case .createItem(let alias, _, _, _, _, _, _, _, _, _, _), .openPursuit(let alias, _, _, _, _, _): aliases.append(alias)
            default: break
            }
        }
        guard (base?.aliasHighWater.values.allSatisfy { $0 >= 0 && $0 < Int.max } ?? true),
              aliases.allSatisfy({ alias in alias.split(separator: ".").allSatisfy {
                  guard let sequence = Int($0) else { return false }
                  return sequence > 0 && sequence < Int.max
              } }) else {
            throw NSError(domain: "Desk", code: 1, userInfo: [NSLocalizedDescriptionKey:
                "Desk alias/high-water value outside the incrementable domain; saved feed preserved."])
        }
    }
    static func nextAlias(parentHandle: String?, parentAlias: String?, base: DeskCompactionBase? = nil, ops: [DeskOp]) throws -> String {
        try validateAliasDomain(base: base, ops: ops)
        let highWater = foldAliasHighWater(seed: base?.aliasHighWater ?? [:], ops: ops)[parentHandle ?? ""] ?? 0
        func advance(_ sequence: Int) throws -> Int {
            let next = sequence.addingReportingOverflow(1)
            guard sequence >= 0, !next.overflow, next.partialValue < Int.max else {
                throw NSError(domain: "Desk", code: 1, userInfo: [NSLocalizedDescriptionKey:
                    "Desk alias sequence exhausted; saved feed preserved."])
            }
            return next.partialValue
        }
        let sequence = try advance(highWater)
        return parentAlias.map { "\($0).\(sequence)" } ?? "\(sequence)"
    }
}
