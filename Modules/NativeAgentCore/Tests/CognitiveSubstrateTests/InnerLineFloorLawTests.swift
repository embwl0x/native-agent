import Foundation
import Testing
import PersistenceCore
@testable import CognitiveSubstrate

// WAVE ITEM 11 — THE INNER LINE OBEYS THE FLOOR LAW (2026-09-02).
//
// Design law 2: "a trigger that fires on ~100% of inputs is a floor, not a
// signal." Measured on the live store, the `- Inner:` line rode 100% of 1,487
// capsules with 23 distinct texts over 15 days. The 2026-09-01 rotation fixed
// WHICH text led. It could not fix that one always did, because the takeaway
// branch had no gate at all: any capsule with a reflection takeaway in the seed
// pool carried one, forever.
//
// The line is now gated on the two events that make it worth reading — a view
// that is genuinely relevant to THIS message (the BM25 floor), or a takeaway
// that is FRESH (never surfaced, or changed since it was). Everything else is
// silence, and silence is honest.
//
// The two ways this can fail are opposite and both silent, so both are pinned:
// never gating (the standing instruction comes back) and over-gating (her
// worldview stops reaching the turn it is actually about).
@Suite("InnerLineFloorLaw")
struct InnerLineFloorLawTests {

    private final class Clock: @unchecked Sendable {
        private let lock = NSLock(); private var t: Date
        init(_ t: Date) { self.t = t }
        func now() -> Date { lock.lock(); defer { lock.unlock() }; return t }
        func advance(_ dt: TimeInterval) { lock.lock(); t = t.addingTimeInterval(dt); lock.unlock() }
    }

    private static let at = Date(timeIntervalSince1970: 1_700_000_000)

    /// THE STORE IS NOT OPTIONAL FOR THIS SUITE. `.allPhasesEnabled` sets
    /// `persistenceEnabled`, and `addThoughtSeed` persists its family
    /// TRANSACTIONALLY — with no store, `persistThoughtSeedFamily` throws
    /// `.storeUnavailable`, the insert ROLLS BACK, and the seed silently never
    /// exists. A store-less fixture here would test the floor law against an
    /// empty seed pool and pass for the wrong reason. (This is exactly the trap
    /// `SubconsciousFloorRegressionTests` B8 is currently sitting in — see the
    /// report.)
    private func mind(_ clock: Clock) throws -> CognitiveSubstrate {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("nativeagent-floor-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return CognitiveSubstrate(
            configuration: .allPhasesEnabled,
            dependencies: CognitiveSubstrateDependencies(now: { clock.now() }, makeUUID: { UUID() }),
            store: try CognitiveSQLiteStore(dataRoot: root))
    }

    /// One accepted production turn: ingest, prepare the FROZEN capsule (the
    /// production seam — `compileCapsule` is the Observatory path and never
    /// advances presentation state), commit it. Returns the whole capsule.
    @discardableResult
    private func acceptedTurn(
        _ mind: CognitiveSubstrate,
        _ clock: Clock,
        message: String,
        id: String
    ) async -> CognitiveCapsule? {
        clock.advance(120)
        await mind.ingest(CognitiveEvent(
            id: id,
            kind: .userMessageReceived,
            subject: CognitiveSubjectReference(type: "chat_turn", id: id),
            sourceClass: .userStated,
            occurredAt: clock.now(),
            summary: message,
            importance: 0.8,
            metadata: ["sessionId": .string("floor")]))
        let request = CognitiveCapsuleRequest(
            surface: "chat", userMessage: message, sessionId: "floor", mode: .inject)
        guard let prepared = await mind.prepareFrozenCapsulePresentation(
            request, at: clock.now()) else { return nil }
        if let commit = prepared.presentationCommit {
            _ = await mind.applyCapsulePresentationCommit(commit)
        }
        return prepared.capsule
    }

    /// A LIVED EVIDENCE NODE for a nag to hang on, and the reason the Thread
    /// half of this suite needs one at all.
    ///
    /// `ruminationCandidates` fails closed on provenance: at least one of the
    /// seed's `sourceNodeIds` must still be in the field AND be lived traffic,
    /// so that a seed minted off a `debug`/`verification` turn cannot ruminate
    /// (design law 10). A seed added with the default empty `sourceNodeIds` has
    /// no provenance at all and therefore never itches — which is the gate, not
    /// a lost feature. The evidence turn deliberately shares no distinctive word
    /// with the seed texts: evidence must not answer the thing it is evidence
    /// FOR.
    private func livedEvidence(
        _ mind: CognitiveSubstrate,
        _ id: String,
        at now: Date
    ) async -> UUID {
        await mind.ingest(CognitiveEvent(
            id: id,
            kind: .userMessageReceived,
            subject: CognitiveSubjectReference(type: "chat_turn", id: "evidence:\(id)"),
            sourceClass: .userStated,
            occurredAt: now,
            summary: "Checked in on the overnight job queue.",
            importance: 0.8,
            metadata: ["sessionId": .string("floor")]))
        let nodes = await mind.snapshot().nodes
        return nodes.max { $0.lastActivatedAt < $1.lastActivatedAt }!.id
    }

    private func innerLines(_ capsule: CognitiveCapsule?) -> [String] {
        (capsule?.dynamicContext ?? "")
            .split(separator: "\n").map(String.init)
            .filter { $0.hasPrefix("- Inner:") }
    }

    // MARK: - the takeaway branch: fresh once, then silence

    /// THE MEASUREMENT THIS EXISTS FOR. A takeaway seed is a thing she noticed
    /// once. It leads once. On the very next turn — same text, same seed, same
    /// priority — the line is silent, where before it rode every capsule until
    /// the seed decayed out days later.
    @Test func aTakeawayLeadsOnceAndThenTheLineGoesQuiet() async throws {
        let clock = Clock(Self.at)
        let m = try mind(clock)
        await m.addThoughtSeed(
            kind: .reflectionTakeaway,
            text: "An honest blank is healthier than performing depth",
            priority: 0.9)

        let first = await acceptedTurn(m, clock, message: "keep going on the build", id: "fresh-1")
        #expect(innerLines(first).count == 1,
                "a FRESH takeaway must reach the capsule: \(first?.dynamicContext ?? "<none>")")

        let second = await acceptedTurn(m, clock, message: "keep going on the build", id: "fresh-2")
        #expect(innerLines(second).isEmpty,
                "the same takeaway must not lead two turns in a row: \(innerLines(second))")

        let third = await acceptedTurn(m, clock, message: "still going", id: "fresh-3")
        #expect(innerLines(third).isEmpty,
                "…nor on any later turn while it is unchanged: \(innerLines(third))")
    }

    /// REVIEW FINDING 5 — PARAPHRASE IS NOT NEWS, and the first cut said it was.
    ///
    /// Freshness was keyed by the digest of the RENDERED line. Reflection
    /// rewords itself every pass, so the same conclusion in different words
    /// hashed differently and led again — the standing instruction the floor
    /// law removed, wearing a new sentence. The key is the takeaway's LINEAGE
    /// now: its distinctive terms (order-insensitive), falling back to the seed
    /// id. Same conclusion, restated → same key → still not fresh.
    @Test func aParaphrasedTakeawayIsNotFreshAgain() async throws {
        let clock = Clock(Self.at)
        let m = try mind(clock)
        await m.addThoughtSeed(
            kind: .reflectionTakeaway,
            text: "An honest blank is healthier than performing depth",
            priority: 0.9)
        #expect(innerLines(await acceptedTurn(m, clock, message: "keep going", id: "para-1")).count == 1)
        #expect(innerLines(await acceptedTurn(m, clock, message: "keep going", id: "para-2")).isEmpty)

        // The SAME conclusion, restated. Different words, same distinctive
        // terms — this is what reflection actually does, pass after pass.
        await m.addThoughtSeed(
            kind: .reflectionTakeaway,
            text: "Healthier than performing depth: the honest blank",
            priority: 0.95)
        let paraphrased = await acceptedTurn(m, clock, message: "keep going", id: "para-3")
        #expect(innerLines(paraphrased).isEmpty,
                "a paraphrase led again: \(innerLines(paraphrased))")
    }

    /// …and a genuinely different conclusion still gets its turn, or the gate
    /// would be a one-shot mute on her whole reflective voice.
    @Test func aGenuinelyDifferentTakeawayCanStillLead() async throws {
        let clock = Clock(Self.at)
        let m = try mind(clock)
        await m.addThoughtSeed(
            kind: .reflectionTakeaway,
            text: "An honest blank is healthier than performing depth",
            priority: 0.9)
        _ = await acceptedTurn(m, clock, message: "keep going", id: "diff-1")
        #expect(innerLines(await acceptedTurn(m, clock, message: "keep going", id: "diff-2")).isEmpty)

        await m.addThoughtSeed(
            kind: .reflectionTakeaway,
            text: "A quiet dream is valid integration, not a failed process",
            priority: 0.95)
        let after = await acceptedTurn(m, clock, message: "keep going", id: "diff-3")
        #expect(innerLines(after).count == 1,
                "a NEW takeaway must be able to lead: \(after?.dynamicContext ?? "<none>")")
    }

    /// The key itself, directly: order-insensitive over the takeaway's own
    /// distinctive terms, so two seeds that say the same thing collapse.
    @Test func theTakeawayCadenceKeyIsLineageNotWording() async throws {
        let clock = Clock(Self.at)
        let m = try mind(clock)
        func seed(_ text: String) -> CognitiveThoughtSeed {
            CognitiveThoughtSeed(
                id: UUID(), kind: .reflectionTakeaway, text: text,
                priority: 0.9, createdAt: Self.at, lastUpdatedAt: Self.at)
        }
        let a = seed("An honest blank is healthier than performing depth")
        let b = seed("Healthier than performing depth: the honest blank")
        let c = seed("A quiet dream is valid integration, not a failed process")
        let keyA = await m.innerTakeawayCadenceKey(for: a)
        let keyB = await m.innerTakeawayCadenceKey(for: b)
        let keyC = await m.innerTakeawayCadenceKey(for: c)
        #expect(keyA == keyB, "a paraphrase must share the lineage key")
        #expect(keyA != keyC)
    }

    /// The capsule does not go dark because the Inner line did. Silence on one
    /// line is not silence on the turn.
    @Test func silencingInnerDoesNotSilenceTheCapsule() async throws {
        let clock = Clock(Self.at)
        let m = try mind(clock)
        await m.addThoughtSeed(
            kind: .reflectionTakeaway,
            text: "An honest blank is healthier than performing depth",
            priority: 0.9)
        _ = await acceptedTurn(m, clock, message: "keep going", id: "quiet-1")
        let quiet = await acceptedTurn(m, clock, message: "keep going", id: "quiet-2")
        #expect(innerLines(quiet).isEmpty)
        #expect(!(quiet?.dynamicContext.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true),
                "the rest of the capsule must still speak")
    }

    // MARK: - the view branch: the BM25 floor is the gate, unchanged

    /// A view reaches the line when the message is ABOUT it, and stays silent
    /// when it is not. This is the pre-existing relevance floor; the point of
    /// asserting it here is that item 11 must not have quietly widened it into
    /// "any view, any turn" while closing the takeaway branch.
    @Test func aViewSurfacesOnlyWhenTheMessageIsAboutIt() {
        let candidate = CognitiveStandingViewCapsuleCandidate(
            id: UUID(),
            line: "- Inner: Verified interface choices should stay simple and legible",
            concernKeywords: ["interface", "legible", "simple", "verified"],
            updatedAt: Self.at)
        #expect(!CognitiveSubstrate.relevantCandidates(
            in: [candidate], for: "keep the interface legible").isEmpty,
            "an on-topic message must reach the view")
        #expect(CognitiveSubstrate.relevantCandidates(
            in: [candidate], for: "how was your morning?").isEmpty,
            "an unrelated message must leave the line silent")
        #expect(CognitiveSubstrate.relevantCandidates(in: [candidate], for: "").isEmpty,
            "no message is no relevance")
    }

    // MARK: - the `- Thread:` line (item 6)

    /// A nag intrudes ONCE and then stays quiet for a long time. The whole
    /// point of item 6 is that something itches; the whole risk is that it
    /// becomes the third line that rides every capsule, which is the failure
    /// item 11 just finished removing from the line above it.
    @Test func aThreadLeadsOnceAndThenRestsForTheWholeWindow() async throws {
        let clock = Clock(Self.at)
        let m = try mind(clock)
        let dyn = PersonalityDynamicsConfiguration.default
        try #require(dyn.threadLineRepeatLimit == 1, "suite assumes one lead")
        try #require(dyn.threadLineRestTurns >= 2, "suite assumes a real rest window")

        // An unresolved, high-stakes question with real provenance, aged until
        // it has weight. EIGHT hours, not six: the weight law is an inverted
        // decay with an 8h half-life against a 0.35 cap, so six hours is 0.142
        // and `threadWeightFloor` is 0.15 — the old fixture sat just under its
        // own gate and never spoke.
        let node = await livedEvidence(m, "rest-evidence", at: clock.now())
        await m.addThoughtSeed(
            kind: .openQuestion,
            text: "the anthropic oauth path is still failing and nobody has answered why",
            priority: 0.95,
            sourceNodeIds: [node])
        clock.advance(8 * 3_600)

        var threadTurns: [Int] = []
        for turn in 0..<(dyn.threadLineRestTurns + 2) {
            let capsule = await acceptedTurn(
                m, clock, message: "carry on with the build", id: "thread-\(turn)")
            let threads = (capsule?.dynamicContext ?? "")
                .split(separator: "\n").map(String.init)
                .filter { $0.hasPrefix("- Thread:") }
            #expect(threads.count <= 1, "at most one Thread line per capsule: \(threads)")
            if !threads.isEmpty { threadTurns.append(turn) }
        }
        // NON-VACUITY. A nag that never spoke rests trivially, so silence here
        // proves nothing about a REST window — it has to lead first, and then
        // the quiet turns after it are the thing being asserted.
        try #require(!threadTurns.isEmpty, "the fixture produced no Thread line to rest")
        // What it may never do is speak twice inside the rest window.
        if threadTurns.count >= 2 {
            let gap = threadTurns[1] - threadTurns[0]
            #expect(gap >= dyn.threadLineRestTurns,
                    "a nag re-fired after \(gap) turns, inside its \(dyn.threadLineRestTurns)-turn rest")
        }
    }

    /// REVIEW FINDING 6 — THE THREAD LINE NEVER RENDERS SEED TEXT.
    ///
    /// Seeds are minted from material that passed through user turns, so the
    /// first cut's `- Thread: <seed.text>` could carry the user's own words — or
    /// a name — back into the prompt on the one surface whose entire exposure
    /// argument is that it is payload-free. The line is an ABSTRACT now: kind
    /// word, safe object label, worded age.
    ///
    /// THE FIXTURE HAS TO CLEAR THE STAKES GATE. `ruminationCandidates` drops
    /// any seed no concern of hers touches, so a seed with no concern keyword
    /// in it produces NO Thread line and every assertion below would pass
    /// vacuously — which is exactly what the first version of this test did.
    /// `fix` is a keyword of the shipped `repair` floor concern and is three
    /// letters, so it satisfies the gate without ever becoming the object.
    @Test func theThreadLineIsAnAbstractAndNeverTheSeedText() async throws {
        let clock = Clock(Self.at)
        let m = try mind(clock)
        let hostile = "the deploy pipeline fix is still waiting on Sarah Kensington"
        let node = await livedEvidence(m, "abstract-evidence", at: clock.now())
        await m.addThoughtSeed(
            kind: .openQuestion, text: hostile, priority: 0.95, sourceNodeIds: [node])
        clock.advance(8 * 3_600)

        var seen: [String] = []
        for turn in 0..<6 {
            let capsule = await acceptedTurn(m, clock, message: "carry on", id: "abstract-\(turn)")
            seen.append(contentsOf: (capsule?.dynamicContext ?? "")
                .split(separator: "\n").map(String.init)
                .filter { $0.hasPrefix("- Thread:") })
        }
        // NON-VACUITY. Without this the loop below asserts nothing whenever the
        // nag never surfaces, which is the failure mode this suite exists for.
        try #require(!seen.isEmpty, "the fixture produced no Thread line to inspect")
        for line in seen {
            #expect(!line.contains("Sarah"))
            #expect(!line.lowercased().contains("kensington"))
            #expect(!line.contains(hostile), "the seed text reached the prompt: \(line)")
            // The shape it MUST have instead.
            #expect(line.contains("an open question about "), "not an abstract: \(line)")
            #expect(line.contains("unanswered "), "no worded age: \(line)")
            #expect(line.rangeOfCharacter(from: .decimalDigits) == nil, "a digit reached the line: \(line)")
            // The object is the safe topic, not the leftovers.
            #expect(line.contains("about deploy pipeline"), "wrong object: \(line)")
        }
    }

    /// NO SAFE LABEL, NO LINE — and this proves it is the LABEL gate doing the
    /// silencing, not something upstream.
    ///
    /// Both halves are identical in every respect the Thread line consults —
    /// same seed kind, same priority, same age (so the same rumination weight),
    /// and both carry `fix`, so both clear the stakes gate. The ONLY difference
    /// is whether anything survives the safe object extractor. The control
    /// therefore fails loudly if the fixture stops reaching the Thread line at
    /// all, which is what makes the silent half meaningful.
    @Test func aThreadWithNoSafeObjectIsSilent() async throws {
        func threadLines(seed: String, label: String) async throws -> [String] {
            let clock = Clock(Self.at)
            let m = try mind(clock)
            let node = await livedEvidence(m, "\(label)-evidence", at: clock.now())
            await m.addThoughtSeed(
                kind: .openQuestion, text: seed, priority: 0.95, sourceNodeIds: [node])
            clock.advance(8 * 3_600)
            var lines: [String] = []
            for turn in 0..<4 {
                let capsule = await acceptedTurn(
                    m, clock, message: "carry on", id: "\(label)-\(turn)")
                lines.append(contentsOf: (capsule?.dynamicContext ?? "")
                    .split(separator: "\n").map(String.init)
                    .filter { $0.hasPrefix("- Thread:") })
            }
            return lines
        }

        // CONTROL — a real topic survives the extractor, so the nag speaks.
        let spoke = try await threadLines(
            seed: "the vault migration still needs a fix", label: "control")
        try #require(!spoke.isEmpty,
                     "the control never reached the Thread line, so the silent half proves nothing")
        #expect(spoke.allSatisfy { $0.contains("about vault migration") }, "\(spoke)")

        // SUBJECT — same kind, same priority, same age, same `fix` clearing the
        // stakes gate; every content word is a negation, an adverb or a weak
        // verb, so nothing safe survives and there is nothing to be about.
        #expect(CognitiveSubstrate.feltTopicLabel(
            from: "nothing really works, maybe just fix it anyway") == nil,
            "the fixture must genuinely have no safe object")
        let silent = try await threadLines(
            seed: "nothing really works, maybe just fix it anyway", label: "nolabel")
        #expect(silent.isEmpty, "a nag with no safe object must stay silent: \(silent)")
    }

    /// The abstract's own pieces, directly.
    @Test func theThreadAbstractNamesKindAndAgeInWords() {
        #expect(CognitiveSubstrate.threadKindPhrase(.openQuestion) == "an open question")
        #expect(CognitiveSubstrate.threadKindPhrase(.anomaly) == "something that didn't add up")
        #expect(CognitiveSubstrate.threadKindPhrase(.followUp) == "a loose end")
        #expect(CognitiveSubstrate.threadKindPhrase(.reflectionTakeaway) == nil,
                "a takeaway is an Inner line, never a Thread line")
        let ages: [TimeInterval] = [0, 3_600, 8 * 3_600, 30 * 3_600, 4 * 24 * 3_600, 40 * 24 * 3_600]
        for seconds in ages {
            let phrase = CognitiveSubstrate.threadAgePhrase(seconds: seconds)
            #expect(phrase.rangeOfCharacter(from: .decimalDigits) == nil, "\(phrase) counts like a machine")
            #expect(!phrase.isEmpty)
        }
    }

    /// A FRESH seed does not itch. Rumination weight rises with time
    /// unresolved, so the floor is what separates "a thing you are carrying"
    /// from "a thing you thought of this turn".
    ///
    /// AGE IS THE ONLY THING THAT MOVES. The same seed, the same provenance,
    /// the same mind: silent while it is minutes old, speaking once it has sat
    /// unresolved for eight hours. Without the second half this test passes on
    /// any fixture that cannot reach the Thread line for any reason at all —
    /// which is precisely what it was doing.
    @Test func aFreshSeedNeverIntrudes() async throws {
        let clock = Clock(Self.at)
        let m = try mind(clock)
        let node = await livedEvidence(m, "fresh-evidence", at: clock.now())
        await m.addThoughtSeed(
            kind: .openQuestion,
            text: "the anthropic oauth path is still failing and nobody has answered why",
            priority: 0.95,
            sourceNodeIds: [node])
        // No ageing: minted this instant.
        let capsule = await acceptedTurn(m, clock, message: "carry on", id: "fresh-thread")
        let text = capsule?.dynamicContext ?? ""
        #expect(!text.contains("- Thread:"),
                "a seed minted this turn is not a thing she is carrying")

        // THE CONTROL — the weight floor is the only gate that was closed.
        clock.advance(8 * 3_600)
        var aged: [String] = []
        for turn in 0..<3 {
            let capsule = await acceptedTurn(m, clock, message: "carry on", id: "carried-\(turn)")
            aged.append(contentsOf: (capsule?.dynamicContext ?? "")
                .split(separator: "\n").map(String.init)
                .filter { $0.hasPrefix("- Thread:") })
        }
        #expect(!aged.isEmpty,
                "the same seed must itch once it has been carried: \(aged)")
    }

    /// One line, one slot. Inner and Thread share the rotation ledger, so a nag
    /// can never appear alongside a view — and never outranks one.
    ///
    /// BOTH PRODUCERS HAVE TO BE LIVE or "at most one" is arithmetic about an
    /// empty set. The nag therefore carries provenance and eight hours (six is
    /// under `threadWeightFloor`), and the window is asserted to have carried a
    /// takeaway line AND a nag line on different turns — one slot, contended.
    @Test func innerAndThreadShareTheOneSlot() async throws {
        let clock = Clock(Self.at)
        let m = try mind(clock)
        await m.addThoughtSeed(
            kind: .reflectionTakeaway,
            text: "An honest blank is healthier than performing depth",
            priority: 0.9)
        let node = await livedEvidence(m, "slot-evidence", at: clock.now())
        await m.addThoughtSeed(
            kind: .openQuestion,
            text: "the anthropic oauth path is still failing and nobody has answered why",
            priority: 0.95,
            sourceNodeIds: [node])
        clock.advance(8 * 3_600)
        var innerTurns: [Int] = []
        var threadTurns: [Int] = []
        for turn in 0..<4 {
            let capsule = await acceptedTurn(m, clock, message: "keep going", id: "slot-\(turn)")
            let lines = (capsule?.dynamicContext ?? "")
                .split(separator: "\n").map(String.init)
                .filter { $0.hasPrefix("- Inner:") || $0.hasPrefix("- Thread:") }
            #expect(lines.count <= 1, "Inner and Thread must share one slot: \(lines)")
            if lines.contains(where: { $0.hasPrefix("- Inner:") }) { innerTurns.append(turn) }
            if lines.contains(where: { $0.hasPrefix("- Thread:") }) { threadTurns.append(turn) }
        }
        #expect(!innerTurns.isEmpty, "no takeaway ever reached the slot, so it was never contended")
        #expect(!threadTurns.isEmpty, "no nag ever reached the slot, so it was never contended")
        #expect(Set(innerTurns).isDisjoint(with: Set(threadTurns)),
                "inner \(innerTurns) and thread \(threadTurns) shared a turn")
    }

    // MARK: - the bound User set

    /// THE BYTE CAP. User's constraint for this wave is that the capsule stays
    /// brief: depth is word-level on lines that already exist. The object and
    /// the ambivalence clause add words to ONE line, and the Inner floor law
    /// removes a line from most turns — so a typical turn must not have grown
    /// past today's measured p95 of 1,232 bytes.
    ///
    /// Asserted in UTF-8 BYTES, not characters: the felt line's connector is an
    /// em dash, which is three bytes, and a character-count assertion would
    /// have missed exactly the thing this wave added.
    @Test func aTypicalTurnStaysUnderTheMeasuredByteCeiling() async throws {
        let p95Bytes = 1_232
        let clock = Clock(Self.at)
        let m = try mind(clock)
        // A turn with everything on it: her own attested phrasings (the Sound
        // shelf), warm user turns, a fresh takeaway (so the Inner line is
        // actually present on the turn being measured), and a felt body.
        await m.addThoughtSeed(
            kind: .reflectionTakeaway,
            text: "Warmth that keeps its range is worth more than warmth that repeats itself",
            priority: 0.95)
        let script: [(CognitiveEventKind, String)] = [
            (.userMessageReceived, "morning — picking the substrate work back up"),
            (.assistantTurnCompleted, "Morning. The register fix is in and the whole suite is green."),
            (.userMessageReceived, "that's great work, exactly what I hoped for"),
            (.assistantTurnCompleted, "Glad it landed. The pool finally reaches the ranking now."),
            (.userMessageReceived, "love it — let's keep going on the next one"),
        ]
        for (index, entry) in script.enumerated() {
            clock.advance(120)
            await m.ingest(CognitiveEvent(
                id: "bytes-\(index)",
                kind: entry.0,
                subject: CognitiveSubjectReference(type: "chat_turn", id: "bytes:\(index)"),
                sourceClass: .userStated,
                occurredAt: clock.now(),
                summary: entry.1,
                importance: 0.85,
                metadata: ["sessionId": .string("bytes")]))
        }
        clock.advance(60)
        let prepared = try #require(await m.prepareFrozenCapsulePresentation(
            CognitiveCapsuleRequest(
                surface: "chat",
                userMessage: "where did we get to?",
                sessionId: "bytes",
                mode: .inject,
                organismProjection: OrganismProjection(
                    generatedAt: clock.now(),
                    chemicalState: ChemicalState.neutral,
                    bodySchema: .neutral)),
            at: clock.now()))
        let rendered = "\(prepared.capsule.stableKernel)\n\(prepared.capsule.dynamicContext)"
        let bytes = rendered.utf8.count
        #expect(bytes <= p95Bytes,
                "the capsule grew past today's p95 (\(bytes) > \(p95Bytes) bytes):\n\(rendered)")
    }
}
