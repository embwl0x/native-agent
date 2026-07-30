import Foundation
import Testing
import PersistenceCore
@testable import CognitiveSubstrate

private func postureSnapshot(
    enabled: Bool = true,
    chemicalState: ChemicalState = .neutral,
    bodySchema: BodySchema = .neutral,
    predictionSummary: OrganismPredictionSummary = .empty,
    dreamRepairSummary: OrganismDreamRepairSummary = .empty,
    reflexSummary: OrganismReflexSummary = .empty,
    reflexCandidates: [OrganismReflexCandidate] = []
) -> OrganismSnapshot {
    OrganismSnapshot(
        generatedAt: Date(timeIntervalSince1970: 7_000),
        enabled: enabled,
        chemicalState: chemicalState,
        bodySchema: bodySchema,
        predictionSummary: predictionSummary,
        dreamRepairSummary: dreamRepairSummary,
        reflexSummary: reflexSummary,
        reflexCandidates: reflexCandidates,
        signalCount: enabled ? 1 : 0,
        lastSignalAt: enabled ? Date(timeIntervalSince1970: 6_900) : nil
    )
}

@Test func disabledOrganismHasNoBehaviorPosture() throws {
    let posture = OrganismBehaviorPosture.from(snapshot: postureSnapshot(enabled: false))
    #expect(posture == nil)
}

@Test func brittleProviderRequiresVerificationBeforeCompletionClaims() throws {
    let snapshot = postureSnapshot(
        bodySchema: BodySchema(providersHealthy: false),
        predictionSummary: OrganismPredictionSummary(strategyCaution: 0.32)
    )
    let posture = try #require(OrganismBehaviorPosture.from(snapshot: snapshot))

    #expect(posture.posture == "careful")
    #expect(posture.claimDiscipline == .verifyBeforeCompletion)
    #expect(posture.toolStrategy == .verifyBeforeRetry)
    #expect(posture.directives.contains {
        $0.contains("verify before retrying") && $0.contains("work is done")
    })

    guard case .object(let json) = posture.toolResultJSON(tool: "shell", surface: "telegram") else {
        Issue.record("tool posture should be object-shaped")
        return
    }
    #expect(json["tool_claims"] == .string("verifyBeforeCompletion"))
    #expect(json["tool_strategy"] == .string("verifyBeforeRetry"))
}

@Test func stalePhoneRequiresDeliveryReceipt() throws {
    let snapshot = postureSnapshot(
        bodySchema: BodySchema(iPhoneReachable: false, notificationPathHealthy: false)
    )
    let posture = try #require(OrganismBehaviorPosture.from(snapshot: snapshot))

    #expect(posture.posture == "delivery-aware")
    #expect(posture.claimDiscipline == .receiptRequired)
    #expect(posture.notificationRequiresReceipt)
    #expect(posture.directives.contains { $0.contains("Do not assume a phone notification was seen") })
}

@Test func typedUnknownProviderBeliefFailsCarefulEvenWhenLegacyBooleanIsOptimistic() throws {
    let now = Date(timeIntervalSince1970: 7_000)
    let belief = ProviderPathBeliefProjection(
        generatedAt: now,
        estimate: 0.5,
        freshness: 0,
        uncertainty: 1,
        evidenceCount: 0,
        newestEvidenceAt: nil,
        state: .healthy,
        bodySchemaProvidersHealthy: true
    )
    let snapshot = postureSnapshot(
        bodySchema: BodySchema(
            providersHealthy: true,
            providersAvailable: true,
            providerPathBelief: belief
        )
    )

    let posture = try #require(OrganismBehaviorPosture.from(snapshot: snapshot))
    #expect(snapshot.bodySchema.providerPathBelief?.state == .unobserved)
    #expect(posture.posture == "careful")
    #expect(posture.claimDiscipline == .verifyBeforeCompletion)
}

@Test func apnsAcceptanceRequiresReceiptEvenWhenCompatibilityBooleanWasOptimistic() throws {
    let now = Date(timeIntervalSince1970: 7_000)
    let belief = NotificationDeliveryBelief(
        generatedAt: now,
        transportConfigured: true,
        transportAccepted: true,
        evidence: [BodyEvidenceReference(
            id: "accepted",
            evidenceClass: .apnsAcceptance,
            observedAt: now,
            receivedAt: now
        )]
    )
    let snapshot = postureSnapshot(
        bodySchema: BodySchema(
            notificationDeliveryBelief: belief,
            notificationPathHealthy: true
        )
    )

    let posture = try #require(OrganismBehaviorPosture.from(snapshot: snapshot))
    #expect(posture.notificationRequiresReceipt)
    #expect(posture.claimDiscipline == .receiptRequired)
}

@Test func resourcePressureConservesLoopBudget() throws {
    let snapshot = postureSnapshot(
        chemicalState: ChemicalState(fatigue: 0.4),
        bodySchema: BodySchema(resourcePressure: .critical)
    )
    let posture = try #require(OrganismBehaviorPosture.from(snapshot: snapshot))

    #expect(posture.posture == "conserving")
    #expect(posture.toolStrategy == .lightweightOnly)
    #expect(posture.loopBudget == .sleep)
    #expect(posture.directives.contains { $0.contains("lightweight next move") })
}

@Test func privateRuntimeContextIsSanitizedAndActionable() throws {
    let posture = try #require(OrganismBehaviorPosture.from(snapshot: postureSnapshot(
        bodySchema: BodySchema(toolHandsAvailable: false)
    )))
    let rendered = posture.privateRuntimeContext(
        runId: "run-1",
        sessionId: "session-1",
        surface: "ios",
        fileAccess: "read_only"
    )

    #expect(rendered.contains("[OrganismBehavior]"))
    #expect(rendered.contains("tool_claims: verifyBeforeCompletion"))
    #expect(rendered.contains("Private behavior posture"))
    #expect(!rendered.contains("ChemicalState"))
    #expect(!rendered.contains("BodySchema"))
}

@Test func approvedLowRiskReflexBiasesPostureWithoutBypassingReview() throws {
    let date = Date(timeIntervalSince1970: 7_000)
    let candidate = OrganismReflexCandidate(
        id: "desk:close",
        pattern: "When a desk item closes cleanly, preserve the concise completion path.",
        trustClass: .lowRisk,
        evidenceCount: 4,
        successCount: 4,
        confidence: 0.72,
        reviewRequired: false,
        autoActivationAllowed: true,
        firstSeenAt: date.addingTimeInterval(-400),
        lastUpdatedAt: date,
        approvedAt: date
    )
    let snapshot = postureSnapshot(
        reflexSummary: OrganismReflexSummary(candidateCount: 1, approvedLowRiskCount: 1, lowRiskCount: 1),
        reflexCandidates: [candidate]
    )
    let posture = try #require(OrganismBehaviorPosture.from(snapshot: snapshot))
    let rendered = posture.privateRuntimeContext(
        runId: "run-2",
        sessionId: "session-2",
        surface: "telegram",
        fileAccess: "read_only"
    )

    #expect(posture.posture == "trained")
    #expect(posture.approvedReflexBiases.count == 1)
    #expect(rendered.contains("approved_low_risk_reflex: Soft preference"))
    #expect(posture.directives.contains { $0.contains("soft") || $0.contains("bias") })
    guard case .object(let json) = posture.toolResultJSON(tool: "desk", surface: "ios") else {
        Issue.record("tool posture should be object-shaped")
        return
    }
    #expect(json["approved_low_risk_reflex_total_count"] == .int(1))
    #expect(json["approved_reflex_bias_sample_count"] == .int(1))
    #expect(json["approved_reflex_biases_are_sampled"] == .bool(false))
    #expect(json["directives"] == nil)
    #expect(json["review_signals"] == nil)
    #expect(json["approved_reflex_biases"] == nil)
}

@Test func postureLabelsApprovedBiasSampleWhenReviewQueueConsumesCandidateSnapshot() async throws {
    let date = Date(timeIntervalSince1970: 7_000)
    let pending = (0..<9).map { index in
        OrganismReflexCandidate(
            id: "pending-\(index)",
            pattern: "Pending pattern \(index)",
            trustClass: .lowRisk,
            evidenceCount: 3,
            successCount: 3,
            confidence: 0.8,
            reviewRequired: true,
            firstSeenAt: date.addingTimeInterval(-500),
            lastUpdatedAt: date.addingTimeInterval(Double(index))
        )
    }
    let approved = (0..<5).map { index in
        OrganismReflexCandidate(
            id: "approved-\(index)",
            pattern: "Approved pattern \(index)",
            trustClass: .lowRisk,
            evidenceCount: 5,
            successCount: 5,
            confidence: 0.9,
            reviewRequired: false,
            autoActivationAllowed: true,
            firstSeenAt: date.addingTimeInterval(-500),
            lastUpdatedAt: date.addingTimeInterval(Double(index)),
            approvedAt: date
        )
    }
    let candidates = Dictionary(uniqueKeysWithValues: (pending + approved).map { ($0.id, $0) })
    let kernel = OrganismKernel(
        configuration: .enabled,
        dependencies: OrganismDependencies(now: { date }),
        reflexState: OrganismReflexState(candidates: candidates, lastUpdatedAt: date)
    )
    let snapshot = await kernel.snapshot()
    let posture = try #require(OrganismBehaviorPosture.from(snapshot: snapshot))
    let rendered = posture.privateRuntimeContext(
        runId: "run-sampled",
        sessionId: "session-sampled",
        surface: "mac",
        fileAccess: "read_only"
    )

    #expect(snapshot.reflexSummary.reviewRequiredCount == 9)
    #expect(snapshot.reflexSummary.approvedLowRiskCount == 5)
    #expect(snapshot.reflexCandidates.count == 12)
    #expect(posture.approvedReflexBiases.count == 3)
    #expect(posture.approvedReflexBiasSampleCount == 3)
    #expect(posture.approvedLowRiskReflexTotalCount == 5)
    #expect(posture.approvedReflexBiasesAreSampled)
    #expect(posture.reviewSignals.contains { $0.contains("9 reflex candidate") })
    #expect(rendered.contains("approved_low_risk_reflex_biases: sample 3 of 5"))
    #expect(rendered.contains("approved_low_risk_reflex: Soft preference"))

    guard case .object(let json) = posture.toolResultJSON(tool: "look", surface: "mac") else {
        Issue.record("tool posture should be object-shaped")
        return
    }
    #expect(json["review_required_reflex_count"] == .int(9))
    #expect(json["approved_low_risk_reflex_total_count"] == .int(5))
    #expect(json["approved_reflex_bias_sample_count"] == .int(3))
    #expect(json["approved_reflex_biases_are_sampled"] == .bool(true))
    #expect(json["directives"] == nil)
    #expect(json["review_signals"] == nil)
    #expect(json["approved_reflex_biases"] == nil)
}
