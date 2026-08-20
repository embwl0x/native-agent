import Testing
import Foundation
@testable import TelegramBot
import NativeAgentCore
import NativeAgentTestSupport
import PersistenceCore

// MARK: - URLProtocol mock
// Isolated stub subclass (own handler slot) — see ConfigurableURLProtocolStub.

private final class MockURLProtocol: ConfigurableURLProtocolStub {}
private final class FailClosedMockURLProtocol: ConfigurableURLProtocolStub {}

private func mockSession(_ handler: @escaping (URLRequest) throws -> (HTTPURLResponse, Data)) -> URLSession {
    MockURLProtocol.makeSession(handler: handler)
}

private func makeResponse(_ url: URL, _ status: Int) -> HTTPURLResponse {
    HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!
}

// MARK: - Factory

@Test func placeholderFactoryReturnsSwiftNativeByDefault() async throws {
    let impl = makeTelegramBot()
    #expect(impl is SwiftNativeTelegramBot)
}

@Test func placeholderFactoryReturnsSwiftNativeWhenEnabled() async throws {
    let impl = makeTelegramBot()
    #expect(impl is SwiftNativeTelegramBot)
}

// MARK: - Codable shape

@Test func TelegramStatus_round_trips_via_Codable_with_extras() throws {
    let s = TelegramStatus(
        enabled: true,
        tokenConfigured: true,
        pollerEnabled: true,
        lastSeenUpdateId: 138562497,
        lastSeenAt: "2026-05-31T00:04:41+00:00",
        lastReplyAt: "2026-05-31T00:04:46+00:00",
        lastError: "poll: timeout",
        extras: .object([
            "allowedChatIds": .array([]),
            "allowedUserIds": .array([.string("111222333")]),
            "requireMention": .bool(true),
            "model": .string("claude-opus-4-8"),
            "commandMenu": .object(["commandCount": .int(16)]),
            "voiceTranscription": .object(["enabled": .bool(true)]),
            "receipts": .array([]),
            "novelKey": .int(99),
        ])
    )
    let data = try JSONEncoder().encode(s)
    let back = try JSONDecoder().decode(TelegramStatus.self, from: data)
    #expect(back == s)
    let raw = String(data: data, encoding: .utf8) ?? ""
    #expect(raw.contains("\"enabled\""))
    #expect(raw.contains("\"allowedUserIds\""))
    #expect(raw.contains("\"commandMenu\""))
    #expect(raw.contains("\"novelKey\""))
}

@Test func TelegramStatus_decodes_unknown_keys_into_extras() throws {
    let raw = Data("""
    {"enabled":true,"tokenConfigured":true,"pollerEnabled":true,
     "lastSeenUpdateId":42,"lastSeenAt":"x","lastReplyAt":"y","lastError":null,
     "allowedChatIds":[],"allowedUserIds":["111222333"],"requireMention":true,
     "model":"claude-opus-4-8","reasoningEffort":"xhigh",
     "commandMenu":{"commandCount":16},"voiceTranscription":{"enabled":true},
     "receipts":[{"chatId":"1"}]}
    """.utf8)
    let s = try JSONDecoder().decode(TelegramStatus.self, from: raw)
    #expect(s.enabled == true)
    #expect(s.tokenConfigured == true)
    #expect(s.pollerEnabled == true)
    #expect(s.lastSeenUpdateId == 42)
    guard case .object(let extras)? = s.extras else {
        Issue.record("extras should be object"); return
    }
    #expect(extras["allowedUserIds"] != nil)
    #expect(extras["commandMenu"] != nil)
    #expect(extras["voiceTranscription"] != nil)
    #expect(extras["receipts"] != nil)
}

@Test func TelegramTestResult_preserves_rawResponse() throws {
    let raw: JSONValue = .object([
        "ok": .bool(true),
        "chatId": .string("111222333"),
        "messageId": .int(2087),
        "receipt": .object(["id": .string("uuid-1")]),
    ])
    let r = TelegramTestResult(rawResponse: raw)
    let data = try JSONEncoder().encode(r)
    let back = try JSONDecoder().decode(TelegramTestResult.self, from: data)
    #expect(back == r)
    #expect(back.rawResponse == raw)
}

// MARK: - Phase B: longPoll + dispatchSwiftSlashCommand + TelegramPollLoop

private let tokenStr = "TKN123"

private let discardTurnCardSend: @Sendable (String, Int, String) async throws -> Int = { _, _, _ in
    9_999
}

private let discardTurnCardEdit: @Sendable (String, Int, Int, String) async throws -> Void = { _, _, _, _ in }

private actor TelegramTaskPriorityCapture {
    private var value: TaskPriority?

    func record(_ priority: TaskPriority) { value = priority }

    func wait(timeout: TimeInterval = 15) async -> TaskPriority? {
        let deadline = Date().addingTimeInterval(timeout)
        while value == nil, Date() < deadline {
            try? await Task.sleep(nanoseconds: 2_000_000)
        }
        return value
    }
}

private func writeTelegramConfigRoot(
    enabled: Bool = true,
    token: String = "123:abc",
    allowedChatIds: [Int] = [1]
) throws -> URL {
    let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("tele_cfg_\(UUID().uuidString)", isDirectory: true)
    let teleDir = tmp.appendingPathComponent("telegram", isDirectory: true)
    try FileManager.default.createDirectory(at: teleDir, withIntermediateDirectories: true)
    let ids = allowedChatIds.map(String.init).joined(separator: ",")
    let payload = #"{"bot_token":"\#(token)","allowed_chat_ids":[\#(ids)],"enabled":\#(enabled)}"#
    try Data(payload.utf8).write(to: teleDir.appendingPathComponent("config.json"))
    return tmp
}

private actor ApprovalHandlerCapture: TelegramApprovalHandling {
    struct Call: Equatable {
        let id: String
        let decision: TelegramApprovalDecision
        let chatId: Int
        let fromUserId: Int?
    }

    private var calls: [Call] = []
    private let reply: String
    private let continuationPrompt: String?

    init(reply: String = "approval handled", continuationPrompt: String? = nil) {
        self.reply = reply
        self.continuationPrompt = continuationPrompt
    }

    func resolveTelegramApproval(
        id: String,
        decision: TelegramApprovalDecision,
        chatId: Int,
        fromUserId: Int?
    ) async throws -> TelegramApprovalResolution {
        calls.append(Call(id: id, decision: decision, chatId: chatId, fromUserId: fromUserId))
        return TelegramApprovalResolution(
            acknowledgement: reply,
            continuationPrompt: continuationPrompt
        )
    }

    func snapshot() -> [Call] { calls }
}

private actor TelegramModelRoutingCapture: ProviderRoutingRef {
    private let menu: TelegramModelMenu
    private var savedSelections: [(surface: String, provider: String?, model: String)] = []

    init(menu: TelegramModelMenu = telegramPollLoopTestModelMenu()) {
        self.menu = menu
    }

    func modelForSurface(_ surface: String) async -> (model: String, provider: String)? {
        (menu.currentModel, menu.currentProvider)
    }

    func modelMenuForSurface(_ surface: String) async -> TelegramModelMenu? {
        menu
    }

    func saveModelConfig(surface: String, key: String, value: String) async throws {}

    func saveModelSelection(surface: String, provider: String?, model: String) async throws {
        savedSelections.append((surface: surface, provider: provider, model: model))
    }

    func savedSnapshot() -> [(surface: String, provider: String?, model: String)] {
        savedSelections
    }
}

private func telegramPollLoopTestModelMenu() -> TelegramModelMenu {
    TelegramModelMenu(
        surface: "telegram",
        currentModel: "claude-opus-4-8",
        currentProvider: "anthropic_oauth_direct",
        providers: [
            TelegramModelProviderChoice(
                id: "anthropic_oauth_direct",
                displayName: "Anthropic",
                isCurrent: true,
                models: [
                    TelegramModelChoice(id: "claude-opus-4-8", name: "Claude Opus 4.8", isCurrent: true),
                    TelegramModelChoice(id: "claude-sonnet-4-6", name: "Claude Sonnet 4.6"),
                ]
            ),
            TelegramModelProviderChoice(
                id: "codex",
                displayName: "Codex CLI",
                models: [
                    TelegramModelChoice(id: "gpt-5.5", name: "GPT-5.5"),
                ]
            ),
        ]
    )
}

private func readTelegramJSONL(_ root: URL, _ name: String) throws -> [JSONValue] {
    let path = root
        .appendingPathComponent("telegram", isDirectory: true)
        .appendingPathComponent(name)
    guard let data = try? Data(contentsOf: path),
          let text = String(data: data, encoding: .utf8) else {
        return []
    }
    return text.split(separator: "\n", omittingEmptySubsequences: true).compactMap { line in
        try? JSONValue.parse(Data(String(line).utf8))
    }
}

@Suite(.serialized)
struct SwiftNativeTelegramBotPhaseBTests {
    private struct FakeVoiceDownloader: TelegramMediaDownloading {
        let bytes: Data

        func download(
            token: String,
            attachment: TelegramMediaAttachment,
            maxBytes: Int
        ) async throws -> TelegramMediaAttachment {
            #expect(token == tokenStr)
            #expect(attachment.kind == "voice")
            #expect(attachment.fileId == "VOICE_FILE_ID")
            #expect(maxBytes == 1024 * 1024)
            return TelegramMediaAttachment(
                kind: attachment.kind,
                fileId: attachment.fileId,
                mimeType: attachment.mimeType ?? "audio/ogg",
                sizeBytes: bytes.count,
                bytes: bytes,
                captureFilename: "voice_42.oga"
            )
        }
    }

    private struct FakeVoiceTranscriber: TelegramVoiceTranscribing {
        func transcribe(_ attachment: TelegramMediaAttachment) async throws -> TelegramVoiceTranscription {
            #expect(attachment.bytes == Data("voice-bytes".utf8))
            #expect(attachment.captureFilename == "voice_42.oga")
            return TelegramVoiceTranscription(
                text: "hey agent this came from a voice message",
                backend: "test",
                model: "test-transcribe",
                latencyMilliseconds: 12
            )
        }
    }

    /// PATCH-2026-08-18: transcriber that always fails with a supplied error.
    /// Drives the headless-denial path — the whole point of the bug is that the
    /// failure arrives with no human present, so the test supplies the error
    /// rather than depending on host TCC state.
    private struct FailingVoiceTranscriber: TelegramVoiceTranscribing {
        let error: any Error
        func transcribe(_ attachment: TelegramMediaAttachment) async throws -> TelegramVoiceTranscription {
            throw error
        }
    }

    /// 2026-07-21 audit: downloader whose reported size passes the
    /// pre-flight check but whose delivered bytes exceed the cap — drives
    /// the post-download HARD byte cap on the voice path.
    private struct OversizedVoiceDownloader: TelegramMediaDownloading {
        let bytes: Data

        func download(
            token: String,
            attachment: TelegramMediaAttachment,
            maxBytes: Int
        ) async throws -> TelegramMediaAttachment {
            TelegramMediaAttachment(
                kind: attachment.kind,
                fileId: attachment.fileId,
                mimeType: attachment.mimeType ?? "audio/ogg",
                sizeBytes: 1,
                bytes: bytes,
                captureFilename: "voice_42.oga"
            )
        }
    }

    @Test func longPoll_GETs_correct_URL_with_offset_and_timeout() async throws {
        nonisolated(unsafe) var captured: URLRequest?
        let session = mockSession { req in
            captured = req
            let body = Data(#"{"ok":true,"result":[]}"#.utf8)
            return (makeResponse(req.url!, 200), body)
        }
        let bot = SwiftNativeTelegramBot(dataRoot: hermeticTelegramDataRoot())
        _ = try await bot.longPoll(token: tokenStr, offset: 42, timeoutSeconds: 25, session: session)
        let url = captured?.url?.absoluteString ?? ""
        #expect(captured?.httpMethod == "GET")
        #expect(url.contains("/bot\(tokenStr)/getUpdates"))
        #expect(url.contains("offset=42"))
        #expect(url.contains("timeout=25"))
    }

    @Test func longPoll_parses_updates_field() async throws {
        let raw = #"""
        {"ok":true,"result":[{"update_id":7,"message":{"message_id":1,"chat":{"id":9},"from":{"id":11},"text":"hi","date":1700000000}}]}
        """#
        let session = mockSession { req in
            (makeResponse(req.url!, 200), Data(raw.utf8))
        }
        let bot = SwiftNativeTelegramBot(dataRoot: hermeticTelegramDataRoot())
        let result = try await bot.longPoll(token: tokenStr, offset: 0, session: session)
        #expect(result.updates.count == 1)
        let u = result.updates[0]
        #expect(u.updateId == 7)
        #expect(u.message?.chatId == 9)
        #expect(u.message?.messageId == 1)
        #expect(u.message?.fromUserId == 11)
        #expect(u.message?.text == "hi")
        #expect(u.message?.date == 1700000000)
    }

    @Test func longPoll_parses_reply_to_message_context() async throws {
        let raw = #"""
        {"ok":true,"result":[{"update_id":8,"message":{"message_id":2,"chat":{"id":9,"type":"private"},"from":{"id":11},"text":"Yeah go ahead","reply_to_message":{"message_id":1,"chat":{"id":9,"type":"private"},"from":{"id":22,"is_bot":true},"text":"Want me to fix that reference so it points at the real location?","date":1700000000},"date":1700000001}}]}
        """#
        let session = mockSession { req in
            (makeResponse(req.url!, 200), Data(raw.utf8))
        }
        let bot = SwiftNativeTelegramBot(dataRoot: hermeticTelegramDataRoot())
        let result = try await bot.longPoll(token: tokenStr, offset: 0, session: session)
        let replyTo = try #require(result.updates.first?.message?.replyTo)
        #expect(replyTo.messageId == 1)
        #expect(replyTo.chatId == 9)
        #expect(replyTo.chatType == "private")
        #expect(replyTo.fromUserId == 22)
        #expect(replyTo.fromIsBot == true)
        #expect(replyTo.previewText == "Want me to fix that reference so it points at the real location?")

        let rendered = TelegramReplyPromptRenderer.messageWithReplyContext(
            text: "Yeah go ahead",
            replyTo: replyTo
        )
        #expect(rendered.contains("Telegram reply context"))
        #expect(rendered.contains("Telegram message from the assistant #1"))
        #expect(rendered.contains("Want me to fix that reference"))
        #expect(rendered.contains("User message: Yeah go ahead"))
    }

    @Test func longPoll_returns_nextOffset_max_plus_one() async throws {
        let raw = #"""
        {"ok":true,"result":[
          {"update_id":4,"message":{"message_id":1,"chat":{"id":1},"date":1}},
          {"update_id":9,"message":{"message_id":2,"chat":{"id":1},"date":1}},
          {"update_id":7,"message":{"message_id":3,"chat":{"id":1},"date":1}}
        ]}
        """#
        let session = mockSession { req in
            (makeResponse(req.url!, 200), Data(raw.utf8))
        }
        let bot = SwiftNativeTelegramBot(dataRoot: hermeticTelegramDataRoot())
        let result = try await bot.longPoll(token: tokenStr, offset: 0, session: session)
        #expect(result.nextOffset == 10)
    }

    @Test func longPoll_empty_updates_returns_input_offset() async throws {
        let session = mockSession { req in
            (makeResponse(req.url!, 200), Data(#"{"ok":true,"result":[]}"#.utf8))
        }
        let bot = SwiftNativeTelegramBot(dataRoot: hermeticTelegramDataRoot())
        let result = try await bot.longPoll(token: tokenStr, offset: 100, session: session)
        #expect(result.nextOffset == 100)
        #expect(result.updates.isEmpty)
    }

    @Test func longPoll_ok_false_throws_underlying() async throws {
        let session = mockSession { req in
            (makeResponse(req.url!, 200), Data(#"{"ok":false,"description":"bad token"}"#.utf8))
        }
        let bot = SwiftNativeTelegramBot(dataRoot: hermeticTelegramDataRoot())
        do {
            _ = try await bot.longPoll(token: tokenStr, offset: 0, session: session)
            Issue.record("expected throw")
        } catch let TelegramBotError.underlying(msg) {
            #expect(msg.contains("bad token"))
        } catch {
            Issue.record("wrong error: \(error)")
        }
    }

    @Test func longPoll_401_throws_notConfigured() async throws {
        let session = mockSession { req in
            (makeResponse(req.url!, 401), Data())
        }
        let bot = SwiftNativeTelegramBot(dataRoot: hermeticTelegramDataRoot())
        do {
            _ = try await bot.longPoll(token: tokenStr, offset: 0, session: session)
            Issue.record("expected throw")
        } catch TelegramBotError.notConfigured {
            // ok
        } catch {
            Issue.record("wrong error: \(error)")
        }
    }

    @Test func longPoll_500_throws_underlying() async throws {
        let session = mockSession { req in
            (makeResponse(req.url!, 500), Data())
        }
        let bot = SwiftNativeTelegramBot(dataRoot: hermeticTelegramDataRoot())
        do {
            _ = try await bot.longPoll(token: tokenStr, offset: 0, session: session)
            Issue.record("expected throw")
        } catch let TelegramBotError.underlying(msg) {
            #expect(msg.contains("500"))
        } catch {
            Issue.record("wrong error: \(error)")
        }
    }

    @Test func longPoll_transport_error_throws_unavailable() async throws {
        let session = mockSession { _ in
            throw URLError(.notConnectedToInternet)
        }
        let bot = SwiftNativeTelegramBot(dataRoot: hermeticTelegramDataRoot())
        do {
            _ = try await bot.longPoll(token: tokenStr, offset: 0, session: session)
            Issue.record("expected throw")
        } catch TelegramBotError.unavailable {
            // ok
        } catch {
            Issue.record("wrong error: \(error)")
        }
    }

    @Test func dispatchSwiftSlashCommand_status_returns_summary() async throws {
        let root = try writeTelegramConfigRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let bot = SwiftNativeTelegramBot(dataRoot: root)
        let reply = try await bot.dispatchSwiftSlashCommand("/status", args: [], chatId: 1)
        let s = try #require(reply)
        #expect(s.contains("Telegram:"))
        #expect(s.contains("enabled=true"))
        #expect(s.contains("tokenConfigured=true"))
        #expect(s.contains("lastSeenAt=never"))
    }

    @Test func dispatchSwiftSlashCommand_unknown_returns_nil() async throws {
        let bot = SwiftNativeTelegramBot(dataRoot: hermeticTelegramDataRoot())
        let reply = try await bot.dispatchSwiftSlashCommand("/xyzzy_unknown", args: [], chatId: 1)
        #expect(reply == nil)
    }

    @Test func telegramApprovalCommand_parses_slash_and_callback_forms() throws {
        #expect(TelegramApprovalCommand.parse(text: "/approve abc") == TelegramApprovalCommand(id: "abc", decision: .approved))
        #expect(TelegramApprovalCommand.parse(text: "/allow abc") == TelegramApprovalCommand(id: "abc", decision: .approved))
        #expect(TelegramApprovalCommand.parse(text: "/deny@native_agent_bot abc") == TelegramApprovalCommand(id: "abc", decision: .denied))
        #expect(TelegramApprovalCommand.parse(text: "/reject abc") == TelegramApprovalCommand(id: "abc", decision: .denied))
        #expect(TelegramApprovalCommand.parse(callbackData: "na_approval:approve:abc") == TelegramApprovalCommand(id: "abc", decision: .approved))
        #expect(TelegramApprovalCommand.parse(callbackData: "na_approval:deny:abc") == TelegramApprovalCommand(id: "abc", decision: .denied))
        #expect(TelegramApprovalCommand.parse(text: "/status") == nil)
    }

    @Test func telegramPollLoop_persists_offset_to_disk() async throws {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("telegram_test_\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: tmp) }

        let raw = #"""
        {"ok":true,"result":[{"update_id":42,"message":{"message_id":1,"chat":{"id":9},"text":"hi","date":1}}]}
        """#
        let session = mockSession { req in
            (makeResponse(req.url!, 200), Data(raw.utf8))
        }
        let loop = TelegramPollLoop(
            interval: 60,
            token: tokenStr,
            // fail-closed allowlist (2026-08-13): empty = drop-all, so message-flow
            // fixtures must allowlist their chat ids explicitly.
            allowedChatIds: [5, 9, 77],
            bot: SwiftNativeTelegramBot(dataRoot: hermeticTelegramDataRoot()),
            session: session,
            offsetURL: tmp,
            sendMessage: { _, _, _ in /* no-op */ }
        )
        await loop.tick()

        let data = try Data(contentsOf: tmp)
        let parsed = try JSONValue.parse(data)
        guard case .object(let obj) = parsed, let v = obj["offset"] else {
            Issue.record("expected offset object"); return
        }
        var read: Int = -1
        if case .int(let i) = v { read = Int(i) }
        else if case .double(let d) = v { read = Int(d) }
        #expect(read == 43)
    }

    @Test func telegramPollLoop_replaysDurablyClaimedPendingUpdateAfterRestart() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("telegram_durable_replay_\(UUID().uuidString)", isDirectory: true)
        let offset = root.appendingPathComponent("telegram", isDirectory: true)
            .appendingPathComponent("last_offset.json")
        defer { try? FileManager.default.removeItem(at: root) }

        let update = TelegramUpdate(
            updateId: 700,
            message: TelegramMessage(
                messageId: 9,
                chatId: 77,
                chatType: "private",
                fromUserId: 11,
                text: "recover this turn",
                date: 1
            )
        )
        let inbox = TelegramUpdateInbox(offsetURL: offset)
        _ = try await inbox.ensurePending(update)
        try await SwiftNativePersistenceCore().writeJSON(
            .object(["offset": .int(701)]),
            to: offset
        )

        actor Capture {
            var calls: [String] = []
            var sent: [String] = []
            func call(_ text: String) { calls.append(text) }
            func send(_ text: String) { sent.append(text) }
            func snapshot() -> ([String], [String]) { (calls, sent) }
        }
        let capture = Capture()
        // This session would fail if touched. Recovery must drain the durable
        // inbox without waiting for a new Telegram poll.
        let offline = mockSession { request in
            throw URLError(.notConnectedToInternet, userInfo: [NSURLErrorFailingURLErrorKey: request.url as Any])
        }
        let coordinator = TelegramTurnCoordinator()
        let loop = TelegramPollLoop(
            interval: 60,
            token: tokenStr,
            allowedChatIds: [77],
            bot: SwiftNativeTelegramBot(dataRoot: root),
            session: offline,
            dataRoot: root,
            offsetURL: offset,
            sendMessage: { _, _, text in await capture.send(text) },
            sendChatAction: { _, _, _ in },
            sendMessageReturningId: discardTurnCardSend,
            editMessageText: discardTurnCardEdit,
            turnCardMinimumEditIntervalSeconds: 0,
            turnCardHeartbeatNanoseconds: 0,
            chatHandler: { _, text in
                await capture.call(text)
                return "recovered reply"
            },
            typingRefreshNanoseconds: 0,
            turnCoordinator: coordinator
        )

        let outcome = await loop.tickOutcome()
        await coordinator.waitUntilAllIdle()
        let (calls, sent) = await capture.snapshot()
        guard case .completed = outcome else {
            Issue.record("expected durable replay to complete, got \(outcome)")
            return
        }
        #expect(calls == ["recover this turn"])
        #expect(sent == ["recovered reply"])
        #expect(try await inbox.snapshots().first?.phase == .completed)
    }

    @Test func telegramPollLoop_quarantinesPriorProcessingClaimWithoutDuplicateEffect() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("telegram_durable_unknown_\(UUID().uuidString)", isDirectory: true)
        let offset = root.appendingPathComponent("telegram", isDirectory: true)
            .appendingPathComponent("last_offset.json")
        defer { try? FileManager.default.removeItem(at: root) }

        let update = TelegramUpdate(
            updateId: 701,
            message: TelegramMessage(
                messageId: 10,
                chatId: 77,
                chatType: "private",
                fromUserId: 11,
                text: "must not duplicate",
                date: 1
            )
        )
        let inbox = TelegramUpdateInbox(offsetURL: offset)
        _ = try await inbox.ensurePending(update)
        _ = try await inbox.transition(updateId: 701, from: [.pending], to: .processing)

        actor Capture {
            var handlerCalls = 0
            func call() { handlerCalls += 1 }
        }
        let capture = Capture()
        let emptySession = mockSession { request in
            (makeResponse(request.url!, 200), Data(#"{"ok":true,"result":[]}"#.utf8))
        }
        let loop = TelegramPollLoop(
            interval: 60,
            token: tokenStr,
            allowedChatIds: [77],
            bot: SwiftNativeTelegramBot(dataRoot: root),
            session: emptySession,
            dataRoot: root,
            offsetURL: offset,
            sendMessage: { _, _, _ in },
            sendChatAction: { _, _, _ in },
            sendMessageReturningId: discardTurnCardSend,
            editMessageText: discardTurnCardEdit,
            turnCardMinimumEditIntervalSeconds: 0,
            turnCardHeartbeatNanoseconds: 0,
            chatHandler: { _, _ in
                await capture.call()
                return "duplicate"
            },
            typingRefreshNanoseconds: 0,
            turnCoordinator: TelegramTurnCoordinator()
        )

        _ = await loop.tickOutcome()
        #expect(await capture.handlerCalls == 0)
        #expect(try await inbox.snapshots().first?.phase == .outcomeUnknown)
        let persisted = await SwiftNativePersistenceCore().readJSON(offset, defaultValue: .null)
        guard case .object(let object) = persisted else {
            Issue.record("expected offset object")
            return
        }
        #expect(object["offset"] == .int(702))
    }

    @Test func telegramUpdateInbox_preservesMalformedClaimAndFailsClosed() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("telegram_durable_corrupt_\(UUID().uuidString)", isDirectory: true)
        let offset = root.appendingPathComponent("telegram", isDirectory: true)
            .appendingPathComponent("last_offset.json")
        let inbox = TelegramUpdateInbox(offsetURL: offset)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: inbox.directory, withIntermediateDirectories: true)
        let path = inbox.directory.appendingPathComponent("702.json")
        let original = Data("{damaged".utf8)
        try original.write(to: path)

        await #expect(throws: TelegramUpdateInboxError.self) {
            _ = try await inbox.snapshots()
        }
        #expect(try Data(contentsOf: path) == original)
    }

    @Test func telegramUpdateInbox_rejectsClaimWhoseFilenameDoesNotMatchUpdateID() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("telegram_durable_misnamed_\(UUID().uuidString)", isDirectory: true)
        let offset = root.appendingPathComponent("telegram", isDirectory: true)
            .appendingPathComponent("last_offset.json")
        let inbox = TelegramUpdateInbox(offsetURL: offset)
        defer { try? FileManager.default.removeItem(at: root) }
        let update = TelegramUpdate(updateId: 703)
        _ = try await inbox.ensurePending(update)
        let canonical = inbox.directory.appendingPathComponent("703.json")
        let alias = inbox.directory.appendingPathComponent("704.json")
        try FileManager.default.moveItem(at: canonical, to: alias)
        let original = try Data(contentsOf: alias)

        await #expect(throws: TelegramUpdateInboxError.self) {
            _ = try await inbox.snapshots()
        }
        #expect(try Data(contentsOf: alias) == original)
    }

    @Test func telegramHumanTurnPromotesBackgroundPollWorkToUserInitiated() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("telegram_priority_\(UUID().uuidString)", isDirectory: true)
        let offset = root.appendingPathComponent("last_offset.json")
        defer { try? FileManager.default.removeItem(at: root) }

        let raw = #"{"ok":true,"result":[{"update_id":43,"message":{"message_id":2,"chat":{"id":9},"from":{"id":11},"text":"hello","date":1}}]}"#
        let session = mockSession { req in
            (makeResponse(req.url!, 200), Data(raw.utf8))
        }
        let capture = TelegramTaskPriorityCapture()
        let loop = TelegramPollLoop(
            interval: 60,
            token: tokenStr,
            // fail-closed allowlist (2026-08-13): empty = drop-all, so message-flow
            // fixtures must allowlist their chat ids explicitly.
            allowedChatIds: [5, 9, 77],
            bot: SwiftNativeTelegramBot(dataRoot: root),
            session: session,
            dataRoot: root,
            offsetURL: offset,
            sendMessage: { _, _, _ in },
            sendChatAction: { _, _, _ in },
            sendMessageReturningId: discardTurnCardSend,
            editMessageText: discardTurnCardEdit,
            turnCardMinimumEditIntervalSeconds: 0,
            turnCardHeartbeatNanoseconds: 0,
            chatHandler: { _, _ in
                await capture.record(Task.currentPriority)
                return "reply"
            },
            typingRefreshNanoseconds: 0
        )

        // Do not await the driver until the handler has recorded its priority;
        // that prevents this test task from priority-donating to the driver and
        // proves the production promotion rather than an await-side escalation.
        let driver = Task.detached(priority: .background) { await loop.tick() }
        let observed = await capture.wait()
        #expect(observed?.rawValue ?? 0 >= TaskPriority.userInitiated.rawValue)
        await driver.value
    }

    @Test func telegramPollLoop_tick_routes_updates_to_dispatch() async throws {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("telegram_test_\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: tmp) }

        let raw = #"""
        {"ok":true,"result":[{"update_id":5,"message":{"message_id":1,"chat":{"id":77},"text":"/status","date":1}}]}
        """#
        let session = mockSession { req in
            (makeResponse(req.url!, 200), Data(raw.utf8))
        }

        actor Capture {
            var calls: [(Int, String)] = []
            func append(_ chatId: Int, _ text: String) { calls.append((chatId, text)) }
            func snapshot() -> [(Int, String)] { calls }
        }
        let cap = Capture()

        let root = try writeTelegramConfigRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let bot = SwiftNativeTelegramBot(dataRoot: root)

        let loop = TelegramPollLoop(
            interval: 60,
            token: tokenStr,
            // fail-closed allowlist (2026-08-13): empty = drop-all, so message-flow
            // fixtures must allowlist their chat ids explicitly.
            allowedChatIds: [5, 9, 77],
            bot: bot,
            session: session,
            offsetURL: tmp,
            sendMessage: { _, chatId, text in
                await cap.append(chatId, text)
            }
        )
        await loop.tick()

        let calls = await cap.snapshot()
        #expect(calls.count == 1)
        #expect(calls.first?.0 == 77)
        #expect(calls.first?.1.hasPrefix("Telegram:") == true)
    }

    @Test func telegramPollLoop_routes_approval_slash_to_injected_handler() async throws {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("telegram_approval_slash_\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: tmp) }

        let raw = #"""
        {"ok":true,"result":[{"update_id":6,"message":{"message_id":2,"chat":{"id":77},"from":{"id":11},"text":"/approve appr-1","date":1}}]}
        """#
        let session = mockSession { req in
            (makeResponse(req.url!, 200), Data(raw.utf8))
        }
        actor SentCapture {
            var sent: [(Int, String)] = []
            func append(_ chatId: Int, _ text: String) { sent.append((chatId, text)) }
            func snapshot() -> [(Int, String)] { sent }
        }
        let sent = SentCapture()
        let handler = ApprovalHandlerCapture(reply: "approved and replayed")

        let loop = TelegramPollLoop(
            interval: 60,
            token: tokenStr,
            // fail-closed allowlist (2026-08-13): empty = drop-all, so message-flow
            // fixtures must allowlist their chat ids explicitly.
            allowedChatIds: [5, 9, 77],
            bot: SwiftNativeTelegramBot(dataRoot: hermeticTelegramDataRoot()),
            session: session,
            offsetURL: tmp,
            sendMessage: { _, chatId, text in await sent.append(chatId, text) },
            approvalHandler: handler
        )
        await loop.tick()

        #expect(await handler.snapshot() == [
            ApprovalHandlerCapture.Call(id: "appr-1", decision: .approved, chatId: 77, fromUserId: 11),
        ])
        let sentMessages = await sent.snapshot()
        #expect(sentMessages.count == 1)
        #expect(sentMessages.first?.0 == 77)
        #expect(sentMessages.first?.1 == "approved and replayed")
    }

    @Test func telegramPollLoop_routes_approval_callback_to_injected_handler() async throws {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("telegram_approval_callback_\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: tmp) }

        let raw = #"""
        {"ok":true,"result":[{"update_id":7,"callback_query":{"id":"cb-1","from":{"id":11},"message":{"message_id":3,"chat":{"id":77}},"data":"na_approval:deny:appr-2"}}]}
        """#
        let session = mockSession { req in
            (makeResponse(req.url!, 200), Data(raw.utf8))
        }
        actor Capture {
            var sent: [(Int, String)] = []
            var answered: [(String, String)] = []
            var edits: [(Int, Int, String, JSONValue?)] = []
            func send(_ chatId: Int, _ text: String) { sent.append((chatId, text)) }
            func answer(_ callbackId: String, _ text: String) { answered.append((callbackId, text)) }
            func edit(_ chatId: Int, _ messageId: Int, _ text: String, _ markup: JSONValue?) {
                edits.append((chatId, messageId, text, markup))
            }
            func sentSnapshot() -> [(Int, String)] { sent }
            func answerSnapshot() -> [(String, String)] { answered }
            func editSnapshot() -> [(Int, Int, String, JSONValue?)] { edits }
        }
        let capture = Capture()
        let handler = ApprovalHandlerCapture(reply: "denied")

        let loop = TelegramPollLoop(
            interval: 60,
            token: tokenStr,
            // fail-closed allowlist (2026-08-13): empty = drop-all, so message-flow
            // fixtures must allowlist their chat ids explicitly.
            allowedChatIds: [5, 9, 77],
            bot: SwiftNativeTelegramBot(dataRoot: hermeticTelegramDataRoot()),
            session: session,
            offsetURL: tmp,
            sendMessage: { _, chatId, text in await capture.send(chatId, text) },
            answerCallbackQuery: { _, callbackId, text in await capture.answer(callbackId, text) },
            editMessageTextWithReplyMarkup: { _, chatId, messageId, text, markup in
                await capture.edit(chatId, messageId, text, markup)
            },
            approvalHandler: handler
        )
        await loop.tick()

        #expect(await handler.snapshot() == [
            ApprovalHandlerCapture.Call(id: "appr-2", decision: .denied, chatId: 77, fromUserId: 11),
        ])
        let answered = await capture.answerSnapshot()
        #expect(answered.count == 1)
        #expect(answered.first?.0 == "cb-1")
        #expect(answered.first?.1 == "denied")
        let sentMessages = await capture.sentSnapshot()
        #expect(sentMessages.isEmpty)
        let edits = await capture.editSnapshot()
        #expect(edits.count == 1)
        #expect(edits.first?.0 == 77)
        #expect(edits.first?.1 == 3)
        #expect(edits.first?.2 == "denied")
        #expect(edits.first?.3 == TelegramTurnControlCallback.clearedReplyMarkup)
    }

    @Test func telegramPollLoop_approved_callback_resumesInterruptedChatWithoutAppendingSyntheticUserTurn() async throws {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("telegram_approval_resume_\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: tmp) }

        let raw = #"""
        {"ok":true,"result":[{"update_id":8,"callback_query":{"id":"cb-2","from":{"id":11},"message":{"message_id":4,"chat":{"id":77}},"data":"na_approval:approve:appr-3"}}]}
        """#
        let session = mockSession { req in
            (makeResponse(req.url!, 200), Data(raw.utf8))
        }
        actor Capture {
            var sent: [(Int, String)] = []
            var chatCalls: [(Int, String, Bool, Int?)] = []
            func send(_ chatId: Int, _ text: String) { sent.append((chatId, text)) }
            func chat(_ chatId: Int, _ text: String, _ suppressUserAppend: Bool, _ fromUserId: Int?) {
                chatCalls.append((chatId, text, suppressUserAppend, fromUserId))
            }
            func sentSnapshot() -> [(Int, String)] { sent }
            func chatSnapshot() -> [(Int, String, Bool, Int?)] { chatCalls }
        }
        let capture = Capture()
        let handler = ApprovalHandlerCapture(
            reply: "approved and replayed",
            continuationPrompt: "[internal continuation with verified result]"
        )
        let loop = TelegramPollLoop(
            interval: 60,
            token: tokenStr,
            // fail-closed allowlist (2026-08-13): empty = drop-all, so message-flow
            // fixtures must allowlist their chat ids explicitly.
            allowedChatIds: [5, 9, 77],
            bot: SwiftNativeTelegramBot(dataRoot: hermeticTelegramDataRoot()),
            session: session,
            offsetURL: tmp,
            sendMessage: { _, chatId, text in await capture.send(chatId, text) },
            sendChatAction: { _, _, _ in },
            sendMessageReturningId: discardTurnCardSend,
            editMessageText: discardTurnCardEdit,
            turnCardMinimumEditIntervalSeconds: 0,
            turnCardHeartbeatNanoseconds: 0,
            approvalHandler: handler,
            progressChatHandler: { chatId, text, _, context in
                await capture.chat(
                    chatId,
                    text,
                    context.suppressUserAppend,
                    context.fromUserId
                )
                return "continued answer"
            },
            typingRefreshNanoseconds: 0
        )

        await loop.tick()

        let chatCalls = await capture.chatSnapshot()
        #expect(chatCalls.count == 1)
        #expect(chatCalls.first?.0 == 77)
        #expect(chatCalls.first?.1 == "[internal continuation with verified result]")
        #expect(chatCalls.first?.2 == true)
        #expect(chatCalls.first?.3 == 11)
        #expect(await capture.sentSnapshot().map(\.1) == ["continued answer"])
    }

    @Test func telegramPollLoop_model_slash_sends_provider_buttons() async throws {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("telegram_model_menu_\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: tmp) }

        let raw = #"""
        {"ok":true,"result":[{"update_id":70,"message":{"message_id":2,"chat":{"id":77},"from":{"id":11},"text":"/model","date":1}}]}
        """#
        let session = mockSession { req in
            (makeResponse(req.url!, 200), Data(raw.utf8))
        }
        actor Capture {
            var plain: [String] = []
            var menus: [(chatId: Int, text: String, markup: JSONValue)] = []
            func send(_ text: String) { plain.append(text) }
            func menu(_ chatId: Int, _ text: String, _ markup: JSONValue) {
                menus.append((chatId: chatId, text: text, markup: markup))
            }
            func snapshot() -> ([String], [(chatId: Int, text: String, markup: JSONValue)]) {
                (plain, menus)
            }
        }
        let capture = Capture()
        let routing = TelegramModelRoutingCapture()
        let bot = SwiftNativeTelegramBot(
            dataRoot: hermeticTelegramDataRoot(),
            completenessDeps: TelegramBotCompletenessDeps(routing: routing)
        )

        let loop = TelegramPollLoop(
            interval: 60,
            token: tokenStr,
            // fail-closed allowlist (2026-08-13): empty = drop-all, so message-flow
            // fixtures must allowlist their chat ids explicitly.
            allowedChatIds: [5, 9, 77],
            bot: bot,
            session: session,
            offsetURL: tmp,
            sendMessage: { _, _, text in await capture.send(text) },
            sendMessageWithReplyMarkup: { _, chatId, text, markup in
                await capture.menu(chatId, text, markup)
            }
        )
        await loop.tick()

        let (plain, menus) = await capture.snapshot()
        #expect(plain.isEmpty)
        #expect(menus.count == 1)
        let menu = try #require(menus.first)
        #expect(menu.chatId == 77)
        #expect(menu.text.contains("Choose a provider:"))
        #expect(!menu.text.contains("Choose with /model <number>"))
        guard case .object(let root) = menu.markup,
              case .array(let rows)? = root["inline_keyboard"] else {
            Issue.record("expected inline keyboard")
            return
        }
        #expect(rows.count == 2)
        guard case .array(let firstRow)? = rows.first,
              case .object(let firstButton)? = firstRow.first else {
            Issue.record("expected provider button")
            return
        }
        #expect(firstButton["text"] == .string("Anthropic (current)"))
        #expect(firstButton["callback_data"] == .string("na_model:p:0"))
    }

    @Test func telegramPollLoop_model_provider_callback_opens_model_buttons() async throws {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("telegram_model_provider_\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: tmp) }

        let raw = #"""
        {"ok":true,"result":[{"update_id":71,"callback_query":{"id":"cb-model-provider","from":{"id":11},"message":{"message_id":3,"chat":{"id":77}},"data":"na_model:p:1"}}]}
        """#
        let session = mockSession { req in
            (makeResponse(req.url!, 200), Data(raw.utf8))
        }
        actor Capture {
            var edits: [(chatId: Int, messageId: Int, text: String, markup: JSONValue?)] = []
            var answers: [(String, String)] = []
            func edit(_ chatId: Int, _ messageId: Int, _ text: String, _ markup: JSONValue?) {
                edits.append((chatId: chatId, messageId: messageId, text: text, markup: markup))
            }
            func answer(_ callbackId: String, _ text: String) { answers.append((callbackId, text)) }
            func snapshot() -> ([(chatId: Int, messageId: Int, text: String, markup: JSONValue?)], [(String, String)]) {
                (edits, answers)
            }
        }
        let capture = Capture()
        let routing = TelegramModelRoutingCapture()
        let bot = SwiftNativeTelegramBot(
            dataRoot: hermeticTelegramDataRoot(),
            completenessDeps: TelegramBotCompletenessDeps(routing: routing)
        )

        let loop = TelegramPollLoop(
            interval: 60,
            token: tokenStr,
            // fail-closed allowlist (2026-08-13): empty = drop-all, so message-flow
            // fixtures must allowlist their chat ids explicitly.
            allowedChatIds: [5, 9, 77],
            bot: bot,
            session: session,
            offsetURL: tmp,
            sendMessage: { _, _, _ in },
            answerCallbackQuery: { _, callbackId, text in await capture.answer(callbackId, text) },
            editMessageTextWithReplyMarkup: { _, chatId, messageId, text, markup in
                await capture.edit(chatId, messageId, text, markup)
            }
        )
        await loop.tick()

        let (edits, answers) = await capture.snapshot()
        #expect(answers.first?.0 == "cb-model-provider")
        #expect(answers.first?.1 == "Choose a model.")
        let edit = try #require(edits.first)
        #expect(edit.chatId == 77)
        #expect(edit.messageId == 3)
        #expect(edit.text.contains("Provider: Codex CLI (codex)"))
        guard case .object(let root)? = edit.markup,
              case .array(let rows)? = root["inline_keyboard"],
              case .array(let firstRow)? = rows.first,
              case .object(let firstButton)? = firstRow.first else {
            Issue.record("expected model inline keyboard")
            return
        }
        #expect(firstButton["text"] == .string("GPT-5.5"))
        #expect(firstButton["callback_data"] == .string("na_model:m:1:0"))
    }

    @Test func telegramPollLoop_model_callback_saves_selection_and_confirms() async throws {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("telegram_model_select_\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: tmp) }

        let raw = #"""
        {"ok":true,"result":[{"update_id":72,"callback_query":{"id":"cb-model-select","from":{"id":11},"message":{"message_id":4,"chat":{"id":77}},"data":"na_model:m:1:0"}}]}
        """#
        let session = mockSession { req in
            (makeResponse(req.url!, 200), Data(raw.utf8))
        }
        actor Capture {
            var edits: [(String, JSONValue?)] = []
            var answers: [(String, String)] = []
            func edit(_ text: String, _ markup: JSONValue?) { edits.append((text, markup)) }
            func answer(_ callbackId: String, _ text: String) { answers.append((callbackId, text)) }
            func snapshot() -> ([(String, JSONValue?)], [(String, String)]) { (edits, answers) }
        }
        let capture = Capture()
        let routing = TelegramModelRoutingCapture()
        let bot = SwiftNativeTelegramBot(
            dataRoot: hermeticTelegramDataRoot(),
            completenessDeps: TelegramBotCompletenessDeps(routing: routing)
        )

        let loop = TelegramPollLoop(
            interval: 60,
            token: tokenStr,
            // fail-closed allowlist (2026-08-13): empty = drop-all, so message-flow
            // fixtures must allowlist their chat ids explicitly.
            allowedChatIds: [5, 9, 77],
            bot: bot,
            session: session,
            offsetURL: tmp,
            sendMessage: { _, _, _ in },
            answerCallbackQuery: { _, callbackId, text in await capture.answer(callbackId, text) },
            editMessageTextWithReplyMarkup: { _, _, _, text, markup in
                await capture.edit(text, markup)
            }
        )
        await loop.tick()

        let saved = await routing.savedSnapshot()
        #expect(saved.count == 1)
        #expect(saved.first?.surface == "telegram")
        #expect(saved.first?.provider == "codex")
        #expect(saved.first?.model == "gpt-5.5")
        let (edits, answers) = await capture.snapshot()
        #expect(answers.first?.0 == "cb-model-select")
        #expect(answers.first?.1 == "Telegram model set to gpt-5.5.")
        let edit = try #require(edits.first)
        #expect(edit.0.contains("Telegram model set"))
        #expect(edit.0.contains("Provider: Codex CLI (codex)"))
        #expect(edit.0.contains("GPT-5.5 [gpt-5.5]"))
        guard case .object(let root)? = edit.1,
              case .array(let rows)? = root["inline_keyboard"] else {
            Issue.record("expected confirmation keyboard")
            return
        }
        #expect(rows.count == 2)
    }

    @Test func telegramPollLoop_stop_cancels_active_turn() async throws {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("telegram_stop_\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: tmp) }

        let raw = #"""
        {"ok":true,"result":[{"update_id":8,"message":{"message_id":4,"chat":{"id":77},"from":{"id":11},"text":"/stop","date":1}}]}
        """#
        let session = mockSession { req in
            (makeResponse(req.url!, 200), Data(raw.utf8))
        }
        actor Capture {
            var sent: [String] = []
            var cancelled = false
            func send(_ text: String) { sent.append(text) }
            func markCancelled() { cancelled = true }
            func snapshot() -> ([String], Bool) { (sent, cancelled) }
        }
        let capture = Capture()
        let coordinator = TelegramTurnCoordinator()
        let activeTask = Task {
            do {
                try await Task.sleep(nanoseconds: 5_000_000_000)
            } catch {
                await capture.markCancelled()
            }
        }
        defer { activeTask.cancel() }
        let activeId = try #require(await coordinator.beginTurn(chatId: 77, text: "slow work", task: activeTask))

        let loop = TelegramPollLoop(
            interval: 60,
            token: tokenStr,
            // fail-closed allowlist (2026-08-13): empty = drop-all, so message-flow
            // fixtures must allowlist their chat ids explicitly.
            allowedChatIds: [5, 9, 77],
            session: session,
            offsetURL: tmp,
            sendMessage: { _, _, text in await capture.send(text) },
            turnCoordinator: coordinator
        )
        await loop.tick()
        try? await Task.sleep(nanoseconds: 50_000_000)
        await coordinator.finishTurn(chatId: 77, turnId: activeId)

        let (sent, cancelled) = await capture.snapshot()
        // A synthetic coordinator turn without a work card cannot present a
        // confirmed terminal state. The live production path always owns a
        // card (covered by TelegramTurnControlsTests), and does not spray a
        // redundant standalone stop notice.
        #expect(sent.isEmpty)
        #expect(cancelled)
    }

    @Test func telegramPollLoop_normal_turn_is_admitted_before_handler_can_compete_for_chat() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("telegram_atomic_admission_\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let offset = root.appendingPathComponent("telegram/last_offset.json")
        let raw = #"""
        {"ok":true,"result":[{"update_id":81,"message":{"message_id":41,"chat":{"id":77},"from":{"id":11},"text":"do the work","date":1}}]}
        """#
        let session = mockSession { req in
            (makeResponse(req.url!, 200), Data(raw.utf8))
        }
        actor Capture {
            var handlerCalls = 0
            var competingAdmissionWon = false
            var sent: [String] = []
            func handlerEntered() { handlerCalls += 1 }
            func markCompetingWin() { competingAdmissionWon = true }
            func send(_ text: String) { sent.append(text) }
            func snapshot() -> (Int, Bool, [String]) {
                (handlerCalls, competingAdmissionWon, sent)
            }
        }
        let capture = Capture()
        let coordinator = TelegramTurnCoordinator()
        let loop = TelegramPollLoop(
            interval: 60,
            token: tokenStr,
            allowedChatIds: [77],
            session: session,
            dataRoot: root,
            offsetURL: offset,
            sendMessage: { _, _, text in await capture.send(text) },
            sendChatAction: { _, _, _ in },
            sendMessageReturningId: discardTurnCardSend,
            editMessageText: discardTurnCardEdit,
            turnCardMinimumEditIntervalSeconds: 0,
            turnCardHeartbeatNanoseconds: 0,
            progressChatHandler: { _, _, _, _ in
                await capture.handlerEntered()
                // This is the old TOCTOU window made deterministic: when the
                // normal Task was created before beginTurn, its handler could
                // claim the still-empty coordinator itself. Atomic startTurn
                // records the normal owner before this closure can begin.
                if let competing = await coordinator.startTurn(
                    chatId: 77,
                    text: "competing continuation",
                    operation: {}
                ) {
                    await capture.markCompetingWin()
                    await competing.task.value
                    await coordinator.finishTurn(chatId: 77, turnId: competing.id)
                }
                return "normal reply"
            },
            typingRefreshNanoseconds: 0,
            turnCoordinator: coordinator
        )

        await loop.tick()

        let result = await capture.snapshot()
        #expect(result.0 == 1)
        #expect(!result.1)
        #expect(result.2 == ["normal reply"])
        #expect(!(await coordinator.snapshot(chatId: 77).isRunning))
    }

    @Test func telegramPollLoop_retry_replays_last_user_message_without_command_prompt() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("telegram_retry_command_\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let offset = root
            .appendingPathComponent("telegram", isDirectory: true)
            .appendingPathComponent("last_offset.json")

        let raw = #"""
        {"ok":true,"result":[
          {"update_id":9,"message":{"message_id":5,"chat":{"id":77},"from":{"id":11},"text":"retry this","date":1}},
          {"update_id":10,"message":{"message_id":6,"chat":{"id":77},"from":{"id":11},"text":"/retry","date":2}}
        ]}
        """#
        let session = mockSession { req in
            (makeResponse(req.url!, 200), Data(raw.utf8))
        }
        actor Capture {
            var sent: [String] = []
            var calls: [(text: String, suppress: Bool)] = []
            func send(_ text: String) { sent.append(text) }
            func record(text: String, suppress: Bool) -> Int {
                calls.append((text, suppress))
                return calls.count
            }
            func snapshot() -> ([String], [(text: String, suppress: Bool)]) { (sent, calls) }
        }
        let capture = Capture()
        let coordinator = TelegramTurnCoordinator()

        let loop = TelegramPollLoop(
            interval: 60,
            token: tokenStr,
            // fail-closed allowlist (2026-08-13): empty = drop-all, so message-flow
            // fixtures must allowlist their chat ids explicitly.
            allowedChatIds: [5, 9, 77],
            session: session,
            dataRoot: root,
            offsetURL: offset,
            sendMessage: { _, _, text in await capture.send(text) },
            sendChatAction: { _, _, _ in },
            sendMessageReturningId: discardTurnCardSend,
            editMessageText: discardTurnCardEdit,
            turnCardMinimumEditIntervalSeconds: 0,
            turnCardHeartbeatNanoseconds: 0,
            progressChatHandler: { _, text, _, context in
                let count = await capture.record(text: text, suppress: context.suppressUserAppend)
                return count == 1 ? "first reply" : "retry reply"
            },
            typingRefreshNanoseconds: 0,
            turnCoordinator: coordinator
        )
        await loop.tick()

        let (sent, calls) = await capture.snapshot()
        #expect(sent == ["first reply", "retry reply"])
        #expect(calls.map(\.text) == ["retry this", "retry this"])
        #expect(calls.map(\.suppress) == [false, true])
    }

    @Test func telegramPollLoop_empty_reply_without_draft_sends_visible_notice() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("telegram_empty_reply_\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let offset = root
            .appendingPathComponent("telegram", isDirectory: true)
            .appendingPathComponent("last_offset.json")
        let raw = #"""
        {"ok":true,"result":[{"update_id":11,"message":{"message_id":7,"chat":{"id":77},"from":{"id":11},"text":"send the handoff","date":1}}]}
        """#
        let session = mockSession { req in
            (makeResponse(req.url!, 200), Data(raw.utf8))
        }
        actor Capture {
            var sent: [String] = []
            func send(_ text: String) { sent.append(text) }
            func snapshot() -> [String] { sent }
        }
        let capture = Capture()
        let loop = TelegramPollLoop(
            interval: 60,
            token: tokenStr,
            // fail-closed allowlist (2026-08-13): empty = drop-all, so message-flow
            // fixtures must allowlist their chat ids explicitly.
            allowedChatIds: [5, 9, 77],
            session: session,
            dataRoot: root,
            offsetURL: offset,
            sendMessage: { _, _, text in await capture.send(text) },
            sendChatAction: { _, _, _ in },
            sendMessageReturningId: discardTurnCardSend,
            editMessageText: discardTurnCardEdit,
            turnCardMinimumEditIntervalSeconds: 0,
            turnCardHeartbeatNanoseconds: 0,
            chatHandler: { _, _ in "" },
            typingRefreshNanoseconds: 0,
            turnCoordinator: TelegramTurnCoordinator()
        )

        await loop.tick()

        #expect(await capture.snapshot() == [
            "(the reply came back empty - check the Mac error log)",
        ])
        let errors = try readTelegramJSONL(root, "errors.jsonl")
        guard case .object(let error)? = errors.first else {
            Issue.record("expected empty-reply error")
            return
        }
        #expect(error["context"] == .string("empty_reply"))
        let receipts = try readTelegramJSONL(root, "receipts.jsonl")
        guard case .object(let receipt)? = receipts.first else {
            Issue.record("expected visible empty-reply receipt")
            return
        }
        #expect(receipt["kind"] == .string("empty_reply_notice"))
    }

    @Test func telegramPollLoop_empty_retry_without_draft_sends_visible_notice() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("telegram_empty_retry_\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let offset = root
            .appendingPathComponent("telegram", isDirectory: true)
            .appendingPathComponent("last_offset.json")
        let raw = #"""
        {"ok":true,"result":[
          {"update_id":12,"message":{"message_id":8,"chat":{"id":77},"from":{"id":11},"text":"retry this","date":1}},
          {"update_id":13,"message":{"message_id":9,"chat":{"id":77},"from":{"id":11},"text":"/retry","date":2}}
        ]}
        """#
        let session = mockSession { req in
            (makeResponse(req.url!, 200), Data(raw.utf8))
        }
        actor Capture {
            var sent: [String] = []
            var calls = 0
            func send(_ text: String) { sent.append(text) }
            func reply() -> String {
                calls += 1
                return calls == 1 ? "first reply" : ""
            }
            func snapshot() -> [String] { sent }
        }
        let capture = Capture()
        let loop = TelegramPollLoop(
            interval: 60,
            token: tokenStr,
            // fail-closed allowlist (2026-08-13): empty = drop-all, so message-flow
            // fixtures must allowlist their chat ids explicitly.
            allowedChatIds: [5, 9, 77],
            session: session,
            dataRoot: root,
            offsetURL: offset,
            sendMessage: { _, _, text in await capture.send(text) },
            sendChatAction: { _, _, _ in },
            sendMessageReturningId: discardTurnCardSend,
            editMessageText: discardTurnCardEdit,
            turnCardMinimumEditIntervalSeconds: 0,
            turnCardHeartbeatNanoseconds: 0,
            chatHandler: { _, _ in await capture.reply() },
            typingRefreshNanoseconds: 0,
            turnCoordinator: TelegramTurnCoordinator()
        )

        await loop.tick()

        #expect(await capture.snapshot() == [
            "first reply",
            "(the retry came back empty - check the Mac error log)",
        ])
        let receipts = try readTelegramJSONL(root, "receipts.jsonl")
        let receiptKinds = receipts.compactMap { row -> String? in
            guard case .object(let object) = row,
                  case .string(let kind)? = object["kind"] else { return nil }
            return kind
        }
        #expect(receiptKinds == ["reply", "empty_retry_notice"])
    }

    @Test func telegramPollLoop_syncs_command_menu_once_per_registry_version() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("telegram_menu_\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let offset = root
            .appendingPathComponent("telegram", isDirectory: true)
            .appendingPathComponent("last_offset.json")

        let session = mockSession { req in
            (makeResponse(req.url!, 200), Data(#"{"ok":true,"result":[]}"#.utf8))
        }

        actor Capture {
            var commandCounts: [Int] = []
            func sync(token: String, commands: [TelegramBotCommand]) -> TelegramCommandMenuStatus {
                commandCounts.append(commands.count)
                return TelegramCommandMenuStatus(
                    commandCount: commands.count,
                    registryVersion: TelegramCommandRegistry.version,
                    syncedAt: "2026-06-04T00:00:00Z"
                )
            }
            func count() -> Int { commandCounts.count }
        }
        let capture = Capture()

        let loop = TelegramPollLoop(
            interval: 60,
            token: tokenStr,
            // fail-closed allowlist (2026-08-13): empty = drop-all, so message-flow
            // fixtures must allowlist their chat ids explicitly.
            allowedChatIds: [5, 9, 77],
            session: session,
            dataRoot: root,
            offsetURL: offset,
            sendMessage: { _, _, _ in },
            syncCommandMenu: { token, commands in
                await capture.sync(token: token, commands: commands)
            }
        )
        await loop.tick()
        await loop.tick()

        #expect(await capture.count() == 1)
        let status = try await SwiftNativeTelegramBot(dataRoot: root).getStatus()
        guard case .object(let extras)? = status.extras,
              case .object(let menu)? = extras["commandMenu"] else {
            Issue.record("expected commandMenu status")
            return
        }
        #expect(menu["commandCount"] == .int(Int64(TelegramCommandRegistry.commands.count)))
        #expect(menu["registryVersion"] == .string(TelegramCommandRegistry.version))
        #expect(menu["synced"] == .bool(true))
    }

    @Test func telegramPollLoop_records_chat_handler_failures_and_error_notice_receipt() async throws {
        enum HandlerFailure: Error { case boom }
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("telegram_logs_\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let offset = root
            .appendingPathComponent("telegram", isDirectory: true)
            .appendingPathComponent("last_offset.json")

        let raw = #"""
        {"ok":true,"result":[{"update_id":88,"message":{"message_id":3,"chat":{"id":77},"from":{"id":11},"text":"hello","date":1}}]}
        """#
        let session = mockSession { req in
            (makeResponse(req.url!, 200), Data(raw.utf8))
        }

        actor Capture {
            var sent: [(Int, String)] = []
            func append(_ chatId: Int, _ text: String) { sent.append((chatId, text)) }
            func snapshot() -> [(Int, String)] { sent }
        }
        let cap = Capture()

        let loop = TelegramPollLoop(
            interval: 60,
            token: tokenStr,
            // fail-closed allowlist (2026-08-13): empty = drop-all, so message-flow
            // fixtures must allowlist their chat ids explicitly.
            allowedChatIds: [5, 9, 77],
            session: session,
            dataRoot: root,
            offsetURL: offset,
            sendMessage: { _, chatId, text in
                await cap.append(chatId, text)
            },
            sendChatAction: { _, _, _ in },
            sendMessageReturningId: discardTurnCardSend,
            editMessageText: discardTurnCardEdit,
            turnCardMinimumEditIntervalSeconds: 0,
            turnCardHeartbeatNanoseconds: 0,
            chatHandler: { _, _ in throw HandlerFailure.boom }
        )
        await loop.tick()

        let sent = await cap.snapshot()
        #expect(sent.count == 1)
        #expect(sent.first?.1 == "(internal error while drafting a reply)")

        let errors = try readTelegramJSONL(root, "errors.jsonl")
        guard case .object(let errorRow)? = errors.first else {
            Issue.record("expected error row")
            return
        }
        #expect(errorRow["context"] == .string("chat_handler"))
        #expect(errorRow["updateId"] == .int(88))

        let receipts = try readTelegramJSONL(root, "receipts.jsonl")
        guard case .object(let receiptRow)? = receipts.first else {
            Issue.record("expected receipt row")
            return
        }
        #expect(receiptRow["kind"] == .string("error_notice"))
        #expect(receiptRow["chatId"] == .string("77"))

        let status = try await SwiftNativeTelegramBot(dataRoot: root).getStatus()
        #expect(status.lastSeenUpdateId == 88)
        #expect(status.lastReplyAt != nil)
        guard case .object(let extras)? = status.extras,
              case .array(let statusErrors)? = extras["errors"] else {
            Issue.record("expected tailed status errors")
            return
        }
        #expect(!statusErrors.isEmpty)
    }

    @Test func telegramPollLoop_surfaces_provider_usage_errors_without_internal_notice() async throws {
        struct UsageFailure: Error, LocalizedError {
            var errorDescription: String? {
                "llm: provider error: Anthropic OAuth usage is exhausted. Add more at claude.ai/settings/usage or switch providers."
            }
        }
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("telegram_usage_error_\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let offset = root
            .appendingPathComponent("telegram", isDirectory: true)
            .appendingPathComponent("last_offset.json")

        let raw = #"""
        {"ok":true,"result":[{"update_id":89,"message":{"message_id":4,"chat":{"id":77},"from":{"id":11},"text":"hello","date":1}}]}
        """#
        let session = mockSession { req in
            (makeResponse(req.url!, 200), Data(raw.utf8))
        }

        actor Capture {
            var sent: [(Int, String)] = []
            var handlerCalls = 0
            func append(_ chatId: Int, _ text: String) { sent.append((chatId, text)) }
            func bumpHandlerCall() { handlerCalls += 1 }
            func snapshot() -> ([(Int, String)], Int) { (sent, handlerCalls) }
        }
        let cap = Capture()

        let loop = TelegramPollLoop(
            interval: 60,
            token: tokenStr,
            // fail-closed allowlist (2026-08-13): empty = drop-all, so message-flow
            // fixtures must allowlist their chat ids explicitly.
            allowedChatIds: [5, 9, 77],
            session: session,
            dataRoot: root,
            offsetURL: offset,
            sendMessage: { _, chatId, text in
                await cap.append(chatId, text)
            },
            sendChatAction: { _, _, _ in },
            sendMessageReturningId: discardTurnCardSend,
            editMessageText: discardTurnCardEdit,
            turnCardMinimumEditIntervalSeconds: 0,
            turnCardHeartbeatNanoseconds: 0,
            chatHandler: { _, _ in
                await cap.bumpHandlerCall()
                throw UsageFailure()
            },
            chatRetryAttempts: 1,
            chatRetryDelayNanoseconds: 0
        )
        await loop.tick()

        let (sent, handlerCalls) = await cap.snapshot()
        #expect(handlerCalls == 1)
        #expect(sent.map { $0.1 } == [
            "(Claude OAuth usage is exhausted. Switch provider with /provider or add more at claude.ai/settings/usage.)",
        ])

        let receipts = try readTelegramJSONL(root, "receipts.jsonl")
        guard case .object(let receiptRow)? = receipts.first else {
            Issue.record("expected receipt row")
            return
        }
        #expect(receiptRow["kind"] == .string("error_notice"))
        #expect(receiptRow["replyPreview"] == .string("(Claude OAuth usage is exhausted. Switch provider with /provider or add more at claude.ai/settings/usage.)"))
    }

    @Test func telegramPollLoop_classifies_anthropic_overload_as_retryable_not_internal() {
        struct OverloadedFailure: Error, LocalizedError {
            var errorDescription: String? {
                "llm: provider error: Anthropic OAuth: Overloaded"
            }
        }

        let error = OverloadedFailure()
        #expect(TelegramPollLoop.isRetryableChatHandlerError(error))
        #expect(TelegramPollLoop.chatErrorNotice(for: error) == "(drafting stalled; try again in a moment)")
    }

    @Test func telegramPollLoop_never_retries_after_tool_effects_even_when_transient() {
        // A provider 502 AFTER a tool dispatch is marker-wrapped by
        // ChatOrchestration (ProviderErrorAfterToolEffects). Replaying the
        // whole handler would re-run the tools, so the marker must veto every
        // transient phrase the inner error also matches.
        struct WrappedFailure: Error, LocalizedError {
            var errorDescription: String? {
                "provider failure after 2 tool dispatch(es) [whole-turn retry unsafe: tool effects present]: "
                + "llm: transient: server status 502"
            }
        }
        #expect(!TelegramPollLoop.isRetryableChatHandlerError(WrappedFailure()))
        // Same inner phrase WITHOUT the marker stays retryable (pre-effect failures).
        struct BareFailure: Error, LocalizedError {
            var errorDescription: String? { "llm: transient: server status 502" }
        }
        #expect(TelegramPollLoop.isRetryableChatHandlerError(BareFailure()))
    }

    @Test func telegramPollLoop_retries_transient_chat_handler_failure_then_replies() async throws {
        struct TransientFailure: LocalizedError {
            var errorDescription: String? {
                "chat: llm: transient: upstream connect error or disconnect/reset before headers"
            }
        }
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("telegram_retry_\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let offset = root
            .appendingPathComponent("telegram", isDirectory: true)
            .appendingPathComponent("last_offset.json")

        let raw = #"""
        {"ok":true,"result":[{"update_id":89,"message":{"message_id":4,"chat":{"id":77},"from":{"id":11},"text":"hello","date":1}}]}
        """#
        let session = mockSession { req in
            (makeResponse(req.url!, 200), Data(raw.utf8))
        }

        actor Capture {
            var sent: [(Int, String)] = []
            var handlerCalls = 0
            func append(_ chatId: Int, _ text: String) { sent.append((chatId, text)) }
            func nextHandlerCall() -> Int {
                handlerCalls += 1
                return handlerCalls
            }
            func snapshot() -> ([(Int, String)], Int) { (sent, handlerCalls) }
        }
        let cap = Capture()

        let loop = TelegramPollLoop(
            interval: 60,
            token: tokenStr,
            // fail-closed allowlist (2026-08-13): empty = drop-all, so message-flow
            // fixtures must allowlist their chat ids explicitly.
            allowedChatIds: [5, 9, 77],
            session: session,
            dataRoot: root,
            offsetURL: offset,
            sendMessage: { _, chatId, text in
                await cap.append(chatId, text)
            },
            sendChatAction: { _, _, _ in },
            sendMessageReturningId: discardTurnCardSend,
            editMessageText: discardTurnCardEdit,
            turnCardMinimumEditIntervalSeconds: 0,
            turnCardHeartbeatNanoseconds: 0,
            chatHandler: { _, _ in
                let call = await cap.nextHandlerCall()
                if call == 1 { throw TransientFailure() }
                return "recovered"
            },
            chatRetryAttempts: 1,
            chatRetryDelayNanoseconds: 0
        )
        await loop.tick()

        let (sent, handlerCalls) = await cap.snapshot()
        #expect(handlerCalls == 2)
        #expect(sent.map { $0.1 } == ["recovered"])

        let errors = try readTelegramJSONL(root, "errors.jsonl")
        #expect(errors.isEmpty)

        let receipts = try readTelegramJSONL(root, "receipts.jsonl")
        guard case .object(let receiptRow)? = receipts.first else {
            Issue.record("expected receipt row")
            return
        }
        #expect(receiptRow["kind"] == .string("reply"))
        #expect(receiptRow["updateId"] == .int(89))

        let stateData = try Data(contentsOf: root
            .appendingPathComponent("telegram", isDirectory: true)
            .appendingPathComponent("state.json"))
        let parsed = try JSONValue.parse(stateData)
        guard case .object(let state) = parsed else {
            Issue.record("expected state object")
            return
        }
        #expect(state["lastChatRetryError"] == .null)
        #expect(state["lastChatRetryFailedAttempt"] == .null)
        #expect(state["lastChatRetryNextAttempt"] == .null)
        #expect(state["lastChatRetrySuppressUserAppend"] == .null)
    }

    @Test func telegramPollLoop_sends_typing_action_before_chat_handler_reply() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("telegram_typing_\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let offset = root
            .appendingPathComponent("telegram", isDirectory: true)
            .appendingPathComponent("last_offset.json")

        let raw = #"""
        {"ok":true,"result":[{"update_id":92,"message":{"message_id":6,"chat":{"id":77},"from":{"id":11},"text":"hello","date":1}}]}
        """#
        let session = mockSession { req in
            (makeResponse(req.url!, 200), Data(raw.utf8))
        }

        actor Capture {
            var sent: [(Int, String)] = []
            var actions: [(Int, String)] = []
            func appendMessage(_ chatId: Int, _ text: String) { sent.append((chatId, text)) }
            func appendAction(_ chatId: Int, _ action: String) { actions.append((chatId, action)) }
            func snapshot() -> ([(Int, String)], [(Int, String)]) { (sent, actions) }
        }
        let cap = Capture()

        let loop = TelegramPollLoop(
            interval: 60,
            token: tokenStr,
            // fail-closed allowlist (2026-08-13): empty = drop-all, so message-flow
            // fixtures must allowlist their chat ids explicitly.
            allowedChatIds: [5, 9, 77],
            session: session,
            dataRoot: root,
            offsetURL: offset,
            sendMessage: { _, chatId, text in
                await cap.appendMessage(chatId, text)
            },
            sendChatAction: { _, chatId, action in
                await cap.appendAction(chatId, action)
            },
            sendMessageReturningId: discardTurnCardSend,
            editMessageText: discardTurnCardEdit,
            turnCardMinimumEditIntervalSeconds: 0,
            turnCardHeartbeatNanoseconds: 0,
            chatHandler: { _, _ in "reply" },
            typingRefreshNanoseconds: 0
        )
        await loop.tick()

        let (sent, actions) = await cap.snapshot()
        #expect(actions.map { $0.0 } == [77])
        #expect(actions.map { $0.1 } == ["typing"])
        #expect(sent.map { $0.1 } == ["reply"])
    }

    // BLOCKER (2026-06-10): /restart's terminate arm must run AFTER the
    // reply send, not before — the old path armed the grace timer inside
    // dispatch and then raced sendMessage against the app exit. This drives
    // the REAL poll loop end to end and pins the event order.
    @Test func telegramPollLoop_restart_arms_terminate_after_reply_send() async throws {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("telegram_restart_order_\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: tmp) }

        // Private chat: chat.id == from.id, chat.type == "private".
        let raw = #"""
        {"ok":true,"result":[{"update_id":99,"message":{"message_id":8,"chat":{"id":1,"type":"private"},"from":{"id":1},"text":"/restart wedged","date":1}}]}
        """#
        let session = mockSession { req in
            (makeResponse(req.url!, 200), Data(raw.utf8))
        }

        final class OrderRecorder: @unchecked Sendable {
            private let lock = NSLock()
            private(set) var events: [String] = []
            func record(_ event: String) {
                lock.lock(); defer { lock.unlock() }
                events.append(event)
            }
        }
        let recorder = OrderRecorder()

        struct OrderedRestartRef: TelegramRestartRef {
            let recorder: OrderRecorder
            func ownerChatIds() async -> Set<Int64> { [1] }
            func requestRestart(reason: String) async -> TelegramRestartOutcome {
                recorder.record("fired:\(reason)")
                return TelegramRestartOutcome(
                    reply: "Restarting NativeAgent — back in under a minute.",
                    armTerminate: { recorder.record("arm") }
                )
            }
        }

        let root = try writeTelegramConfigRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let bot = SwiftNativeTelegramBot(
            dataRoot: root,
            completenessDeps: TelegramBotCompletenessDeps(
                restart: OrderedRestartRef(recorder: recorder)
            )
        )

        let loop = TelegramPollLoop(
            interval: 60,
            token: tokenStr,
            // fail-closed allowlist (2026-08-13): empty = drop-all, so message-flow
            // fixtures must allowlist their chat ids explicitly.
            allowedChatIds: [1, 5, 9, 77],
            bot: bot,
            session: session,
            offsetURL: tmp,
            sendMessage: { _, _, text in
                recorder.record("send:\(text)")
            }
        )
        await loop.tick()

        #expect(recorder.events == [
            "fired:wedged",
            "send:Restarting NativeAgent — back in under a minute.",
            "arm",
        ])
    }

    @Test func telegramPollLoop_uses_one_durable_card_without_progress_message_spray() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("telegram_progress_\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let offset = root
            .appendingPathComponent("telegram", isDirectory: true)
            .appendingPathComponent("last_offset.json")

        let raw = #"""
        {"ok":true,"result":[{"update_id":93,"message":{"message_id":7,"chat":{"id":77},"from":{"id":11},"text":"use tools","date":1}}]}
        """#
        let session = mockSession { req in
            (makeResponse(req.url!, 200), Data(raw.utf8))
        }

        actor Capture {
            var sent: [(Int, String)] = []
            var cards: [(Int, String)] = []
            var edits: [(Int, String)] = []
            func append(_ chatId: Int, _ text: String) { sent.append((chatId, text)) }
            func sendCard(_ chatId: Int, _ text: String) -> Int {
                cards.append((chatId, text))
                return 333
            }
            func editCard(_ messageId: Int, _ text: String) {
                edits.append((messageId, text))
            }
            func snapshot() -> (sent: [(Int, String)], cards: [(Int, String)], edits: [(Int, String)]) {
                (sent, cards, edits)
            }
        }
        let cap = Capture()

        let loop = TelegramPollLoop(
            interval: 60,
            token: tokenStr,
            // fail-closed allowlist (2026-08-13): empty = drop-all, so message-flow
            // fixtures must allowlist their chat ids explicitly.
            allowedChatIds: [5, 9, 77],
            session: session,
            dataRoot: root,
            offsetURL: offset,
            sendMessage: { _, chatId, text in
                await cap.append(chatId, text)
            },
            sendChatAction: { _, _, _ in },
            sendMessageReturningId: { _, chatId, text in
                await cap.sendCard(chatId, text)
            },
            editMessageText: { _, _, messageId, text in
                await cap.editCard(messageId, text)
            },
            turnCardMinimumEditIntervalSeconds: 0,
            turnCardHeartbeatNanoseconds: 0,
            progressChatHandler: { _, _, progress, _ in
                await progress(.toolUse(name: "read_skill", input: .object(["name": .string("builder")])))
                await progress(.toolUse(name: "list_skills", input: nil))
                await progress(.toolResult(name: "read_skill", output: .string("ok")))
                await progress(.toolUse(name: "codex_message", input: nil))
                for index in 0..<12 {
                    await progress(.status(text: "Progress \(index)"))
                }
                return "done"
            },
            typingRefreshNanoseconds: 0
        )
        await loop.tick()

        let captured = await cap.snapshot()
        #expect(captured.sent.map { $0.1 } == ["done"])
        #expect(captured.cards.count == 1)
        #expect(captured.cards[0].1.hasPrefix("Acknowledged ·"))
        #expect(captured.edits.count > 8)
        #expect(captured.edits.allSatisfy { $0.0 == 333 })
        #expect(captured.edits.contains { $0.1.contains("Delegate: Codex") })
        #expect(captured.edits.last?.1.hasPrefix("Completed ·") == true)
    }

    @Test func telegramPollLoop_uploads_generated_images_after_reply() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("telegram_generated_image_\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let offset = root
            .appendingPathComponent("telegram", isDirectory: true)
            .appendingPathComponent("last_offset.json")
        let imagesDir = root.appendingPathComponent("generated_images", isDirectory: true)
        try FileManager.default.createDirectory(at: imagesDir, withIntermediateDirectories: true)
        let imagePath = imagesDir.appendingPathComponent("sample.png", isDirectory: false)
        try Data("fake-png".utf8).write(to: imagePath)

        let raw = #"""
        {"ok":true,"result":[{"update_id":94,"message":{"message_id":8,"chat":{"id":77},"from":{"id":11},"text":"make art","date":1}}]}
        """#
        let session = mockSession { req in
            (makeResponse(req.url!, 200), Data(raw.utf8))
        }

        actor Capture {
            var events: [String] = []
            func append(_ event: String) { events.append(event) }
            func snapshot() -> [String] { events }
        }
        let cap = Capture()

        let loop = TelegramPollLoop(
            interval: 60,
            token: tokenStr,
            // fail-closed allowlist (2026-08-13): empty = drop-all, so message-flow
            // fixtures must allowlist their chat ids explicitly.
            allowedChatIds: [5, 9, 77],
            session: session,
            dataRoot: root,
            offsetURL: offset,
            sendMessage: { _, _, text in
                await cap.append("message:\(text)")
            },
            sendPhoto: { _, chatId, path, caption in
                await cap.append("photo:\(chatId):\(path):\(caption ?? "")")
            },
            sendChatAction: { _, _, action in
                await cap.append("action:\(action)")
            },
            sendMessageReturningId: discardTurnCardSend,
            editMessageText: discardTurnCardEdit,
            turnCardMinimumEditIntervalSeconds: 0,
            turnCardHeartbeatNanoseconds: 0,
            progressChatHandler: { _, _, progress, _ in
                await progress(.toolResult(
                    name: "image_generate",
                    output: .object([
                        "status": .string("ok"),
                        "images": .array([
                            .object([
                                "path": .string(imagePath.path),
                                "filename": .string(imagePath.lastPathComponent),
                                "byteSize": .int(8),
                            ])
                        ]),
                    ])
                ))
                return "done"
            },
            typingRefreshNanoseconds: 0
        )
        await loop.tick()

        #expect(await cap.snapshot() == [
            "action:typing",
            "message:done",
            "action:upload_photo",
            "photo:77:\(imagePath.path):",
        ])
    }

    @Test func telegramPollLoop_richReplyKeepsOneCardOneResponseAndGeneratedMedia() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("telegram_rich_image_\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let offset = root
            .appendingPathComponent("telegram", isDirectory: true)
            .appendingPathComponent("last_offset.json")
        let generatedImages = root.appendingPathComponent("generated_images", isDirectory: true)
        try FileManager.default.createDirectory(at: generatedImages, withIntermediateDirectories: true)
        let imagePath = generatedImages.appendingPathComponent("sample.png")
        try Data("fake-png".utf8).write(to: imagePath)
        let raw = #"""
        {"ok":true,"result":[{"update_id":194,"message":{"message_id":18,"chat":{"id":77},"from":{"id":11},"text":"make a rich report","date":1}}]}
        """#
        let session = mockSession { req in
            (makeResponse(req.url!, 200), Data(raw.utf8))
        }

        actor Capture {
            var ordinary: [String] = []
            var richDrafts: [TelegramInputRichMessage] = []
            var richFinals: [TelegramInputRichMessage] = []
            var cards: [String] = []
            var cardEdits: [String] = []
            var photos: [String] = []
            func appendOrdinary(_ text: String) { ordinary.append(text) }
            func richDraft(_ message: TelegramInputRichMessage) { richDrafts.append(message) }
            func richFinal(_ message: TelegramInputRichMessage) -> Int { richFinals.append(message); return 818 }
            func card(_ text: String) -> Int { cards.append(text); return 717 }
            func cardEdit(_ text: String) { cardEdits.append(text) }
            func photo(_ path: String) { photos.append(path) }
        }
        let capture = Capture()
        let loop = TelegramPollLoop(
            interval: 60,
            token: tokenStr,
            allowedChatIds: [77],
            session: session,
            dataRoot: root,
            offsetURL: offset,
            sendMessage: { _, _, text in await capture.appendOrdinary(text) },
            sendPhoto: { _, _, path, _ in await capture.photo(path) },
            sendChatAction: { _, _, _ in },
            sendMessageReturningId: { _, _, text in await capture.card(text) },
            sendRichMessageDraft: { _, _, _, message in await capture.richDraft(message) },
            sendRichMessage: { _, _, message in await capture.richFinal(message) },
            editMessageText: { _, _, _, text in await capture.cardEdit(text) },
            turnCardMinimumEditIntervalSeconds: 0,
            turnCardHeartbeatNanoseconds: 0,
            progressChatHandler: { _, _, progress, _ in
                await progress(.textDelta(accumulated: "# Report\nPartial"))
                await progress(.toolResult(
                    name: "image_generate",
                    output: .object([
                        "status": .string("ok"),
                        "images": .array([.object([
                            "path": .string(imagePath.path),
                            "filename": .string(imagePath.lastPathComponent),
                            "byteSize": .int(8),
                        ])]),
                    ])
                ))
                return "# Report\nComplete"
            },
            typingRefreshNanoseconds: 0
        )

        await loop.tick()

        #expect(await capture.cards.count == 1)
        #expect(await capture.richDrafts.count == 1)
        #expect(await capture.richFinals.count == 1)
        #expect(await capture.ordinary.isEmpty)
        #expect(await capture.photos == [imagePath.path])
        #expect(await capture.cardEdits.last?.hasPrefix("Completed ·") == true)
        let ledgerURL = root.appendingPathComponent("telegram/work_cards.json")
        let ledgerData = try Data(contentsOf: ledgerURL)
        let ledgerJSON = try JSONValue.parse(ledgerData)
        guard case .object(let ledgerObject) = ledgerJSON,
              case .array(let cards)? = ledgerObject["cards"] else {
            Issue.record("expected work-card ledger envelope")
            return
        }
        #expect(cards.isEmpty)
    }

    @Test func telegramPollLoop_ambiguousRichFinalDoesNotDuplicateAndCardIsOutcomeUnknown() async {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("telegram_rich_ambiguous_\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let offset = root
            .appendingPathComponent("telegram", isDirectory: true)
            .appendingPathComponent("last_offset.json")
        let raw = #"""
        {"ok":true,"result":[{"update_id":195,"message":{"message_id":19,"chat":{"id":77},"from":{"id":11},"text":"reply once","date":1}}]}
        """#
        let session = mockSession { req in
            (makeResponse(req.url!, 200), Data(raw.utf8))
        }

        actor Capture {
            var ordinary: [String] = []
            var richFinalCount = 0
            var cardEdits: [String] = []
            func appendOrdinary(_ text: String) { ordinary.append(text) }
            func richFinal() throws -> Int { richFinalCount += 1; throw URLError(.networkConnectionLost) }
            func edit(_ text: String) { cardEdits.append(text) }
        }
        let capture = Capture()
        let loop = TelegramPollLoop(
            interval: 60,
            token: tokenStr,
            allowedChatIds: [77],
            session: session,
            dataRoot: root,
            offsetURL: offset,
            sendMessage: { _, _, text in await capture.appendOrdinary(text) },
            sendChatAction: { _, _, _ in },
            sendMessageReturningId: { _, _, _ in 719 },
            sendRichMessageDraft: { _, _, _, _ in },
            sendRichMessage: { _, _, _ in try await capture.richFinal() },
            editMessageText: { _, _, _, text in await capture.edit(text) },
            turnCardMinimumEditIntervalSeconds: 0,
            turnCardHeartbeatNanoseconds: 0,
            chatHandler: { _, _ in "Maybe delivered" },
            typingRefreshNanoseconds: 0
        )

        await loop.tick()

        #expect(await capture.richFinalCount == 1)
        #expect(await capture.ordinary.isEmpty)
        #expect(await capture.cardEdits.last?.hasPrefix("Outcome unknown ·") == true)
    }

    @Test func telegramPollLoop_retries_progress_handler_without_duplicate_user_append() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("telegram_retry_\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let offset = root
            .appendingPathComponent("telegram", isDirectory: true)
            .appendingPathComponent("last_offset.json")

        let raw = #"""
        {"ok":true,"result":[{"update_id":95,"message":{"message_id":9,"chat":{"id":77},"from":{"id":11},"text":"retry me","date":1}}]}
        """#
        let session = mockSession { req in
            (makeResponse(req.url!, 200), Data(raw.utf8))
        }

        actor Capture {
            var sent: [String] = []
            var contexts: [TelegramChatAttemptContext] = []
            var userAppends = 0

            func appendSent(_ text: String) { sent.append(text) }
            func appendContext(_ context: TelegramChatAttemptContext) {
                contexts.append(context)
                if !context.suppressUserAppend {
                    userAppends += 1
                }
            }
            func attemptCount() -> Int { contexts.count }
            func snapshot() -> ([String], [TelegramChatAttemptContext], Int) {
                (sent, contexts, userAppends)
            }
        }
        let cap = Capture()

        let loop = TelegramPollLoop(
            interval: 60,
            token: tokenStr,
            // fail-closed allowlist (2026-08-13): empty = drop-all, so message-flow
            // fixtures must allowlist their chat ids explicitly.
            allowedChatIds: [5, 9, 77],
            session: session,
            dataRoot: root,
            offsetURL: offset,
            sendMessage: { _, _, text in
                await cap.appendSent(text)
            },
            sendChatAction: { _, _, _ in },
            sendMessageReturningId: discardTurnCardSend,
            editMessageText: discardTurnCardEdit,
            turnCardMinimumEditIntervalSeconds: 0,
            turnCardHeartbeatNanoseconds: 0,
            progressChatHandler: { _, _, _, context in
                await cap.appendContext(context)
                if await cap.attemptCount() == 1 {
                    throw URLError(.timedOut)
                }
                return "retry reply"
            },
            chatRetryAttempts: 1,
            chatRetryDelayNanoseconds: 0,
            typingRefreshNanoseconds: 0
        )
        await loop.tick()

        let (sent, contexts, userAppends) = await cap.snapshot()
        #expect(sent == ["retry reply"])
        #expect(contexts.map(\.attemptIndex) == [0, 1])
        #expect(contexts.map(\.suppressUserAppend) == [false, true])
        #expect(contexts.map(\.fromUserId) == [11, 11])
        #expect(userAppends == 1)

        let data = try Data(contentsOf: offset)
        let parsed = try JSONValue.parse(data)
        guard case .object(let obj) = parsed else {
            Issue.record("expected offset object")
            return
        }
        #expect(obj["offset"] == .int(96))
    }

    @Test func telegramPollLoop_persists_offset_before_chat_handler_runs() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("telegram_offset_before_handler_\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let offset = root
            .appendingPathComponent("telegram", isDirectory: true)
            .appendingPathComponent("last_offset.json")

        let raw = #"""
        {"ok":true,"result":[{"update_id":97,"message":{"message_id":11,"chat":{"id":77},"from":{"id":11},"text":"slow turn","date":1}}]}
        """#
        let session = mockSession { req in
            (makeResponse(req.url!, 200), Data(raw.utf8))
        }

        actor Capture {
            var offsetDuringHandler: Int?
            var sent: [String] = []

            func captureOffset(_ url: URL) {
                guard let data = try? Data(contentsOf: url),
                      let parsed = try? JSONValue.parse(data),
                      case .object(let obj) = parsed,
                      let raw = obj["offset"] else {
                    offsetDuringHandler = nil
                    return
                }
                switch raw {
                case .int(let value):
                    offsetDuringHandler = Int(value)
                case .double(let value):
                    offsetDuringHandler = Int(value)
                default:
                    offsetDuringHandler = nil
                }
            }

            func appendSent(_ text: String) { sent.append(text) }
            func snapshot() -> (Int?, [String]) { (offsetDuringHandler, sent) }
        }
        let cap = Capture()

        let loop = TelegramPollLoop(
            interval: 60,
            token: tokenStr,
            // fail-closed allowlist (2026-08-13): empty = drop-all, so message-flow
            // fixtures must allowlist their chat ids explicitly.
            allowedChatIds: [5, 9, 77],
            session: session,
            dataRoot: root,
            offsetURL: offset,
            sendMessage: { _, _, text in
                await cap.appendSent(text)
            },
            sendChatAction: { _, _, _ in },
            sendMessageReturningId: discardTurnCardSend,
            editMessageText: discardTurnCardEdit,
            turnCardMinimumEditIntervalSeconds: 0,
            turnCardHeartbeatNanoseconds: 0,
            progressChatHandler: { _, _, _, _ in
                await cap.captureOffset(offset)
                return "done"
            },
            typingRefreshNanoseconds: 0
        )
        await loop.tick()

        let (offsetDuringHandler, sent) = await cap.snapshot()
        #expect(offsetDuringHandler == 98)
        #expect(sent == ["done"])
    }

    @Test func telegramPollLoop_transcribes_voice_message_and_routes_to_chat_with_marker() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("telegram_voice_\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let offset = root
            .appendingPathComponent("telegram", isDirectory: true)
            .appendingPathComponent("last_offset.json")

        let raw = #"""
        {"ok":true,"result":[{"update_id":94,"message":{"message_id":8,"chat":{"id":77},"from":{"id":11},"voice":{"file_id":"VOICE_FILE_ID","file_size":10,"mime_type":"audio/ogg","duration":3},"date":1}}]}
        """#
        let session = mockSession { req in
            (makeResponse(req.url!, 200), Data(raw.utf8))
        }

        actor Capture {
            var sent: [(Int, String)] = []
            var actions: [(Int, String)] = []
            var handlerTexts: [String] = []
            func appendMessage(_ chatId: Int, _ text: String) { sent.append((chatId, text)) }
            func appendAction(_ chatId: Int, _ action: String) { actions.append((chatId, action)) }
            func appendHandlerText(_ text: String) { handlerTexts.append(text) }
            func snapshot() -> ([(Int, String)], [(Int, String)], [String]) {
                (sent, actions, handlerTexts)
            }
        }
        let cap = Capture()

        let loop = TelegramPollLoop(
            interval: 60,
            token: tokenStr,
            // fail-closed allowlist (2026-08-13): empty = drop-all, so message-flow
            // fixtures must allowlist their chat ids explicitly.
            allowedChatIds: [5, 9, 77],
            session: session,
            dataRoot: root,
            offsetURL: offset,
            sendMessage: { _, chatId, text in
                await cap.appendMessage(chatId, text)
            },
            sendChatAction: { _, chatId, action in
                await cap.appendAction(chatId, action)
            },
            sendMessageReturningId: discardTurnCardSend,
            editMessageText: discardTurnCardEdit,
            turnCardMinimumEditIntervalSeconds: 0,
            turnCardHeartbeatNanoseconds: 0,
            progressChatHandler: { _, text, _, _ in
                await cap.appendHandlerText(text)
                return "voice reply"
            },
            voiceDownloader: FakeVoiceDownloader(bytes: Data("voice-bytes".utf8)),
            voiceTranscriber: FakeVoiceTranscriber(),
            voiceMaxBytes: 1024 * 1024,
            typingRefreshNanoseconds: 0
        )
        await loop.tick()

        let (sent, actions, handlerTexts) = await cap.snapshot()
        #expect(actions.map { $0.1 } == ["typing", "typing"])
        #expect(sent.map { $0.1 } == ["Transcribing voice message", "voice reply"])
        #expect(handlerTexts.count == 1)
        #expect(handlerTexts.first?.contains("[Telegram voice message]") == true)
        #expect(handlerTexts.first?.contains("hey Agent this came from a voice message") == true)

        let receipts = try readTelegramJSONL(root, "receipts.jsonl")
        #expect(receipts.count == 2)
        guard case .object(let transcriptionRow)? = receipts.first,
              case .object(let replyRow)? = receipts.last else {
            Issue.record("expected voice transcription and reply receipts")
            return
        }
        #expect(transcriptionRow["kind"] == .string("voice_transcription"))
        #expect(transcriptionRow["model"] == .string("test-transcribe"))
        #expect(replyRow["kind"] == .string("voice_reply"))
        #expect(replyRow["replyPreview"] == .string("voice reply"))
    }

    /// PATCH-2026-08-18 (root cause 130dc377): a missing macOS Speech
    /// Recognition grant must never be a silent drop. Three things have to
    /// happen together — the SENDER gets a chat notice, the failure is recorded,
    /// and the app-side capability signal fires so the human at the Mac gets a
    /// card with a route to System Settings. Asserting only the chat notice
    /// would have passed before the fix existed.
    @Test func telegramPollLoop_voice_speech_permission_denied_raises_capability_flag_and_user_notice() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("telegram_voice_denied_\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let offset = root
            .appendingPathComponent("telegram", isDirectory: true)
            .appendingPathComponent("last_offset.json")

        let raw = #"""
        {"ok":true,"result":[{"update_id":94,"message":{"message_id":8,"chat":{"id":77},"from":{"id":11},"voice":{"file_id":"VOICE_FILE_ID","file_size":10,"mime_type":"audio/ogg","duration":3},"date":1}}]}
        """#
        let session = mockSession { req in
            (makeResponse(req.url!, 200), Data(raw.utf8))
        }

        actor Capture {
            var sent: [String] = []
            var capabilities: [String] = []
            func appendMessage(_ text: String) { sent.append(text) }
            func appendCapability(_ name: String) { capabilities.append(name) }
            func snapshot() -> ([String], [String]) { (sent, capabilities) }
        }
        let cap = Capture()

        let loop = TelegramPollLoop(
            interval: 60,
            token: tokenStr,
            allowedChatIds: [5, 9, 77],
            session: session,
            dataRoot: root,
            offsetURL: offset,
            sendMessage: { _, _, text in await cap.appendMessage(text) },
            sendChatAction: { _, _, _ in },
            sendMessageReturningId: discardTurnCardSend,
            editMessageText: discardTurnCardEdit,
            turnCardMinimumEditIntervalSeconds: 0,
            turnCardHeartbeatNanoseconds: 0,
            progressChatHandler: { _, _, _, _ in "unused" },
            voiceDownloader: FakeVoiceDownloader(bytes: Data("voice-bytes".utf8)),
            voiceTranscriber: FailingVoiceTranscriber(
                error: TelegramVoiceTranscriptionError.speechPermissionDenied("denied")
            ),
            onCapabilityDenied: { name in await cap.appendCapability(name) },
            voiceMaxBytes: 1024 * 1024,
            typingRefreshNanoseconds: 0
        )
        await loop.tick()

        let (sent, capabilities) = await cap.snapshot()

        // 1. The Telegram sender is told, in words that name the actual problem.
        #expect(sent.contains { $0.contains("Speech Recognition permission is not approved") })

        // 2. The app-side signal fired exactly once, naming the capability.
        #expect(capabilities == ["speechRecognition"])

        // 3. The failure is on the record with its context.
        let errors = try readTelegramJSONL(root, "errors.jsonl")
        #expect(errors.count == 1)
        guard case .object(let errorRow)? = errors.first else {
            Issue.record("expected a voice_transcription error row")
            return
        }
        #expect(errorRow["context"] == .string("voice_transcription"))
    }

    /// NEGATIVE CONTROL for the test above. Without this, that test passes for
    /// the wrong reason — a catch block that flagged EVERY failure would satisfy
    /// it while turning the permission card into noise the user learns to
    /// ignore. A conversion failure is a real voice failure that no System
    /// Settings switch can fix, so it must NOT raise the capability flag.
    // No `throws` on this one: nothing in the body throws, and Swift's typed-throws
    // inference makes a bare `async throws` here resolve to `throws(Never)`.
    @Test func telegramPollLoop_voice_non_permission_error_does_not_raise_capability_flag() async {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("telegram_voice_convfail_\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let offset = root
            .appendingPathComponent("telegram", isDirectory: true)
            .appendingPathComponent("last_offset.json")

        let raw = #"""
        {"ok":true,"result":[{"update_id":94,"message":{"message_id":8,"chat":{"id":77},"from":{"id":11},"voice":{"file_id":"VOICE_FILE_ID","file_size":10,"mime_type":"audio/ogg","duration":3},"date":1}}]}
        """#
        let session = mockSession { req in
            (makeResponse(req.url!, 200), Data(raw.utf8))
        }

        actor Capture {
            var sent: [String] = []
            var capabilities: [String] = []
            func appendMessage(_ text: String) { sent.append(text) }
            func appendCapability(_ name: String) { capabilities.append(name) }
            func snapshot() -> ([String], [String]) { (sent, capabilities) }
        }
        let cap = Capture()

        let loop = TelegramPollLoop(
            interval: 60,
            token: tokenStr,
            allowedChatIds: [5, 9, 77],
            session: session,
            dataRoot: root,
            offsetURL: offset,
            sendMessage: { _, _, text in await cap.appendMessage(text) },
            sendChatAction: { _, _, _ in },
            sendMessageReturningId: discardTurnCardSend,
            editMessageText: discardTurnCardEdit,
            turnCardMinimumEditIntervalSeconds: 0,
            turnCardHeartbeatNanoseconds: 0,
            progressChatHandler: { _, _, _, _ in "unused" },
            voiceDownloader: FakeVoiceDownloader(bytes: Data("voice-bytes".utf8)),
            voiceTranscriber: FailingVoiceTranscriber(
                error: TelegramVoiceTranscriptionError.conversionFailed("ffmpeg exited 1")
            ),
            onCapabilityDenied: { name in await cap.appendCapability(name) },
            voiceMaxBytes: 1024 * 1024,
            typingRefreshNanoseconds: 0
        )
        await loop.tick()

        let (sent, capabilities) = await cap.snapshot()

        // The sender is still told something went wrong — failures are never silent.
        #expect(sent.contains { $0.contains("I got your voice note") })
        // But no permission card is raised: no TCC switch would fix this.
        #expect(capabilities.isEmpty)
    }

    @Test func telegramPollLoop_voice_post_download_byte_cap_drops_oversized() async throws {
        // 2026-07-21 audit: the voice path trusted the downloader's
        // pre-flight size check alone. The post-download HARD cap (mirror
        // of the photo guard) must drop oversized bytes before they reach
        // the transcriber or the chat handler.
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("telegram_voice_oversized_\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let offset = root
            .appendingPathComponent("telegram", isDirectory: true)
            .appendingPathComponent("last_offset.json")

        let raw = #"""
        {"ok":true,"result":[{"update_id":94,"message":{"message_id":8,"chat":{"id":77},"from":{"id":11},"voice":{"file_id":"VOICE_FILE_ID","file_size":10,"mime_type":"audio/ogg","duration":3},"date":1}}]}
        """#
        let session = mockSession { req in
            (makeResponse(req.url!, 200), Data(raw.utf8))
        }

        actor Capture {
            var sent: [(Int, String)] = []
            var handlerCalls = 0
            func appendMessage(_ chatId: Int, _ text: String) { sent.append((chatId, text)) }
            func bumpHandler() { handlerCalls += 1 }
            func snapshot() -> ([(Int, String)], Int) { (sent, handlerCalls) }
        }
        let cap = Capture()

        let loop = TelegramPollLoop(
            interval: 60,
            token: tokenStr,
            // fail-closed allowlist (2026-08-13): empty = drop-all, so message-flow
            // fixtures must allowlist their chat ids explicitly.
            allowedChatIds: [5, 9, 77],
            session: session,
            dataRoot: root,
            offsetURL: offset,
            sendMessage: { _, chatId, text in
                await cap.appendMessage(chatId, text)
            },
            sendChatAction: { _, _, _ in },
            sendMessageReturningId: discardTurnCardSend,
            editMessageText: discardTurnCardEdit,
            turnCardMinimumEditIntervalSeconds: 0,
            turnCardHeartbeatNanoseconds: 0,
            progressChatHandler: { _, _, _, _ in
                await cap.bumpHandler()
                return "should not run"
            },
            voiceDownloader: OversizedVoiceDownloader(bytes: Data("voice-bytes".utf8)),
            voiceTranscriber: FakeVoiceTranscriber(),
            voiceMaxBytes: 4,
            typingRefreshNanoseconds: 0
        )
        await loop.tick()

        let (sent, handlerCalls) = await cap.snapshot()
        #expect(handlerCalls == 0, "oversized voice bytes must never reach the chat handler")
        #expect(sent.contains { $0.1.contains("too large") })
        let receipts = try readTelegramJSONL(root, "receipts.jsonl")
        #expect(receipts.contains { row in
            if case .object(let o) = row, o["kind"] == .string("voice_transcription_error") { return true }
            return false
        })
    }

    @Test func telegramPollLoop_transient_chat_handler_exhaustion_sends_provider_notice() async throws {
        struct TransientFailure: LocalizedError {
            var errorDescription: String? {
                "chat: llm: transient: connection refused: chatgpt.com"
            }
        }
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("telegram_retry_exhausted_\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let offset = root
            .appendingPathComponent("telegram", isDirectory: true)
            .appendingPathComponent("last_offset.json")

        let raw = #"""
        {"ok":true,"result":[{"update_id":90,"message":{"message_id":5,"chat":{"id":77},"from":{"id":11},"text":"hello","date":1}}]}
        """#
        let session = mockSession { req in
            (makeResponse(req.url!, 200), Data(raw.utf8))
        }

        actor Capture {
            var sent: [(Int, String)] = []
            var handlerCalls = 0
            var cardSends: [String] = []
            var cardEdits: [String] = []
            func append(_ chatId: Int, _ text: String) { sent.append((chatId, text)) }
            func bumpHandlerCall() { handlerCalls += 1 }
            func sendCard(_ text: String) -> Int { cardSends.append(text); return 901 }
            func editCard(_ text: String) { cardEdits.append(text) }
            func snapshot() -> (sent: [(Int, String)], handlerCalls: Int, cardSends: [String], cardEdits: [String]) {
                (sent, handlerCalls, cardSends, cardEdits)
            }
        }
        let cap = Capture()

        let loop = TelegramPollLoop(
            interval: 60,
            token: tokenStr,
            // fail-closed allowlist (2026-08-13): empty = drop-all, so message-flow
            // fixtures must allowlist their chat ids explicitly.
            allowedChatIds: [5, 9, 77],
            session: session,
            dataRoot: root,
            offsetURL: offset,
            sendMessage: { _, chatId, text in
                await cap.append(chatId, text)
            },
            sendChatAction: { _, _, _ in },
            sendMessageReturningId: { _, _, text in await cap.sendCard(text) },
            editMessageText: { _, _, _, text in await cap.editCard(text) },
            turnCardMinimumEditIntervalSeconds: 0,
            turnCardHeartbeatNanoseconds: 0,
            chatHandler: { _, _ in
                await cap.bumpHandlerCall()
                throw TransientFailure()
            },
            chatRetryAttempts: 1,
            chatRetryDelayNanoseconds: 0
        )
        await loop.tick()

        let captured = await cap.snapshot()
        #expect(captured.handlerCalls == 2)
        #expect(captured.sent.map { $0.1 } == ["(drafting stalled; try again in a moment)"])
        #expect(captured.cardSends.count == 1)
        #expect(captured.cardEdits.contains { $0.hasPrefix("Retrying ·") })
        #expect(captured.cardEdits.last?.hasPrefix("Failed ·") == true)

        let receipts = try readTelegramJSONL(root, "receipts.jsonl")
        guard case .object(let receiptRow)? = receipts.first else {
            Issue.record("expected receipt row")
            return
        }
        #expect(receiptRow["kind"] == .string("error_notice"))
        #expect(receiptRow["replyPreview"] == .string("(drafting stalled; try again in a moment)"))
    }

    @Test func telegramPollLoop_records_reply_send_failures_in_state() async throws {
        enum SendFailure: Error { case noRoute }
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("telegram_send_fail_\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let offset = root
            .appendingPathComponent("telegram", isDirectory: true)
            .appendingPathComponent("last_offset.json")

        let raw = #"""
        {"ok":true,"result":[{"update_id":91,"message":{"message_id":4,"chat":{"id":77},"from":{"id":11},"text":"hello","date":1}}]}
        """#
        let session = mockSession { req in
            (makeResponse(req.url!, 200), Data(raw.utf8))
        }
        let loop = TelegramPollLoop(
            interval: 60,
            token: tokenStr,
            // fail-closed allowlist (2026-08-13): empty = drop-all, so message-flow
            // fixtures must allowlist their chat ids explicitly.
            allowedChatIds: [5, 9, 77],
            session: session,
            dataRoot: root,
            offsetURL: offset,
            sendMessage: { _, _, _ in throw SendFailure.noRoute },
            sendChatAction: { _, _, _ in },
            sendMessageReturningId: discardTurnCardSend,
            editMessageText: discardTurnCardEdit,
            turnCardMinimumEditIntervalSeconds: 0,
            turnCardHeartbeatNanoseconds: 0,
            chatHandler: { _, _ in "reply" }
        )
        await loop.tick()

        let errors = try readTelegramJSONL(root, "errors.jsonl")
        guard case .object(let errorRow)? = errors.first else {
            Issue.record("expected error row")
            return
        }
        #expect(errorRow["context"] == .string("send_reply"))
        #expect(errorRow["updateId"] == .int(91))

        let status = try await SwiftNativeTelegramBot(dataRoot: root).getStatus()
        #expect(status.lastSeenUpdateId == 91)
        #expect(status.lastError?.contains("send_reply") == true)
    }

    @Test func telegramPollLoop_successful_empty_poll_clears_stale_error_state() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("telegram_empty_poll_\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let teleDir = root.appendingPathComponent("telegram", isDirectory: true)
        try FileManager.default.createDirectory(at: teleDir, withIntermediateDirectories: true)
        try Data(#"{"lastError":"poll: old timeout","lastChatRetryError":"old retry","lastChatRetryFailedAttempt":1,"lastChatRetryNextAttempt":2,"lastChatRetrySuppressUserAppend":true}"#.utf8)
            .write(to: teleDir.appendingPathComponent("state.json"))
        let session = mockSession { req in
            (makeResponse(req.url!, 200), Data(#"{"ok":true,"result":[]}"#.utf8))
        }
        let loop = TelegramPollLoop(
            interval: 60,
            token: tokenStr,
            // fail-closed allowlist (2026-08-13): empty = drop-all, so message-flow
            // fixtures must allowlist their chat ids explicitly.
            allowedChatIds: [5, 9, 77],
            session: session,
            dataRoot: root,
            offsetURL: teleDir.appendingPathComponent("last_offset.json"),
            sendMessage: { _, _, _ in }
        )
        await loop.tick()

        let stateData = try Data(contentsOf: teleDir.appendingPathComponent("state.json"))
        let parsed = try JSONValue.parse(stateData)
        guard case .object(let obj) = parsed else {
            Issue.record("expected state object")
            return
        }
        #expect(obj["lastError"] == .null)
        #expect(obj["lastChatRetryError"] == .null)
        #expect(obj["lastChatRetryFailedAttempt"] == .null)
        #expect(obj["lastChatRetryNextAttempt"] == .null)
        #expect(obj["lastChatRetrySuppressUserAppend"] == .null)
        guard case .string(let pollAt)? = obj["lastPollAt"] else {
            Issue.record("expected lastPollAt")
            return
        }
        #expect(!pollAt.isEmpty)
    }

    @Test func unknown_command_advances_offset_so_polling_cannot_wedge() async throws {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("telegram_test_\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: tmp) }

        try Data(#"{"offset":10}"#.utf8).write(to: tmp)

        let raw = #"""
        {"ok":true,"result":[{"update_id":99,"message":{"message_id":1,"chat":{"id":5},"text":"/xyzzy_unknown","date":1}}]}
        """#
        let session = mockSession { req in
            (makeResponse(req.url!, 200), Data(raw.utf8))
        }

        let loop = TelegramPollLoop(
            interval: 60,
            token: tokenStr,
            // fail-closed allowlist (2026-08-13): empty = drop-all, so message-flow
            // fixtures must allowlist their chat ids explicitly.
            allowedChatIds: [5, 9, 77],
            bot: SwiftNativeTelegramBot(dataRoot: hermeticTelegramDataRoot()),
            session: session,
            offsetURL: tmp,
            sendMessage: { _, _, _ in }
        )
        await loop.tick()

        let data = try Data(contentsOf: tmp)
        let parsed = try JSONValue.parse(data)
        guard case .object(let obj) = parsed, let v = obj["offset"] else {
            Issue.record("expected offset object"); return
        }
        var read: Int = -1
        if case .int(let i) = v { read = Int(i) }
        else if case .double(let d) = v { read = Int(d) }
        #expect(read == 100)
    }

    @Test func encoded_token_in_URL() async throws {
        nonisolated(unsafe) var captured: URLRequest?
        let session = mockSession { req in
            captured = req
            return (makeResponse(req.url!, 200), Data(#"{"ok":true,"result":[]}"#.utf8))
        }
        let bot = SwiftNativeTelegramBot(dataRoot: hermeticTelegramDataRoot())
        let weirdToken = "abc/def:ghi?xyz"
        _ = try await bot.longPoll(token: weirdToken, offset: 0, timeoutSeconds: 25, session: session)
        let url = captured?.url?.absoluteString ?? ""
        #expect(!url.contains("abc/def:ghi?xyz"))
        #expect(url.contains("abc%2Fdef%3Aghi%3Fxyz"))
    }

    @Test func telegramConfig_loadFromDisk_perFeature_path() async throws {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("tele_cfg_\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let teleDir = tmp.appendingPathComponent("telegram", isDirectory: true)
        try FileManager.default.createDirectory(at: teleDir, withIntermediateDirectories: true)
        let payload = #"""
        {"bot_token":"123:abc","allowed_chat_ids":[12345,67890],"enabled":true}
        """#
        try Data(payload.utf8).write(to: teleDir.appendingPathComponent("config.json"))
        let cfg = TelegramConfig.loadFromDisk(dataRoot: tmp)
        #expect(cfg?.botToken == "123:abc")
        #expect(cfg?.allowedChatIds == [12345, 67890])
        #expect(cfg?.enabled == true)
        #expect(cfg?.voiceTranscriptionBackend == TelegramVoiceTranscriptionBackends.appleSpeech)
        #expect(cfg?.voiceTranscriptionModel == TelegramVoiceTranscriptionBackends.appleSpeechModel)
    }

    @Test func telegramConfig_loadFromDisk_canonicalizes_voice_backend_aliases() async throws {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("tele_cfg_\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let teleDir = tmp.appendingPathComponent("telegram", isDirectory: true)
        try FileManager.default.createDirectory(at: teleDir, withIntermediateDirectories: true)
        let payload = #"""
        {"bot_token":"123:abc","allowed_chat_ids":[1],"enabled":true,"voice_transcription_backend":"speech","voice_transcription_model":""}
        """#
        try Data(payload.utf8).write(to: teleDir.appendingPathComponent("config.json"))
        let cfg = TelegramConfig.loadFromDisk(dataRoot: tmp)
        #expect(cfg?.voiceTranscriptionBackend == TelegramVoiceTranscriptionBackends.appleSpeech)
        #expect(cfg?.voiceTranscriptionModel == TelegramVoiceTranscriptionBackends.appleSpeechModel)
    }

    @Test func telegramConfig_saveToDisk_locksDownTokenFilePermissions() async throws {
        // 2026-07-21 audit: the bot-token file was persisted with default
        // perms while the X OAuth token store gets explicit 0600/0700.
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("tele_cfg_\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        try TelegramConfig.saveToDisk(
            TelegramConfig(botToken: "123:secret-token", allowedChatIds: [1], enabled: true),
            dataRoot: tmp
        )
        let dir = tmp.appendingPathComponent("telegram", isDirectory: true)
        let file = dir.appendingPathComponent("config.json")
        let dirPerms = try FileManager.default.attributesOfItem(atPath: dir.path)[.posixPermissions] as? NSNumber
        let filePerms = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber
        #expect(dirPerms?.intValue == 0o700)
        #expect(filePerms?.intValue == 0o600)
    }

    @Test func telegramConfig_loadFromDisk_healsLooseTokenFilePermissions() async throws {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("tele_cfg_\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let teleDir = tmp.appendingPathComponent("telegram", isDirectory: true)
        try FileManager.default.createDirectory(at: teleDir, withIntermediateDirectories: true)
        let file = teleDir.appendingPathComponent("config.json")
        let payload = #"""
        {"bot_token":"123:abc","allowed_chat_ids":[1],"enabled":true}
        """#
        try Data(payload.utf8).write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path)
        let cfg = TelegramConfig.loadFromDisk(dataRoot: tmp)
        #expect(cfg?.botToken == "123:abc")
        let filePerms = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber
        #expect(filePerms?.intValue == 0o600)
    }

    @Test func telegramConfig_loadFromDisk_ignores_legacy_daemon_config() async throws {
        // 2026-06-06 daemon-config retirement: the legacy
        // <dataRoot>/config/config.json[telegram] block is dead. Swift no
        // longer reads it under any circumstance, even when the canonical
        // <dataRoot>/telegram/config.json is absent. The one-shot
        // migration shim was retired along with the daemon-era config; no
        // code path reads the legacy block anymore.
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("tele_cfg_\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let cfgDir = tmp.appendingPathComponent("config", isDirectory: true)
        try FileManager.default.createDirectory(at: cfgDir, withIntermediateDirectories: true)
        let payload = #"""
        {"telegram":{"token":"xyz:777","allowed_chat_ids":[42],"enabled":true}}
        """#
        try Data(payload.utf8).write(to: cfgDir.appendingPathComponent("config.json"))
        let cfg = TelegramConfig.loadFromDisk(dataRoot: tmp)
        // No canonical telegram/config.json AND we no longer fall back to
        // the legacy block → result is nil.
        #expect(cfg == nil)
        // Canonical file was NOT created by the load attempt.
        let canonical = tmp
            .appendingPathComponent("telegram", isDirectory: true)
            .appendingPathComponent("config.json")
        #expect(!FileManager.default.fileExists(atPath: canonical.path))
    }

    @Test func telegramConfig_loadFromDisk_roundtrips_disabled_token() async throws {
        // F4 fix-5: a saved-disabled token MUST round-trip — saving with
        // enabled=false used to drop the whole config to nil, wiping every
        // configured field on the next read. Now the config comes back with
        // enabled=false so the UI's toggle survives.
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("tele_cfg_\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let teleDir = tmp.appendingPathComponent("telegram", isDirectory: true)
        try FileManager.default.createDirectory(at: teleDir, withIntermediateDirectories: true)
        let payload = #"""
        {"bot_token":"123:abc","allowed_chat_ids":[1],"enabled":false}
        """#
        try Data(payload.utf8).write(to: teleDir.appendingPathComponent("config.json"))
        let cfg = TelegramConfig.loadFromDisk(dataRoot: tmp)
        #expect(cfg?.botToken == "123:abc")
        #expect(cfg?.enabled == false)
        #expect(cfg?.allowedChatIds == [1])
    }

    @Test func timeout_interval_assertion() async throws {
        nonisolated(unsafe) var captured: URLRequest?
        let session = mockSession { req in
            captured = req
            return (makeResponse(req.url!, 200), Data(#"{"ok":true,"result":[]}"#.utf8))
        }
        let bot = SwiftNativeTelegramBot(dataRoot: hermeticTelegramDataRoot())
        _ = try await bot.longPoll(token: tokenStr, offset: 0, timeoutSeconds: 25, session: session)
        #expect(captured?.timeoutInterval == 35)
    }
}

// Audit 2026-06-09: Telegram hard-rejects >4096-char messages; before
// chunking, long Agent replies died silently (typing, then nothing).
@Suite("Telegram message chunking")
struct TelegramChunkingTests {
    @Test func shortMessagePassesThroughUnchanged() {
        let chunks = TelegramPollLoop._tgChunkMessage("hello the user", limit: 4000)
        #expect(chunks == ["hello the user"])
    }

    @Test func longMessageSplitsUnderLimitPreservingContent() {
        let line = String(repeating: "x", count: 80)
        let text = Array(repeating: line, count: 200).joined(separator: "\n") // ~16k chars
        let chunks = TelegramPollLoop._tgChunkMessage(text, limit: 4000)
        #expect(chunks.count >= 4)
        for c in chunks { #expect(c.count <= 4000) }
        // Content preserved modulo the newline/space separators we split on.
        let rejoined = chunks.joined(separator: "\n")
        #expect(rejoined.replacingOccurrences(of: "\n", with: "")
            == text.replacingOccurrences(of: "\n", with: ""))
    }

    @Test func unbrokenBlobStillSplitsHard() {
        let text = String(repeating: "a", count: 9000)
        let chunks = TelegramPollLoop._tgChunkMessage(text, limit: 4000)
        #expect(chunks.count == 3)
        #expect(chunks.joined() == text)
    }

    @Test func budgetsByUTF16NotGraphemes() {
        // Telegram counts UTF-16 code units: 3000 emoji = 3000 graphemes
        // but 6000 units — one grapheme-budgeted chunk would 400.
        let text = String(repeating: "\u{1F600}", count: 3000)
        let chunks = TelegramPollLoop._tgChunkMessage(text, limit: 4000)
        #expect(chunks.count == 2)
        for c in chunks { #expect(c.utf16.count <= 4000) }
        #expect(chunks.joined() == text)
    }

}

// Audit 2026-06-09 (security-adjacent): URLSession errors embed the failing
// URL incl. /bot<TOKEN>/; recordError rows render in the Mac UI.
@Suite("Telegram token redaction")
struct TelegramTokenRedactionTests {
    @Test func redactsBotTokenInURLErrorText() {
        let raw = "Error Domain=NSURLErrorDomain Code=-1009 \"offline\" UserInfo={NSErrorFailingURLStringKey=https://api.telegram.org/bot7123456789:AAH-secret_Token123/sendMessage}"
        let redacted = TelegramPollLoop._tgRedactToken(raw)
        #expect(!redacted.contains("AAH-secret_Token123"))
        #expect(redacted.contains("bot<redacted>"))
        #expect(redacted.contains("sendMessage"))
    }

    @Test func leavesTokenFreeTextAlone() {
        let raw = "getUpdates status 409"
        #expect(TelegramPollLoop._tgRedactToken(raw) == raw)
    }
}

// MARK: - telegram-vision-in (inbound photo ingestion)
//
// Recovers the daemon-era telegram_photo_attachment / max_bytes / downloader
// behaviour (commit 0f50aa30) on the Swift poll path. Hermetic: the Telegram
// getUpdates JSON is a fixture and the image download is a mock.

// Dedicated stub subclass for the photo-ingest suite. A SEPARATE class from
// the file's global MockURLProtocol so this @Suite(.serialized) suite can't
// clobber SwiftNativeTelegramBotPhaseBTests' handler when the two suites run
// in parallel — ConfigurableURLProtocolStub keys handler storage by concrete
// class, so distinct subclasses stay isolated (same hazard CmpMockURLProtocol
// avoids).
private final class PhotoMockURLProtocol: ConfigurableURLProtocolStub {}

private func photoMockSession(_ handler: @escaping (URLRequest) throws -> (HTTPURLResponse, Data)) -> URLSession {
    PhotoMockURLProtocol.makeSession(handler: handler)
}

private func readTracesJSONL(_ root: URL) -> [JSONValue] {
    let path = root
        .appendingPathComponent("traces", isDirectory: true)
        .appendingPathComponent("events.jsonl")
    guard let data = try? Data(contentsOf: path),
          let text = String(data: data, encoding: .utf8) else { return [] }
    return text.split(separator: "\n", omittingEmptySubsequences: true).compactMap { line in
        try? JSONValue.parse(Data(String(line).utf8))
    }
}

@Suite(.serialized)
struct TelegramPhotoIngestTests {

    // A photo downloader that returns fixed bytes (success), mirroring the real
    // two-stage TelegramMediaDownloader's output shape.
    private struct FakePhotoDownloader: TelegramMediaDownloading {
        let bytes: Data
        let filename: String?
        func download(token: String, attachment: TelegramMediaAttachment, maxBytes: Int) async throws -> TelegramMediaAttachment {
            TelegramMediaAttachment(
                kind: attachment.kind,
                fileId: attachment.fileId,
                mimeType: attachment.mimeType,
                sizeBytes: bytes.count,
                bytes: bytes,
                captureFilename: filename
            )
        }
    }

    private struct FailingPhotoDownloader: TelegramMediaDownloading {
        let error: TelegramMediaDownloadError
        func download(token: String, attachment: TelegramMediaAttachment, maxBytes: Int) async throws -> TelegramMediaAttachment {
            throw error
        }
    }

    // MARK: pure extraction

    @Test func photoAttachment_picks_largest_variant() {
        let msg = TelegramMessage(
            messageId: 1, chatId: 9, date: 1,
            extras: .object(["photo": .array([
                .object(["file_id": .string("small"), "width": .int(90), "height": .int(60)]),
                .object(["file_id": .string("big"), "width": .int(1280), "height": .int(720)]),
                .object(["file_id": .string("mid"), "width": .int(320), "height": .int(240)]),
            ])])
        )
        let att = TelegramPollLoop.photoAttachment(from: msg)
        #expect(att?.kind == "photo")
        #expect(att?.fileId == "big")
    }

    @Test func photoAttachment_accepts_image_document() {
        let msg = TelegramMessage(
            messageId: 1, chatId: 9, date: 1,
            extras: .object(["document": .object([
                "file_id": .string("doc1"), "mime_type": .string("image/png"),
            ])])
        )
        let att = TelegramPollLoop.photoAttachment(from: msg)
        #expect(att?.kind == "document")
        #expect(att?.fileId == "doc1")
        #expect(att?.mimeType == "image/png")
    }

    @Test func photoAttachment_rejects_non_image_document_and_text() {
        let pdf = TelegramMessage(messageId: 1, chatId: 9, date: 1,
            extras: .object(["document": .object(["file_id": .string("x"), "mime_type": .string("application/pdf")])]))
        #expect(TelegramPollLoop.photoAttachment(from: pdf) == nil)
        let textOnly = TelegramMessage(messageId: 1, chatId: 9, text: "hi", date: 1)
        #expect(TelegramPollLoop.photoAttachment(from: textOnly) == nil)
    }

    @Test func caption_extracted_from_extras() {
        let msg = TelegramMessage(messageId: 1, chatId: 9, date: 1,
            extras: .object(["caption": .string("  look at this  ")]))
        #expect(TelegramPollLoop.caption(from: msg) == "look at this")
        let blank = TelegramMessage(messageId: 1, chatId: 9, date: 1,
            extras: .object(["caption": .string("   ")]))
        #expect(TelegramPollLoop.caption(from: blank) == nil)
    }

    @Test func imageMime_resolves_from_suffix_and_fallback() {
        #expect(TelegramPollLoop.imageMime(forFilename: "x.png", fallbackMime: nil) == "image/png")
        #expect(TelegramPollLoop.imageMime(forFilename: "x.jpeg", fallbackMime: nil) == "image/jpeg")
        #expect(TelegramPollLoop.imageMime(forFilename: nil, fallbackMime: "image/webp") == "image/webp")
        // unknown suffix -> jpeg default
        #expect(TelegramPollLoop.imageMime(forFilename: "x.dat", fallbackMime: nil) == "image/jpeg")
    }

    // MARK: full-loop — success: image bytes land on the turn

    @Test func photoOnly_downloads_and_attaches_image_to_turn() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("telegram_photo_ok_\(UUID().uuidString)", isDirectory: true)
        let offset = root.appendingPathComponent("telegram", isDirectory: true)
            .appendingPathComponent("last_offset.json")
        let raw = #"""
        {"ok":true,"result":[{"update_id":100,"message":{"message_id":5,"chat":{"id":77},"from":{"id":11},"photo":[{"file_id":"small","width":90,"height":60},{"file_id":"big","width":1280,"height":720}],"date":1}}]}
        """#
        let session = photoMockSession { req in (makeResponse(req.url!, 200), Data(raw.utf8)) }

        actor Capture {
            var sent: [String] = []
            var handlerText: String?
            var attachmentCount = 0
            var firstAttachmentBytes: Data?
            var firstAttachmentMime: String?
            func note(_ t: String) { sent.append(t) }
            func handler(_ text: String, _ atts: [TelegramMediaAttachment]) {
                handlerText = text
                attachmentCount = atts.count
                firstAttachmentBytes = atts.first?.bytes
                firstAttachmentMime = atts.first?.mimeType
            }
            func snap() -> ([String], String?, Int, Data?, String?) {
                (sent, handlerText, attachmentCount, firstAttachmentBytes, firstAttachmentMime)
            }
        }
        let cap = Capture()
        let imageBytes = Data("PNGDATA".utf8)

        let loop = TelegramPollLoop(
            interval: 60, token: tokenStr, allowedChatIds: [77], session: session, dataRoot: root, offsetURL: offset,
            sendMessage: { _, _, text in await cap.note(text) },
            sendChatAction: { _, _, _ in },
            sendMessageReturningId: discardTurnCardSend,
            editMessageText: discardTurnCardEdit,
            turnCardMinimumEditIntervalSeconds: 0,
            turnCardHeartbeatNanoseconds: 0,
            attachmentChatHandler: { _, text, atts, _, _ in
                await cap.handler(text, atts)
                return "I see the image"
            },
            photoDownloader: FakePhotoDownloader(bytes: imageBytes, filename: "big.png"),
            typingRefreshNanoseconds: 0
        )
        await loop.tick()

        let (sent, handlerText, attCount, attBytes, attMime) = await cap.snap()
        // The model got a non-empty synthetic prompt + exactly the image.
        #expect(handlerText?.contains("no caption") == true)
        #expect(attCount == 1)
        #expect(attBytes == imageBytes)
        #expect(attMime == "image/png")
        // The reply was sent to the user.
        #expect(sent.contains("I see the image"))

        let receipts = try readTelegramJSONL(root, "receipts.jsonl")
        #expect(receipts.contains { row in
            if case .object(let o) = row, o["kind"] == .string("photo_reply") { return true }
            return false
        })
    }

    @Test func captionedPhoto_uses_caption_as_prompt() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("telegram_photo_caption_\(UUID().uuidString)", isDirectory: true)
        let offset = root.appendingPathComponent("telegram", isDirectory: true)
            .appendingPathComponent("last_offset.json")
        let raw = #"""
        {"ok":true,"result":[{"update_id":101,"message":{"message_id":6,"chat":{"id":77},"from":{"id":11},"photo":[{"file_id":"big","width":800,"height":600}],"caption":"what is this?","date":1}}]}
        """#
        let session = photoMockSession { req in (makeResponse(req.url!, 200), Data(raw.utf8)) }

        actor Capture {
            var handlerText: String?
            var attachmentCount = 0
            func handler(_ text: String, _ atts: [TelegramMediaAttachment]) { handlerText = text; attachmentCount = atts.count }
            func snap() -> (String?, Int) { (handlerText, attachmentCount) }
        }
        let cap = Capture()

        let loop = TelegramPollLoop(
            interval: 60, token: tokenStr, allowedChatIds: [77], session: session, dataRoot: root, offsetURL: offset,
            sendMessage: { _, _, _ in },
            sendChatAction: { _, _, _ in },
            sendMessageReturningId: discardTurnCardSend,
            editMessageText: discardTurnCardEdit,
            turnCardMinimumEditIntervalSeconds: 0,
            turnCardHeartbeatNanoseconds: 0,
            attachmentChatHandler: { _, text, atts, _, _ in await cap.handler(text, atts); return "ok" },
            photoDownloader: FakePhotoDownloader(bytes: Data("IMG".utf8), filename: "p.jpg"),
            typingRefreshNanoseconds: 0
        )
        await loop.tick()

        let (handlerText, attCount) = await cap.snap()
        #expect(handlerText == "what is this?")
        #expect(attCount == 1)
    }

    // MARK: tripwire — oversize

    @Test func oversizePhoto_emits_trace_and_user_reply() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("telegram_photo_oversize_\(UUID().uuidString)", isDirectory: true)
        let offset = root.appendingPathComponent("telegram", isDirectory: true)
            .appendingPathComponent("last_offset.json")
        let raw = #"""
        {"ok":true,"result":[{"update_id":102,"message":{"message_id":7,"chat":{"id":77},"from":{"id":11},"photo":[{"file_id":"huge","width":4000,"height":3000}],"date":1}}]}
        """#
        let session = photoMockSession { req in (makeResponse(req.url!, 200), Data(raw.utf8)) }

        actor Capture {
            var sent: [String] = []
            var handlerCalled = false
            func note(_ t: String) { sent.append(t) }
            func markHandler() { handlerCalled = true }
            func snap() -> ([String], Bool) { (sent, handlerCalled) }
        }
        let cap = Capture()

        let loop = TelegramPollLoop(
            interval: 60, token: tokenStr, allowedChatIds: [77], session: session, dataRoot: root, offsetURL: offset,
            sendMessage: { _, _, text in await cap.note(text) },
            sendChatAction: { _, _, _ in },
            sendMessageReturningId: discardTurnCardSend,
            editMessageText: discardTurnCardEdit,
            turnCardMinimumEditIntervalSeconds: 0,
            turnCardHeartbeatNanoseconds: 0,
            attachmentChatHandler: { _, _, _, _, _ in await cap.markHandler(); return "should not run" },
            photoDownloader: FailingPhotoDownloader(error: .oversized(reportedBytes: 20 * 1024 * 1024, capBytes: 10 * 1024 * 1024)),
            typingRefreshNanoseconds: 0
        )
        await loop.tick()

        let (sent, handlerCalled) = await cap.snap()
        // Tripwire: user got a visible "couldn't process that image" reply.
        #expect(sent.contains { $0.contains("couldn't process that image") })
        #expect(sent.contains { $0.contains("too large") })
        // The chat handler must NOT have been called (no blind text reply).
        #expect(handlerCalled == false)

        // Tripwire trace landed in traces/events.jsonl.
        let traces = readTracesJSONL(root)
        let dropped = traces.first { row in
            if case .object(let o) = row, o["kind"] == .string("telegram.attachment_dropped") { return true }
            return false
        }
        #expect(dropped != nil)
        if case .object(let o)? = dropped, case .object(let payload)? = o["payload"] {
            #expect(payload["attachmentKind"] == .string("photo"))
            if case .string(let reason)? = payload["reason"] {
                #expect(reason.contains("too large"))
                #expect(!reason.contains(tokenStr))
            } else { Issue.record("missing reason") }
        } else { Issue.record("malformed dropped trace") }
    }

    // MARK: tripwire — download failure

    @Test func photoDownloadFailure_emits_trace_and_user_reply() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("telegram_photo_dlfail_\(UUID().uuidString)", isDirectory: true)
        let offset = root.appendingPathComponent("telegram", isDirectory: true)
            .appendingPathComponent("last_offset.json")
        let raw = #"""
        {"ok":true,"result":[{"update_id":103,"message":{"message_id":8,"chat":{"id":77},"from":{"id":11},"photo":[{"file_id":"f","width":800,"height":600}],"date":1}}]}
        """#
        let session = photoMockSession { req in (makeResponse(req.url!, 200), Data(raw.utf8)) }

        actor Capture {
            var sent: [String] = []
            func note(_ t: String) { sent.append(t) }
            func snap() -> [String] { sent }
        }
        let cap = Capture()

        let loop = TelegramPollLoop(
            interval: 60, token: tokenStr, allowedChatIds: [77], session: session, dataRoot: root, offsetURL: offset,
            sendMessage: { _, _, text in await cap.note(text) },
            sendChatAction: { _, _, _ in },
            sendMessageReturningId: discardTurnCardSend,
            editMessageText: discardTurnCardEdit,
            turnCardMinimumEditIntervalSeconds: 0,
            turnCardHeartbeatNanoseconds: 0,
            attachmentChatHandler: { _, _, _, _, _ in "should not run" },
            photoDownloader: FailingPhotoDownloader(error: .httpError(status: 502)),
            typingRefreshNanoseconds: 0
        )
        await loop.tick()

        let sent = await cap.snap()
        #expect(sent.contains { $0.contains("couldn't process that image") })

        let traces = readTracesJSONL(root)
        #expect(traces.contains { row in
            if case .object(let o) = row, o["kind"] == .string("telegram.attachment_dropped") { return true }
            return false
        })

        // The error was also recorded (token-redacted) in errors.jsonl.
        let errors = try readTelegramJSONL(root, "errors.jsonl")
        #expect(errors.contains { row in
            if case .object(let o) = row, o["context"] == .string("photo_ingest") { return true }
            return false
        })
    }

    // MARK: tripwire — no downloader wired (ingestion disabled)

    @Test func photo_withNoDownloader_emits_trace_and_user_reply() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("telegram_photo_nodl_\(UUID().uuidString)", isDirectory: true)
        let offset = root.appendingPathComponent("telegram", isDirectory: true)
            .appendingPathComponent("last_offset.json")
        let raw = #"""
        {"ok":true,"result":[{"update_id":104,"message":{"message_id":9,"chat":{"id":77},"from":{"id":11},"photo":[{"file_id":"f","width":800,"height":600}],"date":1}}]}
        """#
        let session = photoMockSession { req in (makeResponse(req.url!, 200), Data(raw.utf8)) }

        actor Capture {
            var sent: [String] = []
            func note(_ t: String) { sent.append(t) }
            func snap() -> [String] { sent }
        }
        let cap = Capture()

        let loop = TelegramPollLoop(
            interval: 60, token: tokenStr, allowedChatIds: [77], session: session, dataRoot: root, offsetURL: offset,
            sendMessage: { _, _, text in await cap.note(text) },
            sendChatAction: { _, _, _ in },
            sendMessageReturningId: discardTurnCardSend,
            editMessageText: discardTurnCardEdit,
            turnCardMinimumEditIntervalSeconds: 0,
            turnCardHeartbeatNanoseconds: 0,
            attachmentChatHandler: { _, _, _, _, _ in "should not run" },
            photoDownloader: nil,
            typingRefreshNanoseconds: 0
        )
        await loop.tick()

        let sent = await cap.snap()
        #expect(sent.contains { $0.contains("couldn't process that image") })
        let traces = readTracesJSONL(root)
        #expect(traces.contains { row in
            if case .object(let o) = row, o["kind"] == .string("telegram.attachment_dropped") { return true }
            return false
        })
    }

    @Test func attachmentDroppedNotice_redacts_token() {
        // _tgRedactToken matches the real bot<digits>:<secret> token shape.
        let withToken = "failed at https://api.telegram.org/bot7123456789:AAH-secret_Token123/getFile"
        let notice = TelegramPollLoop.attachmentDroppedNotice(reason: withToken)
        #expect(!notice.contains("AAH-secret_Token123"))
        #expect(notice.contains("couldn't process that image"))
    }
}

// MARK: - Fail-closed empty allowlist (User directive 2026-08-13)

/// An EMPTY allowlist drops every inbound message before dispatch — the
/// allowlist is the ONLY perimeter in front of ungated YOLO execution, so
/// "nothing configured" must mean "nobody gets in", never "everybody does".
/// The old back-compat (empty = accept all) meant one config wipe silently
/// opened the front door.
@Test func telegramPollLoop_emptyAllowlist_failsClosed_dropsAllMessages() async throws {
    let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("telegram_failclosed_\(UUID().uuidString).json")
    defer { try? FileManager.default.removeItem(at: tmp) }

    let raw = #"""
    {"ok":true,"result":[{"update_id":91,"message":{"message_id":1,"chat":{"id":9},"from":{"id":11},"text":"hello","date":1}}]}
    """#
    let session = FailClosedMockURLProtocol.makeSession { req in
        (makeResponse(req.url!, 200), Data(raw.utf8))
    }
    actor Flag { var called = false; func mark() { called = true }; func read() -> Bool { called } }
    let flag = Flag()
    let loop = TelegramPollLoop(
        interval: 60,
        token: tokenStr,
        // Deliberately NO allowedChatIds / allowedUserIds: fail-closed path.
        bot: SwiftNativeTelegramBot(dataRoot: hermeticTelegramDataRoot()),
        session: session,
        offsetURL: tmp,
        sendMessage: { _, _, _ in },
        chatHandler: { _, _ in
            await flag.mark()
            return "reply"
        }
    )
    await loop.tick()

    // The handler must never fire, and the offset still advances so the
    // dropped update is not re-fetched forever.
    #expect(await flag.read() == false)
    let data = try Data(contentsOf: tmp)
    #expect(String(data: data, encoding: .utf8)?.contains("92") == true)
}

/// PATCH-2026-08-18. Pins the two facts that make the headless-orphaned-grant
/// regression (root cause 130dc377) impossible to reintroduce silently.
@Suite("Speech permission denial handling")
struct TelegramSpeechPermissionGuardTests {

    /// THE INVARIANT. A prompting authorization API anywhere in the TelegramBot
    /// sources is the bug itself: this module only ever runs headless, off an
    /// inbound update, where macOS cannot render a consent prompt and resolves
    /// the request to a permanent .denied without asking the user. The only
    /// legitimate prompt site in the whole app is
    /// SystemPermissionPreflight.requestSpeechRecognitionIfNotDetermined(),
    /// which is @MainActor and app-side. A unit test cannot observe TCC, so this
    /// pins the fact at the SOURCE level instead — the same technique the
    /// transcript-correction scope test already uses.
    @Test func telegramBotSourcesNeverRequestSpeechAuthorization() throws {
        let sourceRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // TelegramBotTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // NativeAgentCore
            .appendingPathComponent("Sources/TelegramBot", isDirectory: true)
        let files = try FileManager.default.contentsOfDirectory(
            at: sourceRoot, includingPropertiesForKeys: nil)

        var offenders: [String] = []
        for file in files where file.pathExtension == "swift" {
            let text = try String(contentsOf: file, encoding: .utf8)
            // Strip comments before matching: these sources' own explanatory
            // comments name the forbidden API on purpose, and matching them
            // would make the guard fire on its own documentation. Done as a real
            // scan rather than a line filter — dropping any line that STARTS
            // with "//" would hide live code trailing a block-comment close
            // (`/*` newline `// */ SFSpeechRecognizer.requestAuthorization {}`),
            // a false negative in exactly the guard that must not have one.
            if Self.strippingComments(text).contains("SFSpeechRecognizer.requestAuthorization") {
                offenders.append(file.lastPathComponent)
            }
        }
        #expect(offenders.isEmpty,
                "headless TelegramBot sources must never call SFSpeechRecognizer.requestAuthorization; offenders: \(offenders)")
    }

    /// Removes `//` line comments and `/* */` block comments (nested-aware),
    /// leaving only executable text. String literals are not modelled; the only
    /// consequence would be a false POSITIVE (the guard firing on the API name
    /// inside a literal), which fails loud rather than silent.
    static func strippingComments(_ source: String) -> String {
        var out = ""
        var blockDepth = 0
        var index = source.startIndex
        while index < source.endIndex {
            let rest = source[index...]
            if blockDepth == 0, rest.hasPrefix("//") {
                // Skip to end of line.
                if let newline = source[index...].firstIndex(of: "\n") {
                    out.append("\n")
                    index = source.index(after: newline)
                } else {
                    index = source.endIndex
                }
                continue
            }
            if rest.hasPrefix("/*") {
                blockDepth += 1
                index = source.index(index, offsetBy: 2)
                continue
            }
            if blockDepth > 0, rest.hasPrefix("*/") {
                blockDepth -= 1
                index = source.index(index, offsetBy: 2)
                continue
            }
            if blockDepth == 0 {
                out.append(source[index])
            }
            index = source.index(after: index)
        }
        return out
    }

    /// The headless path must still READ the grant and fail loudly.
    @Test func telegramVoiceTranscriptionReadsAuthorizationStatus() throws {
        let source = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/TelegramBot/TelegramVoiceTranscription.swift")
        let text = try String(contentsOf: source, encoding: .utf8)
        #expect(text.contains("SFSpeechRecognizer.authorizationStatus()"))
    }

    /// The denial predicate's full contract. Only a genuine permission denial
    /// may raise the capability card; every other voice failure is a real
    /// failure that no System Settings switch fixes, and flagging it would turn
    /// the card into noise the user learns to ignore.
    @Test func denialPredicateFiresOnlyForPermissionDenial() {
        #expect(TelegramPollLoop.isSpeechPermissionDenial(
            TelegramVoiceTranscriptionError.speechPermissionDenied("denied")))
        #expect(TelegramPollLoop.isSpeechPermissionDenial(
            TelegramVoiceTranscriptionError.speechPermissionDenied("restricted")))

        // Neighbours that must NOT flag. speechUnavailable is the sharp one:
        // its message mentions speech, so a naive string match catches it.
        let nonDenials: [TelegramVoiceTranscriptionError] = [
            .speechUnavailable("recognizer is not currently available"),
            .speechRecognitionFailed("timed out"),
            .malformedResponse,
            .conversionFailed("ffmpeg exited 1"),
        ]
        for error in nonDenials {
            #expect(!TelegramPollLoop.isSpeechPermissionDenial(error),
                    "must not flag a capability for \(error)")
        }

        // Untyped errors fall through to the narrow string check.
        struct Untyped: LocalizedError {
            let errorDescription: String?
        }
        #expect(TelegramPollLoop.isSpeechPermissionDenial(
            Untyped(errorDescription: "voice transcription: speech recognition permission denied: denied")))
        #expect(!TelegramPollLoop.isSpeechPermissionDenial(
            Untyped(errorDescription: "network connection lost")))
    }
}
