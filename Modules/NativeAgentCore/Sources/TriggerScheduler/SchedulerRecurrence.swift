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
import Desk
// Blueprint: | `SchedulerRecurrence.swift` | Shared recurrence, civil-minute and intention timing grammar |

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
        // ISO/civil scheduling supports Gregorian years 1...9999; occurrence identity additionally requires rounded milliseconds to fit Int64.
        guard epoch.isFinite, (-62_135_596_800...253_402_300_799).contains(epoch),
              Int64(exactly: (epoch * 1_000).rounded()) != nil,
              let value = Int64(exactly: epoch.rounded(.towardZero)) else {
            throw TriggerSchedulerError.schedulerInvalid("run_at must be a finite epoch timestamp within the supported range")
        }
        return value
    }

    static func everyInterval(_ schedule: [String: JSONValue]) throws -> Int {
        var total = 0
        var found = false
        for (key, multiplier) in [("seconds", 1), ("minutes", 60), ("hours", 3600), ("days", 86400), ("interval_seconds", 1), ("intervalSeconds", 1)] {
            guard let raw = schedule[key] else { continue }
            found = true
            let value = try integer(raw)
            let product = value.multipliedReportingOverflow(by: multiplier)
            let sum = total.addingReportingOverflow(product.partialValue)
            guard value >= 0, !product.overflow, !sum.overflow else {
                throw TriggerSchedulerError.schedulerInvalid("schedule duration is invalid or too large")
            }
            total = sum.partialValue
        }
        guard found, total >= 60 else { throw TriggerSchedulerError.schedulerInvalid("every requires a duration of at least 60 seconds") }
        return total
    }

    static func scheduleType(_ schedule: [String: JSONValue]) -> String {
        (string(schedule["type"]) ?? string(schedule["kind"]) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    /// Current schedule type and the saved oneShot projection agree.
    public static func isOneShot(_ body: [String: JSONValue], schedule: [String: JSONValue]? = nil) -> Bool {
        if let minutes = body["in_minutes"], minutes != .null { return true }
        if case .string? = body["schedule"] { return true }
        return scheduleType(schedule ?? body["schedule"]?.objectValue ?? [:]) == "once"
            || body["oneShot"] == .bool(true)
    }

    /// Find the next occurrence in the supplied zone, defaulting to the Mac's current zone.
    static func nextFromSchedule(_ schedule: [String: JSONValue], afterEpoch: Double?, now: @Sendable () -> Date,
                                 zone tz: TimeZone = .autoupdatingCurrent) throws -> Double {
        let typ = scheduleType(schedule)
        let nowEpoch = afterEpoch ?? now().timeIntervalSince1970

        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = tz

        // after = the minute after the one the clock shows, kept as an instant: in the hour a fall-back repeats, one reading names two instants.
        let offset = Double(tz.secondsFromGMT(for: Date(timeIntervalSince1970: nowEpoch)))
        let shown = ((nowEpoch + offset) / 60).rounded(.down) * 60
        let afterMinute = Date(timeIntervalSince1970: shown - offset + 60)
        // A minute the clock already showed is spent: one civil minute is one occurrence.
        func spent(_ date: Date) -> Bool { date.timeIntervalSince1970 + Double(tz.secondsFromGMT(for: date)) <= shown }

        switch typ {
        case "once":
            // Saved jobs and intention inputs meet at the same recurrence owner.
            return try epochFromValue(firstPresent(schedule["run_at"], schedule["runAt"], schedule["at"]) ?? .null, zone: tz, now: now)
        case "every":
            let resolved = try everyInterval(schedule)
            let nextRun = nowEpoch + Double(resolved)
            _ = try checkedEpoch(nextRun)
            return nextRun
        case "hourly", "daily", "weekly", "monthly", "cron":
            // Only absence uses the documented hourly minute.
            let (hour, minute) = typ == "cron" ? (0, 0) : typ == "hourly" ? (0, try schedule["minute"].map { try integer($0) } ?? 0) : try timeParts(schedule)
            guard (0...59).contains(minute) else {
                throw TriggerSchedulerError.schedulerInvalid("hourly schedule minute out of range")
            }
            let weekdays = typ == "weekly" ? try weekdaySet(firstPresent(schedule["weekdays"], schedule["weekday"])) : Set(0...6)
            let monthDay = try max(1, min(31, integerOr(
                schedule["day"], schedule["monthday"], schedule["monthDay"],
                default: 1
            )))
            let expression = (string(firstPresent(schedule["expression"], schedule["cron"], .string(""))) ?? "")
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
        let raw = firstPresent(spec["at"], spec["time"])
        let hour: Int
        let minute: Int
        if let r = raw {
            // A present clock must be text matching the whole field.
            let text: String
            if case .string(let value) = r { text = value }
            else { text = String(try integer(r)) } // documented numeric hour unit
            guard let (h, m) = parseHHMM(text) else {
                throw TriggerSchedulerError.schedulerInvalid("schedule.at must be HH:MM")
            }
            hour = h
            minute = m
        } else {
            // Documented defaults apply only to absent fields.
            hour = try spec["hour"].map { try integer($0) } ?? defaultHour
            minute = try spec["minute"].map { try integer($0) } ?? defaultMinute
        }
        guard (0...23).contains(hour), (0...59).contains(minute) else {
            throw TriggerSchedulerError.schedulerInvalid("scheduled hour/minute out of range")
        }
        return (hour, minute)
    }

    /// Require a whole-field H[:MM] match; whitespace surrounds digits and only an absent minute defaults to zero.
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
        func weekdayText(_ value: JSONValue) throws -> String {
            if case .string(let text) = value { return text }
            return String(try integer(value)) // documented 1=Monday … 7=Sunday
        }
        if case .array(let arr) = raw {
            values = try arr.map(weekdayText)
        } else {
            values = try weekdayText(raw)
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
                guard (1...7).contains(value) else { throw TriggerSchedulerError.schedulerInvalid("weekday must be 1 through 7") }
                result.insert(value - 1)
            } else {
                throw TriggerSchedulerError.schedulerInvalid("Unknown weekday: \(item)")
            }
        }
        guard !result.isEmpty else { throw TriggerSchedulerError.schedulerInvalid("weekday input contains no days") }
        return result
    }

    static func cronValues(_ field: String, minimum: Int, maximum: Int, names: [String: Int] = [:]) throws -> Set<Int> {
        var allowed: Set<Int> = []
        for partRaw in field.lowercased().split(separator: ",", omittingEmptySubsequences: false) {
            var part = String(partRaw).trimmingCharacters(in: .whitespaces)
            func namedOrInt(_ token: String) throws -> Int {
                let t = token.trimmingCharacters(in: .whitespaces)
                if let n = names[t] { return n }
                if t.allSatisfy({ $0.isNumber }), !t.isEmpty, let v = Int(t) { return v }
                throw TriggerSchedulerError.schedulerInvalid("""
                    cron token '\(token)' is invalid; use an integer from \(minimum) through \
                    \(maximum)\(names.isEmpty ? "" : " or " + names.keys.sorted().joined(separator: ", ")) in schedule.expression
                    """, code: "schedule_cron_token_invalid", path: "$.schedule.expression")
            }
            var step = 1
            if let slash = part.firstIndex(of: "/") {
                let stepText = String(part[part.index(after: slash)...]).trimmingCharacters(in: .whitespaces)
                part = String(part[..<slash])
                // Steps are integers clamped to at least one; nonnumeric input refuses.
                guard let parsedStep = Int(stepText), stepText.allSatisfy({ $0.isASCII && ($0.isNumber || $0 == "-") }) else {
                    throw TriggerSchedulerError.schedulerInvalid("cron step '\(stepText)' is not an integer; use */N in schedule.expression, for example */5",
                        code: "schedule_cron_step_invalid", path: "$.schedule.expression")
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
                throw TriggerSchedulerError.schedulerInvalid("cron range '\(part)' must ascend within \(minimum)...\(maximum); edit schedule.expression",
                    code: "schedule_cron_range_invalid", path: "$.schedule.expression")
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
            throw TriggerSchedulerError.schedulerInvalid("schedule.expression needs 5 cron fields: minute hour day month weekday; for example 0 9 * * *",
                code: "schedule_cron_fields_invalid", path: "$.schedule.expression")
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

    /// Offset-bearing input names an instant; naive datetime and date-only input use the supplied civil zone (midnight for dates).
    static func parseISO(_ text: String, zone: TimeZone = .autoupdatingCurrent) -> Double? {
        let normalized = text.replacingOccurrences(of: "Z", with: "+00:00")

        if let d = NativeTimestampFormat.parseISO8601FractionalFirst(normalized) { return d.timeIntervalSince1970 }

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

// MARK: - An intention's rhythm

extension SchedulerJobNormalizer {
    /// A once input is an at moment, not a recurring rhythm.
    public static let rhythmKinds: Set<String> = ["every", "hourly", "daily", "weekly", "monthly", "cron"]

    /// Keep the public timing schema beside the rhythm parser so they cannot drift.
    public static let intentionWhenSchema: JSONValue = {
        let number: JSONValue = .object(["type": .array([.string("number"), .string("string")])])
        let text = ToolSchema.strSchema()
        let kinds = rhythmKinds.union(["once"]).sorted().joined(separator: "|")
        let kind: JSONValue = .object(["type": .string("string"), "pattern": .string("(?i)^\\s*(" + kinds + ")\\s*$"),
            "description": .string("Rhythm type: " + kinds + "; kind is an alias for type.")])
        let weekdays: JSONValue = .object(["oneOf": .array([text, .object(["type": .string("integer")]),
            .object(["type": .string("array"), "items": number])]),
            "description": .string("Weekday names (mon…sun, weekdays, weekends) or numbers 1=Monday…7=Sunday; list, comma-separated or space-separated.")])
        var fields: [String: JSONValue] = ["type": kind, "kind": kind,
            "at": .object(["type": .array([.string("number"), .string("string")]),
                "description": .string("H or HH:MM for daily/weekly/monthly; ISO or local date/time for a single moment.")]),
            "time": number, "run_at": text, "runAt": text,
            "expression": ToolSchema.strSchema("Five-field cron expression, on the Mac's local clock."), "cron": text,
            "weekdays": weekdays, "weekday": weekdays]
        for name in ["seconds", "minutes", "hours", "days", "interval_seconds", "intervalSeconds",
                     "hour", "minute", "day", "monthday", "monthDay"] { fields[name] = number }
        return .object(["description": .string("""
            Omit for next_turn. Strings: own_turn, when_user_messages [door: \(MyQueue.Door.listed)], when_user_here, when_user_away, \
            on_news <words>, on <signal>, after_card <id>, at \
            <ISO time>, a local date/time with optional weekday (Sun Nov 1 at 06:00), in N minutes|hours|days, every <cron>, every N minutes|hours|days. \
            Objects name a rhythm type/kind, or cron/expression; {at:<ISO/local time>} and {type:once,at:<ISO/local time>} name one moment. Local words use \
            the system date reader in the Mac's zone; ambiguous readings refuse with their interpretation. Rhythm defaults and cross-field timing are checked \
            by the clock.
            """),
            "oneOf": .array([text, .object(["type": .string("object"), "properties": .object(fields),
                "additionalProperties": .bool(true)])])])
    }()

    /// Require five-field cron syntax or an explicit interval; unmatched text cannot establish a rhythm.
    public static func rhythm(_ value: JSONValue) -> JSONValue? {
        var fields: [String: JSONValue]
        switch value {
        case .object(let object): fields = object
        case .string(let raw):
            let words = raw.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: " ").map(String.init)
            guard let head = words.first?.lowercased(), ["every", "cron"].contains(head), words.count > 1 else { return nil }
            let rest = Array(words.dropFirst())
            if rest.count == 5 { fields = ["type": .string("cron"), "expression": .string(rest.joined(separator: " "))] }
            else if rest.count == 2, let count = Int(rest[0]),
                    let unit = ["minute": "minutes", "minutes": "minutes", "hour": "hours", "hours": "hours", "day": "days",
                        "days": "days"][rest[1].lowercased()] {
                fields = ["type": .string("every"), unit: .int(Int64(count))]
            } else { return nil }
        default: return nil
        }
        if fields["type"] == nil, fields["kind"] == nil, fields["cron"] != nil || fields["expression"] != nil { fields["type"] = .string("cron") }
        // A rhythm names its kind: an untyped object (a bare {at}) would read as the job grammar's hourly default.
        guard fields["type"] != nil || fields["kind"] != nil, rhythmKinds.contains(scheduleType(fields)) else { return nil }
        // It must read: one occurrence ahead proves the clock understands it.
        guard (try? nextFromSchedule(fields, afterEpoch: Date().timeIntervalSince1970, now: { Date() })) != nil else { return nil }
        return .object(fields)
    }

    /// The first occurrence after `date`, in the Mac's zone; nil when it has none.
    public static func nextOccurrence(_ rhythm: JSONValue, after date: Date) -> Date? {
        guard case .object(let fields) = rhythm, rhythmKinds.contains(scheduleType(fields)),
              let epoch = try? nextFromSchedule(fields, afterEpoch: date.timeIntervalSince1970, now: { date }) else { return nil }
        return Date(timeIntervalSince1970: epoch)
    }

    /// An `every` rhythm's interval, which counts from where it was filed; nil for calendar rhythms.
    public static func rhythmInterval(_ rhythm: JSONValue) -> TimeInterval? {
        guard case .object(let fields) = rhythm, scheduleType(fields) == "every",
              let seconds = try? everyInterval(fields) else { return nil }
        return TimeInterval(seconds)
    }
}
