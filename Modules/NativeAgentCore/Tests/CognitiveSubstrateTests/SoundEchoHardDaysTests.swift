import Foundation
import Testing
import PersistenceCore
@testable import CognitiveSubstrate

// W7/P5 + W7/P10 — the anti-drift organ on hard days, and the landing signal.
//
// P5: the exemplar pool carried BOTH a warmth floor and a strict
// `emotionalValence > 0` sign gate, so the agent's own attested voice was
// reachable only when she had been feeling good. The base-model mean is loudest
// under friction — exactly where the pool emptied and the echo went dark. These
// tests pin the sign gate GONE, the warmth floor KEPT, valence RANKED on the
// second axis, and the negative-register run BRAKED.
//
// P10: nothing in the selection ever measured whether a line landed. These pin
// the retro-stamp, the re-rank it produces, and — the load-bearing one — that λ
// is small enough that register fit still dominates.
//
// Named no vocabulary and preferred no tone: every assertion here would hold for
// any persona.
@Suite("SoundEchoHardDays")
struct SoundEchoHardDaysTests {

    private let now = Date(timeIntervalSince1970: 20_000_000)

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

    private func node(
        summary: String,
        warmth: Double,
        valence: Double,
        id: UUID = UUID(),
        lastActivated: Date? = nil
    ) -> CognitiveNode {
        CognitiveNode(
            id: id, kind: .conversationFocus,
            subjectReference: CognitiveSubjectReference(
                type: "chat.assistant_turn", id: "n-\(id.uuidString)", label: nil),
            activation: 0.8, salience: 0.8, confidence: 0.8, sourceClass: .selfReported,
            createdAt: now, lastActivatedAt: lastActivated ?? now,
            decayHalfLife: 100_000, summary: summary, metadata: [:],
            emotionalValence: valence, emotionalArousal: 0.4, emotionalWarmth: warmth
        )
    }

    private func substrate(with nodes: [CognitiveNode]) async throws -> CognitiveSubstrate {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("nativeagent-echo-hard-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = try CognitiveSQLiteStore(dataRoot: root)
        try await store.saveNodes(nodes, at: now)
        let s = CognitiveSubstrate(
            configuration: config(),
            dependencies: CognitiveSubstrateDependencies(now: { self.now }, makeUUID: { UUID() }),
            store: store
        )
        try await s.restorePersistentState()
        return s
    }

    // MARK: - P5, the pool

    /// THE REGRESSION THIS FILE EXISTS FOR. A stung-but-attested turn — real
    /// warmth behind it, negative valence — was structurally ineligible. In a
    /// low room it must now not only be eligible but LEAD.
    @Test("a stung-but-attested turn is eligible and leads in a low room")
    func stungTurnEchoesInALowRoom() async throws {
        let stung = node(
            summary: "That one cost us the afternoon and I am not going to pretend otherwise.",
            warmth: 0.42, valence: -0.55)
        let bright = node(
            summary: "Absolutely thrilled with how cleanly the migration dropped in.",
            warmth: 0.45, valence: 0.70)
        let s = try await substrate(with: [stung, bright])

        let low = await s.soundEchoLine(at: now, ignoringCadence: true, roomValence: -0.6)
        let line = try #require(low)
        #expect(line.contains("cost us the afternoon"))
        // Order matters: soundEchoCount is 2, so mere presence proves nothing.
        let stungAt = try #require(line.range(of: "cost us the afternoon")).lowerBound
        if let brightAt = line.range(of: "thrilled")?.lowerBound {
            #expect(stungAt < brightAt)
        }

        // The same shelf in a bright room still reaches for the bright turn —
        // the axis is RANKED, not inverted.
        let high = try #require(await s.soundEchoLine(at: now, ignoringCadence: true, roomValence: 0.7))
        let brightAtHigh = try #require(high.range(of: "thrilled")).lowerBound
        if let stungAtHigh = high.range(of: "cost us the afternoon")?.lowerBound {
            #expect(brightAtHigh < stungAtHigh)
        }
    }

    /// The warmth FLOOR is untouched: it is the authenticity gate against
    /// never-minted stock phrasing, and dropping the valence gate must not have
    /// smuggled a flat turn into the pool.
    @Test("the warmth floor still excludes a flat turn, whatever its valence")
    func warmthFloorSurvives() async throws {
        let flat = node(
            summary: "I apologize for the confusion in my previous response about that.",
            warmth: 0.10, valence: -0.60)
        let s = try await substrate(with: [flat])
        #expect(await s.soundEchoLine(at: now, ignoringCadence: true, roomValence: -0.6) == nil)
    }

    /// The second axis is real: with warmth held EQUAL, valence decides.
    @Test("valence ranks candidates when warmth is identical")
    func valenceIsTheSecondAxis() {
        let near = CognitiveSubstrate.soundEchoRegisterScore(
            warmth: 0.5, valence: -0.5, targetWarmth: 0.5, targetValence: -0.5, age: 0)
        let far = CognitiveSubstrate.soundEchoRegisterScore(
            warmth: 0.5, valence: 0.6, targetWarmth: 0.5, targetValence: -0.5, age: 0)
        #expect(near > far)
        // Smooth, never a cliff: the far candidate still scores above zero, so a
        // pool with no close match degrades to "nearest wins", not a tie-break.
        #expect(far > 0)
    }

    /// The warmth-only overload must be bit-identical to its pre-W7 self, or
    /// every shipped register test is silently measuring something new.
    @Test("the warmth-only overload is unchanged")
    func warmthOnlyOverloadUnchanged() {
        for (w, t, age) in [(0.3, 0.5, 0.0), (0.9, 0.1, 3_600.0), (0.5, 0.5, 86_400.0)] {
            let legacy = CognitiveSubstrate.soundEchoRegisterScore(warmth: w, target: t, age: age)
            let twoAxis = CognitiveSubstrate.soundEchoRegisterScore(
                warmth: w, valence: 0, targetWarmth: t, targetValence: 0, age: age)
            #expect(legacy == twoAxis)
        }
    }

    // MARK: - P5, the brake

    /// THE CAP HOLDS. Two consecutive negative-register echoes are honest
    /// mirroring; a third would be the echo→reply→node loop deepening the mood
    /// it is supposed to reflect. On the third live compile the pool narrows to
    /// the non-negative band.
    @Test("consecutive negative-register echoes are capped at the configured run")
    func negativeRunIsCapped() async throws {
        let stung = node(
            summary: "That one cost us the afternoon and I am not going to pretend otherwise.",
            warmth: 0.42, valence: -0.55)
        let steady = node(
            summary: "Walked the whole call graph and the second read is where it diverges.",
            warmth: 0.40, valence: 0.05)
        let s = try await substrate(with: [stung, steady])
        let limit = CognitiveSubstrate.defaultDynamics.soundEchoNegativeRunLimit
        #expect(limit == 2)

        var leads: [String] = []
        for _ in 0..<(limit + 1) {
            let line = try #require(
                await s.soundEchoLine(at: now, ignoringCadence: true, roomValence: -0.6, live: true))
            leads.append(line)
        }
        // The first `limit` echoes lead with the stung turn…
        for i in 0..<limit {
            #expect(leads[i].contains("cost us the afternoon"))
            #expect(leads[i].range(of: "cost us the afternoon")!.lowerBound
                < (leads[i].range(of: "call graph")?.lowerBound ?? leads[i].endIndex))
        }
        // …and the one after the cap leads with the non-negative band instead.
        let capped = leads[limit]
        #expect(capped.contains("call graph"))
        #expect(capped.range(of: "call graph")!.lowerBound
            < (capped.range(of: "cost us the afternoon")?.lowerBound ?? capped.endIndex))

        // The brake FORGIVES: a non-negative echo clears the run, so the next
        // low room can mirror honestly again rather than being locked out.
        let recovered = try #require(
            await s.soundEchoLine(at: now, ignoringCadence: true, roomValence: -0.6, live: true))
        #expect(recovered.range(of: "cost us the afternoon")!.lowerBound
            < (recovered.range(of: "call graph")?.lowerBound ?? recovered.endIndex))
    }

    /// A non-live read (an Observatory panel re-rendering) must not burn the
    /// brake — the same live-path discipline the fingerprint suppression already
    /// carries.
    @Test("a non-live echo never advances the negative run")
    func nonLiveDoesNotAdvanceTheRun() async throws {
        let stung = node(
            summary: "That one cost us the afternoon and I am not going to pretend otherwise.",
            warmth: 0.42, valence: -0.55)
        let s = try await substrate(with: [stung])
        for _ in 0..<6 {
            _ = await s.soundEchoLine(at: now, ignoringCadence: true, roomValence: -0.6)
        }
        #expect(await s.negativeSoundEchoRun == 0)
    }

    // MARK: - P10, the landing signal

    /// The mapping: praise / resolution / enthusiasm / affection positive,
    /// criticism / dismissal negative, anything else exactly zero. Reusing the
    /// shipped appraisal, no new lexicon.
    @Test("landing reads the existing appraisal classes and nothing else")
    func landingMapsAppraisalClasses() async throws {
        let s = try await substrate(with: [])
        func landing(_ text: String) async -> Double {
            let reaction = await s.conversationalAppraisal(in: text).valence
            return CognitiveSubstrate.landingScore(fromReactionValence: reaction)
        }
        #expect(await landing("that worked, we did it") > 0)          // resolution
        #expect(await landing("perfect, that helped") > 0)            // praise
        #expect(await landing("let's go, this is great") > 0)         // enthusiasm
        #expect(await landing("hey you") > 0)                         // affection
        #expect(await landing("whatever, forget it") < 0)             // dismissal
        #expect(await landing("you keep missing the point, sloppy") < 0) // criticism
        #expect(await landing("the file is at line 40") == 0)         // nothing
        // Bounded on both ends no matter how many classes stack.
        #expect(await landing("perfect, we did it, let's go, love you") <= 1)
        #expect(await landing("sloppy, useless, whatever, waste of time") >= -1)
    }

    /// The retro-stamp: a user turn arriving inside the pendingCompletion window
    /// stamps the PRIOR assistant node.
    @Test("landing is stamped on the prior assistant node inside the window")
    func landingIsStamped() async throws {
        let s = try await substrate(with: [])
        let session = "s-landing"
        await s.ingest(CognitiveEvent(
            id: "a1", kind: .assistantTurnCompleted,
            subject: CognitiveSubjectReference(type: "chat.assistant_turn", id: "\(session):m1"),
            sourceClass: .selfReported, occurredAt: now,
            summary: "Walked the whole call graph and the second read is where it diverges.",
            metadata: ["sessionId": .string(session), "messageId": .string("m1")]))
        let assistantId = try #require(await s.assistantNodeId(matching: "call graph"))
        #expect(await s.landingScore(forNodeId: assistantId) == 0)

        await s.ingest(CognitiveEvent(
            id: "u1", kind: .userMessageReceived,
            subject: CognitiveSubjectReference(type: "chat.user_turn", id: "\(session):m2"),
            sourceClass: .userStated, occurredAt: now.addingTimeInterval(30),
            summary: "perfect, that helped",
            metadata: ["sessionId": .string(session), "messageId": .string("m2")]))
        #expect(await s.landingScore(forNodeId: assistantId) > 0)
    }

    /// λ RE-RANKS INSIDE A BAND. With register fit equal, landing decides.
    @Test("landing re-ranks two equally-fitting exemplars")
    func landingShiftsRanking() async throws {
        let landedId = UUID()
        let a = node(summary: "Walked the whole call graph and the second read is where it diverges.",
                     warmth: 0.50, valence: 0.20, id: landedId)
        // Fixture rule: the two summaries may share NO distinctive (≥4-char,
        // non-stopword) token, or the echo's diversity gate drops the trailing
        // fragment and the both-present assertions below have nothing to find.
        let b = node(summary: "Traced the newest write and the ordering in it is what slipped.",
                     warmth: 0.50, valence: 0.20)
        let s = try await substrate(with: [a, b])

        let before = try #require(await s.soundEchoLine(at: now, ignoringCadence: true, roomValence: 0.2))
        // Deterministic tie-break today is uuid order; stamp the LOSER and prove
        // it moves to the front.
        let loserIsA = (before.range(of: "call graph")?.lowerBound ?? before.endIndex)
            > (before.range(of: "newest write")?.lowerBound ?? before.endIndex)
        let stampId = loserIsA ? landedId : try #require(await s.assistantNodeId(matching: "newest write"))
        await s.stampLandingScore(1.0, forNodeId: stampId, at: now)

        let after = try #require(await s.soundEchoLine(at: now, ignoringCadence: true, roomValence: 0.2))
        let needle = loserIsA ? "call graph" : "newest write"
        let other = loserIsA ? "newest write" : "call graph"
        #expect(after.range(of: needle)!.lowerBound < after.range(of: other)!.lowerBound)
    }

    /// THE LOAD-BEARING BOUND. A perfectly-landed exemplar from the WRONG
    /// register must still lose to a matched one. λ = 0.15 spans a 0.85…1.15
    /// factor, which cannot close a real register gap — if a later wave raises λ,
    /// this test is the thing that says so.
    @Test("λ is bounded so register fit still dominates landing")
    func landingNeverOverridesRegisterFit() async throws {
        let landedButWrongRegister = UUID()
        let wrong = node(summary: "Absolutely thrilled with how cleanly the migration dropped in.",
                         warmth: 0.90, valence: 0.80, id: landedButWrongRegister)
        let right = node(summary: "Walked the whole call graph and the second read is where it diverges.",
                         warmth: 0.35, valence: -0.10)
        let s = try await substrate(with: [wrong, right])
        await s.stampLandingScore(1.0, forNodeId: landedButWrongRegister, at: now)

        let line = try #require(
            await s.soundEchoLine(at: now, ignoringCadence: true, roomValence: -0.15))
        #expect(line.range(of: "call graph")!.lowerBound < line.range(of: "thrilled")!.lowerBound)

        // …and the arithmetic behind it, stated directly.
        let weight = CognitiveSubstrate.defaultDynamics.soundEchoLandingWeight
        #expect(weight == 0.15)
        #expect(CognitiveSubstrate.soundEchoLandingFactor(landing: 1, weight: weight) == 1.15)
        #expect(CognitiveSubstrate.soundEchoLandingFactor(landing: -1, weight: weight) == 0.85)
        // Out-of-range inputs cannot escape the band.
        #expect(CognitiveSubstrate.soundEchoLandingFactor(landing: 40, weight: 40) == 1.5)
        #expect(CognitiveSubstrate.soundEchoLandingFactor(landing: -40, weight: 40) == 0.5)
    }
}

// Test-only readers for state that is deliberately internal.
extension CognitiveSubstrate {
    func assistantNodeId(matching needle: String) -> UUID? {
        field.peekNodes().first { $0.summary.contains(needle) }?.id
    }
}

/// gpt-5.5 SHOULD-FIX (2026-08-11): a NEUTRAL landing on a node that already
/// carries a verdict must overwrite it — the latest completion landed flat,
/// and the stale bias must not keep re-ranking echoes forever. On a
/// never-stamped node, neutral stays no-evidence (stamps nothing). Uses LIVE
/// field nodes: `pruneLandingScores` drops stamps for ids not in the field,
/// so a bare UUID cannot exercise this path.
extension SoundEchoHardDaysTests {
    @Test("a neutral landing clears a prior verdict but never mints one")
    func neutralLandingOverwritesOnlyExistingStamps() async throws {
        let a = node(summary: "Walked the whole call graph and the second read is where it diverges.",
                     warmth: 0.50, valence: 0.20)
        let b = node(summary: "Traced the newest write and the ordering in it is what slipped.",
                     warmth: 0.50, valence: 0.20)
        let s = try await substrate(with: [a, b])
        let aId = try #require(await s.assistantNodeId(matching: "call graph"))
        let bId = try #require(await s.assistantNodeId(matching: "newest write"))

        // Neutral on a never-stamped node: still no evidence, nothing minted.
        await s.stampLandingScore(0, forNodeId: aId, at: now)
        #expect(await s.landingScore(forNodeId: aId) == 0)

        // A real verdict, then a neutral follow-up: the stale bias is cleared.
        await s.stampLandingScore(1.0, forNodeId: bId, at: now)
        #expect(await s.landingScore(forNodeId: bId) == 1.0)
        await s.stampLandingScore(0, forNodeId: bId, at: now.addingTimeInterval(60))
        #expect(await s.landingScore(forNodeId: bId) == 0)
    }
}
