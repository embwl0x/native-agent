import AgentWorkspace
import Privacy
import Foundation
import PersistenceCore

/// What the other agent is doing right now on one send: working since when,
/// its last sign of life, the reply text streamed so far and its latest tool
/// or progress note. Display only: never the reply, a receipt, or settlement
/// evidence. The final answer still lands through the lane's own path.
///
/// Keyed by the conversation record id, or `<agent>:<message id>` when a
/// built-in lane's wake helper reports it (it knows only the message id).
/// Kept beside `conversations.json`, not inside it: partials are written a few
/// times a second and the records file wakes the delegation runner and her
/// screen on every write.
public struct AgentConversationLive: Codable, Sendable, Equatable {
    public var key: String
    public var recordID: String?
    public var operationID: String?
    public var agent: String
    public var messageID: String?
    /// acp, a2a, command, desktop, claude, codex, omp, …
    public var lane: String
    /// working (the agent is on it), waiting (handed off, no live channel), finished.
    public var state: String
    /// The lane supplies partial text; false means only the working signal is real.
    public var streams: Bool
    public var startedAt: Date
    public var lastActivityAt: Date
    /// The newest part of the reply being written (tail, bounded).
    public var partial: String?
    public var partialChars: Int
    public var partialTruncated: Bool
    public var note: String?
    public var finishedAt: Date?
    /// The agent's first sign of work (text, a note, activity); the send's own start is not one.
    public var firstActivityAt: Date?
}

public struct AgentConversationLiveTarget: Sendable, Hashable {
    public let dataRoot: URL
    public let key: String
    public let recordID: String?
    public let operationID: String?
    public let agent: String
    public let messageID: String?

    public static func record(_ row: AgentConversationRecord, dataRoot: URL) -> Self {
        .init(dataRoot: dataRoot, key: row.id, recordID: row.id, operationID: row.operationID,
              agent: row.agent, messageID: nil)
    }

    /// A built-in lane's wake helper knows the accepted message id, not the record.
    public static func message(agent: String, messageID: String, dataRoot: URL) -> Self {
        .init(dataRoot: dataRoot, key: messageKey(agent: agent, messageID: messageID), recordID: nil,
              operationID: nil, agent: agent, messageID: messageID)
    }

    static func messageKey(agent: String, messageID: String) -> String { agent + ":" + messageID.lowercased() }
}

public enum AgentConversationLiveContext {
    /// Set around one conversation send so a lane deep in the call can report
    /// progress without learning about records. Lanes that call back from
    /// another task capture it first.
    @TaskLocal public static var target: AgentConversationLiveTarget?
}

/// One shared update stream. Every lane feeds it; partial text is coalesced to
/// at most one write and one published event per `interval`, state changes go
/// out at once.
public actor AgentConversationLiveHub {
    public static let shared = AgentConversationLiveHub()
    static let interval: Duration = .milliseconds(400)
    static let partialLimit = 16 * 1024

    private var entries: [String: (live: AgentConversationLive, root: URL)] = [:]
    private var dirty: Set<String> = []
    private var pendingFlush: Task<Void, Never>?
    private var publisher: (@Sendable (AgentConversationLive) -> Void)?

    public func setPublisher(_ publisher: @escaping @Sendable (AgentConversationLive) -> Void) {
        self.publisher = publisher
    }

    public func begin(_ target: AgentConversationLiveTarget, lane: String, streams: Bool = false,
                      state: String = "working", note: String? = nil) {
        let now = Date()
        entries[target.key] = (AgentConversationLive(key: target.key, recordID: target.recordID,
            operationID: target.operationID, agent: target.agent, messageID: target.messageID, lane: lane,
            state: state, streams: streams, startedAt: now, lastActivityAt: now, partial: nil, partialChars: 0,
            partialTruncated: false, note: note, finishedAt: nil), target.dataRoot)
        schedule(target.key, now: true)
    }

    /// Streamed reply text: `delta` appends, `replace` is the whole text so far.
    public func text(_ target: AgentConversationLiveTarget, delta: String? = nil, replace: String? = nil) {
        guard replace != nil || !(delta ?? "").isEmpty else { return }
        edit(target, activity: true) { live in
            let whole = replace ?? (live.partial ?? "") + (delta ?? "")
            live.streams = true
            live.state = "working"
            live.partialChars = replace?.count ?? live.partialChars + (delta?.count ?? 0)
            if replace != nil { live.partialTruncated = false }
            // Tail only: the newest words are the live part.
            if whole.utf8.count > Self.partialLimit {
                live.partial = String(whole.suffix(Self.partialLimit / 2))
                live.partialTruncated = true
            } else { live.partial = whole }
        }
    }

    public func note(_ target: AgentConversationLiveTarget, _ text: String) {
        let clipped = String(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(300))
        guard !clipped.isEmpty else { return }
        edit(target, activity: true) { $0.state = "working"; $0.note = clipped }
    }

    /// A sign of life with nothing to show (bytes on a pipe, a transcript write).
    public func activity(_ target: AgentConversationLiveTarget) {
        edit(target, activity: true) { $0.state = "working" }
    }

    /// When the agent first showed work on this send, while it is still live here.
    public func firstActivity(_ target: AgentConversationLiveTarget) -> Date? {
        entries[target.key]?.live.firstActivityAt
    }

    /// The send's own call returned: `waiting` when the reply comes later.
    public func settle(_ target: AgentConversationLiveTarget, state: String, note: String? = nil) {
        edit(target, now: true) { live in
            live.state = state
            if let note { live.note = note }
            if state == "finished" { live.finishedAt = Date() }
        }
    }

    private func edit(_ target: AgentConversationLiveTarget, now: Bool = false, activity: Bool = false,
                      _ change: (inout AgentConversationLive) -> Void) {
        if let entry = entries[target.key], entry.live.operationID != target.operationID { return }
        if entries[target.key] == nil,
           let saved = AgentConversationLiveStore(dataRoot: target.dataRoot).all()[target.key] {
            guard saved.operationID == target.operationID else { return }
            entries[target.key] = (saved, target.dataRoot)
        }
        if entries[target.key] == nil { begin(target, lane: target.agent) }
        guard var entry = entries[target.key] else { return }
        change(&entry.live)
        entry.live.lastActivityAt = Date()
        if activity, entry.live.firstActivityAt == nil { entry.live.firstActivityAt = entry.live.lastActivityAt }
        entries[target.key] = entry
        schedule(target.key, now: now)
    }

    private func schedule(_ key: String, now: Bool) {
        dirty.insert(key)
        if now { flush(); return }
        guard pendingFlush == nil else { return }
        pendingFlush = Task { [weak self] in
            // Cancelled means a flush already ran; flushing again here could
            // cancel the one scheduled after it.
            do { try await Task.sleep(for: Self.interval) } catch { return }
            await self?.flush()
        }
    }

    private func flush() {
        pendingFlush?.cancel()
        pendingFlush = nil
        let keys = dirty
        dirty.removeAll()
        // Redacted once here, so the file, agent_read and the event stream all
        // carry the same scrubbed text; memory keeps the raw tail to append to.
        let changed = keys.compactMap { key -> (live: AgentConversationLive, root: URL)? in
            guard var entry = entries[key] else { return nil }
            entry.live.partial = entry.live.partial.map(NativeAgentSecretRedactor.redactText)
            entry.live.note = entry.live.note.map(NativeAgentSecretRedactor.redactText)
            return entry
        }
        for (root, group) in Dictionary(grouping: changed, by: { $0.root }) {
            if let saved = try? AgentConversationLiveStore(dataRoot: root).merge(group.map(\.live)) {
                for entry in group {
                    if let live = saved[entry.live.key] { publisher?(live) }
                    if saved[entry.live.key]?.state == "finished" { entries.removeValue(forKey: entry.live.key) }
                }
            }
        }
        // Settled (finished or handed off to wait) entries live on disk;
        // memory keeps only what is still moving.
        for key in keys where entries[key]?.live.state != "working" { entries.removeValue(forKey: key) }
    }
}

public struct AgentConversationLiveStore: Sendable {
    public let fileURL: URL
    private let dataRoot: URL
    public init(dataRoot: URL) {
        self.dataRoot = dataRoot
        fileURL = dataRoot.appendingPathComponent("agents/conversation-live.json")
    }

    /// Unlocked read for display; a file caught mid-write reads as empty.
    public func all() -> [String: AgentConversationLive] {
        guard let data = try? Data(contentsOf: fileURL), data.count <= 4 * 1024 * 1024 else { return [:] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([String: AgentConversationLive].self, from: data)) ?? [:]
    }

    /// This record's current send, if its agent is still on it. The wake
    /// helper's entry (by message id) is the closer view, so it wins.
    public func current(for row: AgentConversationRecord) -> AgentConversationLive? {
        guard ["sending", "waiting"].contains(row.phase) else { return nil }
        let rows = all()
        if case .string(let message)? = row.readInput?["message_id"],
           let live = rows[AgentConversationLiveTarget.messageKey(agent: row.agent, messageID: message)] {
            return live
        }
        guard let live = rows[row.id], live.operationID == row.operationID else { return nil }
        return live
    }

    @discardableResult func merge(_ changed: [AgentConversationLive]) throws -> [String: AgentConversationLive] {
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        return try CredentialFileLock.withLock(fileURL) {
            var rows = all()
            let before = rows
            // The record owns settlement. Read it inside the live-file lock so
            // a late progress write cannot restore waiting after settlement.
            let records = try AgentConversationStore(dataRoot: dataRoot).recordsUnlocked()
            for live in changed {
                if let id = live.recordID {
                    guard let row = records.first(where: { $0.id == id }), row.operationID == live.operationID else { continue }
                }
                rows[live.key] = live
            }
            for (key, var live) in rows {
                let row: AgentConversationRecord?
                if let id = live.recordID {
                    row = records.first { $0.id == id }
                    if row == nil { rows.removeValue(forKey: key); continue }
                } else if let messageID = live.messageID {
                    row = records.first { $0.agent == live.agent && $0.readInput?["message_id"] == .string(messageID) }
                } else { row = nil }
                if let row, (live.operationID != nil && live.operationID != row.operationID)
                    || !["sending", "waiting"].contains(row.phase) {
                    live.state = "finished"
                    live.finishedAt = live.finishedAt ?? row.updatedAt
                    rows[key] = live
                }
            }
            let now = Date()
            rows = rows.filter { now.timeIntervalSince($0.value.lastActivityAt) < 24 * 60 * 60 }
            if rows.count > 64 {
                let keep = rows.values.sorted { $0.lastActivityAt > $1.lastActivityAt }.prefix(64).map(\.key)
                rows = rows.filter { keep.contains($0.key) }
            }
            if rows != before {
                let encoder = JSONEncoder()
                encoder.dateEncodingStrategy = .iso8601
                try encoder.encode(rows).write(to: fileURL, options: [.atomic])
            }
            return rows
        }
    }
}

extension AgentConversationLive {
    /// The shape `agent_read` and the event stream carry.
    public func projection(name: String? = nil) -> JSONValue {
        let iso = ISO8601DateFormatter()
        var fields: [String: JSONValue] = ["state": .string(state), "lane": .string(lane), "streams": .bool(streams),
            "started_at": .string(iso.string(from: startedAt)), "last_activity_at": .string(iso.string(from: lastActivityAt))]
        if let partial, !partial.isEmpty {
            fields["partial_text"] = .string(partial)
            fields["partial_chars"] = .int(Int64(partialChars))
            if partialTruncated { fields["partial_truncated"] = .bool(true) }
        }
        if let note { fields["note"] = .string(note) }
        if let finishedAt { fields["finished_at"] = .string(iso.string(from: finishedAt)) }
        if let firstActivityAt { fields["first_activity_at"] = .string(iso.string(from: firstActivityAt)) }
        let who = name ?? "The agent"
        fields["detail"] = .string(state == "finished"
            ? "\(who) finished; its answer arrives through the conversation."
            : streams
            ? "Partial text so far. The reply is not finished; the final answer replaces it."
            : state == "waiting"
            ? "Sent; \(who) has not shown activity on a live channel since. The answer arrives through the conversation."
            : "\(who) is working. This connection does not stream text; the last activity time is real.")
        return .object(fields)
    }
}
