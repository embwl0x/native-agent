import Foundation
import BackgroundLoops
import PersistenceCore

// Doctor visibility for background loops. Motivated by 2026-07-12→16:
// github_tracking failed every tick for 4 days (633 timeout receipts in
// logs/background_loop_failures.jsonl) and nothing surfaced it — Doctor never
// read loop state. This is READ-ONLY visibility: no new persisted state, no
// notifications, no timers.
//
// The scheduler keeps no distinct last-SUCCESS timestamp (LoopState.lastTickAt
// advances on failed ticks too, and lastError != nil ⟺ the LAST tick failed —
// see record(outcome:) in BackgroundLoops.swift, which clears lastError on
// completed/skipped and sets it on failed). Persistence is therefore proven
// from the durable failure receipts file instead: a loop whose last tick
// failed AND that has ≥ persistentFailureThreshold receipts inside its grace
// window is FAILING (red); a last-tick failure without that history is a
// transient blip (yellow) that self-clears on the next successful tick.

struct LoopHealthObservation: Equatable, Sendable {
    let loopId: String
    let lastRun: Date?
    let nextRun: Date?
    let lastError: String?
    let running: Bool
    let executing: Bool
    let executionStartedAt: Date?
    let executionTimeout: TimeInterval
    /// Sweep R4 item 3: event-listener liveness. nil for loops with no event
    /// lane at all — which is NOT the same as a loop whose listener is down.
    let eventListener: LoopEventListenerHealth?
    /// C8: when the loop last COMPLETED work, and what its last tick said. A
    /// loop can be running, scheduled, error-free and ticking on time while
    /// every tick skips — every other field on this observation reads healthy
    /// for that state, which is exactly how dormant lanes stayed invisible.
    let lastSuccessfulWorkAt: Date?
    let lastResult: String?
    let firstSeenAt: Date?

    init(
        loopId: String,
        lastRun: Date?,
        nextRun: Date?,
        lastError: String?,
        running: Bool,
        executing: Bool = false,
        executionStartedAt: Date? = nil,
        executionTimeout: TimeInterval = 300,
        eventListener: LoopEventListenerHealth? = nil,
        lastSuccessfulWorkAt: Date? = nil,
        lastResult: String? = nil,
        firstSeenAt: Date? = nil
    ) {
        self.loopId = loopId
        self.lastRun = lastRun
        self.nextRun = nextRun
        self.lastError = lastError
        self.running = running
        self.executing = executing
        self.executionStartedAt = executionStartedAt
        self.executionTimeout = executionTimeout
        self.eventListener = eventListener
        self.lastSuccessfulWorkAt = lastSuccessfulWorkAt
        self.lastResult = lastResult
        self.firstSeenAt = firstSeenAt
    }

    init(status: LoopStatus) {
        self.init(
            loopId: status.name,
            lastRun: status.lastRun,
            nextRun: status.nextRun,
            lastError: status.lastError,
            running: status.running,
            executing: status.executing,
            executionStartedAt: status.executionStartedAt,
            executionTimeout: status.executionTimeout,
            eventListener: status.eventListener,
            lastSuccessfulWorkAt: status.lastSuccessfulWorkAt,
            lastResult: status.lastResult,
            firstSeenAt: status.firstSeenAt
        )
    }
}

enum LoopHealthLevel: String, Sendable {
    case ok
    case warn
    case fail

    /// Vocabulary understood by NativeAgentTheme.statusColor / StatusBadge.
    var statusText: String {
        switch self {
        case .ok: "ok"
        case .warn: "warn"
        case .fail: "failed"
        }
    }
}

struct LoopHealthVerdict: Equatable, Identifiable, Sendable {
    let loopId: String
    let level: LoopHealthLevel
    let detail: String
    var id: String { loopId }
}

enum DoctorLoopHealth {
    /// Receipts inside the grace window needed to call a failure persistent
    /// rather than a blip. At the common 5-minute tick interval the 30-minute
    /// floor holds up to 6 ticks, so 3 = half the window solidly failing.
    static let persistentFailureThreshold = 3

    /// The scheduler sets nextTickAt = lastTickAt + interval on every recorded
    /// tick, so the spread is a faithful interval estimate; loops that have not
    /// ticked yet fall back to the 5-minute manager default.
    static func estimatedInterval(for observation: LoopHealthObservation) -> TimeInterval {
        if let last = observation.lastRun, let next = observation.nextRun, next > last {
            return next.timeIntervalSince(last)
        }
        return 300
    }

    /// Grace window = max(3 × estimated interval, 30 min).
    static func graceWindow(for observation: LoopHealthObservation) -> TimeInterval {
        max(3 * estimatedInterval(for: observation), 30 * 60)
    }

    /// How far past `nextRun` a loop may drift before Doctor calls it overdue.
    /// Half an estimated interval, floored at 60s, so ordinary tick jitter and
    /// a tick body that legitimately runs long never flap the verdict.
    static func overdueTolerance(for observation: LoopHealthObservation) -> TimeInterval {
        max(estimatedInterval(for: observation) / 2, 60)
    }

    /// Pure health rule. `recentFailureDates` maps loopId → receipt timestamps
    /// (any order), with coalesced incidents contributing one timestamp per
    /// occurrence. Only receipts inside the loop's grace window count toward
    /// persistence.
    static func evaluate(
        observations: [LoopHealthObservation],
        recentFailureDates: [String: [Date]],
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
    static let eventListenerFailureThreshold = 3

    /// Verdict contribution from the EVENT lane. nil when the loop has no event
    /// listener, or when the listener is alive and has not been flapping.
    static func eventListenerVerdict(
        for observation: LoopHealthObservation,
        now: Date
    ) -> (level: LoopHealthLevel, detail: String)? {
        guard let listener = observation.eventListener else { return nil }
        if listener.active, listener.consecutiveEnds == 0 { return nil }
        let endedPhrase = listener.lastEndedAt
            .map { "last ended \(describeAge(now.timeIntervalSince($0))) ago" }
            ?? "never started"
        let restarts = listener.restartCount == 1 ? "1 restart" : "\(listener.restartCount) restarts"
        let detail = "Event listener \(listener.active ? "restarted but not yet delivering" : "is down")"
            + " (\(listener.consecutiveEnds) consecutive stream end(s), \(restarts), \(endedPhrase))."
            + (listener.lastError.map { " \($0)" } ?? "")
        let level: LoopHealthLevel = listener.consecutiveEnds >= eventListenerFailureThreshold
            ? .fail
            : .warn
        return (level, detail)
    }

    /// C8: how long a running loop may go without COMPLETING work before
    /// Doctor calls it dormant. Floored at a week so a genuinely slow lane is
    /// not slandered, and scaled to `3 × interval` so a weekly loop needs three
    /// missed weeks — the same "three periods" shape `graceWindow` uses.
    static let dormancyFloor: TimeInterval = 7 * 24 * 60 * 60

    static func dormancyThreshold(for observation: LoopHealthObservation) -> TimeInterval {
        max(dormancyFloor, 3 * estimatedInterval(for: observation))
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
    static func lastOutcomeWasLegitimateSkip(_ observation: LoopHealthObservation) -> Bool {
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
    /// 2026-09-10 (D3): the bound applies only to a loop that was EXPECTED to
    /// complete work in the window. A loop whose last tick legitimately skipped
    /// — nothing due, feature off, no queued work — completed nothing because
    /// there was nothing to complete, and a loop whose first tick has not fired
    /// yet has had no chance at all. Calling either one dormant put nine
    /// warnings on a healthy install ("no work completed in 9d. Last outcome:
    /// skipped: no Desk notification due"), which is normal life reported as a
    /// fault.
    ///
    /// A loop that has NEVER completed is judged from `firstSeenAt` — the
    /// durable stamp of when it was first registered. `lastRun` cannot serve:
    /// a lane that ticks hourly and completes nothing has a fresh `lastRun`
    /// forever, which is precisely the state this rule exists to catch. With no
    /// first-seen stamp (a loop registered by an older build) the rule stays
    /// silent rather than guessing.
    static func dormancyVerdict(
        for observation: LoopHealthObservation,
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
        let reason = observation.lastResult.map { " Last outcome: \($0)." } ?? ""
        return (
            .warn,
            "\(lead) (dormancy bound \(describeAge(threshold))).\(reason)"
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
            detail: "\(base.detail) \(listener.detail)"
        )
    }

    private static func baseVerdict(
        for observation: LoopHealthObservation,
        recentFailureDates: [String: [Date]],
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
        let recentFailures = (recentFailureDates[observation.loopId] ?? [])
            .filter { $0 >= cutoff && $0 <= now }
            .count
        let age = observation.lastRun.map { describeAge(now.timeIntervalSince($0)) } ?? "unknown"
        if recentFailures >= persistentFailureThreshold {
            return LoopHealthVerdict(
                loopId: observation.loopId,
                level: .fail,
                detail: "Failing persistently (\(recentFailures) failures in \(describeAge(window))): \(lastError). Last tick \(age) ago."
            )
        }
        return LoopHealthVerdict(
            loopId: observation.loopId,
            level: .warn,
            detail: "Last tick failed: \(lastError). Last tick \(age) ago."
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
    /// - otherwise            → ok
    static func scheduleVerdict(
        for observation: LoopHealthObservation,
        now: Date
    ) -> LoopHealthVerdict {
        func verdict(_ level: LoopHealthLevel, _ detail: String) -> LoopHealthVerdict {
            LoopHealthVerdict(loopId: observation.loopId, level: level, detail: detail)
        }
        let lastTickPhrase = observation.lastRun
            .map { "Last tick \(describeAge(now.timeIntervalSince($0))) ago." }
            ?? "It has never ticked."

        guard observation.running else {
            return verdict(.fail, "Not running: registered, but no scheduler task is active. \(lastTickPhrase)")
        }
        if observation.executing {
            let age = observation.executionStartedAt
                .map { max(0, now.timeIntervalSince($0)) }
            if let age, age > observation.executionTimeout + overdueTolerance(for: observation) {
                return verdict(
                    .fail,
                    "Active tick exceeded its \(describeAge(observation.executionTimeout)) watchdog. \(lastTickPhrase)"
                )
            }
            let agePhrase = age.map { " for \(describeAge($0))" } ?? ""
            return verdict(.ok, "Active tick in progress\(agePhrase).")
        }
        guard let nextRun = observation.nextRun else {
            return verdict(.fail, "Not scheduled: running, but no next tick is planned. \(lastTickPhrase)")
        }

        let overdueBy = now.timeIntervalSince(nextRun)
        guard overdueBy > overdueTolerance(for: observation) else {
            if observation.lastRun == nil {
                return verdict(.ok, "First check in \(describeAge(-overdueBy)).")
            }
            if lastOutcomeWasLegitimateSkip(observation) {
                return verdict(.ok, "Ticking; nothing was due on the last check.")
            }
            return verdict(.ok, "Healthy.")
        }
        if observation.lastRun == nil {
            return verdict(.fail, "Never ticked and overdue by \(describeAge(overdueBy)): the first tick has not fired.")
        }
        let grace = graceWindow(for: observation)
        if overdueBy > grace {
            return verdict(.fail, "Overdue by \(describeAge(overdueBy)) (beyond \(describeAge(grace)) grace). \(lastTickPhrase)")
        }
        return verdict(.warn, "Overdue by \(describeAge(overdueBy)). \(lastTickPhrase)")
    }

    private static func rank(_ level: LoopHealthLevel) -> Int {
        switch level {
        case .fail: 0
        case .warn: 1
        case .ok: 2
        }
    }

    static func describeAge(_ seconds: TimeInterval) -> String {
        let s = max(0, seconds)
        if s < 90 { return "\(Int(s))s" }
        if s < 90 * 60 { return "\(Int(s / 60))m" }
        if s < 36 * 3600 { return "\(Int(s / 3600))h" }
        return "\(Int(s / 86400))d"
    }

    /// Parses failure-receipt timestamps per loop from the scheduler's durable
    /// receipts file (logs/background_loop_failures.jsonl). Bounded: reads at
    /// most the trailing `maxBytes` of the file and the newest `maxReceipts`
    /// rows, so a months-old file cannot balloon a Doctor load.
    static func recentFailureDates(
        receiptsFile: URL,
        maxBytes: Int = 512 * 1024,
        maxReceipts: Int = 500
    ) -> [String: [Date]] {
        guard let handle = try? FileHandle(forReadingFrom: receiptsFile) else { return [:] }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        let start = size > UInt64(maxBytes) ? size - UInt64(maxBytes) : 0
        guard (try? handle.seek(toOffset: start)) != nil,
              let data = try? handle.readToEnd(),
              let text = String(data: data, encoding: .utf8) else { return [:] }
        let parser = ISO8601DateFormatter()
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var result: [String: [Date]] = [:]
        // Drop the first line when we started mid-file: it is almost certainly
        // a partial JSON row.
        let lines = text.split(separator: "\n", omittingEmptySubsequences: true)
        let usable = start > 0 ? lines.dropFirst() : lines[...]
        for line in usable.suffix(maxReceipts) {
            guard let rowData = line.data(using: .utf8),
                  let row = try? JSONSerialization.jsonObject(with: rowData) as? [String: Any],
                  let loopId = row["loopId"] as? String else { continue }
            let timestamp = (row["lastAt"] as? String) ?? (row["createdAt"] as? String) ?? ""
            guard let date = parser.date(from: timestamp) ?? fractional.date(from: timestamp) else {
                continue
            }
            let occurrences = max(1, row["occurrences"] as? Int ?? 1)
            for _ in 0..<occurrences {
                result[loopId, default: []].append(date)
            }
        }
        return result
    }

    // MARK: - Doctor row (FIX-4, 2026-09-01)

    /// The id of the single Doctor row that carries loop health.
    ///
    /// Until this existed, `DoctorLoopHealth` was rendered only inside the
    /// Doctor loops section: `doctorReport.checks` carried no loop row, so
    /// `AppModel.systemHealthSummary` (the toolbar pill) could not see a
    /// verdict from here. On 2026-09-01 the receipts file held 215
    /// telegram_poll and 212 slack failures and the pill was green.
    ///
    /// The `live.` prefix is load-bearing, not decoration: it marks an
    /// app-added live-owner row, which keeps this out of the Support
    /// Snapshot's OFFLINE rollup (a cold core `runAll` in another process has
    /// no loop fleet to report) and out of onboarding's app-scaffold gate.
    static let doctorCheckID = "live.background_loops"

    /// One Doctor row summarizing every loop verdict: counts by bucket and the
    /// worst offender named, so a flapping fleet lowers the pill.
    ///
    /// Buckets are assigned per loop with precedence failing > dormant >
    /// degraded > healthy. `dormancyVerdict` is READ, never re-decided: a loop
    /// it flags is reported as dormant unless the schedule/error lanes already
    /// called it failing.
    static func doctorCheck(
        observations: [LoopHealthObservation],
        recentFailureDates: [String: [Date]],
        now: Date
    ) -> DoctorCheck {
        // Absence of loops is no signal, never health: the app registers its
        // fleet at launch, so an empty status list means the scheduler has not
        // come up (or has gone away) rather than that everything is fine.
        guard !observations.isEmpty else {
            return DoctorCheck(
                id: doctorCheckID,
                title: "Background Loops",
                status: "warn",
                detail: "No background loops are registered, so there is nothing to report on. "
                    + "That is a missing signal, not a clean bill of health.",
                repair: nil
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
                .map(\.loopId)
        )
        var failing: [LoopHealthVerdict] = []
        var dormantVerdicts: [LoopHealthVerdict] = []
        var degraded: [LoopHealthVerdict] = []
        var healthy = 0
        for verdict in verdicts {
            switch verdict.level {
            case .fail: failing.append(verdict)
            case .warn:
                if dormant.contains(verdict.loopId) {
                    dormantVerdicts.append(verdict)
                } else {
                    degraded.append(verdict)
                }
            case .ok: healthy += 1
            }
        }
        var counts = ["\(failing.count) failing", "\(dormantVerdicts.count) dormant"]
        if !degraded.isEmpty { counts.append("\(degraded.count) degraded") }
        counts.append("\(healthy) healthy")
        var detail = "\(verdicts.count) background loop(s): \(counts.joined(separator: ", "))."
        // `evaluate` sorts worst-first, so the head of the list IS the worst
        // offender; naming it means the pill's tooltip points somewhere.
        if let worst = verdicts.first, worst.level != .ok {
            detail += " Worst: \(worst.loopId) — \(worst.detail)"
        }
        let status: String
        if !failing.isEmpty {
            status = "fail"
        } else if dormantVerdicts.isEmpty && degraded.isEmpty {
            status = "ok"
        } else {
            status = "warn"
        }
        return DoctorCheck(
            id: doctorCheckID,
            title: "Background Loops",
            status: status,
            detail: detail,
            repair: status == "ok" ? nil : "Open Doctor → background loops for the per-loop verdicts."
        )
    }

    /// Live variant of `doctorCheck`, sharing `current`'s inputs.
    static func doctorCheck(
        dataRoot: URL = PersistenceCore.defaultDataRoot(),
        now: Date = Date()
    ) async -> DoctorCheck {
        let statuses = await BackgroundLoops.BackgroundLoopsManager.shared.status()
        let receipts = recentFailureDates(
            receiptsFile: dataRoot.appendingPathComponent("logs/background_loop_failures.jsonl")
        )
        return doctorCheck(
            observations: statuses.map(LoopHealthObservation.init(status:)),
            recentFailureDates: receipts,
            now: now
        )
    }

    /// Live snapshot for DoctorView: core manager states + receipts tail.
    static func current(
        dataRoot: URL = PersistenceCore.defaultDataRoot(),
        now: Date = Date()
    ) async -> [LoopHealthVerdict] {
        let statuses = await BackgroundLoops.BackgroundLoopsManager.shared.status()
        let receipts = recentFailureDates(
            receiptsFile: dataRoot.appendingPathComponent("logs/background_loop_failures.jsonl")
        )
        return evaluate(
            observations: statuses.map(LoopHealthObservation.init(status:)),
            recentFailureDates: receipts,
            now: now
        )
    }
}
