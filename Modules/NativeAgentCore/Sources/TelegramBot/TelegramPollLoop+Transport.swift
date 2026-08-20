import Foundation
import NativeAgentCore
import PersistenceCore

extension TelegramPollLoop {
    public static let defaultSendRichMessageDraft: @Sendable (
        String, Int, Int, TelegramInputRichMessage
    ) async throws -> Void = {
        token, chatId, draftId, richMessage in
        guard let url = _tgBuildBotURL(token: token, method: "sendRichMessageDraft") else {
            throw TelegramBotError.invalidRequest
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONValue.object([
            "chat_id": .int(Int64(chatId)),
            "draft_id": .int(Int64(draftId)),
            "rich_message": richMessage.jsonValue,
        ]).serializedData(pretty: false)
        let (data, response) = try await URLSession.shared.data(for: request)
        _ = try _tgValidateResponse(
            data,
            response: response,
            operation: "sendRichMessageDraft",
            resultType: Bool.self,
            validateResult: { $0 }
        )
    }

    public static let defaultSendRichMessage: @Sendable (
        String, Int, TelegramInputRichMessage
    ) async throws -> Int = {
        token, chatId, richMessage in
        guard let url = _tgBuildBotURL(token: token, method: "sendRichMessage") else {
            throw TelegramBotError.invalidRequest
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONValue.object([
            "chat_id": .int(Int64(chatId)),
            "rich_message": richMessage.jsonValue,
        ]).serializedData(pretty: false)
        let (data, response) = try await URLSession.shared.data(for: request)
        let result = try _tgValidateResponse(
            data,
            response: response,
            operation: "sendRichMessage",
            resultType: TelegramAPIMessageResult.self
        )
        return result.value.messageId
    }

    public static let defaultSendMessageWithReplyMarkupReturningId:
        @Sendable (String, Int, String, JSONValue) async throws -> Int = {
            token, chatId, text, replyMarkup in
            guard let url = _tgBuildBotURL(token: token, method: "sendMessage") else {
                throw TelegramBotError.invalidRequest
            }
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONValue.object([
                "chat_id": .int(Int64(chatId)),
                "text": .string(text),
                "reply_markup": replyMarkup,
            ]).serializedData(pretty: false)
            let (data, response) = try await URLSession.shared.data(for: request)
            let result = try _tgValidateResponse(
                data,
                response: response,
                operation: "sendMessage",
                resultType: TelegramAPIMessageResult.self
            )
            return result.value.messageId
        }

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
        let result = try _tgValidateResponse(
            data,
            response: resp,
            operation: "sendMessage",
            resultType: TelegramAPIMessageResult.self
        )
        return result.value.messageId
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
        _ = try _tgValidateResponse(
            data,
            response: resp,
            operation: "editMessageText",
            resultType: TelegramAPIMessageResult.self,
            allowMessageNotModified: true
        )
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
        _ = try _tgValidateResponse(
            data,
            response: resp,
            operation: "editMessageText",
            resultType: TelegramAPIMessageResult.self,
            allowMessageNotModified: true
        )
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
            _ = try _tgValidateResponse(
                data,
                response: resp,
                operation: "sendMessage",
                resultType: TelegramAPIMessageResult.self
            )
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
        _ = try _tgValidateResponse(
            data,
            response: resp,
            operation: "sendPhoto",
            resultType: TelegramAPIMessageResult.self
        )
    }

    enum TelegramValidatedResult<Result: Sendable>: Sendable {
        case value(Result)
        case notModified

        var value: Result {
            switch self {
            case .value(let result): return result
            case .notModified:
                preconditionFailure("not-modified has no decoded result")
            }
        }
    }

    /// One validation seam for every Telegram Bot API method: HTTP status is
    /// transport evidence, while the typed response envelope and result decide
    /// semantic success.
    static func _tgValidateResponse<Result: Decodable & Sendable>(
        _ data: Data,
        response: URLResponse,
        operation: String,
        resultType: Result.Type,
        allowMessageNotModified: Bool = false,
        validateResult: (Result) -> Bool = { _ in true }
    ) throws -> TelegramValidatedResult<Result> {
        guard let http = response as? HTTPURLResponse else {
            throw TelegramAPIFailure(
                kind: .malformedResponse,
                operation: operation,
                telegramDescription: "missing HTTP response"
            )
        }
        return try _tgValidateResponse(
            data,
            httpStatus: http.statusCode,
            operation: operation,
            resultType: resultType,
            allowMessageNotModified: allowMessageNotModified,
            validateResult: validateResult
        )
    }

    static func _tgValidateResponse<Result: Decodable & Sendable>(
        _ data: Data,
        httpStatus: Int,
        operation: String,
        resultType: Result.Type,
        allowMessageNotModified: Bool = false,
        validateResult: (Result) -> Bool = { _ in true }
    ) throws -> TelegramValidatedResult<Result> {
        let envelope = try? JSONDecoder().decode(TelegramAPIResponse.self, from: data)
        let sanitizedDescription = envelope?.description.map(_tgRedactToken)
        let isNotModified = sanitizedDescription?
            .localizedCaseInsensitiveContains("message is not modified") == true

        guard (200..<300).contains(httpStatus) else {
            if allowMessageNotModified, isNotModified { return .notModified }
            throw TelegramAPIFailure(
                kind: .httpStatus,
                operation: operation,
                httpStatus: httpStatus,
                errorCode: envelope?.errorCode,
                telegramDescription: sanitizedDescription,
                parameters: envelope?.parameters
            )
        }

        guard let envelope else {
            throw TelegramAPIFailure(
                kind: .malformedResponse,
                operation: operation,
                httpStatus: httpStatus,
                telegramDescription: "response was not a Telegram API envelope"
            )
        }
        guard envelope.ok else {
            if allowMessageNotModified, isNotModified { return .notModified }
            throw TelegramAPIFailure(
                kind: .rejected,
                operation: operation,
                httpStatus: httpStatus,
                errorCode: envelope.errorCode,
                telegramDescription: sanitizedDescription,
                parameters: envelope.parameters
            )
        }
        guard let rawResult = envelope.result,
              let resultData = try? rawResult.serializedData(pretty: false),
              let result = try? JSONDecoder().decode(resultType, from: resultData),
              validateResult(result) else {
            throw TelegramAPIFailure(
                kind: .malformedResult,
                operation: operation,
                httpStatus: httpStatus,
                errorCode: envelope.errorCode,
                telegramDescription: sanitizedDescription ?? "response result had an unexpected shape",
                parameters: envelope.parameters
            )
        }
        return .value(result)
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
        let (data, resp) = try await URLSession.shared.data(for: req)
        _ = try _tgValidateResponse(
            data,
            response: resp,
            operation: "sendChatAction",
            resultType: Bool.self,
            validateResult: { $0 }
        )
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
        let (data, resp) = try await URLSession.shared.data(for: req)
        _ = try _tgValidateResponse(
            data,
            response: resp,
            operation: "answerCallbackQuery",
            resultType: Bool.self,
            validateResult: { $0 }
        )
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
        let (data, resp) = try await URLSession.shared.data(for: req)
        _ = try _tgValidateResponse(
            data,
            response: resp,
            operation: "sendMessage",
            resultType: TelegramAPIMessageResult.self
        )
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
