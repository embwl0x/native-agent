import Foundation
import NativeAgentShared
import CryptoKit
import NativeAgentCore
import PersistenceCore
import os
// Blueprint: | `ChatSessionRetention.swift` | Locked archival preserves acknowledged transcript bytes |

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

/// Bounds the hot index without deleting history; `enforce` uses the caller's locked rows. Manual archive owns its locks. Rows append to
/// `chat/archive/sessions.jsonl`; transcripts move from `chat/messages/` to `chat/archive/messages/`. Lock sessions index, transcript, then archive index;
/// writers release the transcript lock before index sync. Contended transcripts stay hot for a later pass. Archive history belongs to local/off-disk backups
/// and PrivacyMap/chat; data export and phone sync exclude raw archive files.
public enum ChatSessionRetention {
    public static let diskStorageOwner = DiskStorageOwner.retained(id: "chat", roots: ["chat"],
        policy: """
            Transcripts, archives and retained tool results are memory; Clean Up keeps them. Launch rebuilds the retained history search index. \
            chat.archive organizes conversations without reclaiming transcript bytes. No history erasure control is provided by this cleanup.
            """)

    // Archived transcripts and their locator rows are durable history. Only explicit deletion may remove them; the active index remains bounded.
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

        let protectedSessionIds = try resolvedProtectedSessionIds(policy, dataRoot: dataRoot, rows: rows)
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
        // The caller holds the sessions lock. Checkpoint each removal while archive still holds the transcript lock, before deleting hot history.
        var report = ChatSessionRetentionReport()
        var staleEmptyAborts = 0
        for (index, row) in rows.enumerated() {
            guard let reason = reasons[index] else {
                kept.append(row)
                continue
            }
            if try archive(row: row, reason: reason, dataRoot: dataRoot, now: now,
                           commitIndexRemoval: { try ChatSessionIndexFile.removeArchivedRow(row, from: &indexedRows, at: sessionsPath) }) != nil {
                report.archivedSessions += 1
                switch reason {
                case .activeCap:
                    report.archivedForCap += 1
                case .staleEmpty:
                    report.archivedEmptySessions += 1
                case .manual: break
                }
            } else {
                if reason == .staleEmpty { staleEmptyAborts += 1 }
                kept.append(row)
            }
        }

        // Aborted stale-empty archives rejoin active-cap planning as nonempty sessions. The bounded second pass executes only active-cap removals.
        if staleEmptyAborts > 0 {
            let secondReasons = plannedArchiveReasons(
                rows: kept,
                now: now,
                policy: policy,
                protectedSessionIds: protectedSessionIds
            )
            for (index, row) in kept.enumerated() where secondReasons[index] == .activeCap {
                if try archive(row: row, reason: .activeCap, dataRoot: dataRoot, now: now,
                               commitIndexRemoval: { try ChatSessionIndexFile.removeArchivedRow(row, from: &indexedRows, at: sessionsPath) }) != nil {
                    report.archivedSessions += 1
                    report.archivedForCap += 1
                }
            }
        }

        report.keptSessions = indexedRows.count
        return (indexedRows, report)
    }

    /// Best-effort enforcement for callers whose success path must continue even if retention is temporarily unavailable. Failures are logged, never silently
    /// swallowed.
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

    /// Manual archive uses retention's index → transcript → archive transaction and writes the same restorable transcript locator.
    public static func archiveSession(id: String, dataRoot: URL) async throws -> [String: JSONValue]? {
        guard NativeAgentChatSessionID.normalizedPathComponent(id) != nil else { return nil }
        let index = dataRoot.appendingPathComponent("chat/sessions.json")
        return try await SwiftNativePersistenceCore.withFileLock(index) {
            var rows = try ChatSessionIndexFile.loadObjectRowsForMutation(at: index)
            guard let row = rows.first(where: { $0["id"] == .string(id) }) else { return nil }
            guard let archived = try archive(row: row, reason: .manual, dataRoot: dataRoot, now: Date(), commitIndexRemoval: {
                try ChatSessionIndexFile.removeArchivedRow(row, from: &rows, at: index)
            }) else {
                throw PersistenceCoreError.ioFailure(
                    "The conversation is busy; its transcript and active row were left in place. Archive it when its writer finishes.")
            }
            return archived
        }
    }

    private enum ArchiveReason: String {
        case activeCap = "active_cap"
        case staleEmpty = "stale_empty"
        case manual
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
        dataRoot: URL,
        rows: [[String: JSONValue]]
    ) throws -> Set<String> {
        var protected = policy.protectedSessionIds
        if policy.includeMacPinnedSessions {
            protected.formUnion(try macPinnedChatSessionIds(dataRoot: dataRoot))
        }
        // The live anchor stays protected independently of pins on every surface. Its publisher shares this caller's sessions lock, so the read is atomic.
        protected.formUnion(try ConversationAnchor.protectedSessionIds(dataRoot: dataRoot))
        // A session a door (Telegram chat, Slack channel/thread) is bound to is where that door's next message lands; archiving it would restart that door with
        // an empty conversation.
        protected.formUnion(try doorMappedSessionIds(dataRoot: dataRoot))
        // Contact panes read their owned conversation; archiving it would blank the pane.
        protected.formUnion(try contactSessionIds(dataRoot: dataRoot, rows: rows))
        return protected
    }

    /// Hash contact identity so its protected session prefix is shared across surfaces.
    public static func contactSessionPrefix(owner: String) -> String {
        let digest = SHA256.hash(data: Data(owner.utf8))
        return "agent-" + digest.map { String(format: "%02x", $0) }.joined().prefix(12) + "-"
    }

    private static func contactSessionIds(dataRoot: URL, rows: [[String: JSONValue]]) throws -> Set<String> {
        var owners = ["codex", "claude", "omp"]
        let path = dataRoot.appendingPathComponent("agents/peers.json")
        do {
            // Unknown protection stops retention, as with pins above.
            guard case .array(let peers) = try JSONValue.parse(Data(contentsOf: path)) else {
                throw PersistenceCoreError.ioFailure("I couldn’t read your agent contacts. I’ve left your conversations in place.")
            }
            for case .object(let peer) in peers { if case .string(let id)? = peer["id"] { owners.append(id) } }
        } catch CocoaError.fileReadNoSuchFile {}
        // Unknown caller liveness stops retention before any transcript is moved.
        var ids = Set(owners.map { contactSessionPrefix(owner: $0) + ContactCaller.shared(peer: $0) })
        let prefixes = owners.map { ($0, contactSessionPrefix(owner: $0)) }
        for case .string(let id)? in rows.map({ $0["id"] }) {
            for (owner, prefix) in prefixes where id.hasPrefix(prefix) {
                guard let caller = ContactCaller(conversation: String(id.dropFirst(prefix.count)), peer: owner) else { continue }
                if try caller.isLive() { ids.insert(id) }
            }
        }
        return ids
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
    ) throws -> [String: JSONValue]? {
        guard case .string(let sessionId)? = row["id"],
              let safeSessionId = NativeAgentChatSessionID.normalizedPathComponent(sessionId) else {
            return nil
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
        baseArchivedRow["archivedBy"] = .string(reason == .manual ? "mac_chat" : "chat_session_retention")
        if reason == .manual {
            baseArchivedRow["archivedAt"] = .string(ISO8601DateFormatter().string(from: now))
        } else {
            baseArchivedRow["retentionArchivedAt"] = .string(NativeTimestampFormat.fractionalZulu(now))
            baseArchivedRow["retentionReason"] = .string(reason.rawValue)
        }

        let archived = try CredentialFileLock.tryWithLock(messagesPath) { () throws -> [String: JSONValue]? in
            if reason != .staleEmpty, ChatSessionIndexFile.hasPendingTranscriptIndexSync(at: messagesPath) {
                return nil
            }
            // Recheck emptiness under the transcript lock before archiving a stale-empty session.
            if reason == .staleEmpty, transcriptIsNonEmpty(messagesPath) {
                return nil
            }
            // Archive only the transcript version acknowledged by the session index.
            if reason == .activeCap, transcriptModifiedDate(messagesPath) != nil {
                // Pending writers alter bytes before index sync; retain unacknowledged versions until reconciliation confirms them.
                guard let version = ChatSessionIndexFile.transcriptVersion(at: messagesPath),
                      row[ChatSessionIndexFile.acknowledgedTranscriptKey] == version else {
                    return nil
                }
            }
            // Check existence only after locking: a writer may be creating the first row while retention is selecting this session.
            var archivedMessagesPath: URL?
            var archivedRow = baseArchivedRow
            var reused = false
            let hotExists = FileManager.default.fileExists(atPath: messagesPath.path)
            if hotExists || reason == .manual {
                let bytes: Data
                do { bytes = try Data(contentsOf: messagesPath) }
                catch CocoaError.fileReadNoSuchFile where row["messageCount"] == .int(0) { bytes = Data() }
                if reason == .manual, let latest = try archiveIndexRows(dataRoot: dataRoot).last(where: { $0["id"] == .string(sessionId) }),
                   case .string(let relative)? = latest["messagesArchivePath"] {
                    var comparable = latest
                    comparable.removeValue(forKey: "messagesArchivePath")
                    comparable["archivedAt"] = baseArchivedRow["archivedAt"]
                    let existing = dataRoot.appendingPathComponent(relative)
                    if comparable == baseArchivedRow, try Data(contentsOf: existing) == bytes {
                        // Its archive commit survived a failed hot-index removal. Finish that transaction without another copy or archive row.
                        archivedRow = latest
                        archivedMessagesPath = existing
                        reused = true
                    }
                }
                if !reused {
                    let archiveDir = dataRoot
                        .appendingPathComponent("chat", isDirectory: true)
                        .appendingPathComponent("archive", isDirectory: true)
                        .appendingPathComponent("messages", isDirectory: true)
                    try FileManager.default.createDirectory(at: archiveDir, withIntermediateDirectories: true)
                    let destination = try uniqueArchivePath(directory: archiveDir, safeSessionId: safeSessionId, now: now)
                    try ContactThread.replace(bytes, to: destination)
                    archivedMessagesPath = destination
                    archivedRow["messagesArchivePath"] = .string(relativePath(destination, under: dataRoot))
                }
            }

            // Lock archive after transcript. On contention, discard the copy and keep the session hot; no removal may precede its durable archive row.
            let indexRowWritten = try CredentialFileLock.tryWithLock(archiveIndex) {
                if !reused { try appendJSONL(.object(archivedRow), to: archiveIndex) }
                return true
            }
            guard indexRowWritten == true else {
                if let archivedMessagesPath, !reused {
                    try? FileManager.default.removeItem(at: archivedMessagesPath)
                }
                return nil
            }

            // Both archive bytes and its row exist before the active row goes. If interrupted after this checkpoint, the hot copy may survive and be recovered
            // as an orphan; an active row never loses history.
            try commitIndexRemoval()
            if archivedMessagesPath != nil && hotExists {
                try FileManager.default.removeItem(at: messagesPath)
            }
            return archivedRow
        }
        return archived ?? nil
    }

    /// Under the transcript lock, detect a non-blank JSONL line. Unreadable bytes count as empty, allowing stale-empty sessions to leave the hot tier.
    private static func transcriptIsNonEmpty(_ path: URL) -> Bool {
        guard let data = try? Data(contentsOf: path), !data.isEmpty else { return false }
        guard let text = String(data: data, encoding: .utf8) else { return true }
        return text.split(separator: "\n").contains {
            !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

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
        // The caller's index lock serializes torn-line repair and O_APPEND.
        try SwiftNativePersistenceCore.appendOwnedBytes(Data(line.utf8), to: path, durable: true)
    }

    private static func relativePath(_ url: URL, under root: URL) -> String {
        let path = url.standardizedFileURL.path
        return NativeAgentWorkspaceRoot.relativePath(path, under: root.standardizedFileURL.path) ?? path
    }
}

