import Foundation
import CryptoKit
import NativeAgentCore
import PersistenceCore
import TurnTrace
// Blueprint: | `SessionHistoryReader.swift` | `SessionHistoryReader` actor; `promptMessagesWithStats` retains the cursor boundary regardless of raw bytes/rows; `messages`, `messagesWithStats`; initialization leaves retired middle-index files untouched |

// MARK: - ChatMessage

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
    /// Rows skipped because they belong to the current run. This is
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
    public let contextStatistics: (totalChars: Int, messageCount: Int)

    public init(messages: [ChatMessage], stats: SessionHistoryReadStats, contextStatistics: (totalChars: Int, messageCount: Int) = (0, 0)) {
        self.messages = messages
        self.stats = stats
        self.contextStatistics = contextStatistics
    }
}

private struct SessionHistoryLineReadResult: Sendable {
    let lines: [String]
    let sourceBytes: Int64
    let bytesRead: Int64
    let truncated: Bool
}

// MARK: - SessionHistoryReader

/// Reads chat session history from disk. Sessions live in
/// a single JSON list at `data/chat/sessions.json` and
/// per-session messages at `data/chat/messages/<id>.jsonl`.
public actor SessionHistoryReader {
    /// Opening anchors and relevance sampling have their own bounded reads;
    /// the replayed head belongs exclusively to HistoryWindowCursorStore.
    private static let promptHeadMaximumBytes = 64 * 1024
    private static let relevanceFullReadMaximumBytes = 128 * 1024
    private static let relevanceSampleMaximumBytes = 96 * 1024
    private static let relevanceSampleWindowCount = 8

    /// Shared so turn assembly resolves the model-window policy against
    /// the same data root as the history reader.
    package nonisolated let dataRoot: URL

    public init(dataRoot: URL = PersistenceCore.defaultDataRoot()) {
        self.dataRoot = dataRoot
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
        let path = try transcriptPath(for: safeId, transcriptURL: transcriptURL)
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
        var validEncoding = true
        if let limit, limit > 0, !strictEvidence {
            // A bounded tail: only the bytes the selection needs, from the end.
            // A file that will not open, seek or read whole is read_failed,
            // never an empty tail.
            let handle = try? FileHandle(forReadingFrom: path)
            let size = (try? handle?.seekToEnd()).map(Int.init)
            var unread = size == nil
            let result = Self.tailLinesResult(
                size: size ?? 0,
                minimumLineCount: max(64, limit * 3),
                maximumBytes: maximumBytes
            ) { offset, count in
                let chunk = (try? handle?.seek(toOffset: UInt64(offset))).flatMap { _ in try? handle?.read(upToCount: count) }
                if chunk?.count != count { unread = true }
                return chunk
            }
            lines = result.lines
            sourceBytes = result.sourceBytes
            bytesRead = result.bytesRead
            truncatedRead = result.truncated
            mode = unread ? "read_failed" : "tail"
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
                validEncoding = String(data: data, encoding: .utf8) != nil
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
            ),
            contextStatistics: validEncoding ? decodeResult.contextStatistics : (0, 0)
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

    /// Opening anchors, every recollection, and the cursor's contiguous window.
    /// The tail is a minimum read width, never another owner of the head. With
    /// no surviving boundary, admit the transcript so the cursor can establish
    /// one under its rendered-row and character budgets.
    public nonisolated func promptMessagesWithStats(
        transcript: Data?,
        anchorLimit: Int = 3,
        tailLimit: Int,
        windowCursor: HistoryWindowCursor,
        excludingRunId: String? = nil,
        relevanceWhen: (SessionHistoryReadResult) -> Bool = { _ in false }
    ) -> (prompt: SessionHistoryReadResult, relevance: SessionHistoryReadResult?) {
        guard let transcript else {
            return (SessionHistoryReadResult(
                messages: [],
                stats: SessionHistoryReadStats(mode: "missing")
            ), nil)
        }
        let excludedRunId = excludingRunId?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let shouldExcludeRun = excludedRunId?.isEmpty == false
        if tailLimit <= 0 {
            return (SessionHistoryReadResult(
                messages: [],
                stats: SessionHistoryReadStats(mode: "tail_zero")
            ), nil)
        }
        var rows: [String: DecodedRow] = [:]
        func decode(_ line: String) -> DecodedRow {
            if let row = rows[line] { return row }
            let row = Self.decodeRow(line)
            rows[line] = row
            return row
        }
        let head = Self.headLinesResult(
            from: transcript,
            maximumLineCount: max(0, anchorLimit),
            maximumBytes: Self.promptHeadMaximumBytes
        )
        let lines = String(decoding: transcript, as: UTF8.self)
            .split(separator: "\n", omittingEmptySubsequences: true)
        var windowStart = 0
        if let boundary = windowCursor.dropBoundaryIdentity {
            for index in lines.indices.reversed() {
                let decoded = Self.decodeMessages(from: [String(lines[index])],
                    excludingRunId: nil, excludingAwaitingConsumption: true, decode: decode)
                guard let row = decoded.messages.first else { continue }
                let identity = boundary.hasPrefix("id\u{1F}") ? row.historyIdentity()
                    : SessionHistoryPromptRenderer.renderable(row)?.historyIdentity
                if identity == boundary {
                    windowStart = index
                    break
                }
            }
        }
        // Raw payload size cannot displace the cursor's actual boundary.
        let tailStart = min(windowStart, max(0, lines.count - max(64, tailLimit)))
        var selected: [String] = []
        for (index, line) in lines.enumerated() {
            let text = String(line)
            if index >= tailStart || (index < head.lines.count && head.lines[index] == text) {
                selected.append(text)
                continue
            }
            // Only older recollection candidates need decoding.
            if text.contains("compaction_summary"), case .object(let fields)? = decode(text).value,
               case .object(let metadata)? = fields["metadata"], metadata["kind"] == .string("compaction_summary") {
                selected.append(text)
            } else if index < head.lines.count {
                selected.append(head.lines[index])
            }
        }
        let prompt = Self.selectionResult(
            SessionHistoryLineReadResult(lines: selected, sourceBytes: Int64(transcript.count),
                bytesRead: Int64(transcript.count), truncated: selected.count < lines.count),
            mode: "cursor_recollections_tail", excludingRunId: shouldExcludeRun ? excludedRunId : nil, decode: decode)
        let relevance = relevanceWhen(prompt) ? relevanceMessagesWithStats(
            size: transcript.count, excludingRunId: excludingRunId, decode: decode
        ) { transcript.subdata(in: (transcript.startIndex + $0)..<(transcript.startIndex + $0 + $1)) } : nil
        return (prompt, relevance)
    }

    /// Return bounded candidates for semantic "earlier session" ranking.
    /// Small transcripts are cheap enough to decode exactly. Large transcripts
    /// are sampled through fixed-size interior windows; exact older wording is
    /// still available through the explicit search_chat_history tool. JSONL
    /// remains authoritative and this projection owns no stale sidecar state.
    /// From the file, reading only the windows it samples.
    public func relevanceMessagesWithStats(
        forSessionId id: String,
        excludingRunId: String? = nil,
        transcriptURL: URL? = nil
    ) throws -> SessionHistoryReadResult {
        guard let safeId = NativeAgentChatSessionID.normalizedPathComponent(id) else {
            return SessionHistoryReadResult(messages: [], stats: SessionHistoryReadStats(mode: "invalid_session_id"))
        }
        let path = try transcriptPath(for: safeId, transcriptURL: transcriptURL)
        guard FileManager.default.fileExists(atPath: path.path) else {
            return SessionHistoryReadResult(messages: [], stats: SessionHistoryReadStats(mode: "missing"))
        }
        guard let handle = try? FileHandle(forReadingFrom: path), let size = try? handle.seekToEnd() else {
            return SessionHistoryReadResult(messages: [], stats: SessionHistoryReadStats(mode: "read_failed"))
        }
        var unread = false
        let result = relevanceMessagesWithStats(size: Int(size), excludingRunId: excludingRunId) { offset, count in
            let chunk = (try? handle.seek(toOffset: UInt64(offset))).flatMap { _ in try? handle.read(upToCount: count) }
            if chunk?.count != count { unread = true }
            return chunk
        }
        return unread ? SessionHistoryReadResult(messages: [], stats: SessionHistoryReadStats(mode: "read_failed")) : result
    }

    private func transcriptPath(for safeId: String, transcriptURL: URL?) throws -> URL {
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
        return path
    }

    private nonisolated func relevanceMessagesWithStats(
        size: Int,
        excludingRunId: String?,
        decode: (String) -> DecodedRow = SessionHistoryReader.decodeRow,
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
        return Self.selectionResult(lineRead, mode: mode,
            excludingRunId: shouldExcludeRun ? excludedRunId : nil, decode: decode)
    }

    private nonisolated static func selectionResult(
        _ lineRead: SessionHistoryLineReadResult, mode: String,
        excludingRunId: String?, decode: (String) -> DecodedRow
    ) -> SessionHistoryReadResult {
        let decodeResult = decodeMessages(
            from: lineRead.lines,
            excludingRunId: excludingRunId,
            excludingAwaitingConsumption: true, decode: decode
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
    package typealias DecodedRow = (value: JSONValue?, role: String?, content: String?, timestamp: String?, contextStatistics: (totalChars: Int, messageCount: Int))

    /// Parse one row's canonical fields and raw-object context counts; preserve invalid JSON shapes.
    package nonisolated static func decodeRow(_ line: String) -> DecodedRow {
        let lineData = Data(line.trimmingCharacters(in: .whitespacesAndNewlines).utf8)
        var statistics = (totalChars: 0, messageCount: 0)
        let parsed: JSONValue? = autoreleasepool {
            let raw = try? JSONSerialization.jsonObject(with: lineData, options: [.fragmentsAllowed])
            if let object = raw as? [String: Any] {
                statistics.messageCount = 1
                if let content = object["content"] as? String {
                    statistics.totalChars = content.count
                } else if let content = object["content"],
                          let bytes = try? JSONSerialization.data(withJSONObject: content) {
                    statistics.totalChars = bytes.count
                }
            }
            // Non-finite legacy tokens remain readable but never count as raw JSON objects.
            return raw.map { JSONValue(fromFoundation: $0) } ?? (try? JSONValue.parse(lineData))
        }
        guard case .object(let row)? = parsed else { return (parsed, nil, nil, nil, statistics) }
        func string(_ key: String) -> String? { if case .string(let text)? = row[key] { return text }; return nil }
        return (parsed, string("role"), string("content") ?? string("text"), string("createdAt") ?? string("timestamp"), statistics)
    }

    private nonisolated static func decodeMessages(
        from lines: [String],
        excludingRunId: String?,
        excludingAwaitingConsumption: Bool = false,
        decode: (String) -> DecodedRow = SessionHistoryReader.decodeRow
    ) -> (
        messages: [ChatMessage],
        excludedByRunId: Int,
        malformedRowCount: Int,
        invalidShapeRowCount: Int,
        contextStatistics: (totalChars: Int, messageCount: Int)
    ) {
        var msgs: [ChatMessage] = []
        var excludedCount = 0
        var malformedCount = 0
        var invalidShapeCount = 0
        var contextStatistics = (totalChars: 0, messageCount: 0)
        msgs.reserveCapacity(lines.count)
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { continue }
            let decoded = decode(line)
            contextStatistics.totalChars += decoded.contextStatistics.totalChars
            contextStatistics.messageCount += decoded.contextStatistics.messageCount
            guard let parsed = decoded.value else { malformedCount += 1; continue }
            guard case .object(let obj) = parsed else { invalidShapeCount += 1; continue }
            if excludingAwaitingConsumption, case .object(let metadata)? = obj["metadata"],
               metadata["awaitingConsumption"] == .bool(true) { continue }
            if let excludingRunId,
               message(parsed, hasRunId: excludingRunId) {
                excludedCount += 1
                continue
            }
            guard let role = decoded.role, let content = decoded.content else {
                invalidShapeCount += 1
                continue
            }
            msgs.append(ChatMessage(
                role: role,
                content: content,
                timestamp: decoded.timestamp ?? "",
                extras: parsed
            ))
        }
        return (msgs, excludedCount, malformedCount, invalidShapeCount, contextStatistics)
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

}
