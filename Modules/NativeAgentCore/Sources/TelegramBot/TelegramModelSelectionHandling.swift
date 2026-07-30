import Foundation
import NativeAgentCore
import PersistenceCore

public enum TelegramModelSelectionAction: Sendable, Equatable {
    case providers
    case provider(index: Int)
    case model(providerIndex: Int, modelIndex: Int)
}

public struct TelegramModelSelectionCallback: Sendable, Equatable {
    public let callbackId: String
    public let action: TelegramModelSelectionAction
    public let chatId: Int
    public let messageId: Int
    public let fromUserId: Int?

    public init?(_ raw: JSONValue) {
        guard case .object(let obj) = raw,
              case .string(let callbackId)? = obj["id"],
              case .string(let data)? = obj["data"],
              let action = Self.parseAction(data) else {
            return nil
        }
        let fromUserId: Int? = {
            guard case .object(let from)? = obj["from"] else { return nil }
            return Self.int(from["id"])
        }()
        let message: [String: JSONValue]? = {
            guard case .object(let message)? = obj["message"] else { return nil }
            return message
        }()
        let chatId: Int? = {
            guard case .object(let chat)? = message?["chat"] else { return nil }
            return Self.int(chat["id"])
        }()
        let messageId = Self.int(message?["message_id"]) ?? Self.int(message?["messageId"])
        guard let chatId, let messageId else { return nil }

        self.callbackId = callbackId
        self.action = action
        self.chatId = chatId
        self.messageId = messageId
        self.fromUserId = fromUserId
    }

    public static func providerData(index: Int) -> String {
        "na_model:p:\(index)"
    }

    public static func modelData(providerIndex: Int, modelIndex: Int) -> String {
        "na_model:m:\(providerIndex):\(modelIndex)"
    }

    public static var providersData: String {
        "na_model:providers"
    }

    private static func parseAction(_ raw: String) -> TelegramModelSelectionAction? {
        let parts = raw.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        guard parts.first == "na_model" else { return nil }
        if parts.count == 2, parts[1] == "providers" {
            return .providers
        }
        if parts.count == 3, parts[1] == "p", let index = Int(parts[2]), index >= 0 {
            return .provider(index: index)
        }
        if parts.count == 4,
           parts[1] == "m",
           let providerIndex = Int(parts[2]),
           let modelIndex = Int(parts[3]),
           providerIndex >= 0,
           modelIndex >= 0 {
            return .model(providerIndex: providerIndex, modelIndex: modelIndex)
        }
        return nil
    }

    private static func int(_ value: JSONValue?) -> Int? {
        switch value {
        case .int(let i)?: return Int(i)
        case .double(let d)?: return Int(d)
        case .string(let s)?: return Int(s)
        default: return nil
        }
    }
}

enum TelegramModelSelectionUI {
    static func providerText(menu: TelegramModelMenu) -> String {
        """
        Telegram model
        Current: \(modelLabel(id: menu.currentModel, name: nil))
        Provider: \(currentProviderDisplayName(menu: menu)) (\(menu.currentProvider))

        Choose a provider:
        """
    }

    static func providerReplyMarkup(menu: TelegramModelMenu) -> JSONValue {
        let rows = menu.providers.enumerated().map { index, provider -> JSONValue in
            .array([
                .object([
                    "text": .string(providerButtonTitle(provider)),
                    "callback_data": .string(TelegramModelSelectionCallback.providerData(index: index)),
                ]),
            ])
        }
        return .object(["inline_keyboard": .array(rows)])
    }

    static func modelText(menu: TelegramModelMenu, providerIndex: Int) -> String? {
        guard providerIndex >= 0, providerIndex < menu.providers.count else { return nil }
        let provider = menu.providers[providerIndex]
        return """
        Telegram model
        Provider: \(provider.displayName) (\(provider.id))
        Current: \(modelLabel(id: menu.currentModel, name: currentModelName(menu: menu)))

        Choose a model:
        """
    }

    static func modelReplyMarkup(
        menu: TelegramModelMenu,
        providerIndex: Int,
        maxModels: Int = 40
    ) -> JSONValue? {
        guard providerIndex >= 0, providerIndex < menu.providers.count else { return nil }
        let provider = menu.providers[providerIndex]
        var rows: [JSONValue] = provider.models.prefix(maxModels).enumerated().map { modelIndex, model in
            .array([
                .object([
                    "text": .string(modelButtonTitle(model)),
                    "callback_data": .string(TelegramModelSelectionCallback.modelData(
                        providerIndex: providerIndex,
                        modelIndex: modelIndex
                    )),
                ]),
            ])
        }
        rows.append(.array([
            .object([
                "text": .string("Back to providers"),
                "callback_data": .string(TelegramModelSelectionCallback.providersData),
            ]),
        ]))
        return .object(["inline_keyboard": .array(rows)])
    }

    static func selectedText(provider: TelegramModelProviderChoice, model: TelegramModelChoice) -> String {
        """
        Telegram model set
        Provider: \(provider.displayName) (\(provider.id))
        Model: \(modelLabel(id: model.id, name: model.name))

        Providers tab will reflect this under Telegram.
        """
    }

    static func selectedReplyMarkup(providerIndex: Int) -> JSONValue {
        .object([
            "inline_keyboard": .array([
                .array([
                    .object([
                        "text": .string("Choose another model"),
                        "callback_data": .string(TelegramModelSelectionCallback.providerData(index: providerIndex)),
                    ]),
                ]),
                .array([
                    .object([
                        "text": .string("Change provider"),
                        "callback_data": .string(TelegramModelSelectionCallback.providersData),
                    ]),
                ]),
            ]),
        ])
    }

    static func modelLabel(id: String, name: String?) -> String {
        let trimmedId = id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let name else { return trimmedId }
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty, trimmedName != trimmedId else { return trimmedId }
        return "\(trimmedName) [\(trimmedId)]"
    }

    private static func providerButtonTitle(_ provider: TelegramModelProviderChoice) -> String {
        provider.displayName + (provider.isCurrent ? " (current)" : "")
    }

    private static func modelButtonTitle(_ model: TelegramModelChoice) -> String {
        let title: String
        if model.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            title = model.id
        } else {
            title = model.name
        }
        return title + (model.isCurrent ? " (current)" : "")
    }

    private static func currentProviderDisplayName(menu: TelegramModelMenu) -> String {
        menu.providers.first { providerIdsMatch($0.id, menu.currentProvider) }?.displayName
            ?? menu.currentProvider
    }

    private static func currentModelName(menu: TelegramModelMenu) -> String? {
        for provider in menu.providers {
            if let model = provider.models.first(where: { $0.id == menu.currentModel }) {
                return model.name
            }
        }
        return nil
    }

    private static func providerIdsMatch(_ lhs: String, _ rhs: String) -> Bool {
        normalizeProviderId(lhs) == normalizeProviderId(rhs)
    }

    private static func normalizeProviderId(_ raw: String) -> String {
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
}
