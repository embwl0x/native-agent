import Foundation

// MARK: - Cross-agent task ledger (U6 orchestration polish, 2026-06-11)
//
// A shared who-owns-what / done / blocked feed for Claude (CLI), the
// in-app assistant, and Codex (CLI) — replacing fire-and-forget bridge
// messages with durable, append-under-flock state. THREE writers already
// speak "append-under-flock"; no daemon, no server.
//
// MODULE HOME: PersistenceCore. The ledger is pure JSONL + flock IO with NO
// provider / LLM / mission dependencies, so the least-coupled home is the IO
// foundation everything already depends on. PersistenceCore depends only on
// NativeAgentCore; ChatOrchestration and BackgroundLoops (the two Swift
// consumers) already list PersistenceCore as a dependency — so this adds ZERO
// new Package.swift edges and is cycle-safe by construction (a leaf module
// gaining no new imports cannot introduce a cycle).
//
// STORE (matches the build plan, Claude 2026-06-11):
//   • <dataRoot>/orchestration/task_ledger.jsonl — append-only EVENTS feed.
//   • <dataRoot>/orchestration/task_ledger_state.json — derived COMPACTED view.
//   Both under the events-feed flock discipline (withFileLock + the shared
//   `<path>.lock` sidecar). Bound: snapshot+tail compaction (B4) at newest-5000
//   with a threshold/4 keep-tail (audit 2026-07-21 hysteresis).
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
}

public enum TaskLedgerKind: String, Sendable, CaseIterable {
    case created, claimed, update, blocked, done, cancelled
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
        self.ts = ts ?? TaskLedgerClock.nowISO()
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
              let actor = TaskLedgerActor(rawValue: actorRaw),
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
/// folded from its event stream. `status` is the last terminal-ish kind.
public struct TaskLedgerTaskState: Sendable, Equatable {
    public var taskId: String
    public var title: String?
    public var owner: TaskLedgerActor?     // last claimer (nil if never claimed)
    public var status: TaskLedgerKind       // last kind applied
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
        if case .string(let o)? = obj["owner"] { owner = TaskLedgerActor(rawValue: o) }
        var lastNote: String?
        if case .string(let n)? = obj["lastNote"] { lastNote = n }
        var refs: [String] = []
        if case .array(let arr)? = obj["refs"] {
            refs = arr.compactMap { if case .string(let s) = $0 { return s } else { return nil } }
        }
        return TaskLedgerTaskState(
            taskId: taskId, title: title, owner: owner, status: status,
            createdTs: createdTs, updatedTs: updatedTs, lastNote: lastNote, refs: refs
        )
    }
}

/// The op-log's compaction snapshot (B4, 2026-07-17). `tasks` is the FULL
/// reduced ledger through `lastCompactedOpId`, in first-seen order. Replay seeds
/// from it and folds only the events that FOLLOW `lastCompactedOpId`. ADDITIVE
/// on disk: it lives in a NEW file beside the feed, so an old feed with no base
/// loads as pure genesis (`base: nil`). Folding pre-cap events into this base
/// BEFORE any trim is what stops a quiet task's founding events (title/owner)
/// from scrolling off the cap and vanishing — the naive newest-N cap could.
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
        var compactedOpCount = 0
        if case .int(let c)? = obj["compactedOpCount"] { compactedOpCount = Int(c) }
        return TaskLedgerCompactionBase(
            tasks: tasks, lastCompactedOpId: lastCompactedOpId,
            compactedAt: compactedAt, compactedOpCount: compactedOpCount
        )
    }
}

/// One consistent read of the replayable feed: the compaction base (if any) and
/// the tail events that FOLLOW it, plus the raw file event count (the trim
/// threshold keys on actual file size, pre prefix-drop).
struct TaskLedgerFeed: Sendable {
    let base: TaskLedgerCompactionBase?
    var events: [TaskLedgerEvent]
    var fileEventCount: Int
}

public struct TaskLedgerBaseCorrupt: Error, LocalizedError, Sendable {
    public let path: String
    public var errorDescription: String? {
        "task ledger: compaction base at \(path) exists but does not decode — refusing to fold from the tail alone (that would silently drop every compacted task)"
    }
}

public enum TaskLedgerClock {
    /// ISO-8601 UTC, microsecond precision — matches AgentSwarmClock.nowISO so
    /// timestamps sort lexicographically and align with the rest of the
    /// Swift-native event feeds.
    public static func nowISO(_ date: Date = Date()) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSSSSS'+00:00'"
        return f.string(from: date)
    }

    /// Parse an ISO-8601 timestamp produced by `nowISO` (or the Python CLI's
    /// `datetime.now(timezone.utc).isoformat()`) back to a Date. Tolerant of
    /// both the microsecond `+00:00` form and a bare-seconds fallback.
    public static func parseISO(_ s: String) -> Date? {
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = withFraction.date(from: s) { return d }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: s)
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

// MARK: - Reader / writer

/// Append-under-flock task-ledger store. Stateless — all state lives on disk.
/// The events feed and the derived state file share the events feed's flock,
/// so a state recompaction can never race an append.
public struct SwiftNativeTaskLedger: Sendable {
    public static let logLabel = "TaskLedger"
    /// The feed never exceeds this many lines: crossing it triggers the
    /// snapshot+truncate compaction (B4) that folds the overflow into the
    /// base, never dropping it — a quiet task's founding events survive.
    public static let maxLines = JSONLLineCaps.activityEvents
    /// File event count that triggers a snapshot+truncate on the next in-lock
    /// append.
    static let opsCompactionThreshold = JSONLLineCaps.activityEvents
    /// Newest events retained in the feed after a compaction; everything
    /// before the tail folds into the base. Mirrors the GitHubCommandStore
    /// hysteresis (audit 2026-07-21): keep-tail = threshold/4 of slack so a
    /// steady-state append past the first compaction does NOT rewrite the
    /// base + full feed under the flock on EVERY append — compaction now
    /// amortizes over the next 3/4 · threshold appends.
    static let compactionKeepTail = max(1, opsCompactionThreshold / 4)
    /// Terminal tasks (`done`/`cancelled`) whose last update is older than
    /// this are evicted from the compaction base at fold time (audit
    /// 2026-07-21, mirrors DeskStore's live-handle pruning). Without eviction
    /// the base — and the derived task_ledger_state.json — kept every taskId
    /// ever written.
    static let terminalTaskRetention: TimeInterval = 30 * 24 * 60 * 60
    /// Per-task cap on the derived `refs` union. Without it a long-lived task
    /// that attaches a ref per event grows the derived state — and the
    /// compaction base it is baked into — without bound. Newest-wins.
    static let maxRefsPerTask = 64

    public let dataRoot: URL
    public let persistence: SwiftNativePersistenceCore
    /// Injectable trim knobs so tests can drive compaction without writing 5000
    /// events. `compactionThreshold` defaults to `opsCompactionThreshold` and
    /// `keepTail` to `compactionKeepTail` (threshold/4 hysteresis).
    let compactionThreshold: Int
    let keepTail: Int

    public init(dataRoot: URL, persistence: SwiftNativePersistenceCore = SwiftNativePersistenceCore()) {
        self.dataRoot = dataRoot
        self.persistence = persistence
        self.compactionThreshold = Self.opsCompactionThreshold
        self.keepTail = Self.compactionKeepTail
    }

    /// Test-only initializer that scales the compaction trim down so a handful
    /// of events exercise the snapshot+tail path. `keepTail` is clamped to at
    /// least 1 (an empty tail would lose the newest event).
    init(dataRoot: URL, persistence: SwiftNativePersistenceCore = SwiftNativePersistenceCore(), compactionThreshold: Int, keepTail: Int) {
        self.dataRoot = dataRoot
        self.persistence = persistence
        self.compactionThreshold = max(2, compactionThreshold)
        self.keepTail = max(1, keepTail)
    }

    /// `<dataRoot>/orchestration/task_ledger.jsonl`.
    public var eventsPath: URL {
        dataRoot
            .appendingPathComponent("orchestration", isDirectory: true)
            .appendingPathComponent("task_ledger.jsonl")
    }

    /// `<dataRoot>/orchestration/task_ledger_state.json`.
    public var statePath: URL {
        dataRoot
            .appendingPathComponent("orchestration", isDirectory: true)
            .appendingPathComponent("task_ledger_state.json")
    }

    /// `<dataRoot>/orchestration/task_ledger_base.json` — the compaction snapshot
    /// the feed folds FROM (B4). Written atomically BEFORE the feed truncate; a
    /// crash between the two is healed by the replay prefix-drop.
    public var basePath: URL {
        dataRoot
            .appendingPathComponent("orchestration", isDirectory: true)
            .appendingPathComponent("task_ledger_base.json")
    }

    /// Append one event under the events-feed flock, cap to newest-5000, then
    /// recompact the derived state file IN THE SAME LOCK (so the state view
    /// never lags a committed append and a concurrent recompaction can't race).
    @discardableResult
    public func append(_ event: TaskLedgerEvent) async throws -> TaskLedgerEvent {
        try await persistence.withFileLock(eventsPath) {
            try await appendAndRecompactUnlocked(event)
        }
        return event
    }

    /// Claim a task with an in-lock compare-and-set guard. Without `force`,
    /// another actor's active `claimed` / `update` state refuses the takeover.
    @discardableResult
    public func claim(_ event: TaskLedgerEvent, force: Bool = false) async throws -> TaskLedgerEvent {
        guard event.kind == .claimed else {
            throw TaskLedgerInvalidClaimEvent(kind: event.kind)
        }
        try await persistence.withFileLock(eventsPath) {
            if !force {
                // Fold base + tail so a claim CAS still sees an owner whose
                // founding events were compacted into the base.
                let feed = try await readFeedUnlocked()
                let current = Self.compact(base: feed.base, feed.events)
                if let task = current.first(where: { $0.taskId == event.taskId }),
                   let owner = task.owner,
                   owner != event.actor,
                   task.status == .claimed || task.status == .update {
                    throw TaskLedgerClaimConflict(
                        taskId: event.taskId,
                        owner: owner,
                        status: task.status
                    )
                }
            }
            try await appendAndRecompactUnlocked(event)
        }
        return event
    }

    private func appendAndRecompactUnlocked(_ event: TaskLedgerEvent) async throws {
        // Append UNCAPPED — snapshot+tail compaction (B4) replaces the old naive
        // newest-N line cap, which dropped a quiet task's founding events
        // outright. The caller already holds the flock.
        try await persistence.appendJSONL(event.toJSON(), to: eventsPath)
        // Recompact derived state from base + tail (folds compacted tasks too).
        let feed = try await readFeedUnlocked()
        let state = Self.compact(base: feed.base, feed.events)
        try await persistence.writeJSON(Self.stateJSON(state), to: statePath)
        // End-of-transaction snapshot+truncate once the feed file crosses the
        // threshold: fold the pre-tail prefix into the base, keep the newest tail.
        try await compactIfNeededUnlocked(feed: feed)
    }

    /// Snapshot the pre-tail prefix into the base and truncate the feed to the
    /// newest `keepTail` events, once the raw file crosses `compactionThreshold`.
    /// The base is written atomically BEFORE the feed rewrite; the replay
    /// prefix-drop makes the in-between crash window safe (never lost, never
    /// double-applied). The caller holds the events flock.
    private func compactIfNeededUnlocked(feed: TaskLedgerFeed) async throws {
        guard feed.fileEventCount >= compactionThreshold else { return }
        // `feed.events` is already base+tail (prefix-dropped). Fold everything
        // EXCEPT the kept tail into the (existing) base.
        guard feed.events.count > keepTail else { return }
        let prefix = Array(feed.events.dropLast(keepTail))
        let tail = Array(feed.events.suffix(keepTail))
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
        let feedNow = feed.events.compactMap { TaskLedgerClock.parseISO($0.ts) }.max()
        let baseTasks = feedNow.map { now in
            folded.filter { Self.retainInCompactionBase($0, now: now) }
        } ?? folded
        let newBase = TaskLedgerCompactionBase(
            tasks: baseTasks,
            lastCompactedOpId: lastPrefix.id,
            compactedAt: TaskLedgerClock.nowISO(),
            compactedOpCount: feed.fileEventCount
        )
        try await SnapshotTailOpLog.commitCompaction(
            baseJSON: newBase.toJSON(),
            tailRows: tail.map { $0.toJSON() },
            basePath: basePath, opsPath: eventsPath, persistence: persistence
        )
    }

    /// Retention predicate for the compaction-base fold (audit 2026-07-21):
    /// terminal tasks past `terminalTaskRetention` are retired from the base
    /// (their events are already fully folded; nothing live references them).
    /// Non-terminal tasks always retain, and an unparseable stamp fails toward
    /// KEEPING the task — eviction must never lose a live or unreadable row.
    static func retainInCompactionBase(_ task: TaskLedgerTaskState, now: Date) -> Bool {
        guard task.status == .done || task.status == .cancelled else { return true }
        guard let updated = TaskLedgerClock.parseISO(task.updatedTs) else { return true }
        return now.timeIntervalSince(updated) < terminalTaskRetention
    }

    /// Read all events in the FILE (no lock, no base). Post-compaction this is
    /// only the tail (the newest `keepTail`, plus a stale prefix in the crash
    /// window) — identical to the window the old newest-N cap left behind, so
    /// callers reading raw events see the same recent slice they always did.
    /// Use `readFeedUnlocked` / `listTasks` for the base-folded authoritative view.
    public func readEventsUnlocked() async throws -> [TaskLedgerEvent] {
        let raw = try await persistence.readJSONL(eventsPath)
        return raw.compactMap { TaskLedgerEvent.fromJSON($0) }
    }

    /// Read the replayable feed: the compaction base (if any) + the events that
    /// FOLLOW it. Events are read FIRST, base SECOND — a reader racing a
    /// compaction then sees (old/absent base, full ops), (new base, full ops →
    /// prefix-dropped), or (new base, truncated ops); the prefix-drop also heals
    /// a crash between base write and feed truncate. A base file that EXISTS but
    /// does not decode throws (folding the tail alone would blank compacted
    /// tasks). No base file → genesis: the whole feed folds from empty.
    func readFeedUnlocked() async throws -> TaskLedgerFeed {
        let events = try await readEventsUnlocked()
        let fileEventCount = events.count
        guard FileManager.default.fileExists(atPath: basePath.path) else {
            return TaskLedgerFeed(base: nil, events: events, fileEventCount: fileEventCount)
        }
        // Read the base bytes DIRECTLY — `persistence.readJSON` collapses every
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
        return TaskLedgerFeed(base: base, events: tail, fileEventCount: fileEventCount)
    }

    /// List the derived compacted task states, newest-updated first. Reads the
    /// events feed directly (always current) rather than the cached state file,
    /// so a list right after a CLI append reflects it without a recompaction.
    ///
    /// UNDER THE EVENTS FLOCK (2026-08-01). `readFeedUnlocked` reads events
    /// FIRST and the base SECOND, and unlike GitHubCommandStore the ledger's
    /// base carries no `tailFirstOpId` torn-read proof — so a lock-free reader
    /// that suspends at the `await` before the base read can pair a
    /// PRE-compaction events snapshot with a POST-compaction base. That feed
    /// still holds e1..eN, the new base already folded them, and
    /// `dropCompactedPrefix` finds no `lastCompactedOpId` in the old snapshot →
    /// returns the events UNCHANGED → the fold double-applies them on top of a
    /// base that already contains them. A `done` task reappears as `claimed`,
    /// and `staleClaims` then fires on a closed task. The flock makes the two
    /// reads one atomic pairing. `staleClaims` funnels through here rather than
    /// taking the lock itself — `withFileLock` is NOT reentrant (a fresh fd
    /// spins EWOULDBLOCK against our own held lock), so nesting would deadlock.
    /// For the same reason `claim` / `appendAndRecompactUnlocked` call
    /// `readFeedUnlocked` directly: they already hold this lock.
    public func listTasks(includeTerminal: Bool = true) async throws -> [TaskLedgerTaskState] {
        let feed = try await persistence.withFileLock(eventsPath) {
            try await readFeedUnlocked()
        }
        var states = Self.compact(base: feed.base, feed.events)
        if !includeTerminal {
            states = states.filter { $0.status != .done && $0.status != .cancelled }
        }
        return states.sorted { $0.updatedTs > $1.updatedTs }
    }

    /// Tasks with an active CLAIM older than `staleAfter` and no update since.
    /// "Active claim" = current status is `claimed` (a later update/done/etc.
    /// clears the stale signal). Returns newest-claimed first. Reads through
    /// `listTasks`, which takes the events flock — do NOT add a second
    /// `withFileLock` here; it is not reentrant and would deadlock.
    public func staleClaims(
        staleAfter: TimeInterval = 24 * 60 * 60,
        now: Date = Date()
    ) async throws -> [TaskLedgerTaskState] {
        let tasks = try await listTasks(includeTerminal: false)
        return tasks.filter { task in
            guard task.status == .claimed, task.owner != nil else { return false }
            guard let updated = TaskLedgerClock.parseISO(task.updatedTs) else { return false }
            return now.timeIntervalSince(updated) >= staleAfter
        }
    }

    // MARK: - Compaction

    /// Fold the event stream into per-task derived state. Events are applied in
    /// FILE ORDER (append order); `created` seeds the title/createdTs, `claimed`
    /// sets the owner, every event advances status + updatedTs, and refs union
    /// in first-seen order. A task with no explicit `created` event still
    /// materializes (first event seeds it) — honest about whatever the feed has.
    public static func compact(_ events: [TaskLedgerEvent]) -> [TaskLedgerTaskState] {
        compact(base: nil, events)
    }

    /// Fold seeded from a compaction base: the base's task states ARE the reduced
    /// ledger through `lastCompactedOpId`, so the tail events apply on top exactly
    /// as if the compacted prefix had just been replayed. This is what keeps a
    /// compacted task's title/owner alive after a trim (B4).
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
                if let t = e.title, !t.isEmpty { s.title = t }
                if e.kind == .claimed { s.owner = e.actor }
                s.status = e.kind
                s.updatedTs = e.ts
                if let n = e.note, !n.isEmpty { s.lastNote = n }
                for r in e.refs where !s.refs.contains(r) { s.refs.append(r) }
                // Bound the union: refs were the one unbounded field in the
                // derived state — a long-lived task accumulating a ref per
                // event grew task_ledger_state.json AND the compaction base
                // forever. Newest-wins (suffix), matching every other tail cap
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

    /// Wrap the compacted states in the on-disk state-file envelope.
    static func stateJSON(_ states: [TaskLedgerTaskState]) -> JSONValue {
        .object([
            "version": .int(1),
            "generatedTs": .string(TaskLedgerClock.nowISO()),
            "tasks": .array(states.map { $0.toJSON() }),
        ])
    }
}
