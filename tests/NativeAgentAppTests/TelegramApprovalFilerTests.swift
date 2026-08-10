import Foundation
import Testing
import ApprovalInbox
import ChatOrchestration
import NativeAgentCore
import PersistenceCore
import TelegramBot
@testable import NativeAgentApp

@Suite("TelegramApprovalFiler")
struct TelegramApprovalFilerTests {
    private struct DecisionCall: Equatable, Sendable {
        let id: String
        let decision: ApprovalDecision
    }

    private func tempRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("TelegramApprovalFiler-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    @Test func fileApprovalRequest_stagesInboxRecordAndSendsTelegramPrompt() async throws {
        let root = try tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        actor Capture {
            var prompt: (chatId: Int, approval: ApprovalRecord, toolName: String, payload: JSONValue)?
            private var decisions: [DecisionCall] = []

            func recordPrompt(chatId: Int, approval: ApprovalRecord, toolName: String, payload: JSONValue) {
                prompt = (chatId, approval, toolName, payload)
            }

            func recordDecision(id: String, decision: ApprovalDecision) {
                decisions.append(DecisionCall(id: id, decision: decision))
            }

            func decisionSnapshot() -> [DecisionCall] { decisions }
        }

        let capture = Capture()
        let filer = TelegramApprovalFiler(
            dataRoot: root,
            token: "test-token",
            promptSender: { _, chatId, approval, toolName, payload in
                await capture.recordPrompt(
                    chatId: chatId,
                    approval: approval,
                    toolName: toolName,
                    payload: payload
                )
            },
            approvalResolver: { id, decision in
                await capture.recordDecision(id: id, decision: decision)
                _ = try await SwiftNativeApprovalInbox(root: root)
                    .resolve(id, decision: decision, decidedBy: "telegram-test")
                try await NativeClient.annotateApprovalExecution(
                    id: id,
                    executedAction: .object([
                        "status": .string("committed"),
                        "payload": .object(["large": .string(String(repeating: "x", count: 400))]),
                    ]),
                    detail: "raw execution payload that must never be echoed to Telegram",
                    root: root
                )
            }
        )

        let approvalId = try await ChatToolSessionContext.$verifiedChatId.withValue("77") {
            try await ChatToolSessionContext.$verifiedUserId.withValue("11") {
                try await ChatToolSessionContext.$verifiedSessionId.withValue("telegram-session") {
                    try await filer.fileApprovalRequest(
                        toolName: "github_set_repo_visibility",
                        surface: "telegram",
                        payload: JSONValue.object(["visibility": .string("private")]),
                        reason: "autonomy=confirm"
                    )
                }
            }
        }

        guard let prompt = await capture.prompt else {
            Issue.record("expected Telegram prompt")
            return
        }
        #expect(prompt.chatId == 77)
        #expect(prompt.toolName == "github_set_repo_visibility")
        #expect(prompt.approval.id == approvalId)

        let record = try await SwiftNativeApprovalInbox(root: root).get(approvalId)
        #expect(record.action == "github_set_repo_visibility")
        #expect(record.remoteResolvable == true)
        #expect(record.localOnly == false)
        guard case .object(let payload) = record.payload else {
            Issue.record("expected object payload")
            return
        }
        #expect(payload["kind"] == JSONValue.string("chat_tool_approval"))
        #expect(payload["toolName"] == JSONValue.string("github_set_repo_visibility"))
        guard case .object(let telegram)? = payload["telegram"] else {
            Issue.record("expected telegram metadata")
            return
        }
        #expect(telegram["chatId"] == JSONValue.string("77"))
        #expect(telegram["sessionId"] == JSONValue.string("telegram-session"))
        guard case .object(let origin)? = payload["origin"] else {
            Issue.record("expected transport-authenticated origin metadata")
            return
        }
        #expect(origin["chatId"] == .string("77"))
        #expect(origin["userId"] == .string("11"))
        #expect(origin["sessionId"] == .string("telegram-session"))

        let reply = try await filer.resolveTelegramApproval(
            id: approvalId,
            decision: TelegramApprovalDecision.approved,
            chatId: 77,
            fromUserId: 11
        )
        #expect(reply.acknowledgement == "Approved and completed github_set_repo_visibility.")
        #expect(reply.continuationPrompt?.contains("approved tool has already run exactly once") == true)
        #expect(reply.continuationPrompt?.contains("do not repeat the tool call") == true)
        #expect(reply.continuationPrompt?.contains("raw execution payload") == false)
        #expect(await capture.decisionSnapshot() == [
            DecisionCall(id: approvalId, decision: .approved),
        ])
        let resolved = try await SwiftNativeApprovalInbox(root: root).get(approvalId)
        #expect(resolved.status == "resolved")
        #expect(resolved.decision == "approved")
    }

    @Test func applyResolvedChatToolApproval_replaysExactApprovedToolAndAnnotatesRecord() async throws {
        let root = try tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }

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
                "input": .object(["category": .string("core")]),
                "telegram": .object([
                    "chatId": .string("77"),
                    "sessionId": .string("telegram-session"),
                ]),
            ]),
            "remoteResolvable": .bool(true),
            "localOnly": .bool(false),
        ]))
        let resolved = try await inbox.resolve(
            approval.id,
            decision: .approved,
            decidedBy: "telegram-test"
        )

        await NativeClient.applyResolvedChatToolApproval(from: resolved, dataRoot: root)

        let annotated = try await inbox.get(approval.id)
        guard case .object(let executed)? = annotated.executedAction else {
            Issue.record("expected execution annotation")
            return
        }
        #expect(executed["op"] == .string("chat_tool_approval_replay"))
        #expect(executed["tool"] == .string("tool_catalog"))
        #expect(annotated.detail?.contains("tool_catalog executed after approval") == true)

        // The verified outcome is absorbed into the originating session once,
        // so a later turn knows approval already completed and does not retry.
        await NativeClient.ensureChatToolApprovalOutcomeReceipt(from: annotated, dataRoot: root)
        await NativeClient.ensureChatToolApprovalOutcomeReceipt(from: annotated, dataRoot: root)
        let transcript = try await SwiftNativePersistenceCore().readJSONL(
            root
                .appendingPathComponent("chat", isDirectory: true)
                .appendingPathComponent("messages", isDirectory: true)
                .appendingPathComponent("telegram-session.jsonl")
        )
        #expect(transcript.count == 1)
        guard case .object(let row) = transcript[0],
              case .object(let metadata)? = row["metadata"] else {
            Issue.record("expected canonical tool outcome receipt")
            return
        }
        #expect(row["role"] == .string("tool"))
        #expect(metadata["toolName"] == .string("tool_catalog"))
        #expect(metadata["approvalId"] == .string(approval.id))
        #expect(metadata["ok"] == .bool(true))
        guard case .string(let resultSummary)? = metadata["resultSummary"] else {
            Issue.record("expected verified replay result in continuity receipt")
            return
        }
        #expect(resultSummary.contains("Result:"))
        #expect(resultSummary.contains("\"available_tools\""))
    }

    @Test func applyResolvedChatToolApproval_acceptsCanonicalCrossSurfaceOrigin() async throws {
        let root = try tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let inbox = SwiftNativeApprovalInbox(root: root)
        let approval = try await inbox.create(.object([
            "title": .string("Approve tool_catalog"),
            "action": .string("tool_catalog"),
            "risk": .string("confirm"),
            "reason": .string("autonomy=confirm"),
            "payload": .object([
                "kind": .string("chat_tool_approval"),
                "toolName": .string("tool_catalog"),
                "surface": .string("slack"),
                "input": .object(["category": .string("core")]),
                "origin": .object([
                    "sessionId": .string("slack-session"),
                    "chatId": .string("C123"),
                    "userId": .string("U456"),
                    "destinationId": .string("C123"),
                    "threadId": .string("171234.50"),
                ]),
            ]),
            "remoteResolvable": .bool(true),
            "localOnly": .bool(false),
        ]))
        let resolved = try await inbox.resolve(
            approval.id,
            decision: .approved,
            decidedBy: "activity-test"
        )

        await NativeClient.applyResolvedChatToolApproval(from: resolved, dataRoot: root)

        let annotated = try await inbox.get(approval.id)
        guard case .object(let executed)? = annotated.executedAction else {
            Issue.record("expected cross-surface execution annotation")
            return
        }
        #expect(executed["op"] == .string("chat_tool_approval_replay"))
        #expect(executed["surface"] == .string("slack"))

        await NativeClient.ensureChatToolApprovalOutcomeReceipt(from: annotated, dataRoot: root)
        let transcript = try await SwiftNativePersistenceCore().readJSONL(
            root
                .appendingPathComponent("chat", isDirectory: true)
                .appendingPathComponent("messages", isDirectory: true)
                .appendingPathComponent("slack-session.jsonl")
        )
        #expect(transcript.count == 1)
    }

    @Test func reconcileApprovedPersonaReplay_recoversPriorDoubleApprovalFailureExactlyOnce() async throws {
        let root = try tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let persistence = SwiftNativePersistenceCore()
        try await persistence.writeJSON(
            .object([
                "permissionLevel": .string("full_mac_os"),
                "developerMode": .bool(true),
                "filePolicy": .object(["outsideWorkspaceDefault": .string("allow")]),
            ]),
            to: root
                .appendingPathComponent("trust", isDirectory: true)
                .appendingPathComponent("policy.json")
        )
        try await persistence.writeJSON(
            .object([
                "bot_token": .string("redacted"),
                "allowed_chat_ids": .array([.int(77)]),
                "allowed_user_ids": .array([.int(11)]),
            ]),
            to: root
                .appendingPathComponent("telegram", isDirectory: true)
                .appendingPathComponent("config.json")
        )
        let personaRoot = root.appendingPathComponent("persona", isDirectory: true)
        try FileManager.default.createDirectory(at: personaRoot, withIntermediateDirectories: true)
        let soul = personaRoot.appendingPathComponent("SOUL.md")
        try "# Soul\n".write(to: soul, atomically: true, encoding: .utf8)

        let input: [String: JSONValue] = [
            "kind": .string("soul"),
            "title": .string("User-approved identity note"),
            "content": .string("Carry this bounded note forward."),
        ]
        let inbox = SwiftNativeApprovalInbox(root: root)
        let approval = try await inbox.create(.object([
            "title": .string("Approve persona update"),
            "action": .string("persona_append_section"),
            "risk": .string("confirm"),
            "reason": .string("autonomy=confirm source=dynamic_persona_guard"),
            "payload": .object([
                "kind": .string("chat_tool_approval"),
                "toolName": .string("persona_append_section"),
                "surface": .string("telegram"),
                "input": .object(input),
                "origin": .object([
                    "sessionId": .string("telegram-session"),
                    "chatId": .string("77"),
                    "userId": .string("11"),
                ]),
            ]),
            "remoteResolvable": .bool(true),
            "localOnly": .bool(false),
        ]))
        _ = try await inbox.resolve(
            approval.id,
            decision: .approved,
            decidedBy: "telegram-test"
        )
        try await NativeClient.annotateApprovalExecution(
            id: approval.id,
            executedAction: .object([
                "op": .string("chat_tool_approval_replay"),
                "tool": .string("persona_append_section"),
                "surface": .string("telegram"),
                "status": .string("failed"),
                "error": .string(
                    "tool denied: approval required, no filer is available on this noninteractive surface: "
                        + "autonomy=confirm source=dynamic_persona_guard"
                ),
            ]),
            detail: "persona_append_section approved replay FAILED",
            root: root
        )
        let failed = try await inbox.get(approval.id)
        await NativeClient.ensureChatToolApprovalOutcomeReceipt(from: failed, dataRoot: root)

        await NativeClient.reconcileUnappliedChatToolApprovalExecutions(dataRoot: root)
        await NativeClient.reconcileUnappliedChatToolApprovalExecutions(dataRoot: root)

        let healed = try await inbox.get(approval.id)
        guard case .object(let executed)? = healed.executedAction else {
            Issue.record("expected healed execution annotation")
            return
        }
        if executed["status"] != .string("succeeded") {
            Issue.record("replay did not heal: \(healed.detail ?? String(describing: executed))")
        }

        let body = try String(contentsOf: soul, encoding: .utf8)
        #expect(body.components(separatedBy: "## User-approved identity note").count == 2)
        #expect(body.contains("Carry this bounded note forward."))
        #expect(executed["status"] == .string("succeeded"))

        let transcript = try await persistence.readJSONL(
            root
                .appendingPathComponent("chat", isDirectory: true)
                .appendingPathComponent("messages", isDirectory: true)
                .appendingPathComponent("telegram-session.jsonl")
        )
        #expect(transcript.count == 1)
        guard case .object(let row) = transcript[0],
              case .object(let metadata)? = row["metadata"] else {
            Issue.record("expected healed canonical approval receipt")
            return
        }
        #expect(metadata["approvalId"] == .string(approval.id))
        #expect(metadata["ok"] == .bool(true))
    }
}
