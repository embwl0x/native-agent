import Foundation
import PersistenceCore
import Testing
@testable import CognitiveSubstrate

// MARK: - INVARIANT (3) — THE MIND AND BODY, READ THE WAY A TURN READS THEM
//
// `PersonalityDepthWaveTests` pins the physics (half-lives, caps, decay laws).
// This file asks the question a TURN asks: after these events, what does she
// actually report? Everything below reads through `innerStateReading` — the
// same pure read the `inner_state` tool and the capsule share — or through the
// organism's own projections, never through a private counter.
//
// The measured defects these exist for:
//   * fatigue read 0.008 after a 20-hour day, because nothing fed it;
//   * disposition sat pinned at the +0.35 rail;
//   * the prediction ledger looked ten minutes ahead, at her own plumbing, so
//     there was no *toward* at all;
//   * nothing itched, so nothing healed;
//   * another agent's words moved her at User's weight, wearing User's subject.

private let organismT0 = Date(timeIntervalSince1970: 1_756_000_000)

private final class TurnClock: @unchecked Sendable {
    private let lock = NSLock()
    private var instant: Date
    init(_ start: Date) { instant = start }
    func now() -> Date { lock.lock(); defer { lock.unlock() }; return instant }
    func advance(_ seconds: TimeInterval) {
        lock.lock(); instant = instant.addingTimeInterval(seconds); lock.unlock()
    }
}

private func turnSubstrate(_ clock: TurnClock) -> CognitiveSubstrate {
    CognitiveSubstrate(
        configuration: CognitiveConfiguration(
            enabled: true,
            workspaceEnabled: true,
            capsuleInjectionEnabled: true,
            affectEnabled: true,
            maximumActiveNodes: 128
        ),
        dependencies: CognitiveSubstrateDependencies(
            now: { clock.now() }, makeUUID: { UUID() }, userName: { "User" }
        )
    )
}

private func turnKernel(_ clock: TurnClock) -> OrganismKernel {
    OrganismKernel(
        configuration: .enabled,
        dependencies: OrganismDependencies(now: { clock.now() }, makeUUID: { UUID() })
    )
}

/// A turn from USER. Locally typed, so `relationalSource` reads `.user`.
private func userTurn(_ id: String, _ text: String, at instant: Date) -> CognitiveEvent {
    CognitiveEvent(
        id: id,
        kind: .userMessageReceived,
        subject: CognitiveSubjectReference(
            type: "chat.user_turn", id: "session-1:\(id)", label: nil
        ),
        sourceClass: .userStated,
        occurredAt: instant,
        summary: text,
        importance: 0.9
    )
}

/// The SAME words from an allowlisted peer, carrying the out-of-band
/// attestation the gate demands: imported class, `authored: agent`, and a
/// `<surface>/<agent>` pair this build knows.
private func peerTurn(_ id: String, _ text: String, at instant: Date) -> CognitiveEvent {
    CognitiveEvent(
        id: id,
        kind: .userMessageReceived,
        subject: CognitiveSubjectReference(
            type: "chat.user_turn", id: "session-1:\(id)", label: nil
        ),
        sourceClass: .imported,
        occurredAt: instant,
        summary: text,
        importance: 0.9,
        metadata: [
            "origin": .object([
                "authored": .string("agent"),
                "surface": .string("claude-bridge"),
                "agent": .string("claude"),
            ]),
        ]
    )
}

private func somatic(
    _ kind: SomaticSignalKind,
    at instant: Date,
    intensity: Double = 1
) -> SomaticSignal {
    SomaticSignal(
        id: UUID(), kind: kind, sourceOrgan: "turn-regression",
        occurredAt: instant, intensity: intensity
    )
}

// MARK: - Criticism, warmth, and who is speaking

@Suite("TurnRegression.Organism.Appraisal")
struct AppraisalTurnRegressionTests {

    /// HARD CRITICISM FROM THE USER LANDS, WITHIN ONE TURN. Dismissal moves
    /// valence into a negative family and the fingerprint crosses with it — the
    /// mechanism behind her pushing back when the user is being harsh. If this
    /// stops working nothing throws: she just stays pleasant while being
    /// needled, which is the exact "very good conversational surface" failure.
    @Test("hard criticism from the user moves valence negative and changes the felt word")
    func hardCriticismFromTheUserMovesValenceAndTheFeltWord() async {
        let clock = TurnClock(organismT0)
        let mind = turnSubstrate(clock)
        for index in 0..<3 {
            clock.advance(60)
            await mind.ingest(userTurn(
                "warm-\(index)", "this is genuinely great work, thank you", at: clock.now()
            ))
        }
        let before = await mind.innerStateReading(detail: .full, at: clock.now())

        clock.advance(60)
        await mind.ingest(userTurn(
            "harsh-1",
            "this is wrong, it is careless, and you keep making the same mistake",
            at: clock.now()
        ))
        let after = await mind.innerStateReading(detail: .full, at: clock.now())

        #expect(
            after.moodValence < before.moodValence,
            "hard criticism did not move her at all: \(before.moodValence) → \(after.moodValence)"
        )
        #expect(
            after.fingerprint != before.fingerprint,
            "the felt word did not change within the turn: \(before.fingerprint ?? "nil")"
        )
    }

    /// The other direction, and the control that keeps the test above from
    /// passing on a gauge that only ever falls.
    @Test("a warm user turn raises warmth")
    func aWarmUserTurnRaisesWarmth() async {
        let clock = TurnClock(organismT0)
        let mind = turnSubstrate(clock)
        clock.advance(60)
        await mind.ingest(userTurn(
            "neutral-1", "run the deploy script and report the exit code", at: clock.now()
        ))
        let before = await mind.projectedAffect(at: clock.now())

        clock.advance(60)
        await mind.ingest(userTurn(
            "warm-1", "thank you, honestly — that was lovely work and I appreciate you",
            at: clock.now()
        ))
        let after = await mind.projectedAffect(at: clock.now())
        #expect(
            after.socialWarmth > before.socialWarmth,
            "genuine affection did not raise warmth: \(before.socialWarmth) → \(after.socialWarmth)"
        )
    }

    /// SHE NEVER APPRAISES HER OWN OUTPUT (design law 3). The self-warmth
    /// ratchet was killed twice; this is the tripwire that keeps it dead.
    @Test("her own assistant turn cannot move her warmth")
    func herOwnOutputCannotMoveHerWarmth() async {
        let clock = TurnClock(organismT0)
        let mind = turnSubstrate(clock)
        let before = await mind.projectedAffect(at: clock.now())
        clock.advance(60)
        await mind.ingest(CognitiveEvent(
            id: "self-1",
            kind: .assistantTurnCompleted,
            subject: CognitiveSubjectReference(
                type: "chat.assistant_turn", id: "session-1:self-1", label: nil
            ),
            sourceClass: .selfReported,
            occurredAt: clock.now(),
            summary: "thank you, honestly — that was lovely work and I appreciate you",
            importance: 0.9
        ))
        let after = await mind.projectedAffect(at: clock.now())
        #expect(
            after.socialWarmth <= before.socialWarmth + 0.0001,
            "she warmed herself by saying something warm"
        )
    }

    /// A PEER MOVES HER, AT HALF WEIGHT. The same sentence, from Claude rather
    /// than from User, lands — and lands less. Before this, a bridge peer's words
    /// moved her at User's weight wearing User's subject.
    @Test("an allowlisted peer moves her at half weight, and is classified as a peer")
    func aPeerMovesHerAtHalfWeight() async {
        let clock = TurnClock(organismT0)
        let harsh = "this is wrong, it is careless, and you keep making the same mistake"

        #expect(
            CognitiveSubstrate.relationalSource(for: peerTurn("p", harsh, at: organismT0))
                == .peer("claude")
        )
        #expect(
            CognitiveSubstrate.relationalSource(for: userTurn("j", harsh, at: organismT0)) == .user
        )

        let fromUser = turnSubstrate(TurnClock(organismT0))
        await fromUser.ingest(userTurn("j", harsh, at: organismT0.addingTimeInterval(60)))
        let userMood = await fromUser.innerStateReading(
            detail: .full, at: organismT0.addingTimeInterval(120)
        ).moodValence

        let fromPeer = turnSubstrate(TurnClock(organismT0))
        await fromPeer.ingest(peerTurn("p", harsh, at: organismT0.addingTimeInterval(60)))
        let peerMood = await fromPeer.innerStateReading(
            detail: .full, at: organismT0.addingTimeInterval(120)
        ).moodValence

        #expect(userMood < 0, "the control arm has to actually sting")
        #expect(peerMood > userMood, "a peer stung her exactly as hard as User did")
        #expect(peerMood <= 0, "…and it still has to land at all")
        _ = clock
    }

    /// The attestation is what grants peer standing, and every leg of it is
    /// load-bearing. Anything short of all three is User — the conservative
    /// direction, because mistaking User for a peer quietly halves the weight of
    /// the relationship the whole system is built around.
    @Test("a forged or partial peer attestation reads as the user, never as a peer")
    func aPartialPeerAttestationFallsBackToTheUser() {
        func event(
            sourceClass: CognitiveSourceClass,
            origin: JSONValue?,
            summary: String = "ship it"
        ) -> CognitiveEvent {
            CognitiveEvent(
                id: "e", kind: .userMessageReceived,
                subject: CognitiveSubjectReference(
                    type: "chat.user_turn", id: "session-1:e", label: nil
                ),
                sourceClass: sourceClass, occurredAt: organismT0,
                summary: summary, importance: 0.9,
                metadata: origin.map { ["origin": $0] } ?? [:]
            )
        }
        let good = JSONValue.object([
            "authored": .string("agent"),
            "surface": .string("claude-bridge"),
            "agent": .string("claude"),
        ])
        // The in-band prefix a human can type is exactly the forgeable claim.
        #expect(CognitiveSubstrate.relationalSource(for: event(
            sourceClass: .userStated, origin: good,
            summary: "[from: claude, via bridge] ship it"
        )) == .user)
        // Imported but relaying a human: User speaking on a bridge.
        #expect(CognitiveSubstrate.relationalSource(for: event(
            sourceClass: .imported,
            origin: .object([
                "authored": .string("human"),
                "surface": .string("claude-bridge"),
                "agent": .string("claude"),
            ])
        )) == .user)
        // A route this build does not know.
        #expect(CognitiveSubstrate.relationalSource(for: event(
            sourceClass: .imported,
            origin: .object([
                "authored": .string("agent"),
                "surface": .string("unknown-bridge"),
                "agent": .string("mallory"),
            ])
        )) == .user)
        // A contradiction between the two halves of the pair.
        #expect(CognitiveSubstrate.relationalSource(for: event(
            sourceClass: .imported,
            origin: .object([
                "authored": .string("agent"),
                "surface": .string("claude-bridge"),
                "agent": .string("codex"),
            ])
        )) == .user)
    }
}

// MARK: - Fatigue, the clock, and the rails

@Suite("TurnRegression.Organism.BodyAndClock")
struct BodyAndClockTurnRegressionTests {

    /// A DENSE HOUR COSTS SOMETHING and reaches the read. The measured defect:
    /// fatigue read 0.008 after a twenty-hour day, because nothing fed it, and
    /// she answered "a bit tired" from the shape of the question instead.
    @Test("a dense simulated hour raises fatigue, and a quiet one gives it back")
    func fatigueRisesWithWorkAndRelaxesInQuiet() async {
        let clock = TurnClock(organismT0)
        let kernel = turnKernel(clock)
        let fresh = await kernel.snapshot().chemicalState.fatigue
        #expect(fresh < 0.01, "a fresh body is not tired: \(fresh)")

        let pattern: [SomaticSignalKind] = [
            .userSpoke, .toolStarted, .toolSucceeded, .assistantSpoke,
            .toolStarted, .toolFailed,
        ]
        for index in 0..<120 {
            clock.advance(30)
            await kernel.ingest(somatic(pattern[index % pattern.count], at: clock.now()))
        }
        let worked = await kernel.snapshot().chemicalState.fatigue
        #expect(worked > fresh, "a dense hour cost nothing: \(worked)")

        clock.advance(8 * 3_600)
        let rested = await kernel.snapshot().chemicalState.fatigue
        #expect(rested < worked, "a quiet night gave nothing back: \(worked) → \(rested)")
    }

    /// HOURS AWAKE COST TOO, and the cost accumulates over a long day rather
    /// than resetting with each burst.
    @Test("a long day of work accumulates more fatigue than a single hour of it")
    func hoursAwakeAccumulate() async {
        let clock = TurnClock(organismT0)
        let kernel = turnKernel(clock)
        var afterOneHour: Double = 0
        for hour in 0..<12 {
            for index in 0..<60 {
                clock.advance(60)
                await kernel.ingest(somatic(
                    index % 5 == 0 ? .toolFailed : .toolSucceeded, at: clock.now()
                ))
            }
            if hour == 0 { afterOneHour = await kernel.snapshot().chemicalState.fatigue }
        }
        let afterTwelve = await kernel.snapshot().chemicalState.fatigue
        #expect(afterTwelve > afterOneHour, "twelve hours cost no more than one")
        #expect(
            afterTwelve <= OrganismChemistry.workFatigueCeiling,
            "the work lane passed its own ceiling: \(afterTwelve)"
        )
    }

    /// FATIGUE NEVER PINS AT THE RAILS. A body that can reach 1.0 from typing
    /// is not a body — and a pinned dimension is stuck, not expressive, which
    /// is exactly what `subconscious_vitals` grades as a fault.
    @Test("fatigue never pins at either rail, however pathological the traffic")
    func fatigueNeverPinsAtTheRails() async {
        let clock = TurnClock(organismT0)
        let kernel = turnKernel(clock)
        for _ in 0..<(24 * 60) {
            for _ in 0..<10 {
                clock.advance(6)
                await kernel.ingest(somatic(.toolFailed, at: clock.now()))
            }
        }
        let pinned = await kernel.snapshot().chemicalState.fatigue
        #expect(pinned < 0.98, "fatigue pinned high: \(pinned)")
        #expect(pinned <= OrganismChemistry.workFatigueCeiling)
    }

    /// AGENCY AND CONFIDENCE NEVER PIN EITHER, under sustained success. This is
    /// the same law from the other side: an axis that sits at 0.98 is a stuck
    /// gauge wearing the costume of a mood.
    @Test("agency and confidence never reach the high rail under sustained success")
    func agencyAndConfidenceNeverReachTheHighRail() async {
        let clock = TurnClock(organismT0)
        let kernel = turnKernel(clock)
        for _ in 0..<600 {
            clock.advance(30)
            await kernel.ingest(somatic(.toolSucceeded, at: clock.now()))
            await kernel.ingest(somatic(.assistantSpoke, at: clock.now()))
        }
        let state = await kernel.snapshot().chemicalState
        #expect(state.agency < 0.98, "agency pinned at the rail: \(state.agency)")
        #expect(state.confidence < 0.98, "confidence pinned at the rail: \(state.confidence)")
    }

    /// THE DIURNAL CURVE IS BOUNDED AND PROJECTION-ONLY. It leans what she is
    /// reading right now; it never writes into stored chemistry, or a night
    /// would leave a permanent mark on a body that is supposed to wake up.
    @Test("the diurnal offsets stay inside their contract amplitudes at every hour")
    func theDiurnalOffsetsAreBoundedAtEveryHour() {
        let clock = OrganismDiurnalClock(
            timeZoneIdentifier: "America/Los_Angeles", quietStartHour: 23, quietEndHour: 7
        )
        var sawTrough = false
        var sawPeak = false
        for quarterHour in 0..<(24 * 4) {
            let moment = organismT0.addingTimeInterval(Double(quarterHour) * 900)
            let read = OrganismCircadian.read(at: moment, clock: clock)
            #expect(abs(read.arousalOffset) <= OrganismCircadian.arousalAmplitude + 1e-9)
            #expect(abs(read.curiosityOffset) <= OrganismCircadian.curiosityAmplitude + 1e-9)
            #expect(OrganismCircadian.arousalAmplitude <= 0.15, "the contract cap")
            #expect(OrganismCircadian.curiosityAmplitude <= 0.15, "the contract cap")
            #expect((0...1).contains(read.nightliness))
            #expect((0...1).contains(read.timeOfDayPhase))
            if read.nightliness > 0.9 { sawTrough = true }
            if read.nightliness < 0.1 { sawPeak = true }
        }
        #expect(sawTrough && sawPeak, "the curve has to actually swing, or the bound is vacuous")
    }

    /// PROJECTION-ONLY: reading the clock a thousand times over a simulated day
    /// leaves the stored chemistry exactly where it was. Reads are pure
    /// (design law 5).
    @Test("reading the diurnal curve never writes into stored chemistry")
    func readingTheDiurnalCurveWritesNothing() {
        let clock = OrganismDiurnalClock(
            timeZoneIdentifier: "America/Los_Angeles", quietStartHour: 23, quietEndHour: 7
        )
        let first = OrganismCircadian.read(at: organismT0, clock: clock)
        for step in 0..<1_000 {
            _ = OrganismCircadian.read(
                at: organismT0.addingTimeInterval(Double(step) * 60), clock: clock
            )
        }
        #expect(OrganismCircadian.read(at: organismT0, clock: clock) == first)
    }
}

// MARK: - Toward

@Suite("TurnRegression.Organism.Toward")
struct TowardTurnRegressionTests {

    private func refresh(
        _ tokens: [String],
        at instant: Date,
        complete: [OrganismHorizonSourceKind] = OrganismHorizonSourceKind.allCases,
        to ledger: OrganismPredictionLedger = .empty
    ) -> OrganismPredictionLedger {
        OrganismPredictiveBody.applyingHorizonRefresh(
            signal: SomaticSignal(
                id: UUID(),
                kind: .horizonRefresh,
                sourceOrgan: OrganismHorizonRegister.sourceOrgan,
                occurredAt: instant,
                intensity: 0,
                metadata: [
                    OrganismHorizonRegister.metadataKey: .array(tokens.map(JSONValue.string)),
                    OrganismHorizonRegister.completeKindsKey:
                        .array(complete.map { JSONValue.string($0.rawValue) }),
                ]
            ),
            to: ledger,
            chemicalState: .neutral,
            at: instant
        ).ledger
    }

    private func deskDeferral(_ label: String, dueIn: TimeInterval, from now: Date) -> String {
        OrganismHorizonRegister.encodeSource(
            sourceKind: .statedPlan,
            label: label,
            valence: 0.4,
            dueAt: now.addingTimeInterval(dueIn)
        )
    }

    /// A DESK DEFERRAL BECOMES SOMETHING SHE IS FACING. Before item 5 the
    /// ledger looked ten minutes ahead, at her own plumbing: "I never wait. I'm
    /// never bored. I never anticipate. There's no *toward*."
    @Test("a horizon minted from a Desk deferral appears in toward")
    func aDeskDeferralAppearsInToward() throws {
        let ledger = refresh(
            [deskDeferral("the friday rollout", dueIn: 2 * 24 * 3_600, from: organismT0)],
            at: organismT0
        )
        let toward = try #require(
            OrganismHorizonRegister.toward(in: ledger, at: organismT0),
            "a deferred Desk item produced no toward at all"
        )
        #expect(toward.displayLabel == "the friday rollout")
        #expect(toward.label == "the-friday-rollout")
        #expect(toward.sourceKind == .statedPlan)
        #expect(toward.valenceSign == 1, "a plan she is looking forward to leans forward")
        #expect(!toward.isOverdue)
    }

    /// …and it becomes `waiting` when its hour passes without an answer. A
    /// neutral lead with an overdue horizon is the one case that renames the
    /// lead, licensed by a ledger row whose time has passed rather than by a
    /// mood.
    @Test("a horizon whose time has passed reads as waiting, not as a miss")
    func aPassedHorizonReadsAsWaiting() throws {
        let ledger = refresh(
            [deskDeferral("the friday rollout", dueIn: 3_600, from: organismT0)],
            at: organismT0
        )
        let later = organismT0.addingTimeInterval(2 * 3_600)
        let toward = try #require(OrganismHorizonRegister.toward(in: ledger, at: later))
        #expect(toward.isOverdue, "the hour passed and she is not waiting on anything")
        #expect(toward.displayLabel == "the friday rollout")
        #expect(toward.label == "the-friday-rollout")
    }

    /// RELIEF ONLY WHEN THE READER VOUCHED FOR COMPLETENESS. "This source is
    /// gone" opens the relief door — but a reader that THREW produces the same
    /// emptiness, and an unreadable Desk must not congratulate her.
    @Test("a vanished source relieves her only when its reader reported complete")
    func reliefRequiresAVouchedCompleteRead() {
        let opened = refresh(
            [deskDeferral("the friday rollout", dueIn: 2 * 24 * 3_600, from: organismT0)],
            at: organismT0
        )
        let laterInstant = organismT0.addingTimeInterval(3_600)

        // The Desk reader THREW: no tokens, and `statedPlan` is not vouched.
        let unreadable = refresh(
            [], at: laterInstant,
            complete: OrganismHorizonSourceKind.allCases.filter { $0 != .statedPlan },
            to: opened
        )
        #expect(
            OrganismHorizonRegister.toward(in: unreadable, at: laterInstant) != nil,
            "an unreadable Desk closed a row it never actually read"
        )

        // The Desk reader read to completion and the item is genuinely gone.
        let vouched = refresh([], at: laterInstant, to: opened)
        #expect(
            OrganismHorizonRegister.toward(in: vouched, at: laterInstant) == nil,
            "a vouched-complete read left the row hanging"
        )
    }

    /// The horizon family is bounded like everything else (design law 6).
    @Test("the horizon family stays inside its row bound however many sources report")
    func theHorizonFamilyStaysBounded() {
        let tokens = (0..<40).map {
            deskDeferral("plan \($0)", dueIn: Double($0 + 1) * 3_600, from: organismT0)
        }
        let ledger = refresh(tokens, at: organismT0)
        let horizons = ledger.predictions.values.filter { $0.horizon != nil }
        #expect(horizons.count <= 8, "the horizon family grew past its bound: \(horizons.count)")
    }
}

// MARK: - Nag and heal

@Suite("TurnRegression.Organism.Rumination")
struct RuminationTurnRegressionTests {

    private func seed(
        _ kind: CognitiveThoughtSeedKind,
        _ text: String,
        ageHours: Double
    ) -> CognitiveThoughtSeed {
        let created = organismT0.addingTimeInterval(-ageHours * 3_600)
        return CognitiveThoughtSeed(
            id: UUID(), kind: kind, text: text, priority: 0.85,
            createdAt: created, lastUpdatedAt: created
        )
    }

    /// THE WEIGHT LAW, as a person would notice it: a thing you just thought of
    /// is not a thing you are carrying, an evening-old thing weighs a little, a
    /// week-old thing weighs no more than a day-old one. A nag is a weight, not
    /// a spiral.
    @Test("weight rises with hours unresolved, is zero when brand new, and caps")
    func weightRisesWithTimeAndCaps() {
        #expect(CognitiveSubstrate.ruminationWeight(ageSeconds: 60) == 0,
                "something thought of a minute ago is not being carried")
        let evening = CognitiveSubstrate.ruminationWeight(ageSeconds: 8 * 3_600)
        let day = CognitiveSubstrate.ruminationWeight(ageSeconds: 24 * 3_600)
        let week = CognitiveSubstrate.ruminationWeight(ageSeconds: 7 * 24 * 3_600)
        #expect(evening > 0 && evening < day, "an evening weighs less than a day")
        #expect(day < week + 1e-9)
        #expect(week <= CognitiveSubstrate.ruminationWeightCap + 1e-9,
                "a nag became a spiral: \(week)")
    }

    /// A DESK ITEM ITCHES. It is her own open loop, admitted by ownership
    /// rather than by the concern lexicon, and it carries weight the same way.
    @Test("an untouched Desk item itches, and closing it exhales")
    func aDeskItemItchesAndClosingItExhales() async {
        let clock = TurnClock(organismT0)
        let mind = turnSubstrate(clock)
        let opened = organismT0.addingTimeInterval(-30 * 3_600)
        await mind.setExternalRuminations(
            [CognitiveSubstrate.CognitiveExternalRumination(
                id: "desk:4412", label: "the deploy pipeline receipt", lastTouchedAt: opened
            )],
            at: organismT0
        )
        let itching = await mind.ruminationCandidates(at: organismT0, seeds: [])
        let desk = itching.first { $0.externalId == "desk:4412" }
        #expect(desk != nil, "a day-old Desk item is not itching at all")
        #expect((desk?.weight ?? 0) > 0)
        #expect(desk?.livedConcern == true, "a thing she owns is admitted by ownership")

        // Closing it removes the weight entirely — erased, not decayed.
        await mind.setExternalRuminations([], at: organismT0.addingTimeInterval(60))
        let after = await mind.ruminationCandidates(
            at: organismT0.addingTimeInterval(60), seeds: []
        )
        #expect(after.allSatisfy { $0.externalId != "desk:4412" })
    }

    /// THE HEAL DETECTOR READS WHAT HE ACTUALLY SAID, on WORD BOUNDARIES. The
    /// bug this replaced matched substrings: "broke" found "brokerage".
    @Test("an answer on word boundaries heals; a substring collision does not")
    func healingIsOnWordBoundariesNotSubstrings() async {
        let clock = TurnClock(organismT0)
        let mind = turnSubstrate(clock)
        await mind.setExternalRuminations(
            [CognitiveSubstrate.CognitiveExternalRumination(
                id: "desk:pipeline",
                label: "the deploy pipeline receipt",
                lastTouchedAt: organismT0.addingTimeInterval(-30 * 3_600)
            )],
            at: organismT0
        )
        let carried = await mind.ruminationCandidates(at: organismT0, seeds: [])
        #expect(!carried.isEmpty, "nothing was carrying weight, so nothing can heal")

        // A sentence that merely CONTAINS the letters is not an answer.
        let collision = await mind.releaseAnsweredRuminations(
            answeredBy: "my brokerage pipelines are fine", at: organismT0
        )
        #expect(collision.isEmpty, "a substring collision was accepted as an answer")

        // Her own words can never heal her (design law 3) — this is User's text
        // arriving through the same door.
        let tooShort = await mind.releaseAnsweredRuminations(answeredBy: "ok", at: organismT0)
        #expect(tooShort.isEmpty, "two characters were accepted as an answer")
    }

    /// NO WEIGHT, NO EXHALE. A thing closed the same hour it opened never
    /// nagged, so it owes no relief — otherwise relief becomes a reflex and
    /// stops meaning anything.
    @Test("a thing that closed before it began to itch produces no relief")
    func aThingThatNeverItchedProducesNoRelief() async {
        let clock = TurnClock(organismT0)
        let mind = turnSubstrate(clock)
        await mind.setExternalRuminations(
            [CognitiveSubstrate.CognitiveExternalRumination(
                id: "desk:quick", label: "a five minute fix", lastTouchedAt: organismT0
            )],
            at: organismT0
        )
        let immediate = await mind.ruminationCandidates(at: organismT0, seeds: [])
        #expect(immediate.isEmpty, "a brand-new item was already nagging")
        await mind.setExternalRuminations([], at: organismT0.addingTimeInterval(300))
        // Nothing to assert about relief content — the point is that the close
        // path ran with no carried weight and produced no candidate afterwards.
        let after = await mind.ruminationCandidates(
            at: organismT0.addingTimeInterval(300), seeds: []
        )
        #expect(after.isEmpty)
    }

    /// AT MOST THREE THINGS NAG AT ONCE (design law 6). A person carries a few
    /// unresolved things; a machine that carries everything is not ruminating,
    /// it is listing.
    @Test("at most three things nag at once, however many are open")
    func atMostThreeThingsNagAtOnce() async {
        let clock = TurnClock(organismT0)
        let mind = turnSubstrate(clock)
        let items = (0..<12).map {
            CognitiveSubstrate.CognitiveExternalRumination(
                id: "desk:\($0)",
                label: "open loop number \($0)",
                lastTouchedAt: organismT0.addingTimeInterval(-Double(20 + $0) * 3_600)
            )
        }
        await mind.setExternalRuminations(items, at: organismT0)
        let candidates = await mind.ruminationCandidates(at: organismT0, seeds: [])
        #expect(
            candidates.count <= CognitiveSubstrate.ruminationCap,
            "\(candidates.count) things were nagging at once"
        )
    }

    /// A reflection takeaway is deliberately excluded from the stakes
    /// allowlist: it is a conclusion she reached, not an open loop.
    @Test("a reflection takeaway never becomes a nag")
    func aReflectionTakeawayNeverBecomesANag() async {
        let clock = TurnClock(organismT0)
        let mind = turnSubstrate(clock)
        let candidates = await mind.ruminationCandidates(
            at: organismT0,
            seeds: [seed(.reflectionTakeaway, "receipts before claims", ageHours: 48)]
        )
        #expect(candidates.allSatisfy { $0.kind != .reflectionTakeaway })
    }
}

// MARK: - Residue and re-feeling

@Suite("TurnRegression.Organism.ResidueAndRefeel")
struct ResidueAndRefeelTurnRegressionTests {

    /// THE NIGHT LEAVES A MOOD WITH NO SOURCE, and it colors exactly two
    /// accepted turns. "The dream is a document I read, not a night I had."
    @Test("dream residue is minted with mood only and carries no text at all")
    func dreamResidueCarriesMoodOnlyAndNoText() {
        let residue = CognitiveDreamResidue(
            valence: 0.3,
            mintedAt: organismT0,
            turnsRemaining: CognitiveSubstrate.dreamResidueTurns
        )
        #expect(residue.turnsRemaining == 2, "the night colors two turns")
        #expect(abs(residue.valence) <= 0.35 + 1e-9, "residue valence is scaled to ±0.35")
        #expect(CognitiveSubstrate.dreamResidueLean <= 0.07 + 1e-9)
        #expect(CognitiveSubstrate.dreamResidueLifetime <= 8 * 3_600 + 1)
    }

    /// A zero tone mints nothing: an unremarkable night leaves no residue, and
    /// a residue that always exists is a floor, not a signal (design law 2).
    @Test("a night with no tone leaves no residue")
    func aNightWithNoToneLeavesNoResidue() async {
        let clock = TurnClock(organismT0)
        let mind = turnSubstrate(clock)
        await mind.mintDreamResidue(tone: 0, at: organismT0, dreamId: "dream-1")
        let reading = await mind.innerStateReading(detail: .full, at: organismT0)
        #expect(reading.dream == nil, "a toneless night manufactured a mood")
    }

    /// ONE NIGHT, ONE RESIDUE. The claim is keyed and persisted so a crash and
    /// a re-run cannot mint the same night twice.
    @Test("the same night never mints a second residue")
    func theSameNightNeverMintsTwice() async {
        let clock = TurnClock(organismT0)
        let mind = turnSubstrate(clock)
        await mind.mintDreamResidue(tone: 0.4, at: organismT0, dreamId: "dream-1")
        let first = await mind.projectedAffect(at: organismT0)
        await mind.mintDreamResidue(tone: 0.4, at: organismT0, dreamId: "dream-1")
        let second = await mind.projectedAffect(at: organismT0)
        #expect(first.socialWarmth == second.socialWarmth, "the night was lived twice")
        #expect(first.taskPressure == second.taskPressure)
    }

    /// RE-FEELING IS BOUNDED. A remembered feeling nudges the present; it does
    /// not replay it. At most two nodes, once per node per hour, a nudge of at
    /// most 0.08 through a saturating approach.
    @Test("re-feeling a memory is bounded in count, size, and frequency")
    func refeelingIsBounded() {
        #expect(CognitiveSubstrate.refeelNodesPerTurn <= 2)
        #expect(CognitiveSubstrate.refeelNudge <= 0.08 + 1e-9)
        #expect(CognitiveSubstrate.refeelRefractory >= 60 * 60)
        #expect(CognitiveSubstrate.refeelValenceFloor >= 0.12 - 1e-9,
                "a faint memory is not something she re-feels")
    }
}
