import Foundation
import Testing
import PersistenceCore
@testable import CognitiveSubstrate

private final class OrganismTestClock: @unchecked Sendable {
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

    func advance(by interval: TimeInterval) {
        lock.lock()
        current = current.addingTimeInterval(interval)
        lock.unlock()
    }
}

private final class OrganismTestUUIDs: @unchecked Sendable {
    private let lock = NSLock()
    private var index = 0

    func next() -> UUID {
        lock.lock()
        defer {
            index += 1
            lock.unlock()
        }
        return UUID(uuidString: String(format: "10000000-0000-0000-0000-%012d", index))!
    }
}

private func organismSignal(
    _ kind: SomaticSignalKind,
    id: UUID = UUID(uuidString: "20000000-0000-0000-0000-000000000001")!,
    at date: Date = Date(timeIntervalSince1970: 1_000),
    intensity: Double = 1,
    valence: Double? = nil,
    metadata: [String: JSONValue] = [:]
) -> SomaticSignal {
    SomaticSignal(
        id: id,
        kind: kind,
        sourceOrgan: "test",
        occurredAt: date,
        intensity: intensity,
        valence: valence,
        metadata: metadata
    )
}

@Test func warmUserSignalRaisesWarmthOnly() async throws {
    let updated = OrganismChemistry.applying(
        signal: organismSignal(.userSpoke, valence: 0.8),
        to: .neutral,
        bodySchema: .neutral
    ).chemicalState

    #expect(updated.warmth > ChemicalState.neutral.warmth)
    #expect(updated.vigilance == ChemicalState.neutral.vigilance)
    #expect(updated.curiosity == ChemicalState.neutral.curiosity)
    #expect(updated.confidence == ChemicalState.neutral.confidence)
}

@Test func assistantSpeechAloneDoesNotRaiseConfidenceOrCoherence() {
    let start = ChemicalState(coherence: 0.41, confidence: 0.39)
    let updated = OrganismChemistry.applying(
        signal: organismSignal(.assistantSpoke, valence: 0.9),
        to: start,
        bodySchema: .neutral
    ).chemicalState

    #expect(updated == start)
}

@Test func providerFailureRaisesVigilance() async throws {
    let result = OrganismChemistry.applying(
        signal: organismSignal(.providerFailed),
        to: .neutral,
        bodySchema: .neutral
    )

    #expect(result.chemicalState.vigilance > ChemicalState.neutral.vigilance)
    #expect(result.chemicalState.confidence < ChemicalState.neutral.confidence)
    #expect(result.bodySchema.providersHealthy == false)
}

@Test func toolSuccessRaisesConfidenceAndCoherence() async throws {
    let start = ChemicalState(vigilance: 0.2, coherence: 0.45, confidence: 0.45, urgency: 0.4)
    let updated = OrganismChemistry.applying(
        signal: organismSignal(.toolSucceeded),
        to: start,
        bodySchema: .neutral
    ).chemicalState

    #expect(updated.confidence > start.confidence)
    #expect(updated.coherence > start.coherence)
    #expect(updated.urgency < start.urgency)
    #expect(updated.vigilance < start.vigilance)
}

@Test func resourcePressureRaisesFatigue() async throws {
    let result = OrganismChemistry.applying(
        signal: organismSignal(
            .resourcePressureChanged,
            metadata: ["level": .string("critical")]
        ),
        to: .neutral,
        bodySchema: .neutral
    )

    #expect(result.chemicalState.fatigue > ChemicalState.neutral.fatigue)
    #expect(result.chemicalState.vigilance > ChemicalState.neutral.vigilance)
    #expect(result.bodySchema.resourcePressure == .critical)
}

@Test func appSleepDoesNotManufactureFatigueOnRestart() async throws {
    let start = ChemicalState(fatigue: 0.6, urgency: 0.5)
    let result = OrganismChemistry.applying(
        signal: organismSignal(.appSleep),
        to: start,
        bodySchema: .neutral
    )

    #expect(result.chemicalState.fatigue == start.fatigue)
    #expect(result.chemicalState.urgency < start.urgency)
    #expect(result.bodySchema.macAwake == false)
}

@Test func runningKernelContinuouslyDecaysFatigueAndReleasesConservingPosture() async throws {
    let clock = OrganismTestClock(Date(timeIntervalSince1970: 10_000))
    let kernel = OrganismKernel(
        configuration: .enabled,
        dependencies: OrganismDependencies(now: { clock.now() }),
        chemicalState: ChemicalState(fatigue: 0.8, coherence: 0.8, confidence: 0.8)
    )

    let initial = await kernel.snapshot()
    let initialPosture = try #require(OrganismBehaviorPosture.from(snapshot: initial))
    #expect(initialPosture.posture == "conserving")
    #expect(initialPosture.toolStrategy == .lightweightOnly)

    clock.advance(by: 4 * 3_600)
    let rested = await kernel.snapshot()
    let restedPosture = try #require(OrganismBehaviorPosture.from(snapshot: rested))
    let expectedFatigue = 0.8 * pow(0.78, 4)

    #expect(abs(rested.chemicalState.fatigue - expectedFatigue) < 0.000_000_1)
    #expect(rested.chemicalState.fatigue < 0.35)
    #expect(restedPosture.posture != "conserving")
    #expect(restedPosture.toolStrategy == .normal)
    #expect(restedPosture.loopBudget == .normal)
}

@Test func repeatedReadsAtOneTimestampDoNotDoubleDecay() async throws {
    let clock = OrganismTestClock(Date(timeIntervalSince1970: 20_000))
    let kernel = OrganismKernel(
        configuration: .enabled,
        dependencies: OrganismDependencies(now: { clock.now() }),
        chemicalState: ChemicalState(vigilance: 0.7, fatigue: 0.8)
    )

    clock.advance(by: 2 * 3_600)
    let first = await kernel.snapshot()
    let second = await kernel.snapshot()

    #expect(first.chemicalState == second.chemicalState)
    #expect(abs(first.chemicalState.fatigue - (0.8 * pow(0.78, 2))) < 0.000_000_1)
    #expect(abs(first.chemicalState.vigilance - (0.7 * pow(0.78, 2))) < 0.000_000_1)
}

@Test func signalsApplyAfterElapsedChemistryHasSettled() async throws {
    let clock = OrganismTestClock(Date(timeIntervalSince1970: 30_000))
    let kernel = OrganismKernel(
        configuration: .enabled,
        dependencies: OrganismDependencies(now: { clock.now() }),
        chemicalState: ChemicalState(fatigue: 0.8, urgency: 0.8)
    )

    clock.advance(by: 2 * 3_600)
    await kernel.ingest(organismSignal(.toolSucceeded, at: clock.now()))
    let snapshot = await kernel.snapshot()

    #expect(abs(snapshot.chemicalState.fatigue - (0.8 * pow(0.78, 2))) < 0.000_000_1)
    #expect(snapshot.chemicalState.urgency < 0.8 * pow(0.78, 2))
    #expect(snapshot.signalCount == 1)
}

@Test func runtimeDecayPreservesFreshBodySchemaUntilSamplerChangesIt() async throws {
    let clock = OrganismTestClock(Date(timeIntervalSince1970: 40_000))
    let kernel = OrganismKernel(
        configuration: .enabled,
        dependencies: OrganismDependencies(now: { clock.now() }),
        chemicalState: ChemicalState(fatigue: 0.8),
        bodySchema: BodySchema(resourcePressure: .critical)
    )

    clock.advance(by: 2 * 3_600)
    let snapshot = await kernel.snapshot()

    #expect(snapshot.bodySchema.resourcePressure == .critical)
    #expect(snapshot.chemicalState.fatigue < 0.8)
    #expect(snapshot.projectedBodyLine == "- Body: resources feel tight; keep the next move lightweight.")
}

@Test func exportSettlesLiveStateAndUsesCurrentTimestamp() async throws {
    let clock = OrganismTestClock(Date(timeIntervalSince1970: 50_000))
    let kernel = OrganismKernel(
        configuration: .enabled,
        dependencies: OrganismDependencies(now: { clock.now() }),
        chemicalState: ChemicalState(fatigue: 0.8)
    )

    clock.advance(by: 3 * 3_600)
    let state = try #require(await kernel.exportPersistentState())

    #expect(state.savedAt == clock.now())
    #expect(abs(state.chemicalState.fatigue - (0.8 * pow(0.78, 3))) < 0.000_000_1)
}

@Test func settleContinuityExportUsesSettleAnchorSoRestoreInsideWindowDoesNotDoubleDecay() async throws {
    // F3-M5: settleContinuity() forward-decays through now+6h and anchors
    // lastSettledAt there. Exporting with savedAt=now (the pre-fix behavior)
    // let restorePersistentState re-decay that already-forward-decayed window
    // on a relaunch inside 6h — a double-decay. exportPersistentState must
    // stamp savedAt at the settle anchor instead.
    let t0 = Date(timeIntervalSince1970: 100_000)
    let clock = OrganismTestClock(t0)
    let kernel = OrganismKernel(
        configuration: .enabled,
        dependencies: OrganismDependencies(now: { clock.now() }),
        chemicalState: ChemicalState(warmth: 0.7, fatigue: 0.9)
    )
    await kernel.ingest(organismSignal(.providerFailed, at: t0))

    await kernel.settleContinuity()

    // No wall-clock advance: savedAt is the settle anchor (t0 + 6h), not t0.
    let exported = try #require(await kernel.exportPersistentState())
    #expect(exported.savedAt == t0.addingTimeInterval(6 * 3_600))

    // Relaunch 1h later — inside the 6h forward-decay window.
    let restoreClock = OrganismTestClock(t0.addingTimeInterval(3_600))
    let fresh = OrganismKernel(
        configuration: .enabled,
        dependencies: OrganismDependencies(now: { restoreClock.now() })
    )
    await fresh.restorePersistentState(exported)
    let restored = try #require(await fresh.exportPersistentState())

    // savedAt (t0+6h) is still in the future at restore (t0+1h), so
    // decayed(at:) clamps elapsed to zero — the restored chemistry and field
    // equal the exported settled values, NOT a second decay pass on top.
    #expect(restored.chemicalState == exported.chemicalState)
    #expect(restored.field == exported.field)
}

@Test func chemicalValuesClamp() async throws {
    let state = ChemicalState(
        warmth: 2,
        vigilance: -1,
        curiosity: 4,
        fatigue: -0.5,
        coherence: 9,
        agency: 8,
        tenderness: -3,
        confidence: 10,
        novelty: -10,
        urgency: 11
    )

    #expect(state.warmth == 1)
    #expect(state.vigilance == 0)
    #expect(state.curiosity == 1)
    #expect(state.fatigue == 0)
    #expect(state.coherence == 1)
    #expect(state.agency == 1)
    #expect(state.tenderness == 0)
    #expect(state.confidence == 1)
    #expect(state.novelty == 0)
    #expect(state.urgency == 1)
}

@Test func disabledKernelIgnoresSignals() async throws {
    let clock = OrganismTestClock(Date(timeIntervalSince1970: 1_000))
    let kernel = OrganismKernel(
        configuration: .disabled,
        dependencies: OrganismDependencies(now: { clock.now() })
    )

    await kernel.ingest(organismSignal(.providerFailed, at: clock.now()))
    let snapshot = await kernel.snapshot()

    #expect(snapshot.enabled == false)
    #expect(snapshot.signalCount == 0)
    #expect(snapshot.chemicalState == .neutral)
    #expect(snapshot.bodySchema == .neutral)
}

@Test func projectionOmitsNeutralState() async throws {
    let clock = OrganismTestClock(Date(timeIntervalSince1970: 1_000))
    let kernel = OrganismKernel(
        configuration: .enabled,
        dependencies: OrganismDependencies(now: { clock.now() })
    )

    let projection = await kernel.projection()

    #expect(projection.bodyLine == nil)
    #expect(projection.isNeutral)
}

@Test func metadataIsBoundedAndRedacted() async throws {
    let metadata: [String: JSONValue] = [
        "z": .string("keep but trim"),
        "a": .string("first"),
        "authorization": .string("Bearer secret-token"),
        "nested": .object(["api_key": .string("sk-test-secret"), "safe": .string("abcdef")]),
    ]
    let bounded = SomaticSignal.boundedMetadata(
        metadata,
        bounds: OrganismMetadataBounds(maximumKeys: 3, maximumStringCharacters: 4, maximumArrayItems: 2, maximumDepth: 3)
    )

    #expect(Array(bounded.keys).sorted() == ["a", "authorization", "nested"])
    #expect(bounded["a"] == .string("firs"))
    #expect(bounded["authorization"] == .string("[redacted]"))
    guard case .object(let nested)? = bounded["nested"] else {
        Issue.record("nested metadata missing")
        return
    }
    #expect(nested["api_key"] == .string("[redacted]"))
    #expect(nested["safe"] == .string("abcd"))
}

@Test func noFileIONoLLMNoMemoryWrites() async throws {
    let clock = OrganismTestClock(Date(timeIntervalSince1970: 1_000))
    let uuids = OrganismTestUUIDs()
    let kernel = OrganismKernel(
        configuration: .enabled,
        dependencies: OrganismDependencies(
            now: { clock.now() },
            makeUUID: { uuids.next() }
        )
    )

    await kernel.ingest(organismSignal(.toolSucceeded, at: clock.now()))
    let snapshot = await kernel.snapshot()
    let projection = await kernel.projection()

    #expect(snapshot.signalCount == 1)
    #expect(snapshot.chemicalState.confidence > ChemicalState.neutral.confidence)
    #expect(snapshot.reflexCandidates.isEmpty, "routine signals must not compile generic reflex proposals")
    #expect(projection.generatedAt == clock.now())
}
