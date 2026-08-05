import Testing
import Foundation
import PersistenceCore
@testable import TelegramBot

// MARK: - /restart owner gating (2026-06-10)
//
// The restart routine itself (cooldown, audit, relauncher, terminate) is
// AppRestartCoordinator's job and is covered in ChatOrchestrationTests.
// THESE tests pin the Telegram-side contract: /restart only fires for the
// owner allowlist FROM A PRIVATE CHAT (an allowlisted group chat must never
// let arbitrary members restart the app — slash commands run BEFORE the
// poll loop's group mention gate), fails closed on missing dep / unknown
// sender / empty allowlist / missing-or-mismatched from id, forwards the
// caller-supplied reason, and only arms termination via the afterReplySent
// followup (never during dispatch). Stub ref only — no restart ever fires.

private final class MockRestartRef: TelegramRestartRef, @unchecked Sendable {
    private let lock = NSLock()
    let owners: Set<Int64>
    /// When true, requestRestart returns an armTerminate closure that
    /// records "arm" — mimicking a restart that actually fired.
    let provideArm: Bool
    private(set) var requestedReasons: [String] = []
    private(set) var events: [String] = []

    init(owners: Set<Int64>, provideArm: Bool = false) {
        self.owners = owners
        self.provideArm = provideArm
    }

    func ownerChatIds() async -> Set<Int64> { owners }

    func requestRestart(reason: String) async -> TelegramRestartOutcome {
        record(reason) // sync helper — NSLock defer-unlock is banned in async contexts
        let arm: (@Sendable () -> Void)?
        if provideArm {
            arm = { [weak self] in
                if let self { self.recordEvent("arm") }
            }
        } else {
            arm = nil
        }
        return TelegramRestartOutcome(
            reply: "Restarting NativeAgent — back in under a minute.",
            armTerminate: arm
        )
    }

    private func record(_ reason: String) {
        lock.lock(); defer { lock.unlock() }
        requestedReasons.append(reason)
        events.append("fired")
    }

    fileprivate func recordEvent(_ event: String) {
        lock.lock(); defer { lock.unlock() }
        events.append(event)
    }
}

@Suite("Telegram /restart owner gating")
struct TelegramRestartCommandTests {

    @Test func restart_from_owner_private_chat_routes_to_shared_restart_routine() async throws {
        let restart = MockRestartRef(owners: [123])
        let bot = SwiftNativeTelegramBot(
            dataRoot: hermeticTelegramDataRoot(),
            completenessDeps: TelegramBotCompletenessDeps(restart: restart)
        )
        let reply = try await bot.dispatchSwiftSlashCommand(
            "/restart", args: ["hung", "tool", "loop"], chatId: 123,
            fromUserId: 123, chatType: "private"
        )
        #expect(reply == "Restarting NativeAgent — back in under a minute.")
        #expect(restart.requestedReasons == ["hung tool loop"])
    }

    @Test func restart_default_reason_when_no_args() async throws {
        let restart = MockRestartRef(owners: [123])
        let bot = SwiftNativeTelegramBot(
            dataRoot: hermeticTelegramDataRoot(),
            completenessDeps: TelegramBotCompletenessDeps(restart: restart)
        )
        _ = try await bot.dispatchSwiftSlashCommand(
            "/restart", args: [], chatId: 123, fromUserId: 123, chatType: "private"
        )
        #expect(restart.requestedReasons == ["telegram /restart"])
    }

    @Test func restart_from_non_owner_chat_is_refused_without_firing() async throws {
        let restart = MockRestartRef(owners: [123])
        let bot = SwiftNativeTelegramBot(
            dataRoot: hermeticTelegramDataRoot(),
            completenessDeps: TelegramBotCompletenessDeps(restart: restart)
        )
        let reply = try await bot.dispatchSwiftSlashCommand(
            "/restart", args: [], chatId: 999, fromUserId: 999, chatType: "private"
        )
        #expect(reply == "/restart is owner-gated; this chat is not authorized.")
        #expect(restart.requestedReasons.isEmpty)
    }

    @Test func restart_with_empty_allowlist_fails_closed() async throws {
        // No owner on disk → NOBODY may restart, not "everybody may".
        let restart = MockRestartRef(owners: [])
        let bot = SwiftNativeTelegramBot(
            dataRoot: hermeticTelegramDataRoot(),
            completenessDeps: TelegramBotCompletenessDeps(restart: restart)
        )
        let reply = try await bot.dispatchSwiftSlashCommand(
            "/restart", args: [], chatId: 123, fromUserId: 123, chatType: "private"
        )
        #expect(reply == "/restart is owner-gated; this chat is not authorized.")
        #expect(restart.requestedReasons.isEmpty)
    }

    @Test func restart_without_chat_id_fails_closed() async {
        // Legacy completeness path (no chatId threaded) must never restart,
        // even with the dep fully wired: nil sender is never the owner.
        let restart = MockRestartRef(owners: [123])
        let bot = SwiftNativeTelegramBot(dataRoot: hermeticTelegramDataRoot())
        let reply = await bot.dispatchCompletenessCommand(
            "/restart",
            args: [],
            depsOverride: TelegramBotCompletenessDeps(restart: restart),
            chatId: nil
        )
        #expect(reply != nil)
        #expect(restart.requestedReasons.isEmpty)
    }

    // BLOCKER (2026-06-10): an ALLOWLISTED group chat must not let any
    // member /restart. Slash commands are processed before the group
    // mention gate, so the restart gate itself must require a private chat.
    @Test func restart_from_allowlisted_group_chat_is_refused() async throws {
        let groupChatId = -100123 // Telegram group/supergroup ids are negative
        let restart = MockRestartRef(owners: [Int64(groupChatId)])
        let bot = SwiftNativeTelegramBot(
            dataRoot: hermeticTelegramDataRoot(),
            completenessDeps: TelegramBotCompletenessDeps(restart: restart)
        )
        let reply = try await bot.dispatchSwiftSlashCommand(
            "/restart", args: [], chatId: groupChatId,
            fromUserId: 555, chatType: "group"
        )
        #expect(reply == "/restart only works in a private chat with the owner; group chats cannot restart the app.")
        #expect(restart.requestedReasons.isEmpty)
    }

    @Test func restart_from_allowlisted_group_without_chat_type_still_refused() async throws {
        // Even when chat.type is absent (synthetic shape), the negative
        // chat id proxy must catch the group case.
        let groupChatId = -100123
        let restart = MockRestartRef(owners: [Int64(groupChatId)])
        let bot = SwiftNativeTelegramBot(
            dataRoot: hermeticTelegramDataRoot(),
            completenessDeps: TelegramBotCompletenessDeps(restart: restart)
        )
        let reply = try await bot.dispatchSwiftSlashCommand(
            "/restart", args: [], chatId: groupChatId, fromUserId: 555
        )
        #expect(reply == "/restart only works in a private chat with the owner; group chats cannot restart the app.")
        #expect(restart.requestedReasons.isEmpty)
    }

    @Test func restart_with_missing_from_user_id_fails_closed() async throws {
        let restart = MockRestartRef(owners: [123])
        let bot = SwiftNativeTelegramBot(
            dataRoot: hermeticTelegramDataRoot(),
            completenessDeps: TelegramBotCompletenessDeps(restart: restart)
        )
        let reply = try await bot.dispatchSwiftSlashCommand(
            "/restart", args: [], chatId: 123, chatType: "private"
        )
        #expect(reply == "/restart is owner-gated; this chat is not authorized.")
        #expect(restart.requestedReasons.isEmpty)
    }

    @Test func restart_with_mismatched_from_user_id_fails_closed() async throws {
        // A genuine private chat has from.id == chat.id; anything else is a
        // forged/synthetic shape and fails closed.
        let restart = MockRestartRef(owners: [123])
        let bot = SwiftNativeTelegramBot(
            dataRoot: hermeticTelegramDataRoot(),
            completenessDeps: TelegramBotCompletenessDeps(restart: restart)
        )
        let reply = try await bot.dispatchSwiftSlashCommand(
            "/restart", args: [], chatId: 123, fromUserId: 999, chatType: "private"
        )
        #expect(reply == "/restart is owner-gated; this chat is not authorized.")
        #expect(restart.requestedReasons.isEmpty)
    }

    // BLOCKER (2026-06-10): the terminate timer must not race the reply
    // send. The detailed dispatch returns the arm as afterReplySent and
    // must NOT have invoked it during dispatch.
    @Test func restart_detailed_dispatch_defers_terminate_arm_to_followup() async throws {
        let restart = MockRestartRef(owners: [123], provideArm: true)
        let bot = SwiftNativeTelegramBot(
            dataRoot: hermeticTelegramDataRoot(),
            completenessDeps: TelegramBotCompletenessDeps(restart: restart)
        )
        let outcome = try await bot.dispatchSwiftSlashCommandDetailed(
            "/restart", args: [], chatId: 123, fromUserId: 123, chatType: "private"
        )
        #expect(outcome.reply == "Restarting NativeAgent — back in under a minute.")
        // Restart fired, but the arm has NOT run yet.
        #expect(restart.events == ["fired"])
        let followup = try #require(outcome.afterReplySent)
        followup()
        #expect(restart.events == ["fired", "arm"])
    }

    @Test func restart_without_wired_dep_reports_unsupported() async throws {
        let bot = SwiftNativeTelegramBot(
            dataRoot: hermeticTelegramDataRoot(),
            completenessDeps: TelegramBotCompletenessDeps()
        )
        let reply = try await bot.dispatchSwiftSlashCommand(
            "/restart", args: [], chatId: 123, fromUserId: 123, chatType: "private"
        )
        let text = try #require(reply)
        #expect(text.contains("not wired in this build"))
    }

    @Test func command_registry_advertises_owner_gated_restart() {
        let restart = TelegramCommandRegistry.commands.first { $0.command == "restart" }
        #expect(restart != nil)
        #expect(restart?.description.contains("owner only") == true)
    }
}
