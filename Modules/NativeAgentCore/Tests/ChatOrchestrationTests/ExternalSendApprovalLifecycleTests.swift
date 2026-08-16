import Foundation
import Testing
import ApprovalInbox
import NativeAgentCore
import PersistenceCore
@testable import ChatOrchestration

private func makeExternalSendTempRoot(_ label: String) throws -> URL {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("ExternalSendApproval-\(label)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}

private func writeAgentMailFixtureConfig(_ root: URL) throws {
    let path = root
        .appendingPathComponent("secrets", isDirectory: true)
        .appendingPathComponent("agentmail.json")
    try FileManager.default.createDirectory(
        at: path.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    let value: JSONValue = .object([
        "api_key": .string("agentmail-test-secret-never-persist"),
        "inbox_id": .string("agent@example.test"),
        "display_name": .string("Agent"),
    ])
    try value.serializedData(pretty: true).write(to: path)
}

@Test func slackSendAliasesStageExactBoundedPrivatePayloadWithoutDispatch() async throws {
    for alias in ["slack.post_message", "slack_post_message"] {
        let root = try makeExternalSendTempRoot(alias.replacingOccurrences(of: ".", with: "-"))
        defer { try? FileManager.default.removeItem(at: root) }
        let body = "private Slack body \(alias)"
        let input: [String: JSONValue] = [
                "channel": .string("C123"),
                "text": .string(body),
                "thread_ts": .string("1700000000.000001"),
                "access_token": .string("must-not-be-persisted"),
        ]
        let result: JSONValue
        if alias == "slack_post_message" {
            result = try await SwiftToolDispatcher(dataRoot: root).dispatch(
                tool: alias,
                input: input,
                surface: "chat"
            )
        } else {
            result = try await ExternalSendApprovalLifecycle.stage(
                invokedAs: alias,
                input: input,
                surface: "connector_action",
                dataRoot: root
            ).toolResult
        }

        guard case .object(let resultObject) = result,
              case .string(let approvalID)? = resultObject["approvalId"] else {
            Issue.record("expected pending Slack approval result")
            continue
        }
        #expect(resultObject["status"] == .string("pending_approval"))
        #expect(!((try? result.serialize(pretty: false)) ?? "").contains(body))

        let record = try await SwiftNativeApprovalInbox(root: root).get(approvalID)
        let replay = try #require(ExternalSendApprovalRequest(record: record))
        #expect(record.action == ExternalSendApprovalRequest.approvalAction)
        #expect(replay.actionID == "slack.post_message")
        #expect(replay.invokedAs == alias)
        #expect(replay.input["text"] == .string(body))
        #expect(replay.input["thread_ts"] == .string("1700000000.000001"))
        #expect(replay.input["access_token"] == nil)
        #expect(!record.payloadPreview.contains(body))
        #expect(!record.payloadPreview.contains("C123"))
        #expect(!replay.idempotencyKey.isEmpty)
    }
}

@Test func agentMailSendAliasesShareTheSameReplayPolicyWithoutPersistingConfigSecrets() async throws {
    for alias in ["agentmail.send", "agentmail_send"] {
        let root = try makeExternalSendTempRoot(alias.replacingOccurrences(of: ".", with: "-"))
        defer { try? FileManager.default.removeItem(at: root) }
        try writeAgentMailFixtureConfig(root)
        let body = "private AgentMail body \(alias)"
        let staged = try await ExternalSendApprovalLifecycle.stage(
            invokedAs: alias,
            input: [
                "to": .array([.string("one@example.test"), .string("two@example.test")]),
                "cc": .string("copy@example.test"),
                "subject": .string("Bounded subject"),
                "body": .string(body),
                "api_key": .string("must-not-be-persisted"),
            ],
            surface: "connector_action",
            dataRoot: root
        )

        let replay = try #require(ExternalSendApprovalRequest(record: staged.approval))
        #expect(replay.actionID == "agentmail.send")
        #expect(replay.invokedAs == alias)
        #expect(replay.input["text"] == .string(body))
        #expect(replay.input["inboxId"] == .string("agent@example.test"))
        #expect(replay.input["api_key"] == nil)
        let serialized = try staged.approval.toJSON().serialize(pretty: false)
        #expect(!serialized.contains("agentmail-test-secret-never-persist"))
        #expect(!staged.approval.payloadPreview.contains(body))
    }
}

@Test func externalSendStagingRejectsOversizedSlackBodyWithoutCreatingApproval() async throws {
    let root = try makeExternalSendTempRoot("oversized")
    defer { try? FileManager.default.removeItem(at: root) }
    let result = await ExternalSendApprovalLifecycle.stageToolResult(
        invokedAs: "slack_post_message",
        input: [
            "channel": .string("C123"),
            "text": .string(String(repeating: "x", count: 40_001)),
        ],
        surface: "chat",
        dataRoot: root
    )

    guard case .object(let object) = result else {
        Issue.record("expected failure object")
        return
    }
    #expect(object["status"] == .string("failed"))
    let approvals = try await SwiftNativeApprovalInbox(root: root).list(filter: .all)
    #expect(approvals.isEmpty)
}

@Test func trustedCallerCanBindAStableExternalSendIdempotencyKey() async throws {
    let root = try makeExternalSendTempRoot("stable-idempotency")
    defer { try? FileManager.default.removeItem(at: root) }
    let staged = try await ExternalSendApprovalLifecycle.stage(
        invokedAs: "slack.post_message",
        input: [
            "channel": .string("C123"),
            "text": .string("scheduled body"),
            "_nativeAgentSchedulerOccurrenceKey": .string("must-not-be-inferred"),
        ],
        surface: "scheduler",
        idempotencyKey: "  scheduler-occurrence-42  ",
        dataRoot: root
    )

    let replay = try #require(ExternalSendApprovalRequest(record: staged.approval))
    #expect(replay.idempotencyKey == "scheduler-occurrence-42")
    #expect(replay.input["_nativeAgentSchedulerOccurrenceKey"] == nil)
}

@Test func invalidExplicitExternalSendIdempotencyKeyCreatesNoApproval() async throws {
    let root = try makeExternalSendTempRoot("invalid-idempotency")
    defer { try? FileManager.default.removeItem(at: root) }

    do {
        _ = try await ExternalSendApprovalLifecycle.stage(
            invokedAs: "slack.post_message",
            input: ["channel": .string("C123"), "text": .string("scheduled body")],
            surface: "scheduler",
            idempotencyKey: String(repeating: "x", count: 129),
            dataRoot: root
        )
        Issue.record("Oversized explicit idempotency key was accepted")
    } catch {
        #expect(error.localizedDescription.contains("1 to 128"))
    }
    let approvals = try await SwiftNativeApprovalInbox(root: root).list(filter: .all)
    #expect(approvals.isEmpty)
}
