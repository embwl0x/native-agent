import Foundation
import NativeAgentShared
import NativeAgentCore
import PersistenceCore
// Blueprint: | `ProviderRoutingContracts.swift` | `ProviderRoutingSnapshot`, `TurnRouteAdmission`, `SwiftNativeProviderRouting` |

extension ProviderSurfaceGroups {
    public static func group(for surface: String) -> ProviderSurfaceGroup? {
        let canonical = canonicalRoutingSurface(surface)
        return all.first { $0.surfaces.contains(canonical) }
    }

    public static func members(of surface: String) -> [String] {
        group(for: surface)?.surfaces ?? [canonicalRoutingSurface(surface)]
    }

}

/// Bots carry an explicit provider/model/effort tuple that is validated without downstream reselection. Route-supplied catalogs precede shipped rows;
/// absent control evidence is unavailable.
public enum ProviderModelChoice {
    public static func rejection(
        provider: String?,
        model: String?,
        reasoningEffort: String?,
        accountModels: [CodexAccountModelCatalog.Model]? = nil,
        moonshotModels: [ProviderModelInfo]? = nil,
        openRouterModels: [ProviderModelInfo]? = nil,
        dataRoot: URL = PersistenceCore.defaultDataRoot()
    ) -> String? {
        let route = provider?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let id = model?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let effort = reasoningEffort?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        guard !route.isEmpty else { return "Choose the account this runs on." }
        guard !id.isEmpty else { return "Choose a model on that account." }
        if ProviderFamilyIdentity.normalize(route) == "openrouter" {
            guard let row = openRouterModels?.first(where: { $0.id.caseInsensitiveCompare(id) == .orderedSame }),
                  let supported = row.supported_reasoning_efforts else {
                return "OpenRouter's reasoning capabilities for \(id) are unavailable. Refresh its model catalog in Providers before choosing a Think level."
            }
            if supported.isEmpty {
                return effort.isEmpty || effort == "default" ? nil
                    : "\(id) has no Think selector. Choose provider default in Providers."
            }
            return supported.contains(effort) ? nil
                : "\(id) does not support Think \(effort); it supports " + supported.joined(separator: ", ") + "."
        }
        guard !effort.isEmpty else { return "Choose a Think level for that model." }
        guard REASONING_EFFORT_OPTIONS.contains(effort) else {
            return "\(effort) is not a Think level."
        }
        let moonshot = ProviderFamilyIdentity.normalize(route) == "moonshot" ? moonshotModels : nil
        let openRouter = ProviderFamilyIdentity.normalize(route) == "openrouter" ? openRouterModels : nil
        guard moonshot.map({ $0.contains { $0.id.lowercased() == id.lowercased() } })
            ?? accountModels.map({ $0.contains { $0.id.lowercased() == id.lowercased() } })
            ?? FirstPartyModelCatalog.routeCarries(id, providerID: route, dataRoot: dataRoot) else {
            return "\(route) does not serve \(id). Pick a model that account offers."
        }
        guard let supported = openRouter?.first(where: { $0.id == id })?.supported_reasoning_efforts
            ?? moonshot.flatMap({ _ in MoonshotModelCatalog.supportedReasoningEfforts(for: id) })
            ?? accountModels?.first(where: { $0.id.lowercased() == id.lowercased() })?.supportedReasoningEfforts
            ?? FirstPartyModelCatalog.routeSupportedEfforts(id, providerID: route, dataRoot: dataRoot), !supported.isEmpty else {
            return "Think controls for \(id) on \(route) are unknown. Refresh its model catalog in Providers."
        }
        if !supported.contains(effort) {
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
// Provider inspection/configuration and runtime dispatch share the in-process routing owner and modelRouting envelope.

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
        "id",
        "displayName",
        "kind",
        "configured",
        "active",
        "surface",
        "modelCatalog",
        "oauthStatus",
        "lastTestedAt",
        "lastError",
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
                if let v = try c.decodeIfPresent(JSONValue.self, forKey: JSONKey(k)) {
                    return v
                }
            }
            return nil
        }

        let idVal = try c.decode(String.self, forKey: JSONKey("id"))
        self.id = idVal
        self.displayName = try str("displayName")
        self.kind = try str("kind")
        self.configured = try bool("configured")
        self.active = try bool("active")
        self.surface = try str("surface")
        self.modelCatalog = try jv("modelCatalog")
        self.oauthStatus = try jv("oauthStatus")
        self.lastTestedAt = try str("lastTestedAt")
        self.lastError = try str("lastError")

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

/// Read back the canonical group after commit.
public struct ProviderGroupWriteResult: Sendable {
    public let surfacesChanged: [String]
    public let snapshot: ProviderRoutingSnapshot
}

public struct ProviderGroupWriteFailure: LocalizedError, Sendable {
    public let detail: String
    public let forwardIntent: JSONValue
    public let intentStatus: String
    public let projectionsCommitted: [String]
    public let projectionsPending: [String]
    public let projectionsUnknown: [String]
    public let surfacesPendingRecovery: [String]
    public var errorDescription: String? { detail }
}

public struct ProviderCatalogSnapshot: Sendable {
    public let routing: ProviderRoutingSnapshot
    public let providers: [Provider]
    public let rowSet: ProviderSurfaceRowSet
}

extension ProviderRoutingSnapshot {
    /// An unset surface names why its saved model cannot run.
    public func unusablePickNotice(for surface: String) -> String? {
        ProviderRoutingSurfaceLookup.value(unusablePicks, surface)
    }
}

extension ProviderSurfaceRowSet {
    public init(surfacePreferenceKeys: Set<String>, activeProviderKeys: Set<String>) {
        let stored = Set(surfacePreferenceKeys.union(activeProviderKeys).map(canonicalRoutingSurface))
        self.init(visibleSurfaces: MODEL_SURFACES, unsupportedStoredKeys: stored.subtracting(Set(MODEL_SURFACES)).sorted())
    }
}
// MARK: - Routing vocabulary

/// One group inventory governs all model consumers. Model/account inherit only with no override; effort/tier mutate independently, and partial/conflicting
/// tuples remain unavailable.
public let MODEL_SURFACES: [String] = ProviderSurfaceGroups.all.flatMap(\.surfaces)

/// Normalize current surface spelling consistently; unsupported names fail admission.
public func canonicalRoutingSurface(_ surface: String) -> String {
    surface.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
}

public let REASONING_EFFORT_OPTIONS: [String] = ["default", "none", "minimal", "low", "medium", "high", "xhigh", "max", "ultra"]

public let SERVICE_TIER_OPTIONS: [String] = ["default", "priority"]

/// Default effort still requires model/account compatibility admission.
public let DEFAULT_REASONING_EFFORT: String = "high"

/// Surface maps read the current normalized name only.
public enum ProviderRoutingSurfaceLookup {
    public static func value<V>(_ map: [String: V], _ surface: String) -> V? {
        map[canonicalRoutingSurface(surface)]
    }
}

/// Hold one immutable execution tuple before choosing a branch. The store remains authority and adapters reread credentials for corruption/revocation.
public struct TurnRouteAdmission: Sendable, Equatable {
    public let routingSurface: String
    public let modelId: String
    public let reasoningEffort: String?
    public let providerId: String?
    public let serviceTier: String?
    public init(routingSurface: String, modelId: String, reasoningEffort: String?,
                providerId: String?, serviceTier: String?) {
        self.routingSurface = routingSurface; self.modelId = modelId
        self.reasoningEffort = reasoningEffort; self.providerId = providerId; self.serviceTier = serviceTier
    }

    public var modelAdmission: ModelAdmission {
        get throws {
            guard let providerId, !providerId.isEmpty else { throw LLMError.notConfigured(provider: "router") }
            return ModelAdmission(provider: providerId, model: modelId,
                reasoningEffort: reasoningEffort, serviceTier: serviceTier)
        }
    }

    /// Apply the selected tuple to the value the caller will hand to its work.
    public func admittedTurn(_ turn: Turn, model: String? = nil, reasoningEffort: String? = nil) throws -> Turn {
        let admitted = try modelAdmission
        return turn.with(\.admission, ModelAdmission(provider: admitted.provider, model: model ?? admitted.model,
            reasoningEffort: reasoningEffort ?? admitted.reasoningEffort, serviceTier: admitted.serviceTier))
    }
}

extension ProviderRoutingSnapshot {
    public func routeAdmission(for surface: String, requestedModel: String? = nil,
        requestedReasoningEffort: String? = nil, suppliedModel: String = "",
        choice: ProviderTurnChoice? = nil,
        call: LLMCall? = nil, inheritChat: Bool = true) throws -> TurnRouteAdmission {
        let normalized = surface.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let routingSurface = canonicalRoutingSurface(normalized)
        // An admitted call reads exactly the held tuple. Picker changes cannot splice into it.
        if let admitted = call?.admission {
            return TurnRouteAdmission(routingSurface: routingSurface, modelId: admitted.model,
                reasoningEffort: admitted.reasoningEffort,
                providerId: admitted.provider, serviceTier: admitted.serviceTier)
        }
        let choice = choice ?? call?.turn?.providerChoice
        if let choice {
            guard !choice.provider.isEmpty, !choice.model.isEmpty, !choice.reasoningEffort.isEmpty else {
                throw LLMError.providerError(message: "Choose a provider, model and Think level.")
            }
            return TurnRouteAdmission(routingSurface: routingSurface, modelId: choice.model,
                reasoningEffort: choice.reasoningEffort, providerId: choice.provider,
                serviceTier: choice.fast ? "priority" : "default")
        }
        // A supplied/requested model cannot make a broken saved group borrow Chat's account. An already bound call retains its own admission.
        if let fault = unusablePickNotice(for: routingSurface) {
            throw LLMError.providerError(message: fault)
        }
        let preference = ProviderRoutingSurfaceLookup.value(self.preferences, routingSurface)
            ?? (inheritChat ? self.preferences["chat"] : nil)
        let configuredModel = preference?.model
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let supplied = suppliedModel.trimmingCharacters(in: .whitespacesAndNewlines)
        let requested = requestedModel?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let admittedModel: String
        if !supplied.isEmpty {
            admittedModel = supplied
        } else if ProviderRoutingSurfaceLookup.value(self.activeProviders, routingSurface) != nil {
            admittedModel = configuredModel
        } else {
            admittedModel = requested.isEmpty ? configuredModel : requested
        }
        guard !admittedModel.isEmpty else {
            if call != nil { throw LLMError.notConfigured(provider: "router") }
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
        return TurnRouteAdmission(
            routingSurface: routingSurface,
            modelId: admittedModel,
            reasoningEffort: requestedEffort.isEmpty
                ? (preference?.reasoningEffort ?? DEFAULT_REASONING_EFFORT) : requestedEffort,
            providerId: ProviderRoutingSurfaceLookup.value(self.activeProviders, routingSurface)
                ?? (inheritChat ? self.activeProviders["chat"] : nil),
            serviceTier: preference?.serviceTier ?? "default"
        )
    }
}

extension SwiftNativeProviderRouting {
    public func checkedRouteAdmission(for surface: String, requestedModel: String? = nil,
        requestedReasoningEffort: String? = nil, suppliedModel: String = "", preview: Bool = false) async throws -> TurnRouteAdmission {
        try await checkedRoutingSnapshot(preview: preview).routeAdmission(for: surface, requestedModel: requestedModel,
            requestedReasoningEffort: requestedReasoningEffort, suppliedModel: suppliedModel)
    }
}
