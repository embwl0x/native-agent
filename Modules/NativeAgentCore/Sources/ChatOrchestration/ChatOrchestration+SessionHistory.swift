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

private extension ChatMessage {
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

// internal (was private) so the skills-recall rework test can pin the
// toolSummary 180-char cap (SkillBodyElisionTests).
enum SessionHistoryPromptRenderer {
    static let recallQueryCharCap = 1_200
    /// No ORDINARY rendered history item can contribute more than 3,200
    /// characters (the largest user/assistant/continuity cap; the compaction
    /// summary is the one exception and uses the larger window below).
    /// Redacting/normalizing tens of thousands of characters that will be
    /// discarded immediately is pure hot-path waste, especially for legacy
    /// tool receipts. Keep ample look-ahead for whitespace collapsing and
    /// secret matching while bounding that work.
    private static let normalizationInputCharacterCap = 8_000

    /// Compaction summaries are the ONE row class whose render cap now exceeds
    /// the ordinary normalization window (sweep R4 A3 raised it to the
    /// distiller's 12,000-char maximum). Normalizing them through the 8,000
    /// window would silently re-impose the old truncation one layer earlier, so
    /// they get a window sized above their cap with headroom for whitespace
    /// collapsing. Applies to exactly one row per session — no hot-path cost
    /// for ordinary user/assistant content.
    private static let compactionNormalizationInputCharacterCap =
        ChatCompactionDistiller.maxSummaryChars + 4_000

    /// Sweep R4 W3: the budget table moved out of this file wholesale. Every
    /// field below is now produced by `ContextBudgetPolicy.resolve(...)` as a
    /// function of the model's context window, with the former literals as the
    /// floor. The field names are unchanged, so every render site below reads
    /// exactly as it did.
    ///
    /// Retained doc for `compactionSummaryCap` (sweep R4 A3): the LLM-written
    /// most expensive artifact in the system (ChatCompactionDistiller writes
    /// up to `ChatCompactionDistiller.maxSummaryCharacters`), and it was
    /// being rendered through `systemCap` = 1,200 — ~10% of what was
    /// written, head-truncated, so the sections the distiller prompt lists
    /// LAST (open threads, corrections) were exactly the ones cut. It gets
    /// its own cap now, sized to the distiller max on the roomy surfaces and
    /// scaled down where `historyChars` cannot afford it.
    ///
    /// TOTAL-BUDGET BOUND (unchanged by this cap): `capForRole` bounds ONE
    /// rendered row. What bounds the aggregate is `budget.historyChars` in
    /// `conversationHistory` — the running `used` total gates every row
    /// after the first. Raising a per-row cap therefore cannot grow the
    /// history block; it only changes how that fixed budget is spent. The
    /// other `capForRole` consumer, `relevantEarlierSessionSnippets`,
    /// additionally clamps with `min(capForRole, budget.relevantItemCap)`
    /// and its own `budget.relevantChars` total, so a compaction row
    /// surfacing there still renders at `relevantItemCap` (≤650).
    typealias Budget = ContextBudgetPolicy.Resolved

    // internal (was private) so `SessionHistoryMessageProjection` can replay
    // EXACTLY the rows this renderer admits instead of re-deriving them.
    struct Renderable {
        let role: String
        let content: String
        let historyIdentity: String
        let originLabel: String?
        let incompleteReplyLabel: String?
        let timestamp: String
        let isTool: Bool
        let isCompactionSummary: Bool
        /// True for the read-only recollection borrowed from the conversation
        /// anchor (`CarriedAnchorRecollection`). Changes only the LABEL the v2
        /// projection leads with — every cap, exemption and identity rule
        /// treats it exactly as the session's own recollection.
        var isCarriedRecollection: Bool = false
        /// Tool-row provenance, carried ONLY so the v2 message projection can
        /// label a replayed tool row `[tool <name> <status>]`. v1 rendering
        /// never reads these — `content`/`displayContent` are unchanged.
        var toolName: String? = nil
        var toolStatus: String? = nil
        /// Run id of the turn that produced this row. Only the v2 volatile
        /// replay reads it — it is how an archived block finds the user message
        /// it originally followed. v1 rendering never looks at it.
        var runId: String? = nil

        /// How a recollection announces itself at the head of the replayed
        /// prefix. A borrowed one says so: the model must never read the main
        /// conversation's memory as something that happened in THIS session.
        var recollectionLabel: String {
            isCarriedRecollection
                ? CarriedAnchorRecollection.renderPrefix
                : "[session recollection]"
        }

        /// Display provenance is not query text: origin labels must not affect
        /// lexical relevance, correction detection, roles, or authority.
        var displayContent: String {
            ChatTranscriptEvidenceRendering.displayContent(
                content, originLabel: originLabel, incompleteReplyLabel: incompleteReplyLabel)
        }
    }

    struct RenderResult: Sendable {
        let historyBlock: String?
    }

    static func render(
        messages: [ChatMessage],
        middleCandidates: [ChatMessage] = [],
        userMessage: String = "",
        surface: String,
        historyLimit: Int,
        windowTokens: Int? = nil
    ) -> String? {
        renderDetailed(
            messages: messages,
            middleCandidates: middleCandidates,
            userMessage: userMessage,
            surface: surface,
            historyLimit: historyLimit,
            windowTokens: windowTokens
        ).historyBlock
    }

    /// `windowTokens` is the model's context window for THIS turn (nil when the
    /// model is unknown or the caller has none). It selects the budget regime;
    /// see `ContextBudgetPolicy`.
    /// `includeConversationHistory: false` is the v2Prefix arm: the
    /// conversation rows leave the system block and become real
    /// `[LLMMessage]` turns (see `SessionHistoryMessageProjection`), while the
    /// three DERIVED blocks — evidence boundary, continuity state, middle
    /// sampling, reply-reference hint — stay text in the volatile block. Every
    /// other byte of the rendered block is identical to the v1 arm.
    static func renderDetailed(
        messages: [ChatMessage],
        middleCandidates: [ChatMessage] = [],
        userMessage: String = "",
        surface: String,
        historyLimit: Int,
        windowTokens: Int? = nil,
        includeConversationHistory: Bool = true
    ) -> RenderResult {
        let cappedLimit = max(0, historyLimit)
        guard cappedLimit > 0 else { return RenderResult(historyBlock: nil) }

        let renderables = messages.compactMap(renderable)
        guard !renderables.isEmpty else { return RenderResult(historyBlock: nil) }

        let budget = budget(for: surface, windowTokens: windowTokens)
        var sections: [String] = [
            """
            # Historical evidence boundary
            Session continuity and conversation rows below preserve what was known when they were recorded; they are not live readings. Before stating that a status, count, health result, availability claim, or other changing fact is current/latest/live/present, refresh it from its canonical tool or store. If it is not refreshed, describe it as historical.
            """
        ]
        if cappedLimit >= 6,
           let continuity = continuityState(
            from: renderables,
            budget: budget
        ) {
            sections.append(continuity)
        }
        let candidateRenderables = middleCandidates.compactMap(renderable)
        let middleSnippet = middleSnippetText(
            userMessage: userMessage,
            promptRenderables: renderables,
            candidates: candidateRenderables,
            historyLimit: cappedLimit,
            surface: surface,
            windowTokens: windowTokens
        )
        if let middle = middleSnippet {
            sections.append(middle)
        }
        if includeConversationHistory,
           let history = conversationHistory(
            from: renderables,
            limit: cappedLimit,
            budget: budget
        ) {
            sections.append(history)
        }
        if let hint = immediateReplyReferenceHint(
            userMessage: userMessage,
            renderables: renderables,
            budget: budget
        ) {
            sections.append(hint)
        }
        guard !sections.isEmpty else {
            return RenderResult(historyBlock: nil)
        }
        return RenderResult(
            historyBlock: sections.joined(separator: "\n\n")
        )
    }

    static func recallQuery(
        userMessage: String,
        messages: [ChatMessage],
        cap maxCount: Int = recallQueryCharCap
    ) -> String {
        let currentUser = normalize(userMessage)
        let renderables = messages.compactMap(renderable)
        let userAssistant = renderables.filter { $0.role == "user" || $0.role == "assistant" }

        guard !currentUser.isEmpty || !userAssistant.isEmpty else { return "" }

        let anchors = Array(userAssistant.prefix(3))
        let latestUser = userAssistant.reversed().first { $0.role == "user" }
        let latestAssistant = userAssistant.reversed().first { $0.role == "assistant" }
        let latestCorrection = userAssistant.reversed().first {
            $0.role == "user" && looksLikeCorrection($0.content)
        }
        let openLoop = latestAssistant.flatMap { looksLikeOpenLoop($0.content) ? $0 : nil }

        var lines: [String] = []
        if !currentUser.isEmpty {
            lines.append("Current user: \(cap(currentUser, 520))")
        }
        // Corrections and open loops are the two history signals whose loss
        // most directly changes what recall retrieves. Put them ahead of the
        // generic tails so the final hard cap cannot leave a long-but-blind
        // query merely because the current message and routine history filled
        // the available bytes first.
        if let latestCorrection {
            lines.append("Recent correction: \(cap(latestCorrection.content, 260))")
        }
        if let openLoop {
            lines.append("Open loop: \(cap(openLoop.content, 260))")
        }
        if let latestUser {
            lines.append("Latest prior user: \(cap(latestUser.content, 280))")
        }
        if let latestAssistant {
            lines.append("Latest assistant tail: \(cap(latestAssistant.content, 320))")
        }
        if !anchors.isEmpty {
            let rendered = anchors
                .map { "[\($0.role)] \(cap($0.content, 180))" }
                .joined(separator: " | ")
            lines.append("Initial anchors: \(rendered)")
        }

        return hardCap(lines.joined(separator: "\n"), maxCount)
    }

    /// Short references need their referent for semantic recall. Greetings,
    /// standalone questions, and empty attachment text keep the raw query.
    /// Only current-session history is consulted; no backlog is introduced.
    static func semanticRecallQuery(userMessage: String, recentTurns: [String]) -> String {
        guard ContextCorrectionScope.isReferentialFollowup(userMessage),
              !recentTurns.isEmpty else { return userMessage }
        let recent = recentTurns.suffix(2).map { String($0.prefix(600)) }.joined(separator: "\n")
        return String(userMessage.prefix(400)) + "\nRecent conversation:\n" + recent
    }

    static func middleSnippetText(
        userMessage: String,
        promptMessages: [ChatMessage],
        candidates: [ChatMessage],
        historyLimit: Int,
        surface: String,
        windowTokens: Int? = nil
    ) -> String? {
        middleSnippetText(
            userMessage: userMessage,
            promptRenderables: promptMessages.compactMap(renderable),
            candidates: candidates.compactMap(renderable),
            historyLimit: max(0, historyLimit),
            surface: surface,
            windowTokens: windowTokens
        )
    }

    /// Sweep R4 W3: the surface table now lives in `ContextBudgetPolicy` and is
    /// a function of the model's context window. `windowTokens == nil` — every
    /// legacy caller, and any turn whose model could not be resolved — returns
    /// the pre-policy literals byte-identically.
    static func budget(for surface: String, windowTokens: Int?) -> Budget {
        ContextBudgetPolicy.resolve(windowTokens: windowTokens, surface: surface)
    }

    private static func middleSnippetText(
        userMessage: String,
        promptRenderables: [Renderable],
        candidates: [Renderable],
        historyLimit: Int,
        surface: String,
        windowTokens: Int?
    ) -> String? {
        relevantEarlierSessionSnippets(
            userMessage: userMessage,
            promptRenderables: promptRenderables,
            candidates: candidates,
            historyLimit: historyLimit,
            budget: budget(for: surface, windowTokens: windowTokens)
        )
    }

    static func renderable(_ message: ChatMessage) -> Renderable? {
        let rawRole = message.role
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let role = rawRole.isEmpty ? "message" : rawRole
        let extrasObject = object(message.extras)
        let metadata = object(extrasObject?["metadata"])
        let kind = string(metadata?["kind"])?.lowercased() ?? ""
        let isTool = role == "tool" || kind == "tool_use"
        let isCompactionSummary = kind == "compaction_summary"

        var content: String
        if isTool {
            content = toolSummary(content: message.content, metadata: metadata)
        } else if isCompactionSummary {
            content = normalize(
                message.content,
                inputCap: compactionNormalizationInputCharacterCap
            )
        } else {
            content = normalize(message.content)
        }
        // Vision wave (2026-06-11 review catch): image turns persist base64-
        // free attachment metadata; an image-only turn has EMPTY content and
        // vanished from rebuilt history entirely, a captioned one lost the
        // fact an image was attached. Render a compact reference instead —
        // never the base64 (history lives in the cacheable system prompt).
        content = ChatTranscriptEvidenceRendering.contentIncludingAttachments(
            content, attachments: metadata?["attachments"])
        guard !content.isEmpty else { return nil }
        if role == "assistant", isTransientAssistantFailure(content) {
            return nil
        }
        return Renderable(
            role: isCompactionSummary ? "summary" : role,
            content: content,
            historyIdentity: message.historyIdentity(
                renderedRole: isCompactionSummary ? "summary" : role, renderedContent: content),
            originLabel: role == "user" && !isCompactionSummary
                ? ChatTranscriptEvidenceRendering.recordedOriginLabel(metadata?["origin"]) : nil,
            incompleteReplyLabel: role == "assistant" && !isCompactionSummary
                ? ChatTranscriptEvidenceRendering.recordedIncompleteReplyLabel(extras: extrasObject, metadata: metadata) : nil,
            timestamp: message.timestamp,
            isTool: isTool,
            isCompactionSummary: isCompactionSummary,
            isCarriedRecollection: isCompactionSummary
                && !(string(metadata?[CarriedAnchorRecollection.carriedFromKey]) ?? "").isEmpty,
            toolName: isTool
                ? (string(metadata?["toolName"]) ?? string(metadata?["tool_name"]) ?? "tool")
                : nil,
            toolStatus: isTool
                ? (ChatTranscriptEvidenceRendering.recordedToolStatus(metadata) ?? "ran")
                : nil,
            runId: string(extrasObject?["runId"]) ?? string(metadata?["runId"])
        )
    }

    private static func isTransientAssistantFailure(_ content: String) -> Bool {
        let lower = content.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return lower.hasPrefix("chat error:")
            || lower.hasPrefix("(drafting stalled;")
            || lower.hasPrefix("(internal error while drafting")
    }

    private static func continuityState(
        from messages: [Renderable],
        budget: Budget
    ) -> String? {
        let userAssistant = messages.filter { $0.role == "user" || $0.role == "assistant" }
        guard !userAssistant.isEmpty else { return nil }

        let anchors = Array(userAssistant.prefix(3))
        let latestUser = userAssistant.reversed().first { $0.role == "user" }
        let latestAssistant = userAssistant.reversed().first { $0.role == "assistant" }
        let latestCorrection = userAssistant.reversed().first {
            $0.role == "user" && looksLikeCorrection($0.content)
        }
        let openLoop = latestAssistant.flatMap { looksLikeOpenLoop($0.content) ? $0 : nil }

        var lines: [String] = ["SESSION_CONTINUITY_STATE:"]
        if !anchors.isEmpty {
            let rendered = anchors
                .map { "[\($0.role)] \(cap($0.displayContent, 220))" }
                .joined(separator: " | ")
            lines.append("Initial anchors: \(rendered)")
        }
        if let latestUser {
            lines.append("Latest user before this turn: \(cap(latestUser.displayContent, 280))")
        }
        if let latestAssistant {
            lines.append("Latest assistant tail: \(cap(latestAssistant.displayContent, 320))")
        }
        if let latestCorrection {
            lines.append("Recent correction/callout: \(cap(latestCorrection.displayContent, 260))")
        }
        if let openLoop {
            lines.append("Open loop: \(cap(openLoop.displayContent, 280))")
        }
        lines.append("For older or elided wording, use search_chat_history/session_search scoped to the current session first, then broaden only if needed.")

        let rendered = lines.joined(separator: "\n")
        return rendered.count > budget.continuityCap
            ? String(rendered.prefix(budget.continuityCap)) + "..."
            : rendered
    }

    private static func relevantEarlierSessionSnippets(
        userMessage: String,
        promptRenderables: [Renderable],
        candidates: [Renderable],
        historyLimit: Int,
        budget: Budget
    ) -> String? {
        guard budget.relevantChars > 0, !candidates.isEmpty else { return nil }
        let query = middleSearchQuery(userMessage: userMessage, renderables: promptRenderables)
        let queryTerms = Set(searchTokens(query))
        guard !queryTerms.isEmpty else { return nil }

        let visible = alreadyRenderedSignatures(from: promptRenderables, historyLimit: historyLimit)
        var docs: [(index: Int, message: Renderable, tokens: [String], frequencies: [String: Int])] = []
        docs.reserveCapacity(candidates.count)
        for (index, candidate) in candidates.enumerated() {
            guard !visible.contains(signature(candidate)) else { continue }
            let tokens = searchTokens(candidate.content)
            guard !tokens.isEmpty else { continue }
            var frequencies: [String: Int] = [:]
            for token in tokens { frequencies[token, default: 0] += 1 }
            guard queryTerms.contains(where: { frequencies[$0] != nil }) else { continue }
            docs.append((index: index, message: candidate, tokens: tokens, frequencies: frequencies))
        }
        guard !docs.isEmpty else { return nil }

        var documentFrequency: [String: Int] = [:]
        for doc in docs {
            let unique = Set(doc.tokens)
            for term in queryTerms where unique.contains(term) {
                documentFrequency[term, default: 0] += 1
            }
        }
        let averageLength = max(1.0, Double(docs.map { $0.tokens.count }.reduce(0, +)) / Double(docs.count))
        let ranked = docs.compactMap { doc -> (index: Int, message: Renderable, score: Double)? in
            var score = 0.0
            let length = max(1.0, Double(doc.tokens.count))
            for term in queryTerms {
                guard let tfRaw = doc.frequencies[term],
                      let df = documentFrequency[term],
                      df > 0 else { continue }
                let tf = Double(tfRaw)
                let idf = log(1.0 + (Double(docs.count - df) + 0.5) / (Double(df) + 0.5))
                let denominator = tf + 1.2 * (1.0 - 0.75 + 0.75 * (length / averageLength))
                score += idf * ((tf * 2.2) / denominator)
            }
            guard score > 0 else { return nil }
            switch doc.message.role {
            case "user": score *= 1.15
            case "tool": score *= 0.85
            default: break
            }
            return (index: doc.index, message: doc.message, score: score)
        }
        .sorted {
            if $0.score == $1.score { return $0.index > $1.index }
            return $0.score > $1.score
        }
        .prefix(4)
        .sorted { $0.index < $1.index }

        guard !ranked.isEmpty else { return nil }
        var lines = ["Relevant earlier session snippets:"]
        var used = lines[0].count
        var added = 0
        for hit in ranked {
            let capValue = min(capForRole(hit.message, budget: budget), budget.relevantItemCap)
            let line = "[\(hit.message.role)] \(cap(hit.message.displayContent, capValue))"
            let projected = used + line.count + 1
            if added > 0 && projected > budget.relevantChars { break }
            lines.append(line)
            used = projected
            added += 1
        }
        return added > 0 ? lines.joined(separator: "\n") : nil
    }

    private static func middleSearchQuery(
        userMessage: String,
        renderables: [Renderable]
    ) -> String {
        let current = normalize(userMessage)
        let userAssistant = renderables.filter { $0.role == "user" || $0.role == "assistant" }
        let latestUser = userAssistant.reversed().first { $0.role == "user" }
        let latestAssistant = userAssistant.reversed().first { $0.role == "assistant" }
        let latestCorrection = userAssistant.reversed().first {
            $0.role == "user" && looksLikeCorrection($0.content)
        }
        return [
            current,
            latestUser?.content ?? "",
            latestAssistant?.content ?? "",
            latestCorrection?.content ?? "",
        ]
        .filter { !$0.isEmpty }
        .joined(separator: " ")
    }

    private static func alreadyRenderedSignatures(
        from renderables: [Renderable],
        historyLimit: Int
    ) -> Set<String> {
        var visible = Set(renderables.suffix(max(0, historyLimit)).map(signature))
        let userAssistant = renderables.filter { $0.role == "user" || $0.role == "assistant" }
        for item in userAssistant.prefix(3) { visible.insert(signature(item)) }
        if let latestUser = userAssistant.reversed().first(where: { $0.role == "user" }) {
            visible.insert(signature(latestUser))
        }
        if let latestAssistant = userAssistant.reversed().first(where: { $0.role == "assistant" }) {
            visible.insert(signature(latestAssistant))
            if looksLikeOpenLoop(latestAssistant.content) {
                visible.insert(signature(latestAssistant))
            }
        }
        if let latestCorrection = userAssistant.reversed().first(where: {
            $0.role == "user" && looksLikeCorrection($0.content)
        }) {
            visible.insert(signature(latestCorrection))
        }
        return visible
    }

    private static func signature(_ message: Renderable) -> String {
        message.historyIdentity
    }

    /// The rendered history line for one admitted row. ONE owner, shared by
    /// the v1 text block and the v2 message projection so the two can never
    /// disagree about caps.
    static func renderedHistoryLine(_ msg: Renderable, budget: Budget) -> String {
        "[\(msg.role)] \(cap(msg.displayContent, capForRole(msg, budget: budget)))"
    }

    /// The row TEXT the v2 projection replays — the same capped body the v1
    /// line carries, without the `[role]` prefix (the message role carries it).
    static func projectedHistoryText(_ msg: Renderable, budget: Budget) -> String {
        cap(msg.displayContent, capForRole(msg, budget: budget))
    }

    /// The newest-first admission the conversation-history block runs, lifted
    /// out verbatim so `SessionHistoryMessageProjection` replays EXACTLY the
    /// rows v1 rendered (compaction-summary reservation included) instead of
    /// re-deriving a second, drifting rule.
    ///
    /// Returns indices INTO `tail`, oldest→newest, plus whether anything was
    /// left out (either trimmed off the front by `limit` or squeezed out by
    /// `budget.historyChars`).
    static func admittedHistoryIndices(
        tail: [Renderable],
        totalCount: Int,
        budget: Budget
    ) -> (indices: [Int], omitted: Bool) {
        var admitted: [(index: Int, length: Int)] = []
        var used = 0
        var omitted = totalCount > tail.count

        // Sweep R4 A3: the compaction recollection is the ONLY surviving record
        // of every turn that was elided — and it is by construction one of the
        // OLDEST rows in the tail. The fill below runs newest-first, so now that
        // this row can legitimately be several thousand characters, ordinary
        // recent chatter would crowd out the exact artifact compaction paid an
        // LLM call to produce. It gets first claim on `historyChars`; the
        // aggregate bound itself is unchanged.
        let reservedIndex = tail.indices.last { tail[$0].isCompactionSummary }
        if let reservedIndex {
            let length = renderedHistoryLine(tail[reservedIndex], budget: budget).count
            admitted.append((reservedIndex, length))
            used = length + 1
        }

        // Unchanged fill semantics for every other row: newest-first, and the
        // newest row is admitted even if it alone exceeds the budget.
        var admittedFromStream = false
        for idx in tail.indices.reversed() {
            if idx == reservedIndex { continue }
            let length = renderedHistoryLine(tail[idx], budget: budget).count
            let projected = used + length + 1
            if admittedFromStream && projected > budget.historyChars {
                omitted = true
                continue
            }
            admitted.append((idx, length))
            used = projected
            admittedFromStream = true
        }
        return (admitted.map(\.index).sorted(), omitted)
    }

    private static func conversationHistory(
        from messages: [Renderable],
        limit: Int,
        budget: Budget
    ) -> String? {
        let tail = Array(messages.suffix(limit))
        guard !tail.isEmpty else { return nil }

        let admission = admittedHistoryIndices(
            tail: tail, totalCount: messages.count, budget: budget
        )
        let omitted = admission.omitted
        let lines = admission.indices.map { renderedHistoryLine(tail[$0], budget: budget) }
        guard !lines.isEmpty else { return nil }

        var out: [String] = ["Conversation history:"]
        if omitted {
            out.append("[NOTICE: Earlier session details are elided. Use search_chat_history/session_search for exact older wording.]")
        }
        out.append(contentsOf: lines)
        return out.joined(separator: "\n")
    }

    private static func immediateReplyReferenceHint(
        userMessage: String,
        renderables: [Renderable],
        budget: Budget
    ) -> String? {
        guard looksLikeShortAffirmativeContinuation(userMessage) else { return nil }
        let userAssistant = renderables.filter { $0.role == "user" || $0.role == "assistant" }
        guard let latest = userAssistant.last, latest.role == "assistant" else { return nil }
        let assistantCap = min(max(220, budget.assistantCap), 700)
        return """
        Immediate reply reference:
        The current user message is a short approval or continuation. Unless contradicted, treat it as referring to the immediately previous assistant message:
        [assistant] \(cap(latest.displayContent, assistantCap))
        """
    }

    static func capForRole(_ message: Renderable, budget: Budget) -> Int {
        // Sweep R4 #6: `toolSummary` already projected this row head+tail. A
        // row cap BELOW that projection's length would head-truncate it and
        // throw the tail (the part that carries the failure) away again — the
        // exact bug being fixed. Floor the tool row cap at the projection's
        // worst case so the two layers cannot fight.
        if message.isTool { return max(budget.toolCap, toolRowMinimumCap) }
        // Sweep R4 A3: routed to its OWN cap, not the generic system cap.
        if message.isCompactionSummary { return budget.compactionSummaryCap }
        switch message.role {
        case "user": return budget.userCap
        case "assistant": return budget.assistantCap
        case "system", "summary": return budget.systemCap
        default: return 900
        }
    }

    // internal (not private) so the skills-recall rework test can pin the
    // 180-char cap — the guarantee that a pulled skill body never rides
    // forward into later prompts at full length.
    static func toolSummary(
        content: String,
        metadata: [String: JSONValue]?
    ) -> String {
        let recordedStatus = ChatTranscriptEvidenceRendering.recordedToolStatus(metadata)
        let normalizedContent = normalize(content)
        if !normalizedContent.isEmpty {
            return recordedStatus.map { "\($0): \(normalizedContent)" } ?? normalizedContent
        }
        let name = string(metadata?["toolName"]) ?? string(metadata?["tool_name"]) ?? "tool"
        let ok: String = {
            if case .bool(let value)? = metadata?["ok"] { return value ? "ok" : "failed" }
            return "ran"
        }()
        let toolStatus = recordedStatus.map { "\($0): \(name)" } ?? "\(name) \(ok)"
        // Skill reads: the 180-char preview would be the skill body's first
        // paragraph — redundant bytes in every subsequent prompt. The NAME is
        // the whole continuity signal ("I already read that skill"); she can
        // re-read on demand. (User, 2026-07-03: "180 chars could add up if
        // she uses a lot of skills.")
        if name == "read_skill" {
            let skillName = Self.readSkillName(fromInputJSON: string(metadata?["inputJSON"]))
            return skillName.isEmpty
                ? toolStatus
                : "\(toolStatus): \(skillName) (body elided — re-read if needed)"
        }
        let rawResult = string(metadata?["resultSummary"]) ?? ""
        let result = toolResultProjection(rawResult)
        if result.isEmpty {
            return toolStatus
        }
        return "\(toolStatus): \(result)"
    }

    // MARK: - Cross-turn tool-result projection (sweep R4, finding #6)

    /// Floor for the per-row cap applied to tool rows, sized so the head+tail
    /// projection below (plus a long tool name and the "ok: " lead-in) always
    /// survives `capForRole` intact.
    static let toolRowMinimumCap = 360

    /// Characters of the ORIGINAL kept from the head of a prior-turn tool result.
    static let toolResultHeadChars = 110
    /// Characters of the ORIGINAL kept from the tail. Tool FAILURES put the
    /// lines that matter (compiler errors, "N tests failed", exit status) at the
    /// END — the old head-only `cap(result, 180)` dropped every one of them and
    /// left a bare "..." that did not even say something had been cut.
    static let toolResultTailChars = 50
    /// Bound on how much raw text is normalized/redacted per end. Legacy
    /// 50–60 KB tool_catalog receipts must not be rescanned in full to produce
    /// a ~180-char preview.
    private static let toolResultRedactionWindow = 512

    /// Head+tail-preserving projection of a prior-turn tool result, mirroring
    /// the in-turn reference implementations (`ProviderToolResultProjection`
    /// preview_head/preview_tail and `SubprocessSupport.headTailPreserve`):
    /// both ends survive and the elision is stated explicitly with a character
    /// count instead of a bare "...". Short results pass through untouched.
    static func toolResultProjection(_ raw: String) -> String {
        let keep = toolResultHeadChars + toolResultTailChars
        if raw.count <= toolResultRedactionWindow {
            let normalized = normalize(raw)
            guard normalized.count > keep else { return normalized }
            return String(normalized.prefix(toolResultHeadChars))
                + toolResultElisionMarker(normalized.count - keep)
                + String(normalized.suffix(toolResultTailChars))
        }
        // Too large to normalize whole: redact a bounded window at each end.
        let head = normalize(String(raw.prefix(toolResultRedactionWindow)))
        let tail = normalize(String(raw.suffix(toolResultRedactionWindow)))
        guard head.count > keep || !tail.isEmpty else { return head }
        let kept = min(head.count, toolResultHeadChars) + min(tail.count, toolResultTailChars)
        return String(head.prefix(toolResultHeadChars))
            + toolResultElisionMarker(max(0, raw.count - kept))
            + String(tail.suffix(toolResultTailChars))
    }

    private static func toolResultElisionMarker(_ elided: Int) -> String {
        " [… \(elided) chars elided …] "
    }

    /// Pull the `name` argument out of a persisted read_skill inputJSON blob.
    static func readSkillName(fromInputJSON raw: String?) -> String {
        guard let raw, let data = raw.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let name = obj["name"] as? String
        else { return "" }
        return name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func looksLikeCorrection(_ content: String) -> Bool {
        let lower = content.lowercased()
        let needles = [
            "no ", "not ", "wrong", "incorrect", "what are you talking about",
            "i said", "you said", "that's not", "thats not", "actually"
        ]
        return needles.contains { lower.contains($0) }
    }

    private static func looksLikeShortAffirmativeContinuation(_ content: String) -> Bool {
        let trimmed = normalize(content).lowercased()
        guard !trimmed.isEmpty, trimmed.count <= 90 else { return false }
        guard !trimmed.contains("?") else { return false }
        let simple = trimmed
            .replacingOccurrences(of: #"[^a-z0-9'\s]"#, with: " ", options: .regularExpression)
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
        guard !simple.isEmpty, simple.split(separator: " ").count <= 8 else { return false }

        let exact: Set<String> = [
            "yes", "yes please", "yes do it", "yes go ahead",
            "yeah", "yeah please", "yeah go ahead", "yeah do it", "yeah do that",
            "yea", "yep", "yup", "sure", "sure do it",
            "ok", "okay", "ok do it", "okay do it", "ok go ahead", "okay go ahead",
            "go ahead", "do it", "do that", "please do", "please do that",
            "sounds good", "that works", "thats fine", "that's fine",
            "thats good", "that's good", "fine by me", "go for it"
        ]
        if exact.contains(simple) { return true }

        let approvalPrefixes = ["yes ", "yeah ", "yep ", "yup ", "ok ", "okay ", "sure "]
        let actionPhrases = [
            "go ahead", "do it", "do that", "make it", "fix it",
            "that works", "thats fine", "that's fine", "go for it"
        ]
        return approvalPrefixes.contains { simple.hasPrefix($0) }
            && actionPhrases.contains { simple.contains($0) }
    }

    private static func looksLikeOpenLoop(_ content: String) -> Bool {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasSuffix("?") { return true }
        let lower = trimmed.lowercased()
        let needles = [
            "want me to", "should i", "i can ", "i'll ", "next step",
            "waiting on", "blocked on", "confirm"
        ]
        return needles.contains { lower.contains($0) }
    }

    private static func searchTokens(_ text: String) -> [String] {
        let normalized = normalize(text).lowercased()
        return normalized
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)
            .filter { token in
                token.count >= 3 && !retrievalStopwords.contains(token)
            }
    }

    private static let retrievalStopwords: Set<String> = [
        "about", "after", "again", "all", "also", "and", "are", "ask", "back",
        "been", "before", "being", "but", "can", "could", "did", "does", "doing",
        "done", "few", "for", "from", "get", "got", "had", "has", "have", "her",
        "here", "him", "his", "how", "into", "just", "last", "latest", "like",
        "make", "maybe", "message", "more", "not", "now", "our", "out", "please",
        "prior", "really", "right", "said", "same", "she", "should", "some",
        "that", "the", "their", "them", "then", "there", "these", "thing",
        "this", "those", "through", "turn", "user", "was", "what", "when",
        "where", "with", "would", "yeah", "you", "your",
    ]

    private static func normalize(
        _ text: String,
        inputCap: Int = normalizationInputCharacterCap
    ) -> String {
        let bounded = text.count > inputCap
            ? String(text.prefix(inputCap))
            : text
        return ChatSecretRedactor.redactText(bounded)
            .replacingOccurrences(of: "\r", with: "\n")
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func cap(_ text: String, _ maxCount: Int) -> String {
        guard text.count > maxCount else { return text }
        return String(text.prefix(max(0, maxCount))) + "..."
    }

    private static func hardCap(_ text: String, _ maxCount: Int) -> String {
        guard maxCount > 0 else { return "" }
        guard text.count > maxCount else { return text }
        if maxCount <= 3 { return String(text.prefix(maxCount)) }
        return String(text.prefix(maxCount - 3)) + "..."
    }

    private static func object(_ value: JSONValue?) -> [String: JSONValue]? {
        if case .object(let obj)? = value { return obj }
        return nil
    }

    private static func string(_ value: JSONValue?) -> String? {
        if case .string(let s)? = value { return s }
        return nil
    }

    private static func array(_ value: JSONValue?) -> [JSONValue]? {
        if case .array(let a)? = value { return a }
        return nil
    }

    private static func int(_ value: JSONValue?) -> Int? {
        switch value {
        case .some(.int(let i)): return Int(i)
        case .some(.double(let d)): return Int(d)
        default: return nil
        }
    }
}

// MARK: - SessionHistoryMessageProjection (v2Prefix conversation prefix)

/// Prior turns → `[LLMMessage]`, oldest→newest, for the `v2Prefix`
/// conversation shape.
///
/// The whole point of v2 is that the transcript stops riding the DYNAMIC
/// system segment (which churns every turn and therefore can never be cached
/// across turns) and becomes a real message prefix that a provider cache can
/// match byte-for-byte from one turn to the next.
///
/// ADMISSION IS NOT RE-DERIVED. This replays EXACTLY the rows
/// `SessionHistoryPromptRenderer.conversationHistory` admits — same
/// `renderable` filter, same `capForRole`, same
/// `budget(for:windowTokens:)`, same newest-first fill including the
/// compaction-summary reservation — by calling the renderer's own internal
/// helpers. A second, drifting copy of that rule is the one way this change
/// could silently change what the model sees.
///
/// Mapping (deliberately conservative — prior tool rounds have NO provider
/// call ids, so inventing `tool_use`/`tool_result` pairs would be a lie the
/// provider would reject or, worse, accept):
///   - user      → `.user` text
///   - assistant → `.assistant` text, with `<tool_use>` markers STRIPPED
///                 (text-compat transcripts retain literal markers; replaying
///                 one re-injects a call)
///   - tool row  → an extra text block `[tool <name> <status>] <projection>`
///                 appended to the immediately preceding assistant message
///                 (a synthetic assistant message when there is none)
///   - compaction summary → a leading `[session recollection] …` text block on
///                 the OLDEST replayed user message
/// Consecutive same-role rows merge; leading assistant rows are trimmed so
/// `messages[0]` is always `.user`.
enum SessionHistoryMessageProjection {
    struct Result: Sendable {
        /// Oldest → newest. Always starts with a `.user` message (or is empty).
        let messages: [LLMMessage]
        /// Every admitted row reduced to what the window cursor needs —
        /// identity, role, rendered length, anchor/recollection exemption.
        /// Payload-free by construction: no transcript content leaves here.
        let rows: [HistoryWindowRow]
        /// Sum of every rendered row's v1 line length — the number the window
        /// cursor compares against `budget.historyChars`.
        let usedChars: Int
        /// Rows the cursor skipped this turn (already outside the window).
        let droppedRowCount: Int
        /// Run ids of the user turns this prefix actually replays. The volatile
        /// archive is pruned to exactly this set: a block whose position is no
        /// longer in the prefix cannot be replayed into it.
        let replayedRunIds: Set<String>

        var admittedIdentities: [String] { rows.map(\.identity) }

        static let empty = Result(
            messages: [], rows: [], usedChars: 0, droppedRowCount: 0, replayedRunIds: []
        )
    }

    /// Rows pinned at the HEAD regardless of the window cursor. Mirrors the
    /// reader's `anchorLimit: 3` — the opening of a session is what makes the
    /// rest of it legible, so sliding the window never eats it.
    static let anchorLimit = 3

    /// The admitted rows ALONE, without building any message. The window
    /// cursor needs the rows to decide whether to advance, and the projection
    /// needs the cursor's answer — so the admission runs once here and both
    /// halves read it, rather than the projection running twice per turn.
    struct Admission {
        let renderables: [SessionHistoryPromptRenderer.Renderable]
        let budget: ContextBudgetPolicy.Resolved
        let rows: [HistoryWindowRow]
        var usedChars: Int { rows.reduce(0) { $0 + $1.length + 1 } }
    }

    /// v2 ADMISSION — deliberately NOT the v1 rule.
    ///
    /// v1 fills newest-first against `budget.historyChars` and re-runs that
    /// fill every turn. Both halves of that are per-turn moving parts: the
    /// `suffix(historyLimit)` head slides as the session grows, and the
    /// budget fill re-decides where the block starts every time a row's size
    /// changes. Either one rewrites the head of the replayed prefix, which is
    /// precisely what a provider cache cannot survive — so on v2 they are both
    /// gone and the cursor is the ONLY head.
    ///
    /// What remains here: the contiguous range the reader returned, rendered
    /// under the SAME per-row caps (`capForRole`), with the anchors and the
    /// compaction recollection pinned. Size is enforced downstream, and only
    /// by the cursor's hysteresis — rarely, at a turn boundary, oldest-first.
    ///
    /// `historyLimit == 0` still means "no history"; it is the disable switch,
    /// not a window.
    static func admission(
        messages: [ChatMessage],
        historyLimit: Int,
        surface: String,
        windowTokens: Int? = nil
    ) -> Admission? {
        guard max(0, historyLimit) > 0 else { return nil }
        let renderables = messages.compactMap(SessionHistoryPromptRenderer.renderable)
        guard !renderables.isEmpty else { return nil }
        let budget = SessionHistoryPromptRenderer.budget(
            for: surface, windowTokens: windowTokens
        )
        let anchorIdentities = Set(
            renderables
                .filter { $0.role == "user" || $0.role == "assistant" }
                .prefix(anchorLimit)
                .map(\.historyIdentity)
        )
        let rows = renderables.map { row in
            HistoryWindowRow(
                identity: row.historyIdentity,
                role: row.isTool ? "tool" : row.role,
                length: SessionHistoryPromptRenderer
                    .renderedHistoryLine(row, budget: budget).count,
                isAnchor: anchorIdentities.contains(row.historyIdentity),
                isCompactionSummary: row.isCompactionSummary
            )
        }
        return Admission(renderables: renderables, budget: budget, rows: rows)
    }

    static func project(
        messages: [ChatMessage],
        historyLimit: Int,
        surface: String,
        windowTokens: Int? = nil,
        cursor: HistoryWindowCursor? = nil,
        archivedTurnMessages: [String: [LLMMessage]] = [:]
    ) -> Result {
        guard let admission = admission(
            messages: messages,
            historyLimit: historyLimit,
            surface: surface,
            windowTokens: windowTokens
        ) else { return .empty }
        return project(
            admission, cursor: cursor, archivedTurnMessages: archivedTurnMessages
        )
    }

    /// `archivedTurnMessages` (run id → the messages that turn sent after its
    /// user turn, in order) replays each earlier turn's mid-conversation system
    /// messages at THEIR ORIGINAL POSITIONS: immediately after the user message
    /// they followed, before that turn's assistant reply.
    ///
    /// Two kinds ride here and both must stay. The turn-scoped volatile block
    /// is cleared once a later user message arrives — 0 input tokens — but must
    /// remain in `messages`. The `tool_addition`/`tool_removal` message is NOT
    /// turn-scoped at all, and removing an already-sent one invalidates the
    /// prefix from that point.
    ///
    /// This is not an optimization, it is the contract. A cleared turn-scoped
    /// message costs 0 input tokens but must STAY in `messages` byte-for-byte;
    /// omitting it makes turn N+1's prefix diverge from turn N's at the element
    /// right after `user(N)`, so everything from there — the previous turn's
    /// tool rounds and reply included — is re-created at full price.
    ///
    /// Empty by default, so every non-clear_at lane is unchanged.
    static func project(
        _ admission: Admission,
        cursor: HistoryWindowCursor?,
        archivedTurnMessages: [String: [LLMMessage]] = [:]
    ) -> Result {
        var admitted = admission.renderables
        let budget = admission.budget
        let rows = admission.rows
        let usedChars = admission.usedChars
        let identities = rows.map(\.identity)

        // Window cursor: drop the oldest admitted rows through (and including)
        // the recorded boundary. Anchors and the compaction summary are exempt
        // — they are the two row classes whose loss is not recoverable from
        // what remains. A boundary that is not present (compaction rewrote the
        // transcript, or the window already slid past it) drops nothing:
        // fail-open is a bigger prompt, never a lost row.
        var droppedRowCount = 0
        if let boundary = cursor?.dropBoundaryIdentity,
           let boundaryOffset = identities.firstIndex(of: boundary) {
            // THE HEAD IS THE BOUNDARY — nothing is pinned in front of it.
            //
            // Anchors used to be exempt, which produced `anchors ‖ GAP ‖ live
            // window`. The anchors themselves are deterministic (the reader
            // takes the first lines of the transcript file, not
            // relevance-chosen rows), but the row immediately AFTER them is
            // whatever the reader's sliding tail happened to reach back to, so
            // the joint between the two moved as the session grew — and the
            // merge of a trailing anchor into that first live row changed with
            // it. That is a head that differs between requests even while the
            // cursor reports stable.
            //
            // Now the emitted head is exactly the first row after the persisted
            // boundary, so `messages[0]` is a pure function of the cursor. The
            // opening of the session is not lost: `continuityState` carries
            // "Initial anchors: …" in the volatile block, which is where
            // per-turn relevance material belongs anyway.
            //
            // The compaction recollection is the one exception — it is the only
            // surviving record of everything already elided, and it leads the
            // oldest replayed user message rather than standing as a row.
            var kept: [SessionHistoryPromptRenderer.Renderable] = []
            for (offset, row) in admitted.enumerated() {
                if offset <= boundaryOffset, !rows[offset].isCompactionSummary {
                    droppedRowCount += 1
                    continue
                }
                kept.append(row)
            }
            admitted = kept
        }
        guard !admitted.isEmpty else { return .empty }

        var out: [LLMMessage] = []
        var pendingRecollection: String?
        var replayedRunIds = Set<String>()
        // A replayed block is HELD until the turn's assistant reply is emitted.
        // The same wire rule that governs the current turn governs a replayed
        // one: a system message may end the array or precede an assistant turn,
        // never precede a user turn. A turn whose reply is not in the prefix
        // (transient failure, filtered by `renderable`) has no intact position
        // to replay into, and the tail block would sit directly before the
        // CURRENT user message — so both cases drop the block rather than
        // emit an array the provider rejects.
        var pendingReplay: (runId: String, messages: [LLMMessage])?

        func flushPendingReplay() {
            guard let pending = pendingReplay else { return }
            pendingReplay = nil
            out.append(contentsOf: pending.messages)
        }

        func appendText(_ role: LLMMessage.Role, _ text: String) {
            guard !text.isEmpty else { return }
            if let last = out.last, last.role == role {
                out[out.count - 1] = LLMMessage(role: role, content: last.content + [.text(text)])
            } else {
                out.append(LLMMessage(role: role, content: [.text(text)]))
            }
        }

        for row in admitted {
            let body = SessionHistoryPromptRenderer.projectedHistoryText(row, budget: budget)
            if body.isEmpty { continue }
            if row.isCompactionSummary {
                // Held for the oldest replayed USER message rather than
                // emitted as its own turn: a synthetic role here would read as
                // a real exchange that never happened.
                pendingRecollection = row.recollectionLabel + " " + body
                continue
            }
            if row.isTool {
                flushPendingReplay()
                let label = "[tool \(row.toolName ?? "tool") \(row.toolStatus ?? "ran")]"
                if let last = out.last, last.role == .assistant {
                    out[out.count - 1] = LLMMessage(
                        role: .assistant,
                        content: last.content + [.text("\(label) \(body)")]
                    )
                } else {
                    out.append(LLMMessage(
                        role: .assistant, content: [.text("\(label) \(body)")]
                    ))
                }
                continue
            }
            switch row.role {
            case "user":
                pendingReplay = nil
                if let recollection = pendingRecollection {
                    pendingRecollection = nil
                    if let last = out.last, last.role == .user {
                        out[out.count - 1] = LLMMessage(
                            role: .user, content: last.content + [.text(body)]
                        )
                    } else {
                        out.append(LLMMessage(
                            role: .user, content: [.text(recollection), .text(body)]
                        ))
                    }
                } else {
                    appendText(.user, body)
                }
                if let runId = row.runId {
                    replayedRunIds.insert(runId)
                    // Byte-for-byte, in position, exactly once — held until the
                    // reply proves the position is intact.
                    if let replay = archivedTurnMessages[runId], !replay.isEmpty,
                       pendingReplay == nil {
                        pendingReplay = (runId, replay)
                    }
                }
            case "assistant":
                flushPendingReplay()
                // A replayed assistant turn that still carries a literal
                // `<tool_use>` marker would re-issue that call on the next
                // provider read. Strip before it ever reaches the wire.
                appendText(.assistant, ToolCallParser.stripToolUseMarkers(body))
            default:
                // system/summary/unknown rows are not a two-party turn; fold
                // them into the user side rather than inventing a role.
                pendingReplay = nil
                appendText(.user, "[\(row.role)] " + body)
            }
        }

        // The tail block is deliberately dropped: `seed` appends the CURRENT
        // user message next, and a system message directly before it is the
        // exact 400 this shape has to avoid.
        pendingReplay = nil
        // A conversation must open on a user turn: an assistant-first prefix is
        // rejected outright by the Anthropic wire and reads as a hallucinated
        // opening everywhere else. A leading system row would be equally
        // invalid, and the same loop removes it.
        while let first = out.first, first.role != .user {
            out.removeFirst()
        }
        // User, 2026-09-06: a summary-only history dropped the WHOLE
        // recollection here. A backstop compaction can leave the newest raw
        // message as the only survivor, and at turn start that is the current
        // user row, which history reading excludes by run id — so projection
        // sees the summary alone, holds it in pendingRecollection, produces no
        // ordinary message, and returned `.empty` BEFORE the preservation
        // fallback two lines below. The recollection is the session's entire
        // memory of itself; it goes out on a user message of its own.
        if out.isEmpty {
            guard let recollection = pendingRecollection else { return .empty }
            pendingRecollection = nil
            out = [LLMMessage(role: .user, content: [.text(recollection)])]
        }
        // A recollection with no surviving user row to lead still has to be
        // said: prepend it to the first message rather than dropping it.
        if let recollection = pendingRecollection, let first = out.first {
            out[0] = LLMMessage(role: first.role, content: [.text(recollection)] + first.content)
        }
        return Result(
            messages: out,
            rows: rows,
            usedChars: usedChars,
            droppedRowCount: droppedRowCount,
            replayedRunIds: replayedRunIds
        )
    }
}

// MARK: - Mid-conversation tool changes (Anthropic structured lanes)

/// The turn-invariant `tools` array plus this turn's OFFERED delta, for the
/// Anthropic beta `mid-conversation-tool-changes-2026-07-01`.
///
/// WHY: `tools` sits FIRST in Anthropic's hashed prefix (tools → system →
/// messages), so a session load or an idle drop that edits the array
/// invalidates the cache for the WHOLE conversation. The fix is to declare the
/// session's full pinned catalog once, mark every non-floor tool
/// `defer_loading: true`, and express what is actually offered THIS turn as
/// `tool_addition` / `tool_removal` blocks in a `role: "system"` message that
/// sits behind the cache breakpoint.
///
/// NO LEDGER. History is rebuilt from the transcript every turn, so the turn's
/// message re-declares the FULL delta relative to the array's own defaults
/// (floor offered, everything else deferred) rather than a diff against what
/// some earlier turn declared.
///
/// `array` names are INTERNAL tool names; the loop maps them through
/// `ProviderToolNameMap` before they reach the wire.
struct StructuredToolChangePlan: Sendable, Equatable {
    /// The session's FULL pinned catalog, canonical order, byte-stable across
    /// turns. Non-floor entries carry `deferLoading`.
    let array: [LLMToolSchema]
    /// Everything offered to the model at turn start (floor + resident +
    /// pinned MCP + session loads + promotions, minus drops).
    let offered: [String]
    /// Offered − array defaults: the `tool_addition` set.
    let additions: [String]
    /// Array defaults (the always-on floor) withdrawn by policy this turn:
    /// the `tool_removal` set. A deferred tool is withdrawn by simply not
    /// being added, so it never needs a removal block.
    let removals: [String]
    /// RECEIPT: offered names that are not declared in `array`. Referencing
    /// one is a 400, so they are dropped from the addition list and never
    /// sent — recorded here so the drop is observable instead of silent.
    let droppedUnknown: [String]
    /// The session declaration's re-pin counter. The array can only move when
    /// this moves, so the turn trace carries it next to the array fingerprint
    /// and a cache miss is attributable instead of mysterious.
    let declarationGeneration: Int

    var arrayNames: Set<String> { Set(array.map(\.name)) }
}

/// Per-turn binding for the plan above, bound by the STRUCTURED chat turn-start
/// sites around the engine call and read at the tool loop's seeding site.
///
/// Unbound (every text-compat turn, every non-Anthropic provider, every model
/// whose catalog row does not claim the capability, every non-chat caller) →
/// the loop keeps today's churning-tools-array behavior exactly.
enum StructuredToolChangeContext {
    @TaskLocal static var plan: StructuredToolChangePlan?
}

// MARK: - ConversationPrefixSeeding (v2Prefix message assembly)

/// Assembles the provider message array for one turn:
///
///   historyMessages ‖ [volatile block] ‖ [current user message]
///
/// On `.v1Legacy` this is a no-op that returns the exact single-user-message
/// array every lane built before — the rollback arm is byte-identical by
/// construction, not by a parallel code path that has to be kept in sync.
///
/// DELIVERY LADDER for the volatile block. The block has to sit AFTER the
/// cached transcript prefix, and how it can be expressed depends on what the
/// provider can actually encode:
///
///   1. `.system(clearAtNextUserMessage: true)` — the model both supports a
///      mid-conversation system role AND can drop it at the next user turn, so
///      a turn-scoped instruction never becomes permanent transcript.
///   2. `.system(...)` plain — mid-conversation system supported, no clear_at.
///   3. `.system(...)` on the OpenAI OAuth Responses lane, where the adapter
///      encodes it as a `developer` item.
///   4. Leading text block of the CURRENT user message — every provider whose
///      adapter has a TWO-WAY role model and would therefore encode `.system`
///      as ASSISTANT prose (XAI OAuth, OpenAI api-key, Moonshot) and every
///      unknown model. Putting words in her own mouth is a worse failure than
///      losing the cache win, so this rung is the default, not the exception.
enum ConversationPrefixSeeding {
    enum VolatileDelivery: String, Sendable, Equatable {
        /// Mid-conversation system message, dropped by the provider at the
        /// next user turn.
        case systemClearAt
        /// Mid-conversation system message (Responses `developer` included).
        case system
        /// Leading text block of the current user message.
        case userLeadingBlock
        /// Nothing to deliver (empty volatile block, or `.v1Legacy`).
        case none
    }

    /// Providers whose OAuth Responses adapter encodes `.system` as a
    /// `developer` input item — rung 3.
    static func isOpenAIResponsesLane(_ providerId: String?) -> Bool {
        let normalized = (providerId ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "-", with: "_")
        return normalized == "openai_oauth_direct" || normalized == "codex"
    }

    static func delivery(model: String, providerId: String?) -> VolatileDelivery {
        if supportsMidConversationSystemClearAt(forModel: model) { return .systemClearAt }
        if supportsMidConversationSystem(forModel: model) { return .system }
        if isOpenAIResponsesLane(providerId) { return .system }
        return .userLeadingBlock
    }

    /// The current user message exactly as every lane built it before v2.
    static func currentUserMessage(_ ctx: TurnContext) -> LLMMessage {
        ctx.imageBlocks.isEmpty
            ? .user(ctx.userMessage)
            : .userWithImages(ctx.userMessage, images: ctx.imageBlocks)
    }

    struct Seed {
        /// The context to hand the provider. On v2 its `systemSegments.dynamic`
        /// is EMPTY (the bytes moved into `turnVolatileBlock`); on v1 it is the
        /// caller's context, untouched.
        let context: TurnContext
        let messages: [LLMMessage]
        let delivery: VolatileDelivery
        /// Index of the volatile system message, which is the LAST element of
        /// `messages` when one exists. nil when the block folded into the user
        /// turn instead, or when there was nothing volatile to deliver.
        let volatileIndex: Int?
        /// Index of the CURRENT turn's user message. Everything strictly before
        /// it is the cacheable prefix — history through the previous assistant
        /// — which is what `prefixFingerprint` hashes and what the next turn can
        /// reuse. The current user message is per-turn by definition and is
        /// deliberately excluded.
        let currentUserIndex: Int
        /// The shape this seed ACTUALLY produced — not the shape that was
        /// asked for. A `.v2Prefix` request with no replayed history falls back
        /// to the v1 message array, and the adapters read the task-local shape
        /// to choose their wire layout, so the caller must re-bind THIS value
        /// for the rest of the turn or the body and the layout disagree.
        let shape: ConversationPrefixShape
        /// TEXT-COMPAT lane only: the session-loaded tool catalog run was
        /// delivered in the volatile block instead of the cached prefix, so the
        /// prefix's tool contribution is the FLOOR alone (see `telemetry`).
        let textToolCatalogRidesVolatileBlock: Bool
    }

    /// `textToolCatalogAppendix` is the text-compat lane's "Also loaded this
    /// session:" run. Passing it (even as `""`) declares this a TEXT lane: its
    /// tool contract is rendered prose, not a provider tools array, so the
    /// appended rows ride the per-turn volatile block and only the always-on
    /// floor stays in the cached prefix. `nil` (the default, and every
    /// structured/native caller) is the pre-2026-09-01 behavior exactly —
    /// there the provider's own `tools` array is the contract and the
    /// equivalent fix is Anthropic's mid-conversation `tool_addition` content
    /// blocks (follow-up, not this change).
    /// The mid-conversation tool-change message for one turn, or nil when
    /// there is nothing to declare. `additions`/`removals` are PROVIDER names,
    /// already validated against the request's `tools` array by the caller.
    static func toolChangeMessage(
        additions: [String],
        removals: [String]
    ) -> LLMMessage? {
        let changes = additions.map(LLMToolChange.addition)
            + removals.map(LLMToolChange.removal)
        return changes.isEmpty ? nil : .toolChanges(changes)
    }

    /// `toolChanges` is the mid-conversation `tool_addition`/`tool_removal`
    /// message (structured Anthropic lanes only). It goes AFTER the current
    /// user message and BEFORE the turn-scoped volatile block: a turn-scoped
    /// message is text-only and 400s if it carries a tool-change block, and
    /// consecutive system messages are judged as one group, so the pair still
    /// satisfies "follows a user turn, ends the array". nil (every other
    /// caller) is byte-identical to the pre-2026-09-02 shape.
    static func seed(
        _ ctx: TurnContext,
        shape: ConversationPrefixShape,
        textToolCatalogAppendix: String? = nil,
        toolChanges: LLMMessage? = nil
    ) -> Seed {
        // v2 only engages when there IS a replayed prefix to protect. A turn
        // with no prior history (session turn 1, an ephemeral tool turn, any
        // non-chat caller) has nothing to reuse across turns, so relocating its
        // volatile block would be a model-visible move that buys nothing. Those
        // turns stay on the v1 shape, byte for byte.
        guard shape == .v2Prefix, !ctx.historyMessages.isEmpty else {
            // The tool-change message is NOT a v2 feature: on a plan turn the
            // array declares most tools deferred, so dropping the additions
            // here would leave the model holding the floor alone. It still
            // ends the array, directly after the one user message — legal.
            return Seed(
                context: ctx,
                messages: [currentUserMessage(ctx)] + (toolChanges.map { [$0] } ?? []),
                delivery: .none,
                volatileIndex: nil,
                currentUserIndex: 0,
                shape: .v1Legacy,
                // The v1 arm never relocates anything: on that shape the
                // catalog run stays in `stableSuffix` where the layout put it.
                textToolCatalogRidesVolatileBlock: false
            )
        }
        let split = ctx.splittingVolatileBlock(appending: textToolCatalogAppendix ?? "")
        let volatile = split.turnVolatileBlock ?? ""
        var messages = split.historyMessages
        var delivery: VolatileDelivery = .none
        var current = currentUserMessage(split)
        if !volatile.isEmpty {
            delivery = Self.delivery(model: split.modelId, providerId: split.providerId)
            if delivery == .userLeadingBlock {
                // The block leads the CURRENT turn's words. When the merge
                // below folds this into a trailing history user message, the
                // block still sits immediately before those words, which is
                // what the ordering is for.
                current = LLMMessage(role: .user, content: [.text(volatile)] + current.content)
            }
        }

        // WIRE RULE (live 400 on 785d7c42, `messages.28`): a text-carrying
        // system message must IMMEDIATELY FOLLOW a user turn, and must either
        // END the array or be followed by an assistant turn. One followed
        // directly by another user message is rejected outright. So the
        // current user message goes in FIRST and the volatile block goes LAST:
        //
        //     history … ‖ current user ‖ volatile system
        //
        // This is also the better cache layout — the current user turn now sits
        // inside the prefix the next turn replays, instead of behind a system
        // message that has to be re-sent ahead of it.
        //
        // Merge rather than append when history already ends on a user turn
        // (the previous assistant reply was a transient failure and was filtered
        // out of the projection): two consecutive user messages are their own
        // 400, and this is the only place that adjacency can appear.
        let currentUserIndex: Int
        if let last = messages.last, last.role == .user {
            messages[messages.count - 1] = LLMMessage(
                role: .user, content: last.content + current.content
            )
            currentUserIndex = messages.count - 1
        } else {
            currentUserIndex = messages.count
            messages.append(current)
        }

        // Tool changes first, turn-scoped volatile block last: the volatile
        // block is the one that must END the array to render.
        if let toolChanges { messages.append(toolChanges) }

        var volatileIndex: Int?
        switch delivery {
        case .systemClearAt:
            volatileIndex = messages.count
            // Ends the array, so it always renders — and the provider clears it
            // as soon as a later user message exists.
            messages.append(.system(volatile, clearAtNextUserMessage: true))
        case .system:
            volatileIndex = messages.count
            messages.append(.system(volatile))
        case .userLeadingBlock, .none:
            break
        }

        return Seed(
            context: split,
            messages: messages,
            delivery: delivery,
            volatileIndex: volatileIndex,
            currentUserIndex: currentUserIndex,
            shape: .v2Prefix,
            textToolCatalogRidesVolatileBlock: textToolCatalogAppendix != nil
        )
    }

    /// Append user-role text to a seeded conversation without ever producing a
    /// shape the wire rejects.
    ///
    /// TWO adjacencies are fatal here, and this is the one helper that knows
    /// both: two consecutive user messages, and a user message placed directly
    /// after the volatile system message. Since v2 ends the seeded array with
    /// that system message, an empty-reply nudge appended naively lands in
    /// exactly the second case — on the recovery path, which is when a second
    /// failure costs most.
    ///
    /// Rule: walk back over any trailing system run, then merge into the user
    /// message in front of it, or insert a new one at that position. With no
    /// trailing system run this is byte-identical to the previous
    /// merge-into-trailing-user-else-append behavior, so `.v1Legacy` is
    /// unchanged.
    static func appendUserText(_ text: String, to conversation: inout [LLMMessage]) {
        var insertAt = conversation.count
        while insertAt > 0, conversation[insertAt - 1].role == .system { insertAt -= 1 }
        if insertAt > 0, conversation[insertAt - 1].role == .user {
            let target = conversation[insertAt - 1]
            conversation[insertAt - 1] = LLMMessage(
                role: .user, content: target.content + [.text(text)]
            )
        } else {
            conversation.insert(.user(text), at: insertAt)
        }
    }

    /// PERMANENT DIAGNOSTIC: a short digest of ONE message — its role plus its
    /// serialized content — so head drift is visible in the trace.
    ///
    /// Sizes are blind to this failure: two different first messages have the
    /// same length, so `historyMessageChars` looks stable while the provider
    /// re-reads everything. Twelve hex characters is enough to compare two
    /// turns' rows by eye and far too little to reconstruct content from.
    static func messageDigest(_ message: LLMMessage) -> String {
        var hasher = SHA256()
        func feed(_ label: String, _ data: Data) {
            hasher.update(data: Data("\(label.utf8.count):\(label)\(data.count):".utf8))
            hasher.update(data: data)
        }
        feed("role", Data(message.role.rawValue.utf8))
        feed("clearAt", Data(String(message.turnScopedClearAtNextUserMessage).utf8))
        for change in message.toolChanges {
            feed("change." + change.kind.rawValue, Data(change.name.utf8))
        }
        for (index, block) in message.content.enumerated() {
            switch block {
            case .text(let text):
                feed("b\(index).text", Data(text.utf8))
            case .toolUse(let id, let name, let inputJSON):
                feed("b\(index).toolUse.id", Data(id.utf8))
                feed("b\(index).toolUse.name", Data(name.utf8))
                feed("b\(index).toolUse.input", inputJSON)
            case .toolResult(let toolUseId, let content, let isError):
                feed("b\(index).toolResult.id", Data(toolUseId.utf8))
                feed("b\(index).toolResult.content", Data(content.utf8))
                feed("b\(index).toolResult.error", Data(String(isError).utf8))
            case .image(let mediaType, let base64, let name, let byteSize):
                feed("b\(index).image.mediaType", Data(mediaType.utf8))
                feed("b\(index).image.base64", Data(base64.utf8))
                feed("b\(index).image.name", Data((name ?? "").utf8))
                feed("b\(index).image.byteSize", Data(String(max(0, byteSize)).utf8))
            }
        }
        return String(hasher.finalize().map { String(format: "%02x", $0) }.joined().prefix(12))
    }

    /// How many leading messages carry a digest. Six covers the head — where
    /// drift actually shows — without turning a trace row into a transcript.
    static let messageDigestCount = 6

    /// SHA-256 over everything that must be byte-identical from one turn to the
    /// next for a provider prefix cache to hit: the stable segments, the tool
    /// contract, and every message STRICTLY BEFORE the volatile block.
    ///
    /// Sizes and digests only — no prompt content ever leaves this function.
    static func prefixFingerprint(
        stable: String,
        stableSuffix: String,
        toolSchemaFingerprint: String,
        messagesBeforeVolatile: [LLMMessage]
    ) -> String {
        var hasher = SHA256()
        func feed(_ label: String, _ data: Data) {
            hasher.update(data: Data("\(label.utf8.count):\(label)\(data.count):".utf8))
            hasher.update(data: data)
        }
        feed("stable", Data(stable.utf8))
        feed("stableSuffix", Data(stableSuffix.utf8))
        feed("tools", Data(toolSchemaFingerprint.utf8))
        for (index, message) in messagesBeforeVolatile.enumerated() {
            feed("m\(index).role", Data(message.role.rawValue.utf8))
            for (blockIndex, block) in message.content.enumerated() {
                let prefix = "m\(index).b\(blockIndex)"
                switch block {
                case .text(let text):
                    feed(prefix + ".text", Data(text.utf8))
                case .toolUse(let id, let name, let inputJSON):
                    feed(prefix + ".toolUse.id", Data(id.utf8))
                    feed(prefix + ".toolUse.name", Data(name.utf8))
                    feed(prefix + ".toolUse.input", inputJSON)
                case .toolResult(let toolUseId, let content, let isError):
                    feed(prefix + ".toolResult.id", Data(toolUseId.utf8))
                    feed(prefix + ".toolResult.content", Data(content.utf8))
                    feed(prefix + ".toolResult.error", Data(String(isError).utf8))
                case .image(let mediaType, let base64, let name, let byteSize):
                    feed(prefix + ".image.mediaType", Data(mediaType.utf8))
                    feed(prefix + ".image.base64", Data(base64.utf8))
                    feed(prefix + ".image.name", Data((name ?? "").utf8))
                    feed(prefix + ".image.byteSize", Data(String(max(0, byteSize)).utf8))
                }
            }
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// One redacted, capped, single-line preview of conversation text for a
    /// trace row. User, 2026-09-06: redaction runs on the WHOLE string before
    /// the cap, so a secret that starts inside the kept window cannot survive
    /// as a half-matched tail.
    static func tracePreview(_ text: String, limit: Int) -> String {
        String(
            NativeAgentSecretRedactor.redactText(text)
                .replacingOccurrences(of: "\n", with: " ")
                .prefix(limit)
        )
    }

    /// Fingerprint + size receipts for one seeded turn, published to the turn
    /// trace and the `llm.call` row. Payload-free.
    /// The window facts come off the CONTEXT, not from the caller: the cursor
    /// ran ONCE, inside the context build, and every seeding site has to report
    /// that same decision rather than re-reading it from disk or passing a
    /// placeholder that quietly disagrees with it.
    static func telemetry(
        _ seed: Seed,
        shape: ConversationPrefixShape,
        toolSchemaFingerprint: String,
        toolChangePlan: StructuredToolChangePlan? = nil
    ) -> ConversationPrefixTelemetrySnapshot {
        // "What the next turn can reuse": history through the previous
        // assistant. The CURRENT user message is per-turn content and is
        // excluded — including it would make the fingerprint change every turn
        // by construction and measure nothing.
        let before = Array(seed.messages.prefix(seed.currentUserIndex))
        let segments = seed.context.systemSegments
        // TEXT-COMPAT lane: only the always-on FLOOR is inside the cached
        // prefix — the session-loaded run rides the volatile block. Hashing the
        // whole schema set here would report a moved prefix on every
        // tool_load/promotion the layout deliberately stopped moving, which is
        // the instrument lying about the exact fix it is measuring.
        let prefixToolFingerprint = seed.textToolCatalogRidesVolatileBlock
            ? SwiftNativeTurnEngine.toolSchemaFingerprint(
                seed.context.toolSchemas.filter {
                    SwiftToolDispatcher.alwaysOnCoreNames.contains($0.name)
                }
            )
            : toolSchemaFingerprint
        return ConversationPrefixTelemetrySnapshot(
            shapeVersion: shape.rawValue,
            prefixFingerprintSHA256: prefixFingerprint(
                stable: segments?.stable ?? seed.context.systemPrompt ?? "",
                stableSuffix: segments?.stableSuffix ?? "",
                toolSchemaFingerprint: prefixToolFingerprint,
                messagesBeforeVolatile: before
            ),
            historyMessageCount: seed.context.historyMessages.count,
            historyMessageChars: seed.context.historyMessages.reduce(0) { total, message in
                total + message.content.reduce(0) {
                    if case .text(let text) = $1 { return $0 + text.count }
                    return $0
                }
            },
            volatileBlockChars: seed.context.turnVolatileBlock?.count ?? 0,
            volatileDelivery: seed.delivery.rawValue,
            windowCursorAdvanceCount: seed.context.historyWindowReceipt?.advanceCount ?? 0,
            windowSlid: seed.context.historyWindowReceipt?.slid ?? false,
            messageCount: seed.messages.count,
            messageDigests: seed.messages.prefix(messageDigestCount).map(messageDigest),
            toolChanges: toolChangePlan.map {
                .init(
                    arrayFingerprintSHA256: SwiftNativeTurnEngine
                        .toolSchemaFingerprint($0.array),
                    offeredCount: $0.offered.count,
                    additionCount: $0.additions.count,
                    removalCount: $0.removals.count,
                    droppedUnknownCount: $0.droppedUnknown.count,
                    declarationGeneration: $0.declarationGeneration
                )
            },
            prefixMessageDigests: before.map(messageDigest),
            // User, 2026-09-06: these previews are RAW CONVERSATION TEXT and they
            // ride into the `llm.call` trace row and the persisted telemetry
            // file, which the rest of this payload deliberately keeps to
            // counts/timings/identifiers. A key or token pasted into the first
            // messages was copied there verbatim. Every preview now goes
            // through the canonical redactor (the one inner_state uses,
            // [REDACTED_*]) BEFORE truncation — truncating first would cut a
            // secret in half and leave the tail unmatched — and the caps are
            // shorter: this is a prefix-shape probe, not a transcript.
            headPreviews: (before.prefix(4).map { message in
                let text = message.content.compactMap { block -> String? in
                    if case .text(let t) = block { return t }
                    return nil
                }.joined(separator: " ")
                return "\(message.role.rawValue): " + Self.tracePreview(text, limit: 64)
            }) + (before.count > 1 ? before[1].content.prefix(16).enumerated().map { index, block -> String in
                if case .text(let t) = block {
                    return "m1.\(index)[\(t.count)]: " + Self.tracePreview(t, limit: 48)
                }
                return "m1.\(index): <non-text>"
            } : []) + [],
        )
    }
}
