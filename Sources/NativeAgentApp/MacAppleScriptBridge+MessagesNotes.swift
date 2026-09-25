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
            set output to ""
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
            let threads = parseMessagesMetadata(raw)
            if threadID != nil && threads.isEmpty {
                return failedEnvelope(integration: "messages", reason: "thread_not_found")
            }
            var result: [String: JSONValue] = [
                "status": .string("completed"), "count": .int(Int64(threads.count)),
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
            return .object(MacContactsAdapter.naming(result))
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
    /// `title` (exact) reads that note's whole text in the same call. A single
    /// hit carries its text too (2026-09-24).
    /// Returns: {status, count, total, notes: [{name, body_preview | body, modified_at, folder}]}
    public static func notesSearch(input: [String: JSONValue]) async throws -> JSONValue {
        let limit = clampedInt(input["limit"], defaultValue: 10, min: 1, max: 50)
        // A note's own id reads exactly that note, whatever else shares its title.
        if let id = inputString(input["id"])?.trimmingCharacters(in: .whitespacesAndNewlines), !id.isEmpty {
            return await notesRead(selection: "notes whose id is \"\(escapeForAppleScript(id))\"", limit: 1, whole: true)
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

    /// Plain text (not the HTML body): 200 characters a row, up to 4000 when
    /// one note is the answer.
    private static func notesRead(selection: String, limit: Int, whole: Bool) async -> JSONValue {
        let source = """
        tell application "Notes"
            if (count of accounts) is 0 then return "__NATIVEAGENT_NOTES_NOT_CONFIGURED__"
            if (count of folders) is 0 then return "__NATIVEAGENT_NOTES_NOT_CONFIGURED__"
            set hits to \(selection)
            set totalHits to count of hits
            set previewChars to 200
            if \(whole ? "true" : "false") or totalHits is 1 then set previewChars to 4000
            set output to "__TOTAL__" & (totalHits as text) & "###"
            set countNote to 0
            repeat with i from 1 to totalHits
                if countNote ≥ \(limit) then exit repeat
                set n to item i of hits
                set nm to ""
                set bp to ""
                set md to ""
                set fd to ""
                set nid to ""
                try
                    set nid to (id of n) as string
                end try
                try
                    set nm to (name of n) as string
                end try
                try
                    set bp to (plaintext of n) as string
                    if (count of bp) > previewChars then set bp to text 1 thru previewChars of bp
                end try
                try
                    set md to ((modification date of n) as string)
                end try
                try
                    set fd to (name of container of n) as string
                end try
                set output to output & nm & "|||" & bp & "|||" & md & "|||" & fd & "|||" & nid & "###"
                set countNote to countNote + 1
            end repeat
            return output
        end tell
        """
        do {
            var raw = try await runAppleScript(source)
            if let setup = readSetupEnvelope(raw: raw, integration: "notes") { return setup }
            var total: Int64?
            if raw.hasPrefix("__TOTAL__"), let end = raw.range(of: "###") {
                total = Int64(raw[raw.index(raw.startIndex, offsetBy: 9)..<end.lowerBound])
                raw = String(raw[end.upperBound...])
            }
            var notes = parseNoteRecords(raw)
            if whole && notes.isEmpty { return failedEnvelope(integration: "notes", reason: "no_matching_note") }
            if notes.count == 1, case .object(var row) = notes[0], let text = row.removeValue(forKey: "body_preview") {
                row["body"] = text
                notes[0] = .object(row)
            }
            var result: [String: JSONValue] = ["status": .string("completed"), "count": .int(Int64(notes.count)), "notes": .array(notes)]
            if let total {
                result["total"] = .int(total)
                if total > Int64(notes.count) { result["message"] = .string("Showing \(notes.count) of \(total); narrow with query, or read one with title.") }
            }
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
        let bodyAS = escapeForAppleScript(body)
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
            let bodyAS = escapeForAppleScript(body)
            bodyStmt = "set body of targetNote to \"\(bodyAS)\""
        } else if let append = append {
            let appendAS = escapeForAppleScript(append)
            bodyStmt = "set body of targetNote to ((body of targetNote) as string) & return & \"\(appendAS)\""
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
}
