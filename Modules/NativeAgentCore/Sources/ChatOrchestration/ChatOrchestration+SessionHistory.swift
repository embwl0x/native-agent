import Foundation
import NativeAgentCore
import PersistenceCore

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
        excludedByRunId: Int = 0,
        returnedCount: Int = 0,
        truncated: Bool = false
    ) {
        self.mode = mode
        self.sourceBytes = sourceBytes
        self.bytesRead = bytesRead
        self.linesRead = linesRead
        self.decodedCount = decodedCount
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
    /// Prompt assembly is a latency-sensitive projection over the canonical
    /// JSONL audit log. Never let a few giant tool receipts turn that projection
    /// back into an unbounded transcript scan.
    private static let promptHeadMaximumBytes = 64 * 1024
    private static let promptTailMaximumBytes = 192 * 1024
    private static let relevanceFullReadMaximumBytes = 128 * 1024
    private static let relevanceSampleMaximumBytes = 96 * 1024
    private static let relevanceSampleWindowCount = 8

    /// Internal (not private) so buildTurnContextWithHistory can derive the
    /// default SessionDigestProvider from the SAME data root the history
    /// comes from (immutable Sendable `let` → legal synchronous cross-actor
    /// access within the module). Fixture-rooted tests therefore never leak
    /// digest reads onto the live data dir.
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
            let key = "\(msg.timestamp)\u{1F}\(msg.role)\u{1F}\(msg.content)"
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
            let key = "\(message.timestamp)\u{1F}\(message.role)\u{1F}\(message.content)"
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
                excludedByRunId: decodeResult.excludedByRunId,
                returnedCount: out.count,
                truncated: lineRead.truncated || decoded.count != out.count
            )
        )
    }

    private nonisolated static func tailLines(
        from path: URL,
        minimumLineCount: Int
    ) -> [String] {
        tailLinesResult(from: path, minimumLineCount: minimumLineCount).lines
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

    private nonisolated static func headLines(
        from path: URL,
        maximumLineCount: Int
    ) -> [String] {
        headLinesResult(from: path, maximumLineCount: maximumLineCount).lines
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
            return SessionHistoryLineReadResult(lines: [], sourceBytes: 0, bytesRead: 0, truncated: false)
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
            return SessionHistoryLineReadResult(lines: [], sourceBytes: 0, bytesRead: 0, truncated: false)
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
    ) -> (messages: [ChatMessage], excludedByRunId: Int) {
        var msgs: [ChatMessage] = []
        var excludedCount = 0
        msgs.reserveCapacity(lines.count)
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { continue }
            guard let lineData = trimmed.data(using: .utf8) else { continue }
            guard let parsed = try? JSONValue.parse(lineData) else { continue }
            guard case .object(let obj) = parsed else { continue }
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
            if case .string(let s)? = obj["createdAt"] { timestamp = s }
            else if case .string(let s)? = obj["timestamp"] { timestamp = s }
            guard let role, let content else { continue }
            msgs.append(ChatMessage(
                role: role,
                content: content,
                timestamp: timestamp,
                extras: parsed
            ))
        }
        return (msgs, excludedCount)
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
        guard let data = try? Data(contentsOf: path) else { return nil }
        guard let parsed = try? JSONValue.parse(data) else { return nil }
        guard case .array(let arr) = parsed else { return nil }
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
    /// `buildTurnContext` shape — no error is raised. Either way the
    /// per-session "since last session" digest (U3 item 8) is injected at
    /// the end of the STABLE segment when a prior session exists.
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
        clockNowOverride: Date? = nil
    ) async throws -> TurnContext {
        // Non-nil queryUserMessage is authoritative EVEN WHEN BLANK — an
        // attachment-only text-compat turn must not fall back to the hinted
        // wire message (gpt-5.5 review 2026-08-13, NEEDS-FIX #1).
        let queryMessage = queryUserMessage ?? userMessage
        var trace = ContextStageTrace()
        let prior: [ChatMessage]
        let middleCandidates: [ChatMessage]
        let priorStats: SessionHistoryReadStats
        let middleStats: SessionHistoryReadStats?
        if historyLimit > 0 {
            let priorResult = (try? await trace.measure("history.prompt_read") {
                try await historyReader.promptMessagesWithStats(
                    forSessionId: sessionId,
                    anchorLimit: 3,
                    tailLimit: max(64, historyLimit * 2),
                    excludingRunId: excludeHistoryRunId
                )
            }) ?? SessionHistoryReadResult(
                messages: [],
                stats: SessionHistoryReadStats(mode: "prompt_read_failed")
            )
            prior = priorResult.messages
            priorStats = priorResult.stats
            if prior.count > historyLimit || priorStats.sourceBytes > priorStats.bytesRead {
                let middleResult = (try? await trace.measure("history.middle_sample") {
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
        let expandedRecallQuery = await trace.measure("history.recall_query") {
            SessionHistoryPromptRenderer.recallQuery(
                userMessage: queryMessage,
                messages: prior
            )
        }
        let baseStartNs = DispatchTime.now().uptimeNanoseconds
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
                recentTurns: prior.suffix(4).map(\.content),
                queryUserMessage: queryMessage
            )
            trace.record("context.base", since: baseStartNs)
        } catch {
            trace.record("context.base", since: baseStartNs)
            throw error
        }
        let base = await trace.measure("history.digest") {
            await Self.injectingSessionDigest(
                into: rawBase,
                sessionId: sessionId,
                provider: sessionDigest ?? SessionDigestProvider(dataRoot: historyReader.dataRoot)
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
        let historyWindowTokens = ContextBudgetPolicy.windowTokens(forModel: base.modelId)
        let historyBudget = ContextBudgetPolicy.resolve(
            windowTokens: historyWindowTokens,
            surface: surface
        )
        let renderedHistory = await trace.measure("history.render") {
            SessionHistoryPromptRenderer.renderDetailed(
                messages: prior,
                middleCandidates: middleCandidates,
                userMessage: userMessage,
                surface: surface,
                historyLimit: historyLimit,
                windowTokens: historyWindowTokens
            )
        }
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
        // U3 wave-2 item 8 (2026-06-10): since-last-session digest, injected
        // at the HEAD of the DYNAMIC segment (after persona + REM pins, before
        // the dynamic recall/history mass — the same position in `combined`,
        // on the churning side of the cache breakpoint). The digest describes
        // the PREVIOUS session, so its bytes change per session; keeping it
        // out of the stable block is what lets the stable-end breakpoint hit
        // ACROSS sessions (see injectingSessionDigest). Injection
        // happens BEFORE the history guard below on purpose: the session's
        // FIRST turn has no renderable history and used to early-return, and
        // the first turn is exactly where the digest must already be present
        // (turn 2+ would otherwise prepend new stable bytes → prefix churn).
        // nil provider → derive from the history reader's data root, so the
        // digest always reads the same store the history comes from.
        guard let historyBlock else {
            let runtimeStartNs = DispatchTime.now().uptimeNanoseconds
            let clockedBase = await contextByAppendingCurrentTurnFacts(
                base, clockNowOverride: clockNowOverride)
            let finalBase = Self.contextBySettingNaturalExpressionCue(
                clockedBase,
                cue: naturalExpressionCue
            )
            trace.record("context.clock_runtime", since: runtimeStartNs)
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
            fluidContextTurn: base.fluidContextTurn
        )
        let runtimeStartNs = DispatchTime.now().uptimeNanoseconds
        let clocked = await contextByAppendingCurrentTurnFacts(
            contextWithHistory, clockNowOverride: clockNowOverride)
        let finalContext = Self.contextBySettingNaturalExpressionCue(
            clocked,
            cue: naturalExpressionCue
        )
        trace.record("context.clock_runtime", since: runtimeStartNs)
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
            recalledCount: finalContext.recalled.count
        )
        return finalContext
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
        recalledCount: Int
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
        provider: SessionDigestProvider
    ) async -> TurnContext {
        guard let seg = base.systemSegments else { return base }
        guard let digest = await provider.digest(forSessionId: sessionId),
              !digest.isEmpty else { return base }
        let dynamic = seg.dynamic.isEmpty ? digest : digest + "\n\n" + seg.dynamic
        let segments = SystemPromptSegments(stable: seg.stable, dynamic: dynamic)
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
            fluidContextTurn: base.fluidContextTurn
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
    private typealias Budget = ContextBudgetPolicy.Resolved

    private struct Renderable {
        let role: String
        let content: String
        let timestamp: String
        let isTool: Bool
        let isCompactionSummary: Bool
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
    static func renderDetailed(
        messages: [ChatMessage],
        middleCandidates: [ChatMessage] = [],
        userMessage: String = "",
        surface: String,
        historyLimit: Int,
        windowTokens: Int? = nil
    ) -> RenderResult {
        let cappedLimit = max(0, historyLimit)
        guard cappedLimit > 0 else { return RenderResult(historyBlock: nil) }

        let renderables = messages.compactMap(renderable)
        guard !renderables.isEmpty else { return RenderResult(historyBlock: nil) }

        let budget = budget(for: surface, windowTokens: windowTokens)
        var sections: [String] = []
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
        if let history = conversationHistory(
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
        if let latestUser {
            lines.append("Latest prior user: \(cap(latestUser.content, 280))")
        }
        if let latestAssistant {
            lines.append("Latest assistant tail: \(cap(latestAssistant.content, 320))")
        }
        if let latestCorrection {
            lines.append("Recent correction: \(cap(latestCorrection.content, 260))")
        }
        if let openLoop {
            lines.append("Open loop: \(cap(openLoop.content, 260))")
        }
        if !anchors.isEmpty {
            let rendered = anchors
                .map { "[\($0.role)] \(cap($0.content, 180))" }
                .joined(separator: " | ")
            lines.append("Initial anchors: \(rendered)")
        }

        return hardCap(lines.joined(separator: "\n"), maxCount)
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
    private static func budget(for surface: String, windowTokens: Int?) -> Budget {
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

    private static func renderable(_ message: ChatMessage) -> Renderable? {
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
        if let attachments = array(metadata?["attachments"]), !attachments.isEmpty {
            let refs = attachments.compactMap { entry -> String? in
                guard let obj = object(entry) else { return nil }
                let name = string(obj["name"]) ?? string(obj["mime"]) ?? "attachment"
                if let bytes = int(obj["byteSize"]), bytes > 0 {
                    return "\(name), \(bytes / 1024)kB"
                }
                return name
            }
            if !refs.isEmpty {
                let marker = "[sent image: \(refs.joined(separator: "; "))]"
                content = content.isEmpty ? marker : "\(marker) \(content)"
            }
        }
        guard !content.isEmpty else { return nil }
        if role == "assistant", isTransientAssistantFailure(content) {
            return nil
        }
        return Renderable(
            role: isCompactionSummary ? "summary" : role,
            content: content,
            timestamp: message.timestamp,
            isTool: isTool,
            isCompactionSummary: isCompactionSummary
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
                .map { "[\($0.role)] \(cap($0.content, 220))" }
                .joined(separator: " | ")
            lines.append("Initial anchors: \(rendered)")
        }
        if let latestUser {
            lines.append("Latest user before this turn: \(cap(latestUser.content, 280))")
        }
        if let latestAssistant {
            lines.append("Latest assistant tail: \(cap(latestAssistant.content, 320))")
        }
        if let latestCorrection {
            lines.append("Recent correction/callout: \(cap(latestCorrection.content, 260))")
        }
        if let openLoop {
            lines.append("Open loop: \(cap(openLoop.content, 280))")
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
            let line = "[\(hit.message.role)] \(cap(hit.message.content, capValue))"
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
        "\(message.timestamp)\u{1F}\(message.role)\u{1F}\(message.content)"
    }

    private static func conversationHistory(
        from messages: [Renderable],
        limit: Int,
        budget: Budget
    ) -> String? {
        let tail = Array(messages.suffix(limit))
        guard !tail.isEmpty else { return nil }

        func renderedLine(_ msg: Renderable) -> String {
            "[\(msg.role)] \(cap(msg.content, capForRole(msg, budget: budget)))"
        }

        var admitted: [(index: Int, line: String)] = []
        var used = 0
        var omitted = messages.count > tail.count

        // Sweep R4 A3: the compaction recollection is the ONLY surviving record
        // of every turn that was elided — and it is by construction one of the
        // OLDEST rows in the tail. The fill below runs newest-first, so now that
        // this row can legitimately be several thousand characters, ordinary
        // recent chatter would crowd out the exact artifact compaction paid an
        // LLM call to produce. It gets first claim on `historyChars`; the
        // aggregate bound itself is unchanged.
        let reservedIndex = tail.indices.last { tail[$0].isCompactionSummary }
        if let reservedIndex {
            let line = renderedLine(tail[reservedIndex])
            admitted.append((reservedIndex, line))
            used = line.count + 1
        }

        // Unchanged fill semantics for every other row: newest-first, and the
        // newest row is admitted even if it alone exceeds the budget.
        var admittedFromStream = false
        for idx in tail.indices.reversed() {
            if idx == reservedIndex { continue }
            let line = renderedLine(tail[idx])
            let projected = used + line.count + 1
            if admittedFromStream && projected > budget.historyChars {
                omitted = true
                continue
            }
            admitted.append((idx, line))
            used = projected
            admittedFromStream = true
        }

        let lines = admitted.sorted { $0.index < $1.index }.map(\.line)
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
        [assistant] \(cap(latest.content, assistantCap))
        """
    }

    private static func capForRole(_ message: Renderable, budget: Budget) -> Int {
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
        let normalizedContent = normalize(content)
        if !normalizedContent.isEmpty {
            return normalizedContent
        }
        let name = string(metadata?["toolName"]) ?? string(metadata?["tool_name"]) ?? "tool"
        let ok: String = {
            if case .bool(let value)? = metadata?["ok"] { return value ? "ok" : "failed" }
            return "ran"
        }()
        // Skill reads: the 180-char preview would be the skill body's first
        // paragraph — redundant bytes in every subsequent prompt. The NAME is
        // the whole continuity signal ("I already read that skill"); she can
        // re-read on demand. (User, 2026-07-03: "180 chars could add up if
        // she uses a lot of skills.")
        if name == "read_skill" {
            let skillName = Self.readSkillName(fromInputJSON: string(metadata?["inputJSON"]))
            return skillName.isEmpty
                ? "read_skill \(ok)"
                : "read_skill \(ok): \(skillName) (body elided — re-read if needed)"
        }
        let rawResult = string(metadata?["resultSummary"]) ?? ""
        let result = toolResultProjection(rawResult)
        if result.isEmpty {
            return "\(name) \(ok)"
        }
        return "\(name) \(ok): \(result)"
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

    private static func cap(_ text: String, _ maxCount: Int) -> String {
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
