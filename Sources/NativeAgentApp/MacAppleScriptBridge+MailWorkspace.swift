import Foundation
import SQLite3
import PersistenceCore
import MacIntegration
import UniformTypeIdentifiers

extension MacAppleScriptBridge {
    /// Bounded mailbox reads with opaque owner IDs. Transport fields are encoded
    /// separately so message content can never manufacture another message ID.
    static func mailWorkspaceRead(input: [String: JSONValue], query: [String]? = nil) async throws -> JSONValue {
        var input = input
        if input["message_id"] != nil, input["expected_message_id"] == nil { input["expected_message_id"] = .string("") }
        guard let scope = mailReadScope(input) else {
            return .object(["status": .string("failed"), "integration": .string("mail"),
                "reason": .string("unsupported_mailbox"),
                "message": .string("Accepted scopes: inbox, sent. scope and mailbox must agree when both are supplied.")])
        }
        if input["message_id"] != nil && mailExactLocator(input, allowMissingMessageID: true) == nil {
            return .object(["status": .string("failed"), "integration": .string("mail"),
                "reason": .string("invalid_message_locator"),
                "message": .string("Call mail_list_recent without message_id, then copy scope, message_id, expected_message_id, expected_account and position from the same row to read it.")])
        }
        do {
            let local = mailLocalRead(input)
            if let row = local.row {
                return .object(["status": .string("completed"), "count": .int(1),
                    "messages": .array([.object(row)]), "scope": .string(scope), "detail": .bool(true)])
            }
            let script = mailWorkspaceScript(input: input)
            let raw: String
            do {
                try Task.checkCancellation()
                raw = try await runAppleScript(script)
            } catch let error as NSError where error.domain == "NativeAgentAppleScript" && [-1712, -1001, appleScriptOutcomeUnknownCode].contains(error.code) {
                // Only this read retries, once, with the same paired identity and time bounds.
                try Task.checkCancellation()
                raw = try await runAppleScript(script)
            }
            if let setup = readSetupEnvelope(raw: raw, integration: "mail") { return setup }
            if raw == "__MESSAGE_CHANGED__" {
                return .object(["status": .string("failed"), "integration": .string("mail"),
                    "reason": .string("message_changed_or_moved_refresh_inbox"),
                    "message": .string("The message no longer matches this mailbox locator. Call mail_list_recent without message_id in the same scope and use the identifiers from one fresh row; do not reuse its old position.")])
            }
            if input["message_id"] == nil { return mailIndexPage(header: raw, input: input, query: query) }
            let rows = parseMailWorkspaceRecords(raw, detail: true)
            if rows.isEmpty { return failedEnvelope(integration: "mail", reason: "message_not_in_inbox") }
            return .object(["status": .string("completed"), "count": .int(Int64(rows.count)),
                "messages": .array(rows.map { row in
                    guard case .object(var object) = row else { return row }
                    object["scope"] = .string(scope)
                    object["attachments_status"] = .string(local.attachments)
                    return .object(object)
                }), "scope": .string(scope), "detail": .bool(true)])
        } catch let AppleScriptError.permissionDenied(app) {
            return deniedEnvelope(integration: "mail", app: app)
        } catch let error as NSError where error.domain == "NativeAgentAppleScript" && [-1712, -1001, appleScriptOutcomeUnknownCode].contains(error.code) {
            // A read changes nothing, so the "outcome unknown" caution for sends does not apply.
            return .object(["status": .string("failed"), "integration": .string("mail"), "error_code": .int(Int64(error.code)),
                "error": .string("Mail did not answer within two bounded read attempts (it may be busy syncing). Nothing was changed. Let Mail finish syncing, then call mail_list_recent again; for a message body, use the scope, identifiers and position from a fresh row.")])
        } catch { return failedEnvelope(integration: "mail", error: error) }
    }

    static func mailReadScope(_ input: [String: JSONValue]) -> String? {
        let value = input["scope"] ?? input["mailbox"] ?? .string("inbox")
        guard case .string(let scope) = value, ["inbox", "sent"].contains(scope),
              input["scope"] == nil || input["mailbox"] == nil || input["scope"] == input["mailbox"] else { return nil }
        return scope
    }

    static func mailIndexDatabase() -> OpaquePointer? {
        let library = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Mail")
        let version = ((try? FileManager.default.contentsOfDirectory(atPath: library.path)) ?? [])
            .compactMap { $0.hasPrefix("V") ? Int($0.dropFirst()) : nil }.max()
        var database: OpaquePointer?
        guard let version,
              sqlite3_open_v2(library.appendingPathComponent("V\(version)/MailData/Envelope Index").path, &database,
                              SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK else {
            if let database { sqlite3_close(database) }
            return nil
        }
        if let database { sqlite3_busy_timeout(database, 500); FoldedText.register(database) }
        return database
    }

    public static func mailSenders(input: [String: JSONValue]) async throws -> JSONValue {
        let scope = input["scope"] ?? .string("inbox")
        guard scope == .string("inbox") || scope == .string("all"),
              input["unread_only"] == nil || input["unread_only"] == .bool(true) || input["unread_only"] == .bool(false) else {
            return failedEnvelope(integration: "mail", reason: "invalid_mail_filter")
        }
        do {
            let header = scope == .string("inbox") ? try await runAppleScript(mailWorkspaceScript(input: [:])) : ""
            if let setup = readSetupEnvelope(raw: header, integration: "mail") { return setup }
            let task = Task.detached(priority: .utility) { mailIndexSenders(header: header, input: input) }
            let result = await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
            try Task.checkCancellation()
            return result
        } catch let AppleScriptError.permissionDenied(app) {
            return deniedEnvelope(integration: "mail", app: app)
        } catch { return failedEnvelope(integration: "mail", error: error) }
    }

    static func mailIndexAccounts(_ header: String) -> [(name: String, id: String, inbox: String)] {
        header.split(separator: "\n").compactMap { line in
            let fields = line.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
            guard fields.count == 4, fields[0] == "__BOX__" else { return nil }
            let decoded = fields[1...3].map { decodeConversationTransport($0) ?? "" }
            return (decoded[0], decoded[1], decoded[2])
        }
    }

    static func mailIndexFilters(_ input: [String: JSONValue], bind: (Any) -> String) -> (sql: String, error: JSONValue?) {
        var filter = ""
        if let since = input["since"] {
            guard case .string(let value) = since else { return ("", failedEnvelope(integration: "mail", reason: "invalid_mail_since")) }
            let local = DateFormatter()
            local.locale = Locale(identifier: "en_US_POSIX"); local.calendar = Calendar(identifier: .gregorian)
            local.dateFormat = "yyyy-MM-dd"; local.isLenient = false
            let date = value == "this week" ? Calendar.current.dateInterval(of: .weekOfYear, for: Date())?.start
                : value.count == 10 ? local.date(from: value).flatMap { local.string(from: $0) == value ? $0 : nil } : ISO8601DateFormatter().date(from: value)
            guard let date else {
                return ("", .object(["status": .string("failed"), "integration": .string("mail"),
                    "message": .string("since must be this week (start of the local calendar week), local YYYY-MM-DD, or ISO-8601 with a time zone.")]))
            }
            filter += " AND m.date_received >= \(bind(Int(date.timeIntervalSince1970)))"
        }
        if let category = input["category"] {
            guard case .string(let name) = category else { return ("", failedEnvelope(integration: "mail", reason: "invalid_mail_category")) }
            let categories = ["primary", "transactions", "updates", "promotions"]
            let names = name.components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            let indices = names.compactMap { categories.firstIndex(of: $0) }
            guard !indices.isEmpty, indices.count == names.count else { return ("", failedEnvelope(integration: "mail", reason: "invalid_mail_category")) }
            filter += " AND coalesce(g.model_category, 0) IN (\(indices.map { bind($0) }.joined(separator: ",")))"
        }
        return (filter, nil)
    }

    static func mailIndexSenders(header: String, input: [String: JSONValue]) -> JSONValue {
        guard let database = mailIndexDatabase() else { return failedEnvelope(integration: "mail", reason: "mail_index_unavailable") }
        defer { sqlite3_close(database) }
        // Stop expensive aggregation rather than returning guessed or partial totals.
        let deadline = NSNumber(value: ProcessInfo.processInfo.systemUptime + 2)
        sqlite3_progress_handler(database, 500, { pointer in
            guard let pointer else { return 1 }
            return Task.isCancelled || ProcessInfo.processInfo.systemUptime >= Unmanaged<NSNumber>.fromOpaque(pointer).takeUnretainedValue().doubleValue ? 1 : 0
        }, Unmanaged.passUnretained(deadline).toOpaque())
        defer { sqlite3_progress_handler(database, 0, nil, nil); withExtendedLifetime(deadline) {} }
        var bindings: [Any] = []
        func bind(_ value: Any) -> String { bindings.append(value); return "?\(bindings.count)" }
        let dated = mailIndexFilters(input, bind: bind)
        if let error = dated.error { return error }
        var filter = "m.deleted = 0" + dated.sql
        if input["unread_only"] == .bool(true) { filter += " AND m.read = 0" }
        let scope = inputString(input["scope"]) ?? "inbox"
        if scope == "inbox" {
            let accounts = mailIndexAccounts(header)
            guard !accounts.isEmpty else { return failedEnvelope(integration: "mail", reason: "mail_index_unavailable") }
            var boxes: OpaquePointer?
            guard sqlite3_prepare_v2(database, "SELECT ROWID, url FROM mailboxes", -1, &boxes, nil) == SQLITE_OK, let boxes else {
                return failedEnvelope(integration: "mail", reason: "mail_index_unavailable")
            }
            defer { sqlite3_finalize(boxes) }
            var matched: Set<Int> = [], ids: [Int64] = []
            var step = sqlite3_step(boxes)
            while step == SQLITE_ROW {
                if let raw = sqlite3_column_text(boxes, 1), let url = URL(string: String(cString: raw)), let host = url.host,
                   let index = accounts.firstIndex(where: { !$0.id.isEmpty && !$0.inbox.isEmpty
                       && host.caseInsensitiveCompare($0.id) == .orderedSame
                       && String(url.path.dropFirst()).caseInsensitiveCompare($0.inbox) == .orderedSame }) {
                    matched.insert(index); ids.append(sqlite3_column_int64(boxes, 0))
                }
                step = sqlite3_step(boxes)
            }
            guard step == SQLITE_DONE, matched.count == accounts.count else {
                return failedEnvelope(integration: "mail", reason: "inbox_coverage_unavailable")
            }
            let selected = ids.map { bind($0) }.joined(separator: ",")
            filter += " AND (m.mailbox IN (\(selected)) OR m.ROWID IN (SELECT message_id FROM labels WHERE mailbox_id IN (\(selected))))"
        }
        let limit = clampedInt(input["limit"], defaultValue: 15, min: 1, max: 50)
        let sql = """
            SELECT lower(trim(coalesce(a.address, ''))), a.comment, count(*), sum(m.read = 0), max(m.date_received)
            FROM messages m LEFT JOIN addresses a ON a.ROWID = m.sender
            LEFT JOIN message_global_data g ON g.ROWID = m.global_message_id
            WHERE \(filter) GROUP BY lower(trim(coalesce(a.address, '')))
            ORDER BY count(*) DESC, max(m.date_received) DESC, lower(trim(coalesce(a.address, ''))) LIMIT \(limit)
            """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            return failedEnvelope(integration: "mail", reason: "mail_index_unavailable")
        }
        defer { sqlite3_finalize(statement) }
        for (index, value) in bindings.enumerated() {
            if let number = value as? Int { sqlite3_bind_int64(statement, Int32(index + 1), Int64(number)) }
            else if let number = value as? Int64 { sqlite3_bind_int64(statement, Int32(index + 1), number) }
        }
        var rows: [JSONValue] = [], step = sqlite3_step(statement)
        while step == SQLITE_ROW {
            func text(_ column: Int32) -> String { sqlite3_column_text(statement, column).map { String(cString: $0) } ?? "" }
            rows.append(.object(["address": .string(text(0)), "display_name": .string(text(1)),
                "message_count": .int(sqlite3_column_int64(statement, 2)), "unread_count": .int(sqlite3_column_int64(statement, 3)),
                "newest_date": sqlite3_column_type(statement, 4) == SQLITE_NULL ? .null
                    : .string(ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: Double(sqlite3_column_int64(statement, 4)))))]))
            step = sqlite3_step(statement)
        }
        guard step == SQLITE_DONE, !Task.isCancelled, ProcessInfo.processInfo.systemUptime < deadline.doubleValue else {
            return failedEnvelope(integration: "mail", reason: "sender_counts_unavailable")
        }
        return .object(["status": .string("completed"), "scope": .string(scope), "count": .int(Int64(rows.count)),
            "unread_only": .bool(input["unread_only"] == .bool(true)), "senders": .array(rows)])
    }

    /// The local file read; without a row, the attachments line the Mail read
    /// after it carries: why the local read failed, in its own words. The
    /// single and batch reads both use it.
    static func mailLocalRead(_ input: [String: JSONValue], batch: Bool = false) -> (row: [String: JSONValue]?, attachments: String) {
        do {
            return (try mailFileRead(input: input, batch: batch), "")
        } catch {
            return (nil, "Attachments unavailable: \(error.localizedDescription)")
        }
    }

    /// ROWID locates the store file; the index and RFC header must both agree
    /// with the paired identity.
    static func mailFileRead(input: [String: JSONValue], batch: Bool = false) throws -> [String: JSONValue] {
        let message = try mailFileMessage(input: input)
        let parts = try mailMessageParts(message.source, attachmentsRoot: message.attachmentsRoot)
        let plain = parts.plain.flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
        guard let body = plain ?? parts.html.map(mailHTMLText) ?? (parts.attachments.isEmpty ? nil : "") else { throw mailMIMEError() }
        let offset = clampedInt(input["body_offset"], defaultValue: 0, min: 0, max: 2_000_000)
        let end = min(body.count, offset + (batch ? 4000 : 16000))
        var row = message.row
        row.merge(["body": .string(offset < end ? String(body.dropFirst(offset).prefix(end - offset)) : ""),
            "body_offset": .int(Int64(offset)), "body_end": .int(Int64(end)), "body_total": .int(Int64(body.count)),
            "truncated": .bool(end < body.count), "attachments": .array(parts.attachments.enumerated().map { index, part in
                .object(["filename": .string(part.filename), "content_type": .string(part.contentType),
                    "size": part.data.map { .int(Int64($0.count)) } ?? .null, "index": .int(Int64(index + 1))])
            })]) { _, new in new }
        let tables = mailHTMLTables(html: parts.html)
        if !tables.isEmpty { row["body_tables"] = .array(tables) }
        return row
    }

    static func mailAttachment(input: [String: JSONValue]) throws -> (filename: String, data: Data) {
        guard mailReadScope(input) != nil, mailExactLocator(input) != nil else {
            throw NSError(domain: "MailFileRead", code: 3, userInfo: [NSLocalizedDescriptionKey: "Use the scope and paired message identity from a Mail read."])
        }
        let message = try mailFileMessage(input: input)
        let parts = try mailMessageParts(message.source, attachmentsRoot: message.attachmentsRoot).attachments
        let matches = parts.enumerated().filter { index, part in
            (input["index"] == nil || input["index"] == .int(Int64(index + 1)))
                && (input["filename"] == nil || input["filename"] == .string(part.filename))
        }
        guard input["index"] != nil || input["filename"] != nil, matches.count == 1 else {
            throw NSError(domain: "MailFileRead", code: 5, userInfo: [NSLocalizedDescriptionKey: "Select one attachment by its 1-based index or unique filename from the Mail read."])
        }
        let part = matches[0].element
        guard let data = part.data else { throw mailFileError(4, "This attachment is not on disk. Download the message in Mail, then save it again.") }
        return (part.filename, data)
    }

    /// Each way it can fail says which: not in the index, a different email
    /// than the locator names, the index or a file unreadable, or no copy on
    /// disk (the only one a download fixes).
    private static func mailFileMessage(input: [String: JSONValue]) throws -> (row: [String: JSONValue], source: Data, attachmentsRoot: URL?) {
        guard let locator = mailExactLocator(input, allowMissingMessageID: true), !locator.messageID.isEmpty else {
            throw mailFileError(6, "The local read needs expected_message_id from a mail_list_recent row.")
        }
        let mismatch = mailFileError(7, "Mismatch: message_id \(locator.id) is a different email than expected_message_id names. Use the identifiers from one fresh mail_list_recent row.")
        let indexError = NSError(domain: "MailFileRead", code: 1,
            userInfo: [NSLocalizedDescriptionKey: "Mail's index is unavailable. Check Mail's index and Full Disk Access."])
        guard let database = mailIndexDatabase() else { throw indexError }
        defer { sqlite3_close(database) }
        var statement: OpaquePointer?
        let sql = """
            SELECT b.url, g.message_id_header, coalesce(m.subject_prefix, '') || coalesce(s.subject, ''),
                   a.comment, a.address, m.date_received, m.read
            FROM messages m JOIN mailboxes b ON b.ROWID = m.mailbox
            LEFT JOIN message_global_data g ON g.ROWID = m.global_message_id
            LEFT JOIN subjects s ON s.ROWID = m.subject LEFT JOIN addresses a ON a.ROWID = m.sender
            WHERE m.ROWID = ? AND m.deleted = 0
            """
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else { throw indexError }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int64(statement, 1, locator.id)
        let step = sqlite3_step(statement)
        if step == SQLITE_DONE {
            throw mailFileError(8, "Mail's index has no message \(locator.id); it was deleted or moved. Call mail_list_recent again and use one fresh row.")
        }
        guard step == SQLITE_ROW else { throw indexError }
        func text(_ column: Int32) -> String { sqlite3_column_text(statement, column).map { String(cString: $0) } ?? "" }
        func identity(_ value: String) -> String { value.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "<>"))) }
        guard identity(text(1)) == identity(locator.messageID) else { throw mismatch }
        guard let mailbox = URL(string: text(0)), let indexPath = sqlite3_db_filename(database, "main") else { throw indexError }
        let root = URL(fileURLWithPath: String(cString: indexPath)).deletingLastPathComponent().deletingLastPathComponent()
        let components = mailbox.path.split(separator: "/").map { String($0) + ".mbox" }
        var boxes = [mailbox.isFileURL ? mailbox : components.reduce(root.appendingPathComponent(mailbox.host ?? "")) { $0.appendingPathComponent($1) }]
        // Mail can put a label's backing store in a differently named directory.
        // Search directory names only, never the messages in a huge mailbox.
        if !FileManager.default.fileExists(atPath: boxes[0].path), let name = components.last {
            var pending = [(root, 0)], visited = 0
            while let (directory, depth) = pending.popLast(), visited < 2048 {
                visited += 1
                for entry in try FileManager.default.contentsOfDirectory(at: directory,
                    includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey], options: [.skipsHiddenFiles]) {
                    let values = try entry.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                    guard values.isDirectory == true, values.isSymbolicLink != true else { continue }
                    if entry.lastPathComponent.caseInsensitiveCompare(name) == .orderedSame { boxes.append(entry) }
                    else if depth < 8, !["Data", "Messages", "MailData"].contains(entry.lastPathComponent) { pending.append((entry, depth + 1)) }
                }
            }
        }
        let shard = String(locator.id / 1000).reversed().map(String.init).joined(separator: "/")
        var otherEmail = false
        for box in boxes where FileManager.default.fileExists(atPath: box.path) {
            let stores = try FileManager.default.contentsOfDirectory(at: box, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])
                .filter { UUID(uuidString: $0.lastPathComponent) != nil }
            for store in stores {
                let directory = store.appendingPathComponent("Data/\(shard)/Messages")
                for suffix in ["emlx", "partial.emlx"] {
                    let file = directory.appendingPathComponent("\(locator.id).\(suffix)")
                    guard FileManager.default.fileExists(atPath: file.path) else { continue }
                    let data = try Data(contentsOf: file)
                    guard let newline = data.firstIndex(of: 10),
                          let count = Int(String(decoding: data[..<newline], as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)),
                          count >= 0, count <= data.count - newline - 1 else { throw mailMIMEError() }
                    let source = data.subdata(in: (newline + 1)..<(newline + 1 + count))
                    let headers = mailMIMEHeaders(String(decoding: source, as: UTF8.self))
                    guard identity(headers["message-id"] ?? "") == identity(locator.messageID) else { otherEmail = true; continue }
                    let iso = ISO8601DateFormatter()
                    iso.timeZone = .current  // local time, as people read it (10-09)
                    var row: [String: JSONValue] = ["message_id": .int(locator.id), "expected_message_id": .string(locator.messageID),
                        "subject": .string(text(2)), "sender": .string(mailSenderText(comment: text(3), address: text(4))),
                        "date": .string(sqlite3_column_type(statement, 5) == SQLITE_NULL ? ""
                            : iso.string(from: Date(timeIntervalSince1970: TimeInterval(sqlite3_column_int64(statement, 5))))),
                        "unread": .bool(sqlite3_column_int(statement, 6) == 0), "scope": .string(mailReadScope(input) ?? "inbox")]
                    if let account = locator.account { row["expected_account"] = .string(account) }
                    if let position = locator.position { row["position"] = .int(Int64(position)) }
                    // Mail's index has no account names and the locator names no
                    // mailbox, so both are the ones passed in, not checked.
                    row["verification"] = .string(locator.account == nil
                        ? "Mailbox not verified by the local read: scope is the one passed in."
                        : "Account and mailbox not verified by the local read: expected_account and scope are the ones passed in.")
                    return (row, source, suffix == "partial.emlx"
                        ? directory.deletingLastPathComponent().appendingPathComponent("Attachments/\(locator.id)") : nil)
                }
            }
        }
        if otherEmail { throw mismatch }
        throw mailFileError(9, "No local copy of this message is on disk. Download the message in Mail to list or save attachments.")
    }

    /// One inbox page read from Mail's own index (Envelope Index, read-only,
    /// under the app's Full Disk Access): rows from each account's
    /// inbox, newest first, positions as Mail numbers them, `limit` rows by
    /// date. `header` is the script's account inboxes; counts are the index's
    /// own. A query matches subject and sender over the whole mailbox. An
    /// account whose inbox the index lacks is named in `accounts_not_listed`;
    /// the others still list.
    static func mailIndexPage(header: String, input: [String: JSONValue], query: [String]?) -> JSONValue {
        guard let scope = mailReadScope(input) else { return failedEnvelope(integration: "mail", reason: "unsupported_mailbox") }
        let limit = clampedInt(input["limit"], defaultValue: 10, min: 1, max: 50)
        guard input["unread"] == nil || input["unread"] == .bool(true) || input["unread"] == .bool(false),
              input["sort"] == nil || input["sort"] == .string("oldest") || input["sort"] == .string("newest") else {
            return failedEnvelope(integration: "mail", reason: "invalid_mail_filter")
        }
        let oldest = input["sort"] == .string("oldest")
        let listOffset = clampedInt(input["offset"], defaultValue: 0, min: 0, max: 10000)
        var offsets: [String: JSONValue] = [:]
        if case .object(let cursor)? = input["offset"] {
            guard cursor.values.allSatisfy({ if case .int(let value) = $0 { value >= 0 && value < Int.max - 50 } else { false } }) else {
                return failedEnvelope(integration: "mail", reason: "invalid_mail_offset")
            }
            offsets = cursor
        }
        let accounts = mailIndexAccounts(header)
        guard !accounts.isEmpty, let database = mailIndexDatabase() else {
            return failedEnvelope(integration: "mail", reason: "mail_index_unavailable")
        }
        defer { sqlite3_close(database) }
        /// Runs `sql` with integer/text bindings, one closure call per row; false when it cannot run.
        func each(_ sql: String, _ bindings: [Any], _ row: (OpaquePointer) -> Void) -> Bool {
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else { return false }
            defer { sqlite3_finalize(statement) }
            for (index, value) in bindings.enumerated() {
                if let number = value as? Int { sqlite3_bind_int64(statement, Int32(index + 1), Int64(number)) }
                if let text = value as? String { sqlite3_bind_text(statement, Int32(index + 1), text, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self)) }
            }
            var step = sqlite3_step(statement)
            while step == SQLITE_ROW { row(statement); step = sqlite3_step(statement) }
            return step == SQLITE_DONE
        }
        func text(_ statement: OpaquePointer, _ column: Int32) -> String {
            sqlite3_column_text(statement, column).map { String(cString: $0) } ?? ""
        }
        // A Gmail inbox is a label over All Mail; other inboxes hold their messages.
        let inboxMessages = "m.deleted = 0 AND (m.mailbox = ?1 OR m.ROWID IN (SELECT message_id FROM labels WHERE mailbox_id = ?1))"
        let joins = """
            LEFT JOIN subjects s ON s.ROWID = m.subject LEFT JOIN addresses a ON a.ROWID = m.sender
            LEFT JOIN message_global_data g ON g.ROWID = m.global_message_id
            """
        // Each row's place in the mailbox as Mail numbers it (newest first), so
        // a filtered row still carries its true position.
        let positions = "(SELECT m.ROWID AS id, row_number() OVER (ORDER BY m.date_received DESC, m.ROWID DESC) AS position FROM messages m WHERE \(inboxMessages)) p"
        // Mail's own categories (model_category; 2026-10-07 by sender: 0
        // Primary, 1 Transactions, 2 Updates, 3 Promotions). An inbox list
        // shows Primary and Transactions unless all_categories; a search covers all.
        let categories = ["primary", "transactions", "updates", "promotions"]
        let primaryOnly = scope == "inbox" && query == nil && ["unread", "sort", "from", "since", "category", "attachment"].allSatisfy { input[$0] == nil } && input["all_categories"] != .bool(true)
        var filter = "1"
        if primaryOnly { filter += " AND coalesce(g.model_category, 0) IN (0, 1)" }
        if case .bool(let unread)? = input["unread"] { filter += " AND m.read = \(unread ? 0 : 1)" }
        // The subject as shown (its "Re: " prefix too), case and accents aside.
        let patterns = (query ?? []).map(FoldedText.fold)
        var bindings: [Any] = patterns
        func bind(_ value: Any) -> String { bindings.append(value); return "?\(bindings.count + 3)" }
        if !patterns.isEmpty {
            filter += " AND (" + patterns.indices.map { index in
                let parameter = "?\(index + 4)"
                return "(folded_contains(coalesce(m.subject_prefix, '') || coalesce(s.subject, ''), \(parameter)) OR folded_contains(a.address, \(parameter)) OR folded_contains(a.comment, \(parameter)))"
            }.joined(separator: " OR ") + ")"
        }
        let iso = ISO8601DateFormatter()
        iso.timeZone = .current  // local time, as people read it (10-09)
        iso.formatOptions = [.withInternetDateTime]
        if let from = input["from"] {
            guard case .string(let sender) = from, !sender.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return failedEnvelope(integration: "mail", reason: "invalid_mail_sender")
            }
            let parameter = bind(FoldedText.fold(sender))
            filter += " AND (folded_contains(a.address, \(parameter)) OR folded_contains(a.comment, \(parameter)))"
        }
        let dated = mailIndexFilters(input, bind: bind)
        if let error = dated.error { return error }
        filter += dated.sql
        if let attachment = input["attachment"] {
            var nameFilter = ""
            if case .string(let name) = attachment, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                nameFilter = " AND folded_contains(x.name, \(bind(FoldedText.fold(name))))"
            } else if attachment != .bool(true) {
                return failedEnvelope(integration: "mail", reason: "invalid_mail_attachment")
            }
            filter += " AND EXISTS (SELECT 1 FROM attachments x WHERE x.message = m.ROWID\(nameFilter))"
        }
        // Every account type's mailbox URL is `scheme://<account id>/<mailbox path>`
        // (imap, ews, pop, local), so an inbox is its account id and Mail's own name for it.
        var mailboxes: [(id: Int, account: String, path: String)] = []
        guard each("SELECT ROWID, url FROM mailboxes", [], { statement in
            if let url = URL(string: text(statement, 1)), let host = url.host {
                mailboxes.append((Int(sqlite3_column_int64(statement, 0)), host, String(url.path.dropFirst())))
            }
        }) else { return failedEnvelope(integration: "mail", reason: "mail_index_unavailable") }
        var boxes: [(account: String, total: Int, unread: Int, count: Int, offset: Int, consumed: Int, rows: [JSONValue])] = [], notListed: [JSONValue] = []
        var unreadByCategory = Dictionary(uniqueKeysWithValues: (categories + ["unclassified"]).map { ($0, 0) })
        for account in accounts.sorted(by: { $0.id < $1.id }) {
            var total = 0, unread = 0, count = 0, rows: [JSONValue] = []
            let offset: Int
            if case .int(let value)? = offsets[account.id] { offset = Int(value) }
            else { offset = listOffset }
            let unnamed = account.id.isEmpty || account.inbox.isEmpty
            let mailbox = unnamed ? nil : mailboxes.first {
                $0.account.caseInsensitiveCompare(account.id) == .orderedSame && $0.path.caseInsensitiveCompare(account.inbox) == .orderedSame
            }?.id
            guard let mailbox else {
                notListed.append(.object(unnamed
                    ? ["account": .string(account.name), "reason": .string("account_details_unreadable"),
                       "message": .string("Mail did not give this mailbox's account id or name, so its mail is not in this list.")]
                    : ["account": .string(account.name), "reason": .string("mailbox_not_in_mail_index"),
                       "message": .string("This account's requested mailbox was not found in Mail's index, so its mail is not in this list.")]))
                continue
            }
            guard each("SELECT coalesce(g.model_category, 0), count(*), coalesce(sum(m.read = 0), 0) FROM messages m LEFT JOIN message_global_data g ON g.ROWID = m.global_message_id WHERE \(inboxMessages) GROUP BY coalesce(g.model_category, 0)", [mailbox], {
                      let category = Int(sqlite3_column_int64($0, 0)), categoryUnread = Int(sqlite3_column_int64($0, 2))
                      total += Int(sqlite3_column_int64($0, 1)); unread += categoryUnread
                      unreadByCategory[categories.indices.contains(category) ? categories[category] : "unclassified", default: 0] += categoryUnread
                  }),
                  filter == "1" || each("SELECT count(*) FROM messages m \(joins) WHERE \(inboxMessages) AND \(filter)", [mailbox, 0, 0] + bindings, { count = Int(sqlite3_column_int64($0, 0)) }),
                  each("""
                    SELECT m.ROWID, g.message_id_header, m.subject_prefix, s.subject, a.comment, a.address, m.date_received, m.read, g.model_category, p.position
                    FROM \(positions) JOIN messages m ON m.ROWID = p.id \(joins)
                    WHERE \(filter) ORDER BY p.position \(oldest ? "DESC" : "ASC") LIMIT ?2 OFFSET ?3
                    """, [mailbox, limit, offset] + bindings, { statement in
                        var messageID = text(statement, 1)
                        if messageID.hasPrefix("<"), messageID.hasSuffix(">") { messageID = String(messageID.dropFirst().dropLast()) }
                        let received = sqlite3_column_type(statement, 6) == SQLITE_NULL ? ""
                            : iso.string(from: Date(timeIntervalSince1970: TimeInterval(sqlite3_column_int64(statement, 6))))
                        var row: [String: JSONValue] = ["message_id": .int(sqlite3_column_int64(statement, 0)), "expected_message_id": .string(messageID),
                            "subject": .string(text(statement, 2) + text(statement, 3)), "sender": .string(mailSenderText(comment: text(statement, 4), address: text(statement, 5))),
                            "date": .string(received), "unread": .bool(sqlite3_column_int(statement, 7) == 0),
                            "position": .int(sqlite3_column_int64(statement, 9)), "body_status": .string("not_loaded"), "scope": .string(scope)]
                        if !account.name.isEmpty { row["expected_account"] = .string(account.name) }
                        let category = sqlite3_column_type(statement, 8) == SQLITE_NULL ? 0 : Int(sqlite3_column_int64(statement, 8))
                        if categories.indices.contains(category) { row["category"] = .string(categories[category]) }
                        rows.append(.object(row))
                    }) else { return failedEnvelope(integration: "mail", reason: "mail_index_unavailable") }
            if filter == "1" { count = total }
            boxes.append((account.id, total, unread, count, offset, 0, rows))
        }
        // Merge account heads; fetched rows outside this page remain unconsumed.
        func received(_ row: JSONValue) -> String { if case .object(let o) = row, case .string(let d)? = o["date"] { d } else { "" } }
        var rows: [JSONValue] = []
        while rows.count < limit {
            var next: Int?
            for index in boxes.indices where boxes[index].consumed < boxes[index].rows.count {
                if let current = next {
                    let candidate = received(boxes[index].rows[boxes[index].consumed])
                    let selected = received(boxes[current].rows[boxes[current].consumed])
                    if oldest ? candidate < selected : candidate > selected { next = index }
                } else { next = index }
            }
            guard let next else { break }
            rows.append(boxes[next].rows[boxes[next].consumed])
            boxes[next].consumed += 1
        }
        if input["attachment"] != nil {
            for index in rows.indices {
                guard case .object(var row) = rows[index], case .int(let id)? = row["message_id"] else {
                    return failedEnvelope(integration: "mail", reason: "mail_index_unavailable")
                }
                var names: [JSONValue] = []
                guard each("SELECT name FROM attachments WHERE message = ?1 ORDER BY attachment_id, name LIMIT 5", [Int(id)], {
                    names.append(.string(text($0, 0)))
                }) else { return failedEnvelope(integration: "mail", reason: "mail_index_unavailable") }
                row["attachment_names"] = .array(names)
                rows[index] = .object(row)
            }
        }
        var result: [String: JSONValue] = ["status": .string("completed"), "count": .int(Int64(rows.count)),
            "messages": .array(rows), "scope": .string(scope), "detail": .bool(false),
            "sort": .string(oldest ? "oldest" : "newest"),
            "content_note": .string("Mailbox metadata only; open a message to load its body. Pages read the current mailbox, which may change between reads."),
            "mailbox_total": .int(Int64(boxes.reduce(0) { $0 + $1.total }))]
        let hasMore = boxes.contains(where: { $0.count > $0.offset + $0.consumed })
        result["has_more"] = .bool(hasMore)
        if filter != "1" { result["matching_total"] = .int(Int64(boxes.reduce(0) { $0 + $1.count })) }
        if query != nil {
            result["note"] = .string("Matched the supplied filters across the whole \(scope) mailbox; query searches sender and subject, from searches sender only. Bodies were not searched.")
        } else if primaryOnly {
            result["note"] = .string("Primary and Transactions only (Mail's categories); all_categories: true lists Updates and Promotions too.")
        }
        if hasMore {
            for box in boxes { offsets[box.account] = .int(Int64(box.offset + box.consumed)) }
            result["next_offset"] = .object(offsets)
        }
        if scope == "inbox" {
            result["inbox_total"] = result["mailbox_total"]
            result["inbox_unread"] = .int(Int64(boxes.reduce(0) { $0 + $1.unread }))
            result["inbox_unread_by_category"] = .object(unreadByCategory.mapValues { .int(Int64($0)) })
            result["category_note"] = .string("Exact unread counts across all inbox categories, independent of this page's filters. Mail's Primary category is not a guarantee that the sender is a person; unclassified covers unknown category codes.")
        }
        if !notListed.isEmpty {
            // The totals would count different accounts, so a partial page carries none.
            result["mailbox_total"] = nil; result["inbox_total"] = nil; result["inbox_unread"] = nil
            result["inbox_unread_by_category"] = nil; result["category_note"] = nil
            result["accounts_not_listed"] = .array(notListed)
            let names = notListed.compactMap { if case .object(let o) = $0, case .string(let n)? = o["account"] { n.isEmpty ? "an account" : n } else { nil } }
            result["message"] = .string("Not listed: \(names.joined(separator: ", ")); see accounts_not_listed.\(boxes.isEmpty ? "" : " The other accounts are listed.")")
        }
        return .object(result)
    }

    /// The sender as Mail shows it: `Name <address>`, the name quoted when it
    /// holds a mail special (a bare address as the name stays bare).
    static func mailSenderText(comment: String, address: String) -> String {
        guard !comment.isEmpty else { return address }
        let bareAddress = comment.contains("@") && !comment.contains(where: \.isWhitespace)
        let name = bareAddress || comment.rangeOfCharacter(from: CharacterSet(charactersIn: "()<>[]:;@\\,.\"")) == nil ? comment
            : "\"" + comment.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
        return address.isEmpty ? name : "\(name) <\(address)>"
    }

    typealias MailLocator = MailReadLocator

    static func mailExactLocator(_ input: [String: JSONValue], allowMissingMessageID: Bool = false) -> MailLocator? {
        MailReadLocator.parse(input, allowMissingMessageID: allowMissingMessageID)
    }

    static func mailLookupCommand(_ command: String, deadline: String? = nil) -> String {
        guard let deadline else { return command }
        return """
        set lookupSecondsRemaining to \(deadline) - (current date)
        if lookupSecondsRemaining < 1 then error number -1712
        with timeout of lookupSecondsRemaining seconds
            \(command)
        end timeout
        """
    }

    /// The one message `list` holds is the one that was read: exactly one
    /// match, its RFC id when available, and its account when supplied, so the
    /// same email in a second account's inbox is never the one acted on.
    /// Sets `list` to the message with the locator's id in `targetBox`. The
    /// listing's position is tried first, then a few places later (new mail
    /// pushes it down) and earlier, before the full `whose id is` scan, which
    /// times out in a ~140k-message account inbox (2026-09-24). The identity
    /// check after it still decides.
    static func mailExactLookup(_ locator: MailLocator, into list: String, deadline: String? = nil) -> String {
        let scan = mailLookupCommand("set \(list) to (messages of targetBox whose id is \(locator.id))", deadline: deadline)
        guard let position = locator.position else { return scan }
        return """
        set \(list) to {}
        repeat with shiftBy in {0, 1, 2, 3, 4, 5, 6, 8, 10, 12, 16, 20, -1, -2, -3}
            set probeIndex to \(position) + (shiftBy as integer)
            if probeIndex ≥ 1 then
                try
                    \(mailLookupCommand("set candidateMsg to message probeIndex of targetBox", deadline: deadline))
                    \(mailLookupCommand("set candidateID to id of candidateMsg", deadline: deadline))
                    if candidateID is \(locator.id) then
                        set \(list) to {candidateMsg}
                        exit repeat
                    end if
                on error errText number errNum
                    if errNum is -1712 then error errText number errNum
                end try
            end if
        end repeat
        if (count of \(list)) is 0 then
            \(scan)
        end if
        """
    }

    static func mailIdentityCheck(_ locator: MailLocator, list: String, fail: String, deadline: String? = nil) -> String {
        var lines = [
            "if (count of \(list)) is not 1 then return \"\(fail)\"",
            "if (id of item 1 of \(list)) is not \(locator.id) then return \"\(fail)\"",
        ]
        if !locator.messageID.isEmpty {
            lines.append("if ((message id of item 1 of \(list)) as text) is not \"\(escapeForAppleScript(locator.messageID))\" then return \"\(fail)\"")
        }
        if let account = locator.account {
            lines.append("if ((name of account of mailbox of item 1 of \(list)) as text) is not \"\(escapeForAppleScript(account))\" then return \"\(fail)\"")
        }
        return lines.map { mailLookupCommand($0, deadline: deadline) }.joined(separator: "\n")
    }

    /// AppleScript that sets `targetBox` (not `scope`: Mail owns that word, -10006) to the inbox of the named account (each
    /// account's own inbox is a mailbox of the combined one), or the combined
    /// inbox when none is named or found. An id looked up there is scanned in
    /// one account's inbox, not all of them (2026-09-24: a 141k-message
    /// combined inbox timed out on `whose id is`).
    static func mailAccountScope(_ account: String?, scope: String = "inbox", deadline: String? = nil) -> String {
        let box = scope == "sent" ? "sent mailbox" : "inbox"
        let target = mailLookupCommand("set targetBox to \(box)", deadline: deadline)
        guard let account else { return target }
        return """
        \(target)
        try
            \(mailLookupCommand("set accountMailboxes to mailboxes of \(box)", deadline: deadline))
            repeat with mb in accountMailboxes
                \(mailLookupCommand("set mailboxAccountName to (name of account of mb) as text", deadline: deadline))
                if mailboxAccountName is "\(escapeForAppleScript(account))" then
                    set targetBox to mb
                    exit repeat
                end if
            end repeat
        on error errText number errNum
            if errNum is -1712 then error errText number errNum
        end try
        """
    }

    static func mailWorkspaceScript(input: [String: JSONValue], batch: Bool = false) -> String {
        let scope = mailReadScope(input) ?? "inbox"
        let box = scope == "sent" ? "sent mailbox" : "inbox"
        let locator = mailExactLocator(input, allowMissingMessageID: true)
        let contentLimit = batch ? 4000 : 16000
        let offset = locator == nil ? 0 : clampedInt(input["body_offset"], defaultValue: 0, min: 0, max: 2_000_000)
        /// One row: `msg` and `accountName` are set by the caller.
        let row = """
                set subjectText to (subject of msg) as text
                set senderText to (sender of msg) as text
                set bodyText to (content of msg) as text
                set totalCharacters to count of bodyText
                set startOffset to \(offset)
                set endOffset to startOffset + \(contentLimit)
                if endOffset > totalCharacters then set endOffset to totalCharacters
                set wasTruncated to "false"
                if endOffset < totalCharacters then set wasTruncated to "true"
                if startOffset ≥ totalCharacters then
                    set bodyText to ""
                else
                    set bodyText to text (startOffset + 1) thru endOffset of bodyText
                end if
                set messageIDText to message id of msg
                if messageIDText is missing value then set messageIDText to ""
                set output to output & ((id of msg) as text) & "|" & (my encoded(messageIDText)) & "|" & (my encoded(subjectText)) & "|" & (my encoded(senderText)) & "|" & (my encoded((date received of msg) as text)) & "|" & (my encoded(bodyText)) & "|" & wasTruncated & "|" & (startOffset as text) & "|" & (endOffset as text) & "|" & (totalCharacters as text) & "|" & ((read status of msg) as text) & "|" & (my encoded(accountName)) & "|" & (rowPosition as text)
                \(Self.mailSourceScript)
                set completedRows to completedRows + 1
        """
        let body: String
        if let locator {
            body = """
            \(batch ? locator.account.map { mailBatchAccountScope($0, scope: scope) } ?? "return \"__MESSAGE_CHANGED__\"" : mailAccountScope(locator.account, scope: scope))
            \(mailExactLookup(locator, into: "msgList"))
            \(mailIdentityCheck(locator, list: "msgList", fail: "__MESSAGE_CHANGED__"))
            set msg to item 1 of msgList
            set rowPosition to 0
            set accountName to ""
            try
                set accountName to (name of account of mailbox of msg) as text
            end try
            \(row)
            """
        } else {
            // 2026-09-26: only the account inboxes come from Mail; the rows and
            // counts come from its index (mailIndexPage), since each `message i`
            // of a 141k-message inbox costs Mail ~1.5s.
            body = """
            set boxes to {}
            try
                set boxes to (mailboxes of \(box)) as list
            end try
            repeat with mb in boxes
                set boxName to ""
                set boxAccount to ""
                set boxInbox to ""
                try
                    set boxInbox to (name of mb) as text
                    set boxName to (name of account of mb) as text
                    set boxAccount to (id of account of mb) as text
                end try
                set output to output & "__BOX__|" & (my encoded(boxName)) & "|" & (my encoded(boxAccount)) & "|" & (my encoded(boxInbox)) & linefeed
            end repeat
            """
        }
        return """
        property readDeadline : missing value
        on checkReadDeadline()
            if (current date) > readDeadline then error "Conversation read exceeded its bounded time budget" number -1712
        end checkReadDeadline
        on replaced(sourceText, needle, replacementText)
            set oldDelimiters to AppleScript's text item delimiters
            set AppleScript's text item delimiters to needle
            set pieces to text items of sourceText
            set AppleScript's text item delimiters to replacementText
            set resultText to pieces as text
            set AppleScript's text item delimiters to oldDelimiters
            return resultText
        end replaced
        on encoded(value)
            my checkReadDeadline()
            set resultText to my replaced(value as text, "%", "%25")
            set resultText to my replaced(resultText, "|", "%7C")
            set resultText to my replaced(resultText, ":", "%3A")
            set resultText to my replaced(resultText, ",", "%2C")
            set resultText to my replaced(resultText, linefeed, "%0A")
            return my replaced(resultText, return, "%0D")
        end encoded
        set readDeadline to (current date) + 9
        with timeout of 4 seconds
        tell application "Mail"
            set enabledAccounts to (accounts whose enabled is true)
            if (count of enabledAccounts) is 0 then return "__NATIVEAGENT_MAIL_NOT_CONFIGURED__"
            my checkReadDeadline()
            set output to ""
            set completedRows to 0
            \(body)
            return output
        end tell
        end timeout
        """
    }

    /// Inverse of the script's fixed escaping alphabet. Reject malformed escapes;
    /// decode once so literal percent sequences never become structural delimiters.
    static func decodeConversationTransport(_ value: String) -> String? {
        let allowed: Set<String> = ["25", "7C", "3A", "2C", "0A", "0D"]
        var cursor = value.startIndex
        while cursor < value.endIndex {
            if value[cursor] == "%" {
                guard let end = value.index(cursor, offsetBy: 3, limitedBy: value.endIndex) else { return nil }
                let start = value.index(after: cursor)
                guard allowed.contains(String(value[start..<end])) else { return nil }
                cursor = end
            } else { cursor = value.index(after: cursor) }
        }
        return value.removingPercentEncoding
    }

    static func parseMailWorkspaceRecords(_ raw: String, detail: Bool) -> [JSONValue] {
        raw.split(separator: "\n").compactMap { line in
            let fields = line.split(separator: "|", omittingEmptySubsequences: false)
            // An 11th field is the read status, a 12th the account (2026-09-24); older scripts send 10.
            // A 14th is an opened message's raw source, read for its tables.
            guard (10...14).contains(fields.count), let id = Int64(fields[0]), id > 0 else { return nil }
            let decoded = fields[1...5].compactMap { decodeConversationTransport(String($0)) }
            guard decoded.count == 5, fields[6] == "true" || fields[6] == "false",
                  let offset = Int64(fields[7]), let end = Int64(fields[8]), let total = Int64(fields[9]),
                  offset >= 0, end >= 0, total >= 0, end <= total else { return nil }
            var row: [String: JSONValue] = ["message_id": .int(id), "expected_message_id": .string(decoded[0]), "subject": .string(decoded[1]),
                "sender": .string(decoded[2]), "date": .string(normalizeAppleScriptDate(decoded[3]))]
            if fields.count >= 11, ["true", "false"].contains(fields[10]) { row["unread"] = .bool(fields[10] == "false") }
            // 13th: its place in its account's inbox, the fast way back to it.
            if fields.count >= 13, let position = Int64(fields[12]), position > 0 { row["position"] = .int(position) }
            if fields.count >= 12, let account = decodeConversationTransport(String(fields[11])), !account.isEmpty {
                row["expected_account"] = .string(account)
            }
            if detail {
                row["body"] = .string(decoded[4]); row["truncated"] = .bool(fields[6] == "true")
                row["body_offset"] = .int(offset); row["body_end"] = .int(end); row["body_total"] = .int(total)
                if fields.count == 14, let source = decodeConversationTransport(String(fields[13])) {
                    let tables = mailHTMLTables(source: source)
                    if !tables.isEmpty { row["body_tables"] = .array(tables) }
                }
            } else { row["body_status"] = .string("not_loaded") }
            return .object(row)
        }
    }
}

/// Simple HTML tables in an opened message (desk walk 4, 09-25): Mail's plain
/// `content` lists every cell on its own line, so a row of labels over a row
/// of values reads as all the labels, then all the values. The owner returns
/// the tables as `body_tables` beside the unchanged body; the mail room lays
/// them out row by row where the body lines are exactly those cells.
extension MacAppleScriptBridge {
    /// Ends an opened message's row with its raw source, after the base row
    /// is already in `output`: "" when it is large (Mail's `message size` says
    /// so before anything is fetched; an unknown size counts as large), slow,
    /// or the read is near its time budget. Every step is in a `try`, so the
    /// source can never delay the row past its budget or fail it.
    static let mailSourceScript = """
    set sourceText to ""
    set sourceBytes to 300001
    try
        set sourceBytes to (message size of msg) as integer
    end try
    if sourceBytes ≤ 300000 and (current date) < ((my readDeadline) - 3) then
        try
            with timeout of 2 seconds
                set sourceText to (source of msg) as text
            end timeout
            if (count of sourceText) > 300000 then set sourceText to ""
        end try
    end if
    set sourceField to ""
    try
        set sourceField to my encoded(sourceText)
    end try
    set output to output & "|" & sourceField & linefeed
    """

    /// Innermost tables of the message's HTML part, each `{header, rows}`:
    /// rows of plain cell text, all the same width (2–10), at most 30 rows
    /// and 200 cells in all. A cell broken over lines leaves its table out.
    static func mailHTMLTables(source: String) -> [JSONValue] {
        mailHTMLTables(html: (try? mailMIMEParts(Data(source.utf8)))?.html)
    }

    private static func mailHTMLTables(html: String?) -> [JSONValue] {
        guard let html else { return [] }
        func matches(_ pattern: String, _ text: String) -> [[String]] {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return [] }
            let ns = text as NSString
            return regex.matches(in: text, range: NSRange(location: 0, length: ns.length)).map { match in
                (0..<match.numberOfRanges).map { match.range(at: $0).location == NSNotFound ? "" : ns.substring(with: match.range(at: $0)) }
            }
        }
        var tables: [JSONValue] = [], cells = 0
        for table in matches(#"<table\b[^>]*>((?:(?!<table\b)[\s\S])*?)</table>"#, html) {
            var rows: [[String]] = [], heads: [Bool] = [], simple = true
            for tr in matches(#"<tr\b[^>]*>([\s\S]*?)</tr>"#, table[1]) {
                let found = matches(#"<t(h|d)\b[^>]*>([\s\S]*?)</t[hd]\s*>"#, tr[1])
                let texts = found.map { mailCellText($0[2]) }
                if texts.contains(where: { $0 == nil }) { simple = false; break }
                let row = texts.compactMap { $0 }
                if row.allSatisfy(\.isEmpty) { continue }
                rows.append(row); heads.append(found.allSatisfy { $0[1].lowercased() == "h" })
            }
            guard simple, rows.count >= 2, rows.count <= 30, let width = rows.first?.count, (2...10).contains(width),
                  rows.allSatisfy({ $0.count == width }), cells + rows.count * width <= 200 else { continue }
            cells += rows.count * width
            tables.append(.object(["header": .bool(heads[0]), "rows": .array(rows.map { .array($0.map(JSONValue.string)) })]))
        }
        return tables
    }

    /// A cell's text on one line, or nil when it breaks over lines or runs long.
    private static func mailCellText(_ inner: String) -> String? {
        // One block (a <p> or <div> around the text) is still one line; a break or a second block is not.
        if inner.range(of: #"<(br|li|tr|h[1-6])\b"#, options: [.regularExpression, .caseInsensitive]) != nil
            || inner.components(separatedBy: "<").filter({ $0.range(of: #"^(p|div)\b"#, options: [.regularExpression, .caseInsensitive]) != nil }).count > 1 {
            return nil
        }
        let line = mailHTMLText(inner).split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return line.count > 120 ? nil : line
    }

    private static func mailHTMLText(_ html: String) -> String {
        var text = html.replacingOccurrences(of: #"(?is)<(script|style)\b[^>]*>.*?</\1\s*>"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"(?i)<br\b[^>]*>|</(?:p|div|tr|li|h[1-6])\s*>"#, with: "\n", options: .regularExpression)
            .replacingOccurrences(of: #"<[^>]*>"#, with: " ", options: .regularExpression)
        for (entity, value) in [("&nbsp;", " "), ("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&#39;", "'"), ("&apos;", "'"), ("&amp;", "&")] {
            text = text.replacingOccurrences(of: entity, with: value, options: .caseInsensitive)
        }
        while let range = text.range(of: #"&#(x?)([0-9a-fA-F]{1,6});"#, options: .regularExpression) {
            let code = text[range].dropFirst(2).dropLast()
            let scalar = code.hasPrefix("x") || code.hasPrefix("X") ? UInt32(code.dropFirst(), radix: 16) : UInt32(code)
            text.replaceSubrange(range, with: scalar.flatMap(Unicode.Scalar.init).map { String(Character($0)) } ?? " ")
        }
        // Marketing preheaders pad with invisible characters; they are not text.
        text.unicodeScalars.removeAll { [0x00AD, 0x034F, 0x200B, 0x200C, 0x200D, 0x200E, 0x200F, 0x2060, 0xFEFF].contains($0.value) }
        return text.components(separatedBy: "\n").map { $0.split(whereSeparator: \.isWhitespace).joined(separator: " ") }
            .joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func mailMIMEError() -> NSError {
        mailFileError(2, "The saved message could not be parsed: its local copy has incomplete or unsupported MIME content.")
    }

    private static func mailFileError(_ code: Int, _ text: String) -> NSError {
        NSError(domain: "MailFileRead", code: code, userInfo: [NSLocalizedDescriptionKey: text])
    }

    private static func mailMIMEHeaders(_ source: String) -> [String: String] {
        let raw = source.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        let header = String(raw.components(separatedBy: "\n\n")[0])
            .replacingOccurrences(of: #"\n[ \t]+"#, with: " ", options: .regularExpression)
        var fields: [String: String] = [:]
        for line in header.split(separator: "\n") {
            guard let colon = line.firstIndex(of: ":") else { continue }
            fields[String(line[..<colon]).lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        return fields
    }

    /// Latin-1 preserves every source byte while separating MIME boundaries;
    /// charset conversion happens only after transfer decoding each text part.
    private typealias MailMIMEAttachment = (filename: String, contentType: String, data: Data?, part: String)

    private static func mailMessageParts(_ source: Data, attachmentsRoot: URL?) throws
        -> (plain: String?, html: String?, attachments: [MailMIMEAttachment]) {
        var result = try mailMIMEParts(source, attachmentsRoot: attachmentsRoot)
        if let root = attachmentsRoot, FileManager.default.fileExists(atPath: root.path) {
            for part in try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]).sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                guard try part.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true else { continue }
                for file in try FileManager.default.contentsOfDirectory(at: part, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]).sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                    guard !result.attachments.contains(where: { $0.part == part.lastPathComponent && $0.filename == file.lastPathComponent }) else { continue }
                    guard file.resolvingSymlinksInPath().path.hasPrefix(root.resolvingSymlinksInPath().path + "/"),
                          try file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else { throw mailMIMEError() }
                    result.attachments.append((file.lastPathComponent,
                        UTType(filenameExtension: file.pathExtension)?.preferredMIMEType ?? "application/octet-stream",
                        try Data(contentsOf: file), part.lastPathComponent))
                }
            }
        }
        return result
    }

    private static func mailMIMEParts(_ source: Data, depth: Int = 0, partNumber: String = "",
        attachmentsRoot: URL? = nil) throws -> (plain: String?, html: String?, attachments: [MailMIMEAttachment]) {
        guard depth < 20, let raw = String(data: source, encoding: .isoLatin1),
              let end = raw.range(of: "\r\n\r\n") ?? raw.range(of: "\n\n") else { throw mailMIMEError() }
        let headers = mailMIMEHeaders(String(raw[..<end.lowerBound]))
        let type = headers["content-type"] ?? "text/plain"
        let kind = type.components(separatedBy: ";")[0].trimmingCharacters(in: .whitespaces).lowercased()
        let body = String(raw[end.upperBound...])
        func parameter(_ name: String, in field: String? = nil) -> String? {
            let field = field ?? type
            guard let regex = try? NSRegularExpression(pattern: "(?:^|;)\\s*" + name + #"(\*)?\s*=\s*(?:"([^"]*)"|([^;\s]+))"#, options: .caseInsensitive),
                  let match = regex.firstMatch(in: field, range: NSRange(field.startIndex..., in: field)),
                  let value = [2, 3].compactMap({ Range(match.range(at: $0), in: field).map { String(field[$0]) } }).first else { return nil }
            if match.range(at: 1).location != NSNotFound {
                let pieces = value.split(separator: "'", maxSplits: 2, omittingEmptySubsequences: false)
                return pieces.count == 3 ? String(pieces[2]).removingPercentEncoding : nil
            }
            return value
        }
        let filename = parameter("filename", in: headers["content-disposition"] ?? "") ?? parameter("name")
        if let filename, !filename.isEmpty {
            let file = attachmentsRoot?.appendingPathComponent(partNumber.isEmpty ? "1" : partNumber).appendingPathComponent(filename)
            let data: Data?
            if let file, FileManager.default.fileExists(atPath: file.path) {
                guard file.resolvingSymlinksInPath().path.hasPrefix(attachmentsRoot!.resolvingSymlinksInPath().path + "/"),
                      try file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else { throw mailMIMEError() }
                data = try Data(contentsOf: file)
            } else if attachmentsRoot != nil && body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                data = nil
            } else { data = try mailMIMEDecode(body, encoding: headers["content-transfer-encoding"]) }
            return (nil, nil, [(filename, kind, data, partNumber.isEmpty ? "1" : partNumber)])
        }
        if headers["content-disposition"]?.lowercased().hasPrefix("attachment") == true { return (nil, nil, []) }
        if kind.hasPrefix("multipart/") {
            guard let boundary = parameter("boundary"), !boundary.isEmpty else { throw mailMIMEError() }
            var result: (plain: String?, html: String?, attachments: [MailMIMEAttachment]) = (nil, nil, [])
            var lines: [String] = [], started = false, closed = false, number = 0
            for line in body.components(separatedBy: "\n") {
                let marker = line.trimmingCharacters(in: .whitespaces)
                if marker == "--" + boundary || marker == "--" + boundary + "--" {
                    if started {
                        var source = lines.joined(separator: "\n")
                        if source.hasSuffix("\r") { source.removeLast() }
                        guard let data = source.data(using: .isoLatin1) else { throw mailMIMEError() }
                        number += 1
                        let part = try mailMIMEParts(data, depth: depth + 1,
                            partNumber: partNumber.isEmpty ? "\(number)" : "\(partNumber).\(number)", attachmentsRoot: attachmentsRoot)
                        if let plain = part.plain { result.plain = [result.plain, plain].compactMap { $0 }.joined(separator: "\n") }
                        if let html = part.html { result.html = [result.html, html].compactMap { $0 }.joined(separator: "\n") }
                        result.attachments += part.attachments
                    }
                    lines = []; started = true
                    if marker == "--" + boundary + "--" { closed = true; break }
                } else if started { lines.append(line) }
            }
            guard closed else { throw mailMIMEError() }
            return result
        }
        guard ["text/plain", "text/html"].contains(kind) else { return (nil, nil, []) }
        let data = try mailMIMEDecode(body, encoding: headers["content-transfer-encoding"])
        let charset = parameter("charset") ?? "us-ascii"
        let encoding = CFStringConvertEncodingToNSStringEncoding(CFStringConvertIANACharSetNameToEncoding(charset as CFString))
        guard let text = String(data: data, encoding: String.Encoding(rawValue: encoding)) else { throw mailMIMEError() }
        return kind == "text/plain" ? (text, nil, []) : (nil, text, [])
    }

    private static func mailMIMEDecode(_ body: String, encoding: String?) throws -> Data {
        let data: Data?
        switch encoding?.lowercased() ?? "7bit" {
        case "base64":
            data = Data(base64Encoded: body.filter { !$0.isWhitespace })
        case "quoted-printable":
            guard let encoded = body.replacingOccurrences(of: "=\r\n", with: "").replacingOccurrences(of: "=\n", with: "").data(using: .isoLatin1) else { throw mailMIMEError() }
            let input = Array(encoded)
            var bytes: [UInt8] = [], i = 0
            while i < input.count {
                if input[i] == UInt8(ascii: "=") {
                    guard i + 2 < input.count, let byte = UInt8(String(decoding: input[(i + 1)...(i + 2)], as: UTF8.self), radix: 16) else { throw mailMIMEError() }
                    bytes.append(byte); i += 3
                } else { bytes.append(input[i]); i += 1 }
            }
            data = Data(bytes)
        case "7bit", "8bit", "binary": data = body.data(using: .isoLatin1)
        default: throw mailMIMEError()
        }
        guard let data else { throw mailMIMEError() }
        return data
    }
}
