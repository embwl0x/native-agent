import Foundation
import AppKit
import PersistenceCore

extension MacAppleScriptBridge {
    // MARK: MAIL

    /// List the N most recent messages in inbox. Input: "limit" (default 10, max 50).
    /// Returns: {status, count, messages: [{subject, sender, date, snippet}]}
    public static func mailListRecent(input: [String: JSONValue]) async throws -> JSONValue {
        try await mailWorkspaceRead(input: input)
    }

    /// Search inbox by subject/sender/body fragment. Input: "query" (required),
    /// "limit" (default 10, max 50).
    /// Returns: same shape as mailListRecent.
    public static func mailSearch(input: [String: JSONValue]) async throws -> JSONValue {
        guard let query = inputString(input["query"]), !query.isEmpty else {
            return failedEnvelope(integration: "mail", reason: "missing_query")
        }
        return try await mailWorkspaceRead(input: input, query: query)
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
            set sendOK to send newMsg
            if sendOK is true then
                return "sent"
            end if
            return "refused"
        end tell
        """
        do {
            // 2026-09-06: Mail's `send` returns a boolean and this discarded it,
            // so a message Mail refused (no account able to send from, offline
            // outbox rejection) was reported to the operator as sent.
            let raw = try await runAppleScript(source).trimmingCharacters(in: .whitespacesAndNewlines)
            guard raw == "sent" else {
                return failedEnvelope(integration: "mail", reason: "mail_refused_send")
            }
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

    /// Mark read, archive or delete: the exact message (message_id +
    /// expected_message_id from mail_list_recent), or by subject (and optional
    /// sender). Archive and delete act on one message only: several subject
    /// matches are refused, never all moved (2026-09-24).
    /// Returns: {status, action, matched_count, subject}.
    public static func mailMarkRead(input: [String: JSONValue]) async throws -> JSONValue {
        await mailManage(input: input, action: "marked_read", single: false, body: """
            repeat with msg in hits
                set read status of msg to true
            end repeat
            """)
    }

    /// Archive one inbox message (move to the Archive mailbox); "no_archive_mailbox" when none exists.
    public static func mailArchive(input: [String: JSONValue]) async throws -> JSONValue {
        await mailManage(input: input, action: "archived", single: true, body: """
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
            """)
    }

    /// Delete one inbox message (Mail's `delete` moves it to Trash).
    public static func mailDelete(input: [String: JSONValue]) async throws -> JSONValue {
        await mailManage(input: input, action: "deleted", single: true, body: """
            repeat with msg in hits
                delete msg
            end repeat
            """)
    }

    private static func mailManage(input: [String: JSONValue], action: String, single: Bool, body: String) async -> JSONValue {
        let exact = mailExactLocator(input)
        if input["message_id"] != nil && exact == nil { return failedEnvelope(integration: "mail", reason: "invalid_message_locator") }
        let subject = inputString(input["subject"]) ?? ""
        guard exact != nil || !subject.isEmpty else { return failedEnvelope(integration: "mail", reason: "missing_subject") }
        let whereClause = exact.map { "id is \($0.id)" }
            ?? Self.mailMatchWhereClause(subjectAS: escapeForAppleScript(subject), sender: inputString(input["sender"]))
        let check = exact.map { mailIdentityCheck($0, list: "hits", fail: "-2") }
            ?? (single ? "if n > 1 then return \"-3|\" & (n as text)" : "")
        // The lookup is bounded (a whose-scan of a huge inbox otherwise runs on
        // Mail's ~120s default, holding the one AppleScript queue after the 15s
        // gate gave up). It runs before any change, so a timeout changed nothing.
        let source = """
        tell application "Mail"
            \(mailAccountScope(exact?.account))
            with timeout of 8 seconds
                \(exact.map { mailExactLookup($0, into: "hits") } ?? "set hits to (messages of targetBox whose \(whereClause))")
            end timeout
            set n to count of hits
            if n is 0 then return "0"
            \(check)
            set firstSubject to (subject of item 1 of hits) as text
            \(body)
            return (n as text) & "|" & firstSubject
        end tell
        """
        do {
            return mailMutationResult(try await runAppleScript(source), action: action)
        } catch let AppleScriptError.permissionDenied(app) {
            return deniedEnvelope(integration: "mail", app: app)
        } catch {
            return failedEnvelope(integration: "mail", error: error)
        }
    }

    static func mailMutationResult(_ raw: String, action: String) -> JSONValue {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        switch text {
        case "0": return failedEnvelope(integration: "mail", reason: "no_matching_message")
        case "-2": return failedEnvelope(integration: "mail", reason: "message_changed_or_moved_refresh_inbox")
        case "__NO_ARCHIVE__": return failedEnvelope(integration: "mail", reason: "no_archive_mailbox")
        default: break
        }
        let parts = text.split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false)
        if parts.first == "-3", parts.count == 2 {
            return .object(["status": .string("failed"), "integration": .string("mail"), "reason": .string("several_messages_match"),
                "message": .string("\(parts[1]) inbox messages have that subject, so nothing changed. Pass the message_id and expected_message_id from mail_list_recent, or add sender.")])
        }
        guard let count = Int64(parts.first ?? ""), count > 0 else {
            return .object([
                "status": .string("outcome_unknown"), "action": .string(action),
                "message": .string("I couldn't confirm what changed. Check Mail before trying again."),
            ])
        }
        return .object(["status": .string("completed"), "action": .string(action), "matched_count": .int(count),
                        "subject": .string(parts.count == 2 ? String(parts[1]) : "")])
    }

    /// Reply by exact inbox/message identity, or a unique subject/sender.
    /// Required: body. Optional: sender for legacy disambiguation, reply_all (bool,
    /// default false).
    /// Returns: {status, action: "sent_reply", subject}.
    public static func mailReply(input: [String: JSONValue]) async throws -> JSONValue {
        let exact = mailExactLocator(input)
        if input["message_id"] != nil && exact == nil { return failedEnvelope(integration: "mail", reason: "invalid_message_locator") }
        let subject = inputString(input["subject"]) ?? ""
        guard exact != nil || !subject.isEmpty else {
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
        let whereClause = exact.map { "id is \($0.id)" } ?? Self.mailMatchWhereClause(subjectAS: subjectAS, sender: sender)
        let identityCheck = exact.map { mailIdentityCheck($0, list: "hits", fail: "-2") } ?? ""
        let replyAllPhrase = replyAll ? "with reply to all" : "without reply to all"
        let source = """
        tell application "Mail"
            \(mailAccountScope(exact?.account))
            with timeout of 8 seconds
                \(exact.map { mailExactLookup($0, into: "hits") } ?? "set hits to (messages of targetBox whose \(whereClause))")
            end timeout
            if (count of hits) is 0 then return "0"
            if (count of hits) is not 1 then return "-2"
            set originalMsg to first item of hits
            \(identityCheck)
            set replyMsg to reply originalMsg opening window false \(replyAllPhrase)
            tell replyMsg
                set content to "\(bodyAS)"
                set sendOK to send
            end tell
            if sendOK is true then
                return "1"
            end if
            return "-1"
        end tell
        """
        do {
            // 2026-09-06: `send` returns a boolean and the reply path discarded
            // it too, so "1" meant only "a matching message was found", never
            // "Mail sent it". -1 is now Mail's own refusal.
            let raw = try await runAppleScript(source)
            let code = Int(raw.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
            if code == -2 { return failedEnvelope(integration: "mail", reason: "message_changed_or_ambiguous_refresh_inbox") }
            if code < 0 {
                return failedEnvelope(integration: "mail", reason: "mail_refused_send")
            }
            if code == 0 {
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
