import Foundation
import CryptoKit
import NativeAgentCore
import PersistenceCore

// Blueprint: | `TelegramModelSelectionHandling.swift` | `TelegramModelSelectionCallback`: provider/model selection callback encoding, key validation and action parsing |

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
