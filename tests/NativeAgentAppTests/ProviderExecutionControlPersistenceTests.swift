import Foundation
import Testing
import NativeAgentCore
@testable import NativeAgentApp

@Suite("Provider execution-control persistence", .serialized)
struct ProviderExecutionControlPersistenceTests {
    @Test func moonshotIsFirstClassAndCacheFilesAreNotFakeProviders() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("provider-moonshot-\(UUID().uuidString)", isDirectory: true)
        let providers = root.appendingPathComponent("providers", isDirectory: true)
        try FileManager.default.createDirectory(at: providers, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data(#"{"schema_version":1,"models":[]}"#.utf8)
            .write(to: providers.appendingPathComponent("moonshot-models-cache.json"))
        try Data(#"{"schema_version":1,"models":[]}"#.utf8)
            .write(to: providers.appendingPathComponent("openrouter-models-cache.json"))

        let rows = try await NativeClient(baseURL: "").listProviders(
            dataRoot: root,
            codexCacheURL: root.appendingPathComponent("missing-model-cache.json"),
            authEnvironment: [:]
        )
        let moonshot = try #require(rows.first { $0.provider_id == "moonshot" })
        #expect(moonshot.display_name == "Moonshot AI (Kimi)")
        #expect(moonshot.auth_modes == ["api_key"])
        #expect(moonshot.auth_status.state == "needs_key")
        let k3 = try #require(moonshot.models.first { $0.id == "kimi-k3" })
        #expect(k3.context_length == 1_048_576)
        #expect(k3.supported_reasoning_efforts == ["max"])
        #expect(k3.supports_streaming)
        #expect(k3.supports_vision)
        #expect(k3.supports_tools)
        #expect(rows.contains { $0.provider_id.contains("models-cache") } == false)
    }

    @Test func pendingSurfaceRecoveryMarkerIsNotListedAsAProvider() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("provider-pending-marker-\(UUID().uuidString)", isDirectory: true)
        let providers = root.appendingPathComponent("providers", isDirectory: true)
        try FileManager.default.createDirectory(at: providers, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try Data(#"{"schemaVersion":1}"#.utf8).write(
            to: providers.appendingPathComponent("pending-surface-configuration.json")
        )

        let rows = try await NativeClient(baseURL: "").listProviders(
            dataRoot: root,
            codexCacheURL: root.appendingPathComponent("missing-model-cache.json"),
            authEnvironment: [:]
        )
        #expect(rows.contains { $0.provider_id == "pending-surface-configuration" } == false)
    }

    @Test func appProviderMutationsPreserveCorruptPickerState() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("provider-corruption-\(UUID().uuidString)", isDirectory: true)
        let providers = root.appendingPathComponent("providers", isDirectory: true)
        try FileManager.default.createDirectory(at: providers, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let surfaces = providers.appendingPathComponent("surfaces.json")
        let active = providers.appendingPathComponent("active.json")
        let damagedSurface = Data("{bad-surface".utf8)
        let damagedActive = Data("[\"bad-active\"]".utf8)
        try damagedSurface.write(to: surfaces)
        try Data("{}".utf8).write(to: active)
        await #expect(throws: (any Error).self) {
            try await NativeClient.writeSurfacePref(
                surface: "chat",
                model: "gpt-5.6-sol",
                reasoningEffort: "high",
                serviceTier: "default",
                dataRoot: root
            )
        }
        #expect(try Data(contentsOf: surfaces) == damagedSurface)

        try Data("{}".utf8).write(to: surfaces)
        try damagedActive.write(to: active)
        await #expect(throws: (any Error).self) {
            try await NativeClient.writeActiveProvider(
                surface: "chat",
                providerID: "openai_oauth_direct",
                dataRoot: root
            )
        }
        #expect(try Data(contentsOf: active) == damagedActive)
    }

    @Test func inferredProviderSavePreflightsCorruptActiveStateBeforeSurfaceCommit() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("provider-preflight-\(UUID().uuidString)", isDirectory: true)
        let providers = root.appendingPathComponent("providers", isDirectory: true)
        try FileManager.default.createDirectory(at: providers, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let surfaces = providers.appendingPathComponent("surfaces.json")
        let active = providers.appendingPathComponent("active.json")
        let originalSurface = Data(#"{"chat":{"model":"claude-opus-4-8"}}"#.utf8)
        let damagedActive = Data("not-json".utf8)
        try originalSurface.write(to: surfaces)
        try damagedActive.write(to: active)

        await #expect(throws: (any Error).self) {
            _ = try await NativeClient(baseURL: "").configureModel(
                surface: "chat",
                model: "gpt-5.6-sol",
                reasoningEffort: "high",
                inferProvider: true,
                dataRoot: root,
                codexCacheURL: root.appendingPathComponent("missing-models.json")
            )
        }
        #expect(try Data(contentsOf: surfaces) == originalSurface)
        #expect(try Data(contentsOf: active) == damagedActive)
    }

    @Test func thinkAndFastSavesPreserveTheExplicitAuthRoute() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("provider-control-persistence-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let client = NativeClient(baseURL: "http://127.0.0.1")
        for providerID in ["openai", "openai_oauth_direct", "codex"] {
            try await NativeClient.writeActiveProvider(
                surface: "chat",
                providerID: providerID,
                dataRoot: root
            )

            _ = try await client.configureModel(
                surface: "chat",
                model: "gpt-5.6-sol",
                reasoningEffort: "ultra",
                serviceTier: "priority",
                dataRoot: root,
                codexCacheURL: root.appendingPathComponent("missing-models-cache.json")
            )

            let active = try await NativeClient.readActiveProvidersFromDisk(dataRoot: root)
            #expect(active["chat"] == providerID)
        }
    }

    @Test func accountAndPublicCatalogsKeepTheirDistinctGPT56Capabilities() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("provider-model-scope-\(UUID().uuidString)", isDirectory: true)
        let providers = root.appendingPathComponent("providers", isDirectory: true)
        // An injected root is a distinct runtime body. Its account auth lives
        // at the root-owned Codex home; an arbitrary process CODEX_HOME must
        // not redirect provider readiness outside that canonical boundary.
        let codexHome = root.appendingPathComponent("codex_home", isDirectory: true)
        try FileManager.default.createDirectory(at: providers, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: codexHome, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try Data(#"{"api_key":"test-only"}"#.utf8)
            .write(to: providers.appendingPathComponent("openai.json"))
        // Saving provider preferences creates this credential-free placeholder.
        // It must not shadow the real account auth or its signed model catalog.
        try Data(#"{"auth_mode":"oauth","default_model":"gpt-5.6-sol"}"#.utf8)
            .write(to: providers.appendingPathComponent("openai_oauth_direct.json"))
        try Data(#"{"auth_mode":"chatgpt","tokens":{"access_token":"test-access","refresh_token":"test-refresh","account_id":"account-test"}}"#.utf8)
            .write(to: codexHome.appendingPathComponent("auth.json"))
        try Data(#"{"models":[{"slug":"gpt-5.6-sol","display_name":"Sol","default_reasoning_level":"low","supported_reasoning_levels":[{"effort":"low"},{"effort":"ultra"}],"additional_speed_tiers":["fast"],"service_tiers":[{"id":"priority"}],"supported_in_api":true,"visibility":"list"}]}"#.utf8)
            .write(to: codexHome.appendingPathComponent("models_cache.json"))

        let providersList = try await NativeClient(baseURL: "http://127.0.0.1").listProviders(
            dataRoot: root,
            codexCacheURL: codexHome.appendingPathComponent("models_cache.json"),
            authEnvironment: ["CODEX_HOME": codexHome.path]
        )
        let codex = try #require(providersList.first { $0.provider_id == "codex" })
        let apiKey = try #require(providersList.first { $0.provider_id == "openai" })
        let oauth = try #require(providersList.first { $0.provider_id == "openai_oauth_direct" })

        #expect(codex.models.contains { $0.id == "gpt-5.6-sol" })
        let publicSol = try #require(apiKey.models.first { $0.id == "gpt-5.6-sol" })
        #expect(publicSol.supported_reasoning_efforts == ["none", "low", "medium", "high", "xhigh", "max"])
        #expect(publicSol.supported_reasoning_efforts?.contains("ultra") == false)
        #expect(oauth.auth_status.state == "ready")
        let oauthSol = try #require(oauth.models.first { $0.id == "gpt-5.6-sol" })
        #expect(oauthSol.supported_reasoning_efforts == ["low", "ultra"])
        #expect(oauthSol.supports_fast == true)
    }

    @Test func staleGlobalCatalogCannotShadowVerifiedFirstPartyCapabilities() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("provider-global-catalog-\(UUID().uuidString)", isDirectory: true)
        let providers = root.appendingPathComponent("providers", isDirectory: true)
        let codexHome = root.appendingPathComponent("codex-home", isDirectory: true)
        try FileManager.default.createDirectory(at: providers, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: codexHome, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let stale = ModelCatalogResponse(
            status: "ok",
            source: "stale-test",
            defaultModel: "claude-sonnet-5",
            fallbackModels: [],
            models: [ModelCatalogItem(
                id: "claude-sonnet-5",
                displayName: "STALE Sonnet",
                description: nil,
                defaultReasoningEffort: "high",
                supportedReasoningEfforts: ["high"],
                supportsFast: true,
                priority: 0
            )],
            reasoningEfforts: [],
            current: ModelRoutingCurrent(
                chat: ModelSurfacePreference(surface: "chat", model: "claude-sonnet-5", reasoningEffort: "high"),
                telegram: ModelSurfacePreference(surface: "telegram", model: "claude-sonnet-5", reasoningEffort: "high"),
                ios: nil,
                executions: nil,
                autonomy: nil,
                swarms: nil,
                dream: nil,
                training: nil
            ),
            updatedAt: nil
        )
        try JSONEncoder().encode(stale)
            .write(to: providers.appendingPathComponent("models.json"))

        let catalog = try await NativeClient(baseURL: "http://127.0.0.1")
            .getModelCatalog(
                refresh: false,
                dataRoot: root,
                codexCacheURL: codexHome.appendingPathComponent("models_cache.json")
            )
        let sonnet = try #require(catalog.models.first { $0.id == "claude-sonnet-5" })
        #expect(sonnet.displayName == "Claude Sonnet 5")
        #expect(sonnet.supportedReasoningEfforts == ["low", "medium", "high", "xhigh", "max"])
        #expect(sonnet.supportsFast == false)
        let grok = try #require(catalog.models.first { $0.id == "grok-4.5" })
        #expect(grok.supportedReasoningEfforts == ["low", "medium", "high"])
        #expect(grok.supportsFast == true)
        #expect(catalog.current.chat.model == nativeAgentPrimaryModel)
        #expect(catalog.current.telegram.model == nativeAgentPrimaryModel)
    }
}
