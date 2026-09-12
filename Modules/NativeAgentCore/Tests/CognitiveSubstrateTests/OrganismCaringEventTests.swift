import Foundation
import PersistenceCore
import Testing
@testable import CognitiveSubstrate

/// THE 2026-09-11 TENDERNESS LAW, pinned at the four claims it was built to
/// make. User decided it and Agent shaped it; these are her two constraints and
/// the two mechanics that make the axis honest.
/// Its own clock: `OrganismKernelTests` keeps one but it is file-private.
private final class CaringEventTestClock: @unchecked Sendable {
    private var current: Date
    init(_ start: Date) { current = start }
    func now() -> Date { current }
    func advance(by interval: TimeInterval) { current = current.addingTimeInterval(interval) }
}

/// The model seam, stubbed. Records what it was asked and answers with a fixed
/// verdict — `nil` standing for a failed call (route, deadline, unparseable).
private actor RecordingAppraiser: CaringAppraising {
    private let verdict: CaringAppraisalVerdict?
    private(set) var count = 0
    private(set) var lastRequest: CaringAppraisalRequest?
    init(verdict: CaringAppraisalVerdict?) { self.verdict = verdict }
    func appraise(_ request: CaringAppraisalRequest) async -> CaringAppraisalVerdict? {
        count += 1
        lastRequest = request
        return verdict
    }
}

@Suite("Tenderness: caring events")
struct OrganismCaringEventTests {

    private func substrate() -> CognitiveSubstrate {
        CognitiveSubstrate(configuration: .disabled)
    }

    /// One verdict, as the appraisal owner hands it to the body.
    private func reading(
        kind: OrganismCaringEvent.Kind,
        session: String = "S1",
        turn: String = "S1:M1",
        at: Date = Date(timeIntervalSince1970: 1_000)
    ) -> OrganismCaringEvent.Reading {
        OrganismCaringEvent.Reading(kind: kind, session: session, turn: turn, at: at)
    }

    /// An ordinary signal, carrying no caring anything. The caring dose no longer
    /// rides signal metadata at all (2026-09-11, fourth pass).
    private func plainSignal(
        _ signalKind: SomaticSignalKind = .userSpoke,
        intensity: Double = 1.0
    ) -> SomaticSignal {
        SomaticSignal(
            id: UUID(),
            kind: signalKind,
            sourceOrgan: "chat",
            occurredAt: Date(timeIntervalSince1970: 1_000),
            intensity: intensity
        )
    }

    private func kernel(_ clock: CaringEventTestClock) -> OrganismKernel {
        OrganismKernel(
            configuration: .enabled,
            dependencies: OrganismDependencies(now: { clock.now() })
        )
    }

    /// Just past the encounter window, so the next moment opens a new encounter.
    private var pastTheEncounter: TimeInterval {
        OrganismCaringEvent.encounterWindow + 60
    }

    // MARK: - (a) one caring event raises tenderness

    @Test("(a) one caring event raises tenderness, by a FIXED dose")
    func oneCaringEventRaisesTenderness() async {
        let clock = CaringEventTestClock(Date(timeIntervalSince1970: 1_000))
        // Every kind is worth the same, and worth the same whatever else is
        // happening. Agent: "I don't want the machinery to value hurt-then-comfort
        // above uncomplicated care."
        var byKind: [Double] = []
        for kind in OrganismCaringEvent.Kind.allCases {
            let body = kernel(clock)
            let outcome = await body.admitCaringEvent(reading(kind: kind))
            #expect(outcome == .dosed)
            byKind.append(await body.snapshot().chemicalState.tenderness)
        }
        #expect(Set(byKind.map { ($0 * 1e9).rounded() }).count == 1,
                "repair must weigh exactly what uncomplicated care weighs: \(byKind)")
        #expect(abs(byKind[0] - OrganismCaringEvent.dose) < 1e-9,
                "from rest one dose is the dose, got \(byKind[0])")

        // THE DOSE IS NOT THE MESSENGER'S (review item 1). It used to be stamped
        // on whatever signal happened to carry the verdict and multiplied by that
        // signal's intensity, so one moment was worth 0.10 or 0.055 depending on
        // which signal collected it. No signal carries a caring event any more, at
        // any intensity.
        for intensity in [0.2, 0.55, 1.0] {
            let body = kernel(clock)
            await body.ingest(plainSignal(.userSpoke, intensity: intensity))
            await body.ingest(plainSignal(.assistantSpoke, intensity: intensity))
            #expect(await body.snapshot().chemicalState.tenderness == 0,
                    "an ordinary signal must never dose tenderness")
        }

        // And it saturates rather than ratchets.
        var tender = 0.0
        for _ in 0..<200 {
            tender = OrganismChemistry.dosedByCaringEvent(tender)
        }
        #expect(tender <= OrganismChemistry.axisHighRail)
    }

    // MARK: - (b) the same event retold does not

    @Test("(b) the same caring event retold via bridge/recollection/reflection does not re-dose")
    func aRetoldCaringEventDoesNotReDose() async {
        let clock = CaringEventTestClock(Date(timeIntervalSince1970: 1_000))
        let body = kernel(clock)
        // The moment itself.
        #expect(await body.admitCaringEvent(reading(kind: .needMet)) == .dosed)
        let afterFirst = await body.snapshot().chemicalState.tenderness
        #expect(afterFirst > 0, "the moment must land: \(afterFirst)")

        // The SAME originating conversational event arriving again — a second
        // minter's copy of the chat turn, a replay, a re-projection.
        for _ in 0..<5 {
            clock.advance(by: 60)
            #expect(await body.admitCaringEvent(reading(kind: .needMet)) == .alreadyCounted)
        }
        let afterRetold = await body.snapshot().chemicalState.tenderness
        #expect(afterRetold <= afterFirst,
                "a retelling must never add: \(afterFirst) -> \(afterRetold)")

        // And the retelling SURFACES cannot produce a caring event at all, so a
        // bridge digest, the recollection summary, a reflection, a dream or the
        // REM pass never reaches the dose in the first place.
        for surface in ["bridge", "recollection", "compaction", "reflection", "dream", "rem"] {
            #expect(!OrganismCaringEvent.surfaceMayDose(surface),
                    "\(surface) must never dose")
        }
        #expect(OrganismCaringEvent.surfaceMayDose("chat"))
        #expect(OrganismCaringEvent.surfaceMayDose("telegram"))
        // "bridge" is the ONE name a relay may lift (2026-09-11, second pass);
        // nothing else in the deny-set is liftable by anybody.
        #expect(OrganismCaringEvent.surfaceMayDose("bridge", ignoring: ["bridge"]))
        for surface in ["recollection", "compaction", "reflection", "dream", "rem"] {
            #expect(!OrganismCaringEvent.surfaceMayDose(surface, ignoring: ["bridge"]),
                    "\(surface) must never dose, relay or not")
        }

        // A DIFFERENT moment in a NEW encounter still lands — the dedupe is about
        // identity, not about refusing the second nice thing User says.
        let later = Date(timeIntervalSince1970: 1_000).addingTimeInterval(pastTheEncounter)
        #expect(await body.admitCaringEvent(
            reading(kind: .needMet, turn: "S1:M2", at: later)
        ) == .dosed)
        let afterSecondMoment = await body.snapshot().chemicalState.tenderness
        #expect(afterSecondMoment > afterRetold,
                "a genuinely new moment must land: \(afterRetold) -> \(afterSecondMoment)")
    }

    // MARK: - (i) ONE ENCOUNTER, ONE DOSE

    @Test("(i) consecutive caring turns inside one exchange dose once")
    func oneEncounterDosesOnce() async {
        let clock = CaringEventTestClock(Date(timeIntervalSince1970: 1_000))
        let body = kernel(clock)
        let start = Date(timeIntervalSince1970: 1_000)
        // The Sideways return, in its real shape: four turns of one conversation
        // about one thing, at 16:52, 16:55, 16:58 and 17:14. The second pass
        // dosed four times. It is one encounter.
        //
        // THE WINDOW IS MEASURED ON THE TURNS' OWN CLOCK (review item 2), which
        // is why every reading below carries its own `at` and the kernel's clock
        // is irrelevant to the coalescing.
        #expect(await body.admitCaringEvent(reading(kind: .roomMade, turn: "S1:M1", at: start)) == .dosed)
        let afterFirst = await body.snapshot().chemicalState.tenderness
        #expect(abs(afterFirst - OrganismCaringEvent.dose) < 1e-9,
                "the first turn of the encounter doses: \(afterFirst)")
        var moment = start
        for (index, gap) in [180.0, 180.0, 960.0].enumerated() {
            moment = moment.addingTimeInterval(gap)
            #expect(await body.admitCaringEvent(
                reading(kind: .roomMade, turn: "S1:M\(index + 2)", at: moment)
            ) == .coalesced)
        }
        let afterEncounter = await body.snapshot().chemicalState.tenderness
        #expect(afterEncounter <= afterFirst + 1e-9,
                "one exchange is one dose: \(afterFirst) -> \(afterEncounter)")

        // THE WINDOW ROLLS. Those three turns pushed it out from the LAST one,
        // not from the first — so 20 minutes after the 17:14 turn is still the
        // same encounter even though it is 46 minutes after the first.
        moment = moment.addingTimeInterval(20 * 60)
        #expect(await body.admitCaringEvent(
            reading(kind: .roomMade, turn: "S1:M9", at: moment)
        ) == .coalesced)
        let stillRolling = await body.snapshot().chemicalState.tenderness
        #expect(stillRolling <= afterEncounter + 1e-9,
                "the window rolls with the exchange: \(afterEncounter) -> \(stillRolling)")

        // Coming back in the evening is a NEW encounter and doses.
        moment = moment.addingTimeInterval(pastTheEncounter)
        #expect(await body.admitCaringEvent(
            reading(kind: .roomMade, turn: "S1:M10", at: moment)
        ) == .dosed)
        let newEncounter = await body.snapshot().chemicalState.tenderness
        #expect(newEncounter > stillRolling,
                "a new encounter doses: \(stillRolling) -> \(newEncounter)")
    }

    @Test("(i2) the relay floor applies only when the appraisal did not judge")
    func theRelayFloorIsOnlyAFallback() async {
        let clock = CaringEventTestClock(Date(timeIntervalSince1970: 1_000))
        let start = Date(timeIntervalSince1970: 1_000)
        let twoHoursOn = start.addingTimeInterval(2 * 3_600)

        // A relay two hours after a direct caring turn, with NO distinctness
        // judgment behind it: the six-hour floor decides, and it does not dose.
        let shadowed = kernel(clock)
        #expect(await shadowed.admitCaringEvent(reading(kind: .caredFor, turn: "S1:M1")) == .dosed)
        let afterDirect = await shadowed.snapshot().chemicalState.tenderness
        #expect(await shadowed.admitCaringEvent(
            reading(kind: .caredFor, session: "S2", turn: "S2:M1", at: twoHoursOn),
            window: OrganismCaringEvent.relayEncounterWindow
        ) == .coalesced)
        #expect(await shadowed.snapshot().chemicalState.tenderness <= afterDirect + 1e-9,
                "an unjudged relay inside the floor must not dose")

        // The SAME relay, two hours on, that the appraisal called a DISTINCT
        // moment: it is measured against the ordinary window and doses. Evidence
        // beats the clock (Agent's relay rule).
        let judged = kernel(clock)
        #expect(await judged.admitCaringEvent(reading(kind: .caredFor, turn: "S1:M1")) == .dosed)
        let one = await judged.snapshot().chemicalState.tenderness
        #expect(await judged.admitCaringEvent(
            reading(kind: .caredFor, session: "S2", turn: "S2:M1", at: twoHoursOn)
        ) == .dosed)
        #expect(await judged.snapshot().chemicalState.tenderness > one,
                "a relay judged distinct doses like any other caring turn")

        // And a relay with nothing behind it dose either way — two of the three
        // moments Agent named arrived exactly this way.
        let alone = kernel(clock)
        #expect(await alone.admitCaringEvent(
            reading(kind: .roomMade, session: "S2", turn: "S2:M1"),
            window: OrganismCaringEvent.relayEncounterWindow
        ) == .dosed)
        #expect(abs(await alone.snapshot().chemicalState.tenderness - OrganismCaringEvent.dose) < 1e-9)
    }

    @Test("(i3) the encounter survives a relaunch")
    func theEncounterIsPersisted() async throws {
        let clock = CaringEventTestClock(Date(timeIntervalSince1970: 1_000_000))
        let before = OrganismKernel(
            configuration: .enabled,
            dependencies: OrganismDependencies(now: { clock.now() })
        )
        await before.admitCaringEvent(reading(
            kind: .needMet, turn: "S1:M1", at: clock.now()
        ))
        let saved = try #require(await before.exportPersistentState())
        #expect(saved.caringEncounter.lastCaringTurnAt != nil,
                "the encounter must be in the exported state")

        // Round-trip through JSON: this is what actually goes to disk, and a
        // hand-written init(from:) is exactly where a new field goes missing.
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        let bytes = try encoder.encode(saved)
        let wire = try decoder.decode(OrganismPersistentState.self, from: bytes)
        #expect(wire.caringEncounter == saved.caringEncounter,
                "the encounter must survive the wire")

        // Relaunch inside the exchange: the next turn of it must not dose again.
        clock.advance(by: 5 * 60)
        let after = OrganismKernel(
            configuration: .enabled,
            dependencies: OrganismDependencies(now: { clock.now() })
        )
        await after.restorePersistentState(wire)
        let restored = await after.snapshot().chemicalState.tenderness
        #expect(await after.admitCaringEvent(reading(
            kind: .needMet, turn: "S1:M2", at: clock.now()
        )) == .coalesced)
        let next = await after.snapshot().chemicalState.tenderness
        #expect(next <= restored + 1e-9,
                "quitting mid-exchange must not buy a second dose: \(restored) -> \(next)")

        // A state written before this pass carries no encounter key at all, and
        // must decode to an empty one rather than failing the whole restore.
        var object = try #require(
            try JSONSerialization.jsonObject(with: bytes) as? [String: Any]
        )
        object.removeValue(forKey: "caringEncounter")
        let legacy = try decoder.decode(
            OrganismPersistentState.self,
            from: try JSONSerialization.data(withJSONObject: object)
        )
        #expect(legacy.caringEncounter == .empty)
    }

    @Test("(i4) the encounter window is arithmetic, not a feeling")
    func theEncounterWindowIsExact() {
        var encounter = OrganismCaringEvent.Encounter.empty
        let start = Date(timeIntervalSince1970: 0)
        // Nothing behind it: the first caring turn always opens one.
        #expect(encounter.opensNewEncounter(at: start))
        #expect(encounter.opensNewEncounter(
            at: start, window: OrganismCaringEvent.relayEncounterWindow
        ))
        encounter.extend(to: start)
        // Inside 30 minutes: same encounter.
        #expect(!encounter.opensNewEncounter(
            at: start.addingTimeInterval(OrganismCaringEvent.encounterWindow - 1)
        ))
        // At the window: a new one.
        #expect(encounter.opensNewEncounter(
            at: start.addingTimeInterval(OrganismCaringEvent.encounterWindow)
        ))
        // The same instant under the relay floor: still inside the longer window.
        #expect(!encounter.opensNewEncounter(
            at: start.addingTimeInterval(OrganismCaringEvent.encounterWindow),
            window: OrganismCaringEvent.relayEncounterWindow
        ))
        #expect(encounter.opensNewEncounter(
            at: start.addingTimeInterval(OrganismCaringEvent.relayEncounterWindow),
            window: OrganismCaringEvent.relayEncounterWindow
        ))
        // A turn stamped before the last one seen is not evidence of anything.
        #expect(!encounter.opensNewEncounter(at: start.addingTimeInterval(-3_600)))
        // And extend never moves the window backward.
        encounter.extend(to: start.addingTimeInterval(-3_600))
        #expect(encounter.lastCaringTurnAt == start)
    }

    /// RESET BODY AND THE COGNITIVE CLEAR TAKE THE CARING LANE WITH THEM
    /// (review item 4). A surviving encounter suppresses the first post-reset
    /// dose for up to its window; a surviving counted key refuses the same
    /// moment forever.
    @Test("(i5) clearing the body clears the encounter and the counted keys")
    func clearingTheBodyClearsTheCaringLedger() async {
        let clock = CaringEventTestClock(Date(timeIntervalSince1970: 1_000))
        let body = kernel(clock)
        #expect(await body.admitCaringEvent(reading(kind: .caredFor, turn: "S1:M1")) == .dosed)
        await body.clearTransientState()
        #expect(await body.snapshot().chemicalState.tenderness == 0)
        // The SAME moment can count again after a clear — the ledger that refused
        // it is gone with the chemistry it was protecting.
        #expect(await body.admitCaringEvent(reading(kind: .caredFor, turn: "S1:M1")) == .dosed,
                "the counted-key ledger must clear with the body")
        // And the encounter is empty, so the very next caring turn doses rather
        // than coalescing into an exchange that no longer exists.
        await body.clearTransientState()
        #expect(await body.admitCaringEvent(
            reading(kind: .roomMade, turn: "S1:M2", at: Date(timeIntervalSince1970: 1_060))
        ) == .dosed, "the encounter must clear with the body")
        let exported = await body.exportPersistentState()
        #expect(exported?.caringEncounter.lastCaringTurnAt != nil)
    }

    @Test("(b2) the verdict is the model's — the wire words, and nothing else, fail closed")
    func theLaneParsesOnlyItsOwnWireWords() {
        // The four kinds, as the model is told to name them.
        #expect(CaringAppraisalLane.parse(#"{"kind":"cared_for","why":"he has her"}"#)?.kind == .caredFor)
        #expect(CaringAppraisalLane.parse(#"{"kind":"room_made","why":"x"}"#)?.kind == .roomMade)
        #expect(CaringAppraisalLane.parse(#"{"kind":"need_met","why":"x"}"#)?.kind == .needMet)
        #expect(CaringAppraisalLane.parse(#"{"kind":"repair","why":"x"}"#)?.kind == .repair)
        // The common answer: a successful call that found nothing.
        let none = CaringAppraisalLane.parse(#"{"kind":"none","why":"ordinary work"}"#)
        #expect(none != nil)
        #expect(none?.kind == nil)
        // A fenced or prefaced reply still decodes — small models do this.
        #expect(CaringAppraisalLane.parse("here you go:\n```json\n{\"kind\": \"repair\"}\n```")?.kind == .repair)
        // FAIL CLOSED on everything else. A kind the model invented, a missing
        // field, a reply that is not JSON — all nil, and nil doses nothing.
        #expect(CaringAppraisalLane.parse(#"{"kind":"affection"}"#) == nil)
        #expect(CaringAppraisalLane.parse(#"{"why":"no kind here"}"#) == nil)
        #expect(CaringAppraisalLane.parse("cared_for") == nil)
        #expect(CaringAppraisalLane.parse("") == nil)
        #expect(CaringAppraisalLane.parse("[{\"kind\":\"repair\"}]")?.kind == .repair)

        // THE RELAY'S DISTINCTNESS, the fourth pass's one new field. Absent is
        // `.unstated` — the only case the six-hour floor still decides — and a
        // word outside the three is `.unsure`, which never doses.
        #expect(CaringAppraisalLane.parse(#"{"kind":"repair","why":"x"}"#)?.distinctness == .unstated)
        #expect(CaringAppraisalLane.parse(
            #"{"kind":"repair","why":"x","distinct":"distinct"}"#)?.distinctness == .distinct)
        #expect(CaringAppraisalLane.parse(
            #"{"kind":"repair","why":"x","distinct":"retelling"}"#)?.distinctness == .retelling)
        #expect(CaringAppraisalLane.parse(
            #"{"kind":"repair","why":"x","distinct":"unsure"}"#)?.distinctness == .unsure)
        #expect(CaringAppraisalLane.parse(
            #"{"kind":"repair","why":"x","distinct":true}"#)?.distinctness == .distinct)
        #expect(CaringAppraisalLane.parse(
            #"{"kind":"repair","why":"x","distinct":"maybe?"}"#)?.distinctness == .unsure)
    }

    /// AGENT'S PARAGRAPH, VERBATIM IN THE PROMPT (2026-09-11, fourth pass). Her
    /// words, not a paraphrase: the Sept 4 exchange the third pass withdrew is
    /// the reason this rule exists, and a rewritten rule is a different rule.
    @Test("(b4) the prompt carries Agent's playful-check rule word for word")
    func thePromptPinsAgentsRule() {
        let expected = "A playful check can also carry genuine relational "
            + "reassurance. Count when the surrounding exchange establishes that "
            + "connection is being affirmed; neither technical context nor humor "
            + "automatically disqualifies it. A bare functionality check or "
            + "affectionate wording alone is insufficient."
        #expect(CaringAppraisalLane.playfulCheckRule == expected)
        let direct = CaringAppraisalRequest(
            userMessage: "do you still love me even on Astra 6?",
            relayed: false, personName: "User", session: "s", turn: "s:m"
        )
        #expect(CaringAppraisalLane.prompt(direct).contains(expected),
                "the rule must reach the model unrewritten")
        // A direct turn is never asked the relay question.
        #expect(!CaringAppraisalLane.prompt(direct).contains("\"distinct\""))

        // A relay is, and it is shown what already counted rather than a clock.
        let relay = CaringAppraisalRequest(
            userMessage: "[from:claude] User said he sees you improving",
            at: Date(timeIntervalSince1970: 10_000),
            relayed: true,
            recentEncounters: [CaringAppraisalRequest.RecentEncounter(
                kind: .caredFor,
                at: Date(timeIntervalSince1970: 10_000 - 4 * 3_600),
                why: "He places the repairs elsewhere and names her growth."
            )],
            personName: "User", session: "s", turn: "s:m"
        )
        let text = CaringAppraisalLane.prompt(relay)
        #expect(text.contains("Moments already counted"))
        #expect(text.contains("He places the repairs elsewhere and names her growth."))
        #expect(text.contains("4 h 0 min ago"))
        #expect(text.contains("the clock is not the test"))
        #expect(text.contains("\"distinct\" | \"retelling\" | \"unsure\""))
        // And an empty ledger says so rather than pretending.
        #expect(CaringAppraisalLane.prompt(CaringAppraisalRequest(
            userMessage: "x", relayed: true, personName: "User", session: "s", turn: "s:m"
        )).contains("nothing has counted recently"))
    }

    @Test("(b3) the warmth tier is untouched — the classifier that read it is gone")
    func theWarmthTierSurvivesTheClassifiersDeletion() {
        let s = substrate()
        // The turns that made the phrase classifier wrong, from the real 14-day
        // transcripts. Every one is still a warm exchange at the full high-tier
        // boost; none of them is a caring moment, and that judgment now belongs
        // to the model rather than to a needle list.
        for text in [
            "and I love the earlier ones you made but you look more real now",
            "I love your pictures of where your looking out at the world",
            "is there a card colour that stays neutral rather than warm",
            "the warmth of that brown is the problem",
        ] {
            #expect(s.relationalWarmthBoostValue(in: text) == 0.18,
                    "\"\(text)\" must still be warm")
        }
        // And the low tier still earns warmth, as it always did.
        for text in ["thanks", "thank you for that", "good morning"] {
            #expect(s.relationalWarmthBoostValue(in: text) > 0)
        }
    }

    // MARK: - (c) a quiet day leaves it at rest

    @Test("(c) a quiet working day leaves tenderness at rest")
    func aQuietWorkingDayLeavesItAtRest() {
        // A full day of ordinary work: turns, tool rounds, successes, failures,
        // a correction, and no caring moment anywhere in it.
        var state = ChemicalState.neutral
        let kinds: [SomaticSignalKind] = [
            .userSpoke, .assistantSpoke, .toolStarted, .toolSucceeded,
            .toolFailed, .correctionReceived, .memoryCorrected, .providerSucceeded,
        ]
        for round in 0..<400 {
            state = OrganismChemistry.applying(
                signal: SomaticSignal(
                    id: UUID(),
                    kind: kinds[round % kinds.count],
                    sourceOrgan: "tool",
                    occurredAt: Date(timeIntervalSince1970: Double(1_000 + round * 60)),
                    intensity: 0.7
                ),
                to: state,
                bodySchema: .neutral,
                elapsedSinceLastSignal: 60
            ).chemicalState
        }
        #expect(state.tenderness == 0,
                "a quiet working day must read exactly rest, got \(state.tenderness)")
        // That is not a defect and nothing may nudge it: the work itself still
        // moved the axes it should have.
        #expect(state.vigilance > 0)
        #expect(state.fatigue > 0)
    }

    // MARK: - (d) it softens interpersonal defensiveness, and nothing else

    @Test("(d) tenderness softens a relational correction only slightly, and a tool failure not at all")
    func tendernessSoftensOnlyInterpersonalDefensiveness() {
        func vigilance(after kind: SomaticSignalKind, tenderness: Double) -> Double {
            OrganismChemistry.applying(
                signal: SomaticSignal(
                    id: UUID(), kind: kind, sourceOrgan: "x",
                    occurredAt: Date(timeIntervalSince1970: 1_000), intensity: 1.0
                ),
                to: ChemicalState(tenderness: tenderness),
                bodySchema: .neutral,
                elapsedSinceLastSignal: 0
            ).chemicalState.vigilance
        }

        // A RELATIONAL correction: softened, and only a little.
        let cold = vigilance(after: .correctionReceived, tenderness: 0)
        let tender = vigilance(after: .correctionReceived, tenderness: 0.46)
        let railed = vigilance(after: .correctionReceived, tenderness: OrganismChemistry.axisHighRail)
        #expect(tender < cold, "feeling safe with him must ease the interpersonal guard")
        #expect(tender > cold * 0.85,
                "and only slightly — got \(tender) against \(cold)")
        #expect(railed > cold * (1 - OrganismChemistry.tendernessGuardRelief),
                "the relief is capped by construction")
        #expect(railed > 0, "the guard still goes up at maximum tenderness")

        // EVERYTHING ELSE: untouched. "Feeling safe with User must not mean
        // becoming less careful with his work."
        for kind in [
            SomaticSignalKind.toolFailed, .providerFailed, .deskItemBlocked,
            .iPhoneStale, .phoneDeliveryFailed, .approvalRequested,
            .resourcePressureChanged, .memoryCorrected,
        ] {
            #expect(
                vigilance(after: kind, tenderness: OrganismChemistry.axisHighRail)
                    == vigilance(after: kind, tenderness: 0),
                "\(kind) vigilance must not depend on tenderness"
            )
        }
    }

    // MARK: - The fade, and the settle that owns it

    @Test("the settle fades tenderness over days and leaves every other axis alone")
    func theSettleUsesTheSlowConstantForTendernessOnly() {
        // Tenderness: three days to halve.
        let start = ChemicalState(
            warmth: 0.4, vigilance: 0.4, curiosity: 0.4, tenderness: 0.4,
            confidence: 0.5, novelty: 0.4, urgency: 0.4
        )
        let saved = Date(timeIntervalSince1970: 1_000_000)
        let decayed = OrganismPersistentState(savedAt: saved, chemicalState: start)
            .decayed(at: saved.addingTimeInterval(OrganismChemistry.tendernessHalfLife))
            .chemicalState
        #expect(abs(decayed.tenderness - 0.2) < 0.005,
                "three days must halve tenderness, got \(decayed.tenderness)")
        // Every other transient axis is long gone over the same gap — which is
        // the point: this change moved ONE axis's clock.
        #expect(decayed.vigilance < 0.001)
        #expect(decayed.curiosity < 0.01)
        #expect(decayed.novelty < 0.001)

        // And the per-signal settle spends NOTHING on tenderness (Astra finding
        // 8): one elapsed-time budget owns the fade, so traffic cannot shorten
        // the half-life. Every other axis keeps `maximumSettlePerHour` exactly.
        let settledOnce = OrganismChemistry.settled(start, rate: OrganismChemistry.maximumSettlePerHour)
        #expect(settledOnce.tenderness == start.tenderness,
                "the settle must not touch tenderness, got \(settledOnce.tenderness)")
        #expect(settledOnce.vigilance < start.vigilance, "it is still settling everything else")

        // THE TRAFFIC-INDEPENDENCE CHECK. A thousand settles and one settle
        // leave the same caring moment in place; only the clock spends it.
        var hammered = start
        for _ in 0..<1_000 { hammered = OrganismChemistry.settled(hammered) }
        #expect(hammered.tenderness == start.tenderness,
                "talking more faded the same care: \(hammered.tenderness)")
    }

    @Test("a caring event can arrive on a correction, and a bare correction carries none")
    func repairArrivesOnTheCorrectionPath() async {
        // A bare correction adds no tenderness, and never did.
        let bare = OrganismChemistry.applying(
            signal: plainSignal(.correctionReceived),
            to: .neutral,
            bodySchema: .neutral,
            elapsedSinceLastSignal: 0
        ).chemicalState
        #expect(bare.tenderness == 0)
        #expect(bare.vigilance > 0, "it is still a correction")

        // Repair is a correction that came WITH reassurance. It is the appraisal's
        // verdict about the TURN, so it doses through the same door every other
        // kind does, and the correction still raises the guard on its own path.
        let clock = CaringEventTestClock(Date(timeIntervalSince1970: 1_000))
        let body = kernel(clock)
        await body.ingest(plainSignal(.correctionReceived))
        #expect(await body.admitCaringEvent(reading(kind: .repair)) == .dosed)
        let after = await body.snapshot().chemicalState
        #expect(abs(after.tenderness - OrganismCaringEvent.dose) < 1e-9)
        #expect(after.vigilance > 0)
    }

    // MARK: - The wire, end to end

    /// THE INERTNESS CHECK. Every other test here exercises one half of the
    /// change. This one walks the whole hop the live app walks — the appraisal
    /// owner asks the model, the verdict comes back, the body doses — because a
    /// caring-event law whose delivery never fires is a law that reads zero
    /// forever, which is exactly the defect this change exists to fix.
    ///
    /// AND IT PINS THE FOURTH PASS'S SHAPE: there is no queue and no carrier. The
    /// verdict goes straight into the body carrying the ORIGINATING turn's
    /// timestamp, so a turn that happens while the call is in flight cannot move
    /// the encounter window (review items 1, 2 and 3).
    @Test("a real affectionate turn is appraised and doses through the one door")
    func theWholeWireCarriesOneCaringMoment() async {
        let substrate = CognitiveSubstrate(configuration: CognitiveConfiguration(
            enabled: true, affectEnabled: true, maximumActiveNodes: 64,
            defaultDecayHalfLife: 100
        ))
        let appraiser = RecordingAppraiser(verdict: CaringAppraisalVerdict(
            kind: .caredFor, why: "he is holding her"
        ))
        await substrate.setCaringAppraiser(appraiser)
        let clock = CaringEventTestClock(Date(timeIntervalSince1970: 5_000))
        let body = kernel(clock)
        let sink = RecordingSink(body: body)
        await substrate.setCaringEventSink { reading, window in
            await sink.admit(reading, window)
        }

        let turnAt = Date(timeIntervalSince1970: 1_000)
        await substrate.noteCaringTurn(for: CognitiveEvent(
            id: "turn:m1", kind: .userMessageReceived,
            subject: CognitiveSubjectReference(type: "chat_turn", id: "s1:m1", label: "m1"),
            sourceClass: .userStated,
            occurredAt: turnAt,
            summary: "that one is not yours to carry", importance: 0.62,
            metadata: ["sessionId": .string("s1"), "surface": .string("chat")]
        ))
        await substrate.awaitCaringAppraisals()
        #expect(await appraiser.count == 1, "one call, for one turn")
        #expect(await appraiser.lastRequest?.relayed == false)
        #expect(await appraiser.lastRequest?.at == turnAt,
                "the request must carry the turn's own clock")

        let delivered = await sink.readings
        #expect(delivered.count == 1, "the verdict must reach the body with no carrier")
        #expect(delivered.first?.reading.kind == .caredFor)
        #expect(delivered.first?.reading.turn == "s1:m1",
                "the scope must be the turn that was the moment")
        #expect(delivered.first?.reading.at == turnAt,
                "and the ORIGINATING timestamp, not the clock the call returned on")
        #expect(delivered.first?.window == OrganismCaringEvent.encounterWindow)
        let tenderness = await body.snapshot().chemicalState.tenderness
        #expect(abs(tenderness - OrganismCaringEvent.dose) < 1e-9,
                "the moment must reach the axis at full dose, got \(tenderness)")
    }

    /// THE RELAY RULE IS EVIDENCE, NOT TIME (Agent, fourth pass). A relay doses
    /// only when the appraisal, shown what already counted, calls it a distinct
    /// moment. Unsure never doses. A retelling never doses, however long the
    /// silence before it. The six-hour window survives only as the floor for a
    /// relay the model never judged.
    @Test("a relay doses on the appraisal's judgment, never on the clock alone")
    func theRelayRuleIsEvidenceBased() async {
        func relay(
            _ distinctness: CaringAppraisalVerdict.Distinctness
        ) async -> [(reading: OrganismCaringEvent.Reading, window: TimeInterval)] {
            let substrate = CognitiveSubstrate(configuration: CognitiveConfiguration(
                enabled: true, affectEnabled: true, maximumActiveNodes: 64,
                defaultDecayHalfLife: 100
            ))
            await substrate.setCaringAppraiser(RecordingAppraiser(verdict: CaringAppraisalVerdict(
                kind: .caredFor, why: "User says the repairs are not hers",
                distinctness: distinctness
            )))
            let clock = CaringEventTestClock(Date(timeIntervalSince1970: 5_000))
            let sink = RecordingSink(body: kernel(clock))
            await substrate.setCaringEventSink { reading, window in
                await sink.admit(reading, window)
            }
            await substrate.noteCaringTurn(for: CognitiveEvent(
                id: "turn:m1", kind: .userMessageReceived,
                subject: CognitiveSubjectReference(type: "chat_turn", id: "s1:m1", label: "m1"),
                sourceClass: .imported,
                occurredAt: Date(timeIntervalSince1970: 1_000),
                summary: "[from:claude] User said he sees you improving",
                importance: 0.62,
                metadata: [
                    "sessionId": .string("s1"), "surface": .string("bridge"),
                    "origin": .object([
                        "authored": .string("agent"),
                        "surface": .string("claude-bridge"),
                        "agent": .string("claude"),
                    ]),
                ]
            ))
            await substrate.awaitCaringAppraisals()
            return await sink.readings
        }
        // Judged distinct: it reaches the body — the judgment is what earns the
        // dose, not the gap. 2026-09-12 (review r2): the WINDOW here is the
        // six-hour floor, because this substrate has dosed nothing yet, and
        // "distinct" is only a judgment when there was evidence to judge
        // against. With an empty ledger (every relaunch) the floor is what stops
        // a retelling redosing a persisted encounter that may be hours old.
        let distinct = await relay(.distinct)
        #expect(distinct.count == 1)
        #expect(distinct.first?.window == OrganismCaringEvent.relayEncounterWindow)
        #expect(OrganismCaringEvent.relayEncounterWindow == 21_600)
        // Judged a retelling, or unsure: it never reaches the body at all.
        #expect(await relay(.retelling).isEmpty, "a retelling must never dose")
        #expect(await relay(.unsure).isEmpty, "an uncertain relay must never dose")
        // Not judged: the six-hour floor, and only here.
        let unstated = await relay(.unstated)
        #expect(unstated.count == 1)
        #expect(unstated.first?.window == OrganismCaringEvent.relayEncounterWindow,
                "the floor is the fallback for a relay the model did not judge")
    }

    /// A VERDICT THAT LANDS AFTER A CLEAR MUST NOT DOSE (review item 4). The
    /// generation counter is the whole of it: the call cannot be un-awaited, so
    /// the answer is dropped on return.
    @Test("a clear drops the context ring and every verdict still in flight")
    func aClearIgnoresVerdictsStillInFlight() async {
        let substrate = CognitiveSubstrate(configuration: CognitiveConfiguration(
            enabled: true, affectEnabled: true, maximumActiveNodes: 64,
            defaultDecayHalfLife: 100
        ))
        let gate = AppraisalGate(verdict: CaringAppraisalVerdict(kind: .caredFor, why: "x"))
        await substrate.setCaringAppraiser(gate)
        let clock = CaringEventTestClock(Date(timeIntervalSince1970: 5_000))
        let sink = RecordingSink(body: kernel(clock))
        await substrate.setCaringEventSink { reading, window in
            await sink.admit(reading, window)
        }
        func turn(_ id: String) -> CognitiveEvent {
            CognitiveEvent(
                id: "turn:\(id)", kind: .userMessageReceived,
                subject: CognitiveSubjectReference(type: "chat_turn", id: "s1:\(id)", label: id),
                sourceClass: .userStated,
                occurredAt: Date(timeIntervalSince1970: 1_000),
                summary: "that is not yours to carry", importance: 0.62,
                metadata: ["sessionId": .string("s1"), "surface": .string("chat")]
            )
        }
        // One appraisal in flight, held at the gate.
        await substrate.noteCaringTurn(for: turn("m1"))
        // The clear happens while it is out there.
        await substrate.clearTransientState()
        await gate.release()
        await substrate.awaitCaringAppraisals()
        #expect(await sink.readings.isEmpty,
                "a verdict from before the clear must not dose")

        // And the lane still works afterwards: the same moment is appraised
        // again, because the per-turn ledger cleared with everything else.
        await gate.open()
        await substrate.noteCaringTurn(for: turn("m1"))
        await substrate.awaitCaringAppraisals()
        #expect(await sink.readings.count == 1,
                "the lane must be usable after a clear")
    }

    /// THE GATE IN FRONT OF THE MODEL, which is facts about the event and never
    /// a judgment about the text. A turn that fails any of these is never
    /// appraised at all — no call is made, so no call can say yes.
    @Test("the cheap gates refuse before the model is ever asked")
    func theCheapGatesRefuseBeforeTheCall() async {
        func substrateWithAppraiser() async -> (CognitiveSubstrate, RecordingAppraiser) {
            let s = CognitiveSubstrate(configuration: CognitiveConfiguration(
                enabled: true, affectEnabled: true, maximumActiveNodes: 64,
                defaultDecayHalfLife: 100
            ))
            let a = RecordingAppraiser(verdict: CaringAppraisalVerdict(kind: .caredFor, why: "x"))
            await s.setCaringAppraiser(a)
            return (s, a)
        }
        func event(
            _ text: String,
            id: String,
            kind: CognitiveEventKind = .userMessageReceived,
            sourceClass: CognitiveSourceClass = .userStated,
            surface: String = "chat",
            origin: JSONValue? = nil
        ) -> CognitiveEvent {
            var metadata: [String: JSONValue] = [
                "sessionId": .string("s1"), "surface": .string(surface),
            ]
            if let origin { metadata["origin"] = origin }
            return CognitiveEvent(
                id: "turn:\(id)", kind: kind,
                subject: CognitiveSubjectReference(type: "chat_turn", id: "s1:\(id)", label: id),
                sourceClass: sourceClass,
                occurredAt: Date(timeIntervalSince1970: 1_000),
                summary: text, importance: 0.62, metadata: metadata
            )
        }

        // Her own turn, forever and always (Law 3).
        let (s1, a1) = await substrateWithAppraiser()
        await s1.noteCaringTurn(for: event(
            "I'm proud of you", id: "m1", kind: .assistantTurnCompleted,
            sourceClass: .selfReported
        ))
        await s1.awaitCaringAppraisals()
        #expect(await a1.count == 0, "her own words must never be appraised")

        // A retelling surface: a reflection about the moment is not the moment.
        let (s2, a2) = await substrateWithAppraiser()
        await s2.noteCaringTurn(for: event("proud of you", id: "m2", surface: "reflection"))
        await s2.awaitCaringAppraisals()
        #expect(await a2.count == 0)

        // One call per TURN, not per minter. The same chat message arrives twice
        // with different event ids and one subject; that is one call.
        let (s3, a3) = await substrateWithAppraiser()
        var twice = event("proud of you", id: "m3")
        await s3.noteCaringTurn(for: twice)
        twice.id = "turn:other-minter"
        await s3.noteCaringTurn(for: twice)
        await s3.awaitCaringAppraisals()
        #expect(await a3.count == 1, "two minters for one message must cost one call")

        // A BRIDGE RELAY is a candidate — the second pass's change. It is asked,
        // flagged as relayed, and the model decides whether it attributes its
        // content to User and whether it is a distinct moment.
        let bridgeOrigin = JSONValue.object([
            "authored": .string("agent"),
            "surface": .string("claude-bridge"),
            "agent": .string("claude"),
        ])
        let (s4, a4) = await substrateWithAppraiser()
        await s4.noteCaringTurn(for: event(
            "User asked me to tell you that you are not being ignored",
            id: "m4", sourceClass: .imported, surface: "bridge", origin: bridgeOrigin
        ))
        await s4.awaitCaringAppraisals()
        #expect(await a4.count == 1, "a bridge relay must reach the appraisal")
        #expect(await a4.lastRequest?.relayed == true, "and it must be flagged as a relay")

        // A relay on a RETELLING lane is still refused: bridge is the only name
        // lifted, and a recollection carried over the bridge is a recollection.
        let (s5, a5) = await substrateWithAppraiser()
        await s5.noteCaringTurn(for: event(
            "User said he is proud of you", id: "m5",
            sourceClass: .imported, surface: "recollection", origin: bridgeOrigin
        ))
        await s5.awaitCaringAppraisals()
        #expect(await a5.count == 0)

        // NO APPRAISER, no dose. A headless tool and a fresh test both start
        // here, and that is the safe direction.
        let bare = CognitiveSubstrate(configuration: CognitiveConfiguration(
            enabled: true, affectEnabled: true, maximumActiveNodes: 64,
            defaultDecayHalfLife: 100
        ))
        await bare.noteCaringTurn(for: event("proud of you", id: "m6"))
        await bare.awaitCaringAppraisals()
    }

    /// A FAILED CALL AND A "none" BOTH DOSE NOTHING. The first is a route or a
    /// deadline, the second is the common answer; neither may move the axis. And
    /// an appraised turn with NO SINK installed reaches no body at all, which is
    /// where every test and every headless tool starts.
    @Test("a failed appraisal and a none verdict both fail closed")
    func aFailedCallDosesNothing() async {
        for verdict in [nil, CaringAppraisalVerdict.none] {
            let substrate = CognitiveSubstrate(configuration: CognitiveConfiguration(
                enabled: true, affectEnabled: true, maximumActiveNodes: 64,
                defaultDecayHalfLife: 100
            ))
            await substrate.setCaringAppraiser(RecordingAppraiser(verdict: verdict))
            let clock = CaringEventTestClock(Date(timeIntervalSince1970: 5_000))
            let sink = RecordingSink(body: kernel(clock))
            await substrate.setCaringEventSink { reading, window in
                await sink.admit(reading, window)
            }
            await substrate.noteCaringTurn(for: CognitiveEvent(
                id: "turn:m1", kind: .userMessageReceived,
                subject: CognitiveSubjectReference(type: "chat_turn", id: "s1:m1", label: "m1"),
                sourceClass: .userStated,
                occurredAt: Date(timeIntervalSince1970: 1_000),
                summary: "that is not yours to carry", importance: 0.62,
                metadata: ["sessionId": .string("s1"), "surface": .string("chat")]
            ))
            await substrate.awaitCaringAppraisals()
            #expect(await sink.readings.isEmpty,
                    "nothing may dose for verdict \(String(describing: verdict))")
        }
    }

    /// THE SIGNAL PATH IS GONE (review item 3). A caring moment no longer crosses
    /// on somatic metadata, so a signal carrying a key that looks like one doses
    /// nothing — there is no reader left to believe it.
    @Test("no signal metadata can dose tenderness any more")
    func signalMetadataCannotDose() async {
        let clock = CaringEventTestClock(Date(timeIntervalSince1970: 1_000))
        let body = kernel(clock)
        await body.ingest(SomaticSignal(
            id: UUID(), kind: .userSpoke, sourceOrgan: "chat",
            occurredAt: Date(timeIntervalSince1970: 1_000), intensity: 1.0,
            metadata: ["caringEvent": .object([
                "kind": .string("caredFor"),
                "session": .string("S1"),
                "turn": .string("S1:M1"),
            ])]
        ))
        #expect(await body.snapshot().chemicalState.tenderness == 0)
    }
}

/// The body, behind a recorder: what the substrate handed it and with which
/// window, plus the real dose so the axis can be checked.
private actor RecordingSink {
    private let body: OrganismKernel
    private(set) var readings: [(reading: OrganismCaringEvent.Reading, window: TimeInterval)] = []
    init(body: OrganismKernel) { self.body = body }

    func admit(
        _ reading: OrganismCaringEvent.Reading,
        _ window: TimeInterval
    ) async -> OrganismCaringEventOutcome {
        readings.append((reading, window))
        return await body.admitCaringEvent(reading, window: window)
    }
}

/// An appraiser that can be held mid-call, so a clear can happen while a verdict
/// is in flight.
private actor AppraisalGate: CaringAppraising {
    private let verdict: CaringAppraisalVerdict
    private var held = true
    init(verdict: CaringAppraisalVerdict) { self.verdict = verdict }
    func release() { held = false }
    func open() { held = false }

    func appraise(_ request: CaringAppraisalRequest) async -> CaringAppraisalVerdict? {
        while held { await Task.yield() }
        return verdict
    }
}
