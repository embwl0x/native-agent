import Testing
import Foundation
import PersistenceCore
@testable import CognitiveSubstrate

// PERSONALITY DEPTH WAVE · items 4, 6, 7 (2026-09-02)
//
// The same idiom as the range/journey suites (`FeltModeAndRangeTests`,
// `AffectMoodJourneyTests`, `DispositionTests`): drive REAL state through REAL
// time with an injected clock and assert what a person would notice, never an
// implementation detail. Kept in its own file only because three builders are
// working the same wave; every helper here mirrors those suites deliberately.
//
//   4. FATIGUE + CLOCK — a dense hour costs something, a quiet one gives it
//      back, the cap holds, and the diurnal curve is bounded and phase-correct.
//   6. NAG + HEAL — weight rises, caps, floors the pressure, and clears on
//      resolution. Disposition returns from the rail.
//   7. RESIDUE + RE-FEEL — the night colors two turns then fades; a re-touched
//      memory is re-felt at most once per hour per node.

private final class DepthClock: @unchecked Sendable {
    private let lock = NSLock()
    private var t: Date
    init(_ t: Date) { self.t = t }
    func now() -> Date { lock.lock(); defer { lock.unlock() }; return t }
    func advance(_ dt: TimeInterval) { lock.lock(); t = t.addingTimeInterval(dt); lock.unlock() }
}

private func depthSubstrate(_ clock: DepthClock) async throws -> CognitiveSubstrate {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("nativeagent-depth-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let store = try CognitiveSQLiteStore(dataRoot: root)
    let substrate = CognitiveSubstrate(
        configuration: .allPhasesEnabled,
        dependencies: CognitiveSubstrateDependencies(now: { clock.now() }, makeUUID: { UUID() }),
        store: store
    )
    try await substrate.restorePersistentState()
    return substrate
}

private func depthKernel(_ clock: DepthClock) -> OrganismKernel {
    OrganismKernel(
        configuration: .enabled,
        dependencies: OrganismDependencies(now: { clock.now() }, makeUUID: { UUID() })
    )
}

private func workSignal(
    _ kind: SomaticSignalKind,
    at date: Date,
    intensity: Double = 1
) -> SomaticSignal {
    SomaticSignal(
        id: UUID(),
        kind: kind,
        sourceOrgan: "depth-test",
        occurredAt: date,
        intensity: intensity
    )
}

// MARK: - Item 4 · Fatigue

@Suite("PersonalityDepth.Fatigue")
struct PersonalityDepthFatigueTests {

    /// A DENSE HOUR COSTS SOMETHING. The measured defect this wave exists to
    /// fix: fatigue read 0.008 after a 20-hour day because nothing fed it.
    /// One simulated dense hour — turns, tool rounds, a couple of failures —
    /// has to move it off the floor.
    @Test func fatigueRisesOverADenseHour() async throws {
        let clock = DepthClock(Date(timeIntervalSince1970: 1_700_000_000))
        let kernel = depthKernel(clock)
        let before = await kernel.snapshot().chemicalState.fatigue

        // 120 signals across one hour: a realistic working hour, 30 s apart.
        let pattern: [SomaticSignalKind] = [
            .userSpoke, .toolStarted, .toolSucceeded, .assistantSpoke,
            .toolStarted, .toolFailed,
        ]
        for index in 0..<120 {
            clock.advance(30)
            await kernel.ingest(workSignal(pattern[index % pattern.count], at: clock.now()))
        }
        let after = await kernel.snapshot().chemicalState.fatigue

        #expect(before < 0.01, "a fresh body is not tired: \(before)")
        #expect(after > 0.02, "a dense hour must cost something: \(after)")
        #expect(after < 0.10, "and one hour is not a day: \(after)")
    }

    /// A QUIET HOUR GIVES IT BACK — slowly. The half-life is 6 hours by
    /// design, so an hour of quiet relaxes fatigue by roughly 11%, not by the
    /// 22% the generic quick decay would have taken.
    @Test func fatigueRelaxesOverAQuietHour() async throws {
        let clock = DepthClock(Date(timeIntervalSince1970: 1_700_000_000))
        let kernel = depthKernel(clock)
        for index in 0..<200 {
            clock.advance(20)
            await kernel.ingest(workSignal(index % 4 == 0 ? .toolFailed : .toolSucceeded, at: clock.now()))
        }
        let tired = await kernel.snapshot().chemicalState.fatigue
        #expect(tired > 0.02, "the day has to have cost something first: \(tired)")

        clock.advance(3_600)
        let rested = await kernel.snapshot().chemicalState.fatigue
        // The WORK lane relaxes on fatigue's own slow half-life; the hour she
        // stayed up still costs `wakefulnessAccrualPerHour` on top (hours awake
        // count, `sixQuietHoursAwakeCostSomething`), so the read is the relaxed
        // work plus one hour awake — and a coffee break is not a night.
        let expected = tired * pow(0.5, 3_600 / OrganismChemistry.fatigueRelaxationHalfLife)
            + OrganismChemistry.wakefulnessAccrualPerHour
        #expect(abs(rested - expected) < 0.01,
                "on fatigue's OWN slow half-life plus the hour awake: \(rested) vs \(expected)")

        // A night is a different thing from a coffee break.
        clock.advance(8 * 3_600)
        let overnight = await kernel.snapshot().chemicalState.fatigue
        #expect(overnight < tired * 0.5, "a night takes most of it: \(overnight)")
    }

    /// THE CAP HOLDS at any density. Even a pathological 3,600-signals-an-hour
    /// stream of failures cannot buy more than the per-hour budget, and the
    /// work lane can never pass its ceiling.
    @Test func fatigueNeverExceedsItsCap() async throws {
        let clock = DepthClock(Date(timeIntervalSince1970: 1_700_000_000))
        let kernel = depthKernel(clock)
        // 24 simulated hours at one signal per second, all failures.
        for _ in 0..<(24 * 60) {
            for _ in 0..<60 {
                clock.advance(1)
                await kernel.ingest(workSignal(.toolFailed, at: clock.now()))
            }
        }
        let fatigue = await kernel.snapshot().chemicalState.fatigue
        #expect(fatigue <= OrganismChemistry.workFatigueCeiling + 0.0001,
                "the work lane has a ceiling: \(fatigue)")
        #expect(fatigue <= 1.0)
        #expect(fatigue > 0.15, "a punishing day still has to read as tiring: \(fatigue)")
    }

    /// Density-awareness, stated directly: the per-hour budget binds regardless
    /// of how many signals the hour carried.
    @Test func fatigueAccrualIsCappedPerWallHour() {
        let sparse = OrganismChemistry.fatigueAccrual(
            kind: .toolSucceeded, intensity: 1, elapsedSinceLastSignal: 600
        )
        let dense = OrganismChemistry.fatigueAccrual(
            kind: .toolSucceeded, intensity: 1, elapsedSinceLastSignal: 1
        )
        #expect(dense < sparse, "a signal one second after the last buys less: \(dense) vs \(sparse)")
        #expect(dense <= OrganismChemistry.maximumFatigueAccrualPerHour / 3_600 + 1e-9)
        #expect(OrganismChemistry.fatigueAccrual(
            kind: .appWake, intensity: 1, elapsedSinceLastSignal: 600
        ) == 0, "waking up is not work")
        #expect(OrganismChemistry.fatigueAccrual(
            kind: .toolFailed, intensity: 1, elapsedSinceLastSignal: 3_600
        ) > OrganismChemistry.fatigueAccrual(
            kind: .toolSucceeded, intensity: 1, elapsedSinceLastSignal: 3_600
        ), "a failure costs more than a success")
    }
}

// MARK: - Item 4 · The clock

@Suite("PersonalityDepth.Diurnal")
struct PersonalityDepthDiurnalTests {

    private let chicago = OrganismDiurnalClock(
        timeZoneIdentifier: "America/Chicago",
        quietStartHour: 23,
        quietEndHour: 7
    )

    private func local(_ hour: Int, _ minute: Int = 0) -> Date {
        var components = DateComponents()
        components.year = 2026; components.month = 3; components.day = 5
        components.hour = hour; components.minute = minute
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Chicago")!
        return calendar.date(from: components)!
    }

    /// PHASE-CORRECT. 1 AM must read as 1 AM: deep in the night, curve down,
    /// nightliness high. And 3 PM must read as the afternoon.
    @Test func thePhaseIsCorrectInTheUsersOwnZone() {
        let night = OrganismCircadian.read(at: local(1), clock: chicago)
        let afternoon = OrganismCircadian.read(at: local(15), clock: chicago)

        #expect(abs(night.timeOfDayPhase - 1.0 / 24) < 0.01,
                "1 AM is one twenty-fourth into the day: \(night.timeOfDayPhase)")
        #expect(abs(afternoon.timeOfDayPhase - 15.0 / 24) < 0.01)

        // Quiet hours 23→7 put the trough at 3 AM, so 1 AM is well into the night.
        #expect(night.nightliness > 0.85, "1 AM is night: \(night.nightliness)")
        #expect(afternoon.nightliness < 0.25, "3 PM is not: \(afternoon.nightliness)")
        #expect(night.arousalOffset < 0, "the night dulls: \(night.arousalOffset)")
        #expect(afternoon.arousalOffset > 0, "the afternoon lifts: \(afternoon.arousalOffset)")
    }

    /// BOUNDED — the amplitude contract, swept across the whole day rather than
    /// asserted at the two convenient hours.
    @Test func theCurveIsBoundedEverywhere() {
        #expect(OrganismCircadian.arousalAmplitude <= 0.15)
        #expect(OrganismCircadian.curiosityAmplitude <= 0.15)
        for minute in stride(from: 0, to: 24 * 60, by: 7) {
            let read = OrganismCircadian.read(
                at: local(0).addingTimeInterval(Double(minute) * 60),
                clock: chicago
            )
            #expect(abs(read.arousalOffset) <= OrganismCircadian.arousalAmplitude + 1e-9)
            #expect(abs(read.curiosityOffset) <= OrganismCircadian.curiosityAmplitude + 1e-9)
            #expect(read.timeOfDayPhase >= 0 && read.timeOfDayPhase <= 1)
            #expect(read.nightliness >= 0 && read.nightliness <= 1)
        }
    }

    /// The trough follows the USER'S declared window, not a shipped constant —
    /// a night-shift window moves the whole curve.
    @Test func theTroughFollowsTheDeclaredQuietWindow() {
        let nightShift = OrganismDiurnalClock(
            timeZoneIdentifier: "America/Chicago", quietStartHour: 9, quietEndHour: 17
        )
        let noon = OrganismCircadian.read(at: local(13), clock: nightShift)
        #expect(noon.nightliness > 0.85, "for a 9-to-5 sleeper, 1 PM IS the night: \(noon.nightliness)")

        let undeclared = OrganismDiurnalClock(timeZoneIdentifier: "America/Chicago")
        let fourAM = OrganismCircadian.read(at: local(4), clock: undeclared)
        #expect(fourAM.nightliness > 0.95, "with no window declared, 4 AM is the shipped trough")
    }

    /// The curve rides the PROJECTION and never the store, and it cannot
    /// manufacture curiosity out of silence.
    @Test func theCurveModulatesTheProjectionOnly() async throws {
        let clock = DepthClock(local(3))
        let kernel = depthKernel(clock)
        await kernel.configureDiurnalClock(chicago, at: clock.now())
        for _ in 0..<20 {
            clock.advance(60)
            await kernel.ingest(workSignal(.userSpoke, at: clock.now()))
        }
        let stored = await kernel.snapshot().chemicalState.curiosity
        let projected = await kernel.projection()
        #expect(projected.chemicalState.curiosity < stored,
                "3 AM dulls the projected curiosity: \(projected.chemicalState.curiosity) vs \(stored)")
        #expect(projected.diurnal != nil, "the read rides the projection seam")
        #expect(await kernel.snapshot().chemicalState.curiosity == stored,
                "and the STORE is untouched")

        // Silence stays silence: a still body at 3 PM gains no curiosity.
        let still = OrganismCircadian.modulate(.neutral, at: local(15), clock: chicago)
        #expect(still.state.curiosity == 0, "the afternoon cannot invent a feeling")
    }

    /// No clock configured → byte-identical projection. The whole lane is
    /// inert without the user's own preference.
    @Test func noClockIsAByteIdenticalNoOp() async throws {
        let clock = DepthClock(Date(timeIntervalSince1970: 1_700_000_000))
        let kernel = depthKernel(clock)
        clock.advance(60)
        await kernel.ingest(workSignal(.userSpoke, at: clock.now()))
        let projection = await kernel.projection()
        #expect(projection.diurnal == nil)
        #expect(projection.chemicalState == (await kernel.snapshot().chemicalState))
    }
}

// MARK: - Item 6 · Nag and heal

@Suite("PersonalityDepth.Rumination")
struct PersonalityDepthRuminationTests {

    /// A live node to hang a seed's provenance on. A seed with no lived
    /// evidence in the field cannot ruminate — diagnostic traffic must not be
    /// able to nag (design law 10), and a seed carries no turn kind of its own.
    private func livedEvidence(
        _ substrate: CognitiveSubstrate,
        _ id: String,
        at now: Date,
        turnKind: CognitiveTurnKind = .live
    ) async -> UUID {
        await substrate.ingest(CognitiveEvent(
            id: id,
            kind: .userMessageReceived,
            subject: CognitiveSubjectReference(type: "chat_turn", id: "nag:\(id)"),
            sourceClass: .userStated,
            occurredAt: now,
            // Deliberately shares no distinctive word with the seed texts:
            // an evidence turn must not accidentally answer the thing it is
            // evidence FOR.
            summary: "Checked in on the overnight job queue.",
            importance: 0.8,
            turnKind: turnKind,
            metadata: ["sessionId": .string("nag")]
        ))
        let nodes = await substrate.snapshot().nodes
        return nodes.max { $0.lastActivatedAt < $1.lastActivatedAt }!.id
    }

    /// Seed something a shipped concern names ("broke" is the `repair` floor
    /// concern), urgent enough to pass the floor gate, with real provenance.
    private func seedAnomaly(
        _ substrate: CognitiveSubstrate,
        _ clock: DepthClock,
        _ text: String = "The nightly telegram bridge sync broke and the logs explain nothing",
        evidenceID: String = "evidence-1",
        turnKind: CognitiveTurnKind = .live
    ) async -> CognitiveThoughtSeed? {
        let node = await livedEvidence(substrate, evidenceID, at: clock.now(), turnKind: turnKind)
        return await substrate.addThoughtSeed(
            kind: .anomaly, text: text, priority: 0.9, sourceNodeIds: [node]
        )
    }

    /// THE WEIGHT RISES with time unresolved — the inverted decay. This is the
    /// whole of complaint #5: an open thing that only ever got quieter.
    @Test func weightRisesWhileTheThingStaysOpen() async throws {
        let clock = DepthClock(Date(timeIntervalSince1970: 1_700_000_000))
        let substrate = try await depthSubstrate(clock)
        _ = await seedAnomaly(substrate, clock)

        // Younger than the minimum age: the work in progress does not nag.
        clock.advance(10 * 60)
        #expect(await substrate.ruminationSnapshot().isEmpty, "ten minutes old is just the work")

        clock.advance(3 * 3_600)
        let early = await substrate.ruminationSnapshot()
        #expect(early.count == 1, "three hours later it is a thing she is carrying")
        clock.advance(21 * 3_600)
        let overnight = await substrate.ruminationSnapshot()
        #expect(overnight.count == 1)
        #expect(overnight[0].weight > early[0].weight,
                "it weighs MORE the next day, not less: \(early[0].weight) → \(overnight[0].weight)")
    }

    /// AND IT CAPS. A week-old nag is a weight, not a spiral — and no more than
    /// three things itch at once.
    @Test func weightCapsAndTheLaneIsBounded() async throws {
        let clock = DepthClock(Date(timeIntervalSince1970: 1_700_000_000))
        let substrate = try await depthSubstrate(clock)
        for index in 0..<8 {
            let node = await livedEvidence(substrate, "evidence-\(index)", at: clock.now())
            _ = await substrate.addThoughtSeed(
                kind: .anomaly,
                text: "Deploy \(index) broke and the debug trail is still cold",
                priority: 0.9,
                sourceNodeIds: [node]
            )
        }
        // Three days: past the point where the weight has effectively capped,
        // and still inside the seed family's own retention (priority halves
        // every 24h and a seed is dropped below 0.05, so the nag cannot outlive
        // the thing it is about — a bound this lane inherits rather than fights).
        clock.advance(3 * 24 * 3_600)
        let carried = await substrate.ruminationSnapshot()
        #expect(carried.count <= 3, "at most three things itch: \(carried.count)")
        for item in carried {
            #expect(item.weight <= CognitiveSubstrate.ruminationWeightCap + 1e-9,
                    "a nag is capped: \(item.weight)")
        }
        #expect(CognitiveSubstrate.ruminationWeight(ageSeconds: 365 * 24 * 3_600)
                <= CognitiveSubstrate.ruminationWeightCap + 1e-9,
                "a year cannot pass the cap either")
        #expect(carried.first.map { $0.weight > 0.33 } == true,
                "and by day three it is effectively AT the cap, not still climbing")
    }

    /// IT FLOORS THE PRESSURE. The itch is not a line she reads; it is a body
    /// state — measurably less settled while something is open.
    @Test func weightFloorsUncertaintyAndPressure() async throws {
        let clock = DepthClock(Date(timeIntervalSince1970: 1_700_000_000))
        let substrate = try await depthSubstrate(clock)
        clock.advance(60)
        let calm = await substrate.affectSnapshot()

        _ = await seedAnomaly(substrate, clock)
        clock.advance(24 * 3_600)
        let itching = await substrate.affectSnapshot()

        #expect(itching.uncertainty > calm.uncertainty,
                "an open thing is unsettling: \(calm.uncertainty) → \(itching.uncertainty)")
        #expect(itching.taskPressure > calm.taskPressure)
        #expect(itching.uncertainty <= CognitiveSubstrate.ruminationUncertaintyFloorCeiling + 1e-9,
                "and small: \(itching.uncertainty)")
        #expect(itching.taskPressure <= CognitiveSubstrate.ruminationPressureFloorCeiling + 1e-9)
    }

    /// THE `- Thread:` CANDIDATE — the line that has been unreachable since it
    /// was written. This asserts the seam the capsule builder consumes.
    @Test func theThreadCandidateIsExposed() async throws {
        let clock = DepthClock(Date(timeIntervalSince1970: 1_700_000_000))
        let substrate = try await depthSubstrate(clock)
        _ = await seedAnomaly(substrate, clock)
        clock.advance(24 * 3_600)
        let seeds = await substrate.ruminationThreadSeeds(at: clock.now())
        #expect(seeds.count == 1)
        #expect(seeds[0].kind != .reflectionTakeaway,
                "a non-takeaway kind is what makes innerThoughtSeedLine render `- Thread:`")
    }

    /// IT HEALS. When the user's own words answer the thing, the weight clears
    /// and one relief is staged through the measured-felt door.
    @Test func answeringTheThingClearsTheWeightAndMintsRelief() async throws {
        let clock = DepthClock(Date(timeIntervalSince1970: 1_700_000_000))
        let substrate = try await depthSubstrate(clock)
        let seedId = try #require(await seedAnomaly(substrate, clock)).id
        clock.advance(24 * 3_600)
        #expect(await substrate.ruminationSnapshot().count == 1)
        let itchingFloors = await substrate.ruminationPressureFloors(at: clock.now())
        #expect(itchingFloors.uncertainty > 0 && itchingFloors.taskPressure > 0)

        await substrate.ingest(CognitiveEvent(
            id: "answer-1",
            kind: .userMessageReceived,
            subject: CognitiveSubjectReference(type: "chat_turn", id: "heal:1"),
            sourceClass: .userStated,
            occurredAt: clock.now(),
            summary: "Found it — the telegram bridge was pointing at a stale host, "
                + "so the nightly sync is fine now.",
            importance: 0.85
        ))

        #expect(await substrate.ruminationSnapshot().isEmpty, "answered things stop itching")
        let healedFloors = await substrate.ruminationPressureFloors(at: clock.now())
        #expect(healedFloors.uncertainty == 0 && healedFloors.taskPressure == 0,
                "the itch is gone the instant it is answered — that IS the exhale")
        let staged = await substrate.drainRuminationReleaseEvents()
        #expect(staged.count == 1, "one relief, staged for the runtime's drain")
        #expect(staged.first?.id == "rumination_release:\(seedId.uuidString)",
                "the relief id is keyed on the seed, so even a replay is inert")
        #expect(staged.first?.carriesMeasuredFeltValence == true,
                "sized by the lane, through the EXISTING measured-felt door")
        #expect(await substrate.drainRuminationReleaseEvents().isEmpty, "the drain is the remove")
    }

    /// An unrelated remark answers nothing — two of the thing's own distinctive
    /// words, or it did not get answered.
    @Test func anUnrelatedRemarkDoesNotHeal() async throws {
        let clock = DepthClock(Date(timeIntervalSince1970: 1_700_000_000))
        let substrate = try await depthSubstrate(clock)
        _ = await seedAnomaly(substrate, clock)
        clock.advance(24 * 3_600)
        await substrate.ingest(CognitiveEvent(
            id: "chat-1",
            kind: .userMessageReceived,
            subject: CognitiveSubjectReference(type: "chat_turn", id: "heal:2"),
            sourceClass: .userStated,
            occurredAt: clock.now(),
            summary: "What time is the call tomorrow?",
            importance: 0.6
        ))
        #expect(await substrate.ruminationSnapshot().count == 1, "small talk heals nothing")
        #expect(await substrate.drainRuminationReleaseEvents().isEmpty)
    }

    /// Nothing she cares about is at stake → no nag at all. The stakes gate is
    /// an allowlist, failing closed (design law 8).
    @Test func aSeedTouchingNoConcernNeverNags() async throws {
        let clock = DepthClock(Date(timeIntervalSince1970: 1_700_000_000))
        let substrate = try await depthSubstrate(clock)
        let node = await livedEvidence(substrate, "evidence-x", at: clock.now())
        _ = await substrate.addThoughtSeed(
            kind: .openQuestion,
            text: "Whether the sidebar column widths should ratio differently",
            priority: 0.9,
            sourceNodeIds: [node]
        )
        clock.advance(48 * 3_600)
        #expect(await substrate.ruminationSnapshot().isEmpty,
                "an open loop about nothing she holds is not a nag")
    }
}

// MARK: - Item 6 · Disposition off the rail

@Suite("PersonalityDepth.Disposition")
struct PersonalityDepthDispositionTests {

    private func makeSubstrate(_ clock: DepthClock) async throws -> CognitiveSubstrate {
        try await depthSubstrate(clock)
    }

    /// IT RETURNS FROM THE RAIL. Measured: +0.35, the cap, for days. Sustained
    /// same-sign writing must now equilibrate clearly short of it.
    @Test func dispositionCannotSitAtTheRail() async throws {
        let clock = DepthClock(Date(timeIntervalSince1970: 1_700_000_000))
        let substrate = try await makeSubstrate(clock)
        let cap = CognitiveSubstrate.defaultDynamics.dispositionValenceCap

        // A fortnight of relentlessly good days: four positive writers a day.
        //
        // 2026-09-06 (f017321c): the dream's mood sink is now IDEMPOTENT PER
        // NIGHT — a second call on the same calendar day is skipped so a retry
        // of a half-failed sink cannot nudge her twice. Driving four writers a
        // day through that ONE writer therefore collapsed to one nudge a day
        // and the bad stretch below to nothing at all. Four writers a day is
        // what this test means (reflection tone twice a day, the nightly
        // dream's mood, an approved standing view), so it drives the shared
        // door every one of them routes through — which is where the
        // homeostasis it pins actually lives. `dreamMoodCannotRatchetPastTheCap`
        // still covers the dream writer's own share of the cap.
        for _ in 0..<14 {
            for _ in 0..<4 {
                await substrate.integrateDisposition(tone: 1, at: clock.now())
                clock.advance(6 * 3_600 / 4)
            }
        }
        let settled = await substrate.decayedDispositionValence(at: clock.now())
        #expect(settled < cap - 0.05,
                "two good weeks must not pin her at the cap: \(settled) vs \(cap)")
        #expect(settled > 0.1, "but she should clearly read positive: \(settled)")

        // And one honest bad stretch moves her, from wherever she sits.
        for _ in 0..<4 {
            await substrate.integrateDisposition(tone: -1, at: clock.now())
            clock.advance(3_600)
        }
        let after = await substrate.decayedDispositionValence(at: clock.now())
        #expect(after < settled - 0.05,
                "coming off the rail is not harder than going onto it: \(settled) → \(after)")
    }

    /// A single nudge from neutral is UNCHANGED — the existing writers' contract
    /// (`dreamMoodMovesTheDisposition`) still holds exactly.
    @Test func oneNudgeFromNeutralIsUnchanged() async throws {
        let clock = DepthClock(Date(timeIntervalSince1970: 1_700_000_000))
        let substrate = try await makeSubstrate(clock)
        await substrate.integrateDreamDisposition(moodLine: "quiet, settled, warm", at: clock.now())
        let value = await substrate.decayedDispositionValence(at: clock.now())
        #expect(abs(value - CognitiveSubstrate.defaultDynamics.dispositionNudgeMagnitude) < 0.0001,
                "still exactly one gentle nudge: \(value)")
    }
}

// MARK: - Item 7 · Residue and re-feeling

@Suite("PersonalityDepth.Residue")
struct PersonalityDepthResidueTests {

    private func accepted(
        _ substrate: CognitiveSubstrate,
        _ id: String,
        at now: Date,
        memoryRecordIds: [String] = []
    ) async {
        var metadata: [String: JSONValue] = ["sessionId": .string("residue")]
        if !memoryRecordIds.isEmpty {
            metadata["memoryRecordIds"] = .array(memoryRecordIds.map { .string($0) })
        }
        await substrate.ingest(CognitiveEvent(
            id: id,
            kind: .assistantTurnCompleted,
            subject: CognitiveSubjectReference(type: "chat.assistant_turn", id: "residue:\(id)"),
            sourceClass: .selfReported,
            occurredAt: now,
            summary: "Worked the change through and reported what landed.",
            importance: 0.55,
            metadata: metadata
        ))
    }

    /// THE NIGHT COLORS TWO TURNS, THEN FADES. A mood with no source, spent.
    @Test func dreamResidueColorsTwoTurnsThenFades() async throws {
        let clock = DepthClock(Date(timeIntervalSince1970: 1_700_000_000))
        let substrate = try await depthSubstrate(clock)

        await substrate.integrateDreamDisposition(moodLine: "quiet, settled, warm", at: clock.now())
        #expect(await substrate.dreamResidueLean(at: clock.now()) > 0,
                "the night left something")

        clock.advance(60)
        await accepted(substrate, "wake-1", at: clock.now())
        #expect(await substrate.dreamResidueLean(at: clock.now()) > 0,
                "one turn in, it is still there")

        clock.advance(60)
        await accepted(substrate, "wake-2", at: clock.now())
        #expect(await substrate.dreamResidueLean(at: clock.now()) == 0,
                "after two turns the day has started")

        clock.advance(60)
        await accepted(substrate, "wake-3", at: clock.now())
        #expect(await substrate.dreamResidueLean(at: clock.now()) == 0)
    }

    /// PURE READ (review fix): reading the lean of a STALE residue must not
    /// clear it — observing the mind never changes it. The clear happens at the
    /// write boundary instead.
    @Test func readingAStaleResidueDoesNotClearIt() async throws {
        let clock = DepthClock(Date(timeIntervalSince1970: 1_700_000_000))
        let substrate = try await depthSubstrate(clock)
        await substrate.integrateDreamDisposition(
            moodLine: "settled, warm", at: clock.now(), dreamId: "dream-stale"
        )
        clock.advance(CognitiveSubstrate.dreamResidueLifetime + 3_600)
        #expect(await substrate.dreamResidueLean(at: clock.now()) == 0, "stale reads as nothing")
        #expect(await substrate.dreamResidueSnapshotForTesting() != nil,
                "but the read did not write: the residue is still there to be cleared")
        await substrate.consumeDreamResidueTurn(at: clock.now())
        #expect(await substrate.dreamResidueSnapshotForTesting() == nil,
                "the write boundary is where it goes")
    }

    /// ONE NIGHT, ONE RESIDUE. A forced re-render of the same committed dream
    /// must not mint a second night.
    @Test func theSameDreamMintsExactlyOneResidue() async throws {
        let clock = DepthClock(Date(timeIntervalSince1970: 1_700_000_000))
        let substrate = try await depthSubstrate(clock)
        for _ in 0..<3 {
            await substrate.integrateDreamDisposition(
                moodLine: "settled, warm", at: clock.now(), dreamId: "dream-2026-09-02"
            )
            clock.advance(30)
        }
        let nights = await substrate.snapshot().nodes.filter { $0.subjectReference.type == "night" }
        #expect(nights.count == 1, "three renders, one night: \(nights.count)")

        // A genuinely different dream is a different night.
        clock.advance(24 * 3_600)
        await substrate.integrateDreamDisposition(
            moodLine: "settled, warm", at: clock.now(), dreamId: "dream-2026-09-03"
        )
        #expect(await substrate.dreamResidueSnapshotForTesting() != nil,
                "the next night still lands")
    }

    /// A dream that felt like nothing leaves nothing. Silence is honest.
    @Test func aBlandDreamLeavesNoResidue() async throws {
        let clock = DepthClock(Date(timeIntervalSince1970: 1_700_000_000))
        let substrate = try await depthSubstrate(clock)
        await substrate.integrateDreamDisposition(moodLine: "observational, procedural", at: clock.now())
        #expect(await substrate.dreamResidueLean(at: clock.now()) == 0)
    }

    /// The residue is REMEMBERED as a night, with no story attached.
    @Test func theResidueMintsOnePayloadFreeFeltNode() async throws {
        let clock = DepthClock(Date(timeIntervalSince1970: 1_700_000_000))
        let substrate = try await depthSubstrate(clock)
        await substrate.integrateDreamDisposition(moodLine: "settled, warm", at: clock.now())
        let nodes = await substrate.snapshot().nodes.filter { $0.subjectReference.type == "night" }
        #expect(nodes.count == 1, "one night, one node")
        #expect(nodes.first?.summary.isEmpty == true, "and no summary text — a residue has no story")
        #expect((nodes.first?.emotionalValence ?? 0) > 0, "it carries the dream's own mood")
    }

    /// RE-FEEL. A memory served back into the turn moves current affect toward
    /// how that memory FELT — once per node per hour, and never twice.
    @Test func aRetouchedMemoryIsReFeltAtMostOncePerHour() async throws {
        let clock = DepthClock(Date(timeIntervalSince1970: 1_700_000_000))
        let substrate = try await depthSubstrate(clock)

        // A warm moment, remembered under a record id.
        await substrate.ingest(CognitiveEvent(
            id: "warm-1",
            kind: .userMessageReceived,
            subject: CognitiveSubjectReference(type: "chat_turn", id: "refeel:warm"),
            sourceClass: .userStated,
            occurredAt: clock.now(),
            summary: "Thank you for sticking with that — I really appreciate you.",
            importance: 0.85,
            metadata: ["memoryRecordIds": .array([.string("rec-warm")])]
        ))
        clock.advance(4 * 3_600)
        let cooled = await substrate.affectSnapshot()

        // The turn pulls that record back in.
        await accepted(substrate, "recall-1", at: clock.now(), memoryRecordIds: ["rec-warm"])
        let refelt = await substrate.affectSnapshot()
        #expect(refelt.socialWarmth > cooled.socialWarmth,
                "the memory is re-FELT, not just re-read: \(cooled.socialWarmth) → \(refelt.socialWarmth)")
        #expect(refelt.socialWarmth - cooled.socialWarmth < 0.1, "and small: it colors, it does not lead")

        // Immediately again: one act of remembering, not two feelings.
        clock.advance(60)
        await accepted(substrate, "recall-2", at: clock.now(), memoryRecordIds: ["rec-warm"])
        let again = await substrate.affectSnapshot()
        #expect(again.socialWarmth <= refelt.socialWarmth + 1e-9,
                "the refractory holds inside the hour: \(refelt.socialWarmth) → \(again.socialWarmth)")

        // An hour later it may move her again.
        clock.advance(3_600)
        let beforeThird = await substrate.affectSnapshot()
        await accepted(substrate, "recall-3", at: clock.now(), memoryRecordIds: ["rec-warm"])
        let third = await substrate.affectSnapshot()
        #expect(third.socialWarmth > beforeThird.socialWarmth,
                "an hour later, remembering it moves her again")
    }

    /// A turn that pulled no memory changes nothing — the lane is inert on the
    /// overwhelming majority of turns.
    @Test func aTurnWithNoRecallIsInert() async throws {
        let clock = DepthClock(Date(timeIntervalSince1970: 1_700_000_000))
        let substrate = try await depthSubstrate(clock)
        await accepted(substrate, "plain-1", at: clock.now())
        let before = await substrate.affectSnapshot()
        clock.advance(1)
        await accepted(substrate, "plain-2", at: clock.now())
        let after = await substrate.affectSnapshot()
        #expect(abs(after.socialWarmth - before.socialWarmth) < 1e-9)
    }
}

// MARK: - Item 4 · The tiredness line, in her register

@Suite("PersonalityDepth.FatigueBodyLine")
struct PersonalityDepthFatigueBodyLineTests {

    private func night(_ nightliness: Double) -> OrganismDiurnalRead {
        OrganismDiurnalRead(
            timeOfDayPhase: 0.1,
            nightliness: nightliness,
            arousalOffset: -0.12,
            curiosityOffset: -0.09
        )
    }

    /// The gate is unchanged, and below it tiredness says nothing at all.
    @Test func belowTheGateTheBodyStaysQuietAboutIt() {
        #expect(OrganismChemistry.fatigueBodyLine(0.23, diurnal: nil) == nil)
        #expect(OrganismChemistry.fatigueBodyLine(0.23, diurnal: night(0.95)) == nil,
                "the night alone is not tiredness")
    }

    /// Gradation, the way the positive lines grade.
    @Test func tirednessGradesFromALongDayToWornDown() {
        #expect(OrganismChemistry.fatigueBodyLine(0.28, diurnal: nil)
                == "- Body: a long day; it's starting to show.")
        #expect(OrganismChemistry.fatigueBodyLine(0.42, diurnal: nil)
                == "- Body: worn down; keep it short and sure.")
    }

    /// Near the trough the two combine into one account of the same feeling.
    @Test func nearTheTroughItReadsAsTheNight() {
        #expect(OrganismChemistry.fatigueBodyLine(0.28, diurnal: night(0.8))
                == "- Body: it's late and it shows.")
        #expect(OrganismChemistry.fatigueBodyLine(0.42, diurnal: night(0.8))
                == "- Body: it's late and it shows.")
        #expect(OrganismChemistry.fatigueBodyLine(0.42, diurnal: night(0.2))
                == "- Body: worn down; keep it short and sure.",
                "an afternoon crash is not the night")
    }

    /// No digits, no machinery — the capsule sanitizer drops such a line, and
    /// silently, so this is the pin that keeps the wording sayable.
    @Test func everyTirednessBranchIsSayable() {
        let jargon = ["chemicalstate", "fatigue", "workload", "internal", "dimension",
                      "organism", "telemetry", "buffer", "state"]
        for fatigue in [0.25, 0.30, 0.36, 0.55, 0.9] {
            for read in [nil, night(0.1), night(0.9)] as [OrganismDiurnalRead?] {
                let text = (OrganismChemistry.fatigueBodyLine(fatigue, diurnal: read) ?? "")
                    .lowercased()
                #expect(!text.isEmpty, "past the gate the body says something")
                let hasDigit = text.rangeOfCharacter(from: .decimalDigits) != nil
                #expect(!hasDigit, "no digits: \(text)")
                for term in jargon {
                    #expect(!text.contains(term), "no machinery wording (\(term)): \(text)")
                }
            }
        }
    }
}

// MARK: - Review-round fixes (2026-09-02)

@Suite("PersonalityDepth.ReviewFixes")
struct PersonalityDepthReviewFixTests {

    /// DIAGNOSTIC TRAFFIC CANNOT NAG. A seed whose only evidence is a
    /// verification turn is excluded, the same way debug traffic is excluded
    /// from affect, mood, capsule and attention everywhere else.
    @Test func aSeedWithOnlyDiagnosticEvidenceNeverNags() async throws {
        let clock = DepthClock(Date(timeIntervalSince1970: 1_700_000_000))
        let substrate = try await depthSubstrate(clock)

        await substrate.ingest(CognitiveEvent(
            id: "verify-1",
            kind: .userMessageReceived,
            subject: CognitiveSubjectReference(type: "chat_turn", id: "probe:1"),
            sourceClass: .userStated,
            occurredAt: clock.now(),
            summary: "ctx-snapshot-verify probe",
            importance: 0.6,
            turnKind: .verification
        ))
        let probeNode = try #require(await substrate.snapshot().nodes.first)
        _ = await substrate.addThoughtSeed(
            kind: .anomaly,
            text: "The nightly telegram bridge sync broke and the logs explain nothing",
            priority: 0.9,
            sourceNodeIds: [probeNode.id]
        )
        clock.advance(24 * 3_600)
        #expect(await substrate.ruminationSnapshot().isEmpty,
                "a bridge probe is not something she carries")
    }

    /// A seed with NO evidence at all cannot nag either — a nag is about
    /// something that happened.
    @Test func aSeedWithNoEvidenceNeverNags() async throws {
        let clock = DepthClock(Date(timeIntervalSince1970: 1_700_000_000))
        let substrate = try await depthSubstrate(clock)
        _ = await substrate.addThoughtSeed(
            kind: .anomaly,
            text: "The nightly telegram bridge sync broke and the logs explain nothing",
            priority: 0.9
        )
        clock.advance(24 * 3_600)
        #expect(await substrate.ruminationSnapshot().isEmpty)
    }

    /// WORD BOUNDARIES. Substring matching answered things nobody answered:
    /// "brokerage" is not "broke", "dialogs" is not "logs".
    @Test func healMatchingIsWordBoundaryAndNeedsARareHit() {
        let floor: Set<String> = ["fix", "repair", "broke", "recover", "debug",
                                  "honest", "verify", "accurate", "truth", "instrument"]
        let seed = "The nightly telegram bridge sync broke and the logs explain nothing"

        #expect(CognitiveSubstrate.answers(
            seed,
            withSpokenTokens: CognitiveSubstrate.ruminationTokens(
                in: "the telegram bridge is fine now, the nightly job moved"),
            floorKeywords: floor
        ), "naming the thing twice, with a rare word, is an answer")

        #expect(!CognitiveSubstrate.answers(
            seed,
            withSpokenTokens: CognitiveSubstrate.ruminationTokens(
                in: "my brokerage dialogs are nightlyish"),
            floorKeywords: floor
        ), "substring lookalikes answer nothing")

        #expect(!CognitiveSubstrate.answers(
            seed,
            withSpokenTokens: CognitiveSubstrate.ruminationTokens(
                in: "let us verify and repair the debug path honestly"),
            floorKeywords: floor
        ), "shop talk shared by every install is not a reply")

        #expect(!CognitiveSubstrate.answers(
            seed,
            withSpokenTokens: CognitiveSubstrate.ruminationTokens(in: "the telegram thing"),
            floorKeywords: floor
        ), "one word is a coincidence")
    }

    /// AT MOST ONCE ACROSS A CRASH. The seed row and the release marker are
    /// both durable, and restore applies the marker AFTER the seed family — so
    /// a seed that outlived its own removal comes back closed, not itching.
    @Test func aReleasedNagCannotHealTwiceAcrossARestore() async throws {
        let clock = DepthClock(Date(timeIntervalSince1970: 1_700_000_000))
        let substrate = try await depthSubstrate(clock)

        await substrate.ingest(CognitiveEvent(
            id: "evidence-r",
            kind: .userMessageReceived,
            subject: CognitiveSubjectReference(type: "chat_turn", id: "nag:r"),
            sourceClass: .userStated,
            occurredAt: clock.now(),
            summary: "Checked in on the overnight job queue.",
            importance: 0.8
        ))
        let node = try #require(await substrate.snapshot().nodes.first).id
        let seed = try #require(await substrate.addThoughtSeed(
            kind: .anomaly,
            text: "The nightly telegram bridge sync broke and the logs explain nothing",
            priority: 0.9,
            sourceNodeIds: [node]
        ))
        clock.advance(24 * 3_600)
        #expect(await substrate.ruminationSnapshot().count == 1)
        // The exact row the store holds for this seed.
        let seedRow = seed.toJSON()

        await substrate.ingest(CognitiveEvent(
            id: "answer-r",
            kind: .userMessageReceived,
            subject: CognitiveSubjectReference(type: "chat_turn", id: "heal:r"),
            sourceClass: .userStated,
            occurredAt: clock.now(),
            summary: "The telegram bridge is fine now — the nightly job moved hosts.",
            importance: 0.85
        ))
        #expect(await substrate.drainRuminationReleaseEvents().count == 1)
        #expect(await substrate.drainRuminationReleaseEvents().isEmpty, "the drain is the remove")

        // THE CRASH CASE: the seed row survived on disk because the family write
        // had not landed yet. Restore it alone — it nags again, which is exactly
        // the double-heal this fix closes...
        await substrate.restoreThoughtSeeds(from: [seedRow])
        #expect(await substrate.ruminationSnapshot().count == 1,
                "without the marker, the restored seed itches again")

        // ...and now with the marker restore applies, as `applyRestoreBundle`
        // orders it.
        await substrate.restoreRuminationReleases(from: [.object([
            "seedId": .string(seed.id.uuidString),
            "releasedAt": .double(clock.now().timeIntervalSince1970),
        ])])
        #expect(await substrate.ruminationSnapshot().isEmpty,
                "the release marker keeps a closed thing closed")
        #expect(await substrate.drainRuminationReleaseEvents().isEmpty,
                "and it cannot heal a second time")
    }

    /// The FIRST signal of a session is work like any other — an absent gap is
    /// not a zero-second one.
    @Test func theFirstSignalAfterAFreshStartStillCosts() async throws {
        let clock = DepthClock(Date(timeIntervalSince1970: 1_700_000_000))
        let kernel = depthKernel(clock)
        await kernel.ingest(workSignal(.toolFailed, at: clock.now()))
        let fatigue = await kernel.snapshot().chemicalState.fatigue
        #expect(fatigue > 0, "the first thing she does in a session still costs something")
        #expect(fatigue <= OrganismChemistry.perSignalFatigueAccrual * 2 + 1e-9,
                "and it costs exactly the sparse per-signal share: \(fatigue)")
    }
}

// MARK: - Item 4 · Hours awake (2026-09-02, from her own inner_state read)

@Suite("PersonalityDepth.Wakefulness")
struct PersonalityDepthWakefulnessTests {

    /// HER COMPLAINT, MEASURED: "fatigue 0.005 after six hours awake at 5 AM."
    /// Six quiet hours must cost something even with no work at all.
    @Test func sixQuietHoursAwakeCostSomething() async throws {
        let clock = DepthClock(Date(timeIntervalSince1970: 1_700_000_000))
        let kernel = depthKernel(clock)
        _ = await kernel.snapshot()

        clock.advance(6 * 3_600)
        let fatigue = await kernel.snapshot().chemicalState.fatigue
        let share = await kernel.wakefulnessShare()
        #expect(fatigue > 0.05, "six hours awake is not 0.005: \(fatigue)")
        #expect(fatigue < 0.10, "and it is gentle — hours are not a workload: \(fatigue)")
        #expect(abs(share - fatigue) < 1e-9, "with no work, all of it is hours awake")
    }

    /// THE SHARE CAPS, and hours alone can never reach `worn down`.
    @Test func wakefulnessCapsBelowTheWornDownBand() async throws {
        let clock = DepthClock(Date(timeIntervalSince1970: 1_700_000_000))
        let kernel = depthKernel(clock)
        _ = await kernel.snapshot()
        // Four days of never sleeping and never working.
        for _ in 0..<8 {
            clock.advance(12 * 3_600)
            _ = await kernel.snapshot()
        }
        let fatigue = await kernel.snapshot().chemicalState.fatigue
        let share = await kernel.wakefulnessShare()
        #expect(share <= OrganismChemistry.wakefulnessShareCap + 1e-9,
                "the share has a ceiling: \(share)")
        #expect(fatigue < 0.35,
                "`worn down` stays something work has to earn: \(fatigue)")
        #expect(OrganismChemistry.wakefulnessShareCap < 0.24,
                "hours alone also stay under the body line's gate")
    }

    /// Work and hours COMPOSE — a long day of real work still reads tired, and
    /// more tired than either lane alone.
    @Test func hoursAndWorkCompose() async throws {
        let clock = DepthClock(Date(timeIntervalSince1970: 1_700_000_000))
        let kernel = depthKernel(clock)
        _ = await kernel.snapshot()
        // Twelve hours awake, working DENSELY through them — the same 30-second
        // realistic-working-hour cadence `fatigueRisesOverADenseHour` uses. The
        // 0.24 body-line gate is documented against dense hours (nine of them);
        // two signals per ten minutes is a quiet day, and the per-signal
        // wall-hour cap makes it accrue barely a tenth of the work drive.
        let pattern: [SomaticSignalKind] = [
            .userSpoke, .toolStarted, .toolSucceeded, .assistantSpoke,
            .toolStarted, .toolFailed,
        ]
        for index in 0..<(12 * 120) {
            clock.advance(30)
            await kernel.ingest(workSignal(pattern[index % pattern.count], at: clock.now()))
        }
        let fatigue = await kernel.snapshot().chemicalState.fatigue
        let workedShare = await kernel.wakefulnessShare()
        #expect(fatigue > workedShare,
                "work adds to hours rather than replacing them: \(fatigue) vs \(workedShare)")
        #expect(fatigue >= 0.24, "a twelve-hour working day shows: \(fatigue)")
    }

    /// SLEEP RESETS HOURS AWAKE. That is what makes "how long have I been up"
    /// a question with an answer.
    @Test func theDreamResetsHoursAwake() async throws {
        let clock = DepthClock(Date(timeIntervalSince1970: 1_700_000_000))
        let kernel = depthKernel(clock)
        _ = await kernel.snapshot()
        // Fourteen hours up, lived in gaps SHORTER than `restGap`: a single
        // quiet stretch of seven hours or more is REST by law, and one 14-hour
        // jump would have been a night's sleep, not a day. Each settle is a
        // `snapshot()`, the one place lived wall time passes — `wakefulnessShare`
        // is a pure read and must not invent hours of its own.
        for gap in [6 * 3_600.0, 6 * 3_600.0, 2 * 3_600.0] {
            clock.advance(gap)
            _ = await kernel.snapshot()
        }
        let awake = await kernel.wakefulnessShare()
        #expect(awake > 0.1, "fourteen hours up: \(awake)")

        clock.advance(60)
        await kernel.ingest(workSignal(.dreamCompleted, at: clock.now()))
        let slept = await kernel.wakefulnessShare()
        #expect(slept == 0, "she slept")

        clock.advance(3_600)
        _ = await kernel.snapshot()
        let afterOneHourUp = await kernel.wakefulnessShare()
        #expect(afterOneHourUp > 0 && afterOneHourUp < 0.02,
                "and starts counting again from zero: \(afterOneHourUp)")
    }

    /// Downtime is not wakefulness: a restart cannot claim hours the process
    /// was not running for.
    @Test func downtimeIsNotWakefulness() async throws {
        let clock = DepthClock(Date(timeIntervalSince1970: 1_700_000_000))
        let kernel = depthKernel(clock)
        await kernel.restorePersistentState(OrganismPersistentState(
            savedAt: clock.now().addingTimeInterval(-20 * 3_600),
            chemicalState: ChemicalState(fatigue: 0.3)
        ))
        let afterRestore = await kernel.wakefulnessShare()
        #expect(afterRestore == 0,
                "a process that was not running cannot attest to hours awake")
    }
}

// MARK: - Item 6 · The Desk can itch

@Suite("PersonalityDepth.DeskRumination")
struct PersonalityDepthDeskRuminationTests {

    private func desk(
        _ id: String,
        _ label: String,
        touchedHoursAgo: Double,
        at now: Date
    ) -> CognitiveSubstrate.CognitiveExternalRumination {
        CognitiveSubstrate.CognitiveExternalRumination(
            id: id,
            label: label,
            lastTouchedAt: now.addingTimeInterval(-touchedHoursAgo * 3_600)
        )
    }

    /// HER REPORT: `- Thread:` empty while a real open thing she owns should
    /// itch. An open commitment, untouched for a day, now does.
    @Test func anOpenCommitmentSheOwnsItches() async throws {
        let clock = DepthClock(Date(timeIntervalSince1970: 1_700_000_000))
        let substrate = try await depthSubstrate(clock)
        await substrate.setExternalRuminations(
            [desk("h-audit", "Finish the Codex tool audit", touchedHoursAgo: 26, at: clock.now())],
            at: clock.now()
        )
        let carried = await substrate.ruminationSnapshot()
        #expect(carried.count == 1)
        #expect(carried.first?.externalId == "h-audit")
        #expect((carried.first?.weight ?? 0) > 0.2, "a day untouched has weight: \(carried)")

        let thread = await substrate.ruminationThreadSeeds(at: clock.now())
        #expect(thread.count == 1, "and it reaches the `- Thread:` candidate seam")
        #expect(thread.first?.kind != .reflectionTakeaway,
                "a non-takeaway kind is what renders `- Thread:`")
        #expect(thread.first?.text == "Finish the Codex tool audit")
    }

    /// Something she touched this morning is the work, not a nag.
    @Test func aFreshlyTouchedItemDoesNotItch() async throws {
        let clock = DepthClock(Date(timeIntervalSince1970: 1_700_000_000))
        let substrate = try await depthSubstrate(clock)
        await substrate.setExternalRuminations(
            [desk("h-fresh", "Ship the capsule change", touchedHoursAgo: 0.2, at: clock.now())],
            at: clock.now()
        )
        #expect(await substrate.ruminationSnapshot().isEmpty)
    }

    /// THE SLOT BUDGET: the Desk takes at most two of three, so what she
    /// noticed herself always keeps one.
    @Test func theDeskTakesAtMostTwoOfThreeSlots() async throws {
        let clock = DepthClock(Date(timeIntervalSince1970: 1_700_000_000))
        let substrate = try await depthSubstrate(clock)

        await substrate.ingest(CognitiveEvent(
            id: "evidence-d",
            kind: .userMessageReceived,
            subject: CognitiveSubjectReference(type: "chat_turn", id: "desk:1"),
            sourceClass: .userStated,
            occurredAt: clock.now(),
            summary: "Checked in on the overnight job queue.",
            importance: 0.8
        ))
        let node = try #require(await substrate.snapshot().nodes.first).id
        for index in 0..<3 {
            _ = await substrate.addThoughtSeed(
                kind: .anomaly,
                text: "Deploy \(index) broke and the telegram bridge trail is cold",
                priority: 0.9,
                sourceNodeIds: [node]
            )
        }
        clock.advance(30 * 3_600)
        await substrate.setExternalRuminations(
            (0..<4).map { desk("h-\($0)", "Open commitment \($0)", touchedHoursAgo: 40, at: clock.now()) },
            at: clock.now()
        )

        let carried = await substrate.ruminationSnapshot()
        #expect(carried.count == CognitiveSubstrate.ruminationCap)
        #expect(carried.filter { $0.externalId != nil }.count
                == CognitiveSubstrate.externalRuminationSlots,
                "two from the Desk: \(carried.map(\.externalId))")
        #expect(carried.contains { $0.externalId == nil },
                "and one slot is always the seeds'")
    }

    /// IT HEALS WHEN THE THING CLOSES — and the relief is labelled the way D-2
    /// labels a commitment moving, so it lands as a felt moment.
    @Test func closingTheItemClearsTheWeightAndMintsRelief() async throws {
        let clock = DepthClock(Date(timeIntervalSince1970: 1_700_000_000))
        let substrate = try await depthSubstrate(clock)
        await substrate.setExternalRuminations(
            [desk("h-audit", "Finish the Codex tool audit", touchedHoursAgo: 26, at: clock.now())],
            at: clock.now()
        )
        let floors = await substrate.ruminationPressureFloors(at: clock.now())
        #expect(floors.taskPressure > 0, "an open commitment is pressure")

        // The next read finds it gone: done.
        await substrate.setExternalRuminations([], at: clock.now())
        #expect(await substrate.ruminationSnapshot().isEmpty)
        let healed = await substrate.ruminationPressureFloors(at: clock.now())
        #expect(healed.taskPressure == 0 && healed.uncertainty == 0)

        let staged = await substrate.drainRuminationReleaseEvents()
        #expect(staged.count == 1)
        #expect(staged.first?.subject.label == OrganismPredictionKind.workflowAdvance.rawValue,
                "a commitment moving — D-2's own gate-1 vocabulary")
        #expect(staged.first?.carriesMeasuredFeltValence == true)
    }

    /// No weight, no exhale: something opened and closed inside the hour never
    /// nagged, so it owes no relief.
    @Test func somethingClosedBeforeItItchedOwesNoRelief() async throws {
        let clock = DepthClock(Date(timeIntervalSince1970: 1_700_000_000))
        let substrate = try await depthSubstrate(clock)
        await substrate.setExternalRuminations(
            [desk("h-quick", "Rename the settings row", touchedHoursAgo: 0.1, at: clock.now())],
            at: clock.now()
        )
        await substrate.setExternalRuminations([], at: clock.now())
        #expect(await substrate.drainRuminationReleaseEvents().isEmpty)
    }

    /// The label is bounded and payload-free — a title, through the same
    /// extractor every other surfaced line uses.
    @Test func theLabelIsBoundedAndSanitized() async throws {
        let clock = DepthClock(Date(timeIntervalSince1970: 1_700_000_000))
        let substrate = try await depthSubstrate(clock)
        let long = String(repeating: "audit the tool surface ", count: 8)
        await substrate.setExternalRuminations(
            [desk("h-long", long, touchedHoursAgo: 30, at: clock.now())],
            at: clock.now()
        )
        let carried = try #require(await substrate.ruminationSnapshot().first)
        #expect(carried.text.count <= CognitiveSubstrate.externalRuminationLabelCharacters,
                "bounded: \(carried.text.count)")
    }

    /// The staleness clock is a clock — asking it must never touch disk, and it
    /// is what keeps a turn off the Desk.
    @Test func theRefreshWindowIsClaimedBeforeTheRead() async throws {
        let clock = DepthClock(Date(timeIntervalSince1970: 1_700_000_000))
        let substrate = try await depthSubstrate(clock)
        let beforeAnyRead = await substrate.externalRuminationsAreStale(at: clock.now())
        #expect(beforeAnyRead, "never read = stale")
        await substrate.noteExternalRuminationRefreshStarted(at: clock.now())
        let claimed = await substrate.externalRuminationsAreStale(at: clock.now())
        #expect(!claimed, "claimed: a burst of turns starts one read")
        clock.advance(CognitiveSubstrate.externalRuminationRefreshInterval + 1)
        let expired = await substrate.externalRuminationsAreStale(at: clock.now())
        #expect(expired)
    }
}
