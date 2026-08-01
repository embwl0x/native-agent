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
    running: Bool = true
) -> LoopHealthObservation {
    LoopHealthObservation(
        loopId: loopId,
        lastRun: lastRun,
        nextRun: nextRun ?? lastRun?.addingTimeInterval(interval),
        lastError: lastError,
        running: running
    )
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

@Test func never_ticked_but_scheduled_ahead_is_ok_with_no_ticks_detail() {
    let now = Date(timeIntervalSince1970: 1_784_200_000)
    let obs = observation(lastRun: nil, lastError: nil, nextRun: now.addingTimeInterval(300))
    let verdicts = DoctorLoopHealth.evaluate(observations: [obs], recentFailureDates: [:], now: now)
    #expect(verdicts[0].level == .ok)
    #expect(verdicts[0].detail.hasPrefix("No ticks yet"))
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

@Test func receipts_parser_missing_file_is_empty_not_crash() {
    let missing = FileManager.default.temporaryDirectory
        .appendingPathComponent("nonexistent-\(UUID().uuidString).jsonl")
    #expect(DoctorLoopHealth.recentFailureDates(receiptsFile: missing).isEmpty)
}
