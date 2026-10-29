import Foundation
import NativeAgentShared
import NativeAgentCore
import BackgroundLoops
import DoctorChecks
import Privacy
import PersistenceCore
// Blueprint: | `DoctorLoopHealth.swift` | `DoctorLoopHealth`, `LoopHealthVerdict`; health, dormancy and schedule interpretation of supplied manager observations, plus bounded failure-receipt parsing |

// Live scheduler state and bounded durable receipts distinguish persistent
// failures from transient failures without changing scheduling or due clocks.

public enum LoopHealthLevel: String, Sendable {
    case ok
    case warn
    case fail
    /// Off by config or not needed: neither a fault nor healthy work.
    case off
    case notNeeded

    /// Vocabulary understood by NativeAgentTheme.statusColor / StatusBadge.
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
        let firstAt: Date?
        let lastAt: Date
        let cumulativeOccurrences: Int

        func confirmedOccurrences(since cutoff: Date, through now: Date) -> Int {
            if let firstAt, firstAt >= cutoff, firstAt <= lastAt, lastAt <= now {
                return cumulativeOccurrences
            }
            // A coalesced incident has no timestamps for its middle failures.
            // Across a window boundary only its endpoints are evidence.
            var count = lastAt >= cutoff && lastAt <= now ? 1 : 0
            if cumulativeOccurrences > 1, let firstAt, firstAt < lastAt,
               firstAt >= cutoff, firstAt <= now {
                count += 1
            }
            return count
        }
    }

    /// A skip whose reason starts with this is a lane that cannot run on this
    /// Mac (iCloud Drive off): it is shown as a WARN row with the reason rather
    /// than folded into "nothing was due".
    public static let unavailableSkipPrefix = "unavailable: "

    public static let iCloudDriveStep = "Open System Settings → Apple Account → iCloud → Drive and turn on Sync this Mac."

    /// Restart scheduling of the loops already registered with Core's manager.
    /// Never reassembles loops, forces a workload, or resets a due clock.
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

    /// Receipts inside the grace window needed to call a failure persistent
    /// rather than a blip. At the common 5-minute tick interval the 30-minute
    /// floor holds up to 6 ticks, so 3 = half the window solidly failing.
    public static let persistentFailureThreshold = 3

    /// Grace window = max(3 × registered interval, 30 min).
    public static func graceWindow(for observation: LoopStatus) -> TimeInterval {
        max(3 * observation.interval, 30 * 60)
    }

    /// How far past `nextRun` a loop may drift before Doctor calls it overdue.
    /// Half the registered interval, floored at 60s, so ordinary tick jitter and
    /// a tick body that legitimately runs long never flap the verdict.
    public static func overdueTolerance(for observation: LoopStatus) -> TimeInterval {
        max(observation.interval / 2, 60)
    }

    /// Pure health rule. Incidents stay compact; only occurrences confirmed
    /// inside the loop's grace window count toward persistence.
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

    /// Consecutive stream-ends (with no event in between) that turn a listener
    /// from "restarting, may recover" into "this source is gone". Matched to
    /// the 1s/5s/30s restart backoff: by the third end the loop has been
    /// event-blind for over half a minute and is retrying at the ceiling.
    public static let eventListenerFailureThreshold = 3

    /// Verdict contribution from the EVENT lane. nil when the loop has no event
    /// listener, or when the listener is alive and has not been flapping.
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
            + (listener.lastError.map { "; last listener error: \($0.trimmingCharacters(in: CharacterSet(charactersIn: ".").union(.whitespacesAndNewlines)))" } ?? "") + "."
        let level: LoopHealthLevel = listener.consecutiveEnds >= eventListenerFailureThreshold
            ? .fail
            : .warn
        return (level, detail)
    }

    /// C8: how long a running loop may go without COMPLETING work before
    /// Doctor calls it dormant. Floored at a week so a genuinely slow lane is
    /// not slandered, and scaled to `3 × interval` so a weekly loop needs three
    /// missed weeks — the same "three periods" shape `graceWindow` uses.
    public static let dormancyFloor: TimeInterval = 7 * 24 * 60 * 60

    public static func dormancyThreshold(for observation: LoopStatus) -> TimeInterval {
        max(dormancyFloor, 3 * observation.interval)
    }

    /// True when the loop's last tick was a skip that IS evidence of health:
    /// nothing was due, the feature is not switched on, there was no queued
    /// work. Those are normal life for a loop, not a fault.
    ///
    /// A skip taken INSIDE a loop's own failure backoff is excluded because the
    /// scheduler deliberately leaves `lastError` standing on a health-neutral
    /// skip (see `record(outcome:)`), so `lastError == nil` is exactly "this
    /// skip was the loop working". The single-flight coalesce skip is excluded
    /// too: it means another tick was already running, which says nothing about
    /// what this loop achieved.
    public static func lastOutcomeWasLegitimateSkip(_ observation: LoopStatus) -> Bool {
        guard observation.lastError == nil,
              let result = observation.lastResult,
              result.hasPrefix("skipped: ") else { return false }
        let reason = String(result.dropFirst("skipped: ".count))
        return reason != LoopTickOutcome.coalescedSkipReason
            && reason != LoopTickOutcome.notDueSkipReason
    }

    /// Verdict contribution from the WORK lane: registered, ticking, no error —
    /// and nothing to show for it. nil for a loop that is not running (the
    /// schedule rules already fail that), that has completed recently, or that
    /// has not yet been given its threshold's worth of time to complete
    /// anything.
    ///
    /// Dormancy requires a tick expected to complete work; legitimate skips are healthy.
    ///
    /// A loop that has NEVER completed is judged from `firstSeenAt` — the
    /// durable stamp of when it was first registered. `lastRun` cannot serve:
    /// a lane that ticks hourly and completes nothing has a fresh `lastRun`
    /// forever, which is precisely the state this rule exists to catch. With no
    /// first-seen stamp (a loop registered by an older build) the rule stays
    /// silent rather than guessing.
    public static func dormancyVerdict(
        for observation: LoopStatus,
        now: Date
    ) -> (level: LoopHealthLevel, detail: String)? {
        guard observation.running else { return nil }
        guard observation.lastRun != nil else { return nil }
        guard !lastOutcomeWasLegitimateSkip(observation) else { return nil }
        let threshold = dormancyThreshold(for: observation)
        let reference = [observation.lastSuccessfulWorkAt, observation.firstSeenAt]
            .compactMap { $0 }
            .max()
        guard let reference else { return nil }
        let idle = now.timeIntervalSince(reference)
        guard idle > threshold else { return nil }
        let lead = observation.lastSuccessfulWorkAt == nil
            ? "Registered and ticking, but it has NEVER completed any work"
            : "Registered and ticking, but no work completed in \(describeAge(idle))"
        let reason = observation.lastResult.map { "; last outcome: \($0.trimmingCharacters(in: CharacterSet(charactersIn: ".").union(.whitespacesAndNewlines)))" } ?? ""
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
            // LOOPS-3: "no error recorded" is NOT the same as "healthy".
            // A loop whose scheduler task is not active, or that is
            // scheduled for a time long past, has produced no error
            // precisely because it never ran. Those are the states this
            // rule used to report green.
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
                detail: "Failing persistently (at least \(recentFailures) failures in \(describeAge(window))); last tick \(age) ago; last failure: \(lastError.trimmingCharacters(in: CharacterSet(charactersIn: ".").union(.whitespacesAndNewlines)))."
            )
        }
        return LoopHealthVerdict(
            loopId: observation.name,
            level: .warn,
            // Never ticked: the lane could not be built (its configuration
            // could not be read), so the error is why it cannot run.
            detail: observation.lastRun == nil ? "Cannot run: \(lastError)."
                : "Last tick failed \(age) ago: \(lastError.trimmingCharacters(in: CharacterSet(charactersIn: ".").union(.whitespacesAndNewlines)))."
        )
    }

    /// Verdict for a loop with no recorded error: judge whether it is actually
    /// SCHEDULED and RUNNING rather than assuming silence means health.
    ///
    /// - not running          → fail (a registered loop with no active
    ///                          scheduler task cannot tick; nothing self-clears)
    /// - running, no nextRun  → fail (registered but never scheduled)
    /// - never ticked, overdue→ fail (the starvation signature: the first tick
    ///                          never fired)
    /// - overdue past grace   → fail
    /// - overdue past slack   → warn (may still land)
    /// - otherwise            → the last tick's word: worked or nothing to do
    ///                          (ok), off, not needed
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
        guard let nextRun = observation.nextRun else {
            return verdict(.fail, "Not scheduled: running, but no next tick is planned; \(lastTickPhrase)")
        }

        let overdueBy = now.timeIntervalSince(nextRun)
        guard overdueBy > overdueTolerance(for: observation) else {
            guard let lastRun = observation.lastRun else {
                return verdict(.ok, "First check in \(describeAge(-overdueBy)).")
            }
            let changed = observation.lastSuccessfulWorkAt
            guard lastOutcomeWasLegitimateSkip(observation),
                  let reason = observation.lastResult?.dropFirst("skipped: ".count) else {
                let changedPhrase = changed.map { "\(describeAge(now.timeIntervalSince($0))) ago" } ?? "never"
                return verdict(.ok, "Worked \(describeAge(now.timeIntervalSince(lastRun))) ago; last changed something \(changedPhrase).")
            }
            for (prefix, level, word) in [(unavailableSkipPrefix, LoopHealthLevel.warn, "Unavailable"),
                                          (LoopTickOutcome.offPrefix, .off, "Off"),
                                          (LoopTickOutcome.notNeededPrefix, .notNeeded, "Not needed")]
            where reason.hasPrefix(prefix) {
                return verdict(level, "\(word): \(reason.dropFirst(prefix.count)).")
            }
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

    private static func rank(_ level: LoopHealthLevel) -> Int {
        switch level {
        case .fail: 0
        case .warn: 1
        case .off: 2
        case .notNeeded: 3
        case .ok: 4
        }
    }

    /// Month-day on this Mac's calendar ("10-09").
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

    /// Parses compact failure incidents per loop from the scheduler's durable
    /// receipts file (logs/background_loop_failures.jsonl). Bounded: reads at
    /// most the trailing `maxBytes` of the file and the newest `maxReceipts`
    /// rows, so a months-old file cannot balloon a Doctor load.
    public static func recentFailureDates(
        receiptsFile: URL,
        maxBytes: Int = 512 * 1024,
        maxReceipts: Int = 500
    ) -> [String: [FailureIncident]] {
        guard let read = try? SwiftNativePersistenceCore.tailPhysicalLines(receiptsFile, limit: .max, maxBytes: maxBytes),
              let text = String(data: Data(read.lines.joined(separator: [0x0A])), encoding: .utf8) else { return [:] }
        var result: [String: [FailureIncident]] = [:]
        // Drop the first line when we started mid-file: it is almost certainly
        // a partial JSON row.
        let lines = text.split(separator: "\n", omittingEmptySubsequences: true)
        let usable = read.truncatedToByteWindow ? lines.dropFirst() : lines[...]
        for line in usable.suffix(maxReceipts) {
            guard let rowData = line.data(using: .utf8),
                  let row = try? JSONSerialization.jsonObject(with: rowData) as? [String: Any],
                  let loopId = row["loopId"] as? String else { continue }
            let timestamp = (row["lastAt"] as? String) ?? (row["createdAt"] as? String) ?? ""
            guard let date = NativeTimestampFormat.parseISO8601(timestamp) else {
                continue
            }
            let firstTimestamp = (row["firstAt"] as? String) ?? (row["createdAt"] as? String) ?? ""
            let firstAt = NativeTimestampFormat.parseISO8601(firstTimestamp)
            result[loopId, default: []].append(FailureIncident(
                firstAt: firstAt,
                lastAt: date,
                cumulativeOccurrences: max(1, row["occurrences"] as? Int ?? 1)
            ))
        }
        return result
    }

    // MARK: - Doctor row

    /// `live.` excludes this mounted fleet from offline and onboarding rollups.
    public static let doctorCheckID = "live.background_loops"

    /// Roll up failing > dormant > degraded > off > not needed > healthy;
    /// off and not needed never count as healthy. Read the existing dormancy
    /// verdict, preserving the schedule/error lanes' failing precedence.
    public static func doctorCheck(
        observations: [LoopStatus],
        recentFailureDates: [String: [FailureIncident]],
        now: Date
    ) -> CheckResult {
        // Absence of loops is no signal, never health: the app registers its
        // fleet at launch, so an empty status list means the scheduler has not
        // come up (or has gone away) rather than that everything is fine.
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
        // `evaluate` sorts worst-first, so the head of the list IS the worst
        // offender; naming it means the pill's tooltip points somewhere.
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
