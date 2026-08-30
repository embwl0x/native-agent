import CognitiveSubstrate
import ChatOrchestration
import Context
import Foundation
import NativeAgentCore
import PersistenceCore
import ProviderRouting
import Testing
@testable import NativeAgentApp

// EVAL — ledger fence app.runtimes, Wave 2.
//
// These tests drive the production runtime decision points on injected roots.
// They deliberately avoid source inspection and default data: a regression has
// to change an observed provider tier, a persisted artifact, a runtime
// projection, or a concrete push-to-talk action to remain green.
//
// Covered surface IDs:
// - cognition.physiology.soakEnableGate
// - cognition.organism.persistenceGeneration
// - cognition.pursuit.observation
// - cognition.reflection.scheduleEventDriven
// - cognition.observatoryDetail
// - cognition.research.export
// - cognition.providerVitals.snapshot
// - client.chat.fastModeServiceTier
// - client.chat.personaOverride
// - contextflow.memoryPressureSource
// - voice.input.pushToTalk
// - voice.pushToTalk

private actor Wave2AttemptProbe {
    private var writes = 0
    private let failingWrite: Int

    init(failingWrite: Int) {
        self.failingWrite = failingWrite
    }

    func write(_ state: OrganismPersistentState, to url: URL) async throws {
        writes += 1
        if writes == failingWrite {
            throw CocoaError(.fileWriteUnknown)
        }
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(state).write(to: url, options: .atomic)
    }

    var count: Int { writes }
}

private actor Wave2Reasons {
    private var values: [String] = []
    func append(_ value: String) { values.append(value) }
    var all: [String] { values }
}

@Suite("App runtimes behavior Wave 2", .serialized)
struct AppRuntimesBehaviorWave2EvalTests {
    private func root(_ label: String) throws -> URL {
        let value = FileManager.default.temporaryDirectory
            .appendingPathComponent("app-runtimes-wave2-\(label)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: value, withIntermediateDirectories: true)
        return value
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

    @Test("installed physiology is opt-in and bootstrap emits generated proof evidence")
    func physiologySoakEnableGate() async throws {
        let disabledRoot = try root("soak-off")
        defer { try? FileManager.default.removeItem(at: disabledRoot) }
        #expect(NativeCognitionRuntime.resolveInstalledPhysiologySoakEnablement(
            dataRoot: disabledRoot,
            isTestProcess: false
        ) == .disabledNonDefaultDataRoot)
        #expect(NativeCognitionRuntime.resolveInstalledPhysiologySoakEnablement(
            dataRoot: PersistenceCore.defaultDataRoot(),
            isTestProcess: false
        ) == .disabledByDefault)
        #expect(NativeCognitionRuntime.resolveInstalledPhysiologySoakEnablement(
            dataRoot: PersistenceCore.defaultDataRoot(),
            isTestProcess: true
        ) == .disabledTestProcess)
        let disabled = NativeCognitionRuntime(
            dataRoot: disabledRoot,
            configurationOverride: configuration()
        )
        await disabled.bootstrap()
        #expect(await disabled.installedPhysiologySoakCollectionStatus() == .disabledNonDefaultDataRoot)
        #expect(await disabled.installedPhysiologySoakReport() == nil)

        let enabledRoot = try root("soak-on")
        defer { try? FileManager.default.removeItem(at: enabledRoot) }
        let recorder = InstalledPhysiologySoakRecorder(
            dataRoot: enabledRoot,
            runtimeInstanceID: "wave2-start",
            evidenceClass: .generatedAccelerated,
            coalescingDelayNanoseconds: 0
        )
        let enabled = NativeCognitionRuntime(
            dataRoot: enabledRoot,
            configurationOverride: configuration(),
            physiologySoakRecorderOverride: recorder
        )
        await enabled.bootstrap()
        #expect(await enabled.installedPhysiologySoakCollectionStatus() == .injectedEvidence)
        let report = try #require(await enabled.installedPhysiologySoakReport())
        #expect(report.runtimeSessionCount == 1,
                "bootstrap must settle a runtime_started receipt into the installed cadence")
        #expect(report.evidenceClasses == [.generatedAccelerated],
                "proof injection must not be mislabeled as installed elapsed evidence")
    }

    @Test("a failed organism generation resolves false and a later generation can recover")
    func organismPersistenceGeneration() async throws {
        let dataRoot = try root("organism-persistence")
        defer { try? FileManager.default.removeItem(at: dataRoot) }
        // Bootstrap owns generation one. Make the next caller-visible
        // generation fail so the assertion observes the exact write it names.
        let probe = Wave2AttemptProbe(failingWrite: 2)
        let runtime = NativeCognitionRuntime(
            dataRoot: dataRoot,
            configurationOverride: configuration(),
            organismConfigurationOverride: .enabled,
            microcycleSchedulingMode: .manuallyFlushed,
            installedPhysiologySoakEnabled: false,
            organismPersistenceWriterOverride: { state, url in
                try await probe.write(state, to: url)
            }
        )
        await runtime.bootstrap()

        #expect(await runtime.persistOrganismContinuity(reason: "intentional-failure") == false,
                "the first writer failure must resolve the caller false, not strand or report success")
        let afterFailure = await runtime.organismPersistenceStatusForProof()
        #expect(afterFailure.requestedGeneration == afterFailure.completedGeneration)
        #expect(!afterFailure.drainActive)

        #expect(await runtime.persistOrganismContinuity(reason: "recovery") == true,
                "a failed generation must not permanently poison the persistence drain")
        let afterRecovery = await runtime.organismPersistenceStatusForProof()
        #expect(afterRecovery.requestedGeneration == afterRecovery.completedGeneration)
        #expect(!afterRecovery.drainActive)
        #expect(await probe.count == 3)
    }

    @Test("a Desk pursuit reaches the bounded resident attention projection")
    func pursuitObservation() async throws {
        let dataRoot = try root("pursuit")
        defer { try? FileManager.default.removeItem(at: dataRoot) }
        let absent = NativeCognitionRuntime(
            dataRoot: dataRoot,
            configurationOverride: configuration(),
            installedPhysiologySoakEnabled: false
        )
        await absent.startPursuitRefresh(waitForCompletion: true)
        #expect(await absent.pursuitCandidateCountForProof() == 0)
        #expect(await absent.attentionSignals(at: Date())?.activeTask == nil,
                "an absent Desk feed must remain visibly empty, never fabricate a pursuit")
        let pursuit = Pursuit(
            why: String(repeating: "keep this deliberate pursuit visible ", count: 12),
            evidence: PromotionDossier(citations: [.feltSalience(dates: ["2026-08-23", "2026-08-24"])]),
            doneLooksLike: String(repeating: "the bounded projection has a clear finish ", count: 12),
            abandonCondition: "stop after the proof"
        )
        let store = SwiftNativeDeskStore(dataRoot: dataRoot)
        _ = try await store.openPursuit(project: "eval", title: "projection", pursuit: pursuit)
        let runtime = NativeCognitionRuntime(
            dataRoot: dataRoot,
            configurationOverride: configuration(),
            installedPhysiologySoakEnabled: false,
            pursuitStateLoaderOverride: { try await store.liveState() }
        )

        await runtime.startPursuitRefresh(waitForCompletion: true)
        #expect(await runtime.pursuitCandidateCountForProof() == 1)
        let attention = try #require(await runtime.attentionSignals(at: Date()))
        #expect(attention.activeTask?.count ?? 0 <= 200)
        #expect(attention.goal?.count ?? 0 <= 200)
        #expect(attention.activeTask?.hasPrefix("keep this deliberate pursuit") == true)
        #expect(attention.goal?.hasPrefix("the bounded projection") == true)
    }

    @Test("a Desk feed created after bootstrap invalidates and refreshes the resident pursuit")
    func pursuitObservationRefreshesAfterFeedCreation() async throws {
        let dataRoot = try root("pursuit-created-after-bootstrap")
        defer { try? FileManager.default.removeItem(at: dataRoot) }
        let store = SwiftNativeDeskStore(dataRoot: dataRoot)
        let runtime = NativeCognitionRuntime(
            dataRoot: dataRoot,
            configurationOverride: configuration(),
            installedPhysiologySoakEnabled: false,
            pursuitStateLoaderOverride: { try await store.liveState() }
        )
        await runtime.bootstrap()
        #expect(await runtime.pursuitCandidateCountForProof() == 0,
                "the absence state must remain empty before the Desk feed is created")

        // Bootstrap owns the observation subscription. The runtime has no
        // reference to this store beyond its production loader, so this later
        // store write can reach the resident projection only through the real
        // desk_ops.jsonl invalidation path.
        try? await Task.sleep(nanoseconds: 150_000_000)
        let pursuit = Pursuit(
            why: "refresh only when the Desk event arrives",
            evidence: PromotionDossier(citations: [.feltSalience(dates: ["2026-08-23", "2026-08-24"])]),
            doneLooksLike: "the observer updates the resident projection",
            abandonCondition: "the bounded event window expires"
        )
        _ = try await store.openPursuit(project: "eval", title: "observed", pursuit: pursuit)

        var observed = false
        for _ in 0..<50 {
            if await runtime.pursuitCandidateCountForProof() == 1 {
                observed = true
                break
            }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        #expect(observed,
                "a newly-created desk_ops.jsonl must refresh pursuit within the bounded event window")
        #expect(await runtime.attentionSignals(at: Date())?.activeTask == "refresh only when the Desk event arrives")
    }

    @Test("event-driven reflection coalesces while active and rearms after completion")
    func reflectionScheduleEventDriven() async throws {
        let dataRoot = try root("reflection")
        defer { try? FileManager.default.removeItem(at: dataRoot) }
        let reasons = Wave2Reasons()
        let runtime = NativeCognitionRuntime(
            dataRoot: dataRoot,
            configurationOverride: configuration(),
            installedPhysiologySoakEnabled: false,
            eventDrivenReflectionOperationOverride: { reason in
                await reasons.append(reason)
            }
        )

        await runtime.scheduleEventDrivenReflection(reason: "first")
        await runtime.scheduleEventDrivenReflection(reason: "coalesced")
        await runtime.drainEventDrivenReflectionForProof()
        #expect(await runtime.eventDrivenReflectionAttemptCountForProof() == 1)
        #expect(await reasons.all == ["first"])

        await runtime.scheduleEventDrivenReflection(reason: "rearmed")
        await runtime.drainEventDrivenReflectionForProof()
        #expect(await runtime.eventDrivenReflectionAttemptCountForProof() == 2)
        #expect(await reasons.all == ["first", "rearmed"])
    }

    @Test("observatory projection preserves computed experiment and faculty lanes")
    func observatoryDetail() async throws {
        let dataRoot = try root("observatory")
        defer { try? FileManager.default.removeItem(at: dataRoot) }
        let runtime = NativeCognitionRuntime(
            dataRoot: dataRoot,
            configurationOverride: configuration(),
            organismConfigurationOverride: .disabled,
            installedPhysiologySoakEnabled: false
        )
        await runtime.bootstrap()
        await runtime.runResearchHarness()

        let detail = await runtime.observatoryDetail()
        #expect(Set(detail.experiments.map(\.kind)) == Set(CognitiveExperimentKind.allCases))
        #expect(!detail.facultyMeasurements.isEmpty)
        #expect(detail.welfareBounds.generatedAt.timeIntervalSince1970 > 0)
        #expect(detail.lastResearchExportPath == nil,
                "the detail must distinguish unexported research from an export path")
    }

    @Test("research export returns parseable bytes and updates only after a successful write")
    func researchExport() async throws {
        let dataRoot = try root("export")
        defer { try? FileManager.default.removeItem(at: dataRoot) }
        let runtime = NativeCognitionRuntime(
            dataRoot: dataRoot,
            configurationOverride: configuration(),
            organismConfigurationOverride: .disabled,
            installedPhysiologySoakEnabled: false
        )
        await runtime.runResearchHarness()
        let first = try #require(await runtime.exportResearchTrace())
        let second = try #require(await runtime.exportResearchTrace())
        #expect(first != second,
                "two completed exports must retain distinct artifacts even inside one clock second")
        for path in Set([first, second]) {
            let bytes = try Data(contentsOf: URL(fileURLWithPath: path))
            #expect((try JSONSerialization.jsonObject(with: bytes)) is [String: Any])
        }
        var latest = second
        for _ in 0..<19 { latest = try #require(await runtime.exportResearchTrace()) }
        let exports = try FileManager.default.contentsOfDirectory(
            at: dataRoot.appendingPathComponent("cognition/exports", isDirectory: true),
            includingPropertiesForKeys: nil
        ).filter { $0.lastPathComponent.hasPrefix("cognitive-research-") && $0.pathExtension == "json" }
        #expect(exports.count == 20,
                "the export owner must retain its named 20-artifact bound rather than leak every export")
        #expect(FileManager.default.fileExists(atPath: latest),
                "retention must preserve the export just reported to the observatory")
        #expect(await runtime.observatoryDetail().lastResearchExportPath == latest)

        // A blocked export directory is a real persistence failure, not an
        // "unexported" success. The runtime must return no path and retain no
        // stale path for this fresh observatory instance.
        let failedRoot = try root("export-failed")
        defer { try? FileManager.default.removeItem(at: failedRoot) }
        let cognitionDirectory = failedRoot.appendingPathComponent("cognition", isDirectory: true)
        try FileManager.default.createDirectory(at: cognitionDirectory, withIntermediateDirectories: true)
        try Data("not-a-directory".utf8).write(
            to: cognitionDirectory.appendingPathComponent("exports"),
            options: .atomic
        )
        let failed = NativeCognitionRuntime(
            dataRoot: failedRoot,
            configurationOverride: configuration(),
            organismConfigurationOverride: .disabled,
            installedPhysiologySoakEnabled: false
        )
        await failed.runResearchHarness()
        #expect(await failed.exportResearchTrace() == nil)
        #expect(await failed.observatoryDetail().lastResearchExportPath == nil,
                "a failed write must not be rendered as a completed export")
    }

    @Test("provider vitals remain in memory until the termination-owned snapshot path runs")
    func providerVitalsSnapshot() async throws {
        let dataRoot = try root("provider-vitals")
        defer { try? FileManager.default.removeItem(at: dataRoot) }
        let runtime = NativeCognitionRuntime(
            dataRoot: dataRoot,
            configurationOverride: configuration(),
            organismConfigurationOverride: .disabled,
            installedPhysiologySoakEnabled: false
        )
        let started = LLMCallLifecycleEvent(
            id: "vitals-turn", phase: .started, providerId: "eval-provider", model: "eval-model",
            surface: "chat", sessionId: "session", turnId: "turn", streaming: false, occurredAt: Date()
        )
        await runtime.feedProviderVitals(started)
        await runtime.feedProviderVitals(started.terminal(.succeeded))
        let path = dataRoot.appendingPathComponent("telemetry/provider_vitals.json")
        #expect(!FileManager.default.fileExists(atPath: path.path),
                "observing a turn must not add disk I/O to the turn path")

        await runtime.flushForTermination()
        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: path)) as? [String: Any]
        let providers = object?["providers"] as? [String: Any]
        #expect(providers?["eval-provider"] != nil,
                "the termination snapshot must contain the observed provider, not a success-shaped empty file")
    }

    @Test("chat fast mode only buys priority on the Mac chat surface")
    func chatFastModeServiceTier() {
        #expect(NativeChatTurnOptions.resolve(personaRawValue: nil, fastModeEnabled: false, surface: "chat").serviceTier == nil)
        #expect(NativeChatTurnOptions.resolve(personaRawValue: nil, fastModeEnabled: true, surface: "chat").serviceTier == "priority")
        #expect(NativeChatTurnOptions.resolve(personaRawValue: nil, fastModeEnabled: true, surface: "telegram").serviceTier == nil)
    }

    @Test("picker storage and provider call share the exact normalized persona")
    @MainActor
    func chatPersonaOverride() {
        #expect(NativeChatTurnOptions.normalizedPickerPersona("  agent  ") == "agent")
        #expect(NativeChatTurnOptions.normalizedPickerPersona(" \n ") == "AI")
        let model = AppModel()
        model.chatPersona = "  agent  "
        #expect(model.chatPersona == "agent")
        #expect(NativeChatTurnOptions.resolve(personaRawValue: model.chatPersona, fastModeEnabled: false, surface: "chat").persona == model.chatPersona)
    }

    @Test("memory-pressure mapping is queue-safe and critical wins over warning")
    func memoryPressureSource() async {
        let fromDetachedQueue = await Task.detached {
            NativeContextFlowRuntime.memoryPressureLevel(hasCritical: true, hasWarning: true)
        }.value
        #expect(fromDetachedQueue == .critical)
        #expect(NativeContextFlowRuntime.memoryPressureLevel(hasCritical: false, hasWarning: true) == .warning)
        #expect(NativeContextFlowRuntime.memoryPressureLevel(hasCritical: false, hasWarning: false) == .normal)
    }

    @Test("push-to-talk release never leaves an armed hold without its matching end")
    @MainActor
    func pushToTalkRelease() async throws {
        #expect(GlobalHotkeyManager.voiceReleaseAction(heldSeconds: 0.19, voiceHoldActive: false) == .openWindow)
        #expect(GlobalHotkeyManager.voiceReleaseAction(heldSeconds: 0.20, voiceHoldActive: false) == .openWindow,
                "a cancelled arm must not invent an unmatched voice end")
        #expect(GlobalHotkeyManager.voiceReleaseAction(heldSeconds: 0.20, voiceHoldActive: true) == .endVoice)
        #expect(GlobalHotkeyManager.voiceReleaseAction(heldSeconds: 4, voiceHoldActive: true) == .endVoice)
        let manager = GlobalHotkeyManager.shared
        var starts = 0
        var ends = 0
        var opens = 0
        manager.onVoiceStart = { starts += 1 }
        manager.onVoiceEnd = { ends += 1 }
        manager.onOpenWindow = { opens += 1 }
        defer {
            manager.onVoiceStart = nil
            manager.onVoiceEnd = nil
            manager.onOpenWindow = nil
            manager.unregister()
        }
        manager.handleKeyDown()
        try await Task.sleep(for: .milliseconds(220))
        manager.handleKeyUp()
        #expect(starts == 1 && ends == 1 && opens == 0)
        manager.handleKeyDown()
        manager.handleKeyUp()
        try await Task.sleep(for: .milliseconds(220))
        #expect(starts == 1 && ends == 1 && opens == 1,
                "a tap cancels its arm; it must not leak a delayed start or end")
    }
}
