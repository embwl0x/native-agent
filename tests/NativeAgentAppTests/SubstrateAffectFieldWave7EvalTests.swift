import CognitiveSubstrate
import Foundation
import Testing
@testable import NativeAgentApp

// EVAL — ledger fence core.substrate.affect, Wave 7.
//
// These are runtime control proofs. They use an isolated UserDefaults suite
// only to feed the production configuration reader, then drive the real turn
// projection. No source inspection is used as a substitute for the outcome.

@Suite("Substrate affect and field Wave 7", .serialized)
struct SubstrateAffectFieldWave7EvalTests {
    private func root(_ label: String) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("substrate-affect-field-wave7-\(label)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func livedTurn(_ id: String) -> CognitiveEvent {
        CognitiveEvent(
            id: id,
            kind: .userMessageReceived,
            subject: CognitiveSubjectReference(type: "conversation", id: id, label: "User"),
            sourceClass: .userStated,
            occurredAt: Date(),
            summary: "I really appreciate you. I miss you and I am glad we are working through this together.",
            importance: 0.9,
            turnKind: .live
        )
    }

    private func request() -> CognitiveCapsuleRequest {
        CognitiveCapsuleRequest(
            surface: "chat",
            userMessage: "How are you feeling after that?",
            sessionId: "wave7-affect-session",
            mode: .inject
        )
    }

    @Test("master and capsule controls drive production configuration into a real turn projection")
    func cognitiveControlsDriveRuntimeFanoutAndCapsuleOutcome() async throws {
        let suite = "substrate-affect-field-wave7-controls-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let dataRoot = try root("control-actions")
        defer { try? FileManager.default.removeItem(at: dataRoot) }

        // This is the runtime instance the real CognitionObservatory bindings
        // address. Only its durable preference owner is isolated; neither the
        // mutation methods nor the configuration/projection path is replaced.
        let runtime = NativeCognitionRuntime(
            dataRoot: dataRoot,
            preferenceDefaults: NativeCognitionPreferenceDefaults(defaults: defaults),
            configurationEnvironment: [:],
            organismConfigurationOverride: .disabled,
            microcycleSchedulingMode: .manuallyFlushed,
            installedPhysiologySoakEnabled: false
        )

        await runtime.setEnabled(true)
        #expect(defaults.object(forKey: "cognitiveSubstrateEnabled") as? Bool == true,
                "the real UI action did not persist its master control")
        let masterOn = await runtime.subconsciousRuntimeState()
        #expect(masterOn.enabled)
        #expect(masterOn.capsuleEnabled,
                "an unset capsule control must remain default-on after the master action")
        let loadedOn = NativeCognitionRuntime.loadConfiguration(defaults: defaults, environment: [:])
        #expect(loadedOn.affectEnabled)
        #expect(loadedOn.observatoryEnabled)

        await runtime.observe(livedTurn("wave7-capsule-on"))
        let onProjection = await runtime.prepareTurnProjection(request())
        let injected = try #require(onProjection.capsule)
        #expect(injected.mode == .inject)
        #expect(!injected.dynamicContext.isEmpty,
                "a lived turn with the default-on capsule control must reach provider projection")

        // Actuate the exact capsule setter used by the mounted Toggle. Its
        // persisted value must immediately change the same runtime projection.
        await runtime.setCapsuleEnabled(false)
        #expect(defaults.object(forKey: "cognitiveSubstrateCapsuleEnabled") as? Bool == false)
        let capsuleOff = await runtime.subconsciousRuntimeState()
        #expect(capsuleOff.enabled)
        #expect(!capsuleOff.capsuleEnabled)
        let offProjection = await runtime.prepareTurnProjection(request())
        #expect(offProjection.capsule == nil,
                "a disabled capsule control must be visibly off, never a quiet successful projection")

        // Leave the sub-toggle persisted ON, then turn the master OFF through
        // its real action. The master gate must dominate both the resident
        // runtime and a fresh runtime loading the durable store.
        await runtime.setCapsuleEnabled(true)
        await runtime.setEnabled(false)
        #expect(defaults.object(forKey: "cognitiveSubstrateEnabled") as? Bool == false)
        #expect(defaults.object(forKey: "cognitiveSubstrateCapsuleEnabled") as? Bool == true)
        let masterOff = await runtime.subconsciousRuntimeState()
        #expect(!masterOff.enabled)
        #expect(!masterOff.capsuleEnabled)
        #expect(await runtime.prepareTurnProjection(request()).capsule == nil)

        let reloaded = NativeCognitionRuntime(
            dataRoot: dataRoot,
            preferenceDefaults: NativeCognitionPreferenceDefaults(defaults: defaults),
            configurationEnvironment: [:],
            organismConfigurationOverride: .disabled,
            microcycleSchedulingMode: .manuallyFlushed,
            installedPhysiologySoakEnabled: false
        )
        let reloadedState = await reloaded.subconsciousRuntimeState()
        #expect(!reloadedState.enabled)
        #expect(!reloadedState.capsuleEnabled)
        let loadedOff = NativeCognitionRuntime.loadConfiguration(defaults: defaults, environment: [:])
        #expect(!loadedOff.affectEnabled)
        #expect(!loadedOff.observatoryEnabled)
        #expect(await reloaded.prepareTurnProjection(request()).capsule == nil)
    }

}
