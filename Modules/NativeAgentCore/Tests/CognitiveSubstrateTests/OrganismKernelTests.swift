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

// 2026-09-01 — REWRITTEN. This used to assert `userSpoke` with an explicit
// positive valence raises warmth. That behavior was never reachable in
// production: `CognitiveSomaticSignalAdapter` leaves `userSpoke` valence NIL by
// design (`adapterSuppressesIntrinsicValence` — chat felt-meaning belongs to the
// substrate's appraisal, not to a canned per-kind constant), so every real user
// message fell into the neutral arm and only ever moved curiosity. Warmth's
// relational consequence crosses one-way from the substrate as `socialWarmth`
// and OVERWRITES this axis on every `refreshBodySchema`, so the arm was doubly
// dead. The test now pins what the ADAPTER actually produces.
@Test func adapterProducedUserSpeechRaisesCuriosityOnly() async throws {
    let event = CognitiveEvent(
        id: "user-turn-1",
        kind: .userMessageReceived,
        subject: CognitiveSubjectReference(type: "chat.user_turn", id: "turn-1"),
        sourceClass: .userStated,
        occurredAt: Date(timeIntervalSince1970: 1_000),
        summary: "love you — this is going really well",
        importance: 1
    )
    let signal = try #require(CognitiveSomaticSignalAdapter.signal(
        from: event,
        id: UUID(uuidString: "20000000-0000-0000-0000-000000000009")!
    ))
    #expect(signal.kind == .userSpoke)
    // The whole point: even an unmistakably warm message carries no adapter
    // valence, so a signed arm in the chemistry could never have fired.
    #expect(signal.valence == nil)

    let updated = OrganismChemistry.applying(
        signal: signal,
        to: .neutral,
        bodySchema: .neutral
    ).chemicalState

    #expect(updated.curiosity > ChemicalState.neutral.curiosity)
    #expect(updated.warmth == ChemicalState.neutral.warmth)
    #expect(updated.vigilance == ChemicalState.neutral.vigilance)
    #expect(updated.tenderness == ChemicalState.neutral.tenderness)
}

/// …and the relational consequence it used to fake is REAL on the path that
/// actually owns it: the canonical substrate crossing.
@Test func warmthAndTendernessArriveThroughTheCanonicalCrossing() async {
    let clock = OrganismTestClock(Date(timeIntervalSince1970: 1_000))
    let kernel = OrganismKernel(
        configuration: .enabled,
        dependencies: OrganismDependencies(now: { clock.now() }))
    for _ in 0..<24 {
        clock.advance(by: 300)
        await kernel.refreshBodySchema(
            OrganismBodyRead(memoryHealthy: true),
            canonicalAffect: CognitiveAffectState(
                socialWarmth: 0.8, updatedAt: clock.now()))
    }
    let snapshot = await kernel.snapshot()
    #expect(abs(snapshot.chemicalState.warmth - 0.8) < 0.000_001)
    #expect(snapshot.chemicalState.tenderness > 0.2)
    #expect(snapshot.chemicalState.tenderness <= 0.8)
}

@Test func assistantSpeechAloneDoesNotRaiseConfidenceOrCoherence() {
    let start = ChemicalState(coherence: 0.41, confidence: 0.39)
    // ALONE = the signal's OWN contribution. Both shared laws that ride every
    // signal — the homeostatic settle and the fatigue accrual — are density
    // capped, so a zero-second gap buys neither; whatever moves here is speech
    // itself. Speech moves nothing: producing language is not evidence.
    let updated = OrganismChemistry.applying(
        signal: organismSignal(.assistantSpoke, valence: 0.9),
        to: start,
        bodySchema: .neutral,
        elapsedSinceLastSignal: 0
    ).chemicalState

    #expect(updated == start)

    // With wall time on the clock the shared settle does move the axes — but
    // only ever TOWARD rest, so talking can still never manufacture coherence
    // or confidence above baseline.
    let afterAnHour = OrganismChemistry.applying(
        signal: organismSignal(.assistantSpoke, valence: 0.9),
        to: start,
        bodySchema: .neutral,
        elapsedSinceLastSignal: 3_600
    ).chemicalState
    #expect(afterAnHour.coherence <= ChemicalState.neutral.coherence)
    #expect(afterAnHour.confidence <= ChemicalState.neutral.confidence)
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

@Test(arguments: [ProviderPathBeliefState.uncertain, .stale, .unobserved])
func providerUnknownBodyEvidenceDoesNotManufactureChemistry(_ state: ProviderPathBeliefState) {
    let now = Date(timeIntervalSince1970: 100_000)
    let evidence: [ProviderPathEvidence] = state == .unobserved ? [] : [
        ProviderPathEvidence(
            evidenceID: "successful-call",
            observedAt: state == .stale ? now.addingTimeInterval(-7 * 3_600) : now,
            outcome: .succeeded
        ),
    ]
    let belief = ProviderPathBeliefProjector.project(evidence: evidence, now: now)
    #expect(belief.state == state)
    let healthy = BodySchema.neutral
    let unknown = OrganismBodySchemaSampler.bodySchema(
        from: OrganismBodyRead(providersAvailable: true, providerPathBelief: belief),
        previous: healthy,
        now: now
    )
    #expect(!unknown.providersHealthy) // Conservative compatibility/posture stays intact.
    let initial = ChemicalState(vigilance: 0.2, coherence: 0.45, confidence: 0.6)
    let afterUnknown = OrganismChemistry.integrating(
        bodySchema: unknown, previous: healthy, into: initial
    )
    let afterHealthy = OrganismChemistry.integrating(
        bodySchema: healthy, previous: unknown, into: afterUnknown
    )
    #expect(afterUnknown == initial)
    #expect(afterHealthy == initial)

    // Actual successful calls can remain statistically uncertain. Refreshing
    // that projection after each outcome must not repeatedly subtract coherence.
    var body = unknown
    var chemistry = initial
    for _ in 0..<12 {
        let success = OrganismChemistry.applying(
            signal: organismSignal(.providerSucceeded), to: chemistry, bodySchema: body
        )
        chemistry = OrganismChemistry.integrating(
            bodySchema: unknown, previous: success.bodySchema, into: success.chemicalState
        )
        body = unknown
    }
    // 2026-09-06: the pin was `== initial.coherence`, from before the
    // per-signal homeostatic settle (785d7c42, 2026-09-01). Every signal now
    // also relaxes each axis toward its own resting value, and coherence rests
    // at 0.5 — so twelve signals move 0.45 UP by 0.0035 no matter what they
    // are. That is the settle, not the body: `providerSucceeded` does not
    // touch coherence and unknown evidence still contributes nothing. Pinned
    // against the law that owns it rather than a frozen literal, so a writer
    // that starts subtracting coherence here still fails loudly.
    var settledCoherence = initial.coherence
    for _ in 0..<12 {
        settledCoherence = OrganismChemistry.settled(
            ChemicalState(coherence: settledCoherence),
            rate: OrganismChemistry.settleRate(forElapsed: nil)
        ).coherence
    }
    #expect(abs(chemistry.coherence - settledCoherence) < 1e-12)
    #expect(chemistry.coherence >= initial.coherence,
            "unknown provider evidence must never erode coherence: \(chemistry.coherence)")

    let failure = OrganismChemistry.applying(
        signal: organismSignal(.providerFailed), to: initial, bodySchema: unknown
    )
    #expect(failure.chemicalState.coherence < initial.coherence)
    #expect(failure.chemicalState.vigilance > initial.vigilance)
}

@Test func providerKnownBodyFailureAndLegacyTransitionsStillAffectChemistry() {
    let now = Date(timeIntervalSince1970: 100_000)
    let brittleBelief = ProviderPathBeliefProjector.project(
        evidence: (0..<8).map {
            ProviderPathEvidence(evidenceID: "failed-\($0)", observedAt: now, outcome: .failed)
        },
        now: now
    )
    #expect(brittleBelief.state == .brittle)
    let typedFailure = OrganismBodySchemaSampler.bodySchema(
        from: OrganismBodyRead(providersAvailable: true, providerPathBelief: brittleBelief),
        now: now
    )
    let legacyFailure = OrganismBodySchemaSampler.bodySchema(
        from: OrganismBodyRead(providersHealthy: false), now: now
    )
    let initial = ChemicalState(vigilance: 0.2, coherence: 0.45, confidence: 0.6)
    for failure in [typedFailure, legacyFailure] {
        let affected = OrganismChemistry.integrating(
            bodySchema: failure, previous: .neutral, into: initial
        )
        // Saturating law (2026-09-02): a lower spends a share of the VALUE and
        // a raise a share of the headroom to `axisHighRail` — never a flat
        // delta. Same transition, expressed through the functions that own it.
        #expect(affected.coherence == OrganismChemistry.lower(initial.coherence, by: 0.02))
        #expect(affected.vigilance == OrganismChemistry.raise(initial.vigilance, by: 0.08))
        #expect(affected.confidence == OrganismChemistry.lower(initial.confidence, by: 0.04))
        // ...and it still lands in the direction a known-bad body means.
        #expect(affected.coherence < initial.coherence)
        #expect(affected.vigilance > initial.vigilance)
        #expect(affected.confidence < initial.confidence)
        #expect(OrganismChemistry.integrating(
            bodySchema: failure, previous: failure, into: affected
        ) == affected)
        let recovered = OrganismChemistry.integrating(
            bodySchema: .neutral, previous: failure, into: affected
        )
        #expect(recovered.vigilance < affected.vigilance)
        #expect(recovered.confidence > affected.confidence)
    }
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

    clock.advance(by: 12 * 3_600)
    let rested = await kernel.snapshot()
    let restedPosture = try #require(OrganismBehaviorPosture.from(snapshot: rested))
    // Fatigue relaxes on its OWN slow half-life, not the generic quick decay,
    // and a gap this long is REST (>= `restGap`) so it accrues no hours awake.
    let expectedFatigue = OrganismChemistry.relaxedFatigue(0.8, elapsed: 12 * 3_600)

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
    // Fatigue: its own half-life plus the hours-awake lane (a 2h gap is a lull,
    // not rest). Vigilance still rides the generic quick decay.
    let expectedFatigue = OrganismChemistry.relaxedFatigue(0.8, elapsed: 2 * 3_600)
        + OrganismChemistry.wakefulness(0, elapsed: 2 * 3_600).gain
    #expect(abs(first.chemicalState.fatigue - expectedFatigue) < 0.000_000_1)
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

    // Order, not arithmetic: the elapsed gap settled FIRST — fatigue sits at
    // its own relaxation plus hours awake, and one signal may add at most its
    // per-signal accrual on top — then the signal applied to that settled state.
    let settledFatigue = OrganismChemistry.relaxedFatigue(0.8, elapsed: 2 * 3_600)
        + OrganismChemistry.wakefulness(0, elapsed: 2 * 3_600).gain
    #expect(snapshot.chemicalState.fatigue >= settledFatigue)
    #expect(snapshot.chemicalState.fatigue
        <= settledFatigue + OrganismChemistry.perSignalFatigueAccrual)
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
    #expect(snapshot.projectedBodyLine == "- Body: the Mac is under thermal or low-power pressure; keep the next move lightweight.")
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
    // Export runs the live settle, so fatigue follows its own half-life plus
    // the hours-awake lane the elapsed gap earned.
    let expectedFatigue = OrganismChemistry.relaxedFatigue(0.8, elapsed: 3 * 3_600)
        + OrganismChemistry.wakefulness(0, elapsed: 3 * 3_600).gain
    #expect(abs(state.chemicalState.fatigue - expectedFatigue) < 0.000_000_1)
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

// MARK: - The shared cognitive-side secret filter (2026-09-02)
//
// `JSONValueBounding.containsSecretLikeValue` is the one predicate the metadata
// bounder, `CognitiveSomaticSignalAdapter.safeSourceComponent` and
// `OrganismDreamRepair.clean` all route through. It used to be an unanchored
// `contains("sk-")` in three private copies, which redacted every ordinary
// `desk-…` label — the horizon register could not mint a row from a Desk
// deferral at all. Every credential below is a deliberate fake.

@Suite("Organism.SecretLikeValue")
struct OrganismSecretLikeValueTests {

    /// ANCHORED, not substring: a marker counts wherever it STARTS a token —
    /// the value's own start, or after any non-alphanumeric.
    @Test func theAnchorRedactsCredentialsAtEveryTokenStart() {
        let tail = String(repeating: "a", count: 30)
        let redacts = [
            "sk-ant-\(tail)",
            "sk-proj-\(tail)",
            "token=sk-abc",
            "x/sk-abc",
            "key:sk-abc",
            "\"sk-abc\"",
            "(sk-abc",
            "sk-abc",
            "Bearer \(tail)",
            "xoxb-\(tail)",
            "xapp-\(tail)",
        ]
        for value in redacts {
            #expect(JSONValueBounding.containsSecretLikeValue(value),
                    "a credential at a token start must redact: \(value)")
        }
    }

    /// And the words that broke. A marker at the TAIL of an ordinary word is
    /// not a credential; `desk-2-1` is the horizon label that started this.
    @Test func ordinaryWordsEndingInAMarkerSurvive() {
        for value in ["desk-2-1", "task-7", "risk-list", "disk-usage", "apikeysk-abc"] {
            #expect(!JSONValueBounding.containsSecretLikeValue(value),
                    "an ordinary label must survive: \(value)")
        }
    }

    /// Shapes the old private four-marker list never covered, now inherited
    /// from the canonical `NativeAgentSecretRedactor` — plus AWS, which the
    /// canonical redactor carries no pattern for and the marker list owns.
    @Test func theCanonicalRedactorsShapesAreCoveredToo() {
        let tail = String(repeating: "A", count: 32)
        let shapes = [
            "ghp_\(tail)",
            "github_pat_\(tail)",
            "sk_live_\(tail)",
            "AIza\(tail)",
            "AKIA\(tail)",
            "-----BEGIN RSA PRIVATE KEY----- \(tail) -----END RSA PRIVATE KEY-----",
        ]
        for value in shapes {
            #expect(JSONValueBounding.containsSecretLikeValue(value),
                    "a canonical secret shape must redact here too: \(value)")
        }
    }

    /// Dream-repair evidence answers the same way, because it is now the same
    /// predicate. (The adapter's source component is pinned by
    /// `adapterBoundsAndRedactsSignalMetadata` in `OrganismSignalBusTests`.)
    @Test func dreamRepairEvidenceSharesTheAnchor() {
        let secret = "ghp_\(String(repeating: "A", count: 32))"
        #expect(OrganismDreamRepairEvidence(
            id: "e1", label: "Evidence", summary: "desk-2-1 stayed open"
        ).summary == "desk-2-1 stayed open")
        #expect(OrganismDreamRepairEvidence(
            id: "e1", label: "Evidence", summary: secret
        ).summary == "private evidence hidden")
        #expect(CognitiveSomaticSignalAdapter.safeSourceComponent("desk-2-1") == "desk-2-1",
                "an ordinary source component must survive the same filter")
        #expect(CognitiveSomaticSignalAdapter.safeSourceComponent(secret) == nil)
    }
}
