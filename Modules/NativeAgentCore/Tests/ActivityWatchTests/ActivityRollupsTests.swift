import Foundation
import Testing
@testable import ActivityWatch

// MARK: - Support

private let newYork = TimeZone(identifier: "America/New_York")!
private let utc = TimeZone(identifier: "UTC")!

/// Local midnight, as an epoch instant, in a named timezone.
private func midnight(_ year: Int, _ month: Int, _ day: Int, in zone: TimeZone) -> Double {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = zone
    var components = DateComponents()
    components.year = year
    components.month = month
    components.day = day
    return calendar.date(from: components)!.timeIntervalSince1970
}

private func span(
    _ bundleId: String, _ appName: String,
    from: Double, to: Double, events: Int = 0, title: String? = nil
) -> ActivitySpan {
    ActivitySpan(
        id: "\(bundleId)-\(Int(from))",
        startedAt: from, endedAt: to, lastSeenAt: to,
        bundleId: bundleId, appName: appName, titleRedacted: title,
        eventCount: events, closeReason: .appChange, tzOffsetMin: 0
    )
}

/// Deliberately simple O(bucketCount * spanCount) reference retained in tests.
/// It protects the chronological sweep from becoming a clever-but-wrong
/// optimization around overlaps, clipping, event proration, or DST boundaries.
private func referenceBuckets(
    spans: [ActivitySpan], from: Double, to: Double,
    grain: ActivityRollups.Grain, timezone: TimeZone
) -> [ActivityBucket] {
    let ordered = spans.sorted {
        if $0.startedAt != $1.startedAt { return $0.startedAt < $1.startedAt }
        return $0.id < $1.id
    }
    var result: [ActivityBucket] = []
    for boundary in ActivityRollups.bucketBoundaries(
        from: from, to: to, grain: grain, timezone: timezone
    ) {
        let windowStart = max(boundary.start, from)
        let windowEnd = min(boundary.end, to)
        var seconds: [String: Double] = [:]
        var names: [String: String] = [:]
        var counts: [String: Int] = [:]
        var events: [String: Double] = [:]
        for row in ordered {
            let spanEnd = row.endedAt ?? row.lastSeenAt
            let overlapStart = max(row.startedAt, windowStart)
            let overlapEnd = min(spanEnd, windowEnd)
            let overlap = overlapEnd - overlapStart
            guard overlap > 0 else { continue }
            let duration = max(spanEnd - row.startedAt, 0)
            seconds[row.bundleId, default: 0] += overlap
            names[row.bundleId] = row.appName
            counts[row.bundleId, default: 0] += 1
            events[row.bundleId, default: 0] += Double(row.eventCount)
                * (duration > 0 ? overlap / duration : 1)
        }
        for (bundleID, duration) in seconds.sorted(by: {
            if $0.value != $1.value { return $0.value > $1.value }
            return $0.key < $1.key
        }) {
            result.append(ActivityBucket(
                start: boundary.start, end: boundary.end,
                bundleId: bundleID, appName: names[bundleID] ?? bundleID,
                seconds: duration, spanCount: counts[bundleID] ?? 0,
                eventCount: events[bundleID] ?? 0
            ))
        }
    }
    return result
}

// MARK: - DST

@Test("DST: the 25-hour day has 25 hourly buckets and a 90,000 s daily bucket")
func dstFallBackDayIsTwentyFiveHours() {
    // 2 November 2025, America/New_York: clocks go back, the day is 25 h.
    let dayStart = midnight(2025, 11, 2, in: newYork)
    let dayEnd = midnight(2025, 11, 3, in: newYork)
    #expect(dayEnd - dayStart == 25 * 3600, "fixture is not actually a 25-hour day")

    let hourly = ActivityRollups.bucketBoundaries(
        from: dayStart, to: dayEnd, grain: .hourly, timezone: newYork
    )
    #expect(hourly.count == 25)

    let daily = ActivityRollups.bucketBoundaries(
        from: dayStart, to: dayEnd, grain: .daily, timezone: newYork
    )
    #expect(daily.count == 1)
    #expect(daily[0].end - daily[0].start == 25 * 3600)

    // A span covering the whole local day lands entirely inside one daily bucket
    // — the stored tz_offset_min (0 here, deliberately WRONG for New York) is
    // provenance and must not be used for bucketing.
    let buckets = ActivityRollups.buckets(
        spans: [span("com.apple.Terminal", "Terminal", from: dayStart, to: dayEnd)],
        from: dayStart, to: dayEnd, grain: .daily, timezone: newYork
    )
    #expect(buckets.count == 1)
    #expect(buckets[0].seconds == 25 * 3600)
}

@Test("DST: the 23-hour day has 23 hourly buckets and a 82,800 s daily bucket")
func dstSpringForwardDayIsTwentyThreeHours() {
    // 9 March 2025, America/New_York: clocks jump forward, the day is 23 h.
    let dayStart = midnight(2025, 3, 9, in: newYork)
    let dayEnd = midnight(2025, 3, 10, in: newYork)
    #expect(dayEnd - dayStart == 23 * 3600, "fixture is not actually a 23-hour day")

    let hourly = ActivityRollups.bucketBoundaries(
        from: dayStart, to: dayEnd, grain: .hourly, timezone: newYork
    )
    #expect(hourly.count == 23)

    let buckets = ActivityRollups.buckets(
        spans: [span("com.apple.Terminal", "Terminal", from: dayStart, to: dayEnd, events: 230)],
        from: dayStart, to: dayEnd, grain: .daily, timezone: newYork
    )
    #expect(buckets.count == 1)
    #expect(buckets[0].seconds == 23 * 3600)
    #expect(buckets[0].eventCount == 230)
}

@Test("DST: the SAME rows bucket differently when asked from another timezone")
func sameRowsBucketPerAskingTimezone() {
    // 09:00–11:00 UTC on a fixed day. In New York (UTC-5 in January) that is
    // 04:00–06:00 local, so it lands in different hourly buckets entirely.
    let start = midnight(2025, 1, 15, in: utc) + 9 * 3600
    let rows = [span("com.apple.Mail", "Mail", from: start, to: start + 7200)]

    let utcBuckets = ActivityRollups.buckets(
        spans: rows, from: start - 3600, to: start + 3 * 3600, grain: .hourly, timezone: utc
    )
    let nyBuckets = ActivityRollups.buckets(
        spans: rows, from: start - 3600, to: start + 3 * 3600, grain: .hourly, timezone: newYork
    )
    // Same total, and each timezone's buckets align to ITS OWN hour marks.
    #expect(utcBuckets.reduce(0) { $0 + $1.seconds } == 7200)
    #expect(nyBuckets.reduce(0) { $0 + $1.seconds } == 7200)
    for bucket in utcBuckets {
        #expect(bucket.start.truncatingRemainder(dividingBy: 3600) == 0)
    }
}

// MARK: - Bucket boundaries

@Test("BOUNDARY: a span straddling a bucket edge is split, not double-counted")
func spanStraddlingBucketEdgeIsSplit() {
    let hourStart = midnight(2025, 6, 10, in: utc) + 10 * 3600
    // 10:30 → 11:15: 30 min in the 10:00 bucket, 15 min in the 11:00 bucket.
    let rows = [span("com.apple.Xcode", "Xcode",
                     from: hourStart + 1800, to: hourStart + 4500, events: 45)]

    let buckets = ActivityRollups.buckets(
        spans: rows, from: hourStart, to: hourStart + 2 * 3600,
        grain: .hourly, timezone: utc
    )
    #expect(buckets.count == 2)
    #expect(buckets[0].seconds == 1800)
    #expect(buckets[1].seconds == 900)
    // Total conserved: the split adds up to the real duration.
    #expect(buckets.reduce(0) { $0 + $1.seconds } == 2700)
    // Events are prorated by duration, not duplicated into both buckets.
    #expect(abs(buckets.reduce(0) { $0 + $1.eventCount } - 45) < 0.000_1)
    #expect(abs(buckets[0].eventCount - 30) < 0.000_1)
}

@Test("BOUNDARY: buckets are clamped to the query window, not to the span")
func bucketsClampToQueryWindow() {
    let hourStart = midnight(2025, 6, 10, in: utc) + 10 * 3600
    // A span running from 09:00 to 13:00, asked about only 10:00–11:00.
    let rows = [span("a", "A", from: hourStart - 3600, to: hourStart + 3 * 3600)]
    let buckets = ActivityRollups.buckets(
        spans: rows, from: hourStart, to: hourStart + 3600, grain: .hourly, timezone: utc
    )
    #expect(buckets.count == 1)
    #expect(buckets[0].seconds == 3600)
}

@Test("chronological sweep matches the simple reference across shuffled overlapping spans")
func chronologicalSweepMatchesReference() {
    let start = midnight(2025, 11, 2, in: newYork) - 1800
    let end = start + 30 * 3600
    var seed: UInt64 = 0xA11CE
    func random(_ upperBound: Int) -> Int {
        seed = seed &* 6_364_136_223_846_793_005 &+ 1
        return Int((seed >> 32) % UInt64(upperBound))
    }
    var rows: [ActivitySpan] = []
    for index in 0..<600 {
        let rowStart = start - 7200 + Double(random(34 * 3600))
        let duration = Double(1 + random(5 * 3600))
        rows.append(ActivitySpan(
            id: "random-\(index)", startedAt: rowStart,
            endedAt: rowStart + duration, lastSeenAt: rowStart + duration,
            bundleId: "com.test.\(random(9))", appName: "App \(index % 11)",
            eventCount: random(80), closeReason: .appChange, tzOffsetMin: 0
        ))
    }
    // Exercise the public function with source rows in a hostile order; the
    // store happens to return chronological rows, but the pure seam promises
    // correctness for any caller-provided fixture.
    rows.reverse()
    let expected = referenceBuckets(
        spans: rows, from: start, to: end, grain: .hourly, timezone: newYork
    )
    let actual = ActivityRollups.buckets(
        spans: rows, from: start, to: end, grain: .hourly, timezone: newYork
    )
    #expect(actual == expected)
}

// MARK: - Top-N truncation

@Test("TRUNCATION: top-N reports what it dropped, in rows AND seconds")
func topNReportsHonestTruncation() {
    let start = midnight(2025, 6, 10, in: utc)
    var rows: [ActivitySpan] = []
    for index in 0..<12 {
        // Descending durations: 1200 s, 1100 s, … so the ordering is unambiguous.
        let duration = Double(1200 - index * 100)
        rows.append(span("com.app.\(index)", "App\(index)",
                         from: start + Double(index) * 2000,
                         to: start + Double(index) * 2000 + duration))
    }

    let top = ActivityRollups.topApps(spans: rows, from: start, to: start + 86_400, limit: 5)
    #expect(top.rows.count == 5)
    #expect(top.totalRowCount == 12)
    #expect(top.truncated)
    #expect(top.droppedRowCount == 7)
    // Kept 1200+1100+1000+900+800; dropped 700+600+500+400+300+200+100 = 2800.
    #expect(top.droppedSeconds == 2800)
    #expect(top.rows[0].bundleId == "com.app.0")
    #expect(top.rows[4].bundleId == "com.app.4")

    let untruncated = ActivityRollups.topApps(
        spans: rows, from: start, to: start + 86_400, limit: 50
    )
    #expect(!untruncated.truncated)
    #expect(untruncated.droppedRowCount == 0)
    #expect(untruncated.droppedSeconds == 0)
}

@Test("TRUNCATION: ties break deterministically by bundle id")
func topNIsDeterministicUnderTies() {
    let start = midnight(2025, 6, 10, in: utc)
    let rows = ["com.c", "com.a", "com.b"].enumerated().map { index, bundle in
        span(bundle, bundle, from: start + Double(index) * 100, to: start + Double(index) * 100 + 60)
    }
    let first = ActivityRollups.topApps(spans: rows, from: start, to: start + 3600, limit: 3)
    let second = ActivityRollups.topApps(spans: rows, from: start, to: start + 3600, limit: 3)
    #expect(first.rows.map(\.bundleId) == ["com.a", "com.b", "com.c"])
    #expect(first.rows.map(\.bundleId) == second.rows.map(\.bundleId))
}

// MARK: - The ~50-row cap

@Test("ROW CAP: a synthetic heavy day still answers in <= 50 rows, and says so")
func heavyDayAnswerFitsFiftyRows() async throws {
    let store = try engineTestStore()
    let dayStart = midnight(2025, 6, 10, in: utc)

    // A deliberately brutal day: 40 distinct apps, 900 spans, ~every 90 s for
    // 22 hours. This is far past the plan's projected ~500 spans/day.
    var written = 0
    for index in 0..<900 {
        let start = dayStart + Double(index) * 88
        let app = index % 40
        try await store.openSpan(ActivitySpan(
            id: "heavy-\(index)",
            startedAt: start, endedAt: start + 80, lastSeenAt: start + 80,
            bundleId: "com.heavy.app\(app)", appName: "Heavy \(app)",
            titleRedacted: "window \(index)",
            eventCount: index % 7, closeReason: .appChange, tzOffsetMin: 0
        ))
        written += 1
    }
    #expect(written == 900)

    let rollups = ActivityRollups(store: store, policy: ActivityPolicy(captureEnabled: true))
    let answer = try await rollups.answerBundle(
        from: dayStart, to: dayStart + 86_400, timezone: utc
    )

    #expect(
        answer.rowCount <= ActivityRollups.answerRowCap,
        Comment(rawValue: "answer was \(answer.rowCount) rows — the ~50-row cap is an "
            + "acceptance criterion, not an aspiration")
    )
    #expect(answer.rowCount > 0)
    // And the cap is HONEST: 900 spans and 40 apps cannot fit, so it must say
    // what it dropped rather than presenting a fragment as the whole day.
    #expect(!answer.truncatedSections.isEmpty)
    #expect(answer.topApps.truncated)
    #expect(answer.topApps.droppedRowCount == 40 - answer.topApps.rows.count)
    #expect(answer.totalSeconds == 900 * 80)
}

@Test("ROW CAP: a quiet day is NOT reported as truncated")
func quietDayReportsNoTruncation() async throws {
    let store = try engineTestStore()
    let dayStart = midnight(2025, 6, 10, in: utc)
    for index in 0..<3 {
        let start = dayStart + Double(index) * 3600
        try await store.openSpan(ActivitySpan(
            id: "quiet-\(index)", startedAt: start, endedAt: start + 600,
            lastSeenAt: start + 600, bundleId: "com.quiet.app\(index)",
            appName: "Quiet \(index)", eventCount: 2, closeReason: .idle, tzOffsetMin: 0
        ))
    }
    let rollups = ActivityRollups(store: store, policy: ActivityPolicy(captureEnabled: true))
    let answer = try await rollups.answerBundle(
        from: dayStart, to: dayStart + 86_400, timezone: utc, grain: .daily
    )
    #expect(answer.truncatedSections.isEmpty, "\(answer.truncatedSections)")
    #expect(answer.topApps.rows.count == 3)
    #expect(answer.exemplars.count == 3)
}

// MARK: - Query-time exclusion reaches the rollups

@Test("the rollup tier honours the CURRENT exclusion list")
func rollupsHonourExclusions() async throws {
    let store = try engineTestStore()
    let dayStart = midnight(2025, 6, 10, in: utc)
    try await store.openSpan(ActivitySpan(
        id: "bank", startedAt: dayStart, endedAt: dayStart + 3600, lastSeenAt: dayStart + 3600,
        bundleId: "com.bankofexample.app", appName: "Bank", eventCount: 4,
        closeReason: .idle, tzOffsetMin: 0
    ))
    try await store.openSpan(ActivitySpan(
        id: "term", startedAt: dayStart + 3600, endedAt: dayStart + 5400,
        lastSeenAt: dayStart + 5400, bundleId: "com.apple.Terminal", appName: "Terminal",
        eventCount: 4, closeReason: .idle, tzOffsetMin: 0
    ))

    let policy = ActivityPolicy(
        captureEnabled: true, excludedBundleIDs: ["com.bankofexample.app"]
    )
    let rollups = ActivityRollups(store: store, policy: policy)
    let answer = try await rollups.answerBundle(
        from: dayStart, to: dayStart + 86_400, timezone: utc
    )
    #expect(answer.topApps.rows.map(\.bundleId) == ["com.apple.Terminal"])
    #expect(answer.totalSeconds == 1800)
    #expect(answer.exemplars.allSatisfy { $0.bundleId != "com.bankofexample.app" })
    #expect(answer.buckets.allSatisfy { $0.bundleId != "com.bankofexample.app" })
}

// MARK: - Span merge

@Test("MERGE: adjacent same-app spans under the gap coalesce; a real gap does not")
func adjacentSpansMergeUnderTheGap() {
    let start = midnight(2025, 6, 10, in: utc)
    let rows = [
        span("a", "A", from: start, to: start + 100, events: 3, title: "one"),
        span("a", "A", from: start + 110, to: start + 200, events: 2, title: "one"),
        // 10 minutes later: a real break, not a blink.
        span("a", "A", from: start + 800, to: start + 900, events: 1, title: "one"),
        // Same app, DIFFERENT title: a different thing, never merged away.
        span("a", "A", from: start + 905, to: start + 1000, events: 1, title: "two"),
    ]
    let merged = ActivityRollups.merge(spans: rows)
    #expect(merged.count == 3)
    #expect(merged[0].startedAt == start)
    #expect(merged[0].endedAt == start + 200)
    #expect(merged[0].eventCount == 5)
    #expect(merged[1].startedAt == start + 800)
    #expect(merged[2].titleRedacted == "two")
}

@Test("NO SILENT CAPS: a window too large for the grain says so")
func oversizedWindowReportsBucketCap() async throws {
    let store = try engineTestStore()
    let now = midnight(2025, 6, 10, in: utc)
    // One span at the END of a ten-year window, asked at HOURLY grain. The
    // bucket generator caps at 9,600 buckets, which starting ten years back
    // stops nine and a half years short of the data. Before this was reported,
    // the answer came back with zero buckets and "truncation: none" — a silent
    // cut dressed as a complete answer.
    try await store.openSpan(ActivitySpan(
        id: "late", startedAt: now - 3600, endedAt: now, lastSeenAt: now,
        bundleId: "com.apple.Terminal", appName: "Terminal",
        eventCount: 5, closeReason: .idle, tzOffsetMin: 0
    ))
    let rollups = ActivityRollups(store: store, policy: ActivityPolicy(captureEnabled: true))
    let answer = try await rollups.answerBundle(
        from: now - 3650 * 86_400, to: now, timezone: utc, grain: .hourly
    )
    #expect(answer.buckets.isEmpty)
    #expect(
        answer.truncatedSections.contains { $0.hasPrefix("buckets:") },
        Comment(rawValue: "silent cap — sections were \(answer.truncatedSections)")
    )
    // The top-apps and total figures come from the spans, not the buckets, so
    // they are still correct — the truncation note is about the timeline only.
    #expect(answer.totalSeconds == 3600)

    // The daily grain fits, and then nothing is reported as cut.
    let daily = try await rollups.answerBundle(
        from: now - 30 * 86_400, to: now, timezone: utc, grain: .daily
    )
    #expect(!daily.truncatedSections.contains { $0.hasPrefix("buckets:") })
    #expect(daily.buckets.count == 1)
}
