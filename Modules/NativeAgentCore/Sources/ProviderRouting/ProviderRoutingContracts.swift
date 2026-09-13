import Foundation
import NativeAgentCore
import PersistenceCore

/// The Providers page offers exactly THREE choices — **Chat**, **Work**, and
/// **Memory and mind** — and this table is the only place that says which
/// activity belongs to which. User, 2026-09-13: the grouping is the ROUTING rule,
/// not a layout ("Dream, REM, everything should go to the memory model; I
/// already specified that when we compressed provider picks"), and "if you've
/// missed anything, it needs to be up there on Providers".
///
/// The page's member captions and the router's membership are generated from the
/// SAME list, so they cannot disagree, and every routed surface is claimed by one
/// group — there is no "one row per unclaimed surface" path any more. The
/// resolver keeps no per-surface seed, effort or provider exception: a member
/// with no saved pick follows its group's choice, and a group with no override
/// follows Chat.
///
/// What this replaced: hand-written per-surface seeds (`dream`/`rem`/
/// `studio_wander` on a cheap model, `workshop`/`autonomy`/`swarms` on the
/// primary, `training` on another), which could aim a lane at a model the
/// group's connected route cannot serve. On a fresh 0.4.11 install whose only
/// account was a ChatGPT one, the cheap dream seed was refused by that backend
/// and dreams could never run.
public struct ProviderSurfaceMember: Sendable, Equatable {
    /// The routing surface id, as written in `providers/surfaces.json`.
    public let surface: String
    /// What the Providers page calls it, in a person's words.
    public let label: String

    public init(_ surface: String, _ label: String) {
        self.surface = surface
        self.label = label
    }
}

public struct ProviderSurfaceGroup: Sendable, Equatable, Identifiable {
    public let id: String
    public let title: String
    public let members: [ProviderSurfaceMember]

    public init(id: String, title: String, members: [ProviderSurfaceMember]) {
        self.id = id
        self.title = title
        self.members = members
    }

    public var surfaces: [String] { members.map(\.surface) }

    /// The caption under a group's row: what this choice actually governs.
    public var caption: String {
        let names = members.map(\.label)
        guard names.count > 1 else { return names.first ?? "" }
        return names.dropLast().joined(separator: ", ") + " and " + names[names.count - 1]
    }
}

public enum ProviderSurfaceGroups {
    public static let chat = ProviderSurfaceGroup(
        id: "chat", title: "Chat",
        members: [
            .init("chat", "Chat"),
            .init("ios", "iPhone"),
            .init("telegram", "Telegram"),
            .init("slack", "Slack"),
        ]
    )
    public static let work = ProviderSurfaceGroup(
        id: "work", title: "Work",
        members: [
            .init("desk", "Desk"),
            .init("workshop", "Task execution"),
            .init("autonomy", "Independent tasks"),
            .init("swarms", "Coordinated tasks"),
            .init("training", "Skill practice"),
            .init("heartbeat", "Background check-ins"),
            .init("diagnostics", "Diagnostics"),
        ]
    )
    public static let mind = ProviderSurfaceGroup(
        id: "memory_and_mind", title: "Memory and mind",
        members: [
            .init("memory", "Memory"),
            .init("dream", "Dreams"),
            .init("rem", "REM"),
            .init("cognition_reflection", "Reflection"),
            .init("compaction", "Conversation summaries"),
            .init("self_improvement", "Learning"),
            .init("studio_wander", "Creative exploration"),
        ]
    )
    public static let all: [ProviderSurfaceGroup] = [chat, work, mind]

    /// Every label, keyed by surface — the page reads its row names from here so
    /// a name can never drift from the group that owns it.
    public static let labels: [String: String] = Dictionary(
        uniqueKeysWithValues: all.flatMap(\.members).map { ($0.surface, $0.label) }
    )

    public static func group(for surface: String) -> ProviderSurfaceGroup? {
        let canonical = canonicalRoutingSurface(surface)
        return all.first { $0.surfaces.contains(canonical) }
    }

    public static func members(of surface: String) -> [String] {
        group(for: surface)?.surfaces ?? [canonicalRoutingSurface(surface)]
    }

    /// The two tables must cover each other exactly: every routed surface has a
    /// Providers row, and no group names a surface that is not routed. Called at
    /// startup so a new surface cannot be added without deciding where it shows.
    public static func membershipMismatch() -> String? {
        let grouped = all.flatMap(\.surfaces)
        let routed = Set(MODEL_SURFACES)
        var problems: [String] = []
        let duplicates = grouped.filter { surface in grouped.filter { $0 == surface }.count > 1 }
        if !duplicates.isEmpty {
            problems.append("in more than one group: \(Set(duplicates).sorted().joined(separator: ", "))")
        }
        let ungrouped = routed.subtracting(grouped).sorted()
        if !ungrouped.isEmpty {
            problems.append("routed but in no Providers group: \(ungrouped.joined(separator: ", "))")
        }
        let unrouted = Set(grouped).subtracting(routed).sorted()
        if !unrouted.isEmpty {
            problems.append("in a Providers group but not routed: \(unrouted.joined(separator: ", "))")
        }
        return problems.isEmpty ? nil : problems.joined(separator: "; ")
    }
}

/// One answer to "can this route actually run this model at this effort?",
/// used wherever a provider/model/effort tuple is CHOSEN rather than resolved
/// — the Bots editor, the bot tools, and the bot runner before it spends a turn.
///
/// User, 2026-09-13: "Bots has no default model; Agent is supposed to pick the
/// model when she makes one." A bot carries its own tuple, so nothing downstream
/// re-resolves it; that makes it the one place a nonsense tuple could reach a
/// provider, and this is the check that stops it. No provider branches: the
/// route's catalog is the authority, and a route whose catalog is fetched rather
/// than shipped is trusted with any id.
public enum ProviderModelChoice {
    /// nil when the tuple is usable, else a sentence naming what is wrong.
    public static func rejection(
        provider: String?,
        model: String?,
        reasoningEffort: String?
    ) -> String? {
        let route = provider?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let id = model?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let effort = reasoningEffort?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        guard !route.isEmpty else { return "Choose the account this runs on." }
        guard !id.isEmpty else { return "Choose a model on that account." }
        guard !effort.isEmpty else { return "Choose a Think level for that model." }
        guard REASONING_EFFORT_OPTIONS.contains(effort) else {
            return "\(effort) is not a Think level."
        }
        guard FirstPartyModelCatalog.routeCarries(id, providerID: route) else {
            return "\(route) does not serve \(id). Pick a model that account offers."
        }
        if let supported = FirstPartyModelCatalog.routeSupportedEfforts(id, providerID: route),
           !supported.isEmpty,
           !supported.contains(effort) {
            return "\(id) does not support Think \(effort); it supports "
                + supported.joined(separator: ", ") + "."
        }
        return nil
    }

    public static func isUsable(
        provider: String?,
        model: String?,
        reasoningEffort: String?
    ) -> Bool {
        rejection(provider: provider, model: model, reasoningEffort: reasoningEffort) == nil
    }
}

// MARK: - Subsystem #14: ProviderRouting
//
// SwiftNative owns provider inspection/configuration from local app data.
//
// Scope: provider CONFIG/INSPECTION plus per-surface model-preference storage:
// list providers, get one, configure one, run a connectivity test, and
// read/write model preferences. Live chat routing is Swift-native too:
// ChatOrchestration resolves the surface/model choice and SwiftNativeLLMClient
// dispatches to the installed OAuth/API-key adapters. This file is not the
// whole routing engine; it is the provider state/config surface used by the UI
// and by that Swift chat pipeline.
//
// Legacy route vocabulary kept for compatibility with app/UI callers:
//   GET  /v1/providers                    - list provider records
//   GET  /v1/providers/<id>               - one provider
//   POST /v1/providers/<id>/configure     - set credentials/auth mode
//   POST /v1/providers/<id>/test          - connectivity probe
//   GET  /v1/config                       - modelRouting preferences
//   POST /v1/config/model                 - save surface/model/effort choice
//
// There is intentionally no dedicated model-preferences route; the app keeps
// reading/writing the established `modelRouting` envelope so existing UI/state
// decoding remains stable.

// MARK: - Provider

public struct Provider: Sendable, Codable, Equatable {
    public var id: String
    public var displayName: String?
    public var kind: String?
    public var configured: Bool?
    public var active: Bool?
    public var surface: String?
    public var modelCatalog: JSONValue?
    public var oauthStatus: JSONValue?
    public var lastTestedAt: String?
    public var lastError: String?
    public var extras: JSONValue?

    public init(
        id: String,
        displayName: String? = nil,
        kind: String? = nil,
        configured: Bool? = nil,
        active: Bool? = nil,
        surface: String? = nil,
        modelCatalog: JSONValue? = nil,
        oauthStatus: JSONValue? = nil,
        lastTestedAt: String? = nil,
        lastError: String? = nil,
        extras: JSONValue? = nil
    ) {
        self.id = id
        self.displayName = displayName
        self.kind = kind
        self.configured = configured
        self.active = active
        self.surface = surface
        self.modelCatalog = modelCatalog
        self.oauthStatus = oauthStatus
        self.lastTestedAt = lastTestedAt
        self.lastError = lastError
        self.extras = extras
    }

    private static let knownKeys: Set<String> = [
        "id", "provider_id", "providerId",
        "displayName", "display_name",
        "kind", "type",
        "configured",
        "active",
        "surface",
        "modelCatalog", "models",
        "oauthStatus", "auth_status", "authStatus",
        "lastTestedAt", "last_tested_at",
        "lastError", "last_error",
        "extras",
    ]

    private struct AnyKey: CodingKey, Hashable {
        var stringValue: String
        var intValue: Int? { nil }
        init(_ s: String) { self.stringValue = s }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { return nil }
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyKey.self)
        func str(_ keys: String...) throws -> String? {
            for k in keys {
                if let key = AnyKey(stringValue: k),
                   let v = (try? c.decodeIfPresent(String.self, forKey: key)) ?? nil {
                    return v
                }
            }
            return nil
        }
        func bool(_ keys: String...) throws -> Bool? {
            for k in keys {
                if let key = AnyKey(stringValue: k),
                   let v = (try? c.decodeIfPresent(Bool.self, forKey: key)) ?? nil {
                    return v
                }
            }
            return nil
        }
        func jv(_ keys: String...) throws -> JSONValue? {
            for k in keys {
                if let key = AnyKey(stringValue: k),
                   let v = (try? c.decodeIfPresent(JSONValue.self, forKey: key)) ?? nil {
                    return v
                }
            }
            return nil
        }

        let idVal = try str("id", "provider_id", "providerId") ?? ""
        self.id = idVal
        self.displayName = try str("displayName", "display_name")
        self.kind = try str("kind", "type")
        self.configured = try bool("configured")
        self.active = try bool("active")
        self.surface = try str("surface")
        self.modelCatalog = try jv("modelCatalog", "models")
        self.oauthStatus = try jv("oauthStatus", "auth_status", "authStatus")
        self.lastTestedAt = try str("lastTestedAt", "last_tested_at")
        self.lastError = try str("lastError", "last_error")

        var unknown: [String: JSONValue] = [:]
        for key in c.allKeys where !Self.knownKeys.contains(key.stringValue) {
            if let v = try? c.decode(JSONValue.self, forKey: key) {
                unknown[key.stringValue] = v
            }
        }
        if let explicit = try jv("extras"), case .object(let obj) = explicit {
            for (k, v) in obj { unknown[k] = v }
        }
        self.extras = unknown.isEmpty ? nil : .object(unknown)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: AnyKey.self)
        try c.encode(id, forKey: AnyKey("id"))
        try c.encodeIfPresent(displayName, forKey: AnyKey("displayName"))
        try c.encodeIfPresent(kind, forKey: AnyKey("kind"))
        try c.encodeIfPresent(configured, forKey: AnyKey("configured"))
        try c.encodeIfPresent(active, forKey: AnyKey("active"))
        try c.encodeIfPresent(surface, forKey: AnyKey("surface"))
        try c.encodeIfPresent(modelCatalog, forKey: AnyKey("modelCatalog"))
        try c.encodeIfPresent(oauthStatus, forKey: AnyKey("oauthStatus"))
        try c.encodeIfPresent(lastTestedAt, forKey: AnyKey("lastTestedAt"))
        try c.encodeIfPresent(lastError, forKey: AnyKey("lastError"))
        if case .object(let obj)? = extras {
            for (k, v) in obj where !Self.knownKeys.contains(k) {
                try c.encode(v, forKey: AnyKey(k))
            }
        }
    }
}

// MARK: - ModelPreferences

public struct ModelPreferences: Sendable, Codable, Equatable {
    public var surfaceModels: JSONValue?
    public var defaultModel: String?
    public var fallbackChain: [String]?
    public var extras: JSONValue?

    public init(
        surfaceModels: JSONValue? = nil,
        defaultModel: String? = nil,
        fallbackChain: [String]? = nil,
        extras: JSONValue? = nil
    ) {
        self.surfaceModels = surfaceModels
        self.defaultModel = defaultModel
        self.fallbackChain = fallbackChain
        self.extras = extras
    }

    enum CodingKeys: String, CodingKey {
        case surfaceModels = "surface_models"
        case defaultModel = "default_model"
        case fallbackChain = "fallback_chain"
        case extras
    }
}

// MARK: - ProviderTestResult

public struct ProviderTestResult: Sendable, Codable, Equatable {
    public var rawResponse: JSONValue
    public init(rawResponse: JSONValue) { self.rawResponse = rawResponse }
    enum CodingKeys: String, CodingKey { case rawResponse = "raw_response" }
}

// MARK: - Errors

public enum ProviderRoutingError: Error, LocalizedError {
    case invalidRequest
    case providerNotFound
    case configurationFailed(String)
    case invalidResponse(status: Int)
    case unavailable
    case underlying(String)

    public var errorDescription: String? {
        switch self {
        case .invalidRequest: return "providers: invalid request"
        case .providerNotFound: return "providers: provider not found"
        case .configurationFailed(let m): return "providers: configuration failed: \(m)"
        case .invalidResponse(let s): return "providers: native implementation returned unexpected status \(s)"
        case .unavailable: return "providers: unavailable"
        case .underlying(let m): return "providers: \(m)"
        }
    }
}

// MARK: - SurfacePreference (Phase B picker output)

/// One per-surface picker entry. Mirrors Python's
/// `model_preferences()[surface]` dict: {surface, model, reasoningEffort,
/// modelKnown?}. `modelKnown` is left nil here because computing it requires
/// the compact model catalog — which is still a daemon-side responsibility.
public struct SurfacePreference: Sendable, Codable, Equatable {
    public var surface: String
    public var model: String
    public var reasoningEffort: String
    public var serviceTier: String
    public var modelKnown: Bool?

    public init(
        surface: String,
        model: String,
        reasoningEffort: String,
        serviceTier: String = "default",
        modelKnown: Bool? = nil
    ) {
        self.surface = surface
        self.model = model
        self.reasoningEffort = reasoningEffort
        self.serviceTier = serviceTier
        self.modelKnown = modelKnown
    }
}

/// One reconciled, internally consistent view of the two authoritative picker
/// projections. Execution paths use this instead of independently reading
/// model preferences, active providers, and explicit pins across separate
/// locks, which could otherwise combine values from different commits.
public struct ProviderRoutingSnapshot: Sendable, Equatable {
    public let preferences: [String: SurfacePreference]
    public let activeProviders: [String: String]
    public let pinnedModels: [String: String]
    /// Surfaces whose saved pick cannot be used, keyed to the sentence that says
    /// why — ready to show on the Providers row and to refuse a turn with.
    ///
    /// 2026-09-13, second review: NOTHING is ever substituted for such a pick,
    /// not a literal and not the route's own default. Both ways it could fail
    /// read the same to a person ("my model quietly changed"), so both end the
    /// same way: the surface is unset and this says what to fix.
    ///   * gone from every catalog — "Your Chat model, gpt-5.4, is no longer
    ///     offered. Choose one."
    ///   * not served by the route it sits on — "claude-opus-4-8 isn't offered
    ///     on openai_oauth_direct. Choose one."
    public let unusablePicks: [String: String]

    public init(
        preferences: [String: SurfacePreference],
        activeProviders: [String: String],
        pinnedModels: [String: String],
        unusablePicks: [String: String] = [:]
    ) {
        self.preferences = preferences
        self.activeProviders = activeProviders
        self.pinnedModels = pinnedModels
        self.unusablePicks = unusablePicks
    }

    /// The sentence to show for `surface` when it has no model because the one
    /// it had cannot be used, else nil.
    public func unusablePickNotice(for surface: String) -> String? {
        ProviderRoutingSurfaceLookup.value(unusablePicks, surface)
    }
}

// MARK: - Phase B constants (mirror daemon)

/// MUST stay in sync with the retired daemon (`MODEL_SURFACES`).
/// `rem` was added 2026-06-05 alongside the dream/REM design restore so the
/// per-surface picker can pin the weekly REM consolidation to a specific
/// model independently of nightly dream. Both surfaces fall back to `chat`
/// when unpinned (see DreamCycleRunner + REMConsolidator) so the design
/// "she speaks in her current voice" intent holds by default.
/// `memory` was added 2026-06-10 (U3 wave-2 follow-up, the user's directive:
/// "everything that makes an LLM call should have a model picker") for the
/// memory-machinery LLM calls — the kind-backfill classifier today, future
/// hygiene/merge judgments. Unpinned it follows `chat` (pin-only lookup,
/// same consumer-side pattern as dream/rem) so it always runs on whatever
/// model Agent is currently on unless the user pins something cheaper.
/// `heartbeat` + `diagnostics` were added 2026-06-11 (U2b wave 3, the user's HARD
/// RULE: every LLM call site resolves via the picker, never a hardcoded
/// model). `heartbeat` is the cheap interval health turn (HeartbeatLoop);
/// `diagnostics` is the self-healing root-cause pass (SelfHealingHook). Both
/// follow the `memory` precedent — unpinned they seed to chat's pick (so they
/// run on Agent's current model), and the user can pin either to a cheaper model.
/// `slack` was added 2026-06-17 after Slack became a real inbound chat
/// surface. It follows chat/Telegram by default but must be independently
/// selectable so the user can pin Anthropic/OpenAI/etc. from Providers like every
/// other chat surface.
/// `compaction` was added 2026-07-01 (R4 LLM-distilled chat autocompaction).
/// It resolves the model for the background pass that re-writes the mechanical
/// compaction summary into a richer recollection. Unpinned it follows the chat
/// model (same seed-to-chat rule as `memory`/`ios`) so the summary is written in
/// the assistant's current voice; the user can pin a cheaper model from Providers.
/// `missions` was renamed to `workshop` on 2026-08-05 (P2-3). It is NOT listed
/// here anymore — instead every surface entering this module is folded through
/// `canonicalRoutingSurface`, and `providers/surfaces.json` / `active.json` keys
/// are folded at their single read seam (`reconciledPickerState`). A 0.3.x
/// install whose picker files still say `missions` therefore keeps its pin.
/// `self_improvement` was added 2026-08-21: WeeklySelfImprovementLoop already
/// called with that surface, but absent from this registry it silently fell
/// through to the chat pin — unpinnable and invisible in Providers.
/// `studio_wander` was added 2026-09-02 (personality depth item 9, "her hour"):
/// the once-a-day wandering lane makes its own call, and whose model she thinks
/// with when nobody is watching is a real choice — so it gets its own pickable
/// row beside `dream` rather than inheriting chat's.
public let MODEL_SURFACES: [String] = [
    "chat", "ios", "telegram", "slack", "desk", "workshop", "autonomy", "swarms", "dream", "rem", "training",
    "memory", "heartbeat", "diagnostics", "cognition_reflection", "compaction", "self_improvement",
    "studio_wander",
]

/// Persisted picker keys that deliberately no longer have a routed surface.
/// Keep the retirement date and reason beside the key so a missing Provider
/// Settings row is an intentional compatibility decision, never a silent
/// omission. Entries leave this allowlist only after their saved keys have
/// been migrated away from real installations.
public let RETIRED_MODEL_SURFACE_KEYS: [String: String] = [
    "cognition_cue": "retired 2026-08-24: cue authoring no longer has a routed LLM consumer",
]

/// One auditable answer to the Provider Settings row-set question. The picker
/// renders `visibleSurfaces`; persisted keys outside it must be named either by
/// the dated retirement allowlist or by `unsupportedStoredKeys`, which the UI
/// renders as an adverse configuration state.
public struct ProviderSurfaceRowSet: Sendable, Equatable {
    public let visibleSurfaces: [String]
    public let retiredStoredKeys: [String]
    public let unsupportedStoredKeys: [String]

    public init(
        surfacePreferenceKeys: Set<String>,
        activeProviderKeys: Set<String>
    ) {
        let stored = Set(surfacePreferenceKeys
            .union(activeProviderKeys)
            .map(canonicalRoutingSurface))
        let visible = Set(MODEL_SURFACES)
        let retired = Set(RETIRED_MODEL_SURFACE_KEYS.keys)
        self.visibleSurfaces = MODEL_SURFACES
        self.retiredStoredKeys = stored.intersection(retired).sorted()
        self.unsupportedStoredKeys = stored
            .subtracting(visible)
            .subtracting(retired)
            .sorted()
    }
}

/// The ONE bridge every routing entry point runs its `surface` argument
/// through. Callers on 0.3.x wire vocabulary (`missions`) and callers on the
/// new one (`workshop`) resolve to the same preference, pin, and provider hint.
public func canonicalRoutingSurface(_ surface: String) -> String {
    WorkshopSurfaceVocabulary.canonicalSurface(surface)
}

/// MUST stay in sync with the retired daemon (`REASONING_EFFORT_OPTIONS`).
public let REASONING_EFFORT_OPTIONS: [String] = ["none", "low", "medium", "high", "xhigh", "max", "ultra"]

public let SERVICE_TIER_OPTIONS: [String] = ["default", "priority"]

/// Top-level re-export of the canonical model id. Single source of truth
/// is `nativeAgentPrimaryModel` in NativeAgentCore/Constants.swift; this
/// alias is kept because existing callsites in this file and tests
/// reference `PRIMARY_MODEL` by name. Mirrors the retired daemon.
public let PRIMARY_MODEL: String = nativeAgentPrimaryModel

/// MUST stay in sync with the retired daemon (`DEFAULT_REASONING_EFFORT`).
public let DEFAULT_REASONING_EFFORT: String = "high"

// MARK: - Protocol

public protocol ProviderRoutingProtocol: Sendable {
    func listProviders() async throws -> [Provider]
    func getProvider(id: String) async throws -> Provider
    func configureProvider(id: String, config: JSONValue) async throws -> Provider
    func testProvider(id: String) async throws -> ProviderTestResult
    func getModelPreferences() async throws -> ModelPreferences
    func saveModelConfig(_ body: JSONValue) async throws -> ModelPreferences
    /// Swift-native per-surface picker. Reads `providers/surfaces.json`
    /// and `providers/active.json`, then returns seeded preferences for
    /// every MODEL_SURFACE (sans `modelKnown`, which needs the model catalog).
    func computeModelPreferences() async throws -> [String: SurfacePreference]
    /// Atomic checked view of preferences, active providers, and explicit pins.
    /// The Swift-native owner derives all three from one reconciled tuple.
    func checkedRoutingSnapshot() async throws -> ProviderRoutingSnapshot
    /// Pin-only lookup: returns the model string ONLY when this surface
    /// is explicitly pinned in `providers/surfaces.json`. Used by dream /
    /// REM so they can fall back to the chat-surface model when nothing
    /// is pinned (preserving Agent's current voice by default).
    func pinnedModelStringForSurface(_ surface: String) async -> String?
    /// Throwing execution seam. Corrupt provider authority is unavailable,
    /// never equivalent to an unpinned surface.
    func pinnedModelStringForSurfaceChecked(_ surface: String) async throws -> String?
    /// Read `<dataRoot>/providers/active.json` (surface → provider hint
    /// written by `setActiveProvider`). Empty map when missing. The LLM
    /// dispatch layer uses this as a tiebreaker for ambiguous model ids.
    func activeProvidersForSurfaces() async -> [String: String]
    /// Throwing execution seam. Corrupt provider authority is unavailable,
    /// never equivalent to an empty active-provider map.
    func activeProvidersForSurfacesChecked() async throws -> [String: String]
    /// Best-effort provider inference for a model id. This is used by
    /// prompt/runtime introspection paths when no explicit active provider is
    /// pinned for the current surface.
    func inferProviderForModel(_ modelId: String) -> String?
}

extension ProviderRoutingProtocol {
    /// Default empty so existing conformers keep compiling. The SwiftNative
    /// impl overrides this to read providers/active.json.
    public func activeProvidersForSurfaces() async -> [String: String] { [:] }

    /// Compatibility implementation for test/dummy routers. The production
    /// Swift-native owner overrides this with a single locked disk snapshot.
    public func checkedRoutingSnapshot() async throws -> ProviderRoutingSnapshot {
        let preferences = try await computeModelPreferences()
        let active = await activeProvidersForSurfaces()
        var pins: [String: String] = [:]
        for surface in MODEL_SURFACES {
            if let model = await pinnedModelStringForSurface(surface) {
                pins[surface] = model
            }
        }
        return ProviderRoutingSnapshot(
            preferences: preferences,
            activeProviders: active,
            pinnedModels: pins
        )
    }

    public func activeProvidersForSurfacesChecked() async throws -> [String: String] {
        try await checkedRoutingSnapshot().activeProviders
    }

    public func pinnedModelStringForSurfaceChecked(_ surface: String) async throws -> String? {
        ProviderRoutingSurfaceLookup.value(try await checkedRoutingSnapshot().pinnedModels, surface)
    }

    public func inferProviderForModel(_ modelId: String) -> String? {
        SwiftNativeProviderRouting.inferredProviderID(forModel: modelId)
    }

    /// Convenience: per-surface model lookup via the picker. Returns nil
    /// when the surface is unknown or the picker has no entry. Dream / REM
    /// / Workshop executions / telegram callers use this to pass an explicit model
    /// into LLMClient.complete instead of falling through to the "chat"
    /// surface seed.
    public func modelStringForSurface(_ surface: String) async -> String? {
        guard let prefs = try? await computeModelPreferences() else { return nil }
        if let m = ProviderRoutingSurfaceLookup.value(prefs, surface)?.model, !m.isEmpty {
            return m
        }
        return nil
    }

    /// Returns the pinned model only when the surface is EXPLICITLY pinned
    /// in `providers/surfaces.json`. Unlike `modelStringForSurface(_:)` —
    /// which can't distinguish a seed default from a user pin — this
    /// returns nil whenever there is no on-disk pick for the surface, so
    /// callers like dream / REM can fall back to the chat-surface model
    /// and preserve Agent's current voice by default.
    ///
    /// Default implementation here returns nil; the SwiftNative actor
    /// overrides with a real on-disk read. Test fakes get the default
    /// "no pin" so they continue to fall back through their own paths.
    public func pinnedModelStringForSurface(_ surface: String) async -> String? {
        return nil
    }

    /// True when `surface` has a routing identity of its own: a model pin, or
    /// a provider assigned to its Providers row (onboarding writes assignments
    /// with no pin, so a pin-only test misses them).
    ///
    /// User, 2026-09-06: a surface with NEITHER must follow chat's model AND
    /// chat's provider. Routing a blank surface on its own key hands dispatch a
    /// surface with no `active.json` entry, and the adapter is then inferred
    /// from the model prefix — so a bare `gpt-` id chat serves over the Codex
    /// CLI or the OpenAI API would silently take ChatGPT OAuth instead.
    public func surfaceHasOwnRouting(_ surface: String) async -> Bool {
        if await pinnedModelStringForSurface(surface) != nil { return true }
        let assigned = ProviderRoutingSurfaceLookup
            .value(await activeProvidersForSurfaces(), surface)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return assigned?.isEmpty == false
    }
}

/// P2-3 reader bridge for any surface-keyed routing map.
///
/// Both vocabularies can appear on EITHER side here: a caller still passing
/// `missions` (iOS a version behind, an old script), and a preferences map
/// produced by a conformer that has not been renamed (test doubles, and the
/// protocol defaults running over a fake `computeModelPreferences`). Trying the
/// canonical key and then the legacy key is what keeps a mismatched pair from
/// resolving to nil and silently falling back to the chat-surface model.
public enum ProviderRoutingSurfaceLookup {
    public static func value<V>(_ map: [String: V], _ surface: String) -> V? {
        let canonical = WorkshopSurfaceVocabulary.canonicalSurface(surface)
        if let hit = map[canonical] { return hit }
        guard canonical == WorkshopSurfaceVocabulary.canonical else { return nil }
        return map[WorkshopSurfaceVocabulary.legacy]
    }
}
