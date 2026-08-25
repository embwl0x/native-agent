import Foundation
import Testing
@testable import NativeAgentApp

@MainActor
@Suite("Organism observatory toggle", .serialized)
struct OrganismObservatoryMountedEvalTests {
    private func root() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("organism-mounted-toggle-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test("organism toggle control commits ON and OFF across a runtime restart")
    func organismToggleReachesRuntimeAndPreference() async throws {
        let dataRoot = try root()
        defer { try? FileManager.default.removeItem(at: dataRoot) }
        try Data("complete\n".utf8).write(to: dataRoot.appendingPathComponent(".onboarded"))
        let suite = "NativeAgentTests.OrganismToggle.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let key = NativeCognitionRuntime.organismKernelEnabledKey
        defaults.set(false, forKey: key)
        defaults.set("controls", forKey: "cognitionObservatoryExpandedPanels")
        let now = Date(timeIntervalSince1970: 1_785_974_400)
        let runtime = NativeCognitionRuntime(
            dataRoot: dataRoot,
            configurationOverride: .allPhasesEnabled,
            preferenceDefaults: NativeCognitionPreferenceDefaults(defaults: defaults),
            now: { now },
            monotonicNowNanoseconds: { 42 },
            microcycleSchedulingMode: .manuallyFlushed,
            installedPhysiologySoakEnabled: false
        )
        await runtime.bootstrap()
        #expect(!(await runtime.organismSnapshot()).enabled)

        let initialControl = CognitionObservatoryOrganismControlPresentation(
            cognitiveSubstrateEnabled: true,
            organismKernelEnabled: false
        )
        #expect(initialControl.isEnabled)
        #expect(!initialControl.isOn)
        #expect(CognitionObservatoryOrganismControlPresentation.label == "Organism body kernel")

        await runtime.setOrganismKernelEnabled(true)

        let continuity = dataRoot.appendingPathComponent("cognition/organism_state.json")
        #expect(defaults.bool(forKey: key))
        #expect((await runtime.organismSnapshot()).enabled)
        #expect(FileManager.default.fileExists(atPath: continuity.path))
        let enabledControl = CognitionObservatoryOrganismControlPresentation(
            cognitiveSubstrateEnabled: true,
            organismKernelEnabled: (await runtime.organismSnapshot()).enabled
        )
        #expect(enabledControl.isEnabled)
        #expect(enabledControl.isOn)

        await runtime.setOrganismKernelEnabled(false)

        #expect(defaults.object(forKey: key) as? Bool == false)
        #expect(!(await runtime.organismSnapshot()).enabled)
        #expect(FileManager.default.fileExists(atPath: continuity.path))
        let disabledControl = CognitionObservatoryOrganismControlPresentation(
            cognitiveSubstrateEnabled: true,
            organismKernelEnabled: (await runtime.organismSnapshot()).enabled
        )
        #expect(disabledControl.isEnabled)
        #expect(!disabledControl.isOn)
        #expect(!CognitionObservatoryOrganismControlPresentation(
            cognitiveSubstrateEnabled: false,
            organismKernelEnabled: true
        ).isEnabled)

        let relaunchedRuntime = NativeCognitionRuntime(
            dataRoot: dataRoot,
            configurationOverride: .allPhasesEnabled,
            preferenceDefaults: NativeCognitionPreferenceDefaults(defaults: defaults),
            now: { now },
            monotonicNowNanoseconds: { 43 },
            microcycleSchedulingMode: .manuallyFlushed,
            installedPhysiologySoakEnabled: false
        )
        await relaunchedRuntime.bootstrap()
        #expect(!(await relaunchedRuntime.organismSnapshot()).enabled)
    }
}
