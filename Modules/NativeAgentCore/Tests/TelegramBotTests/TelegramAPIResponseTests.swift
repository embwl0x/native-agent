import Foundation
import Testing
@testable import TelegramBot
import NativeAgentTestSupport

// ConfigurableURLProtocolStub stores its handler per concrete protocol type.
// These separate types keep the adversarial cases independent when Swift
// Testing runs this suite concurrently.
private final class FloodRetryURLProtocol: ConfigurableURLProtocolStub {}
private final class FloodNon429URLProtocol: ConfigurableURLProtocolStub {}
private final class FloodSecondFailureURLProtocol: ConfigurableURLProtocolStub {}

@Suite("Telegram API response validation")
struct TelegramAPIResponseTests {
    @Test func httpFailureRemainsFailureEvenWithTelegramBody() throws {
        let data = try responseData([
            "ok": false,
            "error_code": 502,
            "description": "Bad Gateway",
        ])

        do {
            _ = try TelegramPollLoop._tgValidateResponse(
                data,
                httpStatus: 502,
                operation: "sendChatAction",
                resultType: Bool.self
            )
            Issue.record("expected HTTP failure")
        } catch let failure as TelegramAPIFailure {
            #expect(failure.kind == .httpStatus)
            #expect(failure.httpStatus == 502)
            #expect(failure.errorCode == 502)
        }
    }

    @Test func httpSuccessWithOKFalseIsRejected() throws {
        let data = try responseData([
            "ok": false,
            "error_code": 400,
            "description": "Bad Request: callback query is too old",
        ])

        do {
            _ = try TelegramPollLoop._tgValidateResponse(
                data,
                httpStatus: 200,
                operation: "answerCallbackQuery",
                resultType: Bool.self
            )
            Issue.record("expected semantic rejection")
        } catch let failure as TelegramAPIFailure {
            #expect(failure.kind == .rejected)
            #expect(failure.httpStatus == 200)
            #expect(failure.errorCode == 400)
        }
    }

    @Test func malformedTypedResultFailsHonestly() throws {
        let data = try responseData([
            "ok": true,
            "result": ["chat": ["id": 42]],
        ])

        do {
            _ = try TelegramPollLoop._tgValidateResponse(
                data,
                httpStatus: 200,
                operation: "sendMessage",
                resultType: TelegramAPIMessageResult.self
            )
            Issue.record("expected malformed result failure")
        } catch let failure as TelegramAPIFailure {
            #expect(failure.kind == .malformedResult)
            #expect(failure.httpStatus == 200)
        }
    }

    @Test func messageNotModifiedIsIdempotentOnlyWhenAllowed() throws {
        let data = try responseData([
            "ok": false,
            "error_code": 400,
            "description": "Bad Request: message is not modified",
        ])

        let result = try TelegramPollLoop._tgValidateResponse(
            data,
            httpStatus: 400,
            operation: "editMessageText",
            resultType: TelegramAPIMessageResult.self,
            allowMessageNotModified: true
        )
        guard case .notModified = result else {
            Issue.record("expected idempotent not-modified result")
            return
        }

        #expect(throws: TelegramAPIFailure.self) {
            try TelegramPollLoop._tgValidateResponse(
                data,
                httpStatus: 400,
                operation: "sendMessage",
                resultType: TelegramAPIMessageResult.self
            )
        }
    }

    @Test func retryAndMigrationParametersRemainTyped() throws {
        let data = try responseData([
            "ok": false,
            "error_code": 429,
            "description": "Too Many Requests: retry later",
            "parameters": [
                "retry_after": 17,
                "migrate_to_chat_id": Int64(-1_001_234_567_890),
            ],
        ])

        do {
            _ = try TelegramPollLoop._tgValidateResponse(
                data,
                httpStatus: 429,
                operation: "sendMessage",
                resultType: TelegramAPIMessageResult.self
            )
            Issue.record("expected rate-limit failure")
        } catch let failure as TelegramAPIFailure {
            #expect(failure.kind == .httpStatus)
            #expect(failure.errorCode == 429)
            #expect(failure.parameters?.retryAfter == 17)
            #expect(failure.parameters?.migrateToChatId == -1_001_234_567_890)
            // Both hints must survive the typed transport boundary into the
            // durable error/state owner; otherwise a generic failure hides a
            // rate window or required chat migration from the operator.
            #expect(failure.localizedDescription.contains("retry_after=17s"))
            #expect(failure.localizedDescription.contains("migrate_to_chat_id=-1001234567890"))
        }
    }

    @Test func floodControlRetriesTheConcreteSendPathOnceAfterTheAdvertisedWindow() async throws {
        actor Waits {
            var values: [UInt64] = []
            func record(_ value: UInt64) { values.append(value) }
            func snapshot() -> [UInt64] { values }
        }
        final class Attempts: @unchecked Sendable {
            private let lock = NSLock()
            private var count = 0
            func next() -> Int { lock.withLock { count += 1; return count } }
            func snapshot() -> Int { lock.withLock { count } }
        }
        let attempts = Attempts()
        let waits = Waits()
        let session = FloodRetryURLProtocol.makeSession { request in
            let call = attempts.next()
            if call == 1 {
                return (
                    HTTPURLResponse(url: try #require(request.url), statusCode: 429, httpVersion: nil, headerFields: nil)!,
                    Data(#"{"ok":false,"error_code":429,"parameters":{"retry_after":301}}"#.utf8)
                )
            }
            return (
                HTTPURLResponse(url: try #require(request.url), statusCode: 200, httpVersion: nil, headerFields: nil)!,
                Data(#"{"ok":true,"result":{"message_id":9}}"#.utf8)
            )
        }

        // 2026-09-06 (the per-chat send lane): a 429's retry window becomes a
        // CHAT-LEVEL cooldown on `TelegramChatSendLane.shared`, so a chat id
        // shared with another test leaks that window into it. Each send in this
        // file gets its own chat.
        try await TelegramPollLoop.sendMessage(
            token: "123:abc", chatId: 7_701, text: "one message", session: session,
            sleep: { nanos in await waits.record(nanos) }
        )
        #expect(attempts.snapshot() == 2, "the concrete request path must deliver once after one retry")
        // TWO waits, not one: the retry wrapper sleeps the advertised window,
        // and the lane — which recorded the same window as a chat-level
        // cooldown when the 429 came back — waits out what it still believes is
        // left of it before the second attempt. Under a real clock that
        // remainder is zero; the injected `sleep` does not advance time, so it
        // is visible here. Both are the SAME window, which is the property this
        // test is about: nothing shortens Telegram's advertised retry_after.
        let recordedWaits = await waits.snapshot()
        #expect(recordedWaits.count == 2)
        #expect(recordedWaits.first == 301_000_000_000, "must not shorten Telegram's advertised retry_after")
        #expect(recordedWaits.allSatisfy { $0 > 300_000_000_000 && $0 <= 301_000_000_000 })
    }

    @Test func floodControlDoesNotReplayNon429OrASecondFloodFailure() async throws {
        final class Attempts: @unchecked Sendable {
            private let lock = NSLock()
            private var count = 0
            func next() -> Int { lock.withLock { count += 1; return count } }
            func snapshot() -> Int { lock.withLock { count } }
        }
        actor Waits { var count = 0; func record(_: UInt64) { count += 1 } }

        let non429Attempts = Attempts()
        let non429 = FloodNon429URLProtocol.makeSession { request in
            _ = non429Attempts.next()
            return (
                HTTPURLResponse(url: try #require(request.url), statusCode: 400, httpVersion: nil, headerFields: nil)!,
                Data(#"{"ok":false,"error_code":400,"parameters":{"retry_after":2}}"#.utf8)
            )
        }
        do {
            try await TelegramPollLoop.sendMessage(token: "123:abc", chatId: 7_702, text: "no replay", session: non429)
            Issue.record("expected non-429 rejection")
        } catch {}
        #expect(non429Attempts.snapshot() == 1)

        let secondAttempts = Attempts()
        let waits = Waits()
        let alwaysFlooded = FloodSecondFailureURLProtocol.makeSession { request in
            _ = secondAttempts.next()
            return (
                HTTPURLResponse(url: try #require(request.url), statusCode: 429, httpVersion: nil, headerFields: nil)!,
                Data(#"{"ok":false,"error_code":429,"parameters":{"retry_after":2}}"#.utf8)
            )
        }
        do {
            try await TelegramPollLoop.sendMessage(
                token: "123:abc", chatId: 7_703, text: "one retry only", session: alwaysFlooded,
                sleep: { nanos in await waits.record(nanos) }
            )
            Issue.record("expected second flood-control rejection")
        } catch {}
        #expect(secondAttempts.snapshot() == 2)
        // TWO waits, not one: the retry wrapper sleeps the advertised window,
        // and then the lane — which recorded the same window as a chat-level
        // cooldown when the 429 came back — waits out what it still believes is
        // left of it before the second attempt. Under a real clock that
        // remainder is zero; the injected `sleep` here does not advance time,
        // so the lane's wait is visible. What the test is about is unchanged:
        // exactly two attempts, and no replay of the non-429 rejection above.
        #expect(await waits.count == 2)
    }

    @Test func serverDescriptionCannotLeakBotToken() throws {
        let secret = "7123456789:AAH-secret_Token123"
        let data = try responseData([
            "ok": false,
            "error_code": 400,
            "description": "Bad Request at https://api.telegram.org/bot\(secret)/sendMessage",
        ])

        do {
            _ = try TelegramPollLoop._tgValidateResponse(
                data,
                httpStatus: 200,
                operation: "sendMessage",
                resultType: TelegramAPIMessageResult.self
            )
            Issue.record("expected rejected response")
        } catch let failure as TelegramAPIFailure {
            #expect(!(failure.telegramDescription ?? "").contains(secret))
            #expect(!(failure.localizedDescription).contains(secret))
            #expect((failure.telegramDescription ?? "").contains("[REDACTED_TELEGRAM_TOKEN]"))
        }
    }

    @Test func validMessageAndBooleanResultsDecode() throws {
        let messageData = try responseData([
            "ok": true,
            "result": ["message_id": 42, "text": "sent"],
        ])
        let message = try TelegramPollLoop._tgValidateResponse(
            messageData,
            httpStatus: 200,
            operation: "sendMessage",
            resultType: TelegramAPIMessageResult.self
        )
        #expect(message.value.messageId == 42)

        let boolData = try responseData(["ok": true, "result": true])
        let boolean = try TelegramPollLoop._tgValidateResponse(
            boolData,
            httpStatus: 200,
            operation: "sendChatAction",
            resultType: Bool.self
        )
        #expect(boolean.value)
    }

    @Test func richMethodsUseTheSameSemanticResultValidator() throws {
        let rejectedFinal = try responseData([
            "ok": false,
            "error_code": 400,
            "description": "Bad Request: rich messages are unavailable",
        ])
        #expect(throws: TelegramAPIFailure.self) {
            try TelegramPollLoop._tgValidateResponse(
                rejectedFinal,
                httpStatus: 200,
                operation: "sendRichMessage",
                resultType: TelegramAPIMessageResult.self
            )
        }

        let falseDraft = try responseData(["ok": true, "result": false])
        do {
            _ = try TelegramPollLoop._tgValidateResponse(
                falseDraft,
                httpStatus: 200,
                operation: "sendRichMessageDraft",
                resultType: Bool.self,
                validateResult: { $0 }
            )
            Issue.record("expected false rich-draft result to fail")
        } catch let failure as TelegramAPIFailure {
            #expect(failure.kind == .malformedResult)
            #expect(failure.operation == "sendRichMessageDraft")
        }
    }

    private func responseData(_ object: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }
}
