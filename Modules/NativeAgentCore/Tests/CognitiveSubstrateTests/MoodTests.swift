import Foundation
import Testing
import PersistenceCore
import GRDB
@testable import CognitiveSubstrate

// Wave C — derived MOOD + mood-congruent recall. Proves:
//  (1) derivedMood integrates recency-weighted valence over recent tagged nodes plus
//      the current-affect proxy, excludes stale nodes, and weighs recent over old;
//  (2) recall is mood-congruent — a felt node matching her mood surfaces higher and
//      carries the "mood-congruent" reason, while untagged/neutral is byte-identical;
//  (3) a STRONG mood reaches her phrasing (Feeling + Voice), additively;
//  (4) neutral/legacy stays silent everywhere.
@Suite("Mood")
struct MoodTests {

    private final class Clock: @unchecked Sendable {
        private let lock = NSLock(); private var t: Date
        init(_ t: Date) { self.t = t }
        func now() -> Date { lock.lock(); defer { lock.unlock() }; return t }
    }

    private func config() -> CognitiveConfiguration {
        CognitiveConfiguration(
            enabled: true,
            persistenceEnabled: true,
            workspaceEnabled: true,
            capsuleInjectionEnabled: true,
            affectEnabled: true,
            maximumActiveNodes: 256
        )
    }

    private func tempDataRoot(_ label: String) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("nativeagent-mood-\(label)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    /// A node with an EXACT emotional tag and controllable activation recency.
    private func node(
        summary: String,
        kind: CognitiveNodeKind = .conversationFocus,
        valence: Double,
        arousal: Double,
        warmth: Double,
        createdAt: Date,
        lastActivatedAt: Date
    ) -> CognitiveNode {
        CognitiveNode(
            id: UUID(), kind: kind,
            subjectReference: CognitiveSubjectReference(type: "topic", id: "mood-\(UUID().uuidString)", label: "topic"),
            activation: 0.9, salience: 0.9, confidence: 0.8, sourceClass: .userStated,
            createdAt: createdAt, lastActivatedAt: lastActivatedAt,
            decayHalfLife: 10_000, summary: summary, metadata: [:],
            emotionalValence: valence, emotionalArousal: arousal, emotionalWarmth: warmth)
    }

    private func substrate(with nodes: [CognitiveNode], clock: Clock, label: String) async throws -> CognitiveSubstrate {
        let root = try tempDataRoot(label)
        let store = try CognitiveSQLiteStore(dataRoot: root)
        try await store.saveNodes(nodes, at: clock.now())
        let substrate = CognitiveSubstrate(
            configuration: config(),
            dependencies: CognitiveSubstrateDependencies(now: { clock.now() }, makeUUID: { UUID() }),
            store: store
        )
        try await substrate.restorePersistentState()
        return substrate
    }

    private func request(_ message: String) -> CognitiveCapsuleRequest {
        CognitiveCapsuleRequest(surface: "chat", userMessage: message, sessionId: "s1", mode: .inject)
    }

    private let summary = "User and I are planning the weekend"

    // MARK: - (1) derivedMood integral

    /// Empty field + zero affect → dead-neutral mood.
    @Test func emptyFieldZeroAffectIsNeutral() async throws {
        let clock = Clock(Date(timeIntervalSince1970: 1_000_000))
        let s = try await substrate(with: [], clock: clock, label: "empty")
        let mood = await s.derivedMood(at: clock.now())
        #expect(mood.valence == 0)
        #expect(mood.basis == 0)
    }

    /// Recent warm-tagged nodes → positive mood with the correct basis.
    @Test func recentWarmNodesGivePositiveMood() async throws {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let clock = Clock(now)
        let s = try await substrate(
            with: [
                node(summary: summary, valence: 0.5, arousal: 0.1, warmth: 0.6, createdAt: now, lastActivatedAt: now),
                node(summary: summary + " more", valence: 0.5, arousal: 0.1, warmth: 0.6, createdAt: now, lastActivatedAt: now),
                node(summary: summary + " still", valence: 0.5, arousal: 0.1, warmth: 0.6, createdAt: now, lastActivatedAt: now),
            ],
            clock: clock, label: "warm")
        let mood = await s.derivedMood(at: clock.now())
        #expect(mood.basis == 3, "expected all three felt nodes in the basis: \(mood.basis)")
        #expect(mood.valence > 0, "warm recent nodes should read positive: \(mood.valence)")
        // Neutral (untagged) nodes never enter the basis, so a felt node next to a
        // legacy node counts once.
        let mixed = try await substrate(
            with: [
                node(summary: summary, valence: 0.5, arousal: 0.1, warmth: 0.6, createdAt: now, lastActivatedAt: now),
                node(summary: summary + " legacy", valence: 0, arousal: 0, warmth: 0, createdAt: now, lastActivatedAt: now),
            ],
            clock: clock, label: "mixed")
        let mixedMood = await mixed.derivedMood(at: clock.now())
        #expect(mixedMood.basis == 1, "untagged node must not enter the basis: \(mixedMood.basis)")
    }

    /// A node re-activated more than 24h ago is excluded from the integral.
    @Test func staleNodeExcludedFromMood() async throws {
        let now = Date(timeIntervalSince1970: 2_000_000)
        let clock = Clock(now)
        let fresh = node(summary: summary, valence: 0.5, arousal: 0.1, warmth: 0.6,
                         createdAt: now, lastActivatedAt: now)
        let stale = node(summary: summary + " long ago", valence: 0.5, arousal: 0.1, warmth: 0.6,
                         createdAt: now.addingTimeInterval(-25 * 60 * 60),
                         lastActivatedAt: now.addingTimeInterval(-25 * 60 * 60))
        let s = try await substrate(with: [fresh, stale], clock: clock, label: "stale")
        let mood = await s.derivedMood(at: clock.now())
        #expect(mood.basis == 1, "the >24h node must be excluded: \(mood.basis)")
    }

    /// Recency weighting: a 1h-old positive node outweighs a 12h-old negative node of
    /// equal magnitude, so the blended mood leans positive (asserts ordering, not exact).
    @Test func recentNodeOutweighsOldNode() async throws {
        let now = Date(timeIntervalSince1970: 3_000_000)
        let clock = Clock(now)
        let recentPositive = node(summary: summary + " recent good", valence: 0.6, arousal: 0.1, warmth: 0.6,
                                  createdAt: now.addingTimeInterval(-1 * 60 * 60),
                                  lastActivatedAt: now.addingTimeInterval(-1 * 60 * 60))
        let oldNegative = node(summary: summary + " old bad", valence: -0.6, arousal: 0.3, warmth: 0.1,
                               createdAt: now.addingTimeInterval(-12 * 60 * 60),
                               lastActivatedAt: now.addingTimeInterval(-12 * 60 * 60))
        let s = try await substrate(with: [recentPositive, oldNegative], clock: clock, label: "recency")
        let mood = await s.derivedMood(at: clock.now())
        #expect(mood.basis == 2)
        #expect(mood.valence > 0, "recent positive should outweigh old negative: \(mood.valence)")
    }

    // MARK: - (2) mood-congruent recall

    /// Two nodes identical except opposite valence (+0.5 / −0.5). Under a positive mood
    /// (seeded by extra warm nodes) the positive one scores higher AND carries the
    /// "mood-congruent" reason.
    @Test func congruentNodeRanksHigherUnderPositiveMood() async throws {
        let now = Date(timeIntervalSince1970: 4_000_000)
        let clock = Clock(now)
        let positive = node(summary: "positive-topic", valence: 0.5, arousal: 0.1, warmth: 0.5, createdAt: now, lastActivatedAt: now)
        let negative = node(summary: "negative-topic", valence: -0.5, arousal: 0.1, warmth: 0.1, createdAt: now, lastActivatedAt: now)
        // Two warm anchors push mean mood positive (the pair alone averages ~0).
        let anchorA = node(summary: "anchor-a", valence: 0.6, arousal: 0.1, warmth: 0.6, createdAt: now, lastActivatedAt: now)
        let anchorB = node(summary: "anchor-b", valence: 0.6, arousal: 0.1, warmth: 0.6, createdAt: now, lastActivatedAt: now)
        let s = try await substrate(with: [positive, negative, anchorA, anchorB], clock: clock, label: "congruent")

        let mood = await s.derivedMood(at: clock.now())
        #expect(mood.valence >= 0.15, "mood should have left the neutral band: \(mood.valence)")

        let ws = await s.workspaceSnapshot(currentSessionId: "s1")
        let pos = try #require(ws.items.first { $0.node.summary == "positive-topic" }, "positive node missing from workspace")
        let neg = try #require(ws.items.first { $0.node.summary == "negative-topic" }, "negative node missing from workspace")
        #expect(pos.score > neg.score, "congruent (positive) node should score higher: \(pos.score) vs \(neg.score)")
        #expect(pos.reasons.contains("mood-congruent"), "positive node missing mood-congruent reason: \(pos.reasons)")
        // ADVERSARIAL: the anti-congruent (negative) node gets NO boost and NO reason —
        // congruence requires the same felt direction, not mere closeness on the scale.
        #expect(await s.moodCongruence(for: neg.node, mood: mood) == 0,
                "anti-congruent node must get zero boost")
        #expect(!neg.reasons.contains("mood-congruent"), "anti-congruent node must not carry the reason: \(neg.reasons)")
    }

    /// Mirror case: under a NEGATIVE mood the stung node outranks the warm one —
    /// mood-congruent recall works in both directions (Bower's actual finding).
    @Test func negativeMoodFavorsNegativeNode() async throws {
        let now = Date(timeIntervalSince1970: 4_500_000)
        let clock = Clock(now)
        let positive = node(summary: "positive-topic", valence: 0.5, arousal: 0.1, warmth: 0.5, createdAt: now, lastActivatedAt: now)
        let negative = node(summary: "negative-topic", valence: -0.5, arousal: 0.1, warmth: 0.1, createdAt: now, lastActivatedAt: now)
        let anchorA = node(summary: "anchor-a", valence: -0.6, arousal: 0.3, warmth: 0.1, createdAt: now, lastActivatedAt: now)
        let anchorB = node(summary: "anchor-b", valence: -0.6, arousal: 0.3, warmth: 0.1, createdAt: now, lastActivatedAt: now)
        let s = try await substrate(with: [positive, negative, anchorA, anchorB], clock: clock, label: "neg-congruent")

        let mood = await s.derivedMood(at: clock.now())
        #expect(mood.valence <= -0.15, "mood should be negative past the band: \(mood.valence)")

        let ws = await s.workspaceSnapshot(currentSessionId: "s1")
        let pos = try #require(ws.items.first { $0.node.summary == "positive-topic" })
        let neg = try #require(ws.items.first { $0.node.summary == "negative-topic" })
        #expect(neg.score > pos.score, "under negative mood the stung node should surface: \(neg.score) vs \(pos.score)")
        #expect(neg.reasons.contains("mood-congruent"))
        #expect(await s.moodCongruence(for: pos.node, mood: mood) == 0)
    }

    /// The congruence contribution is exactly capped: a perfect valence match yields
    /// precisely the 0.08 weight, and no combination exceeds it.
    @Test func congruenceCapIsExact() async throws {
        let now = Date(timeIntervalSince1970: 4_700_000)
        let clock = Clock(now)
        let s = try await substrate(with: [], clock: clock, label: "cap")
        let mood = CognitiveMoodReading(valence: 0.5, basis: 3)
        let perfect = node(summary: "match", valence: 0.5, arousal: 0.1, warmth: 0.5, createdAt: now, lastActivatedAt: now)
        #expect(await s.moodCongruence(for: perfect, mood: mood) == 0.08)
        for v in [0.2, 0.5, 0.9, -0.2, -0.9] {
            let n = node(summary: "v\(v)", valence: v, arousal: 0.1, warmth: 0.4, createdAt: now, lastActivatedAt: now)
            let boost = await s.moodCongruence(for: n, mood: mood)
            #expect(boost >= 0 && boost <= 0.08, "boost out of bounds for valence \(v): \(boost)")
        }
    }

    /// derivedMood is genuinely read-only: a mood read at a far-future date must not
    /// decay activations or evict nodes (field.snapshot is mutating; mood must not
    /// route through it).
    @Test func derivedMoodDoesNotMutateField() async throws {
        let now = Date(timeIntervalSince1970: 4_900_000)
        let clock = Clock(now)
        let n = node(summary: "stable", valence: 0.5, arousal: 0.1, warmth: 0.5, createdAt: now, lastActivatedAt: now)
        let s = try await substrate(with: [n], clock: clock, label: "no-mutate")

        let before = try #require(await s.snapshot().nodes.first { $0.summary == "stable" })
        _ = await s.derivedMood(at: now.addingTimeInterval(30 * 24 * 60 * 60))
        let after = try #require(await s.snapshot().nodes.first { $0.summary == "stable" },
                                 "node must survive a future-dated mood read")
        #expect(after.activation == before.activation,
                "mood read must not decay activation: \(before.activation) -> \(after.activation)")
        #expect(after.salience == before.salience)
    }

    /// Neutral mood + untagged pair → congruence is 0 for both → byte-identical scores,
    /// and neither carries the mood-congruent reason.
    @Test func neutralMoodLeavesScoresIdentical() async throws {
        let now = Date(timeIntervalSince1970: 5_000_000)
        let clock = Clock(now)
        let a = node(summary: "topic-a", valence: 0, arousal: 0, warmth: 0, createdAt: now, lastActivatedAt: now)
        let b = node(summary: "topic-b", valence: 0, arousal: 0, warmth: 0, createdAt: now, lastActivatedAt: now)
        let s = try await substrate(with: [a, b], clock: clock, label: "neutral-scores")

        let mood = await s.derivedMood(at: clock.now())
        #expect(mood.basis == 0)
        #expect(mood.valence == 0)

        let ws = await s.workspaceSnapshot(currentSessionId: "s1")
        let itemA = try #require(ws.items.first { $0.node.summary == "topic-a" })
        let itemB = try #require(ws.items.first { $0.node.summary == "topic-b" })
        #expect(itemA.score == itemB.score, "untagged pair under neutral mood must score identically: \(itemA.score) vs \(itemB.score)")
        #expect(!itemA.reasons.contains("mood-congruent"))
        #expect(!itemB.reasons.contains("mood-congruent"))
    }

    // MARK: - (3) mood reaches her phrasing

    // removed 2026-07-08: Focus/Feeling lines replaced by the felt fingerprint
    // (strongGoodMoodReachesFeelingLine asserted the old mood-phrasing append,
    // "the day has a good feel", onto the "- Feeling: ..." line — that mechanic
    // and its host line are both gone; the fingerprint carries no mood-phrase text).

    // removed 2026-07-08: Focus/Feeling lines replaced by the felt fingerprint
    // (lowMoodReachesVoiceLine asserted the old mood-phrasing append, "extra
    // gentle today", onto a "- Voice: ..." line — there is no Voice line anymore).

    // MARK: - (4) byte-identical guard for the neutral/legacy path

    /// Untagged nodes + zero affect → none of the four mood phrases appear anywhere in
    /// the capsule. (Neutral/legacy stays silent — the pre-Wave-C output.)
    @Test func neutralMoodAddsNoPhrasing() async throws {
        let now = Date(timeIntervalSince1970: 8_000_000)
        let clock = Clock(now)
        let s = try await substrate(
            with: [
                node(summary: summary, valence: 0, arousal: 0, warmth: 0, createdAt: now, lastActivatedAt: now),
                node(summary: summary + " two", valence: 0, arousal: 0, warmth: 0, createdAt: now, lastActivatedAt: now),
            ],
            clock: clock, label: "neutral-phrasing")
        let capsule = await s.compileCapsule(request("continue the feature"))
        for phrase in ["the day has a good feel", "the day's been heavy", "extra gentle today", "let the good mood show"] {
            #expect(!capsule.dynamicContext.contains(phrase),
                    "neutral mood must not emit \"\(phrase)\": \(capsule.dynamicContext)")
        }
    }
}
