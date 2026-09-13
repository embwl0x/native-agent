import Foundation
import ProviderRouting
import Testing
@testable import NativeAgentApp

// EVAL FENCE: app.settings / ui.ProviderConfigSheet.modelPicker
@Suite("Provider config sheet model picker", .serialized)
struct ProviderConfigSheetModelPickerEvalTests {
    private func root() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("provider-config-model-picker-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("providers", isDirectory: true),
            withIntermediateDirectories: true
        )
        return root
    }

    /// The sheet calls this production client method. Its only durable model
    /// authority is providers/<id>.json; a per-surface pin must remain exactly
    /// as it was for a later surface-row reader.
    @Test("saving a provider default preserves every surface pin")
    func sheetSaveWritesProviderDefaultWithoutMutatingSurfacePins() async throws {
        let dataRoot = try root()
        defer { try? FileManager.default.removeItem(at: dataRoot) }
        let surfacesURL = dataRoot
            .appendingPathComponent("providers", isDirectory: true)
            .appendingPathComponent("surfaces.json")
        let originalSurfaces = try JSONSerialization.data(withJSONObject: [
            "chat": ["model": "surface-pinned-model", "reasoningEffort": "high"],
            "dream": ["model": "different-surface-pin", "reasoningEffort": "low"],
        ], options: [.sortedKeys])
        try originalSurfaces.write(to: surfacesURL, options: .atomic)

        let client = NativeClient(baseURL: "http://unused", dataRootOverride: dataRoot)
        _ = try await client.configureProvider(
            "openai",
            apiKey: "eval-only-key",
            authMode: "api_key",
            defaultModel: "provider-default-model"
        )

        let providerURL = dataRoot
            .appendingPathComponent("providers", isDirectory: true)
            .appendingPathComponent("openai.json")
        let provider = try #require(
            try JSONSerialization.jsonObject(with: Data(contentsOf: providerURL)) as? [String: Any]
        )
        #expect(provider["default_model"] as? String == "provider-default-model")
        #expect(provider["auth_mode"] as? String == "api_key")
        let persistedSurfaces = try Data(contentsOf: surfacesURL)
        #expect(persistedSurfaces == originalSurfaces)

        // A fresh routing reader proves the unchanged bytes still express the
        // old saved picks, rather than merely comparing a stale in-memory copy.
        // 2026-09-13 (second review): a per-app pick is kept and shown, but only
        // the group's choice routes — so `dream` RUNS on Chat's model while its
        // saved key is still there to see and clear.
        let routing = SwiftNativeProviderRouting(dataRoot: dataRoot)
        let snapshot = try await routing.checkedRoutingSnapshot()
        #expect(snapshot.pinnedModels["chat"] == "surface-pinned-model")
        #expect(snapshot.pinnedModels["dream"] == "different-surface-pin")
        #expect(snapshot.preferences["chat"]?.model == "surface-pinned-model")
        #expect(snapshot.preferences["dream"]?.model == "surface-pinned-model")
    }

    @Test("missing catalog and stale saved default have visible, non-coercing states")
    func pickerPresentationKeepsAdverseSelectionVisible() {
        #expect(
            ProviderConfigModelPickerPresentation.resolve(
                selectedModel: "saved-but-retired",
                advertisedModelIDs: ["current-model"]
            ) == .staleSelection("saved-but-retired")
        )
        let stale = ProviderConfigModelPickerPresentation.resolve(
            selectedModel: "saved-but-retired",
            advertisedModelIDs: ["current-model"]
        )
        #expect(stale.needsReplacement)
        #expect(stale.message?.contains("saved-but-retired") == true)
        #expect(
            ProviderConfigModelPickerPresentation.resolve(
                selectedModel: "current-model",
                advertisedModelIDs: ["current-model"]
            ) == .selected
        )
        #expect(
            ProviderConfigModelPickerPresentation.resolve(
                selectedModel: "saved-but-unverifiable",
                advertisedModelIDs: []
            ) == .noCatalog
        )
        #expect(
            ProviderConfigModelPickerPresentation.resolve(
                selectedModel: "saved-but-unverifiable",
                advertisedModelIDs: []
            ).message?.contains("unavailable") == true
        )
    }
}
