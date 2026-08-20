import Foundation
import Testing
@testable import TelegramBot

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
        }
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
            #expect((failure.telegramDescription ?? "").contains("bot<redacted>"))
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
