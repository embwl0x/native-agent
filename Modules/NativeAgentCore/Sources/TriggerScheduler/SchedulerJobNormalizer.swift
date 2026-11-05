import Foundation
import NativeAgentShared
import PersistenceCore
import Privacy
import os
import NativeAgentCore
import TrustCenter
import Experiences
import NotificationInbox
import Darwin
// Blueprint: | `SchedulerJobNormalizer.swift` | Strict job admission shared by creation, updates and execution |

/// Shared admission prevents creation, updates and execution from disagreeing on argument shape.
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

public enum SchedulerJobNormalizer {
    static let allowedKinds: Set<String> = [
        "connector_action", "dream", "rem", "part", "harness_benchmark", "proactive_scan",
    ]

    // MARK: top-level normalize

    public static func normalize(
        body: [String: JSONValue],
        now: @Sendable () -> Date,
        uuid: @Sendable () -> String
    ) throws -> JSONValue {
        let payload: [String: JSONValue]
        if let value = body["payload"], value != .null {
            guard case .object(let fields) = value else {
                throw TriggerSchedulerError.schedulerInvalid("payload must be an object")
            }
            payload = fields
        } else { payload = [:] }
        guard let kind = string(body["kind"]), allowedKinds.contains(kind) else {
            throw TriggerSchedulerError.schedulerInvalid(
                "Unsupported scheduled Desk task kind. Use queue.add {text, when, until?, say?} for intentions, check-ins and reminders.")
        }
        if kind == "proactive_scan" {
            for key in ["reason", "limit", "surfaceLimit", "surface_limit", "staleDays", "stale_days", "sources"] where body[key] != nil {
                throw TriggerSchedulerError.schedulerInvalid("proactive_scan parameters belong in payload", path: "$." + key)
            }
        }
        try validatePayload(kind: kind, payload: payload)
        for key in ["id", "name", "createdBy"] where body[key] != nil {
            guard let value = string(body[key]), !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw TriggerSchedulerError.schedulerInvalid("\(key) must be a nonblank string")
            }
        }
        if let enabled = body["enabled"], case .bool = enabled {} else if body["enabled"] != nil {
            throw TriggerSchedulerError.schedulerInvalid("enabled must be Boolean")
        }
        // Normalize public units once so every saved row carries a schedule.
        let supplied = ["in_minutes", "interval_seconds", "schedule"].filter { body[$0] != nil && body[$0] != .null }
        guard supplied.count == 1 else {
            throw TriggerSchedulerError.schedulerInvalid("Supply exactly one of schedule, in_minutes or interval_seconds")
        }
        var schedule: [String: JSONValue]
        if let minutes = body["in_minutes"], minutes != .null {
            schedule = try onceInMinutes(minutes, now: now)
        } else if let seconds = body["interval_seconds"], seconds != .null {
            guard case .int(let count) = seconds, count >= 60 else {
                throw TriggerSchedulerError.schedulerInvalid("interval_seconds must be an integer of at least 60")
            }
            schedule = ["type": .string("every"), "seconds": seconds]
        } else {
            switch body["schedule"] {
            case .object(let fields)?: schedule = fields
            case .string(let raw)?:
                let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                let words = text.lowercased().split(whereSeparator: { $0.isWhitespace })
                if words.first == "in" {
                    guard words.count == 3, ["minute", "minutes"].contains(words[2]), let count = Double(words[1]) else {
                        throw TriggerSchedulerError.schedulerInvalid("Relative schedule must say in N minutes")
                    }
                    schedule = try onceInMinutes(.double(count), now: now)
                } else {
                    guard parseISO(text) != nil else { throw TriggerSchedulerError.schedulerInvalid("schedule must name an ISO-8601 time") }
                    schedule = ["type": .string("once"), "at": .string(text)]
                }
            default: throw TriggerSchedulerError.schedulerInvalid("schedule must be an object or time string")
            }
        }
        if scheduleType(schedule) == "cron", let expression = schedule.removeValue(forKey: "cron") {
            guard schedule["expression"] == nil else {
                throw TriggerSchedulerError.schedulerInvalid("Supply schedule.expression or schedule.cron, not both")
            }
            schedule["expression"] = expression
        }
        try validateSchedule(schedule)
        var interval = 0
        let typeLower = scheduleType(schedule)
        // Schedules follow the Mac's local clock and zone; local/system selectors are accepted without storing a zone.
        for key in ["timezone", "tz"] {
            guard let zone = string(schedule.removeValue(forKey: key))?.trimmingCharacters(in: .whitespaces),
                  !["", "local", "system"].contains(zone.lowercased()) else { continue }
            throw TriggerSchedulerError.schedulerInvalid("""
                Schedules run on this Mac's local clock and follow it when it changes zone; remove \(key) \(zone). For one moment elsewhere, give an ISO-8601 \
                time with its offset.
                """)
        }
        if typeLower == "every" {
            interval = try everyInterval(schedule)
            schedule["seconds"] = .int(Int64(interval))
            for key in ["minutes", "hours", "days", "interval_seconds", "intervalSeconds"] {
                schedule.removeValue(forKey: key)
            }
        }

        let oneShot = typeLower == "once"
        let nextRun = try nextFromSchedule(schedule, afterEpoch: nil, now: now)
        let name = (string(body["name"]) ?? titleCased(kind.replacingOccurrences(of: "_", with: " "))).prefixString(160)
        var outPayload = payload
        switch kind {
        case "dream", "rem":
            if payload["objective"] == nil {
                outPayload["objective"] = .string(kind == "rem" ? "Scheduled REM consolidation" : "Scheduled reflection")
            }
        case "proactive_scan":
            outPayload = try ProactiveScanArguments(payload).payload
        case "connector_action":
            guard let actionId = string(payload["actionId"]) else {
                throw TriggerSchedulerError.schedulerInvalid("connector_action requires payload.actionId")
            }
            let input = payload["input"]?.objectValue ?? [:] // input is optional and checked above.
            // Validate the saved job's declaration; no execution turn has been admitted.
            if let refusal = SwiftNativeTriggerScheduler.watchRefusal(action: actionId, input: input, turn: nil) {
                throw TriggerSchedulerError.schedulerInvalid(refusal)
            }
            outPayload["input"] = .object(input)
        default: break
        }
        let id = string(body["id"]) ?? uuid()
        let enabled = body["enabled"] == nil || body["enabled"] == .bool(true)
        let createdBy = string(body["createdBy"]) ?? "agent"

        var job: [String: JSONValue] = [
            "id": .string(id),
            "name": .string(name),
            "kind": .string(kind),
            "intervalSeconds": !oneShot && typeLower == "every" ? .int(Int64(interval)) : .null,
            "enabled": .bool(enabled),
            "oneShot": .bool(oneShot),
            "nextRunAt": .string(floatString(nextRun)),
            "nextRunAtEpoch": .int(try checkedEpoch(nextRun)),
            "lastRunAt": .null,
            "schedule": .object(schedule),
            "payload": .object(outPayload),
            "createdBy": .string(createdBy),
            "createdAt": .string(nowIso(now())),
        ]
        if typeLower != "every", !oneShot {
            job.removeValue(forKey: "intervalSeconds")
        }
        job["nextWallClockOccurrence"] = SchedulerJobRuntime.wallClockOccurrence(for: job, epoch: nextRun).map(JSONValue.string)
        return .object(job)
    }

    // MARK: checked scalar and payload fields

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

    static func boolValue(_ value: JSONValue?, default defaultValue: Bool) -> Bool {
        if case .bool(let flag)? = value { return flag }
        return value == nil ? defaultValue : false // saved authority is checked before this projection.
    }

    static func validatePayload(kind: String, payload: [String: JSONValue]) throws {
        func text(_ key: String, required: Bool = false) throws {
            guard let value = payload[key] else {
                if required { throw TriggerSchedulerError.schedulerInvalid("payload.\(key) is required") }; return
            }
            guard let value = string(value), !required || !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw TriggerSchedulerError.schedulerInvalid("payload.\(key) must be a string")
            }
        }
        switch kind {
        case "connector_action":
            try text("actionId", required: true)
            if let input = payload["input"], case .object = input {} else if payload["input"] != nil {
                throw TriggerSchedulerError.schedulerInvalid("payload.input must be an object")
            }
        case "part":
            try text("part", required: true); try text("signal", required: true)
            guard string(payload["signal"])?.hasPrefix("schedule:") == true else {
                throw TriggerSchedulerError.schedulerInvalid("payload.signal must be schedule:<cron>")
            }
        case "dream", "rem": try text("objective")
        case "proactive_scan":
            _ = try ProactiveScanArguments(payload)
        default: break
        }
    }

    /// Shape validation never advances a clock or searches a year of cron minutes.
    static func validateSchedule(_ fields: [String: JSONValue]) throws {
        guard let type = string(fields["type"]), rhythmKinds.union(["once"]).contains(type) else {
            throw TriggerSchedulerError.schedulerInvalid("schedule.type must name once, every, hourly, daily, weekly, monthly or cron")
        }
        for key in ["timezone", "tz"] {
            if let raw = fields[key] {
                guard let zone = string(raw), ["", "local", "system"].contains(zone.lowercased()) else {
                    throw TriggerSchedulerError.schedulerInvalid("\(key) must use this Mac's local clock; remove the saved selector")
                }
            }
        }
        for key in ["hour", "minute", "day", "monthday", "monthDay", "seconds", "minutes", "hours", "days", "interval_seconds", "intervalSeconds"] {
            if let value = fields[key] { _ = try integer(value) }
        }
        switch type {
        case "once":
            guard let at = fields["at"], floatEpochForDecoration(at) != nil || string(at).flatMap({ parseISO($0) }) != nil else {
                throw TriggerSchedulerError.schedulerInvalid("once requires schedule.at as an epoch or ISO-8601 time")
            }
        case "every": _ = try everyInterval(fields)
        case "hourly":
            let minute = try fields["minute"].map { try integer($0) } ?? 0
            guard (0...59).contains(minute) else { throw TriggerSchedulerError.schedulerInvalid("minute out of range") }
        case "daily", "weekly", "monthly":
            _ = try timeParts(fields)
            if type == "weekly" { _ = try weekdaySet(fields["weekdays"]) }
            if type == "monthly" {
                let day = try integerOr(fields["day"], fields["monthday"], fields["monthDay"], default: 1)
                guard (1...31).contains(day) else { throw TriggerSchedulerError.schedulerInvalid("monthly day must be 1 through 31") }
            }
        case "cron":
            guard let expression = string(fields["expression"]) else { throw TriggerSchedulerError.schedulerInvalid("cron requires expression") }
            _ = try cronFields(expression)
        default: break
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

    static func titleCased(_ s: String) -> String {
        s.split(separator: " ", omittingEmptySubsequences: false)
            .map { word -> String in
                guard let first = word.first else { return String(word) }
                return String(first).uppercased() + word.dropFirst().lowercased()
            }
            .joined(separator: " ")
    }

    /// Stable numeric text preserves the saved occurrence instant.
    static func floatString(_ d: Double) -> String {
        if d.isFinite, d == d.rounded(), abs(d) < 1e16 {
            return String(format: "%.1f", d)
        }
        return String(d)
    }

    static func nowIso(_ date: Date) -> String {
        SwiftNativeTriggerScheduler.isoTimestamp(date)
    }

    // MARK: list_jobs nextRunAt decoration

    /// Resolve timing through SchedulerJobRuntime; ambiguous wall-clock timing stays null with a warning. Keep one timestamp owner; one-offs omit irrelevant
    /// intervals and unrelated metadata passes through.
    static func decorateNextRunAt(_ row: JSONValue) -> JSONValue {
        guard case .object(var d) = row else { return row }
        d.removeValue(forKey: "nextRunAtISO")
        if case .object? = d["schedule"] {
            d["mac_timezone"] = .string(TimeZone.autoupdatingCurrent.identifier)
            if let due = SchedulerJobRuntime.scheduledEpoch(for: d) {
                d["nextRunAt"] = .string(floatString(due))
                d["timezone_detail"] = .string("Follows the Mac: \(TimeZone.autoupdatingCurrent.identifier).")
            } else if SchedulerJobRuntime.wallClockSchedule(d) != nil {
                d["timezone_warning"] = .string("Wall-clock occurrence is ambiguous. Review and save this schedule before it can run.")
                d["nextRunAt"] = .null
                d["nextRunAtEpoch"] = .null
            }
        }
        // One-offs have no interval; discard irrelevant default-hourly decoration.
        let calendarTypes: Set<String> = ["once", "hourly", "daily", "weekly", "monthly", "cron"]
        let scheduleType: String? = {
            guard case .object(let schedule)? = d["schedule"] else { return nil }
            return SchedulerJobNormalizer.scheduleType(schedule)
        }()
        if d["oneShot"] == .bool(true) || scheduleType == "once" {
            d["intervalSeconds"] = .null
        } else if scheduleType.map(calendarTypes.contains) == true {
            d.removeValue(forKey: "intervalSeconds")
        }
        let epoch = floatEpochForDecoration(d["nextRunAt"])
        if let epoch {
            let iso = epochToDecorationISO(epoch)
            d["nextRunAtEpoch"] = .double(epoch)
            d["nextRunAt"] = .string(iso)
        }
        return .object(d)
    }

    /// Accept finite numeric values/strings, including zero, for saved nextRunAt decoration; empty/null/invalid values return nil.
    static func floatEpochForDecoration(_ raw: JSONValue?) -> Double? {
        switch raw {
        case .none, .some(.null):
            return nil
        case .some(.string(let s)):
            if s.isEmpty { return nil }
            let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let v = Double(trimmed), v.isFinite else { return nil }
            return v
        case .some(.int(let i)):
            return Double(i)
        case .some(.double(let d)):
            return d.isFinite ? d : nil
        case .some(.bool):
            return nil
        case .some(.array), .some(.object):
            return nil
        }
    }

    /// Saved decoration uses +00:00, omits zero fractions and otherwise renders six microsecond digits with ties-to-even rounding.
    static func epochToDecorationISO(_ epoch: Double) -> String {
        NativeTimestampFormat.microsecondUTCOffset(Date(timeIntervalSince1970: epoch), rounding: .toNearestOrEven)
    }


}

private extension String {
    /// Persisted text bounds count Unicode scalars, not extended grapheme clusters.
    func prefixString(_ n: Int) -> String {
        let scalars = unicodeScalars
        if scalars.count <= n { return self }
        return String(String.UnicodeScalarView(scalars.prefix(n)))
    }
}
