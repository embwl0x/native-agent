import Foundation
import SQLite3
import PersistenceCore

/// A small, read-only window into one Messages-owned conversation. No transcript
/// cache, database copy, background scan, or archived-object instantiation.
enum MacMessagesHistory {
    private final class Budget {
        let deadline = ProcessInfo.processInfo.systemUptime + 2
    }

    static func read(threadID: String, limit: Int, before: Int64?) -> [String: JSONValue] {
        guard !Task.isCancelled else { return unavailable("history_cancelled", "The conversation read was cancelled.") }
        var database: OpaquePointer?
        let path = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Messages/chat.db").path
        let opened = sqlite3_open_v2(path, &database, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil)
        defer { if let database { sqlite3_close(database) } }
        guard opened == SQLITE_OK, let database else {
            return unavailable("database_unavailable", "Conversation metadata is available, but its local history could not be opened. NativeAgent may need macOS Full Disk Access. No permission was changed.")
        }
        sqlite3_busy_timeout(database, 150)
        let budget = Budget()
        let budgetPointer = Unmanaged.passUnretained(budget).toOpaque()
        sqlite3_progress_handler(database, 500, { pointer in
            guard let pointer else { return 1 }
            let budget = Unmanaged<Budget>.fromOpaque(pointer).takeUnretainedValue()
            return Task.isCancelled || ProcessInfo.processInfo.systemUptime >= budget.deadline ? 1 : 0
        }, budgetPointer)
        defer {
            sqlite3_progress_handler(database, 0, nil, nil)
            withExtendedLifetime(budget) {}
        }

        // guid is unique and the join's primary key starts with chat_id. Requiring
        // their actual indexes prevents an unexpected schema from causing a scan.
        guard indexed(database, table: "chat", columns: ["guid"], unique: true),
              indexed(database, table: "chat_message_join", columns: ["chat_id", "message_id"], unique: true) else {
            return unavailable("unsupported_history_schema", "This Messages database does not expose the exact indexed conversation route needed for a bounded read.")
        }
        var chat: OpaquePointer?
        guard sqlite3_prepare_v2(database, "SELECT ROWID FROM chat WHERE guid = ? LIMIT 1", -1, &chat, nil) == SQLITE_OK, let chat else {
            return unavailable("unsupported_history_schema", "This Messages database could not provide an exact conversation lookup.")
        }
        defer { sqlite3_finalize(chat) }
        bind(threadID, to: chat, at: 1)
        let chatResult = sqlite3_step(chat)
        guard chatResult == SQLITE_ROW else {
            return unavailable(chatResult == SQLITE_DONE ? "exact_thread_not_found" : "history_read_failed",
                "The observed Messages conversation could not be matched to local history by its exact ID. No alternate recipient or conversation was substituted.")
        }
        let chatID = sqlite3_column_int64(chat, 0)
        let sql = """
        SELECT m.ROWID, substr(m.text, 1, 4096), m.date, m.is_from_me,
               substr(h.id, 1, 256), m.cache_has_attachments,
               m.attributedBody IS NOT NULL, length(m.text) > 4096,
               m.associated_message_type, m.item_type,
               CASE WHEN m.text IS NULL AND length(m.attributedBody) <= 65536
                    THEN m.attributedBody ELSE NULL END,
               length(m.attributedBody)
        FROM (SELECT message_id FROM chat_message_join
              WHERE chat_id = ? AND message_id < ? ORDER BY message_id DESC LIMIT ?) AS page
        JOIN message AS m ON m.ROWID = page.message_id
        LEFT JOIN handle AS h ON h.ROWID = m.handle_id
        ORDER BY m.ROWID DESC
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            return unavailable("unsupported_history_schema", "This Messages database version cannot provide this bounded history view.")
        }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int64(statement, 1, chatID)
        sqlite3_bind_int64(statement, 2, before ?? Int64.max)
        sqlite3_bind_int(statement, 3, Int32(min(30, max(1, limit))))
        var messages: [JSONValue] = []
        var remainingBytes = 16 * 1024
        var oldest: Int64?
        var stoppedForBudget = false
        var step = sqlite3_step(statement)
        while step == SQLITE_ROW {
            guard !Task.isCancelled, ProcessInfo.processInfo.systemUptime < budget.deadline else {
                return unavailable("history_temporarily_unavailable", "The bounded conversation read was cancelled or exceeded its time budget; refresh to retry.")
            }
            if remainingBytes == 0 { stoppedForBudget = true; break }
            let id = sqlite3_column_int64(statement, 0)
            oldest = id
            let plain = string(statement, 1)
            let archiveTooLarge = sqlite3_column_int64(statement, 11) > Int64(MacMessagesTypedString.maximumArchiveBytes)
            let decoded: String?
            if plain == nil, let archive = blob(statement, 10) {
                decoded = MacMessagesTypedString.decode(archive, deadline: budget.deadline)
            } else { decoded = nil }
            let original = plain ?? decoded
            let body = clipped(original ?? "", bytes: remainingBytes)
            remainingBytes -= body.utf8.count
            let date = sqlite3_column_int64(statement, 2)
            var row: [String: JSONValue] = [
                "message_id": .int(id),
                "from_me": .bool(sqlite3_column_int(statement, 3) != 0),
                "has_attachments": .bool(sqlite3_column_int(statement, 5) != 0),
                "text_status": .string(original == nil ? (sqlite3_column_int(statement, 6) != 0 ? "archived_text_not_decoded" : "no_plain_text") : "available"),
                "text_source": .string(plain != nil ? "plain_text_column" : decoded != nil ? "typedstream_foundation_string" : "unavailable"),
                "text_truncated": .bool(sqlite3_column_int(statement, 7) != 0 || body.utf8.count < (original?.utf8.count ?? 0)),
                "associated_message_type": .int(Int64(sqlite3_column_int(statement, 8))),
                "item_type": .int(Int64(sqlite3_column_int(statement, 9))),
            ]
            if original == nil, sqlite3_column_int(statement, 6) != 0 {
                row["text_unavailable_reason"] = .string(archiveTooLarge ? "archive_exceeds_64kib_budget" : "unsupported_or_invalid_archive")
            }
            if original != nil { row["text"] = .string(body) }
            if let sender = string(statement, 4) { row["sender"] = .string(sender) }
            if date > 0 {
                let seconds = Double(date) / (date > 100_000_000_000 ? 1_000_000_000 : 1)
                row["date"] = .string(ISO8601DateFormatter().string(from: Date(timeIntervalSinceReferenceDate: seconds)))
            }
            messages.append(.object(row))
            step = sqlite3_step(statement)
        }
        guard !Task.isCancelled, ProcessInfo.processInfo.systemUptime < budget.deadline else {
            return unavailable("history_temporarily_unavailable", "The bounded conversation read was cancelled or exceeded its time budget; refresh to retry.")
        }
        guard step == SQLITE_DONE || stoppedForBudget else {
            return unavailable(step == SQLITE_INTERRUPT || step == SQLITE_BUSY || step == SQLITE_LOCKED ? "history_temporarily_unavailable" : "history_read_failed",
                "The bounded history read did not finish. No partial page is presented as a complete conversation; refresh to retry.")
        }
        var result: [String: JSONValue] = [
            "history_status": .string("available"), "messages": .array(Array(messages.reversed())),
            "history_ordering": .string("Recent local message records, displayed oldest to newest within this page; insertion order can differ from delivery time."),
            "history_note": .string("Read-only local history. Plain text and supported Foundation string bodies are shown. Formatting, attachment content and special records are not interpreted; unsupported archives are labeled, never treated as empty messages. Full Disk Access remains controlled by macOS."),
        ]
        if messages.count == min(30, max(1, limit)) || stoppedForBudget, let oldest {
            // A full page permits one bounded older read; it does not assert that
            // older rows exist without reading them.
            result["older_before_message_id"] = .int(oldest)
        }
        return result
    }

    private static func indexed(_ database: OpaquePointer, table: String, columns: [String], unique: Bool) -> Bool {
        var list: OpaquePointer?
        guard sqlite3_prepare_v2(database, "PRAGMA index_list(\(table))", -1, &list, nil) == SQLITE_OK, let list else { return false }
        defer { sqlite3_finalize(list) }
        while sqlite3_step(list) == SQLITE_ROW {
            guard (!unique || sqlite3_column_int(list, 2) != 0), sqlite3_column_int(list, 4) == 0,
                  let name = string(list, 1) else { continue }
            let escaped = name.replacingOccurrences(of: "\"", with: "\"\"")
            var info: OpaquePointer?
            guard sqlite3_prepare_v2(database, "PRAGMA index_info(\"\(escaped)\")", -1, &info, nil) == SQLITE_OK, let info else { continue }
            var found: [String] = []
            while sqlite3_step(info) == SQLITE_ROW { if let column = string(info, 2) { found.append(column) } }
            sqlite3_finalize(info)
            if found == columns { return true }
        }
        return false
    }

    private static func bind(_ value: String, to statement: OpaquePointer, at index: Int32) {
        _ = value.withCString { sqlite3_bind_text(statement, index, $0, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self)) }
    }
    private static func string(_ statement: OpaquePointer, _ column: Int32) -> String? {
        guard let pointer = sqlite3_column_text(statement, column) else { return nil }
        return String(bytes: UnsafeBufferPointer(start: pointer, count: Int(sqlite3_column_bytes(statement, column))), encoding: .utf8)
    }
    private static func blob(_ statement: OpaquePointer, _ column: Int32) -> Data? {
        let count = Int(sqlite3_column_bytes(statement, column))
        guard count > 0, count <= MacMessagesTypedString.maximumArchiveBytes,
              let pointer = sqlite3_column_blob(statement, column) else { return nil }
        return Data(bytes: pointer, count: count)
    }
    private static func clipped(_ value: String, bytes: Int) -> String {
        var prefix = Array(value.utf8.prefix(bytes))
        while !prefix.isEmpty {
            if let result = String(bytes: prefix, encoding: .utf8) { return result }
            prefix.removeLast()
        }
        return ""
    }
    private static func unavailable(_ reason: String, _ note: String) -> [String: JSONValue] {
        ["history_status": .string("unavailable"), "history_reason": .string(reason), "history_note": .string(note)]
    }
}
