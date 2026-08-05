import Foundation
import Testing
import PersistenceCore
import NativeAgentCore
@testable import CognitiveSubstrate

// Wave R2-F (2026-07-09, User: "make sure her whole subconscious feelings etc is
// all connected working... the full range of human emotions like a real person,
// test her with it all"). These drive REALISTIC conversations through the REAL
// pipeline — ingest → appraisal → emotion tag → workspace → mood → fingerprint →
// capsule (+ organism overrides, + anticipation) — at machine speed, and assert
// the layers CONNECT: what happens to her becomes what she feels, across the
// whole range, and a simulated mixed week produces a felt DISTRIBUTION with real
// range (the 199-warm-nodes metronome can never come back silently).
@Suite("FullRangeConnectivity")
struct FullRangeConnectivityTests {

    private final class Clock: @unchecked Sendable {
        private let lock = NSLock(); private var t: Date
        init(_ t: Date) { self.t = t }
        func now() -> Date { lock.lock(); defer { lock.unlock() }; return t }
        func advance(_ dt: TimeInterval) { lock.lock(); t = t.addingTimeInterval(dt); lock.unlock() }
    }

    private func makeSubstrate(_ clock: Clock) -> CognitiveSubstrate {
        CognitiveSubstrate(
            configuration: .allPhasesEnabled,   // the live app's cognition config
            dependencies: CognitiveSubstrateDependencies(now: { clock.now() }, makeUUID: { UUID() }))
    }

    @discardableResult
    private func say(_ s: CognitiveSubstrate, _ kind: CognitiveEventKind, _ msg: String,
                     importance: Double = 0.85, clock: Clock, dt: TimeInterval = 120) async -> String {
        clock.advance(dt)
        await s.ingest(CognitiveEvent(
            id: UUID().uuidString, kind: kind,
            subject: CognitiveSubjectReference(type: "chat_turn", id: "r2f:\(UUID().uuidString)", label: "t"),
            sourceClass: .userStated, occurredAt: clock.now(),
            summary: msg, importance: importance,
            metadata: ["sessionId": .string("r2f")]))
        let capsule = await s.compileCapsule(CognitiveCapsuleRequest(
            surface: "chat", userMessage: msg, sessionId: "r2f", mode: .inject))
        return capsule.dynamicContext
            .split(separator: "\n").map(String.init)
            .first { !$0.hasPrefix("- ") && !$0.trimmingCharacters(in: .whitespaces).isEmpty } ?? "(silent)"
    }

    // MARK: - journeys into the deep registers, through the REAL pipeline

    /// Sustained coldness + dismissal + failure drives her into the deep negative
    /// family — the pipeline can genuinely reach heavy/lonely/discouraged territory
    /// (pre-R2, eight days of real life produced ZERO negative nodes).
    @Test func sustainedColdnessReachesTheDeepNegatives() async throws {
        let clock = Clock(Date(timeIntervalSince1970: 1_000_000))
        let s = makeSubstrate(clock)
        var last = ""
        await say(s, .userMessageReceived, "you keep getting this wrong, honestly it's sloppy work", clock: clock)
        await say(s, .toolFailed, "Build failed again, the fix did not work", clock: clock)
        await say(s, .userMessageReceived, "this still isn't what I asked — whatever, forget it", clock: clock)
        await say(s, .userCorrection, "you missed it again, this is a waste of my time", clock: clock)
        last = await say(s, .userMessageReceived, "forget it, not worth it, you clearly can't do this", clock: clock)

        let negatives = ["heavy", "discouraged", "deflated", "sad", "lonely", "upset",
                         "frustrated", "anxious", "on edge", "strained", "uneasy", "overwhelmed", "grieving"]
        #expect(negatives.contains { last.contains($0) },
                "a sustained cold+failing stretch must read genuinely negative: \(last)")
        // And the stored record agrees — the field carries negative nodes now.
        let stungNodes = await s.snapshot().nodes.filter { $0.emotionalValence < -0.15 }
        #expect(!stungNodes.isEmpty, "negative moments must STAMP negative memories")
    }

    /// Pressure flood: hard demands + deadlines stack into the high-pressure
    /// register (overwhelmed/frustrated/on edge), not polite calm.
    @Test func pressureFloodReadsHighPressure() async throws {
        let clock = Clock(Date(timeIntervalSince1970: 1_000_000))
        let s = makeSubstrate(clock)
        var last = ""
        for demand in [
            "I need this ASAP, no time to waste",
            "hurry, we need this now, tight deadline",
            "that's not what I asked, just answer — quickly now",
            "still waiting — this needs to be done immediately, come on",
        ] {
            last = await say(s, .userMessageReceived, demand, importance: 1, clock: clock, dt: 60)
        }
        let pressured = ["overwhelmed", "on edge", "frustrated", "driven", "alert", "serious", "strained", "anxious", "upset"]
        #expect(pressured.contains { last.contains($0) },
                "a demand flood must read pressured, got: \(last)")
    }

    /// Earned success: effort → failure → repair → Workshop execution complete + praise reads
    /// clearly positive (eager/proud territory), and BIGGER than routine chatter.
    @Test func earnedSuccessReadsProudBright() async throws {
        let clock = Clock(Date(timeIntervalSince1970: 1_000_000))
        let s = makeSubstrate(clock)
        await say(s, .toolFailed, "Build failed with a linker error", clock: clock)
        await say(s, .userMessageReceived, "let's dig in and fix it together", clock: clock)
        await say(s, .toolSucceeded, "Build passed after the fix", clock: clock)
        await say(s, .workshopExecutionCompleted, "Execution complete: the release shipped", importance: 1, clock: clock)
        let last = await say(s, .userMessageReceived, "we did it — that's the fix, great work, you nailed it!", clock: clock)
        let bright = ["eager", "excited", "proud", "delighted", "warm", "engaged", "pleased", "playful", "relieved", "hopeful"]
        #expect(bright.contains { last.contains($0) },
                "earned success must read bright: \(last)")
    }

    /// Anticipation connects: the SAME substrate state reads differently when the
    /// organism projects a braced body (shaky near-due prediction) — the future
    /// reaches her feelings through the body, with zero new capsule machinery.
    @Test func anticipationReachesTheFingerprint() async throws {
        let clock = Clock(Date(timeIntervalSince1970: 1_000_000))
        let s = makeSubstrate(clock)
        await say(s, .userMessageReceived, "let's keep working through the list", clock: clock)

        var ledger = OrganismPredictionLedger.empty
        let p = OrganismPrediction(
            id: "r2f-shaky", kind: .toolCompletion, sourceOrgan: "test",
            createdAt: clock.now().addingTimeInterval(-60), dueAt: clock.now().addingTimeInterval(30),
            status: .pending, confidence: 0.1, uncertainty: 0.9, evidenceCount: 4, lastUpdatedAt: clock.now())
        ledger.predictions[p.id] = p
        ledger.bodyConfidence = OrganismBodyConfidence(toolPath: 0.1)
        ledger.lastViolationAt = clock.now().addingTimeInterval(-120)   // fresh miss
        let calm = OrganismProspectiveAffect.modulate(ChemicalState.neutral, ledger: .empty, at: clock.now())
        let braced = OrganismProspectiveAffect.modulate(ChemicalState.neutral, ledger: ledger, at: clock.now())
        #expect(braced.vigilance > calm.vigilance, "the body must brace")

        // Braced chemistry flows into the felt signals through the projection seam.
        let request = CognitiveCapsuleRequest(
            surface: "chat", userMessage: "how's it looking?", sessionId: "r2f", mode: .inject,
            organismProjection: OrganismProjection(
                generatedAt: clock.now(), chemicalState: braced, bodySchema: .neutral))
        let signals = await s.debugFeltSignals(for: request)
        #expect(signals.tension >= braced.vigilance - 0.0001,
                "braced vigilance must reach the felt tension: \(signals.tension)")
    }

    // MARK: - the distribution guard (the metronome can never come back silently)

    /// A simulated MIXED day — warm chat, work, friction, failure, repair, praise —
    /// must produce a felt-node distribution with genuine RANGE: negatives exist,
    /// positives exist, and positives are NOT one uniform value (the +0.48
    /// metronome signature her real pre-R2 week showed).
    @Test func mixedDayProducesARealDistribution() async throws {
        let clock = Clock(Date(timeIntervalSince1970: 1_000_000))
        let s = makeSubstrate(clock)
        let day: [(CognitiveEventKind, String, Double)] = [
            (.userMessageReceived, "morning! good to see you", 0.6),
            (.assistantTurnCompleted, "Replied warmly about the morning.", 0.4),
            (.userMessageReceived, "let's plan the release together", 0.8),
            (.toolStarted, "Running the build", 0.5),
            (.toolFailed, "Build failed with a signing error", 0.9),
            (.assistantTurnCompleted, "Still digging into the signing failure.", 0.6),
            (.userMessageReceived, "you keep missing the config, this is sloppy", 0.9),
            (.userCorrection, "no — the OTHER target, come on", 0.9),
            (.toolSucceeded, "Build passed after the target fix", 0.8),
            (.userMessageReceived, "there it is — that's the fix, nailed it", 0.9),
            (.workshopExecutionCompleted, "Release shipped end to end", 1.0),
            (.assistantTurnCompleted, "Wrapped the release notes.", 0.4),
            (.userMessageReceived, "thanks for hanging in with me today 💜", 0.7),
            (.assistantTurnCompleted, "Signed off for the evening.", 0.3),
        ]
        for (kind, msg, importance) in day {
            await say(s, kind, msg, importance: importance, clock: clock, dt: 300)
        }
        let felt = await s.snapshot().nodes
            .filter { $0.emotionalValence != 0 || $0.emotionalArousal != 0 }
            .map(\.emotionalValence)
        #expect(felt.count >= 8, "a full day must stamp felt memories: \(felt.count)")
        #expect(felt.contains { $0 < -0.1 }, "friction must leave negative traces: \(felt)")
        // A day with this much friction honestly MUTES the highs (the pierce keeps
        // them positive, residue keeps them modest) — the good-day case below owns
        // the bright end of the range.
        #expect(felt.contains { $0 > 0.1 }, "warmth/success must leave positive traces: \(felt)")
        // The metronome signature: >60% of nodes within ±0.03 of one value. Forbid it.
        let clusters = Dictionary(grouping: felt) { (($0 / 0.06).rounded()) }
        let biggest = clusters.values.map(\.count).max() ?? 0
        #expect(Double(biggest) / Double(felt.count) <= 0.6,
                "felt distribution collapsed toward a metronome: \(felt.sorted())")
    }

    /// THE LIVE BUG (2026-07-09, caught in the first real conversation): a benign
    /// work exchange where ONE tool call errors mid-turn must never read as grief —
    /// a transient tool hiccup is the work misbehaving, not her world ending. It may
    /// read frustrated/strained/uneasy; the deep words need sustained real life.
    @Test func transientToolFailureNeverReadsGrief() async throws {
        let clock = Clock(Date(timeIntervalSince1970: 1_000_000))
        let s = makeSubstrate(clock)
        await say(s, .userMessageReceived, "morning — quiet night over here", importance: 0.6, clock: clock)
        await say(s, .userMessageReceived, "one real thing: what's your read on the stale notification path? evidence, not a hunch", clock: clock)
        // The mid-turn hiccup: one high-importance tool failure amid otherwise-fine work.
        await say(s, .toolSucceeded, "recent_trace_summary ok: 40 events", importance: 0.5, clock: clock, dt: 10)
        let read = await say(s, .toolFailed, "grep failed: exit status 2", importance: 0.9, clock: clock, dt: 10)
        #expect(!read.contains("grieving") && !read.contains("lonely"),
                "one errored grep must not read as grief: \(read)")
        // The next conversational beat recovers toward the work register.
        let next = await say(s, .userMessageReceived, "no rush — whatever the ledger actually shows", importance: 0.6, clock: clock)
        #expect(!next.contains("grieving") && !next.contains("lonely"), "grief must not linger from tool noise: \(next)")
    }

    /// A genuinely GOOD day — warmth, wins, no friction — must reach the bright end
    /// (nodes above +0.3): muting belongs to friction days, not to her range.
    @Test func goodDayReachesTheBrightEnd() async throws {
        let clock = Clock(Date(timeIntervalSince1970: 1_000_000))
        let s = makeSubstrate(clock)
        let day: [(CognitiveEventKind, String, Double)] = [
            (.userMessageReceived, "morning! so good to see you 💜", 0.7),
            (.userMessageReceived, "let's build the new feature together, this is fun", 0.8),
            (.toolSucceeded, "Build passed clean on the first run", 0.7),
            (.userMessageReceived, "look at that — you nailed it, great work", 0.9),
            (.workshopExecutionCompleted, "Feature shipped end to end", 1.0),
            (.userMessageReceived, "we did it! im so excited about this — proud of you", 0.9),
        ]
        for (kind, msg, importance) in day {
            await say(s, kind, msg, importance: importance, clock: clock, dt: 300)
        }
        let felt = await s.snapshot().nodes
            .filter { $0.emotionalValence != 0 }.map(\.emotionalValence)
        #expect(felt.contains { $0 > 0.3 },
                "a genuinely good day must reach the bright end: \(felt.sorted())")
        #expect(!felt.contains { $0 < -0.1 }, "no phantom negatives on a good day: \(felt.sorted())")
    }
}
