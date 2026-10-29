import Foundation
import NativeAgentShared
import NativeAgentCore
import PersistenceCore
// Blueprint: | `ProviderRoutingContracts.swift` | `ProviderRoutingSnapshot` carries its checked source revision and owns modelOverrideSurfaces independently of effort/Fast for settings and UI inheritance reads; `TurnRouteAdmission` and checked snapshot admission bind one execution tuple with explicit inheritance; `SwiftNativeProviderRouting` surface lookup conveniences |

extension ProviderSurfaceGroups {
    public static func group(for surface: String) -> ProviderSurfaceGroup? {
        let canonical = canonicalRoutingSurface(surface)
        return all.first { $0.surfaces.contains(canonical) }
    }

    public static func members(of surface: String) -> [String] {
        group(for: surface)?.surfaces ?? [canonicalRoutingSurface(surface)]
    }

}

/// Bots carry an explicit provider/model/effort tuple that is validated without downstream reselection.
/// Route-supplied catalogs precede shipped rows; routes without either accept any model ID.
public enum ProviderModelChoice {
    /// nil when the tuple is usable, else a sentence naming what is wrong.
    public static func rejection(
        provider: String?,
        model: String?,
        reasoningEffort: String?,
        accountModels: [CodexAccountModelCatalog.Model]? = nil,
        moonshotModels: [ProviderModelInfo]? = nil
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
        let moonshot = ProviderFamilyIdentity.normalize(route) == "moonshot" ? moonshotModels : nil
        guard moonshot.map({ $0.contains { $0.id.lowercased() == id.lowercased() } })
            ?? accountModels.map({ $0.contains { $0.id.lowercased() == id.lowercased() } })
            ?? FirstPartyModelCatalog.routeCarries(id, providerID: route) else {
            return "\(route) does not serve \(id). Pick a model that account offers."
        }
        if let supported = moonshot.map({ _ in MoonshotModelCatalog.supportedReasoningEfforts(for: id) })
            ?? accountModels?.first(where: { $0.id.lowercased() == id.lowercased() })?.supportedReasoningEfforts
            ?? FirstPartyModelCatalog.routeSupportedEfforts(id, providerID: route),
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
// ChatTurnRuntime resolves the surface/model choice and SwiftNativeLLMClient
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

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: JSONKey.self)
        func str(_ keys: String...) throws -> String? {
            var result: String?
            for k in keys {
                if let v = try c.decodeIfPresent(String.self, forKey: JSONKey(k)) {
                    if result == nil { result = v }
                }
            }
            return result
        }
        func bool(_ keys: String...) throws -> Bool? {
            var result: Bool?
            for k in keys {
                if let v = try c.decodeIfPresent(Bool.self, forKey: JSONKey(k)) {
                    if result == nil { result = v }
                }
            }
            return result
        }
        func jv(_ keys: String...) throws -> JSONValue? {
            for k in keys {
                if let v = (try? c.decodeIfPresent(JSONValue.self, forKey: JSONKey(k))) ?? nil {
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

        var unknown = c.unknownFields(excluding: Self.knownKeys)
        if let explicit = try jv("extras"), case .object(let obj) = explicit {
            for (k, v) in obj { unknown[k] = v }
        }
        self.extras = unknown.isEmpty ? nil : .object(unknown)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: JSONKey.self)
        try c.encode(id, forKey: JSONKey("id"))
        try c.encodeIfPresent(displayName, forKey: JSONKey("displayName"))
        try c.encodeIfPresent(kind, forKey: JSONKey("kind"))
        try c.encodeIfPresent(configured, forKey: JSONKey("configured"))
        try c.encodeIfPresent(active, forKey: JSONKey("active"))
        try c.encodeIfPresent(surface, forKey: JSONKey("surface"))
        try c.encodeIfPresent(modelCatalog, forKey: JSONKey("modelCatalog"))
        try c.encodeIfPresent(oauthStatus, forKey: JSONKey("oauthStatus"))
        try c.encodeIfPresent(lastTestedAt, forKey: JSONKey("lastTestedAt"))
        try c.encodeIfPresent(lastError, forKey: JSONKey("lastError"))
        try c.encodeUnknownFields(extras, excluding: Self.knownKeys)
    }
}

// MARK: - ModelPreferences

public struct ModelPreferences: Sendable, Codable, Equatable {
    public var surfaceModels: JSONValue?
    public var defaultModel: String?
    public var extras: JSONValue?

    public init(
        surfaceModels: JSONValue? = nil,
        defaultModel: String? = nil,
        extras: JSONValue? = nil
    ) {
        self.surfaceModels = surfaceModels
        self.defaultModel = defaultModel
        self.extras = extras
    }

    enum CodingKeys: String, CodingKey {
        case surfaceModels = "surface_models"
        case defaultModel = "default_model"
        case extras
    }
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
        repair.message
    }

    var repair: ToolFailureError {
        let code: String
        let detail: String
        let effects: ToolFailureError.Effects
        let instruction: String
        switch self {
        case .invalidRequest:
            (code, detail, effects) = ("provider_request_invalid", "The provider request has missing or unsupported input.", .none)
            instruction = "Read Providers and correct the request's required fields and supported values."
        case .providerNotFound:
            (code, detail, effects) = ("provider_not_found", "The requested account is not in Providers.", .none)
            instruction = "Read Providers and select an account listed there."
        case .configurationFailed(let message):
            (code, detail, effects) = ("provider_configuration_failed", "Provider configuration failed: \(message)", .unknown)
            instruction = "Read Providers and correct the reported configuration before saving."
        case .invalidResponse(let status):
            (code, detail, effects) = ("provider_http_rejected", "The provider endpoint answered HTTP \(status).", .none)
            instruction = "Read Providers to inspect this account's connection and model access."
        case .unavailable:
            (code, detail, effects) = ("provider_route_unavailable", "No connected account offers a model for this request.", .none)
            instruction = "Read Providers; connect an account and select a model it offers."
        case .underlying(let message):
            (code, detail, effects) = ("provider_state_unavailable", "Provider state is unavailable: \(message)", .unknown)
            instruction = "Inspect providers.routing_repair and correct the reported saved state before changing the selection."
        }
        let input: [String: JSONValue]
        let control: String
        if case .underlying = self {
            input = ["action": .string("setting.get"), "args": .object(["setting": .string("providers.routing_repair")])]
            control = "app {action:\"setting.get\",args:{setting:\"providers.routing_repair\"}}"
        } else {
            input = ["page": .string("providers")]
            control = "app {page:\"providers\"}"
        }
        return ToolFailureError("\(code): \(detail) \(instruction) Use \(control).", effects: effects, owner: "provider routing",
            nextCall: ToolFailureError.call("app", input),
            code: code, instruction: instruction, recovery: .inspect)
    }
}

// MARK: - Resolved surface preferences

/// One surface's resolved preference from the in-process ProviderRouting owner.
/// Chat members share Chat's tuple; Work and Memory and mind share their
/// unanimous group override, or inherit Chat's model/account with independent
/// effort. ProviderRouting owns the catalog
/// too; `modelKnown` is optional catalog metadata, not a routing choice.
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

/// The committed group and its canonical readback.
public struct ProviderGroupWriteResult: Sendable {
    public let surfacesChanged: [String]
    public let snapshot: ProviderRoutingSnapshot
}

public struct ProviderGroupWriteFailure: LocalizedError, Sendable {
    public let detail: String
    public let surfacesRolledBack: [String]
    public let surfacesPendingRecovery: [String]
    public var errorDescription: String? { detail }
}

public struct ProviderCatalogSnapshot: Sendable {
    public let routing: ProviderRoutingSnapshot
    public let providers: [Provider]
    public let rowSet: ProviderSurfaceRowSet
}

/// One reconciled, internally consistent view of the two authoritative picker
/// projections. Execution paths use this instead of independently reading
/// model preferences, active providers, and explicit pins across separate
/// locks, which could otherwise combine values from different commits.
public struct ProviderRoutingSnapshot: Sendable, Equatable {
    /// The checked picker files' committed source revision, read under their lock.
    public let revision: Double
    public let preferences: [String: SurfacePreference]
    public let activeProviders: [String: String]
    public let pinnedModels: [String: String]
    /// Model/account inheritance is independent of effort and Fast.
    public var modelOverrideSurfaces: Set<String> {
        Set(pinnedModels.keys).union(preferences.keys.filter { surface in
            surface != "chat" && (preferences[surface]?.model != preferences["chat"]?.model
                || (activeProviders[surface] ?? activeProviders["chat"]) != activeProviders["chat"])
        })
    }
    /// Unusable saved picks leave the surface unset with a reason; no replacement is selected.
    public let unusablePicks: [String: String]

    public init(
        preferences: [String: SurfacePreference],
        activeProviders: [String: String],
        pinnedModels: [String: String],
        unusablePicks: [String: String] = [:],
        revision: Double = 0
    ) {
        self.revision = revision
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

// MARK: - Routing vocabulary

/// Every in-process LLM consumer routes through one of these surfaces.
/// `ProviderSurfaceGroups` owns the inventory in Chat, Work, then Memory and mind order.
/// Members share their group's model, account, effort and service tier; Work
/// and Memory and mind inherit Chat's model/account until a unanimous override
/// is saved; setting effort alone preserves that inheritance.
/// A provider-only override uses that account's default and requires a model
/// selection when no usable default exists. Legacy `missions` keys fold to
/// `workshop` at the checked read and write boundaries.
public let MODEL_SURFACES: [String] = ProviderSurfaceGroups.all.flatMap(\.surfaces)

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

/// Reasoning controls normalized by the in-process routing owner.
public let REASONING_EFFORT_OPTIONS: [String] = ["none", "low", "medium", "high", "xhigh", "max", "ultra"]

public let SERVICE_TIER_OPTIONS: [String] = ["default", "priority"]

/// Default reasoning control before model/account compatibility normalization.
public let DEFAULT_REASONING_EFFORT: String = "high"

extension SwiftNativeProviderRouting {
    /// Independent model lookup for sizing or an explicitly injected routing choice.
    public func modelStringForSurface(_ surface: String) async -> String? {
        guard let prefs = try? await computeModelPreferences() else { return nil }
        if let m = ProviderRoutingSurfaceLookup.value(prefs, surface)?.model, !m.isEmpty {
            return m
        }
        return nil
    }
}

/// Surface maps accept either vocabulary, checking the canonical key before its persisted alias.
public enum ProviderRoutingSurfaceLookup {
    public static func value<V>(_ map: [String: V], _ surface: String) -> V? {
        let canonical = WorkshopSurfaceVocabulary.canonicalSurface(surface)
        if let hit = map[canonical] { return hit }
        guard canonical == WorkshopSurfaceVocabulary.canonical else { return nil }
        return map[WorkshopSurfaceVocabulary.legacy]
    }
}

/// One immutable provider-routing generation admitted before a chat facade
/// chooses its execution branch. This is execution context only; the
/// ProviderRouting store remains the sole authority and adapters still use a
/// checked reread to detect corrupt/revoked authority.
public struct TurnRouteAdmission: Sendable, Equatable {
    public let routingSurface: String
    public let modelId: String
    public let reasoningEffort: String
    public let providerId: String?
    public let serviceTier: String?
    public init(routingSurface: String, modelId: String, reasoningEffort: String,
                providerId: String?, serviceTier: String?) {
        self.routingSurface = routingSurface; self.modelId = modelId
        self.reasoningEffort = reasoningEffort; self.providerId = providerId; self.serviceTier = serviceTier
    }

    public func withModelContext<T: Sendable>(model: String? = nil, reasoningEffort: String? = nil,
        isolation: isolated (any Actor)? = #isolation,
        _ body: () async throws -> T) async rethrows -> T {
        try await LLMCallContext.$admittedModel.withValue(model ?? modelId) {
        try await LLMCallContext.$providerId.withValue(providerId) {
        try await LLMCallContext.$reasoningEffort.withValue(reasoningEffort ?? self.reasoningEffort) {
        try await LLMCallContext.$serviceTier.withValue(serviceTier, operation: body)
        } } }
    }
}

extension ProviderRoutingSnapshot {
    public func routeAdmission(for surface: String, requestedModel: String? = nil,
        requestedReasoningEffort: String? = nil, suppliedModel: String = "",
        choice: ProviderTurnChoice? = ProviderTurnChoice.current,
        inheritingCall: Bool = false, inheritChat: Bool = true) throws -> TurnRouteAdmission {
        let normalized = surface.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let routingSurface = canonicalRoutingSurface(normalized)
        // Dispatch inherits its bound admission before considering an ambient picker choice.
        let inheritedModel = inheritingCall ? LLMCallContext.admittedModel?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? "" : ""
        if let choice, inheritedModel.isEmpty {
            guard !choice.provider.isEmpty, !choice.model.isEmpty, !choice.reasoningEffort.isEmpty else {
                throw LLMError.providerError(message: "Choose a provider, model and Think level.")
            }
            return TurnRouteAdmission(routingSurface: routingSurface, modelId: choice.model,
                reasoningEffort: choice.reasoningEffort, providerId: choice.provider,
                serviceTier: choice.fast ? "priority" : "default")
        }
        let preference = ProviderRoutingSurfaceLookup.value(self.preferences, routingSurface)
            ?? (inheritChat ? self.preferences["chat"] : nil)
        let configuredModel = preference?.model
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let supplied = suppliedModel.trimmingCharacters(in: .whitespacesAndNewlines)
        let requested = requestedModel?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let admittedModel: String
        if !inheritedModel.isEmpty {
            admittedModel = inheritedModel
        } else if !supplied.isEmpty {
            admittedModel = supplied
        } else if ProviderRoutingSurfaceLookup.value(self.activeProviders, routingSurface) != nil {
            admittedModel = configuredModel
        } else {
            admittedModel = requested.isEmpty ? configuredModel : requested
        }
        guard !admittedModel.isEmpty else {
            if inheritingCall { throw LLMError.notConfigured(provider: "router") }
            let notice = self.unusablePickNotice(for: routingSurface)
                ?? ProviderSurfaceGroups.members(of: routingSurface)
                    .compactMap { self.unusablePickNotice(for: $0) }.first
                ?? self.unusablePickNotice(for: "chat")
            throw LLMError.providerError(
                message: notice.map { "\($0) Open Providers to pick one." }
                    ?? "No model is set up yet. Open Providers and choose one for Chat."
            )
        }
        let requestedEffort = requestedReasoningEffort?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let inheritedProvider = inheritingCall ? LLMCallContext.providerId?
            .trimmingCharacters(in: .whitespacesAndNewlines) : nil
        return TurnRouteAdmission(
            routingSurface: routingSurface,
            modelId: admittedModel,
            reasoningEffort: inheritingCall ? (LLMCallContext.reasoningEffort ?? preference?.reasoningEffort ?? DEFAULT_REASONING_EFFORT) : requestedEffort.isEmpty
                ? (preference?.reasoningEffort ?? DEFAULT_REASONING_EFFORT)
                : requestedEffort,
            providerId: inheritedProvider?.isEmpty == false ? inheritedProvider
                : ProviderRoutingSurfaceLookup.value(self.activeProviders, routingSurface)
                ?? (inheritChat ? self.activeProviders["chat"] : nil),
            serviceTier: (inheritingCall ? LLMCallContext.serviceTier : nil) ?? preference?.serviceTier ?? (inheritingCall ? nil : "default")
        )
    }
}

extension SwiftNativeProviderRouting {
    public func checkedRouteAdmission(for surface: String, requestedModel: String? = nil,
        requestedReasoningEffort: String? = nil, suppliedModel: String = "") async throws -> TurnRouteAdmission {
        try await checkedRoutingSnapshot().routeAdmission(for: surface, requestedModel: requestedModel,
            requestedReasoningEffort: requestedReasoningEffort, suppliedModel: suppliedModel)
    }
}
