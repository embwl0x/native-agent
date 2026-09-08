import AppKit
import ChatOrchestration
import Foundation
import MemoryV2
import MultimodalTTS
import NativeAgentCore
import ProviderRouting
import TelegramBot
import Testing
@testable import NativeAgentApp

/// Settings are authority changes, not view state. These cases exercise the
/// values a fresh production reader consumes, including invalid persisted
/// state, rather than inspecting how a SwiftUI control happens to be wired.
@Suite("app.settings · authority behavior wave 1", .serialized)
struct SettingsBehaviorWave1EvalTests {
    private func tempRoot(_ label: String) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("settings-wave1-\(label)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func isolatedDefaults() throws -> UserDefaults {
        let suite = "nativeagent.settings.wave1.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else {
            throw CocoaError(.fileNoSuchFile)
        }
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    // MARK: - setting.nativeagent.compactionThresholdTokens

    @Test func compactionUsesThePersistedThresholdOnAColdRead() throws {
        let defaults = try isolatedDefaults()
        defaults.set(345_678, forKey: ChatSessionAutocompactionConfig.defaultsKey)

        let config = ChatSessionAutocompactionConfig.productionDefault(defaults: defaults)
        #expect(config.thresholdTokens == 345_678)
        #expect(config.enabled)
    }

    @Test func compactionRejectsZeroAndNegativePersistedThresholds() throws {
        for badValue in [0, -1, -50_000] {
            let defaults = try isolatedDefaults()
            defaults.set(badValue, forKey: ChatSessionAutocompactionConfig.defaultsKey)
            #expect(
                ChatSessionAutocompactionConfig.productionDefault(defaults: defaults).thresholdTokens
                    == ChatSessionAutocompactionConfig.defaultThresholdTokens
            )
        }
    }

    @Test func compactionDefaultsDistillationOnOnlyWhenNoChoiceWasPersisted() throws {
        let absent = try isolatedDefaults()
        #expect(ChatSessionAutocompactionConfig.productionDefault(defaults: absent).distillEnabled)

        let explicitOff = try isolatedDefaults()
        explicitOff.set(false, forKey: ChatSessionAutocompactionConfig.distillEnabledKey)
        #expect(!ChatSessionAutocompactionConfig.productionDefault(defaults: explicitOff).distillEnabled)
    }

    @Test func compactionAppliesTheModelPressureCeilingForSmallWindows() {
        let config = ChatSessionAutocompactionConfig(thresholdTokens: 500_000)
        #expect(config.effectiveThresholdTokens(forModel: "gpt-5.4", providerID: "openai") == 51_200)
    }

    @Test func compactionRetainsTheUserThresholdWhenTheModelWindowIsUnknown() {
        let config = ChatSessionAutocompactionConfig(thresholdTokens: 123_456)
        #expect(config.effectiveThresholdTokens(forModel: "unknown-eval-model", providerID: "openai") == 123_456)
    }

    // MARK: - setting.nativeagent.darkMode

    @MainActor
    @Test func detachedPanelFollowsTheSameDarkModeAuthorityWhenEnabled() throws {
        let defaults = try isolatedDefaults()
        defaults.set(true, forKey: "nativeagent.darkMode")

        #expect(DetachedChatWindowController.preferredAppearance(defaults: defaults)?.name == .darkAqua)
    }

    @MainActor
    @Test func detachedPanelFollowsSystemAppearanceWhenDarkModeIsDisabled() throws {
        let defaults = try isolatedDefaults()
        defaults.set(false, forKey: "nativeagent.darkMode")

        #expect(DetachedChatWindowController.preferredAppearance(defaults: defaults) == nil)
    }

    @MainActor
    @Test func darkModeObserverRegistersOnceAndStopsReceivingChanges() async {
        let center = NotificationCenter()
        let name = Notification.Name("dark-mode-eval")
        let observer = DarkModePreferenceObserver(center: center, name: name, object: nil)
        var notifications = 0
        observer.start { notifications += 1 }
        observer.start { notifications += 1 }
        #expect(observer.isObserving)
        center.post(name: name, object: nil)
        await Task.yield()
        #expect(notifications == 1)

        observer.stop()
        #expect(!observer.isObserving)
        center.post(name: name, object: nil)
        await Task.yield()
        #expect(notifications == 1)
    }

    @MainActor
    @Test func darkModeObserverTearsDownOnRelease() async {
        let center = NotificationCenter()
        let name = Notification.Name("dark-mode-release-eval")
        var notifications = 0
        weak var released: DarkModePreferenceObserver?
        do {
            let observer = DarkModePreferenceObserver(center: center, name: name, object: nil)
            observer.start { notifications += 1 }
            released = observer
        }
        #expect(released == nil)
        center.post(name: name, object: nil)
        await Task.yield()
        #expect(notifications == 0)
    }

    // MARK: - setting.embeddings.memoryMode

    @Test func memoryModeSaveSurvivesAColdRuntimeStatusRead() async throws {
        let root = try tempRoot("memory-mode")
        defer { try? FileManager.default.removeItem(at: root) }
        let writer = ManagedEmbeddingProvider(dataRoot: root, availabilityProbe: { false })
        try await writer.setMemoryMode(ManagedEmbeddingProvider.lowMemoryMode)

        #expect(writer.snapshot().mode == ManagedEmbeddingProvider.lowMemoryMode)
        let reopened = ManagedEmbeddingProvider(dataRoot: root, availabilityProbe: { false })
        #expect(reopened.snapshot().mode == ManagedEmbeddingProvider.lowMemoryMode)
        #expect(ManagedEmbeddingProvider.usesCPUOnlyCompute(mode: reopened.snapshot().mode))
    }

    @Test func malformedMemoryModeIsPersistedAsVisibleFastFallback() async throws {
        let root = try tempRoot("memory-mode-malformed")
        defer { try? FileManager.default.removeItem(at: root) }
        let writer = ManagedEmbeddingProvider(dataRoot: root, availabilityProbe: { false })
        try await writer.setMemoryMode("low-memory")

        let reopened = ManagedEmbeddingProvider(dataRoot: root, availabilityProbe: { false })
        #expect(reopened.snapshot().mode == ManagedEmbeddingProvider.performanceMode)
        #expect(!ManagedEmbeddingProvider.usesCPUOnlyCompute(mode: reopened.snapshot().mode))
    }

    // MARK: - setting.trust.multimodalPolicy / setting.voice.autoReadAndOpenAIVoice

    @Test func savedTTSDenialStopsTheNextVoiceClientBeforeCredentialUse() async throws {
        let root = try tempRoot("tts-denied")
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try await NativeClient.applyTrustPolicyPatch(
            body: ["multimodalPolicy": ["tts_openai": false]],
            dataRoot: root
        )

        await #expect(throws: MultimodalTTSError.trustDenied) {
            _ = try await SwiftOpenAITTSClient(apiKeyOverride: "not-used", dataRoot: root)
                .synthesize(text: "hello", voice: "alloy", format: "mp3")
        }
    }

    @Test func savedTTSGrantReachesTheCredentialGateWithoutFallingBack() async throws {
        let root = try tempRoot("tts-granted")
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try await NativeClient.applyTrustPolicyPatch(
            body: ["multimodalPolicy": ["tts_openai": true]],
            dataRoot: root
        )

        await #expect(throws: MultimodalTTSError.notConfigured) {
            _ = try await SwiftOpenAITTSClient(apiKeyOverride: "", dataRoot: root)
                .synthesize(text: "hello", voice: "alloy", format: "mp3")
        }
    }

    // MARK: - setting.telegram.enabled / allowlist / requireMention

    @Test func telegramSaveAndColdReadPreserveDisabledAuthorizationExactly() throws {
        let root = try tempRoot("telegram-disabled")
        defer { try? FileManager.default.removeItem(at: root) }
        let saved = TelegramConfig(
            botToken: "test-token",
            allowedChatIds: [-100_123, 42],
            allowedUserIds: [7],
            requireMention: true,
            enabled: false
        )
        try TelegramConfig.saveToDisk(saved, dataRoot: root)

        let reread = try #require(TelegramConfig.loadFromDisk(dataRoot: root))
        #expect(reread.enabled == false)
        #expect(reread.allowedChatIds == [-100_123, 42])
        #expect(reread.allowedUserIds == [7])
        #expect(reread.requireMention)
    }

    @Test func telegramMalformedCanonicalConfigIsUnavailableAndBytePreserved() throws {
        let root = try tempRoot("telegram-corrupt")
        defer { try? FileManager.default.removeItem(at: root) }
        let config = root.appendingPathComponent("telegram/config.json")
        try FileManager.default.createDirectory(at: config.deletingLastPathComponent(), withIntermediateDirectories: true)
        let damaged = Data("{not-json".utf8)
        try damaged.write(to: config)

        #expect(TelegramConfig.loadFromDisk(dataRoot: root) == nil)
        #expect(try Data(contentsOf: config) == damaged)
    }

    @Test func requireMentionChangesTheRuntimeGroupMessageDecision() {
        #expect(TelegramPollLoop.dropsForMissingMention(
            requireMention: true, chatId: -100_123, text: "hello"
        ))
        #expect(!TelegramPollLoop.dropsForMissingMention(
            requireMention: false, chatId: -100_123, text: "hello"
        ))
        #expect(!TelegramPollLoop.dropsForMissingMention(
            requireMention: true, chatId: -100_123, text: "@agent hello"
        ))
        #expect(!TelegramPollLoop.dropsForMissingMention(
            requireMention: true, chatId: 42, text: "hello"
        ))
    }

    @Test func telegramAllowlistPresentationAndTestActionShareTheAcceptedIDGate() {
        let empty = telegramAllowlistPresentation(chats: "", users: "")
        #expect(!empty.isValidAndConfigured)

        let junk = telegramAllowlistPresentation(chats: "tbd, none", users: "later")
        #expect(junk.acceptedCount == 0)
        #expect(!junk.isValidAndConfigured)

        let mixed = telegramAllowlistPresentation(chats: "-100123, junk", users: "42")
        #expect(mixed.acceptedCount == 2)
        #expect(mixed.invalidTokens == ["junk"])
        #expect(!mixed.isValidAndConfigured)

        let valid = telegramAllowlistPresentation(chats: "-100123", users: "42 42")
        #expect(valid.acceptedCount == 2)
        #expect(valid.isValidAndConfigured)
    }

    @Test func telegramEnabledChangeIsVisibleAsUnsavedAuthorizationState() {
        let saved = telegramAllowlistPresentation(chats: "42", users: "")
        #expect(!telegramAuthorizationHasUnsavedChanges(
            enabled: true, requireMention: false, allowlist: saved,
            savedEnabled: true, savedRequireMention: false, savedAcceptedCount: 1
        ))
        #expect(telegramAuthorizationHasUnsavedChanges(
            enabled: false, requireMention: false, allowlist: saved,
            savedEnabled: true, savedRequireMention: false, savedAcceptedCount: 1
        ))
        #expect(telegramAuthorizationHasUnsavedChanges(
            enabled: true, requireMention: false,
            allowlist: telegramAllowlistPresentation(chats: "42, junk", users: ""),
            savedEnabled: true, savedRequireMention: false, savedAcceptedCount: 1
        ))
    }

    @Test func unsupportedTelegramReasoningEffortIsVisibleRatherThanAnUnselectedPicker() {
        let model = ModelCatalogItem(
            id: "small-model", displayName: "Small", description: nil,
            defaultReasoningEffort: "low", supportedReasoningEfforts: ["low", "medium"],
            supportsFast: false, priority: 0
        )
        let current = ModelSurfacePreference(surface: "telegram", model: model.id, reasoningEffort: "xhigh")
        let catalog = ModelCatalogResponse(
            status: "ok", source: "eval", defaultModel: model.id, fallbackModels: [], models: [model],
            reasoningEfforts: ["low", "medium", "xhigh"].map {
                ReasoningEffortOption(id: $0, label: $0, description: nil)
            },
            current: ModelRoutingCurrent(chat: current, telegram: current), updatedAt: nil
        )
        let warning = telegramReasoningEffortMismatch(from: catalog, model: model.id, selected: "xhigh")
        #expect(warning?.contains("unsupported") == true)
        #expect(warning?.contains("low") == true)
        #expect(telegramReasoningEffortMismatch(from: catalog, model: model.id, selected: "low") == nil)
    }

    @Test func canonicalTelegramBrainWinsOverAStaleLegacyConfigTuple() async throws {
        let root = try tempRoot("telegram-brain-precedence")
        defer { try? FileManager.default.removeItem(at: root) }
        try TelegramConfig.saveToDisk(
            TelegramConfig(
                botToken: "token", allowedChatIds: [42], enabled: true,
                model: "legacy-model", reasoningEffort: "xhigh"
            ),
            dataRoot: root
        )
        let routing = SwiftNativeProviderRouting(dataRoot: root)
        _ = try await routing.saveModelConfig(.object([
            "surface": .string("telegram"),
            "model": .string("canonical-model"),
            "reasoningEffort": .string("low"),
        ]))

        let freshRouting = SwiftNativeProviderRouting(dataRoot: root)
        let freshLegacy = try #require(TelegramConfig.loadFromDisk(dataRoot: root))
        let resolution = resolveTelegramBrain(
            routing: try await freshRouting.computeModelPreferences()["telegram"],
            legacyModel: freshLegacy.model,
            legacyReasoningEffort: freshLegacy.reasoningEffort
        )

        #expect(resolution.model == "canonical-model")
        #expect(resolution.reasoningEffort == "low")
        #expect(resolution.ignoresLegacyTuple)
    }

    @Test func legacyTelegramBrainCannotReviveAnUnavailableCanonicalRoute() {
        let resolution = resolveTelegramBrain(
            routing: nil,
            legacyModel: "legacy-model",
            legacyReasoningEffort: "xhigh"
        )

        #expect(resolution.model == nil)
        #expect(resolution.reasoningEffort == nil)
        #expect(resolution.ignoresLegacyTuple)
    }

    @Test func missingOpenAIVoicePrerequisitesFallbackToLocalWithVisibleReason() {
        #expect(OpenAIVoiceFailureDisposition.resolve(MultimodalTTSError.trustDenied)
            == .fallbackToLocal(
                message: "OpenAI voice is not allowed. Reading aloud with the Mac voice instead."
            ))
        #expect(OpenAIVoiceFailureDisposition.resolve(MultimodalTTSError.notConfigured)
            == .fallbackToLocal(
                message: "OpenAI voice needs an API key. Reading aloud with the Mac voice instead."
            ))
    }

    @Test func openAIVoiceTransportFailureStaysVisibleInsteadOfChangingVoices() {
        #expect(OpenAIVoiceFailureDisposition.resolve(URLError(.notConnectedToInternet))
            == .surfaceFailure(message: URLError(.notConnectedToInternet).localizedDescription))
    }

    // MARK: - setting.telegram.brain / reasoningEffort

    @Test func telegramModelSelectionWritesTheCanonicalRoutingTuple() async throws {
        let root = try tempRoot("telegram-routing")
        defer { try? FileManager.default.removeItem(at: root) }
        let routing = SwiftNativeProviderRouting(dataRoot: root)
        let bridge = TelegramProviderRoutingBridge(routing: routing, dataRoot: root)

        try await bridge.saveModelSelection(
            surface: "telegram",
            provider: "openai_oauth_direct",
            model: "gpt-5.6-sol"
        )
        let fresh = SwiftNativeProviderRouting(dataRoot: root)
        let snapshot = try await fresh.checkedRoutingSnapshot()
        #expect(snapshot.activeProviders["telegram"] == "openai_oauth_direct")
        #expect(snapshot.preferences["telegram"]?.model == "gpt-5.6-sol")
    }

    @Test func telegramRoutingNeverBorrowsTheChatSurfaceSelection() async throws {
        let root = try tempRoot("telegram-routing-isolation")
        defer { try? FileManager.default.removeItem(at: root) }
        let routing = SwiftNativeProviderRouting(dataRoot: root)
        try await routing.saveSurfaceConfiguration(
            surface: "chat",
            model: "claude-sonnet-5",
            reasoningEffort: "high",
            serviceTier: nil,
            providerId: "anthropic",
            seedMissingControls: true
        )
        try await routing.saveSurfaceConfiguration(
            surface: "telegram",
            model: "gpt-5.6-sol",
            reasoningEffort: "ultra",
            serviceTier: "priority",
            providerId: "openai_oauth_direct",
            seedMissingControls: true
        )

        let snapshot = try await SwiftNativeProviderRouting(dataRoot: root).checkedRoutingSnapshot()
        #expect(snapshot.preferences["chat"]?.model == "claude-sonnet-5")
        #expect(snapshot.preferences["telegram"]?.model == "gpt-5.6-sol")
        #expect(snapshot.preferences["telegram"]?.reasoningEffort == "ultra")
        #expect(snapshot.activeProviders["chat"] == "anthropic")
        #expect(snapshot.activeProviders["telegram"] == "openai_oauth_direct")
    }
}
