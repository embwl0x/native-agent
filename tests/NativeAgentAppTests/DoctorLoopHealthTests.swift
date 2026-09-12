// Doctor loop-health rule (2026-07-16): github_tracking failed every tick for
// 4 days with zero surfacing. These pin the pure rule in DoctorLoopHealth:
// FAIL requires last-tick failure PLUS proven persistence from failure
// receipts inside the grace window; a lone blip is WARN; success is OK. The
// scheduler clears lastError on completed/skipped ticks, so lastError != nil
// is exactly "the last tick failed".

import Foundation
import Testing
@testable import NativeAgentApp

private func observation(
    loopId: String = "github_tracking",
    lastRun: Date?,
    interval: TimeInterval = 300,
    lastError: String?,
    nextRun: Date? = nil,
    running: Bool = true,
    executing: Bool = false,
    executionStartedAt: Date? = nil,
    executionTimeout: TimeInterval = 300
) -> LoopHealthObservation {
    LoopHealthObservation(
        loopId: loopId,
        lastRun: lastRun,
        nextRun: nextRun ?? lastRun?.addingTimeInterval(interval),
        lastError: lastError,
        running: running,
        executing: executing,
        executionStartedAt: executionStartedAt,
        executionTimeout: executionTimeout
    )
}

@Test func long_lived_active_tick_is_not_called_overdue() {
    let now = Date(timeIntervalSince1970: 1_784_200_000)
    let obs = observation(
        loopId: "slack_socket_mode",
        lastRun: now.addingTimeInterval(-1_200),
        interval: 2,
        lastError: nil,
        nextRun: now.addingTimeInterval(-1_198),
        executing: true,
        executionStartedAt: now.addingTimeInterval(-900),
        executionTimeout: 3_900
    )
    let verdict = DoctorLoopHealth.evaluate(
        observations: [obs], recentFailureDates: [:], now: now
    )[0]
    #expect(verdict.level == .ok)
    #expect(verdict.detail.contains("Active tick in progress"))
    #expect(!verdict.detail.contains("Overdue"))
}

@Test func active_tick_past_its_watchdog_is_not_hidden() {
    let now = Date(timeIntervalSince1970: 1_784_200_000)
    let obs = observation(
        lastRun: now.addingTimeInterval(-600),
        lastError: nil,
        executing: true,
        executionStartedAt: now.addingTimeInterval(-700),
        executionTimeout: 300
    )
    let verdict = DoctorLoopHealth.evaluate(
        observations: [obs], recentFailureDates: [:], now: now
    )[0]
    #expect(verdict.level == .fail)
    #expect(verdict.detail.contains("exceeded"))
}

@Test func persistently_failing_loop_is_fail() {
    let now = Date(timeIntervalSince1970: 1_784_200_000)
    let obs = observation(lastRun: now.addingTimeInterval(-60), lastError: "timeout after 600s")
    // 4 receipts inside the 30-min window (5-min interval → grace = 30 min).
    let receipts = ["github_tracking": (1...4).map { now.addingTimeInterval(TimeInterval(-300 * $0)) }]
    let verdicts = DoctorLoopHealth.evaluate(observations: [obs], recentFailureDates: receipts, now: now)
    #expect(verdicts.count == 1)
    #expect(verdicts[0].level == .fail)
    #expect(verdicts[0].detail.contains("timeout after 600s"))
}

@Test func single_blip_is_warn_not_fail() {
    let now = Date(timeIntervalSince1970: 1_784_200_000)
    let obs = observation(lastRun: now.addingTimeInterval(-60), lastError: "HTTP 504")
    let receipts = ["github_tracking": [now.addingTimeInterval(-60)]]
    let verdicts = DoctorLoopHealth.evaluate(observations: [obs], recentFailureDates: receipts, now: now)
    #expect(verdicts[0].level == .warn)
}

@Test func old_receipts_outside_grace_window_do_not_count() {
    let now = Date(timeIntervalSince1970: 1_784_200_000)
    let obs = observation(lastRun: now.addingTimeInterval(-60), lastError: "HTTP 504")
    // Plenty of receipts, all older than the 30-min grace window.
    let receipts = ["github_tracking": (1...10).map { now.addingTimeInterval(TimeInterval(-3600 * $0)) }]
    let verdicts = DoctorLoopHealth.evaluate(observations: [obs], recentFailureDates: receipts, now: now)
    #expect(verdicts[0].level == .warn)
}

@Test func healthy_loop_is_ok_and_recovered_loop_clears() {
    let now = Date(timeIntervalSince1970: 1_784_200_000)
    // lastError == nil ⟺ last tick succeeded/skipped — even with a deep
    // failure history in the receipts, the verdict is OK (self-clearing).
    let obs = observation(lastRun: now.addingTimeInterval(-30), lastError: nil)
    let receipts = ["github_tracking": (1...6).map { now.addingTimeInterval(TimeInterval(-300 * $0)) }]
    let verdicts = DoctorLoopHealth.evaluate(observations: [obs], recentFailureDates: receipts, now: now)
    #expect(verdicts[0].level == .ok)
}

// LOOPS-3: "no error recorded" is not the same as "healthy". A loop that has
// never ticked is only OK while its first tick is still genuinely PENDING —
// running, and scheduled for a time that has not passed yet.

@Test func never_ticked_but_scheduled_ahead_is_ok_with_first_check_detail() {
    let now = Date(timeIntervalSince1970: 1_784_200_000)
    let obs = observation(lastRun: nil, lastError: nil, nextRun: now.addingTimeInterval(300))
    let verdicts = DoctorLoopHealth.evaluate(observations: [obs], recentFailureDates: [:], now: now)
    #expect(verdicts[0].level == .ok)
    // D3 (2026-09-10): plain sentence, no "no ticks yet" hedge stacked with a
    // dormancy warning behind it.
    #expect(verdicts[0].detail == "First check in 5m.")
}

@Test func never_ticked_and_overdue_is_fail_not_ok() {
    // The LOOPS-4 starvation signature seen from Doctor's side: a weekly loop
    // whose scheduled first tick came and went days ago. lastError is nil
    // precisely BECAUSE it never ran — the old rule reported this green.
    let now = Date(timeIntervalSince1970: 1_784_200_000)
    let obs = observation(
        loopId: "weekly_self_improvement",
        lastRun: nil,
        lastError: nil,
        nextRun: now.addingTimeInterval(-3 * 86_400)
    )
    let verdicts = DoctorLoopHealth.evaluate(observations: [obs], recentFailureDates: [:], now: now)
    #expect(verdicts[0].level == .fail)
    #expect(verdicts[0].detail.contains("Never ticked and overdue"))
}

@Test func not_running_loop_is_fail_even_with_no_error() {
    let now = Date(timeIntervalSince1970: 1_784_200_000)
    let obs = observation(
        lastRun: now.addingTimeInterval(-30),
        lastError: nil,
        running: false
    )
    let verdicts = DoctorLoopHealth.evaluate(observations: [obs], recentFailureDates: [:], now: now)
    #expect(verdicts[0].level == .fail)
    #expect(verdicts[0].detail.contains("Not running"))
}

@Test func running_but_unscheduled_loop_is_fail() {
    // Registered, running, but no next tick planned — it can never fire.
    let now = Date(timeIntervalSince1970: 1_784_200_000)
    let obs = observation(lastRun: nil, lastError: nil, nextRun: nil)
    let verdicts = DoctorLoopHealth.evaluate(observations: [obs], recentFailureDates: [:], now: now)
    #expect(verdicts[0].level == .fail)
    #expect(verdicts[0].detail.contains("Not scheduled"))
}

@Test func mildly_overdue_loop_that_has_ticked_before_is_warn_not_fail() {
    let now = Date(timeIntervalSince1970: 1_784_200_000)
    // 5-min loop, next tick was due 5 min ago: past the 150s slack but well
    // inside the 30-min grace window — it may still land.
    let obs = observation(
        lastRun: now.addingTimeInterval(-600),
        lastError: nil,
        nextRun: now.addingTimeInterval(-300)
    )
    let verdicts = DoctorLoopHealth.evaluate(observations: [obs], recentFailureDates: [:], now: now)
    #expect(verdicts[0].level == .warn)
    #expect(verdicts[0].detail.contains("Overdue by"))
}

@Test func severely_overdue_loop_escalates_to_fail() {
    let now = Date(timeIntervalSince1970: 1_784_200_000)
    // 5-min loop whose next tick was due 4 hours ago — far beyond grace.
    let obs = observation(
        lastRun: now.addingTimeInterval(-4 * 3600 - 300),
        lastError: nil,
        nextRun: now.addingTimeInterval(-4 * 3600)
    )
    let verdicts = DoctorLoopHealth.evaluate(observations: [obs], recentFailureDates: [:], now: now)
    #expect(verdicts[0].level == .fail)
}

@Test func tick_jitter_within_slack_stays_ok() {
    // A tick 30s late must not flap the verdict.
    let now = Date(timeIntervalSince1970: 1_784_200_000)
    let obs = observation(
        lastRun: now.addingTimeInterval(-330),
        lastError: nil,
        nextRun: now.addingTimeInterval(-30)
    )
    let verdicts = DoctorLoopHealth.evaluate(observations: [obs], recentFailureDates: [:], now: now)
    #expect(verdicts[0].level == .ok)
}

@Test func long_interval_loop_gets_proportional_grace() {
    let now = Date(timeIntervalSince1970: 1_784_200_000)
    // Hourly loop → grace = 3h, so receipts 1-2h old still count.
    let obs = observation(lastRun: now.addingTimeInterval(-120), interval: 3600, lastError: "boom")
    let receipts = ["github_tracking": [
        now.addingTimeInterval(-3600),
        now.addingTimeInterval(-7200),
        now.addingTimeInterval(-120),
    ]]
    let verdicts = DoctorLoopHealth.evaluate(observations: [obs], recentFailureDates: receipts, now: now)
    #expect(verdicts[0].level == .fail)
}

@Test func verdicts_sort_fail_first_then_warn_then_ok() {
    let now = Date(timeIntervalSince1970: 1_784_200_000)
    let receipts = ["a_failing": (1...4).map { now.addingTimeInterval(TimeInterval(-300 * $0)) }]
    let verdicts = DoctorLoopHealth.evaluate(
        observations: [
            observation(loopId: "z_healthy", lastRun: now, lastError: nil),
            observation(loopId: "a_failing", lastRun: now, lastError: "x"),
            observation(loopId: "m_blip", lastRun: now, lastError: "y"),
        ],
        recentFailureDates: receipts,
        now: now
    )
    #expect(verdicts.map(\.loopId) == ["a_failing", "m_blip", "z_healthy"])
}

@Test func receipts_parser_reads_tail_and_groups_by_loop() throws {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("DoctorLoopHealthTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let file = dir.appendingPathComponent("background_loop_failures.jsonl")
    let rows = [
        #"{"kind":"background_loop.failure","loopId":"github_tracking","status":"failed","error":"timeout after 120s","createdAt":"2026-07-16T07:52:13Z","id":"1"}"#,
        #"{"kind":"background_loop.failure","loopId":"slack_socket_mode","status":"failed","error":"timeout","createdAt":"2026-07-16T06:00:00Z","id":"2"}"#,
        #"{"kind":"background_loop.failure","loopId":"github_tracking","status":"failed","error":"HTTP 504","createdAt":"2026-07-16T07:37:01.500Z","id":"3"}"#,
        "not json at all",
    ]
    try rows.joined(separator: "\n").write(to: file, atomically: true, encoding: .utf8)
    let parsed = DoctorLoopHealth.recentFailureDates(receiptsFile: file)
    #expect(parsed["github_tracking"]?.count == 2)
    #expect(parsed["slack_socket_mode"]?.count == 1)
}

@Test func receipts_parser_counts_coalesced_occurrences() throws {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("DoctorLoopHealthOccurrences-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let file = dir.appendingPathComponent("background_loop_failures.jsonl")
    try """
    {"kind":"background_loop.failure","loopId":"github_tracking","status":"failed","error":"timeout after 120s","createdAt":"2026-07-16T07:52:13Z","firstAt":"2026-07-16T07:52:13Z","lastAt":"2026-07-16T07:54:13Z","occurrences":3,"id":"1"}
    """.write(to: file, atomically: true, encoding: .utf8)

    let parsed = DoctorLoopHealth.recentFailureDates(receiptsFile: file)
    #expect(parsed["github_tracking"]?.count == 3)
}

/// C4: receipts coalesce, so a loop that fails every tick now leaves ONE row
/// carrying `occurrences` instead of N rows. If Doctor kept counting ROWS, that
/// loop would drop from persistently-failing (red) to a single blip (yellow)
/// and persistent-failure detection would die silently. This runs the real
/// path — coalesced file on disk → recentFailureDates → evaluate — and pins the
/// red verdict, with a control proving the assertion can still see yellow.
@Test func doctor_flags_persistent_failure_from_a_single_coalesced_receipt() throws {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("DoctorCoalescedPersistence-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }

    let now = Date(timeIntervalSince1970: 1_784_200_000)
    let stamp = ISO8601DateFormatter()
    let firstAt = stamp.string(from: now.addingTimeInterval(-1_200))
    let lastAt = stamp.string(from: now.addingTimeInterval(-60))
    let obs = observation(lastRun: now.addingTimeInterval(-60), lastError: "timeout after 120s")

    func verdict(occurrences: Int) throws -> LoopHealthVerdict {
        let file = dir.appendingPathComponent("failures-\(occurrences).jsonl")
        try """
        {"kind":"background_loop.failure","loopId":"github_tracking","status":"failed","error":"timeout after 120s","firstAt":"\(firstAt)","lastAt":"\(lastAt)","occurrences":\(occurrences),"id":"1"}
        """.write(to: file, atomically: true, encoding: .utf8)
        let dates = DoctorLoopHealth.recentFailureDates(receiptsFile: file)
        return DoctorLoopHealth.evaluate(
            observations: [obs], recentFailureDates: dates, now: now
        )[0]
    }

    // One row, occurrences ≥ threshold → still persistently failing.
    let coalesced = try verdict(occurrences: DoctorLoopHealth.persistentFailureThreshold + 1)
    #expect(coalesced.level == .fail)
    #expect(coalesced.detail.contains("Failing persistently"))

    // Control: the same single row without a streak behind it stays a blip, so
    // the assertion above is not passing for free.
    let single = try verdict(occurrences: 1)
    #expect(single.level == .warn)
}

@Test func receipts_parser_missing_file_is_empty_not_crash() {
    let missing = FileManager.default.temporaryDirectory
        .appendingPathComponent("nonexistent-\(UUID().uuidString).jsonl")
    #expect(DoctorLoopHealth.recentFailureDates(receiptsFile: missing).isEmpty)
}

// FIX-4 (2026-09-01): the loop verdicts above had no route into
// `doctorReport.checks`, so `AppModel.systemHealthSummary` — the toolbar pill —
// could not see them. On the day this was written the receipts file held 215
// telegram_poll and 212 slack failures and the pill was green. These pin the
// single `background_loops` row that carries the fleet into that report.

private func loopObservation(
    loopId: String,
    now: Date,
    lastError: String? = nil,
    running: Bool = true,
    lastSuccessfulWorkAt: Date? = nil,
    firstSeenAt: Date? = nil,
    interval: TimeInterval = 300
) -> LoopHealthObservation {
    LoopHealthObservation(
        loopId: loopId,
        lastRun: now.addingTimeInterval(-interval / 2),
        nextRun: now.addingTimeInterval(interval / 2),
        lastError: lastError,
        running: running,
        lastSuccessfulWorkAt: lastSuccessfulWorkAt,
        firstSeenAt: firstSeenAt
    )
}

@Test func background_loops_row_reports_a_failing_fleet_as_fail_and_names_the_worst() {
    let now = Date(timeIntervalSince1970: 1_784_200_000)
    let failing = loopObservation(
        loopId: "telegram_poll",
        now: now,
        lastError: "getUpdates timed out",
        lastSuccessfulWorkAt: now.addingTimeInterval(-600)
    )
    let dormant = loopObservation(
        loopId: "weekly_self_improvement",
        now: now,
        lastSuccessfulWorkAt: now.addingTimeInterval(-30 * 86_400),
        firstSeenAt: now.addingTimeInterval(-60 * 86_400)
    )
    let healthy = loopObservation(
        loopId: "memory_hygiene",
        now: now,
        lastSuccessfulWorkAt: now.addingTimeInterval(-120)
    )
    let receipts = [
        "telegram_poll": (0..<DoctorLoopHealth.persistentFailureThreshold)
            .map { now.addingTimeInterval(-60 * Double($0 + 1)) },
    ]

    let row = DoctorLoopHealth.doctorCheck(
        observations: [healthy, dormant, failing],
        recentFailureDates: receipts,
        now: now
    )
    // `live.` marks an app-added live row: excluded from the Support
    // Snapshot's offline rollup and from onboarding's scaffold gate, included
    // in `doctorReport.checks` — which is all the pill reads.
    #expect(row.id == "live.background_loops")
    #expect(NativeClient.supportSnapshotOfflineRollup([row]) == "ok")
    #expect(row.status == "fail")
    #expect(row.detail.contains("3 background loop(s)"))
    #expect(row.detail.contains("1 failing"))
    #expect(row.detail.contains("1 dormant"))
    #expect(row.detail.contains("1 healthy"))
    #expect(row.detail.contains("Worst: telegram_poll"))
    #expect(row.detail.contains("Failing persistently"))

    // The row is the whole point: a failing fleet must lower the pill, which
    // reads `doctorReport.checks` and nothing else.
    let report = DoctorReport(status: "ok", repaired: false, checks: [row])
    #expect(NativeClient.doctorRollup(report.checks.map(\.status)) == "fail")
}

@Test func background_loops_row_separates_dormant_from_healthy() {
    let now = Date(timeIntervalSince1970: 1_784_200_000)
    let dormant = loopObservation(
        loopId: "procedural_lane",
        now: now,
        lastSuccessfulWorkAt: nil,
        firstSeenAt: now.addingTimeInterval(-30 * 86_400)
    )
    let healthy = loopObservation(
        loopId: "memory_hygiene",
        now: now,
        lastSuccessfulWorkAt: now.addingTimeInterval(-120)
    )
    let row = DoctorLoopHealth.doctorCheck(
        observations: [dormant, healthy],
        recentFailureDates: [:],
        now: now
    )
    #expect(row.status == "warn")
    #expect(row.detail.contains("0 failing"))
    #expect(row.detail.contains("1 dormant"))
    #expect(row.detail.contains("1 healthy"))
    #expect(row.detail.contains("Worst: procedural_lane"))
    #expect(row.repair != nil)
}

@Test func background_loops_row_is_green_only_when_every_loop_is() {
    let now = Date(timeIntervalSince1970: 1_784_200_000)
    let row = DoctorLoopHealth.doctorCheck(
        observations: [
            loopObservation(loopId: "a", now: now, lastSuccessfulWorkAt: now.addingTimeInterval(-60)),
            loopObservation(loopId: "b", now: now, lastSuccessfulWorkAt: now.addingTimeInterval(-60)),
        ],
        recentFailureDates: [:],
        now: now
    )
    #expect(row.status == "ok")
    #expect(row.detail.contains("2 healthy"))
    #expect(row.repair == nil)
}

@Test func background_loops_row_treats_an_empty_fleet_as_missing_signal() {
    let row = DoctorLoopHealth.doctorCheck(
        observations: [],
        recentFailureDates: [:],
        now: Date(timeIntervalSince1970: 1_784_200_000)
    )
    // Absence is no signal, never health.
    #expect(row.status == "warn")
    #expect(row.detail.contains("No background loops are registered"))
}
