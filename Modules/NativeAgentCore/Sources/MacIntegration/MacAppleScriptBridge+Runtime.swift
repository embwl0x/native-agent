import Foundation
import MacControl
import PersistenceCore

extension MacAppleScriptBridge {
    // MARK: - AppleScript invocation

    typealias AppleScriptError = SystemAppleScriptAdapter.AppleScriptError

    static func runAppleScript(_ source: String, bundleID: String) async throws -> String {
        do { return try await SystemAppleScriptAdapter.runIntegrationScript(source, bundleID: bundleID) }
        catch let AppleScriptError.permissionDenied(app) {
            if SkillRunContext.handsBack { throw SkillRunContext.HandBack("Automation of \(app)") }
            throw AppleScriptError.permissionDenied(app: app)
        }
    }

    static func isMusicNoCurrentTrackError(_ msg: String) -> Bool {
        let lowered = msg.lowercased()
        return lowered.contains("current track")
            || lowered.contains("class ptrk")
            || (lowered.contains("track") && lowered.contains("can't get"))
            || (lowered.contains("track") && lowered.contains("can’t get"))
            || (lowered.contains("track") && lowered.contains("can't make"))
            || (lowered.contains("track") && lowered.contains("can’t make"))
    }

    // MARK: - Envelopes

    static func deniedEnvelope(integration: String, app: String) -> JSONValue {
        .object([
            "status": .string("denied"),
            "reason": .string("os_automation_denied"),
            "integration": .string(integration),
            "app": .string(app),
            "fix": .string("Grant NativeAgent automation access to \(app) in System Settings → Privacy & Security → Automation."),
        ])
    }

    static func failedEnvelope(integration: String, error: Error) -> JSONValue {
        if let back = error as? SkillRunContext.HandBack { return SkillRunContext.handBack(back.why) }
        let ns = error as NSError
        if ns.domain == "NativeAgentAppleScript", ns.code == SystemAppleScriptAdapter.appleScriptOutcomeUnknownCode {
            return .object([
                "status": .string("unknown"),
                "reason": .string(ns.userInfo["state"] as? String ?? "outcome_unknown"),
                "integration": .string(integration),
                "error_code": .int(Int64(ns.code)),
                "error": .string(ns.localizedDescription),
            ])
        }
        var envelope: [String: JSONValue] = [
            "status": .string("failed"),
            "integration": .string(integration),
            "error_code": .int(Int64(ns.code)),
            "error": .string(ns.localizedDescription),
        ]
        if let state = ns.userInfo["state"] as? String { envelope["reason"] = .string(state) }
        return .object(envelope)
    }

    static func failedEnvelope(integration: String, reason: String) -> JSONValue {
        var envelope: [String: JSONValue] = [
            "status": .string("failed"),
            "integration": .string(integration),
            "reason": .string(reason),
        ]
        // A refusal or a miss before the change; a send Mail declined may still sit in its Outbox.
        if reason != "mail_refused_send" { envelope["effects"] = .string("none") }
        if let message = failureWords[reason] { envelope["message"] = .string(message) }
        return .object(envelope)
    }

    /// What to do next, one plain sentence per reason code (2026-09-24).
    static let failureWords: [String: String] = [
        "missing_query": "Nothing to search for: give a word or phrase in query.",
        "missing_to": "Say who it goes to in to (an email address).",
        "missing_subject": "Say which message: its message_id and expected_message_id from mail_list_recent, or its subject.",
        "missing_body": "Nothing to send or save: put the text in body.",
        "missing_title": "Give the note's title.",
        "invalid_message_locator": "message_id needs the expected_message_id from the same mail_list_recent row.",
        "message_not_in_inbox": "That message is no longer in the inbox; list it again with mail_list_recent and use the new message_id.",
        "message_changed_or_moved_refresh_inbox": "That message moved or changed; list the inbox again with mail_list_recent and use the new message_id.",
        "message_changed_or_ambiguous_refresh_inbox": "That message moved, changed, or its subject matches several; list the inbox again and reply by message_id.",
        "no_matching_message": "No inbox message matches; list the inbox with mail_list_recent and pass its message_id. An archived message is no longer in the inbox, so delete or mark it before archiving.",
        "mail_refused_send": "Mail refused to send it (no account can send, or it is offline); nothing went out.",
        "no_archive_mailbox": "Mail has no Archive mailbox, so nothing moved; leave it or use mail_delete.",
        "mail_delete_no_match": "No indexed message matches in Mail, including archived mail; nothing moved to Trash.",
        "mail_delete_target_changed": "The indexed message moved or changed before deletion; nothing moved to Trash. Locate it again before trying again.",
        "no_trash_mailbox": "Mail has no Trash mailbox for this message's account; nothing was deleted.",
        "message_already_in_trash": "That message is already in Trash; it was left there and was not permanently deleted.",
        "mail_index_unavailable": "Mail's message index could not be read (NativeAgent may need macOS Full Disk Access); nothing was listed or changed.",
        "thread_not_found": "That conversation is not in Messages now; list threads again with messages_recent_threads.",
        "invalid_history_cursor": "before_message_id works only with the same thread_id, using older_before_message_id from the last read.",
        "choose_recipient_or_thread": "Give one of to (a phone number or email) or thread_id, not both.",
        "read_thread_before_reply": "Open the thread first (messages_recent_threads with its thread_id) and pass its participant handles as expected_participants.",
        "invalid_expected_participants": "expected_participants must be the handles from the latest thread read, each once.",
        "participants_changed_read_thread_again": "The people in that thread changed; open it again and reply with the new participants. Nothing was sent.",
        "no_matching_note": "No note has that exact id or title; find it with notes_search and copy its full id or title.",
        "invalid_note_body_offset": "Use body_offset with the same note id and next_body_offset from its last read; the offset must be within the current text.",
        "missing_body_append_or_new_title": "Say what to change: body (replace), append, or new_title.",
        "body_and_append_mutually_exclusive": "Use body to replace or append to add, not both.",
    ]

    static func notConfiguredEnvelope(integration: String, fix: String) -> JSONValue {
        .object([
            "status": .string("failed"),
            "integration": .string(integration),
            "reason": .string("not_configured"),
            "fix": .string(fix),
        ])
    }

    static let mailNotConfiguredSentinel = "__NATIVEAGENT_MAIL_NOT_CONFIGURED__"
    static let notesNotConfiguredSentinel = "__NATIVEAGENT_NOTES_NOT_CONFIGURED__"
    /// 2026-09-06: `notes_create` answering that the folder the caller asked
    /// for does not exist, followed by the folder names that do.
    static let notesFolderMissingSentinel = "__NATIVEAGENT_NOTES_FOLDER_MISSING__"

    /// Converts only explicit setup sentinels. An empty script result remains
    /// a legitimate zero-result read and TCC errors stay owned by the caller's
    /// denied/error catches.
    static func readSetupEnvelope(raw: String, integration: String) -> JSONValue? {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        switch (integration, value) {
        case ("mail", mailNotConfiguredSentinel):
            return notConfiguredEnvelope(
                integration: "mail",
                fix: "Add and enable a Mail account in System Settings → Internet Accounts."
            )
        case ("notes", notesNotConfiguredSentinel):
            return notConfiguredEnvelope(
                integration: "notes",
                fix: "Open Notes and enable an iCloud or local Notes account."
            )
        default:
            return nil
        }
    }

    // MARK: - Input helpers

    static func clampedInt(_ raw: JSONValue?, defaultValue: Int, min: Int, max: Int) -> Int {
        let value: Int
        switch raw {
        case .int(let i):
            value = Int(i)
        case .double(let d):
            value = Int(exactly: d.rounded(.towardZero)) ?? defaultValue
        case .string(let s):
            value = Int(s.trimmingCharacters(in: .whitespacesAndNewlines)) ?? defaultValue
        default:
            value = defaultValue
        }
        return Swift.max(min, Swift.min(max, value))
    }

    static func inputString(_ raw: JSONValue?) -> String? {
        switch raw {
        case .string(let s): return s
        case .int(let i): return String(i)
        case .double(let d): return String(d)
        case .bool(let b): return b ? "true" : "false"
        default: return nil
        }
    }

    static func inputStringArray(_ raw: JSONValue?) -> [String] {
        switch raw {
        case .string(let s) where !s.isEmpty:
            return [s]
        case .array(let arr):
            return arr.compactMap { inputString($0) }.filter { !$0.isEmpty }
        default:
            return []
        }
    }

    // MARK: - AppleScript string escaping

    /// Escape a user-supplied string for safe injection into an AppleScript
    /// string literal. Backslashes first (so we don't double-escape our own
    /// inserted backslashes), then double quotes, then the line breaks.
    ///
    /// 2026-09-06: CR/LF used to be replaced with a SPACE, so an approved
    /// multiline body — a mail send, a Messages send, a note — went out
    /// reflowed onto one line, which is not what the operator approved. An
    /// AppleScript string literal cannot span source lines, but it does accept
    /// `\n` and `\r` escapes inside itself, so the break survives as a break
    /// and the literal still cannot be terminated early.
    static func escapeForAppleScript(_ s: String) -> String {
        var out = s.replacingOccurrences(of: "\\", with: "\\\\")
        out = out.replacingOccurrences(of: "\"", with: "\\\"")
        out = out.replacingOccurrences(of: "\r\n", with: "\\n")
        out = out.replacingOccurrences(of: "\n", with: "\\n")
        out = out.replacingOccurrences(of: "\r", with: "\\r")
        return out
    }

    // MARK: - Output record parsers

    /// Convert AppleScript's localized date string ("Saturday, June 7, 2026
    /// at 10:42:00 AM") to ISO-8601 ("2026-06-07T10:42:00Z"). On parse failure
    /// returns the raw input — better than dropping the field.
    static func normalizeAppleScriptDate(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return "" }
        let formats = [
            "EEEE, MMMM d, yyyy 'at' h:mm:ss a",
            "EEEE, MMMM d, yyyy 'at' HH:mm:ss",
            "MMMM d, yyyy 'at' h:mm:ss a",
            "yyyy-MM-dd HH:mm:ss Z",
        ]
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.timeZone = TimeZone.current
        for f in formats {
            fmt.dateFormat = f
            if let d = fmt.date(from: trimmed) {
                let iso = ISO8601DateFormatter()
                iso.formatOptions = [.withInternetDateTime]
                return iso.string(from: d)
            }
        }
        // Fall back to raw; downstream just gets the locale string.
        return trimmed
    }

    /// Parse `name|||artist|||album|||duration###...` into music track records.
    static func parseMusicTrackRecords(_ raw: String) -> [JSONValue] {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        var out: [JSONValue] = []
        for entry in trimmed.components(separatedBy: "###") {
            let e = entry.trimmingCharacters(in: .whitespacesAndNewlines)
            if e.isEmpty { continue }
            let parts = e.components(separatedBy: "|||")
            let name = parts.indices.contains(0) ? parts[0] : ""
            let artist = parts.indices.contains(1) ? parts[1] : ""
            let album = parts.indices.contains(2) ? parts[2] : ""
            let durationRaw = parts.indices.contains(3) ? parts[3] : ""
            let duration = Double(durationRaw.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
            out.append(.object([
                "name": .string(name),
                "artist": .string(artist),
                "album": .string(album),
                "duration_seconds": .double(duration),
            ]))
        }
        return out
    }

    static func parseMusicPagedTrackRecords(
        _ raw: String,
        offset: Int,
        limit: Int
    ) -> (total: Int, tracks: [JSONValue]) {
        let parts = raw.components(separatedBy: ":::PAGE:::")
        let total = Int(parts.first?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "") ?? 0
        let recordsRaw = parts.dropFirst().joined(separator: ":::PAGE:::")
        let trimmed = recordsRaw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return (total, []) }
        var tracks: [JSONValue] = []
        tracks.reserveCapacity(limit)
        for entry in trimmed.components(separatedBy: "###") {
            let e = entry.trimmingCharacters(in: .whitespacesAndNewlines)
            if e.isEmpty { continue }
            let parts = e.components(separatedBy: "|||")
            let index = Int(parts.indices.contains(0) ? parts[0] : "") ?? (offset + tracks.count + 1)
            let name = parts.indices.contains(1) ? parts[1] : ""
            let artist = parts.indices.contains(2) ? parts[2] : ""
            let album = parts.indices.contains(3) ? parts[3] : ""
            let durationRaw = parts.indices.contains(4) ? parts[4] : ""
            let persistentID = parts.indices.contains(5) ? parts[5] : ""
            let duration = Double(durationRaw.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
            tracks.append(.object([
                "index": .int(Int64(index)),
                "name": .string(name),
                "artist": .string(artist),
                "album": .string(album),
                "duration_seconds": .double(duration),
                "persistent_id": .string(persistentID),
            ]))
        }
        return (total, tracks)
    }

    static func parseMusicPlaylistRecords(
        _ raw: String,
        offset: Int,
        limit: Int
    ) -> (total: Int, playlists: [JSONValue]) {
        let parts = raw.components(separatedBy: ":::PAGE:::")
        let total = Int(parts.first?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "") ?? 0
        let recordsRaw = parts.dropFirst().joined(separator: ":::PAGE:::")
        let trimmed = recordsRaw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return (total, []) }
        var playlists: [JSONValue] = []
        playlists.reserveCapacity(limit)
        for entry in trimmed.components(separatedBy: "###") {
            let e = entry.trimmingCharacters(in: .whitespacesAndNewlines)
            if e.isEmpty { continue }
            let parts = e.components(separatedBy: "|||")
            let index = Int(parts.indices.contains(0) ? parts[0] : "") ?? (offset + playlists.count + 1)
            let name = parts.indices.contains(1) ? parts[1] : ""
            let trackCount = Int64(parts.indices.contains(2) ? parts[2] : "").flatMap { $0 >= 0 ? $0 : nil }
            let persistentID = parts.indices.contains(3) ? parts[3] : ""
            let specialKind = parts.indices.contains(4) ? parts[4] : ""
            playlists.append(.object([
                "index": .int(Int64(index)),
                "name": .string(name),
                "track_count": trackCount.map(JSONValue.int) ?? .string("unknown"),
                "persistent_id": .string(persistentID),
                "special_kind": .string(specialKind),
            ]))
        }
        return (total, playlists)
    }

    static func parseNoteRecords(_ raw: String) throws -> (total: Int64, notes: [JSONValue]) {
        let payload = try JSONDecoder().decode(JSONValue.self, from: Data(raw.utf8))
        guard case .object(let root) = payload, case .int(let total)? = root["total"], total >= 0,
              case .array(let records)? = root["notes"], records.count <= total else {
            throw NSError(domain: "NativeAgentNotes", code: -1, userInfo: [NSLocalizedDescriptionKey: "Notes returned invalid JSON records."])
        }
        let notes = try records.map { record -> JSONValue in
            guard case .object(var row) = record, case .string(let id)? = row["id"], !id.isEmpty,
                  case .string(let modified)? = row["modified_at"],
                  case .string? = row["body"] ?? row["body_preview"],
                  case .bool? = row["truncated"] else {
                throw NSError(domain: "NativeAgentNotes", code: -1, userInfo: [NSLocalizedDescriptionKey: "Notes returned an incomplete JSON record."])
            }
            row["modified_at"] = .string(Self.normalizeAppleScriptDate(modified))
            return .object(row)
        }
        return (total, notes)
    }
}
