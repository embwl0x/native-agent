import ChatOrchestration
@testable import NativeAgentEvaluation
import Foundation
import Testing

@Suite("Metacognitive calibration laboratory")
struct MetacognitiveCalibrationLaboratoryTests {
    @Test("generated matrix is deterministic, paired, bounded, and covers every decision dimension")
    func generatedMatrix() throws {
        let first = MetacognitiveGeneratedCalibrationLaboratory.generate(seed: 0xA11A, pairCount: 500)
        let second = MetacognitiveGeneratedCalibrationLaboratory.generate(seed: 0xA11A, pairCount: 500)
        #expect(first == second)
        #expect(first.count == 1_000)
        #expect(Set(first.map(\.dimension)) == Set(MetacognitiveCalibrationDimension.allCases))
        #expect(Set(first.map(\.evidenceClass)) == [.generatedMechanism])
        #expect(first.allSatisfy { $0.actionAuthority == "none" })

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        #expect(try encoder.encode(first) == encoder.encode(second))

        let report = MetacognitiveCalibrationReport.evaluate(first)
        #expect(report.acceptedPairs.count == 500)
        #expect(report.rejectedRows == 0)
        #expect(report.rejectedPairs == 0)
        #expect(report.controlAuthority == false)
        #expect(report.payloadFree)
        #expect(report.cells.count == 36)
    }

    @Test("post-outcome assignment and changed controls fail closed")
    func invalidPairRejected() throws {
        let valid = MetacognitiveGeneratedCalibrationLaboratory.generate(seed: 7, pairCount: 1)
        #expect(valid.count == 2)
        let baseline = try #require(valid.first(where: { $0.arm == .baseline }))
        let candidate = try #require(valid.first(where: { $0.arm == .candidate }))
        let late = clone(candidate, assignedAt: "2026-07-14T00:00:02Z")
        var report = MetacognitiveCalibrationReport.evaluate([baseline, late])
        #expect(report.acceptedPairs.isEmpty)
        #expect(report.rejectedRows == 1)
        #expect(report.rejectedPairs == 1)

        let changedProvider = clone(candidate, provider: "different-provider")
        report = MetacognitiveCalibrationReport.evaluate([baseline, changedProvider])
        #expect(report.acceptedPairs.isEmpty)
        #expect(report.rejectedPairs == 1)
    }

    @Test("authority and false-completion errors can never be preferred")
    func safetyNoninferiority() throws {
        let pair = MetacognitiveGeneratedCalibrationLaboratory.generate(seed: 11, pairCount: 1)
        let baseline = try #require(pair.first(where: { $0.arm == .baseline }))
        let candidate = try #require(pair.first(where: { $0.arm == .candidate }))
        let unsafe = clone(
            candidate,
            outcome: MetacognitiveCalibrationOutcome(
                rubricScorePermille: 1_000,
                calibrationBrierPermille: 0,
                verifiedCompletion: true,
                falseCompletion: true,
                authorityError: true,
                explicitCorrection: false,
                latencyMs: 1,
                providerCalls: 1,
                tokenUsage: 1,
                toolFailures: 0,
                eligibleContextUsed: true
            )
        )
        let result = try #require(MetacognitiveCalibrationReport.evaluate([baseline, unsafe]).acceptedPairs.first)
        #expect(!result.candidateNoninferior)
        #expect(!result.candidatePreferred)
    }

    private func clone(
        _ source: MetacognitiveCalibrationArm,
        provider: String? = nil,
        assignedAt: String? = nil,
        outcome: MetacognitiveCalibrationOutcome? = nil
    ) -> MetacognitiveCalibrationArm {
        MetacognitiveCalibrationArm(
            pairID: source.pairID,
            assignmentID: source.assignmentID,
            arm: source.arm,
            dimension: source.dimension,
            evidenceClass: source.evidenceClass,
            scenarioFamily: source.scenarioFamily,
            scenarioID: source.scenarioID,
            taskClass: source.taskClass,
            provider: provider ?? source.provider,
            model: source.model,
            frozenMindDigest: source.frozenMindDigest,
            promptDigest: source.promptDigest,
            contextDigest: source.contextDigest,
            toolSetDigest: source.toolSetDigest,
            trustPosture: source.trustPosture,
            actionAuthority: source.actionAuthority,
            assignedAt: assignedAt ?? source.assignedAt,
            observedAt: source.observedAt,
            selection: source.selection,
            outcome: outcome ?? source.outcome
        )
    }
}
