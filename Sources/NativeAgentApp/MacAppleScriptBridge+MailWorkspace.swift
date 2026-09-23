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
            let rows = parseMailWorkspaceRecords(raw, detail: input["message_id"] != nil)
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
                    if parts.count == 3, let next = Int64(parts[1]), let total = Int64(parts[2]), next < total, next <= 10000 {
                        result["next_offset"] = .int(next)
                    }
                }
            }
            return .object(result)
        } catch let AppleScriptError.permissionDenied(app) {
            return deniedEnvelope(integration: "mail", app: app)
        } catch { return failedEnvelope(integration: "mail", error: error) }
    }

    static func mailExactLocator(_ input: [String: JSONValue]) -> (id: Int64, messageID: String)? {
        guard case .int(let id)? = input["message_id"], id > 0,
              let messageID = inputString(input["expected_message_id"]), !messageID.isEmpty, messageID.count < 4096 else { return nil }
        return (id, messageID)
    }

    static func mailWorkspaceScript(input: [String: JSONValue], query: String? = nil) -> String {
        let limit = clampedInt(input["limit"], defaultValue: 10, min: 1, max: 50)
        let locator = mailExactLocator(input)
        let listOffset = locator == nil ? clampedInt(input["offset"], defaultValue: 0, min: 0, max: 10000) : 0
        let selection: String
        if let locator {
            selection = """
            set msgList to (messages of inbox whose id is \(locator.id))
            if (count of msgList) is not 1 then return "__MESSAGE_CHANGED__"
            if ((message id of item 1 of msgList) as text) is not "\(escapeForAppleScript(locator.messageID))" then return "__MESSAGE_CHANGED__"
            set totalMessages to 1
            set messageCount to 1
            """
        } else if let query {
            selection = """
            set q to "\(escapeForAppleScript(query))"
            set totalMessages to count of messages of inbox
            set messageCount to totalMessages
            if messageCount > \(listOffset + 50) then set messageCount to \(listOffset + 50)
            """
        } else {
            selection = """
            set totalMessages to count of messages of inbox
            set messageCount to totalMessages
            if messageCount > \(listOffset + limit) then set messageCount to \(listOffset + limit)
            """
        }
        let item = locator != nil ? "set msg to item i of msgList" : "set msg to message i of inbox"
        let contentLimit = 16000
        let contentRead = locator == nil ? "set bodyText to \"\"" : "set bodyText to (content of msg) as text"
        let partialRecovery = locator == nil ? "if scannedThrough > \(listOffset) and errorNumber is -1712 then exit repeat" : ""
        let footer = locator == nil ? "set output to output & \"__PAGE__|\" & (scannedThrough as text) & \"|\" & (totalMessages as text) & linefeed" : ""
        let match = query == nil ? "true" : "(subjectText contains q) or (senderText contains q)"
        let offset = locator == nil ? 0 : clampedInt(input["body_offset"], defaultValue: 0, min: 0, max: 2_000_000)
        // 2026-09-22: a bulk range read ("subject of messages a thru b of inbox")
        // timed out (-1712) on the unified inbox live, so rows stay per-message.
        let perMessageRows = """
            repeat with i from \(listOffset + 1) to messageCount
                try
                my checkReadDeadline()
                \(item)
                my checkReadDeadline()
                set subjectText to (subject of msg) as text
                set senderText to (sender of msg) as text
                if \(match) then
                \(contentRead)
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
                set output to output & ((id of msg) as text) & "|" & (my encoded(message id of msg)) & "|" & (my encoded(subjectText)) & "|" & (my encoded(senderText)) & "|" & (my encoded((date received of msg) as text)) & "|" & (my encoded(bodyText)) & "|" & wasTruncated & "|" & (startOffset as text) & "|" & (endOffset as text) & "|" & (totalCharacters as text) & linefeed
                set completedRows to completedRows + 1
                end if
                set scannedThrough to i as integer
                if completedRows ≥ \(limit) then exit repeat
                on error errorText number errorNumber
                    \(partialRecovery)
                    error errorText number errorNumber
                end try
            end repeat
            """
        let rows = perMessageRows
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
            \(selection)
            set output to ""
            set completedRows to 0
            set scannedThrough to \(listOffset)
            \(rows)
            \(footer)
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
            guard fields.count == 10, let id = Int64(fields[0]), id > 0 else { return nil }
            let decoded = fields[1...5].compactMap { decodeConversationTransport(String($0)) }
            guard decoded.count == 5, fields[6] == "true" || fields[6] == "false",
                  let offset = Int64(fields[7]), let end = Int64(fields[8]), let total = Int64(fields[9]),
                  offset >= 0, end >= 0, total >= 0, end <= total else { return nil }
            var row: [String: JSONValue] = ["message_id": .int(id), "expected_message_id": .string(decoded[0]), "subject": .string(decoded[1]),
                "sender": .string(decoded[2]), "date": .string(normalizeAppleScriptDate(decoded[3]))]
            if detail {
                row["body"] = .string(decoded[4]); row["truncated"] = .bool(fields[6] == "true")
                row["body_offset"] = .int(offset); row["body_end"] = .int(end); row["body_total"] = .int(total)
            } else { row["body_status"] = .string("not_loaded") }
            return .object(row)
        }
    }
}
