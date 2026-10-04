import Foundation
import SQLite3
import PersistenceCore
import MacIntegration

extension MacAppleScriptBridge {
    /// Bounded mailbox reads with opaque owner IDs. Transport fields are encoded
    /// separately so message content can never manufacture another message ID.
    static func mailWorkspaceRead(input: [String: JSONValue], query: String? = nil) async throws -> JSONValue {
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
            let script = mailWorkspaceScript(input: input, query: query)
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
        if let database { sqlite3_busy_timeout(database, 500) }
        return database
    }

    /// One inbox page read from Mail's own index (Envelope Index, read-only,
    /// under the app's Full Disk Access): rows from each account's
    /// inbox, newest first, positions as Mail numbers them, `limit` rows by
    /// date. `header` is the script's unread count and account inboxes. An
    /// account whose inbox the index lacks is named in `accounts_not_listed`;
    /// the others still list.
    static func mailIndexPage(header: String, input: [String: JSONValue], query: String?) -> JSONValue {
        guard let scope = mailReadScope(input) else { return failedEnvelope(integration: "mail", reason: "unsupported_mailbox") }
        let limit = clampedInt(input["limit"], defaultValue: 10, min: 1, max: 50)
        let listOffset = clampedInt(input["offset"], defaultValue: 0, min: 0, max: 10000)
        var offsets: [String: JSONValue] = [:]
        if case .object(let cursor)? = input["offset"] {
            guard cursor.values.allSatisfy({ if case .int(let value) = $0 { value >= 0 && value < Int.max - 50 } else { false } }) else {
                return failedEnvelope(integration: "mail", reason: "invalid_mail_offset")
            }
            offsets = cursor
        }
        let pageSize = query == nil ? limit : 50
        var unread: Int64 = -1
        var accounts: [(name: String, id: String, inbox: String)] = []
        for line in header.split(separator: "\n") {
            let fields = line.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
            if fields.count == 2, fields[0] == "__UNREAD__" { unread = Int64(fields[1]) ?? -1 }
            if fields.count == 4, fields[0] == "__BOX__" {
                let decoded = fields[1...3].map { decodeConversationTransport($0) ?? "" }
                accounts.append((decoded[0], decoded[1], decoded[2]))
            }
        }
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
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        // Every account type's mailbox URL is `scheme://<account id>/<mailbox path>`
        // (imap, ews, pop, local), so an inbox is its account id and Mail's own name for it.
        var mailboxes: [(id: Int, account: String, path: String)] = []
        guard each("SELECT ROWID, url FROM mailboxes", [], { statement in
            if let url = URL(string: text(statement, 1)), let host = url.host {
                mailboxes.append((Int(sqlite3_column_int64(statement, 0)), host, String(url.path.dropFirst())))
            }
        }) else { return failedEnvelope(integration: "mail", reason: "mail_index_unavailable") }
        var boxes: [(account: String, count: Int, offset: Int, consumed: Int, rows: [JSONValue])] = [], notListed: [JSONValue] = []
        for account in accounts.sorted(by: { $0.id < $1.id }) {
            var count = 0, rows: [JSONValue] = []
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
            guard each("SELECT count(*) FROM messages m WHERE \(inboxMessages)", [mailbox], { count = Int(sqlite3_column_int64($0, 0)) }),
                  each("""
                    SELECT m.ROWID, g.message_id_header, m.subject_prefix, s.subject, a.comment, a.address, m.date_received, m.read
                    FROM messages m LEFT JOIN subjects s ON s.ROWID = m.subject LEFT JOIN addresses a ON a.ROWID = m.sender
                    LEFT JOIN message_global_data g ON g.ROWID = m.global_message_id
                    WHERE \(inboxMessages) ORDER BY m.date_received DESC, m.ROWID DESC LIMIT ?2 OFFSET ?3
                    """, [mailbox, pageSize, offset], { statement in
                        var messageID = text(statement, 1)
                        if messageID.hasPrefix("<"), messageID.hasSuffix(">") { messageID = String(messageID.dropFirst().dropLast()) }
                        let received = sqlite3_column_type(statement, 6) == SQLITE_NULL ? ""
                            : iso.string(from: Date(timeIntervalSince1970: TimeInterval(sqlite3_column_int64(statement, 6))))
                        var row: [String: JSONValue] = ["message_id": .int(sqlite3_column_int64(statement, 0)), "expected_message_id": .string(messageID),
                            "subject": .string(text(statement, 2) + text(statement, 3)), "sender": .string(mailSenderText(comment: text(statement, 4), address: text(statement, 5))),
                            "date": .string(received), "unread": .bool(sqlite3_column_int(statement, 7) == 0),
                            "position": .int(Int64(offset + rows.count + 1)), "body_status": .string("not_loaded"), "scope": .string(scope)]
                        if !account.name.isEmpty { row["expected_account"] = .string(account.name) }
                        rows.append(.object(row))
                    }) else { return failedEnvelope(integration: "mail", reason: "mail_index_unavailable") }
            boxes.append((account.id, count, offset, 0, rows))
        }
        // Merge account heads; fetched rows outside this page remain unconsumed.
        func received(_ row: JSONValue) -> String { if case .object(let o) = row, case .string(let d)? = o["date"] { d } else { "" } }
        var rows: [JSONValue] = [], inspected = 0
        while rows.count < limit {
            var next: Int?
            for index in boxes.indices where boxes[index].consumed < boxes[index].rows.count {
                if let current = next {
                    if received(boxes[index].rows[boxes[index].consumed]) > received(boxes[current].rows[boxes[current].consumed]) { next = index }
                } else { next = index }
            }
            guard let next else { break }
            let row = boxes[next].rows[boxes[next].consumed]
            boxes[next].consumed += 1
            inspected += 1
            if let query, case .object(let object) = row {
                if [object["subject"], object["sender"]].contains(where: { if case .string(let value)? = $0 { value.localizedCaseInsensitiveContains(query) } else { false } }) { rows.append(row) }
            } else { rows.append(row) }
        }
        var result: [String: JSONValue] = ["status": .string("completed"), "count": .int(Int64(rows.count)),
            "messages": .array(rows), "scope": .string(scope), "detail": .bool(false),
            "content_note": .string("Mailbox metadata only; open a message to load its body. Pages read the current mailbox, which may change between reads."),
            "mailbox_total": .int(Int64(boxes.reduce(0) { $0 + $1.count }))]
        let hasMore = boxes.contains(where: { $0.count > $0.offset + $0.consumed })
        result["has_more"] = .bool(hasMore)
        if query != nil {
            result["inspected_count"] = .int(Int64(inspected))
            result["matches_omitted"] = .int(0)
            result["search_coverage"] = .string("Inspected \(inspected) messages in \(scope), sender and subject only, up to 50 per account per page. Bodies were not searched.\(hasMore ? " Later messages remain; continue with next_offset when offered. An empty page does not prove absence." : " No later messages remain in the listed accounts.")")
        }
        if hasMore {
            for box in boxes { offsets[box.account] = .int(Int64(box.offset + box.consumed)) }
            result["next_offset"] = .object(offsets)
        }
        if scope == "inbox" {
            result["inbox_total"] = result["mailbox_total"]
            if unread >= 0 { result["inbox_unread"] = .int(unread) }
        }
        if !notListed.isEmpty {
            // The totals would count different accounts, so a partial page carries none.
            result["mailbox_total"] = nil; result["inbox_total"] = nil; result["inbox_unread"] = nil
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

    static func mailWorkspaceScript(input: [String: JSONValue], query: String? = nil, batch: Bool = false) -> String {
        let scope = mailReadScope(input) ?? "inbox"
        let box = scope == "sent" ? "sent mailbox" : "inbox"
        let locator = mailExactLocator(input, allowMissingMessageID: true)
        let contentLimit = batch ? 4000 : 16000
        let offset = locator == nil ? 0 : clampedInt(input["body_offset"], defaultValue: 0, min: 0, max: 2_000_000)
        let match = query == nil ? "true" : "(subjectText contains q) or (senderText contains q)"
        /// One row: `msg` and `accountName` are set by the caller.
        let row = """
                set subjectText to (subject of msg) as text
                set senderText to (sender of msg) as text
                if \(match) then
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
                end if
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
            // 2026-09-26: only the account inboxes and the unread count come
            // from Mail; the rows come from its index (mailIndexPage), since
            // each `message i` of a 141k-message inbox costs Mail ~1.5s.
            body = """
            set unreadMessages to -1
            try
                set unreadMessages to unread count of \(box)
            end try
            set output to output & "__UNREAD__|" & (unreadMessages as text) & linefeed
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
        guard let html = mailHTMLPart(source) else { return [] }
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
        var text = inner.replacingOccurrences(of: #"<[^>]*>"#, with: " ", options: .regularExpression)
        for (entity, value) in [("&nbsp;", " "), ("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&#39;", "'"), ("&apos;", "'"), ("&amp;", "&")] {
            text = text.replacingOccurrences(of: entity, with: value, options: .caseInsensitive)
        }
        while let range = text.range(of: #"&#(x?)([0-9a-fA-F]{1,6});"#, options: .regularExpression) {
            let code = text[range].dropFirst(2).dropLast()
            let scalar = code.hasPrefix("x") || code.hasPrefix("X") ? UInt32(code.dropFirst(), radix: 16) : UInt32(code)
            text.replaceSubrange(range, with: scalar.flatMap(Unicode.Scalar.init).map { String(Character($0)) } ?? " ")
        }
        let line = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return line.count > 120 ? nil : line
    }

    /// The text/html part of a raw message, decoded (quoted-printable or
    /// base64, by its charset), or nil when there is none.
    private static func mailHTMLPart(_ source: String) -> String? {
        let raw = source.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        guard let type = raw.range(of: #"(?im)^content-type:\s*text/html"#, options: .regularExpression),
              let headerEnd = raw[type.lowerBound...].range(of: "\n\n") else { return nil }
        let headerStart = raw[..<type.lowerBound].range(of: "\n\n", options: .backwards)?.upperBound ?? raw.startIndex
        let headers = raw[headerStart..<headerEnd.lowerBound].lowercased()
        var body = String(raw[headerEnd.upperBound...])
        if let boundary = body.range(of: "\n--") { body = String(body[..<boundary.lowerBound]) }
        let charset = headers.range(of: #"charset="?[a-z0-9._-]+"#, options: .regularExpression).map {
            headers[$0].replacingOccurrences(of: #"charset="?"#, with: "", options: .regularExpression)
        } ?? "utf-8"
        let data: Data?
        if headers.range(of: #"content-transfer-encoding:\s*base64"#, options: .regularExpression) != nil {
            data = Data(base64Encoded: body, options: .ignoreUnknownCharacters)
        } else if headers.range(of: #"content-transfer-encoding:\s*quoted-printable"#, options: .regularExpression) != nil {
            let input = Array(body.replacingOccurrences(of: "=\n", with: "").utf8)
            var bytes: [UInt8] = [], i = 0
            while i < input.count {
                if input[i] == UInt8(ascii: "="), i + 2 < input.count,
                   let byte = UInt8(String(decoding: input[(i + 1)...(i + 2)], as: UTF8.self), radix: 16) {
                    bytes.append(byte); i += 3
                } else { bytes.append(input[i]); i += 1 }
            }
            data = Data(bytes)
        } else { return body }
        guard let data else { return nil }
        let encoding = CFStringConvertEncodingToNSStringEncoding(CFStringConvertIANACharSetNameToEncoding(charset as CFString))
        return String(data: data, encoding: String.Encoding(rawValue: encoding)) ?? String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .isoLatin1)
    }
}
