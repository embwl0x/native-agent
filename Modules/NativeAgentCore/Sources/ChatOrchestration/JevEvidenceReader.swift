import Darwin
import Foundation
import NativeAgentCore
import PersistenceCore

/// An on-demand projection, not another ledger. The transcript chooses the
/// completed turn; the Jev log supplies only what it actually recorded.
enum JevEvidenceReader {
    static let maximumFileBytes = 1024 * 1024
    static let maximumReturnedRows = 64
    static let maximumOutputBytes = 32 * 1024

    struct Row {
        let value: [String: JSONValue]
        let offset: UInt64
        let length: Int
    }

    struct Window {
        let path: URL
        var rows: [Row] = []
        var size: UInt64 = 0
        var start: UInt64 = 0
        var bytesRead = 0
        var malformedOffsets: [UInt64] = []
        var unfinishedTail = false
        var status = "ok"
        var version = ""

        var coverage: JSONValue {
            .object([
                "path": .string(path.path), "status": .string(status),
                "source_bytes": .int(Int64(clamping: size)),
                "start_byte": .int(Int64(clamping: start)),
                "bytes_read": .int(Int64(bytesRead)),
                "prefix_omitted": .bool(start > 0),
                "malformed_rows": .int(Int64(malformedOffsets.count)),
                "unfinished_tail": .bool(unfinishedTail),
                "file_version": .string(version),
            ])
        }

        func locator(_ row: Row) -> JSONValue {
            .object([
                "path": .string(path.path), "file_version": .string(version),
                "byte_offset": .int(Int64(clamping: row.offset)),
                "byte_length": .int(Int64(row.length)),
            ])
        }
    }

    /// Regular files only, no final symlink, no unbounded decode or FIFO wait.
    /// Offsets refer to this file version; rotation/rewrite can invalidate them.
    static func readWindow(_ path: URL, maximumBytes: Int = maximumFileBytes) -> Window {
        var window = Window(path: path)
        let fd = open(path.path, O_RDONLY | O_NONBLOCK | O_NOFOLLOW)
        guard fd >= 0 else {
            window.status = errno == ENOENT ? "missing" : "unavailable"
            return window
        }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? handle.close() }
        var before = stat()
        guard fstat(fd, &before) == 0, (before.st_mode & S_IFMT) == S_IFREG,
              before.st_size >= 0 else {
            window.status = "not_regular_file"
            return window
        }
        window.size = UInt64(before.st_size)
        window.start = window.size > UInt64(max(1, maximumBytes))
            ? window.size - UInt64(max(1, maximumBytes)) : 0
        window.version = "\(before.st_dev):\(before.st_ino):\(before.st_size):\(before.st_mtimespec.tv_sec):\(before.st_mtimespec.tv_nsec)"
        do {
            try handle.seek(toOffset: window.start)
            let data = try handle.read(upToCount: Int(window.size - window.start)) ?? Data()
            window.bytesRead = data.count
            var lineStart = data.startIndex
            // A leading partial record is never decoded, even if its suffix
            // happens to be valid JSON. Include a one-byte boundary check.
            if window.start > 0 {
                try handle.seek(toOffset: window.start - 1)
                if try handle.read(upToCount: 1)?.first != 10 {
                    if let newline = data.firstIndex(of: 10) {
                        lineStart = data.index(after: newline)
                    } else {
                        lineStart = data.endIndex
                    }
                }
            }
            while lineStart < data.endIndex,
                  let newline = data[lineStart...].firstIndex(of: 10) {
                let bytes = Data(data[lineStart..<newline])
                let offset = window.start + UInt64(lineStart)
                if !bytes.isEmpty {
                    if case .object(let row)? = try? JSONValue.parse(bytes) {
                        window.rows.append(Row(value: row, offset: offset, length: bytes.count))
                    } else {
                        window.malformedOffsets.append(offset)
                    }
                }
                lineStart = data.index(after: newline)
            }
            // Writers append newline-terminated rows. A trailing fragment is
            // pending evidence, never a completed event or an older-turn fallback.
            window.unfinishedTail = lineStart < data.endIndex
            var after = stat()
            var atPath = stat()
            if data.count != Int(window.size - window.start)
                || fstat(fd, &after) != 0 || lstat(path.path, &atPath) != 0
                || before.st_ino != atPath.st_ino || before.st_dev != atPath.st_dev
                || before.st_size != after.st_size
                || before.st_mtimespec.tv_sec != after.st_mtimespec.tv_sec
                || before.st_mtimespec.tv_nsec != after.st_mtimespec.tv_nsec {
                window.status = "changed_during_read"
            }
        } catch {
            window.status = "read_failed"
        }
        return window
    }

    static func projection(dataRoot: URL, sessionID: String, turnID: String?) -> JSONValue {
        guard let session = NativeAgentChatSessionID.normalizedPathComponent(sessionID) else {
            return .object(["status": .string("missing_or_invalid_session"),
                            "hint": .string("Use the conversation session_id; an in-turn call supplies it automatically.")])
        }
        let requestedTurn = turnID?.trimmingCharacters(in: .whitespacesAndNewlines)
        var selectedTurn = requestedTurn.flatMap { $0.isEmpty ? nil : $0 }
        var response: [String: JSONValue] = [
            "detail": .string("jev"), "session_id": .string(session),
            "selection": .string(selectedTurn == nil ? "last_completed_turn" : "explicit_turn"),
            "read_at": .string(ISO8601DateFormatter().string(from: Date())),
        ]
        if selectedTurn == nil {
            let transcript = readWindow(dataRoot.appendingPathComponent("chat/messages/\(session).jsonl"))
            response["transcript_coverage"] = transcript.coverage
            guard transcript.status == "ok", !transcript.unfinishedTail else {
                response["status"] = .string("turn_unavailable")
                response["reason"] = .string("The latest completed turn cannot be established from this transcript snapshot.")
                return .object(response)
            }
            for row in transcript.rows.reversed() where row.value["role"] == .string("assistant") {
                let metadata = object(row.value["metadata"])
                if row.value["cancelled"] == .bool(true) || metadata["cancelled"] == .bool(true)
                    || metadata["partial"] == .bool(true) { continue }
                // Do not hop over a newer, uncorrelated assistant response.
                guard !transcript.malformedOffsets.contains(where: { $0 > row.offset }),
                      string(row.value["sessionId"]) == session,
                      object(metadata["outcomeObservation"])["responsePersistence"] == .string("persisted"),
                      let anchor = string(metadata["turnTraceId"]), !anchor.isEmpty else { break }
                selectedTurn = anchor
                response["assistant_message_id"] = row.value["id"] ?? .null
                response["run_id"] = row.value["runId"] ?? .null
                response["completed_at"] = row.value["createdAt"] ?? .null
                response["turn_evidence"] = transcript.locator(row)
                break
            }
        }
        guard let selectedTurn, selectedTurn.count <= 200 else {
            response["status"] = .string("turn_unavailable")
            response["reason"] = .string("No exact completed-turn identity in the bounded transcript window. Supply a known turn_id, or inspect session history; no older turn was guessed.")
            return .object(response)
        }
        response["turn_id"] = .string(selectedTurn)
        let windows = ["log.1.jsonl", "log.jsonl"].map {
            readWindow(dataRoot.appendingPathComponent("jev/\($0)"))
        }
        response["log_coverage"] = .array(windows.map(\.coverage))
        let matches = windows.flatMap { window in
            window.rows.filter {
                string($0.value["sessionId"]) == session && string($0.value["turnId"]) == selectedTurn
            }.map { (window, $0) }
        }
        var outputBytes = 0
        var selected: [(Window, Row)] = []
        for pair in matches.reversed().prefix(maximumReturnedRows) {
            let cost = (try? projectedRecord(pair.1, window: pair.0).serialize(pretty: false).utf8.count) ?? maximumOutputBytes
            guard outputBytes + cost <= maximumOutputBytes else { break }
            outputBytes += cost
            selected.append(pair)
        }
        selected.reverse()
        response["matched_row_count"] = .int(Int64(matches.count))
        response["returned_row_count"] = .int(Int64(selected.count))
        response["rows_omitted"] = .bool(matches.count > selected.count)
        response["status"] = .string(matches.isEmpty ? "not_observed" : "ok")
        response["interpretation"] = .string("Observed rows only. No row means unknown, not skipped or disabled. Missing turn IDs, rotation, read bounds and asynchronous writes can hide evidence. Scores are advice, not verified outcomes. 'carried into the next turn' means queued, not proof the model received it. secs measure recorded inference duration, not added turn latency. Locators belong to the captured file version.")
        response["lanes"] = .array(JevLane.allCases.map { lane in
            let rows = selected.filter { $0.1.value["lane"] == .string(lane.rawValue) }
            let matchedCount = matches.filter { $0.1.value["lane"] == .string(lane.rawValue) }.count
            return .object([
                "lane": .string(lane.rawValue),
                "evidence": .string(matchedCount == 0 ? "not_observed" : "observed"),
                "matched_row_count": .int(Int64(matchedCount)),
                "records_omitted": .bool(rows.count < matchedCount),
                "records": .array(rows.map { projectedRecord($0.1, window: $0.0) }),
            ])
        })
        return .object(response)
    }

    private static func string(_ value: JSONValue?) -> String? {
        if case .string(let text) = value { return text }
        return nil
    }

    private static func projectedRecord(_ row: Row, window: Window) -> JSONValue {
        var result: [String: JSONValue] = ["source": window.locator(row)]
        // No credentials, transcript text or arbitrary future fields.
        for key in ["ts", "summary", "answers", "usage", "secs", "err", "model",
                    "prompt_version", "acted", "would_preload_family",
                    "suggested_family", "dispatched_families", "lines", "disposition",
                    // What was told, and whether it landed — the lane's own
                    // words, already redacted and capped when they were written.
                    "told", "source_turn", "reached_agent"] {
            if let value = row.value[key] { result[key] = bounded(value) }
        }
        return .object(result)
    }

    private static func object(_ value: JSONValue?) -> [String: JSONValue] {
        if case .object(let row) = value { return row }
        return [:]
    }

    private static func bounded(_ value: JSONValue, depth: Int = 0) -> JSONValue {
        guard depth < 4 else { return .string("[detail omitted]") }
        switch NativeAgentSecretRedactor.redactValue(value) {
        case .string(let text):
            return .string(text.count > 500 ? String(text.prefix(500)) + " [truncated]" : text)
        case .array(let values):
            var result = values.prefix(32).map { bounded($0, depth: depth + 1) }
            if values.count > 32 { result.append(.string("[additional entries omitted]")) }
            return .array(result)
        case .object(let values):
            var result = Dictionary(uniqueKeysWithValues: values.keys.sorted().prefix(32).map {
                ($0, bounded(values[$0]!, depth: depth + 1))
            })
            if values.count > 32 { result["_omitted_fields"] = .int(Int64(values.count - 32)) }
            return .object(result)
        default: return value
        }
    }
}
