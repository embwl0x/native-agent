import Foundation
import PersistenceCore
// Blueprint: | `TaskLedger.swift` | `SwiftNativeTaskLedger`: locked history; `PersistenceCore.defaultDataRoot()` or explicit `--data-root` |

// MARK: - Cross-agent task ledger
// Flocked events serialize app and CLI ownership, progress and outcomes.
// Both writers share the PersistenceCore sidecar lock so cross-process appends cannot race.
// Snapshot-plus-tail compaction bounds the feed while preserving founding task state.

// MARK: - Event types

/// Who wrote an event: the agent, the person, or one saved contact named by its peer id.
public struct TaskLedgerActor: Sendable, Hashable {
    public let rawValue: String

    public static let agent = Self(rawValue: "agent")
    public static let user = Self(rawValue: "user")
    public static func contact(_ id: UUID) -> Self { Self(rawValue: "peer:" + id.uuidString.lowercased()) }

    private init(rawValue: String) { self.rawValue = rawValue }

    public init?(wire raw: String) {
        if raw == Self.agent.rawValue { self = .agent; return }
        if raw == Self.user.rawValue { self = .user; return }
        guard raw.hasPrefix("peer:"), let id = UUID(uuidString: String(raw.dropFirst(5))) else { return nil }
        self = .contact(id)
    }
}

public enum TaskLedgerKind: String, Sendable, CaseIterable {
    case created, claimed, update, blocked, done, cancelled, deleted
}

public struct TaskLedgerEvent: Sendable, Equatable {
    public var id: String
    public var taskId: String
    public var ts: String
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

    /// Omit nil or empty optionals so app and CLI writers emit the same wire shape.
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

    /// Reject incomplete history whole so a malformed row cannot become a successful omission.
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
        for key in ["title", "note"] {
            if let value = obj[key] {
                guard case .string = value else { return nil }
            }
        }
        var refs: [String] = []
        if let value = obj["refs"] {
            guard case .array(let arr) = value else { return nil }
            for value in arr {
                guard case .string(let ref) = value else { return nil }
                refs.append(ref)
            }
        }
        let event = TaskLedgerEvent(
            id: id, taskId: taskId, ts: ts, actor: actor, kind: kind,
            title: obj["title"]?.stringValue, note: obj["note"]?.stringValue, refs: refs
        )
        guard event.toJSON() == value else { return nil }
        return event
    }
}

/// Deletion remains final when later events fold into compacted state.
public struct TaskLedgerTaskState: Sendable, Equatable {
    public var taskId: String
    public var title: String?
    public var owner: TaskLedgerActor?
    public var status: TaskLedgerKind
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

    public static func fromJSON(_ value: JSONValue) -> TaskLedgerTaskState? {
        guard case .object(let obj) = value,
              case .string(let taskId)? = obj["taskId"],
              case .string(let statusRaw)? = obj["status"],
              let status = TaskLedgerKind(rawValue: statusRaw),
              case .string(let createdTs)? = obj["createdTs"],
              case .string(let updatedTs)? = obj["updatedTs"] else {
            return nil
        }
        for key in ["title", "lastNote"] {
            if let value = obj[key] {
                guard case .string = value else { return nil }
            }
        }
        var owner: TaskLedgerActor?
        if let value = obj["owner"] {
            guard case .string(let raw) = value, let actor = TaskLedgerActor(wire: raw) else { return nil }
            owner = actor
        }
        var refs: [String] = []
        if let value = obj["refs"] {
            guard case .array(let arr) = value else { return nil }
            for value in arr {
                guard case .string(let ref) = value else { return nil }
                refs.append(ref)
            }
        }
        let state = TaskLedgerTaskState(
            taskId: taskId, title: obj["title"]?.stringValue, owner: owner, status: status,
            createdTs: createdTs, updatedTs: updatedTs, lastNote: obj["lastNote"]?.stringValue, refs: refs
        )
        guard state.toJSON() == value else { return nil }
        return state
    }
}

/// Keep reduced state through the compacted prefix so tail-only replay retains founding events.
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

    /// Reject malformed bases whole because tail-only replay would silently erase compacted tasks.
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
        guard case .int(let rawCount)? = obj["compactedOpCount"], rawCount >= 0,
              let compactedOpCount = Int(exactly: rawCount) else { return nil }
        guard Set(tasks.map(\.taskId)).count == tasks.count else { return nil }
        let base = TaskLedgerCompactionBase(
            tasks: tasks, lastCompactedOpId: lastCompactedOpId,
            compactedAt: compactedAt, compactedOpCount: compactedOpCount
        )
        guard base.toJSON() == value else { return nil }
        return base
    }
}

/// Pair base and following events; count physical rows before prefix-drop so compaction tracks file growth.
struct TaskLedgerFeed: Sendable {
    let base: TaskLedgerCompactionBase?
    var events: [TaskLedgerEvent]
    var fileEventCount: Int
    /// Refuse compaction with undecodable rows because truncation would erase their original evidence.
    var integrity: SnapshotTailOpLog.OpLogIntegrity = .clean

    /// Count undecodable rows too because they still consume feed space.
    var compactionRowCount: Int { integrity.feedRowCount(decodedCount: fileEventCount) }
}

public struct TaskLedgerBaseCorrupt: Error, LocalizedError, Sendable {
    public let path: String
    public var errorDescription: String? {
        """
            task ledger: compaction base at \(path) exists but does not decode — refusing to fold from the tail alone (that would silently drop \
            every compacted task)
            """
    }
}

/// Distinguish unreadable bytes from decoded corruption so transient I/O cannot permanently invalidate the ledger.
public struct TaskLedgerBaseUnreadable: Error, LocalizedError, Sendable {
    public let path: String
    public var errorDescription: String? {
        """
            task ledger: compaction base at \(path) exists but its bytes could not be read (transient IO — fd exhaustion or a dataless file); \
            retry rather than treating the ledger as corrupt
            """
    }
}

/// Preserve unreadable history intact and prevent partial state from authorizing mutations.
public struct TaskLedgerHistoryUnavailable: Error, LocalizedError, Sendable {
    public let path: String
    public let integrity: SnapshotTailOpLog.OpLogIntegrity

    public var errorDescription: String? {
        """
            task ledger history unavailable at \(path): \(integrity.summary). Original bytes retained; repair the named event feed before \
            reading or changing tasks.
            """
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

/// Append, replay and compaction share the events flock so reads cannot straddle committed writes.
/// Local export and phone sync exclude orchestration; off-disk backup retains it.
public struct SwiftNativeTaskLedger: Sendable {
    public static let logLabel = "TaskLedger"
    /// Compact under the append lock so threshold crossing cannot race another writer.
    public static let maxLines = JSONLLineCaps.activityEvents
    static let opsCompactionThreshold = JSONLLineCaps.activityEvents
    /// Keep a quarter-tail so compaction amortizes across the next three-quarter-threshold appends.
    static let compactionKeepTail = max(1, opsCompactionThreshold / 4)
    static let terminalTaskRetention: TimeInterval = 30 * 24 * 60 * 60
    /// Cap refs newest-first so long-lived tasks cannot grow their state and compaction base indefinitely.
    static let maxRefsPerTask = 64

    public let dataRoot: URL
    public init(dataRoot: URL) {
        self.dataRoot = dataRoot
    }

    public var eventsPath: URL {
        dataRoot
            .appendingPathComponent("orchestration", isDirectory: true)
            .appendingPathComponent("task_ledger.jsonl")
    }

    /// Write the base before truncation so prefix-drop repairs crashes between those writes.
    public var basePath: URL {
        dataRoot
            .appendingPathComponent("orchestration", isDirectory: true)
            .appendingPathComponent("task_ledger_base.json")
    }

    @discardableResult
    public func append(_ event: TaskLedgerEvent) async throws -> TaskLedgerEvent {
        try await SwiftNativePersistenceCore.withFileLock(eventsPath) {
            let feed = try await readFeedUnlocked().feed
            let current = Self.compact(base: feed.base, feed.events).first { $0.taskId == event.taskId }
            try await appendAndRecompactUnlocked(event, feed: feed, current: current)
        }
        return event
    }

    /// Compare the observed title and append under one flock so deletion cannot erase renamed work.
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

    /// Claim with locked CAS so active ownership cannot be taken without force.
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
        // The held flock keeps deletion from racing this refusal.
        if current?.status == .deleted {
            throw TaskLedgerTaskDeleted(taskId: event.taskId)
        }
        try await SwiftNativePersistenceCore.appendJSONLDurable(event.toJSON(), to: eventsPath)
        var next = feed
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
        // Terminate torn last lines before appending so malformed bytes remain visible.
        if next.integrity.trailingPartialLine {
            next.integrity.malformedLineCount += 1
            next.integrity.trailingPartialLine = false
        }
        try await compactIfNeededUnlocked(feed: next)
    }

    /// Write the prefix snapshot before rewriting the tail under the flock.
    /// Prefix-drop protects interrupted compaction against loss and duplicate application.
    private func compactIfNeededUnlocked(feed: TaskLedgerFeed) async throws {
        guard feed.compactionRowCount >= Self.opsCompactionThreshold else { return }
        // Refuse compaction if any row cannot be folded, preserving newer writers' event kinds.
        guard SnapshotTailOpLog.mayCompact(feed.integrity, feed: Self.logLabel, path: eventsPath) else { return }
        // Exclude the retained tail from the base so replay cannot apply it twice.
        guard feed.events.count > Self.compactionKeepTail else { return }
        let prefix = Array(feed.events.dropLast(Self.compactionKeepTail))
        let tail = Array(feed.events.suffix(Self.compactionKeepTail))
        guard let lastPrefix = prefix.last else { return }
        // Use the feed clock so identical history compacts identically across machines and times.
        // Unreadable clock evidence cannot authorize eviction.
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

    /// Keep deletion tombstones so tail events cannot resurrect deleted tasks after compaction.
    /// Retain nonterminal tasks and unknown ages; only known-old terminal work may expire.
    static func retainInCompactionBase(_ task: TaskLedgerTaskState, now: Date) -> Bool {
        if task.status == .deleted { return true }
        guard task.status == .done || task.status == .cancelled else { return true }
        guard let updated = DeskClock.parseISO(task.updatedTs) else { return true }
        return now.timeIntervalSince(updated) < terminalTaskRetention
    }

    /// Retain exact integrity diagnostics; functional reads require complete history before replay.
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

    /// Rejected-row counts explain blocked compaction and continued physical feed growth.
    public func feedIntegrity() async throws -> SnapshotTailOpLog.OpLogIntegrity {
        try await readEventsWithIntegrityUnlocked().integrity
    }

    public func feedHealth() async throws -> SnapshotTailOpLog.OpLogHealth {
        let integrity = try await feedIntegrity()
        return SnapshotTailOpLog.OpLogHealth(
            feed: Self.logLabel,
            path: eventsPath,
            physicalRowCount: integrity.physicalRowCount,
            byteCount: try SnapshotTailOpLog.OpLogHealth.fileSize(eventsPath),
            compactionThreshold: Self.opsCompactionThreshold,
            integrity: integrity
        )
    }

    /// Read events before base so compaction cannot pair an old snapshot with a truncated tail.
    /// Prefix-drop prevents duplicate replay; malformed existing bases fail whole and absent bases start at genesis.
    func readFeedUnlocked() async throws -> (feed: TaskLedgerFeed, rawEvents: [TaskLedgerEvent]) {
        let (events, integrity) = try await readEventsWithIntegrityUnlocked()
        return (try readFeedUnlocked(events: events, integrity: integrity), events)
    }

    private func readFeedUnlocked(events: [TaskLedgerEvent], integrity: SnapshotTailOpLog.OpLogIntegrity) throws -> TaskLedgerFeed {
        guard integrity.isClean, !integrity.trailingPartialLine else {
            throw TaskLedgerHistoryUnavailable(path: eventsPath.path, integrity: integrity)
        }
        let fileEventCount = events.count
        guard FileManager.default.fileExists(atPath: basePath.path) else {
            return TaskLedgerFeed(base: nil, events: events, fileEventCount: fileEventCount, integrity: integrity)
        }
        // Distinguish byte-read failure from malformed content so transient I/O cannot become permanent corruption.
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

    /// Pair base and tail under the flock so listing cannot double-replay concurrent compaction.
    /// Same-task-tree reentry lets callers retain their existing acquisition.
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

    /// Read state and retained events together so precompaction evidence cannot replay twice.
    public func taskDetail(id: String) async throws -> (state: TaskLedgerTaskState?, events: [TaskLedgerEvent]) {
        try await SwiftNativePersistenceCore.withFileLock(eventsPath) {
            let (events, integrity) = try await readEventsWithIntegrityUnlocked()
            let feed = try readFeedUnlocked(events: events, integrity: integrity)
            return (Self.compact(base: feed.base, feed.events).first { $0.taskId == id && $0.status != .deleted },
                    events.filter { $0.taskId == id })
        }
    }

    // MARK: - Compaction

    /// Fold in append order; deletion is final, while a first event may found a task without explicit creation.
    public static func compact(_ events: [TaskLedgerEvent]) -> [TaskLedgerTaskState] {
        compact(base: nil, events)
    }

    /// Seed from the base and apply only following events so trimming cannot erase task identity or ownership.
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
                // Cap refs newest-first so long-lived tasks cannot grow the base indefinitely.
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
