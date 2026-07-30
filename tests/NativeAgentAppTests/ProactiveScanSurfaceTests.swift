import Foundation
import Testing
import PersistenceCore
@testable import NativeAgentApp

private func makeProactiveScanTempRoot() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("ProactiveScanSurfaceTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func proactiveOpportunitiesPath(_ root: URL) -> URL {
    root
        .appendingPathComponent("nextgen", isDirectory: true)
        .appendingPathComponent("proactive", isDirectory: true)
        .appendingPathComponent("opportunities.jsonl")
}

private func proactiveNotificationInboxPath(_ root: URL) -> URL {
    root
        .appendingPathComponent("notifications", isDirectory: true)
        .appendingPathComponent("inbox.jsonl")
}

private func proactiveActionIDs(_ values: [JSONValue]) -> [String] {
    values.compactMap { value in
        guard case .object(let obj) = value,
              case .string(let id)? = obj["id"] else {
            return nil
        }
        return id
    }
}

@Test
func proactiveScanSurfacesNotifyOpportunityAndSkipsShadow() async throws {
    let root = try makeProactiveScanTempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let persistence = SwiftNativePersistenceCore()
    let path = proactiveOpportunitiesPath(root)

    try await persistence.appendJSONL(.object([
        "id": .string("opp-notify-1"),
        "kind": .string("approval_backlog"),
        "title": .string("Clear pending approvals"),
        "summary": .string("1 approval request is waiting."),
        "decision": .string("notify"),
        "status": .string("scored"),
        "score": .double(0.72),
        "suggestedAction": .string("approvals.triage"),
        "whyNow": .string("Approvals can make autonomy look frozen."),
    ]), to: path)
    try await persistence.appendJSONL(.object([
        "id": .string("opp-shadow-1"),
        "kind": .string("lazy_capability_drafts"),
        "title": .string("Validate safe drafts"),
        "summary": .string("Drafts are cooling down."),
        "decision": .string("shadow"),
        "status": .string("scored"),
        "score": .double(0.91),
    ]), to: path)

    let result = await NativeAgentScheduledProactiveScan.evaluate(
        dataRoot: root,
        payload: ["surfaceLimit": .int(4)],
        persistence: persistence
    )

    #expect(result.surfaced.map(\.id) == ["opp-notify-1"])
    #expect(result.surfaced.first?.source == "proactive_autonomy:approval_backlog:opp-notify-1")
    if let surfaced = result.surfaced.first {
        #expect(proactiveActionIDs(NativeAgentScheduledProactiveScan.inboxActions(for: surfaced)) == [
            "view",
            "open_approvals",
            "archive",
            "dismiss",
        ])
    }
}

@Test
func proactiveScanSkipsAlreadySurfacedOpportunityIDs() async throws {
    let root = try makeProactiveScanTempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let persistence = SwiftNativePersistenceCore()
    let opportunities = proactiveOpportunitiesPath(root)

    for id in ["opp-a", "opp-b"] {
        try await persistence.appendJSONL(.object([
            "id": .string(id),
            "kind": .string("goal_idea"),
            "title": .string("Idea \(id)"),
            "summary": .string("A useful idea."),
            "decision": .string("notify"),
            "status": .string("scored"),
            "score": .double(id == "opp-a" ? 0.9 : 0.8),
        ]), to: opportunities)
    }
    try await persistence.appendJSONL(.object([
        "id": .string("visible-opp-a"),
        "created_at": .string("2026-06-08T18:00:00+00:00"),
        "source": .string("proactive_autonomy:goal_idea:opp-a"),
        "severity": .string("important"),
        "title": .string("Idea opp-a"),
        "summary": .string("Already surfaced."),
        "status": .string("unread"),
        "actions": .array([]),
    ]), to: proactiveNotificationInboxPath(root))

    let result = await NativeAgentScheduledProactiveScan.evaluate(
        dataRoot: root,
        payload: ["surfaceLimit": .int(4)],
        persistence: persistence
    )

    #expect(result.skippedAlreadySurfacedCount == 1)
    #expect(result.surfaced.map(\.id) == ["opp-b"])
}

@Test
func proactiveScanIgnoresRoutineReceiptsForInboxDigest() async throws {
    let root = try makeProactiveScanTempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let persistence = SwiftNativePersistenceCore()
    let inbox = proactiveNotificationInboxPath(root)

    try await persistence.appendJSONL(.object([
        "id": .string("visible-1"),
        "created_at": .string("2026-06-08T18:00:00+00:00"),
        "source": .string("dream_cycle"),
        "severity": .string("important"),
        "title": .string("Agent dreamed"),
        "summary": .string("Dream receipt"),
        "status": .string("unread"),
        "actions": .array([]),
    ]), to: inbox)
    try await persistence.appendJSONL(.object([
        "id": .string("scan-placeholder"),
        "created_at": .string("2026-06-08T18:00:00+00:00"),
        "source": .string("scheduled_proactive_scan"),
        "severity": .string("important"),
        "title": .string("Scheduled proactive scan"),
        "summary": .string("Placeholder receipt"),
        "status": .string("unread"),
        "actions": .array([]),
    ]), to: inbox)

    let result = await NativeAgentScheduledProactiveScan.evaluate(
        dataRoot: root,
        payload: ["surfaceLimit": .int(4)],
        persistence: persistence
    )

    #expect(result.surfaced.isEmpty)
}

@Test
func proactiveScanCreatesLiveInboxDigestForActionableCards() async throws {
    let root = try makeProactiveScanTempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let persistence = SwiftNativePersistenceCore()
    let inbox = proactiveNotificationInboxPath(root)

    try await persistence.appendJSONL(.object([
        "id": .string("workshop-blocked"),
        "created_at": .string("2026-06-08T18:00:00+00:00"),
        "source": .string("missions"),
        "severity": .string("actionable"),
        "title": .string("Workshop step approval"),
        "summary": .string("A Workshop execution is blocked on approval."),
        "status": .string("unread"),
        "actions": .array([
            .object(["id": .string("approve"), "label": .string("Approve")]),
            .object(["id": .string("deny"), "label": .string("Deny")]),
        ]),
    ]), to: inbox)

    let result = await NativeAgentScheduledProactiveScan.evaluate(
        dataRoot: root,
        payload: ["surfaceLimit": .int(4)],
        persistence: persistence
    )

    #expect(result.surfaced.count == 1)
    #expect(result.surfaced.first?.kind == "inbox_digest")
    #expect(result.surfaced.first?.title == "Review inbox blockers")
    #expect(result.surfaced.first?.summary.contains("1 actionable inbox item") == true)
}

@Test
func proactiveScanIgnoresSchedulerWarningsButSurfacesErrors() async throws {
    let root = try makeProactiveScanTempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let persistence = SwiftNativePersistenceCore()
    let scheduler = root.appendingPathComponent("scheduler", isDirectory: true)
        .appendingPathComponent("jobs.json")

    try await persistence.writeJSON(.array([
        .object([
            "id": .string("morning"),
            "name": .string("Agent Morning Warm-up"),
            "enabled": .bool(true),
            "lastRunStatus": .string("warn"),
            "lastRunDetail": .string("delivered via push,inbox; errors: telegram not configured"),
        ]),
        .object([
            "id": .string("weekly-rem"),
            "name": .string("Agent Weekly REM"),
            "enabled": .bool(true),
            "lastRunStatus": .string("error"),
            "lastRunDetail": .string("provider connection failed"),
        ]),
    ]), to: scheduler)

    let result = await NativeAgentScheduledProactiveScan.evaluate(
        dataRoot: root,
        payload: ["surfaceLimit": .int(4)],
        persistence: persistence
    )

    #expect(result.surfaced.count == 1)
    #expect(result.surfaced.first?.kind == "scheduler_health")
    #expect(result.surfaced.first?.title == "Review scheduler errors")
    #expect(result.surfaced.first?.summary.contains("1 scheduled job") == true)
}
