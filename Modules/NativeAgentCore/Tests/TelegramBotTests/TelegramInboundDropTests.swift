import Foundation
import Testing
@testable import TelegramBot
import NativeAgentTestSupport
import PersistenceCore

// MARK: - Coverage ledger: telegram.config.requireMention
//                         telegram.media.unsupportedAttachmentSilentDrop
//                         telegram.blocked.jsonl
//
// Refusals retain bounded blocked evidence. Admitted unsupported documents
// and videos also report the missing capability without starting a turn or
// bypassing the mention gate. Pin the existing reason vocabulary, notices,
// receipts, duplicate-update behavior, and canonical feed cap.

private final class TelegramInboundDropStub: ConfigurableURLProtocolStub {}

private final class TelegramInboundDropResponses: @unchecked Sendable {
    private let lock = NSLock()
    private var payload = Data(#"{"ok":true,"result":[]}"#.utf8)

    func setUpdate(_ json: String) {
        lock.lock(); defer { lock.unlock() }
        payload = Data("{\"ok\":true,\"result\":[\(json)]}".utf8)
    }

    func data() -> Data {
        lock.lock(); defer { lock.unlock() }
        return payload
    }
}

private actor InboundDropCapture {
    private(set) var sent: [String] = []
    private(set) var handled: [(chatId: Int, text: String)] = []

    func send(_ text: String) { sent.append(text) }
    func handle(chatId: Int, text: String) { handled.append((chatId: chatId, text: text)) }
    func sentSnapshot() -> [String] { sent }
    func handledCount() -> Int { handled.count }
    func handledTexts() -> [String] { handled.map(\.text) }
}

private func makeDropLoop(
    root: URL,
    requireMention: Bool,
    responses: TelegramInboundDropResponses,
    capture: InboundDropCapture,
    failNoticeSend: Bool = false
) -> TelegramPollLoop {
    let session = TelegramInboundDropStub.makeSession { request in
        (
            HTTPURLResponse(
                url: request.url ?? URL(string: "https://api.telegram.org")!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil
            )!,
            responses.data()
        )
    }
    return TelegramPollLoop(
        interval: 60,
        token: "drop-token",
        allowedChatIds: [-1001],
        allowedUserIds: [11],
        requireMention: requireMention,
        session: session,
        dataRoot: root,
        offsetURL: root
            .appendingPathComponent("telegram", isDirectory: true)
            .appendingPathComponent("last_offset.json"),
        sendMessage: { _, _, text in
            if failNoticeSend { throw URLError(.networkConnectionLost) }
            await capture.send(text)
        },
        sendChatAction: { _, _, _ in },
        answerCallbackQuery: { _, _, _ in },
        sendMessageReturningId: { _, _, text in
            await capture.send(text)
            return 4242
        },
        sendMessageWithReplyMarkupReturningId: { _, _, text, _ in
            await capture.send(text)
            return 4243
        },
        editMessageText: { _, _, _, _ in },
        editMessageTextWithReplyMarkup: { _, _, _, _, _ in },
        draftEditIntervalSeconds: 0,
        turnCardMinimumEditIntervalSeconds: 0,
        turnCardHeartbeatNanoseconds: 0,
        turnStopConfirmationNanoseconds: 100_000_000,
        chatHandler: { chatId, text in
            await capture.handle(chatId: chatId, text: text)
            return "ack"
        },
        voiceDownloader: nil,
        photoDownloader: nil,
        typingRefreshNanoseconds: 0,
        turnCoordinator: TelegramTurnCoordinator()
    )
}

private func groupMessageUpdate(updateId: Int, text: String) -> String {
    let escaped = text.replacingOccurrences(of: "\"", with: "\\\"")
    return """
    {"update_id":\(updateId),"message":{"message_id":\(updateId),"chat":{"id":-1001,"type":"supergroup"},"from":{"id":11},"text":"\(escaped)","date":1}}
    """
}

@Suite(.serialized)
struct TelegramInboundDropTests {

    /// The turn runs in its own Task, so the positive controls poll for the
    /// handler rather than assuming it ran by the time `tickOutcome` returns.
    /// Bounded (15s) so a genuinely dropped message fails loudly instead of
    /// hanging the suite; it returns the instant the handler fires, so the
    /// bound costs nothing on a healthy run. 2s was too tight under a loaded
    /// machine and flaked once during this wave.
    private func waitForHandler(_ capture: InboundDropCapture) async -> Bool {
        for _ in 0..<1500 {
            if await capture.handledCount() > 0 { return true }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return false
    }

    // MARK: requireMention

    /// The gate is `text.contains("@")` in a NEGATIVE-id chat. Nothing drove
    /// the branch; the only refs were a Codable round-trip of the status field.
    @Test func requireMention_drops_an_unmentioned_group_message_and_never_starts_a_turn() async throws {
        let root = hermeticTelegramDataRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let responses = TelegramInboundDropResponses()
        let capture = InboundDropCapture()
        let loop = makeDropLoop(root: root, requireMention: true, responses: responses, capture: capture)

        responses.setUpdate(groupMessageUpdate(updateId: 11, text: "someone else is talking"))
        _ = await loop.tickOutcome()

        let blocked = await telegramFeedRows(root: root, "blocked")
        #expect(telegramFeedStrings(blocked, "reason") == ["mention_required"])
        #expect(await capture.handledCount() == 0)
        #expect(await capture.sentSnapshot().isEmpty)
    }

    @Test func requireMention_lets_a_mentioning_group_message_through() async throws {
        let root = hermeticTelegramDataRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let responses = TelegramInboundDropResponses()
        let capture = InboundDropCapture()
        let loop = makeDropLoop(root: root, requireMention: true, responses: responses, capture: capture)

        responses.setUpdate(groupMessageUpdate(updateId: 12, text: "@agent are you there"))
        _ = await loop.tickOutcome()

        #expect(await waitForHandler(capture))
        #expect(await telegramFeedRows(root: root, "blocked").isEmpty)
    }

    /// Off by default: the same unmentioned line must reach the turn. Without
    /// this, a gate stuck ON would look identical to a healthy bot that simply
    /// gets no group traffic.
    @Test func requireMention_off_lets_an_unmentioned_group_message_through() async throws {
        let root = hermeticTelegramDataRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let responses = TelegramInboundDropResponses()
        let capture = InboundDropCapture()
        let loop = makeDropLoop(root: root, requireMention: false, responses: responses, capture: capture)

        responses.setUpdate(groupMessageUpdate(updateId: 13, text: "no at sign here"))
        _ = await loop.tickOutcome()

        #expect(await waitForHandler(capture))
        #expect(await telegramFeedRows(root: root, "blocked").isEmpty)
    }

    // MARK: non-image attachment drop

    /// Unsupported documents remain no-turn drops, with one truthful notice,
    /// delivered-notice receipt, and redacted attachment trace.
    // Historical function name is retained for the coverage-ledger anchor.
    @Test func nonImageDocument_is_dropped_with_no_user_facing_evidence() async throws {
        let root = hermeticTelegramDataRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let responses = TelegramInboundDropResponses()
        let capture = InboundDropCapture()
        let loop = makeDropLoop(root: root, requireMention: false, responses: responses, capture: capture)

        responses.setUpdate("""
        {"update_id":21,"message":{"message_id":21,"chat":{"id":-1001,"type":"supergroup"},"from":{"id":11},"date":1,"document":{"file_id":"DOC-1","mime_type":"application/pdf","file_size":2048,"file_name":"contract.pdf"}}}
        """)
        _ = await loop.tickOutcome()

        let blocked = await telegramFeedRows(root: root, "blocked")
        #expect(telegramFeedStrings(blocked, "reason") == ["empty_or_non_text"])
        #expect(await capture.handledCount() == 0)

        let traces = (try? await SwiftNativePersistenceCore().readJSONL(
            root.appendingPathComponent("traces", isDirectory: true)
                .appendingPathComponent("events.jsonl")
        )) ?? []
        let droppedTraces = traces.filter {
            guard case .object(let row) = $0 else { return false }
            return row["kind"] == .string("telegram.attachment_dropped")
        }
        let notices = await capture.sentSnapshot()

        #expect(notices.count == 1)
        #expect(notices.first?.contains("can't read that document") == true)
        #expect(droppedTraces.count == 1)
        let receipts = await telegramFeedRows(root: root, "receipts")
        #expect(receipts.filter { $0["kind"] == .string("attachment_dropped") }.count == 1)
        #expect(!String(describing: droppedTraces).contains("DOC-1"))
        #expect(!notices.joined().contains("contract.pdf"))
        // Repeated delivery of the same update cannot repeat the notice.
        _ = await loop.tickOutcome()
        #expect(await capture.sentSnapshot() == notices)
    }

    /// A video takes the same path — pinned so a future notice has to cover
    /// the whole class rather than one file type.
    @Test func inboundVideo_takes_the_same_drop_path() async throws {
        let root = hermeticTelegramDataRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let responses = TelegramInboundDropResponses()
        let capture = InboundDropCapture()
        let loop = makeDropLoop(root: root, requireMention: false, responses: responses, capture: capture)

        responses.setUpdate("""
        {"update_id":22,"message":{"message_id":22,"chat":{"id":-1001,"type":"supergroup"},"from":{"id":11},"date":1,"video":{"file_id":"VID-1","mime_type":"video/mp4","file_size":9999}}}
        """)
        _ = await loop.tickOutcome()

        let blocked = await telegramFeedRows(root: root, "blocked")
        #expect(telegramFeedStrings(blocked, "reason") == ["empty_or_non_text"])
        #expect(await capture.handledCount() == 0)
        #expect(await capture.sentSnapshot().count == 1)
        #expect(await capture.sentSnapshot().first?.contains("can't read that video") == true)
    }

    @Test(arguments: [false, true])
    func unsupportedAttachment_never_notifies_an_outsider_or_unmentioned_group(requireMention: Bool) async throws {
        let root = hermeticTelegramDataRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let responses = TelegramInboundDropResponses()
        let capture = InboundDropCapture()
        let loop = makeDropLoop(root: root, requireMention: requireMention, responses: responses, capture: capture)
        let chat = requireMention ? -1001 : -9999
        let user = requireMention ? 11 : 9999
        responses.setUpdate("""
        {"update_id":31,"message":{"message_id":31,"chat":{"id":\(chat)},"from":{"id":\(user)},"video":{"file_id":"VID-1"}}}
        """)
        _ = await loop.tickOutcome()
        #expect(await capture.sentSnapshot().isEmpty)
        #expect(await capture.handledCount() == 0)
        #expect(await telegramFeedRows(root: root, "receipts").isEmpty)
    }

    @Test func unsupportedAttachment_caption_keeps_its_original_text_turn() async throws {
        let root = hermeticTelegramDataRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let responses = TelegramInboundDropResponses()
        let capture = InboundDropCapture()
        let loop = makeDropLoop(root: root, requireMention: true, responses: responses, capture: capture)
        responses.setUpdate("""
        {"update_id":32,"message":{"message_id":32,"chat":{"id":-1001},"from":{"id":11},"caption":"@agent my caption","document":{"file_id":"DOC-1","mime_type":"application/pdf"}}}
        """)
        _ = await loop.tickOutcome()
        #expect(await waitForHandler(capture))
        await loop.shutdown()
        #expect(await capture.handledTexts() == ["@agent my caption"])
        #expect(await capture.sentSnapshot().filter { $0.contains("can't read that document") }.count == 1)
    }

    @Test func unsupportedAttachment_failed_notice_is_not_receipted_as_delivered() async throws {
        let root = hermeticTelegramDataRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let responses = TelegramInboundDropResponses()
        let capture = InboundDropCapture()
        let loop = makeDropLoop(root: root, requireMention: false, responses: responses, capture: capture, failNoticeSend: true)
        responses.setUpdate("""
        {"update_id":33,"message":{"message_id":33,"chat":{"id":-1001},"from":{"id":11},"video":{"file_id":"VID-1"}}}
        """)
        _ = await loop.tickOutcome()
        #expect(await capture.sentSnapshot().isEmpty)
        #expect(await capture.handledCount() == 0)
        #expect(await telegramFeedRows(root: root, "receipts").isEmpty)
        let errors = await telegramFeedRows(root: root, "errors")
        #expect(errors.contains { $0["context"] == .string("send_unsupported_attachment_notice") })
    }

    // MARK: blocked.jsonl vocabulary + cap (source conformance)

    /// blocked.jsonl's reason strings are the only machine-readable account of
    /// why a message never got an answer. A new reason added without a ledger
    /// row, or a reason whose last writer was deleted (the live feed's
    /// `stale_update`), both go unnoticed. Same shape as the other
    /// source-conformance guards (NoPythonRegressionTests,
    /// LoopRunnerCatchOverrideGuardTests).
    @Test func blockedReasonVocabulary_matches_the_declared_set() throws {
        let declared: Set<String> = [
            "allowlist_empty_fail_closed",
            "not_allowlisted",
            "mention_required",
            "no_message",
            "empty_or_non_text",
            "chat_handler_not_configured",
            "unsupported_slash_command",
            // 2026-09-06: a group delivers `/cmd@OtherBot` to every bot in the
            // room and slash dispatch runs BEFORE the mention filter, so
            // `/stop@SomeOtherBot` used to stop this agent's own turn. A
            // command addressed to another bot is dropped with this reason.
            "command_for_other_bot",
        ]

        let sourceDir = try SourceTreeRepoRoot.locate()
            .appendingPathComponent("Modules/NativeAgentCore/Sources/TelegramBot", isDirectory: true)
        let files = try FileManager.default
            .contentsOfDirectory(at: sourceDir, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" }
        #expect(files.count > 10)

        var found: Set<String> = []
        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            var cursor = text.startIndex
            while let call = text.range(of: "recordBlocked(", range: cursor..<text.endIndex) {
                cursor = call.upperBound
                let windowEnd = text.index(call.upperBound, offsetBy: 400, limitedBy: text.endIndex)
                    ?? text.endIndex
                var segment = String(text[call.upperBound..<windowEnd])
                // Stop at the next argument label so only `reason:` literals
                // are harvested; the declaration site yields nothing.
                if let stop = segment.range(of: "update:") {
                    segment = String(segment[..<stop.lowerBound])
                }
                let pieces = segment.split(
                    separator: "\"", omittingEmptySubsequences: false
                )
                for piece in pieces.enumerated() where piece.offset % 2 == 1 {
                    found.insert(String(piece.element))
                }
            }
        }

        #expect(!found.isEmpty, "the scanner found no recordBlocked reasons — it broke, not the code")
        #expect(found == declared, "blocked.jsonl reason vocabulary drifted: \(found.symmetricDifference(declared).sorted())")
        // Dead vocabulary check: the live feed carries rows for this reason and
        // no writer remains. It must not silently come back either.
        #expect(!found.contains("stale_update"))
    }

    /// Keep the blocked feed on the same canonical capped writer as receipts.
    @Test func blockedFeed_should_be_line_capped_like_its_siblings() throws {
        // The sibling feeds are bounded; this is the one that is not.
        #expect(JSONLLineCaps.telegramReceipts > 0)

        let source = try String(
            contentsOf: SourceTreeRepoRoot.locate()
                .appendingPathComponent(
                    "Modules/NativeAgentCore/Sources/TelegramBot/TelegramPollLoop+StateReceipts.swift",
                    isDirectory: false
                ),
            encoding: .utf8
        )
        let recordBlockedBody: String = {
            guard let start = source.range(of: "    func recordBlocked(") else { return "" }
            let rest = source[start.upperBound...]
            guard let end = rest.range(of: "\n    /// Strip the bot token") else { return String(rest) }
            return String(rest[..<end.lowerBound])
        }()
        #expect(recordBlockedBody.contains("blocked.jsonl"))

        #expect(JSONLLineCaps.telegramBlocked > 0)
        #expect(recordBlockedBody.contains("appendJSONLCapped"))
        #expect(recordBlockedBody.contains("JSONLLineCaps.telegramBlocked"))
    }

    @Test func blockedFeed_retains_newest_history_when_a_new_row_crosses_the_cap() async throws {
        let root = hermeticTelegramDataRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let responses = TelegramInboundDropResponses()
        let capture = InboundDropCapture()
        let loop = makeDropLoop(root: root, requireMention: false, responses: responses, capture: capture)
        let path = root.appendingPathComponent("telegram/blocked.jsonl")
        try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        let cap = JSONLLineCaps.telegramBlocked
        let rows = (0..<cap).map { "{\"updateId\":\($0),\"reason\":\"not_allowlisted\"}" }
        try (rows.joined(separator: "\n") + "\n").write(to: path, atomically: true, encoding: .utf8)
        await loop.recordBlocked(reason: "not_allowlisted", update: TelegramUpdate(updateId: cap, message: nil), message: nil, text: nil)
        let retained = await telegramFeedRows(root: root, "blocked")
        #expect(retained.count == cap)
        #expect(retained.first?["updateId"] == .int(1))
        #expect(retained.last?["updateId"] == .int(Int64(cap)))
    }
}
