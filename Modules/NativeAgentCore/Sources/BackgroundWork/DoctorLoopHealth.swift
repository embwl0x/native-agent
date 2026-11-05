import Foundation
import NativeAgentShared
import NativeAgentCore
import BackgroundLoops
import DoctorChecks
import Privacy
import PersistenceCore
import Experiences
// Blueprint: | `DoctorLoopHealth.swift` | `DoctorLoopHealth`, `LoopHealthVerdict`; Health and schedule rules |

// Live scheduler state and bounded durable receipts distinguish persistent
// failures from transient failures without changing scheduling or due clocks.

public enum LoopHealthLevel: String, Sendable {
    case ok
    case warn
    case fail
    /// Off by config or not needed: neither a fault nor healthy work.
    case off
    case notNeeded

    /// Shared status vocabulary keeps theme colors and badges consistent.
    public var statusText: String {
        switch self {
        case .ok: "ok"
        case .warn: "warn"
        case .fail: "failed"
        case .off: "off"
        case .notNeeded: "not needed"
        }
    }

    public var isFault: Bool { self == .warn || self == .fail }
}

public struct LoopHealthVerdict: Equatable, Identifiable, Sendable {
    public let loopId: String
    public let level: LoopHealthLevel
    public let detail: String
    public var id: String { loopId }

    public init(loopId: String, level: LoopHealthLevel, detail: String) {
        self.loopId = loopId
        self.level = level
        self.detail = NativeAppSecretRedactor.redactText(detail)
    }
}

public enum DoctorLoopHealth {
    public struct FailureIncident: Sendable {
        let dates: [Date]

        func confirmedOccurrences(since cutoff: Date, through now: Date) -> Int {
            dates.filter { $0 >= cutoff && $0 <= now }.count
        }
    }

    /// Unavailable work needs a warning, not a misleading nothing-due verdict.
    public static let unavailableSkipPrefix = "unavailable: "

    public static let iCloudDriveStep = "Open System Settings → Apple Account → iCloud → Drive and turn on Sync this Mac."

    /// Restart registered scheduling only; never force work, reassemble loops or reset due clocks.
    public static func safeRepair(
        manager: BackgroundLoops.BackgroundLoopLifetimes
    ) async -> DoctorExecutableRepair? {
        let statuses = await manager.status()
        guard statuses.contains(where: {
            $0.disabledReason == nil &&
                (!$0.running || ($0.lastError != nil && !$0.executing && $0.name != "telegram_poll"))
        }) else { return nil }
        return DoctorExecutableRepair(checkID: doctorCheckID) {
            let wasRunning = await manager.isRunning()
            _ = await manager.start()
            let after = await manager.status()
            guard !after.isEmpty, after.allSatisfy({ $0.disabledReason != nil || $0.running }) else {
                return .unverified("Repair attempted: background scheduling did not restart.")
            }
            return wasRunning
                ? .unverified("Repair attempted: reconciled background scheduling through its owner; failed work retains its normal retry cadence.")
                : .completed("Completed: restarted background scheduling through its owner; due times and execution gates were preserved.")
        }
    }

    /// Three failures cover half the six common five-minute ticks in the minimum grace window.
    public static let persistentFailureThreshold = 3

    public static func graceWindow(for observation: LoopStatus) -> TimeInterval {
        // Event failures still have a bounded observation window, without inventing a cadence.
        guard let period = observation.wake?.period else { return 30 * 60 }
        return max(3 * period, 30 * 60)
    }

    /// Half-interval slack with a 60-second floor prevents normal jitter and long ticks from flapping health.
    public static func overdueTolerance(for observation: LoopStatus) -> TimeInterval {
        // An active event tick retains the watchdog's slack; idle event organs have no overdue check.
        guard let period = observation.wake?.period else { return 60 }
        return max(period / 2, 60)
    }

    /// Only occurrences proven inside the grace window count toward persistent failure.
    public static func evaluate(
        observations: [LoopStatus],
        recentFailureDates: [String: [FailureIncident]],
        now: Date
    ) -> [LoopHealthVerdict] {
        observations.map { observation in
            let base = merge(
                baseVerdict(for: observation, recentFailureDates: recentFailureDates, now: now),
                with: eventListenerVerdict(for: observation, now: now)
            )
            return merge(base, with: dormancyVerdict(for: observation, now: now))
        }
        .sorted { lhs, rhs in
            if lhs.level != rhs.level { return rank(lhs.level) < rank(rhs.level) }
            return lhs.loopId < rhs.loopId
        }
    }

    /// Three consecutive ends reach the 30-second restart ceiling after over half a minute without events.
    public static let eventListenerFailureThreshold = 3

    /// Missing or stable listeners contribute no event-source failure.
    public static func eventListenerVerdict(
        for observation: LoopStatus,
        now: Date
    ) -> (level: LoopHealthLevel, detail: String)? {
        guard let listener = observation.eventListener else { return nil }
        if listener.active, listener.consecutiveEnds == 0 { return nil }
        let endedPhrase = listener.lastEndedAt
            .map { "last ended \(describeAge(now.timeIntervalSince($0))) ago" }
            ?? "never started"
        let restarts = listener.restartCount == 1 ? "1 restart" : "\(listener.restartCount) restarts"
        let detail = "Event listener \(listener.active ? "restarted but not yet delivering" : "is down")"
            + " (\(listener.consecutiveEnds) consecutive stream end(s), \(restarts), \(endedPhrase))"
            + (listener.lastError.map { """
                ; last listener error: \($0.trimmingCharacters(in: CharacterSet(charactersIn: ".").union(.whitespacesAndNewlines)))
                """ } ?? "") + "."
        let level: LoopHealthLevel = listener.consecutiveEnds >= eventListenerFailureThreshold
            ? .fail
            : .warn
        return (level, detail)
    }

    /// A week floor protects slow work; three intervals lets a weekly loop miss three periods before dormancy.
    public static let dormancyFloor: TimeInterval = 7 * 24 * 60 * 60

    public static func dormancyThreshold(for observation: LoopStatus) -> TimeInterval? {
        guard let period = observation.wake?.period else { return nil }
        return max(dormancyFloor, 3 * period)
    }

    /// Legitimate nothing-due or disabled skips show normal operation.
    /// Backoff skips retain lastError, and single-flight coalescing proves no work; neither counts as healthy.
    public static func lastOutcomeWasLegitimateSkip(_ observation: LoopStatus) -> Bool {
        guard observation.lastError == nil,
              let result = observation.lastResult,
              result.hasPrefix("skipped: ") else { return false }
        let reason = String(result.dropFirst("skipped: ".count))
        return reason != LoopTickOutcome.coalescedSkipReason
            && reason != LoopTickOutcome.notDueSkipReason
    }

    /// Dormancy needs expected work and elapsed time; legitimate skips remain healthy.
    /// Judge never-completed work from firstSeenAt: regular idle ticks keep lastRun fresh forever.
    /// Without first-seen evidence, remain silent rather than inventing age.
    public static func dormancyVerdict(
        for observation: LoopStatus,
        now: Date
    ) -> (level: LoopHealthLevel, detail: String)? {
        guard observation.running else { return nil }
        guard observation.lastRun != nil else { return nil }
        guard !lastOutcomeWasLegitimateSkip(observation) else { return nil }
        guard let threshold = dormancyThreshold(for: observation) else { return nil }
        let reference = [observation.lastSuccessfulWorkAt, observation.firstSeenAt]
            .compactMap { $0 }
            .max()
        guard let reference else { return nil }
        let idle = now.timeIntervalSince(reference)
        guard idle > threshold else { return nil }
        let lead = observation.lastSuccessfulWorkAt == nil
            ? "Registered and ticking, but it has NEVER completed any work"
            : "Registered and ticking, but no work completed in \(describeAge(idle))"
        let reason = observation.lastResult.map { """
            ; last outcome: \($0.trimmingCharacters(in: CharacterSet(charactersIn: ".").union(.whitespacesAndNewlines)))
            """ } ?? ""
        return (
            .warn,
            "\(lead) (dormancy bound \(describeAge(threshold)))\(reason)."
        )
    }

    private static func merge(
        _ base: LoopHealthVerdict,
        with listener: (level: LoopHealthLevel, detail: String)?
    ) -> LoopHealthVerdict {
        guard let listener else { return base }
        let level = rank(listener.level) < rank(base.level) ? listener.level : base.level
        return LoopHealthVerdict(
            loopId: base.loopId,
            level: level,
            detail: base.detail.trimmingCharacters(in: CharacterSet(charactersIn: ".").union(.whitespacesAndNewlines)) + "; " + listener.detail
        )
    }

    private static func baseVerdict(
        for observation: LoopStatus,
        recentFailureDates: [String: [FailureIncident]],
        now: Date
    ) -> LoopHealthVerdict {
        guard let lastError = observation.lastError else {
            // No error can also mean no active scheduler or a starved deadline; silence is not health.
            return scheduleVerdict(for: observation, now: now)
        }
        let window = graceWindow(for: observation)
        let cutoff = now.addingTimeInterval(-window)
        let recentFailures = (recentFailureDates[observation.name] ?? [])
            .reduce(0) { count, incident in
                let (sum, overflow) = count.addingReportingOverflow(
                    incident.confirmedOccurrences(since: cutoff, through: now))
                return overflow ? Int.max : sum
            }
        let age = observation.lastRun.map { describeAge(now.timeIntervalSince($0)) } ?? "unknown"
        if recentFailures >= persistentFailureThreshold {
            return LoopHealthVerdict(
                loopId: observation.name,
                level: .fail,
                detail: """
                    Failing persistently (at least \(recentFailures) failures in \(describeAge(window))); last tick \(age) ago; last failure: \
                    \(lastError.trimmingCharacters(in: CharacterSet(charactersIn: ".").union(.whitespacesAndNewlines))).
                    """
            )
        }
        return LoopHealthVerdict(
            loopId: observation.name,
            level: .warn,
            // Before any tick, the registration error explains why the loop cannot run.
            detail: observation.lastRun == nil ? "Cannot run: \(lastError)."
                : "Last tick failed \(age) ago: \(lastError.trimmingCharacters(in: CharacterSet(charactersIn: ".").union(.whitespacesAndNewlines)))."
        )
    }

    /// Verify scheduling and liveness before accepting a clean error record.
    /// Missing scheduling or grace-expired deadlines fail; ordinary deadline slack only warns.
    public static func scheduleVerdict(
        for observation: LoopStatus,
        now: Date
    ) -> LoopHealthVerdict {
        func verdict(_ level: LoopHealthLevel, _ detail: String) -> LoopHealthVerdict {
            LoopHealthVerdict(loopId: observation.name, level: level, detail: detail)
        }
        let lastTickPhrase = observation.lastRun
            .map { "last tick \(describeAge(now.timeIntervalSince($0))) ago." }
            ?? "it has never ticked."

        if let reason = observation.disabledReason {
            return verdict(.off, "Off: \(reason).")
        }
        guard observation.running else {
            return verdict(.fail, "Not running: registered, but no scheduler task is active; \(lastTickPhrase)")
        }
        guard let wake = observation.wake else {
            return verdict(.warn, "Configured wake unavailable; \(lastTickPhrase)")
        }
        if observation.executing {
            let age = observation.executionStartedAt
                .map { max(0, now.timeIntervalSince($0)) }
            if let age, age > observation.executionTimeout + overdueTolerance(for: observation) {
                return verdict(
                    .fail,
                    "Active tick exceeded its \(describeAge(observation.executionTimeout)) watchdog; \(lastTickPhrase)"
                )
            }
            let agePhrase = age.map { " for \(describeAge($0))" } ?? ""
            return verdict(.ok, "Active tick in progress\(agePhrase).")
        }
        if wake.period == nil {
            if let skip = deliberateSkipVerdict(for: observation) { return verdict(skip.level, skip.detail) }
            return verdict(.ok, "Runs on change; no periodic tick is due; \(lastTickPhrase)")
        }
        guard let nextRun = observation.nextRun else {
            return verdict(.fail, "Not scheduled: running, but no next tick is planned; \(lastTickPhrase)")
        }

        let overdueBy = now.timeIntervalSince(nextRun)
        guard overdueBy > overdueTolerance(for: observation) else {
            guard let lastRun = observation.lastRun else {
                return verdict(.ok, "First check in \(describeAge(-overdueBy)).")
            }
            let changed = observation.lastSuccessfulWorkAt
            guard lastOutcomeWasLegitimateSkip(observation) else {
                let changedPhrase = changed.map { "\(describeAge(now.timeIntervalSince($0))) ago" } ?? "never"
                return verdict(.ok, "Worked \(describeAge(now.timeIntervalSince(lastRun))) ago; last changed something \(changedPhrase).")
            }
            if let skip = deliberateSkipVerdict(for: observation) { return verdict(skip.level, skip.detail) }
            let since = changed ?? observation.firstSeenAt
            return verdict(.ok, since.map { "Nothing to do since \(Self.day($0))." } ?? "Nothing to do on the last check.")
        }
        if observation.lastRun == nil {
            return verdict(.fail, "Never ticked and overdue by \(describeAge(overdueBy)): the first tick has not fired.")
        }
        let grace = graceWindow(for: observation)
        if overdueBy > grace {
            return verdict(.fail, "Overdue by \(describeAge(overdueBy)) (beyond \(describeAge(grace)) grace); \(lastTickPhrase)")
        }
        return verdict(.warn, "Overdue by \(describeAge(overdueBy)); \(lastTickPhrase)")
    }

    private static func deliberateSkipVerdict(for observation: LoopStatus) -> (level: LoopHealthLevel, detail: String)? {
        guard lastOutcomeWasLegitimateSkip(observation),
              let reason = observation.lastResult?.dropFirst("skipped: ".count) else { return nil }
        for (prefix, level, word) in [(unavailableSkipPrefix, LoopHealthLevel.warn, "Unavailable"),
                                      (LoopTickOutcome.offPrefix, .off, "Off"),
                                      (LoopTickOutcome.notNeededPrefix, .notNeeded, "Not needed")]
        where reason.hasPrefix(prefix) {
            return (level, "\(word): \(reason.dropFirst(prefix.count)).")
        }
        return nil
    }

    private static func rank(_ level: LoopHealthLevel) -> Int {
        switch level {
        case .fail: 0
        case .warn: 1
        case .off: 2
        case .notNeeded: 3
        case .ok: 4
        }
    }

    public static func day(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MM-dd"
        return formatter.string(from: date)
    }

    public static func describeAge(_ seconds: TimeInterval) -> String {
        let s = max(0, seconds)
        if s < 90 { return "\(Int(s))s" }
        if s < 90 * 60 { return "\(Int(s / 60))m" }
        if s < 36 * 3600 { return "\(Int(s / 3600))h" }
        return "\(Int(s / 86400))d"
    }

    /// Fold the newest incidents from occurrence details; every timestamp can prove grace-window membership.
    public static func recentFailureDates(
        dataRoot: URL,
        maxReceipts: Int = 500
    ) async throws -> [String: [FailureIncident]] {
        let incidents = try await LoopFailureReceipts.incidents(dataRoot: dataRoot, limit: maxReceipts)
        var result: [String: [FailureIncident]] = [:]
        for incident in incidents {
            result[incident.loopId, default: []].append(FailureIncident(dates: incident.dates))
        }
        return result
    }

    // MARK: - Doctor row

    /// `live.` excludes this mounted fleet from offline and onboarding rollups.
    public static let doctorCheckID = "live.background_loops"

    /// Error and schedule failures outrank dormancy; off and not-needed never count as healthy.
    public static func doctorCheck(
        observations: [LoopStatus],
        recentFailureDates: [String: [FailureIncident]],
        now: Date
    ) -> CheckResult {
        // The fleet registers at launch; an empty status list proves no scheduler health.
        guard !observations.isEmpty else {
            return CheckResult(source: "Background loop registrations",
                id: doctorCheckID,
                title: "Background Loops",
                status: "unmeasured",
                detail: "No background loops are registered, so their health has not been measured.",
                human_action: "Quit and reopen NativeAgent to start background scheduling, then run Doctor again."
            )
        }
        let verdicts = evaluate(
            observations: observations,
            recentFailureDates: recentFailureDates,
            now: now
        )
        let dormant = Set(
            observations
                .filter { dormancyVerdict(for: $0, now: now) != nil }
                .map(\.name)
        )
        var failing: [LoopHealthVerdict] = []
        var dormantVerdicts: [LoopHealthVerdict] = []
        var degraded: [LoopHealthVerdict] = []
        var healthy = 0, off = 0, notNeeded = 0
        for verdict in verdicts {
            switch verdict.level {
            case .fail: failing.append(verdict)
            case .warn:
                if dormant.contains(verdict.loopId) {
                    dormantVerdicts.append(verdict)
                } else {
                    degraded.append(verdict)
                }
            case .off: off += 1
            case .notNeeded: notNeeded += 1
            case .ok: healthy += 1
            }
        }
        var counts = ["\(failing.count) failing", "\(dormantVerdicts.count) dormant"]
        if !degraded.isEmpty { counts.append("\(degraded.count) degraded") }
        if off > 0 { counts.append("\(off) off") }
        if notNeeded > 0 { counts.append("\(notNeeded) not needed") }
        counts.append("\(healthy) healthy")
        var detail = "\(verdicts.count) background loop(s): \(counts.joined(separator: ", "))"
        // Worst-first ordering lets the tooltip name the actual worst offender.
        if let worst = verdicts.first, worst.level.isFault {
            detail += "; worst: \(worst.loopId) — \(worst.detail.trimmingCharacters(in: CharacterSet(charactersIn: ".").union(.whitespacesAndNewlines)))"
        }
        // Individual loop rows own repairs; this count creates no second debt.
        return CheckResult(source: "Background loop registrations",
            id: doctorCheckID,
            title: "Background Loops",
            status: !failing.isEmpty ? "fail" : !dormantVerdicts.isEmpty || !degraded.isEmpty ? "warn" : healthy > 0 ? "ok" : off > 0 ? "off" : "not needed",
            detail: detail + "."
        )
    }

}
