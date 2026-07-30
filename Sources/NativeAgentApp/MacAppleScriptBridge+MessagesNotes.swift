import Foundation
import AppKit
import PersistenceCore

extension MacAppleScriptBridge {
    // MARK: MESSAGES

    /// List recent iMessage threads (last N conversations). Input: "limit" (default 10, max 30).
    /// Returns: {status, count, threads: [{handle, lastMessage, lastMessageDate}]}
    public static func messagesRecentThreads(input: [String: JSONValue]) async throws -> JSONValue {
        let limit = clampedInt(input["limit"], defaultValue: 10, min: 1, max: 30)
        let source = """
        tell application "Messages"
            set chatList to chats
            set output to ""
            set countChat to 0
            repeat with i from 1 to (count of chatList)
                if countChat ≥ \(limit) then exit repeat
                set c to item i of chatList
                set handleStr to ""
                try
                    set handleStr to (id of c) as string
                end try
                set lastMsg to ""
                set lastDate to ""
                try
                    set msgs to messages of c
                    if (count of msgs) > 0 then
                        set lastM to item -1 of msgs
                        try
                            set lastMsg to text 1 thru 200 of (text of lastM)
                        on error
                            set lastMsg to (text of lastM) as string
                        end try
                        try
                            set lastDate to ((date sent of lastM) as string)
                        end try
                    end if
                end try
                set output to output & handleStr & "|||" & lastMsg & "|||" & lastDate & "###"
                set countChat to countChat + 1
            end repeat
            return output
        end tell
        """
        do {
            let raw = try await runAppleScript(source)
            let threads = parseThreadRecords(raw)
            return .object([
                "status": .string("completed"),
                "count": .int(Int64(threads.count)),
                "threads": .array(threads),
            ])
        } catch let AppleScriptError.permissionDenied(app) {
            return deniedEnvelope(integration: "messages", app: app)
        } catch {
            return failedEnvelope(integration: "messages", error: error)
        }
    }

    /// Send iMessage. Required: "to" (phone number or email), "body".
    /// Returns: {status, action: "sent", to}.
    public static func messagesSend(input: [String: JSONValue]) async throws -> JSONValue {
        guard let to = inputString(input["to"]), !to.isEmpty else {
            return failedEnvelope(integration: "messages", reason: "missing_to")
        }
        guard let body = inputString(input["body"]), !body.isEmpty else {
            return failedEnvelope(integration: "messages", reason: "missing_body")
        }
        let toAS = escapeForAppleScript(to)
        let bodyAS = escapeForAppleScript(body)
        // Service 1 == iMessage (typical default). If the buddy isn't on
        // iMessage Messages will surface its own error which propagates as
        // a failed envelope.
        let source = """
        tell application "Messages"
            set targetService to 1st service whose service type = iMessage
            set targetBuddy to buddy "\(toAS)" of targetService
            send "\(bodyAS)" to targetBuddy
            return "sent"
        end tell
        """
        do {
            _ = try await runAppleScript(source)
            return .object([
                "status": .string("completed"),
                "action": .string("sent"),
                "to": .string(to),
            ])
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
        let folder = inputString(input["folder"]) ?? "Notes"
        let titleAS = escapeForAppleScript(title)
        let bodyAS = escapeForAppleScript(body)
        let folderAS = escapeForAppleScript(folder)
        let source = """
        tell application "Notes"
            set targetFolder to missing value
            try
                set targetFolder to folder "\(folderAS)"
            end try
            if targetFolder is missing value then
                make new note with properties {name:"\(titleAS)", body:"\(bodyAS)"}
            else
                tell targetFolder
                    make new note with properties {name:"\(titleAS)", body:"\(bodyAS)"}
                end tell
            end if
            return "created"
        end tell
        """
        do {
            _ = try await runAppleScript(source)
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
