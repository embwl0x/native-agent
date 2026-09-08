import Foundation

/// The ONE accessor for a session's consolidated recollections.
///
/// NORTHSTAR clause 1 (one consolidation owner), sweep item 45. A chat
/// transcript's older turns are distilled — off the critical path, as they age
/// past the aging boundary — into `compaction_summary` rows. Those rows ARE the
/// consolidated memory of the turns they replaced: the raw turns no longer
/// exist in the transcript.
///
/// Before this accessor there were two summarizers over the same lived session:
/// the chat lane's compaction distiller and the dream lane's episodic pass,
/// each re-reading raw turns. The dream lane now reads recollections through
/// here instead of re-summarizing material the chat lane already consolidated.
///
/// This lives in PersistenceCore because BOTH sides must agree on the row
/// shape and neither may import the other (ChatOrchestration → DreamREMCycle is
/// the only arrow between them). Writer: `ChatSessionAutocompactor`.
/// Reader: `DreamCycleRunner`.
public struct ChatSessionRecollection: Sendable, Equatable {
    public let sessionId: String
    public let rowId: String?
    /// The recollection text — the LLM-distilled first-person note when the
    /// distiller upgraded it, else the mechanical role-prefixed summary.
    public let text: String
    /// When the recollection row itself was written.
    public let createdAt: Date?
    /// Oldest turn this recollection covers, when the writer recorded it.
    public let coversFrom: Date?
    /// Newest turn this recollection covers, when the writer recorded it.
    public let coversUntil: Date?
    public let messagesReplaced: Int
    /// True once the LLM pass replaced the mechanical summary.
    public let distilled: Bool

    /// The instant this recollection's material ENDS. Consumers compare their
    /// own high-water mark against THIS, never against `createdAt`: a
    /// recollection written today can cover turns from last week, and a
    /// consumer that already read those turns raw must not read them again
    /// through their recollection. Legacy rows (written before coverage was
    /// recorded) fall back to the row's own timestamp.
    public var consolidatedThrough: Date? { coversUntil ?? createdAt }

    public init(
        sessionId: String,
        rowId: String?,
        text: String,
        createdAt: Date?,
        coversFrom: Date?,
        coversUntil: Date?,
        messagesReplaced: Int,
        distilled: Bool
    ) {
        self.sessionId = sessionId
        self.rowId = rowId
        self.text = text
        self.createdAt = createdAt
        self.coversFrom = coversFrom
        self.coversUntil = coversUntil
        self.messagesReplaced = messagesReplaced
        self.distilled = distilled
    }
}

public enum ChatSessionRecollections {
    public struct LatestScan: Sendable {
        public let recollection: ChatSessionRecollection?
        /// Start of an unfinished trailing line, or EOF after a newline.
        public let nextOffset: UInt64
        public let bytesRead: Int
    }

    /// Streaming/incremental accessor for append-owned transcripts. Callers
    /// must reset the offset on replacement, truncation, or an in-place rewrite.
    public static func scanLatest(path: URL, sessionId: String, offset: UInt64 = 0,
                                  previous: ChatSessionRecollection? = nil) throws -> LatestScan {
        let file = try FileHandle(forReadingFrom: path)
        defer { try? file.close() }
        try file.seek(toOffset: offset)
        var pending = Data()
        var newest = previous
        var consumed = offset
        var bytesRead = 0
        func absorb(_ bytes: Data) {
            if let row = try? JSONValue.parse(bytes),
               let value = recollection(fromTranscriptRow: row, sessionId: sessionId) { newest = value }
        }
        while let chunk = try file.read(upToCount: 64 * 1024), !chunk.isEmpty {
            bytesRead += chunk.count
            pending.append(chunk)
            while let newline = pending.firstIndex(of: 10) {
                let end = pending.index(after: newline)
                absorb(Data(pending[..<newline]))
                consumed += UInt64(pending.distance(from: pending.startIndex, to: end))
                pending.removeSubrange(..<end)
            }
        }
        // Preserve the tolerant accessor's support for a valid final JSON row
        // without a newline. Re-read that line if another append completes it.
        if !pending.isEmpty { absorb(pending) }
        return LatestScan(recollection: newest, nextOffset: consumed, bytesRead: bytesRead)
    }

    /// `metadata.kind` marking a transcript row as a consolidated recollection.
    public static let rowKind = "compaction_summary"
    /// `metadata` keys the writer stamps so a reader can tell WHICH stretch of
    /// life a recollection stands for without re-reading the backup.
    public static let coversFromKey = "covers_from"
    public static let coversUntilKey = "covers_until"

    /// Recognize a recollection row. Returns nil for every ordinary transcript
    /// row — this is the only place that knows the shape.
    public static func recollection(
        fromTranscriptRow row: JSONValue,
        sessionId: String
    ) -> ChatSessionRecollection? {
        guard case .object(let obj) = row else { return nil }
        guard case .object(let metadata)? = obj["metadata"],
              case .string(let kind)? = metadata["kind"],
              kind == rowKind
        else { return nil }
        let text: String = {
            if case .string(let value)? = obj["content"] { return value }
            return ""
        }()
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let rowId: String? = {
            if case .string(let value)? = obj["id"] { return value }
            return nil
        }()
        let replaced: Int = {
            if case .int(let value)? = metadata["messages_replaced"] { return Int(value) }
            if case .double(let value)? = metadata["messages_replaced"] { return Int(exactly: value.rounded(.towardZero)) ?? 0 }
            return 0
        }()
        let distilled: Bool = {
            if case .string(let value)? = metadata["distill"] { return value == "llm" }
            return false
        }()
        return ChatSessionRecollection(
            sessionId: sessionId,
            rowId: rowId,
            text: trimmed,
            createdAt: parseTimestamp(obj["createdAt"]),
            coversFrom: parseTimestamp(metadata[coversFromKey]),
            coversUntil: parseTimestamp(metadata[coversUntilKey]),
            messagesReplaced: replaced,
            distilled: distilled
        )
    }

    /// Every recollection in one session's transcript, oldest first. Tolerant
    /// by design: an unparseable line is skipped, never thrown — a reader of
    /// recollections must not be the thing that fails on a corrupt transcript.
    public static func recollections(
        forSession sessionId: String,
        dataRoot: URL
    ) -> [ChatSessionRecollection] {
        let path = dataRoot
            .appendingPathComponent("chat", isDirectory: true)
            .appendingPathComponent("messages", isDirectory: true)
            .appendingPathComponent("\(sessionId).jsonl")
        guard let data = try? Data(contentsOf: path),
              let text = String(data: data, encoding: .utf8)
        else { return [] }
        var out: [ChatSessionRecollection] = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty,
                  let lineData = trimmed.data(using: .utf8),
                  let parsed = try? JSONValue.parse(lineData),
                  let recollection = recollection(fromTranscriptRow: parsed, sessionId: sessionId)
            else { continue }
            out.append(recollection)
        }
        return out
    }

    /// The dream lane's high-water mark — the newest turn a dream has already
    /// consumed — read from the runner's own `.dream_state.json` sidecar.
    ///
    /// It lives HERE, beside the row shape, because the WRITER needs it as much
    /// as the reader: a recollection whose span straddles this mark
    /// (`covers_from <= mark < covers_until`) is admitted WHOLE by the reader,
    /// so its pre-mark turns get dreamed a second time after they were already
    /// dreamed raw. The writer clamps its replacement against this so no such
    /// row is ever created. Absent, unreadable or unparseable → nil, meaning
    /// "no mark to respect" — never a reason to fail a consolidation.
    public static func dreamConsolidationMark(dataRoot: URL) -> Date? {
        let path = dataRoot
            .appendingPathComponent("dream_diary", isDirectory: true)
            .appendingPathComponent(".dream_state.json")
        guard let data = try? Data(contentsOf: path),
              let parsed = try? JSONValue.parse(data),
              case .object(let obj) = parsed
        else { return nil }
        return parseTimestamp(obj["lastDreamedAt"])
    }

    /// True when this recollection's material STRADDLES `mark`: part of it was
    /// already consumed at or before the mark, part of it was not. Such a row
    /// cannot be admitted whole and cannot be split after the fact — the raw
    /// turns behind it are gone.
    public static func straddles(_ recollection: ChatSessionRecollection, mark: Date) -> Bool {
        guard let from = recollection.coversFrom,
              let until = recollection.consolidatedThrough else { return false }
        return from <= mark && until > mark
    }

    /// Live transcripts carry microsecond ISO8601 (`...T11:33:32.167835+00:00`)
    /// while `ISO8601DateFormatter.withFractionalSeconds` accepts three digits.
    /// Try fractional, then plain, then truncate to milliseconds.
    public static func parseTimestamp(_ value: JSONValue?) -> Date? {
        guard case .string(let raw)? = value else { return nil }
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: text) { return date }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        if let date = plain.date(from: text) { return date }
        // Truncate an over-long fractional part to milliseconds and retry.
        if let dot = text.firstIndex(of: ".") {
            let afterDot = text.index(after: dot)
            var digitsEnd = afterDot
            while digitsEnd < text.endIndex, text[digitsEnd].isNumber {
                digitsEnd = text.index(after: digitsEnd)
            }
            let digits = text[afterDot..<digitsEnd]
            if digits.count > 3 {
                let keep = text.index(afterDot, offsetBy: 3)
                let rebuilt = String(text[text.startIndex..<keep]) + String(text[digitsEnd...])
                if let date = fractional.date(from: rebuilt) { return date }
            }
        }
        return nil
    }
}
