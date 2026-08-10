import Foundation
import CryptoKit
import NativeAgentCore
import PersistenceCore

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

    public init(
        preferences: [String: SurfacePreference],
        activeProviders: [String: String],
        pinnedModels: [String: String]
    ) {
        self.preferences = preferences
        self.activeProviders = activeProviders
        self.pinnedModels = pinnedModels
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
public let MODEL_SURFACES: [String] = [
    "chat", "ios", "telegram", "slack", "workshop", "autonomy", "swarms", "dream", "rem", "training",
    "memory", "heartbeat", "diagnostics", "cognition_reflection", "compaction",
]

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
        let lower = modelId.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if lower.isEmpty { return nil }
        if lower.hasPrefix("anthropic/") || lower.hasPrefix("openai/") {
            return "openrouter"
        }
        if lower.hasPrefix("claude-")
            || lower.hasPrefix("sonnet/") || lower.hasPrefix("opus/") || lower.hasPrefix("haiku/") {
            return "anthropic_oauth_direct"
        }
        if lower.hasPrefix("gpt-") {
            return "openai_oauth_direct"
        }
        if lower.hasPrefix("grok-") {
            return "xai_oauth_direct"
        }
        // Kimi Code SUBSCRIPTION ids resolve to "kimi-code" even though two of
        // them carry the `kimi-` prefix that otherwise routes to moonshot.
        // Checked BEFORE the moonshot prefix branch; moonshot's own kimi-k2*/
        // kimi-latest/kimi-k3 ids are not in this set and keep resolving below.
        if FirstPartyModelCatalog.kimiCodeModelIDSet.contains(lower) {
            return "kimi-code"
        }
        if lower.hasPrefix("kimi-") || lower.hasPrefix("moonshot-") {
            return "moonshot"
        }
        return nil
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

// MARK: - SwiftNative impl
//
// Phase B (2026-05-31): the per-surface PICKER methods
// (`computeModelPreferences`, `modelForSurface`, `normalizeModelId`,
// `normalizeReasoningEffort`, `inferProviderForModel`) are now SwiftNative —
// they read/write Swift-native provider picker state through PersistenceCore
// without any HTTP.
//
// The SwiftNative actor reads/writes the provider registry, provider token
// files, and model-surface picker directly.

public actor SwiftNativeProviderRouting: ProviderRoutingProtocol {
    public enum SurfaceCommitStep: Sendable {
        case manifestPrepared
        case surfacesCommitted
        case activeProviderCommitted
    }

    private let dataRoot: URL
    private let surfacesPath: URL
    private let activeProviderPath: URL
    private let persistence: any PersistenceCoreProtocol
    private let surfaceCommitFailureInjector: (@Sendable (SurfaceCommitStep) throws -> Void)?

    /// `dataRoot` owns provider registry/config/catalog reads and writes. The
    /// two path overrides are narrower fixture seams for picker files only;
    /// they must not silently leave the rest of the actor on the personal
    /// root. Secondary/test runtimes therefore pass their exact data root.
    public init(
        dataRoot: URL = PersistenceCore.defaultDataRoot(),
        surfacesPathOverride: URL? = nil,
        activeProviderPathOverride: URL? = nil,
        persistence: any PersistenceCoreProtocol = SwiftNativePersistenceCore(),
        surfaceCommitFailureInjector: (@Sendable (SurfaceCommitStep) throws -> Void)? = nil
    ) {
        self.persistence = persistence
        self.surfaceCommitFailureInjector = surfaceCommitFailureInjector
        self.dataRoot = dataRoot.standardizedFileURL
        if let override = surfacesPathOverride {
            self.surfacesPath = override
        } else {
            self.surfacesPath = self.dataRoot
                .appendingPathComponent("providers", isDirectory: true)
                .appendingPathComponent("surfaces.json")
        }
        if let override = activeProviderPathOverride {
            self.activeProviderPath = override
        } else {
            self.activeProviderPath = self.dataRoot
                .appendingPathComponent("providers", isDirectory: true)
                .appendingPathComponent("active.json")
        }
    }

    private var surfaceTransactionPath: URL {
        surfacesPath.deletingLastPathComponent()
            .appendingPathComponent("pending-surface-configuration.json")
    }

    /// Provider state is bootstrap-empty only when absent. Existing unreadable,
    /// malformed, or wrong-shaped bytes are unavailable and must never be
    /// rewritten by a picker/config mutation as if they were missing.
    public nonisolated static func loadProviderStateObjectChecked(
        at path: URL,
        description: String
    ) throws -> [String: JSONValue] {
        guard FileManager.default.fileExists(atPath: path.path) else { return [:] }
        let data: Data
        do {
            data = try Data(contentsOf: path)
        } catch {
            throw ProviderRoutingError.underlying("saved \(description) state is unreadable")
        }
        let value: JSONValue
        do {
            value = try JSONDecoder().decode(JSONValue.self, from: data)
        } catch {
            throw ProviderRoutingError.underlying("saved \(description) state is malformed")
        }
        guard case .object(let object) = value else {
            throw ProviderRoutingError.underlying("saved \(description) state must be a JSON object")
        }
        return object
    }

    public nonisolated static func loadActiveProviderStateChecked(
        at path: URL
    ) throws -> [String: String] {
        let raw = try loadProviderStateObjectChecked(at: path, description: "active-provider")
        return try loadActiveProviderObjectChecked(raw)
    }

    private struct PendingSurfaceConfiguration: Sendable {
        let surfacesBaseHash: String?
        let activeBaseHash: String?
        let surfaces: [String: JSONValue]
        let active: [String: JSONValue]

        var json: JSONValue {
            .object([
                "schemaVersion": .int(1),
                "surfacesBaseHash": surfacesBaseHash.map(JSONValue.string) ?? .null,
                "activeBaseHash": activeBaseHash.map(JSONValue.string) ?? .null,
                "surfaces": .object(surfaces),
                "active": .object(active),
            ])
        }

        init(
            surfacesBaseHash: String?,
            activeBaseHash: String?,
            surfaces: [String: JSONValue],
            active: [String: JSONValue]
        ) {
            self.surfacesBaseHash = surfacesBaseHash
            self.activeBaseHash = activeBaseHash
            self.surfaces = surfaces
            self.active = active
        }

        init(json: [String: JSONValue]) throws {
            guard case .int(1)? = json["schemaVersion"],
                  case .object(let surfaces)? = json["surfaces"],
                  case .object(let active)? = json["active"] else {
                throw ProviderRoutingError.underlying("pending provider selection is malformed")
            }
            func optionalHash(_ value: JSONValue?) throws -> String? {
                switch value ?? .null {
                case .null:
                    return nil
                case .string(let hash) where hash.count == 64:
                    return hash
                default:
                    throw ProviderRoutingError.underlying("pending provider selection hash is malformed")
                }
            }
            self.surfacesBaseHash = try optionalHash(json["surfacesBaseHash"])
            self.activeBaseHash = try optionalHash(json["activeBaseHash"])
            self.surfaces = surfaces
            self.active = active
            _ = try SwiftNativeProviderRouting.loadActiveProviderObjectChecked(active)
        }
    }

    private nonisolated static func loadActiveProviderObjectChecked(
        _ raw: [String: JSONValue]
    ) throws -> [String: String] {
        var active: [String: String] = [:]
        active.reserveCapacity(raw.count)
        for (surface, value) in raw {
            guard case .string(let providerId) = value,
                  !providerId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw ProviderRoutingError.underlying(
                    "saved active-provider entry for \(surface) must be a non-empty string"
                )
            }
            active[surface] = providerId
        }
        return active
    }

    private nonisolated static func fileSHA256(_ path: URL) throws -> String? {
        guard FileManager.default.fileExists(atPath: path.path) else { return nil }
        let data: Data
        do {
            data = try Data(contentsOf: path)
        } catch {
            throw ProviderRoutingError.underlying("provider selection bytes are unreadable")
        }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private nonisolated static func updatedSurfaceRoot(
        _ root: [String: JSONValue],
        surface: String,
        model: String?,
        reasoningEffort: String?,
        serviceTier: String?,
        seedMissingControls: Bool,
        overwriteExisting: Bool
    ) -> [String: JSONValue] {
        let root = canonicalizeRootForWrite(root, surface: surface)
        if !overwriteExisting, root[surface] != nil { return root }
        var updated = root
        var entry: [String: JSONValue] = [:]
        if case .object(let existing)? = updated[surface] { entry = existing }
        if let model { entry["model"] = .string(model) }
        if let reasoningEffort {
            entry["reasoningEffort"] = .string(reasoningEffort)
        } else if seedMissingControls, entry["reasoningEffort"] == nil {
            entry["reasoningEffort"] = .string("medium")
        }
        if let serviceTier {
            entry["serviceTier"] = .string(normalizeServiceTierStatic(serviceTier))
        } else if seedMissingControls, entry["serviceTier"] == nil {
            entry["serviceTier"] = .string("default")
        }
        updated[surface] = .object(entry)
        return updated
    }

    private nonisolated static func updatedActiveRoot(
        _ root: [String: JSONValue],
        surface: String,
        providerId: String,
        overwriteExisting: Bool
    ) -> [String: JSONValue] {
        let root = canonicalizeRootForWrite(root, surface: surface)
        if !overwriteExisting, root[surface] != nil { return root }
        var updated = root
        updated[surface] = .string(providerId)
        return updated
    }

    /// P2-3 write-side migration, applied ONLY to the surface actually being
    /// mutated. Rewriting a picker file wholesale would be a flag day; folding
    /// just the key we are about to overwrite means the legacy `missions` entry
    /// is retired exactly when its replacement is written, so the file can
    /// never end up carrying two entries that disagree about the same surface.
    /// Untouched surfaces keep their bytes.
    private nonisolated static func canonicalizeRootForWrite(
        _ root: [String: JSONValue],
        surface: String
    ) -> [String: JSONValue] {
        guard surface == WorkshopSurfaceVocabulary.canonical,
              let legacyEntry = root[WorkshopSurfaceVocabulary.legacy] else { return root }
        var updated = root
        updated.removeValue(forKey: WorkshopSurfaceVocabulary.legacy)
        if updated[surface] == nil { updated[surface] = legacyEntry }
        return updated
    }

    /// Finish an interrupted two-file picker commit before any later read or
    /// mutation observes the surface/model tuple. The durable intent is valid
    /// only while each live projection is either its recorded base bytes or
    /// the exact intended object; unrelated concurrent bytes fail closed and
    /// leave the marker available for explicit recovery instead of being
    /// silently overwritten.
    private func reconcilePendingSurfaceConfigurationLocked() async throws {
        guard FileManager.default.fileExists(atPath: surfaceTransactionPath.path) else { return }
        let raw = try Self.loadProviderStateObjectChecked(
            at: surfaceTransactionPath,
            description: "pending provider selection"
        )
        let pending = try PendingSurfaceConfiguration(json: raw)

        let currentSurfaces = try Self.loadProviderStateObjectChecked(
            at: surfacesPath,
            description: "surface preference"
        )
        let currentActiveObject = try Self.loadProviderStateObjectChecked(
            at: activeProviderPath,
            description: "active-provider"
        )
        _ = try Self.loadActiveProviderObjectChecked(currentActiveObject)

        let surfacesRecoverable = try currentSurfaces == pending.surfaces
            || Self.fileSHA256(surfacesPath) == pending.surfacesBaseHash
        let activeRecoverable = try currentActiveObject == pending.active
            || Self.fileSHA256(activeProviderPath) == pending.activeBaseHash
        guard surfacesRecoverable, activeRecoverable else {
            throw ProviderRoutingError.underlying(
                "pending provider selection conflicts with newer provider state"
            )
        }

        if currentSurfaces != pending.surfaces {
            try await persistence.withFileLock(surfacesPath) {
                try await self.persistence.writeJSON(.object(pending.surfaces), to: self.surfacesPath)
            }
        }
        if currentActiveObject != pending.active {
            try await persistence.withFileLock(activeProviderPath) {
                try await self.persistence.writeJSON(.object(pending.active), to: self.activeProviderPath)
            }
        }

        let verifiedSurfaces = try Self.loadProviderStateObjectChecked(
            at: surfacesPath,
            description: "surface preference"
        )
        let verifiedActive = try Self.loadProviderStateObjectChecked(
            at: activeProviderPath,
            description: "active-provider"
        )
        _ = try Self.loadActiveProviderObjectChecked(verifiedActive)
        guard verifiedSurfaces == pending.surfaces, verifiedActive == pending.active else {
            throw ProviderRoutingError.underlying("pending provider selection did not converge")
        }
        do {
            try FileManager.default.removeItem(at: surfaceTransactionPath)
        } catch {
            throw ProviderRoutingError.underlying("clear pending provider selection failed")
        }
    }

    private func reconciledPickerState() async throws -> (
        surfaces: [String: JSONValue],
        active: [String: String]
    ) {
        try await persistence.withFileLock(surfaceTransactionPath) {
            try await self.reconcilePendingSurfaceConfigurationLocked()
            let surfaces = try Self.loadProviderStateObjectChecked(
                at: self.surfacesPath,
                description: "surface preference"
            )
            let active = try Self.loadActiveProviderStateChecked(at: self.activeProviderPath)
            // P2-3 read seam. Both picker files are keyed by surface, and a
            // 0.3.x install has `missions` keys in them. Fold here — the ONE
            // place either file becomes in-memory state — so the snapshot,
            // preferences, and pins all speak the canonical vocabulary. The
            // files themselves are left untouched; only a later WRITE migrates
            // them (see `updatedSurfaceRoot` / `updatedActiveRoot`).
            return (
                WorkshopSurfaceVocabulary.canonicalizeSurfaceKeys(surfaces),
                WorkshopSurfaceVocabulary.canonicalizeSurfaceKeys(active)
            )
        }
    }

    // MARK: Provider management

    public func listProviders() async throws -> [Provider] {
        let openRouterModels = await OpenRouterModelCatalog.providerJSONModels(dataRoot: dataRoot)
        let moonshotModels = await MoonshotModelCatalog.providerJSONModels(dataRoot: dataRoot)
        return nativeListProviders(openRouterModels: openRouterModels, moonshotModels: moonshotModels)
    }

    public func getProvider(id: String) async throws -> Provider {
        guard let provider = try await listProviders().first(where: { $0.id == id }) else {
            throw ProviderRoutingError.providerNotFound
        }
        return provider
    }

    public func configureProvider(id: String, config: JSONValue) async throws -> Provider {
        guard case .object(let body) = config else {
            throw ProviderRoutingError.invalidRequest
        }
        let path = providersDir.appendingPathComponent("\(id).json")
        try FileManager.default.createDirectory(at: providersDir, withIntermediateDirectories: true)
        try await persistence.withFileLock(path) {
            var entry = try Self.loadProviderStateObjectChecked(
                at: path,
                description: "provider \(id) configuration"
            )
            if let mode = Self.firstString(body, keys: ["auth_mode", "authMode"]) {
                entry["auth_mode"] = .string(mode)
            }
            if let apiKey = Self.firstString(body, keys: ["api_key", "apiKey", "key"]) {
                entry["api_key"] = .string(apiKey)
            }
            if let accessToken = Self.firstString(body, keys: ["access_token", "accessToken"]) {
                entry["access_token"] = .string(accessToken)
            }
            if let model = Self.firstString(body, keys: ["default_model", "defaultModel", "model"]) {
                entry["default_model"] = .string(model)
            }
            if entry["auth_mode"] == nil {
                entry["auth_mode"] = .string(id.contains("oauth") ? "oauth" : "api_key")
            }
            try await persistence.writeJSON(.object(entry), to: path)
        }
        // Freshen the authenticated model catalog for providers whose live
        // `/models` list needs credentials. Both refresh paths are non-fatal
        // (models() swallows failures) and keep the on-disk cache — and its
        // TTL stamp — current after a credential change.
        switch id.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "moonshot":
            _ = await MoonshotModelCatalog.models(dataRoot: dataRoot, refresh: true)
        case "openrouter":
            _ = await OpenRouterModelCatalog.models(dataRoot: dataRoot, refresh: true)
        default:
            break
        }
        return try await getProvider(id: id)
    }

    public func testProvider(id: String) async throws -> ProviderTestResult {
        let provider = try await getProvider(id: id)
        let ready = provider.configured == true
        let status = ready ? "ok" : "needs_credentials"
        let detail: String = {
            if case .object(let obj)? = provider.oauthStatus,
               case .string(let d)? = obj["detail"] {
                return d
            }
            // Honest label: this surface checks credential PRESENCE only —
            // no network probe is issued (tested:false below is accurate,
            // but the old "Credentials available" read as a passed test in
            // the UI; audit 2026-06-09, silent-stub class). A real probe is
            // ledgered as an upgrade.
            return ready
                ? "Credentials present (connectivity not tested)"
                : "No usable credentials found"
        }()
        return ProviderTestResult(rawResponse: .object([
            "provider_id": .string(id),
            "status": .string(status),
            "tested": .bool(false),
            "detail": .string(detail),
        ]))
    }

    public func getModelPreferences() async throws -> ModelPreferences {
        return try await modelPreferencesFromComputed()
    }

    public func saveModelConfig(_ body: JSONValue) async throws -> ModelPreferences {
        guard case .object(let obj) = body,
              let rawSurface = Self.firstString(obj, keys: ["surface"]) else {
            throw ProviderRoutingError.invalidRequest
        }
        // P2-3: accept the 0.3.x `missions` spelling from any caller (iOS one
        // version behind, a saved shortcut, an old script) and route it to the
        // canonical surface rather than rejecting it as unknown.
        let surface = canonicalRoutingSurface(rawSurface)
        guard MODEL_SURFACES.contains(surface) else {
            throw ProviderRoutingError.invalidRequest
        }
        let model = Self.firstString(obj, keys: ["model"])
        let effort = Self.firstString(obj, keys: ["reasoningEffort", "reasoning_effort"])
        let serviceTier = Self.firstString(obj, keys: ["serviceTier", "service_tier"])
        let inferredProvider: String? = {
            guard case .bool(let infer)? = obj["inferProvider"], infer, let model else { return nil }
            return inferProviderForModel(model)
        }()
        try await saveSurfaceConfiguration(
            surface: surface,
            model: model,
            reasoningEffort: effort,
            serviceTier: serviceTier,
            providerId: inferredProvider
        )
        return try await modelPreferencesFromComputed()
    }

    /// One canonical logical mutation boundary for a model surface and its
    /// optional provider pin. A durable intent marker protects the two-file
    /// update so restart reconciliation completes the exact tuple or fails
    /// closed if unrelated bytes appeared. Once the marker exists, task
    /// cancellation cannot turn a committed intent into a half-update.
    public func saveSurfaceConfiguration(
        surface: String,
        model: String?,
        reasoningEffort: String?,
        serviceTier: String?,
        providerId: String?,
        seedMissingControls: Bool = false,
        overwriteExisting: Bool = true
    ) async throws {
        let surface = canonicalRoutingSurface(surface)
        guard MODEL_SURFACES.contains(surface) else { throw ProviderRoutingError.invalidRequest }
        if let providerId {
            guard !providerId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw ProviderRoutingError.invalidRequest
            }
        }
        try FileManager.default.createDirectory(
            at: surfaceTransactionPath.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let transactionPath = surfaceTransactionPath
        try await persistence.withFileLock(transactionPath) {
            try await self.reconcilePendingSurfaceConfigurationLocked()
            let surfaceRoot = try Self.loadProviderStateObjectChecked(
                at: self.surfacesPath,
                description: "surface preference"
            )
            let activeRoot = try Self.loadProviderStateObjectChecked(
                at: self.activeProviderPath,
                description: "active-provider"
            )
            _ = try Self.loadActiveProviderObjectChecked(activeRoot)

            let intendedSurfaces = Self.updatedSurfaceRoot(
                surfaceRoot,
                surface: surface,
                model: model,
                reasoningEffort: reasoningEffort,
                serviceTier: serviceTier,
                seedMissingControls: seedMissingControls,
                overwriteExisting: overwriteExisting
            )

            guard let providerId else {
                guard intendedSurfaces != surfaceRoot else { return }
                try Task.checkCancellation()
                try await self.persistence.withFileLock(self.surfacesPath) {
                    try await self.persistence.writeJSON(.object(intendedSurfaces), to: self.surfacesPath)
                }
                return
            }

            let intendedActive = Self.updatedActiveRoot(
                activeRoot,
                surface: surface,
                providerId: providerId,
                overwriteExisting: overwriteExisting
            )
            guard intendedSurfaces != surfaceRoot || intendedActive != activeRoot else { return }

            // Cancellation is honored before durable intent publication. From
            // this point onward the operation owns recovery and must either
            // converge now or be completed on the next checked read/mutation.
            try Task.checkCancellation()
            let pending = PendingSurfaceConfiguration(
                surfacesBaseHash: try Self.fileSHA256(self.surfacesPath),
                activeBaseHash: try Self.fileSHA256(self.activeProviderPath),
                surfaces: intendedSurfaces,
                active: intendedActive
            )
            try await self.persistence.writeJSON(pending.json, to: transactionPath)
            try self.surfaceCommitFailureInjector?(.manifestPrepared)

            try await self.persistence.withFileLock(self.surfacesPath) {
                try await self.persistence.writeJSON(.object(intendedSurfaces), to: self.surfacesPath)
            }
            try self.surfaceCommitFailureInjector?(.surfacesCommitted)

            try await self.persistence.withFileLock(self.activeProviderPath) {
                try await self.persistence.writeJSON(.object(intendedActive), to: self.activeProviderPath)
            }
            try self.surfaceCommitFailureInjector?(.activeProviderCommitted)

            let verifiedSurfaces = try Self.loadProviderStateObjectChecked(
                at: self.surfacesPath,
                description: "surface preference"
            )
            let verifiedActive = try Self.loadProviderStateObjectChecked(
                at: self.activeProviderPath,
                description: "active-provider"
            )
            _ = try Self.loadActiveProviderObjectChecked(verifiedActive)
            guard verifiedSurfaces == intendedSurfaces, verifiedActive == intendedActive else {
                throw ProviderRoutingError.underlying("provider selection did not converge")
            }
            do {
                try FileManager.default.removeItem(at: transactionPath)
            } catch {
                throw ProviderRoutingError.underlying("clear pending provider selection failed")
            }
        }
    }

    /// Canonical raw-pin mutation. `seedMissingControls` exists only for the
    /// established Mac picker contract; all persistence and corruption
    /// handling still remain owned here.
    public func saveSurfacePreference(
        surface: String,
        model: String?,
        reasoningEffort: String?,
        serviceTier: String?,
        seedMissingControls: Bool = false,
        overwriteExisting: Bool = true
    ) async throws {
        let surface = canonicalRoutingSurface(surface)
        guard MODEL_SURFACES.contains(surface) else { throw ProviderRoutingError.invalidRequest }
        try FileManager.default.createDirectory(
            at: surfaceTransactionPath.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try await persistence.withFileLock(surfaceTransactionPath) {
            try await self.reconcilePendingSurfaceConfigurationLocked()
            let root = try Self.loadProviderStateObjectChecked(
                at: self.surfacesPath,
                description: "surface preference"
            )
            _ = try Self.loadActiveProviderStateChecked(at: self.activeProviderPath)
            let updated = Self.updatedSurfaceRoot(
                root,
                surface: surface,
                model: model,
                reasoningEffort: reasoningEffort,
                serviceTier: serviceTier,
                seedMissingControls: seedMissingControls,
                overwriteExisting: overwriteExisting
            )
            guard updated != root else { return }
            try Task.checkCancellation()
            try await self.persistence.withFileLock(self.surfacesPath) {
                try await self.persistence.writeJSON(.object(updated), to: self.surfacesPath)
            }
        }
    }

    public func setActiveProvider(surface: String, providerId: String) async throws {
        let surface = canonicalRoutingSurface(surface)
        guard MODEL_SURFACES.contains(surface),
              !providerId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ProviderRoutingError.invalidRequest
        }
        try await writeActiveProvider(surface: surface, providerId: providerId)
    }

    private var providersDir: URL {
        dataRoot.appendingPathComponent("providers", isDirectory: true)
    }

    private func nativeListProviders(
        openRouterModels: [[String: JSONValue]] = [],
        moonshotModels: [[String: JSONValue]] = []
    ) -> [Provider] {
        var byId: [String: Provider] = [:]

        let registryPath = providersDir.appendingPathComponent("registry.json")
        if let data = try? Data(contentsOf: registryPath),
           let existing = try? JSONDecoder().decode([Provider].self, from: data) {
            for provider in existing {
                byId[provider.id] = provider
            }
        }

        let skipNames: Set<String> = [
            "registry.json", "models.json", "active.json", "surfaces.json",
            "pending-surface-configuration.json",
            "openrouter-models-cache.json", "moonshot-models-cache.json",
        ]
        if let files = try? FileManager.default.contentsOfDirectory(
            at: providersDir,
            includingPropertiesForKeys: nil
        ) {
            for file in files where file.pathExtension == "json"
                && !skipNames.contains(file.lastPathComponent)
                && !file.lastPathComponent.hasSuffix(".lock") {
                let id = file.deletingPathExtension().lastPathComponent
                if byId[id] == nil {
                    byId[id] = synthesizeProvider(
                        id: id,
                        openRouterModels: openRouterModels,
                        moonshotModels: moonshotModels
                    )
                }
            }
        }

        if byId["openai_oauth_direct"] == nil {
            byId["openai_oauth_direct"] = synthesizeProvider(id: "openai_oauth_direct", openRouterModels: openRouterModels)
        }
        if byId["codex"] == nil {
            byId["codex"] = synthesizeProvider(id: "codex", openRouterModels: openRouterModels)
        }
        if byId["openrouter"] == nil {
            byId["openrouter"] = synthesizeProvider(id: "openrouter", openRouterModels: openRouterModels)
        }
        if byId["anthropic_oauth_direct"] == nil {
            byId["anthropic_oauth_direct"] = synthesizeProvider(id: "anthropic_oauth_direct", openRouterModels: openRouterModels)
        }
        if byId["xai_oauth_direct"] == nil {
            byId["xai_oauth_direct"] = synthesizeProvider(id: "xai_oauth_direct", openRouterModels: openRouterModels)
        }
        if byId["openai"] == nil {
            byId["openai"] = synthesizeProvider(id: "openai", openRouterModels: openRouterModels)
        }
        if byId["anthropic"] == nil {
            byId["anthropic"] = synthesizeProvider(id: "anthropic", openRouterModels: openRouterModels)
        }
        if byId["moonshot"] == nil {
            byId["moonshot"] = synthesizeProvider(
                id: "moonshot",
                openRouterModels: openRouterModels,
                moonshotModels: moonshotModels
            )
        }
        // Kimi Code subscription provider — always visible so the UI can
        // configure a key. Static catalog (no live /models refresh).
        if byId["kimi-code"] == nil {
            byId["kimi-code"] = synthesizeProvider(
                id: "kimi-code",
                openRouterModels: openRouterModels
            )
        }
        if !openRouterModels.isEmpty, let provider = byId["openrouter"] {
            byId["openrouter"] = providerReplacingModels(provider, models: openRouterModels)
        }
        if !moonshotModels.isEmpty, let provider = byId["moonshot"] {
            byId["moonshot"] = providerReplacingModels(provider, models: moonshotModels)
        }

        return byId.values.sorted {
            ($0.displayName ?? $0.id).localizedCaseInsensitiveCompare($1.displayName ?? $1.id) == .orderedAscending
        }
    }

    private func synthesizeProvider(
        id: String,
        openRouterModels: [[String: JSONValue]] = [],
        moonshotModels: [[String: JSONValue]] = []
    ) -> Provider {
        let readiness = providerReadiness(id: id)
        return Provider(
            id: id,
            displayName: displayName(for: id),
            kind: id.contains("oauth") || id == "codex" ? "oauth" : "api_key",
            configured: readiness.ready,
            active: readiness.ready,
            surface: nil,
            modelCatalog: .array(modelsForProvider(id, openRouterModels: openRouterModels, moonshotModels: moonshotModels).map { .object($0) }),
            oauthStatus: .object([
                "provider_id": .string(id),
                "state": .string(readiness.ready ? "ready" : readiness.state),
                "detail": .string(readiness.detail),
                "metadata": .object([:]),
            ]),
            lastTestedAt: nil,
            lastError: readiness.ready ? nil : readiness.detail,
            extras: .object([
                "provider_id": .string(id),
                "display_name": .string(displayName(for: id)),
                "auth_modes": .array(authModes(for: id).map { .string($0) }),
                "auth_status": .object([
                    "provider_id": .string(id),
                    "state": .string(readiness.ready ? "ready" : readiness.state),
                    "detail": .string(readiness.detail),
                    "metadata": .object([:]),
                ]),
                "models": .array(modelsForProvider(id, openRouterModels: openRouterModels, moonshotModels: moonshotModels).map { .object($0) }),
            ])
        )
    }

    private nonisolated func providerReplacingModels(
        _ provider: Provider,
        models: [[String: JSONValue]]
    ) -> Provider {
        var updated = provider
        let modelArray: JSONValue = .array(models.map { .object($0) })
        updated.modelCatalog = modelArray
        if case .object(var extras)? = updated.extras {
            extras["models"] = modelArray
            updated.extras = .object(extras)
        } else {
            updated.extras = .object(["models": modelArray])
        }
        return updated
    }

    private func providerReadiness(id: String) -> (ready: Bool, state: String, detail: String) {
        let includeEnvironment = dataRoot.standardizedFileURL
            == PersistenceCore.defaultDataRoot().standardizedFileURL
        switch id {
        case "openai_oauth_direct", "codex":
            let result = Self.validateOpenAIOAuthDirect(dataRoot: dataRoot)
            return (result.0, "needs_oauth", result.1)
        case "anthropic_oauth_direct":
            let result = Self.validateAnthropicOAuthDirect(providersDir: providersDir)
            return (result.0, "needs_oauth", result.1)
        case "xai_oauth_direct", "xai-oauth", "grok-oauth", "x-ai-oauth", "xai-grok-oauth":
            let result = Self.validateXAIOAuthDirect(providersDir: providersDir)
            return (result.0, "needs_oauth", result.1)
        case "openai":
            let ready = LLMCredentialResolver.resolveAPIKey(
                envVar: "OPENAI_API_KEY",
                providerConfigFile: "openai.json",
                dataRoot: dataRoot,
                includeEnvironment: includeEnvironment
            ) != nil
            return (ready, "needs_key", ready ? "API key available" : "No OpenAI API key configured")
        case "anthropic":
            let ready = LLMCredentialResolver.resolveAPIKey(
                envVar: "ANTHROPIC_API_KEY",
                providerConfigFile: "anthropic.json",
                dataRoot: dataRoot,
                includeEnvironment: includeEnvironment
            ) != nil
            return (ready, "needs_key", ready ? "API key available" : "No Anthropic API key configured")
        case "openrouter":
            let ready = LLMCredentialResolver.resolveAPIKey(
                envVar: "OPENROUTER_API_KEY",
                providerConfigFile: "openrouter.json",
                dataRoot: dataRoot,
                includeEnvironment: includeEnvironment
            ) != nil
            return (ready, "needs_key", ready ? "API key available" : "No OpenRouter API key configured")
        case "moonshot":
            let ready = LLMCredentialResolver.resolveAPIKey(
                envVar: "MOONSHOT_API_KEY",
                providerConfigFile: "moonshot.json",
                dataRoot: dataRoot,
                includeEnvironment: includeEnvironment
            ) != nil
            return (ready, "needs_key", ready ? "Moonshot API key available" : "No Moonshot API key configured")
        case "kimi-code":
            let ready = LLMCredentialResolver.resolveAPIKey(
                envVar: "KIMI_CODE_API_KEY",
                providerConfigFile: "kimi-code.json",
                dataRoot: dataRoot,
                includeEnvironment: includeEnvironment
            ) != nil
            return (ready, "needs_key", ready ? "Kimi Code API key available" : "No Kimi Code API key configured")
        default:
            let path = providersDir.appendingPathComponent("\(id).json")
            let ready = (try? Data(contentsOf: path)).map { !$0.isEmpty } ?? false
            return (ready, ready ? "ready" : "needs_credentials", ready ? "Provider config present" : "No provider config found")
        }
    }

    private nonisolated func displayName(for id: String) -> String {
        switch id {
        case "openai", "openai_oauth_direct": return "ChatGPT / OpenAI"
        case "codex": return "Codex CLI"
        case "anthropic": return "Anthropic (API key)"
        case "anthropic_oauth_direct": return "Anthropic (OAuth / Setup-Token)"
        case "xai_oauth_direct", "xai-oauth", "grok-oauth", "x-ai-oauth", "xai-grok-oauth":
            return "xAI Grok (OAuth)"
        case "openrouter": return "OpenRouter"
        case "moonshot": return "Moonshot AI (Kimi)"
        case "kimi-code": return "Kimi Code"
        default: return id.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }

    private nonisolated func authModes(for id: String) -> [String] {
        if id.contains("oauth") || id == "codex" { return ["oauth"] }
        if ["openai", "anthropic", "openrouter", "moonshot", "kimi-code"].contains(id) { return ["api_key"] }
        return ["api_key", "oauth"]
    }

    private nonisolated func modelsForProvider(
        _ id: String,
        openRouterModels: [[String: JSONValue]] = [],
        moonshotModels: [[String: JSONValue]] = []
    ) -> [[String: JSONValue]] {
        let openai = FirstPartyModelCatalog.publicOpenAIModels.map { $0.providerJSON() }
        let accountOpenAI = FirstPartyModelCatalog.chatGPTAccountFallbackModels.map { $0.providerJSON() }
        let anthropic = FirstPartyModelCatalog.anthropicModels.map { $0.providerJSON() }
        let openrouter: [[String: JSONValue]] = openRouterModels.isEmpty
            ? OpenRouterModelCatalog.fallbackModels().map { $0.providerJSON() }
            : openRouterModels
        let xai = FirstPartyModelCatalog.xAIModels.map { $0.providerJSON() }
        let moonshot = moonshotModels.isEmpty
            ? MoonshotModelCatalog.fallbackModels().map { model -> [String: JSONValue] in
                var object = model.providerJSON()
                object["default_reasoning_effort"] = .string(MoonshotModelCatalog.defaultReasoningEffort(for: model.id))
                object["supported_reasoning_efforts"] = .array(MoonshotModelCatalog.supportedReasoningEfforts(for: model.id).map(JSONValue.string))
                object["supports_fast"] = .bool(false)
                return object
            }
            : moonshotModels
        switch id {
        case "openai": return openai
        case "openai_oauth_direct", "codex": return accountOpenAI
        case "anthropic", "anthropic_oauth_direct", "anthropic_mcp": return anthropic
        case "xai", "xai_oauth_direct", "xai-oauth", "grok-oauth", "x-ai-oauth", "xai-grok-oauth":
            return xai
        case "openrouter": return openrouter
        case "moonshot": return moonshot
        case "kimi-code": return FirstPartyModelCatalog.kimiCodeModels.map { $0.providerJSON() }
        default: return openai + anthropic + xai + openrouter + moonshot
        }
    }

    private func modelPreferencesFromComputed() async throws -> ModelPreferences {
        let prefs = try await computeModelPreferences()
        var current: [String: JSONValue] = [:]
        for surface in MODEL_SURFACES {
            if let p = prefs[surface] {
                current[surface] = .object([
                    "surface": .string(surface),
                    "model": .string(p.model),
                    "reasoningEffort": .string(p.reasoningEffort),
                    "reasoning_effort": .string(p.reasoningEffort),
                    "serviceTier": .string(p.serviceTier),
                    "service_tier": .string(p.serviceTier),
                ])
            }
        }
        return ModelPreferences(
            surfaceModels: .object(current),
            defaultModel: prefs["chat"]?.model,
            fallbackChain: ["openai_oauth_direct", "anthropic_oauth_direct", "xai_oauth_direct", "moonshot", "codex", "openrouter", "local"],
            extras: .object([
                "current": .object(current),
                "status": .string("ok"),
            ])
        )
    }

    private func writeActiveProvider(
        surface: String,
        providerId: String,
        overwriteExisting: Bool = true
    ) async throws {
        try FileManager.default.createDirectory(
            at: surfaceTransactionPath.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try await persistence.withFileLock(surfaceTransactionPath) {
            try await self.reconcilePendingSurfaceConfigurationLocked()
            _ = try Self.loadProviderStateObjectChecked(
                at: self.surfacesPath,
                description: "surface preference"
            )
            let root = try Self.loadProviderStateObjectChecked(
                at: self.activeProviderPath,
                description: "active-provider"
            )
            _ = try Self.loadActiveProviderObjectChecked(root)
            let updated = Self.updatedActiveRoot(
                root,
                surface: surface,
                providerId: providerId,
                overwriteExisting: overwriteExisting
            )
            guard updated != root else { return }
            try Task.checkCancellation()
            try await self.persistence.withFileLock(self.activeProviderPath) {
                try await self.persistence.writeJSON(.object(updated), to: self.activeProviderPath)
            }
        }
    }

    // MARK: Phase B — Swift-native picker

    /// Read Swift-native provider picker state and seed every MODEL_SURFACE.
    /// Surface models/efforts come from `providers/surfaces.json`; active
    /// provider hints come from `providers/active.json`.
    public func computeModelPreferences() async throws -> [String: SurfacePreference] {
        try await checkedRoutingSnapshot().preferences
    }

    /// Preferences, active-provider hints, and explicit pins derived from one
    /// recovered tuple while the common transaction lock is held by
    /// `reconciledPickerState()`. No caller can observe a model from one picker
    /// commit paired with the provider from another.
    public func checkedRoutingSnapshot() async throws -> ProviderRoutingSnapshot {
        let pickerState = try await reconciledPickerState()
        return routingSnapshot(
            surfaces: pickerState.surfaces,
            activeProviders: pickerState.active,
            soleConnectedProvider: soleConnectedProviderFamily()
        )
    }

    /// A3.6: the sole connected provider FAMILY, or nil when zero or ≥2
    /// distinct families have usable credentials. Used to adapt unpinned
    /// surface seeds so a fresh install that connected exactly one provider
    /// doesn't route its first turn at a provider the stranger never connected.
    ///
    /// DELIBERATELY presence-based, not liveness-probed (Wave-1 review
    /// accepted-with-rationale): readiness here is credential-shape presence;
    /// a live probe has no place in a routing-snapshot read. If the one
    /// present credential is INVALID, adaptation still improves the failure —
    /// the first turn surfaces `.authRejected` naming the provider the user
    /// actually connected, instead of "not configured" for one they never
    /// touched. Bad-key detection belongs to the turn path, not the seed.
    /// `PRIMARY_MODEL` is a GPT id (`gpt-5.6-sol`), so without this an
    /// Anthropic-only install would default chat to OpenAI and fail the first
    /// turn with "not configured: openai".
    func soleConnectedProviderFamily() -> String? {
        let probes = [
            "anthropic", "anthropic_oauth_direct",
            "openai", "openai_oauth_direct", "codex",
            "xai_oauth_direct", "moonshot", "openrouter",
        ]
        var families: Set<String> = []
        for id in probes where providerReadiness(id: id).ready {
            // Codex is the CLI transport for OpenAI models — group it with
            // the openai family so a codex-only install seeds to GPT.
            let family = id == "codex" ? "openai" : Self.normalizeProviderId(id)
            families.insert(family)
        }
        return families.count == 1 ? families.first : nil
    }

    private func routingSnapshot(
        surfaces: [String: JSONValue],
        activeProviders: [String: String],
        soleConnectedProvider: String? = nil
    ) -> ProviderRoutingSnapshot {
        let surfacesFile = JSONValue.object(surfaces)
        let (surfaceModels, surfaceEfforts) = Self.parseSurfacesFile(surfacesFile)
        let surfaceServiceTiers = Self.parseSurfaceServiceTiers(surfacesFile)

        let chatModelRaw = Self.stringFrom(surfaceModels, key: "chat") ?? PRIMARY_MODEL
        let chatModel = Self.normalizeModelIdStatic(chatModelRaw, fallback: PRIMARY_MODEL)
        let chatEffortRaw = Self.stringFrom(surfaceEfforts, key: "chat") ?? DEFAULT_REASONING_EFFORT
        let chatEffort = Self.normalizeReasoningEffortStatic(
            chatEffortRaw,
            fallback: DEFAULT_REASONING_EFFORT,
            model: chatModel,
            providerID: activeProviders["chat"]
        )
        let chatServiceTier = Self.normalizeServiceTierStatic(
            Self.stringFrom(surfaceServiceTiers, key: "chat") ?? "default"
        )
        let telegramModelRaw = Self.stringFrom(surfaceModels, key: "telegram") ?? chatModel
        let telegramModel = Self.normalizeModelIdStatic(telegramModelRaw, fallback: chatModel)
        let telegramEffortRaw = Self.stringFrom(surfaceEfforts, key: "telegram") ?? chatEffort
        let telegramEffort = Self.normalizeReasoningEffortStatic(
            telegramEffortRaw,
            fallback: chatEffort,
            model: telegramModel,
            providerID: activeProviders["telegram"]
        )

        let seedModel: [String: String] = [
            "chat": chatModel,
            "ios": chatModel,
            "telegram": telegramModel,
            "workshop": PRIMARY_MODEL,
            "autonomy": PRIMARY_MODEL,
            "swarms": PRIMARY_MODEL,
            "dream": "gpt-5.4-mini",
            "rem": "gpt-5.4-mini",
            "training": "gpt-5.4",
            "cognition_reflection": "claude-opus-4-8",
        ]
        let seedEffort: [String: String] = [
            "chat": chatEffort,
            "ios": chatEffort,
            "telegram": telegramEffort,
            "cognition_reflection": "high",
        ]

        var out: [String: SurfacePreference] = [:]
        for surface in MODEL_SURFACES {
            let base = seedModel[surface] ?? chatModel
            let pickedModelRaw = Self.stringFrom(surfaceModels, key: surface) ?? base
            let model = Self.normalizeModelIdStatic(pickedModelRaw, fallback: base)
            // A3.6: for an UNPINNED surface with no explicit active-provider
            // hint, fall back to the sole connected provider (nil unless EXACTLY
            // one family is connected) so a seed pointing at an unconnected
            // provider adapts to the one the stranger actually connected. An
            // explicit model pick (surfaceModels) and an explicit active hint
            // both still win; zero / multiple connected providers leave the
            // seeds exactly as before.
            let hasExplicitPick = Self.stringFrom(surfaceModels, key: surface) != nil
            let effectiveActiveProvider = activeProviders[surface]
                ?? (hasExplicitPick ? nil : soleConnectedProvider)
            let effectiveModel = providerCompatibleModel(
                model,
                activeProvider: effectiveActiveProvider
            )
            let effBase = seedEffort[surface] ?? chatEffort
            let pickedEffortRaw = Self.stringFrom(surfaceEfforts, key: surface) ?? effBase
            let effort = Self.normalizeReasoningEffortStatic(
                pickedEffortRaw,
                fallback: effBase,
                model: effectiveModel,
                providerID: activeProviders[surface]
            )
            let serviceTier = Self.normalizeServiceTierStatic(
                Self.stringFrom(surfaceServiceTiers, key: surface) ?? chatServiceTier
            )
            out[surface] = SurfacePreference(
                surface: surface,
                model: effectiveModel,
                reasoningEffort: effort,
                serviceTier: serviceTier,
                modelKnown: nil
            )
        }
        var pinnedModels: [String: String] = [:]
        if case .object(let models) = surfaceModels {
            for (surface, value) in models {
                guard case .string(let model) = value, !model.isEmpty else { continue }
                pinnedModels[surface] = model
            }
        }
        return ProviderRoutingSnapshot(
            preferences: out,
            activeProviders: activeProviders,
            pinnedModels: pinnedModels
        )
    }

    /// Lookup a single surface. Throws `.invalidRequest` if the surface
    /// is not a known MODEL_SURFACE — mirrors the daemon's contract.
    public func modelForSurface(_ surface: String) async throws -> SurfacePreference {
        let surface = canonicalRoutingSurface(surface)
        guard MODEL_SURFACES.contains(surface) else {
            throw ProviderRoutingError.invalidRequest
        }
        let prefs = try await computeModelPreferences()
        // computeModelPreferences seeds every MODEL_SURFACE, so this is total.
        return prefs[surface]!
    }

    /// Mirrors Python `normalize_model_id`: trim, reject empty, reject any
    /// character outside `[A-Za-z0-9._:/+-]`, length 1..100. Returns
    /// `fallback` on rejection. Does NOT lowercase — Python doesn't either.
    public nonisolated func normalizeModelId(_ raw: String, fallback: String = "") -> String {
        Self.normalizeModelIdStatic(raw, fallback: fallback)
    }

    /// Mirrors Python `normalize_reasoning_effort`: lowercase + trim, then
    /// accept only one of REASONING_EFFORT_OPTIONS. Anything else (including
    /// "") returns `fallback`. Note Python's behavior: empty string → fallback,
    /// invalid string → fallback — identical paths.
    public nonisolated func normalizeReasoningEffort(_ raw: String, fallback: String = "medium") -> String {
        Self.normalizeReasoningEffortStatic(raw, fallback: fallback)
    }

    /// SWIFT-NATIVE PHASE B CORRECTION of `_provider_hint_for_model_id`:
    /// the daemon's Python helper folds OpenRouter's `anthropic/claude-...`
    /// into `anthropic_oauth_direct` and only avoids the mis-routing via the
    /// `inferProvider=false` body flag on the picker save. The Swift path
    /// reads the namespace literally:
    ///   - `anthropic/...`  -> openrouter   (OpenRouter namespace)
    ///   - `openai/...`     -> openrouter
    ///   - bare `claude-...` / `sonnet/`+`opus/`+`haiku/` -> anthropic_oauth_direct
    ///   - bare `gpt-...`   -> openai_oauth_direct
    ///   - bare `grok-...`  -> xai_oauth_direct
    ///   - everything else  -> nil
    /// Returning nil (rather than "") lets the caller decide whether to fall
    /// through to the persisted active provider.
    public nonisolated func inferProviderForModel(_ modelId: String) -> String? {
        Self.inferredProviderID(forModel: modelId)
    }

    public nonisolated static func inferredProviderID(forModel modelId: String) -> String? {
        let lower = modelId.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if lower.isEmpty { return nil }
        // Slash-namespaced id => an OpenRouter / aggregator model id.
        if lower.hasPrefix("anthropic/") || lower.hasPrefix("openai/") {
            return "openrouter"
        }
        if lower.hasPrefix("claude-")
            || lower.hasPrefix("sonnet/") || lower.hasPrefix("opus/") || lower.hasPrefix("haiku/") {
            return "anthropic_oauth_direct"
        }
        if lower.hasPrefix("gpt-") {
            return "openai_oauth_direct"
        }
        if lower.hasPrefix("grok-") {
            return "xai_oauth_direct"
        }
        // Kimi Code SUBSCRIPTION ids (kimi-for-coding[-highspeed], bare k3)
        // resolve to "kimi-code" ahead of the moonshot prefix branch below.
        if FirstPartyModelCatalog.kimiCodeModelIDSet.contains(lower) {
            return "kimi-code"
        }
        if lower.hasPrefix("kimi-") || lower.hasPrefix("moonshot-") {
            return "moonshot"
        }
        return nil
    }

    private nonisolated func providerCompatibleModel(
        _ model: String,
        activeProvider: String?
    ) -> String {
        guard let activeProvider,
              let inferredProvider = inferProviderForModel(model),
              !Self.providerCanServeModel(activeProvider, inferredProvider: inferredProvider) else {
            return model
        }
        return defaultModelForProvider(activeProvider) ?? model
    }

    private nonisolated func defaultModelForProvider(_ providerId: String) -> String? {
        for model in modelsForProvider(providerId) {
            if case .string(let id)? = model["id"],
               !id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return id
            }
        }
        switch Self.normalizeProviderId(providerId) {
        case "anthropic": return "claude-opus-4-8"
        case "openai", "codex": return PRIMARY_MODEL
        case "xai": return XAIOAuthDirectAdapter.defaultModel
        case "moonshot": return MoonshotAdapter.defaultModel
        // Verified live on OpenRouter 2026-08-07; the previous default
        // `anthropic/claude-3.5-sonnet` was delisted, which made an unpinned
        // OpenRouter selection default to a 404 model.
        case "openrouter": return "anthropic/claude-sonnet-5"
        default: return nil
        }
    }

    /// Bare GPT ids are shared by direct OpenAI transports and the Codex CLI.
    /// Compatibility must not normalize Codex into OpenAI because adapter
    /// selection still needs to preserve the user's exact auth route.
    private nonisolated static func providerCanServeModel(
        _ activeProvider: String,
        inferredProvider: String
    ) -> Bool {
        let active = normalizeProviderId(activeProvider)
        let inferred = normalizeProviderId(inferredProvider)
        return active == inferred || (active == "codex" && inferred == "openai")
    }

    private nonisolated static func normalizeProviderId(_ raw: String) -> String {
        switch raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "anthropic", "anthropic_oauth_direct", "anthropic_mcp":
            return "anthropic"
        case "openai", "openai_oauth_direct":
            return "openai"
        case "xai", "xai_oauth_direct", "xai-oauth", "grok-oauth", "x-ai-oauth", "xai-grok-oauth":
            return "xai"
        case "moonshot", "kimi":
            return "moonshot"
        case "openrouter":
            return "openrouter"
        case "codex":
            return "codex"
        default:
            return raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        }
    }

    /// Read `<dataRoot>/providers/active.json`, returning the surface→providerId
    /// map. Missing is empty; the throwing preference path rejects corruption.
    /// This nonthrowing compatibility view stays conservative on corruption.
    /// Surfaces the value the user's picker writes
    /// via `setActiveProvider(surface:providerId:)` so the dispatch layer can
    /// honor it as a tiebreaker when a model id is ambiguous.
    public func activeProvidersForSurfaces() async -> [String: String] {
        (try? await activeProvidersForSurfacesChecked()) ?? [:]
    }

    public func readActiveProvidersChecked() async throws -> [String: String] {
        try await activeProvidersForSurfacesChecked()
    }

    public func activeProvidersForSurfacesChecked() async throws -> [String: String] {
        try await checkedRoutingSnapshot().activeProviders
    }

    /// Actor override of the protocol default. Reads `providers/surfaces.json`
    /// and returns the explicitly-pinned model for `surface` only when the
    /// key is present (and non-empty). Returns nil for any unpinned surface,
    /// so dream / REM can fall back to the chat-surface picker without
    /// confusing a daemon-era seed for a user pin.
    public func pinnedModelStringForSurface(_ surface: String) async -> String? {
        try? await pinnedModelStringForSurfaceChecked(surface)
    }

    public func pinnedModelStringForSurfaceChecked(_ surface: String) async throws -> String? {
        ProviderRoutingSurfaceLookup.value(try await checkedRoutingSnapshot().pinnedModels, surface)
    }

    /// Parse `providers/surfaces.json` into (surfaceModels, surfaceEfforts)
    /// objects in the shape `Self.objectAt` returns. Tolerates two on-disk
    /// shapes: nested `{"chat": {"model":"...","reasoningEffort":"..."}}` and
    /// flat `{"chat": "gpt-5.5"}` (the latter for the simplest picker writes).
    /// Model values also tolerate JSON scalars so migrated picker data keeps
    /// the old Python `str(value or base)` compatibility.
    nonisolated static func parseSurfacesFile(_ raw: JSONValue) -> (JSONValue, JSONValue) {
        guard case .object(let obj) = raw, !obj.isEmpty else {
            return (.object([:]), .object([:]))
        }
        var models: [String: JSONValue] = [:]
        var efforts: [String: JSONValue] = [:]
        for (surface, entry) in obj {
            switch entry {
            case .string(let s):
                if !s.isEmpty { models[surface] = .string(s) }
            case .object(let inner):
                if let m = Self.stringFrom(.object(inner), key: "model") {
                    models[surface] = .string(m)
                }
                if case .string(let e)? = inner["reasoningEffort"], !e.isEmpty {
                    efforts[surface] = .string(e)
                } else if case .string(let e)? = inner["reasoning_effort"], !e.isEmpty {
                    efforts[surface] = .string(e)
                }
            case .bool(_), .int(_), .double(_):
                if let m = Self.stringFrom(.object([surface: entry]), key: surface) {
                    models[surface] = .string(m)
                }
            default:
                continue
            }
        }
        return (.object(models), .object(efforts))
    }

    nonisolated static func parseSurfaceServiceTiers(_ raw: JSONValue) -> JSONValue {
        guard case .object(let obj) = raw, !obj.isEmpty else {
            return .object([:])
        }
        var tiers: [String: JSONValue] = [:]
        for (surface, entry) in obj {
            guard case .object(let inner) = entry else { continue }
            if case .string(let tier)? = inner["serviceTier"], !tier.isEmpty {
                tiers[surface] = .string(tier)
            } else if case .string(let tier)? = inner["service_tier"], !tier.isEmpty {
                tiers[surface] = .string(tier)
            } else if case .bool(let fast)? = inner["fastMode"] {
                tiers[surface] = .string(fast ? "priority" : "default")
            }
        }
        return .object(tiers)
    }

    // MARK: helpers (nonisolated statics so init + nonisolated methods can call)

    nonisolated static func normalizeModelIdStatic(_ raw: String, fallback: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return fallback }
        if trimmed.count > 100 { return fallback }
        // Python: re.fullmatch(r"[A-Za-z0-9._:/+-]{1,100}", model)
        let allowed: Set<Character> = {
            var s: Set<Character> = []
            for c in "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._:/+-" {
                s.insert(c)
            }
            return s
        }()
        for ch in trimmed {
            if !allowed.contains(ch) { return fallback }
        }
        // GPT-5.5 was NativeAgent's primary fallback before GPT-5.6 shipped.
        // Normalize persisted legacy picks at the shared routing boundary so
        // every surface converges on Sol instead of silently downgrading.
        if trimmed.lowercased() == "gpt-5.5" { return nativeAgentPrimaryModel }
        return trimmed
    }

    nonisolated static func normalizeReasoningEffortStatic(_ raw: String, fallback: String) -> String {
        normalizeReasoningEffortStatic(raw, fallback: fallback, model: nil)
    }

    nonisolated static func normalizeReasoningEffortStatic(
        _ raw: String,
        fallback: String,
        model: String?,
        providerID: String? = nil
    ) -> String {
        let normalized = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard REASONING_EFFORT_OPTIONS.contains(normalized) else { return fallback }
        let lowerModel = model?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        let supported: Set<String>
        switch lowerModel {
        case let model where model.hasPrefix("kimi-") || model.hasPrefix("moonshot-"):
            supported = Set(MoonshotModelCatalog.supportedReasoningEfforts(for: model))
        case "gpt-5.6", "gpt-5.6-sol", "gpt-5.6-terra":
            supported = providerID?.lowercased() == "openai"
                ? Set(FirstPartyModelCatalog.publicGPT56Efforts)
                : Set(FirstPartyModelCatalog.accountGPT56SolTerraEfforts)
        case "gpt-5.6-luna":
            supported = providerID?.lowercased() == "openai"
                ? Set(FirstPartyModelCatalog.publicGPT56Efforts)
                : Set(FirstPartyModelCatalog.accountGPT56LunaEfforts)
        default:
            let bareAnthropic = lowerModel.hasPrefix("anthropic/")
                ? String(lowerModel.dropFirst("anthropic/".count))
                : lowerModel
            if let descriptor = FirstPartyModelCatalog.anthropicDescriptor(for: bareAnthropic) {
                supported = Set(descriptor.supportedReasoningEfforts)
            } else if let descriptor = FirstPartyModelCatalog.xAIDescriptor(for: lowerModel) {
                supported = Set(descriptor.supportedReasoningEfforts)
            } else if lowerModel.hasPrefix("claude-") || lowerModel.hasPrefix("anthropic/claude-") {
                supported = ["low", "medium", "high"]
            } else {
                supported = ["low", "medium", "high", "xhigh"]
            }
        }
        guard supported.contains(normalized) else {
            let cleanFallback = fallback.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if supported.contains(cleanFallback) { return cleanFallback }
            if supported.contains("high") { return "high" }
            for candidate in REASONING_EFFORT_OPTIONS where supported.contains(candidate) {
                return candidate
            }
            return "high"
        }
        return normalized
    }

    nonisolated static func normalizeServiceTierStatic(_ raw: String) -> String {
        switch raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "priority", "fast": return "priority"
        default: return "default"
        }
    }

    /// Return the nested object at `key` from `node`, or empty object.
    nonisolated static func objectAt(_ node: JSONValue, key: String) -> JSONValue {
        if case .object(let obj) = node, let v = obj[key], case .object = v {
            return v
        }
        return .object([:])
    }

    /// Mirrors Python's truthiness rules: `None`, `False`, `0`, `0.0`, `""`,
    /// empty list, empty dict — all falsy. Used to preserve the `value or
    /// base` compatibility for migrated picker data.
    nonisolated static func isPythonFalsy(_ v: JSONValue) -> Bool {
        switch v {
        case .null: return true
        case .bool(let b): return !b
        case .int(let i): return i == 0
        case .double(let d): return d == 0
        case .string(let s): return s.isEmpty
        case .array(let a): return a.isEmpty
        case .object(let o): return o.isEmpty
        }
    }

    /// Mirrors Python's `str(value or "")` coercion for migrated picker
    /// values. int/double/bool all coerce; null/empty containers fold to `""`.
    public nonisolated static func jsonValueAsPythonStr(_ v: JSONValue) -> String {
        switch v {
        case .null: return ""
        case .bool(let b): return b ? "True" : "False"
        case .int(let i): return String(i)
        case .double(let d): return pythonFloatStr(d)
        case .string(let s): return s
        case .array, .object: return ""
        }
    }

    /// Render a double the way Python's `str(float)` does for migrated
    /// picker values (1.5 → "1.5", 2.0 → "2.0"). Avoids scientific
    /// notation for the round-trip common cases.
    nonisolated static func pythonFloatStr(_ d: Double) -> String {
        if d == d.rounded() && abs(d) < 1e16 {
            return "\(d)"  // Swift renders 2.0 as "2.0" — matches Python.
        }
        return "\(d)"
    }

    /// Return the string at `key` from `node`, coerced via Python's
    /// `str(value or "")` rules. Returns nil if the value is missing or
    /// Python-falsy (so the caller can fall through to a fallback like
    /// Python's `a or b or c` chain).
    nonisolated static func stringFrom(_ node: JSONValue, key: String) -> String? {
        guard case .object(let obj) = node, let v = obj[key] else { return nil }
        if isPythonFalsy(v) { return nil }
        let coerced = jsonValueAsPythonStr(v)
        return coerced.isEmpty ? nil : coerced
    }

    /// Walk `keys` in order, returning the first one whose value is
    /// Python-truthy (after str-coercion). Mirrors Python's chained
    /// `a or b or c`.
    nonisolated static func firstNonEmptyString(_ node: JSONValue, keys: [String]) -> String? {
        for k in keys {
            if let s = stringFrom(node, key: k) { return s }
        }
        return nil
    }

    nonisolated static func firstString(
        _ obj: [String: JSONValue],
        keys: [String]
    ) -> String? {
        for key in keys {
            if case .string(let s)? = obj[key] {
                let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { return trimmed }
            }
        }
        return nil
    }

    private nonisolated static func validateOpenAIOAuthDirect(dataRoot: URL) -> (Bool, String) {
        let paths = openAIOAuthCandidatePaths(dataRoot: dataRoot)
        var sawAuth = false
        for path in paths {
            guard let data = try? Data(contentsOf: path),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                continue
            }
            sawAuth = true
            let tokens = (obj["tokens"] as? [String: Any]) ?? [:]
            let access = (tokens["access_token"] as? String) ?? ""
            if access.isEmpty { continue }
            let refresh = (tokens["refresh_token"] as? String) ?? ""
            if let expDate = parseAuthExpiresAt(tokens["expires_at"])
                ?? parseAuthExpiresAt(obj["expires_at"])
                ?? jwtExpiry(access) {
                if expDate > Date() {
                    return (true, "Signed in (valid)")
                }
                if !refresh.isEmpty {
                    return (true, "Access expired - refresh on next chat")
                }
                continue
            }
            return (true, "Signed in")
        }
        if sawAuth {
            return (false, "tokens.access_token empty or expired without refresh_token - sign in required")
        }
        return (false, "auth.json missing or malformed")
    }

    /// Production keeps the intentional shared-Codex compatibility search.
    /// An alternate root is a separate body: it may inspect only its exact
    /// `<root>/codex_home/auth.json`, never the repo/default app-support path or
    /// `~/.codex/auth.json`.
    nonisolated static func openAIOAuthCandidatePaths(
        dataRoot: URL,
        defaultDataRoot: URL = PersistenceCore.defaultDataRoot()
    ) -> [URL] {
        let root = dataRoot.standardizedFileURL
        guard root == defaultDataRoot.standardizedFileURL else {
            return [root
                .appendingPathComponent("codex_home", isDirectory: true)
                .appendingPathComponent("auth.json")]
        }
        return OpenAIOAuthDirectAdapter.authPathCandidates(
            dataRoot: root,
            allowSharedFallbacks: true
        )
    }

    private nonisolated static func validateAnthropicOAuthDirect(providersDir: URL) -> (Bool, String) {
        let path = providersDir.appendingPathComponent("anthropic_oauth_direct.json")
        guard let data = try? Data(contentsOf: path),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return (false, "anthropic_oauth_direct.json missing or malformed")
        }
        let topAccess = (obj["access_token"] as? String) ?? ""
        let nestedAccess = ((obj["tokens"] as? [String: Any])?["access_token"] as? String) ?? ""
        let setupToken = (obj["setup_token"] as? String) ?? ""
        let access = !topAccess.isEmpty ? topAccess : (!nestedAccess.isEmpty ? nestedAccess : setupToken)
        if access.isEmpty {
            return (false, "no access_token or setup_token - sign in required")
        }
        let refresh = (obj["refresh_token"] as? String) ?? ""
        if let expDate = parseAuthExpiresAt(obj["expires_at"]) {
            if expDate > Date() {
                return (true, "Signed in (valid)")
            }
            if !refresh.isEmpty {
                return (true, "Access expired - refresh on next chat")
            }
            return (false, "Access expired and no refresh_token - re-auth required")
        }
        return (true, "Signed in")
    }

    private nonisolated static func validateXAIOAuthDirect(providersDir: URL) -> (Bool, String) {
        let path = providersDir.appendingPathComponent("xai_oauth_direct.json")
        guard let data = try? Data(contentsOf: path),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return (false, "xai_oauth_direct.json missing or malformed")
        }
        let access = ((obj["access_token"] as? String)
            ?? ((obj["tokens"] as? [String: Any])?["access_token"] as? String)
            ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let refresh = ((obj["refresh_token"] as? String)
            ?? ((obj["tokens"] as? [String: Any])?["refresh_token"] as? String)
            ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !access.isEmpty else {
            return (false, "no access_token - sign in required")
        }
        if let expDate = parseAuthExpiresAt(obj["expires_at"]) ?? jwtExpiry(access) {
            if expDate > Date() {
                return (true, "Signed in (valid)")
            }
            if !refresh.isEmpty {
                return (true, "Access expired - refresh on next chat")
            }
            return (false, "Access expired and no refresh_token - re-auth required")
        }
        return refresh.isEmpty ? (true, "Signed in") : (true, "Signed in (refresh available)")
    }

    private nonisolated static func parseAuthExpiresAt(_ raw: Any?) -> Date? {
        guard let raw else { return nil }
        if let i = raw as? Int { return Date(timeIntervalSince1970: TimeInterval(i)) }
        if let d = raw as? Double { return Date(timeIntervalSince1970: d) }
        guard let s = raw as? String, !s.isEmpty else { return nil }
        if let unix = TimeInterval(s) { return Date(timeIntervalSince1970: unix) }
        let basic = DateFormatter()
        basic.calendar = Calendar(identifier: .iso8601)
        basic.locale = Locale(identifier: "en_US_POSIX")
        basic.timeZone = TimeZone(secondsFromGMT: 0)
        basic.dateFormat = "yyyy-MM-dd'T'HH:mm:ss'Z'"
        if let d = basic.date(from: s) { return d }
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        if let d = iso.date(from: s) { return d }
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return iso.date(from: s)
    }

    private nonisolated static func jwtExpiry(_ token: String) -> Date? {
        let parts = token.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        var body = String(parts[1])
        while body.count % 4 != 0 { body.append("=") }
        body = body
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        guard let data = Data(base64Encoded: body),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        if let exp = obj["exp"] as? Int { return Date(timeIntervalSince1970: TimeInterval(exp)) }
        if let exp = obj["exp"] as? Double { return Date(timeIntervalSince1970: exp) }
        return nil
    }
}

// MARK: - Factory

/// SwiftNative handles provider routing directly. The provider-selection
/// decisions during chat turns happen inside the ChatOrchestration pipeline,
/// using Swift-native model preference data. This subsystem is
/// config/inspection only.
public func makeProviderRouting(
    dataRoot: URL = PersistenceCore.defaultDataRoot()
) -> any ProviderRoutingProtocol {
    return SwiftNativeProviderRouting(dataRoot: dataRoot)
}

// MARK: - Public model lookup

/// Context-window budget (input-token cap) for a known model id. Single
/// source of truth used by the chat-context status bar. Returns 200_000 for
/// any unknown id so the UI shows the safer of the two values rather than 0.
///
/// 2026-06-07: lifted out of the private `modelsForProvider` table so the
/// Mac UI's getSessionContext can derive the budget directly from
/// `appModel.chatModel` without going through the async provider catalog.
public func contextLength(forModel modelId: String) -> Int {
    let id = modelId.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    if let descriptor = FirstPartyModelCatalog.descriptor(for: id) {
        return descriptor.contextLength
    }
    switch id {
    // OpenAI family
    case let model where model == nativeAgentPrimaryModel: return 200_000
    case "gpt-5.4": return 128_000
    case "gpt-5.4-mini": return 128_000
    // Anthropic family
    case "claude-fable-5": return 200_000
    case "claude-opus-4-8": return 200_000
    case "claude-opus-5": return 200_000
    case "claude-sonnet-4-6": return 200_000
    case "claude-haiku-4-5": return 200_000
    // OpenRouter passthroughs (live rows 2026-08-07; the delisted
    // anthropic/claude-3.5-sonnet entry was retired with them).
    // Non-gauge consumer note: ChatSessionAutocompactor reads this length
    // directly, so the 1M row lets a Sonnet-5-via-OpenRouter session keep the
    // user-configured compaction ceiling instead of clamping to a 200k
    // window's 40% — correct for a genuinely 1M-window model.
    case "meta-llama/llama-3.3-70b-instruct": return 131_072
    case "anthropic/claude-sonnet-5": return 1_000_000
    default:
        // gpt-5.5 review #4 (NEEDS_FIX): unknown-model fallback was 200_000
        // which is optimistic — a 128k-window model would then read percent
        // below 100 even when it had blown its real budget and stopped
        // accepting input. Default to 128_000 so the gauge errs toward
        // pessimism (the user sees pressure sooner) and only widen for ids that
        // self-identify as long-context. opus/sonnet/gpt-5.5 family ids
        // already hit explicit cases above.
        if id.contains("gpt-5.4") || id.contains("gpt-5.3") || id.contains("haiku-3") {
            return 128_000
        }
        return 128_000
    }
}
