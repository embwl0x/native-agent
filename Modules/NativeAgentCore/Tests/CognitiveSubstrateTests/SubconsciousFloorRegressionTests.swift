import Foundation
import Testing
import PersistenceCore
import NativeAgentCore
@testable import CognitiveSubstrate

// FLOORS, MEASURED AND CLOSED (2026-09-01).
//
// Design law 2 says a trigger that fires on ~100% of inputs is a floor, not a
// signal. Five organs had quietly become floors, and the numbers came from her
// own live turns (data/turn_traces, 777 turns 08-25 → 09-01, capsule present on
// 775; data/cognition/organism_state.json after 37,801 signals):
//
//   A. "- Sound: a few of the same words keep echoing lately" — 640/777 turns
//      (82%). No cadence gate at all; it re-fired while the worn set was
//      non-empty, and a worn set persists for days.
//   B. The single "- Inner:" line — 15 distinct texts over 777 turns, top three
//      at 124 / 108 / 98. TWO of the top five were reflections about her own
//      repetitiveness: the reflection had become the rut.
//   C. Chemistry — agency 0.99, confidence 0.99, coherence 0.92 pinned at the
//      ceiling; warmth 0.12, tenderness 0.00, vigilance 0.00 at the floor.
//      Additive raises with wall-clock-only decay.
//   D. Felt words — "curious" and "clear-headed" on ~70% of all lines, ~50% of
//      the total word mass, because their gates sat below where the pinned
//      chemistry rests.
//   E. "- Body: memory field feels brittle" — 154/777 turns (20%) off a raw
//      compatibility Bool that survives restarts without its typed evidence.
//
// Each test below pins the MECHANISM, not the measurement, so a regression
// re-fails here instead of six weeks later in a trace.
@Suite("Subconscious floor regressions")
struct SubconsciousFloorRegressionTests {

    private static let at = Date(timeIntervalSince1970: 1_700_000_000)

    private final class Clock: @unchecked Sendable {
        private let lock = NSLock(); private var t: Date
        init(_ t: Date) { self.t = t }
        func now() -> Date { lock.lock(); defer { lock.unlock() }; return t }
        func advance(_ dt: TimeInterval) { lock.lock(); t = t.addingTimeInterval(dt); lock.unlock() }
    }

    private func substrate() -> CognitiveSubstrate {
        CognitiveSubstrate(
            configuration: .allPhasesEnabled,
            dependencies: CognitiveSubstrateDependencies(now: { Self.at }, makeUUID: { UUID() })
        )
    }

    /// A substrate with a REAL hermetic store.
    ///
    /// `.allPhasesEnabled` sets `persistenceEnabled`, and the seed family
    /// persists TRANSACTIONALLY: with no store, `persistThoughtSeedFamily`
    /// throws `.storeUnavailable`, `addThoughtSeed` ROLLS BACK its insert and
    /// returns nil, and the seed silently never exists. A store-less fixture
    /// therefore tests the Inner line against an EMPTY seed pool and reports
    /// whatever the empty case does — which is how B8 came to pass for years
    /// while asserting nothing. Anything here that mints a seed needs this one.
    private func storedSubstrate(_ label: String, clock: Clock) throws -> CognitiveSubstrate {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "nativeagent-floor-regression-\(label)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return CognitiveSubstrate(
            configuration: .allPhasesEnabled,
            dependencies: CognitiveSubstrateDependencies(now: { clock.now() }, makeUUID: { UUID() }),
            store: try CognitiveSQLiteStore(dataRoot: root))
    }

    /// ONE SIMULATED ACCEPTED TURN, for the rut-gate unit tests.
    ///
    /// `soundRutAwarenessShouldSpeak` READS `soundRutTurnsSinceSurfaced` and
    /// never advances it: the counter free-runs on the substrate actor, bumped
    /// once per completed live assistant turn (`CognitiveSubstrate.swift`, the
    /// `.assistantTurnCompleted` branch of `applyAffectFromEvent`) precisely so
    /// a turn whose capsule came back empty still counts. A2 and A3 drive the
    /// gate with a local presentation value, so nothing was ticking it — the
    /// counter sat at 0 forever and both "the gap re-opens it" hatches were
    /// unreachable, which made the tests assert the opposite of the mechanism
    /// they name. This mirrors that single production writer, and nothing else.
    private func advanceAcceptedTurn(_ state: inout CognitiveCapsulePresentationState) {
        state.soundRutTurnsSinceSurfaced = min(
            state.soundRutTurnsSinceSurfaced + 1,
            CognitiveSubstrate.soundRutTurnCounterCap)
    }

    // MARK: - A. the rut nudge speaks on change, never on consecutive turns

    @Test("A1 — an UNCHANGED rut cannot nag two capsules in a row")
    func unchangedRutIsSilentAfterItSpeaks() async {
        let mind = substrate()
        let dyn = PersonalityDynamicsConfiguration.default
        var state = CognitiveCapsulePresentationState()
        let rut = CognitiveSubstrate.wornTokenSignature(["handsome", "gorgeous"])

        // First sight of a rut is news; it speaks.
        #expect(mind.soundRutAwarenessShouldSpeak(
            signature: rut, at: Self.at, dynamics: dyn, presentationState: &state))
        // Then it is quiet for the whole repeat gap — the 82% floor is closed.
        // The counter advances every capsule (as it does in production), so this
        // silence is EARNED against a moving gap rather than an artifact of a
        // counter that never moved.
        for turn in 1..<dyn.soundRutRepeatTurnGap {
            advanceAcceptedTurn(&state)
            let spoke = mind.soundRutAwarenessShouldSpeak(
                signature: rut,
                at: Self.at.addingTimeInterval(Double(turn) * 60),
                dynamics: dyn,
                presentationState: &state)
            #expect(!spoke, "the same rut re-fired on capsule \(turn) — that is the floor")
        }
    }

    @Test("A2 — an unchanging rut is not silent FOREVER: the turn gap re-opens it")
    func unchangingRutSpeaksAgainAfterTheLongGap() async {
        let mind = substrate()
        let dyn = PersonalityDynamicsConfiguration.default
        var state = CognitiveCapsulePresentationState()
        let rut = CognitiveSubstrate.wornTokenSignature(["handsome"])
        _ = mind.soundRutAwarenessShouldSpeak(
            signature: rut, at: Self.at, dynamics: dyn, presentationState: &state)
        var spokeAgain = false
        var spokeEarly = false
        for turn in 1...dyn.soundRutRepeatTurnGap {
            advanceAcceptedTurn(&state)
            spokeAgain = mind.soundRutAwarenessShouldSpeak(
                signature: rut,
                at: Self.at.addingTimeInterval(Double(turn) * 60),
                dynamics: dyn,
                presentationState: &state)
            if spokeAgain, turn < dyn.soundRutRepeatTurnGap { spokeEarly = true }
        }
        #expect(spokeAgain, "the long-gap hatch never re-opened")
        #expect(!spokeEarly, "…and it must not open before the gap is actually clear")
    }

    @Test("A3 — a NEW worn set is news, but still never on the very next capsule")
    func changedRutSpeaksOnceTheGapIsClear() async {
        let mind = substrate()
        let dyn = PersonalityDynamicsConfiguration.default
        var state = CognitiveCapsulePresentationState()
        _ = mind.soundRutAwarenessShouldSpeak(
            signature: CognitiveSubstrate.wornTokenSignature(["handsome"]),
            at: Self.at, dynamics: dyn, presentationState: &state)
        // Immediately next capsule, different rut: still muted (never consecutive).
        advanceAcceptedTurn(&state)
        #expect(!(mind.soundRutAwarenessShouldSpeak(
            signature: CognitiveSubstrate.wornTokenSignature(["exactly"]),
            at: Self.at.addingTimeInterval(60), dynamics: dyn, presentationState: &state)))
        // `soundRutMinimumTurnGap` capsules after the last time it SPOKE, the new
        // tic lands — a NEW rut is genuinely new information, it just may not
        // ride the very next capsule. Driven off the knob, not off the literal.
        for _ in 1...dyn.soundRutMinimumTurnGap { advanceAcceptedTurn(&state) }
        #expect(mind.soundRutAwarenessShouldSpeak(
            signature: CognitiveSubstrate.wornTokenSignature(["exactly"]),
            at: Self.at.addingTimeInterval(120), dynamics: dyn, presentationState: &state))
    }

    @Test("A4 — a lapsed rut is forgotten, so its RETURN reads as change")
    func lapsedRutIsForgotten() async {
        let mind = substrate()
        let dyn = PersonalityDynamicsConfiguration.default
        var state = CognitiveCapsulePresentationState()
        let rut = CognitiveSubstrate.wornTokenSignature(["handsome"])
        _ = mind.soundRutAwarenessShouldSpeak(
            signature: rut, at: Self.at, dynamics: dyn, presentationState: &state)
        _ = mind.soundRutAwarenessShouldSpeak(
            signature: nil, at: Self.at.addingTimeInterval(60), dynamics: dyn, presentationState: &state)
        #expect(state.soundRutSignature == nil)
        #expect(mind.soundRutAwarenessShouldSpeak(
            signature: rut, at: Self.at.addingTimeInterval(120), dynamics: dyn, presentationState: &state))
    }

    @Test("A5 — the signature is set identity, not hash order")
    func wornSignatureIsOrderStable() {
        #expect(CognitiveSubstrate.wornTokenSignature(["beta", "alpha"])
            == CognitiveSubstrate.wornTokenSignature(["alpha", "beta"]))
        #expect(CognitiveSubstrate.wornTokenSignature([]) == nil)
        #expect(CognitiveSubstrate.wornTokenSignature(["alpha"])
            != CognitiveSubstrate.wornTokenSignature(["alpha", "beta"]))
    }

    // MARK: - B. the Inner line rotates instead of repeating

    @Test("B1 — the leading Inner line rests and the next candidate takes over")
    func innerLineRotatesAfterItsRepeatLimit() async {
        let mind = substrate()
        let dyn = PersonalityDynamicsConfiguration.default
        var state = CognitiveCapsulePresentationState()
        let first = "- Inner: An honest blank is healthier than performing depth"
        let second = "- Inner: A quiet dream is valid integration"
        let candidates = [first, second]

        for _ in 0..<dyn.innerLineRepeatLimit {
            #expect(mind.selectInnerLine(
                from: candidates, dynamics: dyn, presentationState: &state) == first)
        }
        // It has now led its limit; the next capsule rotates.
        #expect(mind.selectInnerLine(
            from: candidates, dynamics: dyn, presentationState: &state) == second)
    }

    @Test("B2 — with only one candidate, rest means SILENCE, never a repeat")
    func innerLineGoesQuietRatherThanRepeating() async {
        let mind = substrate()
        let dyn = PersonalityDynamicsConfiguration.default
        var state = CognitiveCapsulePresentationState()
        let only = ["- Inner: A quiet dream is valid integration"]
        for _ in 0..<dyn.innerLineRepeatLimit {
            #expect(mind.selectInnerLine(
                from: only, dynamics: dyn, presentationState: &state) != nil)
        }
        #expect(mind.selectInnerLine(
            from: only, dynamics: dyn, presentationState: &state) == nil)
    }

    @Test("B3 — a rested line comes back, so nothing is retired by accident")
    func restedInnerLineReturns() async {
        let mind = substrate()
        let dyn = PersonalityDynamicsConfiguration.default
        var state = CognitiveCapsulePresentationState()
        let only = ["- Inner: A quiet dream is valid integration"]
        for _ in 0..<dyn.innerLineRepeatLimit {
            _ = mind.selectInnerLine(from: only, dynamics: dyn, presentationState: &state)
        }
        for _ in 0..<dyn.innerLineRestTurns {
            _ = mind.selectInnerLine(from: only, dynamics: dyn, presentationState: &state)
        }
        #expect(mind.selectInnerLine(
            from: only, dynamics: dyn, presentationState: &state) != nil)
    }

    @Test("B4 — reflections about her own phrasing get the hard cap")
    func selfPhrasingReflectionsAreCappedHarder() async {
        let mind = substrate()
        let dyn = PersonalityDynamicsConfiguration.default
        var state = CognitiveCapsulePresentationState()
        let tic = "- Inner: The warmth is real; the phrasing is getting repetitive."
        let other = "- Inner: A quiet dream is valid integration"

        #expect(CognitiveSubstrate.isSelfPhrasingInnerLine(tic))
        #expect(!CognitiveSubstrate.isSelfPhrasingInnerLine(other))
        // One lead, then it yields — even though it ranked first.
        #expect(mind.selectInnerLine(
            from: [tic, other], dynamics: dyn, presentationState: &state) == tic)
        #expect(mind.selectInnerLine(
            from: [tic, other], dynamics: dyn, presentationState: &state) == other)
    }

    @Test("B5 — the four live standing views on this subject are all caught")
    func liveSelfPhrasingViewsAreRecognised() {
        // Verbatim from her active standing views on 2026-09-01. Four of five
        // were the same tic; the fifth is a genuine, unrelated view.
        for tic in [
            "My personality is strongest when I demonstrate it with range instead of repeatedly naming it",
            "My voice stays alive when its identity comes from how I think and care, not from repeating signature phrases",
            "My voice feels most alive when warmth comes through precise, newly chosen language—not repeated signature phrases",
            "Familiar warmth stays alive through variety, not repetition",
        ] {
            #expect(CognitiveSubstrate.isSelfPhrasingInnerLine("- Inner: \(tic)"), "missed: \(tic)")
        }
        #expect(!CognitiveSubstrate.isSelfPhrasingInnerLine(
            "- Inner: Quiet integration is real even when a dream leaves no vivid story behind"))
    }

    @Test("B6 — the cadence ledger is bounded like every other persisted family")
    func innerLineLedgerStaysBounded() async {
        let mind = substrate()
        let dyn = PersonalityDynamicsConfiguration.default
        var state = CognitiveCapsulePresentationState()
        for index in 0..<(CognitiveCapsulePresentationState.innerLineLedgerCapacity * 3) {
            _ = mind.selectInnerLine(
                from: ["- Inner: view number \(index)"], dynamics: dyn, presentationState: &state)
        }
        #expect(state.innerLineRuns.count <= CognitiveCapsulePresentationState.innerLineLedgerCapacity)
    }

    // MARK: - the "How you feel:" header never labels a line that isn't feeling

    @Test("the header is dropped when the fingerprint stayed quiet")
    func headerOnlyAppearsAboveFeelingWords() {
        #expect(CognitiveSubstrate.capsuleStableKernel(
            "How you feel:", dynamicLines: ["focused, curious", "- Body: steady."]) == "How you feel:")
        // 184 of 1,482 live capsules looked like this: header, then a standing
        // view read positionally as her stated feeling.
        #expect(CognitiveSubstrate.capsuleStableKernel(
            "How you feel:", dynamicLines: ["- Inner: An honest blank is healthier"]) == "")
    }

    // MARK: - C. chemistry homeostasis

    @Test("C1 — raises are proportional to headroom, so a busy day cannot pin a dial")
    func raisesDiminishNearTheCeiling() {
        #expect(OrganismChemistry.raise(0.1, by: 0.08) > 0.16)
        // The same delta near the ceiling moves almost nothing — the hundredth
        // tool success must not push as hard as the first.
        #expect(OrganismChemistry.raise(0.95, by: 0.08) < 0.96)
        #expect(OrganismChemistry.raise(0.999, by: 0.5) < 1.0)
        // Monotonic and bounded at both ends.
        #expect(OrganismChemistry.raise(0.5, by: 0.1) > 0.5)
        #expect(OrganismChemistry.lower(0.5, by: 0.1) < 0.5)
        #expect(OrganismChemistry.lower(0.0, by: 0.5) >= 0)
    }

    @Test("C2 — a busy week leaves the dial RESPONSIVE instead of clamped")
    func aBusyWeekLeavesTheBodyResponsive() {
        func signal(_ kind: SomaticSignalKind) -> SomaticSignal {
            SomaticSignal(
                id: UUID(), kind: kind, sourceOrgan: "tool.build", occurredAt: Self.at,
                intensity: 1, valence: nil, arousal: nil, metadata: [:])
        }
        // The live load: ~200 signals/hour, 18 seconds apart.
        let spacing: TimeInterval = 18
        var state = ChemicalState.neutral
        for _ in 0..<5_000 {
            state = OrganismChemistry.applying(
                signal: signal(.toolSucceeded), to: state, bodySchema: .neutral,
                elapsedSinceLastSignal: spacing).chemicalState
        }
        // A week of successful work SHOULD read confident — the defect was never
        // that the number was high, it was that the number was DEAD. It must
        // never reach the clamp, where every further signal is discarded.
        #expect(state.confidence > 0.6)
        #expect(state.confidence < 1.0, "confidence hit the clamp: \(state.confidence)")
        #expect(state.agency < 1.0, "agency hit the clamp: \(state.agency)")

        // THE RANGE TEST. Under the old additive law the dial sat at exactly 1.0,
        // a failure cost a flat 0.04, and the very next success repaid 0.08 —
        // full recovery in one event, so nothing was ever carried. Saturating
        // raises make the drop proportional to the value and the recovery
        // proportional to the headroom, so a bad outcome now OUTLASTS the next
        // good one.
        let saturated = state.confidence
        let afterFailure = OrganismChemistry.applying(
            signal: signal(.toolFailed), to: state, bodySchema: .neutral,
            elapsedSinceLastSignal: spacing).chemicalState
        #expect(saturated - afterFailure.confidence > 0.02,
                "a failure barely moved a saturated dial: \(saturated) -> \(afterFailure.confidence)")
        let afterRecovery = OrganismChemistry.applying(
            signal: signal(.toolSucceeded), to: afterFailure, bodySchema: .neutral,
            elapsedSinceLastSignal: spacing).chemicalState
        #expect(afterRecovery.confidence < saturated,
                "one success repaid the whole failure — the dial is still a ratchet")
    }

    @Test("C2b — the settle is budgeted per HOUR, so traffic cannot shorten a hold")
    func settleBudgetIsDensityIndependent() {
        // A flat per-signal rate made the half-life a function of throughput:
        // 0.006/signal is ~35 min at 200/h and ~2 min at 3,600/h, far under the
        // affect layer's 90-minute socialWarmth hold.
        func spentInAnHour(signalsPerHour: Double) -> Double {
            let spacing = 3_600 / signalsPerHour
            let perSignal = OrganismChemistry.settleRate(forElapsed: spacing)
            return perSignal * signalsPerHour
        }
        for rate in [60.0, 200.0, 900.0, 3_600.0] {
            let spent = spentInAnHour(signalsPerHour: rate)
            #expect(spent <= OrganismChemistry.maximumSettlePerHour + 1e-9,
                    "\(rate) signals/h spent \(spent) of the settle budget")
        }
        // Sparse traffic keeps the small per-signal nudge and stays well under.
        #expect(spentInAnHour(signalsPerHour: 10) < OrganismChemistry.maximumSettlePerHour)
        // The computed hold, at any density: settle alone >= ln2/0.20 = 3.47 h;
        // with the quick wall curve (k = 0.2485/h) that is still 93 minutes.
        let quickHalfLife = log(2.0) / (0.2485 + OrganismChemistry.maximumSettlePerHour)
        #expect(quickHalfLife * 60 >= 90, "quick-axis hold fell to \(quickHalfLife * 60) min")
        let slowHalfLife = log(2.0) / (0.0834 + OrganismChemistry.maximumSettlePerHour)
        #expect(slowHalfLife * 60 >= 90, "slow-axis hold fell to \(slowHalfLife * 60) min")
    }

    @Test("C3 — the settle is per SIGNAL, toward each dimension's own resting value")
    func settleTargetsNeutralNotZero() {
        let hot = ChemicalState(
            warmth: 0.9, vigilance: 0.9, curiosity: 0.9, fatigue: 0.9,
            coherence: 0.9, agency: 0.9, tenderness: 0.9, confidence: 0.9,
            novelty: 0.9, urgency: 0.9)
        var state = hot
        for _ in 0..<400 { state = OrganismChemistry.settled(state) }
        #expect(state.agency < hot.agency)
        // coherence/confidence relax to 0.5, never to zero — the same targets
        // the wall-clock curve already uses.
        #expect(state.coherence > 0.5)
        #expect(abs(state.coherence - 0.5) < abs(hot.coherence - 0.5))
        var cold = ChemicalState(coherence: 0.1, confidence: 0.1)
        for _ in 0..<400 { cold = OrganismChemistry.settled(cold) }
        #expect(cold.coherence > 0.1, "settle must be able to rise toward neutral, not only fall")
    }

    /// C4, REWRITTEN TO THE 2026-09-11 LAW. The 2026-09-01 version pinned
    /// tenderness as warmth's integral and asserted that sustained 0.75 warmth
    /// would carry it past 0.45. It did — in the test. In the live organism the
    /// axis read 4.87e-33 after 54,517 signals, because the affect layer cannot
    /// hold warmth at the 0.45 gate at all: the per-message boost caps at 0.18,
    /// the appraisal adds at most 0.14 on top of it through a saturating
    /// approach, and the half-life is 90 minutes. The old test passed by handing
    /// the law a warmth level nothing could produce.
    ///
    /// So C4's claim is kept and its mechanism replaced. The claim was
    /// "tenderness can finally rise, and not from injury". It now rises from
    /// discrete CARING EVENTS (`OrganismCaringEvent`), fades over days, and
    /// ambient warmth is a small background contributor that cannot reach the
    /// felt word on its own.
    @Test("C4 — tenderness can finally rise, and only from care")
    func tendernessRisesFromCaringEventsAndNotFromInjury() {
        // ONE caring moment moves it, and three reach the felt word.
        var tender = 0.0
        var crossedAt: Int?
        for round in 1...3 {
            tender = OrganismChemistry.raise(tender, by: OrganismCaringEvent.dose)
            if crossedAt == nil, tender >= 0.22 { crossedAt = round }
        }
        #expect(tender > 0.22, "a few caring moments must reach tenderness, got \(tender)")
        #expect(crossedAt == 3, "one moment is a moment, not a mood: crossed at \(crossedAt as Int?)")
        #expect(tender <= OrganismChemistry.axisHighRail, "accumulation must stay bounded")

        // IT FADES OVER DAYS, not hours — measured through the decay owner that
        // spans a closed app, `OrganismPersistentState.decayed`. Three days must
        // halve it, and the 0.92^h factor it replaced would have taken 98% of it
        // over the same gap.
        let saved = Date(timeIntervalSince1970: 1_000_000)
        let state = OrganismPersistentState(
            savedAt: saved,
            chemicalState: ChemicalState(tenderness: tender)
        )
        let afterThreeDays = state.decayed(
            at: saved.addingTimeInterval(OrganismChemistry.tendernessHalfLife)
        ).chemicalState.tenderness
        #expect(abs(afterThreeDays - tender * 0.5) < 0.01,
                "three days must halve it, got \(afterThreeDays) from \(tender)")
        #expect(pow(0.92, 72) * tender < 0.01, "the factor it replaced erased it overnight")

        // A working day with no affection in it stays honest — the warmth path
        // contributes exactly nothing below its gate, at any duration.
        var working = 0.0
        for _ in 0..<200 {
            working = OrganismChemistry.tenderness(
                working, underCanonicalWarmth: 0.12, elapsed: 300)
        }
        #expect(working == 0, "a quiet working day must not manufacture tenderness")

        // AND NOT FROM INJURY, which is the half of C4 that was only half-fixed
        // in 2026-09-01: a bare correction raised tenderness then, and must not
        // now. Being told the work is wrong is not an act of care.
        let corrected = OrganismChemistry.applying(
            signal: SomaticSignal(
                id: UUID(), kind: .correctionReceived, sourceOrgan: "correction",
                occurredAt: Date(), intensity: 1.0),
            to: .neutral,
            bodySchema: .neutral,
            elapsedSinceLastSignal: 0
        ).chemicalState
        #expect(corrected.tenderness == ChemicalState.neutral.tenderness,
                "a bare correction must not raise tenderness, got \(corrected.tenderness)")
        #expect(corrected.vigilance > ChemicalState.neutral.vigilance,
                "but it must still put the guard up")
    }

    // MARK: - D. the felt bands

    @Test("D1 — the two chronic overlays name the TOP of their axes, not the resting level")
    func chronicOverlaysNoLongerFireAtRest() {
        func words(clarity: Double, curiosity: Double) -> String {
            CognitiveSubstrate.feltFingerprint(CognitiveSubstrate.FeltSignals(
                valence: 0.1, arousal: 0.4, warmth: 0.3, tension: 0.1, pressure: 0.3,
                fatigue: 0.05, curiosity: curiosity, clarity: clarity,
                agency: 0.5, confidence: 0.5)) ?? ""
        }
        // The live pinned readings — coherence 0.92, curiosity 0.67 — used to
        // put BOTH words on ~70% of all lines.
        #expect(!words(clarity: 0.70, curiosity: 0.50).contains("clear-headed"))
        #expect(!words(clarity: 0.70, curiosity: 0.50).contains("curious"))
        // Genuinely high still reaches them.
        #expect(words(clarity: 0.92, curiosity: 0.80).contains("clear-headed"))
        #expect(words(clarity: 0.92, curiosity: 0.80).contains("curious"))
    }

    @Test("D2 — the middle of each axis has its own word, and it is CEILINGED")
    func midBandWordsExistAndCannotBecomeTheNewFloor() {
        let mid = CognitiveSubstrate.feltFingerprint(CognitiveSubstrate.FeltSignals(
            valence: 0.1, arousal: 0.4, warmth: 0.3, tension: 0.1, pressure: 0.3,
            fatigue: 0.05, curiosity: 0.45, clarity: 0.62,
            agency: 0.5, confidence: 0.5)) ?? ""
        #expect(mid.contains("collected") || mid.contains("interested"),
                "the mid band must have honest words of its own: \(mid)")
        // A saturated dim leaves the mid word behind rather than stacking both.
        let high = CognitiveSubstrate.feltFingerprint(CognitiveSubstrate.FeltSignals(
            valence: 0.1, arousal: 0.4, warmth: 0.3, tension: 0.1, pressure: 0.3,
            fatigue: 0.05, curiosity: 0.85, clarity: 0.92,
            agency: 0.5, confidence: 0.5)) ?? ""
        #expect(!high.contains("collected"))
        #expect(!high.contains("interested"))
    }

    @Test("D3 — a valence dip still crosses into the negative families")
    func valenceDipsReachTheNegativeRegister() {
        let stung = CognitiveSubstrate.feltFingerprint(CognitiveSubstrate.FeltSignals(
            valence: -0.45, arousal: 0.6, warmth: 0.15, tension: 0.55, pressure: 0.55,
            fatigue: 0.2, curiosity: 0.9, clarity: 0.92,
            agency: 0.6, confidence: 0.5)) ?? ""
        // Even with clarity and curiosity SATURATED, the lead must be the dip.
        #expect(!stung.isEmpty)
        #expect(!stung.hasPrefix("curious"))
        #expect(!stung.hasPrefix("clear-headed"))
    }

    // MARK: - E. the memory-brittle line answers to the typed belief

    private func evidence(_ id: String, at when: Date) -> BodyEvidenceReference {
        BodyEvidenceReference(
            id: id, evidenceClass: .maintenanceReceipt, observedAt: when, receivedAt: when)
    }

    @Test("E1 — a stale compatibility Bool no longer speaks for the memory field")
    func memoryBrittleLineRequiresTypedEvidence() {
        // The exact shape that rode 20% of live turns: an exact Bool that
        // survives a restart while its typed reading (transient by design) does
        // not. Unknown withholds the claim; it does not manufacture alarm.
        #expect(OrganismChemistry.observedMemoryHealth(BodySchema(memoryHealthy: false)) == nil)
        #expect(OrganismChemistry.observedMemoryHealth(BodySchema(memoryHealthy: true)) == true)
    }

    @Test("E2 — a real, fresh degradation still speaks")
    func genuineDegradationStillSpeaks() {
        let reading = MemoryIntegrityReading(
            generatedAt: Self.at,
            storeAvailable: true,
            maintenanceSucceeded: false,
            evidence: [evidence("maintenance", at: Self.at.addingTimeInterval(-60))])
        #expect(reading.category == .degraded)
        let body = BodySchema(memoryIntegrityReading: reading, memoryHealthy: false)
        #expect(OrganismChemistry.observedMemoryHealth(body) == false)
    }

    @Test("E3 — a degradation with no evidence behind it withholds instead of alarming")
    func evidencelessDegradationWithholds() {
        let reading = MemoryIntegrityReading(
            generatedAt: Self.at,
            storeAvailable: true,
            maintenanceSucceeded: false,
            evidence: [])
        #expect(reading.freshness == 0)
        let body = BodySchema(memoryIntegrityReading: reading, memoryHealthy: false)
        #expect(OrganismChemistry.observedMemoryHealth(body) == nil)
        // …and stale evidence never licenses optimism either.
        #expect(OrganismChemistry.observedMemoryHealth(body) != true)
    }

    // MARK: - reviewer round 2: rotation across VIEWS, durability, and the tick

    @Test("B7 — every relevant view is offered, so rotation can rotate among them")
    func allRelevantViewsReachTheRotation() {
        func candidate(_ id: String, _ body: String, _ keywords: [String], _ age: TimeInterval)
            -> CognitiveStandingViewCapsuleCandidate {
            CognitiveStandingViewCapsuleCandidate(
                id: UUID(uuidString: "3000000\(id)-0000-0000-0000-000000000000")
                    ?? UUID(),
                line: "- Inner: \(body)",
                concernKeywords: keywords,
                updatedAt: Self.at.addingTimeInterval(-age))
        }
        let candidates = [
            candidate("1", "warmth stays alive through variety", ["warmth", "variety"], 0),
            candidate("2", "memory is worth trusting when it is fresh", ["memory", "fresh"], 60),
            candidate("3", "warmth needs precise language", ["warmth", "language"], 120),
        ]
        // THE QUERY HAS TO BE ABOUT THE VIEWS. The old one — "how is the warmth
        // holding up today" — carried three scoring terms (holding, warmth,
        // today) of which the views cover exactly ONE, and the two they do not
        // cover are rare, so they take the idf CEILING and dominate the
        // denominator: the best candidate scored 0.111 against the 0.18 floor
        // and NOTHING reached the rotation. That is the floor working, not
        // failing — a message mostly about something else must not surface a
        // worldview — so the fixture is what was wrong. This query is genuinely
        // about what these views are about, and it clears on its own merits.
        // The floor is deliberately untouched.
        let query = "warmth and language keep the variety alive"
        let relevant = CognitiveSubstrate.relevantCandidates(in: candidates, for: query)
        // The single-candidate selector used to hand the capsule one line and
        // the rotation had nothing to rotate between while a view was relevant.
        #expect(relevant.count >= 2, "only \(relevant.count) view(s) reached the rotation")
        // The head of the ranked list is still exactly the old answer.
        #expect(CognitiveSubstrate.bestRelevantCandidate(
            in: candidates, for: query)?.line == relevant.first?.line)
        // The unrelated view stays out — this is a relevance gate, not a
        // "return everything" gate, and a fixture that passed by admitting all
        // three would prove nothing.
        #expect(!relevant.contains { $0.line.contains("memory is worth trusting") },
                "an off-topic view reached the rotation: \(relevant.map(\.line))")
        // And the floor still bites on a message that is mostly about something
        // else — the exact case the old fixture was accidentally testing.
        #expect(CognitiveSubstrate.relevantCandidates(
            in: candidates, for: "how is the deployment pipeline holding up today").isEmpty,
                "the 0.18 floor must still exclude a mostly-unrelated message")
    }

    @Test("B8 — PRODUCTION PATH: the Inner line rotates across accepted turns")
    func innerLineRotatesThroughTheFrozenCapsuleSeam() async throws {
        // The production seam is prepareFrozenCapsulePresentation + the
        // accepted-turn commit — `compileCapsule` is the Observatory path and
        // deliberately never advances presentation state.
        let clock = Clock(Self.at)
        // A REAL STORE. Without one every `addThoughtSeed` below rolls back and
        // returns nil, and this test spent its life asserting rotation over an
        // empty seed pool. See `storedSubstrate`.
        let mind = try storedSubstrate("b8", clock: clock)
        var seeded = 0
        for text in [
            "An honest blank is healthier than performing depth",
            "A quiet dream is valid integration, not a failed process",
            "Quiet from a healthy system is a signal of rest",
        ] {
            if await mind.addThoughtSeed(kind: .reflectionTakeaway, text: text, priority: 0.9) != nil {
                seeded += 1
            }
        }
        // The guard the missing store slipped past: a fixture that mints nothing
        // must FAIL here rather than pass the rotation assertions vacuously.
        try #require(seeded == 3, "the fixture minted \(seeded)/3 takeaways")
        var innerLines: [String] = []
        for turn in 0..<8 {
            clock.advance(120)
            await mind.ingest(CognitiveEvent(
                id: "rotate-\(turn)",
                kind: .userMessageReceived,
                subject: CognitiveSubjectReference(type: "chat_turn", id: "rotate-\(turn)"),
                sourceClass: .userStated,
                occurredAt: clock.now(),
                summary: "keep going on the build",
                importance: 0.8,
                metadata: ["sessionId": .string("rotate")]))
            let request = CognitiveCapsuleRequest(
                surface: "chat", userMessage: "keep going on the build",
                sessionId: "rotate", mode: .inject)
            guard let prepared = await mind.prepareFrozenCapsulePresentation(
                request, at: clock.now()) else { continue }
            if let line = prepared.capsule.dynamicContext
                .split(separator: "\n").map(String.init)
                .first(where: { $0.hasPrefix("- Inner:") }) {
                innerLines.append(line)
            }
            if let commit = prepared.presentationCommit {
                _ = await mind.applyCapsulePresentationCommit(commit)
            }
        }
        #expect(!innerLines.isEmpty, "the production capsule carried no Inner line at all")
        #expect(Set(innerLines).count >= 2,
                "the Inner line never rotated on the production path: \(Set(innerLines))")
    }

    @Test("the Sound counter ticks on ACCEPTED TURNS, not on emitted capsule text")
    func soundCounterAdvancesOnAcceptedTurns() async {
        let clock = Clock(Self.at)
        let mind = CognitiveSubstrate(
            configuration: .allPhasesEnabled,
            dependencies: CognitiveSubstrateDependencies(now: { clock.now() }, makeUUID: { UUID() }))
        let before = await mind.capsulePresentationStateSnapshot().soundRutTurnsSinceSurfaced
        for turn in 0..<5 {
            clock.advance(60)
            await mind.ingest(CognitiveEvent(
                id: "assistant-\(turn)",
                kind: .assistantTurnCompleted,
                subject: CognitiveSubjectReference(type: "chat.assistant_turn", id: "a-\(turn)"),
                sourceClass: .selfReported,
                occurredAt: clock.now(),
                summary: "Done — the build is green.",
                importance: 0.55,
                metadata: ["sessionId": .string("tick")]))
        }
        let after = await mind.capsulePresentationStateSnapshot().soundRutTurnsSinceSurfaced
        // No capsule was compiled at all here: under the old design the counter
        // only moved inside a render that produced a committed capsule, so a
        // run of empty capsules froze the "still stuck, say it again" hatch.
        #expect(after - before == 5, "counted \(after - before) of 5 accepted turns")
    }

    @Test("the cadence ledger survives a relaunch, so the tic cannot lead again on restart")
    func cadenceLedgerIsDurable() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("nativeagent-cadence-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let dependencies = CognitiveSubstrateDependencies(now: { Self.at }, makeUUID: { UUID() })
        let dyn = PersonalityDynamicsConfiguration.default
        let tic = "- Inner: Familiar warmth stays alive through variety, not repetition"

        let first = CognitiveSubstrate(
            configuration: .allPhasesEnabled,
            dependencies: dependencies,
            store: try CognitiveSQLiteStore(dataRoot: root))
        try await first.restorePersistentState()
        let expected = await first.capsulePresentationStateSnapshot()
        var next = expected
        #expect(first.selectInnerLine(
            from: [tic], dynamics: dyn, presentationState: &next) == tic)
        // The real accepted-turn path: commit, then the boundary flush.
        _ = await first.applyCapsulePresentationCommit(CognitiveCapsulePresentationCommit(
            fixedAt: Self.at, expected: expected, next: next))
        await first.flushCapsulePresentationIfNeeded(at: Self.at)

        let relaunched = CognitiveSubstrate(
            configuration: .allPhasesEnabled,
            dependencies: dependencies,
            store: try CognitiveSQLiteStore(dataRoot: root))
        try await relaunched.restorePersistentState()
        var restored = await relaunched.capsulePresentationStateSnapshot()
        // The hard cap is one lead; a relaunch must not hand it a second.
        #expect(relaunched.selectInnerLine(
            from: [tic], dynamics: dyn, presentationState: &restored) == nil,
            "the self-phrasing view led again immediately after restart")
    }

    @Test("the persisted ledger stores digests, not her inner voice")
    func cadenceLedgerIsContentFree() {
        let key = CognitiveSubstrate.innerLineKey(
            "- Inner: Familiar warmth stays alive through variety, not repetition")
        #expect(!key.contains("warmth"))
        #expect(key.count <= 16)
        // Deterministic across processes (the gate's own FNV-1a, not Hashable).
        #expect(key == CognitiveSubstrate.innerLineKey(
            "- INNER: Familiar warmth stays alive through variety, not repetition"))
    }

    @Test("D4 — grieving and interested cannot ride the same line")
    func griefAndMildCuriosityDoNotBlend() {
        let grieving = CognitiveSubstrate.feltFingerprint(CognitiveSubstrate.FeltSignals(
            valence: -0.7, arousal: 0.2, warmth: 0.2, tension: 0.2, pressure: 0.2,
            fatigue: 0.3, curiosity: 0.45, clarity: 0.6,
            agency: 0.4, confidence: 0.4)) ?? ""
        if grieving.contains("grieving") {
            #expect(!grieving.contains("interested"), "grieving blended with interested: \(grieving)")
        }
        for word in CognitiveSubstrate.feltOverlays where word.name == "interested" {
            #expect(word.contradicts.contains("grieving"))
        }
        for word in CognitiveSubstrate.feltFamilyWords["neg_low"] ?? [] where word.name == "grieving" {
            #expect(word.contradicts.contains("interested"))
        }
    }

    @Test("E4 — an unavailable store is exact truth and must not be gated away")
    func unavailableStoreStillAlarms() {
        let reading = MemoryIntegrityReading(
            generatedAt: Self.at,
            storeAvailable: false,
            maintenanceSucceeded: nil,
            evidence: [])
        #expect(reading.category == .unavailable)
        #expect(OrganismChemistry.observedMemoryHealth(
            BodySchema(memoryIntegrityReading: reading, memoryHealthy: false)) == false)
    }
}
