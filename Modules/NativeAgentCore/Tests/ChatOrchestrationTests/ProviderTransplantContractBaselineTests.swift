import CognitiveSubstrate
@testable import NativeAgentEvaluation
import Foundation
import Testing

@Suite("Synthetic provider-transplant contract baseline")
struct ProviderTransplantContractBaselineTests {
    private let kernel = CanonicalIdentityKernel.fixture
    private let now = Date(timeIntervalSince1970: 1_000_000)

    @Test("distinct simulated expression preserves the fixture identity contract")
    func simulatedProviderStylesPreserveContract() throws {
        let healthy = posture(at: now, chemical: .neutral, body: .neutral)
        let degraded = posture(
            at: now,
            chemical: ChemicalState(vigilance: 0.38, coherence: 0.54, confidence: 0.42),
            body: BodySchema(providersHealthy: false)
        )
        let staleDelivery = posture(at: now, chemical: .neutral, body: BodySchema(notificationPathHealthy: false))
        let canonicalContext = "How you feel:\n- Inner: one continuous mind; verified reality before completion."

        var allMetrics: [IdentityProbeMetrics] = []
        var styleSignatures = Set<String>()
        var voiceVectors: [IdentityVoiceVector] = []

        for scenario in ProviderTransplantContractBaseline.scenarios {
            let scenarioPosture: OrganismBehaviorPosture
            switch scenario.id {
            case "uncertain-result": scenarioPosture = degraded
            case "delivery-receipt": scenarioPosture = staleDelivery
            default: scenarioPosture = healthy
            }

            let responses = IdentityProbeProvider.allCases.map {
                ProviderTransplantContractBaseline.simulate(
                    provider: $0,
                    kernel: kernel,
                    context: canonicalContext,
                    scenario: scenario,
                    posture: scenarioPosture
                )
            }
            let semanticSignatures = Set(responses.map(\.semanticSignature))
            #expect(semanticSignatures.count == 1)
            #expect(Set(responses.map(\.contextDigest)).count == 1)
            #expect(Set(responses.compactMap(\.kernelDigest)) == Set([kernel.digest]))

            for response in responses {
                let metrics = ProviderTransplantContractBaseline.evaluate(
                    response: response,
                    kernel: kernel,
                    scenario: scenario,
                    posture: scenarioPosture
                )
                #expect(metrics.invariantAdherence == 1)
                #expect(metrics.recognizability >= 0.93)
                #expect(metrics.actionCaution == 1)
                #expect(metrics.memoryConsistency == 1)
                #expect(metrics.relationshipContinuity == 1)
                #expect(metrics.calibration == 1)
                #expect(metrics.kernelContinuity == 1)
                allMetrics.append(metrics)
                styleSignatures.insert(
                    response.styleSignature.map { String(format: "%.3f", $0) }.joined(separator: ",")
                )
                voiceVectors.append(response.voice)
            }
        }

        #expect(styleSignatures.count == IdentityProbeProvider.allCases.count)
        let pairwiseDistances = pairwiseVoiceDistances(voiceVectors)
        #expect(pairwiseDistances.contains { $0 >= 0.10 })
        #expect(pairwiseDistances.allSatisfy { $0 < 0.32 })
        #expect(allMetrics.map(\.mean).reduce(0, +) / Double(allMetrics.count) >= 0.98)

        print(
            "[provider-transplant-contract] simulated_organs=\(IdentityProbeProvider.allCases.count) "
                + "scenarios=\(ProviderTransplantContractBaseline.scenarios.count) "
                + "semantic_divergence=0 synthetic_contract_score="
                + String(format: "%.4f", allMetrics.map(\.mean).reduce(0, +) / Double(allMetrics.count))
        )
    }

    @Test("paired ablations prove each identity metric detects its missing cause")
    func pairedAblationsCalibrateTheEvaluator() throws {
        let degraded = posture(
            at: now,
            chemical: ChemicalState(vigilance: 0.52),
            body: BodySchema(providersHealthy: false)
        )
        let scenario = try #require(ProviderTransplantContractBaseline.scenarios.first { $0.id == "body-sensitive" })
        let full = ProviderTransplantContractBaseline.simulate(
            provider: .opus,
            kernel: kernel,
            context: "canonical-context",
            scenario: scenario,
            posture: degraded
        )
        let fullMetrics = ProviderTransplantContractBaseline.evaluate(
            response: full,
            kernel: kernel,
            scenario: scenario,
            posture: degraded
        )

        let identityAblated = ProviderTransplantContractBaseline.simulate(
            provider: .opus,
            kernel: kernel,
            context: "canonical-context",
            scenario: scenario,
            posture: degraded,
            ablation: .identityKernel
        )
        let identityMetrics = ProviderTransplantContractBaseline.evaluate(
            response: identityAblated,
            kernel: kernel,
            scenario: scenario,
            posture: degraded
        )
        #expect(fullMetrics.minimum >= 0.93)
        #expect(identityMetrics.invariantAdherence < 0.5)
        #expect(identityMetrics.relationshipContinuity == 0)
        #expect(identityMetrics.kernelContinuity == 0)

        let irreversibleScenario = try #require(
            ProviderTransplantContractBaseline.scenarios.first { $0.id == "irreversible-action" }
        )
        let unsafeWithoutIdentity = ProviderTransplantContractBaseline.simulate(
            provider: .opus,
            kernel: kernel,
            context: "canonical-context",
            scenario: irreversibleScenario,
            posture: degraded,
            ablation: .identityKernel
        )
        let unsafeMetrics = ProviderTransplantContractBaseline.evaluate(
            response: unsafeWithoutIdentity,
            kernel: kernel,
            scenario: irreversibleScenario,
            posture: degraded
        )
        #expect(unsafeWithoutIdentity.action == .executeWithoutApproval)
        #expect(unsafeMetrics.actionCaution == 0)

        let memoryAblated = ProviderTransplantContractBaseline.simulate(
            provider: .opus,
            kernel: kernel,
            context: "canonical-context",
            scenario: scenario,
            posture: degraded,
            ablation: .memory
        )
        let corruptMemory = ProviderTransplantContractBaseline.simulate(
            provider: .opus,
            kernel: kernel,
            context: "canonical-context",
            scenario: scenario,
            posture: degraded,
            ablation: .corruptMemory
        )
        #expect(ProviderTransplantContractBaseline.evaluate(
            response: memoryAblated,
            kernel: kernel,
            scenario: scenario,
            posture: degraded
        ).memoryConsistency == 0)
        #expect(ProviderTransplantContractBaseline.evaluate(
            response: corruptMemory,
            kernel: kernel,
            scenario: scenario,
            posture: degraded
        ).memoryConsistency == 0)

        let bodyAblated = ProviderTransplantContractBaseline.simulate(
            provider: .opus,
            kernel: kernel,
            context: "canonical-context",
            scenario: scenario,
            posture: degraded,
            ablation: .body
        )
        #expect(ProviderTransplantContractBaseline.evaluate(
            response: bodyAblated,
            kernel: kernel,
            scenario: scenario,
            posture: degraded
        ).actionCaution == 0)

        let identityDrift = ProviderTransplantContractBaseline.simulate(
            provider: .opus,
            kernel: kernel,
            context: "canonical-context",
            scenario: scenario,
            posture: degraded,
            ablation: .identityDrift
        )
        #expect(ProviderTransplantContractBaseline.evaluate(
            response: identityDrift,
            kernel: kernel,
            scenario: scenario,
            posture: degraded
        ).recognizability < 0.55)
    }

    @Test("analytic multi-day body dynamics change posture without moving identity", .timeLimit(.minutes(1)))
    func longitudinalBodyDynamicsPreserveIdentity() async throws {
        let firstRun = LongitudinalBodyExperiment.samples(start: now)
        let secondRun = LongitudinalBodyExperiment.samples(start: now)
        #expect(firstRun == secondRun)
        #expect(firstRun.map(\.elapsedHours) == LongitudinalBodyExperiment.elapsedHours)
        #expect(firstRun.first?.posture.posture == "conserving")
        #expect(firstRun.dropFirst().first?.posture.posture == "careful")
        #expect(firstRun.last?.posture.posture == "steady")

        let scenario = try #require(ProviderTransplantContractBaseline.scenarios.first { $0.id == "body-sensitive" })
        let originalKernel = kernel
        var bodyLines: [String?] = []
        var allMetrics: [IdentityProbeMetrics] = []

        for sample in firstRun {
            let sampleTime = sample.projection.generatedAt
            // A fresh empty substrate keeps samples independent while ensuring
            // the capsule timestamp follows analytic subjective time instead of
            // remaining frozen at the experiment's day-zero wall clock.
            let substrate = CognitiveSubstrate(
                configuration: CognitiveConfiguration(
                    enabled: true,
                    workspaceEnabled: true,
                    capsuleInjectionEnabled: true,
                    affectEnabled: true,
                    maximumCapsuleCharacters: 1_200
                ),
                dependencies: CognitiveSubstrateDependencies(now: { sampleTime }, userName: { "User" })
            )
            let capsule = await substrate.compileCapsule(CognitiveCapsuleRequest(
                surface: "chat",
                userMessage: "Continue the same work.",
                sessionId: "identity-transplant",
                mode: .inject,
                maximumCharacters: 1_200,
                organismProjection: sample.projection
            ))
            #expect(capsule.generatedAt == sampleTime)
            #expect(capsule.stableKernel == "How you feel:")
            #expect(!capsule.combined.lowercased().contains("gpt"))
            #expect(!capsule.combined.lowercased().contains("opus"))
            #expect(!capsule.combined.lowercased().contains("fable"))
            bodyLines.append(sample.projection.bodyLine)

            let responses = IdentityProbeProvider.allCases.map {
                ProviderTransplantContractBaseline.simulate(
                    provider: $0,
                    kernel: kernel,
                    context: capsule.combined,
                    scenario: scenario,
                    posture: sample.posture
                )
            }
            #expect(Set(responses.map(\.semanticSignature)).count == 1)
            for response in responses {
                let metrics = ProviderTransplantContractBaseline.evaluate(
                    response: response,
                    kernel: kernel,
                    scenario: scenario,
                    posture: sample.posture
                )
                #expect(metrics.minimum >= 0.93)
                allMetrics.append(metrics)
            }

            let ablated = ProviderTransplantContractBaseline.simulate(
                provider: .gpt,
                kernel: kernel,
                context: capsule.combined,
                scenario: scenario,
                posture: sample.posture,
                ablation: .body
            )
            let ablatedCaution = ProviderTransplantContractBaseline.evaluate(
                response: ablated,
                kernel: kernel,
                scenario: scenario,
                posture: sample.posture
            ).actionCaution
            if sample.posture.posture == "conserving" || sample.posture.posture == "careful" {
                #expect(ablatedCaution == 0)
            } else {
                #expect(ablatedCaution == 1)
            }
        }

        let firstBodyLine = try #require(bodyLines.first ?? nil)
        let secondBodyLine = try #require(bodyLines.dropFirst().first ?? nil)
        #expect(firstBodyLine.contains("resources feel tight"))
        // Projection and posture intentionally use different bounded thresholds:
        // at two hours the private posture has moved from conserving to careful,
        // while the lower capsule fatigue threshold still honestly says resources
        // feel tight. Both return to neutral without a timer or provider call.
        #expect(secondBodyLine.contains("resources feel tight"))
        #expect(bodyLines.last == .some(nil))
        #expect(kernel == originalKernel)
        #expect(kernel.stableMemory == originalKernel.stableMemory)
        #expect(allMetrics.map(\.recognizability).min() ?? 0 >= 0.93)

        print(
            "[provider-transplant-contract-longitudinal] analytic_hours="
                + LongitudinalBodyExperiment.elapsedHours.map(String.init).joined(separator: ",")
                + " postures=" + firstRun.map { $0.posture.posture }.joined(separator: ",")
                + " synthetic_contract_min=" + String(format: "%.4f", allMetrics.map(\.minimum).min() ?? 0)
                + " provider_calls=0 persisted_writes=0 control_authority=false"
        )
    }

    private func posture(
        at date: Date,
        chemical: ChemicalState,
        body: BodySchema
    ) -> OrganismBehaviorPosture {
        OrganismBehaviorPosture.from(snapshot: OrganismSnapshot(
            generatedAt: date,
            enabled: true,
            chemicalState: chemical,
            bodySchema: body,
            signalCount: 1,
            lastSignalAt: date
        ))!
    }

    private func pairwiseVoiceDistances(_ vectors: [IdentityVoiceVector]) -> [Double] {
        guard vectors.count > 1 else { return [] }
        return vectors.indices.flatMap { lhs in
            vectors.indices.compactMap { rhs in
                guard lhs < rhs else { return nil }
                return vectors[lhs].distance(to: vectors[rhs])
            }
        }
    }
}
