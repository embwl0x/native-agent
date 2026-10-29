import Foundation
import NativeAgentShared
import NativeAgentCore
import PersistenceCore
import TurnTrace
import BackgroundLoops
import ProviderRouting

// Blueprint: | `TelegramBot+Models.swift` | Telegram wire models: typed API failures/results, sender/update/message/reply context and callback number decoding |

// MARK: - TelegramStatus

public struct TelegramVoiceTranscriptionStatus: Codable, Hashable, Sendable {
    public var enabled: Bool
    public var backend: String
    public var model: String
    public var maxBytes: Int
    public init(enabled: Bool, backend: String, model: String, maxBytes: Int) {
        self.enabled = enabled
        self.backend = backend
        self.model = model
        self.maxBytes = maxBytes
    }
}

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

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: JSONKey.self)
        func bool(_ k: String) throws -> Bool? {
            return try c.decodeIfPresent(Bool.self, forKey: JSONKey(k))
        }
        func str(_ k: String) throws -> String? {
            return try c.decodeIfPresent(String.self, forKey: JSONKey(k))
        }
        func int(_ k: String) throws -> Int? {
            return try c.decodeIfPresent(Int.self, forKey: JSONKey(k))
        }
        func jv(_ k: String) throws -> JSONValue? {
            return try c.decodeIfPresent(JSONValue.self, forKey: JSONKey(k))
        }
        self.enabled = try bool("enabled")
        self.tokenConfigured = try bool("tokenConfigured")
        self.pollerEnabled = try bool("pollerEnabled")
        self.lastSeenUpdateId = try int("lastSeenUpdateId")
        self.lastSeenAt = try str("lastSeenAt")
        self.lastReplyAt = try str("lastReplyAt")
        self.lastError = try str("lastError")

        var unknown = c.unknownFields(excluding: Self.knownKeys)
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
        var c = encoder.container(keyedBy: JSONKey.self)
        try c.encodeIfPresent(enabled, forKey: JSONKey("enabled"))
        try c.encodeIfPresent(tokenConfigured, forKey: JSONKey("tokenConfigured"))
        try c.encodeIfPresent(pollerEnabled, forKey: JSONKey("pollerEnabled"))
        try c.encodeIfPresent(lastSeenUpdateId, forKey: JSONKey("lastSeenUpdateId"))
        try c.encodeIfPresent(lastSeenAt, forKey: JSONKey("lastSeenAt"))
        try c.encodeIfPresent(lastReplyAt, forKey: JSONKey("lastReplyAt"))
        try c.encodeIfPresent(lastError, forKey: JSONKey("lastError"))
        try c.encodeUnknownFields(extras, excluding: Self.knownKeys)
    }
}

// MARK: - TelegramTestResult

/// Required identifiers from the validated sendMessage result.
public struct TelegramTestResult: Sendable, Decodable, Equatable {
    public let chatId: Int
    public let messageId: Int

    enum CodingKeys: String, CodingKey { case chat, id, messageId = "message_id" }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        messageId = try values.decode(Int.self, forKey: .messageId)
        chatId = try values.nestedContainer(keyedBy: CodingKeys.self, forKey: .chat)
            .decode(Int.self, forKey: .id)
    }
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

/// The envelope retains error evidence even when the method result is malformed.
public struct TelegramAPIResponse<Result: Decodable & Sendable>: Sendable, Decodable {
    public let ok: Bool
    public let result: Result?
    public let description: String?
    public let errorCode: Int?
    public let parameters: TelegramAPIResponseParameters?

    enum CodingKeys: String, CodingKey {
        case ok, result, description, parameters
        case errorCode = "error_code"
    }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        ok = try values.decode(Bool.self, forKey: .ok)
        description = try values.decodeIfPresent(String.self, forKey: .description)
        errorCode = try values.decodeIfPresent(Int.self, forKey: .errorCode)
        parameters = try values.decodeIfPresent(TelegramAPIResponseParameters.self, forKey: .parameters)
        result = try? values.decode(Result.self, forKey: .result)
    }

}

/// The bot username used to admit commands addressed to this bot.
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
        case invalidDuration
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
        var detail = "telegram_\(kind.rawValue): \(operation)"
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
        if let chatID = parameters?.migrateToChatId {
            detail += ". Update the destination to \(chatID) in Telegram setup."
        } else if let seconds = parameters?.retryAfter, seconds > 0 {
            detail += ". Wait \(seconds)s; inspect the Telegram delivery receipt before resending."
        } else if httpStatus == 401 || errorCode == 401 {
            detail += ". Replace the rejected bot token in Telegram setup."
        } else if httpStatus == 403 || errorCode == 403 {
            detail += ". Check the bot's access to this chat in Telegram."
        } else if kind == .malformedResponse || kind == .malformedResult {
            detail += ". Have the runtime owner inspect the \(operation) transport response; delivery is unconfirmed."
        } else {
            detail += ". Inspect the \(operation) request and Telegram delivery receipt before resending."
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
        case .invalidRequest: return "telegram_request_invalid: Request or destination is invalid. Check the request fields and allowed destination in Telegram setup."
        case .notConfigured: return "telegram_not_configured: Bot token or destination is missing. Set both in Telegram setup."
        case .invalidResponse(let s): return "telegram_http_failed: Transport returned HTTP \(s). Inspect Telegram connection status and the delivery receipt before resending."
        case .unavailable: return "telegram_delivery_unavailable: Delivery cannot proceed. Inspect the saved reply and destination in Telegram setup."
        case .underlying(let m): return "telegram: \(m)"
        }
    }
}

// MARK: - TelegramMessage / TelegramUpdate / TelegramPollResult

private extension KeyedDecodingContainer where Key == JSONKey {
    func jsonValue(for key: String) -> JSONValue? {
        (try? decodeIfPresent(JSONValue.self, forKey: JSONKey(key))) ?? nil
    }

    func integer(for key: String) -> Int? {
        jsonValue(for: key)?.integerValue.flatMap(Int.init(exactly:))
    }

    func extras(excluding knownKeys: Set<String>) -> JSONValue? {
        var unknown = unknownFields(excluding: knownKeys)
        if case .object(let explicit)? = jsonValue(for: "extras") {
            for (key, value) in explicit { unknown[key] = value }
        }
        return unknown.isEmpty ? nil : .object(unknown)
    }
}

func _tgNowString(_ date: Date = Date()) -> String {
    NativeTimestampFormat.fractionalZulu(date)
}

/// Parse expiring state stamps with or without fractional seconds.
func _tgParseDate(_ value: String?) -> Date? {
    guard let value, !value.isEmpty else { return nil }
    return NativeTimestampFormat.parseISO8601FractionalFirst(value)
}

func _tgPreview(_ text: String?, limit: Int = 240) -> String? {
    guard let text else { return nil }
    // Redact receipts.jsonl previews before truncation so partial tokens cannot escape.
    let trimmed = TurnTraceRedactor.redactText(text.trimmingCharacters(in: .whitespacesAndNewlines))
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
        let messageId = obj["message_id"]?.integerValue.flatMap(Int.init(exactly:))
            ?? obj["messageId"]?.integerValue.flatMap(Int.init(exactly:))
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
            chatId: chatObj?["id"]?.integerValue.flatMap(Int.init(exactly:)) ?? obj["chatId"]?.integerValue.flatMap(Int.init(exactly:)),
            chatType: chatObj?["type"]?.stringValue ?? obj["chatType"]?.stringValue,
            fromUserId: fromObj?["id"]?.integerValue.flatMap(Int.init(exactly:)) ?? obj["fromUserId"]?.integerValue.flatMap(Int.init(exactly:)),
            fromIsBot: fromObj?["is_bot"]?.boolValue ?? obj["fromIsBot"]?.boolValue,
            text: obj["text"]?.stringValue,
            caption: obj["caption"]?.stringValue,
            date: obj["date"]?.integerValue.flatMap(Int.init(exactly:))
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

/// Chat and optional forum topic identify the conversation; nil means a chat-only destination.
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
        return obj["message_thread_id"]?.integerValue.flatMap(Int.init(exactly:))
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
    /// Retain `message_thread_id` only for `is_topic_message`, excluding linked-discussion threads.
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
        let c = try decoder.container(keyedBy: JSONKey.self)
        // message_id (wire) or messageId (Swift-encoded round-trip)
        self.messageId = c.integer(for: "message_id") ?? c.integer(for: "messageId") ?? 0

        // chat.id / chat.type (nested) or chatId/chatType (Swift-encoded
        // round-trip)
        if let chat = c.jsonValue(for: "chat"), case .object(let obj) = chat {
            self.chatId = obj["id"]?.integerValue.flatMap(Int.init(exactly:)) ?? 0
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
            self.fromUserId = obj["id"]?.integerValue.flatMap(Int.init(exactly:))
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
        var c = encoder.container(keyedBy: JSONKey.self)
        try c.encode(messageId, forKey: JSONKey("messageId"))
        try c.encode(chatId, forKey: JSONKey("chatId"))
        try c.encodeIfPresent(chatType, forKey: JSONKey("chatType"))
        try c.encodeIfPresent(messageThreadId, forKey: JSONKey("messageThreadId"))
        try c.encodeIfPresent(fromUserId, forKey: JSONKey("fromUserId"))
        try c.encodeIfPresent(text, forKey: JSONKey("text"))
        try c.encodeIfPresent(replyTo, forKey: JSONKey("replyTo"))
        try c.encode(date, forKey: JSONKey("date"))
        try c.encodeUnknownFields(extras, excluding: Self.knownKeys)
    }
}

public struct TelegramUpdate: Sendable, Codable, Equatable {
    public var updateId: Int
    // Synthetic replies use exactly the negative 56-bit namespace; only
    // upstream IDs advance getUpdates, and each must have a representable successor.
    var hasValidInboxID: Bool { updateId >= -(1 << 56) && nextOffset != nil }
    var nextOffset: Int? {
        let (next, overflow) = updateId.addingReportingOverflow(1)
        return overflow ? nil : next
    }
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
        let c = try decoder.container(keyedBy: JSONKey.self)
        guard let id = c.integer(for: "update_id") ?? c.integer(for: "updateId"),
              id >= -(1 << 56), id < Int.max else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Invalid Telegram update ID"))
        }
        self.updateId = id
        self.message = try? c.decodeIfPresent(TelegramMessage.self, forKey: JSONKey("message"))
        self.callbackQuery = c.jsonValue(for: "callback_query") ?? c.jsonValue(for: "callbackQuery")

        self.extras = c.extras(excluding: Self.knownKeys)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: JSONKey.self)
        try c.encode(updateId, forKey: JSONKey("updateId"))
        try c.encodeIfPresent(message, forKey: JSONKey("message"))
        try c.encodeIfPresent(callbackQuery, forKey: JSONKey("callbackQuery"))
        try c.encodeUnknownFields(extras, excluding: Self.knownKeys)
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

/// Every callback family shares transport identity decoding.
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
              let chatId = (chat["id"]?.integerValue.flatMap(Int.init(exactly:)) ?? chat["id"]?.stringValue.flatMap(Int.init)),
              let messageId = (message["message_id"]?.integerValue.flatMap(Int.init(exactly:)) ?? message["message_id"]?.stringValue.flatMap(Int.init))
                ?? (message["messageId"]?.integerValue.flatMap(Int.init(exactly:)) ?? message["messageId"]?.stringValue.flatMap(Int.init)) else {
            return nil
        }
        self.callbackId = callbackId
        self.command = command
        self.chatId = chatId
        self.threadId = TelegramDestination.topicThreadId(inMessageObject: message)
        self.messageId = messageId
        if case .object(let from)? = object["from"] {
            self.fromUserId = (from["id"]?.integerValue.flatMap(Int.init(exactly:)) ?? from["id"]?.stringValue.flatMap(Int.init))
        } else {
            self.fromUserId = nil
        }
    }
}
