import Foundation
import Testing
@testable import NativeAgentApp

@Test func codexPreviewCatalogLoadsAccountVisibleGPT56Capabilities() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("CodexSelectableModelCatalogTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let path = root.appendingPathComponent("models_cache.json")
    try Data(#"""
    {"models":[
      {"slug":"gpt-5.6-sol","display_name":"GPT-5.6-Sol","description":"frontier","default_reasoning_level":"low","supported_reasoning_levels":[{"effort":"low"},{"effort":"medium"},{"effort":"high"},{"effort":"xhigh"},{"effort":"max"},{"effort":"ultra"}],"additional_speed_tiers":["fast"],"service_tiers":[{"id":"priority"}],"supported_in_api":true,"visibility":"list","priority":1,"context_window":400000},
      {"slug":"gpt-5.6-terra","display_name":"GPT-5.6-Terra","default_reasoning_level":"medium","supported_reasoning_levels":[{"effort":"low"},{"effort":"medium"},{"effort":"high"},{"effort":"xhigh"},{"effort":"max"},{"effort":"ultra"}],"additional_speed_tiers":["fast"],"service_tiers":[{"id":"priority"}],"supported_in_api":true,"visibility":"list","priority":2},
      {"slug":"gpt-5.6-luna","display_name":"GPT-5.6-Luna","default_reasoning_level":"medium","supported_reasoning_levels":[{"effort":"low"},{"effort":"medium"},{"effort":"high"},{"effort":"xhigh"},{"effort":"max"}],"additional_speed_tiers":["fast"],"service_tiers":[{"id":"priority"}],"supported_in_api":true,"visibility":"list","priority":3},
      {"slug":"gpt-5.6-hidden","display_name":"Hidden","default_reasoning_level":"high","supported_reasoning_levels":[{"effort":"high"}],"supported_in_api":true,"visibility":"hide","priority":0}
    ]}
    """#.utf8).write(to: path)

    let models = CodexSelectableModelCatalog.load(cacheURL: path)
    #expect(Array(models.map(\.id).prefix(3)) == ["gpt-5.6-sol", "gpt-5.6-terra", "gpt-5.6-luna"])
    #expect(models.prefix(3).allSatisfy { $0.supportsFast })
    #expect(models[0].supportedReasoningEfforts.last == "ultra")
    #expect(models[2].supportedReasoningEfforts.last == "max")
    #expect(models[2].supportedReasoningEfforts.contains("ultra") == false)
}

@Test func reasoningOptionsFollowTheSelectedGPT56Model() throws {
    let sol = ModelCatalogItem(
        id: "gpt-5.6-sol",
        displayName: "GPT-5.6-Sol",
        description: nil,
        defaultReasoningEffort: "low",
        supportedReasoningEfforts: ["low", "medium", "high", "xhigh", "max", "ultra"],
        supportsFast: true,
        priority: 1
    )
    let current = ModelSurfacePreference(
        surface: "chat",
        model: sol.id,
        reasoningEffort: "ultra",
        serviceTier: "priority",
        source: nil,
        modelKnown: true
    )
    let catalog = ModelCatalogResponse(
        status: "ok",
        source: "test",
        defaultModel: sol.id,
        fallbackModels: [],
        models: [sol],
        reasoningEfforts: ["low", "medium", "high", "xhigh", "max", "ultra"].map {
            ReasoningEffortOption(id: $0, label: $0, description: nil)
        },
        current: ModelRoutingCurrent(chat: current, telegram: current),
        updatedAt: nil
    )

    #expect(reasoningOptions(from: catalog, model: sol.id).map(\.id)
        == ["low", "medium", "high", "xhigh", "max", "ultra"])
}

@Test func codexPreviewCatalogIsScopedToAccountBackedProvidersAndExactHome() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("CodexSelectableModelScopeTests-\(UUID().uuidString)")
    let explicitHome = root.appendingPathComponent("explicit", isDirectory: true)
    let defaultHome = root.appendingPathComponent("home", isDirectory: true)
    try FileManager.default.createDirectory(at: explicitHome, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: defaultHome, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let explicitCache = explicitHome.appendingPathComponent("models_cache.json")
    try Data(#"{"models":[{"slug":"gpt-5.6-sol","display_name":"Sol","default_reasoning_level":"low","supported_reasoning_levels":[{"effort":"low"}],"supported_in_api":true,"visibility":"list"}]}"#.utf8)
        .write(to: explicitCache)

    #expect(CodexSelectableModelCatalog.cacheCandidate(
        environment: ["CODEX_HOME": explicitHome.path],
        homeDirectory: defaultHome
    ) == explicitCache)
    #expect(CodexSelectableModelCatalog.cacheCandidate(
        environment: [:],
        homeDirectory: defaultHome
    ) == defaultHome.appendingPathComponent(".codex/models_cache.json"))

    let codexModels = CodexSelectableModelCatalog.providerModelDictionaries(
        providerID: "codex",
        cacheURL: explicitCache
    )
    #expect(codexModels.compactMap { $0["id"] as? String }.contains("gpt-5.6-sol"))
    #expect(CodexSelectableModelCatalog.providerModelDictionaries(
        providerID: "openai",
        cacheURL: explicitCache
    ).isEmpty)
    let oauthModels = CodexSelectableModelCatalog.providerModelDictionaries(
        providerID: "openai_oauth_direct",
        cacheURL: explicitCache
    )
    #expect(oauthModels.compactMap { $0["id"] as? String }.contains("gpt-5.6-sol"))
    #expect(CodexSelectableModelCatalog.isAccountBackedProvider("openai_oauth_direct"))
    #expect(CodexSelectableModelCatalog.isAccountBackedProvider("codex"))
    #expect(CodexSelectableModelCatalog.isAccountBackedProvider("openai") == false)
}

@Test func chatGPTOAuthOnlyReusesASharedCacheForTheSameAccount() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("ChatGPTOAuthCatalogAccountTests-\(UUID().uuidString)")
    let oauthHome = root.appendingPathComponent("oauth", isDirectory: true)
    let cliHome = root.appendingPathComponent("cli", isDirectory: true)
    try FileManager.default.createDirectory(at: oauthHome, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: cliHome, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let oauthAuth = oauthHome.appendingPathComponent("auth.json")
    let cliAuth = cliHome.appendingPathComponent("auth.json")
    let cliCache = cliHome.appendingPathComponent("models_cache.json")
    try Data(#"{"tokens":{"account_id":"account-a"}}"#.utf8).write(to: oauthAuth)
    try Data(#"{"tokens":{"account_id":"account-a"}}"#.utf8).write(to: cliAuth)
    try Data(#"{"models":[]}"#.utf8).write(to: cliCache)

    #expect(CodexSelectableModelCatalog.matchingCacheCandidate(
        oauthAuthURL: oauthAuth,
        fallbackCacheURL: cliCache
    ) == cliCache)

    try Data(#"{"tokens":{"account_id":"account-b"}}"#.utf8).write(to: cliAuth)
    #expect(CodexSelectableModelCatalog.matchingCacheCandidate(
        oauthAuthURL: oauthAuth,
        fallbackCacheURL: cliCache
    ) == nil)

    let oauthCache = oauthHome.appendingPathComponent("models_cache.json")
    try Data(#"{"models":[]}"#.utf8).write(to: oauthCache)
    #expect(CodexSelectableModelCatalog.matchingCacheCandidate(
        oauthAuthURL: oauthAuth,
        fallbackCacheURL: cliCache
    ) == oauthCache)
}

@Test func alternateRootOAuthCatalogNeverReadsSharedCodexHome() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("AlternateOAuthCatalog-\(UUID().uuidString)", isDirectory: true)
    let sharedHome = root.appendingPathComponent("shared-codex", isDirectory: true)
    let alternateRoot = root.appendingPathComponent("secondary-body", isDirectory: true)
    let alternateHome = alternateRoot.appendingPathComponent("codex_home", isDirectory: true)
    try FileManager.default.createDirectory(at: sharedHome, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: alternateHome, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    try Data(#"{"models":[]}"#.utf8)
        .write(to: sharedHome.appendingPathComponent("models_cache.json"))

    #expect(CodexSelectableModelCatalog.chatGPTOAuthCacheCandidate(
        dataRoot: alternateRoot,
        environment: ["CODEX_HOME": sharedHome.path]
    ) == nil)

    let rootedCache = alternateHome.appendingPathComponent("models_cache.json")
    try Data(#"{"models":[]}"#.utf8).write(to: rootedCache)
    #expect(CodexSelectableModelCatalog.chatGPTOAuthCacheCandidate(
        dataRoot: alternateRoot,
        environment: ["CODEX_HOME": sharedHome.path]
    ) == rootedCache)
}
