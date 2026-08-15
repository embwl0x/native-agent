import Testing
import Foundation
import NativeAgentTestSupport
import PersistenceCore
@testable import TelegramBot

// MARK: - URLProtocol mock for TelegramMediaDownloader tests
// Isolated stub subclass (own handler slot) — see ConfigurableURLProtocolStub.

private final class CmpMockURLProtocol: ConfigurableURLProtocolStub {}

// Non-async factory so it can be called from @Test functions without
// MainActor isolation.
private func cmpMockSession(
    _ handler: @escaping (URLRequest) throws -> (HTTPURLResponse, Data)
) -> URLSession {
    CmpMockURLProtocol.makeSession(handler: handler)
}

private func cmpHTTPResponse(_ url: URL, _ status: Int) -> HTTPURLResponse {
    HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!
}

// MARK: - Mock deps

private final class MockProviderRouting: ProviderRoutingRef, @unchecked Sendable {
    var surfaceResult: (model: String, provider: String)? = ("claude-opus-4-8", "anthropic")
    var modelMenu: TelegramModelMenu?
    var savedConfigs: [(surface: String, key: String, value: String)] = []
    var savedSelections: [(surface: String, provider: String?, model: String)] = []
    var saveError: Error?

    func modelForSurface(_ surface: String) async -> (model: String, provider: String)? {
        surfaceResult
    }

    func modelMenuForSurface(_ surface: String) async -> TelegramModelMenu? {
        modelMenu
    }

    func saveModelConfig(surface: String, key: String, value: String) async throws {
        if let err = saveError { throw err }
        savedConfigs.append((surface: surface, key: key, value: value))
    }

    func saveModelSelection(surface: String, provider: String?, model: String) async throws {
        if let err = saveError { throw err }
        savedSelections.append((surface: surface, provider: provider, model: model))
    }
}

private func makeBotWithDeps(
    routing: MockProviderRouting? = nil
) async -> SwiftNativeTelegramBot {
    let bot = SwiftNativeTelegramBot(dataRoot: hermeticTelegramDataRoot())
    let deps = TelegramBotCompletenessDeps(routing: routing)
    await bot.registerCompletenessDeps(deps)
    return bot
}

private func makeTelegramCompletenessTempRoot() throws -> URL {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("telegram_completeness_\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}

private func makeTestModelMenu() -> TelegramModelMenu {
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

private func telegramMessagesPath(root: URL, sessionId: String) -> URL {
    root
        .appendingPathComponent("chat", isDirectory: true)
        .appendingPathComponent("messages", isDirectory: true)
        .appendingPathComponent("\(sessionId).jsonl")
}

private func telegramScratchPath(root: URL, sessionId: String) -> URL {
    root
        .appendingPathComponent("chat", isDirectory: true)
        .appendingPathComponent("sessions", isDirectory: true)
        .appendingPathComponent(sessionId, isDirectory: true)
        .appendingPathComponent("scratch.json")
}

// MARK: - Completeness tests
// Serialized to avoid shared CmpMockURLProtocol.handler clobbering.

@Suite(.serialized)
struct TelegramBotCompletenessTests {

    // MARK: /provider

    @Test func dispatchSwiftSlashCommand_provider_returns_current_model() async throws {
        let routing = MockProviderRouting()
        routing.surfaceResult = ("claude-opus-4-8", "anthropic")
        let bot = await makeBotWithDeps(routing: routing)
        let reply = await dispatchSwiftSlashCommand(bot: bot, command: "/provider", args: [])
        #expect(reply == "anthropic")
    }

    // MARK: /model

    @Test func dispatchSwiftSlashCommand_model_returns_verbose() async throws {
        let routing = MockProviderRouting()
        routing.surfaceResult = ("claude-opus-4-8", "anthropic")
        let bot = await makeBotWithDeps(routing: routing)
        let reply = await dispatchSwiftSlashCommand(bot: bot, command: "/model", args: [])
        let text = try #require(reply)
        #expect(text.contains("Surface: telegram"))
        #expect(text.contains("Model: claude-opus-4-8"))
        #expect(text.contains("Provider: anthropic"))
    }

    @Test func dispatchSwiftSlashCommand_model_lists_provider_menu() async throws {
        let routing = MockProviderRouting()
        routing.modelMenu = makeTestModelMenu()
        let bot = await makeBotWithDeps(routing: routing)
        let reply = await dispatchSwiftSlashCommand(bot: bot, command: "/model", args: [])
        let text = try #require(reply)
        #expect(text.contains("Telegram model: claude-opus-4-8"))
        #expect(text.contains("Provider: Anthropic (anthropic_oauth_direct)"))
        #expect(text.contains("1. Anthropic: Claude Opus 4.8 [claude-opus-4-8] (current)"))
        #expect(text.contains("2. Anthropic: Claude Sonnet 4.6 [claude-sonnet-4-6]"))
        #expect(text.contains("3. Codex CLI: GPT-5.5 [gpt-5.5]"))
        #expect(text.contains("Direct: /model <provider> <model-id>"))
    }

    @Test func dispatchSwiftSlashCommand_model_number_updates_selected_provider_and_model() async throws {
        let routing = MockProviderRouting()
        routing.modelMenu = makeTestModelMenu()
        let bot = await makeBotWithDeps(routing: routing)
        let reply = await dispatchSwiftSlashCommand(
            bot: bot,
            command: "/model",
            args: ["3"]
        )
        #expect(reply == "Telegram model set to gpt-5.5 @ codex. Providers tab will reflect this under Telegram.")
        #expect(routing.savedSelections.count == 1)
        #expect(routing.savedSelections.first?.surface == "telegram")
        #expect(routing.savedSelections.first?.provider == "codex")
        #expect(routing.savedSelections.first?.model == "gpt-5.5")
    }

    @Test func dispatchSwiftSlashCommand_model_provider_model_updates_selection() async throws {
        let routing = MockProviderRouting()
        routing.modelMenu = makeTestModelMenu()
        let bot = await makeBotWithDeps(routing: routing)
        let reply = await dispatchSwiftSlashCommand(
            bot: bot,
            command: "/model",
            args: ["anthropic_oauth_direct", "claude-sonnet-4-6"]
        )
        #expect(reply == "Telegram model set to claude-sonnet-4-6 @ anthropic_oauth_direct. Providers tab will reflect this under Telegram.")
        #expect(routing.savedSelections.first?.surface == "telegram")
        #expect(routing.savedSelections.first?.provider == "anthropic_oauth_direct")
        #expect(routing.savedSelections.first?.model == "claude-sonnet-4-6")
    }

    @Test func dispatchSwiftSlashCommand_model_argument_updates_router() async throws {
        let routing = MockProviderRouting()
        let bot = await makeBotWithDeps(routing: routing)
        let reply = await dispatchSwiftSlashCommand(
            bot: bot,
            command: "/model",
            args: ["claude-sonnet-4-5"]
        )
        #expect(reply == "Telegram model set to claude-sonnet-4-5. Providers tab will reflect this under Telegram.")
        #expect(routing.savedSelections.count == 1)
        #expect(routing.savedSelections.first?.surface == "telegram")
        #expect(routing.savedSelections.first?.provider == nil)
        #expect(routing.savedSelections.first?.model == "claude-sonnet-4-5")
    }

    @Test func dispatchSwiftSlashCommand_actor_forwards_to_completeness_commands() async throws {
        let routing = MockProviderRouting()
        routing.surfaceResult = ("gpt-5.5", "openai_oauth_direct")
        let bot = SwiftNativeTelegramBot(
            dataRoot: hermeticTelegramDataRoot(),
            completenessDeps: TelegramBotCompletenessDeps(routing: routing)
        )
        let reply = try await bot.dispatchSwiftSlashCommand("/model", args: [], chatId: 1)
        let text = try #require(reply)
        #expect(text.contains("Surface: telegram"))
        #expect(text.contains("Model: gpt-5.5"))
        #expect(text.contains("Provider: openai_oauth_direct"))
    }

    // MARK: /think

    @Test func dispatchSwiftSlashCommand_think_low_calls_router_saveModelConfig() async throws {
        let routing = MockProviderRouting()
        let bot = await makeBotWithDeps(routing: routing)
        let reply = await dispatchSwiftSlashCommand(bot: bot, command: "/think", args: ["low"])
        #expect(reply == "Reasoning effort set to low")
        #expect(routing.savedConfigs.count == 1)
        #expect(routing.savedConfigs.first?.surface == "telegram")
        #expect(routing.savedConfigs.first?.key == "reasoning_effort")
        #expect(routing.savedConfigs.first?.value == "low")
    }

    @Test func dispatchSwiftSlashCommand_fast_on_persistsPriorityTierForGPT() async throws {
        let routing = MockProviderRouting()
        routing.surfaceResult = ("gpt-5.6-sol", "openai_oauth_direct")
        let bot = await makeBotWithDeps(routing: routing)
        let reply = await dispatchSwiftSlashCommand(bot: bot, command: "/fast", args: ["on"])
        #expect(reply == "Fast mode enabled for Telegram.")
        #expect(routing.savedConfigs.count == 1)
        #expect(routing.savedConfigs.first?.surface == "telegram")
        #expect(routing.savedConfigs.first?.key == "service_tier")
        #expect(routing.savedConfigs.first?.value == "priority")
    }

    @Test func dispatchSwiftSlashCommand_fast_rejectsModelWithoutFastCapability() async throws {
        let routing = MockProviderRouting()
        routing.surfaceResult = ("claude-opus-4-8", "anthropic")
        let bot = await makeBotWithDeps(routing: routing)
        let reply = await dispatchSwiftSlashCommand(bot: bot, command: "/fast", args: ["on"])
        #expect(reply == "/fast is unsupported for the selected model.")
        #expect(routing.savedConfigs.isEmpty)
    }

    @Test func dispatchSwiftSlashCommand_fast_acceptsGrokCapability() async throws {
        let routing = MockProviderRouting()
        routing.surfaceResult = ("grok-4.5", "xai_oauth_direct")
        let bot = await makeBotWithDeps(routing: routing)
        let reply = await dispatchSwiftSlashCommand(bot: bot, command: "/fast", args: ["on"])
        #expect(reply == "Fast mode enabled for Telegram.")
        #expect(routing.savedConfigs.first?.key == "service_tier")
        #expect(routing.savedConfigs.first?.value == "priority")
    }

    @Test func dispatchSwiftSlashCommand_think_acceptsClaudeMaxCapability() async throws {
        let routing = MockProviderRouting()
        routing.surfaceResult = ("claude-opus-4-8", "anthropic_oauth_direct")
        let bot = await makeBotWithDeps(routing: routing)
        let reply = await dispatchSwiftSlashCommand(bot: bot, command: "/think", args: ["max"])
        #expect(reply == "Reasoning effort set to max")
        #expect(routing.savedConfigs.first?.key == "reasoning_effort")
        #expect(routing.savedConfigs.first?.value == "max")
    }

    @Test func dispatchSwiftSlashCommand_think_xhigh_calls_router_saveModelConfig() async throws {
        let routing = MockProviderRouting()
        let bot = await makeBotWithDeps(routing: routing)
        let reply = await dispatchSwiftSlashCommand(bot: bot, command: "/think", args: ["xhigh"])
        #expect(reply == "Reasoning effort set to xhigh")
        #expect(routing.savedConfigs.first?.surface == "telegram")
        #expect(routing.savedConfigs.first?.key == "reasoning_effort")
        #expect(routing.savedConfigs.first?.value == "xhigh")
    }

    @Test func dispatchSwiftSlashCommand_think_invalid_returns_help_text() async throws {
        let bot = await makeBotWithDeps()
        let reply = await dispatchSwiftSlashCommand(bot: bot, command: "/think", args: ["turbo"])
        #expect(reply == "Model routing is unavailable; reasoning was not changed.")
    }

    // MARK: session/persona/scratch commands

    @Test func dispatchSwiftSlashCommand_new_reset_persona_and_scratch_use_swift_session_store() async throws {
        let root = try makeTelegramCompletenessTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let bot = SwiftNativeTelegramBot(dataRoot: root)
        let store = TelegramSessionStore(dataRoot: root)
        let legacy = try await store.activeSessionId(chatId: 42)
        #expect(legacy == "telegram:42")

        let newReply = try await bot.dispatchSwiftSlashCommand("/new", args: [], chatId: 42)
        let newText = try #require(newReply)
        #expect(newText.contains("Started new Telegram session:"))
        let statusAfterNew = try await store.status(chatId: 42)
        #expect(statusAfterNew.sessionId != legacy)

        let persistence = SwiftNativePersistenceCore()
        let activeMessages = telegramMessagesPath(root: root, sessionId: statusAfterNew.sessionId)
        try await persistence.appendJSONL(.object([
            "id": .string("m1"),
            "role": .string("user"),
            "content": .string("hello"),
            "createdAt": .string("2026-06-04T00:00:00Z"),
        ]), to: activeMessages)
        #expect(((try? await persistence.readJSONL(activeMessages)) ?? []).count == 1)

        let personaReply = try await bot.dispatchSwiftSlashCommand("/persona", args: ["Agent"], chatId: 42)
        #expect(personaReply == "Telegram persona set to Agent")
        let sessionReply = try await bot.dispatchSwiftSlashCommand("/session", args: ["status"], chatId: 42)
        let sessionText = try #require(sessionReply)
        #expect(sessionText.contains(statusAfterNew.sessionId))
        #expect(sessionText.contains("Persona: Agent"))

        let scratchReply = try await bot.dispatchSwiftSlashCommand(
            "/scratch",
            args: ["mood", "ready", "now"],
            chatId: 42
        )
        let scratchText = try #require(scratchReply)
        #expect(scratchText.contains("Wrote scratch mood"))
        let scratch = await persistence.readJSON(
            telegramScratchPath(root: root, sessionId: statusAfterNew.sessionId),
            defaultValue: .object([:])
        )
        guard case .object(let scratchObj) = scratch else {
            Issue.record("expected scratch object")
            return
        }
        #expect(scratchObj["mood"] == .string("ready now"))

        let resetReply = try await bot.dispatchSwiftSlashCommand("/reset", args: [], chatId: 42)
        let resetText = try #require(resetReply)
        #expect(resetText.contains("message(s) cleared"))
        #expect(((try? await persistence.readJSONL(activeMessages)) ?? []).isEmpty)
    }

    @Test func dispatchSwiftSlashCommand_compact_rewrites_current_telegram_session() async throws {
        let root = try makeTelegramCompletenessTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let bot = SwiftNativeTelegramBot(dataRoot: root)
        let store = TelegramSessionStore(dataRoot: root)
        let sessionId = try await store.activeSessionId(chatId: 9)
        let path = telegramMessagesPath(root: root, sessionId: sessionId)
        let persistence = SwiftNativePersistenceCore()
        for idx in 0..<24 {
            try await persistence.appendJSONL(.object([
                "id": .string("m\(idx)"),
                "role": .string(idx % 2 == 0 ? "user" : "assistant"),
                "content": .string("message \(idx)"),
                "createdAt": .string("2026-06-04T00:00:00Z"),
            ]), to: path)
        }

        let reply = try await bot.dispatchSwiftSlashCommand("/compact", args: [], chatId: 9)
        let text = try #require(reply)
        #expect(text.contains("24 -> 21 messages"))
        let rows = try await persistence.readJSONL(path)
        #expect(rows.count == 21)
        guard case .object(let first)? = rows.first else {
            Issue.record("expected compaction summary")
            return
        }
        #expect(first["source"] == .string("telegram_native_compaction"))
    }

    @Test func dispatchSwiftSlashCommand_sessions_and_resume_bind_existing_session() async throws {
        let root = try makeTelegramCompletenessTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let sessionsPath = root
            .appendingPathComponent("chat", isDirectory: true)
            .appendingPathComponent("sessions.json")
        try await SwiftNativePersistenceCore().writeJSON(.array([
            .object([
                "id": .string("existing-session-123"),
                "title": .string("Mac chat"),
                "source": .string("chat"),
                "updatedAt": .string("2026-07-07T00:00:00Z"),
                "messageCount": .int(5),
            ]),
            .object([
                "id": .string("older-session-456"),
                "title": .string("Older chat"),
                "source": .string("telegram"),
                "updatedAt": .string("2026-07-06T00:00:00Z"),
                "messageCount": .int(2),
            ]),
        ]), to: sessionsPath)

        let bot = SwiftNativeTelegramBot(dataRoot: root)
        let listReply = try await bot.dispatchSwiftSlashCommand("/sessions", args: [], chatId: 42)
        let listText = try #require(listReply)
        #expect(listText.contains("existing-session-123"))
        #expect(listText.contains("Use /resume <id>"))

        let resumeReply = try await bot.dispatchSwiftSlashCommand(
            "/resume",
            args: ["existing-session"],
            chatId: 42
        )
        let resumeText = try #require(resumeReply)
        #expect(resumeText.contains("Resumed Telegram session: existing-session-123"))
        let status = try await TelegramSessionStore(dataRoot: root).status(chatId: 42)
        #expect(status.sessionId == "existing-session-123")
    }

    @Test func TelegramCommandRegistry_contains_control_surface() {
        let names = Set(TelegramCommandRegistry.commands.map(\.command))
        for expected in [
            "status", "new", "reset", "session", "clear", "compact",
            "stop", "retry", "sessions", "resume",
            "provider", "model", "think", "brain", "persona",
            "remember", "note", "scratch", "tools", "restart", "help",
            "approve", "deny",
        ] {
            #expect(names.contains(expected))
        }
        #expect(TelegramCommandRegistry.commands.count == TelegramCommandRegistry.definitions.count)
    }

    @Test func TelegramCommandRegistry_parses_aliases_and_args() throws {
        let help = try #require(TelegramCommandRegistry.parse(text: "/h"))
        #expect(help.definition.name == "help")
        #expect(help.definition.handler == .help)

        let stop = try #require(TelegramCommandRegistry.parse(text: "/cancel@native_agent_bot"))
        #expect(stop.definition.name == "stop")
        #expect(stop.definition.handler == .stop)

        let resume = try #require(TelegramCommandRegistry.parse(text: "/switch abc123 extra"))
        #expect(resume.definition.name == "resume")
        #expect(resume.args == ["abc123", "extra"])
    }

    // MARK: /help

    @Test func dispatchSwiftSlashCommand_help_lists_supported_commands() async throws {
        let bot = await makeBotWithDeps()
        let reply = await dispatchSwiftSlashCommand(bot: bot, command: "/help", args: [])
        let text = try #require(reply)
        #expect(text.contains("/status"))
        #expect(text.contains("/provider"))
        #expect(text.contains("/model"))
        #expect(text.contains("/think"))
        #expect(text.contains("/fast <on|off>"))
        #expect(text.contains("/brain"))
        #expect(text.contains("/stop"))
        #expect(text.contains("/retry"))
        #expect(text.contains("/sessions"))
        #expect(text.contains("/resume <id>"))
        #expect(text.contains("/restart"))
        #expect(text.contains("/help"))
        #expect(text.contains("Slash commands are handled locally before chat."))
    }

    // MARK: /restart
    //
    // 2026-06-10: /restart is now a REAL owner-gated command (see
    // RestartCommandTests.swift for the gating matrix). Without a wired
    // TelegramRestartRef dep it still fails closed with an honest
    // "not wired" message — that's what this legacy-shaped test now pins.

    @Test func dispatchSwiftSlashCommand_restart_without_dep_fails_closed() async throws {
        let bot = await makeBotWithDeps()
        let reply = await dispatchSwiftSlashCommand(bot: bot, command: "/restart", args: [])
        let text = try #require(reply)
        #expect(text.contains("not wired in this build"))
        #expect(text.contains("Mac app"))
    }

    // MARK: unknown → nil

    @Test func dispatchSwiftSlashCommand_unknown_returns_nil() async throws {
        let bot = await makeBotWithDeps()
        let reply = await dispatchSwiftSlashCommand(bot: bot, command: "/xyzzy_unknown", args: [])
        #expect(reply == nil)
    }

    // MARK: - TelegramMediaDownloader

    @Test func TelegramMediaDownloader_downloads_photo_two_stage() async throws {
        let token = "TESTTOKEN"
        let fileId = "FILEID123"
        let fakeBytes = Data("fake-image-bytes".utf8)

        let session = cmpMockSession { req in
            let url = req.url!
            if url.path.contains("/getFile") {
                let body = Data("""
                {"ok":true,"result":{"file_id":"\(fileId)","file_size":16,"file_path":"photos/file_42.jpg"}}
                """.utf8)
                return (cmpHTTPResponse(url, 200), body)
            } else if url.path.contains("/file/bot") {
                return (cmpHTTPResponse(url, 200), fakeBytes)
            }
            return (cmpHTTPResponse(url, 404), Data())
        }

        let downloader = TelegramMediaDownloader(session: session)
        let input = TelegramMediaAttachment(kind: "photo", fileId: fileId)
        let result = try await downloader.download(token: token, attachment: input)

        #expect(result.bytes == fakeBytes)
        #expect(result.captureFilename == "file_42.jpg")
        #expect(result.kind == "photo")
        #expect(result.fileId == fileId)
    }

    @Test func TelegramMediaDownloader_respects_maxBytes_cap() async throws {
        let session = cmpMockSession { req in
            let url = req.url!
            let body = Data("""
            {"ok":true,"result":{"file_id":"X","file_size":50000000,"file_path":"big/file.mp4"}}
            """.utf8)
            return (cmpHTTPResponse(url, 200), body)
        }

        let downloader = TelegramMediaDownloader(session: session)
        let input = TelegramMediaAttachment(kind: "video", fileId: "X")
        do {
            _ = try await downloader.download(token: "TK", attachment: input, maxBytes: 1024)
            Issue.record("Expected oversized error")
        } catch TelegramMediaDownloadError.oversized(let reported, let cap) {
            #expect(reported == 50_000_000)
            #expect(cap == 1024)
        }
    }

    @Test func TelegramMediaDownloader_handles_voice_with_no_mime_type() async throws {
        let voiceBytes = Data("voice-ogg-bytes".utf8)

        let session = cmpMockSession { req in
            let url = req.url!
            if url.path.contains("/getFile") {
                let body = Data("""
                {"ok":true,"result":{"file_id":"VFID","file_size":15,"file_path":"voice/voice_99.ogg"}}
                """.utf8)
                return (cmpHTTPResponse(url, 200), body)
            } else {
                return (cmpHTTPResponse(url, 200), voiceBytes)
            }
        }

        let downloader = TelegramMediaDownloader(session: session)
        let input = TelegramMediaAttachment(kind: "voice", fileId: "VFID", mimeType: nil)
        let result = try await downloader.download(token: "TK", attachment: input)

        #expect(result.bytes == voiceBytes)
        #expect(result.mimeType == nil)
        #expect(result.captureFilename == "voice_99.ogg")
    }

    @Test func SwiftOpenAIWhisperTranscriber_posts_multipart_transcription_request() async throws {
        nonisolated(unsafe) var captured: URLRequest?
        nonisolated(unsafe) var capturedBody: Data?
        let session = cmpMockSession { req in
            captured = req
            capturedBody = drainBodyStream(req)
            let body = Data(#"{"text":"hello from telegram voice"}"#.utf8)
            return (cmpHTTPResponse(req.url!, 200), body)
        }
        let client = SwiftOpenAIWhisperTranscriber(
            session: session,
            endpoint: URL(string: "https://api.openai.test/v1/audio/transcriptions")!,
            model: "gpt-4o-mini-transcribe",
            apiKeyOverride: "sk-test",
            dataRoot: URL(fileURLWithPath: NSTemporaryDirectory())
        )
        let result = try await client.transcribe(TelegramMediaAttachment(
            kind: "voice",
            fileId: "VFID",
            mimeType: "audio/webm",
            sizeBytes: 10,
            bytes: Data("voice-webm".utf8),
            captureFilename: "voice.webm"
        ))

        #expect(result.text == "hello from telegram voice")
        #expect(result.backend == "openai")
        #expect(result.model == "gpt-4o-mini-transcribe")
        #expect(captured?.httpMethod == "POST")
        #expect(captured?.value(forHTTPHeaderField: "Authorization") == "Bearer sk-test")
        #expect(captured?.value(forHTTPHeaderField: "Content-Type")?.contains("multipart/form-data") == true)
        let bodyString = String(data: capturedBody ?? Data(), encoding: .utf8) ?? ""
        #expect(bodyString.contains("name=\"model\""))
        #expect(bodyString.contains("gpt-4o-mini-transcribe"))
        #expect(bodyString.contains("filename=\"voice.webm\""))
        #expect(bodyString.contains("voice-webm"))
    }

}
