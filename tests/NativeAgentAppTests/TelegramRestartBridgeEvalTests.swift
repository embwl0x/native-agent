import Foundation
import Testing
import TelegramBot
import PersistenceCore
@testable import NativeAgentApp

// Coverage ledger: app.bridges / telegram.restartBridge
//
// The Telegram-facing acknowledgement is only truthful when the app restart
// primitive both accepts the request and hands back the deferred terminate
// closure. These tests use the real app bridge with a hermetic data root and
// a stubbed primitive; no relauncher or process termination is ever invoked.

private final class TelegramRestartBridgePrimitiveStub: @unchecked Sendable {
    private let lock = NSLock()
    private let response: JSONValue
    private let providesTerminationHandoff: Bool
    private(set) var reasons: [String] = []
    private(set) var terminationArms = 0

    init(response: JSONValue, providesTerminationHandoff: Bool) {
        self.response = response
        self.providesTerminationHandoff = providesTerminationHandoff
    }

    func request(
        reason: String
    ) async -> (envelope: JSONValue, armTerminate: (@Sendable () -> Void)?) {
        let shouldArm = lock.withLock {
            reasons.append(reason)
            return providesTerminationHandoff
        }

        let handoff: (@Sendable () -> Void)?
        if shouldArm {
            handoff = { [weak self] in
                self?.recordTerminationArm()
            }
        } else {
            handoff = nil
        }
        return (response, handoff)
    }

    private func recordTerminationArm() {
        lock.withLock { terminationArms += 1 }
    }
}

private func telegramRestartBridgeRoot() throws -> URL {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("TelegramRestartBridgeEval-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try TelegramBot.TelegramConfig.saveToDisk(
        .init(botToken: "123456:eval-token", allowedChatIds: [42], enabled: true),
        dataRoot: root
    )
    return root
}

private func telegramRestartDispatch(
    root: URL,
    primitive: TelegramRestartBridgePrimitiveStub
) async throws -> TelegramSlashDispatchOutcome {
    let bridge = TelegramRestartBridge(
        dataRoot: root,
        deferredRestart: { reason in await primitive.request(reason: reason) }
    )
    let bot = SwiftNativeTelegramBot(
        dataRoot: root,
        completenessDeps: TelegramBotCompletenessDeps(restart: bridge)
    )
    return try await bot.dispatchSwiftSlashCommandDetailed(
        "/restart",
        args: ["poller", "wedged"],
        chatId: 42,
        fromUserId: 42,
        chatType: "private"
    )
}

@Suite("app.bridges · Telegram restart bridge", .serialized)
struct TelegramRestartBridgeEvalTests {
    @Test("the user receives a restart acknowledgement only after the accepted primitive supplies its terminate handoff")
    func acceptedRestartAcknowledgesThenArmsAfterTheReply() async throws {
        let root = try telegramRestartBridgeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let primitive = TelegramRestartBridgePrimitiveStub(
            response: .object([
                "status": .string("restarting"),
                "note": .string("The relauncher is ready."),
            ]),
            providesTerminationHandoff: true
        )

        let outcome = try await telegramRestartDispatch(root: root, primitive: primitive)

        #expect(outcome.reply?.contains("Restarting NativeAgent") == true)
        #expect(primitive.reasons == ["poller wedged"])
        #expect(primitive.terminationArms == 0, "the reply is emitted before app termination is armed")
        let arm = try #require(outcome.afterReplySent)
        arm()
        #expect(primitive.terminationArms == 1)
    }

    @Test("refused or incomplete primitive outcomes never emit a bare restart acknowledgement")
    func refusedAndIncompleteRestartsReportFailureWithoutArming() async throws {
        let root = try telegramRestartBridgeRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let refused = TelegramRestartBridgePrimitiveStub(
            response: .object([
                "status": .string("failed"),
                "reason": .string("relauncher_spawn_failed"),
                "detail": .string("stubbed relauncher failure"),
            ]),
            providesTerminationHandoff: false
        )
        let refusedOutcome = try await telegramRestartDispatch(root: root, primitive: refused)
        #expect(refusedOutcome.reply?.contains("Restart failed: relauncher_spawn_failed") == true)
        #expect(refusedOutcome.reply?.contains("Restarting NativeAgent") == false)
        #expect(refusedOutcome.afterReplySent == nil)
        #expect(refused.terminationArms == 0)

        // A malformed success envelope without the handoff is not an accepted
        // restart: the process could not be terminated after Telegram sends.
        let incomplete = TelegramRestartBridgePrimitiveStub(
            response: .object(["status": .string("restarting")]),
            providesTerminationHandoff: false
        )
        let incompleteOutcome = try await telegramRestartDispatch(root: root, primitive: incomplete)
        #expect(incompleteOutcome.reply?.contains("Restart failed: restart handoff was incomplete") == true)
        #expect(incompleteOutcome.reply?.contains("Restarting NativeAgent") == false)
        #expect(incompleteOutcome.afterReplySent == nil)
        #expect(incomplete.terminationArms == 0)
    }
}
