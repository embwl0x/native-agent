import Foundation
import NativeAgentShared
import NativeAgentCore
import PersistenceCore
// Blueprint: | `TelegramPollLoop+Transport.swift` | `TelegramPollLoop`: `answerRecordedCallback`, `_tgDestinationFields`, `_tgDestinationBody` |

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

    /// Sends include a topic's `message_thread_id`; edits and callback answers take no thread.
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

    public static let defaultSendSilentRichMessage: @Sendable (
        String, TelegramDestination, TelegramInputRichMessage
    ) async throws -> Int = { token, destination, richMessage in
        let result = try await _tgPostJSON(token: token, method: "sendRichMessage", resultType: TelegramAPIMessageResult.self) {
            var fields = _tgDestinationFields(destination)
            fields["rich_message"] = richMessage.jsonValue
            fields["disable_notification"] = .bool(true)
            return try JSONValue.object(fields).serializedData(pretty: false)
        }
        return result.value.messageId
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

    public static let defaultDeleteMessage: @Sendable (String, Int, Int) async throws -> Void = { token, chatId, messageId in
        try await _tgRetryAfterFloodControl(chatId: chatId) {
            _ = try await _tgPostJSON(
                token: token,
                method: "deleteMessage",
                resultType: Bool.self,
                validateResult: { $0 }
            ) {
                let body: [String: Any] = ["chat_id": chatId, "message_id": messageId]
                return try JSONSerialization.data(withJSONObject: body)
            }
        }
    }

    /// Clean raw plain-text replies once; the cleanup is not idempotent.
    public static func cleanedPlainText(_ text: String) -> String {
        TelegramRichMessageRenderer.sanitize(TelegramRichMessageRenderer.stripBoldMarkers(text))
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
        // nil uses the bounded reply session.
        session: URLSession? = nil,
        sleep: @escaping @Sendable (UInt64) async throws -> Void = { try await Task.sleep(nanoseconds: $0) }
    ) async throws {
        // Split below Telegram's 4096-character limit, preferring newline boundaries.
        for chunk in try _tgChunkMessage(text, limit: 4000) {
            try await _tgRetryAfterFloodControl(chatId: chatId, sleep: sleep) {
                _ = try await _tgPostJSON(
                    token: token,
                    method: "sendMessage",
                    resultType: TelegramAPIMessageResult.self,
                    session: session ?? replySendSession
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

    public static let defaultSendPhoto: @Sendable (String, TelegramDestination, String, Data, String?) async throws -> Void = { token, destination, imagePath, imageData, caption in
        try await _tgRetryAfterFloodControl(chatId: destination.chatId) {
            guard let url = _tgBuildBotURL(token: token, method: "sendPhoto") else {
                throw TelegramBotError.invalidRequest
            }
            let fileURL = URL(fileURLWithPath: imagePath)
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
                mimeType: TelegramPollLoop.imageMime(forFilename: fileURL.lastPathComponent, fallbackMime: nil) ?? "application/octet-stream",
                data: imageData,
                boundary: boundary,
                to: &body
            )
            _tgAppendString("--\(boundary)--\r\n", to: &body)
            req.httpBody = body

            let (data, resp) = try await replySendSession.data(for: req)
            _ = try _tgValidateResponse(
                data,
                response: resp,
                operation: "sendPhoto",
                resultType: TelegramAPIMessageResult.self
            )
        }
    }

    // Bot API JSON calls are finite requests, not long-poll/streaming work.
    // A request timeout alone resets as bytes arrive; bound the whole resource
    // too so a stalled send cannot hold the shared chat lane indefinitely.
    private static let deliverySession: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 30
        return URLSession(configuration: configuration)
    }()

    // Reply chunks and photo uploads: bounded, but roomier than the 30s
    // delivery bound so a slow reply does not fail after earlier chunks landed.
    private static let replySendSession: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 120
        return URLSession(configuration: configuration)
    }()

    /// Build each JSON request inside its caller's existing retry attempt.
    /// Keep serialization lazy so an invalid bot URL still fails first.
    static func _tgPostJSON<Result: Decodable & Sendable>(
        token: String,
        method: String,
        resultType: Result.Type,
        allowMessageNotModified: Bool = false,
        validateResult: (Result) -> Bool = { _ in true },
        session: URLSession = deliverySession,
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
        let data: Data, response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError where error.code == .cancelled {
            // URLSession reports cooperative task cancellation as -999; keep it a
            // cancellation, as the long poll does, so shutdown mid-send retries.
            throw CancellationError()
        }
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
        let envelope = try? JSONDecoder().decode(TelegramAPIResponse<Result>.self, from: data)
        let sanitizedDescription = envelope?.description.map(TurnSecretRedactor.redactText)
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
        guard let result = envelope.result,
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
    /// counts UTF-16 code units: 4000 emoji graphemes can be 8000 units. All
    /// budgeting below is in UTF-16 units while cuts stay on Character
    /// boundaries, splitting an oversized grapheme at scalar boundaries.
    /// Prefers newline boundaries (lines are preserved exactly,
    /// including blank lines; only the single boundary newline between two
    /// chunks is consumed). Always returns at least one element.
    static func _tgChunkMessage(_ text: String, limit: Int) throws -> [String] {
        // A scalar needs at most two UTF-16 units; every hard split consumes one.
        guard limit >= 2 else {
            throw TelegramBotError.underlying("Telegram chunk budget must fit a Unicode scalar (at least two UTF-16 units)")
        }
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
                if head.isEmpty {
                    for scalar in line.unicodeScalars {
                        let u = scalar.utf16.count
                        if units + u > limit { break }
                        head.unicodeScalars.append(scalar)
                        units += u
                    }
                }
                flush()
                chunks.append(head)
                line = String(line.unicodeScalars.dropFirst(head.unicodeScalars.count))
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

    /// Cache the bot username for commands that explicitly name a bot.
    public static let defaultFetchBotUsername: @Sendable (String) async throws -> String = { token in
        try await _tgRetryAfterFloodControl {
            let result = try await _tgPostJSON(token: token, method: "getMe",
                resultType: TelegramAPIBotIdentity.self, validateResult: { !$0.username.isEmpty }) { Data("{}".utf8) }
            return result.value.username
        }
    }

    public static let defaultSendChatAction: @Sendable (String, TelegramDestination, String) async throws -> Void = { token, destination, action in
        try await _tgRetryAfterFloodControl(chatId: destination.chatId) {
            _ = try await _tgPostJSON(
                token: token,
                method: "sendChatAction",
                resultType: Bool.self,
                validateResult: { $0 },
                timeoutInterval: 5
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

/// Serializes sends per chat and shares flood-control cooldowns across its topics.
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
        // Check cancellation after lane handoff; cooldown cancellation must propagate.
        try Task.checkCancellation()
        if let wait = try cooldownNanoseconds(chatId) {
            try await sleep(wait)
        }
        do {
            return try await operation()
        } catch let error as TelegramAPIFailure {
            if error.httpStatus == 429 || error.errorCode == 429,
               let seconds = error.parameters?.retryAfter, seconds > 0 {
                try noteRetryAfter(chatId, seconds: seconds)
            }
            throw error
        }
    }

    /// Cancellation removes queued waiters; lane owners release through run's defer.
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

    private func cooldownNanoseconds(_ chatId: Int) throws -> UInt64? {
        guard let until = cooldownUntil[chatId] else { return nil }
        let remaining = until.timeIntervalSinceNow
        guard remaining > 0 else {
            cooldownUntil[chatId] = nil
            return nil
        }
        return try _tgDurationNanoseconds(remaining)
    }

    private func noteRetryAfter(_ chatId: Int, seconds: Int) throws {
        _ = try _tgDurationNanoseconds(TimeInterval(seconds))
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
/// Chat-bound attempts share a send lane; retry sleeps stay outside it.
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
        try await sleep(_tgDurationNanoseconds(TimeInterval(seconds)))
        return try await attempt()
    }
}

/// Reject unrepresentable server durations before recording or sleeping them.
private func _tgDurationNanoseconds(_ seconds: TimeInterval) throws -> UInt64 {
    guard seconds.isFinite, seconds >= 0,
          let value = UInt64(exactly: (seconds * 1_000_000_000).rounded(.up)) else {
        throw TelegramAPIFailure(kind: .invalidDuration, operation: "retry_after",
                                 telegramDescription: "Server retry duration cannot be represented by the transport timer")
    }
    return value
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

public func defaultTelegramOffsetURL() -> URL {
    defaultDataRoot().appendingPathComponent("telegram/last_offset.json")
}
