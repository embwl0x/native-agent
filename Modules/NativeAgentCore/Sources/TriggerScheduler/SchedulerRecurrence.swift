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
// Blueprint: | `SchedulerRecurrence.swift` | SchedulerJobNormalizer recurrence arithmetic, civil-minute matching and timestamp parsing |

extension SchedulerJobNormalizer {

    internal static func onceInMinutes(_ value: JSONValue, now: @Sendable () -> Date) throws -> [String: JSONValue] {
        let minutes: Double
        switch value {
        case .int(let number): minutes = Double(number)
        case .double(let number): minutes = number
        default: throw TriggerSchedulerError.schedulerInvalid("in_minutes must be a positive number.")
        }
        guard minutes.isFinite, minutes > 0 else {
            throw TriggerSchedulerError.schedulerInvalid("in_minutes must be a positive finite number.")
        }
        let epoch = now().timeIntervalSince1970 + minutes * 60
        _ = try checkedEpoch(epoch)
        return ["type": .string("once"), "at": .double(epoch)]
    }

    static func scheduleFromLegacyBody(_ body: [String: JSONValue], interval: Int) -> [String: JSONValue] {
        let rawRunAt = pyOr(body["run_at"], body["runAt"], body["nextRunAt"])
        if let r = rawRunAt, r.isTruthy, isOneShot(body) {
            return ["type": .string("once"), "run_at": r]
        }
        if let r = rawRunAt, r.isTruthy {
            return ["type": .string("every"), "seconds": .int(Int64(interval)), "firstRunAt": r]
        }
        return ["type": .string("every"), "seconds": .int(Int64(interval))]
    }

    static func epochFromValue(_ raw: JSONValue, zone: TimeZone, now: @Sendable () -> Date) throws -> Double {
        let nowEpoch = now().timeIntervalSince1970
        let epoch: Double
        switch raw {
        case .int(let i):
            epoch = Double(i)
        case .double(let d):
            epoch = d
        case .string(let s):
            let text = s.trimmingCharacters(in: .whitespacesAndNewlines)
            if text.isEmpty { throw TriggerSchedulerError.schedulerInvalid("run_at is required") }
            if let d = Double(text) { epoch = d }
            else if let parsed = parseISO(text, zone: zone) { epoch = parsed }
            else { throw TriggerSchedulerError.schedulerInvalid("run_at must be an epoch timestamp or ISO-8601 datetime") }
        case .null:
            throw TriggerSchedulerError.schedulerInvalid("run_at is required")
        default:
            throw TriggerSchedulerError.schedulerInvalid("run_at must be an epoch timestamp or ISO-8601 datetime")
        }
        _ = try checkedEpoch(epoch)
        let resolved = max(nowEpoch, epoch)
        _ = try checkedEpoch(resolved)
        return resolved
    }

    static func checkedEpoch(_ epoch: Double) throws -> Int64 {
        // ISO/civil scheduling supports Gregorian years 1...9999; occurrence
        // identity additionally requires rounded milliseconds to fit Int64.
        guard epoch.isFinite, (-62_135_596_800...253_402_300_799).contains(epoch),
              Int64(exactly: (epoch * 1_000).rounded()) != nil,
              let value = Int64(exactly: epoch.rounded(.towardZero)) else {
            throw TriggerSchedulerError.schedulerInvalid("run_at must be a finite epoch timestamp within the supported range")
        }
        return value
    }

    static func everyInterval(_ schedule: [String: JSONValue], default defaultInterval: Int = 3600) throws -> Int {
        var seconds = try pyIntOr(schedule["seconds"], default: 0)
        for (key, multiplier) in [("minutes", 60), ("hours", 3600), ("days", 86400)] {
            let value = try pyIntOr(schedule[key], default: 0)
            let product = value.multipliedReportingOverflow(by: multiplier)
            let sum = seconds.addingReportingOverflow(product.partialValue)
            guard !product.overflow, !sum.overflow else {
                throw TriggerSchedulerError.schedulerInvalid("schedule duration is too large")
            }
            seconds = sum.partialValue
        }
        return try max(60, pyIntOr(
            schedule["interval_seconds"], schedule["intervalSeconds"],
            seconds != 0 ? .int(Int64(seconds)) : nil,
            default: defaultInterval
        ))
    }

    static func scheduleType(_ schedule: [String: JSONValue]) -> String {
        (string(schedule["type"]) ?? string(schedule["kind"]) ?? "every")
            .trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    /// Once schedules win; flag aliases use the first present key, including null.
    public static func isOneShot(_ body: [String: JSONValue], schedule: [String: JSONValue]? = nil) -> Bool {
        if let minutes = body["in_minutes"], minutes != .null { return true }
        if case .string? = body["schedule"] { return true }
        return scheduleType(schedule ?? body["schedule"]?.objectValue ?? [:]) == "once"
            || boolValue(body["one_shot"] ?? body["oneShot"] ?? body["payload"]?.objectValue?["one_shot"], default: false)
    }

    /// Find the next occurrence in the supplied zone, defaulting to the Mac's current zone.
    static func nextFromSchedule(_ schedule: [String: JSONValue], afterEpoch: Double?, now: @Sendable () -> Date,
                                 zone tz: TimeZone = .autoupdatingCurrent) throws -> Double {
        let typ = scheduleType(schedule)
        let nowEpoch = afterEpoch ?? now().timeIntervalSince1970

        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = tz

        // after = the minute after the one the clock shows, kept as an instant:
        // in the hour a fall-back repeats, one reading names two instants.
        let offset = Double(tz.secondsFromGMT(for: Date(timeIntervalSince1970: nowEpoch)))
        let shown = ((nowEpoch + offset) / 60).rounded(.down) * 60
        let afterMinute = Date(timeIntervalSince1970: shown - offset + 60)
        // A minute the clock already showed is spent: one civil minute is one occurrence.
        func spent(_ date: Date) -> Bool { date.timeIntervalSince1970 + Double(tz.secondsFromGMT(for: date)) <= shown }

        switch typ {
        case "once":
            // Run-time aliases use their first truthy value.
            return try epochFromValue(pyOr(schedule["run_at"], schedule["runAt"], schedule["at"]) ?? .null, zone: tz, now: now)
        case "every":
            let resolved = try everyInterval(schedule)
            let nextRun = nowEpoch + Double(resolved)
            _ = try checkedEpoch(nextRun)
            return nextRun
        case "hourly", "daily", "weekly", "monthly", "cron":
            // An hourly minute is int(spec.get("minute", 0)), a present-default get.
            let (hour, minute) = typ == "cron" ? (0, 0) : typ == "hourly" ? (0, try schedule["minute"].map { try pyInt($0) } ?? 0) : try timeParts(schedule)
            guard (0...59).contains(minute) else {
                throw TriggerSchedulerError.schedulerInvalid("hourly schedule minute out of range")
            }
            // Weekday aliases use their first truthy value.
            let weekdays = typ == "weekly" ? try weekdaySet(pyOr(schedule["weekdays"], schedule["weekday"])) : Set(0...6)
            // month_day = max(1, min(31, int(spec.day or monthday or monthDay or 1)))
            let monthDay = try max(1, min(31, pyIntOr(
                schedule["day"], schedule["monthday"], schedule["monthDay"],
                default: 1
            )))
            // Cron-expression aliases use their first truthy value.
            let expression = (string(pyOr(schedule["expression"], schedule["cron"], .string(""))) ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let fields: CronFields = try typ == "cron" ? cronFields(expression) : (
                minute: [minute], hour: typ == "hourly" ? Set(0...23) : [hour],
                day: typ == "monthly" ? [monthDay] : Set(1...31), month: Set(1...12),
                // Weekly inputs outside 0...6 must remain unable to match.
                dow: typ == "weekly" ? Set(weekdays.filter { (0...6).contains($0) }.map { ($0 + 1) % 7 }) : Set(0...6)
            )
            // Advance by calendar minutes so daylight-saving transitions retain civil occurrence rules.
            var candidate = afterMinute
            for _ in 0..<(370 * 24 * 60) {
                let c = cal.dateComponents([.hour, .minute, .day, .month, .weekday], from: candidate)
                if !spent(candidate), cronMatches(c, fields: fields) {
                    return candidate.timeIntervalSince1970
                }
                guard let nextCandidate = cal.date(byAdding: .minute, value: 1, to: candidate) else {
                    throw TriggerSchedulerError.schedulerInvalid("could not advance \(typ) candidate")
                }
                candidate = nextCandidate
            }
            throw TriggerSchedulerError.schedulerInvalid("Could not find next run for \(typ) schedule within one year")
        default:
            throw TriggerSchedulerError.schedulerInvalid("Unsupported schedule type: \(typ)")
        }
    }

    /// Parse at/time as H[:MM], otherwise strict hour/minute fields with defaults only when absent.
    static func timeParts(_ spec: [String: JSONValue], defaultHour: Int = 9, defaultMinute: Int = 0) throws -> (Int, Int) {
        let raw = pyOr(spec["at"], spec["time"])
        let hour: Int
        let minute: Int
        if let r = raw, r.isTruthy {
            // str(raw) then exact regex match over the WHOLE string.
            let text = string(r) ?? ""
            guard let (h, m) = parseHHMM(text) else {
                throw TriggerSchedulerError.schedulerInvalid("schedule.at must be HH:MM")
            }
            hour = h
            minute = m
        } else {
            // present-default get → strict int().
            hour = try spec["hour"].map { try pyInt($0) } ?? defaultHour
            minute = try spec["minute"].map { try pyInt($0) } ?? defaultMinute
        }
        guard (0...23).contains(hour), (0...59).contains(minute) else {
            throw TriggerSchedulerError.schedulerInvalid("scheduled hour/minute out of range")
        }
        return (hour, minute)
    }

    /// Match `^\s*(\d{1,2})(?::(\d{1,2}))?\s*$`: 1-2 digit hour,
    /// optional `:` + 1-2 digit minute, surrounded only by whitespace. Returns
    /// (hour, minute) — minute defaults to 0 when the `:MM` group is absent.
    static func parseHHMM(_ raw: String) -> (Int, Int)? {
        let s = raw.trimmingCharacters(in: .whitespaces)
        let parts = s.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count >= 1 else { return nil }
        let hStr = parts[0]
        guard (1...2).contains(hStr.count), hStr.allSatisfy({ $0.isASCII && $0.isNumber }), let h = Int(hStr) else {
            return nil
        }
        if parts.count == 2 {
            let mStr = parts[1]
            guard (1...2).contains(mStr.count), mStr.allSatisfy({ $0.isASCII && $0.isNumber }), let m = Int(mStr) else {
                return nil
            }
            return (h, m)
        }
        return (h, 0)
    }

    /// Normalize weekday names/numbers to 0=Monday through 6=Sunday.
    static func weekdaySet(_ raw: JSONValue?) throws -> Set<Int> {
        let names: [String: Int] = [
            "mon": 0, "monday": 0, "tue": 1, "tues": 1, "tuesday": 1,
            "wed": 2, "wednesday": 2, "thu": 3, "thur": 3, "thurs": 3, "thursday": 3,
            "fri": 4, "friday": 4, "sat": 5, "saturday": 5, "sun": 6, "sunday": 6,
        ]
        guard let raw, !isEmptyForWeekdays(raw) else { return Set(0...6) }
        let values: [String]
        if case .array(let arr) = raw {
            values = arr.map { string($0) ?? "" }
        } else {
            values = (string(raw) ?? "")
                .replacingOccurrences(of: ",", with: " ")
                .split(separator: " ").map(String.init)
        }
        var result: Set<Int> = []
        for item in values {
            let text = item.trimmingCharacters(in: .whitespaces).lowercased()
            if text == "weekday" || text == "weekdays" {
                result.formUnion([0, 1, 2, 3, 4])
            } else if text == "weekend" || text == "weekends" {
                result.formUnion([5, 6])
            } else if let n = names[text] {
                result.insert(n)
            } else if let value = Int(text) {
                result.insert(value >= 1 ? ((value - 1) % 7) : value)
            } else {
                throw TriggerSchedulerError.schedulerInvalid("Unknown weekday: \(item)")
            }
        }
        return result.isEmpty ? Set(0...6) : result
    }

    static func cronValues(_ field: String, minimum: Int, maximum: Int, names: [String: Int] = [:]) throws -> Set<Int> {
        var allowed: Set<Int> = []
        for partRaw in field.lowercased().split(separator: ",", omittingEmptySubsequences: false) {
            var part = String(partRaw).trimmingCharacters(in: .whitespaces)
            func namedOrInt(_ token: String) throws -> Int {
                let t = token.trimmingCharacters(in: .whitespaces)
                if let n = names[t] { return n }
                if t.allSatisfy({ $0.isNumber }), !t.isEmpty, let v = Int(t) { return v }
                throw TriggerSchedulerError.schedulerInvalid("cron token '\(token)' is invalid; use an integer from \(minimum) through \(maximum)\(names.isEmpty ? "" : " or " + names.keys.sorted().joined(separator: ", ")) in schedule.expression", code: "schedule_cron_token_invalid", path: "$.schedule.expression")
            }
            var step = 1
            if let slash = part.firstIndex(of: "/") {
                let stepText = String(part[part.index(after: slash)...]).trimmingCharacters(in: .whitespaces)
                part = String(part[..<slash])
                // Steps are integers clamped to at least one; nonnumeric input refuses.
                guard let parsedStep = Int(stepText), stepText.allSatisfy({ $0.isASCII && ($0.isNumber || $0 == "-") }) else {
                    throw TriggerSchedulerError.schedulerInvalid("cron step '\(stepText)' is not an integer; use */N in schedule.expression, for example */5", code: "schedule_cron_step_invalid", path: "$.schedule.expression")
                }
                step = max(1, parsedStep)
            }
            let start: Int
            let end: Int
            if part == "*" || part == "?" {
                start = minimum; end = maximum
            } else if let dash = part.firstIndex(of: "-") {
                let left = String(part[..<dash])
                let right = String(part[part.index(after: dash)...])
                start = try namedOrInt(left)
                end = try namedOrInt(right)
            } else {
                let value = try namedOrInt(part)
                start = value; end = value
            }
            guard (minimum...maximum).contains(start), (minimum...maximum).contains(end), start <= end else {
                throw TriggerSchedulerError.schedulerInvalid("cron range '\(part)' must ascend within \(minimum)...\(maximum); edit schedule.expression", code: "schedule_cron_range_invalid", path: "$.schedule.expression")
            }
            var value = start
            while value <= end {
                allowed.insert(value)
                if step > end - value { break }
                value += step
            }
        }
        return allowed
    }

    typealias CronFields = (minute: Set<Int>, hour: Set<Int>, day: Set<Int>, month: Set<Int>, dow: Set<Int>)

    static func cronFields(_ expression: String) throws -> CronFields {
        let fields = expression.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        guard fields.count == 5 else {
            throw TriggerSchedulerError.schedulerInvalid("schedule.expression needs 5 cron fields: minute hour day month weekday; for example 0 9 * * *", code: "schedule_cron_fields_invalid", path: "$.schedule.expression")
        }
        let weekdayNames: [String: Int] = ["sun": 0, "mon": 1, "tue": 2, "wed": 3, "thu": 4, "fri": 5, "sat": 6]
        let minute = try cronValues(fields[0], minimum: 0, maximum: 59)
        let hour = try cronValues(fields[1], minimum: 0, maximum: 23)
        let day = try cronValues(fields[2], minimum: 1, maximum: 31)
        let month = try cronValues(fields[3], minimum: 1, maximum: 12)
        let dow = try cronValues(fields[4], minimum: 0, maximum: 7, names: weekdayNames)
        return (minute, hour, day, month, dow)
    }

    static func cronMatches(_ c: DateComponents, fields: CronFields) -> Bool {
        // Calendar 1=Sunday maps to cron 0 (or 7).
        let cronDow = (c.weekday ?? 1) - 1
        let dowMatch = fields.dow.contains(cronDow) || (cronDow == 0 && fields.dow.contains(7))
        return fields.minute.contains(c.minute ?? -1)
            && fields.hour.contains(c.hour ?? -1)
            && fields.day.contains(c.day ?? -1)
            && fields.month.contains(c.month ?? -1)
            && dowMatch
    }

    /// Normalize Z to +00:00, accepting
    /// both `T` and space separators and naive (offset-less) forms, including
    /// date-only. We try, in order:
    ///   1. offset-bearing forms (with/without fractional seconds)
    ///   2. naive datetime forms → wall-clock time in `zone` (the Mac's
    ///      current zone unless the caller is doing civil arithmetic)
    ///   3. date-only `YYYY-MM-DD` → midnight in `zone`
    static func parseISO(_ text: String, zone: TimeZone = .autoupdatingCurrent) -> Double? {
        let normalized = text.replacingOccurrences(of: "Z", with: "+00:00")

        // 1. Offset-bearing (Internet date-time).
        if let d = NativeTimestampFormat.parseISO8601FractionalFirst(normalized) { return d.timeIntervalSince1970 }

        // 2 & 3. Naive forms (no offset) → `zone`. Accept both `T` and space.
        let candidates = ["yyyy-MM-dd'T'HH:mm:ss.SSSSSS",
                          "yyyy-MM-dd'T'HH:mm:ss.SSS",
                          "yyyy-MM-dd'T'HH:mm:ss",
                          "yyyy-MM-dd'T'HH:mm",
                          "yyyy-MM-dd HH:mm:ss.SSSSSS",
                          "yyyy-MM-dd HH:mm:ss.SSS",
                          "yyyy-MM-dd HH:mm:ss",
                          "yyyy-MM-dd HH:mm",
                          "yyyy-MM-dd"]
        for fmt in candidates {
            let df = DateFormatter()
            df.locale = Locale(identifier: "en_US_POSIX")
            df.timeZone = zone
            df.dateFormat = fmt
            if let d = df.date(from: normalized) { return d.timeIntervalSince1970 }
        }
        return nil
    }
}
