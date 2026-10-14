import Foundation
import CoreFoundation

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
            return "Telegram allowed chat ID is not numeric: \(value)"
        case .invalidAllowedUserID(let value):
            return "Telegram allowed user ID is not numeric: \(value)"
        case .existingConfigurationUnreadable:
            return "saved Telegram settings are unreadable; refusing to overwrite them"
        case .persistenceFailed(let detail):
            return "Telegram settings could not be saved: \(detail)"
        case .destinationRequired:
            return "Add an allowed chat or user ID before turning Telegram on. Send your bot a message, then use Check sender in Telegram setup to find your ID."
        }
    }
}

public struct TelegramNumericIDParseResult: Equatable {
    public let canonicalIDs: [String]
    public let invalidTokens: [String]

    public var isConfigured: Bool { !canonicalIDs.isEmpty }
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
        let url = root
            .appendingPathComponent("telegram", isDirectory: true)
            .appendingPathComponent("config.json")
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            guard attributes[.type] as? FileAttributeType == .typeRegular else {
                throw TelegramConfigurationError.existingConfigurationUnreadable
            }
        } catch CocoaError.fileReadNoSuchFile { return }
        catch { throw TelegramConfigurationError.existingConfigurationUnreadable }
        try TelegramConfig.validateSavedConfiguration(dataRoot: root)
        guard TelegramConfig.loadFromDisk(dataRoot: root, includeDisconnected: true) != nil else {
            throw TelegramConfigurationError.existingConfigurationUnreadable
        }
        guard let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data),
              let fields = object as? [String: Any]
        else {
            throw TelegramConfigurationError.existingConfigurationUnreadable
        }
        for key in ["enabled", "require_mention", "voice_transcription_enabled", "voice_enabled"] {
            // Missing fields retain legacy defaults; present authority must
            // be a JSON boolean, never a coerced number or decoder fallback.
            guard let raw = fields[key] else { continue }
            guard let value = raw as? NSNumber,
                  CFGetTypeID(value) == CFBooleanGetTypeID() else {
                throw TelegramConfigurationError.existingConfigurationUnreadable
            }
        }
        // Validate every spelling the codec consumes, even when a canonical
        // spelling shadows it. A fallback must never erase damaged settings.
        for key in ["bot_token", "token", "model", "reasoning_effort", "reasoningEffort",
                    "voice_transcription_backend", "voice_backend", "voice_transcription_model", "voice_model"] {
            if let value = fields[key], !(value is String) {
                throw TelegramConfigurationError.existingConfigurationUnreadable
            }
        }
        for key in ["voice_max_bytes", "voice_max_mb"] {
            guard let value = fields[key] else { continue }
            if key == "voice_max_bytes" {
                if let number = value as? NSNumber,
                   CFGetTypeID(number) != CFBooleanGetTypeID(),
                   number.int64Value > 0,
                   number.compare(NSNumber(value: number.int64Value)) == .orderedSame { continue }
                if let string = value as? String, let bytes = Int(string), bytes > 0 { continue }
            } else {
                let megabytes: Double?
                if let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() {
                    megabytes = number.doubleValue
                } else if let string = value as? String {
                    megabytes = Double(string)
                } else { megabytes = nil }
                if let megabytes, megabytes.isFinite,
                   let bytes = Int(exactly: (megabytes * 1024 * 1024).rounded(.towardZero)), bytes > 0 { continue }
            }
            throw TelegramConfigurationError.existingConfigurationUnreadable
        }
        for key in ["allowed_chat_ids", "allowed_user_ids"] {
            // Missing lists are valid legacy deny-all defaults; present lists
            // must decode completely before any setting can be rewritten.
            guard let raw = fields[key] else { continue }
            guard let values = raw as? [Any] else {
                throw TelegramConfigurationError.existingConfigurationUnreadable
            }
            for value in values {
                if let number = value as? NSNumber,
                   CFGetTypeID(number) != CFBooleanGetTypeID(),
                   number.compare(NSNumber(value: number.int64Value)) == .orderedSame {
                    continue
                }
                if let string = value as? String, Int64(string) != nil { continue }
                throw TelegramConfigurationError.existingConfigurationUnreadable
            }
        }
    }

}
