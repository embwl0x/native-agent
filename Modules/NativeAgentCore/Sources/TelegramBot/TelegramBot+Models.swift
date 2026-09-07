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

/// 2026-09-06: the `getMe` result, for one field only — this bot's username,
/// so a slash command addressed to a DIFFERENT bot in a group is ignored
/// instead of executed here.
public struct TelegramAPIBotIdentity: Sendable, Codable, Equatable {
    public let username: String
}

public struct TelegramAPIMessageResult: Sendable, Codable, Equatable {
    public let messageId: Int

    enum CodingKeys: String, CodingKey {
        case messageId = "message_id"
    }
}

/// A semantic Telegram transport failure. The typed fields preserve retry and
/// migration information while the description is sanitized before exposure.
public struct TelegramAPIFailure: Error, LocalizedError, CustomStringConvertible, Sendable, Equatable {
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
        if let retryAfter = parameters?.retryAfter, retryAfter > 0 {
            detail += " [retry_after=\(retryAfter)s]"
        }
        if let chatID = parameters?.migrateToChatId {
            // This string is persisted by TelegramPollLoop.recordError into
            // state.json/errors.jsonl, so a migration hint cannot disappear
            // behind a generic rejection.
            detail += " [migrate_to_chat_id=\(chatID)]"
        }
        return detail
    }

    /// Most poll-loop error receipts accept a String.  Preserve the structured
    /// Bot API hints there instead of letting Swift's synthesized struct
    /// description turn a migration into an opaque rejection.
    public var description: String { errorDescription ?? "telegram: \(operation) \(kind.rawValue)" }
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
    _tgInt(obj?[key])
}

private func _tgInt(_ value: JSONValue?) -> Int? {
    switch value {
    case .int(let i)?: return Int(i)
    case .double(let d)?: return Int(exactly: d.rounded(.towardZero))
    default: return nil
    }
}

private extension KeyedDecodingContainer where Key == _TGAnyKey {
    func jsonValue(for key: String) -> JSONValue? {
        (try? decodeIfPresent(JSONValue.self, forKey: _TGAnyKey(key))) ?? nil
    }

    func integer(for key: String) -> Int? {
        _tgInt(jsonValue(for: key))
    }

    func extras(excluding knownKeys: Set<String>) -> JSONValue? {
        var unknown: [String: JSONValue] = [:]
        for key in allKeys where !knownKeys.contains(key.stringValue) {
            if let value = try? decode(JSONValue.self, forKey: key) {
                unknown[key.stringValue] = value
            }
        }
        if case .object(let explicit)? = jsonValue(for: "extras") {
            for (key, value) in explicit { unknown[key] = value }
        }
        return unknown.isEmpty ? nil : .object(unknown)
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
    case .some(.double(let d)): return Int(exactly: d.rounded(.towardZero))
    case .some(.string(let s)): return Int(s)
    default: return nil
    }
}

func _tgJSONString(_ value: JSONValue?) -> String? {
    guard case .string(let s)? = value else { return nil }
    return s
}

func _tgNowString(_ date: Date = Date()) -> String {
    NativeTimestampFormat.fractionalZulu(date)
}

/// 2026-09-06: the inverse of `_tgNowString`, for state stamps that expire.
/// Accepts the fractional-seconds form this file writes and the plain one.
func _tgParseDate(_ value: String?) -> Date? {
    guard let value, !value.isEmpty else { return nil }
    return NativeTimestampFormat.parseISO8601FractionalFirst(value)
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
        // Telegram's is_bot identifies a bot, not necessarily this assistant.
        // Group replies can quote another bot; the transport has not compared
        // the quoted sender with our own identity here.
        let source = replyTo.fromIsBot == true
            ? "a Telegram bot message"
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

/// 2026-09-06: a chat plus, when the message lives in a forum topic, that
/// topic's thread. Telegram forum topics are separate conversations: the
/// session key is this pair, and every outbound call for a turn answers into
/// the topic the inbound arrived in. `threadId` is nil for DMs, ordinary
/// groups, and a forum's General topic — all of which Telegram addresses with
/// `chat_id` alone.
public struct TelegramDestination: Sendable, Hashable {
    public var chatId: Int
    public var threadId: Int?

    public init(chatId: Int, threadId: Int? = nil) {
        self.chatId = chatId
        self.threadId = threadId
    }

    /// The chat-only destination. Used where there is genuinely no topic to
    /// answer into: a recovered legacy claim, a config-driven send, a tool
    /// route that carried no thread.
    public static func chat(_ chatId: Int) -> TelegramDestination {
        TelegramDestination(chatId: chatId)
    }

    /// The forum topic a raw Telegram `Message` object belongs to, or nil.
    /// Same rule as `TelegramMessage`: `message_thread_id` only counts when
    /// `is_topic_message` says this really is a topic message. Callback
    /// queries carry the button's message, so their buttons answer in place.
    public static func topicThreadId(inMessageObject obj: [String: JSONValue]?) -> Int? {
        guard let obj else { return nil }
        guard case .bool(true)? = obj["is_topic_message"] else { return nil }
        return _tgExtractInt(obj, "message_thread_id")
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
    /// 2026-09-06: `message_thread_id`, kept ONLY when the wire also said
    /// `is_topic_message`. A linked-discussion comment thread carries a
    /// message_thread_id too, and treating that as a separate conversation
    /// would split a group that works today.
    public var messageThreadId: Int?
    public var fromUserId: Int?
    public var text: String?
    public var replyTo: TelegramReplyContext?
    public var date: Int
    public var extras: JSONValue?

    public init(
        messageId: Int,
        chatId: Int,
        chatType: String? = nil,
        messageThreadId: Int? = nil,
        fromUserId: Int? = nil,
        text: String? = nil,
        replyTo: TelegramReplyContext? = nil,
        date: Int = 0,
        extras: JSONValue? = nil
    ) {
        self.messageId = messageId
        self.chatId = chatId
        self.chatType = chatType
        self.messageThreadId = messageThreadId
        self.fromUserId = fromUserId
        self.text = text
        self.replyTo = replyTo
        self.date = date
        self.extras = extras
    }

    /// Where a reply to this message must go.
    public var destination: TelegramDestination {
        TelegramDestination(chatId: chatId, threadId: messageThreadId)
    }

    private static let knownKeys: Set<String> = [
        "message_id", "messageId",
        "chat", "chatId", "chatType",
        "message_thread_id", "messageThreadId", "is_topic_message",
        "from", "fromUserId",
        "text", "reply_to_message", "replyTo",
        "date", "extras",
    ]

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: _TGAnyKey.self)
        // message_id (wire) or messageId (Swift-encoded round-trip)
        self.messageId = c.integer(for: "message_id") ?? c.integer(for: "messageId") ?? 0

        // chat.id / chat.type (nested) or chatId/chatType (Swift-encoded
        // round-trip)
        if let chat = c.jsonValue(for: "chat"), case .object(let obj) = chat {
            self.chatId = _tgExtractInt(obj, "id") ?? 0
            if case .string(let t)? = obj["type"] {
                self.chatType = t
            } else {
                self.chatType = nil
            }
        } else {
            self.chatId = c.integer(for: "chatId") ?? 0
            self.chatType = {
                guard let v = c.jsonValue(for: "chatType"), case .string(let t) = v else { return nil }
                return t
            }()
        }
        // Forum topic. The wire form only counts when `is_topic_message` says
        // this really is a topic message; the Swift-encoded round-trip carries
        // the already-decided value under its own key.
        if let wireThread = c.integer(for: "message_thread_id") {
            let isTopic: Bool = {
                guard let v = c.jsonValue(for: "is_topic_message"), case .bool(let b) = v else { return false }
                return b
            }()
            self.messageThreadId = isTopic ? wireThread : nil
        } else {
            self.messageThreadId = c.integer(for: "messageThreadId")
        }
        if let from = c.jsonValue(for: "from"), case .object(let obj) = from {
            self.fromUserId = _tgExtractInt(obj, "id")
        } else {
            self.fromUserId = c.integer(for: "fromUserId")
        }
        self.text = {
            guard let v = c.jsonValue(for: "text"), case .string(let s) = v else { return nil }
            return s
        }()
        self.replyTo = TelegramReplyContext.fromTelegramJSON(c.jsonValue(for: "reply_to_message"))
            ?? TelegramReplyContext.fromTelegramJSON(c.jsonValue(for: "replyTo"))
        self.date = c.integer(for: "date") ?? 0

        self.extras = c.extras(excluding: Self.knownKeys)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: _TGAnyKey.self)
        try c.encode(messageId, forKey: _TGAnyKey("messageId"))
        try c.encode(chatId, forKey: _TGAnyKey("chatId"))
        try c.encodeIfPresent(chatType, forKey: _TGAnyKey("chatType"))
        try c.encodeIfPresent(messageThreadId, forKey: _TGAnyKey("messageThreadId"))
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
        self.updateId = c.integer(for: "update_id") ?? c.integer(for: "updateId") ?? 0
        if let msgKey = _TGAnyKey(stringValue: "message"),
           let msg = try? c.decodeIfPresent(TelegramMessage.self, forKey: msgKey) {
            self.message = msg
        } else {
            self.message = nil
        }
        self.callbackQuery = c.jsonValue(for: "callback_query") ?? c.jsonValue(for: "callbackQuery")

        self.extras = c.extras(excluding: Self.knownKeys)
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

/// The message envelope shared by approval, active-turn and queued-turn buttons.
/// Command parsing stays with each caller and runs before envelope decoding.
struct TelegramCallbackPayload<Command> {
    let callbackId: String
    let command: Command
    let chatId: Int
    let threadId: Int?
    let messageId: Int
    let fromUserId: Int?

    init?(_ raw: JSONValue, parseData: (String) -> Command?) {
        guard case .object(let object) = raw,
              case .string(let callbackId)? = object["id"],
              case .string(let data)? = object["data"],
              let command = parseData(data),
              case .object(let message)? = object["message"],
              case .object(let chat)? = message["chat"],
              let chatId = TelegramCallbackNumbers.int(chat["id"]),
              let messageId = TelegramCallbackNumbers.int(message["message_id"])
                ?? TelegramCallbackNumbers.int(message["messageId"]) else {
            return nil
        }
        self.callbackId = callbackId
        self.command = command
        self.chatId = chatId
        self.threadId = TelegramDestination.topicThreadId(inMessageObject: message)
        self.messageId = messageId
        if case .object(let from)? = object["from"] {
            self.fromUserId = TelegramCallbackNumbers.int(from["id"])
        } else {
            self.fromUserId = nil
        }
    }
}

enum TelegramCallbackNumbers {
    static func int(_ value: JSONValue?) -> Int? {
        switch value {
        case .int(let value)?: return Int(exactly: value)
        // Preserve truncation for representable values; malformed or oversized
        // remote IDs must fail decoding rather than trap the poll process.
        case .double(let value)?: return Int(exactly: value.rounded(.towardZero))
        case .string(let value)?: return Int(value)
        default: return nil
        }
    }
}
