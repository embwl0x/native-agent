import AuthoredCapabilities
import Foundation
@preconcurrency import EventKit
import NativeAgentCore
import NativeAgentShared
import PersistenceCore
import Privacy
import MacIntegration
import ToolExecution
// Blueprint: | `LocalPIMConnectorActions.swift` | Shared EventKit authorization facts, scalar interpretation and argument refusals for Calendar and Reminders |

@MainActor
public enum LocalPIMConnectorActions {

    struct CalendarArgumentError: Error {
        let action: String
        let reason: String
        var result: JSONValue {
            .object(["status": .string("failed"), "actionId": .string(action), "effects": .string("none"), "reason": .string(reason)])
        }
    }

    /// The executor's parsers, without constructing a store or requesting access.
    public static func argumentRefusal(tool: String, input: [String: JSONValue]) -> JSONValue? {
        do throws(CalendarArgumentError) {
            switch tool {
            case "mac_calendar_modify_event": _ = try calendarModifyArguments(input: input)
            case "mac_calendar_delete_event": _ = try calendarDeleteExpectation(input: input)
            case "mac_reminders_delete": _ = try reminderDeleteExpectation(input: input)
            case "mac_reminders_update": _ = try reminderUpdateArguments(input: input)
            default: break
            }
            return nil
        } catch {
            return error.result
        }
    }

    /// Render the already-read OS grant shared by the engine's permission pages.
    public static func authorizationStatusPayload(localId: String, wizardStatus: String) -> [String: JSONValue] {
        let state: String = switch wizardStatus {
        case "granted", "authorized": "ready"
        case "not_determined": "probe_needed"
        case "limited", "denied", "restricted": "needs_permission"
        default: "unknown"
        }
        switch localId {
        case "local_calendar":
            return statusPayload(source: "calendar", state: state)
        case "local_reminders":
            return statusPayload(source: "reminders", state: state)
        default:
            return [:]
        }
    }

    static func parseInputDate(_ raw: JSONValue?) -> Date? {
        switch raw {
        case .string(let s):
            let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { return nil }
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime]
            if let d = formatter.date(from: trimmed) { return d }
            let fractional = ISO8601DateFormatter()
            fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let d = fractional.date(from: trimmed) { return d }
            if let epoch = TimeInterval(trimmed) {
                return Date(timeIntervalSince1970: epoch)
            }
            // A local time without a zone, or a bare day (midnight local).
            let local = DateFormatter()
            local.locale = Locale(identifier: "en_US_POSIX")
            local.timeZone = .current
            for format in ["yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd'T'HH:mm", "yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd HH:mm", "yyyy-MM-dd"] {
                local.dateFormat = format
                if let d = local.date(from: trimmed) { return d }
            }
            return nil
        case .int(let i):
            return Date(timeIntervalSince1970: TimeInterval(i))
        case .double(let d):
            return Date(timeIntervalSince1970: d)
        default:
            return nil
        }
    }

    static func calendarAuthorizationState() -> String {
        LocalPIMStore.authorizationState(for: .event)
    }

    static func reminderAuthorizationState() -> String {
        LocalPIMStore.authorizationState(for: .reminder)
    }

    private static func statusPayload(source: String, state: String) -> [String: JSONValue] {
        switch state {
        case "ready":
            return [
                "status": .string("ready"),
                "detail": .string("NativeAgent has read access to local \(source) data through EventKit."),
            ]
        case "probe_needed":
            return [
                "status": .string("probe_needed"),
                "detail": .string("NativeAgent can request local \(source) access directly from macOS."),
                "remedy": SystemPermissionPreflight.remedy(source) ?? .null,
            ]
        case "needs_permission":
            return [
                "status": .string("needs_permission"),
                "detail": .string("macOS has not granted NativeAgent read access to local \(source) data."),
                "remedy": SystemPermissionPreflight.remedy(source) ?? .null,
            ]
        default:
            return [
                "status": .string(state),
                "detail": .string("NativeAgent could not determine local \(source) access."),
            ]
        }
    }

    static func permissionEnvelope(actionId: String, source: String, status: String, mode: InlineInteraction.AccessMode? = nil) -> JSONValue {
        // A skill never opens a macOS prompt or asks for a grant: it hands back to her.
        if SkillRunContext.handsBack { return SkillRunContext.handBack("macOS \(source.capitalized) permission") }
        let message = "NativeAgent needs \(source.capitalized). Allow it on the permission card."
        return .object([
            "status": .string("needs_permission"),
            "actionId": .string(actionId),
            "source": .string("eventkit"),
            "access": .string(status),
            "message": .string(message),
            "remedy": SystemPermissionPreflight.remedy(source, mode: mode) ?? .null,
        ])
    }

    static func inputBool(_ raw: JSONValue?, defaultValue: Bool) -> Bool {
        switch raw {
        case .bool, .string: return ConnectorInputValue.bool(raw, default: defaultValue)
        default: return defaultValue
        }
    }

    nonisolated static func iso(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = .current
        return formatter.string(from: date)
    }
}
