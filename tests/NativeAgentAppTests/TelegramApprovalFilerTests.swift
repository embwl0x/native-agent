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
    @Test("evicted retry IDs cannot starve retained failed receipts")
    func launchCursorPrunesEvictedRetries() async throws {
        let root = try tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let inbox = SwiftNativeApprovalInbox(root: root)
        let seed = try await inbox.create(.object([
            "title": .string("fixture"), "action": .string("tool_catalog"),
            "risk": .string("confirm"), "reason": .string("fixture"),
            "payload": .object([:]),
        ]))
        let row = try await inbox.resolve(seed.id, decision: .approved, decidedBy: "fixture")
        var cursor = NativeClient.ApprovalReconciliationCursor()
        cursor.stamp = "9999"
        cursor.retry = (0..<300).map { "evicted-\($0)" } + [row.id]
        try JSONEncoder().encode(cursor).write(to: NativeClient.ApprovalReconciliationCursor.path(root))
        let selected = await NativeClient.resolvedApprovalsForReconciliation(dataRoot: root)
        #expect(selected.map(\.id) == [row.id])
        await NativeClient.checkpointApprovalReconciliation(dataRoot: root, records: selected, retry: [row.id])
        #expect(try NativeClient.ApprovalReconciliationCursor.read(root).retry == [row.id])
        #expect(await NativeClient.resolvedApprovalsForReconciliation(dataRoot: root).map(\.id) == [row.id])
    }

    @Test("launch cursor reaches an oversized inbox and retains failed receipts")
    func launchCursorReachesAllRows() async throws {
        let root = try tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let inbox = SwiftNativeApprovalInbox(root: root)
        let seed = try await inbox.create(.object([
            "title": .string("fixture"), "action": .string("tool_catalog"),
            "risk": .string("confirm"), "reason": .string("fixture"),
            "payload": .object([:]),
        ]))
        var template = try await inbox.resolve(seed.id, decision: .approved, decidedBy: "fixture")
        template.executedAction = .object(["status": .string("succeeded")])
        var rows: [JSONValue] = []
        for index in 0...300 {
            var row = template
            row.id = String(format: "%04d", index)
            // Equal timestamps exercise the persisted boundary identities.
            rows.append(row.toJSON())
        }
        let path = root.appendingPathComponent("workflows/approvals/requests.json")
        try JSONValue.array(rows.reversed()).serializedData(pretty: false).write(to: path)
        let first = await NativeClient.resolvedApprovalsForReconciliation(dataRoot: root)
        #expect(first.count == 300)
        #expect(first.first?.id == "0000")
        await NativeClient.checkpointApprovalReconciliation(dataRoot: root, records: first, retry: ["0000"])
        let next = await NativeClient.resolvedApprovalsForReconciliation(dataRoot: root)
        #expect(Set(next.map(\.id)) == ["0000", "0300"])
        await NativeClient.checkpointApprovalReconciliation(dataRoot: root, records: next)
        #expect(await NativeClient.resolvedApprovalsForReconciliation(dataRoot: root).isEmpty)

        // An old card resolved after the cursor still needs its effect.
        var late = template
        late.id = "late"
        late.createdAt = "2000-01-01T00:00:00.000+00:00"
        late.resolvedAt = "2099-01-01T00:00:00.000+00:00"
        late.executedAction = nil
        rows.append(late.toJSON())
        try JSONValue.array(rows).serializedData(pretty: false).write(to: path)
        let later = await NativeClient.resolvedApprovalsForReconciliation(dataRoot: root)
        #expect(later.map(\.id) == ["late"])
        await NativeClient.checkpointApprovalReconciliation(dataRoot: root, records: later)
        #expect(await NativeClient.resolvedApprovalsForReconciliation(dataRoot: root).map(\.id) == ["late"])
    }

    @Test("launch cursor includes concurrent resolutions below the page's UUID maximum")
    func launchCursorKeepsTimestampBoundaryOpen() async throws {
        let root = try tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let inbox = SwiftNativeApprovalInbox(root: root)
        let seed = try await inbox.create(.object([
            "title": .string("fixture"), "action": .string("tool_catalog"),
            "risk": .string("confirm"), "reason": .string("fixture"),
            "payload": .object([:]),
        ]))
        var row = try await inbox.resolve(seed.id, decision: .approved, decidedBy: "fixture")
        row.id = "z"
        row.executedAction = .object(["status": .string("succeeded")])
        let path = root.appendingPathComponent("workflows/approvals/requests.json")
        var rows = [row.toJSON()]
        try JSONValue.array(rows).serializedData(pretty: false).write(to: path)
        let page = await NativeClient.resolvedApprovalsForReconciliation(dataRoot: root)
        #expect(page.map(\.id) == ["z"])

        // Resolve another row between selection and checkpoint, at the same
        // timestamp but below its maximum UUID. Only selected IDs are consumed.
        row.id = "m"
        rows.append(row.toJSON())
        try JSONValue.array(rows).serializedData(pretty: false).write(to: path)
        await NativeClient.checkpointApprovalReconciliation(dataRoot: root, records: page)
        // A third resolution arrives after the checkpoint, still at that stamp.
        row.id = "a"
        rows.append(row.toJSON())
        try JSONValue.array(rows).serializedData(pretty: false).write(to: path)
        let next = await NativeClient.resolvedApprovalsForReconciliation(dataRoot: root)
        #expect(next.map(\.id) == ["a", "m"])
        await NativeClient.checkpointApprovalReconciliation(dataRoot: root, records: next)
        #expect(await NativeClient.resolvedApprovalsForReconciliation(dataRoot: root).isEmpty)

        // Legacy cursors have no consumed boundary IDs: revisit the equal stamp.
        try JSONValue.object([
            "stamp": .string(try #require(row.resolvedAt)),
            "id": .string("z"), "retry": .array([]),
        ]).serializedData(pretty: false).write(to: NativeClient.ApprovalReconciliationCursor.path(root))
        #expect(await NativeClient.resolvedApprovalsForReconciliation(dataRoot: root).map(\.id) == ["a", "m", "z"])
    }

    private actor Continuations {
        var calls: [(URL, String, String)] = []
        func record(_ root: URL, _ session: String, _ prompt: String) {
            calls.append((root, session, prompt))
        }
    }

    @Test(arguments: ["succeeded", "failed", "cancelled", "timed_out", "outcome_unknown"])
    func macApprovalContinuesOnceAcrossReconcileAndReceiptHealing(status: String) async throws {
        let root = try tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let inbox = SwiftNativeApprovalInbox(root: root)
        let approval = try await inbox.create(.object([
            "title": .string("Approve tool_catalog"), "action": .string("tool_catalog"),
            "risk": .string("confirm"), "reason": .string("fixture"),
            "payload": .object([
                "kind": .string("chat_tool_approval"), "toolName": .string("tool_catalog"),
                "surface": .string("chat"), "input": .object([:]),
                "origin": .object(["sessionId": .string("mac-session")]),
            ]),
        ]))
        _ = try await inbox.resolve(approval.id, decision: .approved, decidedBy: "fixture")
        try await NativeClient.annotateApprovalExecution(
            id: approval.id, executedAction: .object([
                "status": .string(status), "resultPreview": .string("Receipt evidence"),
            ]), detail: "fixture", root: root)
        let capture = Continuations()
        let continuation: NativeClient.ChatApprovalContinuation = { root, session, prompt in
            await capture.record(root, session, prompt)
        }
        let resolved = try await inbox.get(approval.id)
        async let first = NativeClient.ensureChatToolApprovalOutcomeReceipt(
            from: resolved, dataRoot: root, continuation: continuation)
        async let second = NativeClient.ensureChatToolApprovalOutcomeReceipt(
            from: resolved, dataRoot: root, continuation: continuation)
        _ = await (first, second)
        // New readers use only persisted state, as after relaunch. Healing must
        // update the one receipt without losing its continuation claim.
        try await NativeClient.annotateApprovalExecution(
            id: approval.id, executedAction: .object(["status": .string("succeeded")]),
            detail: "healed", root: root)
        await NativeClient.reconcileUnappliedChatToolApprovalExecutions(dataRoot: root, continuation: continuation)
        try FileManager.default.removeItem(at: root.appendingPathComponent("chat/messages/mac-session.jsonl"))
        await NativeClient.reconcileUnappliedChatToolApprovalExecutions(dataRoot: root, continuation: continuation)
        let calls = await capture.calls
        #expect(calls.count == 1)
        #expect(calls.first?.0 == root)
        #expect(calls.first?.1 == "mac-session")
        #expect(calls.first?.2.contains("Receipt evidence") == true)
        #expect(calls.first?.2.contains(status) == true)
        let rows = try await SwiftNativePersistenceCore().readJSONL(root.appendingPathComponent("chat/messages/mac-session.jsonl"))
        #expect(rows.count == 1, "no app-authored assistant or user message")
        guard case .object(let row)? = rows.first,
              case .object(let metadata)? = row["metadata"] else {
            Issue.record("expected receipt")
            return
        }
        #expect(row["role"] == .string("tool"))
        #expect(metadata["ok"] == .bool(true))
        let saved = try await inbox.get(approval.id)
        guard case .object(let state)? = saved.chatContinuation else {
            Issue.record("expected durable continuation state")
            return
        }
        #expect(state["done"] == .bool(true))
    }

    @Test(arguments: [300.0, 601.0, 18_000.0])
    func launchContinuationUsesResolutionAge(age: TimeInterval) async throws {
        let root = try tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let inbox = SwiftNativeApprovalInbox(root: root)
        let approval = try await inbox.create(.object([
            "title": .string("Approve tool_catalog"), "action": .string("tool_catalog"),
            "risk": .string("confirm"), "reason": .string("fixture"),
            "payload": .object([
                "kind": .string("chat_tool_approval"), "toolName": .string("tool_catalog"),
                "surface": .string("chat"), "input": .object([:]),
                "origin": .object(["sessionId": .string("historical-session")]),
            ]),
        ]))
        _ = try await inbox.resolve(approval.id, decision: .approved, decidedBy: "fixture")
        var resolved = try await inbox.annotateExecution(
            approval.id, executedAction: .object(["status": .string("succeeded")]), detail: "fixture")
        resolved.createdAt = NativeTimestampFormat.fractionalUTCOffset(Date(timeIntervalSince1970: 0))
        resolved.resolvedAt = NativeTimestampFormat.fractionalUTCOffset(Date().addingTimeInterval(-age))
        let persistence = SwiftNativePersistenceCore()
        try await persistence.writeJSON(.array([resolved.toJSON()]), to: inbox.approvalsPath)
        let transcript = root.appendingPathComponent("chat/messages/historical-session.jsonl")
        let sessions = root.appendingPathComponent("chat/sessions.json")
        let oldReply: JSONValue = .object([
            "role": .string("assistant"), "content": .string("Old reply"),
            "createdAt": .string(resolved.createdAt),
        ])
        let newerReply: JSONValue = .object([
            "role": .string("assistant"), "content": .string("Newer reply"),
            "createdAt": .string(NativeTimestampFormat.fractionalZulu(Date())),
        ])
        try await persistence.appendJSONL(oldReply, to: transcript)
        try await persistence.appendJSONL(newerReply, to: transcript)
        try await persistence.writeJSON(.array([.object([
            "id": .string("historical-session"), "updatedAt": .string(resolved.createdAt),
        ])]), to: sessions)
        let originalSessions = try Data(contentsOf: sessions)
        let capture = Continuations()
        let continuation: NativeClient.ChatApprovalContinuation = { root, session, prompt in
            await capture.record(root, session, prompt)
        }
        await NativeClient.reconcileUnappliedChatToolApprovalExecutions(dataRoot: root, continuation: continuation)
        await NativeClient.reconcileUnappliedChatToolApprovalExecutions(dataRoot: root, continuation: continuation)
        #expect(await capture.calls.count == (age <= 600 ? 1 : 0))
        let saved = try await inbox.get(approval.id)
        guard case .object(let state)? = saved.chatContinuation else {
            Issue.record("expected durable continuation state")
            return
        }
        #expect(state["done"] == .bool(true))
        // 2026-09-19: historical approvals still need their missing tool
        // receipt; recovery must not start a new conversation or reorder it.
        let messages = try await persistence.readJSONL(transcript)
        #expect(messages.count == 3)
        #expect(messages.first == oldReply)
        guard case .object(let receipt) = messages[age > 600 ? 1 : 2] else {
            Issue.record("expected recovered tool receipt")
            return
        }
        #expect(receipt["role"] == .string("tool"))
        if age > 600 {
            #expect(messages.last == newerReply)
            #expect(receipt["createdAt"] == .string(resolved.resolvedAt!))
            #expect(state["started"] == nil)
            #expect(try Data(contentsOf: sessions) == originalSessions)
        }
    }

    @Test
    func interruptedMacContinuationNeverRepeatsOnLaunch() async throws {
        let root = try tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let inbox = SwiftNativeApprovalInbox(root: root)
        let approval = try await inbox.create(.object([
            "title": .string("Approve tool_catalog"), "action": .string("tool_catalog"),
            "risk": .string("confirm"), "reason": .string("fixture"),
            "payload": .object([
                "kind": .string("chat_tool_approval"), "toolName": .string("tool_catalog"),
                "surface": .string("chat"), "input": .object([:]),
                "origin": .object(["sessionId": .string("retry-session")]),
            ]),
        ]))
        _ = try await inbox.resolve(approval.id, decision: .approved, decidedBy: "fixture")
        let resolved = try await inbox.annotateExecution(
            approval.id, executedAction: .object(["status": .string("succeeded")]), detail: "fixture")
        let capture = Continuations()
        let failing: NativeClient.ChatApprovalContinuation = { root, session, prompt in
            await capture.record(root, session, prompt)
            throw CancellationError()
        }
        await NativeClient.ensureChatToolApprovalOutcomeReceipt(from: resolved, dataRoot: root, continuation: failing)
        await NativeClient.reconcileUnappliedChatToolApprovalExecutions(dataRoot: root, continuation: failing)
        #expect(await capture.calls.count == 1, "a recent failure must not retry")

        // Simulate elapsed time across relaunch without sleeping or calling a provider.
        func ageClaim() async throws {
            var saved = try await inbox.get(approval.id)
            guard case .object(var state)? = saved.chatContinuation else {
                Issue.record("missing continuation claim")
                return
            }
            state["started"] = .string(NativeTimestampFormat.fractionalUTCOffset(Date(timeIntervalSince1970: 0)))
            saved.chatContinuation = .object(state)
            try await SwiftNativePersistenceCore().writeJSON(.array([saved.toJSON()]), to: inbox.approvalsPath)
        }
        try await ageClaim()
        await NativeClient.ensureChatToolApprovalOutcomeReceipt(from: resolved, dataRoot: root, continuation: failing)
        #expect(await capture.calls.count == 1, "ordinary receipt healing must not retry")
        let retry: NativeClient.ChatApprovalContinuation = { root, session, prompt in
            await capture.record(root, session, prompt)
            throw CancellationError()
        }
        async let first = NativeClient.reconcileUnappliedChatToolApprovalExecutions(dataRoot: root, continuation: retry)
        async let second = NativeClient.reconcileUnappliedChatToolApprovalExecutions(dataRoot: root, continuation: retry)
        _ = await (first, second)
        #expect(await capture.calls.count == 1)
        try await ageClaim()
        try FileManager.default.removeItem(at: root.appendingPathComponent("chat/messages/retry-session.jsonl"))
        await NativeClient.reconcileUnappliedChatToolApprovalExecutions(dataRoot: root, continuation: retry)
        #expect(await capture.calls.count == 1, "an interrupted turn remains consumed")
        let saved = try await inbox.get(approval.id)
        guard case .object(let state)? = saved.chatContinuation else { return }
        #expect(state["retried"] == nil)
        #expect(state["started"] != nil)
        let rows = try await SwiftNativePersistenceCore().readJSONL(root.appendingPathComponent("chat/messages/retry-session.jsonl"))
        #expect(rows.count == 1)
    }

    @Test(arguments: ["chat", "telegram", "slack", "no-session", "denied"])
    func macApprovalContinuationRequiresApprovedMacChatOrigin(origin: String) async throws {
        let root = try tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let inbox = SwiftNativeApprovalInbox(root: root)
        let approval = try await inbox.create(.object([
            "title": .string("Approve tool_catalog"), "action": .string("tool_catalog"),
            "risk": .string("confirm"), "reason": .string("fixture"),
            "payload": .object([
                "kind": .string("chat_tool_approval"), "toolName": .string("tool_catalog"),
                "surface": .string(origin == "telegram" || origin == "slack" ? origin : "chat"),
                "input": .object(["category": .string("core")]),
                "origin": .object(origin == "no-session" ? [:] : ["sessionId": .string("fixture-session")]),
            ]),
        ]))
        let resolved = try await inbox.resolve(
            approval.id, decision: origin == "denied" ? .denied : .approved, decidedBy: "fixture")
        let capture = Continuations()
        let continuation: NativeClient.ChatApprovalContinuation = { root, session, prompt in
            await capture.record(root, session, prompt)
        }
        await NativeClient.applyResolvedChatToolApproval(from: resolved, dataRoot: root, continuation: continuation)
        await NativeClient.reconcileUnappliedChatToolApprovalExecutions(dataRoot: root, continuation: continuation)
        let calls = await capture.calls
        #expect(calls.count == (origin == "chat" ? 1 : 0))
        if origin == "chat" {
            #expect(calls.first?.2.contains("unknown_category") == true)
        }
    }

    @Test func approvalContinuationCannotDispatchTools() async throws {
        let tools = NativeClient.ApprovalReceiptTools()
        #expect(try await tools.listAvailableTools().isEmpty)
        #expect(try await tools.listAvailableToolSchemas().isEmpty)
        await #expect(throws: AutonomyGateError.self) {
            _ = try await tools.dispatch(tool: "tool_catalog", input: [:], surface: "chat")
        }
    }

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
            approvalResolver: { id, decision, provenance in
                await capture.recordDecision(id: id, decision: decision)
                _ = try await SwiftNativeApprovalInbox(root: root)
                    .resolve(id, decision: decision, provenance: provenance)
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
        #expect(resolved.decidedBy == "telegram_verified_user")
        #expect(resolved.resolutionProvenance == .telegram(chatID: "77", userID: "11"))
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
        // Category-scoped discovery rejects unknown categories; `core` is not
        // a tool_load category, so this replay truthfully reports failure.
        #expect(metadata["ok"] == .bool(false))
        guard case .string(let resultSummary)? = metadata["resultSummary"] else {
            Issue.record("expected verified replay result in continuity receipt")
            return
        }
        // The summary is the dispatch envelope; the prose (and the redacted
        // body inside it) lives in `detail`, where its quotes are escaped.
        guard case .object(let parsed)? = try? JSONValue.parse(Data(resultSummary.utf8)),
              case .string(let detail)? = parsed["detail"] else {
            Issue.record("expected an envelope-shaped result summary")
            return
        }
        #expect(detail.contains("Result:"))
        #expect(detail.contains("\"unknown_category\""))
        #expect(detail.contains("\"known_categories\""))
    }

    @Test(arguments: ["queued", "scheduled", "accepted", "started", "pending", "loaded", "deleted", "saved", "cancelled", "timed_out", "outcome_unknown", "succeeded"])
    func approvalOutcomeReceiptPreservesExactClassThroughReplacement(status: String) async throws {
        let root = try tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let inbox = SwiftNativeApprovalInbox(root: root)
        let session = "approval-outcome-fixture"
        let approval = try await inbox.create(.object([
            "title": .string("Approve fixture"), "action": .string("tool_catalog"),
            "risk": .string("confirm"), "reason": .string("fixture"),
            "payload": .object([
                "kind": .string("chat_tool_approval"), "toolName": .string("tool_catalog"),
                "surface": .string("telegram"), "input": .object([:]),
                "telegram": .object(["chatId": .string("77"), "sessionId": .string(session)]),
            ]),
        ]))
        _ = try await inbox.resolve(approval.id, decision: .approved, decidedBy: "fixture")
        let persistence = SwiftNativePersistenceCore()
        let messages = root.appendingPathComponent("chat/messages", isDirectory: true)
        try FileManager.default.createDirectory(at: messages, withIntermediateDirectories: true)
        let transcript = messages.appendingPathComponent("\(session).jsonl")
        try await persistence.appendJSONL(.object([
            "id": .string("pending-row"), "createdAt": .string("2026-08-30T18:00:00Z"),
            "role": .string("tool"), "content": .string(""),
            "metadata": .object([
                "kind": .string(ChatTranscriptToolMessageKind.approvalPending),
                "approvalId": .string(approval.id), "resultClass": .string("unknown"),
            ]),
        ]), to: transcript)

        // This is the same projection called immediately after actual dispatch,
        // not a hand-built executedAction. Only a bounded redacted preview persists.
        let receipt = NativeClient.chatToolApprovalExecutionReceipt(
            toolName: "tool_catalog", surface: "telegram",
            result: .object(["status": .string(status), "detail": .string(String(repeating: "x", count: 4_000))]))
        #expect(receipt.preview.count <= 1_403)
        guard case .object(var action) = receipt.action else {
            Issue.record("expected execution annotation")
            return
        }
        let expectedClass: String
        let expectedPrefix: String
        switch status {
        case "cancelled": (expectedClass, expectedPrefix) = ("cancelled", "Cancelled")
        case "timed_out": (expectedClass, expectedPrefix) = ("timeout", "Timed out")
        case "succeeded", "loaded", "deleted", "saved": (expectedClass, expectedPrefix) = ("succeeded", "Completed")
        default: (expectedClass, expectedPrefix) = ("unknown", "Outcome unconfirmed")
        }
        #expect(action["resultClass"] == .string(expectedClass))

        // New annotations carry the class; old ones retain only canonical status.
        // Both replace the same pending row and remain idempotent on replay.
        for legacy in [false, true] {
            if legacy { action["resultClass"] = nil }
            try await NativeClient.annotateApprovalExecution(
                id: approval.id, executedAction: .object(action), detail: "fixture result", root: root)
            let annotated = try await inbox.get(approval.id)
            await NativeClient.ensureChatToolApprovalOutcomeReceipt(from: annotated, dataRoot: root)
            await NativeClient.ensureChatToolApprovalOutcomeReceipt(from: annotated, dataRoot: root)
            let rows = try await persistence.readJSONL(transcript)
            #expect(rows.count == 1)
            guard case .object(let row)? = rows.first,
                  case .object(let metadata)? = row["metadata"],
                  case .string(let summary)? = metadata["resultSummary"] else {
                Issue.record("expected settled tool receipt")
                return
            }
            #expect(row["id"] == .string("pending-row"))
            #expect(row["createdAt"] == .string("2026-08-30T18:00:00Z"))
            #expect(metadata["kind"] == .string(ChatTranscriptToolMessageKind.toolUse))
            #expect(metadata["resultClass"] == .string(expectedClass))
            // 2026-09-13: the receipt is the dispatch envelope the transcript's
            // readers parse, with the prose kept in `detail`. Prose alone
            // classified as "completion not confirmed" and showed nothing.
            guard case .object(let parsed)? = try? JSONValue.parse(Data(summary.utf8)),
                  case .string(let detail)? = parsed["detail"] else {
                Issue.record("expected an envelope-shaped result summary")
                return
            }
            #expect(parsed["status"] == .string(expectedClass == "succeeded" ? "succeeded" : status))
            #expect(detail.hasPrefix("\(expectedPrefix) after approval"))
            #expect(detail.contains("Completed after approval") == (expectedClass == "succeeded"))
            // 2026-09-13: only confirmed outcomes carry an ok bit. A timeout
            // is failure; cancelled and unknown are neither success nor failure.
            let expectedOK: JSONValue? = expectedClass == "succeeded" ? .bool(true)
                : status == "timed_out" ? .bool(false) : nil
            #expect(metadata["ok"] == expectedOK)
        }
    }

    @Test func approvalExecutionProjectionUsesOriginalOutcomeBeforePreview() {
        let explicitFailure = NativeClient.chatToolApprovalExecutionReceipt(
            toolName: "tool_catalog", surface: "chat",
            result: .object(["status": .string("succeeded"), "ok": .bool(false)]))
        guard case .object(let action) = explicitFailure.action else {
            Issue.record("expected execution annotation")
            return
        }
        #expect(action["resultClass"] == .string("failed"),
                "the original result's explicit failure must not collapse to its status string")
        let legacy = NativeClient.chatToolApprovalExecutionReceipt(
            toolName: "tool_catalog", surface: "chat", result: .object(["ok": .bool(true)]))
        guard case .object(let legacyAction) = legacy.action else {
            Issue.record("expected legacy execution annotation")
            return
        }
        #expect(legacyAction["resultClass"] == .string("succeeded"),
                "a status-less result still carries evidence; the class is retained from it")
        #expect(legacyAction["status"] == .string("succeeded"))
        let noEvidence = NativeClient.chatToolApprovalExecutionReceipt(
            toolName: "tool_catalog", surface: "chat", result: .object([:]))
        guard case .object(let unknownAction) = noEvidence.action else {
            Issue.record("expected execution annotation")
            return
        }
        #expect(unknownAction["resultClass"] == .string("unknown"))
        #expect(unknownAction["status"] == .string("outcome_unknown"),
                "missing evidence must never be recorded as a success")
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

    // 2026-09-06: the verifier admits this historical pre-dispatch failure.
    // Healing must execute once and replace the receipt, while a Mac follow-up
    // already started for the failure must not speak a second time.
    @Test(arguments: ["telegram", "chat"])
    func reconcileApprovedPersonaReplay_recoversPriorDoubleApprovalFailureExactlyOnce(surface: String) async throws {
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
            // Persona writes are lazy tools. Approved replay must bind this
            // exact approved tool turn-locally even when the source session no
            // longer has a persisted loadout.
            "session_id": .string("telegram-session"),
        ]
        #expect(await ActiveToolsStore(dataRoot: root)
            .load(sessionId: "telegram-session").activeTools.isEmpty)
        let inbox = SwiftNativeApprovalInbox(root: root)
        let approval = try await inbox.create(.object([
            "title": .string("Approve persona update"),
            "action": .string("persona_append_section"),
            "risk": .string("confirm"),
            "reason": .string("autonomy=confirm source=dynamic_persona_guard"),
            "payload": .object([
                "kind": .string("chat_tool_approval"),
                "toolName": .string("persona_append_section"),
                "surface": .string(surface),
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
        let capture = Continuations()
        let continuation: NativeClient.ChatApprovalContinuation = { root, session, prompt in
            await capture.record(root, session, prompt)
        }
        await NativeClient.ensureChatToolApprovalOutcomeReceipt(from: failed, dataRoot: root, continuation: continuation)

        await NativeClient.reconcileUnappliedChatToolApprovalExecutions(dataRoot: root, continuation: continuation)
        await NativeClient.reconcileUnappliedChatToolApprovalExecutions(dataRoot: root, continuation: continuation)
        #expect(await capture.calls.count == (surface == "chat" ? 1 : 0))

        let healed = try await inbox.get(approval.id)
        guard case .object(let executed)? = healed.executedAction else {
            Issue.record("expected healed execution annotation")
            return
        }
        // The raw tool annotation preserves the persona owner's terminal status;
        // the canonical approval receipt below classifies it as success.
        if executed["status"] != .string("saved") || executed["resultClass"] != .string("succeeded") {
            Issue.record("replay did not heal: \(healed.detail ?? String(describing: executed))")
        }

        let body = try String(contentsOf: soul, encoding: .utf8)
        #expect(body.components(separatedBy: "## User-approved identity note").count == 2)
        #expect(body.contains("Carry this bounded note forward."))
        #expect(executed["status"] == .string("saved"))
        #expect(executed["resultClass"] == .string("succeeded"))
        #expect(await ActiveToolsStore(dataRoot: root)
            .load(sessionId: "telegram-session").activeTools.isEmpty,
            "approved replay must not persist or broaden the source session loadout")

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
