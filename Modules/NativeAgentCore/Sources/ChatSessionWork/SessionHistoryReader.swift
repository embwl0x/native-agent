import Foundation
import CryptoKit
import NativeAgentCore
import os
import PersistenceCore
import TurnTrace
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
    package func historyIdentity(renderedRole: String? = nil, renderedContent: String? = nil) -> String {
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

    /// Shared so turn assembly resolves the model-window policy against
    /// the same data root as the history reader.
    package nonisolated let dataRoot: URL

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
        excludingRunId: String? = nil,
        strictEvidence: Bool = false,
        maximumBytes: Int? = nil,
        transcriptURL: URL? = nil
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
        let path = transcriptURL ?? dataRoot
            .appendingPathComponent("chat", isDirectory: true)
            .appendingPathComponent("messages", isDirectory: true)
            .appendingPathComponent("\(safeId).jsonl")
        let parent = path.resolvingSymlinksInPath().deletingLastPathComponent()
        let compacted = path.lastPathComponent.hasPrefix("messages.compact.") && path.pathExtension == "jsonl"
            && parent == dataRoot.appendingPathComponent("chat/sessions/\(safeId)").resolvingSymlinksInPath()
        guard compacted || ["chat/messages", "chat/archive/messages", "chat/archive/originals"].contains(where: {
            parent == dataRoot.appendingPathComponent($0).resolvingSymlinksInPath()
        }) else { throw CocoaError(.fileReadNoPermission) }
        if !strictEvidence, !FileManager.default.fileExists(atPath: path.path) {
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
        if let limit, limit > 0, !strictEvidence {
            // A bounded tail: only the bytes the selection needs, from the end.
            let handle = try? FileHandle(forReadingFrom: path)
            let result = Self.tailLinesResult(
                size: (try? handle?.seekToEnd()).map(Int.init) ?? 0,
                minimumLineCount: max(64, limit * 3),
                maximumBytes: maximumBytes
            ) { offset, count in
                (try? handle?.seek(toOffset: UInt64(offset))).flatMap { _ in try? handle?.read(upToCount: count) }
            }
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
                    stats: SessionHistoryReadStats(mode:
                        (error as? CocoaError)?.code == .fileReadNoSuchFile ? "missing" : "read_failed")
                )
            }
            // Exact evidence reads must not silently replace damaged bytes.
            // Ordinary prompt projection retains its established tolerance.
            let text: String
            if strictEvidence {
                guard let decoded = String(data: data, encoding: .utf8) else {
                    return SessionHistoryReadResult(messages: [], stats: SessionHistoryReadStats(
                        mode: "invalid_encoding", sourceBytes: Int64(data.count), bytesRead: Int64(data.count)
                    ))
                }
                text = decoded
            } else {
                text = String(decoding: data, as: UTF8.self)
            }
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

    /// Check provenance across the whole donor, retaining only a bounded tail.
    /// A stale index cannot certify rows outside the prompt's sampled window.
    /// Unreadable, damaged, or changing evidence throws; participant mismatch
    /// or oversized rows disable handoff. The row limit is independent of the
    /// retained tail budget and admits 40,000-character Unicode recollections.
    package nonisolated static func continuityMessages(
        forSessionId id: String,
        dataRoot: URL,
        limit: Int,
        maximumBytes: Int,
        matching: @Sendable (ChatMessage) -> Bool
    ) throws -> [ChatMessage]? {
        guard let safeId = NativeAgentChatSessionID.normalizedPathComponent(id),
              limit > 0, maximumBytes > 0 else { throw CocoaError(.fileReadInvalidFileName) }
        let path = dataRoot.appendingPathComponent("chat/messages/\(safeId).jsonl")
        let attributes = try FileManager.default.attributesOfItem(atPath: path.path)
        let handle = try FileHandle(forReadingFrom: path)
        defer { try? handle.close() }
        let size = try handle.seekToEnd()
        try handle.seek(toOffset: 0)
        let maximumRowBytes = 1024 * 1024
        var remaining = size
        var pending = Data()
        var tail: [(message: ChatMessage, bytes: Int)] = []
        var tailBytes = 0

        func admit(_ line: Data) throws -> Bool {
            guard line.count <= maximumRowBytes else { return false }
            guard let text = String(data: line, encoding: .utf8) else {
                throw CocoaError(.fileReadInapplicableStringEncoding)
            }
            let decoded = Self.decodeMessages(from: [text], excludingRunId: nil)
            guard decoded.malformedRowCount == 0, decoded.invalidShapeRowCount == 0 else {
                throw CocoaError(.coderReadCorrupt)
            }
            for message in decoded.messages {
                guard matching(message) else { return false }
                tail.append((message, line.count))
                tailBytes += line.count
                while tail.count > limit || tailBytes > maximumBytes {
                    tailBytes -= tail.removeFirst().bytes
                }
            }
            return true
        }

        while remaining > 0 {
            try Task.checkCancellation()
            guard let chunk = try handle.read(upToCount: Int(min(remaining, 64 * 1024))),
                  !chunk.isEmpty else { throw CocoaError(.fileReadCorruptFile) }
            remaining -= UInt64(chunk.count)
            pending.append(chunk)
            while let newline = pending.firstIndex(of: 0x0A) {
                guard try admit(Data(pending[..<newline])) else { return nil }
                pending.removeSubrange(...newline)
            }
            guard pending.count <= maximumRowBytes else { return nil }
        }
        if !pending.isEmpty, try !admit(pending) { return nil }
        let settled = try FileManager.default.attributesOfItem(atPath: path.path)
        for key in [FileAttributeKey.size, .modificationDate, .systemFileNumber] {
            guard let before = attributes[key] as? NSObject,
                  let after = settled[key] as? NSObject, before == after else {
                throw CocoaError(.fileReadUnknown)
            }
        }
        return tail.map(\.message)
    }

    /// The one read of a session's live transcript for a turn. Every prompt
    /// selection below runs over these bytes, whether they come from here or
    /// from the compactor's validated read of the same file this turn. nil:
    /// no transcript (or no valid id), which selects as empty history.
    public func transcriptBytes(forSessionId id: String) throws -> Data? {
        guard let safeId = NativeAgentChatSessionID.normalizedPathComponent(id) else { return nil }
        let path = dataRoot.appendingPathComponent("chat/messages/\(safeId).jsonl")
        do { return try Data(contentsOf: path) } catch CocoaError.fileReadNoSuchFile { return nil }
    }

    /// The first few messages plus a bounded tail. This lets the prompt
    /// renderer keep true opening anchors for continuity without decoding an
    /// entire large JSONL transcript on every turn.
    public nonisolated func promptMessagesWithStats(
        transcript: Data?,
        anchorLimit: Int = 3,
        tailLimit: Int,
        excludingRunId: String? = nil
    ) -> SessionHistoryReadResult {
        guard let transcript else {
            return SessionHistoryReadResult(
                messages: [],
                stats: SessionHistoryReadStats(mode: "missing")
            )
        }
        let excludedRunId = excludingRunId?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let shouldExcludeRun = excludedRunId?.isEmpty == false
        if tailLimit <= 0 {
            return SessionHistoryReadResult(
                messages: [],
                stats: SessionHistoryReadStats(mode: "tail_zero")
            )
        }
        let head = Self.headLinesResult(
            from: transcript,
            maximumLineCount: max(0, anchorLimit),
            maximumBytes: Self.promptHeadMaximumBytes
        )
        let tail = Self.tailLinesResult(
            from: transcript,
            minimumLineCount: max(64, tailLimit),
            maximumBytes: Self.promptTailMaximumBytes
        )
        let decodeResult = Self.decodeMessages(
            from: head.lines + tail.lines,
            excludingRunId: shouldExcludeRun ? excludedRunId : nil,
            excludingAwaitingConsumption: true
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
    /// Small transcripts are cheap enough to decode exactly. Large transcripts
    /// are sampled through fixed-size interior windows; exact older wording is
    /// still available through the explicit search_chat_history tool. JSONL
    /// remains authoritative and this projection owns no stale sidecar state.
    /// From the file, reading only the windows it samples.
    public func relevanceMessagesWithStats(
        forSessionId id: String,
        excludingRunId: String? = nil
    ) throws -> SessionHistoryReadResult {
        guard let safeId = NativeAgentChatSessionID.normalizedPathComponent(id) else {
            return SessionHistoryReadResult(messages: [], stats: SessionHistoryReadStats(mode: "invalid_session_id"))
        }
        let path = dataRoot.appendingPathComponent("chat/messages/\(safeId).jsonl")
        guard FileManager.default.fileExists(atPath: path.path) else {
            return SessionHistoryReadResult(messages: [], stats: SessionHistoryReadStats(mode: "missing"))
        }
        guard let handle = try? FileHandle(forReadingFrom: path), let size = try? handle.seekToEnd() else {
            return SessionHistoryReadResult(messages: [], stats: SessionHistoryReadStats(mode: "read_failed"))
        }
        return relevanceMessagesWithStats(size: Int(size), excludingRunId: excludingRunId) { offset, count in
            (try? handle.seek(toOffset: UInt64(offset))).flatMap { _ in try? handle.read(upToCount: count) }
        }
    }

    /// From the bytes this turn already holds.
    public nonisolated func relevanceMessagesWithStats(
        transcript: Data?,
        excludingRunId: String? = nil
    ) -> SessionHistoryReadResult {
        guard let transcript else {
            return SessionHistoryReadResult(
                messages: [],
                stats: SessionHistoryReadStats(mode: "missing")
            )
        }
        return relevanceMessagesWithStats(size: transcript.count, excludingRunId: excludingRunId) {
            transcript.subdata(in: (transcript.startIndex + $0)..<(transcript.startIndex + $0 + $1))
        }
    }

    private nonisolated func relevanceMessagesWithStats(
        size: Int,
        excludingRunId: String?,
        bytes: (_ offset: Int, _ count: Int) -> Data?
    ) -> SessionHistoryReadResult {
        let excludedRunId = excludingRunId?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let shouldExcludeRun = excludedRunId?.isEmpty == false
        let lineRead: SessionHistoryLineReadResult
        let mode: String
        if size <= Self.relevanceFullReadMaximumBytes {
            guard let whole = bytes(0, size) else {
                return SessionHistoryReadResult(messages: [], stats: SessionHistoryReadStats(mode: "read_failed"))
            }
            lineRead = Self.allLinesResult(from: whole)
            mode = "relevance_full_small"
        } else {
            lineRead = Self.sampledLinesResult(
                size: size,
                maximumBytes: Self.relevanceSampleMaximumBytes,
                windowCount: Self.relevanceSampleWindowCount,
                bytes: bytes
            )
            mode = "relevance_sampled"
        }
        let decodeResult = Self.decodeMessages(
            from: lineRead.lines,
            excludingRunId: shouldExcludeRun ? excludedRunId : nil,
            excludingAwaitingConsumption: true
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
                mode: mode,
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

    /// The last lines, read back from the end in 64 KB steps, each counted
    /// once, until at least `minimumLineCount` complete rows or the byte
    /// budget. `bytes(offset, count)` reads from bytes in hand or from the
    /// file alike, so a tail never has to read the whole transcript.
    private nonisolated static func tailLinesResult(
        size: Int,
        minimumLineCount: Int,
        maximumBytes: Int? = nil,
        bytes: (_ offset: Int, _ count: Int) -> Data?
    ) -> SessionHistoryLineReadResult {
        guard minimumLineCount > 0, size > 0 else {
            return SessionHistoryLineReadResult(lines: [], sourceBytes: 0, bytesRead: 0, truncated: false)
        }
        let byteLimit = max(1, maximumBytes ?? Int.max)
        var offset = size
        var chunks: [Data] = []
        var lineCount = 0
        while offset > 0 && lineCount <= minimumLineCount && size - offset < byteLimit {
            let readSize = min(64 * 1024, offset, byteLimit - (size - offset))
            offset -= readSize
            guard let chunk = bytes(offset, readSize), chunk.count == readSize else {
                return SessionHistoryLineReadResult(
                    lines: [], sourceBytes: Int64(size), bytesRead: Int64(size - offset), truncated: offset > 0)
            }
            lineCount += chunk.reduce(0) { count, byte in count + (byte == 0x0A ? 1 : 0) }
            chunks.append(chunk)
        }
        var lines = String(decoding: chunks.reversed().reduce(into: Data(capacity: size - offset)) { $0.append($1) },
                           as: UTF8.self)
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
            sourceBytes: Int64(size),
            bytesRead: Int64(size - offset),
            truncated: offset > 0
        )
    }

    private nonisolated static func tailLinesResult(
        from data: Data,
        minimumLineCount: Int,
        maximumBytes: Int? = nil
    ) -> SessionHistoryLineReadResult {
        tailLinesResult(size: data.count, minimumLineCount: minimumLineCount, maximumBytes: maximumBytes) {
            data.subdata(in: (data.startIndex + $0)..<(data.startIndex + $0 + $1))
        }
    }

    private nonisolated static func headLinesResult(
        from data: Data,
        maximumLineCount: Int,
        maximumBytes: Int? = nil
    ) -> SessionHistoryLineReadResult {
        guard maximumLineCount > 0 else {
            return SessionHistoryLineReadResult(lines: [], sourceBytes: 0, bytesRead: 0, truncated: false)
        }
        let byteLimit = max(1, maximumBytes ?? Int.max)
        var end = 0
        var lineCount = 0
        while lineCount < maximumLineCount && end < byteLimit && end < data.count {
            let next = min(end + 16 * 1024, byteLimit, data.count)
            lineCount += data[(data.startIndex + end)..<(data.startIndex + next)]
                .reduce(0) { count, byte in count + (byte == 0x0A ? 1 : 0) }
            end = next
        }
        var lines = String(decoding: data[data.startIndex..<(data.startIndex + end)], as: UTF8.self)
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map(String.init)
        if lines.count > maximumLineCount {
            lines = Array(lines.prefix(maximumLineCount))
        }
        return SessionHistoryLineReadResult(
            lines: lines,
            sourceBytes: Int64(data.count),
            bytesRead: Int64(end),
            truncated: end < data.count
        )
    }

    private nonisolated static func allLinesResult(from data: Data) -> SessionHistoryLineReadResult {
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
    /// window and cannot force the reader to chase their boundary. Only the
    /// sampled windows are read, from the file or from bytes in hand alike.
    private nonisolated static func sampledLinesResult(
        size: Int,
        maximumBytes: Int,
        windowCount: Int,
        bytes: (_ offset: Int, _ count: Int) -> Data?
    ) -> SessionHistoryLineReadResult {
        guard maximumBytes > 0, windowCount > 0, size > 0 else {
            return SessionHistoryLineReadResult(lines: [], sourceBytes: 0, bytesRead: 0, truncated: false)
        }
        let effectiveCount = min(windowCount, maximumBytes)
        let windowSize = max(1, maximumBytes / effectiveCount)
        let readableWindow = min(windowSize, size)
        let maximumStart = size - readableWindow
        var lines: [String] = []
        var bytesRead: Int64 = 0

        for index in 1...effectiveCount {
            let fraction = Double(index) / Double(effectiveCount + 1)
            let start = Int(Double(maximumStart) * fraction)
            guard let window = bytes(start, readableWindow) else { continue }
            bytesRead += Int64(window.count)
            var lower = window.startIndex
            var upper = window.endIndex
            if start > 0 {
                guard let newline = window.firstIndex(of: 0x0A) else { continue }
                lower = window.index(after: newline)
            }
            if start + window.count < size {
                guard let newline = window.lastIndex(of: 0x0A), newline >= lower else { continue }
                upper = newline
            }
            guard lower < upper else { continue }
            lines.append(contentsOf: String(decoding: window[lower..<upper], as: UTF8.self)
                .split(separator: "\n", omittingEmptySubsequences: true)
                .map(String.init))
        }
        return SessionHistoryLineReadResult(
            lines: lines,
            sourceBytes: Int64(size),
            bytesRead: bytesRead,
            truncated: bytesRead < Int64(size)
        )
    }
    private nonisolated static func decodeMessages(
        from lines: [String],
        excludingRunId: String?,
        excludingAwaitingConsumption: Bool = false
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
            if excludingAwaitingConsumption, case .object(let metadata)? = obj["metadata"],
               metadata["awaitingConsumption"] == .bool(true) { continue }
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
