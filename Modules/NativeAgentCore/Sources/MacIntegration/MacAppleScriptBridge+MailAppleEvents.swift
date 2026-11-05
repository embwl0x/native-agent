import Foundation
import PersistenceCore
// Blueprint: | `MacAppleScriptBridge+MailAppleEvents.swift` | `MacAppleScriptBridge`: checked mailbox identity and metadata |

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

    /// One exact id lookup in the checked mailbox; a supplied position is observation metadata.
    static func mailExactLookup(_ locator: MailReadLocator, into list: String, deadline: String? = nil) -> String {
        mailLookupCommand("set \(list) to (messages of targetBox whose id is \(locator.id))", deadline: deadline)
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

    /// A requested account must resolve exactly; it never expands to the combined mailbox.
    static func mailAccountScope(_ account: String?, scope: String = "inbox", deadline: String? = nil) -> String {
        let box = scope == "inbox" ? "inbox" : "\(scope) mailbox"
        guard let account else { return mailLookupCommand("set targetBox to \(box)", deadline: deadline) }
        return """
        set targetBox to missing value
        \(mailLookupCommand("set accountMailboxes to mailboxes of \(box)", deadline: deadline))
        repeat with mb in accountMailboxes
            \(mailLookupCommand("set mailboxAccountName to (name of account of mb) as text", deadline: deadline))
            if mailboxAccountName is "\(escapeForAppleScript(account))" then
                if targetBox is not missing value then error "Several Mail mailboxes match the requested account; refresh the message locator."
                set targetBox to contents of mb
            end if
        end repeat
        if targetBox is missing value then error "The requested Mail account mailbox is unavailable; refresh the message locator."
        """
    }

    /// Current account/mailbox metadata for the Envelope Index owner; body bytes belong to mailFileRead.
    static func mailWorkspaceScript(input: [String: JSONValue]) -> String {
        let scope = mailReadScope(input) ?? "inbox"
        let box = scope == "inbox" ? "inbox" : "\(scope) mailbox"
        let body = """
            set boxes to (mailboxes of \(box)) as list
            repeat with mb in boxes
                set boxInbox to (name of mb) as text
                set boxName to (name of account of mb) as text
                set boxAccount to (id of account of mb) as text
                set output to output & "__BOX__|" & (my encoded(boxName)) & "|" & (my encoded(boxAccount)) & "|" & (my encoded(boxInbox)) & linefeed
            end repeat
            """
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

    /// Inverse of the script's fixed escaping alphabet. Reject malformed escapes; decode once so literal percent sequences never become structural delimiters.
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

}
