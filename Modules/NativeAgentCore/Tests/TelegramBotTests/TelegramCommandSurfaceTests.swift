import Foundation
import Testing
@testable import TelegramBot
import PersistenceCore

// MARK: - Coverage ledger: telegram.command.tools
//                         telegram.command.clear
//                         telegram.command.remember
//                         telegram.receipt.approvalDecision
//
// Four command-lane surfaces whose failure leaves a confident-looking reply:
// /tools prints a hardcoded control list that has drifted from the registry;
// /clear is the most destructive command in the fence and had ZERO behavioural
// coverage (its reply reports messagesBefore from the PRE-delete read, so
// clearing the wrong file — or nothing at all — prints an identical line);
// /remember silently answers "not configured in this Swift build" when the dep
// is missing; and the approval_decision receipt is the durable answer to "who
// approved this tool, from which chat, when" that no test ever read back.

private actor RecordingMemoryWriter: TelegramMemoryWriteRef {
    private(set) var remembered: [(text: String, source: String)] = []
    private(set) var noted: [(text: String, kind: String, source: String)] = []

    func remember(text: String, source: String) async throws -> String {
        remembered.append((text: text, source: source))
        return "mem-\(remembered.count)"
    }

    func note(text: String, kind: String, source: String) async throws -> String {
        noted.append((text: text, kind: kind, source: source))
        return "note-\(noted.count)"
    }

    func rememberedSnapshot() -> [(text: String, source: String)] { remembered }
    func rememberedCount() -> Int { remembered.count }
}

private actor ReceiptApprovalHandler: TelegramApprovalHandling {
    func resolveTelegramApproval(
        id: String,
        decision: TelegramApprovalDecision,
        chatId: Int,
        fromUserId: Int?
    ) async throws -> TelegramApprovalResolution {
        TelegramApprovalResolution(acknowledgement: "Recorded \(decision.rawValue) for \(id).")
    }
}

@Suite struct TelegramCommandSurfaceTests {

    // MARK: /tools

    /// The registry is the source of truth for what the user can type; the
    /// /tools reply is a hand-maintained sentence. Set containment on the
    /// MENU-VISIBLE names, not exact text.
    ///
    /// KNOWN GAP (stale UI, dated 2026-08-23): the reply lists 15 of 24 —
    /// /stop /retry /sessions /resume /approve /deny /fast /tools /restart are
    /// missing. Recorded as a known issue so this is green today and turns RED
    /// the moment the string is fixed, which is when the ledger row flips.
    @Test func toolsReply_should_advertise_every_menu_visible_command() async throws {
        let root = hermeticTelegramDataRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let reply = try #require(
            try await SwiftNativeTelegramBot(dataRoot: root)
                .dispatchSwiftSlashCommand("/tools", args: [], chatId: 42)
        )

        let menuNames = TelegramCommandRegistry.commands.map(\.command)
        #expect(!menuNames.isEmpty)
        let missing = menuNames.filter { !reply.contains("/\($0)") }

        // The drift, measured — a growing count is itself the regression.
        #expect(missing.count == 9)

        withKnownIssue(
            "telegram.command.tools: the hardcoded 'Available controls:' line has drifted from TelegramCommandRegistry"
        ) {
            #expect(missing.isEmpty, "commands missing from /tools: \(missing.sorted())")
        }
    }

    // MARK: /clear

    @Test func clearCommand_empties_only_the_bound_session() async throws {
        let root = hermeticTelegramDataRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = TelegramSessionStore(dataRoot: root)
        let persistence = SwiftNativePersistenceCore()

        let targetSession = try await store.activeSessionId(chatId: 101)
        let bystanderSession = try await store.activeSessionId(chatId: 202)
        #expect(targetSession != bystanderSession)

        func messagesPath(_ sessionId: String) -> URL {
            root.appendingPathComponent("chat", isDirectory: true)
                .appendingPathComponent("messages", isDirectory: true)
                .appendingPathComponent("\(sessionId).jsonl")
        }

        for idx in 0..<5 {
            try await persistence.appendJSONL(.object([
                "id": .string("t\(idx)"),
                "role": .string(idx % 2 == 0 ? "user" : "assistant"),
                "content": .string("target \(idx)"),
                "createdAt": .string("2026-08-23T00:00:00Z"),
            ]), to: messagesPath(targetSession))
        }
        for idx in 0..<3 {
            try await persistence.appendJSONL(.object([
                "id": .string("b\(idx)"),
                "role": .string("user"),
                "content": .string("bystander \(idx)"),
                "createdAt": .string("2026-08-23T00:00:00Z"),
            ]), to: messagesPath(bystanderSession))
        }
        let bystanderBefore = try Data(contentsOf: messagesPath(bystanderSession))

        let reply = try #require(
            try await SwiftNativeTelegramBot(dataRoot: root)
                .dispatchSwiftSlashCommand("/clear", args: [], chatId: 101)
        )

        // The reported count must equal the rows that ACTUALLY existed — a
        // clear that deleted nothing prints the same confident sentence.
        #expect(reply.contains(targetSession))
        #expect(reply.contains("5 message(s)"))
        #expect(((try? await persistence.readJSONL(messagesPath(targetSession))) ?? []).isEmpty)

        // Byte-identical, not merely "still has 3 rows".
        let bystanderAfter = try Data(contentsOf: messagesPath(bystanderSession))
        #expect(bystanderAfter == bystanderBefore)

        // Clearing twice must report 0, not repeat the stale pre-delete count.
        let second = try #require(
            try await SwiftNativeTelegramBot(dataRoot: root)
                .dispatchSwiftSlashCommand("/clear", args: [], chatId: 101)
        )
        #expect(second.contains("0 message(s)"))
    }

    // MARK: /remember

    @Test func rememberCommand_routes_text_to_the_memory_writer_with_its_source() async throws {
        let root = hermeticTelegramDataRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let writer = RecordingMemoryWriter()
        let bot = SwiftNativeTelegramBot(
            dataRoot: root,
            completenessDeps: TelegramBotCompletenessDeps(memory: writer)
        )

        let reply = try #require(
            try await bot.dispatchSwiftSlashCommand(
                "/remember", args: ["User", "prefers", "answer-first"], chatId: 42
            )
        )

        let calls = await writer.rememberedSnapshot()
        #expect(calls.count == 1)
        #expect(calls.first?.text == "User prefers answer-first")
        // Provenance is the whole point of the durable write: a source that
        // stops naming the Telegram command makes the memory unattributable.
        #expect(calls.first?.source == "telegram:/remember")
        // The reply must carry the id — a bare "ok" hides a no-op writer.
        #expect(reply.contains("mem-1"))
    }

    @Test func rememberCommand_withNoText_returns_usage_without_touching_the_writer() async throws {
        let root = hermeticTelegramDataRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let writer = RecordingMemoryWriter()
        let bot = SwiftNativeTelegramBot(
            dataRoot: root,
            completenessDeps: TelegramBotCompletenessDeps(memory: writer)
        )

        let reply = try #require(
            try await bot.dispatchSwiftSlashCommand("/remember", args: ["   "], chatId: 42)
        )
        #expect(reply.contains("/remember"))
        #expect(await writer.rememberedCount() == 0)
    }

    /// The silent zero: with no memory dep the command answers with a build
    /// note and the user's memory is never stored. Pinned so the unwired shape
    /// stays LOUD in the reply rather than looking like a success.
    @Test func rememberCommand_withoutMemoryDep_says_so_instead_of_claiming_success() async throws {
        let root = hermeticTelegramDataRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let reply = try #require(
            try await SwiftNativeTelegramBot(dataRoot: root)
                .dispatchSwiftSlashCommand("/remember", args: ["something"], chatId: 42)
        )
        #expect(reply.lowercased().contains("not configured"))
        #expect(!reply.lowercased().contains("remembered:"))
    }

    // MARK: approval_decision receipt

    /// The approval FLOW is well covered; the durable RECORD of it was read by
    /// nothing. recordReceipt appends with `try?`, so a silent append failure
    /// or a kind-string drift leaves no answer to "who approved this tool".
    @Test func approvalSlashCommand_writes_one_attributable_approval_decision_receipt() async throws {
        let root = hermeticTelegramDataRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let token = "123456:AAH-secret-bot-token"
        let loop = TelegramPollLoop(
            interval: 60,
            token: token,
            allowedChatIds: [77],
            dataRoot: root,
            offsetURL: root
                .appendingPathComponent("telegram", isDirectory: true)
                .appendingPathComponent("last_offset.json"),
            sendMessage: { _, _, _ in },
            approvalHandler: ReceiptApprovalHandler(),
            turnCoordinator: TelegramTurnCoordinator()
        )
        let message = TelegramMessage(
            messageId: 4242, chatId: 77, fromUserId: 11, text: "/approve tool-req-1"
        )
        let command = try #require(TelegramApprovalCommand.parse(text: "/approve tool-req-1"))

        await loop.handleApprovalSlashCommand(
            command,
            update: TelegramUpdate(updateId: 808, message: message),
            message: message,
            text: "/approve tool-req-1"
        )

        let receipts = await telegramFeedRows(root: root, "receipts")
        let decisions = receipts.filter { $0["kind"] == .string("approval_decision") }
        #expect(decisions.count == 1)
        let row = try #require(decisions.first)
        // Attribution envelope: which chat, which human, which update.
        #expect(row["chatId"] == .string("77"))
        #expect(row["userId"] == .string("11"))
        #expect(row["updateId"] == .int(808))
        // The approval id and the decision have to survive into the row, or
        // the audit trail cannot answer what was approved.
        let flat = String(describing: row)
        #expect(flat.contains("tool-req-1"))
        #expect(flat.contains("approved"))
        // …and the bot token must never ride along into a durable feed.
        #expect(!flat.contains(token))
        #expect(!flat.contains("AAH-secret"))
    }
}
