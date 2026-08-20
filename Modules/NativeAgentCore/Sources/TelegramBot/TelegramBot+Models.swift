import Foundation
import NativeAgentCore
import PersistenceCore
import BackgroundLoops
import ProviderRouting

// MARK: - TelegramStatus

public struct TelegramStatus: Sendable, Codable, Equatable {
    public var enabled: Bool?
    public var tokenConfigured: Bool?
    public var pollerEnabled: Bool?
    public var lastSeenUpdateId: Int?
    public var lastSeenAt: String?
    public var lastReplyAt: String?
    public var lastError: String?
    public var extras: JSONValue?

    public init(
        enabled: Bool? = nil,
        tokenConfigured: Bool? = nil,
        pollerEnabled: Bool? = nil,
        lastSeenUpdateId: Int? = nil,
        lastSeenAt: String? = nil,
        lastReplyAt: String? = nil,
        lastError: String? = nil,
        extras: JSONValue? = nil
    ) {
        self.enabled = enabled
        self.tokenConfigured = tokenConfigured
        self.pollerEnabled = pollerEnabled
        self.lastSeenUpdateId = lastSeenUpdateId
        self.lastSeenAt = lastSeenAt
        self.lastReplyAt = lastReplyAt
        self.lastError = lastError
        self.extras = extras
    }

    private static let knownKeys: Set<String> = [
        "enabled", "tokenConfigured", "pollerEnabled",
        "lastSeenUpdateId", "lastSeenAt", "lastReplyAt", "lastError",
        "extras",
    ]

    private struct AnyKey: CodingKey, Hashable {
        var stringValue: String
        var intValue: Int? { nil }
        init(_ s: String) { self.stringValue = s }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { return nil }
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyKey.self)
        func bool(_ k: String) throws -> Bool? {
            guard let key = AnyKey(stringValue: k) else { return nil }
            return try c.decodeIfPresent(Bool.self, forKey: key)
        }
        func str(_ k: String) throws -> String? {
            guard let key = AnyKey(stringValue: k) else { return nil }
            return try c.decodeIfPresent(String.self, forKey: key)
        }
        func int(_ k: String) throws -> Int? {
            guard let key = AnyKey(stringValue: k) else { return nil }
            return try c.decodeIfPresent(Int.self, forKey: key)
        }
        func jv(_ k: String) throws -> JSONValue? {
            guard let key = AnyKey(stringValue: k) else { return nil }
            return try c.decodeIfPresent(JSONValue.self, forKey: key)
        }
        self.enabled = try bool("enabled")
        self.tokenConfigured = try bool("tokenConfigured")
        self.pollerEnabled = try bool("pollerEnabled")
        self.lastSeenUpdateId = try int("lastSeenUpdateId")
        self.lastSeenAt = try str("lastSeenAt")
        self.lastReplyAt = try str("lastReplyAt")
        self.lastError = try str("lastError")

        var unknown: [String: JSONValue] = [:]
        for key in c.allKeys where !Self.knownKeys.contains(key.stringValue) {
            if let v = try? c.decode(JSONValue.self, forKey: key) {
                unknown[key.stringValue] = v
            }
        }
        if let explicit = try jv("extras") {
            if case .object(let obj) = explicit {
                for (k, v) in obj { unknown[k] = v }
            } else {
                unknown["_extras_value"] = explicit
            }
        }
        self.extras = unknown.isEmpty ? nil : .object(unknown)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: AnyKey.self)
        try c.encodeIfPresent(enabled, forKey: AnyKey("enabled"))
        try c.encodeIfPresent(tokenConfigured, forKey: AnyKey("tokenConfigured"))
        try c.encodeIfPresent(pollerEnabled, forKey: AnyKey("pollerEnabled"))
        try c.encodeIfPresent(lastSeenUpdateId, forKey: AnyKey("lastSeenUpdateId"))
        try c.encodeIfPresent(lastSeenAt, forKey: AnyKey("lastSeenAt"))
        try c.encodeIfPresent(lastReplyAt, forKey: AnyKey("lastReplyAt"))
        try c.encodeIfPresent(lastError, forKey: AnyKey("lastError"))
        if case .object(let obj)? = extras {
            for (k, v) in obj where !Self.knownKeys.contains(k) {
                try c.encode(v, forKey: AnyKey(k))
            }
        }
    }
}

// MARK: - TelegramTestResult

/// Body of POST /v1/telegram/test. The native Bot API call returns
/// {ok, chatId, messageId, receipt}-style data; preserve verbatim.
public struct TelegramTestResult: Sendable, Codable, Equatable {
    public var rawResponse: JSONValue
    public init(rawResponse: JSONValue) { self.rawResponse = rawResponse }

    enum CodingKeys: String, CodingKey { case rawResponse = "raw_response" }
}

// MARK: - Errors

/// Telegram's structured rate-limit / migration hints. Callers can retain
/// these instead of scraping a human-readable error string.
public struct TelegramAPIResponseParameters: Sendable, Codable, Equatable {
    public let retryAfter: Int?
    public let migrateToChatId: Int64?

    public init(retryAfter: Int? = nil, migrateToChatId: Int64? = nil) {
        self.retryAfter = retryAfter
        self.migrateToChatId = migrateToChatId
    }

    enum CodingKeys: String, CodingKey {
        case retryAfter = "retry_after"
        case migrateToChatId = "migrate_to_chat_id"
    }
}

/// The common Telegram Bot API response envelope. `result` stays as a typed
/// JSON value until the transport validates it for the method being called.
public struct TelegramAPIResponse: Sendable, Codable, Equatable {
    public let ok: Bool
    public let result: JSONValue?
    public let description: String?
    public let errorCode: Int?
    public let parameters: TelegramAPIResponseParameters?

    enum CodingKeys: String, CodingKey {
        case ok, result, description, parameters
        case errorCode = "error_code"
    }
}

public struct TelegramAPIMessageResult: Sendable, Codable, Equatable {
    public let messageId: Int

    enum CodingKeys: String, CodingKey {
        case messageId = "message_id"
    }
}

/// A semantic Telegram transport failure. The typed fields preserve retry and
/// migration information while the description is sanitized before exposure.
public struct TelegramAPIFailure: Error, LocalizedError, Sendable, Equatable {
    public enum Kind: String, Sendable, Codable, Equatable {
        case httpStatus
        case rejected
        case malformedResponse
        case malformedResult
    }

    public let kind: Kind
    public let operation: String
    public let httpStatus: Int?
    public let errorCode: Int?
    public let telegramDescription: String?
    public let parameters: TelegramAPIResponseParameters?

    public init(
        kind: Kind,
        operation: String,
        httpStatus: Int? = nil,
        errorCode: Int? = nil,
        telegramDescription: String? = nil,
        parameters: TelegramAPIResponseParameters? = nil
    ) {
        self.kind = kind
        self.operation = operation
        self.httpStatus = httpStatus
        self.errorCode = errorCode
        self.telegramDescription = telegramDescription
        self.parameters = parameters
    }

    public var errorDescription: String? {
        var detail = "telegram: \(operation) \(kind.rawValue)"
        if let httpStatus { detail += " (HTTP \(httpStatus))" }
        if let errorCode { detail += " [Telegram \(errorCode)]" }
        if let telegramDescription, !telegramDescription.isEmpty {
            detail += ": \(telegramDescription)"
        }
        return detail
    }
}

public enum TelegramBotError: Error, LocalizedError {
    case invalidRequest
    case notConfigured
    case invalidResponse(status: Int)
    case unavailable
    case underlying(String)

    public var errorDescription: String? {
        switch self {
        case .invalidRequest: return "telegram: invalid request"
        case .notConfigured: return "telegram: bot token / chat not configured"
        case .invalidResponse(let s): return "telegram: native transport returned unexpected status \(s)"
        case .unavailable: return "telegram: unavailable"
        case .underlying(let m): return "telegram: \(m)"
        }
    }
}

// MARK: - Protocol

public protocol TelegramBotProtocol: Sendable {
    func getStatus() async throws -> TelegramStatus
    /// Send a test reply. `chatId`, when supplied, targets a specific chat
    /// (legacy body key `chat_id`); when nil the native path falls back to the
    /// configured default chat. Defaulted so existing callers compile unchanged.
    func sendTestMessage(message: String?, chatId: String?) async throws -> TelegramTestResult
    func clearLogs() async throws
}

public extension TelegramBotProtocol {
    /// Back-compat overload — preserves the pre-wave-30 `sendTestMessage(message:)`
    /// call shape (no chat targeting).
    func sendTestMessage(message: String?) async throws -> TelegramTestResult {
        try await sendTestMessage(message: message, chatId: nil)
    }
}


// MARK: - TelegramMessage / TelegramUpdate / TelegramPollResult

private struct _TGAnyKey: CodingKey, Hashable {
    var stringValue: String
    var intValue: Int? { nil }
    init(_ s: String) { self.stringValue = s }
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { return nil }
}

private func _tgExtractInt(_ obj: [String: JSONValue]?, _ key: String) -> Int? {
    guard let obj = obj, let v = obj[key] else { return nil }
    switch v {
    case .int(let i): return Int(i)
    case .double(let d): return Int(d)
    default: return nil
    }
}

private func _tgExtractBool(_ obj: [String: JSONValue]?, _ key: String) -> Bool? {
    guard let obj = obj, let v = obj[key] else { return nil }
    switch v {
    case .bool(let b): return b
    default: return nil
    }
}

func _tgJSONInt(_ value: JSONValue?) -> Int? {
    switch value {
    case .some(.int(let i)): return Int(i)
    case .some(.double(let d)): return Int(d)
    case .some(.string(let s)): return Int(s)
    default: return nil
    }
}

func _tgJSONString(_ value: JSONValue?) -> String? {
    guard case .string(let s)? = value else { return nil }
    return s
}

func _tgNowString(_ date: Date = Date()) -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter.string(from: date)
}

func _tgPreview(_ text: String?, limit: Int = 240) -> String? {
    guard let text else { return nil }
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }
    if trimmed.count <= limit { return trimmed }
    return String(trimmed.prefix(limit)) + "..."
}

public struct TelegramReplyContext: Sendable, Codable, Equatable {
    public var messageId: Int
    public var chatId: Int?
    public var chatType: String?
    public var fromUserId: Int?
    public var fromIsBot: Bool?
    public var text: String?
    public var caption: String?
    public var date: Int?

    public init(
        messageId: Int,
        chatId: Int? = nil,
        chatType: String? = nil,
        fromUserId: Int? = nil,
        fromIsBot: Bool? = nil,
        text: String? = nil,
        caption: String? = nil,
        date: Int? = nil
    ) {
        self.messageId = messageId
        self.chatId = chatId
        self.chatType = chatType
        self.fromUserId = fromUserId
        self.fromIsBot = fromIsBot
        self.text = text
        self.caption = caption
        self.date = date
    }

    public var previewText: String? {
        let candidates = [text, caption]
        for candidate in candidates {
            let trimmed = candidate?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !trimmed.isEmpty { return trimmed }
        }
        return nil
    }

    static func fromTelegramJSON(_ value: JSONValue?) -> TelegramReplyContext? {
        guard case .object(let obj)? = value else { return nil }
        let messageId = _tgExtractInt(obj, "message_id")
            ?? _tgExtractInt(obj, "messageId")
            ?? 0
        guard messageId > 0 else { return nil }

        let chatObj: [String: JSONValue]?
        if case .object(let nested)? = obj["chat"] {
            chatObj = nested
        } else {
            chatObj = nil
        }
        let fromObj: [String: JSONValue]?
        if case .object(let nested)? = obj["from"] {
            fromObj = nested
        } else {
            fromObj = nil
        }

        return TelegramReplyContext(
            messageId: messageId,
            chatId: _tgExtractInt(chatObj, "id") ?? _tgExtractInt(obj, "chatId"),
            chatType: _tgJSONString(chatObj?["type"]) ?? _tgJSONString(obj["chatType"]),
            fromUserId: _tgExtractInt(fromObj, "id") ?? _tgExtractInt(obj, "fromUserId"),
            fromIsBot: _tgExtractBool(fromObj, "is_bot") ?? _tgExtractBool(obj, "fromIsBot"),
            text: _tgJSONString(obj["text"]),
            caption: _tgJSONString(obj["caption"]),
            date: _tgExtractInt(obj, "date")
        )
    }
}

public enum TelegramReplyPromptRenderer {
    public static func messageWithReplyContext(
        text: String,
        replyTo: TelegramReplyContext?,
        quoteLimit: Int = 900
    ) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let replyTo,
              let rawQuote = replyTo.previewText?.trimmingCharacters(in: .whitespacesAndNewlines),
              !rawQuote.isEmpty
        else { return text }

        let clippedQuote: String
        if rawQuote.count > quoteLimit {
            clippedQuote = String(rawQuote.prefix(max(0, quoteLimit))) + "..."
        } else {
            clippedQuote = rawQuote
        }
        let source = replyTo.fromIsBot == true
            ? "Telegram message from the assistant"
            : "a Telegram message"
        let userLine = trimmed.isEmpty ? "(empty message)" : trimmed
        return """
        [Telegram reply context]
        The user replied to \(source) #\(replyTo.messageId):
        "\(clippedQuote)"
        [/Telegram reply context]

        User message: \(userLine)
        """
    }
}

public struct TelegramMessage: Sendable, Codable, Equatable {
    public var messageId: Int
    public var chatId: Int
    /// Telegram `chat.type` from the wire update: "private", "group",
    /// "supergroup", or "channel". Owner-gated commands (/restart) require
    /// "private" — an allowlisted group chat must never widen who can fire
    /// them. nil for legacy/synthetic shapes that never carried it.
    public var chatType: String?
    public var fromUserId: Int?
    public var text: String?
    public var replyTo: TelegramReplyContext?
    public var date: Int
    public var extras: JSONValue?

    public init(
        messageId: Int,
        chatId: Int,
        chatType: String? = nil,
        fromUserId: Int? = nil,
        text: String? = nil,
        replyTo: TelegramReplyContext? = nil,
        date: Int = 0,
        extras: JSONValue? = nil
    ) {
        self.messageId = messageId
        self.chatId = chatId
        self.chatType = chatType
        self.fromUserId = fromUserId
        self.text = text
        self.replyTo = replyTo
        self.date = date
        self.extras = extras
    }

    private static let knownKeys: Set<String> = [
        "message_id", "messageId",
        "chat", "chatId", "chatType",
        "from", "fromUserId",
        "text", "reply_to_message", "replyTo",
        "date", "extras",
    ]

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: _TGAnyKey.self)
        func jv(_ k: String) -> JSONValue? {
            guard let key = _TGAnyKey(stringValue: k) else { return nil }
            return (try? c.decodeIfPresent(JSONValue.self, forKey: key)) ?? nil
        }
        func int(_ k: String) -> Int? {
            if let v = jv(k) {
                if case .int(let i) = v { return Int(i) }
                if case .double(let d) = v { return Int(d) }
            }
            return nil
        }
        // message_id (wire) or messageId (Swift-encoded round-trip)
        self.messageId = int("message_id") ?? int("messageId") ?? 0

        // chat.id / chat.type (nested) or chatId/chatType (Swift-encoded
        // round-trip)
        if let chat = jv("chat"), case .object(let obj) = chat {
            self.chatId = _tgExtractInt(obj, "id") ?? 0
            if case .string(let t)? = obj["type"] {
                self.chatType = t
            } else {
                self.chatType = nil
            }
        } else {
            self.chatId = int("chatId") ?? 0
            self.chatType = {
                guard let v = jv("chatType"), case .string(let t) = v else { return nil }
                return t
            }()
        }
        if let from = jv("from"), case .object(let obj) = from {
            self.fromUserId = _tgExtractInt(obj, "id")
        } else {
            self.fromUserId = int("fromUserId")
        }
        self.text = {
            guard let v = jv("text"), case .string(let s) = v else { return nil }
            return s
        }()
        self.replyTo = TelegramReplyContext.fromTelegramJSON(jv("reply_to_message"))
            ?? TelegramReplyContext.fromTelegramJSON(jv("replyTo"))
        self.date = int("date") ?? 0

        var unknown: [String: JSONValue] = [:]
        for key in c.allKeys where !Self.knownKeys.contains(key.stringValue) {
            if let v = try? c.decode(JSONValue.self, forKey: key) {
                unknown[key.stringValue] = v
            }
        }
        if let explicit = jv("extras"), case .object(let obj) = explicit {
            for (k, v) in obj { unknown[k] = v }
        }
        self.extras = unknown.isEmpty ? nil : .object(unknown)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: _TGAnyKey.self)
        try c.encode(messageId, forKey: _TGAnyKey("messageId"))
        try c.encode(chatId, forKey: _TGAnyKey("chatId"))
        try c.encodeIfPresent(chatType, forKey: _TGAnyKey("chatType"))
        try c.encodeIfPresent(fromUserId, forKey: _TGAnyKey("fromUserId"))
        try c.encodeIfPresent(text, forKey: _TGAnyKey("text"))
        try c.encodeIfPresent(replyTo, forKey: _TGAnyKey("replyTo"))
        try c.encode(date, forKey: _TGAnyKey("date"))
        if case .object(let obj)? = extras {
            for (k, v) in obj where !Self.knownKeys.contains(k) {
                try c.encode(v, forKey: _TGAnyKey(k))
            }
        }
    }
}

public struct TelegramUpdate: Sendable, Codable, Equatable {
    public var updateId: Int
    public var message: TelegramMessage?
    public var callbackQuery: JSONValue?
    public var extras: JSONValue?

    public init(
        updateId: Int,
        message: TelegramMessage? = nil,
        callbackQuery: JSONValue? = nil,
        extras: JSONValue? = nil
    ) {
        self.updateId = updateId
        self.message = message
        self.callbackQuery = callbackQuery
        self.extras = extras
    }

    private static let knownKeys: Set<String> = [
        "update_id", "updateId",
        "message",
        "callback_query", "callbackQuery",
        "extras",
    ]

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: _TGAnyKey.self)
        func jv(_ k: String) -> JSONValue? {
            guard let key = _TGAnyKey(stringValue: k) else { return nil }
            return (try? c.decodeIfPresent(JSONValue.self, forKey: key)) ?? nil
        }
        func int(_ k: String) -> Int? {
            if let v = jv(k) {
                if case .int(let i) = v { return Int(i) }
                if case .double(let d) = v { return Int(d) }
            }
            return nil
        }
        self.updateId = int("update_id") ?? int("updateId") ?? 0
        if let msgKey = _TGAnyKey(stringValue: "message"),
           let msg = try? c.decodeIfPresent(TelegramMessage.self, forKey: msgKey) {
            self.message = msg
        } else {
            self.message = nil
        }
        self.callbackQuery = jv("callback_query") ?? jv("callbackQuery")

        var unknown: [String: JSONValue] = [:]
        for key in c.allKeys where !Self.knownKeys.contains(key.stringValue) {
            if let v = try? c.decode(JSONValue.self, forKey: key) {
                unknown[key.stringValue] = v
            }
        }
        if let explicit = jv("extras"), case .object(let obj) = explicit {
            for (k, v) in obj { unknown[k] = v }
        }
        self.extras = unknown.isEmpty ? nil : .object(unknown)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: _TGAnyKey.self)
        try c.encode(updateId, forKey: _TGAnyKey("updateId"))
        try c.encodeIfPresent(message, forKey: _TGAnyKey("message"))
        try c.encodeIfPresent(callbackQuery, forKey: _TGAnyKey("callbackQuery"))
        if case .object(let obj)? = extras {
            for (k, v) in obj where !Self.knownKeys.contains(k) {
                try c.encode(v, forKey: _TGAnyKey(k))
            }
        }
    }
}

public struct TelegramPollResult: Sendable, Equatable {
    public var updates: [TelegramUpdate]
    public var nextOffset: Int
    public init(updates: [TelegramUpdate], nextOffset: Int) {
        self.updates = updates
        self.nextOffset = nextOffset
    }
}
