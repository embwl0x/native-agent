import Foundation
import PersistenceCore
import Testing
@testable import CognitiveSubstrate

/// Personality depth item 3 — INTROSPECTION READS THE RECORD.
///
/// The three properties that make this a record rather than an improvisation:
/// it is PURE (reading never changes what it reads), it is PAYLOAD-FREE (labels
/// and numbers, never what was said), and it is BOUNDED with HONEST EMPTIES
/// (absence reads as absence, not as a shaped zero).
@Suite("inner_state — the read")
struct InnerStateReadTests {

    private let t0 = Date(timeIntervalSince1970: 4_000_000)

    private func substrate(
        now: @escaping @Sendable () -> Date,
        configuration: CognitiveConfiguration = CognitiveConfiguration(
            enabled: true,
            workspaceEnabled: true,
            capsuleInjectionEnabled: true,
            affectEnabled: true,
            maximumActiveNodes: 64
        )
    ) -> CognitiveSubstrate {
        CognitiveSubstrate(
            configuration: configuration,
            dependencies: CognitiveSubstrateDependencies(
                now: now, makeUUID: { UUID() }, userName: { "User" }
            )
        )
    }

    /// A user turn whose SUMMARY carries content and whose SUBJECT carries only
    /// a label — the exact shape the payload-free rule has to survive.
    private func userTurn(id: String, at instant: Date, summary: String) -> CognitiveEvent {
        CognitiveEvent(
            id: id,
            kind: .userMessageReceived,
            subject: CognitiveSubjectReference(
                type: "chat.user_turn", id: "session-1:\(id)", label: nil),
            sourceClass: .userStated,
            occurredAt: instant,
            summary: summary,
            importance: 0.9
        )
    }

    // MARK: - Purity (design law 5)

    @Test("reading her inner state does not change her inner state")
    func readsArePure() async {
        let clock = t0
        let mind = substrate(now: { clock })
        for index in 0..<4 {
            await mind.ingest(userTurn(
                id: "turn-\(index)",
                at: clock.addingTimeInterval(Double(index)),
                summary: "the release keeps slipping and it is wearing on me"
            ))
        }

        // Five reads at one instant, then a sixth an hour later. If any read
        // advanced a decay anchor, evicted a node, or moved affect, the later
        // reading would differ from the one a mind that was never asked
        // produces at the same instant.
        let later = clock.addingTimeInterval(3600)
        for _ in 0..<5 {
            _ = await mind.innerStateReading(detail: .full, at: clock)
        }
        let asked = await mind.innerStateReading(detail: .full, at: later)

        let unasked = substrate(now: { clock })
        for index in 0..<4 {
            await unasked.ingest(userTurn(
                id: "turn-\(index)",
                at: clock.addingTimeInterval(Double(index)),
                summary: "the release keeps slipping and it is wearing on me"
            ))
        }
        let control = await unasked.innerStateReading(detail: .full, at: later)

        #expect(asked.moodValence == control.moodValence)
        #expect(asked.moodBasis == control.moodBasis)
        #expect(asked.feltNodes.count == control.feltNodes.count)
        #expect(asked.fingerprint == control.fingerprint)
    }

    // MARK: - Payload-free

    @Test("only labels and numbers cross — never the user's words")
    func neverCarriesConversationContent() async {
        let clock = t0
        let mind = substrate(now: { clock })
        // A phrase that exists ONLY in node summaries. If any of it reaches the
        // reading, something is exporting content.
        let secret = "zephyrine-quarterly-teardown"
        for index in 0..<6 {
            await mind.ingest(userTurn(
                id: "turn-\(index)",
                at: clock.addingTimeInterval(Double(index)),
                summary: "\(secret) is the thing that keeps going wrong, honestly"
            ))
        }

        let reading = await mind.innerStateReading(detail: .full, at: clock)
        for node in reading.feltNodes {
            #expect(!node.subject.contains(secret))
            // The subject is the reference LABEL or TYPE — never the opaque
            // `session:message` id, which is what `subjectReference.id` holds.
            #expect(!node.subject.contains("session-1"))
        }
        #expect(reading.fingerprintSubject.map { !$0.contains(secret) } ?? true)
        #expect(reading.chemistryWords.allSatisfy { !$0.contains(secret) })
        #expect(reading.standingViews.allSatisfy { !$0.text.contains(secret) })
    }

    @Test("chemistry is words, never digits")
    func chemistryCarriesNoNumbers() {
        // The `- Body:` vocabulary, split. Anything with a digit in the line is
        // refused wholesale, the same rule the capsule's body line enforces.
        let warm = OrganismProjection(
            generatedAt: Date(),
            bodyLine: "- Body: warm and steady, curious.",
            chemicalState: ChemicalState(warmth: 0.5, curiosity: 0.45)
        )
        let words = CognitiveSubstrate.innerStateChemistryWords(warm)
        #expect(words == ["warm and steady", "curious"])
        #expect(words.allSatisfy { $0.rangeOfCharacter(from: .decimalDigits) == nil })

        let numeric = OrganismProjection(
            generatedAt: Date(),
            bodyLine: "- Body: fatigue 0.42 and climbing.",
            chemicalState: ChemicalState(fatigue: 0.42)
        )
        #expect(CognitiveSubstrate.innerStateChemistryWords(numeric).isEmpty)

        // A neutral or absent body says nothing rather than saying "fine".
        #expect(CognitiveSubstrate.innerStateChemistryWords(nil).isEmpty)
        #expect(CognitiveSubstrate.innerStateChemistryWords(
            OrganismProjection(generatedAt: Date())).isEmpty)
    }

    // MARK: - Bounds (design law 6)

    @Test("every list is capped, and compact is smaller than full")
    func listsAreBounded() async {
        let clock = t0
        let mind = substrate(now: { clock })
        for index in 0..<40 {
            await mind.ingest(userTurn(
                id: "turn-\(index)",
                at: clock.addingTimeInterval(Double(index)),
                summary: "subject \(index) went badly and I am not happy about it"
            ))
        }
        for index in 0..<20 {
            _ = await mind.addThoughtSeed(
                kind: .openQuestion,
                text: "open question number \(index) about the release lane",
                priority: 0.9
            )
        }

        let full = await mind.innerStateReading(detail: .full, at: clock)
        #expect(full.feltNodes.count <= CognitiveInnerStateReading.maximumFeltNodes)
        #expect(full.seeds.count <= CognitiveInnerStateReading.maximumSeeds)
        #expect(full.standingViews.count <= CognitiveInnerStateReading.maximumStandingViews)
        #expect(full.expectations.count <= CognitiveInnerStateReading.maximumExpectations)
        #expect(full.seeds.allSatisfy {
            $0.text.count <= CognitiveInnerStateReading.seedTextCharacters
        })
        #expect(full.feltNodes.allSatisfy {
            $0.subject.count <= CognitiveInnerStateReading.subjectLabelCharacters
        })

        let compact = await mind.innerStateReading(detail: .compact, at: clock)
        #expect(compact.feltNodes.count <= CognitiveInnerStateReading.compactFeltNodes)
        #expect(compact.seeds.count <= CognitiveInnerStateReading.compactListItems)
    }

    @Test("felt moments rank by |valence| first, then recency")
    func feltMomentsAreRanked() async {
        let clock = t0
        let mind = substrate(now: { clock })
        for index in 0..<12 {
            await mind.ingest(userTurn(
                id: "turn-\(index)",
                at: clock.addingTimeInterval(Double(index)),
                summary: index == 3
                    ? "this is completely broken and I am furious about it"
                    : "that seems fine, thanks"
            ))
        }
        let reading = await mind.innerStateReading(detail: .full, at: clock)
        guard reading.feltNodes.count >= 2 else { return }
        let magnitudes = reading.feltNodes.map { abs($0.valence) }
        #expect(magnitudes == magnitudes.sorted(by: >))
    }

    @Test("the window clamps to 1…48 rather than failing")
    func windowClamps() async {
        let clock = t0
        let mind = substrate(now: { clock })
        #expect(await mind.innerStateReading(windowHours: 0, at: clock).windowHours == 1)
        #expect(await mind.innerStateReading(windowHours: 999, at: clock).windowHours == 48)
        #expect(await mind.innerStateReading(at: clock).windowHours == 6)
    }

    // MARK: - Honest empties

    @Test("cognition off reads as unavailable, not as calm")
    func disabledIsHonest() async {
        let clock = t0
        let off = substrate(now: { clock }, configuration: .disabled)
        let reading = await off.innerStateReading(detail: .full, at: clock)
        #expect(reading.available == false)
        #expect(reading.fingerprint == nil)
        #expect(reading.feltNodes.isEmpty)
        #expect(reading.chemistryWords.isEmpty)
        #expect(reading.dream == nil)
    }

    @Test("a mind with nothing in it reports nothing, and does not fail")
    func emptyMindIsEmptyNotBroken() async {
        let clock = t0
        let mind = substrate(now: { clock })
        let reading = await mind.innerStateReading(detail: .full, at: clock)
        #expect(reading.available)
        #expect(reading.feltNodes.isEmpty)
        #expect(reading.seeds.isEmpty)
        #expect(reading.standingViews.isEmpty)
        #expect(reading.expectations.isEmpty)
        #expect(reading.dream == nil)
        #expect(reading.fatigue == nil)
        #expect(reading.timeOfDayPhase == nil)
        #expect(reading.ruminationCandidate == nil)
    }

    @Test("optional organism reads are consumed when present and absent when not")
    func optionalOrganismReadsAreOptional() async throws {
        let clock = t0
        let mind = substrate(now: { clock })
        let supplied = await mind.innerStateReading(
            detail: .full,
            organism: CognitiveInnerStateOrganismReads(
                fatigue: 0.4,
                // 1 at the body's trough: the small hours.
                diurnal: OrganismDiurnalRead(
                    timeOfDayPhase: 0.12, nightliness: 0.95,
                    arousalOffset: -0.1, curiosityOffset: -0.1),
                toward: OrganismTowardRead(
                    label: "friday review",
                    sourceKind: .statedPlan,
                    valenceSign: 1,
                    dueAt: clock.addingTimeInterval(86_400),
                    isOverdue: false
                ),
                expectations: [
                    CognitiveInnerStateReading.Expectation(
                        label: "approvalResolution",
                        due: clock.addingTimeInterval(1800),
                        valenceSign: -1
                    ),
                ]
            ),
            at: clock
        )
        #expect(supplied.fatigue == 0.4)
        #expect(supplied.timeOfDayPhase == "late")
        #expect(supplied.expectations.count == 1)
        #expect(supplied.expectations[0].valenceSign == -1)

        // #4, the forward-facing register: a label, a sign, a date.
        let toward = try #require(supplied.toward)
        #expect(toward.label == "friday review")
        #expect(toward.sourceKind == "statedPlan")
        #expect(toward.valenceSign == 1)
        #expect(!toward.isOverdue)
    }

    /// The clock is a NUMBER; the word comes off `feltLatenessFloor`, the same
    /// constant the felt word `late` gates on, mirrored for the other edge. No
    /// second idea of what "late" means enters the system.
    @Test("the body's clock chooses a word from the felt-lateness threshold")
    func timeOfDayWordFollowsTheSharedThreshold() {
        func word(_ nightliness: Double) -> String? {
            CognitiveSubstrate.innerStateTimeOfDayWord(OrganismDiurnalRead(
                timeOfDayPhase: 0.5, nightliness: nightliness,
                arousalOffset: 0, curiosityOffset: 0))
        }
        #expect(word(1.0) == "late")
        #expect(word(CognitiveSubstrate.feltLatenessFloor) == "late")
        #expect(word(0.5) == "ordinary hours")
        #expect(word(0.0) == "daytime")
        // No clock configured is absence, never a plausible default.
        #expect(CognitiveSubstrate.innerStateTimeOfDayWord(nil) == nil)
    }

    /// DIAGNOSTIC TRAFFIC CAN'T FEEL (design law 10). A verification turn is
    /// excluded from lived state everywhere else, and an introspection read is
    /// where letting it through would be most misleading — she would be shown a
    /// felt moment nothing in her actually felt.
    // 2026-09-06: both halves now carry the file's canonical stinging phrase.
    // The fixture shipped with "this is completely broken and I am furious
    // about it", which matches NO class in `conversationalAppraisal` — neither
    // "broken" nor "furious" is a needle there, and the nearest ones ("still
    // broken", "broken my trust") do not fire on it. So the tag stamped ~0,
    // `feltDirection` returned nil at the ±0.15 gate, and NEITHER half was
    // testing the filter: the live control could not produce a felt node, and
    // the verification assertion passed vacuously whether or not the
    // `contributesToLivedState` guard existed at all. "wearing on me" is in the
    // criticism tier the rest of this file already leans on, and stamps −0.635.
    @Test("debug and verification turns never appear as felt moments")
    func diagnosticTrafficIsExcluded() async {
        let clock = t0
        let mind = substrate(now: { clock })
        await mind.ingest(CognitiveEvent(
            id: "probe-1",
            kind: .userMessageReceived,
            subject: CognitiveSubjectReference(
                type: "chat.user_turn", id: "probe:1", label: nil),
            sourceClass: .userStated,
            occurredAt: clock,
            summary: "the release keeps slipping and it is wearing on me",
            importance: 0.9,
            turnKind: .verification
        ))
        let reading = await mind.innerStateReading(detail: .full, at: clock)
        #expect(reading.feltNodes.isEmpty, "a verification turn must not read as a felt moment")

        // ...and the identical LIVE turn does land, so this is a filter and not
        // a broken read.
        let live = substrate(now: { clock })
        await live.ingest(CognitiveEvent(
            id: "turn-1",
            kind: .userMessageReceived,
            subject: CognitiveSubjectReference(
                type: "chat.user_turn", id: "session-1:turn-1", label: nil),
            sourceClass: .userStated,
            occurredAt: clock,
            summary: "the release keeps slipping and it is wearing on me",
            importance: 0.9,
            turnKind: .live
        ))
        #expect(!(await live.innerStateReading(detail: .full, at: clock)).feltNodes.isEmpty)
    }

    // MARK: - Word choice (design law 1 — numbers choose words)

    @Test("mood and disposition words come from the capsule's own bands")
    func wordsFollowTheExistingBands() {
        #expect(CognitiveSubstrate.innerStateMoodWord(0.5) == "good")
        #expect(CognitiveSubstrate.innerStateMoodWord(0.2) == "leaning good")
        #expect(CognitiveSubstrate.innerStateMoodWord(0) == "even")
        #expect(CognitiveSubstrate.innerStateMoodWord(-0.2) == "low")
        #expect(CognitiveSubstrate.innerStateMoodWord(-0.5) == "heavy")
        #expect(CognitiveSubstrate.innerStateDispositionWord(0.3) == "settled")
        #expect(CognitiveSubstrate.innerStateDispositionWord(0) == "even")
        #expect(CognitiveSubstrate.innerStateDispositionWord(-0.3) == "heavy")
    }

    // MARK: - Standing views she can name (Agent, 2026-09-02)

    @Test("standing views carry their id and status so she can reference one")
    func standingViewsAreAddressable() async {
        let clock = t0
        let mind = substrate(now: { clock })
        let reading = await mind.innerStateReading(detail: .full, at: clock)
        // Nothing formed yet — honest empty, and the shape is still right.
        #expect(reading.standingViews.isEmpty)

        let view = CognitiveInnerStateReading.StandingView(
            id: UUID(),
            status: CognitiveStandingView.Status.active.rawValue,
            text: String(repeating: "x", count: 200)
        )
        #expect(view.text.count == CognitiveInnerStateReading.standingViewCharacters)
        #expect(view.status == "active")
    }
}


// MARK: - The PURE suggestion read (2026-09-02, reviewer HIGH)

/// The shoulder tap runs on every residual-repair reschedule — many times a
/// minute under load. Routing that through `thoughtSuggestionSnapshot`, which
/// goes through the field's MUTATING snapshot, meant the act of checking
/// "is anything worth mentioning" was aging and evicting her memory.
@Suite("inner_state — pure thought suggestions")
struct PureThoughtSuggestionTests {

    private let t0 = Date(timeIntervalSince1970: 6_000_000)

    private func substrate(now: @escaping @Sendable () -> Date) -> CognitiveSubstrate {
        CognitiveSubstrate(
            configuration: CognitiveConfiguration(
                enabled: true,
                workspaceEnabled: true,
                capsuleInjectionEnabled: true,
                affectEnabled: true,
                thoughtSeedsEnabled: true,
                maximumActiveNodes: 64
            ),
            dependencies: CognitiveSubstrateDependencies(
                now: now, makeUUID: { UUID() }, userName: { "User" }
            )
        )
    }

    private func seedIn(_ mind: CognitiveSubstrate) async {
        _ = await mind.addThoughtSeed(
            kind: .anomaly,
            text: "Re-check high-pressure cognitive state after provider retry",
            priority: 1
        )
    }

    @Test("the pure read never ages the field the mutating snapshot would")
    func pureReadDoesNotAgeTheField() async {
        let clock = t0
        let asked = substrate(now: { clock })
        await seedIn(asked)
        // A hundred passes, the shape of a busy hour of residual reschedules.
        for _ in 0..<100 {
            _ = await asked.pureThoughtSuggestions(minimumInterruptionScore: 0.8, at: clock)
        }
        let later = clock.addingTimeInterval(7200)
        let after = await asked.innerStateReading(detail: .full, at: later)

        let unasked = substrate(now: { clock })
        await seedIn(unasked)
        let control = await unasked.innerStateReading(detail: .full, at: later)

        #expect(after.seeds.count == control.seeds.count)
        #expect(after.moodValence == control.moodValence)
        #expect(after.feltNodes.count == control.feltNodes.count)
    }

    @Test("it ranks and gates exactly like the snapshot it replaces")
    func rankingMatchesTheSnapshot() async {
        let clock = t0
        let mind = substrate(now: { clock })
        await seedIn(mind)
        let pure = await mind.pureThoughtSuggestions(
            surface: "push", limit: 1, minimumInterruptionScore: 0, at: clock)
        let mutating = await mind.thoughtSuggestionSnapshot(
            surface: "push", limit: 1, minimumInterruptionScore: 0)
        #expect(pure.count == mutating.count)
        if let a = pure.first, let b = mutating.first {
            #expect(a.seedId == b.seedId)
            #expect(a.kind == b.kind)
            #expect(a.reason == b.reason)
            #expect(abs(a.interruptionScore - b.interruptionScore) < 0.0001)
        }
    }

    @Test("the floor is honored and an empty mind yields nothing")
    func floorIsHonored() async {
        let clock = t0
        let empty = substrate(now: { clock })
        #expect(await empty.pureThoughtSuggestions(minimumInterruptionScore: 0.8, at: clock).isEmpty)

        let mind = substrate(now: { clock })
        _ = await mind.addThoughtSeed(kind: .openQuestion, text: "a quiet question", priority: 0.05)
        #expect(await mind.pureThoughtSuggestions(
            minimumInterruptionScore: 0.8, at: clock).isEmpty)
    }
}

// MARK: - The stakes gate is SIGNED views only (2026-09-02, reviewer MEDIUM)

/// A held view is one she adopted herself, at half stake, with no signature on
/// it. It may move how she FEELS; it may not put a notification on User's phone.
/// The authority to interrupt him comes from a view he approved.
@Suite("shoulder tap — the stakes gate")
struct StakesGateTierTests {

    private final class Clock: @unchecked Sendable {
        private let lock = NSLock(); private var t: Date
        init(_ t: Date) { self.t = t }
        func now() -> Date { lock.lock(); defer { lock.unlock() }; return t }
        func advance(_ dt: TimeInterval) { lock.lock(); t = t.addingTimeInterval(dt); lock.unlock() }
    }

    private let seat = StudioCanonTurnProvenance(surface: "chat", turnID: "turn-1")

    private func makeSubstrate(_ label: String, clock: Clock) throws -> CognitiveSubstrate {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("nativeagent-stakes-\(label)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return CognitiveSubstrate(
            configuration: CognitiveConfiguration(
                enabled: true,
                persistenceEnabled: true,
                workspaceEnabled: true,
                capsuleInjectionEnabled: true,
                affectEnabled: true,
                thoughtSeedsEnabled: true,
                reflectiveCallsEnabled: true,
                maximumActiveNodes: 256,
                dailyReflectionCallBudget: 32
            ),
            dependencies: CognitiveSubstrateDependencies(now: { clock.now() }, makeUUID: { UUID() }),
            store: try CognitiveSQLiteStore(dataRoot: root))
    }

    private func formView(_ s: CognitiveSubstrate, body: String, at now: Date) async -> UUID? {
        let receipt = await s.recordUnreservedReflectionResultForTesting(
            request: CognitiveReflectionRequest(reason: "reflect", prompt: "prompt", requestedAt: now),
            resultSummary: "A settled read of the night.\nview: \(body)",
            provider: "test")
        return receipt?.proposalIds.first
    }

    private let phrase = "the anthropic oauth pathway keeps breaking releases"
    private let touching = "anthropic oauth pathway looks brittle again"

    @Test("an ACTIVE view authorizes a tap")
    func activeViewAuthorizes() async throws {
        let clock = Clock(Date(timeIntervalSince1970: 22_000_000))
        let s = try makeSubstrate("active", clock: clock)
        try await s.restorePersistentState()
        let id = try #require(await formView(s, body: phrase, at: clock.now()))
        _ = await s.resolveStandingView(id: id, approved: true)
        #expect(await s.passesStakesGate(touching))
    }

    @Test("a HELD view never authorizes a tap, even though it still leans")
    func heldViewNeverAuthorizes() async throws {
        let clock = Clock(Date(timeIntervalSince1970: 22_100_000))
        let s = try makeSubstrate("held", clock: clock)
        try await s.restorePersistentState()
        let id = try #require(await formView(s, body: phrase, at: clock.now()))
        let held = try #require(await s.holdStandingView(id: id, seat: seat))
        #expect(held.status == .held)
        // It DOES lean — the felt lane may be moved by it...
        #expect(!(await s.livedAppraisalConcerns()).isEmpty)
        // ...and it still may not buzz his phone.
        #expect(!(await s.passesStakesGate(touching)))
        // And she can still SEE it: held views keep listing in inner_state.
        let reading = await s.innerStateReading(detail: .full, at: clock.now())
        #expect(reading.standingViews.contains { $0.status == "held" })
    }

    @Test("a PROPOSED view never authorizes a tap")
    func proposedViewNeverAuthorizes() async throws {
        let clock = Clock(Date(timeIntervalSince1970: 22_200_000))
        let s = try makeSubstrate("proposed", clock: clock)
        try await s.restorePersistentState()
        _ = try #require(await formView(s, body: phrase, at: clock.now()))
        #expect(!(await s.passesStakesGate(touching)))
    }

    @Test("no views at all: fails closed, and the floor concerns never open it")
    func failsClosed() async throws {
        let clock = Clock(Date(timeIntervalSince1970: 22_300_000))
        let s = try makeSubstrate("closed", clock: clock)
        try await s.restorePersistentState()
        #expect(!(await s.passesStakesGate(touching)))
        // "commit" is in the shipped followThrough floor. A machine token
        // tripping a shipped keyword is a coincidence, and a coincidence must
        // never buzz a phone.
        #expect(!(await s.passesStakesGate("tool:commit_memory")))
        #expect(!(await s.passesStakesGate("")))
    }
}
