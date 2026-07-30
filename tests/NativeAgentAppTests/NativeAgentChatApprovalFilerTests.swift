import ApprovalInbox
import ChatOrchestration
import Foundation
import NativeAgentCore
import Testing
@testable import NativeAgentApp

@Suite("NativeAgentChatApprovalFiler")
struct NativeAgentChatApprovalFilerTests {
    @Test func filesCanonicalNonBlockingApprovalWithCompleteReturnRoute() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("NativeAgentChatApprovalFiler-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let route = ChatToolSessionContext.ReplyRoute(
            surface: "slack",
            destinationId: "C123",
            threadId: "171234.50",
            sourceKey: "workspace-primary",
            replyTo: "message-9",
            correlationId: "correlation-7"
        )
        let filer = NativeAgentChatApprovalFiler(dataRoot: root)
        let approvalID = try await ChatToolSessionContext.$verifiedSessionId.withValue("session-1") {
            try await ChatToolSessionContext.$verifiedChatId.withValue("chat-2") {
                try await ChatToolSessionContext.$verifiedUserId.withValue("user-3") {
                    try await ChatToolSessionContext.$replyRoute.withValue(route) {
                        try await filer.fileApprovalRequest(
                            toolName: "external_send",
                            surface: "slack",
                            payload: .object(["message": .string("hello")]),
                            reason: "autonomy=confirm"
                        )
                    }
                }
            }
        }

        let record = try await SwiftNativeApprovalInbox(root: root).get(approvalID)
        #expect(record.action == "external_send")
        #expect(record.remoteResolvable)
        #expect(!record.localOnly)
        guard case .object(let payload) = record.payload,
              case .object(let origin)? = payload["origin"] else {
            Issue.record("expected canonical chat approval payload with origin")
            return
        }
        #expect(payload["kind"] == .string("chat_tool_approval"))
        #expect(payload["surface"] == .string("slack"))
        #expect(origin["sessionId"] == .string("session-1"))
        #expect(origin["chatId"] == .string("chat-2"))
        #expect(origin["userId"] == .string("user-3"))
        #expect(origin["destinationId"] == .string("C123"))
        #expect(origin["threadId"] == .string("171234.50"))
        #expect(origin["sourceKey"] == .string("workspace-primary"))
        #expect(origin["replyTo"] == .string("message-9"))
        #expect(origin["correlationId"] == .string("correlation-7"))

        let pending = await filer.pendingApprovalResult(
            id: approvalID,
            toolName: "external_send",
            surface: "slack",
            payload: .object([:]),
            reason: "autonomy=confirm"
        )
        guard case .object(let pendingObject) = pending,
              case .string(let detail)? = pendingObject["detail"] else {
            Issue.record("expected pending approval object")
            return
        }
        #expect(pendingObject["status"] == .string("waiting_approval"))
        #expect(detail.contains("has not run"))
    }
}
