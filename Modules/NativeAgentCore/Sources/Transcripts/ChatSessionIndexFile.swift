import Foundation
import os
import NativeAgentCore
import Darwin
import PersistenceCore
import NativeAgentShared
// Blueprint: | `ChatSessionIndexFile.swift` | `recordContinuityParticipant`, `recordConversationChange`: Durable index and continuity transactions |

public enum ChatSessionIndexFileError: Error, LocalizedError, Sendable, Equatable {
    case unreadable(path: String, reason: String)
    case empty(path: String)
    case malformed(path: String, reason: String)
    case expectedArray(path: String)
    case nonObjectRow(path: String, index: Int)

    /// Remote error descriptions expose only the filename; associated values retain the local path.
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

/// Only missing storage creates a new index; unreadable or malformed existing bytes must never be overwritten as empty. Hold the shared lock across read, row
/// edits, durable commit and dependent effects. Local/off-disk backup and PrivacyMap/chat include this index; export excludes it and phone sync projects
/// selected rows.
public enum ChatSessionIndexFile {
    /// Keep index publication, destination binding and retention under one lock.
    public static func ensureSession(
        id: String, title: String, source: String, sourceKey: String, kind: ChatThreadKind,
        dataRoot: URL, context: String,
        commitBinding: @Sendable () async throws -> Void = {}
    ) async throws {
        let path = dataRoot.appendingPathComponent("chat/sessions.json")
        try await SwiftNativePersistenceCore.withFileLock(path) {
            var rows = try loadObjectRowsForMutation(at: path)
            if rows.contains(where: { $0["id"] == .string(id) }) {
                try await commitBinding()
                return
            }
            let now = NativeTimestampFormat.fractionalZulu(Date())
            let row = try await ChatSessionRetention.restoreArchivedRow(sessionId: id, dataRoot: dataRoot) ?? [
                "id": .string(id), "title": .string(title), "source": .string(source),
                "threadKind": .string(kind.rawValue), "sourceKey": .string(sourceKey),
                "createdAt": .string(now), "updatedAt": .string(now),
                "archived": .bool(false), "messageCount": .int(0),
                transcriptGenerationKey: .int(0),
            ]
            rows.insert(row, at: 0)
            try write(rows, to: path)
            do {
                try await commitBinding()
            } catch {
                // An unbound row cannot escape the index transaction.
                rows.removeFirst()
                try write(rows, to: path)
                throw error
            }
            ChatSessionRetention.enforceBestEffort(dataRoot: dataRoot, rows: rows, now: Date(), context: context)
        }
    }

    public static func mutate<T: Sendable>(
        at path: URL, _ mutation: @Sendable (inout [[String: JSONValue]]) async throws -> T
    ) async throws -> T {
        try await SwiftNativePersistenceCore.withFileLock(path) {
            var rows = try loadObjectRowsForMutation(at: path)
            let original = rows
            let result = try await mutation(&rows)
            if rows != original { try write(rows, to: path) }
            return result
        }
    }

    /// Compound transactions may commit before their next effect (retention, binding publication). The existing lock scope remains held across both.
    public static func write(_ rows: [[String: JSONValue]], to path: URL, removeWhenEmpty: Bool = false) throws {
        try CredentialFileLock.withLock(path) {
            if removeWhenEmpty && rows.isEmpty { try FileManager.default.removeItem(at: path) }
            else {
                try SwiftNativePersistenceCore.writeDataAtomicDurable(
                    JSONValue.array(rows.map(JSONValue.object)).serializedData(pretty: true), to: path)
            }
        }
    }

    private static let pendingSyncs = OSAllocatedUnfairLock(initialState: [String: Int]())

    /// An overlapping sync may observe another writer's bytes. Keep its transcript hot until every admitted writer has finished its own index commit; after a
    /// crash, the persisted exact-version guard takes over.
    public static func beginTranscriptIndexSync(at path: URL) {
        pendingSyncs.withLock { $0[path.standardizedFileURL.path, default: 0] += 1 }
    }

    public static func endTranscriptIndexSync(at path: URL) {
        pendingSyncs.withLock { counts in
            let key = path.standardizedFileURL.path
            if let count = counts[key], count > 1 { counts[key] = count - 1 }
            else { counts.removeValue(forKey: key) }
        }
    }

    public static func hasPendingTranscriptIndexSync(at path: URL) -> Bool {
        pendingSyncs.withLock { $0[path.standardizedFileURL.path] != nil }
    }

    /// Exact filesystem version acknowledged while holding the transcript lock. Integer seconds/nanoseconds avoid ISO8601 millisecond rounding; inode and size
    /// also distinguish atomic replacements and same-clock appends.
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

    /// Unknown participants stay unavailable; bind an assistant-led opening only when the whole transcript proves the first user's provenance.
    public static func recordContinuityParticipant(
        in row: inout [String: JSONValue], participant: String?, scope: String?, messageCount: Int,
        verifiedOpening: Bool = false
    ) {
        let incoming = participant.map(JSONValue.string) ?? .null
        if row["continuityParticipant"] == nil {
            row["continuityParticipant"] = messageCount == 1 || verifiedOpening ? incoming : .null
            row["continuityScope"] = scope.map(JSONValue.string) ?? .null
        } else if row["continuityParticipant"] != incoming
                    || row["continuityScope"] != (scope.map(JSONValue.string) ?? .null) {
            row["continuityParticipant"] = .null
        }
    }
    /// The last transcript generation containing conversational speech. Tool receipts still advance transcriptGeneration, but do not announce a new exchange to
    /// another open workspace.
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

    /// Read counts and acknowledgments under index → transcript locks; keep retention in that index transaction on every message. Back up the object-array
    /// index locally; export excludes it and phone sync projects sessions and pins under PrivacyMap/chat.
    package static func recordMessage(
        sessionId: String, role normalizedRole: String, source: String, sourceKey: String?, kind: ChatThreadKind?, ownedSessionID: String?,
        timestamp: String, syncedAt: String, preview: String, stamp: TranscriptRowStamp,
        title: String?, continuityParticipant: String?, continuityScope: String?,
        dataRoot: URL, messagesPath: URL, countMessages: @escaping @Sendable (URL) throws -> Int,
        clock retentionClock: @escaping @Sendable () -> Date
    ) async throws {
        let sessionsPath = dataRoot.appendingPathComponent("chat/sessions.json")
        try await SwiftNativePersistenceCore.withFileLock(sessionsPath) {
            let rows = try ChatSessionIndexFile.loadObjectRowsForMutation(at: sessionsPath)
            let needsOpeningProof = !rows.contains {
                $0["id"] == .string(sessionId) && $0["continuityParticipant"] != nil
            }
            let snapshot = try await SwiftNativePersistenceCore.withFileLock(messagesPath) {
                let count = try countMessages(messagesPath)
                var verifiedOpening = false
                if needsOpeningProof, normalizedRole == "user", count > 1, let continuityParticipant {
                    let (transcript, report) = try await SwiftNativePersistenceCore.readJSONLReporting(messagesPath)
                    let users = transcript.filter {
                        guard case .object(let fields) = $0 else { return false }
                        return fields["role"] == .string("user")
                    }
                    verifiedOpening = report.isClean && transcript.count == count && users.count == 1 && transcript.allSatisfy {
                        guard case .object(let fields) = $0,
                              case .string(let role)? = fields["role"],
                              case .object(let metadata)? = fields["metadata"] else { return false }
                        return ["user", "assistant"].contains(role)
                            && ConversationHistory.admitsContinuity(
                                role: role, metadata: metadata, participant: continuityParticipant,
                                source: source, scope: continuityScope)
                    }
                }
                return (count: count, version: ChatSessionIndexFile.transcriptVersion(at: messagesPath),
                        verifiedOpening: verifiedOpening)
            }
            let messageCount = snapshot.count
            let parent = sessionsPath.deletingLastPathComponent()
            try? FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
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
                        in: &row, participant: continuityParticipant, scope: continuityScope, messageCount: messageCount,
                        verifiedOpening: snapshot.verifiedOpening)
                }
                if ownedSessionID == sessionId, let kind {
                    row["threadKind"] = .string(kind.rawValue)
                }
                updated = row
            }

            if updated == nil {
                var row: [String: JSONValue] = [
                    "id": .string(sessionId),
                    "title": .string(title ?? "New Chat"),
                    "source": .string(source),
                    "threadKind": .string((kind ?? ChatThreadKind.inferred(fromSource: source)).rawValue),
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
                        in: &row, participant: continuityParticipant, scope: continuityScope, messageCount: messageCount,
                        verifiedOpening: snapshot.verifiedOpening)
                }
                if !preview.isEmpty { row["lastMessagePreview"] = .string(preview); row[TranscriptRowStamp.previewKey] = stamp.json }
                updated = row
            }

            if var updated {
                if messageCount == 1 || updated["createdAt"] == .string(timestamp) {
                    updated["firstMessageAt"] = .string(timestamp)
                }
                let previous = updated["lastMessageAt"].flatMap { value -> Date? in
                    if case .string(let stamp) = value { return NativeTimestampFormat.parseISO8601FractionalFirst(stamp) }
                    return nil
                } ?? .distantPast
                if (NativeTimestampFormat.parseISO8601FractionalFirst(timestamp) ?? .distantPast) >= previous {
                    updated["lastMessageAt"] = .string(timestamp)
                }
                updated[ChatSessionIndexFile.acknowledgedTranscriptKey] = snapshot.version
                ChatSessionIndexFile.recordConversationChange(in: &updated, role: normalizedRole)
                remaining.insert(updated, at: 0)
            }
            try write(remaining, to: sessionsPath)
            ChatSessionRetention.enforceBestEffort(
                dataRoot: dataRoot,
                rows: remaining,
                now: retentionClock(),
                context: "ChatOrchestrationClient.syncSessionIndex"
            )
        }
    }

    /// Projection changes must preserve unrelated index fields.
    package static func recordProjectionChanges(
        sessionIDs: Set<String>, dataRoot: URL
    ) async throws {
        let path = dataRoot.appendingPathComponent("chat/sessions.json")
        try await SwiftNativePersistenceCore.withFileLock(path) {
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

    /// Acknowledge the rewritten transcript's exact version and count so retention cannot archive an uncommitted generation.
    package static func recordTranscriptRewrite(
        sessionID: String, dataRoot: URL, countMessages: @escaping @Sendable (URL) throws -> Int
    ) async throws {
        let sessionsPath = dataRoot.appendingPathComponent("chat/sessions.json")
        try await SwiftNativePersistenceCore.withFileLock(sessionsPath) {
            var rows = try loadObjectRowsForMutation(at: sessionsPath)
            guard let index = rows.firstIndex(where: { $0["id"] == .string(sessionID) }) else { return }
            bumpTranscriptGeneration(in: &rows[index])
            let messagesPath = dataRoot.appendingPathComponent("chat/messages/\(sessionID).jsonl")
            let snapshot = try await SwiftNativePersistenceCore.withFileLock(messagesPath) {
                (count: try countMessages(messagesPath), version: transcriptVersion(at: messagesPath))
            }
            rows[index]["messageCount"] = .int(Int64(snapshot.count))
            rows[index][acknowledgedTranscriptKey] = snapshot.version
            try write(rows, to: sessionsPath)
        }
    }

    /// Caller must hold index and archived transcript locks.
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

    public static func serializedData(
        for rows: [[String: JSONValue]],
        pretty: Bool = true
    ) throws -> Data {
        try JSONValue.array(rows.map(JSONValue.object)).serializedData(pretty: pretty)
    }

    /// Transcript generations advance on clears and writes; the phone never clears on an absent generation.
    public static let transcriptGenerationKey = "transcriptGeneration"

    public static func transcriptGeneration(in row: [String: JSONValue]) -> Int64? {
        switch row[transcriptGenerationKey] {
        case .int(let value): return value
        // Foreign writers can supply JSON floats; range-check before Int64 conversion to avoid trapping inside the index transaction.
        case .double(let value):
            let truncated = value.rounded(.towardZero)
            guard truncated >= -9_007_199_254_740_992,
                  truncated <= 9_007_199_254_740_992 else { return nil }
            return Int64(truncated)
        default: return nil
        }
    }

    /// Advance without wrapping; absent or unreadable starts at 1, and `Int64.max` returns false.
    @discardableResult
    public static func bumpTranscriptGeneration(in row: inout [String: JSONValue]) -> Bool {
        let current = transcriptGeneration(in: row) ?? 0
        guard current < Int64.max else { return false }
        row[transcriptGenerationKey] = .int(current + 1)
        return true
    }

    /// Check generation exhaustion before deleting bytes: a clear without a newer generation would leave the phone showing stale history.
    public static func isTranscriptGenerationExhausted(in row: [String: JSONValue]) -> Bool {
        transcriptGeneration(in: row) == Int64.max
    }
}

/// Missing or mistyped required fields cannot establish a session row.
public struct ChatSessionRowError: Error, LocalizedError, Sendable, Equatable {
    public let field: String
    public var errorDescription: String? {
        "A chat session row has an unreadable \"\(field)\" field."
    }
}

public extension ChatSession {
    /// Require id, title and createdAt strings; optional fields must be null/absent or exactly typed so malformed rows fail listing.
    init(row o: [String: JSONValue]) throws {
        do {
            let row = try JSONRow(.object(o))
            self.init(
                id: try row.string("id"),
                title: try row.string("title"),
                source: try row.optionalString("source"),
                sourceKey: try row.optionalString("sourceKey"),
                createdAt: try row.string("createdAt"),
                updatedAt: try row.optionalString("updatedAt"),
                archived: try row.optionalBool("archived"),
                messageCount: try row.optionalInt("messageCount"),
                lastMessagePreview: try row.optionalString("lastMessagePreview"),
                summary: try row.optionalString("summary"),
                parentSessionId: try row.optionalString("parentSessionId"),
                rootSessionId: try row.optionalString("rootSessionId"),
                forkedAtMessageId: try row.optionalString("forkedAtMessageId"),
                projectSpaceId: try row.optionalString("projectSpaceId"),
                worktreePath: try row.optionalString("worktreePath"),
                providerId: try row.optionalString("providerId"),
                modelId: try row.optionalString("modelId"),
                transcriptGeneration: try row.optionalInt(ChatSessionIndexFile.transcriptGenerationKey)
            )
            firstMessageAt = try row.optionalString("firstMessageAt")
            lastMessageAt = try row.optionalString("lastMessageAt")
            threadKind = try row.optionalString("threadKind")
            helperID = try row.optionalString("helperID")
        } catch JSONRow.Malformed.field(let key) {
            throw ChatSessionRowError(field: key)
        }
    }
}

private extension UInt8 {
    var isJSONWhitespace: Bool {
        self == 0x20 || self == 0x09 || self == 0x0A || self == 0x0D
    }
}
