import Darwin
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

    /// The `liveState()` replay memo this store consults. Defaults to the
    /// process-wide one; injectable so a test can own an isolated memo rather
    /// than racing every other desk suite for its 8 entries.
    let liveStateMemo: DeskLiveStateMemo

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
        self.liveStateMemo = SwiftNativeDeskStore.sharedLiveStateMemo
    }

    init(
        dataRoot: URL,
        persistence: any PersistenceCoreProtocol = SwiftNativePersistenceCore(),
        changeBus: StoreChangeBus = .shared,
        opsCompactionThreshold: Int = 2_048,
        liveStateMemo: DeskLiveStateMemo
    ) {
        self.dataRoot = dataRoot
        self.persistence = persistence
        self.changeBus = changeBus
        self.opsCompactionThreshold = max(2, opsCompactionThreshold)
        self.liveStateMemo = liveStateMemo
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
        try await persistence.appendJSONLDurable(op.toJSON(), to: opsPath)
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
        try await persistence.writeJSON(state.toJSON(), to: statePath)
        if let newBase = try await compactIfNeededUnlocked(state: state, feed: next) {
            // Compaction ran ⇒ the gate passed ⇒ the rewritten feed is clean.
            next = DeskFeed(base: newBase, ops: [], fileOpCount: 0, integrity: .clean)
        }
        return (state, next)
    }

    /// Read all ops in the FILE (no lock, no base). JSONL appends are
    /// line-atomic via O_APPEND so a reader sees whole lines. Post-compaction
    /// this is only the tail (plus a stale prefix in the crash window) — use
    /// `readFeedUnlocked`/`liveState` for anything semantic.
    public func readOpsUnlocked() async throws -> [DeskOp] {
        try await readOpsWithIntegrityUnlocked().ops
    }

    /// `readOpsUnlocked` plus the accounting of what the scan threw away.
    /// `DeskOp.fromJSON` returns nil for an op token this build does not know
    /// (DeskModels' tolerant `default:` arm) — tolerant on READ, but the count
    /// has to survive to `compactIfNeededUnlocked`, which would otherwise
    /// snapshot state folded without those rows and then delete them.
    func readOpsWithIntegrityUnlocked() async throws -> (ops: [DeskOp], integrity: SnapshotTailOpLog.OpLogIntegrity) {
        let (raw, report) = try await persistence.readJSONLReporting(opsPath)
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

    /// The desk feed's health for the Doctor surface (gpt-5.5 review
    /// 2026-08-02, finding 3): what it cannot decode AND how big it has grown.
    /// Refusing to compact is safe but not free — this is how that trade stops
    /// being an invisible stderr line in a GUI app.
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
        let fileOpCount = ops.count
        guard FileManager.default.fileExists(atPath: basePath.path) else {
            return DeskFeed(base: nil, ops: ops, fileOpCount: fileOpCount, integrity: integrity)
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
        return DeskFeed(base: base, ops: tail, fileOpCount: fileOpCount, integrity: integrity)
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
        // PHYSICAL rows, not decoded ops — see `DeskFeed.compactionRowCount`.
        guard feed.compactionRowCount >= opsCompactionThreshold else { return nil }
        // THE UNKNOWN-ROW GATE (audit 2026-08-02, finding 1). Desk truncates to
        // an EMPTY tail, so a row skipped on read is a row deleted from the only
        // place it exists. A stale DeskSweepCLI reading a newer app's feed is the
        // live failure case — refuse rather than erase. See SnapshotTailOpLog.
        //
        // ORDERED BEFORE the lastOpId guard on purpose (gpt-5.5 review
        // 2026-08-02, finding 2): in the worst skew — a feed where this build
        // decodes NOTHING — `feed.ops` is empty, and asking for a last op id
        // first would return nil silently, so the one loud product signal that
        // the feed is wedged would never be emitted in the very case that needs
        // it most.
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
            case let .createItem(alias, _, _, _, parent, _, _, _, _, _):
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
            case let .setStatus(status, blockedReason, waitingOn, _, _, _) where !status.isTerminal:
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
        summary: String? = nil,
        assignee: String? = nil,
        laneOf: String? = nil
    ) async throws -> DeskItem {
        try await createItemTransaction(
            kind: kind,
            project: project,
            title: title,
            parent: parent,
            summary: summary,
            assignee: assignee,
            laneOf: laneOf,
            reuseEquivalent: false
        ).item
    }

    /// Idempotent owner-create path for conversational tools. Equivalence is
    /// checked under the same flock as alias allocation and append, so two
    /// agents asking for the same live top-level intent cannot race into two
    /// owners. Terminal history never blocks a new item; callers may explicitly
    /// choose `createItem` when a same-named sibling is intentional.
    public func createOrReuseEquivalentItem(
        kind: DeskKind,
        project: String,
        title: String,
        parent: String? = nil,
        summary: String? = nil,
        assignee: String? = nil,
        laneOf: String? = nil
    ) async throws -> CreateResult {
        try await createItemTransaction(
            kind: kind,
            project: project,
            title: title,
            parent: parent,
            summary: summary,
            assignee: assignee,
            laneOf: laneOf,
            reuseEquivalent: true
        )
    }

    private func createItemTransaction(
        kind: DeskKind,
        project: String,
        title: String,
        parent: String?,
        summary: String?,
        assignee: String?,
        laneOf: String?,
        reuseEquivalent: Bool
    ) async throws -> CreateResult {
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
            if reuseEquivalent,
               let existing = priorState.items.first(where: {
                   !$0.status.isTerminal
                       && $0.parent == parent
                       && $0.laneOf == laneOf
                       && Self.equivalentDeskText($0.assignee) == Self.equivalentDeskText(assignee)
                       && Self.equivalentDeskText($0.project) == Self.equivalentDeskText(project)
                       && Self.equivalentDeskText($0.title) == Self.equivalentDeskText(title)
               }) {
                return CreateResult(item: existing, reusedEquivalent: true)
            }
            let alias = Self.nextAlias(parentHandle: parent, parentAlias: parentAlias, base: feed.base, ops: feed.ops)
            let handle = DeskClock.newHandle()
            // The generic create path is HARD-PINNED to origin=.owner with no
            // pursuit (H2) — an origin=agent pursuit can ONLY be minted through
            // openPursuit, which builds the create op with a validated dossier.
            let op = DeskOp(ts: DeskClock.commitStamp(notBefore: feed.maxCommittedTs), handle: handle, body: .createItem(
                alias: alias, kind: kind, project: project, title: title, parent: parent, summary: summary,
                assignee: assignee, laneOf: laneOf,
                origin: .owner, pursuit: nil
            ))
            try Self.validateHierarchyTransition(op, in: priorState, allowArchive: false)
            try Self.validatePursuitInvariants(op, in: priorState, viaGenericPath: true)
            let committedState = try await appendAndRecompactUnlocked(op, feed: feed).state
            guard let created = committedState.items.first(where: { $0.handle == handle }) else {
                throw DeskError.unknownHandle(handle)
            }
            return CreateResult(item: created, reusedEquivalent: false)
        }
    }

    private static func equivalentDeskText(_ value: String?) -> String {
        let folded = (value ?? "")
            .folding(
                options: [.caseInsensitive, .diacriticInsensitive],
                locale: Locale(identifier: "en_US_POSIX")
            )
        let wordsOnly = folded.unicodeScalars.map { scalar in
            CharacterSet.alphanumerics.contains(scalar) ? String(scalar) : " "
        }.joined()
        return wordsOnly
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
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
        summary: String? = nil,
        notify: NotifyPolicy = NotifyPolicy()
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
                    summary: summary, pursuit: pursuit, notify: notify
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
    public func completeWorkSession(
        _ handle: String,
        reservationId: String,
        receipt: String,
        disposition: DeskWorkDisposition? = nil,
        artifactRefs: [String] = []
    ) async throws -> DeskOp {
        try await persistence.withFileLock(opsPath) {
            let feed = try await readFeedUnlocked()
            let state = Self.compact(base: feed.base, feed.ops)
            guard let item = state.items.first(where: { $0.handle == handle }) else {
                throw DeskError.unknownHandle(handle)
            }
            guard item.isPursuit else { throw DeskError.notAPursuit(handle: handle) }
            let body: DeskOpBody = if let disposition {
                .settleWorkSession(
                    reservationId: reservationId,
                    receipt: receipt,
                    disposition: disposition,
                    artifactRefs: Array(artifactRefs.prefix(16))
                )
            } else {
                .completeWorkSession(reservationId: reservationId, receipt: receipt)
            }
            let op = DeskOp(
                ts: DeskClock.commitStamp(notBefore: feed.maxCommittedTs),
                handle: handle,
                body: body
            )
            // Single gate: reservation-exists AND not-already-complete live in
            // the validator so the generic append path enforces them too.
            try Self.validatePursuitInvariants(op, in: state, viaGenericPath: false)
            _ = try await appendAndRecompactUnlocked(op, feed: feed)
            return op
        }
    }

    /// Reserve a typed attempt directly on a non-pursuit Desk item. This is the
    /// admission lane for owner-authored cadence work; it deliberately does
    /// not mutate the pursuit payload or impersonate agent volition.
    @discardableResult
    public func reserveWorkAttempt(
        _ handle: String,
        lane: DeskWorkAttempt.Lane,
        day: String,
        slot: String
    ) async throws -> String {
        try await persistence.withFileLock(opsPath) {
            let feed = try await readFeedUnlocked()
            let state = Self.compact(base: feed.base, feed.ops)
            guard let item = state.items.first(where: { $0.handle == handle }) else {
                throw DeskError.unknownHandle(handle)
            }
            guard !item.status.isTerminal, !item.isPursuit else {
                throw DeskError.notAPursuit(handle: handle)
            }
            let attemptId = DeskClock.workAttemptId(handle: handle, lane: lane, day: day, slot: slot)
            if item.workAttempts.contains(where: { $0.attemptId == attemptId }) { return attemptId }
            let op = DeskOp(
                ts: DeskClock.commitStamp(notBefore: feed.maxCommittedTs),
                handle: handle,
                body: .reserveWorkAttempt(attemptId: attemptId, lane: lane, day: day, slot: slot)
            )
            try Self.validatePursuitInvariants(op, in: state, viaGenericPath: false)
            _ = try await appendAndRecompactUnlocked(op, feed: feed)
            return attemptId
        }
    }

    /// Idempotently settle one typed attempt. Replaying the same terminal
    /// result after a crash is a no-op rather than a duplicate Desk note.
    @discardableResult
    public func completeWorkAttempt(
        _ handle: String,
        attemptId: String,
        receipt: String
    ) async throws -> DeskOp? {
        try await persistence.withFileLock(opsPath) {
            let feed = try await readFeedUnlocked()
            let state = Self.compact(base: feed.base, feed.ops)
            guard let item = state.items.first(where: { $0.handle == handle }) else {
                throw DeskError.unknownHandle(handle)
            }
            guard let attempt = item.workAttempts.first(where: { $0.attemptId == attemptId }) else {
                throw DeskError.unknownReservation(reservationId: attemptId, handle: handle)
            }
            if attempt.completedAt != nil { return nil }
            let op = DeskOp(
                ts: DeskClock.commitStamp(notBefore: feed.maxCommittedTs),
                handle: handle,
                body: .completeWorkAttempt(attemptId: attemptId, receipt: receipt)
            )
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
    public func setStatus(
        _ handle: String,
        status: DeskStatus,
        blockedReason: String? = nil,
        waitingOn: String? = nil,
        progress: DeskProgress? = nil,
        assignee: String? = nil,
        laneOf: String? = nil
    ) async throws -> DeskOp {
        func normalized(_ value: String?, field: String) throws -> String? {
            guard let value else { return nil }
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                throw DeskError.liveActivityMetadataEmpty(field: field)
            }
            return trimmed
        }
        let normalizedAssignee = try normalized(assignee, field: "assignee")
        let normalizedLaneOf = try normalized(laneOf, field: "laneOf")
        return try await appendValidated(DeskOp(
            handle: handle,
            body: .setStatus(
                status: status,
                blockedReason: blockedReason,
                waitingOn: waitingOn,
                progress: progress,
                assignee: normalizedAssignee,
                laneOf: normalizedLaneOf
            )
        ))
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

    /// Append a receipt exactly once, with the existence check and append in
    /// the same flock transaction. Callers supply a stable machine marker at
    /// the start of the note; retries after a crash or concurrent wakeup are a
    /// durable no-op instead of duplicating user-visible history.
    @discardableResult
    public func appendNoteIfAbsent(
        _ handle: String,
        marker: String,
        text: String
    ) async throws -> DeskOp? {
        let normalizedMarker = marker.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedMarker.isEmpty, normalizedText.hasPrefix(normalizedMarker) else {
            throw DeskError.liveActivityMetadataEmpty(field: "idempotent note marker/text")
        }
        return try await persistence.withFileLock(opsPath) {
            let feed = try await readFeedUnlocked()
            let state = Self.compact(base: feed.base, feed.ops)
            guard let item = state.items.first(where: { $0.handle == handle }) else {
                throw DeskError.unknownHandle(handle)
            }
            guard !item.notes.contains(where: { $0.text.hasPrefix(normalizedMarker) }) else {
                return nil
            }
            let op = DeskOp(
                ts: DeskClock.commitStamp(notBefore: feed.maxCommittedTs),
                handle: handle,
                body: .appendNote(text: normalizedText)
            )
            _ = try await appendAndRecompactUnlocked(op, feed: feed)
            return op
        }
    }

    /// Commit the user-facing Observatory veto as one replayable Desk op. A
    /// note and terminal state must never be split across separate writes: on
    /// relaunch the pursuit is either still open, or visibly canceled with its
    /// rationale. Historical partial state is repaired by the same op, while
    /// a completed veto is a durable no-op.
    @discardableResult
    public func vetoPursuit(_ handle: String, note: String) async throws -> DeskOp? {
        let rationale = note.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rationale.isEmpty else {
            throw DeskError.pursuitFieldMissing(reason: "veto rationale is empty")
        }
        return try await persistence.withFileLock(opsPath) {
            let feed = try await readFeedUnlocked()
            let state = Self.compact(base: feed.base, feed.ops)
            guard let item = state.items.first(where: { $0.handle == handle }) else {
                throw DeskError.unknownHandle(handle)
            }
            guard item.isPursuit else { throw DeskError.notAPursuit(handle: handle) }
            if item.status == .canceled,
               item.notes.contains(where: { $0.text == rationale }) {
                return nil
            }
            guard !item.status.isTerminal || item.status == .canceled else {
                throw DeskError.vetoRefusedTerminal(handle: handle, status: item.status)
            }
            let op = DeskOp(
                ts: DeskClock.commitStamp(notBefore: feed.maxCommittedTs),
                handle: handle,
                body: .vetoPursuit(note: rationale)
            )
            try Self.validateHierarchyTransition(op, in: state, allowArchive: false)
            _ = try await appendAndRecompactUnlocked(op, feed: feed)
            return op
        }
    }

    @discardableResult
    public func setCadence(_ handle: String, cadence: Cadence) async throws -> DeskOp {
        try await appendValidated(DeskOp(handle: handle, body: .setCadence(cadence: cadence)))
    }

    @discardableResult
    public func setNotify(_ handle: String, policy: NotifyPolicy) async throws -> DeskOp {
        try await appendValidated(DeskOp(handle: handle, body: .setNotify(policy: policy)))
    }

    // MARK: - Sequencing edges (blocked-on / defer)

    /// setBlockedOn — REPLACE the whole blocker set for `handle`. Blockers are
    /// stable handles of LIVE items (the chat lane resolves aliases first).
    /// Validated UNDER THE OPS FLOCK against ops-derived live state so a refusal
    /// can't race a sibling close: unknown blocker, self-block, and any edge that
    /// would close a cycle are all refused.
    ///
    /// The ts is minted INSIDE the lock via commitStamp — a defaulted timestamp
    /// parameter would be evaluated at the call site BEFORE the lock and could
    /// commit behind a later-issued stamp (the trap this file documents).
    @discardableResult
    public func setBlockedOn(_ handle: String, blockers: [String]) async throws -> DeskOp {
        try await persistence.withFileLock(opsPath) {
            let feed = try await readFeedUnlocked()
            let state = Self.compact(base: feed.base, feed.ops)
            guard state.items.contains(where: { $0.handle == handle }) else {
                throw DeskError.unknownHandle(handle)
            }
            let proposed = Self.normalizeBlockers(blockers)
            try Self.validateBlockedOn(handle: handle, proposed: proposed, in: state)
            let op = DeskOp(
                ts: DeskClock.commitStamp(notBefore: feed.maxCommittedTs),
                handle: handle,
                body: .setBlockedOn(handles: proposed)
            )
            _ = try await appendAndRecompactUnlocked(op, feed: feed)
            return op
        }
    }

    /// setDeferUntil — park `handle` until a day (`yyyy-MM-dd`) or ISO stamp.
    /// nil / empty CLEARS. An unparseable value is REFUSED rather than stored:
    /// the read side treats an unparseable defer as NOT deferred (never park an
    /// item forever silently), so accepting one here would quietly no-op.
    @discardableResult
    public func setDeferUntil(_ handle: String, until: String?) async throws -> DeskOp {
        try await persistence.withFileLock(opsPath) {
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

    /// Write-time gate for a proposed blocker set: every blocker must be a live
    /// item, an item may not block itself, and the edge must not close a cycle in
    /// the PROSPECTIVE graph (live edges with this item's edges replaced by the
    /// proposal). A cycle is unresolvable — nothing in it can ever become ready.
    static func validateBlockedOn(handle: String, proposed: [String], in state: DeskState) throws {
        let liveHandles = Set(state.items.map(\.handle))
        for blocker in proposed {
            if blocker == handle { throw DeskError.blockedOnSelf(handle: handle) }
            guard liveHandles.contains(blocker) else {
                throw DeskError.blockedOnUnknown(handle: handle, blocker: blocker)
            }
        }
        var edges: [String: [String]] = [:]
        for item in state.items { edges[item.handle] = item.blockedOn }
        edges[handle] = proposed

        // Is `handle` reachable FROM any proposed blocker? If so the proposal
        // closes a loop. DFS carries the path so the refusal can name it, and is
        // bounded by both a visited set (existing cycles elsewhere in the graph
        // can't hang it) and a depth cap.
        for start in proposed {
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
        try await persistence.withFileLock(opsPath) {
            let feed = try await readFeedUnlocked()
            let state = Self.compact(base: feed.base, feed.ops)
            guard let item = state.items.first(where: { $0.handle == handle }) else {
                throw DeskError.unknownHandle(handle)
            }
            guard item.isPursuit, !item.status.isTerminal,
                  item.updatedAt == expectedUpdatedAt,
                  let reservation = item.pursuit?.reservations.first(where: {
                      $0.reservationId == reservationId
                  }),
                  reservation.completedAt != nil,
                  reservation.disposition == .goalSatisfied else {
                return false
            }
            var op = DeskOp(
                handle: handle,
                body: .closeItem(outcomeSummary: outcomeSummary, status: .done)
            )
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
                        waitingOn: prior.waitingOn,
                        progress: nil,
                        assignee: nil,
                        laneOf: nil
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
                        //
                        // 2026-09-06: durable: true. The archive record is the
                        // ONLY trace an archived item leaves, and the removing
                        // op two lines below is already durable — so a power
                        // cut between them left the item gone from live state
                        // with no record that it ever existed. "record before
                        // op" only holds if the record is on the platter first.
                        try await appendJSONLCapped(
                            rec.toJSON(), to: archivePath, using: persistence,
                            maxLines: JSONLLineCaps.deskArchive,
                            logLabel: SwiftNativeDeskStore.logLabel,
                            takeLock: false,
                            durable: true
                        )
                    }
                    let archiveOp = DeskOp(ts: now, handle: node.handle, body: .archiveItem)
                    // The whole subtree was validated against one locked state.
                    // Append every canonical op first, then fold/write the derived
                    // state once; the previous per-node recompaction was O(K×N)
                    // and wrote K transient projections that no reader could see
                    // while this same flock was held.
                    try await persistence.appendJSONLDurable(archiveOp.toJSON(), to: opsPath)
                    feed.ops.append(archiveOp)
                    feed.noteAppendedRows(1)
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
    /// PERF (wave 2, F5): the replay is MEMOIZED on the feed's (device, inode,
    /// size, mtime_ns) identity for BOTH files it reads — `desk_ops.jsonl` and
    /// `desk_ops_base.json`. One desk event fans out into ~5 `liveState()`
    /// calls (desk_notify's `nextMeaningfulDeadline` + `tickOutcome`,
    /// workshop_pump's `nextMeaningfulDeadline` + the pump's own read), each
    /// re-decoding the live 352KB op-log plus the 179KB base and re-running the
    /// reducer to produce the SAME bytes.
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
        try await persistence.withFileLock(opsPath) {
            let key = Self.memoKey(opsPath)
            let before = Self.feedStamp(opsPath: opsPath, basePath: basePath)
            if let cached = await liveStateMemo.lookup(key: key, stamp: before) {
                return cached
            }
            let feed = try await readFeedUnlocked()
            let state = Self.compact(base: feed.base, feed.ops)
            let after = Self.feedStamp(opsPath: opsPath, basePath: basePath)
            if let before, after == before {
                await liveStateMemo.store(key: key, stamp: before, state: state)
            }
            return state
        }
    }

    /// Process-wide `liveState()` memo. Keyed on the ops path so alternate data
    /// roots (tests, secondary roots, the sweep CLI's root) never collide.
    static let sharedLiveStateMemo = DeskLiveStateMemo()

    /// Symlinks are resolved so the same desk reached through `/var/...` and
    /// `/private/var/...` is one entry (wave-1 review: an unresolved key both
    /// double-caches and defeats eviction).
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
        case let .createItem(_, _, _, _, _, _, _, _, origin, _):
            // A create_item can NEVER mint an agent pursuit — that path is
            // open_pursuit only (H2). An origin=agent create_item is refused
            // regardless of who calls it.
            guard origin == .agent else { return }   // owner/system creates are unconstrained here
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
            let global = state.items.reduce(0) { count, row in
                count
                    + (row.pursuit?.reservations.filter { $0.day == day }.count ?? 0)
                    + row.workAttempts.filter { $0.day == day }.count
            }
            if global >= maxWorkSessionsGlobalPerDay {
                throw DeskError.workSessionCapReached(scope: "workshop (6/day)", limit: maxWorkSessionsGlobalPerDay, handle: op.handle)
            }

        case let .completeWorkSession(reservationId, _),
             let .settleWorkSession(reservationId, _, _, _):
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

        case let .reserveWorkAttempt(attemptId, lane, day, _):
            guard lane == .ownerCadence,
                  let item = state.items.first(where: { $0.handle == op.handle }),
                  !item.status.isTerminal, !item.isPursuit else {
                throw DeskError.unknownHandle(op.handle)
            }
            if item.workAttempts.contains(where: { $0.attemptId == attemptId }) { return }
            if item.workAttempts.filter({ $0.day == day }).count >= 1 {
                throw DeskError.workSessionCapReached(scope: "per-owner-item (1/day)", limit: 1, handle: op.handle)
            }
            let global = state.items.reduce(0) { count, row in
                count
                    + (row.pursuit?.reservations.filter { $0.day == day }.count ?? 0)
                    + row.workAttempts.filter { $0.day == day }.count
            }
            if global >= maxWorkSessionsGlobalPerDay {
                throw DeskError.workSessionCapReached(scope: "workshop (6/day)", limit: maxWorkSessionsGlobalPerDay, handle: op.handle)
            }

        case let .completeWorkAttempt(attemptId, _):
            guard let item = state.items.first(where: { $0.handle == op.handle }),
                  let attempt = item.workAttempts.first(where: { $0.attemptId == attemptId }) else {
                throw DeskError.unknownReservation(reservationId: attemptId, handle: op.handle)
            }
            if attempt.completedAt != nil {
                throw DeskError.reservationAlreadyComplete(reservationId: attemptId, handle: op.handle)
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
    private static func validateHierarchyTransition(
        _ op: DeskOp,
        in state: DeskState,
        allowArchive: Bool
    ) throws {
        switch op.body {
        case let .createItem(_, _, _, _, parent, _, _, _, _, _):
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
            case let .setStatus(status, blockedReason, waitingOn, _, _, _) where !status.isTerminal:
                result = (status, blockedReason, waitingOn)
            default:
                break
            }
        }
        return result
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
            case .createItem(let alias, _, _, _, let parent, _, _, _, _, _):
                return parent == parentHandle ? alias : nil
            case .openPursuit(let alias, _, _, _, _, _):
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

}

// MARK: - liveState() replay memo (perf wave 2, F5)

/// Process-wide memo behind `SwiftNativeDeskStore.liveState()`.
///
/// Every entry is keyed on the ops path AND stamped with the stat identity of
/// the two files a replay reads. A hit is only ever served while the caller
/// holds the ops flock, so this is strictly a decode+reduce skip: the lock, the
/// blocking behaviour, and the compaction-straddle guarantee are untouched.
actor DeskLiveStateMemo {
    typealias FeedStamp = SnapshotTailOpLog.FeedStamp

    /// Bound on distinct data roots held at once. Roots are few (live + any
    /// test/secondary root); the cap exists so a long-lived process that walks
    /// many temp roots cannot grow this map without limit — every insert has a
    /// matching eviction.
    static let maxEntries = 8

    private struct Entry: Sendable {
        let stamp: FeedStamp
        let state: DeskState
    }

    private var entries: [String: Entry] = [:]
    /// Least-recently-stored first; the eviction order for `maxEntries`.
    private var order: [String] = []
    /// PER-KEY hit/miss tallies. Test-only, and per-key on purpose: the memo is
    /// process-wide, so global counters are polluted by every other desk suite
    /// running concurrently in the same test process.
    private var counters: [String: (hits: Int, misses: Int)] = [:]

    func lookup(key: String, stamp: FeedStamp?) -> DeskState? {
        var tally = counters[key] ?? (0, 0)
        defer { note(key: key, tally: tally) }
        guard let stamp, let entry = entries[key], entry.stamp == stamp else {
            tally.misses += 1
            return nil
        }
        tally.hits += 1
        return entry.state
    }

    private func note(key: String, tally: (hits: Int, misses: Int)) {
        if counters[key] == nil, counters.count >= Self.maxEntries * 4 {
            counters.removeAll()
        }
        counters[key] = tally
    }

    func store(key: String, stamp: FeedStamp, state: DeskState) {
        if entries[key] == nil {
            order.append(key)
            while order.count > Self.maxEntries, let oldest = order.first {
                order.removeFirst()
                entries[oldest] = nil
            }
        }
        entries[key] = Entry(stamp: stamp, state: state)
    }

    /// Test seam: fresh-process equivalent for ONE feed. Key-scoped on
    /// purpose — this memo is process-wide, so a global wipe from one test
    /// silently re-warms every other test running beside it.
    func forget(key: String) {
        entries[key] = nil
        order.removeAll { $0 == key }
        counters[key] = nil
    }

    /// Test seam: fresh-process equivalent for everything. Only safe when no
    /// other desk work is in flight.
    func reset() {
        entries.removeAll()
        order.removeAll()
        counters.removeAll()
    }

    /// Test seam: this key's tallies plus the live entry count.
    func _testStats(key: String) -> (hits: Int, misses: Int, entries: Int) {
        let tally = counters[key] ?? (0, 0)
        return (tally.hits, tally.misses, entries.count)
    }
}
