import Foundation
import AppKit
import PersistenceCore

extension MacAppleScriptBridge {
    // MARK: - AppleScript invocation

    enum AppleScriptError: Error {
        case permissionDenied(app: String)
    }

    private static let appleScriptTimeoutSeconds: TimeInterval = 15
    private static let appleScriptQueue = DispatchQueue(label: "NativeAgent.MacAppleScriptBridge.appleScript")

    private final class AppleScriptContinuationGate: @unchecked Sendable {
        private let lock = NSLock()
        private var didResume = false

        func resume(
            _ continuation: CheckedContinuation<String, any Error>,
            result: Result<String, any Error>
        ) {
            lock.lock()
            defer { lock.unlock() }
            guard !didResume else { return }
            didResume = true
            continuation.resume(with: result)
        }
    }

    static func runAppleScript(_ source: String) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            let gate = AppleScriptContinuationGate()
            DispatchQueue.global(qos: .userInitiated).asyncAfter(
                deadline: .now() + appleScriptTimeoutSeconds
            ) {
                gate.resume(continuation, result: .failure(NSError(
                    domain: "NativeAgentAppleScript",
                    code: -1001,
                    userInfo: [NSLocalizedDescriptionKey:
                        "AppleScript timed out after \(Int(appleScriptTimeoutSeconds))s"]
                )))
            }
            appleScriptQueue.async {
                var error: NSDictionary?
                guard let script = NSAppleScript(source: source) else {
                    gate.resume(continuation, result: .failure(NSError(
                        domain: "NativeAgentAppleScript",
                        code: -500,
                        userInfo: [NSLocalizedDescriptionKey: "Failed to parse AppleScript"]
                    )))
                    return
                }
                let descriptor = script.executeAndReturnError(&error)
                if let error = error {
                    let message = error[NSAppleScript.errorMessage] as? String ?? "Unknown AppleScript error"
                    let number = error[NSAppleScript.errorNumber] as? Int ?? -1
                    // gpt-5.5 review NEEDS_FIX: broader TCC / Automation denial
                    // coverage. -1743 = not authorized to send Apple events,
                    // -10004 = privilege violation, -10010 = app not running /
                    // can't be opened, -1719 = invalid index (assistive access).
                    // Also catch message-based denials — some TCC paths return
                    // the user-facing strings without setting a known code.
                    let tccCodes: Set<Int> = [-1743, -10004, -10010, -1719, -27676]
                    let lowered = message.lowercased()
                    let messageSignals = [
                        "not authori", "not allowed", "denied", "access",
                        "automation", "assistive",
                    ]
                    let messageMatch = messageSignals.contains { lowered.contains($0) }
                    if tccCodes.contains(number) || messageMatch {
                        gate.resume(continuation, result: .failure(AppleScriptError.permissionDenied(
                            app: appNameFromError(message)
                        )))
                    } else {
                        gate.resume(continuation, result: .failure(NSError(
                            domain: "NativeAgentAppleScript",
                            code: number,
                            userInfo: [NSLocalizedDescriptionKey: message]
                        )))
                    }
                    return
                }
                // gpt-5.5 review NEEDS_FIX: distinguish "script ran and returned
                // an explicit empty string" (legitimate empty list) from "script
                // returned nil descriptor" (possible silent TCC denial). The
                // former → return "" so downstream parsers emit 0 records; the
                // latter → throw permission-denied so the chat tool fails
                // closed instead of falsely reporting an empty inbox.
                if descriptor.stringValue == nil {
                    gate.resume(continuation, result: .failure(AppleScriptError.permissionDenied(
                        app: "an app"
                    )))
                } else {
                    gate.resume(continuation, result: .success(descriptor.stringValue ?? ""))
                }
            }
        }
    }

    private static func appNameFromError(_ msg: String) -> String {
        for app in ["Mail", "Messages", "Notes", "Music"] {
            if msg.contains(app) { return app }
        }
        return "an app"
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
        let ns = error as NSError
        return .object([
            "status": .string("failed"),
            "integration": .string(integration),
            "error_code": .int(Int64(ns.code)),
            "error": .string(ns.localizedDescription),
        ])
    }

    static func failedEnvelope(integration: String, reason: String) -> JSONValue {
        .object([
            "status": .string("failed"),
            "integration": .string(integration),
            "reason": .string(reason),
        ])
    }

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
            value = Int(d)
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
    /// inserted backslashes), then double quotes, then strip control chars
    /// that would terminate the literal (CR/LF — AppleScript string literals
    /// can't span lines without explicit `& return &` concatenation).
    static func escapeForAppleScript(_ s: String) -> String {
        var out = s.replacingOccurrences(of: "\\", with: "\\\\")
        out = out.replacingOccurrences(of: "\"", with: "\\\"")
        out = out.replacingOccurrences(of: "\r\n", with: " ")
        out = out.replacingOccurrences(of: "\n", with: " ")
        out = out.replacingOccurrences(of: "\r", with: " ")
        return out
    }

    // MARK: - Output record parsers

    /// Parse `subject|||sender|||date|||snippet###...` into mail records.
    static func parseMailRecords(_ raw: String) -> [JSONValue] {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        var out: [JSONValue] = []
        for entry in trimmed.components(separatedBy: "###") {
            let e = entry.trimmingCharacters(in: .whitespacesAndNewlines)
            if e.isEmpty { continue }
            let parts = e.components(separatedBy: "|||")
            let subject = parts.indices.contains(0) ? parts[0] : ""
            let sender = parts.indices.contains(1) ? parts[1] : ""
            let date = parts.indices.contains(2) ? parts[2] : ""
            let snippet = parts.indices.contains(3) ? parts[3] : ""
            // gpt-5.5 review NEEDS_FIX: AppleScript's `(date as string)` is
            // locale-dependent; normalize to ISO-8601 so callers can rely on
            // a single format (matches Phase 1 EventKit output).
            let isoDate = Self.normalizeAppleScriptDate(date)
            out.append(.object([
                "subject": .string(subject),
                "sender": .string(sender),
                "date": .string(isoDate),
                "snippet": .string(snippet),
            ]))
        }
        return out
    }

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

    /// Parse `handle|||lastMessage|||lastMessageDate###...` into thread records.
    static func parseThreadRecords(_ raw: String) -> [JSONValue] {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        var out: [JSONValue] = []
        for entry in trimmed.components(separatedBy: "###") {
            let e = entry.trimmingCharacters(in: .whitespacesAndNewlines)
            if e.isEmpty { continue }
            let parts = e.components(separatedBy: "|||")
            let handle = parts.indices.contains(0) ? parts[0] : ""
            let lastMessage = parts.indices.contains(1) ? parts[1] : ""
            let lastDate = parts.indices.contains(2) ? parts[2] : ""
            out.append(.object([
                "handle": .string(handle),
                "lastMessage": .string(lastMessage),
                "lastMessageDate": .string(Self.normalizeAppleScriptDate(lastDate)),
            ]))
        }
        return out
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
            let trackCount = Int(parts.indices.contains(2) ? parts[2] : "") ?? 0
            let persistentID = parts.indices.contains(3) ? parts[3] : ""
            let specialKind = parts.indices.contains(4) ? parts[4] : ""
            playlists.append(.object([
                "index": .int(Int64(index)),
                "name": .string(name),
                "track_count": .int(Int64(trackCount)),
                "persistent_id": .string(persistentID),
                "special_kind": .string(specialKind),
            ]))
        }
        return (total, playlists)
    }

    /// Parse `name|||body_preview|||modified_at###...` into note records.
    static func parseNoteRecords(_ raw: String) -> [JSONValue] {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        var out: [JSONValue] = []
        for entry in trimmed.components(separatedBy: "###") {
            let e = entry.trimmingCharacters(in: .whitespacesAndNewlines)
            if e.isEmpty { continue }
            let parts = e.components(separatedBy: "|||")
            let name = parts.indices.contains(0) ? parts[0] : ""
            let bodyPreview = parts.indices.contains(1) ? parts[1] : ""
            let modified = Self.normalizeAppleScriptDate(parts.indices.contains(2) ? parts[2] : "")
            out.append(.object([
                "name": .string(name),
                "body_preview": .string(bodyPreview),
                "modified_at": .string(modified),
            ]))
        }
        return out
    }
}
