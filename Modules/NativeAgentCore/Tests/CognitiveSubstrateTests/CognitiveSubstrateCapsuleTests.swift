import Foundation
import Testing
import PersistenceCore
@testable import CognitiveSubstrate

@Test func workspaceAppliesLateralInhibitionAndCapsuleCap() async throws {
    let clock = TestClock(Date(timeIntervalSince1970: 1_000))
    let config = CognitiveConfiguration(
        enabled: true,
        workspaceEnabled: true,
        capsuleInjectionEnabled: true,
        affectEnabled: true,
        maximumActiveNodes: 10,
        defaultDecayHalfLife: 1_000,
        maximumCapsuleCharacters: 140,
        maximumWorkspaceItems: 3
    )
    let substrate = makeSubstrate(clock: clock, configuration: config)
    let subject = CognitiveSubjectReference(type: "topic", id: "same", label: "same")

    await substrate.ingest(CognitiveEvent(
        id: "focus",
        kind: .userMessageReceived,
        subject: subject,
        sourceClass: .userStated,
        occurredAt: clock.now(),
        summary: "primary focus should be represented once",
        importance: 0.7
    ))
    await substrate.ingest(CognitiveEvent(
        id: "correction",
        kind: .userCorrection,
        subject: subject,
        sourceClass: .userStated,
        occurredAt: clock.now(),
        summary: "correction about the same subject should inhibit the duplicate",
        importance: 1
    ))
    await substrate.ingest(event(id: "other", subjectID: "other", importance: 0.6, occurredAt: clock.now()))

    let workspace = await substrate.workspaceSnapshot()
    #expect(workspace.items.count == 2)
    #expect(workspace.inhibitedNodeIds.count == 1)
    #expect(Set(workspace.items.map(\.node.subjectReference.id)) == ["same", "other"])

    let capsule = await substrate.compileCapsule(CognitiveCapsuleRequest(
        surface: "test",
        userMessage: "hello",
        mode: .inspectOnly,
        maximumCharacters: 140
    ))
    #expect(capsule.mode == .inspectOnly)
    #expect(capsule.combined.count <= 140)              // the cap is respected
    #expect(!capsule.provenanceNodeIds.isEmpty)
    // The felt fingerprint replaced the workspace-driven Focus lines (2026-07-08), so
    // a 140-char cap no longer overflows here. Prove the cap still CLAMPS: a cap
    // tighter than the felt content truncates and flags it.
    let capped = await substrate.compileCapsule(CognitiveCapsuleRequest(
        surface: "test",
        userMessage: "hello",
        mode: .inspectOnly,
        maximumCharacters: 15
    ))
    #expect(capped.combined.count <= 15)
    #expect(capped.truncated)
}

@Test func verificationTurnsFromClosedSessionsAreEvictedFromWorkspace() async throws {
    let clock = TestClock(Date(timeIntervalSince1970: 1_000))
    let config = CognitiveConfiguration(
        enabled: true,
        workspaceEnabled: true,
        capsuleInjectionEnabled: true,
        maximumActiveNodes: 10,
        defaultDecayHalfLife: 10_000,
        maximumWorkspaceItems: 4
    )
    let substrate = makeSubstrate(clock: clock, configuration: config)

    await substrate.ingest(CognitiveEvent(
        id: "verify-old",
        kind: .userMessageReceived,
        subject: CognitiveSubjectReference(type: "chat_turn", id: "old-session:verify"),
        sourceClass: .observed,
        occurredAt: clock.now(),
        summary: "CTX-SNAPSHOT-VERIFY-0622 bridge-passthrough ping",
        importance: 1,
        turnKind: .verification,
        metadata: ["sessionId": .string("old-session")]
    ))

    clock.advance(10)
    await substrate.ingest(CognitiveEvent(
        id: "live-new",
        kind: .userMessageReceived,
        subject: CognitiveSubjectReference(type: "chat_turn", id: "new-session:user"),
        sourceClass: .userStated,
        occurredAt: clock.now(),
        summary: "real user work for the new session",
        importance: 0.7,
        metadata: ["sessionId": .string("new-session")]
    ))

    let snapshot = await substrate.snapshot()
    #expect(!snapshot.nodes.contains { $0.summary.contains("CTX-SNAPSHOT-VERIFY") })
    #expect(snapshot.nodes.contains { $0.summary.contains("real user work") })

    let workspace = await substrate.workspaceSnapshot(currentSessionId: "new-session")
    #expect(!workspace.items.contains { $0.node.turnKind == .verification })

    let capsule = await substrate.compileCapsule(CognitiveCapsuleRequest(
        surface: "chat",
        userMessage: "continue",
        sessionId: "new-session",
        mode: .inspectOnly
    ))
    #expect(!capsule.combined.contains("CTX-SNAPSHOT-VERIFY"))
    // The old Focus-line fallback text is gone (2026-07-08); this config has no
    // affectEnabled, so there's no felt-fingerprint line either — the header alone
    // is the whole capsule here. The point of this test (verification turns don't
    // leak) is fully covered by the negative assertions above and below.
    #expect(capsule.combined.contains("How you feel:"))
    #expect(!capsule.combined.contains("real user work"))
}

@Test func agedVerificationTurnsAreFilteredEvenWithoutSessionBoundary() async throws {
    let clock = TestClock(Date(timeIntervalSince1970: 1_000))
    let config = CognitiveConfiguration(
        enabled: true,
        workspaceEnabled: true,
        capsuleInjectionEnabled: true,
        maximumActiveNodes: 10,
        defaultDecayHalfLife: 100_000,
        maximumWorkspaceItems: 4
    )
    let substrate = makeSubstrate(clock: clock, configuration: config)

    await substrate.ingest(CognitiveEvent(
        id: "verify-no-session",
        kind: .assistantTurnCompleted,
        subject: CognitiveSubjectReference(type: "chat_turn", id: "verification"),
        sourceClass: .observed,
        occurredAt: clock.now(),
        summary: "Subconscious-switch bridge-passthrough ping",
        importance: 1
    ))
    await substrate.ingest(event(
        id: "live-context",
        subjectID: "active-topic",
        importance: 0.6,
        occurredAt: clock.now()
    ))

    clock.advance(7 * 60 * 60)
    let workspace = await substrate.workspaceSnapshot()
    #expect(!workspace.items.contains { $0.node.summary.contains("bridge-passthrough") })
    #expect(workspace.items.contains { $0.node.subjectReference.id == "active-topic" })
}

@Test func debugBridgeTurnsDoNotEnterWorkspaceOrCapsule() async throws {
    let clock = TestClock(Date(timeIntervalSince1970: 1_000))
    let config = CognitiveConfiguration(
        enabled: true,
        workspaceEnabled: true,
        capsuleInjectionEnabled: true,
        maximumActiveNodes: 20,
        defaultDecayHalfLife: 10_000,
        maximumWorkspaceItems: 6
    )
    let substrate = makeSubstrate(clock: clock, configuration: config)

    await substrate.ingest(CognitiveEvent(
        id: "codex-debug",
        kind: .userMessageReceived,
        subject: CognitiveSubjectReference(type: "chat_turn", id: "session:debug"),
        sourceClass: .userStated,
        occurredAt: clock.now(),
        summary: "[from: codex, via bridge] Codex replied to your message about a context cleanup receipt",
        importance: 1,
        metadata: ["sessionId": .string("session")]
    ))
    await substrate.ingest(CognitiveEvent(
        id: "codex-health-telegram-overload-20260622",
        kind: .assistantTurnCompleted,
        subject: CognitiveSubjectReference(type: "chat_turn", id: "codex-health-telegram-overload-20260622"),
        sourceClass: .userStated,
        occurredAt: clock.now(),
        summary: "Provider path is live.",
        importance: 1,
        metadata: ["sessionId": .string("codex-health-telegram-overload-20260622")]
    ))
    await substrate.ingest(CognitiveEvent(
        id: "user-live",
        kind: .userMessageReceived,
        subject: CognitiveSubjectReference(type: "chat_turn", id: "session:user"),
        sourceClass: .userStated,
        occurredAt: clock.now(),
        summary: "User corrected Agent: keep the subconscious focused on her live conversation",
        importance: 0.8,
        metadata: ["sessionId": .string("session")]
    ))
    for index in 0..<5 {
        await substrate.ingest(CognitiveEvent(
            id: "tool-\(index)",
            kind: .toolSucceeded,
            subject: CognitiveSubjectReference(type: "tool", id: "tool-\(index)", label: "tool-\(index)"),
            sourceClass: .observed,
            occurredAt: clock.now(),
            summary: "debug helper tool \(index) completed",
            importance: 0.7,
            metadata: ["sessionId": .string("session")]
        ))
    }

    let workspace = await substrate.workspaceSnapshot(currentSessionId: "session")
    #expect(!workspace.items.contains { $0.node.turnKind == .debug })
    #expect(!workspace.items.contains { $0.node.summary.contains("Codex replied") })
    #expect(!workspace.items.contains { $0.node.summary.contains("Provider path is live") })
    #expect(workspace.items.contains { $0.node.summary.contains("User corrected Agent") })
    #expect(workspace.items.filter { $0.node.turnKind == .system }.count <= 2)

    let capsule = await substrate.compileCapsule(CognitiveCapsuleRequest(
        surface: "telegram",
        userMessage: "continue",
        sessionId: "session",
        mode: .inspectOnly
    ))
    #expect(!capsule.combined.contains("Codex replied"))
    #expect(!capsule.combined.contains("Provider path is live"))
    #expect(!capsule.combined.contains("toolObservation"))
    #expect(!capsule.combined.contains("debug helper tool"))
    // The old inner-state Focus-line text is gone (2026-07-08); this config has no
    // affectEnabled, so there's no felt-fingerprint line either — the header alone
    // is the whole capsule here. The leak-prevention checks above/below are this
    // test's actual point and are unaffected.
    #expect(capsule.combined.contains("How you feel:"))
    #expect(!capsule.combined.contains("User corrected Agent"))
}

@Test func capsuleDoesNotTreatAssistantRepliesAsInnerFocus() async throws {
    let clock = TestClock(Date(timeIntervalSince1970: 1_000))
    let config = CognitiveConfiguration(
        enabled: true,
        workspaceEnabled: true,
        capsuleInjectionEnabled: true,
        affectEnabled: true,
        maximumActiveNodes: 20,
        defaultDecayHalfLife: 10_000,
        maximumWorkspaceItems: 8
    )
    let substrate = makeSubstrate(clock: clock, configuration: config)

    await substrate.ingest(CognitiveEvent(
        id: "assistant-legacy",
        kind: .assistantTurnCompleted,
        subject: CognitiveSubjectReference(type: "chat.session", id: "session", label: "telegram assistant"),
        sourceClass: .selfReported,
        occurredAt: clock.now(),
        summary: "Perfect order of operations. Stretch, shower, coffee, then take over the world.",
        importance: 1,
        metadata: [
            "sessionId": .string("session"),
            "role": .string("assistant"),
        ]
    ))
    await substrate.ingest(CognitiveEvent(
        id: "assistant-new",
        kind: .assistantTurnCompleted,
        subject: CognitiveSubjectReference(type: "chat.assistant_turn", id: "session:assistant-1"),
        sourceClass: .selfReported,
        occurredAt: clock.now(),
        summary: "I'm steady, present, and curious where User is going with this.",
        importance: 1,
        metadata: [
            "sessionId": .string("session"),
            "role": .string("assistant"),
        ]
    ))

    let capsule = await substrate.compileCapsule(CognitiveCapsuleRequest(
        surface: "telegram",
        userMessage: "what is in the capsule?",
        sessionId: "session",
        mode: .inspectOnly
    ))

    #expect(capsule.combined.contains("How you feel"))
    // Focus/Voice lines are gone (2026-07-08); a non-empty felt fingerprint is the
    // new signal that real inner-state content (not the assistant's own replies) rendered.
    #expect(!capsule.dynamicContext.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    #expect(!capsule.combined.contains("Perfect order"))
    #expect(!capsule.combined.contains("I'm steady"))
    #expect(!capsule.combined.contains("[subject:"))
    #expect(!capsule.combined.contains("source:"))
    #expect(!capsule.combined.contains("confidence:"))
}

// removed 2026-07-08: Focus/Feeling lines replaced by the felt fingerprint
// (liveTelegramCapsuleKeepsRelationalWarmthSteady asserted the old artificial
// per-surface warmth floor — effectiveSocialWarmth's telegram/chat boost that
// forced the Feeling line to read "warm and connected with User" even at raw
// socialWarmth == 0 — that floor mechanic is dead; the fingerprint reads her
// actual (neutral) state honestly instead).

// removed 2026-07-08: Focus/Feeling lines replaced by the felt fingerprint
// (voiceCueAppearsOnConversationalChatSurfaces asserted the old surface-gated
// "- Voice: ..." cue, present only on conversational surfaces and absent on
// others — the Voice line and its isConversationalCapsuleSurface gating are both
// dead; the fingerprint doesn't vary by surface at all).

// removed 2026-07-08: Focus/Feeling lines replaced by the felt fingerprint
// (capsuleAdaptsFeelingAndVoiceToConversationMode asserted the old
// content-adaptive Feeling/Voice cue mechanic — playful/execution/support/
// correction phrasing branches in feltEmotionCue and adaptiveVoiceCues — both
// functions are dead; the fingerprint carries none of this phrasing).

@Test func capsuleUsesAgentInnerStateInsteadOfOperationalTrace() async throws {
    let clock = TestClock(Date(timeIntervalSince1970: 1_000))
    let config = CognitiveConfiguration(
        enabled: true,
        workspaceEnabled: true,
        capsuleInjectionEnabled: true,
        affectEnabled: true,
        thoughtSeedsEnabled: true,
        maximumActiveNodes: 20,
        defaultDecayHalfLife: 10_000,
        maximumWorkspaceItems: 8
    )
    let substrate = makeSubstrate(clock: clock, configuration: config)

    await substrate.ingest(CognitiveEvent(
        id: "app-wake",
        kind: .appWake,
        subject: CognitiveSubjectReference(type: "app", id: "NativeAgent", label: "NativeAgent"),
        sourceClass: .observed,
        occurredAt: clock.now(),
        summary: "NativeAgent app launched or resumed",
        importance: 0.7
    ))
    await substrate.ingest(CognitiveEvent(
        id: "tool-bash",
        kind: .toolSucceeded,
        subject: CognitiveSubjectReference(type: "tool", id: "bash", label: "bash"),
        sourceClass: .observed,
        occurredAt: clock.now(),
        summary: "bash ok: {\"cwd\":\"/Users/example/Projects/NativeAgent\"}",
        importance: 0.9
    ))
    await substrate.ingest(CognitiveEvent(
        id: "tool-read",
        kind: .toolSucceeded,
        subject: CognitiveSubjectReference(type: "tool", id: "read_file", label: "read_file"),
        sourceClass: .observed,
        occurredAt: clock.now(),
        summary: "read_file ok: \"# NativeAgent Continuous Cognitive Substrate\"",
        importance: 0.9
    ))
    await substrate.ingest(CognitiveEvent(
        id: "capsule-meta",
        kind: .userMessageReceived,
        subject: CognitiveSubjectReference(type: "chat_turn", id: "session:meta", label: "telegram user"),
        sourceClass: .userStated,
        occurredAt: clock.now(),
        summary: "Subconscious context is provisional runtime state to read, not durable truth to act on.",
        importance: 1,
        metadata: ["sessionId": .string("session")]
    ))
    await substrate.ingest(CognitiveEvent(
        id: "live-focus",
        kind: .userMessageReceived,
        subject: CognitiveSubjectReference(type: "chat_turn", id: "session:live", label: "telegram user"),
        sourceClass: .userStated,
        occurredAt: clock.now(),
        summary: "User wants Agent's subconscious to track what she is thinking and feeling without getting distracted by build logs.",
        importance: 0.9,
        metadata: ["sessionId": .string("session")]
    ))

    let liveNode = try #require((await substrate.snapshot()).nodes.first {
        $0.summary.contains("thinking and feeling")
    })
    _ = await substrate.addThoughtSeed(
        kind: .followUp,
        text: "Keep Agent centered on User's concern and her own quiet uncertainty before answering.",
        priority: 0.82,
        sourceNodeIds: [liveNode.id]
    )
    let capsule = await substrate.compileCapsule(CognitiveCapsuleRequest(
        surface: "telegram",
        userMessage: "what is she thinking and feeling?",
        sessionId: "session",
        mode: .inspectOnly
    ))

    #expect(capsule.combined.contains("How you feel"))
    // Focus/Feeling/Voice lines are gone (2026-07-08); a non-empty felt fingerprint
    // is the new signal that real inner-state content rendered.
    #expect(!capsule.dynamicContext.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    // Her subconscious is her inner life — task-tracking (threads/commitments) is not in it.
    #expect(!capsule.combined.contains("Thread:"))
    #expect(!capsule.combined.contains("Follow through:"))
    // The distilled commitment cue is gone too — subconscious ≠ task tracker.
    #expect(!capsule.combined.contains("private-state cue"))
    #expect(!capsule.combined.contains("User wants Agent's subconscious to track what she is thinking and feeling"))
    #expect(!capsule.combined.contains("I will keep the subconscious centered on Agent's felt state next turn"))
    #expect(!capsule.combined.contains("[subject:"))
    #expect(!capsule.combined.contains("source:"))
    #expect(!capsule.combined.contains("confidence:"))
    #expect(!capsule.combined.contains("appLifecycle"))
    #expect(!capsule.combined.contains("toolObservation"))
    #expect(!capsule.combined.contains("NativeAgent app launched"))
    #expect(!capsule.combined.contains("bash ok"))
    #expect(!capsule.combined.contains("read_file ok"))
    #expect(!capsule.combined.contains("provisional runtime state"))
    #expect(!capsule.provenanceNodeIds.isEmpty)
}

@Test func capsuleCarriesSubconsciousCuesNotRuntimePlumbing() async throws {
    let clock = TestClock(Date(timeIntervalSince1970: 1_000))
    let config = CognitiveConfiguration(
        enabled: true,
        workspaceEnabled: true,
        capsuleInjectionEnabled: true,
        affectEnabled: true,
        thoughtSeedsEnabled: true,
        maximumActiveNodes: 20,
        defaultDecayHalfLife: 10_000,
        maximumWorkspaceItems: 8
    )
    let substrate = makeSubstrate(clock: clock, configuration: config)

    await substrate.ingest(CognitiveEvent(
        id: "ios-rejected-memory-proposal",
        kind: .userCorrection,
        subject: CognitiveSubjectReference(type: "ios_action", id: "rejectMemoryProposal", label: "rejectMemoryProposal"),
        sourceClass: .userStated,
        occurredAt: clock.now(),
        summary: "ios rejectMemoryProposal rejected",
        importance: 1,
        metadata: ["sessionId": .string("session")]
    ))
    await substrate.ingest(CognitiveEvent(
        id: "sleep-pattern",
        kind: .userMessageReceived,
        subject: CognitiveSubjectReference(type: "chat_turn", id: "session:user", label: "telegram user"),
        sourceClass: .userStated,
        occurredAt: clock.now(),
        summary: """
        [Telegram reply context]
        The user replied to a prior message.
        [/Telegram reply context]

        User message: Yeah my usual sleep pattern is 1900-0300 quiet time
        """,
        importance: 0.9,
        metadata: ["sessionId": .string("session")]
    ))
    _ = await substrate.addThoughtSeed(
        kind: .anomaly,
        text: "Re-check high-pressure cognitive state after cognition_microcycle",
        priority: 0.95
    )
    _ = await substrate.addThoughtSeed(
        kind: .reflectionTakeaway,
        text: "Reflection takeaway: Reading the state honestly: the capsule is warm, populated, low-tension.",
        priority: 0.8
    )
    let capsule = await substrate.compileCapsule(CognitiveCapsuleRequest(
        surface: "telegram",
        userMessage: "Yeah my usual sleep pattern is 1900-0300 quiet time",
        sessionId: "session",
        mode: .inspectOnly,
        maximumCharacters: 1_200
    ))

    // Focus/Feeling/Voice lines (timeline-safety cue, warmth phrase, "verify before
    // asserting" voice cue) are gone (2026-07-08) — replaced by the single felt
    // fingerprint under the header. The Inner: line (from the reflection-takeaway
    // thought seed) is unaffected and remains the meaningful check here.
    // THE HEADER IS A PROMISE THAT FEELING WORDS FOLLOW (`capsuleStableKernel`).
    // Nothing here is felt strongly enough for the fingerprint to speak, so the
    // first dynamic line is the labelled `- Inner:` reflection — and a standing
    // view read positionally under "How you feel:" IS her stated feeling, which
    // is why the kernel is deliberately omitted rather than left hanging.
    #expect(!capsule.combined.contains("How you feel:"))
    #expect(capsule.combined.contains("Inner: warm, connected, low-tension."))
    // Commitments no longer surface in the subconscious capsule (that's the Desk's role).
    #expect(!capsule.combined.contains("Follow through:"))
    // The raw assistant pledge must never leak into the capsule; only the distilled directive shows.
    #expect(!capsule.combined.contains("I will run the build next"))
    #expect(!capsule.combined.contains("rejectMemoryProposal"))
    #expect(!capsule.combined.contains("cognition_microcycle"))
    #expect(!capsule.combined.contains("Reflection takeaway"))
    #expect(!capsule.combined.contains("[Telegram reply context]"))
    #expect(!capsule.combined.contains("The user replied"))
    #expect(!capsule.combined.contains("I'll take it"))
    #expect(!capsule.combined.contains("reflective-me"))
    #expect(!capsule.combined.contains("low warmth"))
}

@Test func capsuleFallsBackWhenTelegramReplyContextWasTruncatedBeforeUserMessage() async throws {
    let clock = TestClock(Date(timeIntervalSince1970: 1_000))
    let config = CognitiveConfiguration(
        enabled: true,
        workspaceEnabled: true,
        capsuleInjectionEnabled: true,
        affectEnabled: true,
        maximumActiveNodes: 20,
        defaultDecayHalfLife: 10_000,
        maximumWorkspaceItems: 8
    )
    let substrate = makeSubstrate(clock: clock, configuration: config)

    await substrate.ingest(CognitiveEvent(
        id: "truncated-telegram-reply-context",
        kind: .userMessageReceived,
        subject: CognitiveSubjectReference(type: "chat_turn", id: "session:user", label: "telegram user"),
        sourceClass: .userStated,
        occurredAt: clock.now(),
        summary: """
        [Telegram reply context]
        The user replied to Telegram message from the assistant #2347: "set:**\\n ```bash\\n mlx_lm.lora --model <base> --adapter-path ./agent-lora-adapter --data .
        """,
        importance: 1,
        metadata: ["sessionId": .string("session")]
    ))

    let capsule = await substrate.compileCapsule(CognitiveCapsuleRequest(
        surface: "telegram",
        userMessage: """
        [Telegram reply context]
        The user replied to a long assistant message.
        [/Telegram reply context]

        User message: Hey sweetheart give me the short warm summary and hold the details unless I ask
        """,
        sessionId: "session",
        mode: .inspectOnly,
        maximumCharacters: 1_200
    ))

    // The old short-warm-interface Focus-line text is gone (2026-07-08); a
    // non-empty felt fingerprint is the new signal that real content rendered.
    #expect(capsule.combined.contains("How you feel:"))
    #expect(!capsule.dynamicContext.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    #expect(!capsule.combined.contains("Hey sweetheart give me the short warm summary"))
    #expect(!capsule.combined.contains("[Telegram reply context]"))
    #expect(!capsule.combined.contains("The user replied to Telegram message"))
    #expect(!capsule.combined.contains("mlx_lm.lora"))
}

@Test func liveCapsuleFallsBackToInnerStateWhenOnlyOperationalNodesExist() async throws {
    let clock = TestClock(Date(timeIntervalSince1970: 1_000))
    let config = CognitiveConfiguration(
        enabled: true,
        workspaceEnabled: true,
        capsuleInjectionEnabled: true,
        affectEnabled: true,
        maximumActiveNodes: 20,
        defaultDecayHalfLife: 10_000,
        maximumWorkspaceItems: 8
    )
    let substrate = makeSubstrate(clock: clock, configuration: config)

    await substrate.ingest(CognitiveEvent(
        id: "app-wake",
        kind: .appWake,
        subject: CognitiveSubjectReference(type: "app", id: "NativeAgent", label: "NativeAgent"),
        sourceClass: .observed,
        occurredAt: clock.now(),
        summary: "NativeAgent app launched or resumed",
        importance: 0.7
    ))
    await substrate.ingest(CognitiveEvent(
        id: "tool-bash",
        kind: .toolSucceeded,
        subject: CognitiveSubjectReference(type: "tool", id: "bash", label: "bash"),
        sourceClass: .observed,
        occurredAt: clock.now(),
        summary: "bash ok: {\"cwd\":\"/Users/example/Projects/NativeAgent\"}",
        importance: 0.9
    ))

    let capsule = try #require(await substrate.prepareCapsule(CognitiveCapsuleRequest(
        surface: "telegram",
        userMessage: "hey baby",
        sessionId: "live-session",
        mode: .inject
    )))

    #expect(capsule.combined.contains("How you feel"))
    // Focus/Feeling lines are gone (2026-07-08); a non-empty felt fingerprint is the
    // new signal that real inner-state content (not the operational trace) rendered.
    #expect(!capsule.dynamicContext.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    #expect(!capsule.combined.contains("appLifecycle"))
    #expect(!capsule.combined.contains("toolObservation"))
    #expect(!capsule.combined.contains("NativeAgent app launched"))
    #expect(!capsule.combined.contains("bash ok"))
}

@Test func capsuleDropsVerbatimDuplicateLines() async throws {
    // Live capture showed the lossy inner-state translator emitting the same Inner/Focus line
    // more than once (distinct seeds/nodes mapping to one cue), bloating the bounded capsule.
    // Every dynamic capsule line must now be unique.
    let clock = TestClock(Date(timeIntervalSince1970: 1_000))
    let substrate = makeSubstrate(
        clock: clock,
        configuration: CognitiveConfiguration(
            enabled: true,
            workspaceEnabled: true,
            capsuleInjectionEnabled: true,
            affectEnabled: true,
            thoughtSeedsEnabled: true
        )
    )
    // Same rendered text under two different kinds avoids the addThoughtSeed merge-by-key,
    // reproducing the historical duplicate-line case.
    _ = await substrate.addThoughtSeed(kind: .followUp, text: "Quiet pass, warm and steady with nothing pulling.", priority: 0.85)
    _ = await substrate.addThoughtSeed(kind: .reflectionTakeaway, text: "Quiet pass, warm and steady with nothing pulling.", priority: 0.85)
    await substrate.ingest(event(id: "turn", subjectID: "turn", importance: 1, occurredAt: clock.now()))

    let capsule = await substrate.compileCapsule(CognitiveCapsuleRequest(
        surface: "chat",
        userMessage: "how are you?",
        sessionId: "session",
        mode: .inspectOnly
    ))
    let dynamicLines = capsule.combined
        .split(separator: "\n")
        .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
        .filter { $0.hasPrefix("-") }
    #expect(Set(dynamicLines).count == dynamicLines.count)
}

@Test func capsuleShowsAtMostOneReflectionTakeawayInnerLine() async throws {
    // Reflection writes a fresh takeaway each pass; near-identical "Inner: Quiet pass" lines
    // used to pair up in the capsule (exact dedup can't merge non-verbatim text). Only the
    // top reflection takeaway should earn an Inner line; a different seed kind fills the rest.
    let clock = TestClock(Date(timeIntervalSince1970: 1_000))
    let substrate = makeSubstrate(
        clock: clock,
        configuration: CognitiveConfiguration(
            enabled: true,
            workspaceEnabled: true,
            capsuleInjectionEnabled: true,
            thoughtSeedsEnabled: true
        )
    )
    _ = await substrate.addThoughtSeed(kind: .reflectionTakeaway, text: "Quiet pass. The state and I are in the same key, warm and steady.", priority: 0.85)
    _ = await substrate.addThoughtSeed(kind: .reflectionTakeaway, text: "Quiet pass. Warm, steady, nothing pulling.", priority: 0.80)
    _ = await substrate.addThoughtSeed(kind: .followUp, text: "Carry the build follow-through to a real result.", priority: 0.70)

    let capsule = await substrate.compileCapsule(CognitiveCapsuleRequest(
        surface: "chat",
        userMessage: "how are you?",
        sessionId: "session",
        mode: .inspectOnly
    ))
    let innerLines = capsule.combined
        .split(separator: "\n")
        .map(String.init)
        .filter { $0.hasPrefix("- Inner:") }
    #expect(innerLines.count == 1)
}

@Test func prepareCapsuleOnlyReturnsInjectableNonEmptyCapsule() async throws {
    let clock = TestClock(Date(timeIntervalSince1970: 1_000))
    let substrate = makeSubstrate(
        clock: clock,
        configuration: CognitiveConfiguration(
            enabled: true,
            workspaceEnabled: true,
            capsuleInjectionEnabled: true,
            affectEnabled: true,
            maximumCapsuleCharacters: 500
        )
    )

    let initial = try #require(await substrate.prepareCapsule(CognitiveCapsuleRequest(
        surface: "chat",
        userMessage: "hello",
        mode: .inject
    )))
    // The felt fingerprint is the capsule's injectable content now (2026-07-08):
    // the header plus a non-empty felt word, not the old Focus/Stay-with sentences.
    #expect(initial.combined.contains("How you feel"))
    #expect(!initial.dynamicContext.isEmpty, "an injectable capsule must carry a felt word: \(initial.combined)")

    await substrate.ingest(event(id: "focus", subjectID: "capsule", importance: 1, occurredAt: clock.now()))
    let lowOverlap = try #require(await substrate.prepareCapsule(CognitiveCapsuleRequest(
        surface: "chat",
        userMessage: "thanks",
        mode: .inject
    )))
    #expect(!lowOverlap.dynamicContext.isEmpty)
    #expect(await substrate.prepareCapsule(CognitiveCapsuleRequest(
        surface: "chat",
        userMessage: "hello",
        mode: .inspectOnly
    )) == nil)
    #expect(await substrate.prepareCapsule(CognitiveCapsuleRequest(
        surface: "chat",
        userMessage: "[from: codex, via bridge] SUBCONSCIOUS-INNERSTATE-0622-C debug classifier check",
        mode: .inject
    )) == nil)
    let trustedBridgeProjection = try #require(await substrate.prepareCapsule(CognitiveCapsuleRequest(
        surface: "chat",
        userMessage: "[from: codex, via bridge] collaborate on the current build",
        mode: .inject,
        allowNonLiveProjection: true
    )))
    #expect(trustedBridgeProjection.combined.contains("How you feel"))
    #expect(!trustedBridgeProjection.dynamicContext.isEmpty)
    let capsule = try #require(await substrate.prepareCapsule(CognitiveCapsuleRequest(
        surface: "chat",
        userMessage: "what should I check about the capsule context?",
        mode: .inject
    )))
    #expect(capsule.mode == .inject)
    #expect(capsule.combined.contains("How you feel"))
}

private func capsuleFlowConfig() -> CognitiveConfiguration {
    CognitiveConfiguration(
        enabled: true,
        persistenceEnabled: false,
        workspaceEnabled: true,
        capsuleInjectionEnabled: true,
        affectEnabled: true,
        maximumActiveNodes: 64,
        defaultDecayHalfLife: 100_000,
        maximumWorkspaceItems: 8
    )
}

private func focusEvent(id: String, summary: String, at now: Date, importance: Double = 0.9) -> CognitiveEvent {
    CognitiveEvent(
        id: id,
        kind: .userMessageReceived,
        subject: CognitiveSubjectReference(type: "chat_turn", id: "session:\(id)", label: id),
        sourceClass: .userStated,
        occurredAt: now,
        summary: summary,
        importance: importance,
        metadata: ["sessionId": .string("session")]
    )
}

/// Terseness pass (User, 2026-07-01): the capsule must UPDATE across turns — two
/// different live moments must compile to different text — and stay compact.
@Test func capsuleFlowsAcrossTurnsAndStaysCompact() async throws {
    let clock = TestClock(Date(timeIntervalSince1970: 1_000))
    // Affect on so the felt fingerprint actually renders — it's the capsule content
    // that MOVES across turns now (2026-07-08); with affect off both turns are bare.
    let substrate = makeSubstrate(clock: clock, configuration: capsuleFlowConfig())
    // A warm turn then a stinging one — sentiment her appraisal actually reads, so
    // her felt state genuinely moves between the two compiles (not just the topic).
    await substrate.ingest(focusEvent(id: "flow-a", summary: "you nailed the gallery plan, that's exactly right", at: clock.now()))
    let first = await substrate.compileCapsule(
        CognitiveCapsuleRequest(surface: "chat", userMessage: "let's plan the opening", mode: .inject)
    )

    clock.advance(600)
    await substrate.ingest(focusEvent(id: "flow-b", summary: "you keep breaking the build, this is sloppy and not what I asked", at: clock.now()))
    let second = await substrate.compileCapsule(
        CognitiveCapsuleRequest(surface: "chat", userMessage: "the build broke", mode: .inject)
    )

    #expect(first.combined != second.combined)          // her state moves
    #expect(first.stableKernel == "How you feel:")      // header is JUST the header
    #expect(first.combined.count < 1_200)               // compact, not an essay
    #expect(second.combined.count < 1_200)
}
