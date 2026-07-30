import Foundation
import Testing
@testable import CognitiveSubstrate

private final class OrganismBodyTestClock: @unchecked Sendable {
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
}

@Test func bodySchemaPhoneStaleAffectsProjection() async throws {
    let now = Date(timeIntervalSince1970: 10_000)
    let body = OrganismBodySchemaSampler.bodySchema(
        from: OrganismBodyRead(
            iPhoneLastSeenAt: now.addingTimeInterval(-600),
            iPhoneStaleAfter: 60
        ),
        now: now
    )
    let projection = OrganismChemistry.projection(
        at: now,
        chemicalState: .neutral,
        bodySchema: body
    )

    #expect(body.iPhoneReachable == false)
    #expect(body.notificationPathHealthy == false)
    #expect(projection.bodyLine == "- Body: phone path feels stale; verify delivery before assuming it was seen.")
}

@Test func bodySchemaProviderFailureAddsCautionProjection() async throws {
    let now = Date(timeIntervalSince1970: 10_000)
    let body = OrganismBodySchemaSampler.bodySchema(
        from: OrganismBodyRead(providersHealthy: false),
        now: now
    )
    let projection = OrganismChemistry.projection(
        at: now,
        chemicalState: .neutral,
        bodySchema: body
    )

    #expect(body.providersHealthy == false)
    #expect(projection.bodyLine == "- Body: provider or tool path feels brittle; be careful before claiming completion.")
}

@Test func providerPathBeliefProjectsFreshEvidenceWithoutReplacingReality() throws {
    let now = Date(timeIntervalSince1970: 10_000)
    let healthy = ProviderPathBeliefProjector.project(
        evidence: [
            ProviderPathEvidence(
                evidenceID: "provider-call-digest",
                observedAt: now,
                outcome: .succeeded
            ),
        ],
        now: now
    )
    let brittle = ProviderPathBeliefProjector.project(
        evidence: [
            ProviderPathEvidence(
                evidenceID: "provider-failure-digest",
                observedAt: now,
                outcome: .failed
            ),
        ],
        now: now
    )

    #expect(healthy.state == .uncertain)
    #expect(abs(healthy.estimate - (2.0 / 3.0)) < 0.000_001)
    #expect(healthy.freshness == 1)
    #expect(healthy.uncertainty > 0.7)
    #expect(healthy.bodySchemaProvidersHealthy == nil)
    #expect(brittle.state == .uncertain)
    #expect(abs(brittle.estimate - (1.0 / 3.0)) < 0.000_001)
    #expect(brittle.bodySchemaProvidersHealthy == nil)

    let repeatedFailures = ProviderPathBeliefProjector.project(
        evidence: (0..<8).map { offset in
            ProviderPathEvidence(
                evidenceID: "provider-failure-\(offset)",
                observedAt: now.addingTimeInterval(Double(-offset)),
                outcome: .failed
            )
        },
        now: now
    )
    #expect(repeatedFailures.state == .brittle)
    #expect(repeatedFailures.bodySchemaProvidersHealthy == false)

    let body = OrganismBodySchemaSampler.bodySchema(
        from: OrganismBodyRead(
            providersHealthy: true,
            providerPathBelief: repeatedFailures
        ),
        now: now
    )
    #expect(body.providersHealthy == false)
    #expect(body.providerPathBelief == repeatedFailures)
}

@Test func providerPathBeliefIsUncertainForConflictingOrStaleEvidence() throws {
    let now = Date(timeIntervalSince1970: 100_000)
    let conflicting = ProviderPathBeliefProjector.project(
        evidence: [
            ProviderPathEvidence(evidenceID: "a", observedAt: now, outcome: .succeeded),
            ProviderPathEvidence(evidenceID: "b", observedAt: now, outcome: .failed),
        ],
        now: now
    )
    let stale = ProviderPathBeliefProjector.project(
        evidence: [
            ProviderPathEvidence(
                evidenceID: "old",
                observedAt: now.addingTimeInterval(-7 * 60 * 60),
                outcome: .failed
            ),
        ],
        now: now
    )

    #expect(conflicting.state == .uncertain)
    #expect(conflicting.uncertainty == 1)
    #expect(conflicting.bodySchemaProvidersHealthy == nil)
    #expect(stale.state == .stale)
    #expect(stale.bodySchemaProvidersHealthy == nil)

    let prior = BodySchema(providersHealthy: true)
    let body = OrganismBodySchemaSampler.bodySchema(
        from: OrganismBodyRead(providersHealthy: false, providerPathBelief: stale),
        previous: prior,
        now: now
    )
    #expect(body.providersHealthy == true)
    #expect(body.providerPathBelief == stale)
}

@Test func cancelledAndExpiredProviderEvidenceRemainUnknown() throws {
    let now = Date(timeIntervalSince1970: 110_000)
    for outcome in [ProviderPathEvidenceOutcome.cancelled, .expired, .started] {
        let belief = ProviderPathBeliefProjector.project(
            evidence: [
                ProviderPathEvidence(
                    evidenceID: "neutral-\(outcome.rawValue)",
                    observedAt: now,
                    outcome: outcome
                ),
            ],
            now: now
        )
        #expect(belief.estimate == 0.5)
        #expect(belief.uncertainty == 1)
        #expect(belief.state == .uncertain)
        #expect(belief.bodySchemaProvidersHealthy == nil)
    }
}

@Test func providerAvailabilityIsNotProviderHealth() throws {
    let now = Date(timeIntervalSince1970: 120_000)
    let unobserved = ProviderPathBeliefProjector.project(evidence: [], now: now)

    let available = OrganismBodySchemaSampler.bodySchema(
        from: OrganismBodyRead(
            providersAvailable: true,
            providerPathBelief: unobserved
        ),
        now: now
    )
    #expect(available.providersAvailable == true)
    #expect(available.providersHealthy == false)

    let unavailable = OrganismBodySchemaSampler.bodySchema(
        from: OrganismBodyRead(providersAvailable: false),
        previous: BodySchema(providersHealthy: true, providersAvailable: true),
        now: now
    )
    #expect(unavailable.providersAvailable == false)
    #expect(unavailable.providersHealthy == false)
}

@Test func providerPathBeliefIsBoundedPayloadFreeAndFutureEvidenceDoesNotGainWeight() throws {
    let now = Date(timeIntervalSince1970: 50_000)
    let future = ProviderPathBeliefProjector.project(
        evidence: [
            ProviderPathEvidence(
                evidenceID: String(repeating: "x", count: 200),
                observedAt: now.addingTimeInterval(600),
                outcome: .succeeded,
                sourceReliability: 5
            ),
        ],
        now: now
    )
    let encoded = String(decoding: try JSONEncoder().encode(future), as: UTF8.self).lowercased()

    #expect(future.state == .unobserved)
    #expect(future.estimate == 0.5)
    #expect(future.freshness == 0)
    #expect(future.uncertainty == 1)
    #expect(future.evidenceCount == 0)
    #expect(future.bodySchemaProvidersHealthy == nil)
    #expect(!encoded.contains("token"))
    #expect(!encoded.contains("prompt"))
    #expect(!encoded.contains("output"))
}

@Test func providerPathBeliefDeduplicatesEvidenceAndRejectsNonfiniteReliability() throws {
    let now = Date(timeIntervalSince1970: 60_000)
    let belief = ProviderPathBeliefProjector.project(
        evidence: [
            ProviderPathEvidence(
                evidenceID: "same",
                observedAt: now,
                outcome: .succeeded,
                sourceReliability: .nan
            ),
            ProviderPathEvidence(
                evidenceID: "same",
                observedAt: now.addingTimeInterval(-1),
                outcome: .failed
            ),
        ],
        now: now
    )

    #expect(belief.evidenceCount == 1)
    #expect(belief.state == .uncertain)
    #expect(belief.bodySchemaProvidersHealthy == nil)
}

@Test func providerEvidenceAndProjectionHostileDecodeStayBoundedAndStable() throws {
    let evidenceData = Data(#"{"evidenceID":"sk-proj-secret-prompt-output","observedAt":0,"outcome":"succeeded","sourceReliability":99}"#.utf8)
    let decoded = try JSONDecoder().decode(ProviderPathEvidence.self, from: evidenceData)
    #expect(decoded.evidenceID.count == 64)
    #expect(!decoded.evidenceID.contains("secret"))
    #expect(decoded.sourceReliability == 1)

    let encoded = try JSONEncoder().encode(decoded)
    let once = try JSONDecoder().decode(ProviderPathEvidence.self, from: encoded)
    let twice = try JSONDecoder().decode(ProviderPathEvidence.self, from: try JSONEncoder().encode(once))
    #expect(once == decoded)
    #expect(twice == decoded)

    let projectionData = Data(#"{"generatedAt":0,"estimate":9,"freshness":-2,"uncertainty":-4,"evidenceCount":999999,"newestEvidenceAt":0,"state":"healthy","bodySchemaProvidersHealthy":false}"#.utf8)
    let projection = try JSONDecoder().decode(ProviderPathBeliefProjection.self, from: projectionData)
    #expect(projection.estimate == 1)
    #expect(projection.freshness == 0)
    #expect(projection.uncertainty == 0)
    #expect(projection.evidenceCount == 10_000)
    #expect(projection.state == .stale)
    #expect(projection.bodySchemaProvidersHealthy == nil)
}

@Test func bodySchemaPersistenceOmitsTransientProviderBeliefAndDecodesLegacyRows() throws {
    let now = Date(timeIntervalSince1970: 70_000)
    let belief = ProviderPathBeliefProjector.project(
        evidence: (0..<8).map {
            ProviderPathEvidence(evidenceID: "ok-\($0)", observedAt: now, outcome: .succeeded)
        },
        now: now
    )
    let body = BodySchema(providersHealthy: true, providerPathBelief: belief)
    let data = try JSONEncoder().encode(body)
    let encodedText = String(decoding: data, as: UTF8.self)
    #expect(!encodedText.contains("providerPathBelief"))
    #expect(try JSONDecoder().decode(BodySchema.self, from: data).providerPathBelief == nil)

    let legacy = Data(#"{"macAwake":true,"iPhoneReachable":false,"providersHealthy":false,"memoryHealthy":true,"dreamHealthy":true,"toolHandsAvailable":true,"approvalChannelsOpen":true,"notificationPathHealthy":true,"resourcePressure":"nominal"}"#.utf8)
    let legacyBody = try JSONDecoder().decode(BodySchema.self, from: legacy)
    #expect(legacyBody.providersAvailable == false)
    #expect(legacyBody.providersHealthy == false)
    #expect(legacyBody.providerPathBelief == nil)
}

@Test func frozenOrganismReadSettlesACopyWithoutMutatingLiveState() async throws {
    let now = Date(timeIntervalSince1970: 130_000)
    let kernel = OrganismKernel(
        configuration: .enabled,
        dependencies: OrganismDependencies(now: { now })
    )
    await kernel.ingest(SomaticSignal(
        id: UUID(),
        kind: .providerFailed,
        sourceOrgan: "provider",
        occurredAt: now
    ))
    let before = await kernel.frozenRevisionFingerprint()
    let first = await kernel.frozenRead(at: now)
    _ = await kernel.frozenRead(at: now.addingTimeInterval(6 * 60 * 60))
    let after = await kernel.frozenRevisionFingerprint()
    let repeated = await kernel.frozenRead(at: now)

    #expect(after == before)
    #expect(repeated == first)
}

@Test func exactProviderLifecycleInvalidatesDerivedBelief() async {
    let now = Date(timeIntervalSince1970: 80_000)
    let belief = ProviderPathBeliefProjector.project(
        evidence: (0..<8).map {
            ProviderPathEvidence(evidenceID: "ok-\($0)", observedAt: now, outcome: .succeeded)
        },
        now: now
    )
    let kernel = OrganismKernel(
        configuration: .enabled,
        dependencies: OrganismDependencies(now: { now }),
        bodySchema: BodySchema(providersHealthy: true, providerPathBelief: belief)
    )
    await kernel.ingest(SomaticSignal(
        id: UUID(), kind: .providerFailed, sourceOrgan: "provider", occurredAt: now
    ))
    let snapshot = await kernel.snapshot()
    #expect(snapshot.bodySchema.providersHealthy == false)
    #expect(snapshot.bodySchema.providerPathBelief == nil)
}

@Test func bodySchemaMemoryRecoveryImprovesCoherence() async throws {
    let clock = OrganismBodyTestClock(Date(timeIntervalSince1970: 10_000))
    let kernel = OrganismKernel(
        configuration: .enabled,
        dependencies: OrganismDependencies(now: { clock.now() }),
        bodySchema: BodySchema(memoryHealthy: false)
    )

    await kernel.refreshBodySchema(OrganismBodyRead(memoryHealthy: true))
    let snapshot = await kernel.snapshot()

    #expect(snapshot.bodySchema.memoryHealthy == true)
    #expect(snapshot.chemicalState.coherence > ChemicalState.neutral.coherence)
}

@Test func bodySchemaRefreshCanSkipChemistryForDebugSimulation() async throws {
    let clock = OrganismBodyTestClock(Date(timeIntervalSince1970: 10_000))
    let kernel = OrganismKernel(
        configuration: .enabled,
        dependencies: OrganismDependencies(now: { clock.now() })
    )

    await kernel.refreshBodySchema(
        OrganismBodyRead(providersHealthy: false, toolHandsAvailable: false),
        integratesChemistry: false
    )
    let snapshot = await kernel.snapshot()

    #expect(snapshot.bodySchema.providersHealthy == false)
    #expect(snapshot.bodySchema.toolHandsAvailable == false)
    #expect(snapshot.projectedBodyLine == "- Body: provider or tool path feels brittle; be careful before claiming completion.")
    #expect(snapshot.chemicalState == .neutral)
}

@Test func bodyRefreshAndFrozenReadCrossCanonicalAffectInOneEpoch() async throws {
    let fixedAt = Date(timeIntervalSince1970: 10_000)
    let kernel = OrganismKernel(
        configuration: .enabled,
        dependencies: OrganismDependencies(now: { fixedAt })
    )
    let canonicalAffect = CognitiveAffectState(
        taskPressure: 0.67,
        socialWarmth: 0.82,
        updatedAt: fixedAt
    )

    let read = await kernel.refreshBodySchemaAndFrozenRead(
        OrganismBodyRead(memoryHealthy: true),
        canonicalAffect: canonicalAffect,
        fixedAt: fixedAt
    )
    let live = await kernel.snapshot()

    #expect(read.fixedAt == fixedAt)
    #expect(read.snapshot.generatedAt == fixedAt)
    #expect(abs(read.snapshot.chemicalState.warmth - 0.82) < 0.000_001)
    #expect(abs(read.snapshot.chemicalState.urgency - 0.67) < 0.000_001)
    #expect(abs(live.chemicalState.warmth - 0.82) < 0.000_001)
    #expect(abs(live.chemicalState.urgency - 0.67) < 0.000_001)
}

@Test func bodySchemaResourcePressureSetsLightweightProjection() async throws {
    let now = Date(timeIntervalSince1970: 10_000)
    let body = OrganismBodySchemaSampler.bodySchema(
        from: OrganismBodyRead(resourcePressure: .critical),
        now: now
    )
    let projection = OrganismChemistry.projection(
        at: now,
        chemicalState: .neutral,
        bodySchema: body
    )

    #expect(body.resourcePressure == .critical)
    #expect(projection.bodyLine == "- Body: resources feel tight; keep the next move lightweight.")
}

@Test func disabledKernelIgnoresBodySchemaRefresh() async throws {
    let clock = OrganismBodyTestClock(Date(timeIntervalSince1970: 10_000))
    let kernel = OrganismKernel(
        configuration: .disabled,
        dependencies: OrganismDependencies(now: { clock.now() })
    )

    await kernel.refreshBodySchema(OrganismBodyRead(providersHealthy: false, resourcePressure: .critical))
    let snapshot = await kernel.snapshot()

    #expect(snapshot.enabled == false)
    #expect(snapshot.bodySchema == .neutral)
    #expect(snapshot.chemicalState == .neutral)
    #expect(snapshot.projectedBodyLine == nil)
}

@Test func bodySchemaExportCarriesNoSecretPayload() throws {
    let body = OrganismBodySchemaSampler.bodySchema(
        from: OrganismBodyRead(
            iPhoneLastSeenAt: Date(timeIntervalSince1970: 10_000),
            providersHealthy: true,
            memoryHealthy: true,
            dreamHealthy: true,
            toolHandsAvailable: true,
            approvalChannelsOpen: true,
            notificationPathHealthy: true,
            resourcePressure: .nominal
        ),
        now: Date(timeIntervalSince1970: 10_000)
    )

    let data = try JSONEncoder().encode(body)
    let exported = String(decoding: data, as: UTF8.self).lowercased()

    #expect(!exported.contains("token"))
    #expect(!exported.contains("secret"))
    #expect(!exported.contains("authorization"))
    #expect(!exported.contains("password"))
    #expect(!exported.contains("user"))
}
