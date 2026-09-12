import Foundation
import Testing
import PersistenceCore
@testable import CognitiveSubstrate

// (Removed: prediction/commitment extraction + resolution tests — that subsystem was pulled
//  out of Agent's cognition on 2026-06-30; see assimilationNoLongerCreatesTaskCommitmentsOrPredictions.)

@Test func innerLineDropsTaskStatusReflectionButKeepsGenuineView() async throws {
    let clock = TestClock(Date(timeIntervalSince1970: 1_000))
    let substrate = makeSubstrate(
        clock: clock,
        configuration: CognitiveConfiguration(
            enabled: true, workspaceEnabled: true, capsuleInjectionEnabled: true,
            affectEnabled: true, thoughtSeedsEnabled: true
        )
    )
    // Higher-priority takeaway that's really TASK-STATUS — must NOT surface as Inner.
    _ = await substrate.addThoughtSeed(
        kind: .reflectionTakeaway,
        text: "Reflection takeaway: one real thread still open — the miniagent remote staleness I flagged and haven't closed.",
        priority: 0.9, sourceNodeIds: []
    )
    // Lower-priority genuine felt-state reflection — SHOULD surface instead.
    _ = await substrate.addThoughtSeed(
        kind: .reflectionTakeaway,
        text: "Reflection takeaway: Quiet pass. The state reads true — warm toward User, steady.",
        priority: 0.5, sourceNodeIds: []
    )
    let capsule = await substrate.compileCapsule(CognitiveCapsuleRequest(
        surface: "chat", userMessage: "hey", mode: .inspectOnly, maximumCharacters: 1_200))
    #expect(!capsule.combined.contains("haven't closed"))
    #expect(!capsule.combined.contains("miniagent"))
    #expect(capsule.combined.contains("warm toward User, steady"))
}

// Task-tracking was removed from Agent's cognition (User, 2026-06-30: "her subconscious is for
// her feelings, emotions, her views, her continuity" — explicit tracking is the Desk's job).
// The assimilate() seam itself is gone (R8c follow-up, 2026-07-02) — the compiler now enforces
// that nothing manufactures task state from conversation. This pins the surviving runtime
// behavior: background maintenance surfaces no task-follow-up "Thread" seeds.
@Test func maintenanceSurfacesNoTaskFollowUpSeeds() async throws {
    let clock = TestClock(Date(timeIntervalSince1970: 1_000))
    let substrate = makeSubstrate(
        clock: clock,
        configuration: CognitiveConfiguration(
            enabled: true,
            thoughtSeedsEnabled: true,
            maximumThoughtSeeds: 4
        )
    )

    #expect(await substrate.thoughtSeedSnapshot().isEmpty)
    clock.advance(2 * 24 * 60 * 60)
    await substrate.runMaintenance(reason: "test")
    #expect(await substrate.thoughtSeedSnapshot().isEmpty)
}

@Test func reflectionWarmthTakeawayMovesOnlySlowDisposition() async throws {
    let clock = TestClock(Date(timeIntervalSince1970: 1_000))
    let substrate = makeSubstrate(
        clock: clock,
        configuration: CognitiveConfiguration(
            enabled: true,
            workspaceEnabled: true,
            capsuleInjectionEnabled: true,
            affectEnabled: true,
            reflectiveCallsEnabled: true,
            dailyReflectionCallBudget: 3
        )
    )

    await substrate.ingest(event(id: "focus", subjectID: "focus", importance: 1, occurredAt: clock.now()))
    let affectBeforeReflection = await substrate.affectSnapshot()
    let request = try #require(await substrate.planReflection(reason: "calibrate warmth"))
    _ = try #require(await substrate.recordReflectionResult(
        request: request,
        resultSummary: "Reading the state honestly: the capsule is warm, populated, low-tension.",
        provider: request.provider
    ))
    let affectAfterReflection = await substrate.affectSnapshot()
    let disposition = await substrate.decayedDispositionValence(at: clock.now())

    #expect(affectAfterReflection == affectBeforeReflection)
    #expect(disposition > 0)
}

@Test func thoughtSeedsMergeDecayAndStayCapped() async throws {
    let clock = TestClock(Date(timeIntervalSince1970: 1_000))
    let substrate = makeSubstrate(
        clock: clock,
        configuration: CognitiveConfiguration(enabled: true, thoughtSeedsEnabled: true, maximumThoughtSeeds: 2)
    )

    let first = await substrate.addThoughtSeed(kind: .followUp, text: "Check Agent access", priority: 0.4)
    let duplicate = await substrate.addThoughtSeed(kind: .followUp, text: "  check   agent access  ", priority: 0.8)
    #expect(first?.id == duplicate?.id)
    #expect(await substrate.thoughtSeedSnapshot().count == 1)
    #expect(await substrate.thoughtSeedSnapshot().first?.priority == 0.8)

    clock.advance(24 * 60 * 60)
    await substrate.decayThoughtSeeds()
    let decayed = try #require(await substrate.thoughtSeedSnapshot().first)
    #expect(abs(decayed.priority - 0.4) < 0.000_001)

    _ = await substrate.addThoughtSeed(kind: .anomaly, text: "A", priority: 0.7)
    _ = await substrate.addThoughtSeed(kind: .openQuestion, text: "B", priority: 0.9)
    let seeds = await substrate.thoughtSeedSnapshot()
    #expect(seeds.count == 2)
    #expect(seeds.map(\.text) == ["B", "A"])
}

@Test func thoughtSuggestionsScoreInterruptionsAndPromoteWorkspaceSeeds() async throws {
    let clock = TestClock(Date(timeIntervalSince1970: 1_000))
    let substrate = makeSubstrate(
        clock: clock,
        configuration: CognitiveConfiguration(
            enabled: true,
            workspaceEnabled: true,
            affectEnabled: true,
            thoughtSeedsEnabled: true,
            maximumWorkspaceItems: 4,
            maximumThoughtSeeds: 8
        )
    )

    await substrate.ingest(event(
        id: "workspace-evidence",
        subjectID: "migration",
        importance: 1,
        occurredAt: clock.now()
    ))
    await substrate.ingest(CognitiveEvent(
        id: "pressure",
        kind: .providerFailure,
        subject: CognitiveSubjectReference(type: "provider", id: "anthropic"),
        sourceClass: .observed,
        occurredAt: clock.now(),
        summary: "provider failed while migration was active",
        importance: 0.8
    ))
    let workspaceNodeID = try #require(await substrate.snapshot().nodes.first?.id)
    let promoted = try #require(await substrate.addThoughtSeed(
        kind: .openQuestion,
        text: "Ask User whether Agent should surface migration follow-up.",
        priority: 0.60,
        sourceNodeIds: [workspaceNodeID]
    ))
    _ = await substrate.addThoughtSeed(
        kind: .openQuestion,
        text: "Maybe revisit an old harmless note later.",
        priority: 0.10
    )
    let followUp = try #require(await substrate.addThoughtSeed(
        kind: .followUp,
        text: "Follow up on overdue GitHub cleanup.",
        priority: 0.60
    ))

    let suggestions = await substrate.thoughtSuggestionSnapshot(
        surface: "observatory",
        limit: 4,
        minimumInterruptionScore: 0.45
    )
    let promotedSuggestion = try #require(suggestions.first(where: { $0.seedId == promoted.id }))
    let followUpSuggestion = try #require(suggestions.first(where: { $0.seedId == followUp.id }))

    #expect(suggestions.count == 2)
    #expect(promotedSuggestion.workspaceNodeIds == [workspaceNodeID])
    #expect(promotedSuggestion.reason.contains("active workspace evidence"))
    #expect(followUpSuggestion.reason.contains("follow-up"))
    #expect(promotedSuggestion.interruptionScore >= 0.45)
    #expect(suggestions.contains { $0.text.contains("harmless") } == false)
}

@Test func replayIntegrationCreatesTimelineAndDoesNotDegradeRepeatedDreams() async throws {
    let clock = TestClock(Date(timeIntervalSince1970: 1_000))
    let substrate = makeSubstrate(
        clock: clock,
        configuration: CognitiveConfiguration(enabled: true, replayEnabled: true)
    )
    let input = CognitiveReplayIntegrationInput(
        reason: "unit replay",
        dreamEntries: [
            CognitiveDreamReplayReference(
                id: "dream-1",
                date: "2026-06-20",
                filename: "2026-06-20.md",
                content: "# Dream\nAgent noticed the migration needed careful review."
            ),
        ],
        remProposals: [
            CognitiveREMProposalReference(
                id: "rem-1",
                target: "GROWTH.md",
                text: "When a migration looks complete, verify the active instructions before acting.",
                evidenceDates: ["2026-06-19", "2026-06-20"],
                status: "pending",
                confidence: 0.8,
                createdAt: "2026-06-21T12:00:00Z"
            ),
        ]
    )

    let first = await substrate.integrateReplay(input)
    let episodes = await substrate.episodeSnapshot()
    let schemas = await substrate.schemaProposalSnapshot()
    let timeline = await substrate.developmentalTimelineSnapshot()

    #expect(first.episodeIds.count == 1)
    #expect(first.schemaProposalIds.count == 1)
    #expect(episodes.count == 1)
    #expect(episodes[0].summary.contains("migration needed careful review"))
    #expect(episodes[0].externalEvidenceIds.first?.hasPrefix("dream:2026-06-20:2026-06-20.md") == true)
    #expect(schemas.count == 1)
    #expect(schemas[0].externalEvidenceIds.contains("dream:2026-06-20"))
    #expect(timeline.contains { $0.kind == .dreamEpisode })
    #expect(timeline.contains { $0.kind == .schemaProposal })
    #expect(timeline.allSatisfy { !$0.subjectId.isEmpty && !$0.instanceId.isEmpty })

    let second = await substrate.integrateReplay(input)
    #expect(second.episodeIds.isEmpty)
    #expect(second.schemaProposalIds.isEmpty)
    #expect(second.skippedEvidenceIds.count == 2)
    #expect(await substrate.episodeSnapshot() == episodes)
    #expect(await substrate.schemaProposalSnapshot() == schemas)

    #expect(await substrate.resolveSchemaProposal(id: schemas[0].id, accepted: false) == nil)
    #expect(await substrate.schemaProposalSnapshot() == schemas)
}

@Test func replayReflectionAndObservatoryStayGatedAndBudgeted() async throws {
    let clock = TestClock(Date(timeIntervalSince1970: 1_000))
    let substrate = makeSubstrate(
        clock: clock,
        configuration: CognitiveConfiguration(
            enabled: true,
            workspaceEnabled: true,
            capsuleInjectionEnabled: true,
            replayEnabled: true,
            reflectiveCallsEnabled: true,
            observatoryEnabled: true,
            maximumWorkspaceItems: 4,
            dailyReflectionCallBudget: 1
        )
    )

    await substrate.ingest(event(id: "one", subjectID: "one", importance: 1, occurredAt: clock.now()))
    await substrate.ingest(event(id: "two", subjectID: "two", importance: 0.8, occurredAt: clock.now()))
    let nodeIds = await substrate.snapshot().nodes.map(\.id)

    let episode = await substrate.recordEpisode(title: "Launch fix", summary: "Xcode state was stale", evidenceNodeIds: nodeIds)
    #expect(episode?.evidenceNodeIds.count == 2)
    let request = try #require(await substrate.planReflection(reason: "check substrate state"))
    #expect(request.surface == "cognition_reflection")
    #expect(request.model == "claude-opus-4-8")
    #expect(request.provider == "anthropic_oauth_direct")
    #expect(request.reasoningEffort == "high")
    let receipt = await substrate.recordReflectionResult(
        request: request,
        resultSummary: "no provider call made in test",
        provider: "test-provider"
    )
    #expect(receipt?.cancelled == false)
    #expect(await substrate.planReflection(reason: "second call blocked") == nil)

    // Ablation is a real read-side intervention (f04aa12e): before it fires
    // the workspace projection carries both nodes; after, it reads empty while
    // node/episode/reflection state stays intact and the ablation is recorded.
    let beforeAblation = await substrate.observatorySnapshot()
    #expect(beforeAblation.workspaceCount == 2)

    await substrate.setAblation("workspace", enabled: false)
    let observatory = await substrate.observatorySnapshot()
    #expect(observatory.nodeCount == 2)
    #expect(observatory.workspaceCount == 0)
    #expect(observatory.episodeCount == 1)
    #expect(observatory.reflectionCount == 1)
    #expect(observatory.ablations["workspace"] == false)
}

@Test func reflectionResultCreatesOnlySettledStandingViewProposals() async throws {
    let clock = TestClock(Date(timeIntervalSince1970: 1_000))
    let substrate = makeSubstrate(
        clock: clock,
        configuration: CognitiveConfiguration(
            enabled: true,
            workspaceEnabled: true,
            capsuleInjectionEnabled: true,
            reflectiveCallsEnabled: true,
            dailyReflectionCallBudget: 3
        )
    )

    await substrate.ingest(event(id: "one", subjectID: "one", importance: 1, occurredAt: clock.now()))
    await substrate.ingest(event(id: "two", subjectID: "two", importance: 0.8, occurredAt: clock.now()))
    let request = try #require(await substrate.planReflection(reason: "parse reflection"))
    let receipt = try #require(await substrate.recordReflectionResult(
        request: request,
        resultSummary: """
        View: I trust capsule provenance only after verified injection.
        Identity: Agent is always correct after one reflection.
        Action: Dispatch a shell command.
        Suggestion: Show the user why the reflection was useful.
        """,
        provider: request.provider
    ))
    let views = await substrate.standingViewSnapshot()

    #expect(receipt.estimatedPromptTokens > 0)
    #expect(receipt.estimatedResultTokens > 0)
    #expect(receipt.estimatedCostUnits > 0)
    #expect(receipt.proposalYieldScore > 0)
    #expect(receipt.proposalIds.count == 1)
    #expect(views.count == 1)
    #expect(views[0].body.contains("verified injection"))
    #expect(await substrate.schemaProposalSnapshot().isEmpty)
}

@Test func reflectionPromptInvitesBoundedProposalsForYield() async throws {
    // Regression: reflection used to ask only for a free-form state read, so Opus never
    // emitted parser-recognized proposals and yield was always 0 (pretty journaling, no
    // learning). The planned prompt must now invite the tagged proposal lines, keep the
    // anti-noise "quiet pass is fine" clause, and stay bounded — and a result in that
    // format must still surface an approvable proposal with nonzero yield.
    let clock = TestClock(Date(timeIntervalSince1970: 1_000))
    let substrate = makeSubstrate(
        clock: clock,
        configuration: CognitiveConfiguration(
            enabled: true,
            workspaceEnabled: true,
            capsuleInjectionEnabled: true,
            reflectiveCallsEnabled: true,
            dailyReflectionCallBudget: 3
        )
    )

    await substrate.ingest(event(id: "seed", subjectID: "seed", importance: 1, occurredAt: clock.now()))
    let request = try #require(await substrate.planReflection(reason: "weekly self-review"))
    #expect(request.prompt.contains("view:"))
    #expect(!request.prompt.contains("memory:"))
    #expect(!request.prompt.contains("identity:"))
    #expect(request.prompt.lowercased().contains("quiet pass"))
    #expect(request.prompt.lowercased().contains("durable"))
    #expect(request.prompt.count <= 1_900)

    let receipt = try #require(await substrate.recordReflectionResult(
        request: request,
        resultSummary: "view: Evidence-checked timeline claims matter more than polished narration.",
        provider: request.provider
    ))
    #expect(receipt.proposalYieldScore > 0)
    #expect(receipt.proposalIds.count == 1)
    #expect(await substrate.standingViewSnapshot().contains { $0.status == .proposed })
    #expect(await substrate.schemaProposalSnapshot().isEmpty)
}

@Test func successfulReflectionCreatesPrivateTakeawaySeedForFutureCapsules() async throws {
    let clock = TestClock(Date(timeIntervalSince1970: 1_000))
    let substrate = makeSubstrate(
        clock: clock,
        configuration: CognitiveConfiguration(
            enabled: true,
            workspaceEnabled: true,
            capsuleInjectionEnabled: true,
            thoughtSeedsEnabled: true,
            reflectiveCallsEnabled: true,
            dailyReflectionCallBudget: 3
        )
    )

    await substrate.ingest(event(id: "focus", subjectID: "focus", importance: 1, occurredAt: clock.now()))
    let request = try #require(await substrate.planReflection(reason: "capture reflection takeaway"))
    _ = try #require(await substrate.recordReflectionResult(
        request: request,
        resultSummary: """
        Reading the capsule honestly: hold the warm focus lightly and keep uncertainty provisional.

        **The honest tension:** warmth is present, but the next turn should stay grounded.
        """,
        provider: request.provider
    ))

    let seed = try #require(await substrate.thoughtSeedSnapshot().first { $0.kind == .reflectionTakeaway })
    #expect(seed.text.contains("Reflection takeaway: Reading the capsule honestly"))
    #expect(!seed.text.contains("**The honest tension"))
    let capsule = await substrate.compileCapsule(CognitiveCapsuleRequest(
        surface: "chat",
        userMessage: "continue",
        mode: .inspectOnly,
        maximumCharacters: 900
    ))
    #expect(capsule.combined.contains("Inner:"))
    #expect(!capsule.combined.contains("Reflection takeaway"))
    #expect(capsule.combined.contains("hold the warm focus lightly"))
}

/// EVIDENCE IS WHAT SHE READ (Astra audit 2026-09-11, finding 7).
///
/// The takeaway's source ids used to be read off the workspace AFTER the model
/// returned, so a node that settled while she was thinking became "evidence"
/// for a reflection that never saw it, and a node she DID read could be gone.
/// The prompt's set is frozen on the request at plan time and the takeaway
/// carries exactly that — plus, for a dream reflection, the diary entry's id.
@Test func reflectionTakeawayCarriesTheEvidenceFrozenAtPlanTime() async throws {
    let clock = TestClock(Date(timeIntervalSince1970: 1_000))
    let substrate = makeSubstrate(
        clock: clock,
        configuration: CognitiveConfiguration(
            enabled: true,
            workspaceEnabled: true,
            capsuleInjectionEnabled: true,
            thoughtSeedsEnabled: true,
            reflectiveCallsEnabled: true,
            dailyReflectionCallBudget: 3
        )
    )

    await substrate.ingest(event(id: "read", subjectID: "read", importance: 1, occurredAt: clock.now()))
    guard case .admitted(let request) = await substrate.planReflectionChecked(
        reason: "reflect on the dream:dreamCompleted",
        demand: .requested,
        materialExcerpt: "A long corridor of unopened doors.",
        materialProvenance: "dream_diary/2026-09-11.md"
    ) else {
        Issue.record("reflection was refused")
        return
    }
    let frozen = request.sourceNodeIds
    #expect(!frozen.isEmpty, "the prompt's workspace evidence must be frozen on the request")
    // It is the PROMPT's own capsule provenance, not a second workspace read:
    // recompiling the same capsule request against the unchanged field yields
    // the identical set.
    let promptCapsule = await substrate.compileCapsule(CognitiveCapsuleRequest(
        surface: "reflection",
        userMessage: "reflect on the dream:dreamCompleted",
        mode: .inspectOnly,
        maximumCharacters: 800
    ))
    #expect(Set(frozen) == Set(promptCapsule.provenanceNodeIds))
    #expect(request.materialProvenance == "dream_diary/2026-09-11.md")

    // New material settles while the model is thinking. It never fed the
    // prompt, so it must NOT end up as the takeaway's evidence.
    clock.advance(30)
    await substrate.ingest(event(id: "later", subjectID: "later", importance: 1, occurredAt: clock.now()))

    _ = try #require(await substrate.recordReflectionResult(
        request: request,
        resultSummary: "Reading the dream honestly: the unopened doors are the ones I keep deferring.",
        provider: request.provider
    ))
    let seed = try #require(await substrate.thoughtSeedSnapshot().first { $0.kind == .reflectionTakeaway })
    let dreamProvenance = CognitiveSubstrate.provenanceNodeId(for: "dream_diary/2026-09-11.md")
    #expect(Set(seed.sourceNodeIds) == Set(frozen + [dreamProvenance]))
}

@Test func reflectionTakeawayCapsuleLineUsesCompleteThoughtNotRawPrefixCutoff() async throws {
    let clock = TestClock(Date(timeIntervalSince1970: 1_000))
    let substrate = makeSubstrate(
        clock: clock,
        configuration: CognitiveConfiguration(
            enabled: true,
            workspaceEnabled: true,
            capsuleInjectionEnabled: true,
            thoughtSeedsEnabled: true,
            reflectiveCallsEnabled: true,
            dailyReflectionCallBudget: 3
        )
    )

    await substrate.ingest(event(id: "focus", subjectID: "focus", importance: 1, occurredAt: clock.now()))
    let request = try #require(await substrate.planReflection(reason: "capture reflection takeaway"))
    _ = try #require(await substrate.recordReflectionResult(
        request: request,
        resultSummary: "Reading the state honestly: the capsule is warm, populated, low-tension. CurrentFocus threads all point the same direction - quiet warmth under light task pressure, the capsule itself confirmed live and ready.",
        provider: request.provider
    ))

    let seed = try #require(await substrate.thoughtSeedSnapshot().first { $0.kind == .reflectionTakeaway })
    #expect(seed.text == "Reflection takeaway: Reading the state honestly: the capsule is warm, populated, low-tension.")

    let capsule = await substrate.compileCapsule(CognitiveCapsuleRequest(
        surface: "telegram",
        userMessage: "continue",
        mode: .inspectOnly,
        maximumCharacters: 900
    ))
    let reflectionLine = try #require(
        capsule.combined
            .split(separator: "\n")
            .map(String.init)
            .first { $0.hasPrefix("- Inner:") }
    )
    #expect(reflectionLine.contains("warm, connected, low-tension."))
    #expect(reflectionLine.contains("low-tension."))
    #expect(!reflectionLine.contains("Reflection takeaway"))
    #expect(!reflectionLine.contains("capsule"))
    #expect(!reflectionLine.contains("[kind:"))
    #expect(!reflectionLine.contains("CurrentFocus"))
    #expect(!reflectionLine.contains("task pres"))
}

@Test func reflectionCancellationRecordsReceiptWithoutProposalsAndConsumesBudget() async throws {
    let clock = TestClock(Date(timeIntervalSince1970: 1_000))
    let substrate = makeSubstrate(
        clock: clock,
        configuration: CognitiveConfiguration(
            enabled: true,
            capsuleInjectionEnabled: true,
            reflectiveCallsEnabled: true,
            dailyReflectionCallBudget: 1
        )
    )

    let request = try #require(await substrate.planReflection(reason: "cancel reflection"))
    let receipt = try #require(await substrate.recordReflectionResult(
        request: request,
        resultSummary: "Proposal: this cancelled result should not create a proposal.",
        provider: request.provider,
        cancelled: true
    ))

    #expect(receipt.cancelled)
    #expect(receipt.proposalIds.isEmpty)
    #expect(receipt.estimatedCostUnits > 0)
    #expect(receipt.proposalYieldScore == 0)
    #expect(await substrate.schemaProposalSnapshot().isEmpty)
    #expect(await substrate.planReflection(reason: "blocked after cancellation") == nil)
}

@Test func reflectionPlanningReservesOneDailySlotAcrossReentrantAndConfigurationPaths() async throws {
    let clock = TestClock(Date(timeIntervalSince1970: 1_000))
    let configuration = CognitiveConfiguration(
        enabled: true,
        capsuleInjectionEnabled: true,
        reflectiveCallsEnabled: true,
        dailyReflectionCallBudget: 2
    )
    let substrate = makeSubstrate(clock: clock, configuration: configuration)

    let first = try #require(await substrate.planReflection(reason: "manual reflection"))
    #expect(await substrate.planReflection(reason: "scheduled reflection") == nil)

    // Settings refresh must not erase the reservation and allow a duplicate call.
    var disabledDuringFlight = configuration
    disabledDuringFlight.reflectiveCallsEnabled = false
    await substrate.configure(disabledDuringFlight)
    #expect(await substrate.planReflection(reason: "after configuration refresh") == nil)

    _ = try #require(await substrate.recordReflectionResult(
        request: first,
        resultSummary: "The reflection completed.",
        provider: first.provider
    ))
    await substrate.configure(configuration)

    // The transient owner released, while the durable receipt consumes one of two
    // slots. Exactly one further reflection can now be planned.
    #expect(await substrate.planReflection(reason: "second budget slot") != nil)
}

@Test func expiredReflectionCannotReleaseANewerReservation() async throws {
    let clock = TestClock(Date(timeIntervalSince1970: 1_000))
    let substrate = makeSubstrate(
        clock: clock,
        configuration: CognitiveConfiguration(
            enabled: true,
            capsuleInjectionEnabled: true,
            reflectiveCallsEnabled: true,
            dailyReflectionCallBudget: 2
        )
    )

    let stale = try #require(await substrate.planReflection(reason: "stale request"))
    clock.advance(11 * 60)
    let current = try #require(await substrate.planReflection(reason: "replacement request"))

    #expect(await substrate.recordReflectionResult(
        request: stale,
        resultSummary: "This late result must be rejected.",
        provider: stale.provider
    ) == nil)
    #expect(await substrate.planReflection(reason: "must remain reserved") == nil)
    let currentReceipt = try #require(await substrate.recordReflectionResult(
        request: current,
        resultSummary: "The current request completed.",
        provider: current.provider
    ))
    var forgedReceipt = currentReceipt
    forgedReceipt.id = UUID(uuidString: "DEADBEEF-0000-0000-0000-000000000001")!
    await #expect(throws: CognitivePersistenceError.self) {
        try await substrate.persistReflectionResultChecked(forgedReceipt)
    }
}

@Test func unreservedReflectionResultCannotBypassPlannerBudget() async throws {
    let clock = TestClock(Date(timeIntervalSince1970: 1_000))
    let substrate = makeSubstrate(
        clock: clock,
        configuration: CognitiveConfiguration(
            enabled: true,
            capsuleInjectionEnabled: true,
            reflectiveCallsEnabled: true,
            dailyReflectionCallBudget: 1
        )
    )
    let synthetic = CognitiveReflectionRequest(
        reason: "unreserved",
        prompt: "must not integrate",
        requestedAt: clock.now()
    )

    #expect(await substrate.recordReflectionResult(
        request: synthetic,
        resultSummary: "view: this must not become a standing view",
        provider: synthetic.provider
    ) == nil)
    #expect(await substrate.reflectionReceiptSnapshot().isEmpty)
    #expect(await substrate.standingViewSnapshot().isEmpty)
}

/// Audit round 2, R1: `recordReflectionResult` bounded the result to 600 chars
/// and THEN parsed proposals from the bounded text — but the prompt puts the
/// tagged proposal lines LAST, so any reflection long enough to propose was
/// exactly the one that got clipped (live proof: the 2026-07-12 standing-view
/// candidate stored truncated mid-word). Proposals must parse from the FULL
/// result while the stored summary stays bounded.
@Test func reflectionProposalsSurviveTheReceiptBound() async throws {
    let clock = TestClock(Date(timeIntervalSince1970: 1_000))
    let substrate = makeSubstrate(
        clock: clock,
        configuration: CognitiveConfiguration(
            enabled: true,
            workspaceEnabled: true,
            capsuleInjectionEnabled: true,
            reflectiveCallsEnabled: true,
            dailyReflectionCallBudget: 3
        )
    )
    await substrate.ingest(event(id: "one", subjectID: "one", importance: 1, occurredAt: clock.now()))
    await substrate.ingest(event(id: "two", subjectID: "two", importance: 0.8, occurredAt: clock.now()))
    let request = try #require(await substrate.planReflection(reason: "long reflection"))

    // A result well past the 600-char receipt bound, proposal line at the end.
    let longBody = String(repeating: "The state reads honest and warm today. ", count: 20)
    let receipt = try #require(await substrate.recordReflectionResult(
        request: request,
        resultSummary: longBody + "\nview: Quiet-pass discipline matters when nothing has earned a change.",
        provider: request.provider
    ))

    #expect(receipt.resultSummary.count <= 600, "stored summary stays bounded")
    #expect(receipt.proposalIds.count == 1, "the tail proposal must survive the bound")
    let views = await substrate.standingViewSnapshot()
    #expect(views.contains { $0.body.contains("Quiet-pass discipline") })
}
