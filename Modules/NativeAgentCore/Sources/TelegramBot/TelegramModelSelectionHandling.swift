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
        guard let payload = TelegramCallbackPayload(raw, parseData: Self.parseAction) else { return nil }
        callbackId = payload.callbackId
        action = payload.command
        chatId = payload.chatId
        messageId = payload.messageId
        fromUserId = payload.fromUserId
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
