import Foundation
import NativeAgentCore
import PersistenceCore

extension TelegramPollLoop {
    /// chat-smoothness phase 5: sendMessage that returns the created
    /// message_id so the growing draft can edit it. Single message only —
    /// the draft window is pre-capped to one Telegram-safe chunk.
    public static let defaultSendMessageReturningId: @Sendable (String, Int, String) async throws -> Int = { token, chatId, text in
        guard let url = _tgBuildBotURL(token: token, method: "sendMessage") else {
            throw TelegramBotError.invalidRequest
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = ["chat_id": chatId, "text": text]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, resp) = try await URLSession.shared.data(for: req)
        if let http = resp as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw TelegramBotError.underlying("sendMessage status \(http.statusCode)")
        }
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let result = obj["result"] as? [String: Any],
              let messageId = result["message_id"] as? Int else {
            throw TelegramBotError.underlying("sendMessage response missing message_id")
        }
        return messageId
    }

    /// chat-smoothness phase 5: edit the growing draft in place. Telegram
    /// 400s "message is not modified" when text is unchanged — treated as
    /// success (the draft already shows this text).
    public static let defaultEditMessageText: @Sendable (String, Int, Int, String) async throws -> Void = { token, chatId, messageId, text in
        guard let url = _tgBuildBotURL(token: token, method: "editMessageText") else {
            throw TelegramBotError.invalidRequest
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = ["chat_id": chatId, "message_id": messageId, "text": text]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, resp) = try await URLSession.shared.data(for: req)
        if let http = resp as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            let bodyText = String(data: data, encoding: .utf8) ?? ""
            if bodyText.contains("message is not modified") { return }
            throw TelegramBotError.underlying("editMessageText status \(http.statusCode)")
        }
    }

    public static let defaultEditMessageTextWithReplyMarkup:
        @Sendable (String, Int, Int, String, JSONValue?) async throws -> Void = { token, chatId, messageId, text, replyMarkup in
        guard let url = _tgBuildBotURL(token: token, method: "editMessageText") else {
            throw TelegramBotError.invalidRequest
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        var body: [String: JSONValue] = [
            "chat_id": .int(Int64(chatId)),
            "message_id": .int(Int64(messageId)),
            "text": .string(text),
        ]
        if let replyMarkup {
            body["reply_markup"] = replyMarkup
        }
        req.httpBody = try JSONValue.object(body).serializedData(pretty: false)
        let (data, resp) = try await URLSession.shared.data(for: req)
        if let http = resp as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            let bodyText = String(data: data, encoding: .utf8) ?? ""
            if bodyText.contains("message is not modified") { return }
            throw TelegramBotError.underlying("editMessageText status \(http.statusCode)")
        }
    }

    public static let defaultSendMessage: @Sendable (String, Int, String) async throws -> Void = { token, chatId, text in
        // Telegram hard-rejects messages over 4096 chars with HTTP 400 —
        // before chunking, any long Agent reply (code, lists) silently
        // died: typing indicator for the whole turn, then nothing
        // (audit 2026-06-09). Split on newline boundaries when possible.
        for chunk in _tgChunkMessage(text, limit: 4000) {
            guard let url = _tgBuildBotURL(token: token, method: "sendMessage") else {
                throw TelegramBotError.invalidRequest
            }
            var req = URLRequest(url: url)
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            let body: [String: Any] = ["chat_id": chatId, "text": chunk]
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
            let (data, resp) = try await URLSession.shared.data(for: req)
            if let http = resp as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                throw TelegramBotError.underlying("sendMessage status \(http.statusCode)")
            }
            try _tgRequireSuccessfulResponse(data, operation: "sendMessage")
        }
    }

    public static let defaultSendPhoto: @Sendable (String, Int, String, String?) async throws -> Void = { token, chatId, imagePath, caption in
        guard let url = _tgBuildBotURL(token: token, method: "sendPhoto") else {
            throw TelegramBotError.invalidRequest
        }
        let fileURL = URL(fileURLWithPath: imagePath)
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            throw TelegramBotError.underlying("sendPhoto file missing")
        }
        let imageData = try Data(contentsOf: fileURL)
        guard !imageData.isEmpty else {
            throw TelegramBotError.underlying("sendPhoto file empty")
        }

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 60
        let boundary = "NativeAgentTelegramBoundary-\(UUID().uuidString)"
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        var body = Data()
        _tgAppendMultipartField(name: "chat_id", value: String(chatId), boundary: boundary, to: &body)
        if let caption = caption?.trimmingCharacters(in: .whitespacesAndNewlines), !caption.isEmpty {
            _tgAppendMultipartField(name: "caption", value: String(caption.prefix(1_024)), boundary: boundary, to: &body)
        }
        _tgAppendMultipartFile(
            name: "photo",
            filename: fileURL.lastPathComponent.isEmpty ? "image.png" : fileURL.lastPathComponent,
            mimeType: _tgImageUploadMimeType(for: fileURL),
            data: imageData,
            boundary: boundary,
            to: &body
        )
        _tgAppendString("--\(boundary)--\r\n", to: &body)
        req.httpBody = body

        let (data, resp) = try await URLSession.shared.data(for: req)
        if let http = resp as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw TelegramBotError.underlying("sendPhoto status \(http.statusCode)")
        }
        try _tgRequireSuccessfulResponse(data, operation: "sendPhoto")
    }

    /// Telegram defines success through the JSON `ok` field, not HTTP status
    /// alone. A 2xx response that says `ok: false` must never become an accepted
    /// completion-delivery receipt.
    static func _tgRequireSuccessfulResponse(_ data: Data, operation: String) throws {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              (object["ok"] as? Bool) == true else {
            let description: String
            if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let value = object["description"] as? String,
               !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                description = value
            } else {
                description = "response missing ok=true"
            }
            throw TelegramBotError.underlying("\(operation) rejected: \(description)")
        }
    }

    /// Split a message into Telegram-safe chunks. Telegram's 4096 limit
    /// counts UTF-16 code units, NOT Swift Characters — 4000 emoji
    /// graphemes can be 8000 units (gpt-5.5 review 2026-06-09) — so all
    /// budgeting below is in UTF-16 units while cuts stay on Character
    /// boundaries. Prefers newline boundaries (lines are preserved exactly,
    /// including blank lines; only the single boundary newline between two
    /// chunks is consumed). Always returns at least one element.
    static func _tgChunkMessage(_ text: String, limit: Int) -> [String] {
        guard text.utf16.count > limit else { return [text] }
        var chunks: [String] = []
        var current = ""
        func flush() {
            if !current.isEmpty { chunks.append(current); current = "" }
        }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        for lineSub in lines {
            var line = String(lineSub)
            // Hard-split any single line that alone exceeds the budget,
            // walking Characters so graphemes are never torn.
            while line.utf16.count > limit {
                var head = ""
                var units = 0
                for ch in line {
                    let u = String(ch).utf16.count
                    if units + u > limit { break }
                    head.append(ch)
                    units += u
                }
                flush()
                chunks.append(head)
                line = String(line.dropFirst(head.count))
            }
            let sepUnits = current.isEmpty ? 0 : 1
            if current.utf16.count + sepUnits + line.utf16.count > limit {
                flush()
                current = line
            } else {
                current += (sepUnits == 1 ? "\n" : "") + line
            }
        }
        flush()
        return chunks.isEmpty ? [text] : chunks
    }

    public static let defaultSendChatAction: @Sendable (String, Int, String) async throws -> Void = { token, chatId, action in
        guard let url = _tgBuildBotURL(token: token, method: "sendChatAction") else {
            throw TelegramBotError.invalidRequest
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = ["chat_id": chatId, "action": action]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (_, resp) = try await URLSession.shared.data(for: req)
        if let http = resp as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw TelegramBotError.underlying("sendChatAction status \(http.statusCode)")
        }
    }

    public static let defaultAnswerCallbackQuery: @Sendable (String, String, String) async throws -> Void = { token, callbackId, text in
        guard let url = _tgBuildBotURL(token: token, method: "answerCallbackQuery") else {
            throw TelegramBotError.invalidRequest
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = [
            "callback_query_id": callbackId,
            "text": String(text.prefix(180)),
            "show_alert": false,
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (_, resp) = try await URLSession.shared.data(for: req)
        if let http = resp as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw TelegramBotError.underlying("answerCallbackQuery status \(http.statusCode)")
        }
    }

    public static let defaultSendMessageWithReplyMarkup:
        @Sendable (String, Int, String, JSONValue) async throws -> Void = { token, chatId, text, replyMarkup in
        guard let url = _tgBuildBotURL(token: token, method: "sendMessage") else {
            throw TelegramBotError.invalidRequest
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: JSONValue = .object([
            "chat_id": .int(Int64(chatId)),
            "text": .string(text),
            "reply_markup": replyMarkup,
        ])
        req.httpBody = try body.serializedData(pretty: false)
        let (_, resp) = try await URLSession.shared.data(for: req)
        if let http = resp as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw TelegramBotError.underlying("sendMessage status \(http.statusCode)")
        }
    }

    public static let defaultSyncCommandMenu: TelegramCommandMenuSync = { token, commands in
        guard let url = _tgBuildBotURL(token: token, method: "setMyCommands") else {
            throw TelegramBotError.invalidRequest
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 20
        let payload: [String: Any] = [
            "commands": commands.map { command in
                [
                    "command": command.command,
                    "description": command.description,
                ]
            },
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: payload)
        let (data, resp) = try await URLSession.shared.data(for: req)
        if let http = resp as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw TelegramBotError.underlying("setMyCommands status \(http.statusCode)")
        }
        if !data.isEmpty,
           let parsed = try? JSONValue.parse(data),
           case .object(let obj) = parsed,
           case .bool(false)? = obj["ok"] {
            let description: String
            if case .string(let value)? = obj["description"] {
                description = value
            } else {
                description = "setMyCommands failed"
            }
            throw TelegramBotError.underlying(description)
        }
        return TelegramCommandMenuStatus(
            commandCount: commands.count,
            registryVersion: TelegramCommandRegistry.version,
            syncedAt: _tgNowString()
        )
    }
}

private func _tgAppendMultipartField(
    name: String,
    value: String,
    boundary: String,
    to body: inout Data
) {
    _tgAppendString("--\(boundary)\r\n", to: &body)
    _tgAppendString("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n", to: &body)
    _tgAppendString(value, to: &body)
    _tgAppendString("\r\n", to: &body)
}

private func _tgAppendMultipartFile(
    name: String,
    filename: String,
    mimeType: String,
    data: Data,
    boundary: String,
    to body: inout Data
) {
    _tgAppendString("--\(boundary)\r\n", to: &body)
    _tgAppendString("Content-Disposition: form-data; name=\"\(name)\"; filename=\"\(filename)\"\r\n", to: &body)
    _tgAppendString("Content-Type: \(mimeType)\r\n\r\n", to: &body)
    body.append(data)
    _tgAppendString("\r\n", to: &body)
}

private func _tgAppendString(_ value: String, to body: inout Data) {
    body.append(Data(value.utf8))
}

private func _tgImageUploadMimeType(for url: URL) -> String {
    switch url.pathExtension.lowercased() {
    case "jpg", "jpeg": return "image/jpeg"
    case "png": return "image/png"
    case "gif": return "image/gif"
    case "webp": return "image/webp"
    case "bmp": return "image/bmp"
    case "heic": return "image/heic"
    default: return "application/octet-stream"
    }
}

public func defaultTelegramOffsetURL() -> URL {
    defaultDataRoot().appendingPathComponent("telegram/last_offset.json")
}
