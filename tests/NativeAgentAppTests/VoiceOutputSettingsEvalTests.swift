import Foundation
import Testing
@testable import NativeAgentApp

// EVAL FENCE: app.runtimes / voice.output.settings

@MainActor
@Suite("Voice output settings authority", .serialized)
struct VoiceOutputSettingsEvalTests {
    @Test("the mounted settings state distinguishes loading, configured routes, unavailable policy, and failed writes")
    func presentationDoesNotPassAnUnreadablePolicyOffAsMacVoiceConfiguration() throws {
        let local = try policy(ttsOpenAI: false)
        let remote = try policy(ttsOpenAI: true)

        #expect(VoiceOutputSettingsPresentation.resolve(
            trustPolicy: nil,
            hasReadAttempted: false,
            isSaving: false,
            saveFailure: nil
        ).readState == .loading)

        let localState = VoiceOutputSettingsPresentation.resolve(
            trustPolicy: local,
            hasReadAttempted: true,
            isSaving: false,
            saveFailure: nil
        )
        #expect(localState.readState == .available)
        #expect(localState.remoteVoiceEnabled == false)
        #expect(localState.canChangeRemoteVoice)

        let remoteState = VoiceOutputSettingsPresentation.resolve(
            trustPolicy: remote,
            hasReadAttempted: true,
            isSaving: false,
            saveFailure: nil
        )
        #expect(remoteState.remoteVoiceEnabled == true)
        #expect(remoteState.title == "OpenAI voice selected")

        let unavailable = VoiceOutputSettingsPresentation.resolve(
            trustPolicy: nil,
            hasReadAttempted: true,
            isSaving: false,
            saveFailure: nil
        )
        #expect(unavailable.readState == .unavailable)
        #expect(!unavailable.canChangeRemoteVoice)
        #expect(unavailable.canRetry)

        let failed = VoiceOutputSettingsPresentation.resolve(
            trustPolicy: remote,
            hasReadAttempted: true,
            isSaving: false,
            saveFailure: "policy write denied"
        )
        #expect(failed.readState == .saveFailed)
        #expect(failed.remoteVoiceEnabled == true)
        #expect(failed.detail.contains("prior Trust policy remains active"))
        #expect(TrustFeaturePermissionCards.content(for: .multimodal) != nil)
    }

    @Test("the real setting action persists its route, reloads it, and preserves damaged policy bytes on refusal")
    func savingAndReloadingUseTheCanonicalTrustPolicyBoundary() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let app = AppModel(dataRootOverride: root, startBackgroundTasks: false)

        let loaded = await app.refreshVoiceOutputPolicy()
        #expect(loaded)
        var requested = app.trustPolicy?.multimodalPolicy ?? TrustMultimodalPolicy()
        requested.tts_openai = true
        let saved = await app.saveMultimodalPolicy(requested)
        #expect(saved)

        let reloaded = NativeClient(baseURL: "", dataRootOverride: root)
        let durablePolicy = try await reloaded.getTrustPolicy()
        #expect(durablePolicy.multimodalPolicy?.tts_openai == true)
        #expect(VoiceOutputModeSelection.resolve(for: durablePolicy) == .openAI)

        let policyPath = root.appendingPathComponent("trust/policy.json")
        let damaged = Data("{not json".utf8)
        try damaged.write(to: policyPath, options: .atomic)
        let reloadedDamagedPolicy = await app.refreshVoiceOutputPolicy()
        #expect(!reloadedDamagedPolicy)
        #expect(app.trustPolicy == nil)
        #expect(try Data(contentsOf: policyPath) == damaged)

        // The real mounted save action must also refuse damaged authority
        // bytes without rewriting them or retaining the old remote grant.
        let refusedSave = await app.saveMultimodalPolicy(requested)
        #expect(!refusedSave)
        #expect(app.trustPolicy == nil)
        #expect(try Data(contentsOf: policyPath) == damaged)

        let unavailable = VoiceOutputSettingsPresentation.resolve(
            trustPolicy: nil,
            hasReadAttempted: true,
            isSaving: false,
            saveFailure: app.statusText
        )
        #expect(unavailable.readState == .saveFailed)
        #expect(!unavailable.canChangeRemoteVoice)
    }

    private func policy(ttsOpenAI: Bool) throws -> TrustPolicy {
        try JSONDecoder().decode(TrustPolicy.self, from: Data("""
        {"permissionLevel":"balanced","multimodalPolicy":{"tts_openai":\(ttsOpenAI)}}
        """.utf8))
    }

    private func temporaryRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("voice-output-settings-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
}
