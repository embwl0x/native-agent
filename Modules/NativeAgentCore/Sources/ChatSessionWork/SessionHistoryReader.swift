import Foundation
import CryptoKit
import NativeAgentCore
import PersistenceCore
import TurnTrace
import Transcripts
import Synchronization
// Blueprint: | `SessionHistoryReader.swift` | `SessionHistoryReader`, `messages`, `messagesWithStats`. |

// MARK: - ChatMessage

public struct ChatMessage: Sendable, Codable {
    public let role: String
    public let content: String
    public let timestamp: String
    public let extras: JSONValue?

    // Memoize only immutable row fields; Codable transports the original four fields without cached state.
    private let rendering = HistoryRenderingMemo()
    private enum CodingKeys: String, CodingKey { case role, content, timestamp, extras }

    package func renderedHistory(
        _ build: () -> SessionHistoryPromptRenderer.Renderable?
    ) -> SessionHistoryPromptRenderer.Renderable? {
        rendering.value(build)
    }

    public init(role: String, content: String, timestamp: String, extras: JSONValue?) {
        self.role = role
        self.content = content
        self.timestamp = timestamp
        self.extras = extras
    }
}

private final class HistoryRenderingMemo: Sendable {
    private enum State: Sendable {
        case unread
        case rendered(SessionHistoryPromptRenderer.Renderable?)
    }
    private let state = Mutex<State>(.unread)

    func value(_ build: () -> SessionHistoryPromptRenderer.Renderable?) -> SessionHistoryPromptRenderer.Renderable? {
        state.withLock { state in
            if case .rendered(let value) = state { return value }
            let value = build()
            state = .rendered(value)
            return value
        }
    }
}

extension ChatMessage {
    /// The saved row is the only identity; missing identity remains unavailable.
    package func historyIdentity() -> String? {
        if case .object(let record)? = extras,
           case .string(let id)? = record["id"], !id.isEmpty {
            return "id\u{1F}\(id)"
        }
        return nil
    }
}

public struct SessionHistoryReadStats: Sendable, Equatable {
    public let mode: String
    public let sourceBytes: Int64
    public let bytesRead: Int64
    public let linesRead: Int
    public let decodedCount: Int
    /// Undecodable rows remain on disk; diagnostics expose them without automatic repair.
    public let malformedRowCount: Int
    public let invalidShapeRowCount: Int
    /// Identify exact selected bytes without retaining private speech in diagnostics.
    public let damageEvidence: [String]
    public let returnedCount: Int
    /// Count current-run exclusions separately so empty history cannot hide decoded rows intentionally skipped.
    public let excludedByRunId: Int
    public let truncated: Bool
    public let decodeCacheHits: Int
    public let decodeCacheMisses: Int

    public init(
        mode: String,
        sourceBytes: Int64 = 0,
        bytesRead: Int64 = 0,
        linesRead: Int = 0,
        decodedCount: Int = 0,
        malformedRowCount: Int = 0,
        invalidShapeRowCount: Int = 0,
        damageEvidence: [String] = [],
        excludedByRunId: Int = 0,
        returnedCount: Int = 0,
        truncated: Bool = false,
        decodeCacheHits: Int = 0,
        decodeCacheMisses: Int = 0
    ) {
        self.mode = mode
        self.sourceBytes = sourceBytes
        self.bytesRead = bytesRead
        self.linesRead = linesRead
        self.decodedCount = decodedCount
        self.malformedRowCount = malformedRowCount
        self.invalidShapeRowCount = invalidShapeRowCount
        self.damageEvidence = damageEvidence
        self.excludedByRunId = excludedByRunId
        self.returnedCount = returnedCount
        self.truncated = truncated
        self.decodeCacheHits = decodeCacheHits
        self.decodeCacheMisses = decodeCacheMisses
    }
}

public struct SessionHistoryReadResult: Sendable {
    public fileprivate(set) var messages: [ChatMessage]
    public fileprivate(set) var stats: SessionHistoryReadStats
    public fileprivate(set) var contextStatistics: (totalChars: Int, messageCount: Int)

    public init(messages: [ChatMessage], stats: SessionHistoryReadStats, contextStatistics: (totalChars: Int, messageCount: Int) = (0, 0)) {
        self.messages = messages
        self.stats = stats
        self.contextStatistics = contextStatistics
    }

    public func checkedMessages() throws -> [ChatMessage] {
        guard !["invalid_session_id", "read_failed", "invalid_encoding", "damaged_history"].contains(stats.mode),
              stats.malformedRowCount == 0, stats.invalidShapeRowCount == 0 else {
            throw SessionTranscriptError(
                errorDescription: """
                    Conversation history is unavailable (\(stats.mode), \(stats.malformedRowCount) malformed rows, \(stats.invalidShapeRowCount) invalid \
                    message rows). \(stats.damageEvidence.joined(separator: "; ")). Repair the retained transcript before reading it.
                    """)
        }
        return messages
    }
}

private struct SessionHistoryLineReadResult: Sendable {
    let lines: [String]
    let sourceBytes: Int64
    let bytesRead: Int64
    let truncated: Bool
    var invalidEncoding = false
}

// MARK: - SessionHistoryReader

public actor SessionHistoryReader {
    // Memoize pure transforms by exact UTF-8 input, never file state; every call selects from its supplied read.
    // One memo serves every conversation: a read adds the lines it used, and only the least recently read lines go
    // once their bytes pass the cap (about three times every transcript the agent keeps today).
    private struct PromptRowMemo: Sendable {
        var rows: [Data: (row: DecodedRow, read: UInt64)] = [:]
        var bytes = 0
        var reads: UInt64 = 0
    }
    private static let promptRowMemo = Mutex(PromptRowMemo())
    private static let promptRowMemoMaximumBytes = 48 * 1024 * 1024
    private static let relevanceFullReadMaximumBytes = 128 * 1024
    private static let relevanceSampleMaximumBytes = 96 * 1024
    private static let relevanceSampleWindowCount = 8

    /// Use the history reader's data root when resolving model-window policy.
    package nonisolated let dataRoot: URL

    public init(dataRoot: URL = PersistenceCore.defaultDataRoot()) {
        self.dataRoot = dataRoot
    }

    /// Read oldest-first, tail-bounded when requested; exclude the already-persisted current run so it cannot replay as prior history.
    public func messages(
        forSessionId id: String,
        limit: Int? = nil,
        excludingRunId: String? = nil
    ) async throws -> [ChatMessage] {
        try await messagesWithStats(
            forSessionId: id,
            limit: limit,
            excludingRunId: excludingRunId
        ).checkedMessages()
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
            // Read only the tail selection's bytes; failed open, seek or read remains read_failed, never an empty tail.
            let handle: FileHandle
            do { handle = try FileHandle(forReadingFrom: path) }
            catch let error as CocoaError where error.isFileAbsent {
                return SessionHistoryReadResult(messages: [], stats: SessionHistoryReadStats(mode: "missing"))
            }
            defer { try? handle.close() }
            let size = try handle.seekToEnd()
            var readFailure: (any Error)?
            let selectionLines = limit > Int.max / 3 ? Int.max : limit * 3
            let result = Self.tailLinesResult(
                size: Int(size),
                minimumLineCount: max(64, selectionLines),
                maximumBytes: maximumBytes
            ) { offset, count in
                do {
                    try handle.seek(toOffset: UInt64(offset))
                    let chunk = try handle.read(upToCount: count)
                    guard chunk?.count == count else { throw CocoaError(.fileReadCorruptFile) }
                    return chunk
                } catch { readFailure = error; return nil }
            }
            if let readFailure { throw readFailure }
            lines = result.lines
            sourceBytes = result.sourceBytes
            bytesRead = result.bytesRead
            truncatedRead = result.truncated
            mode = result.invalidEncoding ? "invalid_encoding" : "tail"
        } else {
            let data: Data
            do {
                data = try Data(contentsOf: path)
            } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
                return SessionHistoryReadResult(
                    messages: [],
                    stats: SessionHistoryReadStats(mode: "missing")
                )
            }
            let text: String
            do {
                guard let decoded = String(data: data, encoding: .utf8) else {
                    return SessionHistoryReadResult(messages: [], stats: SessionHistoryReadStats(
                        mode: "invalid_encoding", sourceBytes: Int64(data.count), bytesRead: Int64(data.count)
                    ))
                }
                text = decoded
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
        let damaged = decodeResult.malformedRowCount > 0 || decodeResult.invalidShapeRowCount > 0
        if damaged { msgs = [] }
        let decodedCount = msgs.count
        var truncated = truncatedRead
        if let limit, limit >= 0, msgs.count > limit {
            msgs = Array(msgs.suffix(limit))
            truncated = true
        }
        return SessionHistoryReadResult(
            messages: msgs,
            stats: SessionHistoryReadStats(
                mode: damaged ? "damaged_history" : mode,
                sourceBytes: sourceBytes,
                bytesRead: bytesRead,
                linesRead: lines.count,
                decodedCount: decodedCount,
                malformedRowCount: decodeResult.malformedRowCount,
                invalidShapeRowCount: decodeResult.invalidShapeRowCount,
                damageEvidence: decodeResult.damageEvidence,
                excludedByRunId: decodeResult.excludedByRunId,
                returnedCount: msgs.count,
                truncated: truncated
            ),
            contextStatistics: decodeResult.contextStatistics
        )
    }

    /// Validate the whole donor because a stale index cannot certify rows outside the sampled prompt.
    /// Unreadable, damaged or changing evidence throws; participant mismatch and oversized rows disable handoff.
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

    /// Select history from one transcript read, from the supplied bytes; absence is empty history, invalid IDs fail.
    public func transcriptBytes(forSessionId id: String) throws -> Data? {
        guard let safeId = NativeAgentChatSessionID.normalizedPathComponent(id) else {
            throw SessionTranscriptError(
                errorDescription: "Conversation history has an invalid session id. Select a valid conversation before continuing.")
        }
        let path = dataRoot.appendingPathComponent("chat/messages/\(safeId).jsonl")
        do { return try Data(contentsOf: path) } catch CocoaError.fileReadNoSuchFile { return nil }
    }

    /// Replay reads preserve every retained transcript row.
    public nonisolated func promptMessagesWithStats(
        transcript: Data?,
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
        let previousRows = Self.promptRowMemo.withLock { $0.rows }
        var rows: [Data: DecodedRow] = [:]
        var cacheHits = 0
        var cacheMisses = 0
        func decode(_ line: String) -> DecodedRow {
            let key = Data(line.utf8)
            if let row = rows[key] { return row }
            let row: DecodedRow
            if let kept = previousRows[key]?.row { row = kept; cacheHits += 1 }
            else { row = Self.decodeRow(line); cacheMisses += 1 }
            rows[key] = row
            return row
        }
        // Split JSONL on byte LF without walking every grapheme; preserve String's CR/CRLF segmentation when CR is present.
        guard let decodedTranscript = String(data: transcript, encoding: .utf8) else {
            return (SessionHistoryReadResult(
                messages: [],
                stats: SessionHistoryReadStats(
                    mode: "invalid_encoding",
                    sourceBytes: Int64(transcript.count),
                    bytesRead: Int64(transcript.count)
                )
            ), nil)
        }
        let lines = decodedTranscript.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        let prompt = Self.selectionResult(
            SessionHistoryLineReadResult(lines: lines, sourceBytes: Int64(transcript.count),
                bytesRead: Int64(transcript.count), truncated: false),
            mode: "replay_full", excludingRunId: shouldExcludeRun ? excludedRunId : nil, decode: decode)
        let relevance = relevanceWhen(prompt) ? relevanceMessagesWithStats(
            size: transcript.count, excludingRunId: excludingRunId, decode: decode
        ) { transcript.subdata(in: (transcript.startIndex + $0)..<(transcript.startIndex + $0 + $1)) } : nil
        // Late memo updates affect only cache misses; they cannot publish stale transcript state.
        // A read adds every line it used as the most recent; past the cap the least recently read lines go first.
        Self.promptRowMemo.withLock { memo in
            memo.reads += 1
            for (key, row) in rows {
                if memo.rows.updateValue((row, memo.reads), forKey: key) == nil { memo.bytes += key.count }
            }
            guard memo.bytes > Self.promptRowMemoMaximumBytes else { return }
            for key in memo.rows.sorted(by: { $0.value.read < $1.value.read }).map(\.key) {
                guard memo.bytes > Self.promptRowMemoMaximumBytes else { break }
                memo.rows[key] = nil
                memo.bytes -= key.count
            }
        }
        let stats = prompt.stats
        let measured = SessionHistoryReadResult(messages: prompt.messages, stats: SessionHistoryReadStats(
            mode: stats.mode, sourceBytes: stats.sourceBytes, bytesRead: stats.bytesRead,
            linesRead: stats.linesRead, decodedCount: stats.decodedCount,
            malformedRowCount: stats.malformedRowCount, invalidShapeRowCount: stats.invalidShapeRowCount,
            damageEvidence: stats.damageEvidence,
            excludedByRunId: stats.excludedByRunId, returnedCount: stats.returnedCount,
            truncated: stats.truncated, decodeCacheHits: cacheHits, decodeCacheMisses: cacheMisses),
            contextStatistics: prompt.contextStatistics)
        return (measured, relevance)
    }

    /// Bound semantic candidates with interior windows for large transcripts; explicit search still reaches exact older wording.
    /// JSONL stays authoritative without a sidecar index.
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

    package nonisolated func transcriptPath(for safeId: String, transcriptURL: URL?) throws -> URL {
        let path = transcriptURL ?? dataRoot
            .appendingPathComponent("chat", isDirectory: true)
            .appendingPathComponent("messages", isDirectory: true)
            .appendingPathComponent("\(safeId).jsonl")
        let parent = path.resolvingSymlinksInPath().deletingLastPathComponent()
        // Paths, not URLs: a folder a new install has not made yet has no trailing slash, and URLs would call that a different place.
        guard ["chat/messages", "chat/archive/messages"].contains(where: {
            parent.path == dataRoot.appendingPathComponent($0).resolvingSymlinksInPath().path
        }) else {
            // This is the app's own refusal, so it never sends the person to macOS privacy settings.
            throw NSError(domain: "NativeAgent.ChatHistory", code: 403, userInfo: [
                NSLocalizedDescriptionKey: "That conversation's file is outside the folders conversations live in. Its data was left unchanged."])
        }
        return path
    }

    /// Extend a complete, unfiltered prefix with complete lines; stats describe the whole selected revision, not just this read's IO.
    package nonisolated static func appendCompleteMessages(
        from data: Data, sourceBytes: Int64, to history: inout SessionHistoryReadResult
    ) throws {
        guard let text = String(data: data, encoding: .utf8) else {
            history = SessionHistoryReadResult(messages: [], stats: SessionHistoryReadStats(
                mode: "invalid_encoding", sourceBytes: sourceBytes, bytesRead: sourceBytes))
            return
        }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        let previous = history.stats
        let decoded = decodeMessages(from: lines, excludingRunId: nil, startingLine: previous.linesRead)
        let malformed = try adding(previous.malformedRowCount, decoded.malformedRowCount)
        let invalidShape = try adding(previous.invalidShapeRowCount, decoded.invalidShapeRowCount)
        let damaged = malformed > 0 || invalidShape > 0
        if damaged { history.messages.removeAll() }
        else { history.messages.append(contentsOf: decoded.messages) }
        history.contextStatistics = (
            try adding(history.contextStatistics.totalChars, decoded.contextStatistics.totalChars),
            try adding(history.contextStatistics.messageCount, decoded.contextStatistics.messageCount))
        history.stats = SessionHistoryReadStats(
            mode: damaged ? "damaged_history" : "full",
            sourceBytes: sourceBytes, bytesRead: sourceBytes,
            linesRead: try adding(previous.linesRead, lines.count),
            decodedCount: history.messages.count,
            malformedRowCount: malformed, invalidShapeRowCount: invalidShape,
            damageEvidence: Array((previous.damageEvidence + decoded.damageEvidence).prefix(8)),
            excludedByRunId: try adding(previous.excludedByRunId, decoded.excludedByRunId),
            returnedCount: history.messages.count, truncated: false)
    }

    private nonisolated static func adding(_ left: Int, _ right: Int) throws -> Int {
        let sum = left.addingReportingOverflow(right)
        guard !sum.overflow else { throw CocoaError(.fileReadTooLarge) }
        return sum.partialValue
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
        let damaged = decodeResult.malformedRowCount > 0 || decodeResult.invalidShapeRowCount > 0
        let decoded = damaged || lineRead.invalidEncoding ? [] : decodeResult.messages
        var seen: Set<String> = []
        var out: [ChatMessage] = []
        out.reserveCapacity(decoded.count)
        for message in decoded {
            guard let key = message.historyIdentity() else { continue }
            guard seen.insert(key).inserted else { continue }
            out.append(message)
        }
        return SessionHistoryReadResult(
            messages: out,
            stats: SessionHistoryReadStats(
                mode: lineRead.invalidEncoding ? "invalid_encoding" : damaged ? "damaged_history" : mode,
                sourceBytes: lineRead.sourceBytes,
                bytesRead: lineRead.bytesRead,
                linesRead: lineRead.lines.count,
                decodedCount: decoded.count,
                malformedRowCount: decodeResult.malformedRowCount,
                invalidShapeRowCount: decodeResult.invalidShapeRowCount,
                damageEvidence: decodeResult.damageEvidence,
                excludedByRunId: decodeResult.excludedByRunId,
                returnedCount: out.count,
                truncated: lineRead.truncated || decoded.count != out.count
            )
        )
    }

    /// Count tail lines once in bounded backward steps so selecting a tail never requires the whole transcript.
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
        var complete = chunks.reversed().reduce(into: Data(capacity: size - offset)) { $0.append($1) }
        if offset > 0, let newline = complete.firstIndex(of: 10) { complete.removeSubrange(...newline) }
        guard let text = String(data: complete, encoding: .utf8) else {
            return SessionHistoryLineReadResult(lines: [], sourceBytes: Int64(size), bytesRead: Int64(size - offset), truncated: offset > 0,
                invalidEncoding: true)
        }
        var lines = text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
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

    private nonisolated static func allLinesResult(from data: Data) -> SessionHistoryLineReadResult {
        guard let text = String(data: data, encoding: .utf8) else {
            return SessionHistoryLineReadResult(lines: [], sourceBytes: Int64(data.count), bytesRead: Int64(data.count), truncated: false,
                invalidEncoding: true)
        }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        return SessionHistoryLineReadResult(
            lines: lines,
            sourceBytes: Int64(data.count),
            bytesRead: Int64(data.count),
            truncated: false
        )
    }

    /// Drop rows crossing sampled windows rather than calling them corrupt; giant tool rows cannot force boundary chasing.
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
            guard let text = String(data: window[lower..<upper], encoding: .utf8) else {
                return SessionHistoryLineReadResult(lines: [], sourceBytes: Int64(size), bytesRead: bytesRead, truncated: true, invalidEncoding: true)
            }
            lines.append(contentsOf: text
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
    package struct DecodedRow: Sendable {
        package let value: JSONValue?
        package let role: String?
        package let content: String?
        package let timestamp: String?
        package let contextStatistics: (totalChars: Int, messageCount: Int)
        package let message: ChatMessage?

        init(_ value: JSONValue?, _ role: String?, _ content: String?, _ timestamp: String?,
             _ statistics: (totalChars: Int, messageCount: Int)) {
            self.value = value; self.role = role; self.content = content; self.timestamp = timestamp
            contextStatistics = statistics
            message = role.flatMap { role in content.map {
                ChatMessage(role: role, content: $0, timestamp: timestamp ?? "", extras: value)
            } }
        }
    }

    /// Preserve invalid JSON shapes while parsing canonical fields and raw-object context counts.
    package nonisolated static func decodeRow(_ line: String) -> DecodedRow {
        let lineData = Data(line.trimmingCharacters(in: .whitespacesAndNewlines).utf8)
        var statistics = (totalChars: 0, messageCount: 0)
        let parsed: JSONValue? = autoreleasepool {
            let row = try? ContactThread.decodeRow(lineData)
            if let object = row {
                statistics.messageCount = 1
                if case .string(let content)? = object["content"] {
                    statistics.totalChars = content.count
                } else if let content = object["content"],
                          let bytes = try? content.serializedData(pretty: false) {
                    statistics.totalChars = bytes.count
                }
            }
            return row.map(JSONValue.object)
        }
        guard case .object(let row)? = parsed else { return DecodedRow(parsed, nil, nil, nil, statistics) }
        func string(_ key: String) -> String? { if case .string(let text)? = row[key] { return text }; return nil }
        guard let id = string("id"), !id.isEmpty,
              ContactThread.Line(row).provenanceFailure == nil else {
            return DecodedRow(parsed, nil, nil, nil, statistics)
        }
        return DecodedRow(parsed, string("role"), string("content"), string("createdAt"), statistics)
    }

    private nonisolated static func decodeMessages(
        from lines: [String],
        excludingRunId: String?,
        excludingAwaitingConsumption: Bool = false,
        startingLine: Int = 0,
        decode: (String) -> DecodedRow = SessionHistoryReader.decodeRow
    ) -> (
        messages: [ChatMessage],
        excludedByRunId: Int,
        malformedRowCount: Int,
        invalidShapeRowCount: Int,
        damageEvidence: [String],
        contextStatistics: (totalChars: Int, messageCount: Int)
    ) {
        var msgs: [ChatMessage] = []
        var excludedCount = 0
        var malformedCount = 0
        var invalidShapeCount = 0
        var damageEvidence: [String] = []
        var contextStatistics = (totalChars: 0, messageCount: 0)
        msgs.reserveCapacity(lines.count)
        for (position, line) in lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { continue }
            let decoded = decode(line)
            contextStatistics.totalChars += decoded.contextStatistics.totalChars
            contextStatistics.messageCount += decoded.contextStatistics.messageCount
            func recordDamage() {
                guard damageEvidence.count < 8 else { return }
                damageEvidence.append("selected row \(startingLine + position + 1) sha256 "
                    + SHA256.hash(data: Data(line.utf8)).map { String(format: "%02x", $0) }.joined())
            }
            guard let parsed = decoded.value else { malformedCount += 1; recordDamage(); continue }
            guard case .object(let obj) = parsed else { invalidShapeCount += 1; recordDamage(); continue }
            if excludingAwaitingConsumption, case .object(let metadata)? = obj["metadata"],
               metadata["awaitingConsumption"] == .bool(true) { continue }
            if let excludingRunId,
               message(parsed, hasRunId: excludingRunId) {
                excludedCount += 1
                continue
            }
            guard let message = decoded.message else {
                invalidShapeCount += 1
                recordDamage()
                continue
            }
            msgs.append(message)
        }
        return (msgs, excludedCount, malformedCount, invalidShapeCount, damageEvidence, contextStatistics)
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

public extension Notification.Name {
    /// Notify context readouts after a turn lands so they can refresh.
    static let chatTurnCompleted = Notification.Name("chatTurnCompleted")
    /// Transcript appends and rewrites invalidate projections; object identifies the session.
    static let nativeAgentChatTranscriptDidChange = Notification.Name("NativeAgent.chatTranscriptDidChange")
}
