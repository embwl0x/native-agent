import Foundation
import Testing
import MCPDispatcher
import MultimodalTTS
import TelegramBot
@testable import NativeAgentApp

/// Durable, hermetic settings checks for the controls whose values cross an
/// authority boundary. These deliberately exercise the real production
/// readers/writers against isolated roots; a rendered switch is not proof that
/// the next runtime instance will observe the selected value.
@Suite("app.settings · authority round trips")
struct SettingsAuthorityRoundTripEvalTests {

    @Test func telegramEditorUsesTheSameNumericAuthorityAndRepairsUnsupportedReasoning() {
        let parsed = parseTelegramNumericIDs(" -100123, 42  42\nnot-a-user\t+7 ")
        #expect(parsed.canonicalIDs == ["-100123", "42", "7"])
        #expect(parsed.invalidTokens == ["not-a-user"])
        #expect(parsed.isConfigured)
        #expect(!parseTelegramNumericIDs("junk").isConfigured)

        let model = ModelCatalogItem(
            id: "eval-model",
            displayName: "Eval Model",
            description: nil,
            defaultReasoningEffort: "medium",
            supportedReasoningEfforts: ["low", "medium"],
            supportsFast: false,
            priority: 1
        )
        let current = ModelSurfacePreference(
            surface: "telegram",
            model: model.id,
            reasoningEffort: "medium",
            serviceTier: nil,
            source: "eval",
            modelKnown: true
        )
        let catalog = ModelCatalogResponse(
            status: "ok",
            source: "eval",
            defaultModel: model.id,
            fallbackModels: [],
            models: [model],
            reasoningEfforts: ["low", "medium", "high"].map {
                ReasoningEffortOption(id: $0, label: $0, description: nil)
            },
            current: ModelRoutingCurrent(chat: current, telegram: current),
            updatedAt: nil
        )

        #expect(normalizedReasoningEffort(
            from: catalog,
            model: model.id,
            selected: "unsupported"
        ) == "medium")
        #expect(normalizedReasoningEffort(
            from: catalog,
            model: model.id,
            selected: "low"
        ) == "low")
    }

    private func tempRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("settings-authority-eval-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func writeJSON(_ object: Any, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
            .write(to: url, options: .atomic)
    }

    /// The Telegram config reader is the runtime perimeter. It must discard
    /// malformed IDs while retaining all numeric chat and user IDs, including
    /// negative group-chat identifiers, after a cold reread.
    @Test func telegramAllowlistReaderRejectsMalformedIDsAndKeepsEveryValidPrincipal() throws {
        let root = try tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let configURL = root
            .appendingPathComponent("telegram", isDirectory: true)
            .appendingPathComponent("config.json")
        try writeJSON([
            "bot_token": "test-token",
            "allowed_chat_ids": ["-100123", " -99 ", "not-a-chat", NSNumber(value: 42)],
            "allowed_user_ids": ["7", "", "user-eight", NSNumber(value: 9)],
            "enabled": true,
            "require_mention": true,
        ], to: configURL)

        let loaded = try #require(TelegramConfig.loadFromDisk(dataRoot: root))
        #expect(loaded.allowedChatIds == [-100_123, 42])
        #expect(loaded.allowedUserIds == [7, 9])
        #expect(loaded.requireMention)
        #expect(loaded.enabled)

        // Reopen through a fresh call rather than trusting an in-memory value.
        let reopened = try #require(TelegramConfig.loadFromDisk(dataRoot: root))
        #expect(reopened == loaded)
    }

    /// A consent is not a UI acknowledgement: a separately-created dispatcher
    /// must see the exact persisted grant and a post-revoke dispatcher must no
    /// longer treat it as executable authority.
    @Test func mcpConsentSurvivesColdReloadAndRevocationSurvivesAnotherColdReload() async throws {
        let root = try tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let writer = SwiftNativeMCPDispatcher(root: root)
        _ = try await writer.grantConsent(MCPConsentGrant(
            serverId: "calendar",
            toolName: "calendar.create",
            risk: "external",
            permissions: ["calendar.write", "calendar.read", "calendar.write"],
            argumentSummary: "Create a calendar event"
        ))

        let afterRestart = SwiftNativeMCPDispatcher(root: root)
        let granted = try #require(try await afterRestart.listConsents().first)
        #expect(granted.id == "calendar:calendar.create")
        #expect(granted.status == "granted")
        #expect(granted.permissions == ["calendar.read", "calendar.write"])
        #expect(MCPToolBridge.consent(granted, matchesCurrentEffectiveRisk: "external"))

        try await afterRestart.revokeConsent(serverId: "calendar", toolName: "calendar.create")

        let afterRevokeRestart = SwiftNativeMCPDispatcher(root: root)
        let revoked = try #require(try await afterRevokeRestart.listConsents().first)
        #expect(revoked.status == "revoked")
        #expect(revoked.revokedAt != nil)
        #expect(!MCPToolBridge.consent(revoked, matchesCurrentEffectiveRisk: "external"))
    }

    /// The Trust Center multimodal block is written atomically by the same
    /// app-side patch path that Settings uses. Its values must survive a fresh
    /// decode as one coherent block; a partial write can otherwise turn a
    /// visible privacy choice into an unrelated default after restart.
    @Test func multimodalSettingBlockRoundTripsAtomicallyAndTTSPolicyChangesTheRealGate() async throws {
        let root = try tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let enabled: [String: Any] = [
            "multimodalPolicy": [
                "screen_capture": true,
                "vision_api_calls": false,
                "file_ingestion_pdf": false,
                "file_ingestion_docx": true,
                "image_generation_openai": true,
                "tts_openai": true,
            ]
        ]
        let returned = try await NativeClient.applyTrustPolicyPatch(body: enabled, dataRoot: root)
        let returnedPolicy = try #require(returned.multimodalPolicy)
        #expect(returnedPolicy.screen_capture)
        #expect(!returnedPolicy.vision_api_calls)
        #expect(!returnedPolicy.file_ingestion_pdf)
        #expect(returnedPolicy.file_ingestion_docx)
        #expect(returnedPolicy.image_generation_openai)
        #expect(returnedPolicy.tts_openai)

        let policyURL = root
            .appendingPathComponent("trust", isDirectory: true)
            .appendingPathComponent("policy.json")
        let reopened = try JSONDecoder().decode(TrustPolicy.self, from: Data(contentsOf: policyURL))
        #expect(reopened.multimodalPolicy == returned.multimodalPolicy)

        // True gets beyond the Trust gate, but cannot silently perform a real
        // network request in this hermetic test because the explicit key is
        // empty. Turning the persisted bit back off must change the next
        // client's failure to trustDenied.
        await #expect(throws: MultimodalTTSError.notConfigured) {
            _ = try await SwiftOpenAITTSClient(apiKeyOverride: "", dataRoot: root)
                .synthesize(text: "hello", voice: "alloy", format: "mp3")
        }

        _ = try await NativeClient.applyTrustPolicyPatch(
            body: ["multimodalPolicy": ["tts_openai": false]],
            dataRoot: root
        )
        await #expect(throws: MultimodalTTSError.trustDenied) {
            _ = try await SwiftOpenAITTSClient(apiKeyOverride: "should-not-be-used", dataRoot: root)
                .synthesize(text: "hello", voice: "alloy", format: "mp3")
        }
    }
}
