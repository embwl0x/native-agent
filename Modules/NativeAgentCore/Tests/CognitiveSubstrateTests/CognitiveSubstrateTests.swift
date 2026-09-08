import Foundation
import Testing
import PersistenceCore
@testable import CognitiveSubstrate

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

@Test func microcycleProcessesDirtyStateOnce() async throws {
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

}
