import Foundation
import Testing
import PersistenceCore
import GRDB
@testable import CognitiveSubstrate

// Wave D — overnight emotional consolidation (gentle, arousal-only). Proves:
//  (1) a STALE high-arousal felt node's arousal softens (×0.7) while valence + warmth +
//      summary stay byte-identical; a RECURRED felt node's arousal rises slightly (same
//      untouched-axes guarantee); a neutral/legacy (0,0,0) node is fully untouched;
//  (2) the exact maintenance projection runs the sweep at most once per ~20h,
//      creates no five-minute checkpoints, and becomes due at the boundary;
//  (3) the gate survives restart (a new substrate over the same store does NOT re-sweep
//      within 20h);
//  (4) a nonzero sweep records a timeline event; a zero-count sweep records the receipt
//      (cadence stays observable) but NO timeline event (no noise in her timeline);
//  (5) the felt gate asymmetry — a recurred non-felt charge is NOT reinforced, but a
//      stale charge IS calmed regardless of felt direction.
@Suite("OvernightConsolidation")
struct OvernightConsolidationTests {

    /// Advanceable clock so cadence-gate tests can move time deterministically.
    private final class Clock: @unchecked Sendable {
        private let lock = NSLock(); private var t: Date
        init(_ t: Date) { self.t = t }
        func now() -> Date { lock.lock(); defer { lock.unlock() }; return t }
        func advance(_ interval: TimeInterval) { lock.lock(); t = t.addingTimeInterval(interval); lock.unlock() }
    }

    private func config() -> CognitiveConfiguration {
        CognitiveConfiguration(
            enabled: true,
            persistenceEnabled: true,
            workspaceEnabled: true,
            capsuleInjectionEnabled: true,
            affectEnabled: true,
            maximumActiveNodes: 256
        )
    }

    private func tempDataRoot(_ label: String) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("nativeagent-overnight-\(label)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    /// A node with an EXACT emotional tag and controllable activation recency. A large
    /// decay half-life keeps activation stable across the (sometimes large) age gaps so
    /// only the emotional axes are under test.
    private func node(
        summary: String,
        kind: CognitiveNodeKind = .conversationFocus,
        valence: Double,
        arousal: Double,
        warmth: Double,
        lastActivatedAt: Date,
        metadata: [String: JSONValue] = [:]
    ) -> CognitiveNode {
        CognitiveNode(
            id: UUID(), kind: kind,
            subjectReference: CognitiveSubjectReference(type: "topic", id: "overnight-\(UUID().uuidString)", label: "topic"),
            activation: 0.9, salience: 0.9, confidence: 0.8, sourceClass: .userStated,
            createdAt: lastActivatedAt, lastActivatedAt: lastActivatedAt,
            decayHalfLife: 1_000_000_000, summary: summary, metadata: metadata,
            emotionalValence: valence, emotionalArousal: arousal, emotionalWarmth: warmth)
    }

    private func makeStore(_ label: String) throws -> (CognitiveSQLiteStore, URL) {
        let root = try tempDataRoot(label)
        return (try CognitiveSQLiteStore(dataRoot: root), root)
    }

    private func substrate(store: CognitiveSQLiteStore, clock: Clock) -> CognitiveSubstrate {
        CognitiveSubstrate(
            configuration: config(),
            dependencies: CognitiveSubstrateDependencies(now: { clock.now() }, makeUUID: { UUID() }),
            store: store
        )
    }

    private func consolidationReceiptCount(_ s: CognitiveSubstrate) async -> Int {
        (await s.receiptSnapshot(limit: 80)).filter { $0.kind == "emotional_consolidation" }.count
    }

    private func maintenanceReceiptCount(_ s: CognitiveSubstrate) async -> Int {
        (await s.receiptSnapshot(limit: 80)).filter { $0.kind == "maintenance" }.count
    }

    // MARK: - (1) arousal-only sweep semantics

    /// Stale (>48h) high-arousal felt node → arousal ×0.7; valence, warmth and summary
    /// byte-identical (she wakes lighter, not blanker).
    @Test func staleFeltNodeCalmsArousalOnly() async throws {
        let now = Date(timeIntervalSince1970: 10_000_000)
        let clock = Clock(now)
        let (store, _) = try makeStore("stale-calm")
        let stale = node(summary: "the incident", valence: -0.6, arousal: 0.8, warmth: 0.1,
                         lastActivatedAt: now.addingTimeInterval(-50 * 60 * 60))
        try await store.saveNodes([stale], at: now)
        let s = substrate(store: store, clock: clock)
        try await s.restorePersistentState()

        await s.runMaintenance(reason: "test")
        let after = try #require(await s.snapshot().nodes.first { $0.summary == "the incident" })
        #expect(abs(after.emotionalArousal - 0.8 * 0.7) < 1e-9, "stale arousal must soften ×0.7: \(after.emotionalArousal)")
        #expect(after.emotionalValence == -0.6, "valence must be untouched: \(after.emotionalValence)")
        #expect(after.emotionalWarmth == 0.1, "warmth must be untouched: \(after.emotionalWarmth)")
        #expect(after.summary == "the incident", "summary must be untouched")
    }

    /// Metadata survives both sweep branches byte-identical — the empty-metadata
    /// fixtures elsewhere can't prove this. Use live circulation/routing metadata,
    /// not the retired LLM-authored cue lane.
    @Test func sweepPreservesNodeMetadata() async throws {
        let now = Date(timeIntervalSince1970: 16_000_000)
        let clock = Clock(now)
        let (store, _) = try makeStore("metadata")
        let meta: [String: JSONValue] = [
            "memoryRecordIds": .array([.string("memory-1")]),
            "sessionId": .string("session-1"),
        ]
        let stale = node(summary: "stale-with-meta", valence: -0.6, arousal: 0.8, warmth: 0.1,
                         lastActivatedAt: now.addingTimeInterval(-50 * 60 * 60), metadata: meta)
        let recurred = node(summary: "recurred-with-meta", valence: 0.5, arousal: 0.4, warmth: 0.6,
                            lastActivatedAt: now.addingTimeInterval(-1 * 60 * 60), metadata: meta)
        try await store.saveNodes([stale, recurred], at: now)
        let s = substrate(store: store, clock: clock)
        try await s.restorePersistentState()

        await s.runMaintenance(reason: "test")
        for summary in ["stale-with-meta", "recurred-with-meta"] {
            let after = try #require(await s.snapshot().nodes.first { $0.summary == summary })
            #expect(after.metadata["memoryRecordIds"] == meta["memoryRecordIds"],
                    "\(summary): metadata must survive the sweep")
            #expect(after.metadata["sessionId"] == meta["sessionId"])
        }
    }

    /// Window boundaries + future clock, pinning the shipped semantics exactly:
    /// age == 24h reinforces (inclusive), age == 48h is dead-zone (exclusive), and a
    /// future-dated lastActivatedAt (clock skew) is untouched by BOTH branches.
    @Test func windowBoundariesAndFutureClockPinned() async throws {
        let now = Date(timeIntervalSince1970: 17_000_000)
        let clock = Clock(now)
        let (store, _) = try makeStore("boundaries")
        let at24h = node(summary: "exactly-24h", valence: 0.5, arousal: 0.4, warmth: 0.6,
                         lastActivatedAt: now.addingTimeInterval(-24 * 60 * 60))
        let at48h = node(summary: "exactly-48h", valence: 0.5, arousal: 0.8, warmth: 0.6,
                         lastActivatedAt: now.addingTimeInterval(-48 * 60 * 60))
        let future = node(summary: "future-skew", valence: 0.5, arousal: 0.8, warmth: 0.6,
                          lastActivatedAt: now.addingTimeInterval(60 * 60))
        try await store.saveNodes([at24h, at48h, future], at: now)
        let s = substrate(store: store, clock: clock)
        try await s.restorePersistentState()

        await s.runMaintenance(reason: "test")
        let after24 = try #require(await s.snapshot().nodes.first { $0.summary == "exactly-24h" })
        #expect(abs(after24.emotionalArousal - (0.4 + 0.05 * 0.6)) < 1e-9,
                "age == 24h is inside the recurred window (inclusive): \(after24.emotionalArousal)")
        let after48 = try #require(await s.snapshot().nodes.first { $0.summary == "exactly-48h" })
        #expect(after48.emotionalArousal == 0.8,
                "age == 48h is dead-zone (stale is strictly >48h): \(after48.emotionalArousal)")
        let afterFuture = try #require(await s.snapshot().nodes.first { $0.summary == "future-skew" })
        #expect(afterFuture.emotionalArousal == 0.8,
                "future lastActivatedAt must be untouched by both branches: \(afterFuture.emotionalArousal)")
    }

    /// Recurred (<24h) felt node with arousal > 0 → arousal rises by 0.05·(1−arousal);
    /// valence + warmth untouched.
    @Test func recurredFeltNodeReinforcesArousalOnly() async throws {
        let now = Date(timeIntervalSince1970: 11_000_000)
        let clock = Clock(now)
        let (store, _) = try makeStore("recurred")
        let recurred = node(summary: "the good thread", valence: 0.5, arousal: 0.4, warmth: 0.6,
                            lastActivatedAt: now.addingTimeInterval(-2 * 60 * 60))
        try await store.saveNodes([recurred], at: now)
        let s = substrate(store: store, clock: clock)
        try await s.restorePersistentState()

        await s.runMaintenance(reason: "test")
        let after = try #require(await s.snapshot().nodes.first { $0.summary == "the good thread" })
        let expected = 0.4 + 0.05 * (1 - 0.4)
        #expect(abs(after.emotionalArousal - expected) < 1e-9, "recurred arousal must rise slightly: \(after.emotionalArousal)")
        #expect(after.emotionalArousal > 0.4, "arousal should have risen")
        #expect(after.emotionalValence == 0.5, "valence untouched")
        #expect(after.emotionalWarmth == 0.6, "warmth untouched")
    }

    /// Neutral legacy node (0,0,0) → fully untouched, whether recurred or stale.
    @Test func neutralLegacyNodeFullyUntouched() async throws {
        let now = Date(timeIntervalSince1970: 12_000_000)
        let clock = Clock(now)
        let (store, _) = try makeStore("legacy")
        let recentLegacy = node(summary: "legacy-recent", valence: 0, arousal: 0, warmth: 0,
                                lastActivatedAt: now.addingTimeInterval(-1 * 60 * 60))
        let staleLegacy = node(summary: "legacy-stale", valence: 0, arousal: 0, warmth: 0,
                               lastActivatedAt: now.addingTimeInterval(-60 * 60 * 60))
        try await store.saveNodes([recentLegacy, staleLegacy], at: now)
        let s = substrate(store: store, clock: clock)
        try await s.restorePersistentState()

        await s.runMaintenance(reason: "test")
        for name in ["legacy-recent", "legacy-stale"] {
            let n = try #require(await s.snapshot().nodes.first { $0.summary == name })
            #expect(n.emotionalValence == 0 && n.emotionalArousal == 0 && n.emotionalWarmth == 0,
                    "legacy node \(name) must stay (0,0,0): (\(n.emotionalValence),\(n.emotionalArousal),\(n.emotionalWarmth))")
        }
    }

    // MARK: - (2) cadence gate

    @Test func maintenanceProjectionSkipsFiveMinuteCheckpointAndFiresAtExactBoundary() async throws {
        let now = Date(timeIntervalSince1970: 12_500_000)
        let clock = Clock(now)
        let (store, _) = try makeStore("exact-maintenance")
        let s = substrate(store: store, clock: clock)
        try await s.restorePersistentState()

        let initial = await s.maintenanceOpportunity()
        #expect(initial.isDue)
        #expect(initial.dueReasons == ["emotional_consolidation"])
        #expect(initial.nextMaintenanceAt == now)
        #expect(try await s.runMaintenanceChecked(reason: "initial"))
        #expect(await maintenanceReceiptCount(s) == 1)

        let projected = await s.maintenanceOpportunity()
        let expectedDeadline = now.addingTimeInterval(20 * 60 * 60)
        #expect(!projected.isDue)
        #expect(projected.nextMaintenanceAt == expectedDeadline)

        clock.advance(5 * 60)
        #expect(try await s.runMaintenanceChecked(reason: "old-five-minute-heartbeat") == false)
        #expect(await maintenanceReceiptCount(s) == 1)
        #expect(await s.maintenanceOpportunity().nextMaintenanceAt == expectedDeadline)

        clock.advance(20 * 60 * 60 - 5 * 60)
        let due = await s.maintenanceOpportunity()
        #expect(due.isDue)
        #expect(due.dueReasons == ["emotional_consolidation"])
        #expect(try await s.runMaintenanceChecked(reason: "exact-deadline"))
        #expect(await maintenanceReceiptCount(s) == 2)
    }

    /// Two runMaintenance calls in the same hour → the sweep runs ONCE; advancing past 20h
    /// → it runs again. Proven by the emotional_consolidation receipt count.
    @Test func cadenceGateRunsOncePerWindow() async throws {
        let now = Date(timeIntervalSince1970: 13_000_000)
        let clock = Clock(now)
        let (store, _) = try makeStore("cadence")
        let n = node(summary: "charged", valence: 0.4, arousal: 0.5, warmth: 0.4,
                     lastActivatedAt: now.addingTimeInterval(-1 * 60 * 60))
        try await store.saveNodes([n], at: now)
        let s = substrate(store: store, clock: clock)
        try await s.restorePersistentState()

        await s.runMaintenance(reason: "first")
        clock.advance(30 * 60) // +30 min, well within 20h
        await s.runMaintenance(reason: "second-same-window")
        #expect(await consolidationReceiptCount(s) == 1, "sweep must run once within the 20h window")

        clock.advance(21 * 60 * 60) // cross the 20h gate
        await s.runMaintenance(reason: "third-next-window")
        #expect(await consolidationReceiptCount(s) == 2, "sweep must run again after 20h")
    }

    // MARK: - (3) restart survival

    /// After a consolidation, a NEW substrate over the same store restores the gate and does
    /// NOT re-sweep within 20h — and the once-softened arousal is not softened a second time.
    @Test func gateSurvivesRestart() async throws {
        let now = Date(timeIntervalSince1970: 14_000_000)
        let clock = Clock(now)
        let (store, _) = try makeStore("restart")
        let stale = node(summary: "old charge", valence: -0.5, arousal: 0.8, warmth: 0.1,
                         lastActivatedAt: now.addingTimeInterval(-50 * 60 * 60))
        try await store.saveNodes([stale], at: now)

        let first = substrate(store: store, clock: clock)
        try await first.restorePersistentState()
        await first.runMaintenance(reason: "first-run")
        let afterFirst = try #require(await first.snapshot().nodes.first { $0.summary == "old charge" })
        let calmedOnce = afterFirst.emotionalArousal
        #expect(abs(calmedOnce - 0.8 * 0.7) < 1e-9)

        // Restart: new substrate, same store, clock only 2h later (still inside 20h).
        clock.advance(2 * 60 * 60)
        let second = substrate(store: store, clock: clock)
        try await second.restorePersistentState()
        await second.runMaintenance(reason: "post-restart-within-window")
        let afterRestart = try #require(await second.snapshot().nodes.first { $0.summary == "old charge" })
        #expect(abs(afterRestart.emotionalArousal - calmedOnce) < 1e-9,
                "gate must block a second sweep within 20h: \(afterRestart.emotionalArousal) vs \(calmedOnce)")
        // No NEW emotional_consolidation receipt from the restarted substrate this window.
        #expect(await consolidationReceiptCount(second) == 1, "restart must not re-sweep within the window")
    }

    // MARK: - (4) timeline observability

    /// A sweep that changes nothing (only 24–48h-band + neutral nodes) records the receipt
    /// (cadence stays observable) but NO timeline event (no noise in her timeline).
    @Test func zeroCountSweepRecordsReceiptButNoTimeline() async throws {
        let now = Date(timeIntervalSince1970: 15_000_000)
        let clock = Clock(now)
        let (store, _) = try makeStore("zero-count")
        // 36h-old felt node sits in the dead band (>24h, <48h) → neither reinforced nor calmed.
        let deadBand = node(summary: "in-between", valence: 0.5, arousal: 0.7, warmth: 0.5,
                            lastActivatedAt: now.addingTimeInterval(-36 * 60 * 60))
        let legacy = node(summary: "legacy", valence: 0, arousal: 0, warmth: 0,
                          lastActivatedAt: now.addingTimeInterval(-1 * 60 * 60))
        try await store.saveNodes([deadBand, legacy], at: now)
        let s = substrate(store: store, clock: clock)
        try await s.restorePersistentState()

        await s.runMaintenance(reason: "quiet")
        // Receipt present with zero counts.
        let receipts = (await s.receiptSnapshot(limit: 80)).filter { $0.kind == "emotional_consolidation" }
        #expect(receipts.count == 1, "cadence tick must record a receipt even with zero changes")
        if case .object(let payload)? = receipts.first?.payload {
            #expect(payload["reinforced"] == .int(0))
            #expect(payload["calmed"] == .int(0))
        } else {
            Issue.record("missing receipt payload")
        }
        // No timeline event for a zero-count sweep.
        let timeline = await s.developmentalTimelineSnapshot()
        #expect(timeline.allSatisfy { $0.title != "Overnight emotional consolidation" },
                "zero-count sweep must not record a timeline event")
    }

    /// A nonzero sweep records a developmental-timeline event titled "Overnight emotional
    /// consolidation" with the softened/sustained counts in its summary.
    @Test func nonzeroSweepRecordsTimelineEvent() async throws {
        let now = Date(timeIntervalSince1970: 16_000_000)
        let clock = Clock(now)
        let (store, _) = try makeStore("nonzero")
        let stale = node(summary: "old sting", valence: -0.6, arousal: 0.9, warmth: 0.1,
                         lastActivatedAt: now.addingTimeInterval(-50 * 60 * 60))
        let recurred = node(summary: "fresh warmth", valence: 0.5, arousal: 0.3, warmth: 0.6,
                            lastActivatedAt: now.addingTimeInterval(-1 * 60 * 60))
        try await store.saveNodes([stale, recurred], at: now)
        let s = substrate(store: store, clock: clock)
        try await s.restorePersistentState()

        await s.runMaintenance(reason: "overnight")
        let timeline = await s.developmentalTimelineSnapshot()
        let event = try #require(timeline.first { $0.title == "Overnight emotional consolidation" },
                                 "nonzero sweep must record a timeline event: \(timeline.map(\.title))")
        #expect(event.kind == .replayRun)
        // The summary carries counts + a per-run date stamp — the timeline event ID
        // seeds on the summary, so the stamp is what keeps two nights with identical
        // counts from collapsing into one upserted event.
        #expect(event.summary.hasPrefix("softened 1, sustained 1 · "),
                "summary must carry the counts + per-run stamp: \(event.summary)")
    }

    /// Two sweeps with IDENTICAL counts on different days must produce two distinct
    /// timeline events (the per-run stamp in the summary is the identity token).
    @Test func identicalCountSweepsOnDifferentDaysKeepDistinctTimelineEvents() async throws {
        let now = Date(timeIntervalSince1970: 18_000_000)
        let clock = Clock(now)
        let (store, _) = try makeStore("distinct-nights")
        // One stale felt node: each sweep calms it once (identical counts both nights).
        let stale = node(summary: "recurring sting", valence: -0.6, arousal: 0.9, warmth: 0.1,
                         lastActivatedAt: now.addingTimeInterval(-50 * 60 * 60))
        try await store.saveNodes([stale], at: now)
        let s = substrate(store: store, clock: clock)
        try await s.restorePersistentState()

        await s.runMaintenance(reason: "night one")
        clock.advance(21 * 60 * 60)
        await s.runMaintenance(reason: "night two")

        let events = (await s.developmentalTimelineSnapshot())
            .filter { $0.title == "Overnight emotional consolidation" }
        #expect(events.count == 2,
                "two nights with identical counts must keep two events: \(events.map(\.summary))")
    }

    // MARK: - (5) felt-gate asymmetry

    /// A RECURRED node with real charge but no felt DIRECTION (arousal 0.5, valence 0,
    /// warmth 0 → below every feltDirection threshold) is NOT reinforced; the SAME node when
    /// STALE IS calmed (the calm branch gates on charge, not felt direction).
    @Test func feltGateAsymmetryRecurredVsStale() async throws {
        let now = Date(timeIntervalSince1970: 17_000_000)
        let clock = Clock(now)
        let (store, _) = try makeStore("felt-gate")
        let recurredNonFelt = node(summary: "recurred-nonfelt", valence: 0, arousal: 0.5, warmth: 0,
                                   lastActivatedAt: now.addingTimeInterval(-2 * 60 * 60))
        let staleNonFelt = node(summary: "stale-nonfelt", valence: 0, arousal: 0.5, warmth: 0,
                                lastActivatedAt: now.addingTimeInterval(-50 * 60 * 60))
        try await store.saveNodes([recurredNonFelt, staleNonFelt], at: now)
        let s = substrate(store: store, clock: clock)
        try await s.restorePersistentState()

        await s.runMaintenance(reason: "test")
        let recurredAfter = try #require(await s.snapshot().nodes.first { $0.summary == "recurred-nonfelt" })
        let staleAfter = try #require(await s.snapshot().nodes.first { $0.summary == "stale-nonfelt" })
        #expect(recurredAfter.emotionalArousal == 0.5, "recurred non-felt node must NOT be reinforced: \(recurredAfter.emotionalArousal)")
        #expect(abs(staleAfter.emotionalArousal - 0.5 * 0.7) < 1e-9, "stale charge must be calmed regardless of felt direction: \(staleAfter.emotionalArousal)")
    }
}
