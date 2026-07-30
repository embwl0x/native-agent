import Foundation
import PersistenceCore

/// Runtime helpers for the app-owned scheduled-job loop.
///
/// The create/list/cancel surface lives in `SchedulerJobs.swift`; this file
/// exposes the minimum schedule math the Mac app needs to advance due jobs
/// without duplicating the normalizer's daily/weekly/monthly/cron parser.
public enum SchedulerJobRuntime {
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
        let nowEpoch = now().timeIntervalSince1970
        guard var next = try nextRunEpoch(for: job, afterEpoch: nowEpoch, now: now) else {
            return nil
        }
        var guardCount = 0
        while next <= nowEpoch, guardCount < 10 {
            guard let advanced = try nextRunEpoch(for: job, afterEpoch: next, now: now) else {
                return nil
            }
            next = advanced
            guardCount += 1
        }
        return next
    }

    public static func decorationISO(epoch: Double) -> String {
        SchedulerJobNormalizer.epochToDecorationISO(epoch)
    }

    public static func floatString(_ value: Double) -> String {
        SchedulerJobNormalizer.pyFloatString(value)
    }
}
