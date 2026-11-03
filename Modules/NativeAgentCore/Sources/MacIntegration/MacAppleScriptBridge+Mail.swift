import AuthoredCapabilities
import Foundation
import AppKit
import SQLite3
import PersistenceCore
// Blueprint: | `MacAppleScriptBridge+Mail.swift` | `MacAppleScriptBridge`: Mail reads and mutations, distinct compose/target refusals and exact reply-result decoding with unknown-effect reconciliation |

extension MacAppleScriptBridge {
    // MARK: MAIL

    /// List recent inbox or sent metadata. Input: "limit" (default 10, max 50).
    /// Returns: {status, count, messages: [{subject, sender, date, snippet}]}
    public static func mailListRecent(input: [String: JSONValue]) async throws -> JSONValue {
        try await mailWorkspaceRead(input: input)
    }

    /// Search mailbox pages by subject/sender fragments (OR) and index filters.
    /// Returns: same shape as mailListRecent.
    public static func mailSearch(input: [String: JSONValue]) async throws -> JSONValue {
        let query = inputStringArray(input["query"]).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard (input["query"] == nil || !query.isEmpty), query.allSatisfy({ !$0.isEmpty }) else {
            return failedEnvelope(integration: "mail", reason: "missing_query")
        }
        return try await mailWorkspaceRead(input: input, query: query)
    }

    /// Send mail via Mail.app. Required: "to" (string or array), "subject", "body".
    /// Optional: "cc", "bcc".
    /// Returns: {status, action: "sent", to, subject}.
    public static func mailSend(input: [String: JSONValue]) async throws -> JSONValue {
        try await mailCompose(input: input, send: true)
    }

    private static func mailCompose(input: [String: JSONValue], send: Bool) async throws -> JSONValue {
        let toList = inputStringArray(input["to"])
        guard !toList.isEmpty else {
            return failedEnvelope(integration: "mail", reason: "missing_to")
        }
        guard let subject = input["subject"]?.scalarText else {
            return failedEnvelope(integration: "mail", reason: "missing_compose_subject")
        }
        guard let body = input["body"]?.scalarText else {
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
        let finish = send ? """
            set sendOK to send newMsg
            if sendOK is true then return "sent"
            return "refused"
            """ : mailSaveDraft("newMsg")

        let source = """
        tell application "__NativeAgentApp__"
            \(send ? "" : "set priorDraftIDs to id of every message of drafts mailbox")
            set newMsg to make new outgoing message with properties {subject:"\(subjectAS)", content:"\(bodyAS)", visible:false}
            tell newMsg
                \(recipientsBlock)
            end tell
            \(finish)
        end tell
        """
        do {
            let raw = try await runAppleScript(source, bundleID: "com.apple.mail").trimmingCharacters(in: .whitespacesAndNewlines)
            if !send { return mailDraftResult(raw, input: input) }
            guard raw == "sent" else { return failedEnvelope(integration: "mail", reason: "mail_refused_send") }
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

    /// One bounded job over selected identities. Keep completed receipts when
    /// cancellation or an uncertain script stops the remaining work; never replay.
    public static func mailBatch(input: [String: JSONValue], effects: Bool) async -> JSONValue {
        let markReadOnly = effects && input["messages"] != nil
        let key = markReadOnly ? "messages" : "items"
        guard Set(input.keys).subtracting(["__session_id"]) == [key], case .array(let items)? = input[key],
              (1...(markReadOnly ? 50 : 10)).contains(items.count) else {
            return failedEnvelope(integration: "mail", reason: "invalid_mail_batch")
        }
        let deadline = Date().addingTimeInterval(45)
        var receipts: [JSONValue] = [], seen: Set<[String]> = [], stopped = false
        let identityKeys = MailReadLocator.fields.union(["name"])
        let allowed = identityKeys.union(effects ? ["mark_read", "flagged", "archive"] : ["body_offset"])
        for (index, item) in items.enumerated() {
            var receipt: [String: JSONValue] = ["index": .int(Int64(index))]
            guard case .object(var row) = item else {
                receipt["status"] = .string("failed"); receipt["reason"] = .string("invalid_message_locator")
                receipts.append(.object(receipt)); continue
            }
            if markReadOnly {
                row = row.filter { identityKeys.contains($0.key) && $0.key != "name" }
                row["mark_read"] = .bool(true)
            }
            if let bindingError = row["binding_error"] {
                receipt["status"] = .string("failed"); receipt["reason"] = .string("invalid_mail_batch_item")
                receipt["detail"] = bindingError
                receipts.append(.object(receipt)); continue
            }
            if !effects, row["expected_message_id"] == nil { row["expected_message_id"] = .string("") }
            receipt.merge(row.filter { identityKeys.contains($0.key) }) { _, new in new }
            receipt["requested"] = .object(row.filter { ["mark_read", "flagged", "archive", "body_offset"].contains($0.key) })
            let scope = row["scope"] ?? .string("inbox")
            let validOffset: Bool = if let offset = row["body_offset"] {
                if case .int(let n) = offset { (0...2_000_000).contains(n) } else { false }
            } else { true }
            let validActions = ["mark_read", "archive"].allSatisfy { row[$0] == nil || row[$0] == .bool(true) }
                && (row["flagged"] == nil || row["flagged"] == .bool(true) || row["flagged"] == .bool(false))
                && ["mark_read", "flagged", "archive"].contains { row[$0] != nil }
            guard Set(row.keys).isSubset(of: allowed),
                  case .int(let id)? = row["message_id"], id > 0,
                  case .string? = row["expected_message_id"],
                  case .string(let account)? = row["expected_account"], !account.isEmpty,
                  row["name"] == nil || (row["name"]?.scalarText.map { $0.hasPrefix("mail.") && $0.count <= 32 } ?? false),
                  let locator = MailReadLocator.parse(row, allowMissingMessageID: !effects), locator.account == account,
                  (scope == .string("inbox") || (!effects && scope == .string("sent"))),
                  validOffset, !effects || validActions else {
                receipt["status"] = .string("failed"); receipt["reason"] = .string("invalid_mail_batch_item")
                receipts.append(.object(receipt)); continue
            }
            let identity = [String(id), account, scope == .string("sent") ? "sent" : "inbox"]
            guard seen.insert(identity).inserted else {
                receipt["status"] = .string("failed"); receipt["reason"] = .string("duplicate_mail_batch_item")
                receipts.append(.object(receipt)); continue
            }
            receipt["scope"] = scope
            if stopped || Task.isCancelled || Date() >= deadline {
                stopped = true
                receipt["status"] = .string("not_attempted")
                receipt["reason"] = .string(Task.isCancelled ? "cancelled" : "batch_stopped")
            } else if effects {
                var actions: [String: JSONValue] = [:]
                for action in ["mark_read", "flagged", "archive"] {
                    guard let value = row[action] else { continue }
                    if stopped || Task.isCancelled || Date() >= deadline {
                        stopped = true
                        actions[action] = .object(["status": .string("not_attempted")])
                        continue
                    }
                    let result = await mailBatchMutation(locator: locator, action: action, value: value)
                    actions[action] = result
                    if case .object(let outcome) = result,
                       outcome["status"] == .string("outcome_unknown") || outcome["status"] == .string("denied") || Task.isCancelled {
                        stopped = true
                    }
                    // A refused action does not authorize later effects on this item.
                    if case .object(let outcome) = result, outcome["status"] != .string("completed") {
                        for remaining in ["mark_read", "flagged", "archive"] where row[remaining] != nil && actions[remaining] == nil {
                            actions[remaining] = .object(["status": .string("not_attempted")])
                        }
                        break
                    }
                }
                receipt["actions"] = .object(actions)
                let states = actions.values.compactMap { if case .object(let value) = $0 { value["status"] } else { nil } }
                receipt["status"] = .string(states.allSatisfy { $0 == .string("completed") } ? "completed"
                    : states.contains(.string("outcome_unknown")) ? "outcome_unknown"
                    : states.contains(.string("completed")) ? "partial" : "failed")
            } else {
                do {
                    let body = try mailFileRead(input: row, batch: true)
                    receipt.merge(body) { _, new in new }
                    receipt["status"] = .string("completed")
                } catch let back as SkillRunContext.HandBack {
                    return SkillRunContext.handBack(back.why)
                } catch let AppleScriptError.permissionDenied(app) {
                    if case .object(let denied) = deniedEnvelope(integration: "mail", app: app) { receipt.merge(denied) { _, new in new } }
                    stopped = true
                } catch {
                    receipt["status"] = .string("failed"); receipt["error"] = .string(error.localizedDescription)
                    stopped = true
                }
            }
            receipts.append(.object(receipt))
        }
        let completed = receipts.filter { if case .object(let row) = $0 { row["status"] == .string("completed") } else { false } }.count
        let uncertain = receipts.contains { if case .object(let row) = $0 { row["status"] == .string("outcome_unknown") } else { false } }
        return .object(["status": .string(uncertain ? "outcome_unknown" : completed == items.count ? "completed" : "partial"),
            "integration": .string("mail"), "count": .int(Int64(items.count)), "completed_count": .int(Int64(completed)),
            "items": .array(receipts)])
    }

    static func mailBatchAccountScope(_ account: String, scope: String) -> String {
        let box = scope == "sent" ? "sent mailbox" : "inbox"
        return """
        set targetBox to missing value
        set matchingBoxes to 0
        repeat with mb in (mailboxes of \(box))
            if ((name of account of mb) as text) is "\(escapeForAppleScript(account))" then
                set targetBox to contents of mb
                set matchingBoxes to matchingBoxes + 1
            end if
        end repeat
        if matchingBoxes is not 1 then return "__MESSAGE_CHANGED__"
        """
    }

    private static func mailBatchMutation(locator: MailReadLocator, action: String, value: JSONValue) async -> JSONValue {
        guard let account = locator.account else { return failedEnvelope(integration: "mail", reason: "invalid_message_locator") }
        let body: String
        switch action {
        case "mark_read": body = """
            set read status of msg to true
            if (read status of msg) is not true then return "__OUTCOME_UNKNOWN__"
            """
        case "flagged": body = """
            set flagged status of msg to \(value == .bool(true) ? "true" : "false")
            if (flagged status of msg) is not \(value == .bool(true) ? "true" : "false") then return "__OUTCOME_UNKNOWN__"
            """
        default: body = """
            set archiveBox to missing value
            try
                set archiveBox to mailbox "Archive" of account of mailbox of msg
            end try
            if archiveBox is missing value then return "__NO_ARCHIVE__"
            move msg to archiveBox
            if (mailbox of msg) is not archiveBox then return "__OUTCOME_UNKNOWN__"
            """
        }
        let source = """
        tell application "__NativeAgentApp__"
            try
                with timeout of 4 seconds
                    \(mailBatchAccountScope(account, scope: "inbox"))
                    \(mailExactLookup(locator, into: "hits"))
                    \(mailIdentityCheck(locator, list: "hits", fail: "__MESSAGE_CHANGED__"))
                end timeout
            on error errText number errNum
                if errNum is -1712 then return "__LOOKUP_TIMED_OUT__"
                error errText number errNum
            end try
            set msg to item 1 of hits
            try
                with timeout of 4 seconds
                    \(body)
                end timeout
            on error
                return "__OUTCOME_UNKNOWN__"
            end try
            return "1|"
        end tell
        """
        do {
            let raw = try await runAppleScript(source, bundleID: "com.apple.mail")
            if raw == "__MESSAGE_CHANGED__" { return failedEnvelope(integration: "mail", reason: "message_changed_or_moved_refresh_inbox") }
            return mailMutationResult(raw, action: action)
        } catch is CancellationError {
            return .object(["status": .string("not_attempted"), "reason": .string("cancelled")])
        } catch let back as SkillRunContext.HandBack {
            return SkillRunContext.handBack(back.why)
        } catch let AppleScriptError.permissionDenied(app) {
            return deniedEnvelope(integration: "mail", app: app)
        } catch {
            let error = error as NSError
            return .object(["status": .string(error.domain == "NativeAgentAppleScript" && error.code == -1001 ? "not_attempted" : "outcome_unknown"),
                "error": .string(error.localizedDescription)])
        }
    }

    /// Mark read, archive or delete by message_id + expected_message_id from mail_list_recent,
    /// or by subject and optional sender; archive and delete refuse multiple matches.
    /// Returns: {status, action, matched_count, subject}.
    public static func mailMarkRead(input: [String: JSONValue]) async throws -> JSONValue {
        if input["messages"] != nil { return await mailBatch(input: input, effects: true) }
        return await mailManage(input: input, action: "marked_read", single: false, body: """
            repeat with msg in hits
                set read status of msg to true
            end repeat
            """)
    }

    /// Archive one inbox message (move to the Archive mailbox); "no_archive_mailbox" when none exists.
    public static func mailArchive(input: [String: JSONValue]) async throws -> JSONValue {
        await mailManage(input: input, action: "archived", single: true, body: """
            set archiveBox to missing value
            set msg to item 1 of hits
            try
                set archiveBox to mailbox "Archive" of account of mailbox of msg
            end try
            if archiveBox is missing value then return "__NO_ARCHIVE__"
            move msg to archiveBox
            """)
    }

    /// Find one inbox message through its checked Apple Event locator; lookup failure stops the mutation.
    /// Move to Trash explicitly; `delete` can be permanent under account settings.
    public static func mailDelete(input: [String: JSONValue]) async throws -> JSONValue {
        let exact = MailReadLocator.parse(input)
        if (input["message_id"] != nil || input["expected_message_id"] != nil) && exact == nil {
            return failedEnvelope(integration: "mail", reason: "invalid_message_locator")
        }
        let subject = input["subject"]?.scalarText ?? ""
        guard exact != nil || !subject.isEmpty else { return failedEnvelope(integration: "mail", reason: "missing_message_selector") }
        let moveToTrash = """
            set msg to item 1 of hits
            set trashBox to missing value
            try
                \(mailLookupCommand("set messageAccountID to id of account of mailbox of msg", deadline: "lookupDeadline"))
                \(mailLookupCommand("set trashMailboxes to mailboxes of trash mailbox", deadline: "lookupDeadline"))
                repeat with mb in trashMailboxes
                    \(mailLookupCommand("set trashAccountID to id of account of mb", deadline: "lookupDeadline"))
                    if trashAccountID is messageAccountID then
                        set trashBox to contents of mb
                        exit repeat
                    end if
                end repeat
                if trashBox is missing value then return "__NO_TRASH__"
                \(mailLookupCommand("if (mailbox of msg) is trashBox then return \"__ALREADY_TRASH__\"", deadline: "lookupDeadline"))
                if (current date) ≥ lookupDeadline then return "__LOOKUP_TIMED_OUT__"
            on error errText number errNum
                if errNum is -1712 then return "__LOOKUP_TIMED_OUT__"
                error errText number errNum
            end try
            try
                with timeout of 8 seconds
                    move msg to trashBox
                end timeout
            on error errText number errNum
                if errNum is -1712 then return "__OUTCOME_UNKNOWN__"
                error errText number errNum
            end try
            """
        return await mailManage(input: input, action: "deleted", single: true, body: moveToTrash)
    }

    private static func mailManage(input: [String: JSONValue], action: String, single: Bool, body: String) async -> JSONValue {
        let exact = MailReadLocator.parse(input)
        if (input["message_id"] != nil || input["expected_message_id"] != nil) && exact == nil { return failedEnvelope(integration: "mail", reason: "invalid_message_locator") }
        let subject = input["subject"]?.scalarText ?? ""
        guard exact != nil || !subject.isEmpty else { return failedEnvelope(integration: "mail", reason: "missing_message_selector") }
        let whereClause = exact.map { "id is \($0.id)" }
            ?? Self.mailMatchWhereClause(subjectAS: escapeForAppleScript(subject), sender: input["sender"]?.scalarText)
        let deadline = action == "deleted" ? "lookupDeadline" : nil
        let check = exact.map { mailIdentityCheck($0, list: "hits", fail: "-2", deadline: deadline) }
            ?? (single ? "if n > 1 then return \"-3|\" & (n as text)" : "")
        // The lookup is bounded (a whose-scan of a huge inbox otherwise runs on
        // Mail's ~120s default, holding the one AppleScript queue after the 15s
        // gate gave up). It runs before any change, so a timeout changed nothing.
        let source = """
        \(deadline == nil ? "" : "set lookupDeadline to (current date) + 6")
        tell application "__NativeAgentApp__"
            try
                with timeout of 8 seconds
                    \(mailAccountScope(exact?.account, deadline: deadline))
                    \(exact.map { mailExactLookup($0, into: "hits", deadline: deadline) } ?? mailLookupCommand("set hits to (messages of targetBox whose \(whereClause))", deadline: deadline))
                    set n to count of hits
                    if n is 0 then return "0"
                    \(check)
                    \(mailLookupCommand("set firstSubject to (subject of item 1 of hits) as text", deadline: deadline))
                end timeout
            on error errText number errNum
                if errNum is -1712 then return "__LOOKUP_TIMED_OUT__"
                error errText number errNum
            end try
            \(body)
            return (n as text) & "|" & firstSubject
        end tell
        """
        do {
            return mailMutationResult(try await runAppleScript(source, bundleID: "com.apple.mail"), action: action)
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
        case "__LOOKUP_TIMED_OUT__": return failedEnvelope(integration: "mail", reason: "mail_lookup_timed_out")
        case "-2": return failedEnvelope(integration: "mail", reason: action == "deleted" ? "mail_delete_target_changed" : "message_changed_or_moved_refresh_inbox")
        case "__NO_ARCHIVE__": return failedEnvelope(integration: "mail", reason: "no_archive_mailbox")
        case "__NO_TRASH__": return failedEnvelope(integration: "mail", reason: "no_trash_mailbox")
        case "__ALREADY_TRASH__": return failedEnvelope(integration: "mail", reason: "message_already_in_trash")
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
    /// Required: body. Optional: sender for subject-addressed disambiguation, reply_all (bool,
    /// default false).
    /// Returns: {status, action: "sent_reply", subject}.
    public static func mailReply(input: [String: JSONValue]) async throws -> JSONValue {
        try await mailRespond(input: input, send: true)
    }

    public static func mailDraft(input: [String: JSONValue]) async throws -> JSONValue {
        let result = try await (input["to"] != nil ? mailCompose(input: input, send: false) : mailRespond(input: input, send: false))
        guard case .object(var row) = result else { return result }
        if row["effects"] == .string("none") { row["created"] = .bool(false); return .object(row) }
        guard ["completed", "outcome_unknown", "unknown"].contains(row["status"]?.scalarText ?? "") else { return result }
        row["next_call"] = .object(["tool": .string("app"), "input": .object([
            "action": .string("mail.recent"), "args": .object(["mailbox": .string("drafts")])])])
        return .object(row)
    }

    private static func mailSaveDraft(_ message: String) -> String {
        """
        set draftSubject to subject of \(message)
        set draftRecipients to address of every to recipient of \(message)
        set draftContent to content of \(message)
        save \(message)
        set savedDraftIDs to {}
        repeat with savedMsg in (messages of drafts mailbox whose subject is draftSubject)
            if (id of savedMsg) is not in priorDraftIDs and (address of every to recipient of savedMsg) is draftRecipients then
                if (content of savedMsg) contains draftContent then set end of savedDraftIDs to id of savedMsg
            end if
        end repeat
        if (count of savedDraftIDs) is 1 then return "draft|" & ((item 1 of savedDraftIDs) as text)
        return "__DRAFT_UNCONFIRMED__"
        """
    }

    private static func mailDraftResult(_ raw: String, input: [String: JSONValue]) -> JSONValue {
        let id = raw.hasPrefix("draft|") ? Int64(raw.dropFirst(6)).flatMap { $0 > 0 ? $0 : nil } : nil
        var result: [String: JSONValue] = ["status": .string(id != nil ? "completed" : "outcome_unknown"),
            "action": .string(id != nil ? "draft_saved" : "draft_save_unconfirmed"),
            "saved_in": .string("Apple Mail → Drafts"), "account": input["expected_account"] ?? .null]
        if let id {
            result["created"] = .bool(true)
            result["draft_id"] = .string(String(id))
            result["message_id"] = .int(id)
            result["verification"] = .string("Read back a new message in Drafts with the draft's subject, recipients and content.")
        } else { result["message"] = .string("Draft creation could not be confirmed. Read Drafts before trying again.") }
        if let subject = input["subject"] { result["subject"] = subject }
        if let to = input["to"] { result["to"] = to }
        return .object(result)
    }

    private static func mailRespond(input: [String: JSONValue], send: Bool) async throws -> JSONValue {
        let exact = MailReadLocator.parse(input)
        if (input["message_id"] != nil || input["expected_message_id"] != nil) && exact == nil { return failedEnvelope(integration: "mail", reason: "invalid_message_locator") }
        let subject = input["subject"]?.scalarText ?? ""
        guard exact != nil || !subject.isEmpty else {
            return failedEnvelope(integration: "mail", reason: "missing_message_selector")
        }
        guard let body = input["body"]?.scalarText, !body.isEmpty else {
            return failedEnvelope(integration: "mail", reason: "missing_body")
        }
        let sender = input["sender"]?.scalarText
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
        let finish = send ? """
            set sendOK to send replyMsg
            if sendOK is true then return "1"
            return "-1"
            """ : mailSaveDraft("replyMsg")
        let source = """
        tell application "__NativeAgentApp__"
            \(mailAccountScope(exact?.account))
            with timeout of 8 seconds
                \(exact.map { mailExactLookup($0, into: "hits") } ?? "set hits to (messages of targetBox whose \(whereClause))")
            end timeout
            if (count of hits) is 0 then return "0"
            if (count of hits) is not 1 then return "-2"
            set originalMsg to first item of hits
            \(identityCheck)
            \(send ? "" : "set priorDraftIDs to id of every message of drafts mailbox")
            set replyMsg to reply originalMsg opening window false \(replyAllPhrase)
            tell replyMsg
                set content to "\(bodyAS)"
            end tell
            \(finish)
        end tell
        """
        do {
            let raw = try await runAppleScript(source, bundleID: "com.apple.mail").trimmingCharacters(in: .whitespacesAndNewlines)
            switch raw {
            case "-2": return failedEnvelope(integration: "mail", reason: "message_changed_or_ambiguous_refresh_inbox")
            case "0": return failedEnvelope(integration: "mail", reason: "no_matching_message")
            case "-1" where send: return failedEnvelope(integration: "mail", reason: "mail_refused_send")
            case "1" where send: break
            case "__DRAFT_UNCONFIRMED__" where !send:
                return mailDraftResult(raw, input: input)
            default:
                if !send, raw.hasPrefix("draft|"), let id = Int64(raw.dropFirst(6)), id > 0,
                   raw == "draft|\(id)" {
                    return mailDraftResult(raw, input: input)
                }
                return .object([
                    "status": .string("outcome_unknown"), "integration": .string("mail"),
                    "effects": .string("unknown"), "reason": .string("unexpected_mail_reply_result"),
                    "requested_message": .object(input.filter { MailReadLocator.fields.union(["subject", "sender"]).contains($0.key) }),
                    "action": .string(send ? "sent_reply" : "draft_save_unconfirmed"),
                    "message": .string("Mail returned an unrecognized reply result. Check the original conversation and \(send ? "Sent and Outbox" : "Drafts") before trying again."),
                ])
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
