import Foundation
import ProviderRouting
import Testing
@testable import NativeAgentApp

// EVAL FENCE: app.settings / ui.ProviderSettings.refreshButton
@Suite("Provider Settings refresh button", .serialized)
struct ProviderSettingsRefreshButtonBehaviorEvalTests {
    @Test("the refresh action reads provider and catalog state from its injected app root")
    @MainActor
    func refreshUsesTheInjectedRootForProviderAndModelReads() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try writeCanonicalRouting(to: root)

        let providersDirectory = root.appendingPathComponent("providers", isDirectory: true)
        try JSONSerialization.data(withJSONObject: [[
            "provider_id": "fixture-root-provider",
            "display_name": "Fixture Root Provider",
            "auth_modes": ["api_key"],
            "auth_status": [
                "provider_id": "fixture-root-provider",
                "state": "ready",
                "detail": "fixture credential",
            ],
            "models": [[
                "id": "fixture-root-model",
                "name": "Fixture Root Model",
                "context_length": 8_192,
                "supports_streaming": true,
                "supports_vision": false,
                "supports_tools": true,
                "supports_json_mode": true,
            ]],
        ]], options: [.sortedKeys]).write(
            to: providersDirectory.appendingPathComponent("registry.json"),
            options: .atomic
        )

        let client = NativeClient(baseURL: "", dataRootOverride: root)
        var catalog = try await client.getModelCatalog(refresh: false)
        catalog.models.append(ModelCatalogItem(
            id: "fixture-root-catalog-model",
            displayName: "Fixture Root Catalog Model",
            description: nil,
            defaultReasoningEffort: "high",
            supportedReasoningEfforts: ["low", "high"],
            supportsFast: false,
            priority: 0
        ))
        try JSONEncoder().encode(catalog).write(
            to: providersDirectory.appendingPathComponent("models.json"),
            options: .atomic
        )

        let app = AppModel(dataRootOverride: root, startBackgroundTasks: false)
        let outcome = await ProviderSettingsRefreshAction.perform(
            appModel: app,
            refreshCatalog: true
        )
        guard case let .loaded(snapshot) = outcome else {
            Issue.record("a valid root must produce a refresh receipt, not a failure")
            return
        }
        #expect(snapshot.providers.contains { $0.provider_id == "fixture-root-provider" },
                "the Provider Settings action must not read the default profile's registry")
        #expect(snapshot.catalog?.models.contains { $0.id == "fixture-root-catalog-model" } == true,
                "the Refresh action's model-catalog phase must use the same mounted root")
        #expect(snapshot.activeProviders["chat"] == "codex")
        #expect(snapshot.preferences["chat"]?.model == "gpt-5.6-sol")
    }

    @Test("a damaged routing authority produces a refresh failure receipt rather than a false empty success")
    @MainActor
    func damagedRoutingAuthorityProducesFailureReceipt() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try writeCanonicalRouting(to: root)
        try Data("not valid json".utf8).write(
            to: root.appendingPathComponent("providers/active.json"),
            options: .atomic
        )

        let outcome = await ProviderSettingsRefreshAction.perform(
            appModel: AppModel(dataRootOverride: root, startBackgroundTasks: false),
            refreshCatalog: false
        )
        guard case let .failed(detail) = outcome else {
            Issue.record("damaged active-provider authority must fail the refresh")
            return
        }
        #expect(!detail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        #expect(ProviderSettingsRefreshPresentation.resolve(
            providerCount: 0,
            loadError: detail
        ) == .unavailable(detail))
    }

    private func temporaryRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("provider-settings-refresh-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("providers", isDirectory: true),
            withIntermediateDirectories: true
        )
        return root
    }

    private func writeCanonicalRouting(to root: URL) throws {
        let preferences = Dictionary(uniqueKeysWithValues: MODEL_SURFACES.map {
            ($0, ["model": "gpt-5.6-sol", "reasoningEffort": "high", "serviceTier": "default"])
        })
        let activeProviders = Dictionary(uniqueKeysWithValues: MODEL_SURFACES.map { ($0, "codex") })
        let providersDirectory = root.appendingPathComponent("providers", isDirectory: true)
        try JSONSerialization.data(withJSONObject: preferences, options: [.sortedKeys]).write(
            to: providersDirectory.appendingPathComponent("surfaces.json"), options: .atomic
        )
        try JSONSerialization.data(withJSONObject: activeProviders, options: [.sortedKeys]).write(
            to: providersDirectory.appendingPathComponent("active.json"), options: .atomic
        )
    }
}
