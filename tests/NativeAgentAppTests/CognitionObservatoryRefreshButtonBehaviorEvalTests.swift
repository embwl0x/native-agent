import Foundation
import Testing
@testable import NativeAgentApp

@Suite("Cognition Observatory refresh button behavior", .serialized)
struct CognitionObservatoryRefreshButtonBehaviorEvalTests {
    private func temporaryRoot(_ label: String) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cognition-observatory-refresh-\(label)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    // app.mind / ui.cognitionObservatory.button.refresh
    @Test("the refresh action reads the real runtime configuration and its newest completion owns the visible generation")
    @MainActor func refreshReadsRuntimeAndRejectsAnOlderCompletion() async throws {
        let root = try temporaryRoot("newest-wins")
        defer { try? FileManager.default.removeItem(at: root) }
        let runtime = NativeCognitionRuntime(
            dataRoot: root,
            configurationOverride: .allPhasesEnabled,
            organismConfigurationOverride: .disabled,
            microcycleSchedulingMode: .manuallyFlushed,
            installedPhysiologySoakEnabled: false
        )
        await runtime.bootstrap()
        await runtime.setEnabled(true)

        let detail = await CognitionObservatoryActions.refresh(runtime: runtime)
        #expect(detail.configuration.enabled)

        let coordinator = CognitionObservatoryRefreshCoordinator()
        let olderGeneration = coordinator.begin()
        #expect(coordinator.isRefreshing)
        let newestGeneration = coordinator.begin()
        #expect(coordinator.settle(newestGeneration) == .accepted)
        #expect(!coordinator.isRefreshing)
        #expect(coordinator.settle(olderGeneration) == .superseded)
        #expect(!coordinator.isRefreshing)
    }

    // app.mind / ui.cognitionObservatory.button.refresh
    @Test("a completed refresh can be followed by another real runtime read without retaining the earlier snapshot")
    @MainActor func acceptedRefreshesRemainRepeatable() async throws {
        let root = try temporaryRoot("repeat")
        defer { try? FileManager.default.removeItem(at: root) }
        let suite = "cognition-observatory-refresh-repeat-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let runtime = NativeCognitionRuntime(
            dataRoot: root,
            preferenceDefaults: NativeCognitionPreferenceDefaults(defaults: defaults),
            configurationEnvironment: [:],
            organismConfigurationOverride: .disabled,
            microcycleSchedulingMode: .manuallyFlushed,
            installedPhysiologySoakEnabled: false
        )
        await runtime.bootstrap()
        let coordinator = CognitionObservatoryRefreshCoordinator()

        let first = coordinator.begin()
        let firstDetail = await CognitionObservatoryActions.refresh(runtime: runtime)
        #expect(coordinator.settle(first) == .accepted)
        #expect(!firstDetail.configuration.enabled)

        await runtime.setEnabled(true)
        let second = coordinator.begin()
        let secondDetail = await CognitionObservatoryActions.refresh(runtime: runtime)
        #expect(coordinator.settle(second) == .accepted)
        #expect(secondDetail.configuration.enabled)
    }
}
