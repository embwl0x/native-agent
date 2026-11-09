import AgentWorkspace
import Privacy
import Foundation
import Experiences
import PersistenceCore
// Blueprint: | `AgentConversationLive.swift` | `AgentConversationLive`, `projection` |

/// Progress is display-only, never reply or settlement evidence. Keep partials outside conversations.json: frequent writes there would repeatedly wake the
/// runner and screen. Wake helpers know message IDs, so their keys differ from conversation record IDs.
public struct AgentConversationLive: Codable, Sendable, Equatable {
    public var key: String
    public var recordID: String?
    public var operationID: String?
    public var agent: String
    public var messageID: String?
    public var lane: String
    public var state: String
    /// False means only the working signal is real, not partial text.
    public var streams: Bool
    public var startedAt: Date
    public var lastActivityAt: Date
    public var partial: String?
    public var partialChars: Int
    public var partialTruncated: Bool
    public var note: String?
    public var finishedAt: Date?
    /// The send’s start is not evidence that the other agent began work.
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

    /// Wake helpers know the accepted message ID, not the conversation record.
    public static func message(agent: String, messageID: String, dataRoot: URL) -> Self {
        .init(dataRoot: dataRoot, key: messageKey(agent: agent, messageID: messageID), recordID: nil,
              operationID: nil, agent: agent, messageID: messageID)
    }

    static func messageKey(agent: String, messageID: String) -> String { agent + ":" + messageID.lowercased() }
}

/// Publish accepted progress through one actor-owned writer.
public actor AgentConversationLiveHub {
    public static let shared = AgentConversationLiveHub()
    static let partialLimit = 16 * 1024

    private var entries: [String: (live: AgentConversationLive, root: URL)] = [:]
    private var dirty: Set<String> = []
    private var pendingFlushID: UUID?
    private var publisher: (@Sendable (AgentConversationLive) -> Void)?

    public func setPublisher(_ publisher: @escaping @Sendable (AgentConversationLive) -> Void) {
        self.publisher = publisher
    }

    /// Accepted sends may finish after resident admission closes; their progress stays writable until settlement.
    public func shutdown() {
        flush()
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

    public func text(_ target: AgentConversationLiveTarget, delta: String? = nil, replace: String? = nil) {
        guard replace != nil || !(delta ?? "").isEmpty else { return }
        edit(target, activity: true) { live in
            let whole = replace ?? (live.partial ?? "") + (delta ?? "")
            live.streams = true
            live.state = "working"
            live.partialChars = replace?.count ?? live.partialChars + (delta?.count ?? 0)
            if replace != nil { live.partialTruncated = false }
            // Retain the newest words because only the tail is live progress.
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

    public func activity(_ target: AgentConversationLiveTarget) {
        edit(target, activity: true) { $0.state = "working" }
    }

    public func firstActivity(_ target: AgentConversationLiveTarget) -> Date? {
        entries[target.key]?.live.firstActivityAt
    }

    public func settle(_ target: AgentConversationLiveTarget, state: String, note: String? = nil) {
        edit(target, now: true) { live in
            live.state = state
            if let note { live.note = note }
            if ["finished", "failed"].contains(state) { live.finishedAt = Date() }
        }
    }

    private func edit(_ target: AgentConversationLiveTarget, now: Bool = false, activity: Bool = false,
                      _ change: (inout AgentConversationLive) -> Void) {
        if let entry = entries[target.key], entry.live.operationID != target.operationID { return }
        if entries[target.key] == nil {
            do {
                if let saved = try AgentConversationLiveStore(dataRoot: target.dataRoot).all()[target.key] {
                    guard saved.operationID == target.operationID else { return }
                    entries[target.key] = (saved, target.dataRoot)
                }
            } catch {
                report(error, root: target.dataRoot)
                return
            }
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
        guard pendingFlushID == nil else { return }
        let id = UUID()
        pendingFlushID = id
        Task { flush(ifCurrent: id) }
    }

    private func flush(ifCurrent id: UUID) {
        guard pendingFlushID == id else { return }
        flush()
    }

    private func flush() {
        pendingFlushID = nil
        let keys = dirty
        dirty.removeAll()
        // Redact once for disk and every reader; retain the raw tail only in memory for appends.
        let changed = keys.compactMap { key -> (live: AgentConversationLive, root: URL)? in
            guard var entry = entries[key] else { return nil }
            entry.live.partial = entry.live.partial.map(NativeAgentSecretRedactor.redactText)
            entry.live.note = entry.live.note.map(NativeAgentSecretRedactor.redactText)
            return entry
        }
        for (root, group) in Dictionary(grouping: changed, by: { $0.root }) {
            do {
                let saved = try AgentConversationLiveStore(dataRoot: root).merge(group.map(\.live))
                for entry in group {
                    if let live = saved[entry.live.key] { publisher?(live) }
                    if saved[entry.live.key]?.state == "finished" { entries.removeValue(forKey: entry.live.key) }
                }
            } catch {
                dirty.formUnion(group.map { $0.live.key })
                report(error, root: root)
            }
        }
        // Persist settled entries; memory retains only active progress.
        for key in keys where !dirty.contains(key) && entries[key]?.live.state != "working" { entries.removeValue(forKey: key) }
    }

    private func report(_ error: Error, root: URL) {
        RepairOwed.owe(root, id: UUID().uuidString.lowercased(), kind: .act,
            operation: "agent.conversation.live", owner: root.appendingPathComponent("agents/conversation-live.json").path,
            words: "Live conversation evidence is unavailable: " + error.localizedDescription,
            lever: "Repair agents/conversation-live.json; existing bytes and pending live updates are preserved.")
    }
}

public struct AgentConversationLiveStore: Sendable {
    public let fileURL: URL
    private let dataRoot: URL
    public init(dataRoot: URL) {
        self.dataRoot = dataRoot
        fileURL = dataRoot.appendingPathComponent("agents/conversation-live.json")
    }

    /// Missing storage is empty; a failed or malformed read stays unavailable.
    public func all() throws -> [String: AgentConversationLive] {
        let data: Data
        do { data = try Data(contentsOf: fileURL) }
        catch CocoaError.fileReadNoSuchFile { return [:] }
        guard data.count <= 4 * 1024 * 1024 else {
            throw AgentConversationStore.Failure(
                message: "Live conversation evidence exceeds its 4 MiB bound; repair \(fileURL.path). Existing bytes were preserved.")
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode([String: AgentConversationLive].self, from: data)
    }

    /// Prefer the wake helper’s message-level entry because it observes the send more closely.
    public func current(for row: AgentConversationRecord) throws -> AgentConversationLive? {
        guard ["sending", "waiting"].contains(row.phase) else { return nil }
        return try Self.current(for: row, in: all())
    }

    public static func current(for row: AgentConversationRecord, in rows: [String: AgentConversationLive]) -> AgentConversationLive? {
        guard ["sending", "waiting"].contains(row.phase) else { return nil }
        if case .string(let message)? = row.readInput?["message_id"],
           let live = rows[AgentConversationLiveTarget.messageKey(agent: row.agent, messageID: message)] {
            return live
        }
        guard let live = rows[row.id], live.operationID == row.operationID else { return nil }
        return live
    }

    @discardableResult func merge(_ changed: [AgentConversationLive],
        records checkedRecords: [AgentConversationRecord]? = nil) throws -> [String: AgentConversationLive] {
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        return try CredentialFileLock.withLock(fileURL) {
            var rows = try all()
            let before = rows
            // Reconciliation holds the record lock. Progress flushes read inside the live-file lock so a late write cannot undo settlement.
            let store = AgentConversationStore(dataRoot: dataRoot)
            let records: [AgentConversationRecord]
            if let checkedRecords {
                records = checkedRecords
            } else {
                records = try store.recordsUnlocked()
            }
            for live in changed {
                if let id = live.recordID {
                    guard let row = records.first(where: { $0.id == id }), row.operationID == live.operationID else { continue }
                }
                rows[live.key] = live
            }
            for (key, var live) in Array(rows) {
                let row: AgentConversationRecord?
                if let id = live.recordID {
                    row = records.first { $0.id == id }
                    if row == nil { rows.removeValue(forKey: key); continue }
                } else if let messageID = live.messageID {
                    row = records.first { $0.agent == live.agent && $0.readInput?["message_id"] == .string(messageID) }
                } else { row = nil }
                if let row, (live.operationID != nil && live.operationID != row.operationID)
                    || !["sending", "waiting"].contains(row.phase) {
                    if live.state != "failed" { live.state = "finished" }
                    live.finishedAt = live.finishedAt ?? row.updatedAt
                    rows[key] = live
                }
            }
            let now = Date()
            rows = rows.filter { $0.value.finishedAt.map { now.timeIntervalSince($0) < 24 * 60 * 60 } ?? true }
            if rows.count > 64 {
                let keep = Set(rows.values.filter { $0.finishedAt != nil }
                    .sorted { $0.lastActivityAt > $1.lastActivityAt }.prefix(64).map(\.key))
                rows = rows.filter { $0.value.finishedAt == nil || keep.contains($0.key) }
            }
            if rows != before {
                let encoder = JSONEncoder()
                encoder.dateEncodingStrategy = .iso8601
                try SwiftNativePersistenceCore.writeDataAtomicDurable(encoder.encode(rows), to: fileURL)
            }
            return rows
        }
    }
}

extension AgentConversationLive {
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
            : state == "failed"
            ? note ?? "\(who)'s reply failed."
            : streams
            ? "Partial text so far. The reply is not finished; the final answer replaces it."
            : state == "waiting"
            ? "Sent; \(who) has not shown activity on a live channel since. The answer arrives through the conversation."
            : "\(who) is working. This connection does not stream text; the last activity time is real.")
        return .object(fields)
    }
}
