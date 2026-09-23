import Foundation
import Testing
@testable import NativeAgentApp

// EVAL FENCE: app.runtimes / voice.output.settings

@MainActor
@Suite("Voice output settings authority", .serialized)
struct VoiceOutputSettingsEvalTests {
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
    }

    private func temporaryRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("voice-output-settings-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
}
