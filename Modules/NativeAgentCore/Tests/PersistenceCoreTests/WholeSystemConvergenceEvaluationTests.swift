import Foundation
@testable import NativeAgentEvaluation
import Testing
@testable import PersistenceCore

@Suite("Whole-system convergence evaluation")
struct WholeSystemConvergenceEvaluationTests {
    private let digest = String(repeating: "a", count: 64)

    @Test("repeatable ablation loss is detected from paired exact trials")
    func causalLossDetection() throws {
        let report = try evaluate(
            declaration: .init(
                ablation: .contextUtilityShuffled,
                claimMode: .repeatableLoss,
                primaryMetrics: [.contextRelevance]
            ),
            baseline: [.measured(.contextRelevance, [0.90, 0.88, 0.92, 0.89])],
            ablated: [.measured(.contextRelevance, [0.61, 0.60, 0.64, 0.62])]
        )

        let ablation = try #require(report.ablations.first)
        let metric = try #require(ablation.comparisons.first { $0.metric == .contextRelevance })
        #expect(ablation.verdict == .passed)
        #expect(metric.status == .repeatableLossDetected)
        #expect(metric.signedLoss != nil && metric.signedLoss! > 0.25)
        #expect(metric.lossDirectionFraction == 1)
        #expect(report.generatedFixtureOnly)
        #expect(report.providerCallCount == 0)
        #expect(report.canonicalStateMutationCount == 0)
        #expect(!report.promptAuthority)
        #expect(!report.actionAuthority)
    }

    @Test("local repair remains neutral when only the Dream provider lane is removed")
    func neutralAblation() throws {
        let report = try evaluate(
            declaration: .init(
                ablation: .dreamProviderLaneDisabledLocalRepairRemains,
                claimMode: .parity,
                primaryMetrics: [.taskSuccess]
            ),
            baseline: [.measured(.taskSuccess, [0.82, 0.81, 0.83, 0.82])],
            ablated: [.measured(.taskSuccess, [0.81, 0.82, 0.82, 0.81])]
        )

        let ablation = try #require(report.ablations.first)
        let metric = try #require(ablation.comparisons.first { $0.metric == .taskSuccess })
        #expect(ablation.verdict == .passed)
        #expect(metric.status == .parity)
        #expect(metric.status != .repeatableLossDetected)
    }

    @Test("missing and censored evidence stays numeric-free and inconclusive")
    func missingAndCensoredEvidenceIsNotInferred() throws {
        let report = try evaluate(
            declaration: .init(
                ablation: .usedMemoryReturnEdgeRemoved,
                claimMode: .repeatableLoss,
                primaryMetrics: [.contextRelevance]
            ),
            baseline: [.missing(.contextRelevance, reason: .privacyExcluded)],
            ablated: [.censored(.contextRelevance, reason: .belowDisclosureThreshold)]
        )

        let ablation = try #require(report.ablations.first)
        let metric = try #require(ablation.comparisons.first { $0.metric == .contextRelevance })
        #expect(ablation.verdict == .inconclusive)
        #expect(metric.status == .inconclusiveCensored)
        #expect(metric.baselineMean == nil)
        #expect(metric.ablatedMean == nil)
        #expect(metric.signedLoss == nil)
        #expect(metric.pairedTrialCount == 0)
    }

    @Test("reports and digests are deterministic across input ordering")
    func deterministicReport() throws {
        let declaration = WholeSystemAblationDeclaration(
            ablation: .providerSwapped,
            claimMode: .continuity,
            primaryMetrics: [.identityContractAdherence]
        )
        let manifest = makeManifest(
            declaration,
            requiredGates: [.featureOffBehaviorParity, .publicSafePreOnboardingNeutral],
            performanceLimits: [
                .init(metric: .addedRoutingProviderCalls, maximum: 0),
                .init(metric: .addedPromptBytes, maximum: 0),
            ],
            fossil: [.residentState, .providerIndependentIdentityContract]
        )
        let trial = makeTrial(
            declaration.ablation,
            baseline: [.measured(.identityContractAdherence, [0.97, 0.96, 0.98])],
            ablated: [.measured(.identityContractAdherence, [0.96, 0.97, 0.97])]
        )
        let first = try WholeSystemConvergenceEvaluator.evaluate(
            manifest: manifest,
            trials: [trial],
            gates: [gate(.featureOffBehaviorParity), gate(.publicSafePreOnboardingNeutral)],
            performance: [
                .measured(.addedRoutingProviderCalls, 0),
                .measured(.addedPromptBytes, 0),
            ],
            fossilEvidence: [fossil(.residentState), fossil(.providerIndependentIdentityContract)]
        )
        let second = try WholeSystemConvergenceEvaluator.evaluate(
            manifest: manifest,
            trials: [trial],
            gates: [gate(.publicSafePreOnboardingNeutral), gate(.featureOffBehaviorParity)],
            performance: [
                .measured(.addedPromptBytes, 0),
                .measured(.addedRoutingProviderCalls, 0),
            ],
            fossilEvidence: [fossil(.providerIndependentIdentityContract), fossil(.residentState)]
        )

        #expect(first == second)
        #expect(first.artifactDigestSHA256 == second.artifactDigestSHA256)
        #expect(first.artifactDigestSHA256.count == 64)
        #expect(first.overallVerdict == .passed)
    }

    @Test("feature-off, public-safe, privacy, and authority parity are explicit gates")
    func publicSafeAndFeatureOffParity() throws {
        let required: [WholeSystemGate] = [
            .featureOffByteParity,
            .featureOffBehaviorParity,
            .publicSafePreOnboardingNeutral,
            .publicSafeNoPrivateFixture,
            .publicSafeNoReleaseArtifact,
            .publicSafeNoCredentialMigration,
            .privacyPayloadFree,
            .privacyNoRawPath,
            .privacyNoProviderPayload,
            .privacyNoUnapprovedPersonalEvidence,
            .authorityTrustDenial,
            .authorityApprovalNotBypassed,
            .authorityNoPermissionControl,
            .authorityNoActionControl,
        ]
        let declaration = WholeSystemAblationDeclaration(
            ablation: .dreamProviderLaneDisabledLocalRepairRemains,
            claimMode: .parity,
            primaryMetrics: [.taskSuccess]
        )
        let manifest = makeManifest(declaration, requiredGates: required)
        let report = try WholeSystemConvergenceEvaluator.evaluate(
            manifest: manifest,
            trials: [makeTrial(
                declaration.ablation,
                baseline: [.measured(.taskSuccess, [0.9, 0.9, 0.9])],
                ablated: [.measured(.taskSuccess, [0.9, 0.9, 0.9])]
            )],
            gates: required.map(gate),
            performance: [],
            fossilEvidence: []
        )

        #expect(report.overallVerdict == .passed)
        #expect(report.gates.count == required.count)
        #expect(report.gates.allSatisfy { $0.verdict == .passed })
        #expect(report.generatedFixtureOnly)
        #expect(!report.permissionAuthority)
        #expect(!report.identityAuthority)
        #expect(!report.memoryAuthority)
        #expect(!report.adaptiveInfluenceAuthority)
    }

    @Test("a measured performance budget regression fails the report")
    func performanceBudgetFailure() throws {
        let declaration = WholeSystemAblationDeclaration(
            ablation: .dreamProviderLaneDisabledLocalRepairRemains,
            claimMode: .parity,
            primaryMetrics: [.taskSuccess]
        )
        let manifest = makeManifest(
            declaration,
            performanceLimits: [.init(metric: .outcomeMetadataP95Milliseconds, maximum: 1)]
        )
        let report = try WholeSystemConvergenceEvaluator.evaluate(
            manifest: manifest,
            trials: [makeTrial(
                declaration.ablation,
                baseline: [.measured(.taskSuccess, [0.8, 0.8, 0.8])],
                ablated: [.measured(.taskSuccess, [0.8, 0.8, 0.8])]
            )],
            gates: [],
            performance: [.measured(.outcomeMetadataP95Milliseconds, 1.01)],
            fossilEvidence: []
        )

        #expect(report.overallVerdict == .failed)
        let performance = try #require(report.performance.first)
        #expect(performance.verdict == .failed)
        #expect(performance.measuredValue == 1.01)
        #expect(performance.maximum == 1)
    }

    private func evaluate(
        declaration: WholeSystemAblationDeclaration,
        baseline: [WholeSystemMetricObservation],
        ablated: [WholeSystemMetricObservation]
    ) throws -> WholeSystemConvergenceReport {
        try WholeSystemConvergenceEvaluator.evaluate(
            manifest: makeManifest(declaration),
            trials: [makeTrial(declaration.ablation, baseline: baseline, ablated: ablated)],
            gates: [],
            performance: [],
            fossilEvidence: []
        )
    }

    private func makeManifest(
        _ declaration: WholeSystemAblationDeclaration,
        requiredGates: [WholeSystemGate] = [],
        performanceLimits: [WholeSystemPerformanceLimit] = [],
        fossil: [WholeSystemFossilDimension] = []
    ) -> WholeSystemConvergenceManifest {
        WholeSystemConvergenceManifest(
            manifestVersion: "generated.wave12.test.v1",
            declarations: [declaration],
            thresholds: WholeSystemMetric.allCases.map {
                switch $0 {
                case .latencyMilliseconds:
                    .init(metric: $0, minimumMeaningfulLoss: 10, parityTolerance: 25)
                case .providerCalls:
                    .init(metric: $0, minimumMeaningfulLoss: 0.25, parityTolerance: 0.25)
                default:
                    .init(metric: $0, minimumMeaningfulLoss: 0.02, parityTolerance: 0.02)
                }
            },
            requiredGates: requiredGates,
            performanceLimits: performanceLimits,
            requiredFossilDimensions: fossil
        )
    }

    private func makeTrial(
        _ ablation: WholeSystemAblation,
        baseline: [WholeSystemMetricObservation],
        ablated: [WholeSystemMetricObservation]
    ) -> WholeSystemAblationTrial {
        WholeSystemAblationTrial(
            ablation: ablation,
            evidenceClass: .generatedDeterministic,
            matchedConditionDigestSHA256: digest,
            baseline: WholeSystemMetricSet(observations: baseline),
            ablated: WholeSystemMetricSet(observations: ablated),
            executionEffects: .noControl
        )
    }

    private func gate(_ value: WholeSystemGate) -> WholeSystemGateObservation {
        WholeSystemGateObservation(gate: value, status: .passed, evidenceDigestSHA256: digest)
    }

    private func fossil(_ value: WholeSystemFossilDimension) -> WholeSystemFossilObservation {
        WholeSystemFossilObservation(dimension: value, status: .passed, evidenceDigestSHA256: digest)
    }
}
