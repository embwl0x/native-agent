import Foundation
import NativeAgentShared
import CryptoKit
import NativeAgentCore
import PersistenceCore
import os
// Blueprint: | `ChatSessionRetention.swift` | Archive eligibility and protected conversations; manual/retention archive settlement and durable append before hot-row removal; index to transcript to archive lock order, exact acknowledged-version guard and retained chat storage |

public struct ChatSessionRetentionPolicy: Sendable, Equatable {
    public var maxActiveSessions: Int
    public var staleEmptySessionAgeSeconds: TimeInterval
    public var protectedSessionIds: Set<String>
    public var includeMacPinnedSessions: Bool

    public init(
        maxActiveSessions: Int = 200,
        staleEmptySessionAgeSeconds: TimeInterval = 24 * 60 * 60,
        protectedSessionIds: Set<String> = [],
        includeMacPinnedSessions: Bool = true
    ) {
        self.maxActiveSessions = maxActiveSessions
        self.staleEmptySessionAgeSeconds = staleEmptySessionAgeSeconds
        self.protectedSessionIds = protectedSessionIds
        self.includeMacPinnedSessions = includeMacPinnedSessions
    }

    public static let `default` = ChatSessionRetentionPolicy()
}

public struct ChatSessionRetentionReport: Sendable, Equatable {
    public var keptSessions: Int
    public var archivedSessions: Int
    public var archivedForCap: Int
    public var archivedEmptySessions: Int

    public init(
        keptSessions: Int = 0,
        archivedSessions: Int = 0,
        archivedForCap: Int = 0,
        archivedEmptySessions: Int = 0
    ) {
        self.keptSessions = keptSessions
        self.archivedSessions = archivedSessions
        self.archivedForCap = archivedForCap
        self.archivedEmptySessions = archivedEmptySessions
    }
}

/// Bounds the hot index without deleting history; `enforce` uses the caller's locked rows.
/// Manual archive owns its locks. Rows append to `chat/archive/sessions.jsonl`;
/// transcripts move from `chat/messages/` to `chat/archive/messages/`.
/// Lock sessions index, transcript, then archive index; writers release the transcript
/// lock before index sync. Contended transcripts stay hot for a later pass.
/// Archive history belongs to local/off-disk backups and PrivacyMap/chat;
/// data export and phone sync exclude raw archive files.
public enum ChatSessionRetention {
    public static let diskStorageOwner = DiskStorageOwner.retained(id: "chat", roots: ["chat"],
        policy: "Transcripts, archives and compaction backups are memory; Clean Up keeps them. The history search index belongs to chat and is kept because launch rebuilds it. chat.archive organizes conversations without reclaiming transcript bytes. No history erasure control is provided by this cleanup.")

    // Archived transcripts and their locator rows are durable history. Only
    // explicit deletion may remove them; the active index remains bounded.
    public nonisolated static func defaultBestEffortFailureLogger(_ message: String) {
        nativeLog("%@", message)
    }

    public static func enforce(
        dataRoot: URL,
        rows: [[String: JSONValue]],
        now: Date = Date(),
        policy: ChatSessionRetentionPolicy = .default
    ) throws -> (rows: [[String: JSONValue]], report: ChatSessionRetentionReport) {
        let sessionsPath = dataRoot
            .appendingPathComponent("chat", isDirectory: true)
            .appendingPathComponent("sessions.json")
        // Pruning and enforcement share the caller's locked index snapshot.
        if FileManager.default.fileExists(atPath: sessionsPath.path) { pruneArchive(dataRoot: dataRoot, now: now, rows: rows) }
        guard !rows.isEmpty else {
            return (rows, ChatSessionRetentionReport())
        }

        let protectedSessionIds = try resolvedProtectedSessionIds(policy, dataRoot: dataRoot)
        let reasons = plannedArchiveReasons(
            rows: rows,
            now: now,
            policy: policy,
            protectedSessionIds: protectedSessionIds
        )
        guard !reasons.isEmpty else {
            return (rows, ChatSessionRetentionReport(keptSessions: rows.count))
        }

        var kept: [[String: JSONValue]] = []
        kept.reserveCapacity(rows.count - reasons.count)
        var indexedRows = rows
        // The caller holds the sessions lock. Checkpoint each removal while
        // archive still holds the transcript lock, before deleting hot history.
        var report = ChatSessionRetentionReport()
        var staleEmptyAborts = 0
        for (index, row) in rows.enumerated() {
            guard let reason = reasons[index] else {
                kept.append(row)
                continue
            }
            if try archive(row: row, reason: reason, dataRoot: dataRoot, now: now,
                           commitIndexRemoval: { try ChatSessionIndexFile.removeArchivedRow(row, from: &indexedRows, at: sessionsPath) }) {
                report.archivedSessions += 1
                switch reason {
                case .activeCap:
                    report.archivedForCap += 1
                case .staleEmpty:
                    report.archivedEmptySessions += 1
                }
            } else {
                if reason == .staleEmpty { staleEmptyAborts += 1 }
                kept.append(row)
            }
        }

        // Aborted stale-empty archives rejoin active-cap planning as nonempty
        // sessions. The bounded second pass executes only active-cap removals.
        if staleEmptyAborts > 0 {
            let secondReasons = plannedArchiveReasons(
                rows: kept,
                now: now,
                policy: policy,
                protectedSessionIds: protectedSessionIds
            )
            for (index, row) in kept.enumerated() where secondReasons[index] == .activeCap {
                if try archive(row: row, reason: .activeCap, dataRoot: dataRoot, now: now,
                               commitIndexRemoval: { try ChatSessionIndexFile.removeArchivedRow(row, from: &indexedRows, at: sessionsPath) }) {
                    report.archivedSessions += 1
                    report.archivedForCap += 1
                }
            }
        }

        report.keptSessions = indexedRows.count
        return (indexedRows, report)
    }

    /// Best-effort enforcement for callers whose success path must continue even
    /// if retention is temporarily unavailable. Failures are logged, never
    /// silently swallowed.
    @discardableResult
    public static func enforceBestEffort(
        dataRoot: URL,
        rows: [[String: JSONValue]],
        now: Date = Date(),
        policy: ChatSessionRetentionPolicy = .default,
        context: String,
        failureLogger: @escaping @Sendable (String) -> Void = defaultBestEffortFailureLogger
    ) -> (rows: [[String: JSONValue]], report: ChatSessionRetentionReport)? {
        do {
            return try enforce(dataRoot: dataRoot, rows: rows, now: now, policy: policy)
        } catch {
            failureLogger(
                "\(context): ChatSessionRetention.enforce failed at \(dataRoot.path): \(error)"
            )
            return nil
        }
    }

    /// Manual archive keeps the transcript in place and commits its row to the
    /// archive before removing it from the hot index. Both archive writers use
    /// the same checked schema and durable append under the archive lock.
    public static func archiveSession(id: String, dataRoot: URL) async throws -> [String: JSONValue]? {
        guard NativeAgentChatSessionID.normalizedPathComponent(id) != nil else { return nil }
        let index = dataRoot.appendingPathComponent("chat/sessions.json")
        let archive = dataRoot.appendingPathComponent("chat/archive/sessions.jsonl")
        return try await SwiftNativePersistenceCore.withFileLock(index) {
            var rows = try ChatSessionIndexFile.loadObjectRowsForMutation(at: index)
            guard let position = rows.firstIndex(where: { $0["id"] == .string(id) }) else { return nil }
            var archived = rows[position]
            archived["archived"] = .bool(true)
            archived["archivedBy"] = .string("mac_chat")
            archived["archivedAt"] = .string(ISO8601DateFormatter().string(from: Date()))
            let row = archived
            try await SwiftNativePersistenceCore.withFileLock(archive) {
                var latest = try archiveIndexRows(dataRoot: dataRoot).last { $0["id"] == .string(id) }
                // Ignore only this operation's timestamp when recognizing a retry.
                latest?["archivedAt"] = row["archivedAt"]
                if latest != row { try appendJSONL(.object(row), to: archive) }
            }
            // The archived claim survives an index failure, so a retry only
            // removes the hot row rather than appending another archive record.
            rows.remove(at: position)
            try ChatSessionIndexFile.write(rows, to: index, removeWhenEmpty: true)
            return archived
        }
    }

    private enum ArchiveReason: String {
        case activeCap = "active_cap"
        case staleEmpty = "stale_empty"
    }

    private static func plannedArchiveReasons(
        rows: [[String: JSONValue]],
        now: Date,
        policy: ChatSessionRetentionPolicy,
        protectedSessionIds: Set<String>
    ) -> [Int: ArchiveReason] {
        var reasons: [Int: ArchiveReason] = [:]

        if policy.staleEmptySessionAgeSeconds > 0 {
            for (index, row) in rows.enumerated()
            where !isProtected(row, protectedSessionIds: protectedSessionIds)
                && isStaleEmpty(row, now: now, policy: policy) {
                reasons[index] = .staleEmpty
            }
        }

        let maxActive = max(1, policy.maxActiveSessions)
        let activeIndices = rows.indices.filter {
            reasons[$0] == nil && !isProtected(rows[$0], protectedSessionIds: protectedSessionIds)
        }
        if activeIndices.count > maxActive {
            let overflow = activeIndices.count - maxActive
            for index in activeIndices.suffix(overflow) where reasons[index] == nil {
                reasons[index] = .activeCap
            }
        }

        return reasons
    }

    private static func resolvedProtectedSessionIds(
        _ policy: ChatSessionRetentionPolicy,
        dataRoot: URL
    ) throws -> Set<String> {
        var protected = policy.protectedSessionIds
        if policy.includeMacPinnedSessions {
            protected.formUnion(try macPinnedChatSessionIds(dataRoot: dataRoot))
        }
        // The live anchor stays protected independently of pins on every surface.
        // Its publisher shares this caller's sessions lock, so the read is atomic.
        protected.formUnion(ConversationAnchor.protectedSessionIds(dataRoot: dataRoot))
        // A session a door (Telegram chat, Slack channel/thread) is bound to is
        // where that door's next message lands; archiving it would restart
        // that door with an empty conversation.
        protected.formUnion(try doorMappedSessionIds(dataRoot: dataRoot))
        // A contact's conversations (a saved contact's, a built-in lane's) are
        // what its pane reads; archiving one would blank that pane.
        protected.formUnion(try contactSessionIds(dataRoot: dataRoot))
        return protected
    }

    /// Every session a contact owns starts with this: its id, hashed.
    public static func contactSessionPrefix(owner: String) -> String {
        let digest = SHA256.hash(data: Data(owner.utf8))
        return "agent-" + digest.map { String(format: "%02x", $0) }.joined().prefix(12) + "-"
    }

    private static func contactSessionIds(dataRoot: URL) throws -> Set<String> {
        var owners = ["codex", "claude", "omp"]
        let path = dataRoot.appendingPathComponent("agents/peers.json")
        do {
            // Unknown protection stops retention, as with pins above.
            guard case .array(let peers) = try JSONValue.parse(Data(contentsOf: path)) else {
                throw PersistenceCoreError.ioFailure("I couldn’t read your agent contacts. I’ve left your conversations in place.")
            }
            for case .object(let peer) in peers { if case .string(let id)? = peer["id"] { owners.append(id) } }
        } catch CocoaError.fileReadNoSuchFile {}
        // Each contact's one conversation (ContactThread.session), not every
        // session it opened: a peer starting a context per task stays bounded.
        return Set(owners.map { contactSessionPrefix(owner: $0) + "mcp-" + $0 })
    }

    private static func doorMappedSessionIds(dataRoot: URL) throws -> Set<String> {
        var ids = Set<String>()
        for (door, key) in [("telegram", "chats"), ("slack", "sessions")] {
            let path = dataRoot
                .appendingPathComponent(door, isDirectory: true)
                .appendingPathComponent("session_map.json")
            let data: Data
            do { data = try Data(contentsOf: path) }
            catch CocoaError.fileReadNoSuchFile { continue }
            // Unknown protection stops retention, as with pins above.
            guard case .object(let root) = try JSONValue.parse(data),
                  case .object(let entries)? = root[key] else {
                throw PersistenceCoreError.ioFailure("I couldn’t read the \(door) conversation map. I’ve left your conversations in place.")
            }
            for case .object(let entry) in entries.values {
                if case .string(let id)? = entry["activeSessionId"] {
                    ids.insert(id.trimmingCharacters(in: .whitespacesAndNewlines))
                }
            }
        }
        return ids
    }

    private static func isProtected(
        _ row: [String: JSONValue],
        protectedSessionIds: Set<String>
    ) -> Bool {
        guard case .string(let id)? = row["id"] else { return false }
        return protectedSessionIds.contains(id)
    }

    private static func archive(
        row: [String: JSONValue],
        reason: ArchiveReason,
        dataRoot: URL,
        now: Date,
        commitIndexRemoval: () throws -> Void
    ) throws -> Bool {
        guard case .string(let sessionId)? = row["id"],
              let safeSessionId = NativeAgentChatSessionID.normalizedPathComponent(sessionId) else {
            return false
        }

        let messagesPath = dataRoot
            .appendingPathComponent("chat", isDirectory: true)
            .appendingPathComponent("messages", isDirectory: true)
            .appendingPathComponent("\(safeSessionId).jsonl")
        let archiveIndex = dataRoot
            .appendingPathComponent("chat", isDirectory: true)
            .appendingPathComponent("archive", isDirectory: true)
            .appendingPathComponent("sessions.jsonl")
        var baseArchivedRow = row
        baseArchivedRow["archived"] = .bool(true)
        baseArchivedRow["archivedBy"] = .string("chat_session_retention")
        baseArchivedRow["retentionArchivedAt"] = .string(NativeTimestampFormat.fractionalZulu(now))
        baseArchivedRow["retentionReason"] = .string(reason.rawValue)

        let archived = try CredentialFileLock.tryWithLock(messagesPath) { () throws -> Bool in
            if reason == .activeCap, ChatSessionIndexFile.hasPendingTranscriptIndexSync(at: messagesPath) {
                return false
            }
            // Recheck emptiness under the transcript lock before archiving a stale-empty session.
            if reason == .staleEmpty, transcriptIsNonEmpty(messagesPath) {
                return false
            }
            // Archive only the transcript version acknowledged by the session index.
            if reason == .activeCap, transcriptModifiedDate(messagesPath) != nil {
                // A pending writer changes the exact transcript version before
                // synchronizing the index. Legacy rows stay hot until bounded
                // reconciliation acknowledges their bytes.
                guard let version = ChatSessionIndexFile.transcriptVersion(at: messagesPath),
                      row[ChatSessionIndexFile.acknowledgedTranscriptKey] == version else {
                    return false
                }
            }
            // Check existence only after locking: a writer may be creating the
            // first row while retention is selecting this session.
            var archivedMessagesPath: URL?
            if FileManager.default.fileExists(atPath: messagesPath.path) {
                let archiveDir = dataRoot
                    .appendingPathComponent("chat", isDirectory: true)
                    .appendingPathComponent("archive", isDirectory: true)
                    .appendingPathComponent("messages", isDirectory: true)
                try FileManager.default.createDirectory(at: archiveDir, withIntermediateDirectories: true)
                let destination = try uniqueArchivePath(
                    directory: archiveDir,
                    safeSessionId: safeSessionId,
                    now: now
                )
                try ContactThread.replace(Data(contentsOf: messagesPath), to: destination)
                archivedMessagesPath = destination
            }

            var archivedRow = baseArchivedRow
            if let archivedMessagesPath {
                archivedRow["messagesArchivePath"] = .string(relativePath(archivedMessagesPath, under: dataRoot))
            }
            // Lock archive after transcript. On contention, discard the copy and
            // keep the session hot; no removal may precede its durable archive row.
            let indexRowWritten = try CredentialFileLock.tryWithLock(archiveIndex) {
                try appendJSONL(.object(archivedRow), to: archiveIndex)
                return true
            }
            guard indexRowWritten == true else {
                if let archivedMessagesPath {
                    try? FileManager.default.removeItem(at: archivedMessagesPath)
                }
                return false
            }

            // Both archive bytes and its row exist before the active row goes.
            // If interrupted after this checkpoint, the hot copy may survive
            // and be recovered as an orphan; an active row never loses history.
            try commitIndexRemoval()
            if archivedMessagesPath != nil {
                try FileManager.default.removeItem(at: messagesPath)
            }
            return true
        }
        return archived ?? false
    }

    /// Under the transcript lock, detect a non-blank JSONL line.
    /// Unreadable bytes count as empty, allowing stale-empty sessions to leave the hot tier.
    private static func transcriptIsNonEmpty(_ path: URL) -> Bool {
        guard let data = try? Data(contentsOf: path), !data.isEmpty else { return false }
        guard let text = String(data: data, encoding: .utf8) else { return true }
        return text.split(separator: "\n").contains {
            !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    /// The transcript's last-write time, or nil when there is no transcript.
    static func transcriptModifiedDate(_ path: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: path.path))?[.modificationDate] as? Date
    }

    private static func isStaleEmpty(
        _ row: [String: JSONValue],
        now: Date,
        policy: ChatSessionRetentionPolicy
    ) -> Bool {
        guard messageCount(row) <= 0,
              let stamp = date(row["updatedAt"]) ?? date(row["createdAt"]) else {
            return false
        }
        return now.timeIntervalSince(stamp) >= policy.staleEmptySessionAgeSeconds
    }

    private static func messageCount(_ row: [String: JSONValue]) -> Int {
        switch row["messageCount"] {
        case .int(let value):
            return Int(value)
        case .double(let value):
            return Int(exactly: value.rounded(.towardZero)) ?? 0
        case .string(let value):
            return Int(value.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
        default:
            return 0
        }
    }

    private static func date(_ value: JSONValue?) -> Date? {
        guard case .string(let raw)? = value else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return NativeTimestampFormat.parseISO8601FractionalFirst(trimmed)
    }

    private static func uniqueArchivePath(
        directory: URL,
        safeSessionId: String,
        now: Date
    ) throws -> URL {
        let preferred = directory.appendingPathComponent("\(safeSessionId).jsonl")
        guard FileManager.default.fileExists(atPath: preferred.path) else {
            return preferred
        }
        let stamp = NativeTimestampFormat.fractionalZulu(now)
            .replacingOccurrences(of: ":", with: "-")
            .replacingOccurrences(of: ".", with: "-")
        var candidate = directory.appendingPathComponent("\(safeSessionId).\(stamp).jsonl")
        var counter = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = directory.appendingPathComponent("\(safeSessionId).\(stamp).\(counter).jsonl")
            counter += 1
        }
        return candidate
    }

    private static func appendJSONL(_ record: JSONValue, to path: URL) throws {
        try FileManager.default.createDirectory(
            at: path.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        var line = try record.serialize(pretty: false)
        line += "\n"
        // The shared append: torn-line repair and O_APPEND. The caller holds
        // the index lock.
        try SwiftNativePersistenceCore.appendOwnedBytes(Data(line.utf8), to: path, durable: true)
    }

    private static func relativePath(_ url: URL, under root: URL) -> String {
        let path = url.standardizedFileURL.path
        return NativeAgentWorkspaceRoot.relativePath(path, under: root.standardizedFileURL.path) ?? path
    }
}

