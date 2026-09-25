import Foundation
import PersistenceCore

extension MacAppleScriptBridge {
    /// Bounded inbox reads with opaque owner IDs. Transport fields are encoded
    /// separately so message content can never manufacture another message ID.
    static func mailWorkspaceRead(input: [String: JSONValue], query: String? = nil) async throws -> JSONValue {
        if input["message_id"] != nil && mailExactLocator(input) == nil {
            return failedEnvelope(integration: "mail", reason: "invalid_message_locator")
        }
        do {
            let raw = try await runAppleScript(mailWorkspaceScript(input: input, query: query))
            if let setup = readSetupEnvelope(raw: raw, integration: "mail") { return setup }
            if raw == "__MESSAGE_CHANGED__" { return failedEnvelope(integration: "mail", reason: "message_changed_or_moved_refresh_inbox") }
            var rows = parseMailWorkspaceRecords(raw, detail: input["message_id"] != nil)
            if input["message_id"] == nil {
                // Newest first across accounts (ISO dates sort as text), then the page size.
                func received(_ row: JSONValue) -> String { if case .object(let o) = row, case .string(let d)? = o["date"] { d } else { "" } }
                rows = Array(rows.sorted { received($0) > received($1) }.prefix(clampedInt(input["limit"], defaultValue: 10, min: 1, max: 50)))
            }
            if input["message_id"] != nil && rows.isEmpty { return failedEnvelope(integration: "mail", reason: "message_not_in_inbox") }
            var result: [String: JSONValue] = ["status": .string("completed"), "count": .int(Int64(rows.count)),
                "messages": .array(rows), "scope": .string("inbox"), "detail": .bool(input["message_id"] != nil)]
            if input["message_id"] == nil {
                result["content_note"] = .string("Inbox metadata only; open a message to load its body. Pages read the current inbox, which may change between reads.")
                if query != nil {
                    result["search_coverage"] = .string("Sender and subject in at most 50 inbox messages per page. Message bodies and later pages were not searched; continue with next_offset when offered.")
                }
                if let footer = raw.split(separator: "\n").last, footer.hasPrefix("__PAGE__|") {
                    let parts = footer.split(separator: "|")
                    if parts.count >= 3, let next = Int64(parts[1]), let total = Int64(parts[2]) {
                        result["inbox_total"] = .int(total)
                        let more = parts.count >= 5 ? parts[4] == "true" : next < total
                        if more, next <= 10000 { result["next_offset"] = .int(next) }
                        if parts.count >= 4, let unread = Int64(parts[3]), unread >= 0 { result["inbox_unread"] = .int(unread) }
                    }
                }
            }
            return .object(result)
        } catch let AppleScriptError.permissionDenied(app) {
            return deniedEnvelope(integration: "mail", app: app)
        } catch let error as NSError where error.domain == "NativeAgentAppleScript" && [-1712, appleScriptOutcomeUnknownCode].contains(error.code) {
            // A read changes nothing, so the "outcome unknown" caution for sends does not apply.
            return .object(["status": .string("failed"), "integration": .string("mail"), "error_code": .int(Int64(error.code)),
                "error": .string("Mail was too slow to answer (it is often busy syncing). Nothing was changed. Try again in a minute, or ask for fewer messages.")])
        } catch { return failedEnvelope(integration: "mail", error: error) }
    }

    typealias MailLocator = (id: Int64, messageID: String, account: String?, position: Int?)

    static func mailExactLocator(_ input: [String: JSONValue]) -> MailLocator? {
        // "12345" as well as 12345: the id as text is still the id.
        guard let id = inputString(input["message_id"]).flatMap({ Int64($0.trimmingCharacters(in: .whitespaces)) }), id > 0,
              let messageID = inputString(input["expected_message_id"]), !messageID.isEmpty, messageID.count < 4096 else { return nil }
        let account = inputString(input["expected_account"]).flatMap { $0.isEmpty || $0.count > 512 ? nil : $0 }
        let position = inputString(input["position"]).flatMap { Int($0.trimmingCharacters(in: .whitespaces)) }.flatMap { $0 > 0 && $0 < 10_000_000 ? $0 : nil }
        return (id, messageID, account, position)
    }

    /// The one message `list` holds is the one that was read: exactly one
    /// match, its RFC id, and (when the read carried it) its account, so the
    /// same email in a second account's inbox is never the one acted on.
    /// Sets `list` to the message with the locator's id in `targetBox`. The
    /// listing's position is tried first, then a few places later (new mail
    /// pushes it down) and earlier, before the full `whose id is` scan, which
    /// times out in a ~140k-message account inbox (2026-09-24). The identity
    /// check after it still decides.
    static func mailExactLookup(_ locator: MailLocator, into list: String) -> String {
        let scan = "set \(list) to (messages of targetBox whose id is \(locator.id))"
        guard let position = locator.position else { return scan }
        return """
        set \(list) to {}
        repeat with shiftBy in {0, 1, 2, 3, 4, 5, 6, 8, 10, 12, 16, 20, -1, -2, -3}
            set probeIndex to \(position) + (shiftBy as integer)
            if probeIndex ≥ 1 then
                try
                    set candidateMsg to message probeIndex of targetBox
                    if (id of candidateMsg) is \(locator.id) then
                        set \(list) to {candidateMsg}
                        exit repeat
                    end if
                end try
            end if
        end repeat
        if (count of \(list)) is 0 then \(scan)
        """
    }

    static func mailIdentityCheck(_ locator: MailLocator, list: String, fail: String) -> String {
        var lines = [
            "if (count of \(list)) is not 1 then return \"\(fail)\"",
            "if ((message id of item 1 of \(list)) as text) is not \"\(escapeForAppleScript(locator.messageID))\" then return \"\(fail)\"",
        ]
        if let account = locator.account {
            lines.append("if ((name of account of mailbox of item 1 of \(list)) as text) is not \"\(escapeForAppleScript(account))\" then return \"\(fail)\"")
        }
        return lines.joined(separator: "\n")
    }

    /// AppleScript that sets `targetBox` (not `scope`: Mail owns that word, -10006) to the inbox of the named account (each
    /// account's own inbox is a mailbox of the combined one), or the combined
    /// inbox when none is named or found. An id looked up there is scanned in
    /// one account's inbox, not all of them (2026-09-24: a 141k-message
    /// combined inbox timed out on `whose id is`).
    static func mailAccountScope(_ account: String?) -> String {
        guard let account else { return "set targetBox to inbox" }
        return """
        set targetBox to inbox
        try
            repeat with mb in (mailboxes of inbox)
                if ((name of account of mb) as text) is "\(escapeForAppleScript(account))" then
                    set targetBox to mb
                    exit repeat
                end if
            end repeat
        end try
        """
    }

    static func mailWorkspaceScript(input: [String: JSONValue], query: String? = nil) -> String {
        let limit = clampedInt(input["limit"], defaultValue: 10, min: 1, max: 50)
        let locator = mailExactLocator(input)
        let listOffset = locator == nil ? clampedInt(input["offset"], defaultValue: 0, min: 0, max: 10000) : 0
        let contentLimit = 16000
        let offset = locator == nil ? 0 : clampedInt(input["body_offset"], defaultValue: 0, min: 0, max: 2_000_000)
        let match = query == nil ? "true" : "(subjectText contains q) or (senderText contains q)"
        /// One row: `msg` and `accountName` are set by the caller.
        let row = """
                set subjectText to (subject of msg) as text
                set senderText to (sender of msg) as text
                if \(match) then
                \(locator == nil ? "set bodyText to \"\"" : "set bodyText to (content of msg) as text")
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
                set output to output & ((id of msg) as text) & "|" & (my encoded(message id of msg)) & "|" & (my encoded(subjectText)) & "|" & (my encoded(senderText)) & "|" & (my encoded((date received of msg) as text)) & "|" & (my encoded(bodyText)) & "|" & wasTruncated & "|" & (startOffset as text) & "|" & (endOffset as text) & "|" & (totalCharacters as text) & "|" & ((read status of msg) as text) & "|" & (my encoded(accountName)) & "|" & (rowPosition as text)\(locator == nil ? " & linefeed" : "\n" + Self.mailSourceScript)
                set completedRows to completedRows + 1
                end if
        """
        let body: String
        if let locator {
            body = """
            \(mailAccountScope(locator.account))
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
            // 2026-09-24: the combined inbox lists one account after another
            // (an old iCloud welcome before today's Gmail), so rows are read
            // round-robin from each account's own inbox, newest first, and
            // Swift sorts them by date. The inbox's own counts come first,
            // before any row can spend the time budget.
            let rounds = listOffset + (query == nil ? limit : 50)
            body = """
            \(query.map { "set q to \"\(escapeForAppleScript($0))\"" } ?? "")
            set totalMessages to count of messages of inbox
            set unreadMessages to -1
            try
                set unreadMessages to unread count of inbox
            end try
            set boxes to {}
            try
                set boxes to (mailboxes of inbox) as list
            end try
            if (count of boxes) is 0 then set boxes to {inbox}
            set boxNames to {}
            set boxCounts to {}
            repeat with mb in boxes
                set boxName to ""
                try
                    set boxName to (name of account of mb) as text
                end try
                set end of boxNames to boxName
                set end of boxCounts to (count of messages of mb)
            end repeat
            set timedOut to false
            repeat with i from \(listOffset + 1) to \(rounds)
                set anyLeft to false
                repeat with b from 1 to (count of boxes)
                    if i ≤ (item b of boxCounts) then
                        set anyLeft to true
                        try
                            my checkReadDeadline()
                            set msg to message i of (item b of boxes)
                            set accountName to item b of boxNames
                            set rowPosition to i
                            \(row)
                        on error errorText number errorNumber
                            set timedOut to true
                            if completedRows > 0 and errorNumber is -1712 then exit repeat
                            error errorText number errorNumber
                        end try
                    end if
                end repeat
                if timedOut then exit repeat
                set scannedThrough to i
                if not anyLeft then exit repeat
                \(query == nil ? "" : "if completedRows ≥ \(limit) then exit repeat")
            end repeat
            set moreLeft to "false"
            repeat with n in boxCounts
                if (n as integer) > scannedThrough then set moreLeft to "true"
            end repeat
            set output to output & "__PAGE__|" & (scannedThrough as text) & "|" & (totalMessages as text) & "|" & (unreadMessages as text) & "|" & moreLeft & linefeed
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
            set scannedThrough to \(listOffset)
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
