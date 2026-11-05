import Foundation
import NativeAgentShared
import ProviderRouting
import NativeAgentCore
import ChatToolRuntime
import MemoryV2
import DeviceSync
import NotificationInbox
import PersistenceCore

// Blueprint: | `TelegramModelSelection.swift` | Use checked account-scoped catalogs; retain each provider's cause and declared capabilities |

public struct TelegramProviderRoutingBridge: Sendable {
    let routing: SwiftNativeProviderRouting

    public init(routing: SwiftNativeProviderRouting) {
        self.routing = routing
    }

    public func saveModelConfig(surface: String, key: String, value: String, turn: Turn) async throws {
        var body: [String: JSONValue] = ["surface": .string(surface)]
        switch key {
        case "reasoning_effort", "reasoningEffort":
            body["reasoningEffort"] = .string(value)
        case "service_tier", "serviceTier":
            body["serviceTier"] = .string(value)
        case "model":
            // The model changes; the surface keeps its chosen route.
            body["model"] = .string(value)
        default:
            body[key] = .string(value)
        }
        _ = try await routing.saveModelConfig(.object(body))
    }

    public func saveModelSelection(surface: String, provider: String?, model: String, turn: Turn) async throws {
        // Keep the surface's explicit account rather than guessing from the model name.
        let explicitProvider = provider?.trimmingCharacters(in: .whitespacesAndNewlines)
        let admittedProvider = explicitProvider?.isEmpty == false ? explicitProvider : nil
        try await routing.saveSurfaceConfiguration(
            surface: surface,
            model: model,
            reasoningEffort: nil,
            serviceTier: nil,
            providerId: admittedProvider
        )
    }

    public func modelMenuForSurface(_ surface: String) async throws -> TelegramModelMenu {
        let snapshot = try await routing.checkedProviderSnapshot()
        guard let preference = snapshot.routing.preferences[surface],
              let currentProvider = snapshot.routing.activeProviders[surface] else {
            throw ProviderRoutingError.configurationFailed("The checked \(surface) route is unavailable. Read Providers to repair routing.")
        }
        let providers = snapshot.providers
        let choices = providers.filter { Self.isSelectableProvider($0, currentProvider: currentProvider) }.map { provider in
            let isCurrent = TelegramModelMenu.providerIDsMatch(provider.id, currentProvider)
            let models: [TelegramModelChoice]
            var issue: String?
            do {
                models = try routing.checkedCatalogModels(for: provider.id).map { model in
                    TelegramModelChoice(id: model.id, name: model.name,
                        isCurrent: isCurrent && model.id == preference.model,
                        supportedReasoningEfforts: model.supported_reasoning_efforts,
                        supportsFast: model.supports_fast)
                }
            } catch {
                models = []
                issue = error.localizedDescription
            }
            return TelegramModelProviderChoice(id: provider.id,
                displayName: provider.displayName ?? provider.id, isCurrent: isCurrent,
                models: models, catalogIssue: issue)
        }
        return TelegramModelMenu(surface: surface, currentModel: preference.model,
            currentProvider: currentProvider, providers: choices)
    }

    private static func isSelectableProvider(_ provider: Provider, currentProvider: String) -> Bool {
        if provider.id == "codex" { return true }
        if TelegramModelMenu.providerIDsMatch(provider.id, currentProvider) { return true }
        if provider.configured == true || provider.active == true { return true }
        if case .object(let obj)? = provider.oauthStatus,
           case .string(let state)? = obj["state"],
           state == "ready" {
            return true
        }
        if case .object(let extras)? = provider.extras,
           case .object(let status)? = extras["auth_status"],
           case .string(let state)? = status["state"],
           state == "ready" {
            return true
        }
        return false
    }


}

public struct TelegramModelMenu: Sendable, Equatable {
    public let surface: String
    public let currentModel: String
    public let currentProvider: String
    public let providers: [TelegramModelProviderChoice]

    public init(
        surface: String,
        currentModel: String,
        currentProvider: String,
        providers: [TelegramModelProviderChoice]
    ) {
        self.surface = surface
        self.currentModel = currentModel
        self.currentProvider = currentProvider
        self.providers = providers
    }

    /// Only the bound provider's published model describes its capabilities.
    public var catalogIssues: String {
        providers.compactMap { $0.catalogIssue }.joined(separator: "\n")
    }

    public var currentCapabilities: (reasoningEfforts: [String]?, supportsFast: Bool?) {
        get throws {
            guard let provider = providers.first(where: { Self.providerIDsMatch($0.id, currentProvider) }) else {
                throw ProviderRoutingError.configurationFailed("The selected provider is unavailable. Read Providers.")
            }
            if let issue = provider.catalogIssue { throw ProviderRoutingError.configurationFailed(issue) }
            guard let model = provider.models.first(where: { $0.id == currentModel }) else {
                throw ProviderRoutingError.configurationFailed("The selected model is absent from its checked catalog. Refresh models in Providers.")
            }
            return (model.supportedReasoningEfforts, model.supportsFast)
        }
    }

    public static func providerIDsMatch(_ lhs: String, _ rhs: String) -> Bool {
        lhs == rhs
    }

}

public struct TelegramModelProviderChoice: Sendable, Equatable {
    public let id: String
    public let displayName: String
    public let isCurrent: Bool
    public let models: [TelegramModelChoice]
    public let catalogIssue: String?

    public init(
        id: String,
        displayName: String,
        isCurrent: Bool = false,
        models: [TelegramModelChoice],
        catalogIssue: String? = nil
    ) {
        self.id = id
        self.displayName = displayName
        self.isCurrent = isCurrent
        self.models = models
        self.catalogIssue = catalogIssue
    }
}

public struct TelegramModelChoice: Sendable, Equatable {
    public let id: String
    public let name: String
    public let isCurrent: Bool
    public let supportedReasoningEfforts: [String]?
    public let supportsFast: Bool?

    public init(
        id: String,
        name: String,
        isCurrent: Bool = false,
        supportedReasoningEfforts: [String]?,
        supportsFast: Bool?
    ) {
        self.id = id
        self.name = name
        self.isCurrent = isCurrent
        self.supportedReasoningEfforts = supportedReasoningEfforts
        self.supportsFast = supportsFast
    }
}

extension SwiftNativeTelegramBot {
    public func telegramModelMenuForSurface(_ surface: String = "telegram") async throws -> TelegramModelMenu {
        guard let routing = completenessDeps?.routing else { throw TelegramBotError.notConfigured }
        return try await routing.modelMenuForSurface(surface)
    }

    /// Current model in plain words; unavailable routing preserves its cause.
    public func telegramPlainModelPhrase(_ surface: String = "telegram") async throws -> String {
        let menu = try await telegramModelMenuForSurface(surface)
        var name = menu.currentModel
        for provider in menu.providers where TelegramModelMenu.providerIDsMatch(provider.id, menu.currentProvider) {
            for model in provider.models where model.id.caseInsensitiveCompare(menu.currentModel) == .orderedSame {
                let trimmed = model.name.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { name = trimmed }
            }
        }
        return TurnSecretRedactor.redactText("\(name) via \(menu.currentProvider)")
    }

    public func saveTelegramModelSelection(
        surface: String = "telegram",
        provider: String?,
        model: String,
        turn: Turn
    ) async throws {
        guard let routing = completenessDeps?.routing else {
            throw TelegramBotError.notConfigured
        }
        try await routing.saveModelSelection(surface: surface, provider: provider, model: model, turn: turn)
    }
}
