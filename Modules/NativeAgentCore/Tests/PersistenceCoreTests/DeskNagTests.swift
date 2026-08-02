import Testing
import Foundation
@testable import PersistenceCore

// MARK: - Desk nag lane (Wave 3) — config persistence + pure evaluator
//
// The two invariants these tests exist to protect:
//   1. DEFAULT OFF. A fresh install has no config file, loads to disabled, and
//      the evaluator is totally inert (no nags, no digest, no config mutation).
//   2. STALE ALONE NEVER PINGS. A stale+static item is digest material; only
//      stale + a delta underneath earns an interruption, and each item gets at
//      most ONE per windowId.

@Suite("DeskNag")
struct DeskNagTests {

    private func hermeticRoot() -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("DeskNag-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    /// A minimal live item. `updatedAt` is injected so staleness is exact.
    private func item(
        handle: String,
        alias: String,
        project: String = "NativeAgent",
        title: String = "ship it",
        updatedAt: Date,
        status: DeskStatus = .todo,
        blockedOn: [String] = [],
        deferUntil: String? = nil,
        staleAfter: String? = nil
    ) -> DeskItem {
        var row = DeskItem(
            handle: handle,
            alias: alias,
            kind: .plan,
            status: status,
            project: project,
            title: title,
            openedAt: DeskClock.nowISO(updatedAt),
            updatedAt: DeskClock.nowISO(updatedAt)
        )
        row.blockedOn = blockedOn
        row.deferUntil = deferUntil
        row.cadence = Cadence(mode: .manual, staleAfter: staleAfter)
        return row
    }

    private func state(_ items: [DeskItem], now: Date) -> DeskState {
        DeskState(items: items, generatedTs: DeskClock.nowISO(now))
    }

    private func evaluate(
        _ items: [DeskItem],
        config: DeskNagConfig,
        now: Date
    ) -> DeskNagEvaluator.Outcome {
        let st = state(items, now: now)
        let plan = DeskSequencing.compute(st, now: now)
        return DeskNagEvaluator.evaluate(state: st, plan: plan, config: config, now: now)
    }

    /// Scoped-on, globally-on config with a pre-seeded baseline for `handle`.
    private func armed(
        project: String = "NativeAgent",
        observed: [String: DeskNagObservation] = [:],
        ledger: [String: Int] = [:],
        mutedUntil: String? = nil,
        windowId: Int = 1
    ) -> DeskNagConfig {
        DeskNagConfig(
            enabled: true,
            scopes: [DeskNagScope(kind: .project, id: project, enabled: true)],
            mutedUntil: mutedUntil,
            windowId: windowId,
            ledger: ledger,
            observed: observed
        )
    }

    // MARK: - 1. Config: default off + round-trip

    @Test func freshInstallLoadsDefaultOffAndWritesNothing() async throws {
        let root = hermeticRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = DeskNagConfigStore(dataRoot: root)

        let config = await store.load()
        #expect(config.enabled == false, "the nag lane must be OFF until User opts in")
        #expect(config.scopes.isEmpty)
        #expect(config.mutedUntil == nil)
        #expect(config.windowId == 1)
        // Loading must not materialise the file — a fresh install leaves no trace.
        #expect(!FileManager.default.fileExists(atPath: store.configPath.path))
    }

    @Test func configRoundTripsThroughDiskWithEveryField() async throws {
        let root = hermeticRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = DeskNagConfigStore(dataRoot: root)

        let original = DeskNagConfig(
            enabled: true,
            scopes: [
                DeskNagScope(kind: .project, id: "NativeAgent", enabled: true),
                DeskNagScope(kind: .item, id: "desk_abc", enabled: false),
            ],
            mutedUntil: "2026-09-01",
            windowId: 7,
            ledger: ["desk_abc": 7],
            observed: ["desk_abc": DeskNagObservation(
                updatedAt: "2026-08-01T00:00:00.000000+00:00",
                effectiveBlockerCount: 2,
                deferElapsed: false
            )]
        )
        try await store.save(original)
        let reloaded = await store.load()
        #expect(reloaded == original)
    }

    @Test func decodeIsTolerantAndEncodeOmitsEmpty() {
        // A junk scope row drops the ROW, not the file (preference state must
        // never fail closed into silent not-nagging).
        let raw = JSONValue.object([
            "enabled": .bool(true),
            "windowId": .int(3),
            "scopes": .array([
                .object(["kind": .string("project"), "id": .string("na"), "enabled": .bool(true)]),
                .object(["kind": .string("galaxy"), "id": .string("nope")]),
                .string("garbage"),
            ]),
        ])
        let decoded = DeskNagConfig.fromJSON(raw)
        #expect(decoded.enabled)
        #expect(decoded.windowId == 3)
        #expect(decoded.scopes.count == 1)
        #expect(decoded.scopes.first?.id == "na")

        // Omit-empty: an untouched config is three scalars.
        guard case .object(let obj) = DeskNagConfig().toJSON() else {
            Issue.record("config did not encode to an object"); return
        }
        #expect(obj["scopes"] == nil)
        #expect(obj["ledger"] == nil)
        #expect(obj["observed"] == nil)
        #expect(obj["mutedUntil"] == nil)
        #expect(obj["enabled"] == .bool(false))
    }

    @Test func windowBumpsOnEnableAndUnmuteOnly() {
        let base = DeskNagConfig()
        let on = base.settingGlobal(true)
        #expect(on.windowId == 2, "off→on opens a new attention window")
        #expect(on.settingGlobal(true).windowId == 2, "on→on is not a transition")
        #expect(on.settingGlobal(false).windowId == 2, "turning OFF does not re-arm anything")
        let muted = on.muted(until: nil)
        #expect(muted.mutedUntil == DeskNagConfig.indefiniteMuteSentinel)
        #expect(muted.windowId == 2, "muting suspends; it does not re-arm")
        #expect(muted.unmuted().windowId == 3)
        #expect(muted.unmuted().mutedUntil == nil)
    }

    @Test func muteIsElapsedInThePastAndUnparseableReadsAsUnmuted() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        var cfg = DeskNagConfig(enabled: true)
        cfg.mutedUntil = DeskClock.nowISO(now.addingTimeInterval(3600))
        #expect(cfg.isMuted(now: now))
        #expect(!cfg.muteHasElapsed(now: now))
        cfg.mutedUntil = DeskClock.nowISO(now.addingTimeInterval(-3600))
        #expect(!cfg.isMuted(now: now))
        #expect(cfg.muteHasElapsed(now: now), "a past stamp is the transition the loop watches for")
        // Bad date → NOT muted. Going quiet forever over a typo is the worse failure.
        cfg.mutedUntil = "whenever"
        #expect(!cfg.isMuted(now: now))
    }

    @Test func itemScopeOverridesProjectScope() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let row = item(handle: "desk_a", alias: "1", updatedAt: now)
        var cfg = armed()
        #expect(cfg.scopeEnabled(for: row))
        cfg = cfg.settingScope(kind: .item, id: "desk_a", enabled: false)
        #expect(!cfg.scopeEnabled(for: row), "the most specific scope decides")
        // No scope at all → nothing nags, even with the global switch on.
        #expect(!DeskNagConfig(enabled: true).scopeEnabled(for: row))
    }

    // MARK: - 2. Evaluator: global off is inert

    @Test func globallyDisabledIsTotallyInert() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let stale = item(handle: "desk_a", alias: "1", updatedAt: now.addingTimeInterval(-10 * 86_400))
        let out = evaluate([stale], config: DeskNagConfig(), now: now)
        #expect(out.nags.isEmpty)
        #expect(out.digestLines.isEmpty)
        #expect(out.updatedConfig == DeskNagConfig(), "a disabled lane must not even record observations")
    }

    // MARK: - 3. Stale + STATIC → digest, never a nag

    @Test func staleAndStaticGoesToTheDigestNotAPing() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let old = now.addingTimeInterval(-5 * 86_400)
        let row = item(handle: "desk_a", alias: "1", title: "notarize the build", updatedAt: old)
        let config = armed(observed: ["desk_a": DeskNagEvaluator.observation(row, plan: DeskSequencing.compute(state([row], now: now), now: now))])

        let out = evaluate([row], config: config, now: now)
        #expect(out.nags.isEmpty, "staleness alone must never ping")
        #expect(out.digestLines.count == 1)
        #expect(out.digestLines[0].contains("notarize the build"))
        #expect(out.digestLines[0].contains("stale 5d"))
        #expect(out.updatedConfig.ledger.isEmpty, "a digest mention must not spend the item's nag budget")
    }

    @Test func firstSightingOnlyRecordsABaseline() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let row = item(handle: "desk_a", alias: "1", updatedAt: now.addingTimeInterval(-5 * 86_400))
        let out = evaluate([row], config: armed(), now: now)
        #expect(out.nags.isEmpty)
        #expect(out.digestLines.isEmpty, "with no baseline there is no delta and nothing honest to say")
        #expect(out.updatedConfig.observed["desk_a"] != nil)
    }

    // MARK: - 4. Stale + DELTA → one nag, once per window

    @Test func blockerClearingOnAStaleItemNagsExactlyOncePerWindow() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let old = now.addingTimeInterval(-6 * 86_400)
        let target = item(handle: "desk_a", alias: "1", title: "cut the release", updatedAt: old)
        // Baseline remembers ONE live blocker; the blocker has since closed, so
        // the derived effective-blocker count is now zero. That is the delta.
        let config = armed(observed: [
            "desk_a": DeskNagObservation(updatedAt: target.updatedAt, effectiveBlockerCount: 1, deferElapsed: true),
        ])

        let first = evaluate([target], config: config, now: now)
        #expect(first.nags.count == 1)
        #expect(first.nags[0].level == .digest, "the nag lane never escalates")
        #expect(first.nags[0].body.contains("blockers cleared"))
        #expect(first.nags[0].body.contains("untouched 6d"))
        #expect(first.updatedConfig.ledger["desk_a"] == 1)

        // Same window, a SECOND delta (content moved while stale) → capped.
        var moved = target
        moved.updatedAt = DeskClock.nowISO(now.addingTimeInterval(-4 * 86_400))
        var withStaleBaseline = first.updatedConfig
        withStaleBaseline.observed["desk_a"] = DeskNagObservation(
            updatedAt: target.updatedAt, effectiveBlockerCount: 0, deferElapsed: true)
        let second = evaluate([moved], config: withStaleBaseline, now: now)
        #expect(second.nags.isEmpty, "one nag per item per window is a hard cap")
        #expect(second.updatedConfig.observed["desk_a"]?.updatedAt == moved.updatedAt,
                "a capped delta is consumed, not left pending to detonate next window")

        // New window (User unmuted / switched the lane back on) → re-armed.
        var nextWindow = second.updatedConfig
        nextWindow.windowId += 1
        nextWindow.observed["desk_a"] = DeskNagObservation(
            updatedAt: moved.updatedAt, effectiveBlockerCount: 2, deferElapsed: true)
        let third = evaluate([moved], config: nextWindow, now: now)
        #expect(third.nags.count == 1, "a new window re-arms the item")
        #expect(third.updatedConfig.ledger["desk_a"] == nextWindow.windowId)
    }

    @Test func deferElapsingIsADeltaButAParkedItemIsSilent() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let old = now.addingTimeInterval(-8 * 86_400)

        // Still parked: not stale, not a next action, nothing said.
        let parked = item(handle: "desk_a", alias: "1", updatedAt: old, deferUntil: "2099-01-01")
        let whileParked = evaluate([parked], config: armed(observed: [
            "desk_a": DeskNagObservation(updatedAt: parked.updatedAt, effectiveBlockerCount: 0, deferElapsed: false),
        ]), now: now)
        #expect(whileParked.nags.isEmpty)
        #expect(whileParked.digestLines.isEmpty)

        // Park elapsed: same item, defer date now in the past → the flip fires.
        let freed = item(handle: "desk_a", alias: "1", updatedAt: old, deferUntil: "2020-01-01")
        let afterPark = evaluate([freed], config: armed(observed: [
            "desk_a": DeskNagObservation(updatedAt: freed.updatedAt, effectiveBlockerCount: 0, deferElapsed: false),
        ]), now: now)
        #expect(afterPark.nags.count == 1)
        #expect(afterPark.nags[0].body.contains("defer elapsed"))
    }

    @Test func aFreshItemNeverNagsNoMatterWhatMoved() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        // Touched an hour ago: a real delta, but not stale → not news.
        let fresh = item(handle: "desk_a", alias: "1", updatedAt: now.addingTimeInterval(-3_600))
        let out = evaluate([fresh], config: armed(observed: [
            "desk_a": DeskNagObservation(updatedAt: "2020-01-01T00:00:00.000000+00:00", effectiveBlockerCount: 3, deferElapsed: true),
        ]), now: now)
        #expect(out.nags.isEmpty)
        #expect(out.digestLines.isEmpty)
    }

    @Test func cadenceStaleAfterOverridesTheDefault() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        // 6h old: not stale by the 72h default, stale by the item's own "2h".
        let row = item(handle: "desk_a", alias: "1", updatedAt: now.addingTimeInterval(-6 * 3_600), staleAfter: "2h")
        let out = evaluate([row], config: armed(observed: [
            "desk_a": DeskNagObservation(updatedAt: row.updatedAt, effectiveBlockerCount: 1, deferElapsed: true),
        ]), now: now)
        #expect(out.nags.count == 1)
    }

    // MARK: - 5. Scope

    @Test func itemScopeNagsOnlyThatItem() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let old = now.addingTimeInterval(-9 * 86_400)
        let a = item(handle: "desk_a", alias: "1", title: "the one User cares about", updatedAt: old)
        let b = item(handle: "desk_b", alias: "2", title: "the other one", updatedAt: old)
        let baseline = DeskNagObservation(updatedAt: a.updatedAt, effectiveBlockerCount: 1, deferElapsed: true)
        let config = DeskNagConfig(
            enabled: true,
            scopes: [DeskNagScope(kind: .item, id: "desk_a", enabled: true)],
            observed: ["desk_a": baseline, "desk_b": baseline]
        )
        let out = evaluate([a, b], config: config, now: now)
        #expect(out.nags.count == 1)
        #expect(out.nags[0].handle == "desk_a")
        #expect(out.updatedConfig.observed["desk_b"] == baseline, "an out-of-scope item is not even observed")
    }

    /// STATE LIFECYCLE, keyed on PRESENCE IN STATE rather than on status
    /// (audit 2026-08-02, M1). A handle that has left the desk entirely is
    /// pruned from both maps; a handle that is merely CLOSED keeps its entries,
    /// because closing is reversible and the once-per-window cap must survive
    /// the round trip. `state.items` already excludes archived rows, so both
    /// maps stay bounded by the visible desk.
    @Test func handlesAbsentFromStateAreDroppedButClosedOnesKeepTheirLedger() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let closed = item(handle: "desk_a", alias: "1", updatedAt: now.addingTimeInterval(-9 * 86_400), status: .done)
        let config = armed(
            observed: ["desk_a": DeskNagObservation(updatedAt: closed.updatedAt, effectiveBlockerCount: 0, deferElapsed: true),
                       "desk_gone": DeskNagObservation(updatedAt: "x", effectiveBlockerCount: 0, deferElapsed: true)],
            ledger: ["desk_a": 1, "desk_gone": 1]
        )
        let out = evaluate([closed], config: config, now: now)
        #expect(out.updatedConfig.observed["desk_gone"] == nil, "gone from state ⇒ gone from the maps")
        #expect(out.updatedConfig.ledger["desk_gone"] == nil)
        #expect(out.updatedConfig.observed["desk_a"] != nil, "closed is not gone — it can be reopened")
        #expect(out.updatedConfig.ledger["desk_a"] == 1)
    }

    /// THE M1 BUG. Close and reopen an item inside ONE window and the
    /// once-per-window cap has to hold. PRE-FIX the prune keyed on
    /// `!isTerminal`, so the close wiped the ledger entry and the reopen nagged
    /// again — an unbounded ping source for a round trip User makes constantly.
    @Test func closingAndReopeningInsideOneWindowDoesNotReArmTheNag() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let stale = now.addingTimeInterval(-9 * 86_400)
        let blocked = item(handle: "desk_a", alias: "1", updatedAt: stale, blockedOn: ["desk_b"])
        let blocker = item(handle: "desk_b", alias: "2", updatedAt: stale)
        let baseline = DeskNagObservation(updatedAt: blocked.updatedAt, effectiveBlockerCount: 1, deferElapsed: true)

        // Tick 1: the blocker closes, the dependent nags — once.
        let closedBlocker = item(handle: "desk_b", alias: "2", updatedAt: stale, status: .done)
        let first = evaluate([blocked, closedBlocker], config: armed(observed: ["desk_a": baseline]), now: now)
        #expect(first.nags.count == 1)
        #expect(first.nags[0].handle == "desk_a")
        #expect(first.updatedConfig.ledger["desk_a"] == 1)

        // Tick 2: User closes the dependent. Same window.
        let closedDependent = item(handle: "desk_a", alias: "1", updatedAt: stale, status: .done, blockedOn: ["desk_b"])
        let afterClose = evaluate([closedDependent, closedBlocker], config: first.updatedConfig, now: now)
        #expect(afterClose.updatedConfig.ledger["desk_a"] == 1,
                "the cap must survive a close — this is the entry the old prune deleted")

        // Tick 3: he reopens it, and it edits — still STALE (a 5-day-old stamp)
        // so "moved while stale" is a genuine, nag-worthy delta. Same window,
        // so it must stay silent. PRE-FIX the ledger entry was gone and this
        // nagged.
        let reopened = item(handle: "desk_a", alias: "1",
                            updatedAt: now.addingTimeInterval(-5 * 86_400), blockedOn: ["desk_b"])
        let afterReopen = evaluate([reopened, closedBlocker], config: afterClose.updatedConfig, now: now)
        #expect(afterReopen.nags.isEmpty,
                "one ping per item per deliberate User action — a close/reopen cycle is not a new window")
        #expect(afterReopen.updatedConfig.ledger["desk_a"] == 1)

        // A genuine window bump — and only that — re-arms the item: same shape
        // of delta, new window, one ping.
        var bumped = afterReopen.updatedConfig
        bumped.windowId += 1
        let editedAgain = item(handle: "desk_a", alias: "1",
                               updatedAt: now.addingTimeInterval(-4 * 86_400), blockedOn: ["desk_b"])
        #expect(evaluate([editedAgain, closedBlocker], config: bumped, now: now).nags.count == 1)
    }

    // MARK: - 6. Muted: tracking continues, nothing pings, drift survives

    @Test func mutedKeepsTrackingButNeverPingsAndUnmuteReportsTheDrift() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let old = now.addingTimeInterval(-7 * 86_400)
        let drifted = item(handle: "desk_a", alias: "1", title: "notary refresh", updatedAt: old)
        let appeared = item(handle: "desk_b", alias: "2", title: "showed up mid-mute", updatedAt: old)
        let config = armed(
            observed: ["desk_a": DeskNagObservation(updatedAt: drifted.updatedAt, effectiveBlockerCount: 2, deferElapsed: true)],
            mutedUntil: DeskClock.nowISO(now.addingTimeInterval(3 * 86_400))
        )

        let out = evaluate([drifted, appeared], config: config, now: now)
        #expect(out.nags.isEmpty, "muted means quiet")
        #expect(out.digestLines.isEmpty)
        // Tracking CONTINUES: the item that appeared during the mute is now
        // baselined …
        #expect(out.updatedConfig.observed["desk_b"] != nil)
        // … while the drifted item's baseline stays FROZEN, which is the
        // evidence the unmute digest is built from.
        #expect(out.updatedConfig.observed["desk_a"]?.effectiveBlockerCount == 2)

        let st = state([drifted, appeared], now: now)
        let plan = DeskSequencing.compute(st, now: now)
        let drift = DeskNagEvaluator.digestOnUnmute(state: st, plan: plan, config: out.updatedConfig, now: now)
        #expect(drift.count == 1)
        #expect(drift[0].contains("notary refresh"))
        #expect(drift[0].contains("blockers cleared"))

        // Consuming the drift + unmuting leaves nothing to re-report.
        let consumed = DeskNagEvaluator.consumingDrift(state: st, plan: plan, config: out.updatedConfig, now: now).unmuted()
        #expect(consumed.mutedUntil == nil)
        #expect(consumed.windowId == config.windowId + 1)
        #expect(DeskNagEvaluator.digestOnUnmute(state: st, plan: plan, config: consumed, now: now).isEmpty)
        #expect(evaluate([drifted, appeared], config: consumed, now: now).nags.isEmpty,
                "what User just read in the digest must not come straight back as a nag")
    }

    /// THE UNMUTE-DRIFT BUG (audit 2026-08-02, finding 3). `consumingDrift`
    /// advances the baseline for EVERY scoped item, but the digest reported
    /// only the first 8 — so a two-week mute over 20 drifted items showed User 8
    /// and silently ate the other 12: they never nag (their delta is consumed)
    /// and never reappear in a later digest (there is no drift left).
    ///
    /// PRE-FIX: `lines.count == 8` and no trace of the other 12.
    @Test func unmuteDriftOverflowIsReportedNotSwallowed() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let old = now.addingTimeInterval(-14 * 86_400)
        // 20 items that all drifted while muted: each had a blocker, now none.
        let items = (1...20).map {
            item(handle: "desk_\($0)", alias: "\($0)", title: "drifted \($0)", updatedAt: old)
        }
        let observed = Dictionary(uniqueKeysWithValues: items.map {
            ($0.handle, DeskNagObservation(updatedAt: $0.updatedAt, effectiveBlockerCount: 2, deferElapsed: true))
        })
        let config = armed(observed: observed, mutedUntil: DeskClock.nowISO(now.addingTimeInterval(-60)))
        let st = state(items, now: now)
        let plan = DeskSequencing.compute(st, now: now)

        let lines = DeskNagEvaluator.digestOnUnmute(state: st, plan: plan, config: config, now: now)
        #expect(lines.count == DeskNagEvaluator.digestLineCap + 1, "still short: 8 lines plus one receipt")
        #expect(lines.prefix(DeskNagEvaluator.digestLineCap).allSatisfy { $0.contains("blockers cleared") })
        #expect(lines.last == DeskNagEvaluator.overflowLine(hidden: 12))
        #expect(lines.last!.contains("+12 more moved"),
                "the 12 items whose baselines consumingDrift is about to advance must be ACCOUNTED for")

        // And the consume half really does swallow all 20 — which is exactly
        // why the count above has to be told.
        let consumed = DeskNagEvaluator.consumingDrift(state: st, plan: plan, config: config, now: now).unmuted()
        #expect(DeskNagEvaluator.digestOnUnmute(state: st, plan: plan, config: consumed, now: now).isEmpty)
    }

    /// At or below the cap there is no overflow line — the receipt only appears
    /// when something was actually hidden.
    @Test func unmuteDriftAtTheCapAddsNoOverflowLine() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let old = now.addingTimeInterval(-14 * 86_400)
        let items = (1...DeskNagEvaluator.digestLineCap).map {
            item(handle: "desk_\($0)", alias: "\($0)", title: "drifted \($0)", updatedAt: old)
        }
        let observed = Dictionary(uniqueKeysWithValues: items.map {
            ($0.handle, DeskNagObservation(updatedAt: $0.updatedAt, effectiveBlockerCount: 2, deferElapsed: true))
        })
        let st = state(items, now: now)
        let plan = DeskSequencing.compute(st, now: now)
        let lines = DeskNagEvaluator.digestOnUnmute(
            state: st, plan: plan,
            config: armed(observed: observed, mutedUntil: DeskClock.nowISO(now.addingTimeInterval(-60))),
            now: now
        )
        #expect(lines.count == DeskNagEvaluator.digestLineCap)
        #expect(!lines.contains { $0.contains("more moved") })
    }

    /// The same receipt on the stale+static digest. That one DOES regenerate
    /// every tick, so nothing is lost — but a truncated list that says so beats
    /// one that doesn't, and both digests now cap the same way.
    @Test func staleDigestOverflowIsAlsoCounted() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let stale = now.addingTimeInterval(-9 * 86_400)
        let items = (1...11).map { item(handle: "desk_\($0)", alias: "\($0)", updatedAt: stale) }
        let observed = Dictionary(uniqueKeysWithValues: items.map {
            ($0.handle, DeskNagObservation(updatedAt: $0.updatedAt, effectiveBlockerCount: 0, deferElapsed: true))
        })
        let out = evaluate(items, config: armed(observed: observed), now: now)
        #expect(out.nags.isEmpty, "stale + static is digest material, never a ping")
        #expect(out.digestLines.count == DeskNagEvaluator.digestLineCap + 1)
        #expect(out.digestLines.last == DeskNagEvaluator.overflowLine(hidden: 3, describing: "stale"))
    }

    @Test func unmuteDigestNamesItemsCreatedWhileQuiet() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let fresh = item(handle: "desk_new", alias: "3", title: "born during the quiet week", updatedAt: now)
        let st = state([fresh], now: now)
        let plan = DeskSequencing.compute(st, now: now)
        let lines = DeskNagEvaluator.digestOnUnmute(state: st, plan: plan, config: armed(), now: now)
        #expect(lines.count == 1)
        #expect(lines[0].contains("new since the mute"))
    }

    // MARK: - 7. Real blocker cascade end-to-end through the store

    @Test func closingTheLastBlockerIsTheDeltaThatEarnsANag() async throws {
        let root = hermeticRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SwiftNativeDeskStore(dataRoot: root)
        let blocker = try await store.createItem(kind: .plan, project: "NativeAgent", title: "sign the build")
        let dependent = try await store.createItem(kind: .plan, project: "NativeAgent", title: "ship the build")
        _ = try await store.setBlockedOn(dependent.handle, blockers: [blocker.handle])

        // Evaluate "later": far enough out that the dependent is stale.
        let now = Date().addingTimeInterval(10 * 86_400)
        var live = try await store.liveState()
        var plan = DeskSequencing.compute(live, now: now)
        let baseline = DeskNagEvaluator.evaluate(
            state: live, plan: plan, config: armed(), now: now
        ).updatedConfig
        #expect(baseline.observed[dependent.handle]?.effectiveBlockerCount == 1)

        // Close the blocker — no cascade op; blockedness is DERIVED.
        _ = try await store.closeItem(blocker.handle, outcomeSummary: "signed", canceled: false)
        live = try await store.liveState()
        plan = DeskSequencing.compute(live, now: now)
        let out = DeskNagEvaluator.evaluate(state: live, plan: plan, config: baseline, now: now)
        #expect(out.nags.count == 1)
        #expect(out.nags[0].handle == dependent.handle)
        #expect(out.nags[0].body.contains("blockers cleared"))
    }

    // MARK: - 8. Nag-aware wake deadline (day-exact defer-elapse)

    @Test func deadlineIsNilWhenDisabledOrNothingIsAhead() {
        let now = Date()
        let parked = item(handle: "d1", alias: "1", updatedAt: now,
                          deferUntil: DeskClock.nowISO(now.addingTimeInterval(3_600)))
        var off = armed(); off.enabled = false
        #expect(DeskNagEvaluator.nextMeaningfulDeadline(
            state: state([parked], now: now), config: off, after: now) == nil)
        // Enabled, but nothing deferred and no mute → nil (no timer to arm).
        let idle = item(handle: "d2", alias: "2", updatedAt: now)
        #expect(DeskNagEvaluator.nextMeaningfulDeadline(
            state: state([idle], now: now), config: armed(), after: now) == nil)
    }

    @Test func deadlineIsTheEarliestInScopeFutureDefer() {
        let now = Date()
        let soon = now.addingTimeInterval(2 * 3_600)
        let later = now.addingTimeInterval(8 * 3_600)
        let rows = [
            item(handle: "d1", alias: "1", updatedAt: now, deferUntil: DeskClock.nowISO(later)),
            item(handle: "d2", alias: "2", updatedAt: now, deferUntil: DeskClock.nowISO(soon)),
            // Out of scope: different project, no scope entry → never wakes us.
            item(handle: "d3", alias: "3", project: "Atrium", updatedAt: now,
                 deferUntil: DeskClock.nowISO(now.addingTimeInterval(60))),
            // Elapsed park and terminal item both contribute nothing.
            item(handle: "d4", alias: "4", updatedAt: now,
                 deferUntil: DeskClock.nowISO(now.addingTimeInterval(-60))),
            item(handle: "d5", alias: "5", updatedAt: now, status: .done,
                 deferUntil: DeskClock.nowISO(soon.addingTimeInterval(-3_600))),
        ]
        let got = DeskNagEvaluator.nextMeaningfulDeadline(
            state: state(rows, now: now), config: armed(), after: now)
        #expect(got != nil)
        if let got { #expect(abs(got.timeIntervalSince(soon)) < 1.0) }
        // Strictly future, never a past date an exact-deadline owner could spin on.
        if let got { #expect(got > now) }
    }

    @Test func deadlineWhileMutedIsTheMuteEndAlone() {
        let now = Date()
        let muteEnd = now.addingTimeInterval(4 * 3_600)
        // A defer BEFORE the mute end must not wake the loop early — the
        // deadline is re-derived after the unmute wake, so nothing is lost.
        let parked = item(handle: "d1", alias: "1", updatedAt: now,
                          deferUntil: DeskClock.nowISO(now.addingTimeInterval(3_600)))
        let config = armed(mutedUntil: DeskClock.nowISO(muteEnd))
        let got = DeskNagEvaluator.nextMeaningfulDeadline(
            state: state([parked], now: now), config: config, after: now)
        #expect(got != nil)
        if let got { #expect(abs(got.timeIntervalSince(muteEnd)) < 1.0) }
    }
}
