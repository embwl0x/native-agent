import Foundation
import Testing
@testable import ActivityWatch

// MARK: - What this file guards
//
// The WATCHER's own contracts, driven headlessly — no window server, no AX
// grant, no capture thread. Every test below is deliberately constructed so the
// watcher never installs its observers: the assertions are about the gates, the
// feeds and the state machine, and a leaked CFRunLoop thread in a test target is
// its own defect. Ledger fence `core.activity`:
//
//   activity.clock.ActivityClock          the real clock's monotonic contract
//   activity.watcher.startBounded         the gate refuses and installs NOTHING
//   activity.watcher.pauseResume          pause/resume flip the indicator, idempotently
//   activity.watcher.policyChangedFeed    the callback fires once, with the CLAMPED policy
//   activity.watcher.motorEpochGate       an agent-driven activation opens no human span
//   activity.watcher.unknownFrontmostAndSelfPidGap   the anti-misattribution synthesis
//   activity.watcher.attachObserverFailurePath       what an AX-attach failure writes

private func watcherRoot() -> URL {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("ActivityWatcherContract-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}

private let watcherBase: Double = 1_700_000_000

// MARK: - activity.clock.ActivityClock

@Test("CLOCK: the real clock's monotonic hand never goes backwards and is not the wall")
func systemClockMonotonicContract() async throws {
    // Only the ManualActivityClock is ever exercised in this target, so
    // SystemActivityClock — the one the live watcher actually runs on — has no
    // coverage at all. Its monotonicNow drifting from mach time would break
    // every duration silently: `safeNow()` anchors wall time to the monotonic
    // hand precisely so a backwards NTP step cannot rewind a span.
    let clock = SystemActivityClock()

    var readings: [Double] = []
    for _ in 0..<6 {
        readings.append(clock.monotonicNow())
        try await Task.sleep(nanoseconds: 5_000_000)
    }
    #expect(readings.allSatisfy { $0.isFinite })
    #expect(
        zip(readings, readings.dropFirst()).allSatisfy { $0 <= $1 },
        "monotonicNow went BACKWARDS across \(readings) — every span duration is then suspect"
    )
    #expect(
        readings.last! > readings.first!,
        "monotonicNow did not advance over ~25 ms — a frozen hand pins every span at 0 s"
    )

    // It advances at wall-clock RATE (mach timebase applied), within a generous
    // factor. A missing numer/denom conversion is off by orders of magnitude on
    // Apple silicon, which this catches and a "> 0" check does not.
    let wallStart = Date().timeIntervalSince1970
    let monoStart = clock.monotonicNow()
    try await Task.sleep(nanoseconds: 120_000_000)
    let wallElapsed = Date().timeIntervalSince1970 - wallStart
    let monoElapsed = clock.monotonicNow() - monoStart
    #expect(wallElapsed > 0.1)
    #expect(
        monoElapsed > wallElapsed / 4 && monoElapsed < wallElapsed * 4,
        """
        monotonicNow advanced \(monoElapsed) s while the wall advanced \(wallElapsed) s. \
        The mach timebase conversion is wrong, so every monotonic bound in the watcher \
        is in the wrong unit.
        """
    )

    // The two hands are NOT the same number. `monotonicNow` is uptime-based;
    // returning wall time here would make the sleep-safety arithmetic vacuous.
    #expect(
        abs(clock.wallNow() - clock.monotonicNow()) > 1_000_000,
        "monotonicNow returned something wall-clock-shaped — the sleep gate is then a no-op"
    )
    #expect(abs(clock.wallNow() - Date().timeIntervalSince1970) < 5)
}

// MARK: - activity.watcher.startBounded

#if canImport(AppKit)
@Test("START GATE: startBounded refuses without capture, and installs no thread or pump")
func startBoundedRefusesAndInstallsNothing() async throws {
    // The bounded start is the app-facing entry point, and its ROLLBACK path —
    // partial observers torn down, lifecycle left honest, no leaked pump — is
    // what stops a wedged bootstrap from leaving capture silently dead with
    // only a one-line lastError. The deterministic halves of that gate are
    // asserted here; the AX-bootstrap-timeout half needs a seam (see the build
    // report) because a test host with a live window server becomes ready.
    let store = try ActivitySpanStore(dataRoot: watcherRoot())
    let watcher = ActivityWatcher(store: store, policy: ActivityPolicy())

    #expect(watcher.isCaptureEnabled == false, "precondition: the shipped default is off")
    #expect(watcher.lifecycleState == .stopped)

    // REFUSED, and it reports the refusal as "there is nothing to run" rather
    // than as a failure — the caller is meant to call this unconditionally.
    let refused = await watcher.startBounded(timeout: 0.2)
    #expect(refused, "startBounded reported failure for a watcher that is correctly OFF")
    #expect(watcher.isCapturing == false)
    #expect(
        watcher.lifecycleState == .stopped,
        "the lifecycle moved to \(watcher.lifecycleState) without capture ever being enabled"
    )
    #expect(watcher.status().spansOpened == 0)

    // Idempotent, and stop() on something that never installed is a no-op that
    // must not block on a run-loop hop that will never be serviced.
    _ = await watcher.startBounded(timeout: 0.2)
    await watcher.stop()
    #expect(watcher.isCapturing == false)
    #expect(watcher.lifecycleState == .stopped)

    // Nothing was recorded, through the whole sequence.
    let spans = try await store.querySpans(from: 0, to: .greatestFiniteMagnitude, limit: 50)
    #expect(spans.isEmpty, "a refused start wrote \(spans.count) row(s)")

    // AFTER a stop has been requested, an enabled watcher still does not
    // install: it queues a restart instead. This is the path that stops a
    // disable/enable race from running two capture threads at once.
    let enabled = ActivityWatcher(
        store: store,
        policy: ActivityPolicy(captureEnabled: true)
    )
    await enabled.stop()
    let queued = await enabled.startBounded(timeout: 0.2)
    #expect(
        queued == false,
        "startBounded installed while a stop was pending — two capture threads can now overlap"
    )
    #expect(enabled.isCapturing == false)
    await enabled.stop()
}

// MARK: - activity.watcher.pauseResume

@Test("PAUSE: the indicator goes dark and comes back, and both calls are idempotent")
func pauseAndResumeFlipTheIndicatorIdempotently() async throws {
    // `Status.isPaused` is the flag the UI renders through, and pause/resume
    // are the only writers of it. The dead-control risk: a pause() that stops
    // short of the flag, or a resume() that never clears it, leaves the
    // indicator and the reality disagreeing — the user sees "recording" (or
    // "not recording") and neither is true. There is no caller of either method
    // in the app today; see the source guard in ActivityWatchArchitectureTests
    // for that half.
    //
    // WHAT THIS DELIBERATELY DOES NOT ASSERT: `isCapturing`. It is ALSO gated on
    // `_installed`, which is false for a watcher that never started a capture
    // thread — so it reads false here whatever pause() does, and an
    // `isCapturing == false` expectation would be vacuous. (Proven vacuous:
    // deleting `!_paused` from `isCapturing` left such an assertion green.)
    // Covering the installed-and-paused combination needs a live capture thread,
    // which is the ui-walk/live tier, not this one.
    let store = try ActivitySpanStore(dataRoot: watcherRoot())
    let watcher = ActivityWatcher(
        store: store, policy: ActivityPolicy(captureEnabled: true)
    )

    var observed: [Bool] = [watcher.status().isPaused]
    watcher.pause()
    observed.append(watcher.status().isPaused)
    watcher.pause()   // idempotent
    observed.append(watcher.status().isPaused)
    watcher.resume()
    observed.append(watcher.status().isPaused)
    watcher.resume()  // idempotent
    observed.append(watcher.status().isPaused)
    watcher.pause()
    observed.append(watcher.status().isPaused)

    #expect(
        observed == [false, true, true, false, false, true],
        """
        the paused flag went \(observed) across \
        [fresh, pause, pause, resume, resume, pause]. Either a call did not reach the \
        status the UI renders, or a repeated call toggled instead of holding — both \
        leave the capture indicator saying something that is not true.
        """
    )

    // Still ENABLED throughout: pause is not a consent change, and must not be
    // reported as one.
    #expect(
        watcher.isCaptureEnabled,
        "pause() cleared the capture CONSENT flag — pause and revoke are different things"
    )
    watcher.resume()

    // Nothing was written by any of it — pause/resume are control, not capture.
    let spans = try await store.querySpans(from: 0, to: .greatestFiniteMagnitude, limit: 50)
    #expect(spans.isEmpty)
    await watcher.stop()
}

// MARK: - activity.watcher.policyChangedFeed

/// Hands back one staged policy, then reports "unchanged" — the
/// `ActivityPolicySource` contract.
private final class RecordingPolicySource: ActivityPolicySource, @unchecked Sendable {
    private let lock = NSLock()
    private var pending: ActivityPolicy?

    func stage(_ policy: ActivityPolicy) {
        lock.lock(); pending = policy; lock.unlock()
    }

    func reloadIfChanged() -> ActivityPolicy? {
        lock.lock(); defer { lock.unlock() }
        defer { pending = nil }
        return pending
    }
}

/// Thread-safe log of everything the `policyChanged` closure was handed.
private final class PolicyLog: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [ActivityPolicy] = []

    func append(_ policy: ActivityPolicy) {
        lock.lock(); entries.append(policy); lock.unlock()
    }

    var all: [ActivityPolicy] {
        lock.lock(); defer { lock.unlock() }
        return entries
    }
}

@Test("POLICY FEED: the Trust Center is told about an out-of-band change, and told the CLAMPED one")
func policyChangedFeedCarriesTheClampedPolicy() async throws {
    // STALE UI ON THE PRIVACY SWITCH. `policyChanged` is the ONLY channel by
    // which an out-of-band policy change reaches the app; the controller's
    // handler assigns the payload straight to what the Trust Center toggles
    // render. If it stops firing, `activity-probe policy --disable` stops
    // capture correctly while the Trust Center keeps showing every switch ON —
    // the user reads consent state that is a whole tick or session out of date.
    // No existing test constructs a watcher with this closure at all.
    //
    // The clamp matters as much as the firing: what is handed over must be
    // `safelyPolled`'s output, not the raw file contents, or the UI renders
    // permissions the watcher never granted.
    let store = try ActivitySpanStore(dataRoot: watcherRoot())
    let source = RecordingPolicySource()
    let log = PolicyLog()

    var current = ActivityPolicy(
        captureEnabled: true,
        captureTitles: true,
        browserTitlesEnabled: true,
        allowModelAccess: true,
        excludedBundleIDs: ["com.example.vault"],
        retentionDays: 30
    )
    current.appNameOnlyMode = false

    let watcher = ActivityWatcher(
        store: store,
        policy: current,
        policySource: source,
        policyChanged: { log.append($0) }
    )
    // Park a stop request FIRST so the applied policy can never spin up a real
    // capture thread inside the test host. The feed under test is unaffected —
    // `policyChanged` fires before any of that branching.
    await watcher.stop()
    #expect(log.all.isEmpty, "the feed fired before any policy change")

    // Nothing staged → no poll result → no feed. A callback that fires on every
    // tick is as useless as one that never fires.
    #expect(watcher.pollPolicySource() == false)
    #expect(log.all.isEmpty, "the feed fired on an unchanged policy — it would churn the UI")

    // The out-of-band write: one genuine TIGHTENING, and three LOOSENINGS the
    // clamp has to refuse.
    var written = current
    written.captureTitles = false                       // tighten  → applied
    written.excludedBundleIDs = ["com.example.other"]   // loosen   → unioned
    written.retentionDays = 90                          // loosen   → clamped to 30
    written.allowModelAccess = true                     // unchanged
    written.browserTitlesEnabled = true                 // unchanged, but gated by titles
    source.stage(written)

    #expect(watcher.pollPolicySource(), "the poll did not report that it applied a change")

    let fired = log.all
    #expect(
        fired.count == 1,
        "the policy feed fired \(fired.count) time(s) for ONE applied change"
    )
    let announced = try #require(fired.first)

    // What the Trust Center will now render.
    #expect(announced.captureTitles == false, "the tightening did not reach the UI feed")
    #expect(
        announced.retentionDays == 30,
        """
        THE FEED CARRIED THE RAW FILE. retention_days came through as \
        \(announced.retentionDays); the clamp only ever shrinks it. The Trust Center \
        would render a 90-day promise the watcher never made.
        """
    )
    #expect(
        announced.excludedBundleIDs.contains("com.example.vault"),
        "the feed dropped an exclusion already in force — the UI would show the app unprotected"
    )
    #expect(announced.excludedBundleIDs.contains("com.example.other"))
    #expect(announced.captureEnabled)

    // The feed and the watcher agree. A feed that reports something the watcher
    // did not apply is worse than no feed.
    #expect(announced == ActivityWatcher.safelyPolled(
        written, current: current, currentlyEnabled: true
    ))
    #expect(watcher.isCaptureEnabled == announced.captureEnabled)

    // A DISABLE also reaches the feed — the direction the poll exists for.
    var disabled = announced
    disabled.captureEnabled = false
    source.stage(disabled)
    #expect(watcher.pollPolicySource())
    #expect(log.all.count == 2)
    #expect(log.all.last?.captureEnabled == false)
    #expect(watcher.isCaptureEnabled == false)

    await watcher.stop()
}
#endif

// MARK: - activity.watcher.motorEpochGate
// MARK: - activity.watcher.unknownFrontmostAndSelfPidGap

@Test("PROVENANCE: a self-attributed activation closes the human's span and opens nothing")
func selfProcessActivationClosesAndOpensNothing() {
    // THREE watcher branches synthesize `.activate(selfProcessBundleID)` rather
    // than returning early: the motor-epoch gate (an app NativeAgent itself
    // opened), an unknown frontmost (nil bundle id or pid), and our own pid.
    // All three depend on this ENGINE behaviour — close what is open, open
    // nothing. If the engine ever started opening a row for the sentinel, the
    // agent's own browsing would appear in the human's top_apps; if it stopped
    // closing, a transient bundle-less process would silently donate its dwell
    // time to whatever the human was in before it, as one perfectly well-formed
    // longer row.
    var engine = ActivitySpanEngine(policy: ActivityPolicy(captureEnabled: true))

    let opened = engine.process(
        .activate(bundleId: "com.example.editor", appName: "Editor", at: 1_000)
    )
    #expect(opened.count == 1)
    guard case .open(let humanSpan) = opened[0] else {
        Issue.record("the human activation did not open a span")
        return
    }

    // The sentinel every one of the three branches feeds.
    let sentinel = engine.process(.activate(
        bundleId: ActivityPolicy.selfProcessBundleID, appName: "agent-driven", at: 1_060
    ))
    #expect(
        sentinel == [.close(id: humanSpan.id, reason: .appChange, at: 1_060)],
        """
        the self/agent sentinel produced \(sentinel) instead of exactly one close. \
        Anything else is either a leaked open row or an agent-driven span wearing \
        the human's name.
        """
    )
    #expect(engine.openSpan == nil, "a span is open for NativeAgent's own sentinel bundle")

    // While the sentinel is frontmost, ordinary events write nothing at all.
    #expect(engine.process(.focusEvent(at: 1_070)).isEmpty)
    #expect(engine.process(.titleChange(raw: "Chat", at: 1_080)).isEmpty)
    #expect(engine.process(.heartbeat(at: 1_090)).isEmpty)
    #expect(engine.openSpan == nil)

    // The human taking the app back opens a NEW span — the gate is not a
    // permanent blind spot.
    let back = engine.process(
        .activate(bundleId: "com.example.editor", appName: "Editor", at: 1_100)
    )
    #expect(back.count == 1)
    guard case .open(let resumed) = back[0] else {
        Issue.record("the human could not take the app back after an agent-driven edge")
        return
    }
    #expect(resumed.id != humanSpan.id)
    #expect(resumed.startedAt == 1_100, "the resumed span absorbed the agent's 40 s")

    // NON-OVERRIDABLE: a policy that tries to un-exclude the sentinel cannot.
    var permissive = ActivityPolicy(captureEnabled: true)
    permissive.excludedBundleIDs = []
    #expect(
        permissive.allowsCapture(bundleID: ActivityPolicy.selfProcessBundleID) == false,
        "an empty exclusion list made NativeAgent's own sentinel capturable"
    )
}

// MARK: - activity.watcher.attachObserverFailurePath

@Test("AX-ATTACH FAILURE: the junk row it writes is sub-second, zero-event, and reason=quit")
func axAttachFailureProducesAnIdentifiableJunkRow() async throws {
    // A JUNK-ROW GENERATOR, confirmed live. `attachObserver` runs microseconds
    // after `handleActivation` opened the span; if AX registration fails on any
    // of the three notifications it feeds `.terminate` immediately, closing the
    // just-opened span with close_reason='quit' at ~0 duration and 0 events.
    // ALL 25 'quit' rows in the live store are sub-1-second AND have
    // event_count=0 — not one looks like a human using an app and closing it.
    //
    // This pins the SHAPE that branch emits, end to end into the store, so the
    // signature stays recognisable: it is what any future suppression or marker
    // has to be built against, and it is what an answer-side filter would key
    // on. It also pins the two properties that must hold whatever else changes:
    // the close lands at the timestamp it was given (never at open time, which
    // would be a negative-duration row) and no row is left open.
    let store = try ActivitySpanStore(dataRoot: watcherRoot())
    var engine = ActivitySpanEngine(policy: ActivityPolicy(captureEnabled: true))

    // A REAL span first, so the junk row has something honest to be compared
    // against and the assertions cannot pass on an empty store.
    try await store.apply(engine.process(
        .activate(bundleId: "com.example.editor", appName: "Editor", at: watcherBase)
    ))
    try await store.apply(engine.process(.focusEvent(at: watcherBase + 30)))
    try await store.apply(engine.process(.focusEvent(at: watcherBase + 60)))

    // THE BRANCH: activate, then terminate 50 ms later — the exact shape
    // ActivityWatcher.swift emits when AXObserverAddNotification returns
    // .invalidUIElement or .cannotComplete.
    let activateAt = watcherBase + 120
    try await store.apply(engine.process(
        .activate(bundleId: "com.example.browser", appName: "Browser", at: activateAt)
    ))
    try await store.apply(engine.process(.terminate(at: activateAt + 0.05)))

    #expect(engine.openSpan == nil, "the AX-attach failure path left a row open")

    let rows = try await store.querySpans(
        from: watcherBase - 60, to: watcherBase + 600, limit: 50
    )
    #expect(rows.count == 2, "expected the honest row plus the junk one, got \(rows.count)")

    let junk = try #require(rows.first { $0.bundleId == "com.example.browser" })
    let honest = try #require(rows.first { $0.bundleId == "com.example.editor" })

    #expect(junk.closeReason == .quit)
    #expect(
        junk.endedAt == activateAt + 0.05,
        "the close did not land at the timestamp the branch fed it"
    )
    #expect(junk.duration >= 0, "a negative-duration row reached the store")
    #expect(junk.duration < 1, "the junk row is \(junk.duration) s — the fixture no longer models the branch")
    #expect(junk.eventCount == 0)

    // The honest row is the control: this is what a real app-use row looks
    // like, and the difference between the two is the whole signature.
    #expect(honest.duration >= 100)
    #expect(honest.eventCount == 2)

    // THE COST, stated as an assertion rather than a comment: the junk row is
    // counted as a span in top_apps exactly like the honest one. Nothing in the
    // fence suppresses it, so anything that later does has to change this line.
    let top = ActivityRollups.topApps(
        spans: rows, from: watcherBase - 60, to: watcherBase + 600, limit: 10
    )
    let browserRow = try #require(top.rows.first { $0.bundleId == "com.example.browser" })
    #expect(
        browserRow.spanCount == 1,
        """
        the sub-second zero-event 'quit' row is \(browserRow.spanCount) span(s) in top_apps. \
        If this is now 0, the suppression this row asked for has shipped — update this \
        assertion and flip activity.watcher.attachObserverFailurePath in the ledger.
        """
    )

    // And the honest control still counts, so the assertion above is not
    // passing on an empty rollup.
    #expect(top.rows.contains { $0.bundleId == "com.example.editor" })
}
