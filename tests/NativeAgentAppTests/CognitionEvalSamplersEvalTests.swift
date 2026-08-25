import CognitiveSubstrate
import Foundation
import PersistenceCore
import Testing
@testable import NativeAgentApp

@Suite("Cognition evaluation samplers", .serialized)
struct CognitionEvalSamplersEvalTests {
    private func root(_ label: String) throws -> URL {
        let value = FileManager.default.temporaryDirectory
            .appendingPathComponent("cognition-eval-samplers-\(label)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: value, withIntermediateDirectories: true)
        return value
    }

    private func enabledRuntime(dataRoot: URL) -> NativeCognitionRuntime {
        NativeCognitionRuntime(
            dataRoot: dataRoot,
            configurationOverride: .allPhasesEnabled,
            organismConfigurationOverride: .disabled,
            microcycleSchedulingMode: .manuallyFlushed,
            installedPhysiologySoakEnabled: false
        )
    }

    @Test("records each real sampler exactly once and bounds repeated runs")
    func recordsAllSamplersWithBoundedResults() async throws {
        let dataRoot = try root("complete")
        defer { try? FileManager.default.removeItem(at: dataRoot) }
        let runtime = enabledRuntime(dataRoot: dataRoot)

        let first = await runtime.runResearchHarness()
        #expect(first.isComplete)
        #expect(!first.isFailed)
        #expect(first.recordedKinds == CognitiveExperimentKind.allCases)
        #expect(first.unavailableKinds.isEmpty)

        let second = await runtime.runResearchHarness()
        #expect(second.isComplete)
        let detail = await runtime.observatoryDetail()
        #expect(
            Set(detail.experiments.map(\.kind)) == Set(CognitiveExperimentKind.allCases),
            "each sampler must write its concrete experiment result through the real substrate"
        )
        #expect(
            detail.experiments.count == CognitiveExperimentKind.allCases.count,
            "re-running the fixed sampler set must replace its stable results instead of growing without bound"
        )
    }

    @Test("reports disabled samplers as unavailable rather than a successful empty run")
    func disabledSamplersAreUnavailable() async throws {
        let dataRoot = try root("disabled")
        defer { try? FileManager.default.removeItem(at: dataRoot) }
        let runtime = NativeCognitionRuntime(
            dataRoot: dataRoot,
            configurationOverride: .disabled,
            organismConfigurationOverride: .disabled,
            microcycleSchedulingMode: .manuallyFlushed,
            installedPhysiologySoakEnabled: false
        )

        let outcome = await runtime.runResearchHarness()
        #expect(!outcome.isComplete)
        #expect(!outcome.isFailed)
        #expect(outcome.recordedKinds.isEmpty)
        #expect(outcome.unavailableKinds == CognitiveExperimentKind.allCases)
        #expect(outcome.presentationText.contains("unavailable"))
    }
}
