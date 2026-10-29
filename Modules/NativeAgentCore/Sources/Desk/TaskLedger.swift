import Foundation
import PersistenceCore
// Blueprint: | `TaskLedger.swift` | `SwiftNativeTaskLedger` owns the orchestration event feed and compaction base; the CLI and wrapper use `PersistenceCore.defaultDataRoot()` unless `--data-root` is explicit |

// MARK: - Cross-agent task ledger
//
// Shared append-under-flock state records task ownership, progress and outcomes.
//
// MODULE HOME: Desk. The ledger owns orchestration records here and imports
// PersistenceCore for shared JSONL, snapshot/tail and task-tree-aware flock IO.
//
// STORE:
//   • <dataRoot>/orchestration/task_ledger.jsonl — append-only EVENTS feed.
//   • <dataRoot>/orchestration/task_ledger_base.json — compaction snapshot.
//   Both under the events-feed flock discipline (withFileLock + the shared
//   `<path>.lock` sidecar). Bound: snapshot+tail compaction at newest-5000
//   with a threshold/4 keep-tail.
//
// EVENT SCHEMA: {id, taskId, ts, actor, kind, title?, note?, refs[]}
//   actor in claude | assistant | codex | user
//   kind  ∈ created | claimed | update | blocked | done | cancelled
//
// CROSS-PROCESS: the CLI writer (script/task_ledger.sh -> task-ledger) flocks the SAME
// `<path>.lock` sidecar this module's withFileLock uses (open O_CREAT|O_WRONLY
// 0o600 + flock LOCK_EX), so Swift-in-app and Swift-on-CLI serialize against
// each other on the events file. See PersistenceCore+FileLock.swift for the
// lock-file naming convention both sides match exactly. No Python helper owns
// this path on the Swift-native branch.

// MARK: - Event types

public enum TaskLedgerActor: String, Sendable, CaseIterable {
    case claude, assistant, codex, user

    /// Decode accepts historical actor aliases; writes use canonical raw values without rewriting stored events.
    public init?(wire raw: String) {
        if let canonical = TaskLedgerActor(rawValue: raw) {
            self = canonical
        } else if raw == "agent" {
            self = .assistant
        } else {
            return nil
        }
    }
}

public enum TaskLedgerKind: String, Sendable, CaseIterable {
    case created, claimed, update, blocked, done, cancelled, deleted
}

/// One append-only ledger event. `id` is the event id; `taskId` groups events
/// for one task. `title`/`note` are optional free text; `refs` are opaque
/// reference strings (file paths, commit ids, PR urls, etc.).
public struct TaskLedgerEvent: Sendable, Equatable {
    public var id: String
    public var taskId: String
    public var ts: String          // ISO-8601 UTC, microsecond precision
    public var actor: TaskLedgerActor
    public var kind: TaskLedgerKind
    public var title: String?
    public var note: String?
    public var refs: [String]

    public init(
        id: String = UUID().uuidString,
        taskId: String,
        ts: String? = nil,
        actor: TaskLedgerActor,
        kind: TaskLedgerKind,
        title: String? = nil,
        note: String? = nil,
        refs: [String] = []
    ) {
        self.id = id
        self.taskId = taskId
        self.ts = ts ?? DeskClock.nowISO(Date())
        self.actor = actor
        self.kind = kind
        self.title = title
        self.note = note
        self.refs = refs
    }

    /// Serialize to the JSONValue wire form persisted to the events feed.
    /// Optional fields are omitted when nil/empty (NOT emitted as null) so the
    /// Python CLI writer and this Swift writer produce the same shape.
    public func toJSON() -> JSONValue {
        var obj: [String: JSONValue] = [
            "id": .string(id),
            "taskId": .string(taskId),
            "ts": .string(ts),
            "actor": .string(actor.rawValue),
            "kind": .string(kind.rawValue),
        ]
        if let title, !title.isEmpty { obj["title"] = .string(title) }
        if let note, !note.isEmpty { obj["note"] = .string(note) }
        if !refs.isEmpty { obj["refs"] = .array(refs.map { .string($0) }) }
        return .object(obj)
    }

    /// Parse one event off the feed. Tolerant of unknown actor/kind tokens
    /// (skipped → nil) so a future schema addition by one writer never crashes
    /// an older reader.
    public static func fromJSON(_ value: JSONValue) -> TaskLedgerEvent? {
        guard case .object(let obj) = value,
              case .string(let id)? = obj["id"],
              case .string(let taskId)? = obj["taskId"],
              case .string(let ts)? = obj["ts"],
              case .string(let actorRaw)? = obj["actor"],
              case .string(let kindRaw)? = obj["kind"],
              let actor = TaskLedgerActor(wire: actorRaw),
              let kind = TaskLedgerKind(rawValue: kindRaw) else {
            return nil
        }
        var title: String?
        if case .string(let t)? = obj["title"] { title = t }
        var note: String?
        if case .string(let n)? = obj["note"] { note = n }
        var refs: [String] = []
        if case .array(let arr)? = obj["refs"] {
            refs = arr.compactMap { if case .string(let s) = $0 { return s } else { return nil } }
        }
        return TaskLedgerEvent(
            id: id, taskId: taskId, ts: ts, actor: actor, kind: kind,
            title: title, note: note, refs: refs
        )
    }
}

/// Derived (compacted) state for one task — the latest title/owner/status
/// folded from its event stream. Deletion remains the final status.
public struct TaskLedgerTaskState: Sendable, Equatable {
    public var taskId: String
    public var title: String?
    public var owner: TaskLedgerActor?     // last claimer (nil if never claimed)
    public var status: TaskLedgerKind       // last kind applied before or at deletion
    public var createdTs: String
    public var updatedTs: String
    public var lastNote: String?
    public var refs: [String]               // union of all refs seen, in first-seen order

    public func toJSON() -> JSONValue {
        var obj: [String: JSONValue] = [
            "taskId": .string(taskId),
            "status": .string(status.rawValue),
            "createdTs": .string(createdTs),
            "updatedTs": .string(updatedTs),
        ]
        if let title, !title.isEmpty { obj["title"] = .string(title) }
        if let owner { obj["owner"] = .string(owner.rawValue) }
        if let lastNote, !lastNote.isEmpty { obj["lastNote"] = .string(lastNote) }
        if !refs.isEmpty { obj["refs"] = .array(refs.map { .string($0) }) }
        return .object(obj)
    }

    /// Parse one compacted task state off the compaction base. Mirrors `toJSON`:
    /// `status`/`taskId`/`createdTs`/`updatedTs` are required, the rest optional.
    public static func fromJSON(_ value: JSONValue) -> TaskLedgerTaskState? {
        guard case .object(let obj) = value,
              case .string(let taskId)? = obj["taskId"],
              case .string(let statusRaw)? = obj["status"],
              let status = TaskLedgerKind(rawValue: statusRaw),
              case .string(let createdTs)? = obj["createdTs"],
              case .string(let updatedTs)? = obj["updatedTs"] else {
            return nil
        }
        var title: String?
        if case .string(let t)? = obj["title"] { title = t }
        var owner: TaskLedgerActor?
        if case .string(let o)? = obj["owner"] { owner = TaskLedgerActor(wire: o) }
        var lastNote: String?
        if case .string(let n)? = obj["lastNote"] { lastNote = n }
        var refs: [String] = []
        if case .array(let arr)? = obj["refs"] {
            refs = arr.compactMap { if case .string(let s) = $0 { return s } else { return nil } }
        }
        let state = TaskLedgerTaskState(
            taskId: taskId, title: title, owner: owner, status: status,
            createdTs: createdTs, updatedTs: updatedTs, lastNote: lastNote, refs: refs
        )
        // The sole surviving snapshot may normalize only the documented alias.
        var migrated = obj
        if migrated["owner"] == .string("agent") { migrated["owner"] = .string("assistant") }
        guard state.toJSON() == .object(migrated) else { return nil }
        return state
    }
}

/// The base retains full reduced task state through lastCompactedOpId in first-seen order.
/// Replay applies only following events; an absent base starts from genesis.
struct TaskLedgerCompactionBase: Sendable, Equatable {
    let tasks: [TaskLedgerTaskState]
    let lastCompactedOpId: String
    let compactedAt: String
    let compactedOpCount: Int

    func toJSON() -> JSONValue {
        .object([
            "version": .int(1),
            "tasks": .array(tasks.map { $0.toJSON() }),
            "lastCompactedOpId": .string(lastCompactedOpId),
            "compactedAt": .string(compactedAt),
            "compactedOpCount": .int(Int64(compactedOpCount)),
        ])
    }

    /// STRICT decode — a malformed task row fails the whole base so the caller
    /// throws rather than folding from the tail alone (which would silently drop
    /// every compacted task). `lastCompactedOpId` must be present and non-empty.
    static func fromJSON(_ value: JSONValue) -> TaskLedgerCompactionBase? {
        guard case .object(let obj) = value,
              obj["version"] == .int(1),
              case .array(let rows)? = obj["tasks"],
              case .string(let lastCompactedOpId)? = obj["lastCompactedOpId"],
              !lastCompactedOpId.isEmpty,
              case .string(let compactedAt)? = obj["compactedAt"] else {
            return nil
        }
        var tasks: [TaskLedgerTaskState] = []
        tasks.reserveCapacity(rows.count)
        for row in rows {
            guard let state = TaskLedgerTaskState.fromJSON(row) else { return nil }
            tasks.append(state)
        }
        var migrated = obj
        // Older bases omitted the accounting field; no task data is inferred.
        if migrated["compactedOpCount"] == nil { migrated["compactedOpCount"] = .int(0) }
        guard case .int(let rawCount)? = migrated["compactedOpCount"], rawCount >= 0,
              let compactedOpCount = Int(exactly: rawCount) else { return nil }
        migrated["tasks"] = .array(tasks.map { $0.toJSON() })
        let base = TaskLedgerCompactionBase(
            tasks: tasks, lastCompactedOpId: lastCompactedOpId,
            compactedAt: compactedAt, compactedOpCount: compactedOpCount
        )
        guard base.toJSON() == .object(migrated) else { return nil }
        return base
    }
}

/// One consistent read of the replayable feed: the compaction base (if any) and
/// the tail events that FOLLOW it, plus the raw file event count (the trim
/// threshold keys on actual file size, pre prefix-drop).
struct TaskLedgerFeed: Sendable {
    let base: TaskLedgerCompactionBase?
    var events: [TaskLedgerEvent]
    var fileEventCount: Int
    /// What the raw feed scan could not use — malformed lines and events whose
    /// `kind` token this build does not know. Compaction REFUSES while this is
    /// non-clean: the truncate drops everything before the kept tail, so a
    /// skipped row would be erased. Same policy as DeskStore; see
    /// `SnapshotTailOpLog`.
    var integrity: SnapshotTailOpLog.OpLogIntegrity = .clean

    /// Compaction thresholds count physical feed rows, including undecodable events.
    var compactionRowCount: Int { integrity.feedRowCount(decodedCount: fileEventCount) }
}

public struct TaskLedgerBaseCorrupt: Error, LocalizedError, Sendable {
    public let path: String
    public var errorDescription: String? {
        "task ledger: compaction base at \(path) exists but does not decode — refusing to fold from the tail alone (that would silently drop every compacted task)"
    }
}

/// The base file EXISTS but its bytes could not be read at all (fd exhaustion,
/// an iCloud dataless placeholder, a transient IO error). Distinct from
/// `TaskLedgerBaseCorrupt` on purpose: this one is TRANSIENT and retryable, so
/// it must never be reported as — or acted on like — permanent corruption.
public struct TaskLedgerBaseUnreadable: Error, LocalizedError, Sendable {
    public let path: String
    public var errorDescription: String? {
        "task ledger: compaction base at \(path) exists but its bytes could not be read (transient IO — fd exhaustion or a dataless file); retry rather than treating the ledger as corrupt"
    }
}

public struct TaskLedgerClaimConflict: Error, LocalizedError, Sendable {
    public let taskId: String
    public let owner: TaskLedgerActor
    public let status: TaskLedgerKind

    public var errorDescription: String? {
        "task \(taskId) already claimed by \(owner.rawValue) (status \(status.rawValue)); use --force to take over"
    }
}

public struct TaskLedgerInvalidClaimEvent: Error, LocalizedError, Sendable {
    public let kind: TaskLedgerKind

    public var errorDescription: String? {
        "claim requires kind claimed, got \(kind.rawValue)"
    }
}

public struct TaskLedgerTaskDeleted: Error, LocalizedError, Sendable {
    public let taskId: String

    public var errorDescription: String? {
        "task \(taskId) was deleted; further writes are refused"
    }
}

// MARK: - Reader / writer

/// Append-under-flock task-ledger store. Stateless — all state lives on disk.
/// The events feed and compaction base share the events feed's flock,
/// so replay and compaction can never race an append.
/// Owns task_ledger.jsonl and its versioned compaction base.
/// Local backup/export and phone sync exclude orchestration/; off-disk includes
/// it; PrivacyMap lists the tree.
public struct SwiftNativeTaskLedger: Sendable {
    public static let logLabel = "TaskLedger"
    /// Crossing this bound triggers snapshot+truncate compaction; founding task events survive in the base.
    public static let maxLines = JSONLLineCaps.activityEvents
    /// File event count that triggers a snapshot+truncate on the next in-lock
    /// append.
    static let opsCompactionThreshold = JSONLLineCaps.activityEvents
    /// Retain the newest threshold/4 events so compaction amortizes across the next 3/4 threshold appends.
    static let compactionKeepTail = max(1, opsCompactionThreshold / 4)
    /// Done/cancelled tasks older than this since their last update are evicted when the base folds.
    static let terminalTaskRetention: TimeInterval = 30 * 24 * 60 * 60
    /// Per-task cap on the derived `refs` union. Without it a long-lived task
    /// that attaches a ref per event grows the derived state — and the
    /// compaction base it is baked into — without bound. Newest-wins.
    static let maxRefsPerTask = 64

    public let dataRoot: URL
    public init(dataRoot: URL) {
        self.dataRoot = dataRoot
    }

    /// `<dataRoot>/orchestration/task_ledger.jsonl`.
    public var eventsPath: URL {
        dataRoot
            .appendingPathComponent("orchestration", isDirectory: true)
            .appendingPathComponent("task_ledger.jsonl")
    }

    /// `<dataRoot>/orchestration/task_ledger_base.json` — the compaction snapshot
    /// the feed folds FROM. Written atomically BEFORE the feed truncate; a
    /// crash between the two is healed by the replay prefix-drop.
    public var basePath: URL {
        dataRoot
            .appendingPathComponent("orchestration", isDirectory: true)
            .appendingPathComponent("task_ledger_base.json")
    }

    /// Append one event and compact if needed under the events-feed flock.
    @discardableResult
    public func append(_ event: TaskLedgerEvent) async throws -> TaskLedgerEvent {
        try await SwiftNativePersistenceCore.withFileLock(eventsPath) {
            let feed = try await readFeedUnlocked().feed
            let current = Self.compact(base: feed.base, feed.events).first { $0.taskId == event.taskId }
            try await appendAndRecompactUnlocked(event, feed: feed, current: current)
        }
        return event
    }

    /// Append a delete marker only if the current task still has the title
    /// observed by the caller. The same flock protects the comparison and append.
    @discardableResult
    public func delete(_ event: TaskLedgerEvent, expectedTitle: String) async throws -> Bool {
        guard event.kind == .deleted else { return false }
        return try await SwiftNativePersistenceCore.withFileLock(eventsPath) {
            let feed = try await readFeedUnlocked().feed
            guard let current = Self.compact(base: feed.base, feed.events).first(where: { $0.taskId == event.taskId }) else { return false }
            guard current.status != .deleted else {
                throw TaskLedgerTaskDeleted(taskId: event.taskId)
            }
            guard current.title == expectedTitle else { return false }
            try await appendAndRecompactUnlocked(event, feed: feed, current: current)
            return true
        }
    }

    /// Claim a task with an in-lock compare-and-set guard. Without `force`,
    /// another actor's active `claimed` / `update` state refuses the takeover.
    @discardableResult
    public func claim(_ event: TaskLedgerEvent, force: Bool = false) async throws -> TaskLedgerEvent {
        guard event.kind == .claimed else {
            throw TaskLedgerInvalidClaimEvent(kind: event.kind)
        }
        try await SwiftNativePersistenceCore.withFileLock(eventsPath) {
            let feed = try await readFeedUnlocked().feed
            let current = Self.compact(base: feed.base, feed.events).first { $0.taskId == event.taskId }
            if !force, let task = current,
               let owner = task.owner, owner != event.actor,
               task.status == .claimed || task.status == .update {
                throw TaskLedgerClaimConflict(taskId: event.taskId, owner: owner, status: task.status)
            }
            try await appendAndRecompactUnlocked(event, feed: feed, current: current)
        }
        return event
    }

    private func appendAndRecompactUnlocked(_ event: TaskLedgerEvent, feed: TaskLedgerFeed, current: TaskLedgerTaskState?) async throws {
        // The caller holds the flock: deletion cannot race this refusal.
        if current?.status == .deleted {
            throw TaskLedgerTaskDeleted(taskId: event.taskId)
        }
        // Snapshot-before-truncate compaction retains each task's founding state.
        try await SwiftNativePersistenceCore.appendJSONLDurable(event.toJSON(), to: eventsPath)
        var next = feed
        // Match the wire form's omitted empty optional fields.
        var committed = event
        if committed.title?.isEmpty == true { committed.title = nil }
        if committed.note?.isEmpty == true { committed.note = nil }
        if committed.id == feed.base?.lastCompactedOpId {
            next.events.removeAll()
        } else {
            next.events.append(committed)
        }
        next.fileEventCount += 1
        next.integrity = next.integrity.appendingRows(1)
        // The durable append terminates a torn last line before its new row,
        // making the old fragment malformed rather than a tolerated tail.
        if next.integrity.trailingPartialLine {
            next.integrity.malformedLineCount += 1
            next.integrity.trailingPartialLine = false
        }
        // End-of-transaction snapshot+truncate once the feed file crosses the
        // threshold: fold the pre-tail prefix into the base, keep the newest tail.
        try await compactIfNeededUnlocked(feed: next)
    }

    /// Snapshot the pre-tail prefix into the base and truncate the feed to the
    /// newest `compactionKeepTail` events, once the raw file crosses `opsCompactionThreshold`.
    /// The base is written atomically BEFORE the feed rewrite; the replay
    /// prefix-drop makes the in-between crash window safe (never lost, never
    /// double-applied). The caller holds the events flock.
    private func compactIfNeededUnlocked(feed: TaskLedgerFeed) async throws {
        // PHYSICAL rows, not decoded events — see `TaskLedgerFeed.compactionRowCount`.
        guard feed.compactionRowCount >= Self.opsCompactionThreshold else { return }
        // Refuse compaction if any row cannot be folded, preserving newer writers' event kinds.
        guard SnapshotTailOpLog.mayCompact(feed.integrity, feed: Self.logLabel, path: eventsPath) else { return }
        // `feed.events` is already base+tail (prefix-dropped). Fold everything
        // EXCEPT the kept tail into the (existing) base.
        guard feed.events.count > Self.compactionKeepTail else { return }
        let prefix = Array(feed.events.dropLast(Self.compactionKeepTail))
        let tail = Array(feed.events.suffix(Self.compactionKeepTail))
        guard let lastPrefix = prefix.last else { return }
        // "Now" for the retention fold is the FEED'S OWN newest stamp, never
        // wall-clock (mirrors GitHubCommandStore's terminal retirement, which
        // anchors to `updatedAt`): the same feed must fold to the same base on
        // every machine and at every replay, otherwise two writers compacting
        // the identical feed minutes apart produce different bases and the
        // eviction boundary drifts with whoever happened to run the append.
        // No parseable stamp anywhere in the feed → evict nothing (eviction
        // must never lose a row just because the clock is unreadable).
        let folded = Self.compact(base: feed.base, prefix)
        let feedNow = feed.events.compactMap { DeskClock.parseISO($0.ts) }.max()
        let tailTaskIDs = Set(tail.map(\.taskId))
        let baseTasks = feedNow.map { now in
            folded.filter { tailTaskIDs.contains($0.taskId) || Self.retainInCompactionBase($0, now: now) }
        } ?? folded
        let newBase = TaskLedgerCompactionBase(
            tasks: baseTasks,
            lastCompactedOpId: lastPrefix.id,
            compactedAt: DeskClock.nowISO(Date()),
            compactedOpCount: feed.fileEventCount
        )
        try await SnapshotTailOpLog.commitCompaction(
            baseJSON: newBase.toJSON(),
            tailRows: tail.map { $0.toJSON() },
            basePath: basePath, opsPath: eventsPath
        )
    }

    /// Retention predicate for the compaction-base fold:
    /// done/cancelled tasks past `terminalTaskRetention` are retired from the
    /// base. Deleted tasks retain their tombstone so later events cannot revive
    /// them after the original delete event leaves the tail. Non-terminal tasks
    /// always retain, and an unparseable stamp fails toward KEEPING the task.
    static func retainInCompactionBase(_ task: TaskLedgerTaskState, now: Date) -> Bool {
        if task.status == .deleted { return true }
        guard task.status == .done || task.status == .cancelled else { return true }
        guard let updated = DeskClock.parseISO(task.updatedTs) else { return true }
        return now.timeIntervalSince(updated) < terminalTaskRetention
    }

    /// All events in the FILE (no lock, no base), plus the accounting of what
    /// the scan threw away.
    /// `TaskLedgerEvent.fromJSON` returns nil for an unknown `kind` — tolerant
    /// on read, but the count must reach `compactIfNeededUnlocked` so the fold
    /// cannot delete rows it never folded.
    func readEventsWithIntegrityUnlocked() async throws -> (events: [TaskLedgerEvent], integrity: SnapshotTailOpLog.OpLogIntegrity) {
        let (raw, report) = try await SwiftNativePersistenceCore.readJSONLReporting(eventsPath)
        let events = raw.compactMap { TaskLedgerEvent.fromJSON($0) }
        let integrity = SnapshotTailOpLog.OpLogIntegrity(
            malformedLineCount: report.malformedLineCount,
            undecodableRowCount: raw.count - events.count,
            trailingPartialLine: report.trailingPartialLine,
            physicalRowCount: report.physicalLineCount
        )
        SnapshotTailOpLog.noteIntegrity(integrity, feed: Self.logLabel, path: eventsPath)
        return (events, integrity)
    }

    /// The readable counter behind the log line: what the ledger's feed
    /// currently cannot decode. Non-zero means compaction is (correctly)
    /// refusing to run and the feed is growing.
    public func feedIntegrity() async throws -> SnapshotTailOpLog.OpLogIntegrity {
        try await readEventsWithIntegrityUnlocked().integrity
    }

    /// Doctor feed health includes undecodable rows and physical feed size.
    public func feedHealth() async throws -> SnapshotTailOpLog.OpLogHealth {
        let integrity = try await feedIntegrity()
        return SnapshotTailOpLog.OpLogHealth(
            feed: Self.logLabel,
            path: eventsPath,
            physicalRowCount: integrity.physicalRowCount,
            byteCount: SnapshotTailOpLog.OpLogHealth.fileSize(eventsPath),
            compactionThreshold: Self.opsCompactionThreshold,
            integrity: integrity
        )
    }

    /// Read the replayable feed: the compaction base (if any) + the events that
    /// FOLLOW it. Events are read FIRST, base SECOND — a reader racing a
    /// compaction then sees (old/absent base, full ops), (new base, full ops →
    /// prefix-dropped), or (new base, truncated ops); the prefix-drop also heals
    /// a crash between base write and feed truncate. A base file that EXISTS but
    /// does not decode throws (folding the tail alone would blank compacted
    /// tasks). No base file → genesis: the whole feed folds from empty.
    func readFeedUnlocked() async throws -> (feed: TaskLedgerFeed, rawEvents: [TaskLedgerEvent]) {
        let (events, integrity) = try await readEventsWithIntegrityUnlocked()
        return (try readFeedUnlocked(events: events, integrity: integrity), events)
    }

    private func readFeedUnlocked(events: [TaskLedgerEvent], integrity: SnapshotTailOpLog.OpLogIntegrity) throws -> TaskLedgerFeed {
        let fileEventCount = events.count
        guard FileManager.default.fileExists(atPath: basePath.path) else {
            return TaskLedgerFeed(base: nil, events: events, fileEventCount: fileEventCount, integrity: integrity)
        }
        // Read the base bytes DIRECTLY — `SwiftNativePersistenceCore.readJSON` collapses every
        // failure mode into its default (EMFILE burst, an iCloud dataless
        // placeholder, a mid-read EIO all look identical to a parse failure),
        // and the corruption invariant below is PERMANENT: it bricks reads AND
        // writes. Separating "could not read the bytes" (transient → throw a
        // distinct, retryable error) from "read the bytes, they are not a base"
        // (genuine corruption → fail loud) keeps the fail-loud contract without
        // laundering a transient IO blip into permanent corruption.
        guard let data = try? Data(contentsOf: basePath) else {
            throw TaskLedgerBaseUnreadable(path: basePath.path)
        }
        guard let raw = try? JSONValue.parse(data),
              let base = TaskLedgerCompactionBase.fromJSON(raw) else {
            throw TaskLedgerBaseCorrupt(path: basePath.path)
        }
        let tail = SnapshotTailOpLog.dropCompactedPrefix(
            events, lastCompactedOpId: base.lastCompactedOpId, id: { $0.id }
        )
        return TaskLedgerFeed(base: base, events: tail, fileEventCount: fileEventCount, integrity: integrity)
    }

    /// List the derived compacted task states, newest-updated first. Reads the
    /// canonical base + events feed, so a list right after a CLI append reflects it.
    ///
    /// The events flock pairs base and tail atomically so compaction cannot cause double replay.
    /// claim and appendAndRecompactUnlocked already hold the lock.
    /// withFileLock supports same-task-tree reentry without another acquisition.
    public func listTasks(includeTerminal: Bool = true) async throws -> [TaskLedgerTaskState] {
        let feed = try await SwiftNativePersistenceCore.withFileLock(eventsPath) {
            try await readFeedUnlocked().feed
        }
        var states = Self.compact(base: feed.base, feed.events)
        states = states.filter { $0.status != .deleted }
        if !includeTerminal {
            states = states.filter { $0.status != .done && $0.status != .cancelled }
        }
        return states.sorted { $0.updatedTs > $1.updatedTs }
    }

    /// Folded state and raw retained events share one locked read; a stale
    /// pre-compaction prefix remains evidence, never replayed twice into state.
    public func taskDetail(id: String) async throws -> (state: TaskLedgerTaskState?, events: [TaskLedgerEvent]) {
        try await SwiftNativePersistenceCore.withFileLock(eventsPath) {
            let (events, integrity) = try await readEventsWithIntegrityUnlocked()
            let feed = try readFeedUnlocked(events: events, integrity: integrity)
            return (Self.compact(base: feed.base, feed.events).first { $0.taskId == id && $0.status != .deleted },
                    events.filter { $0.taskId == id })
        }
    }

    // MARK: - Compaction

    /// Fold the event stream into per-task derived state. Events are applied in
    /// FILE ORDER (append order); `created` seeds the title/createdTs, `claimed`
    /// sets the owner, every event advances status + updatedTs until deletion,
    /// and refs union in first-seen order. Deletion is final. A task with no
    /// explicit `created` event still materializes (first event seeds it).
    public static func compact(_ events: [TaskLedgerEvent]) -> [TaskLedgerTaskState] {
        compact(base: nil, events)
    }

    /// Fold seeded from a compaction base: the base's task states ARE the reduced
    /// ledger through `lastCompactedOpId`, so the tail events apply on top exactly
    /// as if the compacted prefix had just been replayed. This is what keeps a
    /// compacted task's title/owner alive after a trim.
    static func compact(base: TaskLedgerCompactionBase?, _ events: [TaskLedgerEvent]) -> [TaskLedgerTaskState] {
        var byTask: [String: TaskLedgerTaskState] = [:]
        var order: [String] = []
        if let base {
            for s in base.tasks {
                if byTask[s.taskId] == nil { order.append(s.taskId) }
                byTask[s.taskId] = s
            }
        }
        for e in events {
            if var s = byTask[e.taskId] {
                if s.status == .deleted { continue }
                if let t = e.title, !t.isEmpty { s.title = t }
                if e.kind == .claimed { s.owner = e.actor }
                s.status = e.kind
                s.updatedTs = e.ts
                if let n = e.note, !n.isEmpty { s.lastNote = n }
                for r in e.refs where !s.refs.contains(r) { s.refs.append(r) }
                // Bound the union: refs were the one unbounded field in the
                // derived state — a long-lived task accumulating a ref per
                // event grew the compaction base forever. Newest-wins
                // (suffix), matching every other tail cap
                // in the store.
                if s.refs.count > Self.maxRefsPerTask { s.refs = Array(s.refs.suffix(Self.maxRefsPerTask)) }
                byTask[e.taskId] = s
            } else {
                order.append(e.taskId)
                byTask[e.taskId] = TaskLedgerTaskState(
                    taskId: e.taskId,
                    title: e.title,
                    owner: e.kind == .claimed ? e.actor : nil,
                    status: e.kind,
                    createdTs: e.ts,
                    updatedTs: e.ts,
                    lastNote: e.note,
                    refs: Array(e.refs.suffix(Self.maxRefsPerTask))
                )
            }
        }
        return order.compactMap { byTask[$0] }
    }
}
