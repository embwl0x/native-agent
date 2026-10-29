import Foundation
import NativeAgentShared
import ProviderRouting
import NativeAgentCore
import ChatToolRuntime
import MemoryV2
import DeviceSync
import NotificationInbox
import PersistenceCore

// Blueprint: | `TelegramModelSelection.swift` | Account-scoped provider/model selection, capability lookup, menu values and bot-facing model access |

public struct TelegramProviderRoutingBridge: Sendable {
    let routing: SwiftNativeProviderRouting

    public init(routing: SwiftNativeProviderRouting) {
        self.routing = routing
    }

    public func saveModelConfig(surface: String, key: String, value: String) async throws {
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

    public func saveModelSelection(surface: String, provider: String?, model: String) async throws {
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

    public func modelMenuForSurface(_ surface: String) async -> TelegramModelMenu? {
        guard let snapshot = try? await routing.checkedRoutingSnapshot(),
              let preference = snapshot.preferences[surface] else {
            return nil
        }
        let current = (
            model: preference.model,
            provider: snapshot.activeProviders[surface]
                ?? routing.inferProviderForModel(preference.model)
                ?? "unknown"
        )
        let currentProvider = current.provider
        let providers = try? await routing.listProviders()
        let choices = providers.map { providers in providers
            .filter { Self.isSelectableProvider($0, currentProvider: currentProvider) }
            .map { provider in
                let isCurrent = TelegramModelMenu.providerIDsMatch(provider.id, currentProvider)
                var models = Self.modelChoices(
                    from: provider,
                    currentModel: current.model,
                    isCurrentProvider: isCurrent
                )
                if isCurrent,
                   !models.contains(where: { $0.id == current.model }) {
                    let descriptor = FirstPartyModelCatalog.descriptor(
                        for: current.model,
                        providerID: provider.id
                    )
                    models.insert(
                        TelegramModelChoice(
                            id: current.model,
                            name: current.model,
                            isCurrent: true,
                            supportedReasoningEfforts: descriptor?.supportedReasoningEfforts ?? [],
                            supportsFast: descriptor?.supportsFast ?? false
                        ),
                        at: 0
                    )
                }
                return TelegramModelProviderChoice(
                    id: provider.id,
                    displayName: provider.displayName ?? Self.displayName(for: provider.id),
                    isCurrent: isCurrent,
                    models: models
                )
            }
            .filter { !$0.models.isEmpty }
        }

        return TelegramModelMenu(
            surface: surface,
            currentModel: current.model,
            currentProvider: currentProvider,
            providers: choices
        )
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

    private static func modelChoices(
        from provider: Provider,
        currentModel: String,
        isCurrentProvider: Bool
    ) -> [TelegramModelChoice] {
        var out: [TelegramModelChoice] = []
        var seen: Set<String> = []
        for object in modelObjects(from: provider) {
            guard let id = firstString(object, keys: ["id", "model_id", "model"]),
                  !id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                continue
            }
            let name = firstString(object, keys: ["name", "display_name", "displayName"]) ?? id
            if seen.insert(id).inserted {
                out.append(TelegramModelChoice(
                    id: id,
                    name: name,
                    isCurrent: isCurrentProvider && id == currentModel,
                    supportedReasoningEfforts: stringArray(
                        object,
                        keys: ["supported_reasoning_efforts", "supportedReasoningEfforts"]
                    ),
                    supportsFast: firstBool(
                        object,
                        keys: ["supports_fast", "supportsFast"]
                    ) ?? false
                ))
            }
        }
        return out
    }

    private static func modelObjects(from provider: Provider) -> [[String: JSONValue]] {
        guard case .array(let items)? = provider.modelCatalog else { return [] }
        return items.compactMap { item in
            guard case .object(let obj) = item else { return nil }
            return obj
        }
    }

    private static func firstString(
        _ object: [String: JSONValue],
        keys: [String]
    ) -> String? {
        for key in keys {
            guard let value = object[key] else { continue }
            switch value {
            case .string(let str):
                let trimmed = str.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { return trimmed }
            case .int(let int):
                return String(int)
            case .double(let double):
                return String(double)
            case .bool(let bool):
                return bool ? "true" : "false"
            case .null, .array, .object:
                continue
            }
        }
        return nil
    }

    private static func stringArray(
        _ object: [String: JSONValue],
        keys: [String]
    ) -> [String] {
        for key in keys {
            guard case .array(let values)? = object[key] else { continue }
            return values.compactMap { value in
                guard case .string(let string) = value else { return nil }
                return string
            }
        }
        return []
    }

    private static func firstBool(
        _ object: [String: JSONValue],
        keys: [String]
    ) -> Bool? {
        for key in keys {
            guard case .bool(let value)? = object[key] else { continue }
            return value
        }
        return nil
    }

    private static func displayName(for providerId: String) -> String {
        switch TelegramModelMenu.normalizedProviderID(providerId) {
        case "anthropic": return "Anthropic"
        case "openai": return "ChatGPT / OpenAI"
        case "codex": return "Codex CLI"
        case "xai": return "xAI Grok"
        case "moonshot": return "Moonshot AI (Kimi)"
        case "openrouter": return "OpenRouter"
        default: return providerId.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }

}

public struct TelegramModelMenu: Sendable, Equatable {
    public let surface: String
    public let currentModel: String
    public let currentProvider: String
    /// Nil means the provider catalog is unavailable; selection is still checked.
    public let providers: [TelegramModelProviderChoice]?

    public init(
        surface: String,
        currentModel: String,
        currentProvider: String,
        providers: [TelegramModelProviderChoice]?
    ) {
        self.surface = surface
        self.currentModel = currentModel
        self.currentProvider = currentProvider
        self.providers = providers
    }

    /// Catalog unavailability does not erase the checked current selection.
    public var currentCapabilities: (reasoningEfforts: [String], supportsFast: Bool)? {
        if let provider = providers?.first(where: {
               TelegramModelMenu.providerIDsMatch($0.id, currentProvider)
           }),
           let model = provider.models.first(where: {
               $0.id.caseInsensitiveCompare(currentModel) == .orderedSame
           }),
           !model.supportedReasoningEfforts.isEmpty || model.supportsFast {
            return (model.supportedReasoningEfforts, model.supportsFast)
        }
        guard let descriptor = FirstPartyModelCatalog.descriptor(
            for: currentModel,
            providerID: currentProvider
        ) else { return nil }
        return (descriptor.supportedReasoningEfforts, descriptor.supportsFast)
    }

    public static func providerIDsMatch(_ lhs: String, _ rhs: String) -> Bool {
        normalizedProviderID(lhs) == normalizedProviderID(rhs)
    }

    public static func normalizedProviderID(_ raw: String) -> String {
        switch raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "xai", "xai_oauth_direct", "xai-oauth", "grok-oauth", "x-ai-oauth", "xai-grok-oauth":
            return "xai_oauth_direct"
        case "moonshot", "kimi":
            return "moonshot"
        default:
            return raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        }
    }

}

public struct TelegramModelProviderChoice: Sendable, Equatable {
    public let id: String
    public let displayName: String
    public let isCurrent: Bool
    public let models: [TelegramModelChoice]

    public init(
        id: String,
        displayName: String,
        isCurrent: Bool = false,
        models: [TelegramModelChoice]
    ) {
        self.id = id
        self.displayName = displayName
        self.isCurrent = isCurrent
        self.models = models
    }
}

public struct TelegramModelChoice: Sendable, Equatable {
    public let id: String
    public let name: String
    public let isCurrent: Bool
    public let supportedReasoningEfforts: [String]
    public let supportsFast: Bool

    public init(
        id: String,
        name: String,
        isCurrent: Bool = false,
        supportedReasoningEfforts: [String] = [],
        supportsFast: Bool = false
    ) {
        self.id = id
        self.name = name
        self.isCurrent = isCurrent
        self.supportedReasoningEfforts = supportedReasoningEfforts
        self.supportsFast = supportsFast
    }
}

extension SwiftNativeTelegramBot {
    public func telegramModelMenuForSurface(_ surface: String = "telegram") async -> TelegramModelMenu? {
        await completenessDeps?.routing?.modelMenuForSurface(surface)
    }

    /// Current model in plain words, or nil when routing is unavailable.
    public func telegramPlainModelPhrase(_ surface: String = "telegram") async -> String? {
        guard let menu = await completenessDeps?.routing?.modelMenuForSurface(surface) else { return nil }
        var name = menu.currentModel
        for provider in menu.providers ?? [] where TelegramModelMenu.providerIDsMatch(provider.id, menu.currentProvider) {
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
        model: String
    ) async throws {
        guard let routing = completenessDeps?.routing else {
            throw TelegramBotError.notConfigured
        }
        try await routing.saveModelSelection(surface: surface, provider: provider, model: model)
    }
}
