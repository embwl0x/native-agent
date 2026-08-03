import Foundation
import NativeAgentCore
import PersistenceCore
import Testing
@testable import ChatOrchestration

@Test("claude_message appends one inbox row for a caller-supplied message_id")
func claudeMessageIdempotency() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("claude-message-idempotency-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let dispatcher = SwiftToolDispatcher(
        dataRoot: root,
        agentBridgeConfigRoot: root,
        claudeMessageWakeupOverride: { _ in
            .object(["status": .string("queued")])
        }
    )
    let input: [String: JSONValue] = [
        "text": .string("follow up on the deploy"),
        "message_id": .string("claude_followup_7"),
        "topic": .string("deploy"),
    ]

    let first = try await dispatcher.dispatch(tool: "claude_message", input: input, surface: "chat")
    let second = try await dispatcher.dispatch(tool: "claude_message", input: input, surface: "chat")

    guard case .object(let firstObject) = first, case .object(let secondObject) = second else {
        Issue.record("claude_message should return object receipts")
        return
    }
    #expect(firstObject["messageId"] == .string("claude_followup_7"))
    #expect(firstObject["deduplicated"] == .bool(false))
    #expect(secondObject["messageId"] == .string("claude_followup_7"))
    #expect(secondObject["deduplicated"] == .bool(true))

    let inbox = root
        .appendingPathComponent("claude-bridge", isDirectory: true)
        .appendingPathComponent("claude-inbox.jsonl")
    let rows = try await SwiftNativePersistenceCore().readJSONL(inbox)
    #expect(rows.count == 1)

    // A same-id/different-text send is a conflict, never a silent second row.
    let conflicted = try await dispatcher.dispatch(
        tool: "claude_message",
        input: [
            "text": .string("a different body for the same id"),
            "message_id": .string("claude_followup_7"),
        ],
        surface: "chat"
    )
    guard case .object(let conflictObject) = conflicted else {
        Issue.record("claude_message conflict should return an object receipt")
        return
    }
    #expect(conflictObject["status"] == .string("failed"))
    #expect(conflictObject["reason"] == .string("message_id_conflict"))
    let rowsAfterConflict = try await SwiftNativePersistenceCore().readJSONL(inbox)
    #expect(rowsAfterConflict.count == 1)
}
