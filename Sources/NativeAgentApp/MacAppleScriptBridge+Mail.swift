import Foundation
import AppKit
import SQLite3
import PersistenceCore

extension MacAppleScriptBridge {
    // MARK: MAIL

    /// List recent inbox or sent metadata. Input: "limit" (default 10, max 50).
    /// Returns: {status, count, messages: [{subject, sender, date, snippet}]}
    public static func mailListRecent(input: [String: JSONValue]) async throws -> JSONValue {
        try await mailWorkspaceRead(input: input)
    }

    /// Search mailbox pages by subject/sender fragment. Input: "query" (required),
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

    /// One bounded job over selected identities. Keep completed receipts when
    /// cancellation or an uncertain script stops the remaining work; never replay.
    static func mailBatch(input: [String: JSONValue], effects: Bool) async -> JSONValue {
        guard Set(input.keys).subtracting(["__session_id"]) == ["items"], case .array(let items)? = input["items"],
              (1...10).contains(items.count) else {
            return failedEnvelope(integration: "mail", reason: "invalid_mail_batch")
        }
        let deadline = Date().addingTimeInterval(45)
        var receipts: [JSONValue] = [], seen: Set<[String]> = [], stopped = false
        let identityKeys: Set<String> = ["name", "message_id", "expected_message_id", "expected_account", "position", "scope"]
        let allowed = identityKeys.union(effects ? ["mark_read", "flagged", "archive"] : ["body_offset"])
        for (index, item) in items.enumerated() {
            var receipt: [String: JSONValue] = ["index": .int(Int64(index))]
            guard case .object(var row) = item else {
                receipt["status"] = .string("failed"); receipt["reason"] = .string("invalid_message_locator")
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
                  row["name"] == nil || (inputString(row["name"]).map { $0.hasPrefix("mail.") && $0.count <= 32 } ?? false),
                  let locator = mailExactLocator(row, allowMissingMessageID: !effects), locator.account == account,
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
                    let raw = try await runAppleScript(mailWorkspaceScript(input: row, batch: true))
                    let messages = parseMailWorkspaceRecords(raw, detail: true)
                    if let setup = readSetupEnvelope(raw: raw, integration: "mail"), case .object(let result) = setup {
                        receipt.merge(result) { _, new in new }; stopped = true
                    } else if raw == "__MESSAGE_CHANGED__" {
                        receipt["status"] = .string("failed"); receipt["reason"] = .string("message_changed_or_moved_refresh_inbox")
                    } else if messages.count == 1, case .object(let body) = messages[0] {
                        receipt.merge(body) { _, new in new }; receipt["status"] = .string("completed")
                    } else {
                        receipt["status"] = .string("failed"); receipt["reason"] = .string("invalid_mail_read_receipt")
                    }
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

    private static func mailBatchMutation(locator: MailLocator, action: String, value: JSONValue) async -> JSONValue {
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
        tell application "Mail"
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
            let raw = try await runAppleScript(source)
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
            set msg to item 1 of hits
            try
                set archiveBox to mailbox "Archive" of account of mailbox of msg
            end try
            if archiveBox is missing value then return "__NO_ARCHIVE__"
            move msg to archiveBox
            """)
    }

    /// Find one inbox message via AppleScript, using the index after a miss or lookup timeout.
    /// Move to Trash explicitly; `delete` can be permanent under account settings.
    public static func mailDelete(input: [String: JSONValue]) async throws -> JSONValue {
        let exact = mailExactLocator(input)
        if (input["message_id"] != nil || input["expected_message_id"] != nil) && exact == nil {
            return failedEnvelope(integration: "mail", reason: "invalid_message_locator")
        }
        let subject = inputString(input["subject"]) ?? ""
        guard exact != nil || !subject.isEmpty else { return failedEnvelope(integration: "mail", reason: "missing_subject") }
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
        let inboxResult = await mailManage(input: input, action: "deleted", single: true, body: moveToTrash)
        guard case .object(let result) = inboxResult,
              case .string(let reason)? = result["reason"],
              reason == "no_matching_message" || reason == "mail_lookup_timed_out" else { return inboxResult }
        var expectedAccountID = ""
        if let account = exact?.account {
            let source = """
            with timeout of 8 seconds
            tell application "Mail"
                set sourceAccounts to (accounts whose name is "\(escapeForAppleScript(account))")
                if (count of sourceAccounts) is not 1 then return ""
                return (id of item 1 of sourceAccounts) as text
            end tell
            end timeout
            """
            do { expectedAccountID = try await runAppleScript(source).trimmingCharacters(in: .whitespacesAndNewlines) }
            catch let AppleScriptError.permissionDenied(app) { return deniedEnvelope(integration: "mail", app: app) }
            catch { return failedEnvelope(integration: "mail", error: error) }
            guard !expectedAccountID.isEmpty else { return mailMutationResult("-2", action: "deleted") }
        }
        guard let database = mailIndexDatabase() else { return failedEnvelope(integration: "mail", reason: "mail_index_unavailable") }
        defer { sqlite3_close(database) }
        guard sqlite3_create_function_v2(database, "mail_sender_text", 2, SQLITE_UTF8 | SQLITE_DETERMINISTIC, nil, { context, _, values in
            guard let values else { sqlite3_result_null(context); return }
            let comment = sqlite3_value_text(values[0]).map { String(cString: $0) } ?? ""
            let address = sqlite3_value_text(values[1]).map { String(cString: $0) } ?? ""
            let sender = MacAppleScriptBridge.mailSenderText(comment: comment, address: address)
            sqlite3_result_text(context, sender, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        }, nil, nil, nil) == SQLITE_OK else {
            return failedEnvelope(integration: "mail", reason: "mail_index_unavailable")
        }
        let sender = inputString(input["sender"]) ?? ""
        let predicate = exact == nil
            ? "(coalesce(m.subject_prefix, '') || coalesce(s.subject, '')) = ?1 COLLATE NOCASE AND (?2 = '' OR instr(lower(mail_sender_text(a.comment, a.address)), lower(?2)) > 0)"
            : "g.message_id_header IN (?2, ?3)"
        let order = exact == nil ? "" : "ORDER BY CASE WHEN m.ROWID = ?1 THEN 0 ELSE 1 END"
        let sql = """
        SELECT m.ROWID, g.message_id_header, b.url FROM messages m
        LEFT JOIN subjects s ON s.ROWID = m.subject LEFT JOIN addresses a ON a.ROWID = m.sender
        LEFT JOIN message_global_data g ON g.ROWID = m.global_message_id
        JOIN mailboxes b ON b.ROWID = m.mailbox WHERE m.deleted = 0 AND \(predicate)
        AND (?4 = '' OR substr(b.url, instr(b.url, '://') + 3, length(?4) + 1) = (?4 || '/') COLLATE NOCASE)
        \(order) LIMIT 2
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            return failedEnvelope(integration: "mail", reason: "mail_index_unavailable")
        }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 4, expectedAccountID, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        if let exact {
            sqlite3_bind_int64(statement, 1, exact.id)
            sqlite3_bind_text(statement, 2, exact.messageID, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            sqlite3_bind_text(statement, 3, "<\(exact.messageID)>", -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        } else {
            sqlite3_bind_text(statement, 1, subject, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            sqlite3_bind_text(statement, 2, sender, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        }
        var targets: [(id: Int64, messageID: String, url: String)] = []
        var step = sqlite3_step(statement)
        while step == SQLITE_ROW {
            func text(_ column: Int32) -> String { sqlite3_column_text(statement, column).map { String(cString: $0) } ?? "" }
            var messageID = text(1)
            if messageID.hasPrefix("<"), messageID.hasSuffix(">") { messageID = String(messageID.dropFirst().dropLast()) }
            targets.append((sqlite3_column_int64(statement, 0), messageID, text(2)))
            step = sqlite3_step(statement)
        }
        guard step == SQLITE_DONE else { return failedEnvelope(integration: "mail", reason: "mail_index_unavailable") }
        guard let target = targets.first else { return failedEnvelope(integration: "mail", reason: "mail_delete_no_match") }
        guard targets.count == 1 || target.id == exact?.id else {
            return .object(["status": .string("failed"), "integration": .string("mail"),
                "reason": .string("several_messages_match"),
                "message": .string("Several indexed messages match, so nothing changed. Use a fresh message_id and expected_message_id for one message.")])
        }
        guard let url = URL(string: target.url), let accountID = url.host, !url.path.isEmpty else {
            return failedEnvelope(integration: "mail", reason: "invalid_message_locator")
        }
        var identityCheck = "if (id of item 1 of hits) is not \(target.id) then return \"-2\""
        let expectedID = exact?.messageID ?? target.messageID
        if !expectedID.isEmpty {
            identityCheck += "\nif ((message id of item 1 of hits) as text) is not \"\(escapeForAppleScript(expectedID))\" then return \"-2\""
        }
        if let account = exact?.account {
            identityCheck += "\nif ((name of account of mailbox of item 1 of hits) as text) is not \"\(escapeForAppleScript(account))\" then return \"-2\""
        }
        let subjectCheck = exact == nil ? """
            if ((subject of item 1 of hits) as text) is not "\(escapeForAppleScript(subject))" then return "-2"
            \(sender.isEmpty ? "" : "if ((sender of item 1 of hits) as text) does not contain \"\(escapeForAppleScript(sender))\" then return \"-2\"")
            """ : ""
        let sourceBox = url.scheme == "local"
            ? "set targetBox to mailbox \"\(escapeForAppleScript(String(url.path.dropFirst())))\""
            : """
            set sourceAccounts to (accounts whose id is "\(escapeForAppleScript(accountID))")
            if (count of sourceAccounts) is not 1 then return "-2"
            set targetBox to mailbox "\(escapeForAppleScript(String(url.path.dropFirst())))" of item 1 of sourceAccounts
            """
        let source = """
        set lookupDeadline to (current date) + 6
        with timeout of 8 seconds
        tell application "Mail"
            try
                \(sourceBox.components(separatedBy: "\n").map { mailLookupCommand($0, deadline: "lookupDeadline") }.joined(separator: "\n"))
                \(mailLookupCommand("set hits to {message id \(target.id) of targetBox}", deadline: "lookupDeadline"))
                \(identityCheck.components(separatedBy: "\n").map { mailLookupCommand($0, deadline: "lookupDeadline") }.joined(separator: "\n"))
                \(subjectCheck.components(separatedBy: "\n").filter { !$0.isEmpty }.map { mailLookupCommand($0, deadline: "lookupDeadline") }.joined(separator: "\n"))
                \(mailLookupCommand("set firstSubject to (subject of item 1 of hits) as text", deadline: "lookupDeadline"))
            on error errText number errNum
                if errNum is -1712 then return "__LOOKUP_TIMED_OUT__"
                error errText number errNum
            end try
            \(moveToTrash)
            return "1|" & firstSubject
        end tell
        end timeout
        """
        do { return mailMutationResult(try await runAppleScript(source), action: "deleted") }
        catch let AppleScriptError.permissionDenied(app) { return deniedEnvelope(integration: "mail", app: app) }
        catch { return failedEnvelope(integration: "mail", error: error) }
    }

    private static func mailManage(input: [String: JSONValue], action: String, single: Bool, body: String) async -> JSONValue {
        let exact = mailExactLocator(input)
        if (input["message_id"] != nil || input["expected_message_id"] != nil) && exact == nil { return failedEnvelope(integration: "mail", reason: "invalid_message_locator") }
        let subject = inputString(input["subject"]) ?? ""
        guard exact != nil || !subject.isEmpty else { return failedEnvelope(integration: "mail", reason: "missing_subject") }
        let whereClause = exact.map { "id is \($0.id)" }
            ?? Self.mailMatchWhereClause(subjectAS: escapeForAppleScript(subject), sender: inputString(input["sender"]))
        let deadline = action == "deleted" ? "lookupDeadline" : nil
        let check = exact.map { mailIdentityCheck($0, list: "hits", fail: "-2", deadline: deadline) }
            ?? (single ? "if n > 1 then return \"-3|\" & (n as text)" : "")
        // The lookup is bounded (a whose-scan of a huge inbox otherwise runs on
        // Mail's ~120s default, holding the one AppleScript queue after the 15s
        // gate gave up). It runs before any change, so a timeout changed nothing.
        let source = """
        \(deadline == nil ? "" : "set lookupDeadline to (current date) + 6")
        tell application "Mail"
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
    /// Required: body. Optional: sender for legacy disambiguation, reply_all (bool,
    /// default false).
    /// Returns: {status, action: "sent_reply", subject}.
    public static func mailReply(input: [String: JSONValue]) async throws -> JSONValue {
        let exact = mailExactLocator(input)
        if (input["message_id"] != nil || input["expected_message_id"] != nil) && exact == nil { return failedEnvelope(integration: "mail", reason: "invalid_message_locator") }
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
