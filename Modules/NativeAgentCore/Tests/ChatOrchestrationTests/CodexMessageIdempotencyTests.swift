import Foundation
import NativeAgentCore
import PersistenceCore
import Testing
@testable import ChatOrchestration

private actor WakeupCallCounter {
    private(set) var count = 0
    func increment() { count += 1 }
}

@Test("codex_message appends one inbox row for a deterministic GitHub event id")
func codexMessageIdempotency() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("codex-message-idempotency-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let wakeups = WakeupCallCounter()
    let dispatcher = SwiftToolDispatcher(
        dataRoot: root,
        agentBridgeConfigRoot: root,
        codexMessageNotificationPermissionOverride: false,
        codexMessageWakeupOverride: { _ in
            await wakeups.increment()
            return .object(["status": .string("queued")])
        }
    )
    let input: [String: JSONValue] = [
        "text": .string("sample/engine #91"),
        "message_id": .string("ghcmd_event_91"),
        "topic": .string("GitHub Command sample/engine#91"),
    ]

    let first = try await dispatcher.dispatch(tool: "codex_message", input: input, surface: "github-command")
    let second = try await dispatcher.dispatch(tool: "codex_message", input: input, surface: "github-command")

    guard case .object(let firstObject) = first, case .object(let secondObject) = second else {
        Issue.record("codex_message should return object receipts")
        return
    }
    #expect(firstObject["messageId"] == .string("ghcmd_event_91"))
    #expect(firstObject["deduplicated"] == .bool(false))
    #expect(secondObject["messageId"] == .string("ghcmd_event_91"))
    #expect(secondObject["deduplicated"] == .bool(true))

    // The first send wakes the codex thread; the duplicate must NOT — its
    // wakeup is reported as deduplicated without invoking the override.
    #expect(firstObject["wakeup"] == .object(["status": .string("queued")]))
    #expect(secondObject["wakeup"] == .object(["status": .string("deduplicated")]))
    #expect(await wakeups.count == 1)

    let inbox = root
        .appendingPathComponent("codex-nativeagent-bridge", isDirectory: true)
        .appendingPathComponent("codex-inbox.jsonl")
    let rows = try await SwiftNativePersistenceCore().readJSONL(inbox)
    #expect(rows.count == 1)
}
