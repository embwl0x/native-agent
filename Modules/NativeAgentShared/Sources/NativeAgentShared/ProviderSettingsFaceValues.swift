import Foundation
// Blueprint: | `ProviderSettingsFaceValues.swift` | Finished provider settings, conversation controls and catalog values for the face feed |

public struct ProviderTurnChoice: Sendable, Codable, Hashable {
    public let provider: String
    public let model: String
    public let reasoningEffort: String
    public let fast: Bool

    public init(provider: String, model: String, reasoningEffort: String, fast: Bool) {
        self.provider = provider
        self.model = model
        self.reasoningEffort = reasoningEffort
        self.fast = fast
    }
}

public struct ProviderSignInStatus: Sendable, Codable, Equatable {
    public let isSignedIn: Bool
    public let detail: String?
    public let error: String?

    public init(isSignedIn: Bool, detail: String?, error: String?) {
        self.isSignedIn = isSignedIn
        self.detail = detail
        self.error = error
    }
}

public enum CodexCLISessionOffer: Sendable, Codable, Equatable {
    case available(email: String?, alreadyDeclined: Bool)
    case unavailable(reason: String)
}

public struct ProviderSettingsSnapshot: FaceValue {
    public let routing: ProviderRoutingSnapshot
    public let providers: [ProviderInfo]
    public let catalog: ModelCatalogResponse?
    public let catalogError: String?
    public let rowSet: ProviderSurfaceRowSet
    public let unavailableModels: [String: Bool]
    public let oauthStatuses: [String: ProviderSignInStatus]
    public let codexCLISessionOffer: CodexCLISessionOffer?
    public var activeProviders: [String: String] { routing.activeProviders }
    public var preferences: [String: SurfacePreference] { routing.preferences }

    public init(routing: ProviderRoutingSnapshot, providers: [ProviderInfo], catalog: ModelCatalogResponse?, catalogError: String?,
                rowSet: ProviderSurfaceRowSet, unavailableModels: [String: Bool], oauthStatuses: [String: ProviderSignInStatus],
                codexCLISessionOffer: CodexCLISessionOffer?) {
        self.routing = routing
        self.providers = providers
        self.catalog = catalog
        self.catalogError = catalogError
        self.rowSet = rowSet
        self.unavailableModels = unavailableModels
        self.oauthStatuses = oauthStatuses
        self.codexCLISessionOffer = codexCLISessionOffer
    }

    public func selection(for surface: String) -> ProviderTurnChoice? {
        guard let preference = preferences[surface], let provider = activeProviders[surface] else { return nil }
        return .init(provider: provider, model: preference.model, reasoningEffort: preference.reasoningEffort,
                     fast: preference.serviceTier == "priority")
    }
}

public struct ProviderHelperPresentation: FaceValue {
    public let name: String
    public let model: String?
    public init(name: String, model: String?) { self.name = name; self.model = model }
}

public struct ProviderModelPresentation: FaceValue {
    public let model: ModelCatalogItem
    public let efforts: [ReasoningEffortOption]
    public init(model: ModelCatalogItem, efforts: [ReasoningEffortOption]) { self.model = model; self.efforts = efforts }
}

public struct ProviderComposerPresentation: FaceValue {
    public let contract: ProviderHelperPresentation?
    public var choice: ProviderTurnChoice?
    public let providerGroups: [ChatComposerModelGroup]
    public let models: [String: [String: ProviderModelPresentation]]
    public var selectedModel: ModelCatalogItem? {
        guard let choice else { return nil }
        return models[choice.provider]?[choice.model]?.model
    }
    public var efforts: [ReasoningEffortOption] {
        guard let choice else { return [] }
        return models[choice.provider]?[choice.model]?.efforts ?? []
    }
    public var supportsFast: Bool { selectedModel?.supportsFast == true }
    public var fastIsOn: Bool { choice?.fast == true && (contract != nil || supportsFast) }

    public init(contract: ProviderHelperPresentation?, choice: ProviderTurnChoice?, providerGroups: [ChatComposerModelGroup],
                models: [String: [String: ProviderModelPresentation]]) {
        self.contract = contract
        self.choice = choice
        self.providerGroups = providerGroups
        self.models = models
    }
}

public struct ProviderSessionPresentation: FaceValue {
    public let controls: ProviderComposerPresentation
    public let context: SessionContextStatus?
    public let error: String?
    public var contract: ProviderHelperPresentation? { controls.contract }
    public var choice: ProviderTurnChoice? { controls.choice }

    public init(controls: ProviderComposerPresentation, context: SessionContextStatus?, error: String?) {
        self.controls = controls
        self.context = context
        self.error = error
    }
}

public struct ProviderSettingsFace: FaceValue {
    public var snapshot: ProviderSettingsSnapshot?
    public var error: String?
    public var sessions: [String: ProviderSessionPresentation] = [:]
    public var providerProbeStarts: [String: Date] = [:]
    public var catalogRefreshStarted: Date?
    public var codexAuth: CodexAuthStatus?
    public var isSavingChatBrain = false
    public var readiness: Readiness = .loading
    public var chatChoice: ProviderTurnChoice?
    public var chatModelReady = false
    public var connectedProviderLabel: String?
    public var apiKeyAccountIDs: [String] = []
    public init() {}

    public enum Readiness: Sendable, Codable, Equatable {
        case loading, ready, needsConnection
        case unavailable(String)
    }
}
