import Foundation
// Blueprint: | `TelegramBot+Settings.swift` | Mobile operation prerequisites delegate saved field validation to `TelegramConfig.validateSavedConfiguration` |

/// A Telegram settings mutation was rejected before it could make the saved
/// inbound authorization narrower, wider, or unreadable by accident. Keeping
/// this distinct from transport errors lets a mounted settings surface report
/// a configuration failure without claiming that its save took effect.
public enum TelegramConfigurationError: Error, Equatable, LocalizedError, Sendable {
    case invalidAllowedChatID(String)
    case invalidAllowedUserID(String)
    case existingConfigurationUnreadable
    case persistenceFailed(String)
    case destinationRequired

    public var errorDescription: String? {
        switch self {
        case .invalidAllowedChatID(let value):
            return "telegram_chat_id_invalid: Allowed chat ID '\(value)' is not numeric. Use Check sender in Telegram setup and enter that chat ID."
        case .invalidAllowedUserID(let value):
            return "telegram_user_id_invalid: Allowed user ID '\(value)' is not numeric. Use Check sender in Telegram setup and enter that user ID."
        case .existingConfigurationUnreadable:
            return "telegram_settings_unreadable: Saved settings cannot be read and were not overwritten. Repair telegram/config.json before saving in Telegram setup."
        case .persistenceFailed(let detail):
            return "telegram_settings_save_failed: \(detail). Inspect telegram/config.json and its directory access before saving in Telegram setup."
        case .destinationRequired:
            return "telegram_destination_required: No allowed chat or user ID is set. Message your bot, then use Check sender in Telegram setup and add that ID."
        }
    }
}

public struct TelegramNumericIDParseResult: Equatable {
    public let canonicalIDs: [String]
    public let invalidTokens: [String]
}

public func parseTelegramNumericIDs(_ value: String) -> TelegramNumericIDParseResult {
    let tokens = value
        .split { $0 == "," || $0 == " " || $0 == "\n" || $0 == "\t" }
        .map(String.init)
        .filter { !$0.isEmpty }
    var valid: [String] = []
    var invalid: [String] = []
    for token in tokens {
        if let id = Int64(token) {
            valid.append(String(id))
        } else {
            invalid.append(token)
        }
    }
    return TelegramNumericIDParseResult(
        canonicalIDs: Array(Set(valid)).sorted(),
        invalidTokens: invalid
    )
}

extension TelegramConfig {
    public static func validateMobileConfiguration(at root: URL) throws {
        do {
            _ = try TelegramConfig.loadSavedConfiguration(dataRoot: root)
        } catch { throw TelegramConfigurationError.existingConfigurationUnreadable }
    }

}
