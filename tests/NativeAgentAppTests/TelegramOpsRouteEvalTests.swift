import Foundation
import Testing
import TelegramBot
@testable import NativeAgentApp

// EVAL FENCE: app.bridges / telegram.configureTelegram
@Suite("Telegram operations route", .serialized)
struct TelegramOpsRouteEvalTests {
    @Test("configure persists the complete Telegram authorization request at the injected root")
    func configurePersistsTokenAllowlistAndGateFields() async throws {
        let root = try temporaryRoot("round-trip")
        defer { try? FileManager.default.removeItem(at: root) }
        let client = NativeClient(baseURL: "", dataRootOverride: root)

        try await client.configureTelegram(
            token: "  123456:fixture-token  ",
            allowedChatIds: ["-1001234567890", "42"],
            allowedUserIds: [" 7", "8 "],
            requireMention: true,
            model: "",
            reasoningEffort: "",
            enabled: true,
            restartPollLoop: false
        )

        let saved = try #require(TelegramConfig.loadFromDisk(dataRoot: root))
        #expect(saved.botToken == "123456:fixture-token")
        #expect(saved.allowedChatIds == Set([-1_001_234_567_890, 42]))
        #expect(saved.allowedUserIds == Set([7, 8]))
        #expect(saved.requireMention)
        #expect(saved.enabled)
        #expect(FileManager.default.fileExists(atPath: configurationURL(root).path))
    }

    @Test("configure fails closed with a typed error for malformed input or existing authority bytes")
    func configureRejectsInvalidInputAndPreservesUnreadableAuthority() async throws {
        let root = try temporaryRoot("adverse")
        defer { try? FileManager.default.removeItem(at: root) }
        let client = NativeClient(baseURL: "", dataRootOverride: root)

        await #expect(throws: TelegramConfigurationError.invalidAllowedChatID("not-a-number")) {
            try await client.configureTelegram(
                token: "123:fixture-token",
                allowedChatIds: ["not-a-number"],
                allowedUserIds: [],
                requireMention: false,
                model: "",
                reasoningEffort: "",
                enabled: true,
                restartPollLoop: false
            )
        }
        #expect(!FileManager.default.fileExists(atPath: configurationURL(root).path))

        let url = configurationURL(root)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let malformed = Data("{not valid JSON\n".utf8)
        try malformed.write(to: url, options: .atomic)

        await #expect(throws: TelegramConfigurationError.existingConfigurationUnreadable) {
            try await client.configureTelegram(
                token: "123:replacement-token",
                allowedChatIds: ["42"],
                allowedUserIds: ["7"],
                requireMention: true,
                model: "",
                reasoningEffort: "",
                enabled: true,
                restartPollLoop: false
            )
        }
        #expect(try Data(contentsOf: url) == malformed)
    }

    private func temporaryRoot(_ label: String) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("telegram-ops-route-\(label)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func configurationURL(_ root: URL) -> URL {
        root
            .appendingPathComponent("telegram", isDirectory: true)
            .appendingPathComponent("config.json")
    }
}
