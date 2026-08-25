import Foundation
import Testing
import TelegramBot
import ProviderRouting
@testable import NativeAgentApp

/// Coverage-ledger fence `app.settings` — the Telegram settings page.
///
/// Rows closed here (docs/evals/ledger.json):
///   * `store.telegram.config`            (UNCOVERED → wrong value + UNMEASURED)
///   * `setting.telegram.enabledAndAllowlist` (REPORTS-ONLY)
///   * `setting.telegram.allowlist`       (UNCOVERED → wrong value)
///   * `setting.telegram.requireMention`  (UNCOVERED → dead control)
///   * `setting.telegram.enabled`         (REPORTS-ONLY → dead control)
///   * `setting.telegram.brain`           (REPORTS-ONLY → two writers, one routing decision)
///
/// Why this file exists: `data/telegram/config.json` holds a bot token AND the
/// entire inbound authorization allowlist for an internet-reachable surface,
/// and before this file NOTHING read it — no instrument organ, no test, and
/// the ui-walk only proves the page renders. Every assertion below runs
/// against the REAL production writer/reader (`TelegramConfig.saveToDisk` /
/// `.loadFromDisk`) in a throwaway temp root; nothing touches the live store.
@Suite("app.settings · Telegram authorization store")
struct TelegramAuthorizationStoreEvalTests {

    private func tempRoot() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("telegram-auth-eval-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func rawConfigObject(root: URL) throws -> [String: Any] {
        let url = root
            .appendingPathComponent("telegram", isDirectory: true)
            .appendingPathComponent("config.json")
        let data = try Data(contentsOf: url)
        return (try JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }

    // MARK: - The store round-trip

    /// The authorization boundary must survive a save/load cycle EXACTLY.
    /// Silent-failure this bites: a save that drops the user-id half of the
    /// allowlist, or that resets `requireMention`, or that flips a
    /// deliberately-disabled poller back on at the next app launch.
    @Test func allowlistRequireMentionAndDisabledStateRoundTripExactly() throws {
        let root = try tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let saved = TelegramConfig(
            botToken: "123456:AA-bot-token",
            allowedChatIds: [-1_001_234_567_890, 42],
            allowedUserIds: [7, 8],
            requireMention: true,
            enabled: false
        )
        try TelegramConfig.saveToDisk(saved, dataRoot: root)

        let loaded = try #require(TelegramConfig.loadFromDisk(dataRoot: root))
        #expect(loaded.allowedChatIds == [-1_001_234_567_890, 42])
        #expect(loaded.allowedUserIds == [7, 8])
        #expect(loaded.requireMention == true,
                "requireMention must round-trip: false makes Agent answer EVERY line in every allowed group.")
        // Documented contract (TelegramBot+Config.swift): a saved-disabled
        // token must round-trip so the user can park the poller without
        // wiping the token.
        #expect(loaded.enabled == false)
        #expect(loaded.botToken == "123456:AA-bot-token")
    }

    /// Negative-space pin for the SAME round-trip: a set that is stored is not
    /// a set that is merged. Saving a NARROWER allowlist must not leave the
    /// previous, wider one behind — that is the "revoked access that still
    /// works" shape.
    @Test func narrowingTheAllowlistRemovesTheRevokedIdsRatherThanMerging() throws {
        let root = try tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        try TelegramConfig.saveToDisk(
            TelegramConfig(botToken: "t", allowedChatIds: [1, 2, 3], allowedUserIds: [9], enabled: true),
            dataRoot: root
        )
        try TelegramConfig.saveToDisk(
            TelegramConfig(botToken: "t", allowedChatIds: [1], allowedUserIds: [], enabled: true),
            dataRoot: root
        )

        let loaded = try #require(TelegramConfig.loadFromDisk(dataRoot: root))
        #expect(loaded.allowedChatIds == [1], "chat ids 2 and 3 were revoked and must be gone")
        #expect(loaded.allowedUserIds.isEmpty, "user id 9 was revoked and must be gone")
    }

    /// The exact "green badge, authorizes nobody" state is REPRESENTABLE and
    /// PERSISTS: enabled == true with a zero-length allowlist. The only thing
    /// standing between that state and an open front door is the poll loop's
    /// fail-closed branch, which is pinned below.
    @Test func enabledWithAnEmptyAllowlistPersistsAndTheRuntimeFailsClosed() throws {
        let root = try tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        try TelegramConfig.saveToDisk(
            TelegramConfig(botToken: "t", allowedChatIds: [], allowedUserIds: [], enabled: true),
            dataRoot: root
        )
        let loaded = try #require(TelegramConfig.loadFromDisk(dataRoot: root))
        #expect(loaded.enabled == true)
        #expect(loaded.allowedChatIds.isEmpty && loaded.allowedUserIds.isEmpty,
                "the store can hold an enabled bot with nobody authorized — the runtime gate is the ONLY perimeter")

        #expect(TelegramPollLoop.inboundAuthorizationDecision(
            allowedChatIds: loaded.allowedChatIds,
            allowedUserIds: loaded.allowedUserIds,
            chatId: 42,
            fromUserId: 7
        ) == .allowlistEmpty)
    }

    /// An empty bot token discards the ENTIRE saved config at read time —
    /// including the allowlist the user just typed. The bytes stay on disk;
    /// every reader sees nil. Pinning it because the consequence is severe and
    /// invisible: `loadFromDisk() == nil` at the poll-loop wiring means an
    /// EMPTY allowlist, i.e. the surface silently stops answering anyone.
    @Test func emptyBotTokenMakesTheWholeConfigUnreadableEvenThoughTheAllowlistIsOnDisk() throws {
        let root = try tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        try TelegramConfig.saveToDisk(
            TelegramConfig(botToken: "", allowedChatIds: [42], allowedUserIds: [7], enabled: true),
            dataRoot: root
        )

        #expect(TelegramConfig.loadFromDisk(dataRoot: root) == nil,
                "documented: a config with no token does not load")

        // …but the allowlist IS on disk. The loss is at READ time, so no
        // writer ever reports it.
        let raw = try rawConfigObject(root: root)
        #expect((raw["allowed_chat_ids"] as? [NSNumber])?.map(\.int64Value) == [42])
        #expect((raw["allowed_user_ids"] as? [NSNumber])?.map(\.int64Value) == [7])
    }

    /// The file carries a bot token. Owner-only permissions are part of the
    /// contract (`0700` dir / `0600` file), and `loadFromDisk` heals a config
    /// written before the lockdown. A regression here leaks a live bot token
    /// to every process running as the user.
    @Test func configFileAndDirectoryAreOwnerOnly() throws {
        let root = try tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        try TelegramConfig.saveToDisk(
            TelegramConfig(botToken: "secret-token", allowedChatIds: [1], enabled: true),
            dataRoot: root
        )
        let dir = root.appendingPathComponent("telegram", isDirectory: true)
        let file = dir.appendingPathComponent("config.json")

        let dirPerms = try FileManager.default.attributesOfItem(atPath: dir.path)[.posixPermissions] as? NSNumber
        let filePerms = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber
        #expect(dirPerms?.intValue == 0o700)
        #expect(filePerms?.intValue == 0o600)

        // The heal path: loosen both, then read — loadFromDisk must lock down.
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.path)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path)
        _ = TelegramConfig.loadFromDisk(dataRoot: root)
        let healedDir = try FileManager.default.attributesOfItem(atPath: dir.path)[.posixPermissions] as? NSNumber
        let healedFile = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber
        #expect(healedDir?.intValue == 0o700)
        #expect(healedFile?.intValue == 0o600)
    }

    // MARK: - Config → runtime reach (dead-control class)

    /// Every authorization field the Telegram settings page writes reaches the
    /// live poll-loop decision from the saved config, rather than a default.
    @Test func everyAuthorizationFieldReachesThePollLoopFromTheSavedConfig() throws {
        let root = try tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try TelegramConfig.saveToDisk(
            TelegramConfig(
                botToken: "t",
                allowedChatIds: [-100_123],
                allowedUserIds: [7],
                requireMention: true,
                enabled: true
            ),
            dataRoot: root
        )
        let saved = try #require(TelegramConfig.loadFromDisk(dataRoot: root))

        #expect(TelegramPollLoop.inboundAuthorizationDecision(
            allowedChatIds: saved.allowedChatIds,
            allowedUserIds: saved.allowedUserIds,
            chatId: -100_123,
            fromUserId: 999
        ) == .allowed)
        #expect(TelegramPollLoop.inboundAuthorizationDecision(
            allowedChatIds: saved.allowedChatIds,
            allowedUserIds: saved.allowedUserIds,
            chatId: -100_999,
            fromUserId: 7
        ) == .allowed)
        #expect(TelegramPollLoop.inboundAuthorizationDecision(
            allowedChatIds: saved.allowedChatIds,
            allowedUserIds: saved.allowedUserIds,
            chatId: -100_999,
            fromUserId: 999
        ) == .notAllowlisted)
        #expect(TelegramPollLoop.dropsForMissingMention(
            requireMention: saved.requireMention,
            chatId: -100_123,
            text: "ordinary group line"
        ))
    }

    /// `requireMention` drives the actual group-message drop decision; direct
    /// messages and explicit mentions remain eligible.
    @Test func requireMentionIsConsultedAtAGroupMessageDropSite() throws {
        #expect(TelegramPollLoop.dropsForMissingMention(
            requireMention: true, chatId: -100_123, text: "ordinary group line"
        ))
        #expect(!TelegramPollLoop.dropsForMissingMention(
            requireMention: true, chatId: -100_123, text: "@agent hello"
        ))
        #expect(!TelegramPollLoop.dropsForMissingMention(
            requireMention: true, chatId: 42, text: "private message"
        ))
        #expect(!TelegramPollLoop.dropsForMissingMention(
            requireMention: false, chatId: -100_123, text: "ordinary group line"
        ))
    }

    // MARK: - Two writers, one routing decision (setting.telegram.brain)

    /// The Telegram page's Model/Think pickers are a SECOND place the telegram
    /// surface's brain is set — the Providers page's per-surface picker is the
    /// first. The app resolves this by making `providers/surfaces.json` the
    /// single authority: `configureTelegram` MIGRATES any legacy model/effort
    /// out of the telegram config and then writes `model: nil,
    /// reasoningEffort: nil` into the config it saves. If someone re-adds
    /// `model: model` there, the two stores drift and whichever wrote last
    /// silently wins.
    @Test func telegramConfigIsNotASecondAuthorityForTheSurfaceModel() async throws {
        let root = try tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try TelegramConfig.saveToDisk(
            TelegramConfig(
                botToken: "123456:token",
                allowedChatIds: [42],
                requireMention: false,
                enabled: true,
                model: "claude-opus-5",
                reasoningEffort: "xhigh"
            ),
            dataRoot: root
        )
        let client = NativeClient(baseURL: "", dataRootOverride: root)
        try await client.configureTelegram(
            token: "",
            allowedChatIds: ["42"],
            allowedUserIds: [],
            requireMention: false,
            model: "",
            reasoningEffort: "",
            enabled: true,
            dataRoot: root,
            restartPollLoop: false
        )

        let persisted = try #require(TelegramConfig.loadFromDisk(dataRoot: root))
        #expect(persisted.model == nil)
        #expect(persisted.reasoningEffort == nil)
        let routing = try await SwiftNativeProviderRouting(dataRoot: root).computeModelPreferences()
        let resolved = resolveTelegramBrain(
            routing: routing["telegram"],
            legacyModel: persisted.model,
            legacyReasoningEffort: persisted.reasoningEffort
        )
        #expect(resolved.model == "claude-opus-5")
        #expect(resolved.reasoningEffort == "xhigh")
        #expect(!resolved.ignoresLegacyTuple)
    }

    /// The migration read has something to migrate: a LEGACY config that still
    /// carries `model` / `reasoning_effort` must parse, so `existing?.model`
    /// is non-nil on the next save. If the parser stopped reading those keys,
    /// the migration would silently no-op and the user's stored brain choice
    /// would evaporate on the first save.
    @Test func legacyModelAndEffortKeysStillParseSoTheMigrationHasASource() throws {
        let root = try tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let dir = root.appendingPathComponent("telegram", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let payload: [String: Any] = [
            "bot_token": "t",
            "allowed_chat_ids": [42],
            "enabled": true,
            "model": "claude-opus-5",
            "reasoning_effort": "xhigh",
        ]
        try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
            .write(to: dir.appendingPathComponent("config.json"))

        let loaded = try #require(TelegramConfig.loadFromDisk(dataRoot: root))
        #expect(loaded.model == "claude-opus-5")
        #expect(loaded.reasoningEffort == "xhigh")
    }

    // MARK: - Badge vs. persist pipeline (setting.telegram.allowlist)

    /// The authorization badge and Test Reply gate must use the same numeric
    /// parser as persistence. Text such as `none` must not look configured.
    @Test func allowlistBadgeAndPersistenceUseTheSameNumericParser() async throws {
        let textOnly = parseTelegramNumericIDs("none, tbd")
        #expect(!textOnly.isConfigured)
        #expect(textOnly.invalidTokens == ["none", "tbd"])
        let numeric = parseTelegramNumericIDs("42, -1001234567890")
        #expect(numeric.isConfigured)
        #expect(numeric.canonicalIDs == ["-1001234567890", "42"])

        let root = try tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let client = NativeClient(baseURL: "", dataRootOverride: root)
        try await client.configureTelegram(
            token: "123456:token",
            allowedChatIds: numeric.canonicalIDs,
            allowedUserIds: ["7"],
            requireMention: true,
            model: "",
            reasoningEffort: "",
            enabled: true,
            dataRoot: root,
            restartPollLoop: false
        )
        let saved = try #require(TelegramConfig.loadFromDisk(dataRoot: root))
        #expect(saved.allowedChatIds == [-1_001_234_567_890, 42])
        #expect(saved.allowedUserIds == [7])
        #expect(saved.requireMention)
        #expect(telegramAllowlistPresentation(
            chats: numeric.canonicalIDs.joined(separator: ", "),
            users: "7"
        ).isValidAndConfigured)
    }
}
