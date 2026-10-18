import Foundation
import PersistenceCore

/// Runtime helpers for the app-owned scheduled-job loop.
///
/// The create/list/cancel surface lives in `SchedulerJobs.swift`; this file
/// exposes the minimum schedule math the Mac app needs to advance due jobs
/// without duplicating the normalizer's daily/weekly/monthly/cron parser.
public enum SchedulerJobRuntime {
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
        guard let schedule = wallClockSchedule(job) else { return nil }
        return occurrence(at: Date(timeIntervalSince1970: epoch), zone: SchedulerJobNormalizer.resolveTimezone(schedule["timezone"] ?? schedule["tz"]))
    }

    static func civilEpoch(_ key: String) -> Double? {
        guard key.count == 16, key.contains(" ") else { return nil }
        return SchedulerJobNormalizer.parseISO(key.replacingOccurrences(of: " ", with: "T") + ":00Z")
    }

    public static func nextWallClockOccurrence(for job: [String: JSONValue]) -> String? {
        if let saved = job["nextWallClockOccurrence"] { return string(saved) }
        guard job["activeOccurrence"] == nil, job["retryPendingUntilEpoch"] == nil,
              let schedule = wallClockSchedule(job) else { return nil }
        let zone = SchedulerJobNormalizer.resolveTimezone(schedule["timezone"] ?? schedule["tz"])
        func civil(_ value: JSONValue?) -> Double? {
            string(value).flatMap(SchedulerJobNormalizer.parseISO).flatMap {
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
        var civilSchedule = schedule
        civilSchedule["timezone"] = .string("UTC")
        guard let next = try? SchedulerJobNormalizer.nextFromSchedule(civilSchedule, afterEpoch: after, now: { Date() }) else { return nil }
        return occurrence(at: Date(timeIntervalSince1970: next), zone: TimeZone(secondsFromGMT: 0)!)
    }

    /// Claims and retry floors keep their instant. Unclaimed wall-clock work follows the current zone.
    public static func scheduledEpoch(for job: [String: JSONValue]) -> Double? {
        let saved = epoch(from: job["nextRunAt"]) ?? epoch(from: job["nextRunAtEpoch"])
        guard job["activeOccurrence"] == nil, job["retryPendingUntilEpoch"] == nil,
              let schedule = wallClockSchedule(job) else { return saved }
        guard let key = nextWallClockOccurrence(for: job), let next = civilEpoch(key) else { return nil }
        if let saved, wallClockOccurrence(for: job, epoch: saved) == key { return saved }
        let zone = SchedulerJobNormalizer.resolveTimezone(schedule["timezone"] ?? schedule["tz"])
        return wallClock(Date(timeIntervalSince1970: next), from: TimeZone(secondsFromGMT: 0)!, to: zone)?.timeIntervalSince1970
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
        return afterEpoch + Double(interval)
    }

    public static func nextRunEpochAfterNow(
        for job: JSONValue,
        now: @escaping @Sendable () -> Date = { Date() }
    ) throws -> Double? {
        try nextRunEpoch(for: job, afterEpoch: now().timeIntervalSince1970, now: now)
    }

    public static func decorationISO(epoch: Double) -> String {
        SchedulerJobNormalizer.epochToDecorationISO(epoch)
    }

    public static func floatString(_ value: Double) -> String {
        SchedulerJobNormalizer.pyFloatString(value)
    }
}
