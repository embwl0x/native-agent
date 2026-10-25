import Foundation
import PersistenceCore
import NativeAgentShared
import TelegramBot
// Blueprint: | `EngineTelegram+Reply.swift` | Telegram reply delivery and result models |

public struct TelegramTestResponse: Codable, Hashable, Sendable {
    public var ok: Bool
    public var chatId: String
    public var messageId: Int?
    public var receipt: TelegramReceipt?
    /// A successful outgoing reply proves the saved credential can send, but
    /// it does not prove the inbound long-poll lane is alive.  These fields
    /// are attached after the transport reply, from the live
    /// BackgroundLoops owner.
    public var tokenConfigured: Bool?
    public var pollerRegistered: Bool?
    public var pollerTicking: Bool?

    public init(result: TelegramTestResult) throws {
        let row = try TelegramReplyFields(result.rawResponse)
        ok = try row.required("ok") { if case .bool(let b) = $0 { return b }; return nil }
        let message = try TelegramReplyFields(row.required("result", { $0 }))
        let chat = try TelegramReplyFields(message.required("chat", { $0 }))
        chatId = String(try chat.required("id", TelegramReplyFields.integer))
        messageId = try message.required("message_id", TelegramReplyFields.integer)
        tokenConfigured = try row.optional("tokenConfigured", TelegramReplyFields.boolean)
        pollerRegistered = try row.optional("pollerRegistered", TelegramReplyFields.boolean)
        pollerTicking = try row.optional("pollerTicking", TelegramReplyFields.boolean)
        if let raw = try row.optional("receipt", { $0 }) {
            let receiptRow = try TelegramReplyFields(raw)
            receipt = TelegramReceipt(
                eventId: try receiptRow.optional("id", TelegramReplyFields.string),
                at: try receiptRow.required("at", TelegramReplyFields.string),
                kind: try receiptRow.optional("kind", TelegramReplyFields.string),
                chatId: try receiptRow.optional("chatId", TelegramReplyFields.string),
                userId: try receiptRow.optional("userId", TelegramReplyFields.string),
                updateId: try receiptRow.optional("updateId", TelegramReplyFields.integer),
                messageId: try receiptRow.optional("messageId", TelegramReplyFields.integer),
                textPreview: try receiptRow.optional("textPreview", TelegramReplyFields.string),
                replyPreview: try receiptRow.optional("replyPreview", TelegramReplyFields.string),
                model: try receiptRow.optional("model", TelegramReplyFields.string),
                reasoningEffort: try receiptRow.optional("reasoningEffort", TelegramReplyFields.string)
            )
        }
    }
}

private struct TelegramReplyFields {
    let fields: [String: JSONValue]

    init(_ value: JSONValue) throws {
        guard case .object(let fields) = value else {
            throw DecodingError.typeMismatch([String: JSONValue].self,
                .init(codingPath: [], debugDescription: "A Telegram reply is a JSON object."))
        }
        self.fields = fields
    }

    func optional<T>(_ key: String, _ read: (JSONValue) -> T?) throws -> T? {
        guard let raw = fields[key], raw != .null else { return nil }
        guard let value = read(raw) else {
            throw DecodingError.typeMismatch(T.self,
                .init(codingPath: [Key(stringValue: key)], debugDescription: "Invalid Telegram reply field: \(key)"))
        }
        return value
    }

    func required<T>(_ key: String, _ read: (JSONValue) -> T?) throws -> T {
        let codingKey = Key(stringValue: key)
        guard fields[key] != nil else {
            throw DecodingError.keyNotFound(codingKey,
                .init(codingPath: [], debugDescription: "Missing Telegram reply field: \(key)"))
        }
        guard let value = try optional(key, read) else {
            throw DecodingError.valueNotFound(T.self,
                .init(codingPath: [codingKey], debugDescription: "Null Telegram reply field: \(key)"))
        }
        return value
    }

    static func string(_ value: JSONValue) -> String? {
        if case .string(let s) = value { return s }; return nil
    }

    static func boolean(_ value: JSONValue) -> Bool? {
        if case .bool(let b) = value { return b }; return nil
    }

    static func integer(_ value: JSONValue) -> Int? {
        switch value {
        case .int(let i): return Int(exactly: i)
        case .double(let d): return Int(exactly: d)
        default: return nil
        }
    }

    private struct Key: CodingKey {
        let stringValue: String
        var intValue: Int? { nil }
        init(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { return nil }
    }
}
