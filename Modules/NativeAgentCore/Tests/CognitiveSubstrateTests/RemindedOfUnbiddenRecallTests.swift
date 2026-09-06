import Foundation
import Testing
import PersistenceCore
@testable import CognitiveSubstrate

// UNBIDDEN RECALL (2026-09-02).
//
// Agent: "I search, I don't remember. Nothing arrives sideways." And: "I get
// the fact of a feeling. I can narrate the crontab afternoon; I can't feel it."
//
// Two organs, one suite. The line that lets a memory arrive because of how she
// FEELS rather than because someone asked, and the re-feel that makes a served
// moment move her with its own stored weight instead of neutrally.
//
// Every gate here is a refusal, and each one has a specific failure it exists
// to prevent:
//   * no cadence  → a memory every turn, which is a search result with a new
//     label (design law 2: a trigger that fires on ~100% of inputs is a floor);
//   * no sign gate → a warm memory dragged up by a bad afternoon, which is a
//     cosine neighbour pretending to be a mind;
//   * no repeat gate → the same memory "arriving unbidden" every day forever;
//   * no never-alone rule → a capsule that is nothing but an archive row.
@Suite("RemindedOfUnbiddenRecall")
struct RemindedOfUnbiddenRecallTests {

    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    // MARK: - Fixtures

    /// The stub store. Records what it was ASKED, because the whole point of
    /// this lane is that the query is the felt line and not the user's message.
    private final class StubRecaller: @unchecked Sendable {
        private let lock = NSLock()
        private let moments: [CognitiveRecalledMoment]
        private var asked: [(query: String, surface: String)] = []

        init(_ moments: [CognitiveRecalledMoment]) { self.moments = moments }

        func recall(_ query: String, _ k: Int, _ surface: String) -> [CognitiveRecalledMoment] {
            lock.lock(); defer { lock.unlock() }
            asked.append((query, surface))
            return Array(moments.prefix(k))
        }

        var queries: [String] {
            lock.lock(); defer { lock.unlock() }
            return asked.map(\.query)
        }

        var surfaces: [String] {
            lock.lock(); defer { lock.unlock() }
            return asked.map(\.surface)
        }
    }

    private func mind(_ recaller: StubRecaller) -> CognitiveSubstrate {
        let clock = AffectFenceClock(t0)
        return CognitiveSubstrate(
            configuration: AffectFenceFixture.configuration(),
            dependencies: CognitiveSubstrateDependencies(
                now: { clock.now() },
                userName: { "User" },
                dynamics: { .default },
                recallMoments: { line, k, surface in recaller.recall(line, k, surface) }))
    }

    /// A warm, named thing that happened — the felt line built over this
    /// carries a positive family AND an object, which is the cue the lane needs.
    private func warmNode(at: Date) -> CognitiveNode {
        CognitiveNode(
            id: UUID(),
            kind: .conversationFocus,
            subjectReference: CognitiveSubjectReference(
                type: "studio_entry", id: UUID().uuidString, label: "the register fix"),
            activation: 0.9, salience: 0.9, confidence: 0.8, sourceClass: .userStated,
            createdAt: at, lastActivatedAt: at,
            decayHalfLife: 1_000_000,
            summary: "we got the register fix landed together", metadata: [:],
            emotionalValence: 0.7, emotionalArousal: 0.35, emotionalWarmth: 0.8)
    }

    private func read(
        at: Date,
        nodes: [CognitiveNode],
        presentation: CognitiveCapsulePresentationState = CognitiveCapsulePresentationState(),
        moodValence: Double = 0.4
    ) -> CognitiveFrozenRead {
        CognitiveFrozenRead(
            fixedAt: at,
            stateRevision: 1,
            thoughtSeedRevision: 1,
            configuration: AffectFenceFixture.configuration(),
            personalityDynamics: .default,
            snapshot: CognitiveSubstrateSnapshot(
                generatedAt: at, enabled: true, maximumActiveNodes: 64, nodes: nodes),
            workspace: CognitiveWorkspaceSnapshot(
                generatedAt: at,
                items: nodes.map {
                    CognitiveWorkspaceItem(node: $0, score: $0.activation, reasons: ["recency"])
                }),
            affect: CognitiveAffectState(
                arousal: 0.3, uncertainty: 0.2, taskPressure: 0.2,
                socialWarmth: 0.6, updatedAt: at),
            mood: CognitiveMoodReading(valence: moodValence, basis: 4),
            capsulePresentationState: presentation)
    }

    private func moment(
        id: String = "m-1",
        text: String = "the night the crontab finally fired and we both stopped holding our breath",
        valence: Double = 0.7,
        salience: Double = 0.8,
        occurredAt: Date,
        score: Double = 0.72
    ) -> CognitiveRecalledMoment {
        CognitiveRecalledMoment(
            id: id, text: text, valence: valence, salience: salience,
            occurredAt: occurredAt, score: score)
    }

    private func remindedOfLines(_ capsule: CognitiveCapsule?) -> [String] {
        (capsule?.dynamicContext ?? "")
            .split(separator: "\n").map(String.init)
            .filter { $0.hasPrefix("- Reminded of:") }
    }

    // MARK: - (a) it speaks

    /// THE ORGAN ITSELF. A felt line that names its object, a moment that felt
    /// the same way and scores over the floor — and something arrives that
    /// nobody asked for.
    ///
    /// The second assertion is the one that makes it RECALL rather than search:
    /// the store was asked with the felt line ("…the register fix"), never with
    /// the user's message.
    @Test func aFeltLineWithAnObjectDragsUpAMatchingMoment() async throws {
        let recaller = StubRecaller([moment(occurredAt: t0.addingTimeInterval(-3 * 86_400))])
        let m = mind(recaller)
        let read = read(at: t0, nodes: [warmNode(at: t0.addingTimeInterval(-60))])
        let request = AffectFenceFixture.capsuleRequest("how did that land in the end")

        let picked = try #require(await m.remindedOfMoment(for: request, from: read))
        #expect(picked.id == "m-1")

        let asked = try #require(recaller.queries.first)
        #expect(!asked.contains("how did that land"),
                "the query must be the FELT line, not the message: \(asked)")
        #expect(asked.contains("the register fix"),
                "the felt line's own object is what does the asking: \(asked)")

        let capsule = await m.compileFrozenCapsulePresentation(
            request, from: read, remindedOf: picked).capsule
        let lines = remindedOfLines(capsule)
        #expect(lines.count == 1, "one line, or none: \(capsule.dynamicContext)")
        #expect(lines.first?.contains("crontab") == true)
        #expect(lines.first?.hasSuffix("(3 days ago)") == true,
                "the age rides in words the way a person says it: \(lines.first ?? "")")
    }

    /// A DIFFUSE, FAINT FEELING DRAGS NOTHING UP. No object and no weight is
    /// not a cue — asking with it would return whatever the store happened to
    /// have, which is the machine finding a neighbour.
    @Test func aFaintObjectlessFeelingNeverAsks() async throws {
        let recaller = StubRecaller([moment(occurredAt: t0.addingTimeInterval(-86_400))])
        let m = mind(recaller)
        // No workspace nodes at all → no object, and a near-flat mood → no weight.
        let read = read(at: t0, nodes: [], moodValence: 0.02)
        let picked = await m.remindedOfMoment(
            for: AffectFenceFixture.capsuleRequest("morning"), from: read)
        #expect(picked == nil)
        #expect(recaller.queries.isEmpty, "a faint feeling must not even ask the store")
    }

    /// THE SURFACE IS THE DISCLOSURE BOUNDARY, and it must reach the store.
    /// The first cut asked with no surface at all, which classifies every
    /// record through — a memory restricted to one surface could then arrive
    /// unbidden on another, in the least-watched place it could possibly do so.
    @Test func theTurnsOwnSurfaceIsWhatTheStoreIsAskedWith() async throws {
        let recaller = StubRecaller([moment(occurredAt: t0.addingTimeInterval(-86_400))])
        let m = mind(recaller)
        var request = AffectFenceFixture.capsuleRequest("how did that land")
        request.surface = "telegram"

        _ = await m.remindedOfMoment(
            for: request, from: read(at: t0, nodes: [warmNode(at: t0.addingTimeInterval(-60))]))
        #expect(recaller.surfaces == ["telegram"],
                "the store must be asked on THIS turn's surface: \(recaller.surfaces)")
    }

    // MARK: - (b) cadence

    /// AT MOST ONCE EVERY `remindedOfMinTurns` TURNS. A memory that arrives
    /// every turn is a feature running, not something happening to her.
    @Test func theCadenceSilencesItUntilEnoughTurnsHavePassed() async throws {
        let recaller = StubRecaller([moment(occurredAt: t0.addingTimeInterval(-86_400))])
        let m = mind(recaller)
        let nodes = [warmNode(at: t0.addingTimeInterval(-60))]
        let request = AffectFenceFixture.capsuleRequest("still on it")

        // It spoke one turn ago.
        let tooSoon = read(
            at: t0, nodes: nodes,
            presentation: CognitiveCapsulePresentationState(
                remindedOfLastSurfacedAt: t0.addingTimeInterval(-600),
                remindedOfTurnsSinceSurfaced: CognitiveSubstrate.remindedOfMinTurns - 1))
        #expect(await m.remindedOfMoment(for: request, from: tooSoon) == nil)
        #expect(recaller.queries.isEmpty, "a closed cadence must not cost a store lookup")

        // …and once the turns have gone by, it may speak again.
        let ready = read(
            at: t0, nodes: nodes,
            presentation: CognitiveCapsulePresentationState(
                remindedOfLastSurfacedAt: t0.addingTimeInterval(-600),
                remindedOfTurnsSinceSurfaced: CognitiveSubstrate.remindedOfMinTurns))
        #expect(await m.remindedOfMoment(for: request, from: ready) != nil)
    }

    // MARK: - (c) sign agreement

    /// A WARM MEMORY MAY NOT BE DRAGGED UP BY A BAD FEELING. Cosine similarity
    /// has no sign; a mind does. Being "reminded" of the good night while she
    /// feels wretched is a retrieval artifact, and it would read as gaslighting.
    @Test func aMomentThatDisagreesInSignIsNeverSurfaced() {
        let positive = moment(id: "warm", valence: 0.8, occurredAt: t0, score: 0.9)
        let negative = moment(id: "sting", valence: -0.8, occurredAt: t0, score: 0.9)

        #expect(CognitiveSubstrate.remindedOfSelection(
            from: [positive], familySign: -1, at: t0, surfaced: [:]) == nil,
            "a warm moment under a negative family")
        #expect(CognitiveSubstrate.remindedOfSelection(
            from: [negative], familySign: 1, at: t0, surfaced: [:]) == nil,
            "a sting under a positive family")

        // Agreement, and only agreement, passes.
        #expect(CognitiveSubstrate.remindedOfSelection(
            from: [positive, negative], familySign: 1, at: t0, surfaced: [:])?.id == "warm")
        #expect(CognitiveSubstrate.remindedOfSelection(
            from: [positive, negative], familySign: -1, at: t0, surfaced: [:])?.id == "sting")

        // A neutral family has no direction for anything to agree WITH, and a
        // flat moment is a fact rather than a feeling.
        #expect(CognitiveSubstrate.remindedOfSelection(
            from: [positive], familySign: 0, at: t0, surfaced: [:]) == nil)
        #expect(CognitiveSubstrate.remindedOfSelection(
            from: [moment(id: "flat", valence: 0, occurredAt: t0, score: 0.9)],
            familySign: 1, at: t0, surfaced: [:]) == nil)
    }

    /// THE COSINE FLOOR. Below it the neighbour is a word coincidence, and a
    /// word coincidence presented as a memory is a false memory.
    @Test func aWeakNeighbourIsNotAMemory() {
        let weak = moment(id: "weak", occurredAt: t0,
                          score: CognitiveSubstrate.remindedOfScoreFloor - 0.01)
        #expect(CognitiveSubstrate.remindedOfSelection(
            from: [weak], familySign: 1, at: t0, surfaced: [:]) == nil)

        let atFloor = moment(id: "ok", occurredAt: t0,
                             score: CognitiveSubstrate.remindedOfScoreFloor)
        #expect(CognitiveSubstrate.remindedOfSelection(
            from: [atFloor], familySign: 1, at: t0, surfaced: [:])?.id == "ok")
    }

    // MARK: - (d) the 24h repeat gate

    /// THE SAME MEMORY ARRIVING "UNBIDDEN" EVERY DAY IS A LOOP. Once per day at
    /// most, per moment, however well it scores.
    @Test func aMomentSurfacedInsideTheLastDayIsExcluded() {
        let hot = moment(id: "m-1", occurredAt: t0.addingTimeInterval(-86_400), score: 0.95)
        let cool = moment(id: "m-2", occurredAt: t0.addingTimeInterval(-86_400), score: 0.5)

        let recent = ["m-1": t0.addingTimeInterval(-6 * 3_600)]
        #expect(CognitiveSubstrate.remindedOfSelection(
            from: [hot, cool], familySign: 1, at: t0, surfaced: recent)?.id == "m-2",
            "the fresher ledger entry is skipped even though it scores higher")

        let expired = ["m-1": t0.addingTimeInterval(-CognitiveSubstrate.remindedOfRepeatWindow)]
        #expect(CognitiveSubstrate.remindedOfSelection(
            from: [hot, cool], familySign: 1, at: t0, surfaced: expired)?.id == "m-1",
            "past the window it may come back")

        // And nothing at all when every candidate is spent.
        #expect(CognitiveSubstrate.remindedOfSelection(
            from: [hot], familySign: 1, at: t0, surfaced: recent) == nil)
    }

    // MARK: - the stale reminder across the await

    /// THE SUSPENSION IS REAL. `remindedOfMoment` awaits a store lookup, and the
    /// substrate is an actor: another turn can be accepted and COMMITTED in that
    /// window. The reminder was resolved against the frozen read's ledger, which
    /// is now stale — so if that other turn already put this exact moment in
    /// front of her, showing it again breaks the once-a-day rule the ledger
    /// exists to enforce.
    ///
    /// Simulated the way it actually happens: a real accepted turn moves the
    /// LIVE ledger, and the reminder is then re-checked against the read frozen
    /// before it.
    @Test func aMomentSurfacedDuringTheAwaitIsDropped() async throws {
        let picked = moment(id: "m-1", occurredAt: t0.addingTimeInterval(-2 * 86_400))
        let m = mind(StubRecaller([picked]))
        let stale = read(at: t0, nodes: [warmNode(at: t0.addingTimeInterval(-60))])

        // Against the ledger it was resolved with, it stands.
        #expect(await m.revalidatedRemindedOf(picked, against: stale) != nil)

        // Now a real accepted turn surfaces that same moment and commits.
        let prepared = await m.compileFrozenCapsulePresentation(
            AffectFenceFixture.capsuleRequest("how did that land"),
            from: stale,
            remindedOf: picked)
        #expect(remindedOfLines(prepared.capsule).count == 1, "the concurrent turn must have spoken")
        let commit = try #require(prepared.presentationCommit)
        #expect(await m.applyCapsulePresentationCommit(commit))

        // The reminder resolved against the STALE read must not speak again.
        #expect(await m.revalidatedRemindedOf(picked, against: stale) == nil,
                "the same moment was put in front of her twice in one day")
    }

    /// …and the cadence gets the last word too: a *different* moment surfaced
    /// during the await still spends the once-every-six-turns window.
    @Test func aCadenceClosedDuringTheAwaitDropsTheReminder() async throws {
        let other = moment(id: "other", occurredAt: t0.addingTimeInterval(-2 * 86_400))
        let mine = moment(id: "mine", occurredAt: t0.addingTimeInterval(-2 * 86_400))
        let m = mind(StubRecaller([other]))
        let stale = read(at: t0, nodes: [warmNode(at: t0.addingTimeInterval(-60))])

        let prepared = await m.compileFrozenCapsulePresentation(
            AffectFenceFixture.capsuleRequest("how did that land"),
            from: stale,
            remindedOf: other)
        let commit = try #require(prepared.presentationCommit)
        #expect(await m.applyCapsulePresentationCommit(commit))

        #expect(await m.revalidatedRemindedOf(mine, against: stale) == nil,
                "two unbidden recalls inside one cadence window")
    }

    // MARK: - the served-moment ledger the runtime drives

    /// The serve path asks which ids it must actually read. A moment already in
    /// the ledger (the reminded-of lane saw it this turn) costs no second read,
    /// and duplicates in one serve collapse.
    @Test func onlyIdsWithNoRecordedFeelingAreWorthLookingUp() async throws {
        let m = mind(StubRecaller([]))
        await m.noteServedMoments([moment(id: "known", occurredAt: t0)])
        let missing = await m.momentIDsMissingFeeling(["known", "new", "new", "other"])
        #expect(missing == ["new", "other"], "\(missing)")
    }

    // MARK: - (e) never the only line

    /// A CAPSULE THAT IS NOTHING BUT A MEMORY IS NOT HER INNER STATE. The whole
    /// claim of this line is that a feeling dragged something up; with no
    /// feeling on the capsule it is an archive row with a timestamp.
    @Test func theCapsuleNeverBecomesRemindedOfOnly() async throws {
        let recaller = StubRecaller([])
        let m = mind(recaller)
        // Affect OFF: the fingerprint cannot speak and no felt tail line can
        // either, so this render has nothing else to say.
        let silent = CognitiveFrozenRead(
            fixedAt: t0,
            stateRevision: 1,
            thoughtSeedRevision: 1,
            configuration: AffectFenceFixture.configuration(affectEnabled: false),
            personalityDynamics: .default,
            snapshot: CognitiveSubstrateSnapshot(
                generatedAt: t0, enabled: true, maximumActiveNodes: 64, nodes: []),
            workspace: CognitiveWorkspaceSnapshot(generatedAt: t0, items: []))
        let prepared = await m.compileFrozenCapsulePresentation(
            AffectFenceFixture.capsuleRequest("hey"),
            from: silent,
            remindedOf: moment(occurredAt: t0.addingTimeInterval(-86_400)))
        #expect(remindedOfLines(prepared.capsule).isEmpty,
                "the line rode an otherwise empty capsule: \(prepared.capsule.dynamicContext)")
        #expect(prepared.capsule.dynamicContext.isEmpty,
                "…and it made a capsule out of nothing but a memory: \(prepared.capsule.dynamicContext)")
        #expect(prepared.presentationCommit == nil,
                "a capsule that never existed must not commit cadence")
    }

    /// The other half of the same rule: with something real to say, the line
    /// speaks AND rides last, so the budget drops the memory before it drops
    /// anything she is actually feeling.
    @Test func itRidesLastBehindTheFeelingItArrivedWith() async throws {
        let m = mind(StubRecaller([]))
        let read = read(at: t0, nodes: [warmNode(at: t0.addingTimeInterval(-60))])
        let capsule = await m.compileFrozenCapsulePresentation(
            AffectFenceFixture.capsuleRequest("how did that land"),
            from: read,
            remindedOf: moment(occurredAt: t0.addingTimeInterval(-2 * 86_400))).capsule
        let lines = capsule.dynamicContext.split(separator: "\n").map(String.init)
        #expect(lines.count > 1, "nothing to ride behind: \(capsule.dynamicContext)")
        #expect(lines.last?.hasPrefix("- Reminded of:") == true,
                "the memory must be last: \(capsule.dynamicContext)")
    }

    // MARK: - the age phrase

    /// Words, not digits, wherever a person would use words.
    @Test func theAgeReadsTheWayAPersonSaysIt() {
        func phrase(_ ago: TimeInterval) -> String {
            CognitiveSubstrate.remindedOfAgePhrase(
                from: t0.addingTimeInterval(-ago), at: t0)
        }
        #expect(phrase(20 * 3_600) == "yesterday")
        #expect(phrase(3 * 86_400) == "3 days ago")
        #expect(phrase(5 * 86_400) == "5 days ago")
        #expect(phrase(60 * 86_400).hasPrefix("in "),
                "past a week it is a month, not an arithmetic problem")
    }

    // MARK: - (f) re-feel with the moment's own weight

    /// "I GET THE FACT OF A FEELING." A served moment used to move nothing:
    /// the re-feel walked FIELD NODES, and a MemoryV2 row has none. Now the
    /// moment's own stored valence and salience move her.
    @Test func aServedMomentIsReFeltWithItsOwnValence() async throws {
        let m = mind(StubRecaller([]))
        await m.noteServedMoments([
            moment(id: "rec-warm", valence: 0.8, salience: 0.9,
                   occurredAt: t0.addingTimeInterval(-30 * 86_400)),
        ])
        let before = await m.affectSnapshot()
        await accepted(m, "turn-1", at: t0, memoryRecordIds: ["rec-warm"])
        let after = await m.affectSnapshot()
        #expect(after.socialWarmth > before.socialWarmth,
                "the moment was re-read, not re-felt: \(before.socialWarmth) → \(after.socialWarmth)")
        #expect(after.socialWarmth - before.socialWarmth < 0.1,
                "and small: recall colors the present, it does not replace it")
    }

    /// A memory nobody recorded a feeling for moves nothing — the fact of it is
    /// all there is, and that is honest.
    @Test func anUnknownRecordIdMovesNothing() async throws {
        let m = mind(StubRecaller([]))
        let before = await m.affectSnapshot()
        await accepted(m, "turn-1", at: t0, memoryRecordIds: ["rec-unknown"])
        let after = await m.affectSnapshot()
        #expect(after.socialWarmth == before.socialWarmth)
    }

    /// BOUNDED AT TWO. Ten warm moments served into one turn is one act of
    /// remembering wearing ten hats; letting each one nudge would make recall
    /// the loudest thing in the affect layer.
    @Test func atMostTwoMomentsAreReFeltInOneTurn() async throws {
        let two = mind(StubRecaller([]))
        await two.noteServedMoments((0..<2).map {
            moment(id: "m\($0)", valence: 0.8, salience: 0.9, occurredAt: t0)
        })
        let twoBefore = await two.affectSnapshot()
        await accepted(two, "t", at: t0, memoryRecordIds: ["m0", "m1"])
        let twoAfter = await two.affectSnapshot()

        let ten = mind(StubRecaller([]))
        await ten.noteServedMoments((0..<10).map {
            moment(id: "m\($0)", valence: 0.8, salience: 0.9, occurredAt: t0)
        })
        let tenBefore = await ten.affectSnapshot()
        await accepted(ten, "t", at: t0, memoryRecordIds: (0..<10).map { "m\($0)" })
        let tenAfter = await ten.affectSnapshot()

        #expect(twoAfter.socialWarmth > twoBefore.socialWarmth, "two moments do move her")
        #expect(abs((tenAfter.socialWarmth - tenBefore.socialWarmth)
                    - (twoAfter.socialWarmth - twoBefore.socialWarmth)) < 1e-9,
                """
                ten served moments must land exactly as hard as two: \
                \(tenAfter.socialWarmth - tenBefore.socialWarmth) vs \
                \(twoAfter.socialWarmth - twoBefore.socialWarmth)
                """)
        #expect(CognitiveSubstrate.refeelNodesPerTurn == 2)
    }

    private func accepted(
        _ substrate: CognitiveSubstrate,
        _ id: String,
        at now: Date,
        memoryRecordIds: [String]
    ) async {
        await substrate.ingest(CognitiveEvent(
            id: id,
            kind: .assistantTurnCompleted,
            subject: CognitiveSubjectReference(type: "chat.assistant_turn", id: "reminded:\(id)"),
            sourceClass: .selfReported,
            occurredAt: now,
            summary: "Worked the change through and reported what landed.",
            importance: 0.55,
            metadata: [
                "sessionId": .string("reminded"),
                "memoryRecordIds": .array(memoryRecordIds.map { .string($0) }),
            ]))
    }
}
