import Foundation
import Context
import MemoryV2
import CryptoKit
import NativeAgentCore
import os
import PersistenceCore
// v2Prefix delivery ladder: supportsMidConversationSystem / …ClearAt.
import ProviderRouting

// MARK: - ChatMessage / ChatSession

public struct ChatMessage: Sendable, Codable {
    public let role: String           // 'user' | 'assistant' | 'system'
    public let content: String
    public let timestamp: String      // ISO8601
    public let extras: JSONValue?

    public init(role: String, content: String, timestamp: String, extras: JSONValue?) {
        self.role = role
        self.content = content
        self.timestamp = timestamp
        self.extras = extras
    }
}

extension ChatMessage {
    /// Head/tail reads overlap, but separate messages can share timestamp,
    /// role and text (especially attachment-only or rescued partial rows).
    /// Prefer the transcript's existing identity; retain the old tuple only
    /// for legacy rows that have no usable ID. This never changes stored IDs.
    func historyIdentity(renderedRole: String? = nil, renderedContent: String? = nil) -> String {
        if case .object(let record)? = extras,
           case .string(let id)? = record["id"], !id.isEmpty {
            return "id\u{1F}\(id)"
        }
        return "legacy\u{1F}\(timestamp)\u{1F}\(renderedRole ?? role)\u{1F}\(renderedContent ?? content)"
    }
}

public struct ChatSession: Sendable, Codable {
    public let id: String
    public let createdAt: String
    public let title: String?
    public let extras: JSONValue?

    public init(id: String, createdAt: String, title: String?, extras: JSONValue?) {
        self.id = id
        self.createdAt = createdAt
        self.title = title
        self.extras = extras
    }
}

public struct SessionHistoryReadStats: Sendable, Equatable {
    public let mode: String
    public let sourceBytes: Int64
    public let bytesRead: Int64
    public let linesRead: Int
    public let decodedCount: Int
    /// Rows present in the sampled bytes that could not be decoded as JSON.
    /// They remain on disk; this is visibility, never an automatic repair.
    public let malformedRowCount: Int
    /// Valid JSON rows that are not usable chat message objects.
    public let invalidShapeRowCount: Int
    public let returnedCount: Int
    /// L4-04: rows skipped because they belong to the CURRENT run. This is
    /// the number that separates "fresh session, nothing to load" from
    /// "history existed and decoded to nothing" in the turn trace.
    public let excludedByRunId: Int
    public let truncated: Bool

    public init(
        mode: String,
        sourceBytes: Int64 = 0,
        bytesRead: Int64 = 0,
        linesRead: Int = 0,
        decodedCount: Int = 0,
        malformedRowCount: Int = 0,
        invalidShapeRowCount: Int = 0,
        excludedByRunId: Int = 0,
        returnedCount: Int = 0,
        truncated: Bool = false
    ) {
        self.mode = mode
        self.sourceBytes = sourceBytes
        self.bytesRead = bytesRead
        self.linesRead = linesRead
        self.decodedCount = decodedCount
        self.malformedRowCount = malformedRowCount
        self.invalidShapeRowCount = invalidShapeRowCount
        self.excludedByRunId = excludedByRunId
        self.returnedCount = returnedCount
        self.truncated = truncated
    }
}

public struct SessionHistoryReadResult: Sendable {
    public let messages: [ChatMessage]
    public let stats: SessionHistoryReadStats

    public init(messages: [ChatMessage], stats: SessionHistoryReadStats) {
        self.messages = messages
        self.stats = stats
    }
}

private struct SessionHistoryLineReadResult: Sendable {
    let lines: [String]
    let sourceBytes: Int64
    let bytesRead: Int64
    let truncated: Bool
    /// The file exists but could not be opened or read. Without this, a
    /// failed read is `lines: []` — indistinguishable from an empty
    /// transcript, which the receipt then reports as a clean read.
    var readFailed: Bool = false
}

// MARK: - SessionHistoryReader

/// Reads daemon-format chat session history from disk. The daemon stores
/// chat sessions as a single JSON list at `data/chat/sessions.json` and
/// per-session messages at `data/chat/messages/<id>.jsonl`.
public actor SessionHistoryReader {
    private static let log = Logger(subsystem: "com.nativeagent.core", category: "session-history")
    /// Prompt assembly is a latency-sensitive projection over the canonical
    /// JSONL audit log. Never let a few giant tool receipts turn that projection
    /// back into an unbounded transcript scan.
    private static let promptHeadMaximumBytes = 64 * 1024
    /// The prompt tail must reach the window cursor's boundary or the head
    /// slides by BYTES while the cursor reports stable: at 192 KB the live
    /// session's last 96 rows (242 KB, tool results included) already
    /// overflowed it, the boundary row fell out of the tail, "boundary not
    /// found → drop nothing" made the head the tail's first row, and every
    /// appended row moved it — a full history rebuild on four of seven turns
    /// (2026-09-02, caught by the prefix digest chain). Compaction bounds the
    /// transcript, so 2 MB is a ceiling, not a working size.
    private static let promptTailMaximumBytes = 2 * 1024 * 1024
    private static let relevanceFullReadMaximumBytes = 128 * 1024
    private static let relevanceSampleMaximumBytes = 96 * 1024
    private static let relevanceSampleWindowCount = 8

    /// Internal so turn assembly resolves the model-window policy against
    /// the same data root as the history reader.
    let dataRoot: URL

    public init(dataRoot: URL = PersistenceCore.defaultDataRoot()) {
        self.dataRoot = dataRoot
        Self.cleanupRetiredMiddleIndex(dataRoot: dataRoot)
    }

    /// One-shot removal of the retired session_middle_index sqlite (W3a,
    /// 2026-07-01): its only reader (shadowCompare) is gone, so the derived
    /// index would otherwise sit orphaned on disk holding indexed transcript
    /// text that chat clears/deletes never touch. Idempotent; per-process
    /// once-gate keeps init cheap.
    private static let middleIndexCleanupOnce = NSLock()
    private nonisolated(unsafe) static var middleIndexCleanupRoots = Set<String>()
    private static func cleanupRetiredMiddleIndex(dataRoot: URL) {
        middleIndexCleanupOnce.lock()
        defer { middleIndexCleanupOnce.unlock() }
        let rootKey = dataRoot.standardizedFileURL.path
        guard middleIndexCleanupRoots.insert(rootKey).inserted else { return }
        let base = dataRoot
            .appendingPathComponent("chat", isDirectory: true)
            .appendingPathComponent("session_middle_index.sqlite")
        for suffix in ["", "-wal", "-shm"] {
            let path = URL(fileURLWithPath: base.path + suffix)
            try? FileManager.default.removeItem(at: path)
        }
    }

    /// Read messages for a session from `data/chat/messages/<id>.jsonl`.
    /// Returns chronological order (oldest first). If `limit` is set, only
    /// the LAST `limit` messages are returned (still in chronological order).
    ///
    /// `excludingRunId` is used by live chat turns after the user row has
    /// already been persisted. It prevents the current turn from being rendered
    /// as "prior" history inside the system prompt.
    public func messages(
        forSessionId id: String,
        limit: Int? = nil,
        excludingRunId: String? = nil
    ) async throws -> [ChatMessage] {
        try await messagesWithStats(
            forSessionId: id,
            limit: limit,
            excludingRunId: excludingRunId
        ).messages
    }

    public func messagesWithStats(
        forSessionId id: String,
        limit: Int? = nil,
        excludingRunId: String? = nil
    ) async throws -> SessionHistoryReadResult {
        guard let safeId = NativeAgentChatSessionID.normalizedPathComponent(id) else {
            return SessionHistoryReadResult(
                messages: [],
                stats: SessionHistoryReadStats(mode: "invalid_session_id")
            )
        }
        let excludedRunId = excludingRunId?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let shouldExcludeRun = excludedRunId?.isEmpty == false
        let path = dataRoot
            .appendingPathComponent("chat", isDirectory: true)
            .appendingPathComponent("messages", isDirectory: true)
            .appendingPathComponent("\(safeId).jsonl")
        guard FileManager.default.fileExists(atPath: path.path) else {
            return SessionHistoryReadResult(
                messages: [],
                stats: SessionHistoryReadStats(mode: "missing")
            )
        }
        if let limit, limit == 0 {
            return SessionHistoryReadResult(
                messages: [],
                stats: SessionHistoryReadStats(mode: "limit_zero")
            )
        }
        let lines: [String]
        let sourceBytes: Int64
        let bytesRead: Int64
        let truncatedRead: Bool
        let mode: String
        if let limit, limit > 0 {
            let result = Self.tailLinesResult(
                from: path,
                minimumLineCount: max(64, limit * 3)
            )
            lines = result.lines
            sourceBytes = result.sourceBytes
            bytesRead = result.bytesRead
            truncatedRead = result.truncated
            mode = "tail"
        } else {
            let data: Data
            do {
                data = try Data(contentsOf: path)
            } catch {
                return SessionHistoryReadResult(
                    messages: [],
                    stats: SessionHistoryReadStats(mode: "read_failed")
                )
            }
            let text = String(decoding: data, as: UTF8.self)
            lines = text
                .split(separator: "\n", omittingEmptySubsequences: true)
                .map(String.init)
            sourceBytes = Int64(data.count)
            bytesRead = Int64(data.count)
            truncatedRead = false
            mode = "full"
        }
        let decodeResult = Self.decodeMessages(
            from: lines,
            excludingRunId: shouldExcludeRun ? excludedRunId : nil
        )
        var msgs = decodeResult.messages
        let decodedCount = msgs.count
        var truncated = truncatedRead
        if let limit, limit >= 0, msgs.count > limit {
            msgs = Array(msgs.suffix(limit))
            truncated = true
        }
        return SessionHistoryReadResult(
            messages: msgs,
            stats: SessionHistoryReadStats(
                mode: mode,
                sourceBytes: sourceBytes,
                bytesRead: bytesRead,
                linesRead: lines.count,
                decodedCount: decodedCount,
                malformedRowCount: decodeResult.malformedRowCount,
                invalidShapeRowCount: decodeResult.invalidShapeRowCount,
                excludedByRunId: decodeResult.excludedByRunId,
                returnedCount: msgs.count,
                truncated: truncated
            )
        )
    }

    /// Read the first few messages plus a bounded tail. This lets the prompt
    /// renderer keep true opening anchors for continuity without loading an
    /// entire large JSONL transcript on every turn.
    public func promptMessages(
        forSessionId id: String,
        anchorLimit: Int = 3,
        tailLimit: Int,
        excludingRunId: String? = nil
    ) async throws -> [ChatMessage] {
        try await promptMessagesWithStats(
            forSessionId: id,
            anchorLimit: anchorLimit,
            tailLimit: tailLimit,
            excludingRunId: excludingRunId
        ).messages
    }

    public func promptMessagesWithStats(
        forSessionId id: String,
        anchorLimit: Int = 3,
        tailLimit: Int,
        excludingRunId: String? = nil
    ) async throws -> SessionHistoryReadResult {
        guard let safeId = NativeAgentChatSessionID.normalizedPathComponent(id) else {
            return SessionHistoryReadResult(
                messages: [],
                stats: SessionHistoryReadStats(mode: "invalid_session_id")
            )
        }
        let excludedRunId = excludingRunId?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let shouldExcludeRun = excludedRunId?.isEmpty == false
        let path = dataRoot
            .appendingPathComponent("chat", isDirectory: true)
            .appendingPathComponent("messages", isDirectory: true)
            .appendingPathComponent("\(safeId).jsonl")
        guard FileManager.default.fileExists(atPath: path.path) else {
            return SessionHistoryReadResult(
                messages: [],
                stats: SessionHistoryReadStats(mode: "missing")
            )
        }
        if tailLimit <= 0 {
            return SessionHistoryReadResult(
                messages: [],
                stats: SessionHistoryReadStats(mode: "tail_zero")
            )
        }
        let head = Self.headLinesResult(
            from: path,
            maximumLineCount: max(0, anchorLimit),
            maximumBytes: Self.promptHeadMaximumBytes
        )
        let tail = Self.tailLinesResult(
            from: path,
            minimumLineCount: max(64, tailLimit),
            maximumBytes: Self.promptTailMaximumBytes
        )
        let decodeResult = Self.decodeMessages(
            from: head.lines + tail.lines,
            excludingRunId: shouldExcludeRun ? excludedRunId : nil
        )
        let decoded = decodeResult.messages
        var seen: Set<String> = []
        var out: [ChatMessage] = []
        for msg in decoded {
            let key = msg.historyIdentity()
            guard !seen.contains(key) else { continue }
            seen.insert(key)
            out.append(msg)
        }
        return SessionHistoryReadResult(
            messages: out,
            stats: SessionHistoryReadStats(
                mode: "head_tail",
                sourceBytes: max(head.sourceBytes, tail.sourceBytes),
                bytesRead: head.bytesRead + tail.bytesRead,
                linesRead: head.lines.count + tail.lines.count,
                decodedCount: decoded.count,
                malformedRowCount: decodeResult.malformedRowCount,
                invalidShapeRowCount: decodeResult.invalidShapeRowCount,
                excludedByRunId: decodeResult.excludedByRunId,
                returnedCount: out.count,
                truncated: head.truncated || tail.truncated || decoded.count != out.count
            )
        )
    }

    /// Return bounded candidates for semantic "earlier session" ranking.
    /// Small transcripts are cheap enough to read exactly. Large transcripts
    /// are sampled through fixed-size interior windows; exact older wording is
    /// still available through the explicit search_chat_history tool. JSONL
    /// remains authoritative and this projection owns no stale sidecar state.
    public func relevanceMessagesWithStats(
        forSessionId id: String,
        excludingRunId: String? = nil
    ) async throws -> SessionHistoryReadResult {
        guard let safeId = NativeAgentChatSessionID.normalizedPathComponent(id) else {
            return SessionHistoryReadResult(
                messages: [],
                stats: SessionHistoryReadStats(mode: "invalid_session_id")
            )
        }
        let excludedRunId = excludingRunId?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let shouldExcludeRun = excludedRunId?.isEmpty == false
        let path = dataRoot
            .appendingPathComponent("chat", isDirectory: true)
            .appendingPathComponent("messages", isDirectory: true)
            .appendingPathComponent("\(safeId).jsonl")
        guard FileManager.default.fileExists(atPath: path.path) else {
            return SessionHistoryReadResult(
                messages: [],
                stats: SessionHistoryReadStats(mode: "missing")
            )
        }

        let sourceBytes = Self.fileSize(at: path)
        let lineRead: SessionHistoryLineReadResult
        let mode: String
        if sourceBytes <= Int64(Self.relevanceFullReadMaximumBytes) {
            lineRead = Self.allLinesResult(from: path)
            mode = "relevance_full_small"
        } else {
            lineRead = Self.sampledLinesResult(
                from: path,
                maximumBytes: Self.relevanceSampleMaximumBytes,
                windowCount: Self.relevanceSampleWindowCount
            )
            mode = "relevance_sampled"
        }
        let decodeResult = Self.decodeMessages(
            from: lineRead.lines,
            excludingRunId: shouldExcludeRun ? excludedRunId : nil
        )
        let decoded = decodeResult.messages
        var seen: Set<String> = []
        var out: [ChatMessage] = []
        out.reserveCapacity(decoded.count)
        for message in decoded {
            let key = message.historyIdentity()
            guard seen.insert(key).inserted else { continue }
            out.append(message)
        }
        return SessionHistoryReadResult(
            messages: out,
            stats: SessionHistoryReadStats(
                mode: lineRead.readFailed ? "read_failed" : mode,
                sourceBytes: lineRead.sourceBytes,
                bytesRead: lineRead.bytesRead,
                linesRead: lineRead.lines.count,
                decodedCount: decoded.count,
                malformedRowCount: decodeResult.malformedRowCount,
                invalidShapeRowCount: decodeResult.invalidShapeRowCount,
                excludedByRunId: decodeResult.excludedByRunId,
                returnedCount: out.count,
                truncated: lineRead.truncated || decoded.count != out.count
            )
        )
    }

    private nonisolated static func tailLinesResult(
        from path: URL,
        minimumLineCount: Int,
        maximumBytes: Int? = nil
    ) -> SessionHistoryLineReadResult {
        guard minimumLineCount > 0,
              let handle = try? FileHandle(forReadingFrom: path) else {
            return SessionHistoryLineReadResult(lines: [], sourceBytes: 0, bytesRead: 0, truncated: false)
        }
        defer { try? handle.close() }

        let chunkSize: UInt64 = 64 * 1024
        let fileSize = (try? handle.seekToEnd()) ?? 0
        guard fileSize > 0 else {
            return SessionHistoryLineReadResult(lines: [], sourceBytes: 0, bytesRead: 0, truncated: false)
        }

        var offset = fileSize
        var data = Data()
        var lineCount = 0
        let byteLimit = UInt64(max(1, maximumBytes ?? Int.max))
        while offset > 0 && lineCount <= minimumLineCount && UInt64(data.count) < byteLimit {
            let remainingBudget = byteLimit - UInt64(data.count)
            let readSize = min(chunkSize, offset, remainingBudget)
            guard readSize > 0 else { break }
            offset -= readSize
            do {
                try handle.seek(toOffset: offset)
                let chunk = try handle.read(upToCount: Int(readSize)) ?? Data()
                data.insert(contentsOf: chunk, at: 0)
            } catch {
                return SessionHistoryLineReadResult(
                    lines: [],
                    sourceBytes: Int64(fileSize),
                    bytesRead: Int64(data.count),
                    truncated: offset > 0
                )
            }
            lineCount = data.reduce(0) { count, byte in count + (byte == 0x0A ? 1 : 0) }
        }

        let text = String(decoding: data, as: UTF8.self)
        var lines = text
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map(String.init)
        if offset > 0, !lines.isEmpty {
            lines.removeFirst()
        }
        if lines.count > minimumLineCount {
            lines = Array(lines.suffix(minimumLineCount))
        }
        return SessionHistoryLineReadResult(
            lines: lines,
            sourceBytes: Int64(fileSize),
            bytesRead: Int64(data.count),
            truncated: offset > 0
        )
    }

    private nonisolated static func headLinesResult(
        from path: URL,
        maximumLineCount: Int,
        maximumBytes: Int? = nil
    ) -> SessionHistoryLineReadResult {
        guard maximumLineCount > 0,
              let handle = try? FileHandle(forReadingFrom: path) else {
            return SessionHistoryLineReadResult(lines: [], sourceBytes: 0, bytesRead: 0, truncated: false)
        }
        defer { try? handle.close() }

        let fileSize = (try? handle.seekToEnd()) ?? 0
        try? handle.seek(toOffset: 0)
        var data = Data()
        var lineCount = 0
        let byteLimit = max(1, maximumBytes ?? Int.max)
        while lineCount < maximumLineCount && data.count < byteLimit {
            let chunk = (try? handle.read(upToCount: min(16 * 1024, byteLimit - data.count))) ?? Data()
            if chunk.isEmpty { break }
            data.append(chunk)
            lineCount = data.reduce(0) { count, byte in count + (byte == 0x0A ? 1 : 0) }
        }
        var lines = String(decoding: data, as: UTF8.self)
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map(String.init)
        if lines.count > maximumLineCount {
            lines = Array(lines.prefix(maximumLineCount))
        }
        return SessionHistoryLineReadResult(
            lines: lines,
            sourceBytes: Int64(fileSize),
            bytesRead: Int64(data.count),
            truncated: UInt64(data.count) < fileSize
        )
    }

    private nonisolated static func allLinesResult(from path: URL) -> SessionHistoryLineReadResult {
        guard let data = try? Data(contentsOf: path) else {
            return SessionHistoryLineReadResult(
                lines: [], sourceBytes: 0, bytesRead: 0, truncated: false, readFailed: true
            )
        }
        let lines = String(decoding: data, as: UTF8.self)
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map(String.init)
        return SessionHistoryLineReadResult(
            lines: lines,
            sourceBytes: Int64(data.count),
            bytesRead: Int64(data.count),
            truncated: false
        )
    }

    /// Samples complete JSONL rows from evenly spaced interior windows. Any
    /// row crossing a window boundary is intentionally dropped rather than
    /// parsed as corrupt. Giant tool rows therefore consume at most one fixed
    /// window and cannot force the reader to chase their boundary.
    private nonisolated static func sampledLinesResult(
        from path: URL,
        maximumBytes: Int,
        windowCount: Int
    ) -> SessionHistoryLineReadResult {
        guard maximumBytes > 0,
              windowCount > 0,
              let handle = try? FileHandle(forReadingFrom: path) else {
            return SessionHistoryLineReadResult(
                lines: [], sourceBytes: 0, bytesRead: 0, truncated: false, readFailed: true
            )
        }
        defer { try? handle.close() }

        let fileSize = (try? handle.seekToEnd()) ?? 0
        guard fileSize > 0 else {
            return SessionHistoryLineReadResult(lines: [], sourceBytes: 0, bytesRead: 0, truncated: false)
        }
        let effectiveCount = min(windowCount, maximumBytes)
        let windowSize = max(1, maximumBytes / effectiveCount)
        let readableWindow = min(UInt64(windowSize), fileSize)
        let maximumStart = fileSize - readableWindow
        var lines: [String] = []
        var bytesRead: Int64 = 0

        for index in 1...effectiveCount {
            let fraction = Double(index) / Double(effectiveCount + 1)
            let start = UInt64(Double(maximumStart) * fraction)
            do {
                try handle.seek(toOffset: start)
                let data = try handle.read(upToCount: Int(readableWindow)) ?? Data()
                bytesRead += Int64(data.count)
                guard !data.isEmpty else { continue }

                var lower = data.startIndex
                var upper = data.endIndex
                if start > 0 {
                    guard let newline = data.firstIndex(of: 0x0A) else { continue }
                    lower = data.index(after: newline)
                }
                if start + UInt64(data.count) < fileSize {
                    guard let newline = data.lastIndex(of: 0x0A), newline >= lower else { continue }
                    upper = newline
                }
                guard lower < upper else { continue }
                lines.append(contentsOf: String(decoding: data[lower..<upper], as: UTF8.self)
                    .split(separator: "\n", omittingEmptySubsequences: true)
                    .map(String.init))
            } catch {
                continue
            }
        }
        return SessionHistoryLineReadResult(
            lines: lines,
            sourceBytes: Int64(fileSize),
            bytesRead: bytesRead,
            truncated: UInt64(bytesRead) < fileSize
        )
    }

    private nonisolated static func fileSize(at path: URL) -> Int64 {
        guard let value = try? path.resourceValues(forKeys: [.fileSizeKey]).fileSize else { return 0 }
        return Int64(value)
    }

    private nonisolated static func decodeMessages(
        from lines: [String],
        excludingRunId: String?
    ) -> (
        messages: [ChatMessage],
        excludedByRunId: Int,
        malformedRowCount: Int,
        invalidShapeRowCount: Int
    ) {
        var msgs: [ChatMessage] = []
        var excludedCount = 0
        var malformedCount = 0
        var invalidShapeCount = 0
        msgs.reserveCapacity(lines.count)
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { continue }
            guard let lineData = trimmed.data(using: .utf8),
                  let parsed = try? JSONValue.parse(lineData) else {
                malformedCount += 1
                continue
            }
            guard case .object(let obj) = parsed else {
                invalidShapeCount += 1
                continue
            }
            if let excludingRunId,
               message(parsed, hasRunId: excludingRunId) {
                excludedCount += 1
                continue
            }
            var role: String? = nil
            var content: String? = nil
            var timestamp: String = ""
            if case .string(let s)? = obj["role"] { role = s }
            if case .string(let s)? = obj["content"] { content = s }
            // 2026-09-06: legacy transcript rows spell the body `text`, the
            // same fallback `search_chat_history` already reads. Without it
            // this decoder counted those rows as invalid shape and dropped
            // them, so a legacy row could be FOUND by search and then be
            // unreadable by `read_chat_message`, which reads through here.
            else if case .string(let s)? = obj["text"] { content = s }
            if case .string(let s)? = obj["createdAt"] { timestamp = s }
            else if case .string(let s)? = obj["timestamp"] { timestamp = s }
            guard let role, let content else {
                invalidShapeCount += 1
                continue
            }
            msgs.append(ChatMessage(
                role: role,
                content: content,
                timestamp: timestamp,
                extras: parsed
            ))
        }
        return (msgs, excludedCount, malformedCount, invalidShapeCount)
    }

    private nonisolated static func message(_ value: JSONValue, hasRunId runId: String) -> Bool {
        guard case .object(let obj) = value else { return false }
        if case .string(let s)? = obj["runId"], s == runId { return true }
        if case .string(let s)? = obj["run_id"], s == runId { return true }
        if case .object(let metadata)? = obj["metadata"] {
            if case .string(let s)? = metadata["runId"], s == runId { return true }
            if case .string(let s)? = metadata["run_id"], s == runId { return true }
        }
        return false
    }

    /// Load session metadata from `data/chat/sessions.json`.
    public func session(id: String) async throws -> ChatSession? {
        let path = dataRoot
            .appendingPathComponent("chat", isDirectory: true)
            .appendingPathComponent("sessions.json")
        guard FileManager.default.fileExists(atPath: path.path) else { return nil }
        // A sessions.json that exists but cannot be read or parsed is NOT
        // "no such session" — the nil below reads that way to every caller,
        // so say so once in the log rather than silently.
        guard let data = try? Data(contentsOf: path) else {
            Self.log.error("sessions.json unreadable at \(path.path, privacy: .public)")
            return nil
        }
        guard let parsed = try? JSONValue.parse(data) else {
            Self.log.error("sessions.json is not valid JSON at \(path.path, privacy: .public)")
            return nil
        }
        guard case .array(let arr) = parsed else {
            Self.log.error("sessions.json is not a JSON array at \(path.path, privacy: .public)")
            return nil
        }
        for entry in arr {
            guard case .object(let obj) = entry else { continue }
            guard case .string(let entryId)? = obj["id"], entryId == id else { continue }
            var createdAt = ""
            var title: String? = nil
            if case .string(let s)? = obj["createdAt"] { createdAt = s }
            if case .string(let s)? = obj["title"] { title = s }
            return ChatSession(id: entryId, createdAt: createdAt, title: title, extras: entry)
        }
        return nil
    }
}

// MARK: - SwiftNativeTurnEngine + history threading

extension SwiftNativeTurnEngine {
    /// Build the per-turn context with prior conversation history threaded
    /// into the systemPrompt. History is appended AFTER the existing
    /// persona+pins+memory context (stable segments first, dynamic last —
    /// see the caching contract at the combine site below). If the session
    /// has no on-disk history (file missing) this degrades to the normal
    /// `buildTurnContext` shape — no error is raised. The two-line
    /// prior-session anchor is opt-in through the explicit-provider overload
    /// and lands on a session's FIRST turn only.
    public func buildTurnContextWithHistory(
        surface: String,
        userMessage: String,
        sessionId: String,
        historyLimit: Int = 40,
        historyReader: SessionHistoryReader = SessionHistoryReader()
    ) async throws -> TurnContext {
        return try await buildTurnContextWithHistory(
            surface: surface,
            userMessage: userMessage,
            sessionId: sessionId,
            historyLimit: historyLimit,
            historyReader: historyReader,
            personaOverride: nil,
            excludeHistoryRunId: nil
        )
    }

    /// Same as `buildTurnContextWithHistory(...)` but with a Mac UI
    /// `UserDefaults["chatPersona"]` override forwarded into the compiled
    /// persona packet. nil → no override (legacy callers unaffected).
    /// `sessionDigest` is an explicit opt-in: nil never builds or reads the
    /// prior-session anchor. Supplied, it is injected on the first turn only.
    public func buildTurnContextWithHistory(
        surface: String,
        userMessage: String,
        sessionId: String,
        historyLimit: Int,
        historyReader: SessionHistoryReader,
        personaOverride: String?,
        excludeHistoryRunId: String? = nil,
        sessionDigest: SessionDigestProvider? = nil,
        imageBlocks: [LLMContentBlock] = [],
        // Raw user text for relevance consumers (recall query, expression
        // cues, and the selection/embedding inputs downstream) when
        // `userMessage` carries turn-scoped wire riders (text-compat
        // tool-routing hint). nil → `userMessage`.
        queryUserMessage: String? = nil,
        // Turn-start instant for the clock line (see buildTurnContext) —
        // tool loops pass the same value every iteration.
        clockNowOverride: Date? = nil,
        toolSchemaCatalogSeed: TurnToolSchemaCatalogSeed? = nil,
        quietHoursSnapshot: TurnQuietHoursSnapshot? = nil
    ) async throws -> TurnContext {
        // Non-nil queryUserMessage is authoritative EVEN WHEN BLANK — an
        // attachment-only text-compat turn must not fall back to the hinted
        // wire message (gpt-5.5 review 2026-08-13, NEEDS-FIX #1).
        let queryMessage = queryUserMessage ?? userMessage
        var trace = ContextStageTrace()
        // Resolved before the transcript read: the read WIDTH depends on it
        // (see the tailLimit note below).
        let prefixShapeForRead = ConversationPrefixShape.override ?? .v1Legacy
        // v2 replays history as REAL messages behind a cache breakpoint, so
        // carrying more of it is nearly free and continuity is the whole point
        // — twice the v1 render window. The cursor fires at `* 1.15` (92) and
        // trims to `* 0.70` (56), so the live window sits between those.
        let prefixRowCap = max(1, historyLimit * 2)
        let prior: [ChatMessage]
        let middleCandidates: [ChatMessage]
        let priorStats: SessionHistoryReadStats
        let middleStats: SessionHistoryReadStats?
        if historyLimit > 0 {
            let priorResult = (try? await trace.measure(.promptRead) {
                try await historyReader.promptMessagesWithStats(
                    forSessionId: sessionId,
                    anchorLimit: 3,
                    // v2: the reader must NOT be the head. Its tail limit
                    // slides by a few rows every turn as the transcript grows,
                    // and on v2 the projection admits everything it returns —
                    // so the replayed prefix started at a different row every
                    // turn and the message history never cached (live
                    // CD041E66). The window cursor owns the head now; this
                    // number only has to be wide enough that the cursor's
                    // boundary is always INSIDE it. The cursor trims to
                    // `historyLimit * 0.70` rows and fires at `* 1.15`, so a
                    // 2x read leaves the boundary with most of the window
                    // beneath it — it can never slide out from under.
                    tailLimit: prefixShapeForRead == .v2Prefix
                        ? max(96, prefixRowCap * 2)
                        : max(64, historyLimit * 2),
                    excludingRunId: excludeHistoryRunId
                )
            }) ?? SessionHistoryReadResult(
                messages: [],
                stats: SessionHistoryReadStats(mode: "prompt_read_failed")
            )
            prior = priorResult.messages
            priorStats = priorResult.stats
            if prior.count > historyLimit || priorStats.sourceBytes > priorStats.bytesRead {
                let middleResult = (try? await trace.measure(.middleSample) {
                    try await historyReader.relevanceMessagesWithStats(
                        forSessionId: sessionId,
                        excludingRunId: excludeHistoryRunId
                    )
                }) ?? SessionHistoryReadResult(
                    messages: prior,
                    stats: SessionHistoryReadStats(mode: "middle_read_failed")
                )
                middleCandidates = middleResult.messages
                middleStats = middleResult.stats
            } else {
                middleCandidates = prior
                middleStats = nil
            }
        } else {
            prior = []
            middleCandidates = []
            priorStats = SessionHistoryReadStats(mode: "history_disabled")
            middleStats = nil
        }
        let expandedRecallQuery = await trace.measure(.recallQuery) {
            SessionHistoryPromptRenderer.recallQuery(
                userMessage: queryMessage,
                messages: prior
            )
        }
        let baseStartNs = DispatchTime.now().uptimeNanoseconds
        // Capture once at the outer turn boundary. The base builder owns the
        // receipt flag and this history wrapper owns final clock rendering;
        // both must observe the same preference bytes without a second read.
        let quietHoursWindow: TurnQuietHoursWindow?
        if let quietHoursSnapshot {
            quietHoursWindow = quietHoursSnapshot.window
        } else {
            quietHoursWindow = readTurnQuietHours()
        }
        let rawBase: TurnContext
        do {
            rawBase = try await buildTurnContext(
                surface: surface,
                userMessage: userMessage,
                personaOverride: personaOverride,
                imageBlocks: imageBlocks,
                recallQueryOverride: expandedRecallQuery,
                includeClockContext: false,
                sessionID: sessionId,
                recentTurns: prior.filter { $0.role == "user" || $0.role == "assistant" }.suffix(4).map(\.content),
                queryUserMessage: queryMessage,
                clockNowOverride: clockNowOverride,
                toolSchemaCatalogSeed: toolSchemaCatalogSeed,
                quietHoursSnapshot: quietHoursWindow
            )
            trace.record(.contextBase, since: baseStartNs)
        } catch {
            trace.record(.contextBase, since: baseStartNs)
            throw error
        }
        let base = await trace.measure(.digest) {
            await Self.injectingSessionDigest(
                into: rawBase,
                sessionId: sessionId,
                hasPriorHistory: !prior.isEmpty,
                provider: sessionDigest
            )
        }
        let naturalExpressionCue = naturalExpressionGuidanceEnabled
            ? NaturalExpressionGuidance.pendingCues(from: prior, userMessage: queryMessage)
            : nil
        trace.setFlag("expression.rhythmCuePending", naturalExpressionCue != nil)
        // Sweep R4 W3: the ONLY production caller of the history renderer, and
        // the first place in prompt assembly where the admitted model for this
        // turn is known (`buildTurnContext` resolved it above). That makes this
        // the interception point for window-aware budgets — everything the
        // renderer sizes flows from `ContextBudgetPolicy.resolve`. An unknown
        // or unresolvable model yields nil and the floor regime, i.e. exactly
        // the pre-policy budgets.
        let historyWindowTokens = ContextBudgetPolicy.windowTokens(
            forModel: base.modelId,
            providerID: LLMCallContext.providerId,
            dataRoot: historyReader.dataRoot
        )
        let historyBudget = ContextBudgetPolicy.resolve(
            windowTokens: historyWindowTokens,
            surface: surface
        )
        // v2Prefix (2026-09-01): the conversation ROWS leave the system block
        // and become real messages; the three DERIVED blocks (evidence
        // boundary + continuity state, middle sampling, reply-reference hint)
        // stay text in the volatile block. On v1Legacy this reads exactly as
        // it did — one default argument, no behavior change.
        // The BOUND shape, never `.effective`: the outer turn entry resolved it
        // once, and a second resolution here could disagree with what the
        // seeding and the provider call will use.
        let prefixShape = prefixShapeForRead
        let renderedHistory = await trace.measure(.render) {
            SessionHistoryPromptRenderer.renderDetailed(
                messages: prior,
                middleCandidates: middleCandidates,
                userMessage: queryMessage,
                surface: surface,
                historyLimit: historyLimit,
                windowTokens: historyWindowTokens,
                includeConversationHistory: prefixShape == .v1Legacy
            )
        }
        var historyMessages: [LLMMessage] = []
        var historyMessageChars = 0
        var historyWindowReceipt: HistoryWindowReceipt?
        var replayedRunIds = Set<String>()
        // CROSS-SESSION CONTINUITY. A session with no recollection of its own
        // borrows the conversation anchor's, read-only, at the head of the
        // replayed prefix — see `CarriedAnchorRecollection`. Seeded HERE and
        // nowhere else: `prior` itself is untouched, so nothing that persists,
        // ages, recalls or summarises this session ever sees the borrowed row.
        // v1Legacy is the rollback arm and stays byte-identical.
        // Borrowing another conversation's recollection IS remembering across
        // conversations, so the same switch gates it (Codex review 2026-09-05).
        let priorForPrefix = prefixShape == .v2Prefix
            && MemoryPolicyGate.crossSessionRecallEnabled(dataRoot: historyReader.dataRoot)
            ? CarriedAnchorRecollection.seeded(
                prior, sessionId: sessionId, dataRoot: historyReader.dataRoot
            )
            : prior
        trace.setFlag("prefix.carriedRecollection", priorForPrefix.count != prior.count)
        if prefixShape == .v2Prefix,
           let admission = SessionHistoryMessageProjection.admission(
            messages: priorForPrefix,
            historyLimit: historyLimit,
            surface: surface,
            windowTokens: historyWindowTokens
           ) {
            // The window head moves at most once per turn, oldest-first, and
            // never in a turn compaction already rewrote (see
            // HistoryWindowCursor). The turn-id guard inside the store makes a
            // tool loop's later iterations no-ops by construction, so a lane
            // that rebuilds context per iteration cannot slide the prefix
            // mid-turn.
            let cursorStore = await HistoryWindowCursorStoreRegistry.shared
                .store(dataRoot: historyReader.dataRoot)
            let advance = await cursorStore.advanceIfNeeded(
                sessionId: sessionId,
                admitted: admission.rows,
                budgetChars: historyBudget.historyChars,
                // The bound that actually bites: char pressure never fires
                // because the reader hands us a pre-trimmed slice. Enforced
                // ONCE per several turns instead of every turn.
                rowCap: prefixRowCap,
                turnId: TurnTraceContext.turnId,
                compactionRanThisTurn: HistoryWindowTurnFacts.compactionRanThisTurn
            )
            // Replay earlier turns' turn-scoped system messages ONLY where the
            // provider actually supports clear_at. Everywhere else the block was
            // never sent as a system message in the first place, so there is
            // nothing to keep byte-stable and replaying one would ADD a message
            // the previous request did not have — the same divergence, mirrored.
            // Replay is per-CAPABILITY, not per-lane: a turn-scoped block is
            // only replayable where clear_at is supported, and a tool-change
            // message only where mid-conversation tool changes are. Replaying
            // one the previous request never sent would ADD a message — the
            // same divergence, mirrored.
            let replaysClearAt = supportsMidConversationSystemClearAt(forModel: base.modelId)
            let replaysToolChanges = supportsMidConversationToolChanges(forModel: base.modelId)
            var archivedTurnMessages: [String: [LLMMessage]] = [:]
            let archive = await TurnVolatileArchiveRegistry.shared
                .archive(dataRoot: historyReader.dataRoot)
            if replaysClearAt || replaysToolChanges {
                archivedTurnMessages = await archive.load(sessionId: sessionId)
                    .mapValues { entries in
                        entries
                            .filter { $0.toolChanges.isEmpty ? replaysClearAt : replaysToolChanges }
                            .map(\.message)
                    }
                    .filter { !$0.value.isEmpty }
            }
            let projected = SessionHistoryMessageProjection.project(
                admission,
                cursor: advance.cursor,
                archivedTurnMessages: archivedTurnMessages
            )
            // Bound the sidecar to the window the prefix actually replays: when
            // the cursor drops a turn, its archived messages go with it.
            if !archivedTurnMessages.isEmpty {
                await archive.prune(
                    sessionId: sessionId, keeping: projected.replayedRunIds
                )
            }
            replayedRunIds = projected.replayedRunIds
            historyMessages = projected.messages
            historyMessageChars = projected.messages.reduce(0) { total, message in
                total + message.content.reduce(0) {
                    if case .text(let text) = $1 { return $0 + text.count }
                    return $0
                }
            }
            historyWindowReceipt = HistoryWindowReceipt(
                advanceCount: advance.cursor.advanceCount,
                slid: advance.didAdvance
            )
        }
        trace.setLabel("prefix.shapeVersion", prefixShape.rawValue)
        trace.setCount("prefix.historyMessageCount", historyMessages.count)
        trace.setCount("prefix.historyMessageChars", historyMessageChars)
        trace.setCount(
            "prefix.windowCursorAdvanceCount", historyWindowReceipt?.advanceCount ?? 0
        )
        trace.setFlag("prefix.windowSlid", historyWindowReceipt?.slid ?? false)
        trace.setCount("prefix.replayedTurnCount", replayedRunIds.count)
        trace.setCount("budget.windowTokens", historyWindowTokens ?? 0)
        trace.setFlag("budget.derived", historyBudget.isDerived)
        trace.setCount("budget.historyChars", historyBudget.historyChars)
        trace.setCount("budget.memoryBlockChars", historyBudget.memoryBlockChars)
        trace.setCount("budget.recallRowLimit", historyBudget.recallRowLimit)
        let historyBlock = renderedHistory.historyBlock
        trace.setCount("history.prompt.sourceBytes", priorStats.sourceBytes)
        trace.setCount("history.prompt.bytesRead", priorStats.bytesRead)
        trace.setCount("history.prompt.linesRead", priorStats.linesRead)
        trace.setCount("history.prompt.decoded", priorStats.decodedCount)
        trace.setCount("history.prompt.excludedByRunId", priorStats.excludedByRunId)
        trace.setCount("history.prompt.returned", priorStats.returnedCount)
        trace.setFlag("history.prompt.truncated", priorStats.truncated)
        if let middleStats {
            trace.setCount("history.middle.sourceBytes", middleStats.sourceBytes)
            trace.setCount("history.middle.bytesRead", middleStats.bytesRead)
            trace.setCount("history.middle.linesRead", middleStats.linesRead)
            trace.setCount("history.middle.decoded", middleStats.decodedCount)
            trace.setCount("history.middle.returned", middleStats.returnedCount)
            trace.setFlag("history.middle.fullRead", middleStats.mode == "full")
            trace.setFlag("history.middle.sampled", middleStats.mode == "relevance_sampled")
            trace.setFlag("history.middle.truncated", middleStats.truncated)
        } else {
            trace.setFlag("history.middle.fullRead", false)
            trace.setFlag("history.middle.sampled", false)
        }
        trace.setCount("history.priorCount", prior.count)
        trace.setCount("history.middleCandidateCount", middleCandidates.count)
        trace.setCount("history.recallQueryChars", expandedRecallQuery.count)
        trace.setCount("historyBlockChars", historyBlock?.count ?? 0)
        // The prior-session ANCHOR (two lines, one of them a pointer) is
        // injected at the HEAD of the DYNAMIC segment — after persona + REM
        // pins, before the dynamic recall/history mass — on the churning side
        // of the cache breakpoint. Its bytes change per session, so keeping it
        // out of the stable block is what lets the stable-end breakpoint hit
        // ACROSS sessions (see injectingSessionDigest). Injection happens
        // BEFORE the history guard below on purpose: the session's FIRST turn
        // has no renderable history and early-returns there, and the first
        // turn is the ONLY turn the anchor belongs on.
        guard let historyBlock else {
            let runtimeStartNs = DispatchTime.now().uptimeNanoseconds
            let clockedBase = await contextByAppendingCurrentTurnFacts(
                base,
                clockNowOverride: clockNowOverride,
                quietHours: quietHoursWindow,
                sessionID: sessionId
            )
            let finalBase = Self.contextBySettingNaturalExpressionCue(
                clockedBase,
                cue: naturalExpressionCue
            )
            trace.record(ContextHistoryStageName.contextClockRuntime, since: runtimeStartNs)
            trace.setCount("system.stableChars", finalBase.systemSegments?.stable.count ?? 0)
            trace.setCount("system.dynamicChars", finalBase.systemSegments?.dynamic.count ?? 0)
            trace.setCount("system.combinedChars", finalBase.systemPrompt?.count ?? 0)
            trace.setCount("userMessageChars", finalBase.userMessage.count)
            trace.setCount("toolSchemaCount", finalBase.toolSchemas.count)
            trace.emit(kind: "context.history.summary", surface: surface)
            // Turn Inspector W2: emit assembly.stage for the no-history case
            // too (a session's FIRST turn renders no history) — SIZES ONLY.
            Self.fireAssemblyStageEvent(
                surface: surface,
                segments: finalBase.systemSegments,
                combinedSystemPrompt: finalBase.systemPrompt,
                historyBlock: nil,
                userMessage: finalBase.userMessage,
                recalledCount: finalBase.recalled.count
            )
            return finalBase
        }
        // CACHING CONTRACT (U1 step 2, 2026-06-10): segment order is
        // STABLE → SEMI-STABLE → DYNAMIC. Provider prompt caches are prefix
        // matches, so the system prompt must keep its stable bytes first:
        //   [persona packet (identity block handled by the adapter)]
        //   → [REM pins]                     (the STABLE, cacheable mass)
        //   → [session digest (U3 item 8, per-session — DYNAMIC head)]
        //   → [memory recall]                (base.systemPrompt, in order)
        //   → [history block]                (per-turn dynamic, appended)
        // The user message stays in messages[]. Do NOT prepend dynamic
        // content above the persona — history at byte 0 churns the entire
        // prefix every turn and defeats prompt caching. History at the TAIL
        // stays in a high-attention zone (end of system prompt, adjacent to
        // the user message), so recency weighting is preserved.
        let combinedWithoutClock: String
        if let existing = base.systemPrompt, !existing.isEmpty {
            combinedWithoutClock = existing + "\n\n" + historyBlock
        } else {
            combinedWithoutClock = historyBlock
        }
        // U1 step 2b/3b: the history block is per-turn DYNAMIC content, so
        // it joins the dynamic segment tail; the stable segment
        // (persona+pins) is untouched.
        // INVARIANT: systemPrompt == segments.stable + "\n\n" + segments.dynamic
        //            (i.e. combined == segments.combined — empty segments
        //            collapse the separator). The Anthropic adapters verify
        //            this byte-for-byte before splitting system blocks, so
        //            the split can never change model-visible content.
        let segmentsWithoutClock: SystemPromptSegments? = base.systemSegments.map { seg in
            SystemPromptSegments(
                stable: seg.stable,
                stableSuffix: seg.stableSuffix,
                dynamic: seg.dynamic.isEmpty
                    ? historyBlock
                    : seg.dynamic + "\n\n" + historyBlock
            )
        }
        let contextWithHistory = TurnContext(
            surface: base.surface,
            personaID: base.personaID,
            personaDocs: base.personaDocs,
            recalled: base.recalled,
            modelId: base.modelId,
            reasoningEffort: base.reasoningEffort,
            providerId: base.providerId,
            serviceTier: base.serviceTier,
            toolsAvailable: base.toolsAvailable,
            systemPrompt: combinedWithoutClock,
            userMessage: base.userMessage,
            toolSchemas: base.toolSchemas,
            systemSegments: segmentsWithoutClock,
            imageBlocks: base.imageBlocks,
            fluidContextTurn: base.fluidContextTurn,
            naturalExpressionCue: base.naturalExpressionCue,
            historyMessages: historyMessages,
            turnVolatileBlock: base.turnVolatileBlock,
            historyWindowReceipt: historyWindowReceipt
        )
        let runtimeStartNs = DispatchTime.now().uptimeNanoseconds
        let clocked = await contextByAppendingCurrentTurnFacts(
            contextWithHistory,
            clockNowOverride: clockNowOverride,
            quietHours: quietHoursWindow,
            sessionID: sessionId
        )
        let finalContext = Self.contextBySettingNaturalExpressionCue(
            clocked,
            cue: naturalExpressionCue
        )
        trace.record(ContextHistoryStageName.contextClockRuntime, since: runtimeStartNs)
        trace.setCount("system.stableChars", finalContext.systemSegments?.stable.count ?? 0)
        trace.setCount("system.dynamicChars", finalContext.systemSegments?.dynamic.count ?? 0)
        trace.setCount("system.combinedChars", finalContext.systemPrompt?.count ?? 0)
        trace.setCount("userMessageChars", finalContext.userMessage.count)
        trace.setCount("toolSchemaCount", finalContext.toolSchemas.count)
        trace.emit(kind: "context.history.summary", surface: surface)
        // Turn Inspector W2: observe the per-turn system prompt that was just
        // assembled and fire ONE assembly.stage event carrying segment SIZES
        // (char counts) only — NEVER the content (the system prompt is the most
        // secret-dense string in the app). Read-only: this does NOT reorder,
        // rebuild, or touch the assembly (U1 invariant) — it measures `combined`
        // / `segments` / `historyBlock` AFTER they are built.
        Self.fireAssemblyStageEvent(
            surface: surface,
            segments: finalContext.systemSegments,
            combinedSystemPrompt: finalContext.systemPrompt,
            historyBlock: historyBlock,
            userMessage: finalContext.userMessage,
            recalledCount: finalContext.recalled.count,
            shapeVersion: prefixShape.rawValue,
            historyMessageCount: historyMessages.count,
            historyMessageChars: historyMessageChars,
            windowCursorAdvanceCount: historyWindowReceipt?.advanceCount ?? 0,
            windowSlid: historyWindowReceipt?.slid ?? false
        )
        return finalContext
    }

    /// THE per-turn context build. One owner, two callers.
    ///
    /// `streamTurn` used to inline this sequence and the text-compat lane had
    /// no way to reach it, because the volatile block IS the context's dynamic
    /// segment: v2 has to know the context before it can build the message
    /// array that context is an argument to. Rather than copy four steps into
    /// a second place (where they would drift), the sequence lives here and
    /// `streamTurn` calls it — so a context prepared by the lane and one built
    /// inside the stream are the same bytes by construction.
    ///
    /// The lane prepares it and passes it back through `preBuiltContext`; the
    /// stream calls it when no caller supplied one. Order is load-bearing:
    /// history-threaded build → turn-plan hint → runtime context (cognitive
    /// capsule) → lazy tool filter.
    func prepareTurnContext(
        surface: String,
        userMessage: String,
        sessionId: String?,
        historyLimit: Int,
        historyReader: SessionHistoryReader,
        personaOverride: String?,
        excludeHistoryRunId: String?,
        imageBlocks: [LLMContentBlock],
        queryUserMessage: String?,
        clockNowOverride: Date?,
        toolSchemaCatalogSeed: TurnToolSchemaCatalogSeed?,
        quietHoursSnapshot: TurnQuietHoursSnapshot?,
        turnPlan: TurnPlan?,
        runtimeContext: String?,
        turnActiveTools: Set<String>?,
        pinnedActiveTools: Set<String>?,
        pinnedContract: SessionToolContract? = nil
    ) async throws -> TurnContext {
        // Bound explicitly rather than around a Task: both callers invoke this
        // as a plain async call on their own task, so push/pop stays LIFO on
        // that task's own stack. `streamTurn` already holds the same binding
        // around its Task, where re-binding the identical value is a no-op.
        try await LLMCallContext.$turnActiveTools.withValue(turnActiveTools) {
            // Wave 16: when a sessionId is supplied, thread prior conversation
            // history through the context so streaming is coherent across
            // turns (Mac UI's normal sends carry a sessionId). When nil, fall
            // back to context-only (one-shot) — gpt-5.5 review flagged the
            // history-less path as a behavioral regression vs the daemon's
            // /v1/chat/stream, which threaded history.
            let rawCtx: TurnContext
            if let sessionId, !sessionId.isEmpty {
                rawCtx = try await buildTurnContextWithHistory(
                    surface: surface,
                    userMessage: userMessage,
                    sessionId: sessionId,
                    historyLimit: historyLimit,
                    historyReader: historyReader,
                    personaOverride: personaOverride,
                    excludeHistoryRunId: excludeHistoryRunId,
                    // See the structured sibling: first-turn-only prior-session
                    // anchor, rooted at the history reader's data root.
                    sessionDigest: SessionDigestProvider(dataRoot: historyReader.dataRoot),
                    imageBlocks: imageBlocks,
                    queryUserMessage: queryUserMessage,
                    clockNowOverride: clockNowOverride,
                    toolSchemaCatalogSeed: toolSchemaCatalogSeed,
                    quietHoursSnapshot: quietHoursSnapshot
                )
            } else {
                rawCtx = try await buildTurnContext(
                    surface: surface,
                    userMessage: userMessage,
                    personaOverride: personaOverride,
                    imageBlocks: imageBlocks,
                    queryUserMessage: queryUserMessage,
                    clockNowOverride: clockNowOverride,
                    toolSchemaCatalogSeed: toolSchemaCatalogSeed,
                    quietHoursSnapshot: quietHoursSnapshot
                )
            }
            let plannedCtx = Self.contextByAppendingTurnPlanHint(rawCtx, turnPlan: turnPlan)
            let runtimeCtx = Self.contextByAppendingRuntimeContext(
                plannedCtx,
                runtimeContext: runtimeContext ?? ""
            )
            // 2026-06-08 lazy-tool-skill-loading close-out: the Anthropic OAuth
            // compat path goes through here too — apply the SAME per-session
            // lazy filter the structured tool loop applies so this surface
            // doesn't ship the full eager catalog. Empty/nil sessionId falls
            // closed to alwaysOnCore + MCP only. (C3 shared helper.)
            return await lazyFilteredTurnContext(
                runtimeCtx,
                sessionId: sessionId,
                pinnedActiveTools: pinnedActiveTools,
                pinnedContract: pinnedContract
            )
        }
    }

    /// Turn Inspector W2 — assembly.stage emitter (SIZES AND COUNTS ONLY).
    ///
    /// Fires ONE `assembly.stage` event per turn carrying char counts of the
    /// already-built system-prompt segments + cache-relevant metadata. NEVER
    /// the content — the system prompt is the most secret-dense string in the
    /// app, so this payload is structurally counts-only (no string leaf carries
    /// prompt text). Skipped when no turn is bound (the `fireFromContext`
    /// contract). Fire-and-forget, drop-on-backpressure — zero hot-path cost
    /// beyond the bounded emission.
    ///
    /// Segment sizes reported:
    ///   - stable: persona packet + REM pins (+ session digest) — the cacheable
    ///     mass. Reported as ONE count because the combine site sees it as one
    ///     string (`segments.stable`); the persona/pins split happens upstream
    ///     in `buildTurnContext` and is not re-derivable here without rebuilding.
    ///   - dynamicNonHistory: the dynamic segment MINUS the history block
    ///     (i.e. memory recall + per-turn extras).
    ///   - history: the rendered session-history block.
    ///   - current: the current user message.
    ///   - systemTotal: the full combined system prompt length.
    /// Plus `recalledCount` (memory recall hit count) and `breakpointZone`
    /// (whether a stable/dynamic split exists, which drives Anthropic
    /// cache_control breakpoint placement).
    nonisolated static func fireAssemblyStageEvent(
        surface: String,
        segments: SystemPromptSegments?,
        combinedSystemPrompt: String?,
        historyBlock: String?,
        userMessage: String,
        recalledCount: Int,
        // v2Prefix receipts. Sizes and a version label only — never content.
        shapeVersion: String = ConversationPrefixShape.v1Legacy.rawValue,
        historyMessageCount: Int = 0,
        historyMessageChars: Int = 0,
        windowCursorAdvanceCount: Int = 0,
        windowSlid: Bool = false
    ) {
        let systemTotal = combinedSystemPrompt?.count ?? 0
        let stableChars = segments?.stable.count ?? 0
        let dynamicChars = segments?.dynamic.count ?? 0
        let historyChars = historyBlock?.count ?? 0
        // The dynamic segment includes the history block when present; report
        // the recall/extras portion separately so the Inspector can show the
        // recall mass distinct from the (recency-weighted) history mass.
        let dynamicNonHistoryChars = max(0, dynamicChars - historyChars
            - (historyChars > 0 && dynamicChars > historyChars ? 2 : 0)) // "\n\n" join
        let payload: [String: JSONValue] = [
            "stableChars": .int(Int64(stableChars)),
            "dynamicChars": .int(Int64(dynamicChars)),
            "dynamicNonHistoryChars": .int(Int64(dynamicNonHistoryChars)),
            "historyChars": .int(Int64(historyChars)),
            "currentChars": .int(Int64(userMessage.count)),
            "systemTotalChars": .int(Int64(systemTotal)),
            "recalledCount": .int(Int64(recalledCount)),
            // Cache-relevant: a non-nil split means the adapter can place the
            // sys cache_control breakpoint at the end of the STABLE mass (the
            // U1 segmented layout). Segment count == number of cacheable
            // system regions the breakpoint logic distinguishes.
            "segmented": .bool(segments != nil),
            "segmentCount": .int(Int64(segments != nil ? 2 : 1)),
            // v2Prefix: how much of the turn now rides as REPLAYED MESSAGES
            // instead of system-prompt text, and whether the window head moved.
            "shapeVersion": .string(shapeVersion),
            "historyMessageCount": .int(Int64(historyMessageCount)),
            "historyMessageChars": .int(Int64(historyMessageChars)),
            "windowCursorAdvanceCount": .int(Int64(windowCursorAdvanceCount)),
            "windowSlid": .bool(windowSlid),
        ]
        TurnTraceBus.fireFromContext(
            kind: "assembly.stage",
            surface: surface,
            payload: .object(payload)
        )
    }

    /// U3 wave-2 item 8: inject the per-session digest at the HEAD of the
    /// DYNAMIC segment. Rebuilds `systemPrompt` from the new segments so the
    /// adapter-verified invariant `systemPrompt == stable + "\n\n" + dynamic`
    /// holds by construction. Fail-open on every edge:
    ///   - no systemSegments on the context → no safe mid-string insertion
    ///     point → return the context unchanged (legacy combined behavior)
    ///   - provider returns nil/empty (fresh session, source errors, blank
    ///     sessionId) → unchanged.
    ///
    /// CACHE-CORRECTNESS (2026-07-24): this used to append to the END of the
    /// STABLE segment, on the reasoning that "the provider caches per session,
    /// so the injected bytes are identical on every turn of the session".
    /// That premise is FALSE. Anthropic's prompt cache is an exact-prefix
    /// match scoped to the ORGANIZATION, not to a session — a prefix written
    /// by session A is readable by session B iff the bytes match. The digest
    /// describes the PREVIOUS session (its title, message count, end
    /// timestamp, and activity list), so it changes on every new session and
    /// on background activity. Sitting inside the stable segment, it churned
    /// the tail of the block the stable-end cache_control breakpoint covers,
    /// so that breakpoint could only ever hit WITHIN one session and was a
    /// guaranteed miss ACROSS sessions. Measured: two identical bridge turns
    /// 7s apart shared 10,605 bytes of stable prefix and then diverged inside
    /// the "# Since last session" block — cacheRead=0 on both, paying the
    /// 1.25x write premium every turn and never collecting the 0.1x read.
    ///
    /// Moving it to the head of the DYNAMIC segment is byte-identical in
    /// `combined` for all four emptiness cases (empty segments collapse the
    /// "\n\n" separator, so stable+"\n\n"+digest+"\n\n"+dynamic is produced
    /// either way) — the model sees exactly the same system prompt, in the
    /// same order. Only the breakpoint boundary moves: the stable block is
    /// now persona packet + REM pins ONLY, which is genuinely invariant
    /// across sessions and therefore cacheable across them.
    nonisolated static func injectingSessionDigest(
        into base: TurnContext,
        sessionId: String,
        hasPriorHistory: Bool,
        provider: SessionDigestProvider?
    ) async -> TurnContext {
        // Guard before provider/cache access: a surface that did not ask for
        // the carry-over never reads or writes anchor bytes.
        guard let provider else { return base }
        // FIRST TURN ONLY. The anchor exists to hand a BRAND-NEW session the
        // thread it was cut from. From turn 2 the session's own history block
        // carries that thread, and re-injecting two lines that point at a
        // conversation she has already moved past is duplication paid for on
        // every turn. `prior` rows are the same signal the history guard below
        // uses — non-empty prior ⇒ a history block renders — and the current
        // turn's own user row is excluded by runId, so turn 1 is empty here.
        guard !hasPriorHistory else { return base }
        guard let seg = base.systemSegments else { return base }
        guard let digest = await provider.digest(forSessionId: sessionId),
              !digest.isEmpty else { return base }
        let dynamic = seg.dynamic.isEmpty ? digest : digest + "\n\n" + seg.dynamic
        let segments = SystemPromptSegments(
            stable: seg.stable, stableSuffix: seg.stableSuffix, dynamic: dynamic
        )
        return TurnContext(
            surface: base.surface,
            personaID: base.personaID,
            personaDocs: base.personaDocs,
            recalled: base.recalled,
            modelId: base.modelId,
            reasoningEffort: base.reasoningEffort,
            providerId: base.providerId,
            serviceTier: base.serviceTier,
            toolsAvailable: base.toolsAvailable,
            systemPrompt: segments.combined,
            userMessage: base.userMessage,
            toolSchemas: base.toolSchemas,
            systemSegments: segments,
            imageBlocks: base.imageBlocks,
            fluidContextTurn: base.fluidContextTurn,
            naturalExpressionCue: base.naturalExpressionCue,
            historyMessages: base.historyMessages,
            turnVolatileBlock: base.turnVolatileBlock,
            historyWindowReceipt: base.historyWindowReceipt
        )
    }
}
