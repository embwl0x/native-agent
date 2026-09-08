import Foundation
import Testing
import PersistenceCore
@testable import CognitiveSubstrate

@Test func relatedEventsCreateAssociationEdgesAndSpreadActivation() async throws {
    let clock = TestClock(Date(timeIntervalSince1970: 1_000))
    let substrate = makeSubstrate(
        clock: clock,
        configuration: CognitiveConfiguration(
            enabled: true,
            workspaceEnabled: true,
            maximumWorkspaceItems: 4
        )
    )

    await substrate.ingest(CognitiveEvent(
        id: "migration-topic",
        kind: .userMessageReceived,
        subject: CognitiveSubjectReference(type: "topic", id: "migration", label: "Migration"),
        sourceClass: .userStated,
        occurredAt: clock.now(),
        summary: "Swift migration report needs verification",
        importance: 0.5,
        metadata: ["sessionId": .string("session-1")]
    ))
    let before = try #require(await substrate.snapshot().nodes.first { $0.subjectReference.id == "migration" })

    await substrate.ingest(CognitiveEvent(
        id: "migration-tool",
        kind: .toolSucceeded,
        subject: CognitiveSubjectReference(type: "tool", id: "git_log", label: "git_log"),
        sourceClass: .observed,
        occurredAt: clock.now(),
        summary: "migration report verified through git log",
        importance: 0.5,
        metadata: ["sessionId": .string("session-1"), "toolName": .string("git_log")]
    ))

    let after = try #require(await substrate.snapshot().nodes.first { $0.subjectReference.id == "migration" })
    let edges = await substrate.associationSnapshot()
    let workspace = await substrate.workspaceSnapshot()

    #expect(after.activation > before.activation)
    #expect(edges.count == 1)
    #expect(edges.first?.weight ?? 0 > 0)
    #expect(workspace.items.contains { $0.reasons.contains("spreading-activation") })
}

@Test func spreadingActivationPerformanceStaysBounded() async throws {
    let clock = TestClock(Date(timeIntervalSince1970: 1_000))
    // Cap sits BELOW the 300 ingested events so eviction is actually exercised.
    // Scope note: read paths (snapshot/associationEdges) also run enforceCapacity,
    // so these asserts pin the cap at every observable point — deleting ONLY the
    // ingest-time call would be masked by that read-side self-healing (by design;
    // nodesByKey is private, so there is no non-enforcing accessor to pin it).
    let substrate = makeSubstrate(
        clock: clock,
        configuration: CognitiveConfiguration(
            enabled: true,
            workspaceEnabled: true,
            maximumActiveNodes: 128,
            maximumWorkspaceItems: 12
        )
    )

    let wall = ContinuousClock()
    let start = wall.now
    for index in 0..<300 {
        await substrate.ingest(CognitiveEvent(
            id: "perf-\(index)",
            kind: index.isMultiple(of: 5) ? .toolSucceeded : .userMessageReceived,
            subject: CognitiveSubjectReference(type: "topic", id: "topic-\(index)", label: "Topic \(index)"),
            sourceClass: .observed,
            occurredAt: clock.now(),
            summary: "bounded migration performance cluster \(index % 12)",
            importance: Double(index % 10) / 10,
            metadata: ["sessionId": .string("perf-\(index % 8)")]
        ))
    }
    let workspace = await substrate.workspaceSnapshot()
    let edges = await substrate.associationSnapshot()
    let elapsed = start.duration(to: wall.now)

    // "Bounded" is a structural property, not a wall-clock one: per-ingest cost stays flat
    // because enforceCapacity caps the live field and the workspace caps its items. Pin those
    // bounds directly — they hold regardless of scheduler contention.
    let nodes = await substrate.snapshot().nodes
    #expect(nodes.count <= 128)
    #expect(workspace.items.count <= 12)
    // ~170 nodes were evicted above; emitted edges must never reference an evicted node.
    let liveIds = Set(nodes.map(\.id))
    #expect(edges.allSatisfy { liveIds.contains($0.fromNodeId) && liveIds.contains($0.toNodeId) })

    // Wall clock survives only as a gross-regression tripwire (e.g. an accidental O(n²) ingest).
    // Baseline ~1.2s uncontended; 3.067s observed under full-suite parallel load (2026-07-02),
    // which flaked the old 3.0s bound. ~13x-baseline headroom absorbs scheduler contention;
    // wall-clock asserts must never run tight (see nativeagent-hangproof-subprocess-tests).
    print("[substrate-ingest] elapsed=\(elapsed) events=300")
    // The structural caps above (nodes<=128, workspace<=12, live-edge refs) are
    // the always-on correctness guarantees. The gross-regression wall-clock
    // tripwire is gated behind NATIVE_AGENT_PERF_ASSERTS so CI scheduler
    // contention can't flake it, measurable on demand. See
    // nativeagent-hangproof-subprocess-tests.
    if ProcessInfo.processInfo.environment["NATIVE_AGENT_PERF_ASSERTS"] == "1" {
        #expect(elapsed < .seconds(15), "300-event ingest took \(elapsed) — expected ~1.2s; investigate an algorithmic regression, not the bound")
    }
}

@Test func affectStateIsBoundedAndDeterministic() async throws {
    let clock = TestClock(Date(timeIntervalSince1970: 1_000))
    let substrate = makeSubstrate(
        clock: clock,
        configuration: CognitiveConfiguration(enabled: true, affectEnabled: true)
    )

    await substrate.ingest(CognitiveEvent(
        id: "provider-failure",
        kind: .providerFailure,
        subject: CognitiveSubjectReference(type: "provider", id: "openai"),
        sourceClass: .observed,
        occurredAt: clock.now(),
        summary: "provider failed",
        importance: 1
    ))
    let affect = await substrate.affectSnapshot()

    #expect(affect.arousal > 0)
    #expect(affect.uncertainty > 0)
    #expect(affect.arousal <= 1)
    #expect(affect.uncertainty <= 1)
    #expect(affect.updatedAt == clock.now())
}

@Test func debugAndVerificationTurnsDoNotMutateLivedAffectOrMood() async throws {
    let clock = TestClock(Date(timeIntervalSince1970: 1_000))
    let substrate = makeSubstrate(
        clock: clock,
        configuration: CognitiveConfiguration(
            enabled: true,
            workspaceEnabled: true,
            affectEnabled: true
        )
    )

    await substrate.ingest(CognitiveEvent(
        id: "live-warmth",
        kind: .userMessageReceived,
        subject: CognitiveSubjectReference(type: "chat_turn", id: "live"),
        sourceClass: .userStated,
        occurredAt: clock.now(),
        summary: "Thank you, that worked perfectly.",
        importance: 0.8,
        turnKind: .live
    ))
    let beforeAffect = await substrate.affectSnapshot()
    let beforeMood = await substrate.derivedMood(at: clock.now())

    await substrate.ingest(CognitiveEvent(
        id: "debug-hostile-prose",
        kind: .userMessageReceived,
        subject: CognitiveSubjectReference(type: "chat_turn", id: "debug"),
        sourceClass: .userStated,
        occurredAt: clock.now(),
        summary: "[from: codex, via bridge] Whatever, this is useless and you failed.",
        importance: 1,
        turnKind: .debug
    ))
    await substrate.ingest(CognitiveEvent(
        id: "verification-warm-prose",
        kind: .userCorrection,
        subject: CognitiveSubjectReference(type: "chat_turn", id: "verification"),
        sourceClass: .userStated,
        occurredAt: clock.now(),
        summary: "Verification ping: love you, proud of you, we did it.",
        importance: 1,
        turnKind: .verification
    ))

    #expect(await substrate.affectSnapshot() == beforeAffect)
    #expect(await substrate.derivedMood(at: clock.now()) == beforeMood)
    let nonLive = await substrate.snapshot().nodes.filter {
        $0.turnKind == .debug || $0.turnKind == .verification
    }
    #expect(nonLive.count == 2)
    #expect(nonLive.allSatisfy {
        $0.emotionalValence == 0
            && $0.emotionalArousal == 0
            && $0.emotionalWarmth == 0
    })
}

@Test func affectSignalsReadExpectedEventClasses() async throws {
    let clock = TestClock(Date(timeIntervalSince1970: 1_000))
    let substrate = makeSubstrate(
        clock: clock,
        configuration: CognitiveConfiguration(enabled: true, affectEnabled: true)
    )

    await substrate.ingest(CognitiveEvent(
        id: "user-message",
        kind: .userMessageReceived,
        subject: CognitiveSubjectReference(type: "chat_turn", id: "session:user"),
        sourceClass: .userStated,
        occurredAt: clock.now(),
        summary: "User is here with Agent and wants her warm, direct, and present.",
        importance: 1,
        metadata: ["sessionId": .string("session")]
    ))
    let afterUser = await substrate.affectSnapshot()
    #expect(afterUser.arousal > 0)
    #expect(afterUser.socialWarmth > 0)
    #expect(afterUser.taskPressure > 0)
    #expect(afterUser.uncertainty == 0)

    await substrate.ingest(CognitiveEvent(
        id: "provider-failure",
        kind: .providerFailure,
        subject: CognitiveSubjectReference(type: "provider", id: "anthropic"),
        sourceClass: .observed,
        occurredAt: clock.now(),
        summary: "provider failed while drafting",
        importance: 1
    ))
    let afterFailure = await substrate.affectSnapshot()
    #expect(afterFailure.arousal > afterUser.arousal)
    #expect(afterFailure.uncertainty > afterUser.uncertainty)
    #expect(afterFailure.taskPressure > afterUser.taskPressure)

    await substrate.ingest(CognitiveEvent(
        id: "tool-succeeded",
        kind: .toolSucceeded,
        subject: CognitiveSubjectReference(type: "tool", id: "memory_hygiene"),
        sourceClass: .observed,
        occurredAt: clock.now(),
        summary: "memory hygiene completed",
        importance: 1
    ))
    let afterSuccess = await substrate.affectSnapshot()
    #expect(afterSuccess.uncertainty < afterFailure.uncertainty)
    #expect(afterSuccess.taskPressure < afterFailure.taskPressure)
}

@Test func affectMaintenanceDecaysWithoutNewEvent() async throws {
    let clock = TestClock(Date(timeIntervalSince1970: 1_000))
    let substrate = makeSubstrate(
        clock: clock,
        configuration: CognitiveConfiguration(enabled: true, affectEnabled: true)
    )

    await substrate.ingest(CognitiveEvent(
        id: "provider-failure",
        kind: .providerFailure,
        subject: CognitiveSubjectReference(type: "provider", id: "anthropic"),
        sourceClass: .observed,
        occurredAt: clock.now(),
        summary: "provider failed",
        importance: 1
    ))
    let before = await substrate.affectSnapshot()
    clock.advance(60 * 60)
    let after = await substrate.decayAffect()

    #expect(after.arousal < before.arousal)
    #expect(after.uncertainty < before.uncertainty)
    #expect(after.updatedAt == clock.now())
}

@Test func affectStaysExpressiveUnderSustainedConversationAndDecaysHonestly() async throws {
    // Regression: arousal/socialWarmth used to add-then-clamp to a hard 1.0 ceiling under
    // active chat (turns arrive far faster than the old shared 1h decay), so live affect
    // pegged at arousal≈1.0 / warmth=1.0 and lost all dynamic range. Saturating approach
    // plus per-axis decay must keep each axis expressive: high under warmth but below the
    // ceiling with headroom, and falling honestly over quiet time (arousal fast, warmth slow).
    let clock = TestClock(Date(timeIntervalSince1970: 1_000))
    let substrate = makeSubstrate(
        clock: clock,
        configuration: CognitiveConfiguration(enabled: true, affectEnabled: true)
    )

    func warmTurn(_ id: String) async {
        await substrate.ingest(CognitiveEvent(
            id: id,
            kind: .userMessageReceived,
            subject: CognitiveSubjectReference(type: "chat_turn", id: "session:user"),
            sourceClass: .userStated,
            occurredAt: clock.now(),
            summary: "User is warm and present with Agent",
            importance: 1,
            metadata: ["sessionId": .string("session")]
        ))
    }

    // 40 warm turns at a realistic ~90s cadence — the conditions that used to peg affect.
    for i in 0..<40 {
        clock.advance(90)
        await warmTurn("msg-\(i)")
    }
    let active = await substrate.affectSnapshot()

    // This conversation is genuinely warm (warm content every turn), so affect-warmth rides
    // high and toward the ceiling in real warm moments — but it never hard-pegs at exactly 1.0
    // (saturating), and arousal stays in an expressive mid band rather than pinning.
    #expect(active.socialWarmth > 0.8)
    #expect(active.socialWarmth < 1.0)
    #expect(active.arousal > 0.2)
    #expect(active.arousal < 0.95)

    // Honest per-axis decay: after long quiet, arousal collapses well below the slower warmth.
    clock.advance(3 * 60 * 60)
    let cooled = await substrate.decayAffect()
    #expect(cooled.arousal < active.arousal)
    #expect(cooled.socialWarmth < active.socialWarmth)
    #expect(cooled.arousal < cooled.socialWarmth)

    // Still movable from a non-saturated state: a fresh warm turn clearly lifts both axes.
    clock.advance(90)
    await warmTurn("msg-recover")
    let recovered = await substrate.affectSnapshot()
    #expect(recovered.socialWarmth > cooled.socialWarmth)
    #expect(recovered.arousal > cooled.arousal)
}

@Test func affectWarmthTracksWarmthInTheExchangeNotWorkVolume() async throws {
    // User's model: Agent's persona is already naturally warm with him; cognitive affect-warmth
    // is an ADDITIVE modulation on top — it rises on genuine warmth and eases down during
    // focused work (no flat per-message base). Pure work must NOT pump affect-warmth; a warm
    // exchange must lift it well above the work baseline.
    let clock = TestClock(Date(timeIntervalSince1970: 1_000))

    func drive(_ s: CognitiveSubstrate, _ summary: String, _ tag: String) async {
        for i in 0..<20 {
            clock.advance(90)
            await s.ingest(CognitiveEvent(
                id: "\(tag)-\(i)",
                kind: .userMessageReceived,
                subject: CognitiveSubjectReference(type: "chat_turn", id: "session:user"),
                sourceClass: .userStated,
                occurredAt: clock.now(),
                summary: summary,
                importance: 1,
                metadata: ["sessionId": .string("session")]
            ))
        }
    }

    let work = makeSubstrate(clock: clock, configuration: CognitiveConfiguration(enabled: true, affectEnabled: true))
    await drive(work, "Run the build, check the parser threshold at line 50, then rerun the tests", "task")
    let working = await work.affectSnapshot()
    #expect(working.socialWarmth < 0.3)    // focused work does not pump affect-warmth
    #expect(working.taskPressure > 0.05)   // but she is engaged / in work mode

    let warm = makeSubstrate(clock: clock, configuration: CognitiveConfiguration(enabled: true, affectEnabled: true))
    await drive(warm, "love you, you're warm and present, I'm here with you", "warm")
    #expect(await warm.affectSnapshot().socialWarmth > working.socialWarmth + 0.4)
}

@Test func ambientPresenceHoldsQuietWarmthFloorWhenUserStepsAway() async throws {
    // Widen-senses (sampled on the maintenance loop): once a warm session is established, a
    // long quiet gap should leave Agent settled-but-present — warmth holds a small floor
    // instead of decaying to a flat ~0 — while never inventing warmth where no session existed.
    let clock = TestClock(Date(timeIntervalSince1970: 1_000))
    let substrate = makeSubstrate(
        clock: clock,
        configuration: CognitiveConfiguration(enabled: true, affectEnabled: true)
    )

    await substrate.ingest(CognitiveEvent(
        id: "warm",
        kind: .userMessageReceived,
        subject: CognitiveSubjectReference(type: "chat_turn", id: "session:user"),
        sourceClass: .userStated,
        occurredAt: clock.now(),
        summary: "User is warm and present with Agent",
        importance: 1,
        metadata: ["sessionId": .string("session")]
    ))

    // User steps away for hours: decay alone would pull warmth toward ~0.
    clock.advance(4 * 60 * 60)
    await substrate.runMaintenance(reason: "ambient-presence-test")
    let away = await substrate.affectSnapshot()
    #expect(away.socialWarmth > 0.05)   // floor held — still quietly present
    #expect(away.socialWarmth < 0.25)   // but small and quiet, never warm-pegged
    #expect(away.updatedAt == clock.now())

    // With no established presence, ambient presence must not invent warmth from nothing.
    let fresh = makeSubstrate(
        clock: clock,
        configuration: CognitiveConfiguration(enabled: true, affectEnabled: true)
    )
    await fresh.runMaintenance(reason: "no-presence")
    #expect(await fresh.affectSnapshot().socialWarmth == 0)

    // After an explicit clearTransientState(), the stale presence timestamp must NOT
    // resurrect warmth on a later maintenance pass — clear means clear (state lifecycle).
    await substrate.clearTransientState()
    clock.advance(60 * 60)
    await substrate.runMaintenance(reason: "after-clear")
    #expect(await substrate.affectSnapshot().socialWarmth == 0)
}

@Test func ambientPresenceDoesNotManufactureWarmthAfterPureWork() async throws {
    // The ambient warmth floor must hold lingering warmth from a genuinely warm moment only.
    // A pure-work session (no warm content) then a long absence must NEVER manufacture
    // affect-warmth — warmth stays content-driven, consistent with the additive model.
    let clock = TestClock(Date(timeIntervalSince1970: 1_000))
    let substrate = makeSubstrate(
        clock: clock,
        configuration: CognitiveConfiguration(enabled: true, affectEnabled: true)
    )
    await substrate.ingest(CognitiveEvent(
        id: "work",
        kind: .userMessageReceived,
        subject: CognitiveSubjectReference(type: "chat_turn", id: "session:user"),
        sourceClass: .userStated,
        occurredAt: clock.now(),
        summary: "Run the build and check the parser threshold at line 50",
        importance: 1,
        metadata: ["sessionId": .string("session")]
    ))
    clock.advance(31 * 60)
    await substrate.runMaintenance(reason: "after-pure-work")
    #expect(await substrate.affectSnapshot().socialWarmth == 0)
}
