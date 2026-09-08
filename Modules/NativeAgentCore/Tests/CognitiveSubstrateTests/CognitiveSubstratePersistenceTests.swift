import Foundation
import Testing
import PersistenceCore
@testable import CognitiveSubstrate

@Test func persistenceRestoresBoundedNodesFromSQLite() async throws {
    let clock = TestClock(Date(timeIntervalSince1970: 1_000))
    let root = try tempDataRoot("restore")
    let config = CognitiveConfiguration(
        enabled: true,
        persistenceEnabled: true,
        maximumActiveNodes: 4,
        defaultDecayHalfLife: 1_000
    )
    let store = try CognitiveSQLiteStore(dataRoot: root)
    let writer = makeSubstrate(clock: clock, configuration: config, store: store)

    await writer.ingest(event(id: "persisted", subjectID: "restore-me", importance: 1, occurredAt: clock.now()))
    try await writer.persistSnapshot()

    let reader = makeSubstrate(clock: clock, configuration: config, store: try CognitiveSQLiteStore(dataRoot: root))
    try await reader.restorePersistentState()
    let restored = await reader.snapshot()

    #expect(restored.nodeCount == 1)
    #expect(restored.nodes.first?.subjectReference.id == "restore-me")
}

@Test func persistenceRestoresReflectionReceiptsAndThoughtSeedsFromSQLite() async throws {
    let clock = TestClock(Date(timeIntervalSince1970: 1_000))
    let root = try tempDataRoot("restore-reflection")
    let config = CognitiveConfiguration(
        enabled: true,
        persistenceEnabled: true,
        workspaceEnabled: true,
        capsuleInjectionEnabled: true,
        thoughtSeedsEnabled: true,
        reflectiveCallsEnabled: true,
        dailyReflectionCallBudget: 2
    )
    let writer = makeSubstrate(
        clock: clock,
        configuration: config,
        store: try CognitiveSQLiteStore(dataRoot: root)
    )

    await writer.ingest(event(id: "persisted", subjectID: "restore-reflection", importance: 1, occurredAt: clock.now()))
    let request = try #require(await writer.planReflection(reason: "persist reflection"))
    let persistedReceipt = try #require(await writer.recordReflectionResult(
        request: request,
        resultSummary: "Reading the capsule honestly: keep the private takeaway available after restart.",
        provider: request.provider
    ))
    try await writer.persistReflectionResultChecked(persistedReceipt)

    let reader = makeSubstrate(
        clock: clock,
        configuration: config,
        store: try CognitiveSQLiteStore(dataRoot: root)
    )
    try await reader.restorePersistentState()

    #expect(await reader.reflectionReceiptSnapshot().count == 1)
    #expect(await reader.thoughtSeedSnapshot().contains { seed in
        seed.kind == .reflectionTakeaway
            && seed.text.contains("private takeaway available after restart")
    })
    let secondRequest = try #require(await reader.planReflection(reason: "second pass still allowed"))
    _ = try #require(await reader.recordReflectionResult(
        request: secondRequest,
        resultSummary: "Reading the capsule honestly: this consumes the second budget slot.",
        provider: secondRequest.provider
    ))
    #expect(await reader.planReflection(reason: "budget exhausted after restore") == nil)
}

@Test func persistenceRestoresFullCognitiveArtifactStateFromSQLite() async throws {
    let clock = TestClock(Date(timeIntervalSince1970: 1_000))
    let root = try tempDataRoot("restore-full-artifacts")
    let config = CognitiveConfiguration(
        enabled: true,
        persistenceEnabled: true,
        workspaceEnabled: true,
        capsuleInjectionEnabled: true,
        affectEnabled: true,
        thoughtSeedsEnabled: true,
        replayEnabled: true,
        reflectiveCallsEnabled: true,
        observatoryEnabled: true,
        dailyReflectionCallBudget: 4
    )
    let writer = makeSubstrate(
        clock: clock,
        configuration: config,
        store: try CognitiveSQLiteStore(dataRoot: root)
    )

    let first = event(id: "artifact-evidence-a", subjectID: "artifact-a", importance: 1, occurredAt: clock.now())
    let second = event(id: "artifact-evidence-b", subjectID: "artifact-b", importance: 1, occurredAt: clock.now())
    await writer.ingest(first)
    await writer.ingest(second)
    let writerSnapshot = await writer.snapshot()
    let evidenceIds = writerSnapshot.nodes.map(\.id)
    await writer.updateAffect(from: CognitiveEvent(
        id: "warm-user",
        kind: .userMessageReceived,
        subject: CognitiveSubjectReference(type: "chat.session", id: "restore-artifacts"),
        sourceClass: .userStated,
        occurredAt: clock.now(),
        summary: "User is warm and excited about Agent continuity.",
        importance: 1
    ))
    _ = try #require(await writer.recordEpisode(
        title: "Continuity episode",
        summary: "Agent noticed continuity should survive restart.",
        evidenceNodeIds: evidenceIds
    ))
    _ = await writer.integrateReplay(CognitiveReplayIntegrationInput(
        reason: "restore full artifacts",
        dreamEntries: [
            CognitiveDreamReplayReference(
                id: "dream-restore",
                date: "2026-06-23",
                filename: "2026-06-23.md",
                content: "Dream replay about carrying continuity across restarts."
            )
        ],
        remProposals: [
            CognitiveREMProposalReference(
                id: "rem-restore",
                target: "SOUL.md",
                text: "Continuity must survive app relaunch before it can be trusted.",
                evidenceDates: ["2026-06-23"],
                status: "proposed",
                confidence: 0.77,
                createdAt: "2026-06-23T00:00:00Z"
            )
        ]
    ))
    _ = try #require(await writer.runResearchExperiment(kind: CognitiveExperimentKind.continuity, seed: "restore"))

    let reader = makeSubstrate(
        clock: clock,
        configuration: config,
        store: try CognitiveSQLiteStore(dataRoot: root)
    )
    try await reader.restorePersistentState()

    #expect(await reader.affectSnapshot().socialWarmth > 0)
    #expect(await reader.episodeSnapshot().contains { $0.title == "Continuity episode" })
    #expect(await reader.schemaProposalSnapshot().contains { $0.body.contains("Continuity must survive app relaunch") })
    #expect(await reader.developmentalTimelineSnapshot().contains { $0.title.contains("Dream replay") })
    #expect(await reader.researchExperimentSnapshot().contains { $0.kind == CognitiveExperimentKind.continuity && $0.seed == "restore" })

    let capsule = await reader.compileCapsule(CognitiveCapsuleRequest(
        surface: "telegram",
        userMessage: "status?",
        sessionId: "restore-artifacts",
        mode: .inspectOnly,
        maximumCharacters: 1_200
    ))
    // Feeling/Focus/Voice lines are gone (2026-07-08): the capsule now carries a
    // single felt-fingerprint line under the "How you feel:" header instead.
    #expect(capsule.combined.contains("How you feel:"))
    #expect(!capsule.dynamicContext.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    // Predictions no longer surface in the subconscious capsule — task-tracking is the Desk's job.
    #expect(!capsule.combined.contains("Expect:"))
}

@Test func retiredIdentityProposalRowsStayPreservedAndDoNotJoinRuntimeRestore() async throws {
    let clock = TestClock(Date(timeIntervalSince1970: 1_000))
    let root = try tempDataRoot("retired-identity-proposal-compatibility")
    let legacyID = UUID(uuidString: "00000000-0000-0000-0000-000000000171")!
    let legacyPayload: JSONValue = .object([
        "id": .string(legacyID.uuidString),
        "claim": .string("Legacy review-only identity hypothesis"),
        "evidenceCount": .int(2),
        "status": .string("proposed"),
        "createdAt": .double(clock.now().timeIntervalSince1970),
        "evidenceNodeIds": .array([]),
    ])
    let writer = try CognitiveSQLiteStore(dataRoot: root)
    try await writer.upsertArtifact(
        kind: "identity_proposal",
        id: legacyID,
        status: "proposed",
        score: 0.4,
        payload: legacyPayload,
        at: clock.now()
    )
    let timelineID = UUID(uuidString: "00000000-0000-0000-0000-000000000172")!
    try await writer.upsertArtifact(
        kind: "developmental_timeline",
        id: timelineID,
        status: "recorded",
        score: 0.4,
        payload: .object([
            "id": .string(timelineID.uuidString),
            "kind": .string("identityProposal"),
            "title": .string("Legacy identity proposal"),
            "summary": .string("Historical review event"),
            "occurredAt": .double(clock.now().timeIntervalSince1970),
            "lineageId": .string("identity:\(legacyID.uuidString)"),
        ]),
        at: clock.now()
    )

    // Opening and restoring the current runtime must neither reinterpret nor
    // delete the retired row. It remains available to migration/backup tools as
    // the exact legacy JSON while consuming no resident cognition state.
    let reopened = try CognitiveSQLiteStore(dataRoot: root)
    let substrate = makeSubstrate(
        clock: clock,
        configuration: CognitiveConfiguration(
            enabled: true,
            persistenceEnabled: true,
            observatoryEnabled: true
        ),
        store: reopened
    )
    try await substrate.restorePersistentState()

    #expect(try await reopened.loadArtifacts(kindPrefix: "identity_proposal") == [legacyPayload])
    #expect(await substrate.developmentalTimelineSnapshot().contains {
        $0.id == timelineID && $0.kind == .identityProposal
    })
    let export = await substrate.exportResearchTrace()
    guard case .object(let rootObject) = export,
          case .object(let actualState)? = rootObject["actualState"] else {
        Issue.record("research export did not contain actualState")
        return
    }
    #expect(actualState["identityProposalCount"] == nil)
}

@Test func persistenceReconcilesFlatAffectFromRecentWarmConversation() async throws {
    let clock = TestClock(Date(timeIntervalSince1970: 1_000))
    let root = try tempDataRoot("restore-affect-warmth")
    let store = try CognitiveSQLiteStore(dataRoot: root)
    let config = CognitiveConfiguration(
        enabled: true,
        persistenceEnabled: true,
        workspaceEnabled: true,
        capsuleInjectionEnabled: true,
        affectEnabled: true
    )
    let writer = makeSubstrate(
        clock: clock,
        configuration: config,
        store: store
    )

    await writer.ingest(CognitiveEvent(
        id: "warm-assistant-turn",
        kind: .assistantTurnCompleted,
        subject: CognitiveSubjectReference(type: "chat.session", id: "restore-warmth"),
        sourceClass: .selfReported,
        occurredAt: clock.now(),
        summary: "Got it, love. Short, sweet, warm with User while holding the details back.",
        importance: 1,
        metadata: ["sessionId": .string("restore-warmth")]
    ))

    clock.advance(1)
    try await store.upsertArtifact(
        kind: "affect",
        id: UUID(uuidString: "00000000-0000-0000-0000-000000000101")!,
        status: "current",
        score: 0,
        payload: .object([
            "arousal": .double(0),
            "uncertainty": .double(0),
            "taskPressure": .double(0),
            "socialWarmth": .double(0),
            "updatedAt": .double(clock.now().timeIntervalSince1970),
        ]),
        at: clock.now()
    )

    let reader = makeSubstrate(
        clock: clock,
        configuration: config,
        store: try CognitiveSQLiteStore(dataRoot: root)
    )
    try await reader.restorePersistentState()

    #expect(await reader.affectSnapshot().socialWarmth >= 0.38)
    let capsule = await reader.compileCapsule(CognitiveCapsuleRequest(
        surface: "telegram",
        userMessage: "hey",
        sessionId: "restore-warmth",
        mode: .inspectOnly,
        maximumCharacters: 1_200
    ))
    // The old "warm and connected with User" Feeling-line phrase is gone
    // (2026-07-08): the socialWarmth assertion above is the load-bearing proof
    // that reconciliation worked; this just confirms the capsule still compiles
    // with real felt content once restored.
    #expect(capsule.combined.contains("How you feel:"))
    #expect(!capsule.dynamicContext.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
}

@Test func sqliteSchemaMarkersAndPruneReceiptsAreTypedAndBounded() async throws {
    let root = try tempDataRoot("schema-prune")
    let store = try CognitiveSQLiteStore(dataRoot: root)
    let markers = try await store.schemaMarkers()
    #expect(markers["schema_version"] == "2")

    let now = Date(timeIntervalSince1970: 1_000)
    for index in 0..<5 {
        try await store.upsertArtifact(
            kind: "test",
            id: UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", index))!,
            status: "open",
            score: Double(index) / 10,
            payload: .object(["index": .int(Int64(index))]),
            at: now.addingTimeInterval(Double(index))
        )
    }
    let result = try await store.prune(maxNodes: 10, maxArtifacts: 2)
    let receipts = try await store.loadReceipts(kindPrefix: "prune")

    #expect(result.deletedArtifacts == 3)
    #expect(receipts.count == 1)
    if case .object(let payload)? = receipts.first {
        #expect(payload["deletedArtifacts"] == .int(3))
    } else {
        #expect(Bool(false))
    }
}

@Test func importantOpenConcernPersistsAcrossRestore() async throws {
    let clock = TestClock(Date(timeIntervalSince1970: 1_000))
    let root = try tempDataRoot("open-concern")
    let config = CognitiveConfiguration(
        enabled: true,
        persistenceEnabled: true,
        workspaceEnabled: true,
        maximumActiveNodes: 4,
        defaultDecayHalfLife: 10_000
    )
    let store = try CognitiveSQLiteStore(dataRoot: root)
    let writer = makeSubstrate(clock: clock, configuration: config, store: store)

    await writer.ingest(event(id: "open", subjectID: "open-concern", importance: 1, occurredAt: clock.now()))
    try await writer.persistSnapshot()

    let reader = makeSubstrate(clock: clock, configuration: config, store: try CognitiveSQLiteStore(dataRoot: root))
    try await reader.restorePersistentState()
    let workspace = await reader.workspaceSnapshot()

    #expect(workspace.items.contains { $0.node.subjectReference.id == "open-concern" })
}

@Test func thoughtSeedDecayDeletionDoesNotResurrectAfterRestart() async throws {
    let root = try tempDataRoot("thought-seed-decay-transaction")
    let clock = TestClock(Date(timeIntervalSince1970: 1_000))
    let configuration = CognitiveConfiguration(
        enabled: true,
        persistenceEnabled: true,
        thoughtSeedsEnabled: true,
        maximumThoughtSeeds: 4
    )
    let writerStore = try CognitiveSQLiteStore(dataRoot: root)
    let writer = makeSubstrate(clock: clock, configuration: configuration, store: writerStore)
    _ = try #require(await writer.addThoughtSeed(
        kind: .followUp,
        text: "This seed should decay away",
        priority: 0.4
    ))

    clock.advance(4 * 24 * 60 * 60)
    await writer.decayThoughtSeeds()
    #expect(await writer.thoughtSeedSnapshot().isEmpty)

    let readerStore = try CognitiveSQLiteStore(dataRoot: root)
    let reader = makeSubstrate(clock: clock, configuration: configuration, store: readerStore)
    try await reader.restorePersistentState()
    #expect(await reader.thoughtSeedSnapshot().isEmpty)
    let transitions = try await readerStore.loadReceiptRecords(
        kindPrefix: "artifact.family_transition",
        limit: 10
    )
    #expect(transitions.contains { record in
        guard case .object(let payload) = record.payload else { return false }
        return payload["family"] == .string("thought_seed")
            && payload["lifecycleRemoved"] == .int(1)
    })
}

@Test func thoughtSeedCapacityEvictionDoesNotResurrectAfterRestart() async throws {
    let root = try tempDataRoot("thought-seed-cap-transaction")
    let clock = TestClock(Date(timeIntervalSince1970: 2_000))
    let configuration = CognitiveConfiguration(
        enabled: true,
        persistenceEnabled: true,
        thoughtSeedsEnabled: true,
        maximumThoughtSeeds: 1
    )
    let writerStore = try CognitiveSQLiteStore(dataRoot: root)
    let writer = makeSubstrate(clock: clock, configuration: configuration, store: writerStore)
    _ = try #require(await writer.addThoughtSeed(kind: .followUp, text: "lower", priority: 0.4))
    _ = try #require(await writer.addThoughtSeed(kind: .anomaly, text: "higher", priority: 0.9))
    #expect(await writer.thoughtSeedSnapshot().map(\.text) == ["higher"])

    let readerStore = try CognitiveSQLiteStore(dataRoot: root)
    let reader = makeSubstrate(clock: clock, configuration: configuration, store: readerStore)
    try await reader.restorePersistentState()
    #expect(await reader.thoughtSeedSnapshot().map(\.text) == ["higher"])
    #expect(try await readerStore.loadArtifacts(kindPrefix: "thought_seed", limit: 10).count == 1)
}

// R8c review fix (2026-07-01): legacy neglected-commitment thought seeds must be
// DRAINED at store open — their enum case is gone, so restore skips them, but
// they'd otherwise crowd surviving reflection-takeaway seeds out of the bounded
// newest-N restore window on legacy databases.
@Test func drainRemovesLegacyNeglectedCommitmentSeedsButKeepsTakeaways() async throws {
    let root = try tempDataRoot("drain-seeds")
    let store = try CognitiveSQLiteStore(dataRoot: root)
    let now = Date(timeIntervalSince1970: 2_000)

    let takeawayId = UUID()
    try await store.upsertArtifact(
        kind: "thought_seed", id: takeawayId, status: "open", score: 0.9,
        payload: .object([
            "id": .string(takeawayId.uuidString),
            "kind": .string("reflectionTakeaway"),
            "text": .string("I've formed a view worth keeping."),
            "priority": .double(0.9),
            "createdAt": .double(2_000),
            "lastUpdatedAt": .double(2_000),
        ]),
        at: now
    )
    let legacyId = UUID()
    try await store.upsertArtifact(
        kind: "thought_seed", id: legacyId, status: "open", score: 0.8,
        payload: .object([
            "id": .string(legacyId.uuidString),
            "kind": .string("neglectedCommitment"),
            "text": .string("I'll follow up on the retired tracker item."),
            "priority": .double(0.8),
            "createdAt": .double(2_000),
            "lastUpdatedAt": .double(2_000),
        ]),
        at: now
    )

    // Re-open the same DB: the open-time drain must remove ONLY the legacy seed.
    let reopened = try CognitiveSQLiteStore(dataRoot: root)
    let seeds = try await reopened.loadArtifacts(kindPrefix: "thought_seed", limit: 100)
    let kinds = seeds.compactMap { payload -> String? in
        guard case .object(let obj) = payload, case .string(let k)? = obj["kind"] else { return nil }
        return k
    }
    #expect(kinds == ["reflectionTakeaway"])
}

@Test func drainRemovesRetiredCueArtifactsReceiptsAndNodeMetadata() async throws {
    let root = try tempDataRoot("drain-cue-authoring")
    let store = try CognitiveSQLiteStore(dataRoot: root)
    let now = Date(timeIntervalSince1970: 2_000)
    let nodeID = UUID()
    try await store.saveNodes([CognitiveNode(
        id: nodeID,
        kind: .conversationFocus,
        subjectReference: CognitiveSubjectReference(type: "chat_turn", id: "legacy-cue"),
        activation: 0.7,
        salience: 0.6,
        confidence: 0.8,
        sourceClass: .userStated,
        createdAt: now,
        lastActivatedAt: now,
        decayHalfLife: 3_600,
        summary: "A real remembered moment.",
        metadata: [
            "sessionId": .string("session"),
            "authored_cue": .string("legacy private cue"),
            "authored_cue_hash": .string("deadbeef"),
            "authored_cue_at": .string("2026-07-01T00:00:00Z"),
        ]
    )], at: now)
    let artifactID = UUID()
    try await store.upsertArtifact(
        kind: "cue_authoring_receipt",
        id: artifactID,
        status: "completed",
        score: 0.5,
        payload: .object(["id": .string(artifactID.uuidString)]),
        at: now
    )
    try await store.appendReceipt(
        kind: "cue_authoring.completed",
        payload: .object(["status": .string("legacy")]),
        at: now
    )

    let reopened = try CognitiveSQLiteStore(dataRoot: root)
    #expect(try await reopened.loadArtifacts(kindPrefix: "cue_authoring", limit: 10).isEmpty)
    #expect(try await reopened.loadReceipts(kindPrefix: "cue_authoring", limit: 10).isEmpty)
    let nodes = try await reopened.loadNodes()
    let restored = try #require(nodes.first(where: { $0.id == nodeID }))
    #expect(restored.metadata["sessionId"] == .string("session"))
    #expect(restored.metadata["authored_cue"] == nil)
    #expect(restored.metadata["authored_cue_hash"] == nil)
    #expect(restored.metadata["authored_cue_at"] == nil)
}
