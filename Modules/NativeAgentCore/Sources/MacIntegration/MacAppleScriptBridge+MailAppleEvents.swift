import Foundation
import PersistenceCore
// Blueprint: | `MacAppleScriptBridge+MailAppleEvents.swift` | `MacAppleScriptBridge`: Apple Event scripts, bounded identity lookups and encoded Mail record framing |

extension MacAppleScriptBridge {
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

    /// Probes positions before id scans; one message must match its id, available RFC id and supplied account.
    static func mailExactLookup(_ locator: MailReadLocator, into list: String, deadline: String? = nil) -> String {
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

    static func mailIdentityCheck(_ locator: MailReadLocator, list: String, fail: String, deadline: String? = nil) -> String {
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

    /// Sets targetBox (Mail reserves scope) to the named account's mailbox when found, else combined.
    static func mailAccountScope(_ account: String?, scope: String = "inbox", deadline: String? = nil) -> String {
        let box = scope == "inbox" ? "inbox" : "\(scope) mailbox"
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
        let box = scope == "inbox" ? "inbox" : "\(scope) mailbox"
        let locator = MailReadLocator.parse(input, allowMissingMessageID: true)
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
            // Mail supplies account inboxes; mailIndexPage supplies message rows and counts.
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
        tell application "__NativeAgentApp__"
            set enabledAccounts to (accounts whose enabled is true)
            if (count of enabledAccounts) is 0 then return "__NATIVEAGENT_MAIL_NOT_CONFIGURED__"
            my checkReadDeadline()
            set output to ""
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

    static func parseMailWorkspaceRecords(_ raw: String) -> [JSONValue] {
        raw.split(separator: "\n").compactMap { line in
            let fields = line.split(separator: "|", omittingEmptySubsequences: false)
            // Optional fields 11–14 hold read status, account, position and raw source.
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
            row["body"] = .string(decoded[4]); row["truncated"] = .bool(fields[6] == "true")
            row["body_offset"] = .int(offset); row["body_end"] = .int(end); row["body_total"] = .int(total)
            if fields.count == 14, let source = decodeConversationTransport(String(fields[13])) {
                let tables = mailHTMLTables(source: source)
                if !tables.isEmpty { row["body_tables"] = .array(tables) }
            }
            return .object(row)
        }
    }

    /// Appends encoded source to a completed row; large, unknown-size, slow or near-deadline reads leave it empty.
    /// Each source step is caught so it cannot fail the row or overrun its budget.
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
}
