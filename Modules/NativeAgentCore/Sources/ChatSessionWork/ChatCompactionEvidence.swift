import Foundation
import NativeAgentShared
import Experiences
import NativeAgentCore
import PersistenceCore
import TurnTrace
import Transcripts
import ProviderRouting
// Blueprint: | `ChatCompactionEvidence.swift` | Compaction trace, retained coverage and safe replacement accounting |
extension ChatSessionAutocompactor {
    func emitCompactionTrace(
        _ outcome: ChatSessionCompactionOutcome,
        model: String,
        surface: String,
        runId: String?,
        status: String
    ) async {
        var payload: [String: JSONValue] = [
            "schema": .string("context.compact.v1"),
            "sessionId": .string(outcome.sessionId),
            "surface": .string(surface),
            "trigger": .string(outcome.trigger),
            "lane": .string(outcome.lane),
            "reason": .string(outcome.reason),
            "model": .string(model),
            "thresholdTokens": .int(Int64(outcome.thresholdTokens)),
            "estimatedTokensBefore": .int(Int64(outcome.estimatedTokensBefore)),
            "transcriptCharsBefore": .int(Int64(outcome.transcriptCharsBefore)),
            "messagesBefore": .int(Int64(outcome.messagesBefore)),
            "messagesAfter": .int(Int64(outcome.messagesAfter)),
            "messagesReplaced": .int(Int64(outcome.messagesReplaced)),
            "summaryChars": .int(Int64(outcome.summaryChars)),
            "sourceBytesBefore": .int(outcome.sourceBytesBefore),
            "sourceBytesAfter": .int(outcome.sourceBytesAfter),
        ]
        if let runId, !runId.isEmpty {
            payload["runId"] = .string(runId)
        }
        let date = now()
        let event = TurnTraceEvent(kind: "context.compact", title: outcome.sessionId, status: status,
            payload: .object(payload), createdAt: ISO8601DateFormatter().string(from: date), ts: date,
            turnId: TurnTraceContext.turnId, surface: surface)
        if TurnTraceContext.turnId != nil { TurnTraceBus.fire(event, on: TurnTraceContext.bus ?? .shared) }
        else { await TurnTracePersistLane(dataRootOverride: dataRoot).append(event) }
    }
    /// Select only enough oldest source to leave ~55% of the effective window
    /// raw. Live cards/results stay raw and count toward that allowance too.
    static func rawHistoryReplacementCount(
        rows: [JSONValue], windowTokens: Int, divisor: Double, force: Bool
    ) -> Int {
        guard rows.count > 1 else { return 0 }
        let rawRows = rows.filter { !isRecollection($0) }
        let rawChars = transcriptCharacterCount(rawRows)
        let target = Int(Double(windowTokens) * divisor
            * ChatSessionAutocompactionConfig.rawHistoryTargetFraction)
        // An explicit manual fold can still shorten a history already below
        // the automatic target; leave half of that smaller raw stretch.
        let keepChars = force && rawChars <= target ? rawChars / 2 : target
        guard rawChars > keepChars else { return 0 }
        let (results, compactible) = InlineInteractionCompactionRetention.splitPendingResults(rawRows)
        let (cards, _) = InlineInteractionCompactionRetention.split(compactible)
        let protected = Set(results + cards)
        var removedChars = 0
        var count = 0
        for index in rows.indices.dropLast() {
            let row = rows[index]
            // Never consume the destination of an in-flight foreground fold.
            if hasPendingDistillation(row) { break }
            if !isRecollection(row), !protected.contains(row), case .object(let object) = row {
                removedChars += ChatCompactionRowRendering.characterCount(object)
            }
            count = index + 1
            if rawChars - removedChars <= keepChars { break }
        }
        return keepingLastUserRow(rows: rows, replaceCount: count)
    }
    /// Legacy mechanical recollections need their retained source distilled too.
    static func hasPendingDistillation(_ row: JSONValue) -> Bool {
        guard case .object(let obj) = row,
              case .object(let metadata)? = obj["metadata"],
              metadata["kind"] == .string(ChatSessionRecollections.rowKind)
        else { return false }
        return metadata["distill"] != .string("llm")
    }
    static func isRecollection(_ row: JSONValue) -> Bool {
        guard case .object(let object) = row else { return false }
        return ChatCompactionRowRendering.isRecollection(object)
    }
    /// The ISO timestamps bounding the material a recollection stands for.
    /// A replaced row that is ITSELF a recollection contributes its own
    /// coverage, so a session consolidated repeatedly keeps an honest span
    /// rather than collapsing to the last compaction's clock.
    static func coverageRange(_ rows: [JSONValue]) -> (from: String?, until: String?) {
        func createdAt(_ row: JSONValue) -> String? {
            guard case .object(let obj) = row,
                  case .string(let value)? = obj["createdAt"] else { return nil }
            return value
        }
        func metadataString(_ row: JSONValue, _ key: String) -> String? {
            guard case .object(let obj) = row,
                  case .object(let metadata)? = obj["metadata"],
                  case .string(let value)? = metadata[key] else { return nil }
            return value
        }
        func isRecollection(_ row: JSONValue) -> Bool {
            metadataString(row, "kind") == ChatSessionRecollections.rowKind
        }
        var until: String?
        for row in rows.reversed() {
            if let value = metadataString(row, ChatSessionRecollections.coversUntilKey)
                ?? createdAt(row) {
                until = value
                break
            }
        }
        // `from` describes the WHOLE selected source. Ordinary folds contain
        // only new turns; a rollup starts at its first old block's coverage,
        // not that block's later write time. Otherwise the dream lane could
        // re-admit material it already consumed.
        var from: String?
        for row in rows {
            if isRecollection(row),
               let value = metadataString(row, ChatSessionRecollections.coversFromKey) {
                from = value
                break
            }
            if let value = createdAt(row) {
                from = value
                break
            }
        }
        if from == nil {
            for row in rows.reversed() {
                if let value = metadataString(row, ChatSessionRecollections.coversUntilKey)
                    ?? createdAt(row) {
                    from = value
                    break
                }
            }
        }
        // A prefix can end on a recollection whose covers_until predates the
        // raw turn that opened the span; never hand out an inverted window.
        if let fromValue = from, let untilValue = until,
           let fromDate = ChatSessionRecollections.parseTimestamp(.string(fromValue)),
           let untilDate = ChatSessionRecollections.parseTimestamp(.string(untilValue)),
           fromDate > untilDate {
            from = untilValue
        }
        return (from, until)
    }
    /// Shrink `replaceCount` so the recollection it produces never straddles
    /// the dream lane's high-water mark. A span wholly at-or-before the mark is
    /// already safe (the dream skips it); a span wholly after it is safe too
    /// (the dream reads all of it, once). Only a straddling span is a double
    /// count — clamp it to the leading rows whose material ENDS at or before
    /// the mark and leave the rest raw. No mark → nothing to respect.
    static func markSafeReplacementCount(
        rows: [JSONValue],
        replaceCount: Int,
        mark: Date?
    ) -> Int {
        guard replaceCount > 0, let mark else { return replaceCount }
        let replaced = Array(rows.prefix(replaceCount))
        let span = coverageRange(replaced)
        guard let until = ChatSessionRecollections.parseTimestamp(span.until.map { .string($0) }),
              until > mark
        else { return replaceCount }
        guard let from = ChatSessionRecollections.parseTimestamp(span.from.map { .string($0) }),
              from <= mark
        else { return replaceCount }
        var safe = 0
        for row in replaced {
            guard let rowUntil = ChatSessionRecollections.parseTimestamp(
                      coverageRange([row]).until.map { .string($0) }
                  ),
                  rowUntil <= mark
            else { break }
            safe += 1
        }
        return safe
    }
    /// True when at least one row is an ordinary turn rather than a recollection
    /// the earlier passes already folded.
    static func containsRawTurn(_ rows: [JSONValue]) -> Bool {
        rows.contains { row in
            guard case .object(let obj) = row,
                  case .object(let metadata)? = obj["metadata"],
                  case .string(let kind)? = metadata["kind"]
            else { return true }
            return kind != ChatSessionRecollections.rowKind
        }
    }
    /// Keep the retained run's user row; skip if no raw turn remains to fold.
    static func keepingLastUserRow(rows: [JSONValue], replaceCount: Int) -> Int {
        let replaceCount = min(replaceCount, rows.firstIndex {
            guard case .object(let row) = $0, case .object(let metadata)? = row["metadata"] else { return false }
            return metadata["awaitingConsumption"] == .bool(true)
        } ?? rows.count)
        func role(_ row: JSONValue) -> String? {
            guard case .object(let obj) = row, case .string(let value)? = obj["role"] else { return nil }
            return value
        }
        guard replaceCount > 0, replaceCount < rows.count,
              ["assistant", "tool"].contains(role(rows[replaceCount]))
        else { return replaceCount }
        guard let lastUser = rows[..<replaceCount].lastIndex(where: { role($0) == "user" }) else { return 0 }
        return lastUser > 0 && containsRawTurn(Array(rows.prefix(lastUser))) ? lastUser : 0
    }
    static func transcriptCharacterCount(_ rows: [JSONValue]) -> Int {
        var total = 0
        for row in rows {
            guard case .object(let obj) = row else { continue }
            total += ChatCompactionRowRendering.characterCount(obj)
        }
        return total
    }
    static func fileSize(_ path: URL) -> Int64 {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path.path),
              let size = attrs[.size] as? NSNumber else {
            return 0
        }
        return size.int64Value
    }
    static func fileSafeTimestamp(_ date: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: date)
    }
}
