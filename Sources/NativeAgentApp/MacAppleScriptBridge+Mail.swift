import Foundation
import AppKit
import PersistenceCore

extension MacAppleScriptBridge {
    // MARK: MAIL

    /// List the N most recent messages in inbox. Input: "limit" (default 10, max 50).
    /// Returns: {status, count, messages: [{subject, sender, date, snippet}]}
    public static func mailListRecent(input: [String: JSONValue]) async throws -> JSONValue {
        let limit = clampedInt(input["limit"], defaultValue: 10, min: 1, max: 50)
        let source = """
        tell application "Mail"
            set enabledAccounts to (accounts whose enabled is true)
            if (count of enabledAccounts) is 0 then return "__NATIVEAGENT_MAIL_NOT_CONFIGURED__"
            set msgList to messages of inbox
            set output to ""
            set countMsg to 0
            repeat with i from 1 to (count of msgList)
                if countMsg ≥ \(limit) then exit repeat
                set msg to item i of msgList
                set output to output & (subject of msg) & "|||" & (sender of msg) & "|||" & ((date received of msg) as string) & "|||"
                try
                    set output to output & (text 1 thru 200 of (content of msg))
                end try
                set output to output & "###"
                set countMsg to countMsg + 1
            end repeat
            return output
        end tell
        """
        do {
            let raw = try await runAppleScript(source)
            if let setup = readSetupEnvelope(raw: raw, integration: "mail") { return setup }
            let messages = parseMailRecords(raw)
            return .object([
                "status": .string("completed"),
                "count": .int(Int64(messages.count)),
                "messages": .array(messages),
            ])
        } catch let AppleScriptError.permissionDenied(app) {
            return deniedEnvelope(integration: "mail", app: app)
        } catch {
            return failedEnvelope(integration: "mail", error: error)
        }
    }

    /// Search inbox by subject/sender/body fragment. Input: "query" (required),
    /// "limit" (default 10, max 50).
    /// Returns: same shape as mailListRecent.
    public static func mailSearch(input: [String: JSONValue]) async throws -> JSONValue {
        guard let query = inputString(input["query"]), !query.isEmpty else {
            return failedEnvelope(integration: "mail", reason: "missing_query")
        }
        let limit = clampedInt(input["limit"], defaultValue: 10, min: 1, max: 50)
        let escapedQuery = escapeForAppleScript(query)
        let source = """
        tell application "Mail"
            set enabledAccounts to (accounts whose enabled is true)
            if (count of enabledAccounts) is 0 then return "__NATIVEAGENT_MAIL_NOT_CONFIGURED__"
            set q to "\(escapedQuery)"
            set msgList to (messages of inbox whose (subject contains q) or (sender contains q) or (content contains q))
            set output to ""
            set countMsg to 0
            repeat with i from 1 to (count of msgList)
                if countMsg ≥ \(limit) then exit repeat
                set msg to item i of msgList
                set output to output & (subject of msg) & "|||" & (sender of msg) & "|||" & ((date received of msg) as string) & "|||"
                try
                    set output to output & (text 1 thru 200 of (content of msg))
                end try
                set output to output & "###"
                set countMsg to countMsg + 1
            end repeat
            return output
        end tell
        """
        do {
            let raw = try await runAppleScript(source)
            if let setup = readSetupEnvelope(raw: raw, integration: "mail") { return setup }
            let messages = parseMailRecords(raw)
            return .object([
                "status": .string("completed"),
                "count": .int(Int64(messages.count)),
                "messages": .array(messages),
            ])
        } catch let AppleScriptError.permissionDenied(app) {
            return deniedEnvelope(integration: "mail", app: app)
        } catch {
            return failedEnvelope(integration: "mail", error: error)
        }
    }

    /// Send mail via Mail.app. Required: "to" (string or array), "subject", "body".
    /// Optional: "cc", "bcc".
    /// Returns: {status, action: "sent", to, subject}.
    public static func mailSend(input: [String: JSONValue]) async throws -> JSONValue {
        let toList = inputStringArray(input["to"])
        guard !toList.isEmpty else {
            return failedEnvelope(integration: "mail", reason: "missing_to")
        }
        guard let subject = inputString(input["subject"]) else {
            return failedEnvelope(integration: "mail", reason: "missing_subject")
        }
        guard let body = inputString(input["body"]) else {
            return failedEnvelope(integration: "mail", reason: "missing_body")
        }
        let ccList = inputStringArray(input["cc"])
        let bccList = inputStringArray(input["bcc"])

        let subjectAS = escapeForAppleScript(subject)
        let bodyAS = escapeForAppleScript(body)

        var recipientLines: [String] = []
        for to in toList {
            let e = escapeForAppleScript(to)
            recipientLines.append("make new to recipient at end of to recipients with properties {address:\"\(e)\"}")
        }
        for cc in ccList {
            let e = escapeForAppleScript(cc)
            recipientLines.append("make new cc recipient at end of cc recipients with properties {address:\"\(e)\"}")
        }
        for bcc in bccList {
            let e = escapeForAppleScript(bcc)
            recipientLines.append("make new bcc recipient at end of bcc recipients with properties {address:\"\(e)\"}")
        }
        let recipientsBlock = recipientLines.joined(separator: "\n            ")

        let source = """
        tell application "Mail"
            set newMsg to make new outgoing message with properties {subject:"\(subjectAS)", content:"\(bodyAS)", visible:false}
            tell newMsg
                \(recipientsBlock)
            end tell
            send newMsg
            return "sent"
        end tell
        """
        do {
            _ = try await runAppleScript(source)
            return .object([
                "status": .string("completed"),
                "action": .string("sent"),
                "to": .array(toList.map { .string($0) }),
                "subject": .string(subject),
            ])
        } catch let AppleScriptError.permissionDenied(app) {
            return deniedEnvelope(integration: "mail", app: app)
        } catch {
            return failedEnvelope(integration: "mail", error: error)
        }
    }

    // MARK: MAIL MANAGE

    /// Mark an inbox message as read. Required: "subject" (exact match from a
    /// prior mail_list_recent / mail_search result). Optional: "sender" for
    /// disambiguation when multiple messages share a subject.
    /// Returns: {status, action: "marked_read", matched_count}.
    public static func mailMarkRead(input: [String: JSONValue]) async throws -> JSONValue {
        guard let subject = inputString(input["subject"]), !subject.isEmpty else {
            return failedEnvelope(integration: "mail", reason: "missing_subject")
        }
        let sender = inputString(input["sender"])
        let subjectAS = escapeForAppleScript(subject)
        let whereClause = Self.mailMatchWhereClause(subjectAS: subjectAS, sender: sender)
        let source = """
        tell application "Mail"
            set hits to (messages of inbox whose \(whereClause))
            set n to count of hits
            repeat with msg in hits
                set read status of msg to true
            end repeat
            return n as string
        end tell
        """
        do {
            let raw = try await runAppleScript(source)
            let n = Int(raw.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
            return .object([
                "status": .string("completed"),
                "action": .string("marked_read"),
                "matched_count": .int(Int64(n)),
            ])
        } catch let AppleScriptError.permissionDenied(app) {
            return deniedEnvelope(integration: "mail", app: app)
        } catch {
            return failedEnvelope(integration: "mail", error: error)
        }
    }

    /// Archive an inbox message (move to the Archive mailbox). Same input shape
    /// as `mailMarkRead`. If no Archive mailbox exists on any account, returns
    /// a failed envelope with reason "no_archive_mailbox".
    /// Returns: {status, action: "archived", matched_count}.
    public static func mailArchive(input: [String: JSONValue]) async throws -> JSONValue {
        guard let subject = inputString(input["subject"]), !subject.isEmpty else {
            return failedEnvelope(integration: "mail", reason: "missing_subject")
        }
        let sender = inputString(input["sender"])
        let subjectAS = escapeForAppleScript(subject)
        let whereClause = Self.mailMatchWhereClause(subjectAS: subjectAS, sender: sender)
        // Try the top-level "Archive" mailbox first; fall back to scanning
        // accounts for an Archive mailbox. If neither exists, return a
        // distinguishable sentinel ("__NO_ARCHIVE__") so the caller can emit
        // the dedicated failure envelope.
        let source = """
        tell application "Mail"
            set hits to (messages of inbox whose \(whereClause))
            set n to count of hits
            if n is 0 then return "0"
            set archiveBox to missing value
            try
                set archiveBox to mailbox "Archive"
            end try
            if archiveBox is missing value then
                repeat with acct in accounts
                    try
                        set archiveBox to mailbox "Archive" of acct
                        exit repeat
                    end try
                end repeat
            end if
            if archiveBox is missing value then return "__NO_ARCHIVE__"
            repeat with msg in hits
                move msg to archiveBox
            end repeat
            return n as string
        end tell
        """
        do {
            let raw = try await runAppleScript(source)
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed == "__NO_ARCHIVE__" {
                return failedEnvelope(integration: "mail", reason: "no_archive_mailbox")
            }
            let n = Int(trimmed) ?? 0
            return .object([
                "status": .string("completed"),
                "action": .string("archived"),
                "matched_count": .int(Int64(n)),
            ])
        } catch let AppleScriptError.permissionDenied(app) {
            return deniedEnvelope(integration: "mail", app: app)
        } catch {
            return failedEnvelope(integration: "mail", error: error)
        }
    }

    /// Delete an inbox message (Mail's `delete` moves to trash). Same input
    /// shape as `mailMarkRead`.
    /// Returns: {status, action: "deleted", matched_count}.
    public static func mailDelete(input: [String: JSONValue]) async throws -> JSONValue {
        guard let subject = inputString(input["subject"]), !subject.isEmpty else {
            return failedEnvelope(integration: "mail", reason: "missing_subject")
        }
        let sender = inputString(input["sender"])
        let subjectAS = escapeForAppleScript(subject)
        let whereClause = Self.mailMatchWhereClause(subjectAS: subjectAS, sender: sender)
        let source = """
        tell application "Mail"
            set hits to (messages of inbox whose \(whereClause))
            set n to count of hits
            repeat with msg in hits
                delete msg
            end repeat
            return n as string
        end tell
        """
        do {
            let raw = try await runAppleScript(source)
            let n = Int(raw.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
            return .object([
                "status": .string("completed"),
                "action": .string("deleted"),
                "matched_count": .int(Int64(n)),
            ])
        } catch let AppleScriptError.permissionDenied(app) {
            return deniedEnvelope(integration: "mail", app: app)
        } catch {
            return failedEnvelope(integration: "mail", error: error)
        }
    }

    /// Reply to a thread. Required: "subject" (the message to reply to),
    /// "body". Optional: "sender" for disambiguation, "reply_all" (bool,
    /// default false).
    /// Returns: {status, action: "sent_reply", subject}.
    public static func mailReply(input: [String: JSONValue]) async throws -> JSONValue {
        guard let subject = inputString(input["subject"]), !subject.isEmpty else {
            return failedEnvelope(integration: "mail", reason: "missing_subject")
        }
        guard let body = inputString(input["body"]), !body.isEmpty else {
            return failedEnvelope(integration: "mail", reason: "missing_body")
        }
        let sender = inputString(input["sender"])
        let replyAll: Bool
        switch input["reply_all"] {
        case .bool(let b): replyAll = b
        case .string(let s): replyAll = ["true", "1", "yes"].contains(s.lowercased())
        case .int(let i): replyAll = i != 0
        default: replyAll = false
        }
        let subjectAS = escapeForAppleScript(subject)
        let bodyAS = escapeForAppleScript(body)
        let whereClause = Self.mailMatchWhereClause(subjectAS: subjectAS, sender: sender)
        let replyAllPhrase = replyAll ? "with reply to all" : "without reply to all"
        let source = """
        tell application "Mail"
            set hits to (messages of inbox whose \(whereClause))
            if (count of hits) is 0 then return "0"
            set originalMsg to first item of hits
            set replyMsg to reply originalMsg opening window false \(replyAllPhrase)
            tell replyMsg
                set content to "\(bodyAS)"
                send
            end tell
            return "1"
        end tell
        """
        do {
            let raw = try await runAppleScript(source)
            let sent = (Int(raw.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0) > 0
            if !sent {
                return failedEnvelope(integration: "mail", reason: "no_matching_message")
            }
            return .object([
                "status": .string("completed"),
                "action": .string("sent_reply"),
                "subject": .string(subject),
            ])
        } catch let AppleScriptError.permissionDenied(app) {
            return deniedEnvelope(integration: "mail", app: app)
        } catch {
            return failedEnvelope(integration: "mail", error: error)
        }
    }

    /// Build the AppleScript `whose` predicate for Mail message lookup —
    /// subject is required, sender is optional. Inputs MUST already be
    /// escapeForAppleScript'd.
    private static func mailMatchWhereClause(subjectAS: String, sender: String?) -> String {
        if let s = sender, !s.isEmpty {
            let senderAS = escapeForAppleScript(s)
            return "(subject is \"\(subjectAS)\") and (sender contains \"\(senderAS)\")"
        }
        return "subject is \"\(subjectAS)\""
    }
}
