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
            return .object(result)
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
        let limit = clampedInt(input["limit"], defaultValue: 10, min: 1, max: 50)
        let source = """
        tell application "Notes"
            if (count of accounts) is 0 then return "__NATIVEAGENT_NOTES_NOT_CONFIGURED__"
            if (count of folders) is 0 then return "__NATIVEAGENT_NOTES_NOT_CONFIGURED__"
            set noteList to notes
            set output to ""
            set countNote to 0
            repeat with i from 1 to (count of noteList)
                if countNote ≥ \(limit) then exit repeat
                set n to item i of noteList
                set nm to ""
                set bp to ""
                set md to ""
                try
                    set nm to (name of n) as string
                end try
                try
                    set bp to text 1 thru 200 of ((body of n) as string)
                on error
                    try
                        set bp to (body of n) as string
                    end try
                end try
                try
                    set md to ((modification date of n) as string)
                end try
                set output to output & nm & "|||" & bp & "|||" & md & "###"
                set countNote to countNote + 1
            end repeat
            return output
        end tell
        """
        do {
            let raw = try await runAppleScript(source)
            if let setup = readSetupEnvelope(raw: raw, integration: "notes") { return setup }
            let notes = parseNoteRecords(raw)
            return .object([
                "status": .string("completed"),
                "count": .int(Int64(notes.count)),
                "notes": .array(notes),
            ])
        } catch let AppleScriptError.permissionDenied(app) {
            return deniedEnvelope(integration: "notes", app: app)
        } catch {
            return failedEnvelope(integration: "notes", error: error)
        }
    }

    /// Search Apple Notes by title/body. Required: "query". Optional: "limit"
    /// (default 10, max 50).
    /// Returns: {status, count, notes: [{name, body_preview, modified_at}]}
    public static func notesSearch(input: [String: JSONValue]) async throws -> JSONValue {
        guard let query = inputString(input["query"]), !query.isEmpty else {
            return failedEnvelope(integration: "notes", reason: "missing_query")
        }
        let limit = clampedInt(input["limit"], defaultValue: 10, min: 1, max: 50)
        let escapedQuery = escapeForAppleScript(query)
        let source = """
        tell application "Notes"
            if (count of accounts) is 0 then return "__NATIVEAGENT_NOTES_NOT_CONFIGURED__"
            if (count of folders) is 0 then return "__NATIVEAGENT_NOTES_NOT_CONFIGURED__"
            set q to "\(escapedQuery)"
            set hits to (notes whose (name contains q) or (body contains q))
            set output to ""
            set countNote to 0
            repeat with i from 1 to (count of hits)
                if countNote ≥ \(limit) then exit repeat
                set n to item i of hits
                set nm to ""
                set bp to ""
                set md to ""
                try
                    set nm to (name of n) as string
                end try
                try
                    set bp to text 1 thru 200 of ((body of n) as string)
                on error
                    try
                        set bp to (body of n) as string
                    end try
                end try
                try
                    set md to ((modification date of n) as string)
                end try
                set output to output & nm & "|||" & bp & "|||" & md & "###"
                set countNote to countNote + 1
            end repeat
            return output
        end tell
        """
        do {
            let raw = try await runAppleScript(source)
            if let setup = readSetupEnvelope(raw: raw, integration: "notes") { return setup }
            let notes = parseNoteRecords(raw)
            return .object([
                "status": .string("completed"),
                "count": .int(Int64(notes.count)),
                "notes": .array(notes),
            ])
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
        guard let title = inputString(input["title"]), !title.isEmpty else {
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
            set hits to (notes whose name is "\(titleAS)")
            if (count of hits) is 0 then return "0"
            set targetNote to first item of hits
            \(bodyStmt)
            \(renameStmt)
            return "1"
        end tell
        """
        do {
            let raw = try await runAppleScript(source)
            let updated = (Int(raw.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0) > 0
            if !updated {
                return failedEnvelope(integration: "notes", reason: "no_matching_note")
            }
            return .object([
                "status": .string("completed"),
                "action": .string("updated"),
                "title": .string(newTitle?.isEmpty == false ? newTitle! : title),
            ])
        } catch let AppleScriptError.permissionDenied(app) {
            return deniedEnvelope(integration: "notes", app: app)
        } catch {
            return failedEnvelope(integration: "notes", error: error)
        }
    }
}
