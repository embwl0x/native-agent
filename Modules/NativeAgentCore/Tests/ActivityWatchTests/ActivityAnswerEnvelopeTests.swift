import Foundation
import PersistenceCore
import Testing
@testable import ActivityWatch

// MARK: - What this file guards
//
// The ANSWER envelope: the properties every activity answer is built out of,
// each of which can be wrong while the answer still looks perfectly well-formed.
// Ledger fence `core.activity`:
//
//   activity.span.duration                  an OPEN row must not grow with the clock
//   activity.rollups.autoGrainThreshold     the 36 h grain flip, AT the boundary
//   activity.rollups.publicFetchEntryPoints buckets()/topApps() are live and policy-filtered
//   activity.query.recordingLimits          the disclosure block mirrors the policy
//   activity.query.resolveRange             named ranges, resolved across a DST day
//
// None of these throws or logs when it breaks. They just answer wrong.

private let utc = TimeZone(identifier: "UTC")!
private let chicago = TimeZone(identifier: "America/Chicago")!

/// Fixed base instant so nothing here depends on the wall clock.
/// 2023-11-14 22:13:20 UTC — comfortably in the past, which one assertion below
/// relies on.
private let envelopeBase: Double = 1_700_000_000

private func envelopeRoot() -> URL {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("ActivityAnswerEnvelope-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}

private func envelopeStore() throws -> ActivitySpanStore {
    try ActivitySpanStore(dataRoot: envelopeRoot())
}

/// Local midnight in a named zone, as an epoch instant.
private func localMidnight(_ year: Int, _ month: Int, _ day: Int, in zone: TimeZone) -> Double {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = zone
    var components = DateComponents()
    components.year = year
    components.month = month
    components.day = day
    return calendar.date(from: components)!.timeIntervalSince1970
}

/// Read a nested key out of a `JSONValue` object tree.
private func jsonValue(_ root: JSONValue, _ path: String...) -> JSONValue? {
    var cursor = root
    for key in path {
        guard case .object(let fields) = cursor, let next = fields[key] else { return nil }
        cursor = next
    }
    return cursor
}

// MARK: - activity.span.duration

@Test("DURATION: an OPEN span measures to its last heartbeat, never to now")
func openSpanDurationDoesNotGrowWithTheClock() async throws {
    // THE NUMBER EVERY ANSWER IS BUILT FROM. `duration` is read by exemplar
    // seconds, exemplar ordering, and the span merge. Its one real rule is the
    // `?? lastSeenAt` fallback: an open row is measured to its last heartbeat,
    // so a row cannot grow while nothing is being observed. Swap it for
    // `?? Date()` and every abandoned or in-flight row starts inflating — the
    // number stays plausible and every existing duration assertion in this
    // target stays green, because they are all on CLOSED fixture spans.
    let open = ActivitySpan(
        startedAt: envelopeBase,
        endedAt: nil,
        lastSeenAt: envelopeBase + 120,
        bundleId: "com.example.editor",
        appName: "Editor",
        eventCount: 3
    )
    #expect(open.isOpen)

    let first = open.duration
    #expect(first == 120)

    // Evaluated at a DIFFERENT wall-clock instant. Same answer, or the property
    // is reading the clock.
    try await Task.sleep(nanoseconds: 30_000_000)
    #expect(
        open.duration == first,
        "an open span's duration moved between two reads — it is measuring to 'now'"
    )

    // The strong form: `now - startedAt` for this fixture is years. If the
    // fallback ever became `Date()`, this is the assertion that names it.
    let sinceStartedNow = Date().timeIntervalSince1970 - envelopeBase
    #expect(sinceStartedNow > 120)
    #expect(
        open.duration < sinceStartedNow,
        """
        AN OPEN SPAN IS MEASURING TO NOW. duration == \(open.duration) against \
        now-startedAt == \(sinceStartedNow). Every abandoned row (27 of them in the \
        live store) inflates the moment this changes, and nothing else in the fence \
        would notice.
        """
    )

    // A closed row measures to endedAt, not to lastSeenAt.
    let closed = ActivitySpan(
        startedAt: envelopeBase,
        endedAt: envelopeBase + 60,
        lastSeenAt: envelopeBase + 120,
        bundleId: "com.example.editor",
        appName: "Editor"
    )
    #expect(closed.duration == 60)

    // And the clamp: a backwards row is 0, never negative.
    let backwards = ActivitySpan(
        startedAt: envelopeBase + 100,
        endedAt: envelopeBase + 10,
        lastSeenAt: envelopeBase + 10,
        bundleId: "com.example.editor",
        appName: "Editor"
    )
    #expect(backwards.duration == 0)
}

// MARK: - activity.rollups.autoGrainThreshold

/// Seed one 10-minute span every three hours across `hours`, so any grain
/// produces several non-empty buckets.
private func seedEveryThreeHours(
    _ store: ActivitySpanStore, from: Double, hours: Int
) async throws {
    var offset: Double = 0
    var index = 0
    while offset < Double(hours) * 3600 {
        let start = from + offset
        let span = ActivitySpan(
            id: "grain-\(index)",
            startedAt: start,
            endedAt: start + 600,
            lastSeenAt: start + 600,
            bundleId: "com.example.editor",
            appName: "Editor",
            eventCount: 5,
            closeReason: .appChange,
            tzOffsetMin: 0
        )
        try await store.openSpan(span)
        offset += 3 * 3600
        index += 1
    }
}

@Test("AUTO GRAIN: the flip is AT 36 h — 36 h is hourly, one second more is daily")
func autoGrainThresholdFlipsAtThirtySixHours() async throws {
    // `grain ?? ((to - from) > 36 * 3600 ? .daily : .hourly)` is the DEFAULT
    // path through ActivityQueryService.run, which never passes a grain. Nudge
    // this constant and "yesterday" silently becomes one daily bucket instead
    // of 24 hourly ones: the answer stays well-formed, the shape of the day
    // just vanishes. `36 * 3600` / `129_600` appears nowhere under Tests/, and
    // every existing answerBundle test either names a grain or uses a window
    // well clear of the boundary.
    let store = try envelopeStore()
    let from = localMidnight(2026, 6, 1, in: utc)
    try await seedEveryThreeHours(store, from: from, hours: 40)
    let rollups = ActivityRollups(
        store: store, policy: ActivityPolicy(captureEnabled: true)
    )

    // BELOW the boundary and ON it: hourly. Every bucket is exactly one hour.
    for hours in [35.0, 36.0] {
        let bundle = try await rollups.answerBundle(
            from: from, to: from + hours * 3600, timezone: utc
        )
        #expect(!bundle.buckets.isEmpty, "\(hours) h produced no buckets — the test is vacuous")
        let widths = Set(bundle.buckets.map { $0.end - $0.start })
        #expect(
            widths == [3600],
            """
            \(hours) h chose a grain with bucket widths \(widths.sorted()) — expected \
            hourly (3600). The auto-grain threshold moved; the default answer path \
            (ActivityQueryService.run passes no grain) just changed resolution silently.
            """
        )
    }

    // ONE SECOND past the boundary: daily.
    let daily = try await rollups.answerBundle(
        from: from, to: from + 36 * 3600 + 1, timezone: utc
    )
    #expect(!daily.buckets.isEmpty)
    let dailyWidths = Set(daily.buckets.map { $0.end - $0.start })
    #expect(
        dailyWidths == [86_400],
        "36 h + 1 s produced bucket widths \(dailyWidths.sorted()) — expected daily (86400)"
    )

    // An EXPLICIT grain still wins over the automatic one, both ways.
    let forcedDaily = try await rollups.answerBundle(
        from: from, to: from + 35 * 3600, timezone: utc, grain: .daily
    )
    #expect(Set(forcedDaily.buckets.map { $0.end - $0.start }) == [86_400])
    let forcedHourly = try await rollups.answerBundle(
        from: from, to: from + 40 * 3600, timezone: utc, grain: .hourly
    )
    #expect(Set(forcedHourly.buckets.map { $0.end - $0.start }) == [3600])
}

// MARK: - activity.rollups.publicFetchEntryPoints

@Test("PUBLIC DOORS: buckets()/topApps() fetch the same rows the pure overloads see, policy-filtered")
func publicFetchEntryPointsAreLiveAndPolicyFiltered() async throws {
    // Both async instance methods are public, and NEITHER has a caller anywhere
    // in the repo — the rollup tests exercise only the static pure overloads
    // plus answerBundle. So the fence carries two untested public entry points
    // whose only job is fetch-then-delegate. Two ways they break silently: the
    // fetch drops the policy (an excluded app reappears in an answer), or the
    // fetch and the pure function disagree about the window.
    let store = try envelopeStore()
    let from = localMidnight(2026, 6, 1, in: utc)
    let to = from + 6 * 3600

    for (index, bundleID) in ["com.example.editor", "com.example.secretvault"].enumerated() {
        for step in 0..<3 {
            let start = from + Double(step) * 3600 + Double(index) * 120
            try await store.openSpan(ActivitySpan(
                id: "\(bundleID)-\(step)",
                startedAt: start,
                endedAt: start + 900,
                lastSeenAt: start + 900,
                bundleId: bundleID,
                appName: bundleID,
                eventCount: 4,
                closeReason: .appChange,
                tzOffsetMin: 0
            ))
        }
    }

    let policy = ActivityPolicy(
        captureEnabled: true,
        excludedBundleIDs: ["com.example.secretvault"]
    )
    let rollups = ActivityRollups(store: store, policy: policy)

    // The fetch the instance methods are supposed to be doing.
    let fetched = try await store.spansOverlapping(from: from, to: to, policy: policy)
    #expect(fetched.count == 3, "precondition: the exclusion should leave 3 of 6 rows")

    let liveBuckets = try await rollups.buckets(
        from: from, to: to, grain: .hourly, timezone: utc
    )
    let pureBuckets = ActivityRollups.buckets(
        spans: fetched, from: from, to: to, grain: .hourly, timezone: utc
    )
    #expect(!liveBuckets.isEmpty, "the public buckets() door returned nothing — vacuous otherwise")
    #expect(
        liveBuckets == pureBuckets,
        "buckets(from:to:grain:timezone:) diverged from the pure overload over its own fetch"
    )

    let liveTop = try await rollups.topApps(from: from, to: to, limit: 10)
    let pureTop = ActivityRollups.topApps(spans: fetched, from: from, to: to, limit: 10)
    #expect(!liveTop.rows.isEmpty)
    #expect(liveTop == pureTop, "topApps(from:to:limit:) diverged from the pure overload")

    // W5 LAYER 2, through these two doors specifically: an excluded app is
    // absent, not merely ranked last.
    #expect(
        !liveBuckets.contains { $0.bundleId == "com.example.secretvault" },
        "an EXCLUDED bundle came back through the public buckets() door"
    )
    #expect(
        !liveTop.rows.contains { $0.bundleId == "com.example.secretvault" },
        "an EXCLUDED bundle came back through the public topApps() door"
    )
    #expect(liveTop.rows.contains { $0.bundleId == "com.example.editor" },
            "the non-excluded app vanished too — the filter is not selective")
}

// MARK: - activity.query.recordingLimits

private func emptyBundle(
    from: Double, to: Double, timezone: TimeZone
) -> ActivityAnswerBundle {
    ActivityAnswerBundle(
        from: from,
        to: to,
        timezoneIdentifier: timezone.identifier,
        totalSeconds: 0,
        topApps: ActivityTopN(
            rows: [], truncated: false, droppedRowCount: 0,
            droppedSeconds: 0, totalRowCount: 0
        ),
        buckets: [],
        exemplars: [],
        truncatedSections: []
    )
}

@Test("DISCLOSURE: recording_limits mirrors the policy, including the title AND")
func recordingLimitsMirrorThePolicy() throws {
    // These five fields are what stop the model claiming completeness. If they
    // drift from the policy the model states a false LIMIT confidently — the
    // one place in an answer where being wrong is a privacy claim, not a
    // rounding error. Nothing asserted they mirror the policy.
    let from = envelopeBase
    let to = envelopeBase + 3600

    struct Case {
        let policy: ActivityPolicy
        let titles: Bool
        let browserTitles: Bool
    }

    let cases: [Case] = [
        // Shipped default: everything off.
        Case(policy: ActivityPolicy(), titles: false, browserTitles: false),
        // Titles on, browser titles off.
        Case(
            policy: ActivityPolicy(captureEnabled: true, captureTitles: true),
            titles: true, browserTitles: false
        ),
        // Titles on AND browser titles on.
        Case(
            policy: ActivityPolicy(
                captureEnabled: true, captureTitles: true, browserTitlesEnabled: true
            ),
            titles: true, browserTitles: true
        ),
        // THE AND THAT MATTERS: app-name-only overrides captureTitles, and it
        // must knock browser titles down with it. A disclosure that says
        // "browser titles recorded" while app-name-only mode is on is a lie
        // that reads as a promise.
        Case(
            policy: ActivityPolicy(
                captureEnabled: true, captureTitles: true,
                browserTitlesEnabled: true, appNameOnlyMode: true
            ),
            titles: false, browserTitles: false
        ),
        // Browser titles on but captureTitles off: still nothing recorded.
        Case(
            policy: ActivityPolicy(captureEnabled: true, browserTitlesEnabled: true),
            titles: false, browserTitles: false
        ),
    ]

    for (index, testCase) in cases.enumerated() {
        var policy = testCase.policy
        policy.retentionDays = 17 - index          // a value no default could supply
        policy.excludedBundleIDs = Set(
            (0..<(index + 2)).map { "com.example.excluded\($0)" }
        )

        let encoded = ActivityQueryService.encode(
            emptyBundle(from: from, to: to, timezone: utc),
            bundleIDFilter: nil,
            policy: policy
        )
        let limits = try #require(
            jsonValue(encoded, "recording_limits"), "case \(index): no recording_limits block"
        )

        #expect(
            jsonValue(limits, "titles_recorded") == .bool(testCase.titles),
            "case \(index): titles_recorded disagrees with captureTitles && !appNameOnlyMode"
        )
        #expect(
            jsonValue(limits, "browser_titles_recorded") == .bool(testCase.browserTitles),
            """
            case \(index): browser_titles_recorded disagrees with \
            (captureTitles && !appNameOnlyMode && browserTitlesEnabled). The model \
            would state a false recording limit.
            """
        )
        #expect(
            jsonValue(limits, "app_name_only_mode") == .bool(policy.appNameOnlyMode),
            "case \(index): app_name_only_mode does not mirror the policy"
        )
        #expect(
            jsonValue(limits, "retention_days") == .int(Int64(policy.retentionDays)),
            "case \(index): retention_days does not mirror the policy"
        )
        // The EFFECTIVE count, which includes the non-overridable ids — a
        // disclosure that counted only the user's list would under-state what
        // the answer omits.
        #expect(
            jsonValue(limits, "excluded_app_count")
                == .int(Int64(policy.effectiveExcludedBundleIDs.count)),
            "case \(index): excluded_app_count is not the EFFECTIVE exclusion count"
        )
        #expect(
            policy.effectiveExcludedBundleIDs.count > policy.excludedBundleIDs.count,
            "case \(index): effective == user list, so the assertion above proves nothing"
        )
    }
}

// MARK: - activity.query.resolveRange

@Test("NAMED RANGES: 'today' is local, ends at now, and 'yesterday' is a 23 h DST day")
func resolveRangeIsCorrectAcrossADSTBoundary() throws {
    // Named ranges are resolved with Calendar in the ASKING timezone, and there
    // is no test for this function at all — the DST tests in this target cover
    // BUCKETING, not range naming. A DST or timezone bug here answers
    // confidently about the wrong day.
    //
    // 2026-03-08 is the US spring-forward day: 2:00 local jumps to 3:00, so the
    // day is 23 hours long. `now` is pinned mid-afternoon on the 9th.
    let now = Date(timeIntervalSince1970: localMidnight(2026, 3, 9, in: chicago) + 15 * 3600)

    let today = try #require(
        ActivityQueryService.resolveRange(named: "today", timezone: chicago, now: now)
    )
    #expect(
        today.from == localMidnight(2026, 3, 9, in: chicago),
        "'today' does not start at LOCAL midnight in the asking timezone"
    )
    #expect(
        today.to == now.timeIntervalSince1970,
        "'today' ran past now — an answer about a day cannot include its future"
    )
    #expect(today.to - today.from == 15 * 3600)

    let yesterday = try #require(
        ActivityQueryService.resolveRange(named: "yesterday", timezone: chicago, now: now)
    )
    #expect(yesterday.from == localMidnight(2026, 3, 8, in: chicago))
    #expect(yesterday.to == localMidnight(2026, 3, 9, in: chicago))
    #expect(
        yesterday.to - yesterday.from == 23 * 3600,
        """
        the spring-forward 'yesterday' came out \((yesterday.to - yesterday.from) / 3600) h \
        long instead of 23 h. A hardcoded 86,400 here answers about the wrong 60 minutes \
        of the day, every DST transition, silently.
        """
    )
    #expect(yesterday.to <= today.from, "'yesterday' overlaps 'today'")

    // The FALL-BACK day is 25 h, from the other side.
    let novNow = Date(timeIntervalSince1970: localMidnight(2026, 11, 2, in: chicago) + 9 * 3600)
    let novYesterday = try #require(
        ActivityQueryService.resolveRange(named: "yesterday", timezone: chicago, now: novNow)
    )
    #expect(novYesterday.to - novYesterday.from == 25 * 3600)

    // The same instant, asked from UTC, is a different day boundary — proof the
    // ASKING timezone is what is being honoured, not the host's.
    let utcToday = try #require(
        ActivityQueryService.resolveRange(named: "today", timezone: utc, now: now)
    )
    #expect(
        utcToday.from != today.from,
        "the same 'now' resolved to the same day start in two zones — the timezone is ignored"
    )

    // The relative ranges are exact offsets from now, in every zone.
    for zone in [chicago, utc] {
        for (name, seconds) in [
            ("last_hour", 3600.0), ("past_hour", 3600.0),
            ("last_24_hours", 86_400.0), ("past_24_hours", 86_400.0),
            ("last_7_days", 7 * 86_400.0), ("this_week", 7 * 86_400.0),
            ("last_30_days", 30 * 86_400.0), ("past_month", 30 * 86_400.0),
        ] {
            let range = try #require(
                ActivityQueryService.resolveRange(named: name, timezone: zone, now: now),
                "'\(name)' is not a recognised range — the tool's vocabulary shrank"
            )
            #expect(range.to == now.timeIntervalSince1970, "'\(name)' does not end at now")
            #expect(range.to - range.from == seconds, "'\(name)' is not \(seconds) s long")
        }
    }

    // Case and surrounding whitespace are tolerated; a name it does not know is
    // nil, never a guessed range.
    #expect(
        ActivityQueryService.resolveRange(named: "  TODAY \n", timezone: chicago, now: now)?.from
            == today.from
    )
    // `(from:to:)` is a tuple, so the optional cannot be compared to nil
    // directly — reach through it for a member instead.
    #expect(
        ActivityQueryService.resolveRange(named: "lastweek", timezone: chicago, now: now)?.from
            == nil,
        "an unknown range name resolved to a window — the tool would answer about a guessed day"
    )
    #expect(
        ActivityQueryService.resolveRange(named: "", timezone: chicago, now: now)?.from == nil
    )
}
