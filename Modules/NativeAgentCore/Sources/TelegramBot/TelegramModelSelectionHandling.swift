import Foundation
import CryptoKit
import NativeAgentCore
import PersistenceCore

public enum TelegramModelSelectionAction: Sendable, Equatable {
    case providers
    case provider(key: String)
    case model(providerKey: String, modelKey: String)
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
            return TelegramCallbackNumbers.int(from["id"])
        }()
        let message: [String: JSONValue]? = {
            guard case .object(let message)? = obj["message"] else { return nil }
            return message
        }()
        let chatId: Int? = {
            guard case .object(let chat)? = message?["chat"] else { return nil }
            return TelegramCallbackNumbers.int(chat["id"])
        }()
        let messageId = TelegramCallbackNumbers.int(message?["message_id"]) ?? TelegramCallbackNumbers.int(message?["messageId"])
        guard let chatId, let messageId else { return nil }

        self.callbackId = callbackId
        self.action = action
        self.chatId = chatId
        self.messageId = messageId
        self.fromUserId = fromUserId
    }

    public static func selectionKey(_ identity: String) -> String {
        SHA256.hash(data: Data(identity.utf8)).prefix(12).map { String(format: "%02x", $0) }.joined()
    }

    public static func providerData(id: String) -> String {
        "na_model:p:\(selectionKey(id))"
    }

    public static func modelData(providerId: String, modelId: String) -> String {
        "na_model:m:\(selectionKey(providerId)):\(selectionKey(modelId))"
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
        if parts.count == 3, parts[1] == "p", isSelectionKey(parts[2]) {
            return .provider(key: parts[2])
        }
        if parts.count == 4,
           parts[1] == "m",
           isSelectionKey(parts[2]), isSelectionKey(parts[3]) {
            return .model(providerKey: parts[2], modelKey: parts[3])
        }
        return nil
    }

    private static func isSelectionKey(_ value: String) -> Bool {
        value.count == 24 && value.allSatisfy { "0123456789abcdef".contains($0) }
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
        let rows = menu.providers.map { provider -> JSONValue in
            .array([
                .object([
                    "text": .string(providerButtonTitle(provider)),
                    "callback_data": .string(TelegramModelSelectionCallback.providerData(id: provider.id)),
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
        var rows: [JSONValue] = provider.models.prefix(maxModels).map { model in
            .array([
                .object([
                    "text": .string(modelButtonTitle(model)),
                    "callback_data": .string(TelegramModelSelectionCallback.modelData(
                        providerId: provider.id,
                        modelId: model.id
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
        Chat model set
        Provider: \(provider.displayName) (\(provider.id))
        Model: \(modelLabel(id: model.id, name: model.name))

        Providers → Chat now uses this model for Mac, iPhone, Telegram, and Slack.
        """
    }

    static func selectedReplyMarkup(providerId: String) -> JSONValue {
        .object([
            "inline_keyboard": .array([
                .array([
                    .object([
                        "text": .string("Choose another model"),
                        "callback_data": .string(TelegramModelSelectionCallback.providerData(id: providerId)),
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
        ProviderFamilyIdentity.normalize(raw)
    }
}
