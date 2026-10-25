import Foundation
import Darwin
import PersistenceCore
import NativeAgentShared
import TurnTrace
// Blueprint: | `ChatSessionIndexFile.swift` | Canonical durable index writer and checked index schema and message-index, projection-generation, transcript-rewrite and retention-removal transactions; count/acknowledgment reads under index → transcript locks, retention on every message within the index transaction; `recordContinuityParticipant`, `recordConversationChange`; backup/export/sync/privacy decisions live here |

public enum ChatSessionIndexFileError: Error, LocalizedError, Sendable, Equatable {
    case unreadable(path: String, reason: String)
    case empty(path: String)
    case malformed(path: String, reason: String)
    case expectedArray(path: String)
    case nonObjectRow(path: String, index: Int)

    /// 2026-09-06: the message names the FILE, not its absolute path. These
    /// descriptions are forwarded to remote surfaces (iPhone error banners),
    /// and a Mac filesystem path is not theirs to see. The full path stays in
    /// the associated value for Mac-local logs.
    public var errorDescription: String? {
        switch self {
        case .unreadable(let path, let reason):
            return "Chat session index \(Self.fileName(path)) could not be read: \(reason)"
        case .empty(let path):
            return "Chat session index \(Self.fileName(path)) is empty."
        case .malformed(let path, let reason):
            return "Chat session index \(Self.fileName(path)) is malformed JSON: \(reason)"
        case .expectedArray(let path):
            return "Chat session index \(Self.fileName(path)) must contain a JSON array."
        case .nonObjectRow(let path, let index):
            return "Chat session index \(Self.fileName(path)) contains a non-object row at index \(index)."
        }
    }

    private static func fileName(_ path: String) -> String {
        let name = (path as NSString).lastPathComponent
        return name.isEmpty ? "chat session index" : name
    }
}

/// Checked mutation and durable commit owner for `chat/sessions.json`.
///
/// A missing file is the only state treated as a new index. Existing files
/// must be readable, non-empty JSON arrays containing only object rows. This
/// prevents read failures and malformed rows from being collapsed into an
/// empty index and overwritten by the next surface that creates a session.
/// Callers hold its shared lock across read, row edits and write.
/// Storage: local/off-disk backup and PrivacyMap/chat include it; data export
/// excludes it. DeviceSync publishes selected session rows, not this raw file.
public enum ChatSessionIndexFile {
    public static func mutate<T: Sendable>(
        at path: URL, using persistence: PersistenceCoreProtocol = SwiftNativePersistenceCore(),
        _ mutation: @Sendable (inout [[String: JSONValue]]) async throws -> T
    ) async throws -> T {
        try await persistence.withFileLock(path) {
            var rows = try loadObjectRowsForMutation(at: path)
            let original = rows
            let result = try await mutation(&rows)
            if rows != original { try write(rows, to: path) }
            return result
        }
    }

    /// Compound transactions may commit before their next effect (retention,
    /// binding publication). The existing lock scope remains held across both.
    public static func write(_ rows: [[String: JSONValue]], to path: URL, removeWhenEmpty: Bool = false) throws {
        try CredentialFileLock.withLock(path) {
            if removeWhenEmpty && rows.isEmpty { try FileManager.default.removeItem(at: path) }
            else {
                try SwiftNativePersistenceCore.writeDataAtomicDurable(
                    JSONValue.array(rows.map(JSONValue.object)).serializedData(pretty: true), to: path)
            }
        }
    }

    private static let pendingSyncLock = NSLock()
    nonisolated(unsafe) private static var pendingSyncs: [String: Int] = [:]

    /// An overlapping sync may observe another writer's bytes. Keep its
    /// transcript hot until every admitted writer has finished its own index
    /// commit; after a crash, the persisted exact-version guard takes over.
    public static func beginTranscriptIndexSync(at path: URL) {
        pendingSyncLock.lock()
        defer { pendingSyncLock.unlock() }
        pendingSyncs[path.standardizedFileURL.path, default: 0] += 1
    }

    public static func endTranscriptIndexSync(at path: URL) {
        pendingSyncLock.lock()
        defer { pendingSyncLock.unlock() }
        let key = path.standardizedFileURL.path
        if let count = pendingSyncs[key], count > 1 { pendingSyncs[key] = count - 1 }
        else { pendingSyncs.removeValue(forKey: key) }
    }

    public static func hasPendingTranscriptIndexSync(at path: URL) -> Bool {
        pendingSyncLock.lock()
        defer { pendingSyncLock.unlock() }
        return pendingSyncs[path.standardizedFileURL.path] != nil
    }

    /// Exact filesystem version acknowledged while holding the transcript lock.
    /// Integer seconds/nanoseconds avoid ISO8601 millisecond rounding; inode
    /// and size also distinguish atomic replacements and same-clock appends.
    public static let acknowledgedTranscriptKey = "acknowledgedTranscriptVersion"

    public static func transcriptVersion(at path: URL) -> JSONValue? {
        var info = stat()
        guard lstat(path.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else { return nil }
        return .object([
            "seconds": .int(Int64(info.st_mtimespec.tv_sec)),
            "nanoseconds": .int(Int64(info.st_mtimespec.tv_nsec)),
            "bytes": .int(info.st_size),
            "inode": .string(String(info.st_ino)),
        ])
    }

    /// Unknown or mixed participants stay unavailable. Legacy transcripts are
    /// not relabeled from their latest turn; only a new conversation binds.
    public static func recordContinuityParticipant(
        in row: inout [String: JSONValue], participant: String?, scope: String?, messageCount: Int
    ) {
        let incoming = participant.map(JSONValue.string) ?? .null
        if row["continuityParticipant"] == nil {
            row["continuityParticipant"] = messageCount == 1 ? incoming : .null
            row["continuityScope"] = scope.map(JSONValue.string) ?? .null
        } else if row["continuityParticipant"] != incoming
                    || row["continuityScope"] != (scope.map(JSONValue.string) ?? .null) {
            row["continuityParticipant"] = .null
        }
    }
    /// The last transcript generation containing conversational speech. Tool
    /// receipts still advance transcriptGeneration, but do not announce a new
    /// exchange to another open workspace.
    public static func recordConversationChange(in row: inout [String: JSONValue], role: String) {
        guard ["user", "assistant"].contains(role), let generation = transcriptGeneration(in: row) else { return }
        row["lastConversationGeneration"] = .int(generation)
    }
    public static func loadObjectRowsForMutation(
        at path: URL,
        fileManager: FileManager = .default
    ) throws -> [[String: JSONValue]] {
        guard fileManager.fileExists(atPath: path.path) else { return [] }

        let data: Data
        do {
            data = try Data(contentsOf: path)
        } catch {
            throw ChatSessionIndexFileError.unreadable(
                path: path.path,
                reason: error.localizedDescription
            )
        }

        guard data.contains(where: { !$0.isJSONWhitespace }) else {
            throw ChatSessionIndexFileError.empty(path: path.path)
        }

        let parsed: JSONValue
        do {
            parsed = try JSONValue.parse(data)
        } catch {
            throw ChatSessionIndexFileError.malformed(
                path: path.path,
                reason: error.localizedDescription
            )
        }

        guard case .array(let values) = parsed else {
            throw ChatSessionIndexFileError.expectedArray(path: path.path)
        }

        var rows: [[String: JSONValue]] = []
        rows.reserveCapacity(values.count)
        for (index, value) in values.enumerated() {
            guard case .object(let row) = value else {
                throw ChatSessionIndexFileError.nonObjectRow(path: path.path, index: index)
            }
            rows.append(row)
        }
        return rows
    }

    /// Canonical sessions.json message-index transaction. The JSON object-array
    /// schema is locally backed up, excluded from production export, projected
    /// to phone sessions/pins and inventoried under PrivacyMap's chat category.
    /// Count and filesystem acknowledgment are read inside index → transcript
    /// locks; retention remains inside the same index transaction on every message.
    package static func recordMessage(
        sessionId: String, role normalizedRole: String, source: String, sourceKey: String?,
        timestamp: String, syncedAt: String, preview: String, stamp: TranscriptRowStamp,
        title: String?, continuityParticipant: String?, continuityScope: String?,
        dataRoot: URL, messagesPath: URL, persistence: any PersistenceCoreProtocol,
        countMessages: @escaping @Sendable (URL) -> Int,
        clock retentionClock: @escaping @Sendable () -> Date
    ) async throws {
        let sessionsPath = dataRoot.appendingPathComponent("chat/sessions.json")
        try await persistence.withFileLock(sessionsPath) {
            let snapshot = try await persistence.withFileLock(messagesPath) {
                (count: countMessages(messagesPath),
                 version: ChatSessionIndexFile.transcriptVersion(at: messagesPath))
            }
            let messageCount = snapshot.count
            let parent = sessionsPath.deletingLastPathComponent()
            try? FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
            let rows = try ChatSessionIndexFile.loadObjectRowsForMutation(at: sessionsPath)

            var updated: [String: JSONValue]? = nil
            var remaining: [[String: JSONValue]] = []
            for var row in rows {
                guard case .string(let id)? = row["id"], id == sessionId else {
                    remaining.append(row)
                    continue
                }
                row["updatedAt"] = .string(syncedAt)
                ChatSessionIndexFile.bumpTranscriptGeneration(in: &row)
                row["messageCount"] = .int(Int64(messageCount))
                if !preview.isEmpty { row["lastMessagePreview"] = .string(preview); row[TranscriptRowStamp.previewKey] = stamp.json }
                if let title,
                   shouldReplaceSessionTitle(row["title"]) {
                    row["title"] = .string(title)
                }
                if row["source"] == nil {
                    row["source"] = .string(source)
                }
                if row["sourceKey"] == nil, let sourceKey {
                    row["sourceKey"] = .string(sourceKey)
                }
                if normalizedRole == "user" {
                    ChatSessionIndexFile.recordContinuityParticipant(
                        in: &row, participant: continuityParticipant, scope: continuityScope, messageCount: messageCount)
                }
                if row["threadKind"] == nil {
                    let existingSource: String = {
                        if case .string(let value)? = row["source"] { return value }
                        return source
                    }()
                    row["threadKind"] = .string(
                        ChatThreadKind.inferred(fromSource: existingSource).rawValue
                    )
                }
                updated = row
            }

            if updated == nil {
                var row: [String: JSONValue] = [
                    "id": .string(sessionId),
                    "title": .string(title ?? "New Chat"),
                    "source": .string(source),
                    "threadKind": .string(ChatThreadKind.inferred(fromSource: source).rawValue),
                    "createdAt": .string(timestamp),
                    "updatedAt": .string(syncedAt),
                    "archived": .bool(false),
                    "messageCount": .int(Int64(messageCount)),
                    "summary": .string(""),
                    ChatSessionIndexFile.transcriptGenerationKey: .int(1),
                ]
                if let sourceKey { row["sourceKey"] = .string(sourceKey) }
                if normalizedRole == "user" {
                    ChatSessionIndexFile.recordContinuityParticipant(
                        in: &row, participant: continuityParticipant, scope: continuityScope, messageCount: messageCount)
                }
                if !preview.isEmpty { row["lastMessagePreview"] = .string(preview); row[TranscriptRowStamp.previewKey] = stamp.json }
                updated = row
            }

            if var updated {
                if messageCount == 1 || updated["createdAt"] == .string(timestamp) {
                    updated["firstMessageAt"] = .string(timestamp)
                }
                let previous = updated["lastMessageAt"].flatMap { value -> Date? in
                    if case .string(let stamp) = value { return dateFromISO8601(stamp) }
                    return nil
                } ?? .distantPast
                if (dateFromISO8601(timestamp) ?? .distantPast) >= previous {
                    updated["lastMessageAt"] = .string(timestamp)
                }
                updated[ChatSessionIndexFile.acknowledgedTranscriptKey] = snapshot.version
                ChatSessionIndexFile.recordConversationChange(in: &updated, role: normalizedRole)
                remaining.insert(updated, at: 0)
            }
            try write(remaining, to: sessionsPath)
            ChatSessionRetention.enforceBestEffort(
                dataRoot: dataRoot,
                now: retentionClock(),
                context: "ChatOrchestrationClient.syncSessionIndex"
            )
        }
    }

    /// Projection-only changes preserve every other index field.
    package static func recordProjectionChanges(
        sessionIDs: Set<String>, dataRoot: URL,
        persistence: any PersistenceCoreProtocol
    ) async throws {
        let path = dataRoot.appendingPathComponent("chat/sessions.json")
        try await persistence.withFileLock(path) {
            var rows = try loadObjectRowsForMutation(at: path)
            var changed = false
            for index in rows.indices {
                guard case .string(let id)? = rows[index]["id"], sessionIDs.contains(id) else { continue }
                changed = bumpTranscriptGeneration(in: &rows[index]) || changed
            }
            guard changed else { return }
            try write(rows, to: path)
        }
    }

    /// A rewritten transcript acknowledges its exact filesystem version and count.
    package static func recordTranscriptRewrite(
        sessionID: String, dataRoot: URL, persistence: any PersistenceCoreProtocol,
        countMessages: @escaping @Sendable (URL) -> Int
    ) async throws {
        let sessionsPath = dataRoot.appendingPathComponent("chat/sessions.json")
        try await persistence.withFileLock(sessionsPath) {
            var rows = try loadObjectRowsForMutation(at: sessionsPath)
            guard let index = rows.firstIndex(where: { $0["id"] == .string(sessionID) }) else { return }
            bumpTranscriptGeneration(in: &rows[index])
            let messagesPath = dataRoot.appendingPathComponent("chat/messages/\(sessionID).jsonl")
            let snapshot = try await persistence.withFileLock(messagesPath) {
                (count: countMessages(messagesPath), version: transcriptVersion(at: messagesPath))
            }
            rows[index]["messageCount"] = .int(Int64(snapshot.count))
            rows[index][acknowledgedTranscriptKey] = snapshot.version
            try write(rows, to: sessionsPath)
        }
    }

    /// Retention calls this while holding index and archived transcript locks.
    static func removeArchivedRow(
        _ row: [String: JSONValue], from rows: inout [[String: JSONValue]], at path: URL
    ) throws {
        guard let index = rows.firstIndex(of: row) else { return }
        var next = rows
        next.remove(at: index)
        try write(next, to: path)
        rows = next
    }

    private static func shouldReplaceSessionTitle(_ value: JSONValue?) -> Bool {
        guard case .string(let raw)? = value else { return true }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty || trimmed == "New Chat"
    }

    private static func dateFromISO8601(_ raw: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: raw) ?? ISO8601DateFormatter().date(from: raw)
    }

    public static func serializedData(
        for rows: [[String: JSONValue]],
        pretty: Bool = true
    ) throws -> Data {
        try JSONValue.array(rows.map(JSONValue.object)).serializedData(pretty: pretty)
    }

    /// 2026-09-06: the session row's monotonic transcript version.
    ///
    /// `updatedAt` is a wall-clock stamp and cannot order two transcript
    /// states: a clock that steps back, two writers a millisecond apart, or a
    /// row restamped for a reason that isn't a transcript write all produce
    /// stamps that lie about which transcript is newer. The phone uses this
    /// version to decide whether an EMPTY published transcript is allowed to
    /// wipe its copy of a chat, so it has to be a counter, never a clock:
    /// incremented on every clear and every transcript write, and only ever
    /// upward. A row with no counter yet is `nil`, and the phone never clears
    /// on `nil` — legacy Macs keep the pre-2026-09-06 behaviour.
    public static let transcriptGenerationKey = "transcriptGeneration"

    public static func transcriptGeneration(in row: [String: JSONValue]) -> Int64? {
        switch row[transcriptGenerationKey] {
        case .int(let value): return value
        // A hand-edited or foreign-writer row can carry the counter as a JSON
        // float. Range-checked, never a bare `Int64(value)` — that traps on
        // anything outside Int64, and this reader sits inside the
        // session-index writer.
        case .double(let value):
            let truncated = value.rounded(.towardZero)
            guard truncated >= -9_007_199_254_740_992,
                  truncated <= 9_007_199_254_740_992 else { return nil }
            return Int64(truncated)
        default: return nil
        }
    }

    /// Advance the row's transcript version. Absent or unreadable starts at 1,
    /// which is still strictly greater than "no version at all".
    ///
    /// 2026-09-06: saturating, never wrapping. `&+ 1` on a row already at
    /// `Int64.max` yields `Int64.min`, and this counter's whole job is that it
    /// only ever moves upward — a wrap would make every subsequent transcript
    /// write look older than the clear that preceded it. A row at the ceiling
    /// stops moving instead and reports `false`, so a caller that needs the
    /// bump to mean something (a clear, which publishes an empty transcript a
    /// remote reader may only act on when it is provably newest) can refuse.
    @discardableResult
    public static func bumpTranscriptGeneration(in row: inout [String: JSONValue]) -> Bool {
        let current = transcriptGeneration(in: row) ?? 0
        guard current < Int64.max else { return false }
        row[transcriptGenerationKey] = .int(current + 1)
        return true
    }

    /// Whether this row's transcript version can no longer advance. A clear
    /// checks this BEFORE deleting any transcript bytes: an empty transcript
    /// published without a newer version is one the phone must refuse, which
    /// would leave the two surfaces disagreeing about the chat forever.
    public static func isTranscriptGenerationExhausted(in row: [String: JSONValue]) -> Bool {
        transcriptGeneration(in: row) == Int64.max
    }
}

/// A `sessions.json` row that does not read as a session: a required field is
/// missing, or a field holds the wrong JSON type.
public struct ChatSessionRowError: Error, LocalizedError, Sendable, Equatable {
    public let field: String
    public var errorDescription: String? {
        "A chat session row has an unreadable \"\(field)\" field."
    }
}

public extension ChatSession {
    /// One `sessions.json` row, read straight from its parsed object. The
    /// same contract the row's Codable decode had: `id`, `title` and
    /// `createdAt` are required strings; every other field is absent/null or
    /// its exact type (integers accept an integral JSON float); anything else
    /// fails the row, and so the listing.
    init(row o: [String: JSONValue]) throws {
        func string(_ key: String) throws -> String? {
            switch o[key] {
            case nil, .null?: return nil
            case .string(let s)?: return s
            default: throw ChatSessionRowError(field: key)
            }
        }
        func required(_ key: String) throws -> String {
            guard let s = try string(key) else { throw ChatSessionRowError(field: key) }
            return s
        }
        func int(_ key: String) throws -> Int? {
            switch o[key] {
            case nil, .null?: return nil
            case .int(let n)?: return Int(n)
            case .double(let d)?:
                guard let n = Int(exactly: d) else { throw ChatSessionRowError(field: key) }
                return n
            default: throw ChatSessionRowError(field: key)
            }
        }
        func bool(_ key: String) throws -> Bool? {
            switch o[key] {
            case nil, .null?: return nil
            case .bool(let b)?: return b
            default: throw ChatSessionRowError(field: key)
            }
        }
        self.init(
            id: try required("id"),
            title: try required("title"),
            source: try string("source"),
            sourceKey: try string("sourceKey"),
            createdAt: try required("createdAt"),
            updatedAt: try string("updatedAt"),
            archived: try bool("archived"),
            messageCount: try int("messageCount"),
            lastMessagePreview: try string("lastMessagePreview"),
            summary: try string("summary"),
            parentSessionId: try string("parentSessionId"),
            rootSessionId: try string("rootSessionId"),
            forkedAtMessageId: try string("forkedAtMessageId"),
            projectSpaceId: try string("projectSpaceId"),
            worktreePath: try string("worktreePath"),
            providerId: try string("providerId"),
            modelId: try string("modelId"),
            transcriptGeneration: try int(ChatSessionIndexFile.transcriptGenerationKey)
        )
        firstMessageAt = try string("firstMessageAt")
        lastMessageAt = try string("lastMessageAt")
    }
}

private extension UInt8 {
    var isJSONWhitespace: Bool {
        self == 0x20 || self == 0x09 || self == 0x0A || self == 0x0D
    }
}
