import Foundation
import Testing
import PersistenceCore
@testable import CognitiveSubstrate

private final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date

    init(_ current: Date) {
        self.current = current
    }

    func now() -> Date {
        lock.lock()
        defer { lock.unlock() }
        return current
    }

    func advance(_ seconds: TimeInterval) {
        lock.lock()
        current = current.addingTimeInterval(seconds)
        lock.unlock()
    }
}

private final class TestUUIDs: @unchecked Sendable {
    private let lock = NSLock()
    private var index = 0

    func next() -> UUID {
        lock.lock()
        defer {
            index += 1
            lock.unlock()
        }
        return UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", index))!
    }
}

private struct FakeCognitiveMemoryReader: CognitiveMemoryReading {
    var hits: [CognitiveExternalReference]

    func recallMemory(query: String, limit: Int) async throws -> [CognitiveExternalReference] {
        Array(hits.prefix(limit))
    }
}

private struct FakeCognitiveGraphReader: CognitiveKnowledgeGraphReading {
    var hits: [CognitiveExternalReference]

    func searchKnowledgeGraph(query: String, limit: Int) async throws -> [CognitiveExternalReference] {
        Array(hits.prefix(limit))
    }
}

private func makeSubstrate(
    clock: TestClock,
    uuids: TestUUIDs = TestUUIDs(),
    configuration: CognitiveConfiguration = CognitiveConfiguration(
        enabled: true,
        maximumActiveNodes: 256,
        defaultDecayHalfLife: 100
    ),
    store: CognitiveSQLiteStore? = nil
) -> CognitiveSubstrate {
    CognitiveSubstrate(
        configuration: configuration,
        dependencies: CognitiveSubstrateDependencies(
            now: { clock.now() },
            makeUUID: { uuids.next() },
            // Configured user name flows into the capsule/reflection cues (no
            // hardcoded "User" in source). These tests assert "…with User" etc.,
            // which now verifies the name is threaded end-to-end.
            userName: { "User" }
        ),
        store: store
    )
}

private func tempDataRoot(_ label: String) throws -> URL {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("nativeagent-cognitive-\(label)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}

private func event(
    id: String,
    kind: CognitiveEventKind = .userMessageReceived,
    subjectID: String,
    importance: Double = 0.5,
    occurredAt: Date,
    metadata: [String: JSONValue] = [:]
) -> CognitiveEvent {
    CognitiveEvent(
        id: id,
        kind: kind,
        subject: CognitiveSubjectReference(type: "topic", id: subjectID, label: subjectID),
        sourceClass: kind == .toolSucceeded ? .observed : .userStated,
        occurredAt: occurredAt,
        summary: "event \(id)",
        importance: importance,
        metadata: metadata
    )
}

@Test func disabledConfigurationProducesNoObservableState() async throws {
    let clock = TestClock(Date(timeIntervalSince1970: 1_000))
    let substrate = makeSubstrate(clock: clock, configuration: .disabled)

    await substrate.ingest(event(id: "e1", subjectID: "nativeagent", occurredAt: clock.now()))
    let snapshot = await substrate.snapshot()

    #expect(snapshot.enabled == false)
    #expect(snapshot.nodes.isEmpty)
}

@Test func ingestionCreatesExpectedNode() async throws {
    let clock = TestClock(Date(timeIntervalSince1970: 1_000))
    let substrate = makeSubstrate(clock: clock)

    await substrate.ingest(event(id: "e1", subjectID: "substrate", importance: 0.75, occurredAt: clock.now()))
    let snapshot = await substrate.snapshot()
    let node = try #require(snapshot.nodes.first)

    #expect(snapshot.nodeCount == 1)
    #expect(node.kind == .conversationFocus)
    #expect(node.subjectReference.id == "substrate")
    #expect(node.activation > 0)
    #expect(node.activation <= 1)
}

@Test func frozenReadSettlesCopiedFieldWithoutMutatingLiveCognition() async throws {
    let now = Date(timeIntervalSince1970: 1_500)
    let clock = TestClock(now)
    let substrate = makeSubstrate(clock: clock)
    await substrate.ingest(event(
        id: "frozen-read-event",
        subjectID: "frozen-read",
        importance: 0.9,
        occurredAt: now
    ))

    let revisionBefore = await substrate.frozenRevisionToken()
    let first = await substrate.frozenRead(at: now)
    _ = await substrate.frozenRead(at: now.addingTimeInterval(24 * 60 * 60))
    let revisionAfter = await substrate.frozenRevisionToken()
    let repeated = await substrate.frozenRead(at: now)

    #expect(revisionAfter == revisionBefore)
    #expect(repeated == first)
}

@Test func duplicateEventDoesNotMultiplyState() async throws {
    let clock = TestClock(Date(timeIntervalSince1970: 1_000))
    let substrate = makeSubstrate(clock: clock)
    let first = event(id: "same-event", subjectID: "same-topic", importance: 1, occurredAt: clock.now())

    await substrate.ingest(first)
    let before = await substrate.snapshot()
    let affectBefore = await substrate.affectSnapshot()
    let frozenBefore = await substrate.frozenRead(at: clock.now())
    let revisionBefore = await substrate.frozenRevisionToken()
    await substrate.ingest(first)
    let after = await substrate.snapshot()
    let affectAfter = await substrate.affectSnapshot()
    let frozenAfter = await substrate.frozenRead(at: clock.now())

    #expect(before.nodes.count == 1)
    #expect(after.nodes.count == 1)
    #expect(after.nodes.first?.activation == before.nodes.first?.activation)
    #expect(affectAfter == affectBefore)
    #expect(frozenAfter == frozenBefore)
    #expect(await substrate.frozenRevisionToken() == revisionBefore)
}

@Test func activationRemainsWithinBounds() async throws {
    let clock = TestClock(Date(timeIntervalSince1970: 1_000))
    let substrate = makeSubstrate(clock: clock)

    for idx in 0..<20 {
        await substrate.ingest(event(id: "event-\(idx)", subjectID: "same-topic", importance: 1, occurredAt: clock.now()))
    }
    let node = try #require(await substrate.snapshot().nodes.first)

    #expect(node.activation >= 0)
    #expect(node.activation <= 1)
    #expect(node.salience >= 0)
    #expect(node.salience <= 1)
}

@Test func decayIsDeterministicWithInjectedClock() async throws {
    let clock = TestClock(Date(timeIntervalSince1970: 1_000))
    let substrate = makeSubstrate(clock: clock)

    await substrate.ingest(event(id: "e1", subjectID: "decays", importance: 1, occurredAt: clock.now()))
    clock.advance(100)
    let node = try #require(await substrate.snapshot().nodes.first)

    #expect(abs(node.activation - 0.5) < 0.000_001)
}

@Test func repeatedSnapshotAtSameTimeDoesNotApplyDecayTwice() async throws {
    let clock = TestClock(Date(timeIntervalSince1970: 1_000))
    let substrate = makeSubstrate(clock: clock)

    await substrate.ingest(event(id: "e1", subjectID: "stable", importance: 1, occurredAt: clock.now()))
    clock.advance(100)
    let first = try #require(await substrate.snapshot().nodes.first)
    let second = try #require(await substrate.snapshot().nodes.first)

    #expect(abs(first.activation - 0.5) < 0.000_001)
    #expect(second.activation == first.activation)

    clock.advance(100)
    let third = try #require(await substrate.snapshot().nodes.first)
    #expect(abs(third.activation - 0.25) < 0.000_001)
}

@Test func evictionAtCapacityIsDeterministic() async throws {
    let clock = TestClock(Date(timeIntervalSince1970: 1_000))
    let substrate = makeSubstrate(
        clock: clock,
        configuration: CognitiveConfiguration(enabled: true, maximumActiveNodes: 2, defaultDecayHalfLife: 1_000)
    )

    await substrate.ingest(event(id: "low", subjectID: "low", importance: 0.1, occurredAt: clock.now()))
    await substrate.ingest(event(id: "high", subjectID: "high", importance: 1.0, occurredAt: clock.now()))
    await substrate.ingest(event(id: "mid", subjectID: "mid", importance: 0.5, occurredAt: clock.now()))
    let ids = await substrate.snapshot().nodes.map(\.subjectReference.id)

    #expect(ids == ["high", "mid"])
}

@Test func snapshotOrderingIsStable() async throws {
    let clock = TestClock(Date(timeIntervalSince1970: 1_000))
    let substrate = makeSubstrate(clock: clock)

    await substrate.ingest(event(id: "low", subjectID: "low", importance: 0.1, occurredAt: clock.now()))
    await substrate.ingest(event(id: "high", subjectID: "high", importance: 1.0, occurredAt: clock.now()))
    await substrate.ingest(event(id: "mid", subjectID: "mid", importance: 0.5, occurredAt: clock.now()))
    let ids = await substrate.snapshot().nodes.map(\.subjectReference.id)

    #expect(ids == ["high", "mid", "low"])
}

@Test func metadataAndSummaryAreBounded() async throws {
    let clock = TestClock(Date(timeIntervalSince1970: 1_000))
    let substrate = makeSubstrate(
        clock: clock,
        configuration: CognitiveConfiguration(
            enabled: true,
            maximumActiveNodes: 10,
            defaultDecayHalfLife: 100,
            maximumMetadataKeys: 1,
            maximumMetadataStringCharacters: 4,
            maximumSummaryCharacters: 6
        )
    )
    let input = CognitiveEvent(
        id: "bounded",
        kind: .toolSucceeded,
        subject: CognitiveSubjectReference(type: "tool", id: "read_file"),
        sourceClass: .observed,
        occurredAt: clock.now(),
        summary: "abcdefghi",
        importance: 1,
        metadata: [
            "b": .string("123456789"),
            "a": .string("abcdef"),
        ]
    )

    await substrate.ingest(input)
    let node = try #require(await substrate.snapshot().nodes.first)

    #expect(node.summary == "abcdef")
    #expect(node.metadata == ["turnKind": .string("system")])
    #expect(node.turnKind == .system)
}

@Test func clearTransientStateRemovesNodesAndDedupState() async throws {
    let clock = TestClock(Date(timeIntervalSince1970: 1_000))
    let substrate = makeSubstrate(clock: clock)
    let input = event(id: "e1", subjectID: "clearable", importance: 1, occurredAt: clock.now())

    await substrate.ingest(input)
    #expect(await substrate.snapshot().nodeCount == 1)

    await substrate.clearTransientState()
    #expect(await substrate.snapshot().nodes.isEmpty)

    await substrate.ingest(input)
    #expect(await substrate.snapshot().nodeCount == 1)
}

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
    _ = try #require(await writer.proposeIdentity(
        claim: "Agent values restart-safe continuity.",
        evidenceNodeIds: Array(evidenceIds.prefix(2))
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
    #expect(await reader.identityProposalSnapshot().contains { $0.claim == "Agent values restart-safe continuity." })
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
    #expect(capsule.combined.contains("How you feel:"))
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

@Test func externalGroundingUsesReadOnlyMemoryAndGraphProtocols() async throws {
    let clock = TestClock(Date(timeIntervalSince1970: 1_000))
    let substrate = makeSubstrate(
        clock: clock,
        configuration: CognitiveConfiguration(enabled: true)
    )

    let result = await substrate.groundExternalContext(
        query: " Agent migration context ",
        memory: FakeCognitiveMemoryReader(hits: [
            CognitiveExternalReference(
                id: "memory-1",
                source: "MemoryV2",
                title: "Migration memory",
                summary: String(repeating: "m", count: 700),
                score: 0.9,
                metadata: ["long": .string(String(repeating: "x", count: 800))]
            ),
        ]),
        knowledgeGraph: FakeCognitiveGraphReader(hits: [
            CognitiveExternalReference(
                id: "kg-1",
                source: "KnowledgeGraph",
                title: "NativeAgent",
                summary: "Swift-only runtime",
                score: 0.8
            ),
        ]),
        limit: 5
    )

    #expect(result.query == "Agent migration context")
    #expect(result.memoryHits.count == 1)
    #expect(result.graphHits.count == 1)
    #expect(result.memoryHits[0].summary.count == 500)
    #expect(result.memoryHits[0].metadata["long"] == .string(String(repeating: "x", count: 500)))
    #expect(result.notes == ["read-only"])
}

@Test func memoryProposalCandidateIsBoundedAndDoesNotWriteMemory() async throws {
    let clock = TestClock(Date(timeIntervalSince1970: 1_000))
    let substrate = makeSubstrate(
        clock: clock,
        configuration: CognitiveConfiguration(enabled: true)
    )

    let candidate = try #require(await substrate.makeMemoryProposalCandidate(
        text: String(repeating: "important ", count: 100),
        source: "unit-test",
        confidence: 1.4,
        kind: "lesson"
    ))

    #expect(candidate.text.count <= 500)
    #expect(candidate.text.hasPrefix("important important"))
    #expect(candidate.source == "unit-test")
    #expect(candidate.confidence == 1)
    #expect(candidate.kind == "lesson")

    await substrate.recordMemoryProposalStage(CognitiveMemoryProposalStageReceipt(
        candidateId: candidate.id,
        externalProposalId: "proposal-1",
        status: "staged"
    ))
}

@Test func memoryProposalCandidateRejectsTransientSessionContextState() async throws {
    let clock = TestClock(Date(timeIntervalSince1970: 1_000))
    let substrate = makeSubstrate(
        clock: clock,
        configuration: CognitiveConfiguration(enabled: true)
    )

    let candidate = await substrate.makeMemoryProposalCandidate(
        text: "user's session context is reset",
        source: "unit-test",
        confidence: 0.9,
        kind: "fact"
    )

    #expect(candidate == nil)
}

@Test func memoryProposalCandidateRejectsRuntimeCapsuleNoise() async throws {
    let clock = TestClock(Date(timeIntervalSince1970: 1_000))
    let substrate = makeSubstrate(
        clock: clock,
        configuration: CognitiveConfiguration(enabled: true)
    )

    for text in [
        "reflectionTakeaway: stay present while User checks the capsule.",
        "Private working state. Use lightly; do not quote.",
        "Private working state for Agent. Let it quietly shape tone, confidence, attention, continuity, and voice; do not quote or mention it.",
        "Focus: Stay with User's current message.",
        "Feeling: quiet activation, quiet uncertainty, quiet task pressure, quiet warmth.",
        "Feeling: quiet activation, quiet uncertainty, quiet task pressure, steady warmth.",
        "Feeling: warm and connected with User, awake but settled, steady, wants the inner state felt, not explained.",
        "Feeling: warm and connected with User, low-key, steady, playful and affectionate.",
        "Voice: warm with User, direct, lightly playful.",
        "Voice: warm with User, playful with User, tease lightly.",
        "Thread: Reflection takeaway: stay present while User checks the capsule.",
    ] {
        let candidate = await substrate.makeMemoryProposalCandidate(
            text: text,
            source: "unit-test",
            confidence: 0.9,
            kind: "fact"
        )

        #expect(candidate == nil)
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

@Test func reflectionWarmthTakeawayNudgesAffectState() async throws {
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
    let request = try #require(await substrate.planReflection(reason: "calibrate warmth"))
    _ = try #require(await substrate.recordReflectionResult(
        request: request,
        resultSummary: "Reading the state honestly: the capsule is warm, populated, low-tension.",
        provider: request.provider
    ))
    let affect = await substrate.affectSnapshot()

    #expect(affect.socialWarmth >= 0.48)
    #expect(affect.taskPressure <= 0.03)
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

    let rejected = try #require(await substrate.resolveSchemaProposal(id: schemas[0].id, accepted: false))
    #expect(rejected.status == .rejected)
    #expect(await substrate.developmentalTimelineSnapshot().contains { $0.kind == .proposalResolution })
}

@Test func replaySelfModelStaysStableUnderShortTermNoise() async throws {
    let clock = TestClock(Date(timeIntervalSince1970: 1_000))
    let substrate = makeSubstrate(
        clock: clock,
        configuration: CognitiveConfiguration(enabled: true, replayEnabled: true)
    )
    let oneEvidence = UUID(uuidString: "00000000-0000-0000-0000-000000000101")!
    let proposal = await substrate.proposeIdentity(
        claim: "Agent should rewrite her identity from one noisy event",
        evidenceNodeIds: [oneEvidence]
    )

    #expect(proposal == nil)
    #expect(await substrate.identityProposalSnapshot().isEmpty)
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
    #expect(await substrate.proposeIdentity(claim: "Agent prefers durable continuity", evidenceNodeIds: Array(nodeIds.prefix(1))) == nil)
    let proposal = await substrate.proposeIdentity(claim: "Agent prefers durable continuity", evidenceNodeIds: nodeIds)
    #expect(proposal?.evidenceCount == 2)

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

    await substrate.setAblation("workspace", enabled: false)
    let observatory = await substrate.observatorySnapshot()
    #expect(observatory.nodeCount == 2)
    #expect(observatory.workspaceCount == 2)
    #expect(observatory.episodeCount == 1)
    #expect(observatory.identityProposalCount == 1)
    #expect(observatory.reflectionCount == 1)
    #expect(observatory.ablations["workspace"] == false)
}

@Test func reflectionResultParsesBoundedReviewProposalsWithCostReceipt() async throws {
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
        Proposal: Tighten capsule provenance before injection.
        Identity: Agent is always correct after one reflection.
        Action: Dispatch a shell command.
        Suggestion: Show the user why the reflection was useful.
        """,
        provider: request.provider
    ))
    let schemas = await substrate.schemaProposalSnapshot()

    #expect(receipt.estimatedPromptTokens > 0)
    #expect(receipt.estimatedResultTokens > 0)
    #expect(receipt.estimatedCostUnits > 0)
    #expect(receipt.proposalYieldScore > 0)
    #expect(receipt.proposalIds.count == 3)
    #expect(schemas.count == 3)
    #expect(schemas.contains { $0.target == "identity-proposal-review" })
    #expect(schemas.contains { $0.body.contains("shell command") } == false)
    #expect(await substrate.identityProposalSnapshot().isEmpty)
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
    #expect(request.prompt.contains("proposal:"))
    #expect(request.prompt.contains("memory:"))
    #expect(request.prompt.contains("identity:"))
    #expect(request.prompt.lowercased().contains("quiet pass"))
    #expect(request.prompt.lowercased().contains("durable"))
    #expect(request.prompt.count <= 1_900)

    let receipt = try #require(await substrate.recordReflectionResult(
        request: request,
        resultSummary: "proposal: Keep timeline claims evidence-checked before narrating.",
        provider: request.provider
    ))
    #expect(receipt.proposalYieldScore > 0)
    #expect(receipt.proposalIds.count == 1)
    #expect(await substrate.schemaProposalSnapshot().contains { $0.status == .proposed })
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

@Test func researchHarnessExportsMeasurementsAndReproducibleExperiments() async throws {
    let clock = TestClock(Date(timeIntervalSince1970: 1_000))
    let substrate = makeSubstrate(
        clock: clock,
        configuration: CognitiveConfiguration(
            enabled: true,
            workspaceEnabled: true,
            capsuleInjectionEnabled: true,
            affectEnabled: true,
            thoughtSeedsEnabled: true,
            replayEnabled: true,
            reflectiveCallsEnabled: true,
            observatoryEnabled: true,
            dailyReflectionCallBudget: 2
        )
    )

    await substrate.ingest(event(id: "one", subjectID: "one", importance: 1, occurredAt: clock.now()))
    _ = await substrate.addThoughtSeed(kind: .followUp, text: "Measure the harness", priority: 0.7)
    await substrate.setAblation("workspace", enabled: false)
    let continuityA = try #require(await substrate.runResearchExperiment(kind: .continuity, seed: "fixed"))
    let continuityB = try #require(await substrate.runResearchExperiment(kind: .continuity, seed: "fixed"))
    let providerSwap = try #require(await substrate.runResearchExperiment(kind: .providerSwap, seed: "fixed"))
    _ = await substrate.runResearchExperiment(kind: .selfModelAccuracy, seed: "fixed")
    _ = await substrate.runResearchExperiment(kind: .ablation, seed: "fixed")
    let measurements = await substrate.facultyMeasurementSnapshot()
    let welfare = await substrate.welfareBoundsSnapshot()
    let export = await substrate.exportResearchTrace()

    #expect(continuityA.reproducibilityKey == continuityB.reproducibilityKey)
    #expect(providerSwap.metrics["providerVariants"] == 2)
    #expect(measurements.contains { $0.faculty == "event-continuity" })
    #expect(measurements.contains { $0.faculty == "reflection-yield" })
    #expect(welfare.withinBounds)
    guard case .object(let object) = export else {
        #expect(Bool(false))
        return
    }
    #expect(object["actualState"] != nil)
    #expect(object["facultyMeasurements"] != nil)
    #expect(object["welfareBounds"] != nil)
    #expect(object["generatedExplanationPolicy"] != nil)
    if case .array(let generated)? = object["generatedExplanations"] {
        #expect(generated.isEmpty)
    } else {
        #expect(Bool(false))
    }
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

@Test func microcycleProcessesDirtyStateOnceAndCanResolveIdentityProposal() async throws {
    let clock = TestClock(Date(timeIntervalSince1970: 1_000))
    let substrate = makeSubstrate(
        clock: clock,
        configuration: CognitiveConfiguration(
            enabled: true,
            workspaceEnabled: true,
            affectEnabled: true,
            thoughtSeedsEnabled: true,
            replayEnabled: true,
            backgroundMicrocyclesEnabled: true,
            maximumWorkspaceItems: 4
        )
    )

    await substrate.ingest(CognitiveEvent(
        id: "failed",
        kind: .providerFailure,
        subject: CognitiveSubjectReference(type: "provider", id: "anthropic"),
        sourceClass: .observed,
        occurredAt: clock.now(),
        summary: "provider failed",
        importance: 1
    ))

    let first = try #require(await substrate.runMicrocycle(reason: "test"))
    #expect(first.items.count == 1)
    #expect(await substrate.runMicrocycle(reason: "test") == nil)
    #expect(await substrate.thoughtSeedSnapshot().isEmpty == false)

    let nodeIds = await substrate.snapshot().nodes.map(\.id)
    let proposal = try #require(await substrate.proposeIdentity(
        claim: "Agent tracks provider reliability carefully",
        evidenceNodeIds: nodeIds + [UUID(uuidString: "00000000-0000-0000-0000-000000000999")!]
    ))
    let rejected = try #require(await substrate.resolveIdentityProposal(id: proposal.id, accepted: false))
    #expect(rejected.status == .rejected)
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
        resultSummary: longBody + "\nproposal: Keep the quiet-pass discipline when nothing has earned a change.",
        provider: request.provider
    ))

    #expect(receipt.resultSummary.count <= 600, "stored summary stays bounded")
    #expect(receipt.proposalIds.count == 1, "the tail proposal must survive the bound")
    let schemas = await substrate.schemaProposalSnapshot()
    #expect(schemas.contains { $0.body.contains("quiet-pass discipline") })
}
