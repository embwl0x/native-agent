import Foundation
import GRDB
import Testing
@testable import CognitiveSubstrate

/// Round 3 Wave A2: notable resolutions become FELT events — relief when a
/// braced expectation lands fine, earned disappointment when a counted-on
/// one falls through. Mild outcomes stay chemistry-only; retry storms are
/// rate-bounded per path kind.
@Suite("Organism resolution felt events")
struct OrganismResolutionFeltTests {
    private let t0 = Date(timeIntervalSince1970: 3_000_000)

    private func signal(_ kind: SomaticSignalKind, at: Date, organ: String = "tool:swift_build") -> SomaticSignal {
        SomaticSignal(id: UUID(), kind: kind, sourceOrgan: organ, occurredAt: at, intensity: 0.8)
    }

    /// Ledgers before/after a resolving pass over one tuned pending row.
    private func resolvedLedgers(
        toolPath: Double,
        confidence: Double,
        uncertainty: Double,
        outcome: SomaticSignalKind,
        recentViolation: Bool = false
    ) -> (before: OrganismPredictionLedger, after: OrganismPredictionLedger, at: Date) {
        var ledger = OrganismPredictionLedger()
        ledger.bodyConfidence.toolPath = toolPath
        if recentViolation { ledger.lastViolationAt = t0.addingTimeInterval(-120) }
        let started = OrganismPredictiveBody.applying(
            signal: signal(.toolStarted, at: t0),
            to: ledger, chemicalState: ChemicalState(), bodySchema: BodySchema()
        )
        var before = started.ledger
        for (id, var p) in before.predictions where p.status == .pending {
            p.confidence = confidence
            p.uncertainty = uncertainty
            before.predictions[id] = p
        }
        let at = t0.addingTimeInterval(30)
        let resolved = OrganismPredictiveBody.applying(
            signal: signal(outcome, at: at),
            to: before, chemicalState: ChemicalState(), bodySchema: BodySchema()
        )
        return (before, resolved.ledger, at)
    }

    @Test func bracedSuccessMintsRelief() {
        let (before, after, at) = resolvedLedgers(
            toolPath: 0.15, confidence: 0.2, uncertainty: 0.9,
            outcome: .toolSucceeded, recentViolation: true
        )
        let result = OrganismResolutionFelt.events(before: before, after: after, at: at)
        #expect(result.events.count == 1)
        #expect(result.events.first?.kind == .relief)
        #expect(result.events.first?.pathKind == .toolCompletion)
        #expect((result.events.first?.magnitude ?? 0) >= OrganismResolutionFelt.reliefBracingFloor)
        #expect(result.stamped.lastResolutionFeltAt?[OrganismPredictionKind.toolCompletion.rawValue] == at)
    }

    @Test func calmSuccessStaysChemistryOnly() {
        let (before, after, at) = resolvedLedgers(
            toolPath: 0.9, confidence: 0.9, uncertainty: 0.1,
            outcome: .toolSucceeded
        )
        let result = OrganismResolutionFelt.events(before: before, after: after, at: at)
        #expect(result.events.isEmpty, "a calm success is not a memory-worthy exhale")
        #expect(result.stamped.lastResolutionFeltAt == nil)
    }

    @Test func confidentFailureMintsDisappointment() {
        let (before, after, at) = resolvedLedgers(
            toolPath: 0.85, confidence: 0.85, uncertainty: 0.1,
            outcome: .toolFailed
        )
        let result = OrganismResolutionFelt.events(before: before, after: after, at: at)
        #expect(result.events.count == 1)
        #expect(result.events.first?.kind == .disappointment)
        #expect((result.events.first?.magnitude ?? 0) > 0)
    }

    @Test func dreadedFailureIsNotDisappointment() {
        // Failing at something she already dreaded is the violation shadow's
        // business (A1 chemistry), not a broken expectation.
        let (before, after, at) = resolvedLedgers(
            toolPath: 0.15, confidence: 0.2, uncertainty: 0.9,
            outcome: .toolFailed
        )
        let result = OrganismResolutionFelt.events(before: before, after: after, at: at)
        #expect(result.events.isEmpty)
    }

    @Test func feltEventsAreRateBoundedPerPath() {
        let (before, after, at) = resolvedLedgers(
            toolPath: 0.15, confidence: 0.2, uncertainty: 0.9,
            outcome: .toolSucceeded, recentViolation: true
        )
        let first = OrganismResolutionFelt.events(before: before, after: after, at: at)
        #expect(first.events.count == 1)

        // A second braced resolution 10 minutes later on the SAME path: the
        // stamp suppresses it. An hour later it may feel again.
        var before2 = first.stamped
        before2.bodyConfidence.toolPath = 0.15
        let started2 = OrganismPredictiveBody.applying(
            signal: signal(.toolStarted, at: at.addingTimeInterval(300)),
            to: before2, chemicalState: ChemicalState(), bodySchema: BodySchema()
        )
        var tuned2 = started2.ledger
        for (id, var p) in tuned2.predictions where p.status == .pending {
            p.confidence = 0.2
            p.uncertainty = 0.9
            tuned2.predictions[id] = p
        }
        let at2 = at.addingTimeInterval(600)
        let resolved2 = OrganismPredictiveBody.applying(
            signal: signal(.toolSucceeded, at: at2),
            to: tuned2, chemicalState: ChemicalState(), bodySchema: BodySchema()
        )
        let second = OrganismResolutionFelt.events(before: tuned2, after: resolved2.ledger, at: at2)
        #expect(second.events.isEmpty, "10 minutes after a felt relief, the same path stays quiet")

        // Past the hour, a FRESH pending row resolving braced may feel again
        // (review 3360e532dd3b: no stale before/after reuse — a real new
        // expectation forms and resolves).
        var before3 = second.stamped
        before3.bodyConfidence.toolPath = 0.15
        before3.lastViolationAt = at.addingTimeInterval(3900)
        let started3 = OrganismPredictiveBody.applying(
            signal: signal(.toolStarted, at: at.addingTimeInterval(3950)),
            to: before3, chemicalState: ChemicalState(), bodySchema: BodySchema()
        )
        var tuned3 = started3.ledger
        for (id, var p) in tuned3.predictions where p.status == .pending {
            p.confidence = 0.2
            p.uncertainty = 0.9
            tuned3.predictions[id] = p
        }
        let at3 = at.addingTimeInterval(4000)
        let resolved3 = OrganismPredictiveBody.applying(
            signal: signal(.toolSucceeded, at: at3),
            to: tuned3, chemicalState: ChemicalState(), bodySchema: BodySchema()
        )
        let third = OrganismResolutionFelt.events(before: tuned3, after: resolved3.ledger, at: at3)
        #expect(third.events.count == 1, "past the hour a fresh braced resolution may feel again")
    }

    @Test func substrateStampsTheMeasuredFeelingOntoTheNode() async {
        // The organism measured this feeling; the substrate must record it
        // as-is — no lexicon, no residue arithmetic, bounded.
        let substrate = CognitiveSubstrate(
            configuration: CognitiveConfiguration(
                enabled: true, workspaceEnabled: true,
                capsuleInjectionEnabled: true, affectEnabled: true,
                maximumActiveNodes: 32
            ),
            dependencies: CognitiveSubstrateDependencies(
                now: { self.t0 }, makeUUID: { UUID() }, userName: { "" }
            )
        )
        let event = CognitiveEvent(
            id: UUID().uuidString,
            kind: .organismResolutionFelt,
            subject: CognitiveSubjectReference(type: "organism_path", id: "tool:swift_build", label: "toolCompletion"),
            sourceClass: .observed,
            occurredAt: t0,
            summary: "Relief — the tool:swift_build path I was braced for landed fine.",
            importance: 0.65,
            metadata: ["feltValence": .double(0.5), "feltArousal": .double(0.15)]
        )
        await substrate.ingest(event)
        let node = await substrate.snapshot().nodes.first { $0.subjectReference.id.hasPrefix("tool:swift_build") }
        #expect(node != nil, "the felt resolution must mint a node")
        #expect(abs((node?.emotionalValence ?? 0) - 0.5) < 0.0001, "the organism's measured valence lands as-is: \(String(describing: node?.emotionalValence))")
    }

    private func makeFeltSubstrate(now: @escaping @Sendable () -> Date) -> CognitiveSubstrate {
        CognitiveSubstrate(
            configuration: CognitiveConfiguration(
                enabled: true, workspaceEnabled: true,
                capsuleInjectionEnabled: true, affectEnabled: true,
                maximumActiveNodes: 64
            ),
            dependencies: CognitiveSubstrateDependencies(now: now, makeUUID: { UUID() }, userName: { "" })
        )
    }

    private func feltResolutionEvent(kind: String, valence: Double, path: String, at: Date) -> CognitiveEvent {
        CognitiveEvent(
            id: UUID().uuidString,
            kind: .organismResolutionFelt,
            subject: CognitiveSubjectReference(type: "organism_path", id: "tool:swift_build#\(UUID().uuidString.prefix(8))", label: path),
            sourceClass: .observed,
            occurredAt: at,
            summary: kind == "relief"
                ? "Relief — the tool path I was braced for landed fine."
                : "Disappointment — the tool path I was counting on fell through.",
            importance: 0.65,
            metadata: ["feltValence": .double(valence), "feltArousal": .double(0.3), "resolutionKind": .string(kind)]
        )
    }

    /// Round 3 Wave A3: repeated felt disappointments on ONE path settle a
    /// negative undertone through the shared disposition writer; repeated
    /// braced-then-fine reliefs teach the body the dread was oversized.
    /// Two repeats are not a pattern.
    @Test func resolutionPatternsNudgeTheSlowLayer() async {
        let t = Date()
        let s = makeFeltSubstrate(now: { t })
        for i in 0..<3 {
            await s.ingest(feltResolutionEvent(
                kind: "disappointment", valence: -0.5, path: "toolCompletion",
                at: t.addingTimeInterval(Double(i - 3) * 600)
            ))
        }
        await s.runMaintenance(reason: "a3-pattern-test")
        let down = await s.decayedDispositionValence(at: t)
        #expect(down < 0, "three felt disappointments must settle a negative undertone: \(down)")

        let t2 = Date()
        let s2 = makeFeltSubstrate(now: { t2 })
        for i in 0..<3 {
            await s2.ingest(feltResolutionEvent(
                kind: "relief", valence: 0.5, path: "toolCompletion",
                at: t2.addingTimeInterval(Double(i - 3) * 600)
            ))
        }
        await s2.runMaintenance(reason: "a3-pattern-test-relief")
        let up = await s2.decayedDispositionValence(at: t2)
        #expect(up > 0, "three felt reliefs must settle a positive undertone: \(up)")

        let t3 = Date()
        let s3 = makeFeltSubstrate(now: { t3 })
        for i in 0..<2 {
            await s3.ingest(feltResolutionEvent(
                kind: "disappointment", valence: -0.5, path: "toolCompletion",
                at: t3.addingTimeInterval(Double(i - 2) * 600)
            ))
        }
        await s3.runMaintenance(reason: "a3-pattern-test-two")
        let flat = await s3.decayedDispositionValence(at: t3)
        #expect(flat == 0, "two repeats are not a pattern: \(flat)")
    }

    private final class TickClock: @unchecked Sendable {
        private let lock = NSLock()
        private var t: Date
        init(_ t: Date) { self.t = t }
        func now() -> Date { lock.lock(); defer { lock.unlock() }; return t }
        func advance(_ interval: TimeInterval) { lock.lock(); t = t.addingTimeInterval(interval); lock.unlock() }
    }

    /// Review a5ae86fae93b High 1: the 48h pattern window outlives the ~20h
    /// consolidation tick — the SAME three disappointments must nudge ONCE.
    /// A second tick with no new felt moments decays the undertone toward
    /// zero instead of deepening it.
    @Test func samePatternDoesNotNudgeTwiceAcrossTicks() async {
        let clock = TickClock(Date())
        let s = makeFeltSubstrate(now: { clock.now() })
        for i in 0..<3 {
            await s.ingest(feltResolutionEvent(
                kind: "disappointment", valence: -0.5, path: "toolCompletion",
                at: clock.now().addingTimeInterval(Double(i - 3) * 600)
            ))
        }
        await s.runMaintenance(reason: "a3-tick-1")
        let first = await s.decayedDispositionValence(at: clock.now())
        #expect(first < 0, "tick 1 must nudge: \(first)")

        clock.advance(21 * 3600)
        await s.runMaintenance(reason: "a3-tick-2")
        let second = await s.decayedDispositionValence(at: clock.now())
        #expect(second > first, "tick 2 with no new moments must only decay, never deepen: \(first) → \(second)")
        #expect(second > first * 0.9 - 0.001 && second < 0, "second reading should be roughly the decayed first nudge: \(second)")
    }

    /// Review bf74aecde2fa: the plan's literal at-most-once-per-kind-per-day
    /// contract — even GENUINELY fresh growth on the same path, same calendar
    /// day, across two ~20h ticks must NOT re-nudge; the second tick only
    /// decays. Fixed-anchor clock so both ticks share one 86,400s day bucket.
    @Test func genuineSameDayGrowthDoesNotReNudge() async {
        // Anchor 60s into a day bucket so tick1 (+0) and tick2 (+20h01m) both
        // fall inside the SAME bucket (72,060s < 86,400s).
        let bucketStart = Date(timeIntervalSince1970: 400 * 86_400)
        let clock = TickClock(bucketStart.addingTimeInterval(60))
        let s = makeFeltSubstrate(now: { clock.now() })
        for i in 0..<3 {
            await s.ingest(feltResolutionEvent(
                kind: "disappointment", valence: -0.5, path: "toolCompletion",
                at: clock.now().addingTimeInterval(Double(i) * 10)
            ))
        }
        await s.runMaintenance(reason: "a3-day-tick-1")
        let first = await s.decayedDispositionValence(at: clock.now())
        #expect(first < 0, "tick 1 nudges: \(first)")

        // A genuinely NEW disappointment on the same path, 20h later, still
        // the same day. Growth gate would pass; the DAY CLAIM must block it.
        clock.advance(20 * 3600 + 60)
        await s.ingest(feltResolutionEvent(
            kind: "disappointment", valence: -0.5, path: "toolCompletion",
            at: clock.now()
        ))
        await s.runMaintenance(reason: "a3-day-tick-2")
        let second = await s.decayedDispositionValence(at: clock.now())
        #expect(second > first, "same-day re-growth must only decay, never deepen: \(first) → \(second)")

        // The NEXT day the claim expires (pruned map no longer holds the key),
        // so a fresh pattern nudges again — the gate is per-day, not permanent.
        clock.advance(26 * 3600) // now in a later day bucket
        for _ in 0..<3 {
            await s.ingest(feltResolutionEvent(
                kind: "disappointment", valence: -0.5, path: "toolCompletion",
                at: clock.now()
            ))
        }
        let beforeThird = await s.decayedDispositionValence(at: clock.now())
        await s.runMaintenance(reason: "a3-day-tick-3")
        let third = await s.decayedDispositionValence(at: clock.now())
        #expect(third < beforeThird, "a fresh pattern the next day must nudge again: \(beforeThird) → \(third)")
    }

    /// Review e74d2856bd9b: clearTransientState resets the disposition, so the
    /// A3 day claim must clear with it — a stale claim would suppress a
    /// legitimate fresh pattern after the clear.
    @Test func clearTransientStateReleasesTheDayClaim() async {
        let bucketStart = Date(timeIntervalSince1970: 420 * 86_400)
        let clock = TickClock(bucketStart.addingTimeInterval(60))
        let s = makeFeltSubstrate(now: { clock.now() })
        for _ in 0..<3 {
            await s.ingest(feltResolutionEvent(
                kind: "disappointment", valence: -0.5, path: "toolCompletion",
                at: clock.now()
            ))
        }
        await s.runMaintenance(reason: "a3-claim")
        #expect(await s.decayedDispositionValence(at: clock.now()) < 0)

        await s.clearTransientState()

        // Same day, fresh pattern after the clear: the claim is gone, so it
        // nudges again instead of being wrongly suppressed.
        for _ in 0..<3 {
            await s.ingest(feltResolutionEvent(
                kind: "disappointment", valence: -0.5, path: "toolCompletion",
                at: clock.now()
            ))
        }
        let before = await s.decayedDispositionValence(at: clock.now())
        await s.runMaintenance(reason: "a3-post-clear")
        let after = await s.decayedDispositionValence(at: clock.now())
        #expect(after < before, "a fresh pattern after a state clear must nudge, not be suppressed by a stale claim: \(before) → \(after)")
    }

    /// Review a5ae86fae93b High 2: a failed maintenance transaction must roll
    /// the in-memory disposition back with the rest of the transition.
    @Test func failedMaintenanceRollsBackTheDispositionNudge() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("felt-rollback-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try CognitiveSQLiteStore(dataRoot: root)
        let t = Date()
        let s = CognitiveSubstrate(
            configuration: CognitiveConfiguration(
                enabled: true, persistenceEnabled: true, workspaceEnabled: true,
                capsuleInjectionEnabled: true, affectEnabled: true,
                maximumActiveNodes: 64
            ),
            dependencies: CognitiveSubstrateDependencies(now: { t }, makeUUID: { UUID() }, userName: { "" }),
            store: store
        )
        for i in 0..<3 {
            await s.ingest(feltResolutionEvent(
                kind: "disappointment", valence: -0.5, path: "toolCompletion",
                at: t.addingTimeInterval(Double(i - 3) * 600)
            ))
        }
        let injector = try DatabaseQueue(path: await store.databaseURL.path)
        try await injector.write { db in
            try db.execute(sql: """
                CREATE TRIGGER fail_maintenance_receipt
                BEFORE INSERT ON cognitive_receipts
                WHEN NEW.kind = 'maintenance'
                BEGIN
                    SELECT RAISE(ABORT, 'injected maintenance failure');
                END
                """)
        }
        await s.runMaintenance(reason: "a3-rollback")
        let after = await s.decayedDispositionValence(at: t)
        #expect(after == 0, "a failed transaction must not leave the nudge in memory: \(after)")
    }

    @Test func kernelBuffersAndDrainsFeltResolutions() async {
        // The kernel stamps felt events at its own clock, so the scenario
        // must live in near-now time for the violation shadow to be fresh.
        let kernel = OrganismKernel(configuration: .enabled)
        let base = Date().addingTimeInterval(-100)
        // Deep dread through the REAL ingest path: repeated failures crush
        // the tool path's body confidence and keep the shadow fresh...
        for round in 0..<4 {
            await kernel.ingest(signal(.toolStarted, at: base.addingTimeInterval(Double(round) * 20)))
            await kernel.ingest(signal(.toolFailed, at: base.addingTimeInterval(Double(round) * 20 + 10)))
        }
        // ...then the braced attempt lands fine.
        await kernel.ingest(signal(.toolStarted, at: base.addingTimeInterval(85)))
        await kernel.ingest(signal(.toolSucceeded, at: base.addingTimeInterval(95)))

        let drained = await kernel.drainResolutionFelt()
        #expect(drained.contains { $0.kind == .relief }, "the braced success after fresh violations must be felt: \(drained)")
        let second = await kernel.drainResolutionFelt()
        #expect(second.isEmpty, "drain is the remove for every add")
    }
}
