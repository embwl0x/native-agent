import ApprovalInbox
import ChatOrchestration
import Foundation
import NativeAgentCore
import NativeAgentShared
import PersistenceCore
import Testing
@testable import NativeAgentApp

/// Wire expectations frozen from review-0414f (d150a75777f102375c6d823d95ad79fdc9696ab9):
/// NativeAgentChatApprovalFiler.fileApprovalRequest, NativeClient.swiftListApprovals,
/// ApprovalInbox.createUnlocked (4000 characters), TelegramApprovalFiler.preview/prompt (1400).
/// Compare UTF-8/encoded bytes, not the Mac card's independently formatted local summary.
struct ApprovalSurfaceParityTests {
    @Test func syncedAndTelegramBytesMatchReview0414f() async throws {
        let cases: [(String, JSONValue, JSONValue)] = [
            ("shell", .object(["command": .string("echo hello")]), .object(["command": .string("echo hello")])),
            ("mail_send", .object(["body": .string("Hello User")]), .object(["body": .string("Hello User")])),
            ("mail_send", .object(["body": .string(String(repeating: "é🙂", count: 3000))]),
             .object(["body": .string(String(repeating: "é🙂", count: 3000))])),
            ("mac_keystroke", .object(["text": .string("abc")]), .object([
                "text_character_count": .int(3), "text_redacted": .bool(true),
                "text_sha256": .string("ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
            ])),
        ]
        for (tool, input, expectedInput) in cases {
            for telegram in [false, true] {
                let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
                try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
                defer { try? FileManager.default.removeItem(at: root) }
                let reason = "autonomy=confirm"
                let capture = PromptCapture()
                let id = try await ChatToolSessionContext.$verifiedChatId.withValue("123") {
                    try await ChatToolSessionContext.$verifiedSessionId.withValue("parity-session") {
                        if telegram {
                            return try await TelegramApprovalFiler(dataRoot: root, token: "fixture", promptSender: {
                                _, _, record, name, payload in
                                await capture.set(TelegramApprovalFiler.approvalPromptText(
                                    approval: record, toolName: name, payload: payload))
                            }).fileApprovalRequest(toolName: tool, surface: "telegram", payload: input, reason: reason)
                        }
                        return try await NativeAgentChatApprovalFiler(dataRoot: root)
                            .fileApprovalRequest(toolName: tool, surface: "mac", payload: input, reason: reason)
                    }
                }
                var origin: [String: JSONValue] = [
                    "sessionId": .string("parity-session"), "chatId": .string("123"), "userId": .null,
                    "destinationId": .null, "threadId": .null, "sourceKey": .null,
                    "replyTo": .null, "correlationId": .null,
                ]
                if !telegram { origin["surface"] = .string("mac") }
                var metadata: [String: JSONValue] = [
                    "kind": .string("chat_tool_approval"), "toolName": .string(tool),
                    "surface": .string(telegram ? "telegram" : "mac"),
                    "input": expectedInput, "origin": .object(origin),
                ]
                if telegram {
                    metadata["telegram"] = .object([
                        "chatId": .string("123"), "threadId": .null, "sessionId": .string("parity-session")
                    ])
                }
                let record = try await SwiftNativeApprovalInbox(root: root).get(id)
                let expectedPayload = JSONValue.object(metadata)
                #expect(try record.payload.serializedData(pretty: false) == expectedPayload.serializedData(pretty: false))
                let preview = String(try expectedPayload.serialize(pretty: false).prefix(4000))
                #expect(Data(record.payloadPreview.utf8) == Data(preview.utf8))
                let rows = try await NativeClient(baseURL: "", dataRootOverride: root).swiftListApprovals()
                let actual = try #require(rows.first)
                // Same approval identity/timestamps; every other encoded field is the baseline contract.
                let expected = ApprovalRequest(
                    id: id, title: "Approve \(tool)", action: tool, risk: "confirm", reason: reason,
                    status: "pending", createdAt: record.createdAt, resolvedAt: nil, decision: nil,
                    payloadPreview: preview, localOnly: false, remoteResolvable: true,
                    chatOriginSessionId: "parity-session", lastRequestedAt: record.lastRequestedAt)
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.sortedKeys]
                #expect(try encoder.encode(actual) == encoder.encode(expected))
                if telegram {
                    let raw = try expectedInput.serialize(pretty: false).trimmingCharacters(in: .whitespacesAndNewlines)
                    let bounded = raw.count > 1400 ? String(raw.prefix(1400)) + "..." : raw
                    let expectedText = """
                    Approval required: \(tool)
                    ID: \(id)
                    Reason: \(reason)

                    \(bounded)

                    You can also reply with /approve \(id) or /deny \(id).
                    """
                    let text = try #require(await capture.text)
                    #expect(Data(text.utf8) == Data(expectedText.utf8))
                }
            }
        }
    }

    private actor PromptCapture {
        var text: String?
        func set(_ value: String) { text = value }
    }
}
