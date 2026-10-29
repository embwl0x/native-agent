import Foundation
import NativeAgentShared
import MacControl
import SQLite3
import PersistenceCore
// Blueprint: | `MacAppleScriptBridge+MailIndex.swift` | `MacAppleScriptBridge`: read-only Envelope Index queries, account coverage, exact sender counts, mailbox pages and sender formatting |

extension MacAppleScriptBridge {
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
            let header = scope == .string("inbox") ? try await runAppleScript(mailWorkspaceScript(input: [:]), bundleID: "com.apple.mail") : ""
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
        let scope = input["scope"]?.scalarText ?? "inbox"
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
                    : .string(NativeTimestampFormat.plainZulu(Date(timeIntervalSince1970: Double(sqlite3_column_int64(statement, 4)))))]))
            step = sqlite3_step(statement)
        }
        guard step == SQLITE_DONE, !Task.isCancelled, ProcessInfo.processInfo.systemUptime < deadline.doubleValue else {
            return failedEnvelope(integration: "mail", reason: "sender_counts_unavailable")
        }
        return .object(["status": .string("completed"), "scope": .string(scope), "count": .int(Int64(rows.count)),
            "unread_only": .bool(input["unread_only"] == .bool(true)), "senders": .array(rows)])
    }

    /// Read-only Envelope Index pages under Full Disk Access use the script's account mailboxes, Mail's positions and index counts.
    /// Queries cover the whole mailbox's subject and sender; missing accounts are named in `accounts_not_listed`.
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
        // Inbox lists default to Primary and Transactions unless all_categories; searches cover every category.
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
        iso.timeZone = .current  // Mail displays local time.
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
                        row["expected_account_id"] = .string(account.id)
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
        if input["attachment"] != nil, !rows.isEmpty {
            let ids = rows.compactMap { if case .object(let row) = $0, case .int(let id)? = row["message_id"] { Int(id) } else { nil } }
            guard ids.count == rows.count else { return failedEnvelope(integration: "mail", reason: "mail_index_unavailable") }
            var namesByMessage: [Int64: [JSONValue]] = [:]
            guard each("""
                SELECT message, name FROM (
                    SELECT message, name, row_number() OVER (PARTITION BY message ORDER BY attachment_id, name) AS position
                    FROM attachments WHERE message IN (\(ids.map { _ in "?" }.joined(separator: ",")))
                ) WHERE position <= 5 ORDER BY message, position
                """, ids, {
                namesByMessage[sqlite3_column_int64($0, 0), default: []].append(.string(text($0, 1)))
            }) else { return failedEnvelope(integration: "mail", reason: "mail_index_unavailable") }
            for index in rows.indices {
                guard case .object(var row) = rows[index], case .int(let id)? = row["message_id"] else {
                    return failedEnvelope(integration: "mail", reason: "mail_index_unavailable")
                }
                row["attachment_names"] = .array(namesByMessage[id] ?? [])
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

    /// Mail's `Name <address>` format quotes special characters and leaves bare-address names bare.
    static func mailSenderText(comment: String, address: String) -> String {
        guard !comment.isEmpty else { return address }
        let bareAddress = comment.contains("@") && !comment.contains(where: \.isWhitespace)
        let name = bareAddress || comment.rangeOfCharacter(from: CharacterSet(charactersIn: "()<>[]:;@\\,.\"")) == nil ? comment
            : "\"" + comment.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
        return address.isEmpty ? name : "\(name) <\(address)>"
    }
}
