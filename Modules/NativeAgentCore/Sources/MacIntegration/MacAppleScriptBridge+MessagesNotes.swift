import Foundation
import NativeAgentShared
import AppKit
import PersistenceCore
import NativeAgentCore
// Blueprint: | `MacAppleScriptBridge+MessagesNotes.swift` | `MacAppleScriptBridge`: Messages list field projection and shared date/duration windows, `messagesSend`, `notesModify` (exact-note update or reversible deletion) |

extension MacAppleScriptBridge {
    // MARK: MESSAGES

    /// Reads Messages' chat.db read-only, newest first; chat guids are AppleScript send ids.
    /// `query` matches people (name, number, email) or messages.
    /// An exact selected chat exposes a bounded local history page.
    public static func messagesRecentThreads(input: [String: JSONValue]) async throws -> JSONValue {
        let limit = clampedInt(input["limit"], defaultValue: 10, min: 1, max: 30)
        let threadID = input["thread_id"]?.scalarText
        guard input["unread_only"] == nil || input["unread_only"] == .bool(true) || input["unread_only"] == .bool(false),
              input["from_me"] == nil || input["from_me"] == .bool(true) || input["from_me"] == .bool(false),
              input["sort"] == nil || input["sort"] == .string("newest") || input["sort"] == .string("oldest_unread") else {
            return failedEnvelope(integration: "messages", reason: "invalid_thread_filter",
                message: "unread_only and from_me take true or false; sort takes newest or oldest_unread. Nothing was read.")
        }
        let unreadOnly = input["unread_only"] == .bool(true)
        let oldestUnread = input["sort"] == .string("oldest_unread")
        let fields: [String]?
        if let value = input["fields"] {
            let allowed: Set<String> = ["thread_id", "name", "participants", "date", "preview", "snippet",
                "latest_message_is_read", "unread_count", "oldest_unread_message_id", "oldest_unread_date",
                "oldest_unread_preview", "oldest_unread_preview_status", "handle", "last_at", "unread"]
            guard threadID == nil, input["from_me"] == nil, case .array(let values) = value,
                  values.allSatisfy({ if case .string(let key) = $0 { allowed.contains(key) } else { false } }) else {
                return failedEnvelope(integration: "messages", reason: "invalid_thread_fields",
                    message: "fields is a list from: " + allowed.sorted().joined(separator: ", ")
                        + "; it lists threads, so it does not combine with thread_id or from_me. Nothing was read.")
            }
            fields = values.compactMap { if case .string(let key) = $0 { key } else { nil } }
        } else { fields = nil }
        let since: Date?
        if let value = input["since"] {
            guard threadID == nil, case .string(let raw) = value, let date = messagesSince(raw),
                  abs(date.timeIntervalSinceReferenceDate * 1_000_000_000) < Double(Int64.max) else {
                return .object(["status": .string("failed"), "integration": .string("messages"), "effects": .string("none"),
                    "message": .string("since takes local YYYY-MM-DD, ISO-8601 with a time zone, a positive duration such as 7d (m/h/d/w), or this week. Use it with a thread list or from_me, within the Messages date range.")])
            }
            since = date
        } else {
            since = oldestUnread ? Date().addingTimeInterval(-30 * 86_400) : nil
        }
        guard threadID == nil || !(unreadOnly || oldestUnread) else {
            return failedEnvelope(integration: "messages", reason: "thread_filters_require_listing")
        }
        let offset = threadID == nil ? clampedInt(input["offset"], defaultValue: 0, min: 0, max: 100_000) : 0
        let query = input["query"]?.scalarText.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.flatMap { $0.isEmpty ? nil : $0 }
        let before: Int64?
        if let value = input["before_message_id"] {
            guard threadID != nil, case .int(let id) = value, id > 0 else {
                return failedEnvelope(integration: "messages", reason: "invalid_history_cursor")
            }
            before = id
        } else { before = nil }
        if case .bool(let fromMe)? = input["from_me"] {
            guard threadID == nil, query == nil, input["unread_only"] == nil, input["sort"] == nil,
                  input["offset"] == nil else {
                return .object(["status": .string("failed"), "integration": .string("messages"), "effects": .string("none"),
                    "message": .string("from_me selects messages across all conversations. Omit thread_id, query, unread_only, sort and offset for this view.")])
            }
            let task = Task.detached(priority: .utility) { MacMessagesHistory.read(limit: limit, fromMe: fromMe, since: since) }
            var result = await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
            try Task.checkCancellation()
            result["status"] = .string(result["history_status"] == .string("available") ? "completed" : "failed")
            result["integration"] = .string("messages")
            result["effects"] = .string("none")
            return .object(await MacContactsExecutor.naming(result))
        }
        let words = threadID == nil ? query : nil
        let listTask = Task.detached(priority: .utility) { MacMessagesHistory.threads(words: words, threadID: threadID, unreadOnly: unreadOnly, oldestUnread: oldestUnread, since: since) }
        let listing = await withTaskCancellationHandler { await listTask.value } onCancel: { listTask.cancel() }
        try Task.checkCancellation()
        guard case .array(let all)? = listing["threads"] else {
            return .object(["status": .string("failed"), "integration": .string("messages"),
                "reason": listing["history_reason"] ?? .string("history_read_failed"), "effects": .string("none"),
                "message": listing["history_note"] ?? .string("Messages' conversations could not be read; refresh to retry.")])
        }
        // People by their Contacts names where known (so a name finds them); handles stay the identity.
        var rows = all
        if case .array(let named)? = await MacContactsExecutor.naming(["threads": .array(all)])["threads"] { rows = named }
        func strings(_ row: JSONValue) -> (texts: [String], snippet: Bool) {
            guard case .object(let object) = row else { return ([], false) }
            var texts: [String] = []
            if case .string(let name)? = object["name"] { texts.append(name) }
            if case .array(let people)? = object["participants"] {
                for case .object(let person) in people {
                    for key in ["handle", "name"] { if case .string(let value)? = person[key] { texts.append(value) } }
                }
            }
            return (texts, object["snippet"] != nil)
        }
        if threadID != nil {
            if rows.isEmpty { return failedEnvelope(integration: "messages", reason: "thread_not_found") }
        } else if let query {
            let digits = query.filter(\.isNumber)
            rows = rows.filter { row in
                let row = strings(row)
                return row.snippet || row.texts.contains { $0.localizedCaseInsensitiveContains(query)
                    || (digits.count >= 7 && $0.filter(\.isNumber).contains(digits)) }
            }
        }
        let page = Array(rows.dropFirst(offset).prefix(limit))
        var result: [String: JSONValue] = [
            "status": .string("completed"), "count": .int(Int64(page.count)),
            "total": .int(Int64(rows.count)), "has_more": .bool(offset + page.count < rows.count),
            "threads": .array(page), "ordering": .string(oldestUnread
                ? "Oldest unread incoming message within since first (default: past 30 days)."
                : "Newest conversation first, by its last message."),
            "history_status": .string("select_conversation"),
            "history_note": .string("Open a conversation to read a bounded page of its local history. fields selects only the requested thread metadata or previews."),
        ]
        if let since { result["since"] = .string(NativeTimestampFormat.plainZulu(since)) }
        if offset + page.count < rows.count { result["next_offset"] = .int(Int64(offset + page.count)) }
        // A word search cut short by its budget says so (the room shows `note`).
        for key in ["partial", "note", "unread_state", "unread_note"] { if let value = listing[key] { result[key] = value } }
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
        result = await MacContactsExecutor.naming(result)
        if let fields, case .array(let threads)? = result["threads"] {
            result["threads"] = .array(threads.map { value in
                guard case .object(let row) = value else { return value }
                var selected: [String: JSONValue] = [:]
                for field in fields {
                    switch field {
                    case "last_at": selected[field] = row["date"]
                    case "unread": selected[field] = row["unread_count"]
                    case "handle":
                        if case .array(let people)? = row["participants"] {
                            selected[field] = .array(people.compactMap { $0.objectValue?["handle"] })
                        }
                    default: selected[field] = row[field]
                    }
                }
                return .object(selected)
            })
        }
        return .object(result)
    }

    private static func messagesSince(_ raw: String) -> Date? {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if value == "this week" { return Calendar.current.dateInterval(of: .weekOfYear, for: Date())?.start }
        let units: [Character: Double] = ["m": 60, "h": 3600, "d": 86_400, "w": 604_800]
        if let unit = value.last, let seconds = units[unit], let count = Double(value.dropLast()), count.isFinite, count > 0 {
            return Date().addingTimeInterval(-count * seconds)
        }
        let local = DateFormatter()
        local.locale = Locale(identifier: "en_US_POSIX"); local.calendar = Calendar(identifier: .gregorian)
        local.dateFormat = "yyyy-MM-dd"; local.isLenient = false
        if value.count == 10 { return local.date(from: value).flatMap { local.string(from: $0) == value ? $0 : nil } }
        return ISO8601DateFormatter().date(from: value)
    }

    /// Send to an explicit recipient, or an exact observed chat after checking
    /// its current participants. Never reinterpret a chat identifier as a handle.
    public static func messagesSend(input: [String: JSONValue]) async throws -> JSONValue {
        let to = input["to"]?.scalarText
        let threadID = input["thread_id"]?.scalarText
        guard (to?.isEmpty == false) != (threadID?.isEmpty == false) else {
            return failedEnvelope(integration: "messages", reason: "choose_recipient_or_thread")
        }
        guard let body = input["body"]?.scalarText, !body.isEmpty else {
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
            let handles = values.compactMap { $0.scalarText }
            guard handles.count == values.count, handles.allSatisfy({ !$0.isEmpty }),
                  Set(handles).count == handles.count else {
                return failedEnvelope(integration: "messages", reason: "invalid_expected_participants")
            }
            let expected = handles.map { "\"\(escapeForAppleScript($0))\"" }.joined(separator: ", ")
            source = """
            tell application "__NativeAgentApp__"
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
            tell application "__NativeAgentApp__"
                set targetService to 1st service whose service type = iMessage
                set targetBuddy to buddy "\(escapeForAppleScript(to!))" of targetService
                send "\(bodyAS)" to targetBuddy
                return "sent"
            end tell
            """
        }
        do {
            let outcome = try await runAppleScript(source, bundleID: "com.apple.MobileSMS")
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
        let id = input["id"]?.scalarText?.trimmingCharacters(in: .whitespacesAndNewlines)
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
        if let title = input["title"]?.scalarText?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty {
            return await notesRead(selection: "notes whose name is \"\(escapeForAppleScript(title))\"", limit: 1, whole: true)
        }
        guard let query = input["query"]?.scalarText?.trimmingCharacters(in: .whitespacesAndNewlines), !query.isEmpty else {
            return await notesRead(selection: "notes", limit: limit, whole: false)
        }
        let q = escapeForAppleScript(query)
        return await notesRead(selection: "notes whose (name contains \"\(q)\") or (body contains \"\(q)\")", limit: limit, whole: false)
    }

    /// JSON protects all fields. A first line matching the name (after trimming)
    /// is elided before paging, with `title_line_elided` recording the omission.
    /// Offsets and totals count stored UTF-16 units, including that title line;
    /// page boundaries expand to whole composed characters so Unicode is never split.
    private static func notesRead(selection: String, limit: Int, whole: Bool, offset: Int = 0) async -> JSONValue {
        let source = """
        use framework "Foundation"
        use scripting additions
        tell application "__NativeAgentApp__"
            if (count of accounts) is 0 then return "__NATIVEAGENT_NOTES_NOT_CONFIGURED__"
            if (count of folders) is 0 then return "__NATIVEAGENT_NOTES_NOT_CONFIGURED__"
            set hits to \(selection)
            -- A deleted note stays readable in Recently Deleted; it is not one of User's notes (10-08).
            set deletedIDs to {}
            repeat with f in folders
                try
                    if (name of f) is "Recently Deleted" then set deletedIDs to deletedIDs & (id of notes of f)
                end try
            end repeat
            if (count of deletedIDs) > 0 then
                set keptHits to {}
                repeat with h in hits
                    if deletedIDs does not contain ((id of h) as string) then set end of keptHits to contents of h
                end repeat
                set hits to keptHits
            end if
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
                set fd to ""
                try
                    set fd to (name of container of n) as string
                end try
                set fullBody to current application's NSString's stringWithString:((plaintext of n) as string)
                set bodyTotal to (fullBody's |length|()) as integer
                if \(offset) > bodyTotal then return "__NATIVEAGENT_NOTES_INVALID_OFFSET__"
                set pageStart to \(offset)
                set titleLineElided to false
                if bodyTotal > 0 then
                    set titleRange to fullBody's lineRangeForRange:{location:0, |length|:0}
                    set trimSet to current application's NSCharacterSet's whitespaceAndNewlineCharacterSet()
                    set firstLine to fullBody's substringWithRange:titleRange
                    set firstLine to firstLine's stringByTrimmingCharactersInSet:trimSet
                    set noteName to current application's NSString's stringWithString:nm
                    set noteName to noteName's stringByTrimmingCharactersInSet:trimSet
                    if (firstLine's isEqualToString:noteName) as boolean then
                        if pageStart < (|length| of titleRange) then
                            set pageStart to |length| of titleRange
                            set titleLineElided to true
                        end if
                    end if
                end if
                set pageLength to bodyTotal - pageStart
                if pageLength > previewChars then set pageLength to previewChars
                set pageRange to {location:pageStart, |length|:pageLength}
                if pageLength > 0 then set pageRange to fullBody's rangeOfComposedCharacterSequencesForRange:pageRange
                set bp to (fullBody's substringWithRange:pageRange) as string
                set nextOffset to (location of pageRange) + (|length| of pageRange)
                set row to current application's NSMutableDictionary's dictionaryWithObjects:{nm, bp, md, fd, nid, location of pageRange, bodyTotal} forKeys:{"name", bodyKey, "modified_at", "folder", "id", "body_offset", "body_total"}
                row's setObject:(current application's NSNumber's numberWithBool:titleLineElided) forKey:"title_line_elided"
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
            let raw = try await runAppleScript(source, bundleID: "com.apple.Notes")
            if let setup = readSetupEnvelope(raw: raw, integration: "notes") { return setup }
            if raw == "__NATIVEAGENT_NOTES_INVALID_OFFSET__" {
                return failedEnvelope(integration: "notes", reason: "invalid_note_body_offset")
            }
            let (total, notes) = try parseNoteRecords(raw)
            var result: [String: JSONValue] = [
                "status": .string("completed"), "source": .string("applescript"),
                "access": .object([
                    "automation": .string("confirmed"), "operation": .string("read"),
                    "note_records": .int(Int64(notes.count)),
                ]),
                "count": .int(Int64(notes.count)), "total": .int(total), "notes": .array(notes),
            ]
            if total > Int64(notes.count) { result["message"] = .string("Showing \(notes.count) of \(total); narrow with query, or read one with title.") }
            // Nothing by that title or id is an answer (count 0), not an error (drive wave 10-28).
            if whole && notes.isEmpty { result["message"] = .string("No note has that title or id.") }
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
        guard let title = input["title"]?.scalarText, !title.isEmpty else {
            return failedEnvelope(integration: "notes", reason: "missing_title")
        }
        guard let body = input["body"]?.scalarText else {
            return failedEnvelope(integration: "notes", reason: "missing_body")
        }
        // Only an omitted folder uses the default; unresolved requests fail with available names.
        let requestedFolder = input["folder"]?.scalarText?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let folder = (requestedFolder?.isEmpty == false) ? requestedFolder! : "Notes"
        let folderWasRequested = requestedFolder?.isEmpty == false
        let titleAS = escapeForAppleScript(title)
        let bodyAS = escapeForAppleScript(notesHTML(body))
        let folderAS = escapeForAppleScript(folder)
        let missingFolderBranch = folderWasRequested ? """
                set folderNames to ""
                repeat with f in folders
                    set fName to (name of f as string)
                    if fName is not "Recently Deleted" then
                        set holder to ""
                        try
                            set holder to " (" & (name of container of f as string) & ")"
                        end try
                        set folderNames to folderNames & fName & holder & "###"
                    end if
                end repeat
                return "\(Self.notesFolderMissingSentinel)" & folderNames
        """ : """
                set newNote to make new note with properties {name:"\(titleAS)", body:"\(bodyAS)"}
        """
        let source = """
        tell application "__NativeAgentApp__"
            set targetFolder to missing value
            try
                set targetFolder to folder "\(folderAS)"
            end try
            if targetFolder is missing value then
        \(missingFolderBranch)
            else
                tell targetFolder
                    set newNote to make new note with properties {name:"\(titleAS)", body:"\(bodyAS)"}
                end tell
            end if
            return "created|" & (id of newNote as string)
        end tell
        """
        do {
            let raw = try await runAppleScript(source, bundleID: "com.apple.Notes")
            if raw.hasPrefix(Self.notesFolderMissingSentinel) {
                let names = raw.dropFirst(Self.notesFolderMissingSentinel.count)
                    .components(separatedBy: "###")
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
                return .object([
                    "status": .string("failed"),
                    "integration": .string("notes"),
                    "effects": .string("none"),
                    "reason": .string("folder_not_found"),
                    "detail": .string("No Notes folder is named that, so nothing changed; use one of available_folders."),
                    "requested_folder": .string(folder),
                    "available_folders": .array(names.map { .string($0) }),
                ])
            }
            // The new note's own id rides on the receipt: the next step reads
            // or changes exactly it, no search needed (drive wave 10-28).
            let newID = raw.hasPrefix("created|") ? String(raw.dropFirst("created|".count)) : ""
            var created: [String: JSONValue] = [
                "status": .string("completed"),
                "action": .string("created"),
                "title": .string(title),
            ]
            if !newID.isEmpty { created["id"] = .string(newID) }
            return .object(created)
        } catch let AppleScriptError.permissionDenied(app) {
            return deniedEnvelope(integration: "notes", app: app)
        } catch {
            return failedEnvelope(integration: "notes", error: error)
        }
    }

    /// Select one exact note for an update or reversible deletion.
    public static func notesModify(input: [String: JSONValue], deleting: Bool) async throws -> JSONValue {
        let noteID = input["id"]?.scalarText?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let title = input["title"]?.scalarText ?? ""
        guard !noteID.isEmpty || !title.isEmpty else {
            return failedEnvelope(integration: "notes", reason: "missing_title")
        }
        let body = input["body"]?.scalarText
        let append = input["append"]?.scalarText
        let newTitle = input["new_title"]?.scalarText
        if !deleting && body == nil && append == nil && (newTitle == nil || newTitle?.isEmpty == true) {
            return failedEnvelope(integration: "notes", reason: "missing_body_append_or_new_title")
        }
        if body != nil && append != nil {
            return failedEnvelope(integration: "notes", reason: "body_and_append_mutually_exclusive")
        }
        let titleAS = escapeForAppleScript(title)
        // Build the body-mutation statement (empty when neither body nor
        // append was passed — rename-only path).
        let bodyStmt: String
        // Notes derives its name from the first HTML line, so a body write
        // keeps that line (read from the exact note by ID) unless the new body
        // already starts with the note's name.
        let titleHTMLStmt = """
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
                """
        if let body = body {
            if body.isEmpty {
                bodyStmt = titleHTMLStmt + "\nset body of targetNote to \"<div>\" & titleHTML & \"</div>\""
            } else {
                let firstLine = escapeForAppleScript(String(body.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false).first ?? ""))
                let bodyAS = escapeForAppleScript(notesHTML(body))
                bodyStmt = titleHTMLStmt + """

                if "\(firstLine)" is ((name of targetNote) as text) then
                    set body of targetNote to "<div>\(bodyAS)</div>"
                else
                    set body of targetNote to "<div>" & titleHTML & "</div><div>\(bodyAS)</div>"
                end if
                """
            }
        } else if let append = append {
            // One new line after the existing body, however many newlines the caller added.
            let appendAS = escapeForAppleScript(notesHTML(append.trimmingCharacters(in: .newlines)))
            bodyStmt = "set body of targetNote to ((body of targetNote) as string) & \"<div>\(appendAS)</div>\""
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
        tell application "__NativeAgentApp__"
            set hits to \(noteID.isEmpty ? "(notes whose name is \"\(titleAS)\")" : "(notes whose id is \"\(escapeForAppleScript(noteID))\")")
            if (count of hits) is 0 then return "0"
            if (count of hits) > 1 then return "-3|" & ((count of hits) as text)
            set targetNote to first item of hits
            if \(deleting ? "true" : "false") then
                set finalName to (name of targetNote) as text
                delete targetNote
                return "1|" & finalName
            end if
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
            let raw = try await runAppleScript(source, bundleID: "com.apple.Notes").trimmingCharacters(in: .whitespacesAndNewlines)
            let parts = raw.split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
            // Ambiguous note titles leave all matches unchanged.
            if parts.first == "-3" {
                return .object(["status": .string("failed"), "integration": .string("notes"), "reason": .string("several_notes_match"),
                    "message": .string("\(parts.count > 1 ? parts[1] : "Several") notes are titled \"\(title)\", so nothing changed. Pass the id of one from notes_search.")])
            }
            guard parts.first == "1" else {
                return failedEnvelope(integration: "notes", reason: "no_matching_note")
            }
            return .object([
                "status": .string("completed"),
                "action": .string(deleting ? "moved_to_recently_deleted" : "updated"),
                "recovery": deleting ? .string("Restore the note from Recently Deleted in Notes.") : .null,
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
