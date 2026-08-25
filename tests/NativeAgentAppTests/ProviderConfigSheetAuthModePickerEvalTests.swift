import Foundation
import Testing
@testable import NativeAgentApp

// EVAL FENCE: app.settings / ui.ProviderConfigSheet.authModePicker
@MainActor
@Suite("Provider configuration auth-mode picker", .serialized)
struct ProviderConfigSheetAuthModePickerEvalTests {
    @Test("the picker normalizes catalog modes, repairs stale saved state, and blocks an empty authority set")
    func authModePickerNeverCreatesAnUntaggedOrUnsupportedSelection() {
        let repaired = ProviderAuthModePickerPresentation.resolve(
            advertisedModes: [" oauth ", "api_key", "oauth", "unsupported"],
            savedMode: "legacy_token",
            providerIsReady: true
        )
        #expect(repaired.supportedModes == ["oauth", "api_key"])
        #expect(repaired.selectedMode == "oauth")
        #expect(repaired.repairedSavedMode == "legacy_token")
        #expect(repaired.canSave)

        let persisted = ProviderAuthModePickerPresentation.resolve(
            advertisedModes: ["api_key", "oauth"],
            savedMode: " API_KEY ",
            providerIsReady: false
        )
        #expect(persisted.selectedMode == "api_key")
        #expect(persisted.repairedSavedMode == nil)

        let unavailable = ProviderAuthModePickerPresentation.resolve(
            advertisedModes: ["legacy_token", ""],
            savedMode: "legacy_token",
            providerIsReady: false
        )
        #expect(unavailable.supportedModes.isEmpty)
        #expect(unavailable.selectedMode.isEmpty)
        #expect(!unavailable.canSave)
    }

    @Test("the selected auth mode persists only in the mounted root and an unsupported mode cannot alter it")
    func selectedAuthModeUsesTheRealScopedWriter() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("provider-auth-mode-picker-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("providers", isDirectory: true),
            withIntermediateDirectories: true
        )

        let client = NativeClient(baseURL: "", dataRootOverride: root)
        _ = try await client.configureProvider(
            "openai",
            apiKey: "fixture-key",
            authMode: " API_KEY ",
            defaultModel: "gpt-5.6-sol"
        )
        let configurationURL = root.appendingPathComponent("providers/openai.json")
        let persisted = try Data(contentsOf: configurationURL)
        let object = try JSONSerialization.jsonObject(with: persisted) as? [String: Any]
        #expect(object?["auth_mode"] as? String == "api_key")
        #expect(object?["default_model"] as? String == "gpt-5.6-sol")

        await #expect(throws: (any Error).self) {
            _ = try await client.configureProvider(
                "openai",
                apiKey: nil,
                authMode: "oauth",
                defaultModel: nil
            )
        }
        #expect(try Data(contentsOf: configurationURL) == persisted,
                "a rejected Picker value must not replace the last valid provider configuration")
    }
}
