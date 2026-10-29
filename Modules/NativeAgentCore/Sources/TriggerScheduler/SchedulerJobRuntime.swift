import Foundation
import PersistenceCore

// Blueprint: | `SchedulerJobRuntime.swift` | `SchedulerJobRuntime`: shared civil schedule math and next occurrences; timezone changes cannot mint another civil occurrence |

/// Runtime helpers for the app-owned scheduled-job loop.
///
/// The create/list/cancel surface lives in `SchedulerJobs.swift`; this file
/// exposes the minimum schedule math the Mac app needs to advance due jobs
/// without duplicating the normalizer's daily/weekly/monthly/cron parser.
public enum SchedulerJobRuntime {
    /// Today's matching civil minute, or nil on a day that skips it.
    static func dailyOccurrence(_ schedule: [String: JSONValue], on date: Date) -> Date? {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .autoupdatingCurrent
        let start = calendar.startOfDay(for: date)
        guard let epoch = try? SchedulerJobNormalizer.nextFromSchedule(
            schedule, afterEpoch: start.timeIntervalSince1970 - 60, now: { date }
        ) else { return nil }
        let occurrence = Date(timeIntervalSince1970: epoch)
        return calendar.isDate(occurrence, inSameDayAs: date) ? occurrence : nil
    }

    public static func wallClockSchedule(_ job: [String: JSONValue]) -> [String: JSONValue]? {
        guard !bool(job["oneShot"], default: false), case .object(let schedule)? = job["schedule"],
              ["hourly", "daily", "weekly", "monthly", "cron"].contains(SchedulerJobNormalizer.scheduleType(schedule)) else { return nil }
        return schedule
    }

    /// Civil identity deliberately has no offset: changing zones cannot create another occurrence.
    public static func occurrence(at date: Date, zone: TimeZone) -> String {
        let format = DateFormatter()
        format.locale = Locale(identifier: "en_US_POSIX")
        format.calendar = Calendar(identifier: .gregorian)
        format.timeZone = zone
        format.dateFormat = "yyyy-MM-dd HH:mm"
        return format.string(from: date)
    }

    public static func wallClockOccurrence(for job: [String: JSONValue], epoch: Double) -> String? {
        guard wallClockSchedule(job) != nil else { return nil }
        return occurrence(at: Date(timeIntervalSince1970: epoch), zone: .autoupdatingCurrent)
    }

    static func civilEpoch(_ key: String) -> Double? {
        guard key.count == 16, key.contains(" ") else { return nil }
        return SchedulerJobNormalizer.parseISO(key.replacingOccurrences(of: " ", with: "T") + ":00Z")
    }

    public static func nextWallClockOccurrence(for job: [String: JSONValue]) -> String? {
        if let saved = job["nextWallClockOccurrence"] { return string(saved) }
        guard job["activeOccurrence"] == nil, job["retryPendingUntilEpoch"] == nil,
              let schedule = wallClockSchedule(job) else { return nil }
        let zone = TimeZone.autoupdatingCurrent
        guard let utc = TimeZone(secondsFromGMT: 0) else { return nil }
        func civil(_ value: JSONValue?) -> Double? {
            // Machine stamps: an offset-less one was written as UTC.
            string(value).flatMap { SchedulerJobNormalizer.parseISO($0, zone: utc) }.flatMap {
                civilEpoch(occurrence(at: Date(timeIntervalSince1970: $0), zone: zone))
            }
        }
        if schedule["firstRunAt"] != nil, string(job["lastRunAt"]) == nil,
           job["lastWallClockOccurrence"] == nil,
           let first = epoch(from: job["nextRunAt"]) ?? epoch(from: job["nextRunAtEpoch"]) {
            return occurrence(at: Date(timeIntervalSince1970: first), zone: zone)
        }
        let anchor = string(schedule["wallClockAnchor"]).flatMap(civilEpoch) ?? civil(schedule["wallClockAnchor"])
        let claimed = string(job["lastWallClockOccurrence"]).flatMap(civilEpoch)
        guard schedule["wallClockAnchor"] == nil || anchor != nil,
              job["lastWallClockOccurrence"] == nil || claimed != nil else { return nil }
        // Settlement deliberately skips missed slots. Its actual completion
        // bounds migration even when the old civil claim is several slots behind.
        guard let after = [anchor, claimed, civil(job["lastRunAt"])].compactMap({ $0 }).max()
            ?? civil(job["createdAt"]) else { return nil }
        guard let next = try? SchedulerJobNormalizer.nextFromSchedule(schedule, afterEpoch: after, now: { Date() },
                                                                       zone: utc) else { return nil }
        return occurrence(at: Date(timeIntervalSince1970: next), zone: utc)
    }

    /// Claims and rows bearing a legacy retry marker keep the saved instant, not the marker's value.
    /// Other wall-clock work resolves its civil identity in the current zone.
    public static func scheduledEpoch(for job: [String: JSONValue]) -> Double? {
        let saved = epoch(from: job["nextRunAt"]) ?? epoch(from: job["nextRunAtEpoch"])
        guard job["activeOccurrence"] == nil, job["retryPendingUntilEpoch"] == nil,
              wallClockSchedule(job) != nil else { return saved }
        guard let key = nextWallClockOccurrence(for: job), let next = civilEpoch(key) else { return nil }
        if let saved, wallClockOccurrence(for: job, epoch: saved) == key { return saved }
        guard let utc = TimeZone(secondsFromGMT: 0) else { return nil }
        return wallClock(Date(timeIntervalSince1970: next), from: utc, to: .autoupdatingCurrent)?.timeIntervalSince1970
    }

    /// The civil minute `date` reads in `from`, formed again in `to`.
    public static func wallClock(_ date: Date, from: TimeZone, to: TimeZone) -> Date? {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = from
        let components = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        calendar.timeZone = to
        return calendar.date(from: components)
    }

    public static func epoch(from raw: JSONValue?) -> Double? {
        SchedulerJobNormalizer.floatEpochForDecoration(raw)
    }

    public static func string(_ raw: JSONValue?) -> String? {
        SchedulerJobNormalizer.string(raw)
    }

    public static func bool(_ raw: JSONValue?, default defaultValue: Bool) -> Bool {
        SchedulerJobNormalizer.boolValue(raw, default: defaultValue)
    }

    public static func int(_ raw: JSONValue?, default defaultValue: Int) -> Int {
        (try? SchedulerJobNormalizer.pyInt(raw)) ?? defaultValue
    }

    public static func nextRunEpoch(
        for job: JSONValue,
        afterEpoch: Double,
        now: @escaping @Sendable () -> Date = { Date() }
    ) throws -> Double? {
        guard case .object(let obj) = job else { return nil }
        if bool(obj["oneShot"], default: false) { return nil }
        if case .object(let schedule)? = obj["schedule"] {
            return try SchedulerJobNormalizer.nextFromSchedule(schedule, afterEpoch: afterEpoch, now: now)
        }
        let interval = max(60, int(obj["intervalSeconds"] ?? obj["interval_seconds"], default: 3600))
        let next = afterEpoch + Double(interval)
        _ = try SchedulerJobNormalizer.checkedEpoch(next)
        return next
    }

    /// Past `now` and past the minute `dueEpoch` claimed: in a fall-back hour a
    /// run finishing at the second 01:01 must not be handed the second 01:59.
    public static func nextRunEpochAfterNow(
        for job: JSONValue,
        beyond dueEpoch: Double? = nil,
        now: @escaping @Sendable () -> Date = { Date() }
    ) throws -> Double? {
        try [now().timeIntervalSince1970, dueEpoch].compactMap { $0 }
            .compactMap { try nextRunEpoch(for: job, afterEpoch: $0, now: now) }.max()
    }

    public static func decorationISO(epoch: Double) -> String {
        SchedulerJobNormalizer.epochToDecorationISO(epoch)
    }

    public static func floatString(_ value: Double) -> String {
        SchedulerJobNormalizer.pyFloatString(value)
    }
}
