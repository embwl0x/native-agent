import Foundation
import SQLite3
import PersistenceCore

/// A small, read-only window into Messages' own conversations and history.
/// No transcript cache, database copy, background scan or archived-object instantiation.
enum MacMessagesHistory {
    /// chat.db opened read-only for one read, with a 2 s budget that
    /// interrupts any statement still running past it.
    private final class Budget {
        let deadline = ProcessInfo.processInfo.systemUptime + 2
        let database: OpaquePointer

        init?() {
            var database: OpaquePointer?
            let path = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Messages/chat.db").path
            guard sqlite3_open_v2(path, &database, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK, let database else {
                if let database { sqlite3_close(database) }
                return nil
            }
            self.database = database
            sqlite3_busy_timeout(database, 150)
            FoldedText.register(database)
            sqlite3_progress_handler(database, 500, { pointer in
                guard let pointer else { return 1 }
                let budget = Unmanaged<Budget>.fromOpaque(pointer).takeUnretainedValue()
                return Task.isCancelled || ProcessInfo.processInfo.systemUptime >= budget.deadline ? 1 : 0
            }, Unmanaged.passUnretained(self).toOpaque())
        }

        deinit {
            sqlite3_progress_handler(database, 0, nil, nil)
            sqlite3_close(database)
        }
    }

    static func read(threadID: String? = nil, limit: Int, before: Int64? = nil, fromMe: Bool? = nil, since: Date? = nil) -> [String: JSONValue] {
        guard !Task.isCancelled else { return unavailable("history_cancelled", "The conversation read was cancelled.") }
        guard let budget = Budget() else {
            return unavailable("database_unavailable", fromMe == nil
                ? "Conversation metadata is available, but its local history could not be opened. NativeAgent may need macOS Full Disk Access. No permission was changed."
                : "Messages' local database could not be opened. NativeAgent may need macOS Full Disk Access. No permission was changed.")
        }
        let database = budget.database
        defer { withExtendedLifetime(budget) {} }

        // guid is unique and the join's primary key starts with chat_id. Requiring
        // their actual indexes prevents an unexpected schema from causing a scan.
        guard fromMe != nil || (index(database, table: "chat", columns: ["guid"], unique: true) != nil &&
              index(database, table: "chat_message_join", columns: ["chat_id", "message_id"], unique: true) != nil) else {
            return unavailable("unsupported_history_schema", "This Messages database does not expose the exact indexed conversation route needed for a bounded read.")
        }
        var chatID: Int64 = 0
        var chat: OpaquePointer?
        defer { if let chat { sqlite3_finalize(chat) } }
        if let threadID {
            guard sqlite3_prepare_v2(database, "SELECT ROWID FROM chat WHERE guid = ? LIMIT 1", -1, &chat, nil) == SQLITE_OK, let chat else {
                return unavailable("unsupported_history_schema", "This Messages database could not provide an exact conversation lookup.")
            }
            bind(threadID, to: chat, at: 1)
            let chatResult = sqlite3_step(chat)
            guard chatResult == SQLITE_ROW else {
                return unavailable(chatResult == SQLITE_DONE ? "exact_thread_not_found" : "history_read_failed",
                    "The observed Messages conversation could not be matched to local history by its exact ID. No alternate recipient or conversation was substituted.")
            }
            chatID = sqlite3_column_int64(chat, 0)
        }
        let unread = unreadAvailable(database)
        let columns = """
        SELECT m.ROWID, substr(m.text, 1, 4096), m.date, m.is_from_me,
               substr(h.id, 1, 256), m.cache_has_attachments,
               m.attributedBody IS NOT NULL, length(m.text) > 4096,
               m.associated_message_type, m.item_type,
               CASE WHEN m.text IS NULL AND length(m.attributedBody) <= 65536
                    THEN m.attributedBody ELSE NULL END,
               length(m.attributedBody), \(unread ? "m.is_read" : "NULL")
        """
        let sql: String
        if fromMe != nil {
            guard let dateIndex = index(database, table: "message", columns: ["date"], unique: false),
                  index(database, table: "chat_message_join", columns: ["message_id"], unique: false) != nil else {
                return unavailable("unsupported_history_schema", "This Messages database does not expose the indexed date and conversation routes needed for a bounded sender read.")
            }
            let dated = "message INDEXED BY \"\(dateIndex.replacingOccurrences(of: "\"", with: "\"\""))\""
            let filter = """
                is_from_me = ?1 AND date >= CASE WHEN (SELECT max(date) FROM \(dated)) > 100000000000 THEN ?2 ELSE ?3 END
                AND EXISTS (SELECT 1 FROM chat_message_join j JOIN chat c ON c.ROWID = j.chat_id WHERE j.message_id = message.ROWID)
                """
            sql = """
                \(columns), total.n, c.guid, c.display_name,
                    (SELECT group_concat(h.id, char(10)) FROM chat_handle_join ch JOIN handle h ON h.ROWID = ch.handle_id WHERE ch.chat_id = c.ROWID)
                FROM (\(since == nil ? "SELECT NULL AS n" : "SELECT count(*) AS n FROM \(dated) WHERE \(filter)")) total
                LEFT JOIN (SELECT ROWID AS message_id FROM \(dated) WHERE \(filter) ORDER BY date DESC, ROWID DESC LIMIT ?4) page ON 1
                LEFT JOIN message m ON m.ROWID = page.message_id
                LEFT JOIN handle h ON h.ROWID = m.handle_id
                LEFT JOIN chat c ON c.ROWID = (SELECT j.chat_id FROM chat_message_join j JOIN chat linked ON linked.ROWID = j.chat_id WHERE j.message_id = m.ROWID ORDER BY j.chat_id LIMIT 1)
                ORDER BY m.date DESC, m.ROWID DESC
                """
        } else {
            sql = """
            \(columns)
            FROM (SELECT message_id FROM chat_message_join
                  WHERE chat_id = ? AND message_id < ? ORDER BY message_id DESC LIMIT ?) AS page
            JOIN message AS m ON m.ROWID = page.message_id
            LEFT JOIN handle AS h ON h.ROWID = m.handle_id
            ORDER BY m.ROWID DESC
            """
        }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            return unavailable("unsupported_history_schema", "This Messages database version cannot provide this bounded history view.")
        }
        defer { sqlite3_finalize(statement) }
        if let fromMe {
            let seconds = since?.timeIntervalSinceReferenceDate ?? 0
            sqlite3_bind_int(statement, 1, fromMe ? 1 : 0)
            sqlite3_bind_int64(statement, 2, since == nil ? .min : Int64((seconds * 1_000_000_000).rounded(.up)))
            sqlite3_bind_int64(statement, 3, since == nil ? .min : Int64(seconds.rounded(.up)))
            sqlite3_bind_int(statement, 4, Int32(min(30, max(1, limit))))
        } else {
            sqlite3_bind_int64(statement, 1, chatID)
            sqlite3_bind_int64(statement, 2, before ?? Int64.max)
            sqlite3_bind_int(statement, 3, Int32(min(30, max(1, limit))))
        }
        var messages: [JSONValue] = []
        var remainingBytes = 16 * 1024
        var oldest: Int64?
        var stoppedForBudget = false
        var total: Int64?
        var step = sqlite3_step(statement)
        while step == SQLITE_ROW {
            guard !Task.isCancelled, ProcessInfo.processInfo.systemUptime < budget.deadline else {
                return unavailable("history_temporarily_unavailable", "The bounded conversation read was cancelled or exceeded its time budget; refresh to retry.")
            }
            if fromMe != nil {
                if since != nil { total = sqlite3_column_int64(statement, 13) }
                if sqlite3_column_type(statement, 0) == SQLITE_NULL { step = sqlite3_step(statement); continue }
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
            if unread { row["is_read"] = .bool(sqlite3_column_int(statement, 12) != 0) }
            if original == nil, sqlite3_column_int(statement, 6) != 0 {
                row["text_unavailable_reason"] = .string(archiveTooLarge ? "archive_exceeds_64kib_budget" : "unsupported_or_invalid_archive")
            }
            if original != nil { row["text"] = .string(body) }
            if fromMe != nil {
                row["thread_id"] = string(statement, 14).map(JSONValue.string) ?? .null
                row["name"] = .string(string(statement, 15) ?? "")
                row["participants"] = .array((string(statement, 16) ?? "").split(separator: "\n").map {
                    .object(["handle": .string(String($0)), "name": .string("")])
                })
                if row["has_attachments"] == .bool(true) { row["attachment_label"] = .string("Attachment") }
            }
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
            "history_status": .string("available"), "messages": .array(fromMe == nil ? Array(messages.reversed()) : messages),
            "unread_state": .string(unread ? "available" : "unavailable"),
            "unread_note": .string(unread ? "is_read is the local Messages read flag, not a recipient delivery/read receipt."
                : "Unread state is unavailable: this Messages database does not expose is_read. No read flag is inferred."),
            "history_ordering": .string("Recent local message records, displayed oldest to newest within this page; insertion order can differ from delivery time."),
            "history_note": .string("Read-only local history. Plain text and supported Foundation string bodies are shown. Formatting, attachment content and special records are not interpreted; unsupported archives are labeled, never treated as empty messages. Full Disk Access remains controlled by macOS."),
        ]
        if let fromMe {
            result["from_me"] = .bool(fromMe)
            result["count"] = .int(Int64(messages.count))
            result["history_ordering"] = .string("Newest message date first across all conversations; message ID breaks date ties.")
            if let since, let total {
                result["since"] = .string(ISO8601DateFormatter().string(from: since))
                result[fromMe ? "sent_count" : "received_count"] = .int(total)
                result["count_note"] = .string("Exact local message record count from since (inclusive), independent of the page limit. Includes attachments, reactions and special records; not a count of conversations or recipients.")
            }
        } else if messages.count == min(30, max(1, limit)) || stoppedForBudget, let oldest {
            // A full page permits one bounded older read; it does not assert that
            // older rows exist without reading them.
            result["older_before_message_id"] = .int(oldest)
        }
        return result
    }

    /// Every conversation with a message, newest first: its people (handles),
    /// group name, and last message's date and text. With `words`, a
    /// conversation whose messages contain them carries the newest such
    /// message as `snippet`. Names come from Contacts in the caller.
    static func threads(words: String?, unreadOnly: Bool = false, oldestUnread: Bool = false) -> [String: JSONValue] {
        guard !Task.isCancelled else { return unavailable("history_cancelled", "The conversation read was cancelled.") }
        guard let budget = Budget() else {
            return unavailable("database_unavailable", "Messages' local database could not be opened. NativeAgent may need macOS Full Disk Access. No permission was changed.")
        }
        let database = budget.database
        defer { withExtendedLifetime(budget) {} }
        func text(_ statement: OpaquePointer, plain: Int32, archive: Int32) -> String? {
            string(statement, plain) ?? blob(statement, archive).flatMap { MacMessagesTypedString.decode($0, deadline: budget.deadline) }
        }
        func when(_ date: Int64) -> String? {
            guard date > 0 else { return nil }
            let seconds = Double(date) / (date > 100_000_000_000 ? 1_000_000_000 : 1)
            return ISO8601DateFormatter().string(from: Date(timeIntervalSinceReferenceDate: seconds))
        }
        let archived = "CASE WHEN m.text IS NULL AND length(m.attributedBody) <= 65536 THEN m.attributedBody END"
        let unread = unreadAvailable(database)
        guard unread || !(unreadOnly || oldestUnread) else {
            return unavailable("unread_state_unavailable", "This Messages database does not expose is_read, so unread filtering and ordering are unavailable.")
        }
        let unreadCount = unread ? "(SELECT count(*) FROM chat_message_join u JOIN message um ON um.ROWID = u.message_id WHERE u.chat_id = c.ROWID AND um.is_from_me = 0 AND um.is_read = 0)" : "NULL"
        let unreadJoin = unreadOnly || oldestUnread ? """
            JOIN message u ON u.ROWID = (SELECT um.ROWID FROM chat_message_join uj
                JOIN message um ON um.ROWID = uj.message_id
                WHERE uj.chat_id = c.ROWID AND um.is_from_me = 0 AND um.is_read = 0
                ORDER BY um.date ASC, um.ROWID ASC LIMIT 1)
            """ : ""
        let unreadColumns = oldestUnread ? "u.date, u.ROWID, substr(u.text, 1, 400), \(archived.replacingOccurrences(of: "m.", with: "u."))" : "NULL, NULL, NULL, NULL"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, """
            SELECT c.guid, c.display_name, j.last, m.is_from_me, substr(m.text, 1, 400), \(archived),
                   (SELECT group_concat(h.id, char(10)) FROM chat_handle_join ch JOIN handle h ON h.ROWID = ch.handle_id WHERE ch.chat_id = c.ROWID),
                   \(unread ? "m.is_read" : "NULL"), \(unreadCount), \(unreadColumns)
            FROM chat c
            JOIN (SELECT chat_id, max(message_date) AS last FROM chat_message_join GROUP BY chat_id) j ON j.chat_id = c.ROWID
            LEFT JOIN message m ON m.ROWID = (SELECT message_id FROM chat_message_join WHERE chat_id = c.ROWID ORDER BY message_date DESC, message_id DESC LIMIT 1)
            \(unreadJoin)
            ORDER BY \(oldestUnread ? "u.date ASC, u.ROWID ASC, c.guid ASC" : "j.last DESC")
            """, -1, &statement, nil) == SQLITE_OK, let statement else {
            return unavailable("unsupported_history_schema", "This Messages database version cannot list its conversations.")
        }
        defer { sqlite3_finalize(statement) }
        var threads: [[String: JSONValue]] = []
        var step = sqlite3_step(statement)
        while step == SQLITE_ROW {
            guard let id = string(statement, 0) else { step = sqlite3_step(statement); continue }
            let handles = (string(statement, 6) ?? "").split(separator: "\n").map { JSONValue.object(["handle": .string(String($0)), "name": .string("")]) }
            var row: [String: JSONValue] = ["thread_id": .string(id), "name": .string(string(statement, 1) ?? ""), "participants": .array(handles)]
            if unread {
                row["latest_message_is_read"] = sqlite3_column_type(statement, 7) == SQLITE_NULL ? .null : .bool(sqlite3_column_int(statement, 7) != 0)
                row["unread_count"] = .int(sqlite3_column_int64(statement, 8))
            }
            if let date = when(sqlite3_column_int64(statement, 2)) { row["date"] = .string(date) }
            if let last = text(statement, plain: 4, archive: 5).map({ String($0.prefix(160)) }), !last.isEmpty {
                row["preview"] = .string(sqlite3_column_int(statement, 3) != 0 ? "You: " + last : last)
            }
            if oldestUnread {
                row["oldest_unread_message_id"] = .int(sqlite3_column_int64(statement, 10))
                if let date = when(sqlite3_column_int64(statement, 9)) { row["oldest_unread_date"] = .string(date) }
                let preview = text(statement, plain: 11, archive: 12)
                row["oldest_unread_preview_status"] = .string(preview == nil ? "unavailable" : "available")
                if let preview { row["oldest_unread_preview"] = .string(String(preview.prefix(160))) }
            }
            threads.append(row)
            step = sqlite3_step(statement)
        }
        guard step == SQLITE_DONE else {
            return unavailable(step == SQLITE_INTERRUPT || step == SQLITE_BUSY || step == SQLITE_LOCKED ? "history_temporarily_unavailable" : "history_read_failed",
                "The conversation list did not finish within its bounded read; refresh to retry.")
        }
        var result: [String: JSONValue] = [
            "unread_state": .string(unread ? "available" : "unavailable"),
            "unread_note": .string(unread ? "unread_count counts all incoming unread local records in each thread, across all dates. latest_message_is_read describes only its latest message."
                : "Unread state is unavailable: this Messages database does not expose is_read. No unread count is inferred."),
        ]
        if let words {
            // Newest first. Plain text is matched in SQL over its whole length;
            // archived bodies are decoded and matched here.
            let folded = FoldedText.fold(words)
            var search: OpaquePointer?
            guard sqlite3_prepare_v2(database, """
                SELECT c.guid, substr(m.text, 1, 400), \(archived)
                FROM chat_message_join j JOIN message m ON m.ROWID = j.message_id JOIN chat c ON c.ROWID = j.chat_id
                WHERE (m.text IS NOT NULL AND folded_contains(m.text, ?1)) OR (m.text IS NULL AND m.attributedBody IS NOT NULL)
                ORDER BY j.message_date DESC
                """, -1, &search, nil) == SQLITE_OK, let search else {
                return unavailable("unsupported_history_schema", "This Messages database version cannot search its messages.")
            }
            defer { sqlite3_finalize(search) }
            bind(folded, to: search, at: 1)
            var found: [String: String] = [:]
            step = sqlite3_step(search)
            while step == SQLITE_ROW {
                if let id = string(search, 0), found[id] == nil {
                    if let plain = string(search, 1) { found[id] = String(plain.prefix(160)) }
                    else if let archive = blob(search, 2), let said = MacMessagesTypedString.decode(archive, deadline: budget.deadline),
                            FoldedText.fold(said).contains(folded) { found[id] = String(said.prefix(160)) }
                }
                step = sqlite3_step(search)
            }
            if step != SQLITE_DONE {
                result["partial"] = .bool(true)
                result["note"] = .string("The word search stopped at its time budget; older messages were not searched.")
            }
            threads = threads.map { row in
                guard case .string(let id)? = row["thread_id"], let said = found[id] else { return row }
                return row.merging(["snippet": .string(said)]) { _, new in new }
            }
        }
        result["threads"] = .array(threads.map(JSONValue.object))
        return result
    }

    private static func unreadAvailable(_ database: OpaquePointer) -> Bool {
        var statement: OpaquePointer?
        let status = sqlite3_prepare_v2(database, "SELECT is_read FROM message LIMIT 0", -1, &statement, nil)
        if let statement { sqlite3_finalize(statement) }
        return status == SQLITE_OK
    }

    private static func index(_ database: OpaquePointer, table: String, columns: [String], unique: Bool) -> String? {
        var list: OpaquePointer?
        guard sqlite3_prepare_v2(database, "PRAGMA index_list(\(table))", -1, &list, nil) == SQLITE_OK, let list else { return nil }
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
            if unique ? found == columns : found.starts(with: columns) { return name }
        }
        return nil
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

/// Matching as people expect it, case and accents aside ("elodie" finds
/// "Élodie"). SQLite's LIKE folds ASCII only, so the Mail and Messages reads
/// register `folded_contains(text, needle)`, `needle` already `fold`ed.
enum FoldedText {
    static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
    }

    static func register(_ database: OpaquePointer) {
        sqlite3_create_function_v2(database, "folded_contains", 2, SQLITE_UTF8 | SQLITE_DETERMINISTIC, nil, { context, _, values in
            guard let values, let hay = sqlite3_value_text(values[0]), let needle = sqlite3_value_text(values[1]) else {
                sqlite3_result_int(context, 0)
                return
            }
            let text = UnsafeBufferPointer(start: hay, count: Int(sqlite3_value_bytes(values[0])))
            let wanted = UnsafeBufferPointer(start: needle, count: Int(sqlite3_value_bytes(values[1])))
            // ASCII on both sides (most subjects and addresses) folds as lowercase, without a String.
            let found = text.allSatisfy({ $0 < 0x80 }) && wanted.allSatisfy({ $0 < 0x80 })
                ? FoldedText.asciiContains(text, wanted)
                : FoldedText.fold(String(decoding: text, as: UTF8.self)).contains(String(decoding: wanted, as: UTF8.self))
            sqlite3_result_int(context, found ? 1 : 0)
        }, nil, nil, nil)
    }

    private static func asciiContains(_ text: UnsafeBufferPointer<UInt8>, _ wanted: UnsafeBufferPointer<UInt8>) -> Bool {
        guard !wanted.isEmpty else { return true }
        guard text.count >= wanted.count else { return false }
        func lower(_ byte: UInt8) -> UInt8 { (65...90).contains(byte) ? byte | 0x20 : byte }
        next: for start in 0...(text.count - wanted.count) {
            for offset in 0..<wanted.count where lower(text[start + offset]) != wanted[offset] { continue next }
            return true
        }
        return false
    }
}
