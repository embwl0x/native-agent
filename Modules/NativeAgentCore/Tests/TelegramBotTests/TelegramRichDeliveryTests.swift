import Foundation
import Testing
@testable import TelegramBot

private struct RichDeliveryTestError: Error, Sendable, CustomStringConvertible {
    let description: String
}

private actor RichDeliverySpy {
    var richDrafts: [TelegramInputRichMessage] = []
    var richFinals: [TelegramInputRichMessage] = []
    var ordinarySends: [String] = []
    var ordinaryDraftSends: [String] = []
    var ordinaryEdits: [String] = []
    var richDraftError: Error?
    var richFinalError: Error?

    func sendRichDraft(_ message: TelegramInputRichMessage) throws {
        richDrafts.append(message)
        if let richDraftError { throw richDraftError }
    }

    func sendRichFinal(_ message: TelegramInputRichMessage) throws -> Int {
        richFinals.append(message)
        if let richFinalError { throw richFinalError }
        return 909
    }

    func sendOrdinary(_ text: String) {
        ordinarySends.append(text)
    }

    func sendOrdinaryDraft(_ text: String) -> Int {
        ordinaryDraftSends.append(text)
        return 707
    }

    func editOrdinaryDraft(_ text: String) {
        ordinaryEdits.append(text)
    }

    func setRichDraftError(_ error: Error?) { richDraftError = error }
    func setRichFinalError(_ error: Error?) { richFinalError = error }
}

private func makeRichDelivery(
    spy: RichDeliverySpy,
    richEnabled: Bool = true
) -> TelegramAssistantDeliveryDriver {
    let ordinary = TelegramDraftStreamer(
        token: "test-token",
        chatId: 44,
        editIntervalSeconds: 0,
        sendReturningId: { _, _, text in
            await spy.sendOrdinaryDraft(text)
        },
        editMessage: { _, _, _, text in
            await spy.editOrdinaryDraft(text)
        }
    )
    let richDraft: TelegramAssistantDeliveryDriver.SendRichDraft?
    let richFinal: TelegramAssistantDeliveryDriver.SendRichFinal?
    if richEnabled {
        richDraft = { _, _, _, message in try await spy.sendRichDraft(message) }
        richFinal = { _, _, message in try await spy.sendRichFinal(message) }
    } else {
        richDraft = nil
        richFinal = nil
    }
    return TelegramAssistantDeliveryDriver(
        token: "test-token",
        chatId: 44,
        turnId: UUID(uuidString: "00000000-0000-0000-0000-000000000044")!,
        ordinary: ordinary,
        sendOrdinary: { _, _, text in await spy.sendOrdinary(text) },
        sendRichDraft: richDraft,
        sendRichFinal: richFinal,
        richDraftInterval: 0
    )
}

@Suite("Telegram Bot API 10.2 rich delivery")
struct TelegramRichDeliveryTests {
    @Test func richDraftAndFinalUseOneRichReplyWithoutOrdinaryDuplicate() async {
        let spy = RichDeliverySpy()
        let delivery = makeRichDelivery(spy: spy)

        await delivery.onDelta("# Result\nPartial")
        let outcome = await delivery.finalize(reply: "# Result\nComplete")

        #expect(outcome == .delivered(messageId: 909))
        #expect(await spy.richDrafts.count == 1)
        #expect(await spy.richFinals.count == 1)
        #expect(await spy.ordinaryDraftSends.isEmpty)
        #expect(await spy.ordinarySends.isEmpty)
    }

    @Test func semanticRejectionFallsBackExactlyOnceToOrdinaryDelivery() async {
        let spy = RichDeliverySpy()
        await spy.setRichFinalError(TelegramAPIFailure(
            kind: .rejected,
            operation: "sendRichMessage",
            httpStatus: 200,
            errorCode: 400,
            telegramDescription: "method unsupported"
        ))
        let delivery = makeRichDelivery(spy: spy)

        let outcome = await delivery.finalize(reply: "Safe fallback")

        #expect(outcome == .delivered(messageId: nil))
        #expect(await spy.richFinals.count == 1)
        #expect(await spy.ordinarySends == ["Safe fallback"])
    }

    @Test func malformedOrFailedEphemeralDraftSafelyMovesToOrdinaryLane() async {
        let spy = RichDeliverySpy()
        await spy.setRichDraftError(TelegramAPIFailure(
            kind: .malformedResult,
            operation: "sendRichMessageDraft",
            httpStatus: 200
        ))
        let delivery = makeRichDelivery(spy: spy)

        await delivery.onDelta("partial answer")
        let outcome = await delivery.finalize(reply: "complete answer")

        #expect(outcome == .delivered(messageId: nil))
        #expect(await spy.richDrafts.count == 1)
        #expect(await spy.richFinals.isEmpty)
        #expect(await spy.ordinaryDraftSends == ["partial answer"])
        #expect(await spy.ordinaryEdits.last == "complete answer")
        #expect(await spy.ordinarySends.isEmpty)
    }

    @Test func malformedFinalResultIsAmbiguousAndNeverFallsBack() async {
        let spy = RichDeliverySpy()
        await spy.setRichFinalError(TelegramAPIFailure(
            kind: .malformedResult,
            operation: "sendRichMessage",
            httpStatus: 200
        ))
        let delivery = makeRichDelivery(spy: spy)

        let outcome = await delivery.finalize(reply: "Do not duplicate me")

        guard case .outcomeUnknown = outcome else {
            Issue.record("expected outcome-unknown")
            return
        }
        #expect(await spy.richFinals.count == 1)
        #expect(await spy.ordinarySends.isEmpty)
        #expect(await spy.ordinaryDraftSends.isEmpty)
    }

    @Test func ambiguousNetworkFinalNeverFallsBackOrRetries() async {
        let spy = RichDeliverySpy()
        await spy.setRichFinalError(URLError(.networkConnectionLost))
        let delivery = makeRichDelivery(spy: spy)

        let outcome = await delivery.finalize(reply: "Maybe delivered")

        guard case .outcomeUnknown = outcome else {
            Issue.record("expected outcome-unknown")
            return
        }
        #expect(await spy.richFinals.count == 1)
        #expect(await spy.ordinarySends.isEmpty)
    }

    @Test func explicitOrdinaryLanePreservesExistingFallback() async {
        let spy = RichDeliverySpy()
        let delivery = makeRichDelivery(spy: spy, richEnabled: false)

        await delivery.onDelta("partial")
        let outcome = await delivery.finalize(reply: "final")

        #expect(outcome == .delivered(messageId: nil))
        #expect(await spy.richDrafts.isEmpty)
        #expect(await spy.richFinals.isEmpty)
        #expect(await spy.ordinaryDraftSends == ["partial"])
        #expect(await spy.ordinaryEdits.last == "final")
    }

    @Test func ordinaryFallbackAlsoExcludesReasoningAndSecrets() async {
        let spy = RichDeliverySpy()
        let delivery = makeRichDelivery(spy: spy, richEnabled: false)
        let secret = "7123456789:AAH-secret_Token123"

        let outcome = await delivery.finalize(reply: """
        <analysis>never visible</analysis>
        User-safe answer \(secret)
        """)

        #expect(outcome == .delivered(messageId: nil))
        let sent = await spy.ordinarySends.joined(separator: "\n")
        #expect(!sent.contains("never visible"))
        #expect(!sent.contains(secret))
        #expect(sent.contains("[REDACTED_TELEGRAM_TOKEN]"))
    }

    @Test func oversizedRichReplyFallsBackLosslesslyWithoutRichDispatch() async {
        let spy = RichDeliverySpy()
        let delivery = makeRichDelivery(spy: spy)
        let reply = String(repeating: "long answer ", count: 4_000) + "end"

        let outcome = await delivery.finalize(reply: reply)

        #expect(outcome == .delivered(messageId: nil))
        #expect(await spy.richFinals.isEmpty)
        #expect(await spy.ordinarySends == [reply])
    }

    @Test func rendererBuildsSafeBoundedHeadingsCodeTablesAndDetails() throws {
        let openAISecret = "sk-proj-ABCDEFGHIJKLMNOPQRSTUVWXYZ1234567890"
        let token = "7123456789:AAH-secret_Token123"
        let raw = """
        <analysis>private chain of thought</analysis>
        # Heading

        ```swift
        let value = 1
        ```

        | Name | Value |
        | --- | --- |
        | token | \(token) |

        <details>
        <summary>More</summary>
        hidden_reasoning: never show this
        User-safe detail with \(openAISecret)
        </details>
        """

        let rendered = try #require(TelegramRichMessageRenderer.render(raw))
        let serialized = try rendered.jsonValue.serialize(pretty: false)

        #expect(rendered.blocks.contains {
            if case .heading(text: "Heading", size: 1) = $0 { return true }
            return false
        })
        #expect(rendered.blocks.contains {
            if case .preformatted = $0 { return true }
            return false
        })
        #expect(rendered.blocks.contains {
            if case .table = $0 { return true }
            return false
        })
        #expect(rendered.blocks.contains {
            if case .details = $0 { return true }
            return false
        })
        #expect(!serialized.contains("private chain of thought"))
        #expect(!serialized.contains("hidden_reasoning"))
        #expect(!serialized.contains(openAISecret))
        #expect(!serialized.contains(token))
        #expect(serialized.contains("[REDACTED_OPENAI_KEY]"))
        #expect(serialized.contains("bot<redacted>") || serialized.contains("[REDACTED_TELEGRAM_TOKEN]"))
        #expect(serialized.utf8.count <= TelegramRichMessageRenderer.maximumUTF8Bytes + 20_000)
        #expect(rendered.blocks.count <= TelegramRichMessageRenderer.maximumBlocks)
    }

    @Test func rendererBoundsTableShapeAndRejectsWholeReplyTruncation() throws {
        let rows = (0..<80).map { "| \($0) | a | b | c | d | e | f | g | h | i | j | k | l | m |" }
        let raw = (["| n | 1 | 2 | 3 | 4 | 5 | 6 | 7 | 8 | 9 | 10 | 11 | 12 | 13 |",
                    "| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |"]
            + rows)
            .joined(separator: "\n")

        let rendered = try #require(TelegramRichMessageRenderer.render(raw))
        let serialized = try rendered.jsonValue.serialize(pretty: false)

        #expect(serialized.utf8.count < 45_000)
        if case .table(let tableRows) = rendered.blocks.first {
            #expect(tableRows.count == TelegramRichMessageRenderer.maximumTableRows)
            #expect(tableRows.allSatisfy { $0.count <= TelegramRichMessageRenderer.maximumTableColumns })
        } else {
            Issue.record("expected bounded table")
        }

        #expect(TelegramRichMessageRenderer.render(
            String(repeating: "é", count: 40_000)
        ) == nil, "oversized replies must fall back whole instead of losing their tail")
    }
}
