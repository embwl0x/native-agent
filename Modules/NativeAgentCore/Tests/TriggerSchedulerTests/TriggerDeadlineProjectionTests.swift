import Foundation
import Testing
import NativeAgentCore
@testable import TriggerScheduler

private func deadlineProjectionRoot() throws -> URL {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("trigger-deadline-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}

private func writeDeadlineJSON(_ object: Any, to url: URL) throws {
    try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    try data.write(to: url, options: .atomic)
}

private func deadlineISO(_ date: Date) -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter.string(from: date)
}

@Suite("Trigger scheduler deadline projection", .serialized)
struct TriggerDeadlineProjectionTests {
    @Test("future time trigger preserves its exact local instant")
    func exactFutureTime() async throws {
        let root = try deadlineProjectionRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone.current
        let now = try #require(calendar.date(from: DateComponents(
            year: 2026, month: 7, day: 13, hour: 9, minute: 0
        )))
        let expected = try #require(calendar.date(from: DateComponents(
            year: 2026, month: 7, day: 13, hour: 11, minute: 17
        )))
        try writeDeadlineJSON([[
            "name": "exact",
            "kind": "time",
            "enabled": true,
            "config": ["hour": 11, "minute": 17],
        ]], to: root.appendingPathComponent("inbox/trigger_config.json"))
        try writeDeadlineJSON([], to: root.appendingPathComponent("workshop/triggers.json"))

        let scheduler = SwiftNativeTriggerScheduler(root: root, now: { now })
        #expect(await scheduler.nextMeaningfulDeadline(after: now) == expected)
    }

    @Test("claimed time occurrence advances across restart to tomorrow")
    func claimedTimeAdvancesToNextOccurrence() async throws {
        let root = try deadlineProjectionRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone.current
        let now = try #require(calendar.date(from: DateComponents(
            year: 2026, month: 7, day: 13, hour: 10, minute: 5
        )))
        let occurrence = try #require(calendar.date(from: DateComponents(
            year: 2026, month: 7, day: 13, hour: 10, minute: 0
        )))
        let expected = try #require(calendar.date(from: DateComponents(
            year: 2026, month: 7, day: 14, hour: 10, minute: 0
        )))
        try writeDeadlineJSON([[
            "name": "daily",
            "kind": "time",
            "enabled": true,
            "config": ["hour": 10, "minute": 0],
        ]], to: root.appendingPathComponent("inbox/trigger_config.json"))
        try writeDeadlineJSON([], to: root.appendingPathComponent("workshop/triggers.json"))
        try writeDeadlineJSON([
            "daily": ["last_fired_at": deadlineISO(occurrence)],
        ], to: root.appendingPathComponent("inbox/trigger_state.json"))

        let restored = SwiftNativeTriggerScheduler(root: root, now: { now })
        #expect(await restored.nextMeaningfulDeadline(after: now) == expected)
    }

    @Test("idle trigger derives an exact crossing from persisted activity")
    func idleCrossingUsesSessionActivity() async throws {
        let root = try deadlineProjectionRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let activity = Date(timeIntervalSince1970: 1_800_000_000)
        let now = activity.addingTimeInterval(5 * 60)
        let expected = activity.addingTimeInterval(30 * 60)
        try writeDeadlineJSON([[
            "name": "idle",
            "kind": "idle",
            "enabled": true,
            "config": ["idle_minutes": 30],
        ]], to: root.appendingPathComponent("inbox/trigger_config.json"))
        try writeDeadlineJSON([], to: root.appendingPathComponent("workshop/triggers.json"))
        try writeDeadlineJSON([[
            "id": "session",
            "title": "Current",
            "updatedAt": deadlineISO(activity),
            "archived": false,
        ]], to: root.appendingPathComponent("chat/sessions.json"))

        let scheduler = SwiftNativeTriggerScheduler(root: root, now: { now })
        #expect(await scheduler.nextMeaningfulDeadline(after: now) == expected)
    }

    @Test("already-due unclaimed occurrence keeps the legacy recovery edge")
    func overdueOccurrenceRetriesWithoutGlobalHeartbeat() async throws {
        let root = try deadlineProjectionRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone.current
        let now = try #require(calendar.date(from: DateComponents(
            year: 2026, month: 7, day: 13, hour: 10, minute: 5
        )))
        try writeDeadlineJSON([[
            "name": "due",
            "kind": "time",
            "enabled": true,
            "config": ["hour": 10, "minute": 0],
        ]], to: root.appendingPathComponent("inbox/trigger_config.json"))
        try writeDeadlineJSON([], to: root.appendingPathComponent("workshop/triggers.json"))

        let scheduler = SwiftNativeTriggerScheduler(root: root, now: { now })
        #expect(
            await scheduler.nextMeaningfulDeadline(after: now)
                == now.addingTimeInterval(60)
        )
    }
}
