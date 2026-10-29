import AuthoredCapabilities
import Foundation
import NativeAgentShared
import MacControl
import PersistenceCore
import NativeAgentCore
// Blueprint: | `MacAppleScriptBridge+Runtime.swift` | `MacAppleScriptBridge`: delegates `runAppleScript` to MacControl, skill hand-back and integration envelopes; `deniedEnvelope`; Music recipe/parsers live in the editable `Resources/abilities/music-library.js` and `music.js` seeds, called through L0 `Parts.call` by MacIntegrationDeliveryActions; the playback receipt and effects survive failed readback as a separate `now_playing` fact, and exact title/artist selection uses Unicode full case folding |

extension MacAppleScriptBridge {
    // MARK: - AppleScript invocation

    typealias AppleScriptError = AppleScriptExecution.AppleScriptError

    static func runAppleScript(_ source: String, bundleID: String) async throws -> String {
        do { return try await AppleScriptExecution.runIntegrationScript(source, bundleID: bundleID) }
        catch let AppleScriptError.permissionDenied(app) {
            if SkillRunContext.handsBack { throw SkillRunContext.HandBack("Automation of \(app)") }
            throw AppleScriptError.permissionDenied(app: app)
        }
    }

    // MARK: - Envelopes

    static func deniedEnvelope(integration: String, app: String) -> JSONValue {
        .object([
            "status": .string("denied"),
            "reason": .string("os_automation_denied"),
            "integration": .string(integration),
            "app": .string(app),
            "remedy": AppleScriptExecution.automationTargetBundleIDs[app].flatMap { SystemPermissionPreflight.remedy("applescript:" + $0) } ?? .null,
        ])
    }

    static func failedEnvelope(integration: String, error: Error) -> JSONValue {
        if let back = error as? SkillRunContext.HandBack { return SkillRunContext.handBack(back.why) }
        let ns = error as NSError
        if ns.domain == "NativeAgentAppleScript", ns.code == AppleScriptExecution.appleScriptOutcomeUnknownCode {
            return .object([
                "status": .string("unknown"),
                "receipt_owner": .string("applescript"), "result_class": .string("unknown"), "effects": .string("unknown"),
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

    static func failedEnvelope(integration: String, reason: String, message: String? = nil) -> JSONValue {
        var envelope: [String: JSONValue] = [
            "status": .string("failed"),
            "integration": .string(integration),
            "reason": .string(reason),
        ]
        if let message { envelope["message"] = .string(message) }
        // A refusal or a miss before the change; a send Mail declined may still sit in its Outbox.
        if reason != "mail_refused_send" { envelope["effects"] = .string("none") }
        return .object(envelope)
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
    /// Missing requested Notes folder, followed by the available folder names.
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

    package static func clampedInt(_ raw: JSONValue?, defaultValue: Int, min: Int, max: Int) -> Int {
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

    static func inputStringArray(_ raw: JSONValue?) -> [String] {
        switch raw {
        case .string(let s) where !s.isEmpty:
            return [s]
        case .array(let arr):
            return arr.compactMap { $0.scalarText }.filter { !$0.isEmpty }
        default:
            return []
        }
    }

    // MARK: - AppleScript string escaping

    /// Escapes backslashes, then quotes, then CR/LF so approved line breaks survive safely.
    static func escapeForAppleScript(_ s: String) -> String {
        var out = s.replacingOccurrences(of: "\\", with: "\\\\")
        out = out.replacingOccurrences(of: "\"", with: "\\\"")
        out = out.replacingOccurrences(of: "\r\n", with: "\\n")
        out = out.replacingOccurrences(of: "\n", with: "\\n")
        out = out.replacingOccurrences(of: "\r", with: "\\r")
        return out
    }

    // MARK: - Output record parsers

    /// Converts localized AppleScript dates to ISO-8601, retaining unparseable dates as text.
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
                return NativeTimestampFormat.plainZulu(d)
            }
        }
        // Fall back to raw; downstream just gets the locale string.
        return trimmed
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
                  case .bool? = row["title_line_elided"],
                  case .bool? = row["truncated"] else {
                throw NSError(domain: "NativeAgentNotes", code: -1, userInfo: [NSLocalizedDescriptionKey: "Notes returned an incomplete JSON record."])
            }
            row["modified_at"] = .string(Self.normalizeAppleScriptDate(modified))
            return .object(row)
        }
        return (total, notes)
    }
}
