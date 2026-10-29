import Foundation
import NativeAgentShared
import PersistenceCore
import Privacy
import os
import NativeAgentCore
import TrustCenter
import WorkshopExecution
import Experiences
import NotificationInbox
import Darwin
// Blueprint: | `SchedulerJobNormalizer.swift` | SchedulerJobNormalizer canonical job input normalization, delivery channels, saved scalar coercion and timing decoration |

public enum SchedulerJobNormalizer {
    static let allowedKinds: Set<String> = [
        "notify", "connector_action", "dream", "rem", "harness_benchmark", "proactive_scan", "workshop", "turn",
    ]

    // MARK: top-level normalize

    static func normalize(
        body: [String: JSONValue],
        now: @Sendable () -> Date,
        uuid: @Sendable () -> String,
        displayNameFallback: String
    ) throws -> JSONValue {
        let payload: [String: JSONValue]
        if case .object(let p)? = body["payload"] { payload = p } else { payload = [:] }

        let kind = (string(pyOr(body["kind"], .string("notify"))) ?? "notify")
            .trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard allowedKinds.contains(kind) else {
            throw TriggerSchedulerError.schedulerInvalid("Unsupported scheduled Desk task kind: \(kind)")
        }

        var interval = try max(60, pyIntOr(
            body["interval_seconds"], body["intervalSeconds"], payload["interval_seconds"],
            default: 3600
        ))

        // schedule resolution.
        var schedule: [String: JSONValue]
        let scheduleShapes = "schedule accepts an ISO-8601 time, 'in N minutes', or an object: type once with at, every with an interval, or hourly/daily/weekly/monthly/cron; alternatively in_minutes, interval_seconds or run_at"
        switch (body["in_minutes"], body["schedule"]) {
        case (let minutes?, _) where minutes != .null:
            guard [body["schedule"], body["interval_seconds"], body["intervalSeconds"],
                   payload["interval_seconds"], body["run_at"], body["runAt"], body["nextRunAt"]]
                .allSatisfy({ $0 == nil || $0 == .null }) else {
                throw TriggerSchedulerError.schedulerInvalid("Supply in_minutes alone, not with another schedule, interval or run time.")
            }
            schedule = try onceInMinutes(minutes, now: now)
        case (_, .object(let raw)):
            schedule = raw
            // An object without a type is named by its own fields: a time is once, an interval is every,
            // a cron is cron. Anything else is refused; a bare {at} must never become hourly
            // (10-29: {at} saved as a 3600 s repeat that would have posted to the user every hour).
            // Named the way the runner reads it (SchedulerRecurrence: type, then kind).
            if (string(raw["type"]) ?? string(raw["kind"]))?.trimmingCharacters(in: .whitespaces).isEmpty ?? true {
                if [raw["at"], raw["run_at"], raw["runAt"]].contains(where: { $0?.isTruthy == true }) {
                    schedule["type"] = .string("once")
                } else if [raw["seconds"], raw["minutes"], raw["hours"], raw["days"], raw["interval_seconds"], raw["intervalSeconds"]]
                            .contains(where: { $0?.isTruthy == true }) {
                    schedule["type"] = .string("every")
                } else if raw["cron"]?.isTruthy == true || raw["expression"]?.isTruthy == true {
                    schedule["type"] = .string("cron")
                } else {
                    throw TriggerSchedulerError.schedulerInvalid(scheduleShapes)
                }
            }
        case (_, .string(let raw)):
            let at = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            let words = at.lowercased().split(whereSeparator: { $0.isWhitespace })
            if words.first == "in" {
                guard words.count == 3, ["minute", "minutes"].contains(words[2]),
                      let minutes = Double(words[1]) else {
                    throw TriggerSchedulerError.schedulerInvalid("Relative schedule must say 'in N minutes', with a positive number of minutes.")
                }
                schedule = try onceInMinutes(.double(minutes), now: now)
            } else {
                guard parseISO(at) != nil else { throw TriggerSchedulerError.schedulerInvalid(scheduleShapes) }
                schedule = ["type": .string("once"), "at": .string(at)]
            }
        case (_, nil), (_, .null?):
            let hasInterval = [body["interval_seconds"], body["intervalSeconds"], payload["interval_seconds"]]
                .contains(where: { $0?.isTruthy == true })
            let hasRunAt = [body["run_at"], body["runAt"], body["nextRunAt"]]
                .contains(where: { $0?.isTruthy == true })
            // No schedule at all must not silently become hourly.
            guard hasInterval || hasRunAt else {
                throw TriggerSchedulerError.schedulerInvalid(scheduleShapes)
            }
            schedule = scheduleFromLegacyBody(body, interval: interval)
        default:
            throw TriggerSchedulerError.schedulerInvalid(scheduleShapes)
        }

        let typeLower = scheduleType(schedule)
        // Schedules follow the Mac's local clock and zone; local/system selectors are accepted without storing a zone.
        for key in ["timezone", "tz"] {
            guard let zone = string(schedule.removeValue(forKey: key))?.trimmingCharacters(in: .whitespaces),
                  !["", "local", "system"].contains(zone.lowercased()) else { continue }
            throw TriggerSchedulerError.schedulerInvalid("Schedules run on this Mac's local clock and follow it when it changes zone; remove \(key) \(zone). For one moment elsewhere, give an ISO-8601 time with its offset.")
        }
        if typeLower == "every" {
            interval = try everyInterval(schedule, default: interval)
            schedule["seconds"] = .int(Int64(interval))
            for key in ["minutes", "hours", "days", "interval_seconds", "intervalSeconds"] {
                schedule.removeValue(forKey: key)
            }
        }

        let oneShot = isOneShot(body, schedule: schedule)

        // First-run aliases select the first truthy value.
        let firstRun = pyOr(schedule["firstRunAt"], body["run_at"], body["runAt"])
        let scheduledRun = try nextFromSchedule(schedule, afterEpoch: nil, now: now)
        let nextRun: Double
        if let fr = firstRun, fr.isTruthy {
            nextRun = try epochFromValue(fr, zone: .autoupdatingCurrent, now: now)
            schedule["firstRunAt"] = fr
        } else {
            nextRun = scheduledRun
        }

        let nameRaw = string(pyOr(
            body["name"], payload["name"],
            // A job without a name is called by its own title before its kind.
            body["title"], payload["title"],
            .string(titleCased(kind.replacingOccurrences(of: "_", with: " "))),
            .string("Scheduled Desk task")
        )) ?? "Scheduled Desk task"
        let name = nameRaw.prefixString(160)

        // per-kind payload normalization.
        var outPayload: [String: JSONValue]
        switch kind {
        case "notify":
            let title = (string(pyOr(
                payload["title"], body["title"],
                .string(name), .string(displayNameFallback)
            )) ?? displayNameFallback).prefixString(120)
            let message = (string(pyOr(
                payload["message"], payload["body"], body["message"], .string("")
            )) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if message.isEmpty {
                throw TriggerSchedulerError.schedulerInvalid("notify scheduled Desk tasks require payload.message")
            }
            let delivery = try deliveryChannels(payload)
            outPayload = [
                "title": .string(title),
                "message": .string(message.prefixString(1000)),
                "source": .string(string(pyOr(payload["source"], .string("scheduled_job"))) ?? "scheduled_job"),
                "delivery": .array(delivery.map { .string($0) }),
            ]
            if case .string(let projectSpaceId)? = payload["projectSpaceId"], !projectSpaceId.isEmpty {
                outPayload["projectSpaceId"] = .string(projectSpaceId.prefixString(160))
            }
            let rawOpts = pyOr(payload["deliveryOptions"], payload["delivery_options"], .object([:]))
            if case .object(let opts)? = rawOpts {
                outPayload["deliveryOptions"] = .object(opts)
            }
        case "dream", "rem":
            var objective = (string(pyOr(payload["objective"], body["objective"], .string(""))) ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if objective.isEmpty {
                objective = kind == "rem" ? "Scheduled REM consolidation" : "Scheduled reflection"
            }
            outPayload = ["objective": .string(objective.prefixString(2000))]
        case "workshop":
            let objective = (string(pyOr(payload["objective"], body["objective"], .string(""))) ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !objective.isEmpty else {
                throw TriggerSchedulerError.schedulerInvalid("workshop scheduled Desk tasks require payload.objective")
            }
            let title = (string(pyOr(payload["title"], body["title"], .string(name))) ?? name)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let expectedEvidence = (string(pyOr(
                payload["expectedEvidence"], payload["expected_evidence"], .string("canonical Workshop completion receipt")
            )) ?? "canonical Workshop completion receipt")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            // Its result is the Desk task's own completion receipt; a workshop job
            // carries no delivery of its own, so none is stored to promise one.
            outPayload = [
                "title": .string((title.isEmpty ? name : title).prefixString(160)),
                "objective": .string(objective.prefixString(2000)),
                "expectedEvidence": .string(expectedEvidence.prefixString(500)),
            ]
        case "turn":
            let prompt = (string(pyOr(payload["prompt"], body["prompt"], .string(""))) ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !prompt.isEmpty else {
                throw TriggerSchedulerError.schedulerInvalid("turn jobs require payload.prompt")
            }
            let title = (string(pyOr(payload["title"], body["title"], .string(name))) ?? name)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            outPayload = [
                "prompt": .string(prompt.prefixString(4000)),
                "title": .string((title.isEmpty ? name : title).prefixString(160)),
            ]
        case "proactive_scan":
            let reason = (string(pyOr(
                payload["reason"], body["reason"], .string("scheduled_proactive_scan")
            )) ?? "scheduled_proactive_scan").prefixString(120)
            let limit = try max(1, min(pyIntOr(payload["limit"], body["limit"], default: 10), 50))
            let surfaceLimit = try max(0, min(pyIntOr(
                payload["surfaceLimit"], payload["surface_limit"], body["surfaceLimit"],
                default: 4
            ), 12))
            outPayload = [
                "reason": .string(reason),
                "limit": .int(Int64(limit)),
                "surfaceLimit": .int(Int64(surfaceLimit)),
            ]
            // Source aliases select the first truthy value, otherwise [].
            let rawSources = pyOr(payload["sources"], body["sources"], .array([]))
            if case .array(let arr)? = rawSources {
                let sources = arr.prefix(8).compactMap { v -> JSONValue? in
                    let s = string(v) ?? ""
                    guard !s.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
                    return .string(s.prefixString(80))
                }
                outPayload["sources"] = .array(sources)
            }
        case "connector_action":
            let actionId = (string(pyOr(
                payload["actionId"], payload["action_id"], payload["id"],
                body["actionId"], body["action_id"], body["action"]
            )) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !actionId.isEmpty else {
                throw TriggerSchedulerError.schedulerInvalid("connector_action scheduled Desk tasks require payload.actionId")
            }
            let rawInput = pyOr(payload["input"], body["input"], .object([:]))
            let input: [String: JSONValue]
            if case .object(let obj)? = rawInput {
                input = obj
            } else {
                throw TriggerSchedulerError.schedulerInvalid("connector_action scheduled Desk tasks require payload.input to be an object when provided")
            }
            if let refusal = SwiftNativeTriggerScheduler.watchRefusal(action: actionId, input: input) {
                throw TriggerSchedulerError.schedulerInvalid(refusal)
            }
            outPayload = [
                "actionId": .string(actionId),
                "input": .object(input),
            ]
        default:
            outPayload = payload
        }

        let id = string(pyOr(body["id"], .string(uuid()))) ?? uuid()
        let enabled = boolValue(body["enabled"], default: true)
        let createdBy = string(pyOr(body["createdBy"], .string("agent"))) ?? "agent"

        var job: [String: JSONValue] = [
            "id": .string(id),
            "name": .string(name),
            "kind": .string(kind),
            "intervalSeconds": !oneShot && typeLower == "every" ? .int(Int64(interval)) : .null,
            "enabled": .bool(enabled),
            "oneShot": .bool(oneShot),
            "nextRunAt": .string(pyFloatString(nextRun)),
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

    /// Omitted or explicitly empty delivery is push; invalid destinations refuse.
    public static func deliveryChannels(_ payload: [String: JSONValue]) throws -> [String] {
        let raw = payload["delivery"] ?? payload["deliveries"] ?? payload["channels"] ?? payload["notifyVia"]
        let values: [String]
        switch raw {
        case .some(.array(let arr)):
            if arr.isEmpty { return ["push"] }
            values = try arr.map {
                guard case .string(let value) = $0 else {
                    throw TriggerSchedulerError.schedulerInvalid("delivery must contain only channel names.")
                }
                return value
            }
        case .some(.string(let s)):
            let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
            if t.isEmpty { return ["push"] }
            values = s.replacingOccurrences(of: ",", with: " ")
                .split(separator: " ").map(String.init)
        case nil:
            return ["push"]
        default:
            throw TriggerSchedulerError.schedulerInvalid("delivery must be a channel name or an array of channel names.")
        }
        let aliases: [String: String] = [
            "iphone": "push", "ios": "push", "apns": "push", "mobile": "push", "phone": "push",
            "telegram": "telegram", "tg": "telegram",
            "macos": "mac", "desktop": "mac", "mac": "mac",
            "chat": "chat", "session": "chat",
            "inbox": "inbox",
            "activity": "activity", "log": "activity",
        ]
        let canonical: Set<String> = ["push", "telegram", "mac", "chat", "inbox", "activity"]
        var channels: [String] = []
        for value in values {
            let lower = value.trimmingCharacters(in: .whitespaces).lowercased()
            let channel = aliases[lower] ?? lower
            guard canonical.contains(channel) else {
                throw TriggerSchedulerError.schedulerInvalid("Unsupported delivery channel '\(value)'. Use push, telegram, mac, chat, inbox, or activity.")
            }
            if !channels.contains(channel) {
                channels.append(channel)
            }
        }
        guard !channels.isEmpty else {
            throw TriggerSchedulerError.schedulerInvalid("delivery must name a channel. Use push, telegram, mac, chat, inbox, or activity.")
        }
        return channels
    }

    // MARK: scalar helpers
    //
    // Saved-schema coercion distinguishes truthiness, absence and strict integer parsing; Swift nil-coalescing is not equivalent.

    /// Saved scalar text uses True/False booleans and float formatting; collections/null/absence return nil.
    static func string(_ v: JSONValue?) -> String? {
        switch v {
        case .some(.string(let s)): return s
        case .some(.int(let i)): return String(i)
        case .some(.double(let d)): return pyFloatString(d)
        case .some(.bool(let b)): return b ? "True" : "False"
        default: return nil
        }
    }

    /// ID comparison stringifies scalars, maps absent/null to literal "None",
    /// and maps containers to a nonscalar sentinel.
    static func pyStrForId(_ v: JSONValue?) -> String {
        switch v {
        case .some(.array), .some(.object):
            return "\u{0}__nonscalar_id__"
        default: return string(v) ?? "None"
        }
    }

    /// Return the first truthy operand, or the final operand when all are falsey.
    static func pyOr(_ values: JSONValue?...) -> JSONValue? {
        for v in values where v?.isTruthy == true { return v }
        return values.last ?? nil
    }

    /// Parse integers, truncate finite representable floats and map booleans to 0/1; non-integer strings and other values throw.
    static func pyInt(_ v: JSONValue?) throws -> Int {
        switch v {
        case .some(.int(let i)): return Int(i)
        case .some(.double(let d)):
            guard let value = Int(exactly: d.rounded(.towardZero)) else {
                throw TriggerSchedulerError.schedulerInvalid("expected an integer")
            }
            return value
        case .some(.bool(let b)): return b ? 1 : 0
        case .some(.string(let s)):
            let t = s.trimmingCharacters(in: .whitespaces)
            if let i = Int(t) { return i }
            throw TriggerSchedulerError.schedulerInvalid("invalid integer literal: \(s)")
        case .some(.array), .some(.object), .some(.null), .none:
            throw TriggerSchedulerError.schedulerInvalid("expected an integer")
        }
    }

    /// Strictly parse the first truthy operand, or use the supplied default.
    static func pyIntOr(_ values: JSONValue?..., default def: Int) throws -> Int {
        for v in values where v?.isTruthy == true { return try pyInt(v) }
        return def
    }

    /// `bool(d.get(k, default))` — present-with-null is FALSEY; absent uses the
    /// stored default; present values follow saved truthiness.
    static func boolValue(_ v: JSONValue?, default def: Bool) -> Bool {
        guard let v else { return def }   // key absent → Python default
        return v.isTruthy
    }

    /// Empty weekday inputs are exactly null, "" or [].
    static func isEmptyForWeekdays(_ v: JSONValue) -> Bool {
        switch v {
        case .null: return true
        case .string(let s): return s.isEmpty
        case .array(let a): return a.isEmpty
        default: return false
        }
    }

    /// Python `str.title()` — capitalize first letter of each word.
    static func titleCased(_ s: String) -> String {
        s.split(separator: " ", omittingEmptySubsequences: false)
            .map { word -> String in
                guard let first = word.first else { return String(word) }
                return String(first).uppercased() + word.dropFirst().lowercased()
            }
            .joined(separator: " ")
    }

    /// Python `str(float)` — integral floats render as "N.0".
    static func pyFloatString(_ d: Double) -> String {
        if d.isFinite, d == d.rounded(), abs(d) < 1e16 {
            return String(format: "%.1f", d)
        }
        return String(d)
    }

    /// ISO-8601 UTC with offset and millisecond precision.
    static func nowIso(_ date: Date) -> String {
        SwiftNativeTriggerScheduler.isoTimestamp(date)
    }

    // MARK: list_jobs nextRunAt decoration

    /// Project timing through `SchedulerJobRuntime.scheduledEpoch`, then format
    /// the epoch as ISO. Ambiguous wall-clock timing is nulled with a warning.
    /// Non-object rows and other metadata pass through; one-offs omit the interval.
    static func decorateNextRunAt(_ row: JSONValue) -> JSONValue {
        guard case .object(var d) = row else { return row }
        if case .object? = d["schedule"] {
            d["mac_timezone"] = .string(TimeZone.autoupdatingCurrent.identifier)
            if let due = SchedulerJobRuntime.scheduledEpoch(for: d) {
                d["nextRunAt"] = .string(pyFloatString(due))
                d["timezone_detail"] = .string("Follows the Mac: \(TimeZone.autoupdatingCurrent.identifier).")
            } else if SchedulerJobRuntime.wallClockSchedule(d) != nil {
                d["timezone_warning"] = .string("Wall-clock occurrence is ambiguous. Review and save this schedule before it can run.")
                d["nextRunAt"] = .null
                d["nextRunAtEpoch"] = .null
                d["nextRunAtISO"] = .null
            }
        }
        // Older one-off and calendar rows retained the default hourly interval.
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
            // nextRunAtEpoch is a JSON number, including for integral epochs.
            d["nextRunAtEpoch"] = .double(epoch)
            d["nextRunAt"] = .string(iso)
            d["nextRunAtISO"] = .string(iso)
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
            // Boolean values are not valid saved timestamps.
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
