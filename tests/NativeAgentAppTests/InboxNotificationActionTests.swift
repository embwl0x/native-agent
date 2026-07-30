import Foundation
import Testing
import NativeAgentCore
import PersistenceCore
@testable import NativeAgentApp

private func makeInboxActionTempRoot() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("InboxNotificationActionTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func decodeInboxItem(_ value: JSONValue) throws -> InboxItemRecord {
    let data = try value.serializedData(pretty: false)
    return try JSONDecoder().decode(InboxItemRecord.self, from: data)
}

@Test
func archiveUpdatesVisibleNotificationInboxRow() async throws {
    let root = try makeInboxActionTempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let path = root.appendingPathComponent("notifications", isDirectory: true)
        .appendingPathComponent("inbox.jsonl")
    let persistence = SwiftNativePersistenceCore()
    try await persistence.appendJSONL(.object([
        "id": .string("visible-1"),
        "created_at": .string("2026-06-08T18:00:00+00:00"),
        "source": .string("dream_cycle"),
        "severity": .string("important"),
        "title": .string("Agent dreamed"),
        "summary": .string("Dream receipt"),
        "status": .string("unread"),
        "actions": .array([]),
    ]), to: path)

    let handled = await NativeClient.updateVisibleNotificationInboxStatus(
        id: "visible-1",
        action: "archive",
        inboxPath: path,
        persistence: persistence
    )

    #expect(handled == true)
    let rows = try await persistence.readJSONL(path)
    guard case .object(let obj)? = rows.first else {
        Issue.record("expected first row object")
        return
    }
    #expect(obj["status"] == .string("archived"))
}

@Test
func readUpdatesVisibleNotificationInboxReadAt() async throws {
    let root = try makeInboxActionTempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let path = root.appendingPathComponent("notifications", isDirectory: true)
        .appendingPathComponent("inbox.jsonl")
    let persistence = SwiftNativePersistenceCore()
    try await persistence.appendJSONL(.object([
        "id": .string("visible-2"),
        "created_at": .string("2026-06-08T18:00:00+00:00"),
        "source": .string("scheduled_proactive_scan"),
        "severity": .string("info"),
        "title": .string("Scheduled proactive scan"),
        "summary": .string("Scan receipt"),
        "status": .string("unread"),
        "actions": .array([]),
    ]), to: path)

    let handled = await NativeClient.updateVisibleNotificationInboxStatus(
        id: "visible-2",
        action: "read",
        inboxPath: path,
        persistence: persistence
    )

    #expect(handled == true)
    let rows = try await persistence.readJSONL(path)
    guard case .object(let obj)? = rows.first else {
        Issue.record("expected first row object")
        return
    }
    #expect(obj["status"] == .string("read"))
    guard case .string(let readAt)? = obj["read_at"] else {
        Issue.record("expected read_at")
        return
    }
    #expect(!readAt.isEmpty)
}

@Test
func missingVisibleNotificationInboxRowReturnsFalse() async throws {
    let root = try makeInboxActionTempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let path = root.appendingPathComponent("notifications", isDirectory: true)
        .appendingPathComponent("inbox.jsonl")

    let handled = await NativeClient.updateVisibleNotificationInboxStatus(
        id: "missing",
        action: "archive",
        inboxPath: path,
        persistence: SwiftNativePersistenceCore()
    )

    #expect(handled == false)
}

@Test
func approvalBacklogFallbackUsesOpenApprovalsNotGenericAct() throws {
    let item = try decodeInboxItem(.object([
        "id": .string("proactive-approval"),
        "created_at": .string("2026-06-08T20:16:17+00:00"),
        "source": .string("proactive_autonomy:approval_backlog:opp-1"),
        "severity": .string("actionable"),
        "title": .string("Clear pending approvals"),
        "summary": .string("1 approval request is waiting."),
        "detail": .string("Suggested action: approvals.triage."),
        "status": .string("unread"),
        "actions": .array([]),
    ]))

    #expect(item.effectiveActions.map(\.id) == ["view", "open_approvals", "archive", "dismiss"])
    #expect(NativeClient.primaryInboxActionID(for: item) == "open_approvals")
}

@Test
func unmappedProactiveActionableFallbackDoesNotExposeDeadActButton() throws {
    let item = try decodeInboxItem(.object([
        "id": .string("proactive-harness"),
        "created_at": .string("2026-06-08T20:16:17+00:00"),
        "source": .string("proactive_autonomy:harness_backlog:opp-2"),
        "severity": .string("actionable"),
        "title": .string("Review and graduate harness learning backlog"),
        "summary": .string("Harness items are pending."),
        "detail": .string("Suggested action: harness_learning.auto_implement_backlog."),
        "status": .string("unread"),
        "actions": .array([]),
    ]))

    #expect(item.effectiveActions.map(\.id) == ["view", "archive", "dismiss"])
    #expect(NativeClient.primaryInboxActionID(for: item) == nil)
}
