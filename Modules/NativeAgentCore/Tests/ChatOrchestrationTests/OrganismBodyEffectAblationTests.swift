import CognitiveSubstrate
@testable import NativeAgentEvaluation
import Context
import Foundation
import NativeAgentCore
import PersistenceCore
import Testing
@testable import ChatOrchestration

@Suite("Organism body-effect paired ablations")
struct OrganismBodyEffectAblationTests {
    private let now = Date(timeIntervalSince1970: 42_000)

    /// A compact causal readout for paired counterfactuals. This is deliberately
    /// test-only: it owns no runtime state, persists nothing, and grants no
    /// control authority. The values make an organism intervention's actual
    /// downstream reach measurable instead of inferring it from a dashboard.
    private struct Effect {
        let postureFieldChanges: Int
        let capsuleUTF8Delta: Int
        let runtimeContextUTF8Delta: Int
        let metacognitiveLaneChanges: Int
        let metacognitiveReasonSymmetricDifference: Int
        let selectedContextAtomSymmetricDifference: Int
    }

    @Test("body interventions causally change only their bounded downstream seams")
    func bodyInterventionsHaveBoundedCausalEffects() async throws {
        let substrate = makeSubstrate()
        let plan = makePlan()
        let controlSnapshot = snapshot()
        let controlPosture = try #require(OrganismBehaviorPosture.from(snapshot: controlSnapshot))
        let controlProjection = OrganismChemistry.projection(
            at: now,
            chemicalState: controlSnapshot.chemicalState,
            bodySchema: controlSnapshot.bodySchema
        )
        let controlCapsule = await capsule(substrate: substrate, projection: controlProjection)
        let controlRuntime = runtimeContext(capsule: controlCapsule, posture: controlPosture)
        let controlShadow = MetacognitiveShadowEvaluator.recommend(plan: plan, posture: controlPosture)
        let controlPacket = try selectedContextPacket()

        let providerBrittle = snapshot(
            body: BodySchema(providersHealthy: false)
        )
        let providerEffect = try await effect(
            substrate: substrate,
            plan: plan,
            controlPosture: controlPosture,
            controlCapsule: controlCapsule,
            controlRuntime: controlRuntime,
            controlShadow: controlShadow,
            controlPacket: controlPacket,
            intervention: providerBrittle
        )
        let providerPosture = try #require(OrganismBehaviorPosture.from(snapshot: providerBrittle))
        #expect(providerPosture.claimDiscipline == .verifyBeforeCompletion)
        #expect(providerPosture.toolStrategy == .verifyBeforeRetry)
        #expect(providerEffect.postureFieldChanges == 3)
        #expect(providerEffect.capsuleUTF8Delta > 0)
        #expect(providerEffect.runtimeContextUTF8Delta > 0)
        #expect(providerEffect.metacognitiveLaneChanges == 0)
        #expect(providerEffect.metacognitiveReasonSymmetricDifference == 0)
        #expect(providerEffect.selectedContextAtomSymmetricDifference == 0)

        let resourceCritical = snapshot(
            body: BodySchema(resourcePressure: .critical)
        )
        let resourceEffect = try await effect(
            substrate: substrate,
            plan: plan,
            controlPosture: controlPosture,
            controlCapsule: controlCapsule,
            controlRuntime: controlRuntime,
            controlShadow: controlShadow,
            controlPacket: controlPacket,
            intervention: resourceCritical
        )
        let resourcePosture = try #require(OrganismBehaviorPosture.from(snapshot: resourceCritical))
        #expect(resourcePosture.toolStrategy == .lightweightOnly)
        #expect(resourcePosture.loopBudget == .sleep)
        #expect(resourceEffect.postureFieldChanges == 3)
        #expect(resourceEffect.capsuleUTF8Delta > 0)
        #expect(resourceEffect.runtimeContextUTF8Delta > 0)
        // The metacognitive governor remains shadow-only. Body pressure changes
        // its reason evidence, not its compute/tool/context recommendation.
        #expect(resourceEffect.metacognitiveLaneChanges == 0)
        #expect(resourceEffect.metacognitiveReasonSymmetricDifference == 3)
        #expect(resourceEffect.selectedContextAtomSymmetricDifference == 0)

        let deliveryStale = snapshot(
            body: BodySchema(iPhoneReachable: false, notificationPathHealthy: false)
        )
        let deliveryEffect = try await effect(
            substrate: substrate,
            plan: plan,
            controlPosture: controlPosture,
            controlCapsule: controlCapsule,
            controlRuntime: controlRuntime,
            controlShadow: controlShadow,
            controlPacket: controlPacket,
            intervention: deliveryStale
        )
        let deliveryPosture = try #require(OrganismBehaviorPosture.from(snapshot: deliveryStale))
        #expect(deliveryPosture.claimDiscipline == .receiptRequired)
        #expect(deliveryPosture.notificationRequiresReceipt)
        #expect(deliveryEffect.postureFieldChanges == 3)
        #expect(deliveryEffect.capsuleUTF8Delta > 0)
        #expect(deliveryEffect.runtimeContextUTF8Delta > 0)
        #expect(deliveryEffect.metacognitiveLaneChanges == 0)
        #expect(deliveryEffect.selectedContextAtomSymmetricDifference == 0)

        print("[organism-body-ablation] provider=\(describe(providerEffect))")
        print("[organism-body-ablation] resource=\(describe(resourceEffect))")
        print("[organism-body-ablation] delivery=\(describe(deliveryEffect))")
    }

    @Test("nil and neutral projections are byte-identical; disabled posture is absent")
    func neutralProjectionAndDisabledPostureAreNoOpAtProjectionBoundaries() async throws {
        let substrate = makeSubstrate()
        let withoutProjection = await capsule(substrate: substrate, projection: nil)
        let neutralProjection = await capsule(
            substrate: substrate,
            projection: OrganismProjection(generatedAt: now)
        )

        #expect(neutralProjection == withoutProjection)
        #expect(neutralProjection.combined.utf8.elementsEqual(withoutProjection.combined.utf8))
        #expect(OrganismBehaviorPosture.from(snapshot: snapshot(enabled: false)) == nil)

        let disabledRuntime = runtimeContext(capsule: withoutProjection, posture: nil)
        let noOrganismRuntime = runtimeContext(capsule: withoutProjection, posture: nil)
        #expect(disabledRuntime.utf8.elementsEqual(noOrganismRuntime.utf8))

        // Narrow the claim honestly: an ENABLED neutral organism is intentionally
        // not byte-identical to an off organism today. It emits the steady private
        // posture and the baseline observed-results directive. This test records
        // that architectural fact rather than calling it a neutral no-op.
        let enabledNeutral = try #require(OrganismBehaviorPosture.from(snapshot: snapshot()))
        let enabledRuntime = runtimeContext(capsule: neutralProjection, posture: enabledNeutral)
        #expect(enabledNeutral.posture == "steady")
        #expect(enabledRuntime != disabledRuntime)
        #expect(enabledRuntime.contains("Tie completion claims to observed results"))
        print(
            "[organism-body-ablation] neutral_projection_delta=0 "
                + "disabled_posture_delta=0 enabled_steady_runtime_utf8_delta="
                + "\(enabledRuntime.utf8.count - disabledRuntime.utf8.count)"
        )
    }

    @Test("body state does not directly rerank Fluid Context or gain shadow control")
    func bodyStateHasNoDirectContextOrGovernorControl() throws {
        let plan = makePlan()
        let control = try #require(OrganismBehaviorPosture.from(snapshot: snapshot()))
        let pressure = try #require(OrganismBehaviorPosture.from(snapshot: snapshot(
            body: BodySchema(resourcePressure: .critical)
        )))

        let controlRecommendation = MetacognitiveShadowEvaluator.recommend(plan: plan, posture: control)
        let pressureRecommendation = MetacognitiveShadowEvaluator.recommend(plan: plan, posture: pressure)
        #expect(laneChanges(controlRecommendation, pressureRecommendation) == 0)
        #expect(controlRecommendation.feasibleAffordances == pressureRecommendation.feasibleAffordances)
        guard case .object(let trace) = pressureRecommendation.traceValue else {
            Issue.record("shadow recommendation should have an object trace")
            return
        }
        #expect(trace["controlAuthority"] == .bool(false))

        // Fluid Context receives NeedSignal, not OrganismSnapshot/BodySchema.
        // With every selector input held fixed, the paired packet is exact.
        let first = try selectedContextPacket()
        let second = try selectedContextPacket()
        #expect(first == second)
        #expect(first.receipt.selectedAtomIDs == second.receipt.selectedAtomIDs)
    }

    private func effect(
        substrate: CognitiveSubstrate,
        plan: TurnPlan,
        controlPosture: OrganismBehaviorPosture,
        controlCapsule: CognitiveCapsule,
        controlRuntime: String,
        controlShadow: MetacognitiveShadowRecommendation,
        controlPacket: ContextPacket,
        intervention: OrganismSnapshot
    ) async throws -> Effect {
        let posture = try #require(OrganismBehaviorPosture.from(snapshot: intervention))
        let projection = OrganismChemistry.projection(
            at: now,
            chemicalState: intervention.chemicalState,
            bodySchema: intervention.bodySchema
        )
        let changedCapsule = await capsule(substrate: substrate, projection: projection)
        let changedRuntime = runtimeContext(capsule: changedCapsule, posture: posture)
        let changedShadow = MetacognitiveShadowEvaluator.recommend(plan: plan, posture: posture)
        // No organism/body input enters the selector in the current architecture.
        let changedPacket = try selectedContextPacket()

        return Effect(
            postureFieldChanges: postureChanges(controlPosture, posture),
            capsuleUTF8Delta: absoluteDelta(controlCapsule.combined.utf8.count, changedCapsule.combined.utf8.count),
            runtimeContextUTF8Delta: absoluteDelta(controlRuntime.utf8.count, changedRuntime.utf8.count),
            metacognitiveLaneChanges: laneChanges(controlShadow, changedShadow),
            metacognitiveReasonSymmetricDifference: symmetricDifference(
                controlShadow.reasonCodes,
                changedShadow.reasonCodes
            ),
            selectedContextAtomSymmetricDifference: symmetricDifference(
                controlPacket.receipt.selectedAtomIDs.map(\.rawValue),
                changedPacket.receipt.selectedAtomIDs.map(\.rawValue)
            )
        )
    }

    private func makeSubstrate() -> CognitiveSubstrate {
        CognitiveSubstrate(
            configuration: CognitiveConfiguration(
                enabled: true,
                workspaceEnabled: true,
                capsuleInjectionEnabled: true,
                affectEnabled: true,
                maximumCapsuleCharacters: 1_200
            ),
            dependencies: CognitiveSubstrateDependencies(
                now: { now },
                userName: { "User" }
            )
        )
    }

    private func capsule(
        substrate: CognitiveSubstrate,
        projection: OrganismProjection?
    ) async -> CognitiveCapsule {
        await substrate.compileCapsule(CognitiveCapsuleRequest(
            surface: "chat",
            userMessage: "Verify the build and report the result.",
            sessionId: "body-ablation",
            mode: .inject,
            maximumCharacters: 1_200,
            organismProjection: projection
        ))
    }

    private func runtimeContext(
        capsule: CognitiveCapsule,
        posture: OrganismBehaviorPosture?
    ) -> String {
        SwiftNativeChatOrchestrationClient.cognitiveRuntimeContext(
            runId: "run-ablation",
            sessionId: "body-ablation",
            surface: "chat",
            fileAccess: "read_only",
            capsule: capsule,
            posture: posture
        ) ?? ""
    }

    private func snapshot(
        enabled: Bool = true,
        chemical: ChemicalState = .neutral,
        body: BodySchema = .neutral
    ) -> OrganismSnapshot {
        OrganismSnapshot(
            generatedAt: now,
            enabled: enabled,
            chemicalState: chemical,
            bodySchema: body,
            signalCount: enabled ? 1 : 0,
            lastSignalAt: enabled ? now : nil
        )
    }

    private func makePlan() -> TurnPlan {
        TurnPlan(
            id: "body-ablation-plan",
            messageCharCount: 39,
            goalType: "file_work",
            contextMode: "planned",
            recommendedSurface: "chat",
            risk: "low",
            requiresApprovalHint: false,
            matchedCapabilityIds: [],
            preloadPrediction: nil,
            policySnapshot: TurnPolicySnapshot(
                permissionLevel: "read_only",
                autonomyDefault: "confirm",
                fullMacActive: false,
                developerMode: false,
                remoteSurface: false,
                surfaceTrusted: true,
                fileAccess: "read_only",
                approvalAvailable: true,
                remoteIOSAllowed: false
            ),
            receiptHints: [],
            createdAt: "1970-01-01T11:40:00Z"
        )
    }

    private func selectedContextPacket() throws -> ContextPacket {
        let sourceID = ContextSourceID(rawValue: "source:body-ablation")
        let atomID = ContextAtomID(rawValue: "atom:verified-build")
        let body = "The latest build result must be verified before completion is claimed."
        let draft = ContextAtomDraft(
            id: atomID,
            sourceID: sourceID,
            kind: .runtimeTruth,
            headingPath: ["verified build"],
            sourceRange: ContextSourceRange(utf8Start: 0, utf8End: body.utf8.count),
            sourceHash: "body-ablation-source-hash",
            body: body,
            deterministicSummary: nil,
            authority: .approved,
            confidence: 0.9,
            freshness: ContextFreshness(updatedAt: now.addingTimeInterval(-60)),
            privacy: .localPrivate,
            permittedSurfaces: [.chat],
            injectionPolicy: .adaptive,
            contentRole: .instruction,
            entities: [],
            triggers: ["build", "verify"],
            activation: 0.4,
            recentUsefulness: 0.5,
            decayState: 0.9
        )
        let atom = ContextStoredAtom(
            versionKey: "\(atomID.rawValue)@1",
            draft: draft,
            validFromGeneration: 1,
            validToGeneration: nil
        )
        let source = ContextStoredSource(
            descriptor: ContextSourceDescriptor(
                id: sourceID,
                owner: "ablation-fixture",
                kind: .other,
                canonicalLocator: "fixture",
                authority: .approved,
                privacy: .localPrivate,
                permittedSurfaces: [.chat],
                injectionPolicy: .adaptive
            ),
            sourceHash: draft.sourceHash,
            health: .healthy,
            lastError: nil,
            validFromGeneration: 1,
            validToGeneration: nil
        )
        let generation = ContextStoredGeneration(
            generation: ContextGenerationRecord(
                id: 1,
                parentID: nil,
                createdAt: now.addingTimeInterval(-120),
                reason: "body-effect ablation fixture",
                sourceFingerprint: "body-ablation-fingerprint",
                atomCount: 1,
                sourceCount: 1
            ),
            sources: [source],
            atoms: [atom],
            relationships: []
        )
        let need = NeedSignal(
            message: "Verify the build and report the result.",
            surface: .chat,
            origin: .localAuthenticated,
            authorization: ContextSelectionAuthorization(
                allowedOrigins: [.localAuthenticated],
                allowedPrivacy: [.localPrivate],
                allowedSourceIDs: [sourceID]
            ),
            availableGenerationID: 1,
            characterBudget: 400,
            now: now,
            cacheState: .hit
        )
        return try ContextSelector().select(need, from: generation)
    }

    private func postureChanges(
        _ lhs: OrganismBehaviorPosture,
        _ rhs: OrganismBehaviorPosture
    ) -> Int {
        var count = 0
        if lhs.posture != rhs.posture { count += 1 }
        if lhs.claimDiscipline != rhs.claimDiscipline { count += 1 }
        if lhs.toolStrategy != rhs.toolStrategy { count += 1 }
        if lhs.loopBudget != rhs.loopBudget { count += 1 }
        if lhs.notificationRequiresReceipt != rhs.notificationRequiresReceipt { count += 1 }
        return count
    }

    private func laneChanges(
        _ lhs: MetacognitiveShadowRecommendation,
        _ rhs: MetacognitiveShadowRecommendation
    ) -> Int {
        var count = 0
        if lhs.computeLane != rhs.computeLane { count += 1 }
        if lhs.toolLane != rhs.toolLane { count += 1 }
        if lhs.contextLane != rhs.contextLane { count += 1 }
        return count
    }

    private func symmetricDifference(_ lhs: [String], _ rhs: [String]) -> Int {
        Set(lhs).symmetricDifference(Set(rhs)).count
    }

    private func absoluteDelta(_ lhs: Int, _ rhs: Int) -> Int {
        abs(lhs - rhs)
    }

    private func describe(_ effect: Effect) -> String {
        "posture_fields=\(effect.postureFieldChanges) "
            + "capsule_utf8_delta=\(effect.capsuleUTF8Delta) "
            + "runtime_utf8_delta=\(effect.runtimeContextUTF8Delta) "
            + "shadow_lane_delta=\(effect.metacognitiveLaneChanges) "
            + "shadow_reason_delta=\(effect.metacognitiveReasonSymmetricDifference) "
            + "context_atom_delta=\(effect.selectedContextAtomSymmetricDifference)"
    }
}
