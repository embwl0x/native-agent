import Foundation
import NativeAgentShared
import PersistenceCore
import NativeAgentCore
import TrustCenter
// Blueprint: | `SchedulerJobNormalizer.swift` | Strict scalar, payload and watch admission shared by the rhythm grammar and scheduled reads |

/// Shared admission prevents creation and execution from disagreeing on argument shape.
public struct ProactiveScanArguments: Sendable {
    public let reason: String
    public let limit: Int
    public let surfaceLimit: Int
    public let staleDays: Int

    public init(_ input: [String: JSONValue]) throws {
        let keys: Set<String> = ["reason", "limit", "surfaceLimit", "staleDays"]
        for key in input.keys.sorted() where !keys.contains(key) {
            throw TriggerSchedulerError.schedulerInvalid("Unknown proactive_scan parameter \(key)", path: "$.payload." + key)
        }
        func integer(_ key: String, default initial: Int, range: ClosedRange<Int>) throws -> Int {
            guard let raw = input[key] else { return initial }
            guard case .int(let number) = raw, let value = Int(exactly: number), range.contains(value) else {
                throw TriggerSchedulerError.schedulerInvalid("\(key) must be an integer in \(range)", path: "$.payload." + key)
            }
            return value
        }
        if let raw = input["reason"] {
            guard case .string(let text) = raw, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  text.count <= 120 else {
                throw TriggerSchedulerError.schedulerInvalid("reason must be nonempty text of at most 120 characters", path: "$.payload.reason")
            }
            reason = text
        } else { reason = "scheduled_proactive_scan" }
        limit = try integer("limit", default: 10, range: 1...50)
        surfaceLimit = try integer("surfaceLimit", default: 4, range: 0...12)
        staleDays = try integer("staleDays", default: 5, range: 1...Int.max)
    }

    public var payload: [String: JSONValue] {
        ["reason": .string(reason), "limit": .int(Int64(limit)),
         "surfaceLimit": .int(Int64(surfaceLimit)), "staleDays": .int(Int64(staleDays))]
    }
}

extension TriggerSchedulerError {
    /// The grammar owns its cause and accepted input through every door.
    static func schedulerInvalid(_ msg: String, code: String = "schedule_input_invalid", path: String = "$") -> ToolFailureError {
        ToolFailureError(msg, argumentPath: path, accepted: msg, effects: .none,
                         nextCall: ToolFailureError.call("app", ["action": .string("schedule.list")]),
                         code: code, instruction: "Correct \(path) in the schedule request; inspect scheduled reads with next_call.",
                         recovery: .correctArguments)
    }
}

/// The rhythm grammar's scalar readers and the payload admission of scheduled reads.
public enum SchedulerJobNormalizer {
    static func string(_ value: JSONValue?) -> String? {
        if case .string(let text)? = value { return text }; return nil
    }

    /// Current documented units may use numeric strings; booleans and fractions are never integers. Absence is handled only by the field's own default.
    static func integer(_ value: JSONValue?) throws -> Int {
        switch value {
        case .int(let count)?:
            guard let count = Int(exactly: count) else { break }; return count
        case .double(let count)?:
            guard count.isFinite, let count = Int(exactly: count) else { break }; return count
        case .string(let text)?:
            guard let count = Int(text.trimmingCharacters(in: .whitespaces)) else { break }; return count
        default: break
        }
        throw TriggerSchedulerError.schedulerInvalid("expected a whole integer")
    }

    static func firstPresent(_ values: JSONValue?...) -> JSONValue? { values.first { $0 != nil } ?? nil }

    static func integerOr(_ values: JSONValue?..., default value: Int) throws -> Int {
        for field in values { if let field { return try integer(field) } }
        return value
    }

    /// A watch names a read and its input; a scan takes the proactive scan's arguments.
    static func validatePayload(kind: String, payload: [String: JSONValue]) throws {
        switch kind {
        case "connector_action":
            guard let action = string(payload["actionId"]), !action.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw TriggerSchedulerError.schedulerInvalid("payload.actionId is required", path: "$.payload.actionId")
            }
            if let input = payload["input"], case .object = input {} else if payload["input"] != nil {
                throw TriggerSchedulerError.schedulerInvalid("payload.input must be an object", path: "$.payload.input")
            }
        case "proactive_scan":
            _ = try ProactiveScanArguments(payload)
        default:
            throw TriggerSchedulerError.schedulerInvalid("""
                kind must be connector_action (a watch) or proactive_scan. Use queue.add {text, when, until?, say?} for intentions, check-ins and \
                reminders; a part wakes on a schedule:<cron> in its own header.
                """, path: "$.kind")
        }
    }

    /// Only null, empty text or an empty array mean no weekdays.
    static func isEmptyForWeekdays(_ v: JSONValue) -> Bool {
        switch v {
        case .null: return true
        case .string(let s): return s.isEmpty
        case .array(let a): return a.isEmpty
        default: return false
        }
    }
}

extension SwiftNativeTriggerScheduler {
    /// A scheduled read is a watch: its action runs through the app door as a read, and what changed comes to the agent as news. Nil when `action` is such a
    /// read; otherwise why not, in words the agent can act on. Scheduling and each run ask it.
    public static func watchRefusal(action: String, input: [String: JSONValue], turn: Turn?) -> String? {
        let declared: ToolClass?
        do { declared = try PermissionLaw.doorClass(action: action, args: input, turn: turn) }
        catch {
            return "The action's effect class is unavailable: \(error.localizedDescription). Repair its action catalog before scheduling this watch."
        }
        switch declared {
        case .read?: return nil
        case nil: return """
            No app action is called \(action). A watch reads through the app door (app {find} names the reads; a part of yours runs as authored.<id>), and \
            what changed comes to you as news.
            """
        case let other?: return """
            \(action) is a \(other), and a watch only reads: what changed comes to you as news. To act on a schedule, give a part a schedule:<cron> wake \
            instead.
            """
        }
    }
}
