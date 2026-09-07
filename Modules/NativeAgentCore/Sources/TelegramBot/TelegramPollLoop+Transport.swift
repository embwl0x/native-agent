import Foundation
import NativeAgentCore
import PersistenceCore

extension TelegramPollLoop {
    func answerRecordedCallback(
        _ callbackId: String,
        text: String,
        context: String,
        update: TelegramUpdate
    ) async {
        do {
            try await answerCallbackQuery(token, callbackId, text)
        } catch {
            await recordError(
                context: context,
                error: String(describing: error),
                update: update,
                message: nil,
                text: nil
            )
        }
    }

    /// 2026-09-06: `chat_id` plus, for a forum topic, `message_thread_id`.
    /// Telegram drops a send into General when the thread is missing, which is
    /// how every topic reply used to land in the wrong conversation. Edits and
    /// callback answers are addressed by message id and take no thread.
    static func _tgDestinationFields(_ destination: TelegramDestination) -> [String: JSONValue] {
        var fields: [String: JSONValue] = ["chat_id": .int(Int64(destination.chatId))]
        if let threadId = destination.threadId {
            fields["message_thread_id"] = .int(Int64(threadId))
        }
        return fields
    }

    static func _tgDestinationBody(_ destination: TelegramDestination) -> [String: Any] {
        var body: [String: Any] = ["chat_id": destination.chatId]
        if let threadId = destination.threadId {
            body["message_thread_id"] = threadId
        }
        return body
    }

    public static let defaultSendRichMessageDraft: @Sendable (
        String, TelegramDestination, Int, TelegramInputRichMessage
    ) async throws -> Void = {
        token, destination, draftId, richMessage in
        try await _tgRetryAfterFloodControl(chatId: destination.chatId) {
            _ = try await _tgPostJSON(
                token: token,
                method: "sendRichMessageDraft",
                resultType: Bool.self,
                validateResult: { $0 }
            ) {
                var draftFields = _tgDestinationFields(destination)
                draftFields["draft_id"] = .int(Int64(draftId))
                draftFields["rich_message"] = richMessage.jsonValue
                return try JSONValue.object(draftFields).serializedData(pretty: false)
            }
        }
    }

    public static let defaultSendRichMessage: @Sendable (
        String, TelegramDestination, TelegramInputRichMessage
    ) async throws -> Int = {
        token, destination, richMessage in
        return try await _tgRetryAfterFloodControl(chatId: destination.chatId) {
            let result = try await _tgPostJSON(
                token: token,
                method: "sendRichMessage",
                resultType: TelegramAPIMessageResult.self
            ) {
                var richFields = _tgDestinationFields(destination)
                richFields["rich_message"] = richMessage.jsonValue
                return try JSONValue.object(richFields).serializedData(pretty: false)
            }
            return result.value.messageId
        }
    }

    public static let defaultSendMessageWithReplyMarkupReturningId:
        @Sendable (String, TelegramDestination, String, JSONValue) async throws -> Int = {
            token, destination, text, replyMarkup in
            return try await _tgRetryAfterFloodControl(chatId: destination.chatId) {
                let result = try await _tgPostJSON(
                    token: token,
                    method: "sendMessage",
                    resultType: TelegramAPIMessageResult.self
                ) {
                    var cardFields = _tgDestinationFields(destination)
                    cardFields["text"] = .string(text)
                    cardFields["reply_markup"] = replyMarkup
                    return try JSONValue.object(cardFields).serializedData(pretty: false)
                }
                return result.value.messageId
            }
        }

    /// chat-smoothness phase 5: sendMessage that returns the created
    /// message_id so the growing draft can edit it. Single message only —
    /// the draft window is pre-capped to one Telegram-safe chunk.
    public static let defaultSendMessageReturningId: @Sendable (String, TelegramDestination, String) async throws -> Int = { token, destination, text in
        return try await _tgRetryAfterFloodControl(chatId: destination.chatId) {
            let result = try await _tgPostJSON(
                token: token,
                method: "sendMessage",
                resultType: TelegramAPIMessageResult.self
            ) {
                var body = _tgDestinationBody(destination)
                body["text"] = text
                return try JSONSerialization.data(withJSONObject: body)
            }
            return result.value.messageId
        }
    }

    /// chat-smoothness phase 5: edit the growing draft in place. Telegram
    /// 400s "message is not modified" when text is unchanged — treated as
    /// success (the draft already shows this text).
    public static let defaultEditMessageText: @Sendable (String, Int, Int, String) async throws -> Void = { token, chatId, messageId, text in
        try await _tgRetryAfterFloodControl(chatId: chatId) {
            _ = try await _tgPostJSON(
                token: token,
                method: "editMessageText",
                resultType: TelegramAPIMessageResult.self,
                allowMessageNotModified: true
            ) {
                let body: [String: Any] = ["chat_id": chatId, "message_id": messageId, "text": text]
                return try JSONSerialization.data(withJSONObject: body)
            }
        }
    }

    public static let defaultEditMessageTextWithReplyMarkup:
        @Sendable (String, Int, Int, String, JSONValue?) async throws -> Void = { token, chatId, messageId, text, replyMarkup in
        try await _tgRetryAfterFloodControl(chatId: chatId) {
            _ = try await _tgPostJSON(
                token: token,
                method: "editMessageText",
                resultType: TelegramAPIMessageResult.self,
                allowMessageNotModified: true
            ) {
                var body: [String: JSONValue] = [
                    "chat_id": .int(Int64(chatId)),
                    "message_id": .int(Int64(messageId)),
                    "text": .string(text),
                ]
                if let replyMarkup {
                    body["reply_markup"] = replyMarkup
                }
                return try JSONValue.object(body).serializedData(pretty: false)
            }
        }
    }

    public static let defaultSendMessage: @Sendable (String, TelegramDestination, String) async throws -> Void = { token, destination, text in
        try await sendMessage(
            token: token,
            chatId: destination.chatId,
            text: text,
            threadId: destination.threadId
        )
    }

    /// Concrete ordinary-reply transport.  Kept separately from the closure
    /// default so a hermetic URLProtocol session can execute this exact request
    /// and validator path, including flood-control retry semantics.
    static func sendMessage(
        token: String,
        chatId: Int,
        text: String,
        threadId: Int? = nil,
        session: URLSession = .shared,
        sleep: @escaping @Sendable (UInt64) async throws -> Void = { try await Task.sleep(nanoseconds: $0) }
    ) async throws {
        // Telegram hard-rejects messages over 4096 chars with HTTP 400 —
        // before chunking, any long Agent reply (code, lists) silently
        // died: typing indicator for the whole turn, then nothing
        // (audit 2026-06-09). Split on newline boundaries when possible.
        for chunk in _tgChunkMessage(text, limit: 4000) {
            try await _tgRetryAfterFloodControl(chatId: chatId, sleep: sleep) {
                _ = try await _tgPostJSON(
                    token: token,
                    method: "sendMessage",
                    resultType: TelegramAPIMessageResult.self,
                    session: session
                ) {
                    var body = _tgDestinationBody(
                        TelegramDestination(chatId: chatId, threadId: threadId)
                    )
                    body["text"] = chunk
                    return try JSONSerialization.data(withJSONObject: body)
                }
            }
        }
    }

    public static let defaultSendPhoto: @Sendable (String, TelegramDestination, String, String?) async throws -> Void = { token, destination, imagePath, caption in
        try await _tgRetryAfterFloodControl(chatId: destination.chatId) {
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
            _tgAppendMultipartField(name: "chat_id", value: String(destination.chatId), boundary: boundary, to: &body)
            if let threadId = destination.threadId {
                _tgAppendMultipartField(
                    name: "message_thread_id",
                    value: String(threadId),
                    boundary: boundary,
                    to: &body
                )
            }
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
    }

    /// Build each JSON request inside its caller's existing retry attempt.
    /// Keep serialization lazy so an invalid bot URL still fails first.
    private static func _tgPostJSON<Result: Decodable & Sendable>(
        token: String,
        method: String,
        resultType: Result.Type,
        allowMessageNotModified: Bool = false,
        validateResult: (Result) -> Bool = { _ in true },
        session: URLSession = .shared,
        timeoutInterval: TimeInterval? = nil,
        body: () throws -> Data
    ) async throws -> TelegramValidatedResult<Result> {
        guard let url = _tgBuildBotURL(token: token, method: method) else {
            throw TelegramBotError.invalidRequest
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let timeoutInterval { request.timeoutInterval = timeoutInterval }
        request.httpBody = try body()
        let (data, response) = try await session.data(for: request)
        return try _tgValidateResponse(
            data,
            response: response,
            operation: method,
            resultType: resultType,
            allowMessageNotModified: allowMessageNotModified,
            validateResult: validateResult
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

    /// 2026-09-06: `getMe`, wanted for exactly one thing — this bot's
    /// username. A group delivers `/cmd@OtherBot` to every bot in the room and
    /// the command parser stripped the `@suffix` without reading it, so
    /// `/stop@OtherBot` stopped the agent's own turn. Called only when a
    /// command actually names a bot, and the answer is cached in
    /// telegram/state.json, so this is not a per-tick round trip.
    public static let defaultFetchBotUsername: @Sendable (String) async throws -> String = { token in
        try await _tgRetryAfterFloodControl {
            guard let url = _tgBuildBotURL(token: token, method: "getMe") else {
                throw TelegramBotError.invalidRequest
            }
            var req = URLRequest(url: url)
            req.httpMethod = "POST"
            req.timeoutInterval = 20
            let (data, resp) = try await URLSession.shared.data(for: req)
            let result = try _tgValidateResponse(
                data,
                response: resp,
                operation: "getMe",
                resultType: TelegramAPIBotIdentity.self,
                validateResult: { !$0.username.isEmpty }
            )
            return result.value.username
        }
    }

    public static let defaultSendChatAction: @Sendable (String, TelegramDestination, String) async throws -> Void = { token, destination, action in
        try await _tgRetryAfterFloodControl(chatId: destination.chatId) {
            _ = try await _tgPostJSON(
                token: token,
                method: "sendChatAction",
                resultType: Bool.self,
                validateResult: { $0 }
            ) {
                var body = _tgDestinationBody(destination)
                body["action"] = action
                return try JSONSerialization.data(withJSONObject: body)
            }
        }
    }

    public static let defaultAnswerCallbackQuery: @Sendable (String, String, String) async throws -> Void = { token, callbackId, text in
        try await _tgRetryAfterFloodControl {
            _ = try await _tgPostJSON(
                token: token,
                method: "answerCallbackQuery",
                resultType: Bool.self,
                validateResult: { $0 }
            ) {
                let body: [String: Any] = [
                    "callback_query_id": callbackId,
                    "text": String(text.prefix(180)),
                    "show_alert": false,
                ]
                return try JSONSerialization.data(withJSONObject: body)
            }
        }
    }

    public static let defaultSendMessageWithReplyMarkup:
        @Sendable (String, TelegramDestination, String, JSONValue) async throws -> Void = { token, destination, text, replyMarkup in
        _ = try await defaultSendMessageWithReplyMarkupReturningId(token, destination, text, replyMarkup)
    }

    public static let defaultSyncCommandMenu: TelegramCommandMenuSync = { token, commands in
        try await _tgRetryAfterFloodControl {
            _ = try await _tgPostJSON(
                token: token,
                method: "setMyCommands",
                resultType: Bool.self,
                validateResult: { $0 },
                timeoutInterval: 20
            ) {
                let payload: [String: Any] = [
                    "commands": commands.map { command in
                        [
                            "command": command.command,
                            "description": command.description,
                        ]
                    },
                ]
                return try JSONSerialization.data(withJSONObject: payload)
            }
            return TelegramCommandMenuStatus(
                commandCount: commands.count,
                registryVersion: TelegramCommandRegistry.version,
                syncedAt: _tgNowString()
            )
        }
    }
}

/// 2026-09-06: Telegram's flood control is per CHAT (roughly one message a
/// second, about 20 a minute in a group), but a supergroup's topics now each
/// run their own turn, so two topics in one chat could put two sends on the
/// wire at the same instant and a 429 was answered only by the single request
/// that earned it. This lane is the one wire queue for a chat: sends to the
/// same chatId are serialised, and the retry window any of them is handed
/// becomes a chat-level cooldown the next send waits out instead of earning a
/// second 429. Turns stay concurrent — only the sends line up.
actor TelegramChatSendLane {
    static let shared = TelegramChatSendLane()

    private struct Waiter {
        let id: UUID
        let continuation: CheckedContinuation<Void, Error>
    }

    private var busy: Set<Int> = []
    private var waiting: [Int: [Waiter]] = [:]
    private var cooldownUntil: [Int: Date] = [:]

    func run<T: Sendable>(
        chatId: Int,
        sleep: @escaping @Sendable (UInt64) async throws -> Void,
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await acquire(chatId)
        defer { release(chatId) }
        // 2026-09-06: `release` hands the lane straight to the next waiter, so a
        // waiter cancelled in that instant is past `acquire`'s cancellation
        // check and its `abandon` is a no-op. Re-check here, and let a cancelled
        // cooldown wait THROW: `try?` swallowed the cancellation, skipped the
        // rest of the flood cooldown, and sent into a chat Telegram had told to
        // be quiet — for a turn the user had already stopped.
        try Task.checkCancellation()
        if let wait = cooldownNanoseconds(chatId) {
            try await sleep(wait)
        }
        do {
            return try await operation()
        } catch let error as TelegramAPIFailure {
            if error.httpStatus == 429 || error.errorCode == 429,
               let seconds = error.parameters?.retryAfter, seconds > 0 {
                noteRetryAfter(chatId, seconds: seconds)
            }
            throw error
        }
    }

    /// 2026-09-06: the wait for the lane is CANCELLABLE. It used to be a
    /// non-throwing continuation, so a stopped turn queued behind a chat in a
    /// 30s flood cooldown ignored its cancellation and sent anyway, long after
    /// the user asked it to stop. A cancelled waiter leaves the queue and
    /// throws; a waiter that already owns the lane keeps it and releases it in
    /// the normal way.
    private func acquire(_ chatId: Int) async throws {
        guard busy.contains(chatId) else {
            busy.insert(chatId)
            return
        }
        let waiterId = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                waiting[chatId, default: []].append(Waiter(id: waiterId, continuation: continuation))
            }
        } onCancel: {
            Task { await self.abandon(chatId, waiterId: waiterId) }
        }
    }

    /// Drop a cancelled waiter. A no-op when `release` already handed it the
    /// lane — that task owns the lane and releases it itself.
    private func abandon(_ chatId: Int, waiterId: UUID) {
        guard var queue = waiting[chatId],
              let index = queue.firstIndex(where: { $0.id == waiterId }) else { return }
        let waiter = queue.remove(at: index)
        waiting[chatId] = queue.isEmpty ? nil : queue
        waiter.continuation.resume(throwing: CancellationError())
    }

    private func release(_ chatId: Int) {
        guard var queue = waiting[chatId], !queue.isEmpty else {
            waiting[chatId] = nil
            busy.remove(chatId)
            return
        }
        let next = queue.removeFirst()
        waiting[chatId] = queue.isEmpty ? nil : queue
        // The lane stays held: ownership passes straight to the next waiter.
        next.continuation.resume()
    }

    private func cooldownNanoseconds(_ chatId: Int) -> UInt64? {
        guard let until = cooldownUntil[chatId] else { return nil }
        let remaining = until.timeIntervalSinceNow
        guard remaining > 0 else {
            cooldownUntil[chatId] = nil
            return nil
        }
        return UInt64(remaining * 1_000_000_000)
    }

    private func noteRetryAfter(_ chatId: Int, seconds: Int) {
        let until = Date().addingTimeInterval(TimeInterval(seconds))
        guard cooldownUntil[chatId].map({ $0 < until }) ?? true else { return }
        cooldownUntil[chatId] = until
    }
}

/// A Bot API 429 is a definite non-delivery, unlike a transport interruption
/// after bytes left this process. Retry exactly once, only for that typed
/// rejection, and honor the server's advertised retry window before rebuilding
/// the request. This keeps a successful retry from being duplicated while
/// refusing to invent a replay after an ambiguous transport outcome.
///
/// 2026-09-06: `chatId` puts the attempt in that chat's send lane above. The
/// retry sleep stays OUTSIDE the lane so a waiting topic is not held behind a
/// sleeping request — it hits the published cooldown instead. Methods with no
/// chat of their own (getMe, setMyCommands, answerCallbackQuery, getUpdates)
/// pass nil and go straight to the wire.
func _tgRetryAfterFloodControl<T: Sendable>(
    chatId: Int? = nil,
    sleep: @escaping @Sendable (UInt64) async throws -> Void = { try await Task.sleep(nanoseconds: $0) },
    operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    @Sendable func attempt() async throws -> T {
        guard let chatId else { return try await operation() }
        return try await TelegramChatSendLane.shared.run(
            chatId: chatId,
            sleep: sleep,
            operation: operation
        )
    }
    do {
        return try await attempt()
    } catch let error as TelegramAPIFailure {
        // `retry_after` is meaningful only for the actual flood-control
        // response.  Do not replay a different rejection merely because a
        // future API error happens to carry the same-shaped field.
        guard (error.httpStatus == 429 || error.errorCode == 429),
              let seconds = error.parameters?.retryAfter, seconds > 0 else { throw error }
        try await sleep(UInt64(seconds) * 1_000_000_000)
        return try await attempt()
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
