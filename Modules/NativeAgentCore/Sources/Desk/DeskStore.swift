import NativeAgentShared
import Darwin
import Foundation
import PersistenceCore
import NativeAgentCore
import Synchronization
// Blueprint: | `DeskStore.swift` | `SwiftNativeDeskStore`, `currentRevision`, `continuation`, `setContinuation`, `heldBy`, `updateTitle` |
// Flocked base-plus-tail replay prevents compaction from racing committed appends.
// Snapshot before truncation and prefix-drop on replay prevent loss and duplicate application.
// Preserve alias high-water, reopening targets and the commit-stamp floor because live rows cannot recover them.
/// Local export and phone sync exclude archive and holds; off-disk backup retains the Desk tree.
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
    /// Share revisions across store instances so admission needs no Desk I/O.
    static let truthRevision = Mutex<UInt64>(0)
    public static var currentRevision: UInt64 { truthRevision.withLock { $0 } }
    public static let defaultArchiveGrace: TimeInterval = 48 * 60 * 60
    /// Enforce pursuit and work-session budgets in the store so prompts cannot bypass them.
    public static let maxOpenAgentPursuits = 2
    public static let maxWorkSessionsPerPursuitPerDay = 2
    public static let maxWorkSessionsGlobalPerDay = 6
    public let dataRoot: URL
    let changeBus: StoreChangeBus
    let opsCompactionThreshold = 2_048
    public init(
        dataRoot: URL,
        changeBus: StoreChangeBus = .shared
    ) {
        self.dataRoot = dataRoot
        self.changeBus = changeBus
    }
    var deskDir: URL { dataRoot.appendingPathComponent("desk", isDirectory: true) }
    public var opsPath: URL { deskDir.appendingPathComponent("desk_ops.jsonl") }
    /// Write the base before truncation so prefix-drop can recover interrupted compaction.
    public var basePath: URL { deskDir.appendingPathComponent("desk_ops_base.json") }
    public var archivePath: URL { deskDir.appendingPathComponent("desk_archive.jsonl") }
    public func continuation(_ handle: String) async throws -> DeskContinuation? {
        try await SwiftNativePersistenceCore.withFileLock(opsPath) {
            let feed = try await readFeedUnlocked()
            guard feed.integrity.isClean else { throw DeskContinuationError.unsafe }
            return try inCurrentLife(Self.compact(base: feed.base, feed.ops)).items.first { $0.handle == handle }?.continuation
        }
    }
    /// Commit continuation revisions with CAS; blocked continuations ask on the task itself.
    /// Reopening rechecks pending effects through their domain.
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
                        blockedReason: """
                            Continuation stopped (\(record.reason ?? "blocked")). Check the unfinished step through its own domain, then set \
                            this task back to todo to continue, or cancel it.
                            """,
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
    /// Scan every create and base high-water so aliases stay unique after closure, archival or truncation.
    /// Pursuits share the top-level sequence with ordinary creates.
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
