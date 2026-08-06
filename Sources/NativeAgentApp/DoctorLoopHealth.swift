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
    /// Sweep R4 item 3: event-listener liveness. nil for loops with no event
    /// lane at all — which is NOT the same as a loop whose listener is down.
    let eventListener: LoopEventListenerHealth?

    init(
        loopId: String,
        lastRun: Date?,
        nextRun: Date?,
        lastError: String?,
        running: Bool,
        eventListener: LoopEventListenerHealth? = nil
    ) {
        self.loopId = loopId
        self.lastRun = lastRun
        self.nextRun = nextRun
        self.lastError = lastError
        self.running = running
        self.eventListener = eventListener
    }

    init(status: LoopStatus) {
        self.init(
            loopId: status.name,
            lastRun: status.lastRun,
            nextRun: status.nextRun,
            lastError: status.lastError,
            running: status.running,
            eventListener: status.eventListener
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
    /// (any order); only receipts inside the loop's grace window count toward
    /// persistence.
    static func evaluate(
        observations: [LoopHealthObservation],
        recentFailureDates: [String: [Date]],
        now: Date
    ) -> [LoopHealthVerdict] {
        observations.map { observation in
            merge(baseVerdict(for: observation, recentFailureDates: recentFailureDates, now: now),
                  with: eventListenerVerdict(for: observation, now: now))
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
        guard let nextRun = observation.nextRun else {
            return verdict(.fail, "Not scheduled: running, but no next tick is planned. \(lastTickPhrase)")
        }

        let overdueBy = now.timeIntervalSince(nextRun)
        guard overdueBy > overdueTolerance(for: observation) else {
            if observation.lastRun == nil {
                return verdict(.ok, "No ticks yet; first tick due in \(describeAge(-overdueBy)).")
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
                  let loopId = row["loopId"] as? String,
                  let createdAt = row["createdAt"] as? String,
                  let date = parser.date(from: createdAt) ?? fractional.date(from: createdAt)
            else { continue }
            result[loopId, default: []].append(date)
        }
        return result
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
