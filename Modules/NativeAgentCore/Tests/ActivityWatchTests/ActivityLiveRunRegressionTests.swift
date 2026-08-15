import Foundation
import Testing
@testable import ActivityWatch

/// The two defects a LIVE run exposed on 2026-08-14 that the simulation missed.
///
/// Both are pinned here in the shape the live watcher actually produces, not the
/// shape the ground-truth script happened to use — that gap is precisely why the
/// simulation passed while the real thing wrote junk.

// MARK: - Defect 1: zero-length span churn

private func regressionRoot() -> URL {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("ActivityLiveRegression-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}

@Test("LIVE SHAPE: activate + title 50 ms later yields ONE span, not a 0 s row plus a successor")
func firstTitleDoesNotSplitTheSpan() {
    // THE LIVE SHAPE. The watcher opens the span on `.activate` (no title,
    // because the exclusion gate runs before any AX read), then reads
    // kAXTitle microseconds later and feeds it straight back. A 2-minute run
    // with 6 app switches produced 16 spans, 8 of them zero-length, because
    // that first title was treated as a window change.
    //
    // The old ground-truth script separated the two by NINETY SECONDS, which is
    // why the split looked like a plausible span instead of garbage.
    var engine = deterministicEngine(policy: capturePolicy(titles: true))
    let t = 1_700_000_000.0

    var commands = engine.process(.activate(bundleId: "com.apple.Finder", appName: "Finder", at: t))
    commands += engine.process(.titleChange(raw: "Downloads", at: t + 0.05))
    // A genuine window change, much later.
    commands += engine.process(.titleChange(raw: "Documents", at: t + 26))
    commands += engine.process(.terminate(at: t + 40))

    let opens: [ActivitySpan] = commands.compactMap {
        if case .open(let span) = $0 { return span } else { return nil }
    }
    let closes = commands.filter { if case .close = $0 { return true } else { return false } }
    let retitles = commands.filter { if case .retitle = $0 { return true } else { return false } }

    #expect(
        opens.count == 2,
        """
        expected exactly TWO spans (Finder@Downloads, then Finder@Documents); got \
        \(opens.count). A third means the span's first title split it again — which is \
        the junk zero-length row every live app switch was producing.
        """
    )
    #expect(closes.count == 2, "expected 2 closes, got \(closes.count): \(commands)")
    #expect(retitles.count == 1, "the first title must be a retitle, not a split: \(commands)")

    // The first span carries the FIRST title...
    #expect(opens.first?.titleRedacted == nil, "the open command itself carries no title yet")
    #expect(engine.openSpan == nil, "terminate should have closed everything")

    // ...and NO span is zero-length.
    var starts: [String: Double] = [:]
    for span in opens { starts[span.id] = span.startedAt }
    for command in commands {
        guard case .close(let id, _, let at) = command, let start = starts[id] else { continue }
        #expect(
            at > start,
            "ZERO-LENGTH span \(id): opened at \(start), closed at \(at)"
        )
    }
}

@Test("LIVE SHAPE, END TO END: the store holds one titled span and no zero-length row")
func firstTitleDoesNotSplitTheSpanInTheStore() async throws {
    // Same shape, driven all the way through the REAL store, because the
    // in-place retitle is half engine and half SQL — an engine that emits
    // `.retitle` into a store that drops it would still lose the title.
    let store = try ActivitySpanStore(dataRoot: regressionRoot())
    let t = 1_700_000_000.0
    let script = ActivityScript(
        policy: capturePolicy(titles: true),
        events: [
            .activate(bundleId: "com.apple.Finder", appName: "Finder", at: t),
            .titleChange(raw: "Downloads", at: t + 0.05),
            .titleChange(raw: "Documents", at: t + 26),
            .terminate(at: t + 40),
        ]
    )
    let spans = try await ActivitySimulator.replay(script, into: store)

    #expect(spans.count == 2, "expected 2 rows, got \(spans.count): \(spans.map(\.titleRedacted))")
    #expect(spans.first?.titleRedacted == "Downloads", "the first span lost its initial title")
    #expect(spans.last?.titleRedacted == "Documents")
    for span in spans {
        let end = span.endedAt ?? span.lastSeenAt
        #expect(end > span.startedAt, "ZERO-LENGTH row: \(span.bundleId) at \(span.startedAt)")
    }
    // The retitle counts as an event on the span it landed on.
    #expect(spans.first?.eventCount == 1, "retitle must bump event_count exactly once")
}

@Test("An UNCHANGED title is still just an event, and a SECOND distinct title still splits")
func retitleDoesNotSwallowGenuineWindowChanges() {
    // The negative control for the fix: making the first title in-place must not
    // turn the engine into one that never splits at all.
    //
    // STRENGTHENED (gpt-5.5 MINOR, 2026-08-14). The first version asserted only
    // "the second distinct title opens exactly one successor" — which the OLD,
    // always-split engine satisfied too, so it protected nothing. It now pins
    // the EXACT command sequence, which the pre-fix engine cannot produce: the
    // first title has to be a `.retitle` on the existing span (the old engine
    // emitted close+open there), so `.open` must appear exactly TWICE across the
    // whole run, not three times.
    var engine = deterministicEngine(policy: capturePolicy(titles: true))
    let t = 1_700_000_000.0
    var commands = engine.process(.activate(bundleId: "com.example.editor", appName: "Editor", at: t))
    commands += engine.process(.titleChange(raw: "a.txt", at: t + 1))

    let same = engine.process(.titleChange(raw: "a.txt", at: t + 2))
    commands += same
    #expect(
        same.allSatisfy { if case .touch = $0 { return true } else { return false } },
        "an unchanged title must be a bare touch, got \(same)"
    )

    let different = engine.process(.titleChange(raw: "b.txt", at: t + 3))
    commands += different
    let opens = different.filter { if case .open = $0 { return true } else { return false } }
    #expect(opens.count == 1, "a SECOND, different title must still open a successor")
    #expect(engine.openSpan?.titleRedacted == "b.txt")

    // The whole sequence, kind by kind. `open, retitle, touch, close, open` —
    // an always-splitting engine produces `open, close, open, touch, close, open`
    // and fails on both counts below.
    #expect(
        commandKinds(commands) == ["open", "retitle", "touch", "close", "open"],
        "unexpected command sequence: \(commandKinds(commands))"
    )
    let allOpens = commands.filter { if case .open = $0 { return true } else { return false } }
    #expect(
        allOpens.count == 2,
        """
        expected exactly TWO opens (Editor@a.txt, then Editor@b.txt); got \(allOpens.count). \
        A third means the span's FIRST title split it — the junk zero-length row the retitle \
        path exists to prevent.
        """
    )
}

/// Command kinds in order, for sequence assertions that a reverted fix fails.
private func commandKinds(_ commands: [ActivityStoreCommand]) -> [String] {
    commands.map { command in
        switch command {
        case .open: return "open"
        case .touch: return "touch"
        case .heartbeat: return "heartbeat"
        case .retitle: return "retitle"
        case .close: return "close"
        case .reconcileAbandoned: return "reconcileAbandoned"
        }
    }
}

@Test("NIL IS A TITLE VALUE: 'A' → nil → 'B' is three spans, and the middle one is nil-titled")
func nilTitleIsNotMistakenForAnUndecidedTitle() {
    // THE DEFECT (gpt-5.5 BLOCKING, 2026-08-14): `titleRedacted == nil` was used
    // to mean "this span has not learned its title yet". But nil is ALSO a
    // legitimate current title — a window with no AX title, or one the redactor
    // dropped whole. So after "A" → nil correctly split and opened a nil-titled
    // successor, the next title "B" landed on a span whose title read nil, was
    // treated as an INITIAL title, and was stamped IN PLACE. Result: the
    // nil-titled interval was retroactively relabelled "B" and a genuine window
    // change vanished.
    var engine = deterministicEngine(policy: capturePolicy(titles: true))
    let t = 1_700_000_000.0

    var commands = engine.process(.activate(bundleId: "com.example.editor", appName: "Editor", at: t))
    commands += engine.process(.titleChange(raw: "A", at: t + 1))     // initial title -> retitle
    commands += engine.process(.titleChange(raw: nil, at: t + 10))    // real change -> split
    commands += engine.process(.titleChange(raw: "B", at: t + 20))    // real change -> split
    commands += engine.process(.terminate(at: t + 30))

    let opens: [ActivitySpan] = commands.compactMap {
        if case .open(let span) = $0 { return span } else { return nil }
    }
    #expect(
        opens.count == 3,
        """
        expected THREE spans (A, nil, B); got \(opens.count). Two means the nil→"B" transition \
        was swallowed as an initial title, mislabelling the nil-titled interval as "B" and \
        losing a real window change. Sequence: \(commandKinds(commands))
        """
    )
    #expect(opens.first?.titleRedacted == nil, "the first span is opened by activate, still untitled")
    #expect(engine.openSpan == nil, "terminate should have closed everything")

    guard opens.count == 3 else { return }
    #expect(opens[1].titleRedacted == nil, "the MIDDLE span must carry a nil title, got \(String(describing: opens[1].titleRedacted))")
    #expect(opens[2].titleRedacted == "B", "the third span must carry B, got \(String(describing: opens[2].titleRedacted))")
    // Exactly one retitle: the FIRST title only. Both later transitions split.
    let retitles = commands.filter { if case .retitle = $0 { return true } else { return false } }
    #expect(retitles.count == 1, "only the initial title may be stamped in place: \(commandKinds(commands))")
    #expect(
        commandKinds(commands) == [
            "open", "retitle", "close", "open", "close", "open", "close",
        ],
        "unexpected command sequence: \(commandKinds(commands))"
    )
}

@Test("NIL IS A TITLE VALUE, END TO END: the store holds three rows, the middle one untitled")
func nilTitleSplitSurvivesTheStore() async throws {
    let store = try ActivitySpanStore(dataRoot: regressionRoot())
    let t = 1_700_000_000.0
    let script = ActivityScript(
        policy: capturePolicy(titles: true),
        events: [
            .activate(bundleId: "com.example.editor", appName: "Editor", at: t),
            .titleChange(raw: "A", at: t + 1),
            .titleChange(raw: nil, at: t + 10),
            .titleChange(raw: "B", at: t + 20),
            .terminate(at: t + 30),
        ]
    )
    let spans = try await ActivitySimulator.replay(script, into: store)

    #expect(spans.count == 3, "expected 3 rows, got \(spans.count): \(spans.map(\.titleRedacted))")
    guard spans.count == 3 else { return }
    #expect(spans[0].titleRedacted == "A", "the first span lost its initial title")
    #expect(spans[1].titleRedacted == nil, "the nil-titled interval was relabelled")
    #expect(spans[2].titleRedacted == "B")
}

// MARK: - Defect 2: a running watcher never re-read the policy file

/// Stub source: hands back whatever was last staged, once.
private final class StubPolicySource: ActivityPolicySource, @unchecked Sendable {
    private let lock = NSLock()
    private var pending: ActivityPolicy?
    private(set) var pollCount = 0

    func stage(_ policy: ActivityPolicy) {
        lock.lock(); pending = policy; lock.unlock()
    }

    func reloadIfChanged() -> ActivityPolicy? {
        lock.lock(); defer { lock.unlock() }
        pollCount += 1
        defer { pending = nil }
        return pending
    }
}

#if canImport(AppKit)
@Test("OUT-OF-BAND: a policy file flipped to captureEnabled=false stops a running watcher")
func outOfBandPolicyDisableStopsCapture() async throws {
    // THE LIVE DEFECT: with the watcher running, `activity-probe policy
    // --disable` wrote captureEnabled=false to disk and 40 more seconds of app
    // switching added 4 MORE rows. The instant-pause guarantee only held for
    // the in-app toggle, which calls `updatePolicy` directly.
    let root = regressionRoot()
    let store = try ActivitySpanStore(dataRoot: root)
    let source = StubPolicySource()
    let watcher = ActivityWatcher(
        store: store,
        policy: capturePolicy(titles: true),
        policySource: source
    )
    #expect(watcher.isCaptureEnabled, "precondition: capture starts enabled")

    // Nothing staged → the poll is a no-op and must not churn the policy.
    #expect(watcher.pollPolicySource() == false)
    #expect(watcher.isCaptureEnabled)

    // The out-of-band write.
    var disabled = capturePolicy(titles: true)
    disabled.captureEnabled = false
    source.stage(disabled)

    #expect(watcher.pollPolicySource(), "the poll must report that it applied a change")
    #expect(
        watcher.isCaptureEnabled == false,
        """
        the watcher kept capture enabled after the policy source reported \
        captureEnabled=false. This is the live defect: 4 further rows were written \
        after the probe CLI disabled capture on disk.
        """
    )
    #expect(watcher.isCapturing == false)
    #expect(source.pollCount == 2, "poll must reach the source every call")

    let spans = try await store.querySpans(from: 0, to: .greatestFiniteMagnitude, limit: 100)
    #expect(spans.isEmpty)
    await watcher.stop()
}

// MARK: - Defect 3: the poll is a SAFETY VALVE, not a control channel

@Test("OUT-OF-BAND: a polled captureEnabled=true must NOT enable a disabled watcher")
func outOfBandPolicyEnableIsRefused() async throws {
    // THE DEFECT (gpt-5.5 BLOCKING, 2026-08-14): `ActivityPolicy`'s decoder
    // defaults every missing key, so a TORN external write of
    // `{"captureEnabled":true}` decodes as a valid ENABLED policy with default
    // exclusions — and the poll applied it immediately. A file nobody
    // deliberately wrote could turn capture on. Enabling goes through the
    // in-app Trust Center path and nowhere else.
    let root = regressionRoot()
    let store = try ActivitySpanStore(dataRoot: root)
    let source = StubPolicySource()
    let watcher = ActivityWatcher(store: store, policy: ActivityPolicy(), policySource: source)
    #expect(watcher.isCaptureEnabled == false, "precondition: capture starts disabled")

    source.stage(capturePolicy(titles: true))   // the torn/hostile write
    #expect(
        watcher.pollPolicySource() == false,
        "the poll applied an out-of-band ENABLE; it may only ever tighten"
    )
    #expect(
        watcher.isCaptureEnabled == false,
        """
        A POLLED POLICY TURNED CAPTURE ON. A partial or torn write of the policy file decodes \
        as an enabled policy with default exclusions; the poll is a safety valve and must \
        never be a way to start recording.
        """
    )
    #expect(watcher.isCapturing == false)

    // NOT a watcher that can never enable at all: the clamp refuses the poll
    // specifically, and passes an identical policy straight through when the
    // deliberate in-app path (a direct `updatePolicy`) already turned capture on.
    #expect(
        ActivityWatcher.safelyPolled(
            capturePolicy(titles: true), current: capturePolicy(titles: true), currentlyEnabled: true
        ) != nil,
        "the clamp refuses everything — the refusal above proves nothing"
    )
    await watcher.stop()
}

@Test("OUT-OF-BAND: a polled captureEnabled=false DOES disable an enabled watcher")
func outOfBandPolicyDisableIsStillApplied() async throws {
    // The positive control for the clamp above: tightening still lands, or the
    // whole poll is dead code and the live defect it fixed comes back.
    let root = regressionRoot()
    let store = try ActivitySpanStore(dataRoot: root)
    let source = StubPolicySource()
    let watcher = ActivityWatcher(
        store: store, policy: capturePolicy(titles: true), policySource: source
    )
    #expect(watcher.isCaptureEnabled, "precondition: capture starts enabled")

    var disabled = capturePolicy(titles: true)
    disabled.captureEnabled = false
    source.stage(disabled)

    #expect(watcher.pollPolicySource(), "the poll must apply a DISABLE")
    #expect(watcher.isCaptureEnabled == false, "a polled disable was ignored")
    await watcher.stop()
}

@Test("OUT-OF-BAND: a polled policy cannot shrink the exclusion set or loosen titles")
func outOfBandPolicyCannotLoosenPrivacy() async throws {
    let root = regressionRoot()
    let store = try ActivitySpanStore(dataRoot: root)
    let source = StubPolicySource()
    let current = capturePolicy(titles: true, excluded: ["com.example.secret"])
    let watcher = ActivityWatcher(store: store, policy: current, policySource: source)

    // A polled policy that drops the exclusion and turns titles fully on.
    let loosened = capturePolicy(titles: true, browserTitles: true, excluded: [])
    source.stage(loosened)
    #expect(
        watcher.pollPolicySource() == false,
        "a poll that only LOOSENS must apply nothing (union + AND collapses it to the current policy)"
    )

    // The clamp itself, stated directly.
    let safe = try #require(ActivityWatcher.safelyPolled(
        loosened, current: current, currentlyEnabled: true
    ))
    #expect(
        safe.excludedBundleIDs.contains("com.example.secret"),
        """
        THE POLL DROPPED AN EXCLUSION. Exclusions are unioned, never replaced: a torn or stale \
        file write must not un-exclude an app the user excluded.
        """
    )
    #expect(safe.browserTitlesEnabled == false, "browser titles went false→true via the poll")

    // Tightening in the same fields still passes through.
    let tightened = capturePolicy(titles: false, excluded: ["com.example.other"])
    let clamped = try #require(ActivityWatcher.safelyPolled(
        tightened, current: current, currentlyEnabled: true
    ))
    #expect(clamped.captureTitles == false, "a polled titles-OFF must be applied")
    #expect(
        clamped.excludedBundleIDs == ["com.example.secret", "com.example.other"],
        "the polled exclusions must be unioned with the current ones, got \(clamped.excludedBundleIDs)"
    )
    await watcher.stop()
}

@Test("CONFORMANCE: the title read re-checks the capture fence immediately before the AX call")
func titleReadReChecksCaptureEnabled() throws {
    // TOCTOU (gpt-5.5 IMPORTANT, 2026-08-14): `handleActivation` polls the
    // policy and checks `isCaptureEnabled`, then feeds `.activate`, starts the
    // timer and attaches the observer before this read happens. A disable
    // landing in that gap used to still cost an AX title read. Source-level
    // because the AX read itself needs a window server, a TCC grant and a real
    // frontmost app — none of which exist in this suite; the guard being
    // PRESENT and ahead of the read is the checkable property.
    let url = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()            // ActivityWatchTests
        .deletingLastPathComponent()            // Tests
        .deletingLastPathComponent()            // NativeAgentCore
        .appendingPathComponent("Sources/ActivityWatch/ActivityWatcher.swift")
    let code = try String(contentsOf: url, encoding: .utf8)

    let start = try #require(
        code.range(of: "private func captureTitleIfAllowed("),
        "captureTitleIfAllowed no longer exists — this guard is blind"
    )
    let read = try #require(
        code.range(of: "Self.frontmostWindowTitle(pid:", range: start.upperBound..<code.endIndex),
        "the AX title read moved out of captureTitleIfAllowed — this guard is blind"
    )
    let body = String(code[start.upperBound..<read.lowerBound])
    #expect(
        body.contains("guard isCaptureEnabled else"),
        """
        NO CAPTURE-FENCE RE-CHECK BEFORE THE AX TITLE READ.

        captureTitleIfAllowed re-checks the LOCK immediately before reading kAXTitle but not \
        the master capture fence. An out-of-band or Trust Center disable landing between \
        handleActivation's check and this read then still reads a window title after the user \
        said stop.
        """
    )
    #expect(
        body.contains("reconcileLocked()"),
        "the lock re-check disappeared from captureTitleIfAllowed"
    )
}
#endif

@Test("OUT-OF-BAND: the disabled policy reaches the engine, which then opens nothing")
func disabledPolicyFromFileStopsTheEngineOpeningSpans() {
    // The other half of the same guarantee, at the layer that actually decides
    // whether a row exists. `pollPolicySource` routes through `updatePolicy`,
    // which is this call.
    var engine = ActivitySpanEngine(policy: capturePolicy(titles: true))
    _ = engine.process(.activate(bundleId: "com.apple.Finder", appName: "Finder", at: 1_000))
    #expect(engine.openSpan != nil, "precondition")

    var disabled = capturePolicy(titles: true)
    disabled.captureEnabled = false
    let closes = engine.updatePolicy(disabled, at: 1_010)
    #expect(closes.count == 1, "the open span must close at the flip, got \(closes)")

    let after = engine.process([
        .activate(bundleId: "com.apple.TextEdit", appName: "TextEdit", at: 1_020),
        .titleChange(raw: "untitled", at: 1_021),
        .activate(bundleId: "com.apple.Finder", appName: "Finder", at: 1_040),
    ])
    let opens = after.filter { if case .open = $0 { return true } else { return false } }
    #expect(opens.isEmpty, "engine opened \(opens.count) span(s) under a disabled policy")
    #expect(engine.openSpan == nil)
}

@Test("The file-backed policy source decodes only when the file actually changes")
func policyFileSourceIsStatCheap() throws {
    // The tick calls this once a minute and every activation calls it too, so
    // "cheap" is load-bearing: it must not decode JSON on an unchanged file.
    let root = regressionRoot()
    let store = ActivityPolicyStore(dataRoot: root)
    let source = ActivityPolicyFileSource(store: store)

    // No file yet: first observation reports (the safe default), then settles.
    _ = source.reloadIfChanged()
    #expect(source.reloadIfChanged() == nil, "an unchanged, still-absent file must report nil")

    try store.save(capturePolicy(titles: true))
    let loaded = source.reloadIfChanged()
    #expect(loaded?.captureEnabled == true, "a new policy file must be picked up")
    #expect(source.reloadIfChanged() == nil, "an unchanged file must not be re-decoded")

    var disabled = capturePolicy(titles: true)
    disabled.captureEnabled = false
    // Same size, different content — the mtime is what has to catch this.
    Thread.sleep(forTimeInterval: 0.02)
    try store.save(disabled)
    #expect(source.reloadIfChanged()?.captureEnabled == false, "the disable was missed")
    #expect(source.reloadIfChanged() == nil)

    // `prime()` records the stamp without reporting, so a watcher handed a
    // freshly-loaded policy does not immediately re-apply it.
    let primed = ActivityPolicyFileSource(store: store)
    primed.prime()
    #expect(primed.reloadIfChanged() == nil, "prime() must suppress the first report")
}
