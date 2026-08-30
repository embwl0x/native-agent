import Foundation
import NativeAgentCore
import PersistenceCore
import Testing
@testable import ChatOrchestration

private actor WakeupCallCounter {
    private(set) var count = 0
    private(set) var payloads: [[String: JSONValue]] = []
    func increment() { count += 1 }
    func record(_ payload: [String: JSONValue]) { count += 1; payloads.append(payload) }
}

private func codexInboxObject(_ value: JSONValue?) -> [String: JSONValue]? {
    guard case .object(let object)? = value else { return nil }
    return object
}

private func markInboxConsumed(_ inbox: URL) async throws {
    let persistence = SwiftNativePersistenceCore()
    let rows = try await persistence.readJSONL(inbox).map { row -> JSONValue in
        guard case .object(var object) = row else { return row }
        object["read"] = .bool(true)
        object["consumedAt"] = .string("2026-08-19T12:00:00Z")
        return .object(object)
    }
    let data = try rows.map { try $0.serialize(pretty: false) }
        .joined(separator: "\n")
        .appending("\n")
        .data(using: .utf8)!
    try data.write(to: inbox, options: .atomic)
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
    let inbox = root
        .appendingPathComponent("codex-nativeagent-bridge", isDirectory: true)
        .appendingPathComponent("codex-inbox.jsonl")
    try await markInboxConsumed(inbox)
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

    let rows = try await SwiftNativePersistenceCore().readJSONL(inbox)
    #expect(rows.count == 1)
}

@Test("codex_message retries a duplicate inbox row whose wake never landed")
func codexMessageRetriesUnconsumedDuplicate() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("codex-message-retry-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let wakeups = WakeupCallCounter()
    let dispatcher = SwiftToolDispatcher(
        dataRoot: root,
        agentBridgeConfigRoot: root,
        codexMessageNotificationPermissionOverride: false,
        codexMessageWakeupOverride: { payload in
            await wakeups.record(payload)
            return await wakeups.count == 1
                ? .object(["status": .string("failed"), "reason": .string("app_server_socket_missing")])
                : .object(["status": .string("sent")])
        }
    )
    let input: [String: JSONValue] = [
        "text": .string("sample/engine #92"),
        "message_id": .string("ghcmd_event_92"),
        "topic": .string("GitHub Command sample/engine#92"),
    ]

    let first = try await dispatcher.dispatch(tool: "codex_message", input: input, surface: "github-command")
    let inbox = root.appendingPathComponent("codex-nativeagent-bridge/codex-inbox.jsonl")
    // Model a durable request from an earlier invocation without clock sleeps.
    let originalRows = try await SwiftNativePersistenceCore().readJSONL(inbox)
    var original = try #require(codexInboxObject(originalRows.first))
    original["createdAt"] = .string("2026-08-19T12:00:00Z")
    try Data((try JSONValue.object(original).serialize(pretty: false) + "\n").utf8).write(to: inbox)
    let beforeRetry = try Data(contentsOf: inbox)
    let second = try await dispatcher.dispatch(tool: "codex_message", input: input, surface: "github-command")
    guard case .object(let firstObject) = first, case .object(let secondObject) = second else {
        Issue.record("codex_message should return object receipts")
        return
    }
    #expect(firstObject["wakeup"] == .object([
        "status": .string("failed"), "reason": .string("app_server_socket_missing"),
    ]))
    #expect(secondObject["deduplicated"] == .bool(true))
    #expect(secondObject["wakeupRetried"] == .bool(true))
    #expect(secondObject["wakeup"] == .object(["status": .string("sent")]))
    #expect(secondObject["queuedAt"] == .string("2026-08-19T12:00:00Z"))
    #expect(await wakeups.count == 2)
    let retryPayload = try #require(await wakeups.payloads.last)
    #expect(retryPayload["queuedAt"] == .string("2026-08-19T12:00:00Z"))
    #expect(retryPayload["sessionId"] == nil)
    #expect(try Data(contentsOf: inbox) == beforeRetry)
    #expect(try await SwiftNativePersistenceCore().readJSONL(inbox).count == 1)
}

@Test("codex_message rejects changed session, origin, brain, or priority for the same unconsumed id")
func codexMessageRetryKeepsExactOperation() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("codex-bound-retry-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let wakeups = WakeupCallCounter()
    let dispatcher = SwiftToolDispatcher(
        dataRoot: root, agentBridgeConfigRoot: root,
        codexMessageNotificationPermissionOverride: false,
        codexMessageWakeupOverride: { payload in
            await wakeups.record(payload)
            return .object(["status": .string("failed")])
        }
    )
    let input: [String: JSONValue] = [
        "text": .string("retain this exact work"), "message_id": .string("bound-operation"),
        "session_id": .string("original-session"), "model": .string("gpt-5.5"),
    ]
    _ = try await dispatcher.dispatch(tool: "codex_message", input: input, surface: "chat")
    let inbox = root.appendingPathComponent("codex-nativeagent-bridge/codex-inbox.jsonl")
    let before = try Data(contentsOf: inbox)
    for (key, value) in [
        ("session_id", JSONValue.string("other-session")),
        ("model", .string("gpt-5.4")),
        ("priority", .string("urgent")),
    ] {
        var changed = input
        changed[key] = value
        let result = try await dispatcher.dispatch(tool: "codex_message", input: changed, surface: "chat")
        #expect(codexInboxObject(result)?["reason"] == .string("message_id_conflict"))
    }
    let changedOrigin = try await dispatcher.dispatch(tool: "codex_message", input: input, surface: "telegram")
    #expect(codexInboxObject(changedOrigin)?["reason"] == .string("message_id_conflict"))
    #expect(await wakeups.count == 1)
    #expect(try Data(contentsOf: inbox) == before)
    var newOperation = input
    newOperation["message_id"] = .string("explicit-new-operation")
    newOperation["model"] = .string("gpt-5.4")
    _ = try await dispatcher.dispatch(tool: "codex_message", input: newOperation, surface: "chat")
    #expect(await wakeups.count == 2)
}

@Test("codex_message does not append or wake through a malformed inbox")
func codexMessageRetryPreservesMalformedInbox() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("codex-malformed-retry-\(UUID().uuidString)")
    let inbox = root.appendingPathComponent("codex-nativeagent-bridge/codex-inbox.jsonl")
    try FileManager.default.createDirectory(at: inbox.deletingLastPathComponent(), withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let bytes = Data("{lost admission".utf8)
    try bytes.write(to: inbox)
    let wakeups = WakeupCallCounter()
    let dispatcher = SwiftToolDispatcher(
        dataRoot: root, agentBridgeConfigRoot: root,
        codexMessageNotificationPermissionOverride: false,
        codexMessageWakeupOverride: { payload in
            await wakeups.record(payload)
            return .object(["status": .string("sent")])
        }
    )
    let result = try await dispatcher.dispatch(tool: "codex_message", input: [
        "text": .string("same uncertain operation"), "message_id": .string("uncertain")
    ], surface: "chat")
    #expect(codexInboxObject(result)?["reason"] == .string("inbox_write_failed"))
    #expect(await wakeups.count == 0)
    #expect(try Data(contentsOf: inbox) == bytes)
}

@Test("codex_message preserves uncertain consumption markers", arguments: ["missingRead", "invalidRead", "invalidConsumedAt"])
func codexMessageRetryRequiresCanonicalUnreadEvidence(marker: String) async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("codex-consumption-retry-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let wakeups = WakeupCallCounter()
    let dispatcher = SwiftToolDispatcher(
        dataRoot: root, agentBridgeConfigRoot: root,
        codexMessageNotificationPermissionOverride: false,
        codexMessageWakeupOverride: { payload in
            await wakeups.record(payload)
            return .object(["status": .string("failed")])
        }
    )
    let input: [String: JSONValue] = ["text": .string("inspect original receipt"), "message_id": .string("same-unread-operation")]
    _ = try await dispatcher.dispatch(tool: "codex_message", input: input, surface: "github-command")
    let inbox = root.appendingPathComponent("codex-nativeagent-bridge/codex-inbox.jsonl")
    let rows = try await SwiftNativePersistenceCore().readJSONL(inbox)
    var row = try #require(codexInboxObject(rows.first))
    if marker == "missingRead" { row.removeValue(forKey: "read") }
    if marker == "invalidRead" { row["read"] = .string("false") }
    if marker == "invalidConsumedAt" { row["consumedAt"] = .int(1) }
    let bytes = Data((try JSONValue.object(row).serialize(pretty: false) + "\n").utf8)
    try bytes.write(to: inbox)
    let result = try await dispatcher.dispatch(tool: "codex_message", input: input, surface: "github-command")
    #expect(codexInboxObject(result)?["wakeupRetried"] == nil)
    #expect(await wakeups.count == 1)
    #expect(try Data(contentsOf: inbox) == bytes)
}
