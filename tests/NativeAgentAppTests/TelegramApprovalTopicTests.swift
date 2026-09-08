import Foundation
import Testing
import ApprovalInbox
import PersistenceCore
@testable import NativeAgentApp

// Agent's review of the 2026-09-07 Telegram approval fix: one validated parser
// for the recorded topic, and routing validation before the resolver acts.
@Suite("TelegramApproval recorded topic")
struct TelegramApprovalTopicTests {
    private func payload(threadId: JSONValue?) -> JSONValue {
        var telegram: [String: JSONValue] = ["chatId": .string("77")]
        if let threadId { telegram["threadId"] = threadId }
        return .object(["kind": .string("chat_tool_approval"), "telegram": .object(telegram)])
    }

    @Test func absentAndValidTopics() {
        #expect(TelegramApprovalFiler.recordedTopic(payload(threadId: nil)) == .absent)
        #expect(TelegramApprovalFiler.recordedTopic(payload(threadId: .null)) == .absent)
        #expect(TelegramApprovalFiler.recordedTopic(payload(threadId: .string("   "))) == .absent)
        #expect(TelegramApprovalFiler.recordedTopic(payload(threadId: .int(10))) == .topic(10))
        #expect(TelegramApprovalFiler.recordedTopic(payload(threadId: .string(" 20 "))) == .topic(20))
        #expect(TelegramApprovalFiler.recordedTopic(payload(threadId: .double(30))) == .topic(30))
    }

    @Test(arguments: [
        JSONValue.double(1e100), .double(10.5), .bool(true), .object([:]), .array([]), .string("topic-a"),
    ])
    func malformedTopicsAreNeverGeneral(value: JSONValue) {
        guard case .malformed = TelegramApprovalFiler.recordedTopic(payload(threadId: value)) else {
            Issue.record("\(value) must be malformed, not absent (General) or a truncated topic")
            return
        }
    }

    @Test func malformedTopicIsRefusedBeforeTheResolverActs() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("TelegramApprovalTopic-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let inbox = SwiftNativeApprovalInbox(root: root)
        let approval = try await inbox.create(.object([
            "title": .string("Approve tool_catalog"),
            "action": .string("tool_catalog"),
            "risk": .string("confirm"),
            "reason": .string("autonomy=confirm"),
            "payload": .object([
                "kind": .string("chat_tool_approval"),
                "toolName": .string("tool_catalog"),
                "surface": .string("telegram"),
                "input": .object([:]),
                "telegram": .object(["chatId": .string("77"), "threadId": .double(1e100)]),
                "origin": .object(["chatId": .string("77"), "userId": .string("11")]),
            ]),
            "remoteResolvable": .bool(true),
            "localOnly": .bool(false),
        ]))
        actor Spy { var calls = 0; func hit() { calls += 1 } }
        let spy = Spy()
        let filer = TelegramApprovalFiler(
            dataRoot: root,
            token: "test-token",
            promptSender: { _, _, _, _, _ in },
            approvalResolver: { _, _, _ in await spy.hit() }
        )
        await #expect(throws: (any Error).self) {
            _ = try await filer.resolveTelegramApproval(
                id: approval.id, decision: .approved, chatId: 77, fromUserId: 11
            )
        }
        #expect(await spy.calls == 0)
        #expect(try await inbox.get(approval.id).status == "pending")
    }
}
