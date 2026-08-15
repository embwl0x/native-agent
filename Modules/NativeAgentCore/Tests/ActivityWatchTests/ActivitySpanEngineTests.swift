import Foundation
import Testing
@testable import ActivityWatch

// MARK: - Support

private func hermeticDataRoot() -> URL {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("ActivityWatchTests-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}

func engineTestStore() throws -> ActivitySpanStore {
    try ActivitySpanStore(dataRoot: hermeticDataRoot())
}

/// Capture-on policy with an empty user exclusion list, so a test that means to
/// exercise exclusions adds exactly the ones it is testing and nothing else
/// leaks in from the shipped starter list.
func capturePolicy(
    titles: Bool = false,
    browserTitles: Bool = false,
    appNameOnly: Bool = false,
    excluded: Set<String> = []
) -> ActivityPolicy {
    ActivityPolicy(
        captureEnabled: true,
        captureTitles: titles,
        browserTitlesEnabled: browserTitles,
        appNameOnlyMode: appNameOnly,
        excludedBundleIDs: excluded
    )
}

func deterministicEngine(policy: ActivityPolicy) -> ActivitySpanEngine {
    let counter = Counter()
    return ActivitySpanEngine(
        policy: policy, tzOffsetMin: 0, makeID: { "sim-\(counter.next())" }
    )
}

final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func next() -> Int {
        lock.lock(); defer { lock.unlock() }
        defer { value += 1 }
        return value
    }
}

private let base: Double = 1_700_000_000

// MARK: - Every open has exactly one close

@Test("STATE LIFECYCLE: every open has exactly one close, with a reason")
func everyOpenHasExactlyOneClose() {
    var engine = deterministicEngine(policy: capturePolicy())
    let commands = engine.process([
        .activate(bundleId: "com.apple.Terminal", appName: "Terminal", at: base),
        .focusEvent(at: base + 10),
        .activate(bundleId: "com.apple.Safari", appName: "Safari", at: base + 20),
        .focusEvent(at: base + 30),
        .idle(at: base + 40),
    ])

    var opens: [String] = []
    var closes: [String: ActivityCloseReason] = [:]
    for command in commands {
        switch command {
        case .open(let span): opens.append(span.id)
        case .close(let id, let reason, _):
            #expect(closes[id] == nil, "span \(id) closed twice")
            closes[id] = reason
        default: break
        }
    }
    #expect(opens.count == 2)
    #expect(closes.count == 2)
    #expect(closes[opens[0]] == .appChange)
    #expect(closes[opens[1]] == .idle)
    #expect(engine.openSpan == nil)
}

@Test("close reasons: appChange / windowChange / idle / lock / sleep / quit")
func closeReasonVocabularyIsReachable() {
    var seen: Set<ActivityCloseReason> = []
    func drive(_ events: [ActivityInputEvent], policy: ActivityPolicy = capturePolicy(titles: true)) {
        var engine = deterministicEngine(policy: policy)
        for command in engine.process(events) {
            if case .close(_, let reason, _) = command { seen.insert(reason) }
        }
    }
    let start: [ActivityInputEvent] = [.activate(bundleId: "a", appName: "A", at: base)]
    drive(start + [.activate(bundleId: "b", appName: "B", at: base + 1)])
    // TWO titles: the first is the span's INITIAL title (retitle, in place), so
    // only the second is a genuine window change. One title alone no longer
    // reaches `.windowChange` — that split was the live zero-length-row defect.
    drive(start + [
        .titleChange(raw: "doc.txt", at: base + 1),
        .titleChange(raw: "other.txt", at: base + 2),
    ])
    drive(start + [.idle(at: base + 1)])
    drive(start + [.lock(at: base + 1)])
    drive(start + [.sleep(at: base + 1)])
    drive(start + [.terminate(at: base + 1)])

    #expect(seen == [.appChange, .windowChange, .idle, .lock, .sleep, .quit])
}

// MARK: - Lock / sleep

@Test("LOCK GATE: lock closes at the boundary and writes NOTHING while locked")
func lockClosesAtBoundaryAndSilencesCapture() {
    var engine = deterministicEngine(policy: capturePolicy(titles: true))
    _ = engine.process(.activate(bundleId: "com.apple.Terminal", appName: "Terminal", at: base))

    let lockCommands = engine.process(.lock(at: base + 100))
    #expect(lockCommands.count == 1)
    guard case .close(_, let reason, let at) = lockCommands[0] else {
        Issue.record("lock did not close the span")
        return
    }
    #expect(reason == .lock)
    #expect(at == base + 100, "closed at the boundary, not at some later moment")

    // Everything that arrives while locked produces ZERO commands. This is the
    // P0 blocker: while locked AX still answers, and it answers with the bare
    // app name — data that looks completely real.
    let whileLocked = engine.process([
        .activate(bundleId: "com.apple.Safari", appName: "Safari", at: base + 200),
        .focusEvent(at: base + 210),
        .titleChange(raw: "Chrome", at: base + 220),
        .heartbeat(at: base + 230),
        .activate(bundleId: "com.apple.loginwindow", appName: "loginwindow", at: base + 240),
    ])
    #expect(whileLocked.isEmpty, "wrote \(whileLocked.count) command(s) while locked")

    // Unlock opens nothing by itself — the live watcher re-seeds, which arrives
    // as an activate. Guessing here would resurrect a stale app.
    #expect(engine.process(.unlock(at: base + 300)).isEmpty)

    let resumed = engine.process(
        .activate(bundleId: "com.apple.Safari", appName: "Safari", at: base + 310)
    )
    #expect(resumed.count == 1)
    if case .open(let span) = resumed[0] {
        #expect(span.startedAt == base + 310)
    } else {
        Issue.record("expected an open after unlock + activate")
    }
}

@Test("SLEEP GATE: sleep closes at the boundary; wake alone opens nothing")
func sleepClosesAtBoundary() {
    var engine = deterministicEngine(policy: capturePolicy())
    _ = engine.process(.activate(bundleId: "a", appName: "A", at: base))
    let commands = engine.process(.sleep(at: base + 60))
    #expect(commands.count == 1)
    if case .close(_, let reason, let at) = commands[0] {
        #expect(reason == .sleep)
        #expect(at == base + 60)
    } else {
        Issue.record("sleep did not close")
    }
    // Eight hours asleep. The span must NOT have grown.
    #expect(engine.process(.wake(at: base + 60 + 8 * 3600)).isEmpty)
    #expect(engine.openSpan == nil)
}

@Test("a lock while both lock and sleep are pending needs BOTH cleared")
func gateNeedsBothSignalsCleared() {
    var engine = deterministicEngine(policy: capturePolicy())
    _ = engine.process(.activate(bundleId: "a", appName: "A", at: base))
    _ = engine.process(.lock(at: base + 10))
    _ = engine.process(.sleep(at: base + 20))
    #expect(engine.isGated)
    _ = engine.process(.unlock(at: base + 30))
    #expect(engine.isGated, "still asleep")
    _ = engine.process(.wake(at: base + 40))
    #expect(!engine.isGated)
}

// MARK: - Crash

@Test("CRASH: emits no close; the next start reconciles it at last_seen_at")
func crashLeavesRowOpenThenReconciles() async throws {
    let store = try engineTestStore()
    var engine = deterministicEngine(policy: capturePolicy())

    try await store.apply(engine.process(.activate(bundleId: "a", appName: "A", at: base)))
    try await store.apply(engine.process(.focusEvent(at: base + 30)))
    let crashCommands = engine.process(.crash(at: base + 45))
    #expect(crashCommands.isEmpty, "a crash cannot emit a close — the process is gone")
    try await store.apply(crashCommands)

    // The row is still open, exactly as a power loss would leave it.
    var rows = try await store.querySpans(from: base - 10, to: base + 1000)
    #expect(rows.count == 1)
    #expect(rows[0].endedAt == nil)
    #expect(rows[0].lastSeenAt == base + 30)

    // Next process start.
    var restarted = deterministicEngine(policy: capturePolicy())
    try await store.apply(restarted.startupReconcile())

    rows = try await store.querySpans(from: base - 10, to: base + 1000)
    #expect(rows.count == 1)
    #expect(rows[0].endedAt == base + 30, "closed AT last_seen_at, never at 'now'")
    #expect(rows[0].closeReason == .abandoned)
}

@Test("a crash mid-stream reconciles on the next processed event")
func crashReconcilesOnNextEvent() {
    var engine = deterministicEngine(policy: capturePolicy())
    _ = engine.process(.activate(bundleId: "a", appName: "A", at: base))
    _ = engine.process(.crash(at: base + 10))
    let next = engine.process(.activate(bundleId: "b", appName: "B", at: base + 20))
    #expect(next.first == .reconcileAbandoned)
    #expect(next.count == 2)
}

// MARK: - last_seen_at

@Test("last_seen_at advances on EVERY processed event, not just the heartbeat")
func lastSeenAdvancesOnEveryEvent() async throws {
    let store = try engineTestStore()
    var engine = deterministicEngine(policy: capturePolicy(titles: true))

    try await store.apply(engine.process(.activate(bundleId: "a", appName: "A", at: base)))
    try await store.apply(engine.process(.focusEvent(at: base + 5)))
    #expect(engine.openSpan?.lastSeenAt == base + 5)

    try await store.apply(engine.process(.focusEvent(at: base + 17)))
    #expect(engine.openSpan?.lastSeenAt == base + 17)

    // A title change that does not change the redacted title is an EVENT, and
    // it must move last_seen_at too — otherwise a crash right after it discards
    // real activity.
    try await store.apply(engine.process(.titleChange(raw: nil, at: base + 23)))
    #expect(engine.openSpan?.lastSeenAt == base + 23)

    let rows = try await store.querySpans(from: base - 10, to: base + 100)
    #expect(rows[0].lastSeenAt == base + 23)
    #expect(rows[0].eventCount == 3, "three events, and the heartbeat has not run")

    try await store.apply(engine.process(.heartbeat(at: base + 90)))
    let after = try await store.querySpans(from: base - 10, to: base + 100)
    #expect(after[0].lastSeenAt == base + 90)
    #expect(after[0].eventCount == 3, "a heartbeat is not a human event")
}

// MARK: - Monotonic safety

@Test("MONOTONIC: a backwards clock step neither invents nor rewinds duration")
func backwardsClockCannotRewind() {
    var engine = deterministicEngine(policy: capturePolicy())
    _ = engine.process(.activate(bundleId: "a", appName: "A", at: base))
    _ = engine.process(.focusEvent(at: base + 100))

    // NTP yanks the clock back an hour.
    let commands = engine.process([
        .focusEvent(at: base - 3600),
        .activate(bundleId: "b", appName: "B", at: base - 3500),
    ])

    var stamps: [Double] = []
    for command in commands {
        switch command {
        case .open(let span): stamps.append(span.startedAt)
        case .touch(_, let at), .heartbeat(_, let at), .close(_, _, let at),
             .retitle(_, _, let at):
            stamps.append(at)
        case .reconcileAbandoned: break
        }
    }
    #expect(stamps == stamps.sorted(), "emitted timestamps went backwards: \(stamps)")
    for stamp in stamps {
        #expect(stamp >= base + 100, "a stamp predates the last real observation")
    }
    // A new span's start is FLOORED at the last emitted close: never overlapping.
    #expect(engine.openSpan?.startedAt == base + 100)
}

@Test("MONOTONIC: a sleep cannot manufacture an 8-hour span")
func sleepCannotManufactureDuration() {
    var engine = deterministicEngine(policy: capturePolicy())
    var opened: ActivitySpan?
    var closedAt: Double?
    for command in engine.process([
        .activate(bundleId: "a", appName: "A", at: base),
        .focusEvent(at: base + 60),
        .sleep(at: base + 65),
        // Wake eight hours later, then a fresh activation.
        .wake(at: base + 65 + 8 * 3600),
        .activate(bundleId: "a", appName: "A", at: base + 65 + 8 * 3600),
    ]) {
        if case .open(let span) = command, opened == nil { opened = span }
        if case .close(_, _, let at) = command { closedAt = at }
    }
    #expect(opened?.startedAt == base)
    #expect(closedAt == base + 65, "the pre-sleep span ends at the sleep boundary")
    #expect((closedAt ?? 0) - (opened?.startedAt ?? 0) == 65)
}

// MARK: - Exclusions

@Test("EXCLUSION: an excluded bundle writes ZERO rows")
func excludedBundleWritesZeroRows() async throws {
    let store = try engineTestStore()
    let policy = capturePolicy(titles: true, excluded: ["com.1password.1password"])
    var engine = deterministicEngine(policy: policy)

    // The exclusion is decided BEFORE anything is read for that app: the gate
    // is `shouldCapture`, which the live watcher calls before its AX read.
    #expect(!engine.shouldCapture(bundleID: "com.1password.1password"))
    #expect(!engine.shouldReadTitle(bundleID: "com.1password.1password"))

    try await store.apply(engine.process([
        .activate(bundleId: "com.1password.1password", appName: "1Password", at: base),
        .focusEvent(at: base + 5),
        .titleChange(raw: "Personal vault", at: base + 10),
        .heartbeat(at: base + 70),
        .idle(at: base + 400),
    ]))

    let rows = try await store.querySpans(from: 0, to: base + 100_000)
    #expect(rows.isEmpty, "an excluded app produced \(rows.count) row(s)")
}

@Test("EXCLUSION: switching TO an excluded app closes the previous span")
func switchingToExcludedAppClosesPrevious() async throws {
    let store = try engineTestStore()
    var engine = deterministicEngine(policy: capturePolicy(excluded: ["com.1password.1password"]))

    try await store.apply(engine.process([
        .activate(bundleId: "com.apple.Terminal", appName: "Terminal", at: base),
        .activate(bundleId: "com.1password.1password", appName: "1Password", at: base + 60),
        .focusEvent(at: base + 90),
    ]))

    let rows = try await store.querySpans(from: 0, to: base + 10_000)
    #expect(rows.count == 1)
    #expect(rows[0].bundleId == "com.apple.Terminal")
    #expect(rows[0].endedAt == base + 60)
    #expect(rows[0].closeReason == .appChange)
    #expect(engine.openSpan == nil)
}

@Test("EXCLUSION: NativeAgent's own bundle id is not overridable")
func selfExclusionIsNotOverridable() async throws {
    let store = try engineTestStore()
    // A policy that tries hard to include NativeAgent: empty exclusion list.
    var engine = deterministicEngine(policy: capturePolicy(titles: true, excluded: []))
    for bundle in ActivityPolicy.alwaysExcludedBundleIDs {
        try await store.apply(engine.process(
            .activate(bundleId: bundle, appName: "should not happen", at: base)
        ))
    }
    #expect(try await store.querySpans(from: 0, to: base + 10_000).isEmpty)
}

@Test("MASTER SWITCH: captureEnabled=false writes nothing at all")
func captureDisabledWritesNothing() async throws {
    let store = try engineTestStore()
    var engine = deterministicEngine(policy: ActivityPolicy())  // all defaults
    try await store.apply(engine.process([
        .activate(bundleId: "com.apple.Terminal", appName: "Terminal", at: base),
        .focusEvent(at: base + 5),
        .titleChange(raw: "hello", at: base + 10),
    ]))
    #expect(try await store.querySpans(from: 0, to: base + 10_000).isEmpty)
}

// MARK: - Titles

@Test("TITLES: off by default — a title change is an event, never a stored title")
func titlesOffRecordsEventNotTitle() async throws {
    let store = try engineTestStore()
    var engine = deterministicEngine(policy: capturePolicy(titles: false))
    try await store.apply(engine.process([
        .activate(bundleId: "com.apple.Terminal", appName: "Terminal", at: base),
        .titleChange(raw: "secret-project — Terminal", at: base + 10),
    ]))
    let rows = try await store.querySpans(from: 0, to: base + 10_000)
    #expect(rows.count == 1)
    #expect(rows[0].titleRedacted == nil)
    #expect(rows[0].eventCount == 1, "the change still counts as activity")
}

@Test("TITLES: the FIRST title lands in place; a SUBSEQUENT one segments the span")
func titleChangeSegmentsSpans() async throws {
    // REBASELINED 2026-08-14 after the live run. This test used to expect THREE
    // rows, the first of them nil-titled and closed as `windowChange` — which is
    // exactly the split that produced a junk zero-length row per app switch on
    // the real watcher, where the first title arrives microseconds after the
    // activation rather than 10 s later.
    let store = try engineTestStore()
    var engine = deterministicEngine(policy: capturePolicy(titles: true))
    try await store.apply(engine.process([
        .activate(bundleId: "com.apple.Terminal", appName: "Terminal", at: base),
        .titleChange(raw: "notes.md — Terminal", at: base + 10),    // INITIAL: in place
        .titleChange(raw: "notes.md — Terminal", at: base + 20),    // unchanged: an event
        .titleChange(raw: "build.log — Terminal", at: base + 30),   // CHANGE: splits
        .terminate(at: base + 40),
    ]))
    let rows = try await store.querySpans(from: 0, to: base + 10_000)
    #expect(rows.count == 2)
    #expect(rows[0].titleRedacted == "notes.md — Terminal", "the initial title must land in place")
    #expect(rows[0].startedAt == base, "the initial title must not move the span's start")
    #expect(rows[0].eventCount == 2, "the retitle and the unchanged repeat each count once")
    #expect(rows[0].closeReason == .windowChange)
    #expect(rows[1].titleRedacted == "build.log — Terminal")
    #expect(rows[1].closeReason == .quit)
    for row in rows {
        #expect((row.endedAt ?? row.lastSeenAt) > row.startedAt, "zero-length row")
    }
}

@Test("TITLES: a secret-shaped title is redacted BEFORE it reaches the span")
func secretTitleIsRedactedAtSource() async throws {
    let store = try engineTestStore()
    var engine = deterministicEngine(policy: capturePolicy(titles: true))
    let secret = "sk-ant-api03-abcdefghijklmnopqrstuvwxyz0123456789ABCDEFGH"
    try await store.apply(engine.process([
        .activate(bundleId: "com.apple.Terminal", appName: "Terminal", at: base),
        .titleChange(raw: secret, at: base + 10),
    ]))
    let rows = try await store.querySpans(from: 0, to: base + 10_000)
    let titles = rows.compactMap(\.titleRedacted)
    #expect(titles == [ActivityTitleRedaction.redactedPlaceholder])
    for row in rows {
        #expect(row.titleRedacted != secret)
        #expect(!(row.titleRedacted ?? "").contains("sk-ant"))
    }
}

@Test("TITLES: browser titles need BOTH captureTitles and browserTitlesEnabled")
func browserTitlesNeedBothSwitches() {
    let safari = "com.apple.Safari"
    let terminal = "com.apple.Terminal"

    var policy = capturePolicy(titles: true, browserTitles: false)
    #expect(policy.allowsTitleCapture(bundleID: terminal))
    #expect(!policy.allowsTitleCapture(bundleID: safari))

    policy = capturePolicy(titles: false, browserTitles: true)
    #expect(!policy.allowsTitleCapture(bundleID: safari))
    #expect(!policy.allowsTitleCapture(bundleID: terminal))

    policy = capturePolicy(titles: true, browserTitles: true)
    #expect(policy.allowsTitleCapture(bundleID: safari))

    // appNameOnlyMode overrides everything.
    policy = capturePolicy(titles: true, browserTitles: true, appNameOnly: true)
    #expect(!policy.allowsTitleCapture(bundleID: safari))
    #expect(!policy.allowsTitleCapture(bundleID: terminal))
}

@Test("TITLES: a browser with titles disabled still records app + duration")
func browserWithoutTitlesStillRecordsDuration() async throws {
    let store = try engineTestStore()
    var engine = deterministicEngine(policy: capturePolicy(titles: true, browserTitles: false))
    try await store.apply(engine.process([
        .activate(bundleId: "com.apple.Safari", appName: "Safari", at: base),
        .titleChange(raw: "Some private page — Safari", at: base + 30),
        .terminate(at: base + 60),
    ]))
    let rows = try await store.querySpans(from: 0, to: base + 10_000)
    #expect(rows.count == 1)
    #expect(rows[0].titleRedacted == nil)
    #expect(rows[0].duration == 60)
}

// MARK: - Policy changes mid-flight

@Test("a policy change that excludes the open app closes it immediately")
func policyChangeClosesNewlyExcludedSpan() {
    var engine = deterministicEngine(policy: capturePolicy())
    _ = engine.process(.activate(bundleId: "com.1password.1password", appName: "1P", at: base))
    #expect(engine.openSpan != nil)

    let commands = engine.updatePolicy(
        capturePolicy(excluded: ["com.1password.1password"]), at: base + 50
    )
    #expect(commands.count == 1)
    if case .close(_, let reason, let at) = commands[0] {
        #expect(reason == .appChange)
        #expect(at == base + 50)
    } else {
        Issue.record("policy change did not close the span")
    }
    #expect(engine.openSpan == nil)
}
