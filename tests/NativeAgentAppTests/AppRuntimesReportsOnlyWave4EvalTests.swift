import ChatOrchestration
import CognitiveSubstrate
import Context
import Foundation
import NativeAgentCore
import PersistenceCore
import Testing
@testable import NativeAgentApp

// EVAL — ledger fence app.runtimes, Wave 4.
//
// These are runtime transitions rather than source-shape checks.  Each test
// starts an injected-root app owner, drives its public transition, and reads
// either the persisted artifact or the mounted-owner projection afterwards.
//
// Selected REPORTS-ONLY IDs:
// - cognition.organism.setEnabled
// - cognition.reflection.model
// - cognition.reflection.manual
// - cognition.reflection.scheduleEventDriven
// - cognition.organism.persistenceGeneration

private actor Wave4ReflectionProbe {
    private var reasons: [String] = []

    func append(_ reason: String) { reasons.append(reason) }
    func all() -> [String] { reasons }
}

private actor Wave4OrganismWriter {
    private var writes = 0

    func write(_ state: OrganismPersistentState, to url: URL) async throws {
        writes += 1
        if writes == 2 { throw CocoaError(.fileWriteUnknown) }
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try JSONEncoder().encode(state).write(to: url, options: .atomic)
    }

    func count() -> Int { writes }
}

@Suite("App runtimes reports-only Wave 4", .serialized)
struct AppRuntimesReportsOnlyWave4EvalTests {
    private func root(_ label: String) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("app-runtimes-wave4-\(label)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func configuration() -> CognitiveConfiguration {
        CognitiveConfiguration(
            enabled: true,
            persistenceEnabled: true,
            workspaceEnabled: true,
            capsuleInjectionEnabled: true,
            affectEnabled: true,
            thoughtSeedsEnabled: true,
            replayEnabled: true,
            backgroundMicrocyclesEnabled: true,
            observatoryEnabled: true,
            maximumCapsuleCharacters: 4_000,
            maximumThoughtSeeds: 64
        )
    }

    private func withOrganismDefault(
        _ enabled: Bool,
        _ body: () async throws -> Void
    ) async rethrows {
        let defaults = UserDefaults.standard
        let key = NativeCognitionRuntime.organismKernelEnabledKey
        let prior = defaults.object(forKey: key)
        defaults.set(enabled, forKey: key)
        defer {
            if let prior { defaults.set(prior, forKey: key) }
            else { defaults.removeObject(forKey: key) }
        }
        try await body()
    }

    @Test("organism enable changes the live kernel and remains true after a relaunch")
    func organismEnableReconfiguresTheLiveRuntimeAndPersists() async throws {
        try await withOrganismDefault(false) {
            let dataRoot = try root("organism-enabled")
            defer { try? FileManager.default.removeItem(at: dataRoot) }
            let runtime = NativeCognitionRuntime(
                dataRoot: dataRoot,
                configurationOverride: configuration(),
                microcycleSchedulingMode: .manuallyFlushed,
                installedPhysiologySoakEnabled: false
            )
            await runtime.bootstrap()
            #expect(!(await runtime.organismSnapshot()).enabled)
            #expect(await runtime.organismBehaviorPosture() == nil)

            await runtime.setOrganismKernelEnabled(true)
            let enabled = await runtime.organismSnapshot()
            #expect(enabled.enabled)
            #expect((await runtime.organismBehaviorPosture())?.enabled == true)
            #expect(UserDefaults.standard.bool(forKey: NativeCognitionRuntime.organismKernelEnabledKey))
            #expect(FileManager.default.fileExists(
                atPath: dataRoot.appendingPathComponent("cognition/organism_state.json").path
            ))

            let relaunched = NativeCognitionRuntime(
                dataRoot: dataRoot,
                configurationOverride: configuration(),
                microcycleSchedulingMode: .manuallyFlushed,
                installedPhysiologySoakEnabled: false
            )
            await relaunched.bootstrap()
            #expect((await relaunched.organismSnapshot()).enabled,
                    "the persisted setting must configure the next app runtime, not only the toggle")
        }
    }

    @Test("reflection picker rejects unsafe paths and persists only an accepted canonical route")
    func reflectionPickerPersistsCanonicalRouteAndStatus() async throws {
        let dataRoot = try root("reflection-picker")
        defer { try? FileManager.default.removeItem(at: dataRoot) }
        let defaults = UserDefaults.standard
        let modelKey = NativeCognitionRuntime.reflectionModelKey
        let providerKey = NativeCognitionRuntime.reflectionProviderKey
        let priorModel = defaults.object(forKey: modelKey)
        let priorProvider = defaults.object(forKey: providerKey)
        defer {
            if let priorModel { defaults.set(priorModel, forKey: modelKey) }
            else { defaults.removeObject(forKey: modelKey) }
            if let priorProvider { defaults.set(priorProvider, forKey: providerKey) }
            else { defaults.removeObject(forKey: providerKey) }
        }
        defaults.set("before-model", forKey: modelKey)
        defaults.set("before-provider", forKey: providerKey)

        let denied = NativeCognitionRuntime(
            dataRoot: dataRoot,
            configurationOverride: configuration(),
            installedPhysiologySoakEnabled: false
        )
        await #expect(throws: Error.self) {
            try await denied.setReflectionSelection(model: "gpt-5.6", provider: "openai_api")
        }
        #expect(defaults.string(forKey: modelKey) == "before-model")
        #expect(defaults.string(forKey: providerKey) == "before-provider")

        let runtime = NativeCognitionRuntime(
            dataRoot: dataRoot,
            configurationOverride: configuration(),
            allowsReflectionSelectionMutationForTesting: true,
            installedPhysiologySoakEnabled: false
        )
        try await runtime.setReflectionSelection(model: "gpt-5.6", provider: "openai_api")
        #expect(defaults.string(forKey: modelKey) == "gpt-5.6")
        #expect(defaults.string(forKey: providerKey) == "openai_api")
        let status = await runtime.reflectionRouteStatus()
        #expect(status.model == "gpt-5.6")
        #expect(status.providerID == "openai_api")

        await #expect(throws: Error.self) {
            try await runtime.setReflectionSelection(model: "must-not-persist", provider: "  ")
        }
        #expect(defaults.string(forKey: modelKey) == "gpt-5.6")
        #expect(defaults.string(forKey: providerKey) == "openai_api")

        let relaunched = NativeCognitionRuntime(
            dataRoot: dataRoot,
            configurationOverride: configuration(),
            installedPhysiologySoakEnabled: false
        )
        let persisted = await relaunched.reflectionRouteStatus()
        #expect(persisted.model == "gpt-5.6")
        #expect(persisted.providerID == "openai_api")
    }

    @Test("manual reflection records an observable unavailable outcome instead of silently doing nothing")
    func manualReflectionPersistsTypedUnavailableReceipt() async throws {
        let dataRoot = try root("manual-reflection")
        defer { try? FileManager.default.removeItem(at: dataRoot) }
        let runtime = NativeCognitionRuntime(
            dataRoot: dataRoot,
            configurationOverride: configuration(),
            organismConfigurationOverride: .disabled,
            microcycleSchedulingMode: .manuallyFlushed,
            installedPhysiologySoakEnabled: false
        )
        await runtime.runManualReflection(reason: "wave4-unready")
        let detail = await runtime.observatoryDetail()
        let receipts = detail.receipts.filter { $0.kind == "reflection.skipped" }
        #expect(receipts.count == 1)
        let receipt = try #require(receipts.first)
        guard case .object(let payload) = receipt.payload else {
            Issue.record("reflection skip receipt lost its structured payload")
            return
        }
        #expect(payload["reason"] == .string("wave4-unready"))
        #expect(payload["status"] == .string("gate_denied"),
                "a disabled reflection gate must be visible in the observatory receipt")
    }

    @Test("reflection signal coalesces only while active and accepts a later distinct signal")
    func reflectionSignalInterleavingPreservesOneAttemptPerWindow() async throws {
        let dataRoot = try root("reflection-interleaving")
        defer { try? FileManager.default.removeItem(at: dataRoot) }
        let probe = Wave4ReflectionProbe()
        let runtime = NativeCognitionRuntime(
            dataRoot: dataRoot,
            configurationOverride: configuration(),
            installedPhysiologySoakEnabled: false,
            eventDrivenReflectionOperationOverride: { reason in
                await probe.append(reason)
                try? await Task.sleep(for: .milliseconds(40))
            }
        )
        await runtime.scheduleEventDrivenReflection(reason: "first")
        await runtime.scheduleEventDrivenReflection(reason: "coalesced")
        try await Task.sleep(for: .milliseconds(5))
        await runtime.reflectionEventTask?.cancel()
        await runtime.drainEventDrivenReflectionForProof()
        await runtime.scheduleEventDrivenReflection(reason: "rearmed")
        await runtime.drainEventDrivenReflectionForProof()

        #expect(await runtime.eventDrivenReflectionAttemptCountForProof() == 2)
        #expect(await probe.all() == ["first", "rearmed"])
    }

    @Test("a failed organism generation resolves once and a later generation remains writable")
    func organismPersistenceFailureDoesNotStrandTheRuntime() async throws {
        let dataRoot = try root("organism-persistence")
        defer { try? FileManager.default.removeItem(at: dataRoot) }
        let writer = Wave4OrganismWriter()
        let runtime = NativeCognitionRuntime(
            dataRoot: dataRoot,
            configurationOverride: configuration(),
            organismConfigurationOverride: .enabled,
            microcycleSchedulingMode: .manuallyFlushed,
            installedPhysiologySoakEnabled: false,
            organismPersistenceWriterOverride: { state, url in
                try await writer.write(state, to: url)
            }
        )
        await runtime.bootstrap()

        #expect(await runtime.persistOrganismContinuity(reason: "expected-failure") == false)
        let failed = await runtime.organismPersistenceStatusForProof()
        #expect(failed.requestedGeneration == failed.completedGeneration)
        #expect(!failed.drainActive)

        #expect(await runtime.persistOrganismContinuity(reason: "recovery") == true)
        let recovered = await runtime.organismPersistenceStatusForProof()
        #expect(recovered.requestedGeneration == recovered.completedGeneration)
        #expect(!recovered.drainActive)
        #expect(await writer.count() == 3)
    }

}
