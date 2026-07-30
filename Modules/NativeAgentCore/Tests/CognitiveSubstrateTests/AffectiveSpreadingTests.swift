import Foundation
import Testing
@testable import CognitiveSubstrate

// Wave F: a FELT memory re-firing nudges emotionally congruent felt neighbors
// a little harder — activation only, facilitation-only, capped at
// affectiveSpreadMaxWhisper. Neutral/legacy (0,0,0) nodes must spread
// byte-identically to pre-Wave-F behavior.
@Suite("AffectiveSpreading")
struct AffectiveSpreadingTests {

    private let cfg = CognitiveConfiguration(
        enabled: true, affectEnabled: true, maximumActiveNodes: 256, defaultDecayHalfLife: 100
    )
    private let now = Date(timeIntervalSince1970: 9_000_000)

    private func event(_ id: String, subject: String, summary: String) -> CognitiveEvent {
        CognitiveEvent(
            id: id, kind: .userMessageReceived,
            subject: CognitiveSubjectReference(type: "topic", id: subject, label: subject),
            sourceClass: .userStated, occurredAt: now, summary: summary,
            importance: 0.5,
            metadata: ["sessionId": .string("s1")]
        )
    }

    /// Standard rig: two structurally IDENTICAL targets (same subject type,
    /// same shared sessionId, token-disjoint summaries) + a source node.
    /// Stamp the given tags, re-fire the source, return each target's
    /// activation delta across the re-fire.
    private func refireDeltas(
        sourceTag: (Double, Double, Double)?,
        warmTag: (Double, Double, Double)?,
        coldTag: (Double, Double, Double)?,
        configuration: CognitiveConfiguration? = nil
    ) throws -> (warm: Double, cold: Double) {
        let cfg = configuration ?? self.cfg
        var field = ContinuityField()
        let warmIngest = field.ingest(
            event("e-warm", subject: "warmTarget", summary: "sunlit afternoon orchard"),
            now: now, makeUUID: { UUID() }, configuration: cfg)
        let coldIngest = field.ingest(
            event("e-cold", subject: "coldTarget", summary: "ledger arithmetic drudgery"),
            now: now, makeUUID: { UUID() }, configuration: cfg)
        let srcIngest = field.ingest(
            event("e-src", subject: "src", summary: "campfire evening embers"),
            now: now, makeUUID: { UUID() }, configuration: cfg)
        let warmOut = try #require(warmIngest)
        let coldOut = try #require(coldIngest)
        let srcOut = try #require(srcIngest)
        if let warmTag {
            field.stampEmotionTag(key: warmOut.key, tag: (valence: warmTag.0, arousal: warmTag.1, warmth: warmTag.2), isNewNode: true, configuration: cfg)
        }
        if let coldTag {
            field.stampEmotionTag(key: coldOut.key, tag: (valence: coldTag.0, arousal: coldTag.1, warmth: coldTag.2), isNewNode: true, configuration: cfg)
        }
        if let sourceTag {
            field.stampEmotionTag(key: srcOut.key, tag: (valence: sourceTag.0, arousal: sourceTag.1, warmth: sourceTag.2), isNewNode: true, configuration: cfg)
        }

        let before = field.snapshot(at: now, configuration: cfg)
        let warmBefore = try #require(before.first { $0.subjectReference.id == "warmTarget" }).activation
        let coldBefore = try #require(before.first { $0.subjectReference.id == "coldTarget" }).activation

        _ = field.ingest(
            event("e-src-refire", subject: "src", summary: "driftwood sparks glow"),
            now: now, makeUUID: { UUID() }, configuration: cfg)

        let after = field.snapshot(at: now, configuration: cfg)
        let warmAfter = try #require(after.first { $0.subjectReference.id == "warmTarget" }).activation
        let coldAfter = try #require(after.first { $0.subjectReference.id == "coldTarget" }).activation
        return (warm: warmAfter - warmBefore, cold: coldAfter - coldBefore)
    }

    @Test("a felt re-fire nudges the congruent neighbor harder, at exactly the whisper cap")
    func congruentNeighborGetsBiggerNudge() throws {
        // Source and warm target share the same feeling (congruence 1);
        // cold target is maximally opposite (congruence 0).
        let deltas = try refireDeltas(
            sourceTag: (1.0, 0.4, 1.0),
            warmTag: (1.0, 0.3, 1.0),
            coldTag: (-1.0, 0.3, 0.0)
        )
        #expect(deltas.cold > 0, "incongruent neighbor still gets the baseline structural nudge")
        #expect(deltas.warm > deltas.cold)
        let expected = deltas.cold * (1 + ContinuityField.affectiveSpreadMaxWhisper)
        #expect(abs(deltas.warm - expected) < 1e-9,
                "congruence-1 boost must be exactly baseline × (1 + cap): \(deltas.warm) vs \(expected)")
    }

    @Test("facilitation-only: a maximally incongruent neighbor equals the all-neutral baseline")
    func incongruentEqualsNeutralBaseline() throws {
        let felt = try refireDeltas(
            sourceTag: (1.0, 0.4, 1.0),
            warmTag: nil,
            coldTag: (-1.0, 0.3, 0.0)
        )
        let neutral = try refireDeltas(sourceTag: nil, warmTag: nil, coldTag: nil)
        #expect(abs(felt.cold - neutral.cold) < 1e-12,
                "opposite feeling must never be dampened below the structural baseline")
    }

    @Test("neutral/legacy targets spread byte-identically whether or not the source is felt")
    func neutralTargetsUntouched() throws {
        let feltSource = try refireDeltas(sourceTag: (1.0, 0.4, 1.0), warmTag: nil, coldTag: nil)
        let neutral = try refireDeltas(sourceTag: nil, warmTag: nil, coldTag: nil)
        #expect(abs(feltSource.warm - neutral.warm) < 1e-12)
        #expect(abs(feltSource.cold - neutral.cold) < 1e-12)
        #expect(abs(feltSource.warm - feltSource.cold) < 1e-12,
                "structurally identical unfelt targets must get identical nudges")
    }

    @Test("affect disabled: stale felt tags must not steer spread (whisper off)")
    func affectDisabledKillsWhisper() throws {
        let affectOff = CognitiveConfiguration(
            enabled: true, affectEnabled: false, maximumActiveNodes: 256, defaultDecayHalfLife: 100
        )
        let felt = try refireDeltas(
            sourceTag: (1.0, 0.4, 1.0),
            warmTag: (1.0, 0.3, 1.0),
            coldTag: (-1.0, 0.3, 0.0),
            configuration: affectOff
        )
        #expect(abs(felt.warm - felt.cold) < 1e-12,
                "with affect off, tagged targets must get identical structural nudges")
    }

    @Test("congruence: 0 unless both felt; 1 for identical felt tags; 0 at maximal opposition")
    func congruenceFunction() {
        func node(_ v: Double, _ a: Double, _ w: Double) -> CognitiveNode {
            var n = CognitiveNode(
                id: UUID(), kind: .conversationFocus,
                subjectReference: CognitiveSubjectReference(type: "topic", id: "x", label: "x"),
                activation: 0.5, salience: 0.5, confidence: 0.5, sourceClass: .observed,
                createdAt: now, lastActivatedAt: now, decayHalfLife: 100,
                summary: "s", metadata: [:]
            )
            n.emotionalValence = v
            n.emotionalArousal = a
            n.emotionalWarmth = w
            return n
        }
        #expect(ContinuityField.affectiveCongruence(node(0, 0, 0), node(1, 0.5, 1)) == 0, "unfelt source → 0")
        #expect(ContinuityField.affectiveCongruence(node(1, 0.5, 1), node(0, 0, 0)) == 0, "unfelt target → 0")
        #expect(ContinuityField.affectiveCongruence(node(0.7, 0.4, 0.6), node(0.7, 0.9, 0.6)) == 1,
                "identical valence+warmth → 1 (arousal is intensity, not quality)")
        #expect(ContinuityField.affectiveCongruence(node(1, 0.5, 1), node(-1, 0.5, 0)) == 0,
                "maximal opposition → 0")
    }
}
