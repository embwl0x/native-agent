import AuthoredCapabilities
import Foundation
import NativeAgentShared
import MacControl
import PersistenceCore
import NativeAgentCore
// Blueprint: | `MacAppleScriptBridge+Runtime.swift` | `MacAppleScriptBridge`, `runAppleScript`, `deniedEnvelope`, `Resources/abilities/music-library.js`, `music.js`, `Parts.call`, `now_playing`: shared script envelopes and Music parts |

extension MacAppleScriptBridge {
    // MARK: - AppleScript invocation

    typealias AppleScriptError = AppleScriptExecution.AppleScriptError

    static func runAppleScript(_ source: String, bundleID: String, context: MacOperationContext) async throws -> String {
        do { return try await AppleScriptExecution.runIntegrationScript(source, bundleID: bundleID, context: context) }
        catch let AppleScriptError.permissionDenied(app) {
            if context.handsBack { throw SkillRunContext.HandBack("Automation of \(app)") }
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
        if let refusal = error as? MacAppActRefusal { return .object(refusal.fields) }
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
    static let notesFolderMissingSentinel = "__NATIVEAGENT_NOTES_FOLDER_MISSING__"

    /// Converts only explicit setup sentinels. An empty script result remains a legitimate zero-result read and TCC errors stay owned by the caller's
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

    package static func clampedInt(_ raw: JSONValue?, defaultValue: Int, min: Int, max: Int) throws -> Int {
        guard let raw else { return Swift.max(min, Swift.min(max, defaultValue)) }
        let value: Int?
        switch raw {
        case .int(let i):
            value = Int(exactly: i)
        case .double(let d):
            value = Int(exactly: d)
        case .string(let s):
            value = Int(s.trimmingCharacters(in: .whitespacesAndNewlines))
        default:
            value = nil
        }
        guard let value else { throw NSError(domain: "NativeAgentInput", code: -400,
            userInfo: [NSLocalizedDescriptionKey: """
                A supplied numeric limit, offset or duration is not an integer. Correct the argument; defaults apply only when omitted.
                """]) }
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

    /// Escape backslashes before quotes and line breaks so approved text remains literal AppleScript content.
    static func escapeForAppleScript(_ s: String) -> String {
        var out = s.replacingOccurrences(of: "\\", with: "\\\\")
        out = out.replacingOccurrences(of: "\"", with: "\\\"")
        out = out.replacingOccurrences(of: "\r\n", with: "\\n")
        out = out.replacingOccurrences(of: "\n", with: "\\n")
        out = out.replacingOccurrences(of: "\r", with: "\\r")
        return out
    }

    // MARK: - Output record parsers

    /// Converts supported AppleScript date spellings to ISO-8601; unsupported dates remain a read failure.
    static func normalizeAppleScriptDate(_ raw: String) throws -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { throw NSError(domain: "NativeAgentDate", code: -1,
            userInfo: [NSLocalizedDescriptionKey: "AppleScript returned no date. Read the source again."]) }
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
        throw NSError(domain: "NativeAgentDate", code: -1, userInfo: [NSLocalizedDescriptionKey: """
            AppleScript returned an unsupported localized date. Repair the source date adapter before reading it again.
            """])
    }

    static func parseNoteRecords(_ raw: String) throws -> (total: Int64, notes: [JSONValue], gaps: [String]) {
        let payload = try JSONDecoder().decode(JSONValue.self, from: Data(raw.utf8))
        guard case .object(let root) = payload, case .int(let total)? = root["total"], total >= 0,
              case .array(let records)? = root["notes"], records.count <= total,
              case .array(let rawGaps)? = root["gaps"] else {
            throw NSError(domain: "NativeAgentNotes", code: -1, userInfo: [NSLocalizedDescriptionKey: "Notes returned invalid JSON records."])
        }
        var gaps = try rawGaps.map { gap -> String in
            guard case .string(let detail) = gap, !detail.isEmpty else {
                throw NSError(domain: "NativeAgentNotes", code: -1, userInfo: [NSLocalizedDescriptionKey: "Notes returned an invalid gap record."])
            }
            return detail
        }
        var notes: [JSONValue] = []
        for (index, record) in records.enumerated() {
            do {
                guard case .object(var row) = record, case .string(let id)? = row["id"], !id.isEmpty,
                      case .string(let modified)? = row["modified_at"],
                      case .string? = row["body"] ?? row["body_preview"],
                      case .bool? = row["title_line_elided"],
                      case .bool? = row["truncated"] else {
                    throw NSError(domain: "NativeAgentNotes", code: -1, userInfo: [NSLocalizedDescriptionKey: "Notes returned an incomplete JSON record."])
                }
                row["modified_at"] = .string(try Self.normalizeAppleScriptDate(modified))
                notes.append(.object(row))
            } catch { gaps.append("notes[\(index)]: \(error.localizedDescription)") }
        }
        return (total, notes, gaps)
    }
}
