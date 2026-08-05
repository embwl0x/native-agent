import Testing
import Foundation
@testable import PersistenceCore

// MARK: - Desk cadence learning (Wave 5)
//
// The invariants worth failing a build over:
//   1. EXPLICIT BEATS LEARNED, always. User's configured interval is not a
//      suggestion the learner gets to overrule.
//   2. THIN EVIDENCE PRODUCES NO NUMBER. Under three changes → nil, so the
//      caller keeps its own default instead of inheriting a coin flip.
//   3. CLAMPED BOTH ENDS + BACKOFF WHILE QUIET, collapsing back on a change.
//   4. UNKNOWN JSON KEYS SURVIVE A ROUND TRIP (two binaries, one file).
//   5. Every store mutation is one locked transaction — concurrent recorders
//      all land, no lost update.

@Suite("DeskCadenceLearning")
struct DeskCadenceLearningTests {

    private func hermeticRoot() -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("DeskCadence-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    private func seed(_ key: String = "ref-1") -> DeskRefObservationStat {
        DeskRefObservationStat.seed(refKey: key, at: t0)
    }

    /// Drive a fingerprint series at fixed offsets (seconds from t0).
    private func drive(
        _ stat: DeskRefObservationStat,
        _ steps: [(offset: TimeInterval, fingerprint: String)]
    ) -> DeskRefObservationStat {
        var s = stat
        for step in steps {
            s = DeskCadenceLearner.record(s, fingerprint: step.fingerprint, at: t0.addingTimeInterval(step.offset))
        }
        return s
    }

    // MARK: - EWMA

    @Test("first fingerprint is a baseline, not a change")
    func baselineIsNotAChange() {
        let s = DeskCadenceLearner.record(seed(), fingerprint: "a", at: t0.addingTimeInterval(10))
        #expect(s.observations == 1)
        #expect(s.changes == 0)
        #expect(s.ewmaChangeIntervalSec == nil)
        #expect(s.lastFingerprint == "a")
    }

    @Test("ewma seeds on the first change and converges over a series")
    func ewmaSeedsAndConverges() {
        // Baseline, then changes every 3600s.
        var steps: [(TimeInterval, String)] = [(0, "f0")]
        for i in 1...8 { steps.append((TimeInterval(i) * 3600, "f\(i)")) }
        var s = seed()

        // After the FIRST change the ewma is exactly that interval (seeded).
        s = DeskCadenceLearner.record(s, fingerprint: "f0", at: t0)
        s = DeskCadenceLearner.record(s, fingerprint: "f1", at: t0.addingTimeInterval(3600))
        #expect(s.changes == 1)
        #expect(s.ewmaChangeIntervalSec == 3600)

        // A steady rhythm keeps it pinned; a doubled interval pulls it up by
        // roughly alpha, not all the way.
        s = DeskCadenceLearner.record(s, fingerprint: "f2", at: t0.addingTimeInterval(7200))
        #expect(s.ewmaChangeIntervalSec == 3600)
        s = DeskCadenceLearner.record(s, fingerprint: "f3", at: t0.addingTimeInterval(7200 + 7200))
        let expected = 0.3 * 7200 + 0.7 * 3600
        #expect(abs((s.ewmaChangeIntervalSec ?? 0) - expected) < 0.001)
        #expect(s.changes == 3)
        #expect(s.observations == 4)

        // Back to the 1h rhythm for several samples → converges toward 3600.
        var t: TimeInterval = 14400
        for i in 4...12 {
            t += 3600
            s = DeskCadenceLearner.record(s, fingerprint: "g\(i)", at: t0.addingTimeInterval(t))
        }
        #expect(abs((s.ewmaChangeIntervalSec ?? 0) - 3600) < 60)
    }

    @Test("repeat fingerprint is observed but is not a change")
    func repeatIsNoChange() {
        let s = drive(seed(), [(0, "a"), (600, "a"), (1200, "a")])
        #expect(s.observations == 3)
        #expect(s.changes == 0)
        #expect(DeskCadenceLearner.learnedIntervalSeconds(s) == nil)
    }

    // MARK: - Confidence floor

    @Test("fewer than 3 changes produces no guess")
    func thinEvidenceIsNil() {
        var s = drive(seed(), [(0, "a"), (3600, "b")])       // 1 change
        #expect(DeskCadenceLearner.learnedIntervalSeconds(s) == nil)
        s = DeskCadenceLearner.record(s, fingerprint: "c", at: t0.addingTimeInterval(7200))  // 2
        #expect(s.changes == 2)
        #expect(DeskCadenceLearner.learnedIntervalSeconds(s) == nil)
        #expect(DeskCadenceLearner.effectiveIntervalSeconds(s, now: t0.addingTimeInterval(999_999)) == nil)
        s = DeskCadenceLearner.record(s, fingerprint: "d", at: t0.addingTimeInterval(10_800)) // 3
        #expect(s.changes == 3)
        #expect(DeskCadenceLearner.learnedIntervalSeconds(s) != nil)
    }

    // MARK: - Clamps

    @Test("a 10-second-churn ref clamps up to the 15-minute floor")
    func clampsLow() {
        var s = seed()
        var t: TimeInterval = 0
        s = DeskCadenceLearner.record(s, fingerprint: "x0", at: t0)
        for i in 1...6 {
            t += 10
            s = DeskCadenceLearner.record(s, fingerprint: "x\(i)", at: t0.addingTimeInterval(t))
        }
        #expect((s.ewmaChangeIntervalSec ?? 0) < 60)
        #expect(DeskCadenceLearner.learnedIntervalSeconds(s) == 900)
    }

    @Test("a 90-day-rhythm ref clamps down to the 24-hour ceiling")
    func clampsHigh() {
        let day: TimeInterval = 86_400
        var s = seed()
        var t: TimeInterval = 0
        s = DeskCadenceLearner.record(s, fingerprint: "y0", at: t0)
        for i in 1...5 {
            t += 90 * day
            s = DeskCadenceLearner.record(s, fingerprint: "y\(i)", at: t0.addingTimeInterval(t))
        }
        #expect((s.ewmaChangeIntervalSec ?? 0) > 30 * day)
        #expect(DeskCadenceLearner.learnedIntervalSeconds(s) == 86_400)
        // And the backoff can never push past the ceiling either.
        let quiet = t0.addingTimeInterval(t + 400 * day)
        #expect(DeskCadenceLearner.effectiveIntervalSeconds(s, now: quiet) == 86_400)
    }

    // MARK: - Backoff

    @Test("backoff grows while quiet and resets when a change lands")
    func backoffGrowsAndResets() {
        // Steady 1h rhythm, 4 changes → learned == 1800s.
        var s = seed()
        s = DeskCadenceLearner.record(s, fingerprint: "b0", at: t0)
        var t: TimeInterval = 0
        for i in 1...4 {
            t += 3600
            s = DeskCadenceLearner.record(s, fingerprint: "b\(i)", at: t0.addingTimeInterval(t))
        }
        let learned = DeskCadenceLearner.learnedIntervalSeconds(s)
        #expect(learned == 1800)

        // Just after the change: no quiet span, so learned stands.
        #expect(DeskCadenceLearner.effectiveIntervalSeconds(s, now: t0.addingTimeInterval(t)) == 1800)
        // Quiet 2h → backoff (3600) still below... equal to learned*2, so it wins.
        let twoHoursQuiet = DeskCadenceLearner.effectiveIntervalSeconds(s, now: t0.addingTimeInterval(t + 7200))
        #expect(twoHoursQuiet == 3600)
        // Quiet 12h → 6h.
        let halfDayQuiet = DeskCadenceLearner.effectiveIntervalSeconds(s, now: t0.addingTimeInterval(t + 43_200))
        #expect(halfDayQuiet == 21_600)
        #expect((halfDayQuiet ?? 0) > (twoHoursQuiet ?? 0))

        // A change lands → quiet span collapses, interval returns to learned.
        let changeAt = t0.addingTimeInterval(t + 43_200)
        let after = DeskCadenceLearner.record(s, fingerprint: "fresh", at: changeAt)
        #expect(DeskCadenceLearner.effectiveIntervalSeconds(after, now: changeAt) == DeskCadenceLearner.learnedIntervalSeconds(after))
        #expect((DeskCadenceLearner.effectiveIntervalSeconds(after, now: changeAt) ?? 0) < (halfDayQuiet ?? 0))
    }

    // MARK: - Precedence

    @Test("explicit duration strings parse through the existing desk parser")
    func explicitParsing() {
        #expect(DeskCadenceLearner.explicitInterval("30m") == 1800)
        #expect(DeskCadenceLearner.explicitInterval("6h") == 21_600)
        #expect(DeskCadenceLearner.explicitInterval("2d") == 172_800)
        #expect(DeskCadenceLearner.explicitInterval(" 45m ") == 2700)
        #expect(DeskCadenceLearner.explicitInterval(nil) == nil)
        #expect(DeskCadenceLearner.explicitInterval("") == nil)
        #expect(DeskCadenceLearner.explicitInterval("soon") == nil)
    }

    @Test("explicit always beats learned; learned beats fallback; fallback only when both absent")
    func precedence() {
        var s = seed()
        s = DeskCadenceLearner.record(s, fingerprint: "p0", at: t0)
        var t: TimeInterval = 0
        for i in 1...4 {
            t += 3600
            s = DeskCadenceLearner.record(s, fingerprint: "p\(i)", at: t0.addingTimeInterval(t))
        }
        let now = t0.addingTimeInterval(t)
        #expect(DeskCadenceLearner.learnedIntervalSeconds(s) == 1800)

        // Explicit present AND a confident learned interval → explicit wins.
        let explicit = DeskCadenceLearner.resolvedIntervalSeconds(explicit: "6h", stat: s, now: now, fallbackSeconds: 300)
        #expect(explicit.seconds == 21_600)
        #expect(explicit.source == .explicit)

        // Empty/blank explicit is NOT a configuration.
        let blank = DeskCadenceLearner.resolvedIntervalSeconds(explicit: "   ", stat: s, now: now, fallbackSeconds: 300)
        #expect(blank.source == .learned)
        #expect(blank.seconds == 1800)

        // No explicit → learned.
        let learned = DeskCadenceLearner.resolvedIntervalSeconds(explicit: nil, stat: s, now: now, fallbackSeconds: 300)
        #expect(learned.seconds == 1800)
        #expect(learned.source == .learned)

        // Neither → fallback, and the fallback is the caller's number verbatim.
        let noStat = DeskCadenceLearner.resolvedIntervalSeconds(explicit: nil, stat: nil, now: now, fallbackSeconds: 4242)
        #expect(noStat.seconds == 4242)
        #expect(noStat.source == .fallback)

        // A stat too thin to learn from is also fallback, never a guess.
        let thin = drive(seed(), [(0, "a"), (60, "b")])
        let thinResolved = DeskCadenceLearner.resolvedIntervalSeconds(explicit: nil, stat: thin, now: now, fallbackSeconds: 4242)
        #expect(thinResolved.seconds == 4242)
        #expect(thinResolved.source == .fallback)

        // Explicit wins even with NO stat at all.
        let explicitOnly = DeskCadenceLearner.resolvedIntervalSeconds(explicit: "30m", stat: nil, now: now, fallbackSeconds: 4242)
        #expect(explicitOnly.seconds == 1800)
        #expect(explicitOnly.source == .explicit)
    }

    // MARK: - Wire

    @Test("JSON round trip preserves unknown fields verbatim")
    func unknownFieldsSurvive() {
        let raw = JSONValue.object([
            "refKey": .string("gh:project/7"),
            "firstObservedAt": .string(DeskClock.nowISO(t0)),
            "lastObservedAt": .string(DeskClock.nowISO(t0.addingTimeInterval(60))),
            "lastChangeAt": .string(DeskClock.nowISO(t0.addingTimeInterval(30))),
            "observations": .int(9),
            "changes": .int(4),
            "ewmaChangeIntervalSec": .double(1234.5),
            "lastFingerprint": .string("sha-abc"),
            // Written by a NEWER binary this one has never heard of:
            "confidenceModel": .string("bayesian-v2"),
            "sampleWindow": .object(["days": .int(30)]),
        ])
        let decoded = DeskRefObservationStat.fromJSON(raw)
        #expect(decoded != nil)
        let stat = decoded!
        #expect(stat.refKey == "gh:project/7")
        #expect(stat.observations == 9)
        #expect(stat.changes == 4)
        #expect(stat.ewmaChangeIntervalSec == 1234.5)
        #expect(stat.unknownFields["confidenceModel"] == .string("bayesian-v2"))
        #expect(stat.unknownFields["sampleWindow"] == .object(["days": .int(30)]))

        // Re-emit: unknown keys are still there, known keys unchanged.
        guard case .object(let out) = stat.toJSON() else {
            Issue.record("toJSON did not produce an object")
            return
        }
        #expect(out["confidenceModel"] == .string("bayesian-v2"))
        #expect(out["sampleWindow"] == .object(["days": .int(30)]))
        #expect(out["refKey"] == .string("gh:project/7"))

        // And a full re-decode is identical — a mutation cycle can't drop them.
        #expect(DeskRefObservationStat.fromJSON(stat.toJSON()) == stat)

        // Even after the learner mutates the row.
        let recorded = DeskCadenceLearner.record(stat, fingerprint: "sha-def", at: t0.addingTimeInterval(600))
        #expect(recorded.unknownFields["confidenceModel"] == .string("bayesian-v2"))
        #expect(DeskRefObservationStat.fromJSON(recorded.toJSON())?.unknownFields.count == 2)
    }

    @Test("container round-trips and a corrupt/missing payload decodes to empty")
    func containerDecode() {
        let stats = DeskCadenceStats(refs: ["a": drive(seed("a"), [(0, "x"), (60, "y")])])
        #expect(DeskCadenceStats.fromJSON(stats.toJSON()) == stats)
        #expect(DeskCadenceStats.fromJSON(.null).refs.isEmpty)
        #expect(DeskCadenceStats.fromJSON(.string("garbage")).refs.isEmpty)
        #expect(DeskCadenceStats.fromJSON(.object(["refs": .array([])])).refs.isEmpty)
        // A single malformed row drops that ROW, not the file.
        let mixed = JSONValue.object(["refs": .object([
            "good": stats.refs["a"]!.toJSON(),
            "bad": .string("nope"),
        ])])
        #expect(DeskCadenceStats.fromJSON(mixed).refs.count == 1)
    }

    // MARK: - Store

    @Test("store round-trips through a temp dataRoot; missing file loads empty")
    func storeRoundTrip() async throws {
        let root = hermeticRoot()
        let store = DeskCadenceStore(dataRoot: root)
        #expect(await store.load().refs.isEmpty)   // no file yet

        _ = try await store.recordObservation(refKey: "r1", fingerprint: "f0", at: t0)
        let second = try await store.recordObservation(refKey: "r1", fingerprint: "f1", at: t0.addingTimeInterval(3600))
        #expect(second.changes == 1)
        #expect(second.observations == 2)

        // A fresh store instance reads the same bytes back off disk.
        let reopened = DeskCadenceStore(dataRoot: root)
        let loaded = await reopened.load()
        #expect(loaded.refs["r1"]?.changes == 1)
        #expect(loaded.refs["r1"]?.ewmaChangeIntervalSec == 3600)

        // resolvedInterval reads through the store and honours explicit.
        let viaStore = await reopened.resolvedInterval(refKey: "r1", explicit: "6h", now: t0, fallbackSeconds: 300)
        #expect(viaStore.source == .explicit)
        let fallback = await reopened.resolvedInterval(refKey: "unknown-ref", explicit: nil, now: t0, fallbackSeconds: 300)
        #expect(fallback.source == .fallback)
        #expect(fallback.seconds == 300)
    }

    @Test("concurrent recordObservation calls all land — no lost update")
    func concurrentRecordsAllLand() async throws {
        let root = hermeticRoot()
        let store = DeskCadenceStore(dataRoot: root)

        // Distinct refs written concurrently: every row must exist.
        await withTaskGroup(of: Void.self) { group in
            for i in 0..<16 {
                group.addTask {
                    _ = try? await store.recordObservation(refKey: "ref-\(i)", fingerprint: "f-\(i)", at: self.t0)
                }
            }
        }
        let byRef = await store.load()
        #expect(byRef.refs.count == 16)

        // Same ref hammered concurrently: every observation must be counted.
        await withTaskGroup(of: Void.self) { group in
            for i in 0..<16 {
                group.addTask {
                    _ = try? await store.recordObservation(
                        refKey: "hot",
                        fingerprint: "fp-\(i)",
                        at: self.t0.addingTimeInterval(TimeInterval(i))
                    )
                }
            }
        }
        let hot = await store.load().refs["hot"]
        #expect(hot?.observations == 16)
        #expect(byRef.refs.count == 16)
    }

    // MARK: - Batch interval (what an actual poller consumes)

    /// A ref with a confident, well-understood rhythm: changes every `every`
    /// seconds, observed right at the last change so quiet-backoff is zero.
    private func confident(_ key: String, every: TimeInterval) -> DeskRefObservationStat {
        var steps: [(TimeInterval, String)] = [(0, "f0")]
        for i in 1...5 { steps.append((TimeInterval(i) * every, "f\(i)")) }
        return drive(seed(key), steps.map { (offset: $0.0, fingerprint: $0.1) })
    }

    /// `now` = the moment of the last change, so no quiet-backoff is in play.
    private func atLastChange(_ stat: DeskRefObservationStat) -> Date {
        DeskClock.parseISO(stat.lastChangeAt) ?? t0
    }

    @Test("an all-understood batch stretches to its SOONEST-due ref")
    func batchStretchesToSoonestRef() {
        // 4h rhythm → 2h poll; 10h rhythm → 5h poll. The batch must follow the 2h
        // one, or the faster ref goes unwatched for hours.
        let fast = confident("fast", every: 4 * 3600)
        let slow = confident("slow", every: 10 * 3600)
        let now = atLastChange(fast)
        let stats = DeskCadenceStats(refs: ["fast": fast, "slow": slow])
        let due = DeskCadenceLearner.batchIntervalSeconds(
            refKeys: ["fast", "slow"], stats: stats, configuredSeconds: 900, now: now
        )
        #expect(due == DeskCadenceLearner.effectiveIntervalSeconds(fast, now: now))
        #expect(due > 900, "learning is allowed to stretch past the configured floor")
    }

    @Test("ONE unlearned ref pins the whole batch to the configured rate")
    func partialKnowledgeStretchesNothing() {
        let known = confident("known", every: 12 * 3600)
        let now = atLastChange(known)
        // "thin" exists but has only a baseline — no confident interval.
        let thin = DeskCadenceLearner.record(seed("thin"), fingerprint: "a", at: now)
        let stats = DeskCadenceStats(refs: ["known": known, "thin": thin])
        #expect(DeskCadenceLearner.batchIntervalSeconds(
            refKeys: ["known", "thin"], stats: stats, configuredSeconds: 900, now: now
        ) == 900)
        // A ref with NO row at all is the same verdict: unknown is not quiet.
        #expect(DeskCadenceLearner.batchIntervalSeconds(
            refKeys: ["known", "never-seen"], stats: stats, configuredSeconds: 900, now: now
        ) == 900)
    }

    @Test("the configured interval is a FLOOR — learning never polls harder")
    func configuredIntervalIsAFloor() {
        // 40m rhythm → 20m poll, which is FASTER than a 6h configured interval.
        let brisk = confident("brisk", every: 40 * 60)
        let now = atLastChange(brisk)
        let learned = DeskCadenceLearner.effectiveIntervalSeconds(brisk, now: now)
        #expect(learned != nil && learned! < 6 * 3600)
        #expect(DeskCadenceLearner.batchIntervalSeconds(
            refKeys: ["brisk"], stats: DeskCadenceStats(refs: ["brisk": brisk]),
            configuredSeconds: 6 * 3600, now: now
        ) == 6 * 3600)
    }

    @Test("an empty batch is not evidence of quiet")
    func emptyBatchKeepsConfigured() {
        #expect(DeskCadenceLearner.batchIntervalSeconds(
            refKeys: [], stats: DeskCadenceStats(), configuredSeconds: 900, now: t0
        ) == 900)
    }

    @Test("a batch that has gone quiet stretches further, and collapses on a change")
    func batchFollowsQuietBackoffBothWays() {
        let ref = confident("ref", every: 2 * 3600)     // 2h rhythm → 1h poll
        let atChange = atLastChange(ref)
        let stats = DeskCadenceStats(refs: ["ref": ref])
        let busy = DeskCadenceLearner.batchIntervalSeconds(
            refKeys: ["ref"], stats: stats, configuredSeconds: 900, now: atChange
        )
        // Two days of silence later the same row must be polled less often.
        let quiet = DeskCadenceLearner.batchIntervalSeconds(
            refKeys: ["ref"], stats: stats, configuredSeconds: 900,
            now: atChange.addingTimeInterval(48 * 3600)
        )
        #expect(quiet > busy)
        // A change lands: the backoff is gone on the very next resolution.
        let moved = DeskCadenceLearner.record(ref, fingerprint: "moved",
                                              at: atChange.addingTimeInterval(48 * 3600))
        let collapsed = DeskCadenceLearner.batchIntervalSeconds(
            refKeys: ["ref"], stats: DeskCadenceStats(refs: ["ref": moved]),
            configuredSeconds: 900, now: atChange.addingTimeInterval(48 * 3600)
        )
        #expect(collapsed < quiet)
    }
}
