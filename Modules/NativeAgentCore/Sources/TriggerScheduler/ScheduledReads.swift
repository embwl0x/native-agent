import Foundation
import NativeAgentShared
import NativeAgentCore
import PersistenceCore
// Blueprint: | `ScheduledReads.swift` | `ScheduledReads`: create, list and cancel checked `watch:<id>` and `scan:<id>` clock times |

/// What the agent schedules through `schedule.*`: a watch (a read through the app door whose new rows come to the agent as news) or a proactive scan.
/// Each is one time on the one clock, its payload beside it; the clock delivers it to the `watch` or `scan` owner.
public enum ScheduledReads {
    /// The kind the agent names, and the clock owner it is delivered to.
    static let owners: [String: String] = ["connector_action": "watch", "proactive_scan": "scan"]

    public static func create(_ input: [String: JSONValue], dataRoot: URL, now: Date = Date()) async throws -> JSONValue {
        let kind = SchedulerJobNormalizer.string(input["kind"])?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        var payload: [String: JSONValue]
        switch input["payload"] {
        case .object(let fields)?: payload = fields
        case nil, .null?: payload = [:]
        default: throw TriggerSchedulerError.schedulerInvalid("payload must be an object", path: "$.payload")
        }
        try SchedulerJobNormalizer.validatePayload(kind: kind, payload: payload)
        guard let owner = owners[kind] else { throw TriggerSchedulerError.schedulerInvalid("kind is unsupported", path: "$.kind") }
        if kind == "connector_action" {
            let action = SchedulerJobNormalizer.string(payload["actionId"]) ?? ""
            let read = payload["input"]?.objectValue ?? [:]
            if let refusal = SwiftNativeTriggerScheduler.watchRefusal(action: action, input: read, turn: nil) {
                throw TriggerSchedulerError.schedulerInvalid(refusal, path: "$.payload.actionId")
            }
            payload = ["actionId": .string(action), "input": .object(read)]
        } else {
            payload = try ProactiveScanArguments(payload).payload
        }
        let named = SchedulerJobNormalizer.string(input["name"])?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard named.count <= 160 else { throw TriggerSchedulerError.schedulerInvalid("name must be at most 160 characters", path: "$.name") }
        payload["name"] = .string(named.isEmpty ? (kind == "proactive_scan" ? "Proactive scan" : "Watch " + (payload["actionId"]?.stringValue ?? "")) : named)
        let key = SchedulerJobNormalizer.string(input["id"])?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let id = owner + ":" + (key.isEmpty ? UUID().uuidString.lowercased() : key)
        let when = try timing(input, now: now)
        let clock = OneClock.at(dataRoot)
        guard try await clock.times(owner: owner).allSatisfy({ $0.id != id }) else {
            throw TriggerSchedulerError.schedulerInvalid("A scheduled read with id \(id) already exists; cancel it first or choose another id", path: "$.id")
        }
        let time = OneClock.Time(id: id, rhythm: when.rhythm, next: when.next, payload: .object(payload))
        try await clock.declare(time)
        return .object(["status": .string("completed"), "read": try row(time)])
    }

    public static func list(dataRoot: URL) async throws -> JSONValue {
        let clock = OneClock.at(dataRoot)
        var rows: [JSONValue] = []
        for owner in owners.values.sorted() { rows += try await clock.times(owner: owner).map { try row($0) } }
        return .object(["status": .string("completed"), "count": .int(Int64(rows.count)), "reads": .array(rows)])
    }

    /// Withdraw one scheduled read by its canonical id; an unknown id refuses.
    public static func cancel(_ id: String, dataRoot: URL) async throws -> JSONValue {
        let wanted = id.trimmingCharacters(in: .whitespacesAndNewlines)
        let clock = OneClock.at(dataRoot)
        var matches: [OneClock.Time] = []
        for owner in owners.values.sorted() {
            matches += try await clock.times(owner: owner).filter { $0.id == wanted }
        }
        guard !wanted.isEmpty, matches.count == 1, let time = matches.first else {
            throw ToolFailureError("No scheduled read is called \(id).", argumentPath: "$.job_id", accepted: "An id from schedule.list.", effects: .none)
        }
        let withdrawn = try row(time)
        try await clock.withdraw(time.id)
        return .object(["status": .string("completed"), "withdrawn": withdrawn])
    }

    /// A watch keeps the row keys its last read saw beside its time, so only rows new since then become news. A watch no longer on the clock (a single
    /// moment already delivered, or cancelled) never reads again, so nothing is kept for it.
    public static func remember(seen: [String], watch id: String, dataRoot: URL) async throws {
        let clock = OneClock.at(dataRoot)
        guard var time = try await clock.times(owner: "watch").first(where: { $0.id == id }) else { return }
        var payload = try checkedPayload(time)
        payload["seen"] = .array(seen.map(JSONValue.string))
        time.payload = .object(payload)
        try await clock.declare(time)
    }

    /// Exactly one of in_minutes (one moment), interval_seconds (a rhythm) or schedule (a rhythm, or one moment as `{type: once, at}` or a time string).
    static func timing(_ input: [String: JSONValue], now: Date) throws -> (rhythm: JSONValue?, next: Date) {
        let supplied = ["in_minutes", "interval_seconds", "schedule"].filter { input[$0] != nil && input[$0] != .null }
        guard supplied.count == 1 else { throw TriggerSchedulerError.schedulerInvalid("Supply exactly one of schedule, in_minutes or interval_seconds") }
        if let minutes = input["in_minutes"], minutes != .null {
            return (nil, try SchedulerJobNormalizer.checkedNextOccurrence(try SchedulerJobNormalizer.onceInMinutes(minutes, now: { now }), after: now))
        }
        if let seconds = input["interval_seconds"], seconds != .null {
            guard case .int(let count) = seconds, count >= 60 else {
                throw TriggerSchedulerError.schedulerInvalid("interval_seconds must be an integer of at least 60", path: "$.interval_seconds")
            }
            let fields: [String: JSONValue] = ["type": .string("every"), "seconds": .int(count)]
            return (.object(fields), try SchedulerJobNormalizer.checkedNextOccurrence(fields, after: now))
        }
        switch input["schedule"] {
        case .object(let fields)?:
            if SchedulerJobNormalizer.scheduleType(fields) == "once" { return (nil, try SchedulerJobNormalizer.checkedNextOccurrence(fields, after: now)) }
            guard let rhythm = SchedulerJobNormalizer.rhythm(.object(fields)), case .object(let checked) = rhythm else {
                // The grammar's own words say what does not read; a shape it reads but that names no rhythm kind is refused here.
                _ = try SchedulerJobNormalizer.checkedNextOccurrence(fields, after: now)
                throw TriggerSchedulerError.schedulerInvalid("schedule.type must name once, every, hourly, daily, weekly, monthly or cron", path: "$.schedule")
            }
            return (rhythm, try SchedulerJobNormalizer.checkedNextOccurrence(checked, after: now))
        case .string(let text)?:
            if let rhythm = SchedulerJobNormalizer.rhythm(.string(text)), case .object(let checked) = rhythm {
                return (rhythm, try SchedulerJobNormalizer.checkedNextOccurrence(checked, after: now))
            }
            return (nil, try SchedulerJobNormalizer.checkedNextOccurrence(["type": .string("once"), "at": .string(text)], after: now))
        default:
            throw TriggerSchedulerError.schedulerInvalid("schedule must be an object or a time string", path: "$.schedule")
        }
    }

    private static func checkedPayload(_ time: OneClock.Time) throws -> [String: JSONValue] {
        guard let kind = owners.first(where: { $0.value == time.owner })?.key,
              case .object(let payload)? = time.payload,
              case .string? = payload["name"] else {
            throw TriggerSchedulerError.persistenceFailure("Scheduled read \(time.id) has no valid saved payload and name; repair clock/times.json.")
        }
        if let seen = payload["seen"] {
            guard time.owner == "watch", case .array(let keys) = seen,
                  keys.allSatisfy({ if case .string = $0 { return true }; return false }) else {
                throw TriggerSchedulerError.persistenceFailure("Scheduled read \(time.id) has invalid saved seen keys; repair clock/times.json.")
            }
        }
        var arguments = payload
        arguments["name"] = nil
        arguments["seen"] = nil
        try SchedulerJobNormalizer.validatePayload(kind: kind, payload: arguments)
        if time.owner == "watch", arguments["input"]?.objectValue == nil {
            throw TriggerSchedulerError.persistenceFailure("Watch \(time.id) has no saved input object; repair clock/times.json.")
        }
        return payload
    }

    static func row(_ time: OneClock.Time) throws -> JSONValue {
        var payload = try checkedPayload(time)
        payload["seen"] = nil
        guard let name = payload.removeValue(forKey: "name") else {
            throw TriggerSchedulerError.persistenceFailure("Scheduled read \(time.id) has no saved name; repair clock/times.json.")
        }
        return .object(["id": .string(time.id), "kind": .string(time.owner == "scan" ? "proactive_scan" : "connector_action"),
                        "name": name, "rhythm": time.rhythm ?? .null,
                        "next": .string(NativeTimestampFormat.fractionalUTCOffset(time.next)), "payload": .object(payload)])
    }
}
