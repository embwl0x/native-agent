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

// MARK: - Per-kind primary-action resolver (2026-08-11)

/// The 2026-06-06 recursion bug picked the first non-"view" entry from the
/// standard fan-out `[view, act, archive, dismiss]` — which was "act" itself.
/// Pin that a morning-brief item shipping EXACTLY that fan-out resolves to a
/// chat draft (marked read, never archived), not anything act-shaped.
@Test
func morningBriefActResolvesToChatDraftMarkedRead() throws {
    let item = try decodeInboxItem(.object([
        "id": .string("brief-1"),
        "created_at": .string("2026-08-11T08:00:00+00:00"),
        "source": .string("trigger:morning_brief"),
        "severity": .string("info"),
        "title": .string("Morning brief"),
        "summary": .string("3 approvals pending, disk healthy, one execution finished overnight."),
        "status": .string("unread"),
        "actions": .array([
            .object(["id": .string("view"), "label": .string("View")]),
            .object(["id": .string("act"), "label": .string("Act")]),
            .object(["id": .string("archive"), "label": .string("Archive")]),
            .object(["id": .string("dismiss"), "label": .string("Dismiss")]),
        ]),
    ]))

    // L5 G6 inversion: the morning brief is HER card, so Act posts its content
    // into the transcript as her message (composer stays empty) rather than
    // drafting a "Re:" note from User to himself.
    let resolution = NativeClient.resolveInboxPrimaryAction(for: item)
    guard case .chatSpoken(let message) = resolution else {
        Issue.record("expected chatSpoken, got \(resolution)")
        return
    }
    #expect(message.contains("Morning brief"))
    #expect(message.contains("3 approvals pending"))
    #expect(resolution.inboxStatusAction == "read")
}

@Test
func idleCheckinActResolvesToChatDraft() throws {
    let item = try decodeInboxItem(.object([
        "id": .string("checkin-1"),
        "created_at": .string("2026-08-11T14:00:00+00:00"),
        "source": .string("idle_checkin"),
        "severity": .string("info"),
        "title": .string("Checking in"),
        "summary": .string("Quiet afternoon — anything you want me on?"),
        "status": .string("unread"),
        "actions": .array([]),
    ]))

    // L5 G6 inversion: idle check-in is the other her-voice card — Act speaks
    // it in the transcript instead of drafting a composer reply.
    guard case .chatSpoken(let message) = NativeClient.resolveInboxPrimaryAction(for: item) else {
        Issue.record("expected chatSpoken")
        return
    }
    #expect(message.contains("Checking in"))
}

/// gpt-5.5 BLOCKING (2026-08-11): the her-voice allowlist is EXACT — a source
/// that merely starts with an allowlisted string (crafted row, or a future
/// producer inheriting the name) must NOT earn the right to speak in the
/// transcript. Those fall back to the composer draft like any other card.
@Test
func prefixExtendedSourceNeverSpeaksInTheTranscript() throws {
    for spoofed in ["trigger:morning_brief_test", "idle_checkin_v2", "trigger:morning_briefx"] {
        let item = try decodeInboxItem(.object([
            "id": .string("spoof-\(spoofed)"),
            "created_at": .string("2026-08-11T08:00:00+00:00"),
            "source": .string(spoofed),
            "severity": .string("info"),
            "title": .string("Not her voice"),
            "summary": .string("Crafted content that must not be spoken as hers."),
            "status": .string("unread"),
            "actions": .array([]),
        ]))
        #expect(!NativeClient.isHerVoiceCard(item))
        if case .chatSpoken = NativeClient.resolveInboxPrimaryAction(for: item) {
            Issue.record("spoofed source \(spoofed) resolved to chatSpoken")
        }
    }
}

@Test
func approvalLinkedActResolvesToOpenApprovals() throws {
    let item = try decodeInboxItem(.object([
        "id": .string("appr-1"),
        "created_at": .string("2026-08-11T08:00:00+00:00"),
        "source": .string("trigger:morning_brief"),
        "severity": .string("actionable"),
        "title": .string("Approval waiting"),
        "summary": .string("A tool call needs your decision."),
        "related_approval_id": .string("approval-42"),
        "status": .string("unread"),
        "actions": .array([]),
    ]))

    let resolution = NativeClient.resolveInboxPrimaryAction(for: item)
    #expect(resolution == .openApprovals)
    // openApprovalsFromInboxAction owns the read-marking on this path.
    #expect(resolution.inboxStatusAction == nil)
}

@Test
func executionLinkedActResolvesToDeskExecution() throws {
    let item = try decodeInboxItem(.object([
        "id": .string("exec-1"),
        "created_at": .string("2026-08-11T08:00:00+00:00"),
        "source": .string("workshop"),
        "severity": .string("important"),
        "title": .string("Execution finished"),
        "summary": .string("Overnight run completed."),
        "related_mission_id": .string("exec-abc"),
        "status": .string("unread"),
        "actions": .array([]),
    ]))

    let resolution = NativeClient.resolveInboxPrimaryAction(for: item)
    #expect(resolution == .openDeskExecution(executionId: "exec-abc"))
    #expect(resolution.inboxStatusAction == "read")
}

@Test
func approvalLinkBeatsExecutionLink() throws {
    let item = try decodeInboxItem(.object([
        "id": .string("both-1"),
        "created_at": .string("2026-08-11T08:00:00+00:00"),
        "source": .string("workshop"),
        "severity": .string("actionable"),
        "title": .string("Needs a decision"),
        "summary": .string("Execution paused on an approval."),
        "related_approval_id": .string("approval-7"),
        "related_mission_id": .string("exec-def"),
        "status": .string("unread"),
        "actions": .array([]),
    ]))

    #expect(NativeClient.resolveInboxPrimaryAction(for: item) == .openApprovals)
}

@Test
func contentlessItemStaysUnresolvedAndWritesNoStatus() throws {
    let item = try decodeInboxItem(.object([
        "id": .string("blank-1"),
        "created_at": .string("2026-08-11T08:00:00+00:00"),
        "source": .string("mystery_source"),
        "severity": .string("info"),
        "title": .string("  "),
        "summary": .string(""),
        "status": .string("unread"),
        "actions": .array([]),
    ]))

    let resolution = NativeClient.resolveInboxPrimaryAction(for: item)
    guard case .unresolved = resolution else {
        Issue.record("expected unresolved, got \(resolution)")
        return
    }
    #expect(resolution.inboxStatusAction == nil)
}

/// Unmapped proactive cards expose no Act button by design
/// (fallbackPrimaryAction == nil); an act call that reaches one anyway must
/// stay unresolved, not turn into a chat draft.
@Test
func unmappedProactiveCardStaysUnresolved() throws {
    let item = try decodeInboxItem(.object([
        "id": .string("proactive-2"),
        "created_at": .string("2026-08-11T08:00:00+00:00"),
        "source": .string("proactive_autonomy:harness_backlog:opp-9"),
        "severity": .string("actionable"),
        "title": .string("Review harness backlog"),
        "summary": .string("Items pending."),
        "status": .string("unread"),
        "actions": .array([]),
    ]))

    let resolution = NativeClient.resolveInboxPrimaryAction(for: item)
    guard case .unresolved = resolution else {
        Issue.record("expected unresolved, got \(resolution)")
        return
    }
}

/// Approval-linked proactive cards still resolve — the proactive guard sits
/// BELOW the approval check in priority.
@Test
func approvalBacklogProactiveCardStillOpensApprovals() throws {
    let item = try decodeInboxItem(.object([
        "id": .string("proactive-3"),
        "created_at": .string("2026-08-11T08:00:00+00:00"),
        "source": .string("proactive_autonomy:approval_backlog:opp-10"),
        "severity": .string("actionable"),
        "title": .string("Clear pending approvals"),
        "summary": .string("2 approval requests are waiting."),
        "detail": .string("Suggested action: approvals.triage."),
        "status": .string("unread"),
        "actions": .array([]),
    ]))

    #expect(NativeClient.resolveInboxPrimaryAction(for: item) == .openApprovals)
}

@Test
func chatDraftTextCapsLongSummary() {
    let longSummary = String(repeating: "x", count: 500)
    let draft = NativeClient.inboxChatDraftText(title: "Brief", summary: longSummary)
    #expect(draft.contains("Brief"))
    #expect(draft.count < 350)
    #expect(draft.contains("…"))
    #expect(draft.hasSuffix("\n\n"))
}
