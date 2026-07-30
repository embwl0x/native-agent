import Testing
import Foundation
@testable import TelegramBot

// chat-smoothness phase 5 (2026-06-12): growing-draft streaming. Telegram has
// no token stream — the draft message is sent once, then EDITED with the
// accumulated text on a throttle; finalize completes it and reports what (if
// anything) still needs a plain send. These tests pin the streamer against
// injected fakes — no network.

private actor DraftTransportSpy {
    var sends: [String] = []
    var edits: [(messageId: Int, text: String)] = []
    var failEdits = false
    var failSends = false
    /// Counts every edit ATTEMPT (success or failure) so tests can pin the
    /// retry/abort sequence after a failed final edit.
    private(set) var editAttempts = 0
    /// Fail only this many leading edit attempts, then succeed — drives the
    /// single-retry path in finalize.
    var failLeadingEditAttempts = 0
    let messageId = 4242

    func send(_ text: String) throws -> Int {
        if failSends { throw TelegramBotError.underlying("send refused") }
        sends.append(text)
        return messageId
    }

    func edit(_ messageId: Int, _ text: String) throws {
        editAttempts += 1
        if failEdits || editAttempts <= failLeadingEditAttempts {
            throw TelegramBotError.underlying("edit refused")
        }
        edits.append((messageId, text))
    }

    func setFailEdits(_ v: Bool) { failEdits = v }
    func setFailSends(_ v: Bool) { failSends = v }
    func setFailLeadingEditAttempts(_ v: Int) { failLeadingEditAttempts = v }
}

private func makeStreamer(
    interval: TimeInterval = 0,
    spy: DraftTransportSpy
) -> TelegramDraftStreamer {
    TelegramDraftStreamer(
        token: "tok",
        chatId: 7,
        editIntervalSeconds: interval,
        sendReturningId: { _, _, text in try await spy.send(text) },
        editMessage: { _, _, id, text in try await spy.edit(id, text) }
    )
}

@Test func first_delta_sends_draft_then_edits_grow_it() async throws {
    let spy = DraftTransportSpy()
    let streamer = makeStreamer(spy: spy)

    await streamer.onDelta("Hello")
    await streamer.onDelta("Hello there the user")

    #expect(await spy.sends == ["Hello"])
    let edits = await spy.edits
    #expect(edits.count == 1)
    #expect(edits.first?.messageId == 4242)
    #expect(edits.first?.text == "Hello there the user")
}

@Test func throttle_skips_updates_inside_the_interval() async throws {
    let spy = DraftTransportSpy()
    let streamer = makeStreamer(interval: 60, spy: spy)   // nothing can pass twice

    await streamer.onDelta("first")
    await streamer.onDelta("first plus more")
    await streamer.onDelta("first plus even more")

    #expect(await spy.sends == ["first"])
    #expect(await spy.edits.isEmpty, "updates inside the throttle window must be dropped")
}

@Test func finalize_without_draft_returns_whole_reply() async throws {
    let spy = DraftTransportSpy()
    let streamer = makeStreamer(spy: spy)

    let remainder = await streamer.finalize(reply: "complete answer")

    #expect(remainder == ["complete answer"])
    #expect(await spy.edits.isEmpty)
}

@Test func finalize_edits_draft_to_final_text_and_reports_nothing_left() async throws {
    let spy = DraftTransportSpy()
    let streamer = makeStreamer(spy: spy)

    await streamer.onDelta("partial")
    let remainder = await streamer.finalize(reply: "partial but now complete")

    #expect(remainder.isEmpty)
    #expect(await spy.edits.last?.text == "partial but now complete")
}

@Test func finalize_skips_redundant_edit_when_text_unchanged() async throws {
    let spy = DraftTransportSpy()
    let streamer = makeStreamer(spy: spy)

    await streamer.onDelta("the whole reply")
    let editsBefore = await spy.edits.count
    let remainder = await streamer.finalize(reply: "the whole reply")

    #expect(remainder.isEmpty)
    #expect(await spy.edits.count == editsBefore, "identical final text must not re-edit")
}

@Test func finalize_long_reply_returns_overflow_for_plain_send() async throws {
    let spy = DraftTransportSpy()
    let streamer = makeStreamer(spy: spy)
    // Two chunks: line-boundary split at the 4000 UTF-16 budget.
    let lineA = String(repeating: "a", count: 3_500)
    let lineB = String(repeating: "b", count: 3_500)
    let reply = lineA + "\n" + lineB

    await streamer.onDelta("partial")
    let remainder = await streamer.finalize(reply: reply)

    #expect(await spy.edits.last?.text == lineA, "draft holds the first chunk")
    #expect(remainder == [lineB], "overflow chunks go back to the caller for plain send")
}

@Test func finalize_hard_split_long_line_returns_exact_chunks() async throws {
    let spy = DraftTransportSpy()
    let streamer = makeStreamer(spy: spy)
    // 9000 chars with NO newline — chunking must hard-split, and the overflow
    // must come back as exact chunks (a "\n" join would corrupt the line).
    let solid = String(repeating: "x", count: 9_000)

    await streamer.onDelta("partial")
    let remainder = await streamer.finalize(reply: solid)

    let delivered = (await spy.edits.last?.text ?? "") + remainder.joined()
    #expect(delivered == solid, "draft + overflow chunks must reassemble byte-exact")
    #expect(remainder.allSatisfy { $0.utf16.count <= 4_000 })
}

@Test func failed_final_edit_falls_back_to_whole_reply() async throws {
    let spy = DraftTransportSpy()
    let streamer = makeStreamer(spy: spy)

    await streamer.onDelta("partial")
    await spy.setFailEdits(true)
    let remainder = await streamer.finalize(reply: "the real answer")

    #expect(remainder == ["the real answer"],
            "a failed final edit must never lose the reply — caller sends it whole")
    // 2026-07-21 audit: final edit + one retry + the abort attempt before
    // the full re-send fallback — three edit attempts, none delivered.
    #expect(await spy.editAttempts == 3)
}

@Test func failed_final_edit_retries_once_before_fallback() async throws {
    let spy = DraftTransportSpy()
    let streamer = makeStreamer(spy: spy)

    await streamer.onDelta("partial")
    await spy.setFailLeadingEditAttempts(1)   // first final edit fails, retry succeeds
    let remainder = await streamer.finalize(reply: "the real answer")

    #expect(remainder.isEmpty, "a successful retry completes the draft — nothing left to send")
    #expect(await spy.editAttempts == 2)
    #expect(await spy.edits.last?.text == "the real answer")
}

@Test func unrecoverable_final_edit_aborts_stale_draft_before_full_resend() async throws {
    let spy = DraftTransportSpy()
    let streamer = makeStreamer(spy: spy)

    await streamer.onDelta("partial")
    await spy.setFailLeadingEditAttempts(2)   // final edit + retry fail; abort edit succeeds
    let remainder = await streamer.finalize(reply: "the real answer")

    #expect(remainder == ["the real answer"], "reply still falls back to a whole send")
    #expect(await spy.editAttempts == 3)
    #expect(await spy.edits.last?.text == "(draft update failed — the full reply follows as new messages)",
            "the dangling partial draft must be converted to an honest notice, not left stale")
}

@Test func failed_first_send_keeps_turn_alive_and_finalize_falls_back() async throws {
    let spy = DraftTransportSpy()
    await spy.setFailSends(true)
    let streamer = makeStreamer(spy: spy)

    await streamer.onDelta("partial")          // send fails silently
    let remainder = await streamer.finalize(reply: "answer")

    #expect(remainder == ["answer"], "no draft was created — whole reply goes to sendMessage")
}

@Test func abort_edits_dangling_draft_to_notice() async throws {
    let spy = DraftTransportSpy()
    let streamer = makeStreamer(spy: spy)

    await streamer.onDelta("partial text that would dangle")
    let delivered = await streamer.abortDelivering(notice: "(turn failed)")

    #expect(delivered)
    #expect(await spy.edits.last?.text == "(turn failed)")
}

@Test func abort_without_draft_reports_not_delivered() async throws {
    let spy = DraftTransportSpy()
    let streamer = makeStreamer(spy: spy)

    let delivered = await streamer.abortDelivering(notice: "(turn failed)")

    #expect(!delivered, "no draft — caller sends its own notice")
    #expect(await spy.edits.isEmpty)
}

@Test func mid_stream_draft_window_caps_at_one_telegram_chunk() async throws {
    let spy = DraftTransportSpy()
    let streamer = makeStreamer(spy: spy)
    let huge = String(repeating: "x", count: 9_000)

    await streamer.onDelta(huge)

    let sent = await spy.sends.first ?? ""
    #expect(sent.utf16.count <= 4_000, "mid-stream draft must stay one Telegram-safe message")
}
