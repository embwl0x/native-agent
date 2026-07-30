import Testing
import Foundation
@testable import ProviderRouting
import NativeAgentCore
import PersistenceCore

// MARK: - Factory

@Test func placeholderFactoryReturnsSwiftNative() async throws {
    let impl = makeProviderRouting()
    #expect(impl is SwiftNativeProviderRouting)
}

@Test func factoryConfinesProviderRegistryToInjectedDataRoot() async throws {
    let paths = try makeProviderRoutingTestPaths()
    let marker = "factory-root-\(UUID().uuidString)"
    let registry = [Provider(id: marker, displayName: "Factory root marker")]
    try JSONEncoder().encode(registry).write(
        to: paths.root
            .appendingPathComponent("providers", isDirectory: true)
            .appendingPathComponent("registry.json")
    )

    let routing = makeProviderRouting(dataRoot: paths.root)
    let providers = try await routing.listProviders()

    #expect(providers.contains(where: { $0.id == marker }))
}

@Test func alternateProviderRootCannotDiscoverSharedCodexAuth() throws {
    let alternate = try makeProviderRoutingTestPaths().root.standardizedFileURL
    let personal = FileManager.default.temporaryDirectory
        .appendingPathComponent("PersonalProviderRoot-\(UUID().uuidString)", isDirectory: true)
        .standardizedFileURL

    let candidates = SwiftNativeProviderRouting.openAIOAuthCandidatePaths(
        dataRoot: alternate,
        defaultDataRoot: personal
    )

    #expect(candidates == [alternate
        .appendingPathComponent("codex_home", isDirectory: true)
        .appendingPathComponent("auth.json")])
    #expect(candidates.allSatisfy { $0.standardizedFileURL.path.hasPrefix(alternate.path + "/") })
}

// MARK: - Codable shape

@Test func Provider_round_trips_via_Codable_with_extras() throws {
    let p = Provider(
        id: "codex",
        displayName: "Codex (ChatGPT via OAuth)",
        kind: "oauth",
        configured: true,
        active: true,
        surface: "chat",
        modelCatalog: .array([.object(["id": .string("gpt-5.5")])]),
        oauthStatus: .object(["state": .string("ready")]),
        lastTestedAt: "2026-05-31T02:22:33Z",
        lastError: nil,
        extras: .object([
            "auth_modes": .array([.string("oauth")]),
            "novelKey": .int(99),
        ])
    )
    let data = try JSONEncoder().encode(p)
    let back = try JSONDecoder().decode(Provider.self, from: data)
    #expect(back.id == p.id)
    #expect(back.displayName == p.displayName)
    #expect(back.kind == p.kind)
    #expect(back.configured == p.configured)
    #expect(back.active == p.active)
    #expect(back.surface == p.surface)
    #expect(back.modelCatalog == p.modelCatalog)
    #expect(back.oauthStatus == p.oauthStatus)
    #expect(back.lastTestedAt == p.lastTestedAt)
    let raw = String(data: data, encoding: .utf8) ?? ""
    #expect(raw.contains("\"auth_modes\""))
    #expect(raw.contains("\"novelKey\""))
}

@Test func Provider_decodes_daemon_snake_case_envelope() throws {
    let raw = Data("""
    {"provider_id":"codex","display_name":"Codex (ChatGPT via OAuth)",
     "auth_modes":["oauth"],
     "auth_status":{"provider_id":"codex","state":"ready","detail":"Logged in"},
     "models":[{"id":"gpt-5.5"}],
     "auth_mode":"","default_model":""}
    """.utf8)
    let p = try JSONDecoder().decode(Provider.self, from: raw)
    #expect(p.id == "codex")
    #expect(p.displayName == "Codex (ChatGPT via OAuth)")
    #expect(p.oauthStatus != nil)
    #expect(p.modelCatalog != nil)
    guard case .object(let extras)? = p.extras else {
        Issue.record("extras should be object"); return
    }
    #expect(extras["auth_modes"] != nil)
    #expect(extras["auth_mode"] != nil)
    #expect(extras["default_model"] != nil)
}

@Test func ModelPreferences_round_trips() throws {
    let prefs = ModelPreferences(
        surfaceModels: .object([
            "chat": .object(["model": .string("claude-opus-4-7")]),
            "telegram": .object(["model": .string("gpt-5.5")]),
        ]),
        defaultModel: "claude-opus-4-7",
        fallbackChain: ["gpt-5.5", "gpt-5.4"],
        extras: .object(["reasoningEfforts": .array([.string("low"), .string("high")])])
    )
    let data = try JSONEncoder().encode(prefs)
    let back = try JSONDecoder().decode(ModelPreferences.self, from: data)
    #expect(back == prefs)
}

@Test func ProviderTestResult_preserves_rawResponse() throws {
    let raw: JSONValue = .object([
        "ok": .bool(true),
        "providerId": .string("codex"),
        "model": .string("gpt-5.5"),
        "latencyMs": .int(842),
    ])
    let r = ProviderTestResult(rawResponse: raw)
    let data = try JSONEncoder().encode(r)
    let back = try JSONDecoder().decode(ProviderTestResult.self, from: data)
    #expect(back == r)
    #expect(back.rawResponse == raw)
}

// MARK: - Phase B SwiftNative picker

private struct ProviderRoutingTestPaths {
    let root: URL
    let surfaces: URL
    let active: URL
}

private func makeProviderRoutingTestPaths(
    surfacesBody: String = "{}",
    activeBody: String = "{}"
) throws -> ProviderRoutingTestPaths {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("ProviderRoutingTests-\(UUID().uuidString)")
    let providers = root.appendingPathComponent("providers", isDirectory: true)
    try FileManager.default.createDirectory(at: providers, withIntermediateDirectories: true)
    let surfaces = providers.appendingPathComponent("surfaces.json")
    let active = providers.appendingPathComponent("active.json")
    try Data(surfacesBody.utf8).write(to: surfaces)
    try Data(activeBody.utf8).write(to: active)
    return ProviderRoutingTestPaths(root: root, surfaces: surfaces, active: active)
}

private func makeSN(_ surfacesBody: String = "{}") throws -> SwiftNativeProviderRouting {
    let paths = try makeProviderRoutingTestPaths(surfacesBody: surfacesBody)
    return SwiftNativeProviderRouting(
        dataRoot: paths.root,
        surfacesPathOverride: paths.surfaces,
        activeProviderPathOverride: paths.active
    )
}

@Test func corruptSurfacePreferencesFailClosedAndRemainUnchanged() async throws {
    let paths = try makeProviderRoutingTestPaths(surfacesBody: "{not-json")
    defer { try? FileManager.default.removeItem(at: paths.root) }
    let damaged = try Data(contentsOf: paths.surfaces)
    let routing = SwiftNativeProviderRouting(
        dataRoot: paths.root,
        surfacesPathOverride: paths.surfaces,
        activeProviderPathOverride: paths.active
    )

    await #expect(throws: (any Error).self) {
        _ = try await routing.computeModelPreferences()
    }
    await #expect(throws: (any Error).self) {
        _ = try await routing.saveModelConfig(.object([
            "surface": .string("chat"),
            "model": .string("gpt-5.6-sol"),
        ]))
    }
    #expect(try Data(contentsOf: paths.surfaces) == damaged)
}

@Test func corruptActiveProviderStateCannotSilentlyRouteAComputedPreference() async throws {
    let paths = try makeProviderRoutingTestPaths(activeBody: "[]")
    defer { try? FileManager.default.removeItem(at: paths.root) }
    let routing = SwiftNativeProviderRouting(
        dataRoot: paths.root,
        surfacesPathOverride: paths.surfaces,
        activeProviderPathOverride: paths.active
    )

    await #expect(throws: (any Error).self) {
        _ = try await routing.computeModelPreferences()
    }
    await #expect(throws: (any Error).self) {
        _ = try await routing.activeProvidersForSurfacesChecked()
    }
    await #expect(throws: (any Error).self) {
        _ = try await routing.pinnedModelStringForSurfaceChecked("chat")
    }
}

@Test func checkedRoutingSnapshotDerivesPreferencesActiveProvidersAndPinsFromOneTuple() async throws {
    let paths = try makeProviderRoutingTestPaths(
        surfacesBody: #"{"chat":{"model":"gpt-5.6-sol","reasoningEffort":"ultra"},"dream":{"model":"claude-opus-4-8","reasoningEffort":"high"}}"#,
        activeBody: #"{"chat":"codex","dream":"anthropic_oauth_direct"}"#
    )
    defer { try? FileManager.default.removeItem(at: paths.root) }
    let routing = SwiftNativeProviderRouting(
        dataRoot: paths.root,
        surfacesPathOverride: paths.surfaces,
        activeProviderPathOverride: paths.active
    )

    let snapshot = try await routing.checkedRoutingSnapshot()

    #expect(snapshot.preferences["chat"]?.model == "gpt-5.6-sol")
    #expect(snapshot.preferences["chat"]?.reasoningEffort == "ultra")
    #expect(snapshot.activeProviders["chat"] == "codex")
    #expect(snapshot.pinnedModels["chat"] == "gpt-5.6-sol")
    #expect(snapshot.pinnedModels["dream"] == "claude-opus-4-8")
    #expect(try await routing.activeProvidersForSurfacesChecked() == snapshot.activeProviders)
    #expect(try await routing.pinnedModelStringForSurfaceChecked("dream") == "claude-opus-4-8")
}

@Test func combinedSurfaceSaveValidatesActiveStateBeforeChangingEitherProjection() async throws {
    let originalSurface = #"{"chat":{"model":"claude-opus-4-8","reasoningEffort":"high"}}"#
    let paths = try makeProviderRoutingTestPaths(
        surfacesBody: originalSurface,
        activeBody: "not-json"
    )
    defer { try? FileManager.default.removeItem(at: paths.root) }
    let routing = SwiftNativeProviderRouting(
        dataRoot: paths.root,
        surfacesPathOverride: paths.surfaces,
        activeProviderPathOverride: paths.active
    )

    await #expect(throws: (any Error).self) {
        try await routing.saveSurfaceConfiguration(
            surface: "chat",
            model: "gpt-5.6-sol",
            reasoningEffort: "ultra",
            serviceTier: "priority",
            providerId: "openai_oauth_direct"
        )
    }

    #expect(try String(contentsOf: paths.surfaces, encoding: .utf8) == originalSurface)
    #expect(try String(contentsOf: paths.active, encoding: .utf8) == "not-json")
}

private enum ProviderSurfaceCommitTestFailure: Error {
    case injected
}

@Test func interruptedCombinedSurfaceSaveRecoversExactTupleOnNextCheckedRead() async throws {
    let paths = try makeProviderRoutingTestPaths(
        surfacesBody: #"{"chat":{"model":"claude-opus-4-8","reasoningEffort":"high"}}"#,
        activeBody: #"{"chat":"anthropic_oauth_direct"}"#
    )
    defer { try? FileManager.default.removeItem(at: paths.root) }
    let interrupted = SwiftNativeProviderRouting(
        dataRoot: paths.root,
        surfacesPathOverride: paths.surfaces,
        activeProviderPathOverride: paths.active,
        surfaceCommitFailureInjector: { step in
            if case .surfacesCommitted = step { throw ProviderSurfaceCommitTestFailure.injected }
        }
    )

    await #expect(throws: ProviderSurfaceCommitTestFailure.self) {
        try await interrupted.saveSurfaceConfiguration(
            surface: "chat",
            model: "gpt-5.6-sol",
            reasoningEffort: "ultra",
            serviceTier: "priority",
            providerId: "openai_oauth_direct"
        )
    }

    let pending = paths.surfaces.deletingLastPathComponent()
        .appendingPathComponent("pending-surface-configuration.json")
    #expect(FileManager.default.fileExists(atPath: pending.path))
    #expect(try SwiftNativeProviderRouting.loadActiveProviderStateChecked(at: paths.active)["chat"] == "anthropic_oauth_direct")

    let recovered = SwiftNativeProviderRouting(
        dataRoot: paths.root,
        surfacesPathOverride: paths.surfaces,
        activeProviderPathOverride: paths.active
    )
    let prefs = try await recovered.computeModelPreferences()
    let active = try await recovered.readActiveProvidersChecked()

    #expect(prefs["chat"]?.model == "gpt-5.6-sol")
    #expect(prefs["chat"]?.reasoningEffort == "ultra")
    #expect(prefs["chat"]?.serviceTier == "priority")
    #expect(active["chat"] == "openai_oauth_direct")
    #expect(!FileManager.default.fileExists(atPath: pending.path))
}

@Test func interruptedCombinedSurfaceSaveRejectsForeignBytesAndPreservesRecoveryMarker() async throws {
    let paths = try makeProviderRoutingTestPaths(
        surfacesBody: #"{"chat":{"model":"claude-opus-4-8"}}"#,
        activeBody: #"{"chat":"anthropic_oauth_direct"}"#
    )
    defer { try? FileManager.default.removeItem(at: paths.root) }
    let interrupted = SwiftNativeProviderRouting(
        dataRoot: paths.root,
        surfacesPathOverride: paths.surfaces,
        activeProviderPathOverride: paths.active,
        surfaceCommitFailureInjector: { step in
            if case .surfacesCommitted = step { throw ProviderSurfaceCommitTestFailure.injected }
        }
    )
    await #expect(throws: ProviderSurfaceCommitTestFailure.self) {
        try await interrupted.saveSurfaceConfiguration(
            surface: "chat",
            model: "gpt-5.6-sol",
            reasoningEffort: "high",
            serviceTier: "default",
            providerId: "openai_oauth_direct"
        )
    }

    let foreignActive = Data(#"{"chat":"openrouter"}"#.utf8)
    try foreignActive.write(to: paths.active)
    let pending = paths.surfaces.deletingLastPathComponent()
        .appendingPathComponent("pending-surface-configuration.json")
    let recovering = SwiftNativeProviderRouting(
        dataRoot: paths.root,
        surfacesPathOverride: paths.surfaces,
        activeProviderPathOverride: paths.active
    )

    await #expect(throws: (any Error).self) {
        _ = try await recovering.computeModelPreferences()
    }
    #expect(try Data(contentsOf: paths.active) == foreignActive)
    #expect(FileManager.default.fileExists(atPath: pending.path))
}

@Test func concurrentCombinedSurfaceSavesPublishOnlyWholeTuples() async throws {
    let paths = try makeProviderRoutingTestPaths()
    defer { try? FileManager.default.removeItem(at: paths.root) }
    let first = SwiftNativeProviderRouting(
        dataRoot: paths.root,
        surfacesPathOverride: paths.surfaces,
        activeProviderPathOverride: paths.active
    )
    let second = SwiftNativeProviderRouting(
        dataRoot: paths.root,
        surfacesPathOverride: paths.surfaces,
        activeProviderPathOverride: paths.active
    )

    async let openAI: Void = first.saveSurfaceConfiguration(
        surface: "chat",
        model: "gpt-5.6-sol",
        reasoningEffort: "ultra",
        serviceTier: "priority",
        providerId: "openai_oauth_direct"
    )
    async let anthropic: Void = second.saveSurfaceConfiguration(
        surface: "chat",
        model: "claude-opus-4-8",
        reasoningEffort: "high",
        serviceTier: "default",
        providerId: "anthropic_oauth_direct"
    )
    _ = try await (openAI, anthropic)

    let prefs = try await first.computeModelPreferences()
    let active = try await first.readActiveProvidersChecked()
    let tuple = (prefs["chat"]?.model, active["chat"])
    let isOpenAI = tuple.0 == "gpt-5.6-sol" && tuple.1 == "openai_oauth_direct"
    let isAnthropic = tuple.0 == "claude-opus-4-8" && tuple.1 == "anthropic_oauth_direct"
    #expect(isOpenAI || isAnthropic)
}

@Test func missingOnlySurfaceSeedPreservesExistingUserPins() async throws {
    let originalSurface = #"{"cognition_reflection":{"model":"gpt-5.6-sol","reasoningEffort":"ultra"}}"#
    let originalActive = #"{"cognition_reflection":"openai_oauth_direct"}"#
    let paths = try makeProviderRoutingTestPaths(
        surfacesBody: originalSurface,
        activeBody: originalActive
    )
    defer { try? FileManager.default.removeItem(at: paths.root) }
    let routing = SwiftNativeProviderRouting(
        dataRoot: paths.root,
        surfacesPathOverride: paths.surfaces,
        activeProviderPathOverride: paths.active
    )

    try await routing.saveSurfaceConfiguration(
        surface: "cognition_reflection",
        model: "claude-opus-4-8",
        reasoningEffort: "high",
        serviceTier: nil,
        providerId: "anthropic_oauth_direct",
        overwriteExisting: false
    )

    #expect(try String(contentsOf: paths.surfaces, encoding: .utf8) == originalSurface)
    #expect(try String(contentsOf: paths.active, encoding: .utf8) == originalActive)
}

@Test func corruptProviderConfigurationIsNeverReplacedBySave() async throws {
    let paths = try makeProviderRoutingTestPaths()
    defer { try? FileManager.default.removeItem(at: paths.root) }
    let path = paths.root.appendingPathComponent("providers/openai.json")
    let damaged = Data("not-json".utf8)
    try damaged.write(to: path)
    let routing = SwiftNativeProviderRouting(
        dataRoot: paths.root,
        surfacesPathOverride: paths.surfaces,
        activeProviderPathOverride: paths.active
    )

    await #expect(throws: (any Error).self) {
        _ = try await routing.configureProvider(
            id: "openai",
            config: .object(["auth_mode": .string("api_key")])
        )
    }
    #expect(try Data(contentsOf: path) == damaged)
}

@Test func injectedDataRootOwnsProviderRegistryBeyondPickerOverrides() async throws {
    let paths = try makeProviderRoutingTestPaths()
    let marker = "alternate-provider-\(UUID().uuidString)"
    let registry = [Provider(id: marker, displayName: "Hermetic marker")]
    let data = try JSONEncoder().encode(registry)
    try data.write(
        to: paths.root
            .appendingPathComponent("providers", isDirectory: true)
            .appendingPathComponent("registry.json")
    )

    let routing = SwiftNativeProviderRouting(
        dataRoot: paths.root,
        surfacesPathOverride: paths.surfaces,
        activeProviderPathOverride: paths.active
    )
    let providers = try await routing.listProviders()

    #expect(providers.contains(where: { $0.id == marker }))
}

@Test func activeProviders_usesOnlyCanonicalActiveStore() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("ProviderRoutingActiveFallback-\(UUID().uuidString)", isDirectory: true)
    let providersDir = root.appendingPathComponent("providers", isDirectory: true)
    let trustDir = root.appendingPathComponent("trust", isDirectory: true)
    try FileManager.default.createDirectory(at: providersDir, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: trustDir, withIntermediateDirectories: true)
    let surfaces = providersDir.appendingPathComponent("surfaces.json")
    let active = providersDir.appendingPathComponent("active.json")
    try Data("{}".utf8).write(to: surfaces)
    try Data("""
    {"telegram":"openai_oauth_direct"}
    """.utf8).write(to: active)
    try Data("""
    {"providerPolicy":{"active_per_surface":{
      "chat":"anthropic_oauth_direct",
      "telegram":"anthropic_oauth_direct",
      "dream":"anthropic_oauth_direct"
    }}}
    """.utf8).write(to: trustDir.appendingPathComponent("policy.json"))

    let sn = SwiftNativeProviderRouting(
        dataRoot: root,
        surfacesPathOverride: surfaces,
        activeProviderPathOverride: active
    )
    let merged = await sn.activeProvidersForSurfaces()
    #expect(merged["chat"] == nil)
    #expect(merged["dream"] == nil)
    #expect(merged["telegram"] == "openai_oauth_direct")
}

@Test func activeProvidersRejectMalformedRowValues() async throws {
    let paths = try makeProviderRoutingTestPaths(activeBody: #"{"chat":123}"#)
    defer { try? FileManager.default.removeItem(at: paths.root) }
    let routing = SwiftNativeProviderRouting(
        dataRoot: paths.root,
        surfacesPathOverride: paths.surfaces,
        activeProviderPathOverride: paths.active
    )

    await #expect(throws: (any Error).self) {
        _ = try await routing.readActiveProvidersChecked()
    }
}

@Test func computeModelPreferences_empty_surfaces_returns_all_surfaces_with_defaults() async throws {
    let sn = try makeSN()
    let prefs = try await sn.computeModelPreferences()
    #expect(Set(prefs.keys) == Set(MODEL_SURFACES))
    #expect(prefs["chat"]?.model == PRIMARY_MODEL)
    #expect(prefs["ios"]?.model == PRIMARY_MODEL)
    #expect(prefs["telegram"]?.model == PRIMARY_MODEL)
    #expect(prefs["chat"]?.reasoningEffort == DEFAULT_REASONING_EFFORT)
}

@Test func computeModelPreferences_overrides_chat_via_surfaces_file() async throws {
    let body = """
    {"chat":{"model":"claude-opus-4-7"}}
    """
    let sn = try makeSN(body)
    let prefs = try await sn.computeModelPreferences()
    #expect(prefs["chat"]?.model == "claude-opus-4-7")
    #expect(prefs["ios"]?.model == "claude-opus-4-7")
}

@Test func computeModelPreferences_overrides_telegram_via_surfaces_file() async throws {
    let body = """
    {"telegram":{"model":"gpt-5.4"}}
    """
    let sn = try makeSN(body)
    let prefs = try await sn.computeModelPreferences()
    #expect(prefs["telegram"]?.model == "gpt-5.4")
}

@Test func computeModelPreferencesCarriesFastTierAndModelSpecificReasoning() async throws {
    let prefs = try await makeSN("""
    {
      "chat":{"model":"gpt-5.6-sol","reasoningEffort":"ultra","serviceTier":"priority"},
      "ios":{"model":"gpt-5.6-luna","reasoningEffort":"ultra","service_tier":"priority"}
    }
    """).computeModelPreferences()
    #expect(prefs["chat"]?.reasoningEffort == "ultra")
    #expect(prefs["chat"]?.serviceTier == "priority")
    #expect(prefs["ios"]?.reasoningEffort == "high")
    #expect(prefs["ios"]?.serviceTier == "priority")
}

@Test func computeModelPreferences_slack_is_chat_surface_with_independent_pin() async throws {
    let inherited = try await makeSN("""
    {"chat":{"model":"claude-opus-4-8","reasoningEffort":"high"}}
    """).computeModelPreferences()
    #expect(inherited["slack"]?.model == "claude-opus-4-8")
    #expect(inherited["slack"]?.reasoningEffort == "high")

    let pinned = try await makeSN("""
    {"chat":{"model":"claude-opus-4-8","reasoningEffort":"high"},"slack":{"model":"gpt-5.5","reasoningEffort":"medium"}}
    """).computeModelPreferences()
    #expect(pinned["slack"]?.model == nativeAgentPrimaryModel)
    #expect(pinned["slack"]?.reasoningEffort == "medium")
}

@Test func computeModelPreferences_activeProviderRepairsStaleCrossProviderModel() async throws {
    let paths = try makeProviderRoutingTestPaths(
        surfacesBody: """
    {
      "chat": {"model": "gpt-5.5", "reasoningEffort": "xhigh"},
      "telegram": {"model": "gpt-5.5", "reasoningEffort": "xhigh"},
      "slack": {"model": "gpt-5.5", "reasoningEffort": "xhigh"}
    }
    """,
        activeBody: """
    {
      "chat": "anthropic_oauth_direct",
      "telegram": "anthropic_oauth_direct",
      "slack": "anthropic_oauth_direct"
    }
    """
    )

    let sn = SwiftNativeProviderRouting(
        dataRoot: paths.root,
        surfacesPathOverride: paths.surfaces,
        activeProviderPathOverride: paths.active
    )
    let prefs = try await sn.computeModelPreferences()

    #expect(prefs["chat"]?.model == "claude-opus-4-8")
    #expect(prefs["chat"]?.reasoningEffort == "xhigh")
    #expect(prefs["telegram"]?.model == "claude-opus-4-8")
    #expect(prefs["telegram"]?.reasoningEffort == "xhigh")
    #expect(prefs["slack"]?.model == "claude-opus-4-8")
    #expect(prefs["slack"]?.reasoningEffort == "xhigh")
}

@Test func computeModelPreferences_keepsBareGPT56ForExplicitCodexProvider() async throws {
    let paths = try makeProviderRoutingTestPaths(
        surfacesBody: """
        {"chat":{"model":"gpt-5.6-sol","reasoningEffort":"ultra","serviceTier":"priority"}}
        """,
        activeBody: """
        {"chat":"codex"}
        """
    )
    let routing = SwiftNativeProviderRouting(
        dataRoot: paths.root,
        surfacesPathOverride: paths.surfaces,
        activeProviderPathOverride: paths.active
    )

    let prefs = try await routing.computeModelPreferences()

    #expect(prefs["chat"]?.model == "gpt-5.6-sol")
    #expect(prefs["chat"]?.reasoningEffort == "ultra")
    #expect(prefs["chat"]?.serviceTier == "priority")
}

@Test func computeModelPreferences_keeps_xhigh_for_current_claude_surfaces() async throws {
    let body = """
    {
      "chat": {"model": "claude-opus-4-8", "reasoningEffort": "xhigh"},
      "telegram": {"model": "claude-opus-4-8", "reasoningEffort": "xhigh"}
    }
    """
    let sn = try makeSN(body)
    let prefs = try await sn.computeModelPreferences()
    #expect(prefs["chat"]?.reasoningEffort == "xhigh")
    #expect(prefs["telegram"]?.reasoningEffort == "xhigh")
}

@Test func computeModelPreferences_keeps_none_for_publicGPT56Provider() async throws {
    let paths = try makeProviderRoutingTestPaths(
        surfacesBody: """
        {"chat":{"model":"gpt-5.6-sol","reasoningEffort":"none","serviceTier":"priority"}}
        """,
        activeBody: """
        {"chat":"openai"}
        """
    )
    let routing = SwiftNativeProviderRouting(
        dataRoot: paths.root,
        surfacesPathOverride: paths.surfaces,
        activeProviderPathOverride: paths.active
    )

    let prefs = try await routing.computeModelPreferences()

    #expect(prefs["chat"]?.model == "gpt-5.6-sol")
    #expect(prefs["chat"]?.reasoningEffort == "none")
    #expect(prefs["chat"]?.serviceTier == "priority")
}

@Test func computeModelPreferences_returns_seed_for_unset_surfaces() async throws {
    let body = """
    {"chat":{"model":"claude-opus-4-7"}}
    """
    let sn = try makeSN(body)
    let prefs = try await sn.computeModelPreferences()
    #expect(prefs["missions"]?.model == PRIMARY_MODEL)
    #expect(prefs["autonomy"]?.model == PRIMARY_MODEL)
    #expect(prefs["swarms"]?.model == PRIMARY_MODEL)
    // 2026-06-05 dream-design-restore: the daemon-era seeds for `dream` /
    // `rem` are preserved at the picker layer (back-compat); the design
    // intent ("speak in her current voice unless explicitly pinned") is
    // enforced by `pinnedModelStringForSurface(_:)` at the dream / REM
    // consumer instead. See pinnedModelStringForSurface tests below.
    #expect(prefs["dream"]?.model == "gpt-5.4-mini")
    #expect(prefs["rem"]?.model == "gpt-5.4-mini")
    #expect(prefs["training"]?.model == "gpt-5.4")
}

@Test func computeModelPreferences_dream_seed_is_gpt_5_4_mini() async throws {
    let sn = try makeSN()
    let prefs = try await sn.computeModelPreferences()
    #expect(prefs["dream"]?.model == "gpt-5.4-mini")
}

@Test func pinnedModelStringForSurface_returns_nil_when_unpinned() async throws {
    // Empty surfaces.json — no surface is pinned, so dream / REM should
    // see nil and fall back to the chat picker in their consumers.
    let sn = try makeSN()
    let dream = await sn.pinnedModelStringForSurface("dream")
    let rem = await sn.pinnedModelStringForSurface("rem")
    #expect(dream == nil)
    #expect(rem == nil)
}

@Test func computeModelPreferences_training_seed_is_gpt_5_4() async throws {
    let sn = try makeSN()
    let prefs = try await sn.computeModelPreferences()
    #expect(prefs["training"]?.model == "gpt-5.4")
}

@Test func computeModelPreferences_executions_autonomy_swarms_seed_to_PRIMARY_MODEL() async throws {
    let sn = try makeSN()
    let prefs = try await sn.computeModelPreferences()
    #expect(prefs["missions"]?.model == PRIMARY_MODEL)
    #expect(prefs["autonomy"]?.model == PRIMARY_MODEL)
    #expect(prefs["swarms"]?.model == PRIMARY_MODEL)
}

@Test func computeModelPreferences_ios_shares_chat_brain_when_unoverridden() async throws {
    let body = """
    {"chat":{"model":"claude-opus-4-7"}}
    """
    let sn = try makeSN(body)
    let prefs = try await sn.computeModelPreferences()
    #expect(prefs["chat"]?.model == "claude-opus-4-7")
    #expect(prefs["ios"]?.model == "claude-opus-4-7")
}

@Test func modelForSurface_unknown_throws_invalidRequest() async throws {
    let sn = try makeSN()
    do {
        _ = try await sn.modelForSurface("nope")
        Issue.record("expected throw")
    } catch ProviderRoutingError.invalidRequest {
        // pass
    } catch {
        Issue.record("unexpected: \(error)")
    }
}

@Test func normalizeModelId_trimsAndMigratesRetiredGPT55() async throws {
    let sn = try makeSN()
    // Python normalize_model_id does NOT lowercase — only trims + validates.
    // NativeAgent additionally retires its former GPT-5.5 primary fallback.
    #expect(sn.normalizeModelId("  gpt-5.5  ", fallback: "x") == nativeAgentPrimaryModel)
    #expect(sn.normalizeModelId("  GPT-5.5  ", fallback: "x") == nativeAgentPrimaryModel)
    #expect(sn.normalizeModelId("  gpt-5.6-terra  ", fallback: "x") == "gpt-5.6-terra")
    #expect(sn.normalizeModelId("", fallback: "x") == "x")
    // Bad chars → fallback.
    #expect(sn.normalizeModelId("bad model!", fallback: "x") == "x")
}

@Test func normalizeReasoningEffort_validates_against_options() async throws {
    let sn = try makeSN()
    #expect(sn.normalizeReasoningEffort("LOW", fallback: "medium") == "low")
    #expect(sn.normalizeReasoningEffort("medium", fallback: "high") == "medium")
    #expect(sn.normalizeReasoningEffort("high", fallback: "low") == "high")
    #expect(sn.normalizeReasoningEffort("xhigh", fallback: "low") == "xhigh")
    // empty → fallback
    #expect(sn.normalizeReasoningEffort("", fallback: "medium") == "medium")
    // invalid → fallback
    #expect(sn.normalizeReasoningEffort("turbo", fallback: "medium") == "medium")
}

@Test func inferProviderForModel_openrouter_anthropic_id() async throws {
    let sn = try makeSN()
    #expect(sn.inferProviderForModel("anthropic/claude-opus-4-7") == "openrouter")
    #expect(sn.inferProviderForModel("openai/gpt-5") == "openrouter")
}

@Test func inferProviderForModel_bare_claude_id() async throws {
    let sn = try makeSN()
    #expect(sn.inferProviderForModel("claude-opus-4-7") == "anthropic_oauth_direct")
    #expect(sn.inferProviderForModel("claude-sonnet-4-5") == "anthropic_oauth_direct")
}

@Test func inferProviderForModel_gpt_id() async throws {
    let sn = try makeSN()
    #expect(sn.inferProviderForModel("gpt-5.5") == "openai_oauth_direct")
    #expect(sn.inferProviderForModel("gpt-5.4-mini") == "openai_oauth_direct")
    #expect(sn.inferProviderForModel("llama3") == nil)
    #expect(sn.inferProviderForModel("") == nil)
}

@Test func inferProviderForModel_grok_id() async throws {
    let sn = try makeSN()
    #expect(sn.inferProviderForModel("grok-4.3") == "xai_oauth_direct")
    #expect(sn.inferProviderForModel("grok-build-0.1") == "xai_oauth_direct")
}

@Test func inferProviderForModel_kimi_id() async throws {
    let sn = try makeSN()
    #expect(sn.inferProviderForModel("kimi-k3") == "moonshot")
    #expect(sn.inferProviderForModel("kimi-k2.7-code") == "moonshot")
}

@Test func computeModelPreferences_activeXAIRepairsStaleCrossProviderModel() async throws {
    let paths = try makeProviderRoutingTestPaths(
        surfacesBody: """
    {"chat": {"model": "gpt-5.5", "reasoningEffort": "high"}}
    """,
        activeBody: """
    {"chat": "xai_oauth_direct"}
    """
    )

    let sn = SwiftNativeProviderRouting(
        dataRoot: paths.root,
        surfacesPathOverride: paths.surfaces,
        activeProviderPathOverride: paths.active
    )
    let prefs = try await sn.computeModelPreferences()
    #expect(prefs["chat"]?.model == XAIOAuthDirectAdapter.defaultModel)
}

@Test func computeModelPreferences_activeMoonshotRepairsStaleModelAndReasoning() async throws {
    let paths = try makeProviderRoutingTestPaths(
        surfacesBody: """
    {"chat": {"model": "gpt-5.5", "reasoningEffort": "high"}}
    """,
        activeBody: """
    {"chat": "moonshot"}
    """
    )

    let sn = SwiftNativeProviderRouting(
        dataRoot: paths.root,
        surfacesPathOverride: paths.surfaces,
        activeProviderPathOverride: paths.active
    )
    let prefs = try await sn.computeModelPreferences()
    #expect(prefs["chat"]?.model == MoonshotAdapter.defaultModel)
    #expect(prefs["chat"]?.reasoningEffort == "max")
}

// MARK: - Swift-native model preference contract

@Test func computeModelPreferences_surfacePins_matchNativeContract() async throws {
    // Mixed real-world-ish surfaces file: string overrides plus non-string
    // scalars (int / double / bool / null) to pin the native
    // `str(value or "")` compatibility rules for migrated picker data.
    let surfacesBody = """
    {
      "chat": {"model": "claude-opus-4-7", "reasoningEffort": "high"},
      "telegram": {"model": "gpt-5.4", "reasoningEffort": "low"},
      "dream": 123,
      "missions": 1.5,
      "autonomy": true,
      "swarms": false,
      "training": null
    }
    """
    let sn = try makeSN(surfacesBody)
    let swiftPrefs = try await sn.computeModelPreferences()

    let expected: [String: (model: String, effort: String)] = [
        "chat": ("claude-opus-4-7", "high"),
        "ios": ("claude-opus-4-7", "high"),
        "telegram": ("gpt-5.4", "low"),
        // `slack` is a chat-like remote surface. Unpinned, it inherits
        // chat's model/effort, but the picker can pin it independently.
        "slack": ("claude-opus-4-7", "high"),
        "missions": ("1.5", "high"),
        "autonomy": ("True", "high"),
        "swarms": (PRIMARY_MODEL, "high"),
        "dream": ("123", "high"),
        // `rem` was added to MODEL_SURFACES 2026-06-05 (dream/REM design
        // restore). It's seeded to `gpt-5.4-mini` for picker back-compat;
        // the "speak in her current voice" intent is enforced at the REM
        // consumer via `pinnedModelStringForSurface` instead, so this
        // picker-level value is just the unpinned seed.
        "rem": ("gpt-5.4-mini", "high"),
        "training": ("gpt-5.4", "high"),
        // `memory` was added to MODEL_SURFACES 2026-06-10 (memory-machinery
        // LLM calls — the kind-backfill classifier etc.). Unpinned it seeds
        // to chat's pick (same rule as ios), which matches the consumer's
        // pin-only + chat-fallback resolution intent.
        "memory": ("claude-opus-4-7", "high"),
        // `heartbeat` + `diagnostics` were added 2026-06-11 (U2b wave 3 —
        // HeartbeatLoop + SelfHealingHook LLM call sites). Same unpinned
        // seed-to-chat rule as `memory`/`ios`.
        "heartbeat": ("claude-opus-4-7", "high"),
        "diagnostics": ("claude-opus-4-7", "high"),
        // Cognitive reflection is the exceptional deep-cognition surface.
        // It defaults to explicit Anthropic Opus 4.8 at the repo's Claude-safe
        // high effort rather than inheriting chat, so provider swaps do not accidentally move
        // the subconscious reflection model.
        "cognition_reflection": ("claude-opus-4-8", "high"),
        // `compaction` was added 2026-07-01 (R4 LLM-distilled autocompaction).
        // Unpinned it seeds to chat's pick (same rule as `memory`/`ios`), so
        // the distilled summary is written in Agent's current voice.
        "compaction": ("claude-opus-4-7", "high"),
    ]
    #expect(Set(swiftPrefs.keys) == Set(expected.keys))
    for (surface, entry) in expected {
        let s = try #require(swiftPrefs[surface])
        #expect(s.surface == surface)
        #expect(s.model == entry.model, "model mismatch @\(surface)")
        #expect(s.reasoningEffort == entry.effort, "effort mismatch @\(surface)")
    }
}

// MARK: - Non-string JSON values in surfaces.json

@Test func computeModelPreferences_int_model_coerces_python_style() async throws {
    let body = """
    {"chat":123}
    """
    let sn = try makeSN(body)
    let prefs = try await sn.computeModelPreferences()
    // Python: str(123 or base) = "123"; regex accepts; result = "123".
    #expect(prefs["chat"]?.model == "123")
}

@Test func computeModelPreferences_double_model_coerces_python_style() async throws {
    let body = """
    {"chat":1.5}
    """
    let sn = try makeSN(body)
    let prefs = try await sn.computeModelPreferences()
    // Python: str(1.5) = "1.5"; regex accepts; result = "1.5".
    #expect(prefs["chat"]?.model == "1.5")
}

@Test func computeModelPreferences_bool_true_model_coerces_to_True_string() async throws {
    let body = """
    {"chat":true}
    """
    let sn = try makeSN(body)
    let prefs = try await sn.computeModelPreferences()
    // Python: str(True) = "True"; regex `[A-Za-z0-9._:/+-]{1,100}` accepts.
    #expect(prefs["chat"]?.model == "True")
}

@Test func computeModelPreferences_bool_false_model_falls_to_base() async throws {
    let body = """
    {"chat":false}
    """
    let sn = try makeSN(body)
    let prefs = try await sn.computeModelPreferences()
    // Python: False or base -> base (chat seed = PRIMARY_MODEL when no chat_model).
    #expect(prefs["chat"]?.model == PRIMARY_MODEL)
}

@Test func computeModelPreferences_null_model_falls_to_base() async throws {
    let body = """
    {"chat":null}
    """
    let sn = try makeSN(body)
    let prefs = try await sn.computeModelPreferences()
    // Python: None or base -> base.
    #expect(prefs["chat"]?.model == PRIMARY_MODEL)
}

// MARK: - Cross-target surface-list contract (iOS picker ↔ MODEL_SURFACES)

/// The iOS app cannot import ProviderRouting, so its per-surface model picker
/// (`iOS/NativeAgentMobile/Sources/ProviderSettingsView.swift`) hand-mirrors a
/// `canonicalSurfaces` constant from this module's `MODEL_SURFACES`. This test
/// is the cross-target contract: it parses that iOS constant out of source and
/// asserts it covers EVERY canonical surface. When a surface is added to
/// `MODEL_SURFACES` but not to the iOS list, this fails with the missing names
/// — so the phone never silently hides a surface the Mac can pin a model for.
///
/// (There is no XCTest bundle in the iOS xcodegen project, so the contract has
/// to live on the Mac test side; it runs under
/// `swift test --filter ProviderRouting`.)
@Test func iOSProviderPicker_surfaceList_coversCanonicalModelSurfaces() throws {
    // #filePath → .../Modules/NativeAgentCore/Tests/ProviderRoutingTests/ThisFile.swift
    // Five pops reach the repo root (mirrors NativeAgentCoreTests).
    let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()   // ProviderRoutingTests/
        .deletingLastPathComponent()   // Tests/
        .deletingLastPathComponent()   // NativeAgentCore/
        .deletingLastPathComponent()   // Modules/
        .deletingLastPathComponent()   // repo root
    let iosView = repoRoot
        .appendingPathComponent("iOS")
        .appendingPathComponent("NativeAgentMobile")
        .appendingPathComponent("Sources")
        .appendingPathComponent("ProviderSettingsView.swift")
    let src = try String(contentsOf: iosView, encoding: .utf8)

    // Extract the bracketed body of `static let canonicalSurfaces = [ ... ]`.
    guard let declRange = src.range(of: "canonicalSurfaces = ["),
          let close = src.range(of: "]", range: declRange.upperBound..<src.endIndex)
    else {
        Issue.record("could not locate `canonicalSurfaces = [...]` in \(iosView.path)")
        return
    }
    let body = String(src[declRange.upperBound..<close.lowerBound])
    // Pull every double-quoted token out of the array literal.
    var iosSurfaces = Set<String>()
    var idx = body.startIndex
    while let open = body.range(of: "\"", range: idx..<body.endIndex),
          let end = body.range(of: "\"", range: open.upperBound..<body.endIndex) {
        iosSurfaces.insert(String(body[open.upperBound..<end.lowerBound]))
        idx = end.upperBound
    }

    let canonical = Set(MODEL_SURFACES)
    let missing = canonical.subtracting(iosSurfaces).sorted()
    #expect(
        missing.isEmpty,
        "iOS ProviderSettingsView.canonicalSurfaces is missing canonical MODEL_SURFACES: \(missing). Append them (keep order) and update surfaceLabel()."
    )
}
