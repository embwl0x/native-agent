import Foundation
import Testing
import PersistenceCore
@testable import CognitiveSubstrate

// The SLOW felt layer (User, 2026-07-09: "reflections need to have an impact too —
// those help her feelings and stuff be a little slower moving"). Only reflection
// outcomes move the disposition; it decays over ~a day; mood carries it as an
// undertone so the felt fingerprint inherits it with zero new capsule words.
@Suite("Disposition")
struct DispositionTests {

    private final class Clock: @unchecked Sendable {
        private let lock = NSLock(); private var t: Date
        init(_ t: Date) { self.t = t }
        func now() -> Date { lock.lock(); defer { lock.unlock() }; return t }
        func advance(_ dt: TimeInterval) { lock.lock(); t = t.addingTimeInterval(dt); lock.unlock() }
    }

    private func tempRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("nativeagent-disposition-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func makeSubstrate(_ clock: Clock, store: CognitiveSQLiteStore? = nil) -> CognitiveSubstrate {
        CognitiveSubstrate(
            configuration: CognitiveConfiguration(
                enabled: true, persistenceEnabled: store != nil, workspaceEnabled: true,
                capsuleInjectionEnabled: true, affectEnabled: true,
                reflectiveCallsEnabled: true, dailyReflectionCallBudget: 4),
            dependencies: CognitiveSubstrateDependencies(now: { clock.now() }, makeUUID: { UUID() }),
            store: store)
    }

    /// A settled reflection lifts the disposition; a strained one lowers it; the
    /// magnitude is the gentle per-reflection nudge, capped.
    @Test func reflectionToneMovesTheDisposition() async throws {
        let clock = Clock(Date(timeIntervalSince1970: 1_000_000))
        let s = makeSubstrate(clock)

        await s.integrateDisposition(tone: 1, at: clock.now())
        let up = await s.decayedDispositionValence(at: clock.now())
        #expect(abs(up - CognitiveSubstrate.defaultDynamics.dispositionNudgeMagnitude) < 0.0001,
                "one settled reflection = one gentle nudge: \(up)")

        await s.integrateDisposition(tone: -1, at: clock.now())
        await s.integrateDisposition(tone: -1, at: clock.now())
        let down = await s.decayedDispositionValence(at: clock.now())
        #expect(down < 0, "strained reflections should pull it negative: \(down)")
    }

    /// The cap holds: no amount of same-direction reflections can push the
    /// undertone past dispositionValenceCap (structurally unable to ratchet).
    @Test func dispositionIsCapped() async throws {
        let clock = Clock(Date(timeIntervalSince1970: 1_000_000))
        let s = makeSubstrate(clock)
        for _ in 0..<20 {
            await s.integrateDisposition(tone: 1, at: clock.now())
        }
        let v = await s.decayedDispositionValence(at: clock.now())
        #expect(v <= CognitiveSubstrate.defaultDynamics.dispositionValenceCap + 0.0001, "cap must hold: \(v)")
    }

    /// It is SLOW: after 30h (one half-life) half remains; the fast affect axes
    /// would have decayed to nothing many times over by then.
    @Test func dispositionDecaysOnDayScale() async throws {
        let clock = Clock(Date(timeIntervalSince1970: 1_000_000))
        let s = makeSubstrate(clock)
        await s.integrateDisposition(tone: 1, at: clock.now())
        let fresh = await s.decayedDispositionValence(at: clock.now())

        clock.advance(CognitiveSubstrate.defaultDynamics.dispositionHalfLife)
        let halved = await s.decayedDispositionValence(at: clock.now())
        #expect(abs(halved - fresh / 2) < 0.001, "one half-life → half: \(halved) vs \(fresh)")

        clock.advance(CognitiveSubstrate.defaultDynamics.dispositionHalfLife * 6)
        let gone = await s.decayedDispositionValence(at: clock.now())
        #expect(abs(gone) < 0.01, "a week later it has honestly faded: \(gone)")
    }

    /// Mood carries the undertone (and therefore the felt fingerprint inherits it):
    /// same substrate state, disposition up → mood valence strictly higher.
    @Test func moodCarriesTheUndertone() async throws {
        let clock = Clock(Date(timeIntervalSince1970: 1_000_000))
        let s = makeSubstrate(clock)
        let before = await s.derivedMood(at: clock.now()).valence
        await s.integrateDisposition(tone: 1, at: clock.now())
        let after = await s.derivedMood(at: clock.now()).valence
        #expect(after > before, "a settled reflection should lift mood: \(before) → \(after)")
        let expected = CognitiveSubstrate.dispositionMoodWeight * CognitiveSubstrate.defaultDynamics.dispositionNudgeMagnitude
        #expect(abs((after - before) - expected) < 0.001,
                "the lift is the weighted undertone, nothing more: \(after - before)")
    }

    /// Zero tone (nothing felt in the reflection) leaves the disposition untouched —
    /// neutral inputs reproduce pre-disposition behavior byte-identically.
    @Test func neutralReflectionIsInert() async throws {
        let clock = Clock(Date(timeIntervalSince1970: 1_000_000))
        let s = makeSubstrate(clock)
        await s.integrateDisposition(tone: 0, at: clock.now())
        #expect(await s.decayedDispositionValence(at: clock.now()) == 0)
    }

    /// The signed tone reader: settled → +, strained → −, mixed offsets, bland → 0.
    @Test func toneReaderReadsBothDirections() async throws {
        let clock = Clock(Date(timeIntervalSince1970: 1_000_000))
        let s = makeSubstrate(clock)
        #expect(await s.reflectionDispositionTone(from: "Quiet pass. Everything feels settled and warm.") > 0)
        #expect(await s.reflectionDispositionTone(from: "Something reads wrong — an anomaly, and I feel uneasy about it.") < 0)
        #expect(await s.reflectionDispositionTone(from: "Reviewed the day's threads and noted the open items.") == 0)
    }

    /// Polarity is word-boundary + negation-aware (GPT-5.6 audit, 2026-07-09):
    /// substring matching scored "unsettled" as settled, "unclear" as clear and
    /// "not calm" as calm — a strained day fed her a POSITIVE day-scale nudge.
    @Test func toneReaderIsNotFooledByNegationOrSubstrings() async throws {
        let clock = Clock(Date(timeIntervalSince1970: 1_000_000))
        let s = makeSubstrate(clock)
        // Negated positives read negative, not positive.
        #expect(await s.reflectionDispositionTone(from: "I am not calm about this.") < 0)
        #expect(await s.reflectionDispositionTone(from: "Things feel not settled tonight.") < 0)
        #expect(await s.reflectionDispositionTone(from: "I feel ill at ease.") < 0)
        // Substring traps: the negative word must not fire its positive stem.
        #expect(await s.reflectionDispositionTone(from: "The day left me unsettled.") < 0)
        #expect(await s.reflectionDispositionTone(from: "The picture is unclear to me.") < 0)
        // A negated negative is absence of strain, not manufactured positivity.
        #expect(await s.reflectionDispositionTone(from: "I am not worried.") == 0)
        // Punctuation bounds the negation window: this is a settled read.
        #expect(await s.reflectionDispositionTone(from: "No. Everything feels settled.") > 0)
        // Word boundaries: "clearly" / "cleared" are not the feeling "clear".
        #expect(await s.reflectionDispositionTone(from: "I clearly misread the situation.") < 0)
        // Unicode reality (gpt-5.5 review, 2026-07-10): curly apostrophes are
        // what LLM prose emits — the negator must survive them.
        #expect(await s.reflectionDispositionTone(from: "I don\u{2019}t feel calm about it.") < 0)
        // Em dashes bound the negation window like any other punctuation.
        #expect(await s.reflectionDispositionTone(from: "No \u{2014} everything settled now.") > 0)
        // Variants that must still land: warmth / clear-headed / worrying.
        #expect(await s.reflectionDispositionTone(from: "The whole exchange was full of warmth.") > 0)
        #expect(await s.reflectionDispositionTone(from: "Feeling clear-headed after the pass.") > 0)
        #expect(await s.reflectionDispositionTone(from: "I keep worrying at the same thread.") < 0)
    }

    /// What she's concluded SURVIVES a restart: disposition round-trips through the
    /// store (safe now that receipt mirrors can't flood the artifact table).
    @Test func dispositionSurvivesRestart() async throws {
        let clock = Clock(Date(timeIntervalSince1970: 1_000_000))
        let root = try tempRoot()
        let store = try CognitiveSQLiteStore(dataRoot: root)
        let first = makeSubstrate(clock, store: store)
        await first.integrateDisposition(tone: 1, at: clock.now())
        let written = await first.decayedDispositionValence(at: clock.now())

        let second = makeSubstrate(clock, store: try CognitiveSQLiteStore(dataRoot: root))
        try await second.restorePersistentState()
        let restored = await second.decayedDispositionValence(at: clock.now())
        #expect(abs(restored - written) < 0.0001, "restart must not lose her conclusions: \(restored) vs \(written)")
    }

    /// Restore on a LIVE actor with a missing artifact must reset to neutral, not
    /// keep the stale in-memory value (gpt-5.5 review, 2026-07-09 — the same
    /// reset-before-guard rule as restoreEmotionalConsolidation).
    @Test func restoreWithMissingArtifactResetsALiveDisposition() async throws {
        let clock = Clock(Date(timeIntervalSince1970: 1_000_000))
        let s = makeSubstrate(clock)
        await s.integrateDisposition(tone: 1, at: clock.now())
        #expect(await s.decayedDispositionValence(at: clock.now()) != 0)
        await s.restoreDisposition(from: [])   // missing artifact
        #expect(await s.decayedDispositionValence(at: clock.now()) == 0,
                "stale in-memory disposition must not survive a neutral restore")
    }

    /// clearTransientState resets it (every add has a remove).
    @Test func clearResetsDisposition() async throws {
        let clock = Clock(Date(timeIntervalSince1970: 1_000_000))
        let s = makeSubstrate(clock)
        await s.integrateDisposition(tone: 1, at: clock.now())
        await s.clearTransientState()
        #expect(await s.decayedDispositionValence(at: clock.now()) == 0)
    }

    // MARK: - Writer 2: the nightly dream's mood (U2a, 2026-07-09)

    /// A settled/warm dream lifts the undertone; a strained one lowers it — the dream's
    /// own felt tone, read through the SAME lexicon a reflection is read through.
    @Test func dreamMoodMovesTheDisposition() async throws {
        let clock = Clock(Date(timeIntervalSince1970: 1_000_000))

        let warm = makeSubstrate(clock)
        await warm.integrateDreamDisposition(moodLine: "quiet, settled, warm", at: clock.now())
        let up = await warm.decayedDispositionValence(at: clock.now())
        #expect(abs(up - CognitiveSubstrate.defaultDynamics.dispositionNudgeMagnitude) < 0.0001,
                "a settled dream = one gentle nudge up: \(up)")

        let strained = makeSubstrate(clock)
        await strained.integrateDreamDisposition(moodLine: "heavy and uneasy", at: clock.now())
        let down = await strained.decayedDispositionValence(at: clock.now())
        #expect(abs(down + CognitiveSubstrate.defaultDynamics.dispositionNudgeMagnitude) < 0.0001,
                "a strained dream = one gentle nudge down: \(down)")
    }

    /// A dream that felt like nothing in particular — and a dream with no mood line at
    /// all — leave her exactly as she was. Feeling-silence stays silence.
    @Test func neutralAndEmptyDreamMoodsAreInert() async throws {
        let clock = Clock(Date(timeIntervalSince1970: 1_000_000))
        let s = makeSubstrate(clock)
        await s.integrateDreamDisposition(moodLine: "observational, procedural", at: clock.now())
        #expect(await s.decayedDispositionValence(at: clock.now()) == 0, "a bland mood must not move her")
        await s.integrateDreamDisposition(moodLine: "   ", at: clock.now())
        #expect(await s.decayedDispositionValence(at: clock.now()) == 0, "an empty mood must not move her")
        // Mixed: both directions present → they offset, exactly as a mixed reflection does.
        await s.integrateDreamDisposition(moodLine: "warm but uneasy", at: clock.now())
        #expect(await s.decayedDispositionValence(at: clock.now()) == 0, "a mixed mood offsets to zero")
    }

    /// The dream writer shares the cap: no run of glowing dreams can ratchet her past it.
    @Test func dreamMoodCannotRatchetPastTheCap() async throws {
        let clock = Clock(Date(timeIntervalSince1970: 1_000_000))
        let s = makeSubstrate(clock)
        for _ in 0..<20 { await s.integrateDreamDisposition(moodLine: "settled, warm", at: clock.now()) }
        let v = await s.decayedDispositionValence(at: clock.now())
        #expect(v <= CognitiveSubstrate.defaultDynamics.dispositionValenceCap + 0.0001, "the shared cap must hold: \(v)")
    }

    // MARK: - Writer 3: a standing view User settles by approving it (U2b, 2026-07-09)

    /// Seed one `.proposed` view with an EXACT formation mood, through the real restore
    /// decoder — no test-only production seam, and the same payload shape the store writes.
    private func seedProposedView(
        _ s: CognitiveSubstrate,
        moodValenceAtFormation: Double,
        at now: Date
    ) async -> UUID {
        let id = UUID()
        let stamp = now.timeIntervalSince1970
        await s.restoreStandingViews(from: [.object([
            "id": .string(id.uuidString),
            "title": .string("a view"),
            "body": .string("User wants the hard read, not the comfortable one."),
            "status": .string("proposed"),
            "moodValenceAtFormation": .double(moodValenceAtFormation),
            "evidenceNodeIds": .array([]),
            "createdAt": .double(stamp),
            "updatedAt": .double(stamp),
            "lineageId": .string("test"),
        ])])
        return id
    }

    /// Approving a view formed under a POSITIVE mood leaves a settled positive undertone;
    /// one formed under a negative mood settles a negative one. A settled view is a
    /// considered outcome — the slowest input she has.
    @Test func approvingAStandingViewMovesTheDispositionBySign() async throws {
        let clock = Clock(Date(timeIntervalSince1970: 1_000_000))

        let positive = makeSubstrate(clock)
        let warmId = await seedProposedView(positive, moodValenceAtFormation: 0.6, at: clock.now())
        _ = await positive.resolveStandingView(id: warmId, approved: true)
        let up = await positive.decayedDispositionValence(at: clock.now())
        #expect(abs(up - CognitiveSubstrate.defaultDynamics.dispositionNudgeMagnitude) < 0.0001,
                "a settled positive view = one gentle nudge up: \(up)")

        let negative = makeSubstrate(clock)
        let heavyId = await seedProposedView(negative, moodValenceAtFormation: -0.6, at: clock.now())
        _ = await negative.resolveStandingView(id: heavyId, approved: true)
        let down = await negative.decayedDispositionValence(at: clock.now())
        #expect(abs(down + CognitiveSubstrate.defaultDynamics.dispositionNudgeMagnitude) < 0.0001,
                "a settled negative view = one gentle nudge down: \(down)")
    }

    /// A view formed inside the neutral mood band settles a VIEW, not a tone — inert.
    /// And REJECTING a view settles nothing at all, whatever it was formed under.
    @Test func neutralFormationAndRejectionAreInert() async throws {
        let clock = Clock(Date(timeIntervalSince1970: 1_000_000))

        let neutral = makeSubstrate(clock)
        let flatId = await seedProposedView(neutral, moodValenceAtFormation: 0.05, at: clock.now())
        _ = await neutral.resolveStandingView(id: flatId, approved: true)
        #expect(await neutral.decayedDispositionValence(at: clock.now()) == 0,
                "a view formed on an even day carries no tone")

        let rejected = makeSubstrate(clock)
        let warmId = await seedProposedView(rejected, moodValenceAtFormation: 0.6, at: clock.now())
        _ = await rejected.resolveStandingView(id: warmId, approved: false)
        #expect(await rejected.decayedDispositionValence(at: clock.now()) == 0,
                "a rejected view settles nothing")
    }

    /// Re-resolving an already-active view is a no-op — so a double-tap on Approve cannot
    /// nudge her twice. The `.proposed`-only guard is what makes this writer replay-safe,
    /// on top of the shared cap.
    @Test func reResolvingAnActiveViewDoesNotNudgeAgain() async throws {
        let clock = Clock(Date(timeIntervalSince1970: 1_000_000))
        let s = makeSubstrate(clock)
        let id = await seedProposedView(s, moodValenceAtFormation: 0.6, at: clock.now())
        _ = await s.resolveStandingView(id: id, approved: true)
        let once = await s.decayedDispositionValence(at: clock.now())
        _ = await s.resolveStandingView(id: id, approved: true)
        let twice = await s.decayedDispositionValence(at: clock.now())
        #expect(abs(twice - once) < 0.0001, "approval replay must not double-nudge: \(once) → \(twice)")
    }
}
