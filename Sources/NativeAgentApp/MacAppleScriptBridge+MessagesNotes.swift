import Foundation
import AppKit
import PersistenceCore

extension MacAppleScriptBridge {
    // MARK: MESSAGES

    /// AppleScript owns chat identity/participants. An exact selected chat can
    /// additionally expose bounded local history when macOS permits that read.
    public static func messagesRecentThreads(input: [String: JSONValue]) async throws -> JSONValue {
        let limit = clampedInt(input["limit"], defaultValue: 10, min: 1, max: 30)
        let threadID = inputString(input["thread_id"])
        let before: Int64?
        if let value = input["before_message_id"] {
            guard threadID != nil, case .int(let id) = value, id > 0 else {
                return failedEnvelope(integration: "messages", reason: "invalid_history_cursor")
            }
            before = id
        } else { before = nil }
        let selection = threadID.map { "set chatList to every chat whose id is \"\(escapeForAppleScript($0))\"" }
            ?? "set chatList to chats"
        let source = """
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
        tell application "Messages"
            \(selection)
            set output to ((count of chatList) as text) & linefeed
            set countChat to 0
            repeat with c in chatList
                if countChat ≥ \(limit) then exit repeat
                my checkReadDeadline()
                set chatID to (id of c) as text
                set chatName to ""
                try
                    set observedName to name of c
                    if observedName is not missing value then set chatName to observedName as text
                end try
                set people to ""
                repeat with p in participants of c
                    my checkReadDeadline()
                    set personHandle to (handle of p) as text
                    set personName to ""
                    try
                        set observedName to name of p
                        if observedName is not missing value then set personName to observedName as text
                    end try
                    set people to people & (my encoded(personHandle)) & ":" & (my encoded(personName)) & ","
                end repeat
                set output to output & (my encoded(chatID)) & "|" & (my encoded(chatName)) & "|" & people & linefeed
                set countChat to countChat + 1
            end repeat
            return output
        end tell
        end timeout
        """
        do {
            let raw = try await runAppleScript(source)
            let lines = raw.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
            guard let first = lines.first, let total = Int(first), total >= 0 else {
                return .object([
                    "status": .string("failed"), "integration": .string("messages"),
                    "reason": .string("invalid_thread_count"),
                    "message": .string("Messages returned an unreadable conversation count. Open Messages, then retry messages_recent_threads."),
                ])
            }
            let threads = parseMessagesMetadata(lines.count > 1 ? String(lines[1]) : "")
            if threadID != nil && threads.isEmpty {
                return failedEnvelope(integration: "messages", reason: "thread_not_found")
            }
            var result: [String: JSONValue] = [
                "status": .string("completed"), "count": .int(Int64(threads.count)),
                "total": .int(Int64(total)), "has_more": .bool(total > threads.count),
                "threads": .array(threads), "ordering": .string("Messages app order; recency is not provided by this interface."),
                "history_status": .string("select_conversation"),
                "history_note": .string("Open a conversation to read a bounded page of its local history. List previews are metadata, not an empty transcript."),
            ]
            if let threadID {
                result["thread_id"] = .string(threadID)
                let historyTask = Task.detached(priority: .utility) {
                    MacMessagesHistory.read(threadID: threadID, limit: limit, before: before)
                }
                let history = await withTaskCancellationHandler {
                    await historyTask.value
                } onCancel: {
                    historyTask.cancel()
                }
                try Task.checkCancellation()
                result.merge(history) { _, new in new }
            }
            // People by their Contacts names where known; handles stay the identity.
            return .object(await MacContactsAdapter.naming(result))
        } catch let AppleScriptError.permissionDenied(app) {
            return deniedEnvelope(integration: "messages", app: app)
        } catch {
            return failedEnvelope(integration: "messages", error: error)
        }
    }

    static func parseMessagesMetadata(_ raw: String) -> [JSONValue] {
        func decoded(_ value: Substring) -> String? {
            decodeConversationTransport(String(value))
        }
        return raw.split(separator: "\n").compactMap { line in
            let fields = line.split(separator: "|", omittingEmptySubsequences: false)
            guard fields.count == 3, let id = decoded(fields[0]), !id.isEmpty,
                  let name = decoded(fields[1]) else { return nil }
            var participants: [JSONValue] = []
            for record in fields[2].split(separator: ",") {
                let pair = record.split(separator: ":", omittingEmptySubsequences: false)
                guard pair.count == 2, let handle = decoded(pair[0]), !handle.isEmpty,
                      let personName = decoded(pair[1]) else { return nil }
                participants.append(.object(["handle": .string(handle), "name": .string(personName)]))
            }
            return .object(["thread_id": .string(id), "handle": .string(id), "name": .string(name),
                "participants": .array(participants)])
        }
    }

    /// Send to an explicit recipient, or an exact observed chat after checking
    /// its current participants. Never reinterpret a chat identifier as a handle.
    public static func messagesSend(input: [String: JSONValue]) async throws -> JSONValue {
        let to = inputString(input["to"])
        let threadID = inputString(input["thread_id"])
        guard (to?.isEmpty == false) != (threadID?.isEmpty == false) else {
            return failedEnvelope(integration: "messages", reason: "choose_recipient_or_thread")
        }
        guard let body = inputString(input["body"]), !body.isEmpty else {
            return failedEnvelope(integration: "messages", reason: "missing_body")
        }
        if let to, !to.isEmpty, !to.contains("@"), !to.contains(where: \.isNumber) {
            return .object(["status": .string("failed"), "integration": .string("messages"), "reason": .string("recipient_is_a_name"),
                "message": .string("\"\(to)\" is a name, not a phone number or email. Look it up with contacts_search, then send to that number. Nothing was sent.")])
        }
        let bodyAS = escapeForAppleScript(body)
        let source: String
        if let threadID, !threadID.isEmpty {
            guard case .array(let values)? = input["expected_participants"], !values.isEmpty,
                  values.count <= 100 else {
                return failedEnvelope(integration: "messages", reason: "read_thread_before_reply")
            }
            let handles = values.compactMap { inputString($0) }
            guard handles.count == values.count, handles.allSatisfy({ !$0.isEmpty }),
                  Set(handles).count == handles.count else {
                return failedEnvelope(integration: "messages", reason: "invalid_expected_participants")
            }
            let expected = handles.map { "\"\(escapeForAppleScript($0))\"" }.joined(separator: ", ")
            source = """
            tell application "Messages"
                set matches to every chat whose id is "\(escapeForAppleScript(threadID))"
                if (count of matches) is not 1 then return "thread_not_found"
                set targetChat to item 1 of matches
                set expectedHandles to {\(expected)}
                set actualPeople to participants of targetChat
                if (count of actualPeople) is not (count of expectedHandles) then return "participants_changed"
                repeat with person in actualPeople
                    if expectedHandles does not contain ((handle of person) as text) then return "participants_changed"
                end repeat
                send "\(bodyAS)" to targetChat
                return "sent"
            end tell
            """
        } else {
            source = """
            tell application "Messages"
                set targetService to 1st service whose service type = iMessage
                set targetBuddy to buddy "\(escapeForAppleScript(to!))" of targetService
                send "\(bodyAS)" to targetBuddy
                return "sent"
            end tell
            """
        }
        do {
            let outcome = try await runAppleScript(source)
            guard outcome == "sent" else {
                return failedEnvelope(integration: "messages", reason: outcome == "participants_changed" ? "participants_changed_read_thread_again" : "thread_not_found")
            }
            var result: [String: JSONValue] = ["status": .string("completed"), "action": .string("sent")]
            if let threadID, !threadID.isEmpty { result["thread_id"] = .string(threadID) }
            else { result["to"] = .string(to!) }
            return .object(result)
        } catch let AppleScriptError.permissionDenied(app) {
            return deniedEnvelope(integration: "messages", app: app)
        } catch {
            return failedEnvelope(integration: "messages", error: error)
        }
    }

    // MARK: NOTES

    /// List recent Apple Notes. Optional: "limit" (default 10, max 50).
    /// Returns the same bounded record shape as `notesSearch`.
    public static func notesListRecent(input: [String: JSONValue]) async throws -> JSONValue {
        await notesRead(selection: "notes", limit: clampedInt(input["limit"], defaultValue: 10, min: 1, max: 50), whole: false)
    }

    /// Search Apple Notes by title/body; blank query lists recent notes, and
    /// `title` (exact) or `id` reads a body page. Continuation requires `id`.
    public static func notesSearch(input: [String: JSONValue]) async throws -> JSONValue {
        let limit = clampedInt(input["limit"], defaultValue: 10, min: 1, max: 50)
        let id = inputString(input["id"])?.trimmingCharacters(in: .whitespacesAndNewlines)
        var offset = 0
        if let value = input["body_offset"] {
            guard let id, !id.isEmpty, case .int(let number) = value,
                  number >= 0, let position = Int(exactly: number) else {
                return failedEnvelope(integration: "notes", reason: "invalid_note_body_offset")
            }
            offset = position
        }
        // A note's own id reads exactly that note, whatever else shares its title.
        if let id, !id.isEmpty {
            return await notesRead(selection: "notes whose id is \"\(escapeForAppleScript(id))\"", limit: 1, whole: true, offset: offset)
        }
        if let title = inputString(input["title"])?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty {
            return await notesRead(selection: "notes whose name is \"\(escapeForAppleScript(title))\"", limit: 1, whole: true)
        }
        guard let query = inputString(input["query"])?.trimmingCharacters(in: .whitespacesAndNewlines), !query.isEmpty else {
            return await notesRead(selection: "notes", limit: limit, whole: false)
        }
        let q = escapeForAppleScript(query)
        return await notesRead(selection: "notes whose (name contains \"\(q)\") or (body contains \"\(q)\")", limit: limit, whole: false)
    }

    /// JSON protects all fields. Offsets count UTF-16 units; page boundaries
    /// expand to whole composed characters so Unicode is never split.
    private static func notesRead(selection: String, limit: Int, whole: Bool, offset: Int = 0) async -> JSONValue {
        let source = """
        use framework "Foundation"
        use scripting additions
        tell application "Notes"
            if (count of accounts) is 0 then return "__NATIVEAGENT_NOTES_NOT_CONFIGURED__"
            if (count of folders) is 0 then return "__NATIVEAGENT_NOTES_NOT_CONFIGURED__"
            set hits to \(selection)
            set totalHits to count of hits
            set previewChars to 200
            if \(whole ? "true" : "false") or totalHits is 1 then set previewChars to 4000
            set bodyKey to "body_preview"
            if \(whole ? "true" : "false") or totalHits is 1 then set bodyKey to "body"
            set output to current application's NSMutableArray's array()
            set countNote to 0
            repeat with i from 1 to totalHits
                if countNote ≥ \(limit) then exit repeat
                set n to item i of hits
                set nid to (id of n) as string
                set nm to (name of n) as string
                set md to (modification date of n) as string
                set fd to (name of container of n) as string
                set fullBody to current application's NSString's stringWithString:((plaintext of n) as string)
                set bodyTotal to (fullBody's |length|()) as integer
                if \(offset) > bodyTotal then return "__NATIVEAGENT_NOTES_INVALID_OFFSET__"
                set pageLength to bodyTotal - \(offset)
                if pageLength > previewChars then set pageLength to previewChars
                set pageRange to {location:\(offset), |length|:pageLength}
                if pageLength > 0 then set pageRange to fullBody's rangeOfComposedCharacterSequencesForRange:pageRange
                set bp to (fullBody's substringWithRange:pageRange) as string
                set nextOffset to (location of pageRange) + (|length| of pageRange)
                set row to current application's NSMutableDictionary's dictionaryWithObjects:{nm, bp, md, fd, nid, location of pageRange, bodyTotal} forKeys:{"name", bodyKey, "modified_at", "folder", "id", "body_offset", "body_total"}
                row's setObject:(current application's NSNumber's numberWithBool:(nextOffset < bodyTotal)) forKey:"truncated"
                if nextOffset < bodyTotal then row's setObject:nextOffset forKey:"next_body_offset"
                output's addObject:row
                set countNote to countNote + 1
            end repeat
        end tell
        set payload to current application's NSDictionary's dictionaryWithObjects:{totalHits, output} forKeys:{"total", "notes"}
        set jsonData to current application's NSJSONSerialization's dataWithJSONObject:payload options:0 |error|:(missing value)
        return (current application's NSString's alloc()'s initWithData:jsonData encoding:(current application's NSUTF8StringEncoding)) as string
        """
        do {
            let raw = try await runAppleScript(source)
            if let setup = readSetupEnvelope(raw: raw, integration: "notes") { return setup }
            if raw == "__NATIVEAGENT_NOTES_INVALID_OFFSET__" {
                return failedEnvelope(integration: "notes", reason: "invalid_note_body_offset")
            }
            let (total, notes) = try parseNoteRecords(raw)
            if whole && notes.isEmpty { return failedEnvelope(integration: "notes", reason: "no_matching_note") }
            var result: [String: JSONValue] = ["status": .string("completed"), "count": .int(Int64(notes.count)), "total": .int(total), "notes": .array(notes)]
            if total > Int64(notes.count) { result["message"] = .string("Showing \(notes.count) of \(total); narrow with query, or read one with title.") }
            return .object(result)
        } catch let AppleScriptError.permissionDenied(app) {
            return deniedEnvelope(integration: "notes", app: app)
        } catch {
            return failedEnvelope(integration: "notes", error: error)
        }
    }

    /// Create a new note. Required: "title", "body". Optional: "folder"
    /// (defaults to "Notes" folder).
    /// Returns: {status, action: "created", title}.
    public static func notesCreate(input: [String: JSONValue]) async throws -> JSONValue {
        guard let title = inputString(input["title"]), !title.isEmpty else {
            return failedEnvelope(integration: "notes", reason: "missing_title")
        }
        guard let body = inputString(input["body"]) else {
            return failedEnvelope(integration: "notes", reason: "missing_body")
        }
        // 2026-09-06: a REQUESTED folder that could not be resolved used to
        // fall through to Notes' default folder, so the note landed somewhere
        // the caller never asked for and the receipt still said "created". The
        // schema promises the default only when `folder` is omitted, so a
        // supplied-but-unresolvable folder is now an error naming what exists.
        let requestedFolder = inputString(input["folder"])?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let folder = (requestedFolder?.isEmpty == false) ? requestedFolder! : "Notes"
        let folderWasRequested = requestedFolder?.isEmpty == false
        let titleAS = escapeForAppleScript(title)
        let bodyAS = escapeForAppleScript(notesHTML(body))
        let folderAS = escapeForAppleScript(folder)
        let missingFolderBranch = folderWasRequested ? """
                set folderNames to ""
                repeat with f in folders
                    set folderNames to folderNames & (name of f as string) & "###"
                end repeat
                return "\(Self.notesFolderMissingSentinel)" & folderNames
        """ : """
                make new note with properties {name:"\(titleAS)", body:"\(bodyAS)"}
        """
        let source = """
        tell application "Notes"
            set targetFolder to missing value
            try
                set targetFolder to folder "\(folderAS)"
            end try
            if targetFolder is missing value then
        \(missingFolderBranch)
            else
                tell targetFolder
                    make new note with properties {name:"\(titleAS)", body:"\(bodyAS)"}
                end tell
            end if
            return "created"
        end tell
        """
        do {
            let raw = try await runAppleScript(source)
            if raw.hasPrefix(Self.notesFolderMissingSentinel) {
                let names = raw.dropFirst(Self.notesFolderMissingSentinel.count)
                    .components(separatedBy: "###")
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
                return .object([
                    "status": .string("failed"),
                    "integration": .string("notes"),
                    "reason": .string("folder_not_found"),
                    "requested_folder": .string(folder),
                    "available_folders": .array(names.map { .string($0) }),
                ])
            }
            return .object([
                "status": .string("completed"),
                "action": .string("created"),
                "title": .string(title),
            ])
        } catch let AppleScriptError.permissionDenied(app) {
            return deniedEnvelope(integration: "notes", app: app)
        } catch {
            return failedEnvelope(integration: "notes", error: error)
        }
    }

    /// Update an existing Apple Note. Required: "title" (current note name to
    /// find). At least one of "body" (replace), "append" (concat to existing),
    /// or "new_title" (rename) must be provided. body + append are mutually
    /// exclusive. Returns: {status, action: "updated", title}.
    public static func notesUpdate(input: [String: JSONValue]) async throws -> JSONValue {
        let noteID = inputString(input["id"])?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let title = inputString(input["title"]) ?? ""
        guard !noteID.isEmpty || !title.isEmpty else {
            return failedEnvelope(integration: "notes", reason: "missing_title")
        }
        let body = inputString(input["body"])
        let append = inputString(input["append"])
        let newTitle = inputString(input["new_title"])
        // gpt-5.5 review NEEDS_FIX: schema declared rename-only valid; impl
        // was rejecting calls without body/append. Now: at least ONE of the
        // three mutations must be provided (body, append, OR new_title).
        // body + append remain mutually exclusive (ambiguous semantic).
        if body == nil && append == nil && (newTitle == nil || newTitle?.isEmpty == true) {
            return failedEnvelope(integration: "notes", reason: "missing_body_append_or_new_title")
        }
        if body != nil && append != nil {
            return failedEnvelope(integration: "notes", reason: "body_and_append_mutually_exclusive")
        }
        let titleAS = escapeForAppleScript(title)
        // Build the body-mutation statement (empty when neither body nor
        // append was passed — rename-only path).
        let bodyStmt: String
        if let body = body {
            if body.isEmpty {
                // Notes derives its name from the first HTML line. Clearing
                // content must keep that line, read from the exact note by ID.
                bodyStmt = """
                set titleHTML to ""
                repeat with titleCharacter in characters of ((name of targetNote) as text)
                    set titleText to titleCharacter as text
                    if titleText is "&" then
                        set titleText to "&amp;"
                    else if titleText is "<" then
                        set titleText to "&lt;"
                    else if titleText is ">" then
                        set titleText to "&gt;"
                    end if
                    set titleHTML to titleHTML & titleText
                end repeat
                set body of targetNote to "<div>" & titleHTML & "</div>"
                """
            } else {
                let bodyAS = escapeForAppleScript(notesHTML(body))
                bodyStmt = "set body of targetNote to \"\(bodyAS)\""
            }
        } else if let append = append {
            let appendAS = escapeForAppleScript(notesHTML(append))
            bodyStmt = "set body of targetNote to ((body of targetNote) as string) & \"<br>\(appendAS)\""
        } else {
            // Rename-only path — no body mutation.
            bodyStmt = ""
        }
        // Build the optional rename statement.
        let renameStmt: String
        if let newTitle = newTitle, !newTitle.isEmpty {
            let newTitleAS = escapeForAppleScript(newTitle)
            renameStmt = "set name of targetNote to \"\(newTitleAS)\""
        } else {
            renameStmt = ""
        }
        let source = """
        tell application "Notes"
            set hits to \(noteID.isEmpty ? "(notes whose name is \"\(titleAS)\")" : "(notes whose id is \"\(escapeForAppleScript(noteID))\")")
            if (count of hits) is 0 then return "0"
            if (count of hits) > 1 then return "-3|" & ((count of hits) as text)
            set targetNote to first item of hits
            set finalName to ""
            \(bodyStmt)
            \(renameStmt)
            try
                set finalName to (name of targetNote) as string
            end try
            return "1|" & finalName
        end tell
        """
        do {
            let raw = try await runAppleScript(source).trimmingCharacters(in: .whitespacesAndNewlines)
            let parts = raw.split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
            // Two notes with one title: which is meant is unknown, so neither changes (2026-09-24).
            if parts.first == "-3" {
                return .object(["status": .string("failed"), "integration": .string("notes"), "reason": .string("several_notes_match"),
                    "message": .string("\(parts.count > 1 ? parts[1] : "Several") notes are titled \"\(title)\", so nothing changed. Pass the id of one from notes_search.")])
            }
            guard parts.first == "1" else {
                return failedEnvelope(integration: "notes", reason: "no_matching_note")
            }
            return .object([
                "status": .string("completed"),
                "action": .string("updated"),
                "title": .string(parts.count > 1 && !parts[1].isEmpty ? parts[1] : (newTitle?.isEmpty == false ? newTitle! : title)),
            ])
        } catch let AppleScriptError.permissionDenied(app) {
            return deniedEnvelope(integration: "notes", app: app)
        } catch {
            return failedEnvelope(integration: "notes", error: error)
        }
    }

    private static func notesHTML(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .replacingOccurrences(of: "\n", with: "<br>")
    }

}
