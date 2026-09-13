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
        modelCatalog: .array([.object(["id": .string("gpt-5.6-sol")])]),
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
     "models":[{"id":"gpt-5.6-sol"}],
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
            "telegram": .object(["model": .string("gpt-5.6-sol")]),
        ]),
        defaultModel: "claude-opus-4-7",
        fallbackChain: ["gpt-5.6-sol", "gpt-5.4"],
        extras: .object(["reasoningEfforts": .array([.string("low"), .string("high")])])
    )
    let data = try JSONEncoder().encode(prefs)
    let back = try JSONDecoder().decode(ModelPreferences.self, from: data)
    #expect(back == prefs)
}

// Eval coverage ledger — `providers.modelPreferences.fallbackChain`.
// A ModelPreferences response must not advertise a recovery chain unless the
// routing owner can actually execute it. Failover lives nowhere in this owner,
// so the computed public envelope deliberately omits the compatibility field.
@Test func computedModelPreferences_doesNotAdvertiseUnimplementedFallbackChain() async throws {
    let routing = try makeSN()
    let preferences = try await routing.getModelPreferences()
    #expect(preferences.fallbackChain == nil)
    #expect(preferences.defaultModel != nil)
    #expect(preferences.surfaceModels != nil)
}

@Test func ProviderTestResult_preserves_rawResponse() throws {
    let raw: JSONValue = .object([
        "ok": .bool(true),
        "providerId": .string("codex"),
        "model": .string("gpt-5.6-sol"),
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

// 2026-08-21 (User-directed fail-loud): the runtime no longer silently swaps a
// family-mismatched model at dispatch, so a bare provider switch must resolve
// the mismatch at the SOURCE — a stale pin from the old provider's family is
// rewritten to the new provider's default in the same transactional update,
// and the panel shows the truth.
@Test func providerSwitch_rewritesIncompatibleStaleModelPin() async throws {
    let paths = try makeProviderRoutingTestPaths(
        surfacesBody: #"{"telegram":{"model":"gpt-5.6-sol","reasoningEffort":"high"}}"#,
        activeBody: #"{"telegram":"openai_oauth_direct"}"#
    )
    defer { try? FileManager.default.removeItem(at: paths.root) }
    let routing = SwiftNativeProviderRouting(
        dataRoot: paths.root,
        surfacesPathOverride: paths.surfaces,
        activeProviderPathOverride: paths.active
    )

    try await routing.setActiveProvider(surface: "telegram", providerId: "anthropic_oauth_direct")

    let active = try await routing.activeProvidersForSurfacesChecked()
    #expect(active["telegram"] == "anthropic_oauth_direct")
    // The GPT pin cannot ride an Anthropic provider: it must have been
    // rewritten to the provider default, never left stale (the runtime would
    // fail that turn loudly) and never silently swapped at dispatch time.
    let pinned = try await routing.pinnedModelStringForSurfaceChecked("telegram")
    #expect(pinned == "claude-opus-4-8")
}

// A compatible pin survives a provider switch untouched.
@Test func providerSwitch_keepsCompatibleModelPin() async throws {
    let paths = try makeProviderRoutingTestPaths(
        surfacesBody: #"{"telegram":{"model":"gpt-5.6-luna","reasoningEffort":"high"}}"#,
        activeBody: #"{"telegram":"openai"}"#
    )
    defer { try? FileManager.default.removeItem(at: paths.root) }
    let routing = SwiftNativeProviderRouting(
        dataRoot: paths.root,
        surfacesPathOverride: paths.surfaces,
        activeProviderPathOverride: paths.active
    )

    try await routing.setActiveProvider(surface: "telegram", providerId: "openai_oauth_direct")

    #expect(try await routing.activeProvidersForSurfacesChecked()["telegram"] == "openai_oauth_direct")
    #expect(try await routing.pinnedModelStringForSurfaceChecked("telegram") == "gpt-5.6-luna")
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

/// User, 2026-09-13: no model is ever chosen in code. On a root with no account
/// and no saved pick there is nothing to answer with, and that is the honest
/// answer — the page says "connect an account" — rather than a literal model id
/// the person never picked. Connecting the first account writes Chat's model
/// down (`adoptProviderForBlankSurfaces`), which is what fills this in.
@Test func computeModelPreferences_withNothingSetUp_hasNoModelToOffer() async throws {
    let sn = try makeSN()
    let prefs = try await sn.computeModelPreferences()
    #expect(Set(prefs.keys) == Set(MODEL_SURFACES))
    #expect(prefs["chat"]?.model == "")
    #expect(prefs["ios"]?.model == "")
    #expect(prefs["telegram"]?.model == "")
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

/// User, 2026-09-13 (second review): a key saved for ONE activity does not route.
/// The Providers page offers three groups and says "Choosing here sets all four",
/// so a per-app key is invisible to the person — honouring it would split a group
/// behind their back. It stays visible as a saved pick and the next group write
/// clears it.
@Test func computeModelPreferences_perSurfaceKeyDoesNotRoute() async throws {
    let body = """
    {"telegram":{"model":"gpt-5.6-luna"}}
    """
    let sn = try makeSN(body)
    let prefs = try await sn.computeModelPreferences()
    #expect(prefs["telegram"]?.model == prefs["chat"]?.model)
    #expect(await sn.pinnedModelStringForSurface("telegram") == "gpt-5.6-luna")
}

/// Retired OpenAI ids fold onto the primary at the routing boundary, so a pick
/// saved by an older install resolves to a model that still exists instead of
/// 404ing or disappearing. `gpt-5.4` and `gpt-5.4-mini` were retired 2026-09-13
/// and are gone from the picker catalog ("they don't even carry the model
/// anymore"); `gpt-5.5` went when 5.6 shipped.
@Test func computeModelPreferences_retiredPicksStopBeingPicks() async throws {
    let sn = try makeSN(#"{"chat":{"model":"gpt-5.4"},"dream":{"model":"gpt-5.4-mini"}}"#)
    let prefs = try await sn.computeModelPreferences()
    // Nothing is swapped in for them: with no account connected on this root
    // there is no choice to inherit either, so both read as not set up.
    #expect(prefs["chat"]?.model == "")
    #expect(prefs["dream"]?.model == "")
    #expect(FirstPartyModelCatalog.descriptor(for: "gpt-5.4") == nil)
    #expect(FirstPartyModelCatalog.descriptor(for: "gpt-5.4-mini") == nil)
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
    // iPhone is a Chat-group member: it takes the group's tuple, not a key
    // written for it alone (second review).
    #expect(prefs["ios"]?.reasoningEffort == "ultra")
    #expect(prefs["ios"]?.serviceTier == "priority")
}

@Test func computeModelPreferences_slack_is_chat_surface_with_independent_pin() async throws {
    let inherited = try await makeSN("""
    {"chat":{"model":"claude-opus-4-8","reasoningEffort":"high"}}
    """).computeModelPreferences()
    #expect(inherited["slack"]?.model == "claude-opus-4-8")
    #expect(inherited["slack"]?.reasoningEffort == "high")

    // A Slack-only key does not route either (second review): Slack is a member
    // of the Chat group and takes the Chat group's tuple.
    let pinned = try await makeSN("""
    {"chat":{"model":"claude-opus-4-8","reasoningEffort":"high"},"slack":{"model":"gpt-5.6-luna","reasoningEffort":"medium"}}
    """).computeModelPreferences()
    #expect(pinned["slack"]?.model == "claude-opus-4-8")
    #expect(pinned["slack"]?.reasoningEffort == "high")

    // A pick of a model this build no longer carries is not a pick: the surface
    // goes back to its group's choice, which here is Chat's (2026-09-13).
    let retired = try await makeSN("""
    {"chat":{"model":"claude-opus-4-8","reasoningEffort":"high"},"slack":{"model":"gpt-5.5","reasoningEffort":"medium"}}
    """).computeModelPreferences()
    #expect(retired["slack"]?.model == "claude-opus-4-8")
}

@Test func computeModelPreferences_activeProviderRepairsStaleCrossProviderModel() async throws {
    let paths = try makeProviderRoutingTestPaths(
        surfacesBody: """
    {
      "chat": {"model": "gpt-5.6-sol", "reasoningEffort": "xhigh"},
      "telegram": {"model": "gpt-5.6-sol", "reasoningEffort": "xhigh"},
      "slack": {"model": "gpt-5.6-sol", "reasoningEffort": "xhigh"}
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

    // User, 2026-09-13 (second review): a pick the route cannot serve is NOT
    // repaired to that route's default — substituting a model the person did not
    // choose reads exactly like the bug it was meant to fix. The surface is
    // unset and the snapshot carries the sentence to show and to refuse with.
    #expect(prefs["chat"]?.model == "")
    #expect(prefs["telegram"]?.model == "")
    #expect(prefs["slack"]?.model == "")
    let snapshot = try await sn.checkedRoutingSnapshot()
    #expect(snapshot.unusablePickNotice(for: "chat")
        == "gpt-5.6-sol isn't offered on anthropic_oauth_direct. Choose one.")
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

/// User, 2026-09-13: every unpinned surface follows Chat. The per-surface seeds
/// this replaced (`workshop`/`autonomy`/`swarms` on the primary,
/// `dream`/`rem`/`studio_wander` on a cheap model, `training` on another) are
/// gone — a lane could otherwise be aimed at a model its group's connected route
/// cannot serve, which is how 0.4.11 dreams died on a ChatGPT-only install.
@Test func computeModelPreferences_unpinned_surfaces_all_follow_chat() async throws {
    let body = """
    {"chat":{"model":"claude-opus-4-7"}}
    """
    let sn = try makeSN(body)
    let prefs = try await sn.computeModelPreferences()
    for surface in MODEL_SURFACES {
        #expect(prefs[surface]?.model == "claude-opus-4-7", "model mismatch @\(surface)")
    }
}

@Test func computeModelPreferences_dream_follows_chat_with_no_seed_of_its_own() async throws {
    let sn = try makeSN()
    let prefs = try await sn.computeModelPreferences()
    // Whatever Chat answers — including "nothing set up yet" — dream answers.
    #expect(prefs["dream"]?.model == prefs["chat"]?.model)
    #expect(prefs["rem"]?.model == prefs["chat"]?.model)
    #expect(prefs["studio_wander"]?.model == prefs["chat"]?.model)
    #expect(prefs["studio_wander"]?.reasoningEffort == prefs["chat"]?.reasoningEffort)
}

/// The Providers page and the resolver must read ONE group table, and every
/// routed surface must be in it — otherwise a new surface silently gets its own
/// un-grouped behavior again.
@Test func everyModelSurfaceBelongsToExactlyOneProvidersGroup() {
    for surface in MODEL_SURFACES {
        let owners = ProviderSurfaceGroups.all.filter { $0.surfaces.contains(surface) }
        #expect(owners.count == 1, "\(surface) is in \(owners.count) groups")
    }
    let claimed = ProviderSurfaceGroups.all.flatMap(\.surfaces)
    #expect(Set(claimed) == Set(MODEL_SURFACES))
    #expect(claimed.count == Set(claimed).count)
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

/// `training` had its own `gpt-5.4` seed; the model is retired and the Work
/// group's choice is the only answer now.
@Test func computeModelPreferences_training_follows_chat() async throws {
    let sn = try makeSN()
    let prefs = try await sn.computeModelPreferences()
    #expect(prefs["training"]?.model == prefs["chat"]?.model)
}

@Test func computeModelPreferences_work_group_follows_chat_when_unpinned() async throws {
    let sn = try makeSN(#"{"chat":{"model":"claude-opus-4-7"}}"#)
    let prefs = try await sn.computeModelPreferences()
    for surface in ProviderSurfaceGroups.work.surfaces {
        #expect(prefs[surface]?.model == "claude-opus-4-7", "model mismatch @\(surface)")
    }
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

@Test func normalizeModelId_trimsAndValidatesWithoutSubstituting() async throws {
    let sn = try makeSN()
    // Python normalize_model_id does NOT lowercase — only trims + validates.
    // User, 2026-09-13: it does not SUBSTITUTE either. A retired id used to be
    // folded onto the primary here; a retired id is now simply not a pick (see
    // `computeModelPreferences_retired_openai_picks...`), so this boundary
    // returns exactly what it was given.
    #expect(sn.normalizeModelId("  gpt-5.5  ", fallback: "x") == "gpt-5.5")
    #expect(sn.normalizeModelId("  GPT-5.5  ", fallback: "x") == "GPT-5.5")
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
    #expect(sn.inferProviderForModel("gpt-5.6-sol") == "openai_oauth_direct")
    #expect(sn.inferProviderForModel("gpt-5.6-luna") == "openai_oauth_direct")
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

/// A pick the route cannot serve is unset and says so — never repaired to that
/// route's default (User, 2026-09-13, second review).
@Test func computeModelPreferences_activeXAILeavesAStaleCrossProviderPickUnset() async throws {
    let paths = try makeProviderRoutingTestPaths(
        surfacesBody: """
    {"chat": {"model": "gpt-5.6-sol", "reasoningEffort": "high"}}
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
    let snapshot = try await sn.checkedRoutingSnapshot()
    #expect(snapshot.preferences["chat"]?.model == "")
    #expect(snapshot.unusablePickNotice(for: "chat")
        == "gpt-5.6-sol isn't offered on xai_oauth_direct. Choose one.")
}

@Test func computeModelPreferences_activeMoonshotLeavesAStaleModelUnset() async throws {
    let paths = try makeProviderRoutingTestPaths(
        surfacesBody: """
    {"chat": {"model": "gpt-5.6-sol", "reasoningEffort": "high"}}
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
    let snapshot = try await sn.checkedRoutingSnapshot()
    #expect(snapshot.preferences["chat"]?.model == "")
    #expect(snapshot.unusablePickNotice(for: "chat")
        == "gpt-5.6-sol isn't offered on moonshot. Choose one.")
}

// MARK: - Swift-native model preference contract

@Test func computeModelPreferences_surfacePins_matchNativeContract() async throws {
    // Mixed real-world-ish surfaces file: string overrides plus non-string
    // scalars (int / double / bool / null) to pin the native
    // `str(value or "")` compatibility rules for migrated picker data.
    //
    // P2-3: the `missions` key below is deliberately the 0.3.x spelling — this
    // fixture IS a live-shaped legacy picker file, so the expectation is a
    // mismatched pair: old key on disk, canonical key out of the picker.
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
        // `gpt-5.4` is retired (2026-09-13): the pick stops counting and takes its
        // whole tuple with it — the `low` was chosen for a model that is gone —
        // so telegram answers with its group's choice, Chat's model and effort.
        "telegram": ("claude-opus-4-7", "high"),
        // `slack` is a chat-like remote surface. Unpinned, it inherits
        // chat's model/effort, but the picker can pin it independently.
        "slack": ("claude-opus-4-7", "high"),
        "desk": ("claude-opus-4-7", "high"),
        "workshop": ("claude-opus-4-7", "high"),
        "autonomy": ("claude-opus-4-7", "high"),
        // false is Python-falsy -> no pick -> Chat's model.
        "swarms": ("claude-opus-4-7", "high"),
        "dream": ("claude-opus-4-7", "high"),
        // `rem` and `training` had seeds of their own until 2026-09-13. Unpinned,
        // they follow Chat like every other member of their group.
        "rem": ("claude-opus-4-7", "high"),
        "training": ("claude-opus-4-7", "high"),
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
        // Cognitive reflection remains high effort, but its unpinned model
        // follows chat. A diagnostic/default path must not silently select an
        // Anthropic-specific model that the user never chose.
        "cognition_reflection": ("claude-opus-4-7", "high"),
        // `compaction` was added 2026-07-01 (R4 LLM-distilled autocompaction).
        // Unpinned it seeds to chat's pick (same rule as `memory`/`ios`), so
        // the distilled summary is written in Agent's current voice.
        "compaction": ("claude-opus-4-7", "high"),
        // `self_improvement` was added 2026-08-21 (sweep): the weekly
        // self-improvement loop already called with that surface but it was
        // missing from the registry, so it silently followed the chat pin
        // with no picker row. Unpinned it seeds to chat's pick (same rule as
        // `memory`/`heartbeat`/`diagnostics`).
        "self_improvement": ("claude-opus-4-7", "high"),
        // `studio_wander` ("her hour") had a cheap model and a bounded effort of
        // its own; since 2026-09-13 it is a plain member of Memory and mind and
        // follows the group's choice, which here is Chat's.
        "studio_wander": ("claude-opus-4-7", "high"),
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
    // Python: False or base -> base. The base is now "nothing chosen yet" on a
    // root with no account, not a literal model id (2026-09-13).
    #expect(prefs["chat"]?.model == "")
}

@Test func computeModelPreferences_null_model_falls_to_base() async throws {
    let body = """
    {"chat":null}
    """
    let sn = try makeSN(body)
    let prefs = try await sn.computeModelPreferences()
    // Python: None or base -> base. The base on a root with no account is
    // "nothing chosen yet" (2026-09-13), never a literal model id.
    #expect(prefs["chat"]?.model == "")
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

// MARK: - C9-5: every key a live picker store actually holds is classified

/// C9-5 (upgrade sweep 2026-08-28). Two picker surfaces were reported as
/// "unknown" — `cognition_cue` and `desk`. Re-checked against the live store
/// (`data/providers/surfaces.json` + `active.json`, 18 keys): `desk` is a
/// canonical `MODEL_SURFACES` row and `cognition_cue` is a dated entry in
/// `RETIRED_MODEL_SURFACE_KEYS`, so NEITHER is unknown today. Nothing pinned
/// that, though — `unsupportedStoredKeys` had no test asserting it stays empty
/// for the real key set, so a rename or a dropped retirement note would put a
/// silent "needs repair" banner in Provider Settings again.
///
/// This is that pin: the exact 18 keys on disk, classified.
@Test func providerSurfaceRowSet_classifiesEveryLiveStoredKey() {
    let liveStoredKeys: Set<String> = [
        "autonomy", "chat", "cognition_cue", "cognition_reflection", "compaction", "desk",
        "diagnostics", "dream", "heartbeat", "ios", "memory", "rem", "self_improvement",
        "slack", "swarms", "telegram", "training", "workshop",
    ]
    let rowSet = ProviderSurfaceRowSet(
        surfacePreferenceKeys: liveStoredKeys,
        activeProviderKeys: liveStoredKeys
    )

    #expect(
        rowSet.unsupportedStoredKeys.isEmpty,
        "live picker keys are unclassified: \(rowSet.unsupportedStoredKeys). Either add the surface to MODEL_SURFACES or give it a dated RETIRED_MODEL_SURFACE_KEYS entry."
    )
    // `desk` routes; `cognition_cue` is retired-with-a-reason. Both named
    // explicitly so a future edit cannot flip one without failing here.
    #expect(MODEL_SURFACES.contains("desk"))
    #expect(!MODEL_SURFACES.contains("cognition_cue"))
    #expect(rowSet.retiredStoredKeys == ["cognition_cue"])
    #expect(RETIRED_MODEL_SURFACE_KEYS["cognition_cue"]?.contains("retired 2026-08-24") == true)

    // Negative control: a genuinely unknown key MUST still surface as
    // unsupported, so the assertion above means "classified", not "lenient".
    let withStranger = ProviderSurfaceRowSet(
        surfacePreferenceKeys: liveStoredKeys.union(["not_a_surface"]),
        activeProviderKeys: liveStoredKeys
    )
    #expect(withStranger.unsupportedStoredKeys == ["not_a_surface"])
}

// MARK: - P2-3: the `missions` -> `workshop` routing-surface seam
//
// Every case below is a MISMATCHED pair on purpose. The picker files on a live
// 0.3.x install are keyed `missions`; the runtime asks for `workshop`. A test
// that wrote and read the same spelling would pass no matter which way the
// bridge was wired.

@Test func legacyMissionsPinInSurfacesFileResolvesUnderTheWorkshopSurface() async throws {
    // Live-shaped 0.3.7 surfaces.json: ONLY the legacy key exists.
    let sn = try makeSN("""
    {"chat":{"model":"gpt-5.6-sol"},
     "missions":{"model":"claude-opus-4-8","reasoningEffort":"low"}}
    """)
    let prefs = try await sn.computeModelPreferences()
    // The legacy key still FOLDS to the canonical surface — that is what this
    // test is for — and it is visible as a saved pick. It does not route on its
    // own: since 2026-09-13 (second review) a per-app key never does, so
    // workshop runs on the Work group's choice, which here is Chat's.
    #expect(await sn.pinnedModelStringForSurface("workshop") == "claude-opus-4-8")
    #expect(prefs["workshop"]?.model == "gpt-5.6-sol")
    // The routing map only ever speaks the canonical vocabulary now.
    #expect(prefs["missions"] == nil)
}

@Test func legacyMissionsSurfaceArgumentStillResolvesAfterTheRename() async throws {
    // A caller a version behind (iOS, a saved shortcut) still says "missions".
    // It must resolve, not throw `.invalidRequest` as an unknown surface.
    let sn = try makeSN("""
    {"chat":{"model":"gpt-5.6-sol"},"workshop":{"model":"claude-opus-4-8"}}
    """)
    // The point is that "missions" RESOLVES rather than throwing as unknown; the
    // model it resolves to is the Work group's choice (Chat's here), because a
    // per-app key does not route.
    let pref = try await sn.modelForSurface("missions")
    #expect(pref.surface == "workshop")
    #expect(pref.model == "gpt-5.6-sol")
    #expect(await sn.pinnedModelStringForSurface("missions") == "claude-opus-4-8")
}

@Test func legacyActiveProviderKeyResolvesUnderTheWorkshopSurface() async throws {
    let paths = try makeProviderRoutingTestPaths(
        surfacesBody: #"{"missions":{"model":"claude-opus-4-8"}}"#,
        activeBody: #"{"chat":"openai","missions":"anthropic"}"#
    )
    defer { try? FileManager.default.removeItem(at: paths.root) }
    let sn = SwiftNativeProviderRouting(
        dataRoot: paths.root,
        surfacesPathOverride: paths.surfaces,
        activeProviderPathOverride: paths.active
    )
    let snapshot = try await sn.checkedRoutingSnapshot()
    // Folded to the canonical spelling, and visible as a saved pick. The route
    // it actually runs on is the group's — a per-app assignment is as invisible
    // to a person as a per-app model, so it does not split the group either.
    #expect(snapshot.activeProviders["missions"] == nil)
    #expect(snapshot.pinnedModels["workshop"] == "claude-opus-4-8")
    #expect(snapshot.activeProviders["workshop"] == snapshot.activeProviders["chat"])
}

@Test func savingTheWorkshopSurfaceRetiresTheLegacyKeyInsteadOfDuplicatingIt() async throws {
    // The write-side migration: a legacy entry is replaced, not shadowed. Two
    // entries for one surface is the state where a later read has to guess.
    let paths = try makeProviderRoutingTestPaths(
        surfacesBody: #"{"chat":{"model":"gpt-5.6-sol"},"missions":{"model":"old-model"}}"#,
        activeBody: #"{"missions":"anthropic"}"#
    )
    defer { try? FileManager.default.removeItem(at: paths.root) }
    let sn = SwiftNativeProviderRouting(
        dataRoot: paths.root,
        surfacesPathOverride: paths.surfaces,
        activeProviderPathOverride: paths.active
    )
    try await sn.saveSurfaceConfiguration(
        surface: "workshop",
        model: "new-model",
        reasoningEffort: "high",
        serviceTier: nil,
        providerId: "openai"
    )

    let surfacesJSON = try JSONSerialization.jsonObject(
        with: Data(contentsOf: paths.surfaces)
    ) as? [String: Any]
    #expect(surfacesJSON?["missions"] == nil, "legacy surface key must be retired on write")
    #expect(((surfacesJSON?["workshop"] as? [String: Any])?["model"] as? String) == "new-model")
    // An untouched surface keeps its bytes — this is not a flag-day rewrite.
    #expect(((surfacesJSON?["chat"] as? [String: Any])?["model"] as? String) == "gpt-5.6-sol")

    let activeJSON = try JSONSerialization.jsonObject(
        with: Data(contentsOf: paths.active)
    ) as? [String: Any]
    #expect(activeJSON?["missions"] == nil)
    #expect(activeJSON?["workshop"] as? String == "openai")
}

@Test func savingViaTheLegacySurfaceNameWritesTheCanonicalKey() async throws {
    // The old spelling as an ARGUMENT (not a file key): accepted, canonicalized.
    let paths = try makeProviderRoutingTestPaths()
    defer { try? FileManager.default.removeItem(at: paths.root) }
    let sn = SwiftNativeProviderRouting(
        dataRoot: paths.root,
        surfacesPathOverride: paths.surfaces,
        activeProviderPathOverride: paths.active
    )
    try await sn.saveSurfacePreference(
        surface: "missions",
        model: "claude-opus-4-8",
        reasoningEffort: "high",
        serviceTier: nil
    )
    let surfacesJSON = try JSONSerialization.jsonObject(
        with: Data(contentsOf: paths.surfaces)
    ) as? [String: Any]
    #expect(surfacesJSON?["missions"] == nil, "writers emit only the canonical spelling")
    #expect(((surfacesJSON?["workshop"] as? [String: Any])?["model"] as? String) == "claude-opus-4-8")
}

@Test func surfaceLookupBridgeReadsAMapKeyedInEitherVocabulary() {
    // The reader bridge itself, both directions. Conformers outside this module
    // (test doubles, app-side wrappers) can still hand back a legacy-keyed map.
    let legacyKeyed = ["missions": 1, "chat": 2]
    let canonicalKeyed = ["workshop": 3, "chat": 4]
    #expect(ProviderRoutingSurfaceLookup.value(legacyKeyed, "workshop") == 1)
    #expect(ProviderRoutingSurfaceLookup.value(legacyKeyed, "missions") == 1)
    #expect(ProviderRoutingSurfaceLookup.value(canonicalKeyed, "missions") == 3)
    #expect(ProviderRoutingSurfaceLookup.value(canonicalKeyed, "workshop") == 3)
    // A non-Workshop miss must NOT fall back to the legacy key.
    #expect(ProviderRoutingSurfaceLookup.value(legacyKeyed, "telegram") == nil)
}
