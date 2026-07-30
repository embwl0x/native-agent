import Testing
import Foundation
@testable import TriggerScheduler
import NativeAgentCore
import PersistenceCore

// Real content for morning_brief / idle_checkin. Every source is fail-open, so
// the tests pin BOTH halves: what a seeded source contributes, and that a
// missing source degrades to an honest sentence instead of a placeholder.

// MARK: - Helpers

private func tempRoot() throws -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("TriggerContentTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

private func localDate(_ y: Int, _ mo: Int, _ d: Int, _ h: Int, _ mi: Int) -> Date {
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = TimeZone.current
    var dc = DateComponents()
    dc.year = y; dc.month = mo; dc.day = d; dc.hour = h; dc.minute = mi; dc.second = 0
    return cal.date(from: dc)!
}

private func writeJSON(_ value: JSONValue, to url: URL) throws {
    try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(), withIntermediateDirectories: true
    )
    try value.serializedData(pretty: false).write(to: url)
}

private func seedSessions(_ rows: [JSONValue], root: URL) throws {
    try writeJSON(.array(rows), to: root.appendingPathComponent("chat/sessions.json"))
}

private func sessionRow(title: String, updatedAt: Date, archived: Bool = false) -> JSONValue {
    .object([
        "id": .string(UUID().uuidString),
        "title": .string(title),
        "archived": .bool(archived),
        "updatedAt": .string(SwiftNativeTriggerScheduler.isoTimestamp(updatedAt)),
    ])
}

private func seedWorkshopExecutions(_ rows: [JSONValue], root: URL) throws {
    try writeJSON(.array(rows), to: root.appendingPathComponent("workshop/legacy_executions.json"))
}

private func seedInboxIndex(_ statuses: [String], root: URL) throws {
    // A5.2 cutover: the brief reads the LIVE inbox (notifications/inbox.jsonl,
    // one row per item, status in-row, last-write-wins per id) — the dead
    // inbox/index.json overlay is no longer consulted.
    var lines: [String] = []
    for s in statuses {
        let row: JSONValue = .object([
            "id": .string(UUID().uuidString),
            "created_at": .string("2026-03-05T08:00:00Z"),
            "source": .string("test"),
            "severity": .string("info"),
            "title": .string("seed"),
            "summary": .string("seed"),
            "status": .string(s),
            "read_at": .null,
        ])
        lines.append(String(data: try row.serializedData(pretty: false), encoding: .utf8) ?? "{}")
    }
    let dir = root.appendingPathComponent("notifications", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    try lines.joined(separator: "\n").appending("\n")
        .write(to: dir.appendingPathComponent("inbox.jsonl"), atomically: true, encoding: .utf8)
}

private func seedWorklog(_ entries: [(Date, String)], root: URL) throws -> URL {
    let path = root.appendingPathComponent("worklog.jsonl")
    var text = ""
    for (ts, summary) in entries {
        let line: JSONValue = .object([
            "ts": .string(SwiftNativeTriggerScheduler.isoTimestamp(ts)),
            "summary": .string(summary),
        ])
        text += try line.serialize(pretty: false) + "\n"
    }
    try text.data(using: .utf8)!.write(to: path)
    return path
}

private func builder(root: URL, now: Date, worklog: URL? = nil) -> TriggerContentBuilder {
    TriggerContentBuilder(
        root: root,
        persistence: SwiftNativePersistenceCore(),
        now: { now },
        worklogPath: worklog ?? root.appendingPathComponent("no-such-worklog.jsonl")
    )
}

// MARK: - morning_brief

@Suite("TriggerContentBuilder: morning brief")
struct MorningBriefSuite {

    @Test func realContentFromSeededSources() async throws {
        let root = try tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let now = localDate(2026, 3, 5, 9, 0)

        // Desk: two live items (create defaults to .watch, which is "open").
        let desk = SwiftNativeDeskStore(dataRoot: root)
        let a = try await desk.createItem(kind: .plan, project: "na", title: "wake the triggers")
        _ = try await desk.setStatus(a.handle, status: .now)
        _ = try await desk.createItem(kind: .watch, project: "na", title: "watch the push path")

        // Worklog: one entry yesterday afternoon, one far too old.
        let worklog = try seedWorklog([
            (localDate(2026, 2, 20, 12, 0), "ancient history"),
            (localDate(2026, 3, 4, 15, 0), "landed the notifier seam"),
        ], root: root)

        try seedWorkshopExecutions([
            .object(["status": .string("running"),
                     "updatedAt": .string(SwiftNativeTriggerScheduler.isoTimestamp(localDate(2026, 3, 5, 2, 0)))]),
            .object(["status": .string("done"),
                     "completedAt": .string(SwiftNativeTriggerScheduler.isoTimestamp(localDate(2026, 3, 4, 23, 0)))]),
        ], root: root)
        try seedInboxIndex(["unread", "unread", "read"], root: root)
        try seedSessions([sessionRow(title: "trigger audit", updatedAt: localDate(2026, 3, 4, 22, 0))], root: root)

        let content = await builder(root: root, now: now, worklog: worklog).morningBrief()

        #expect(content.title == "Morning brief — Thursday, March 5")
        #expect(content.summary.contains("Thursday, March 5"))
        #expect(content.summary.contains("2 open desk items"))
        #expect(content.summary.contains("2 Workshop tasks moved"))
        #expect(content.summary.contains("2 unread"))
        #expect(content.summary.contains("1 log entry since yesterday"))
        #expect(!content.summary.contains("Stub"))

        guard case .string(let detail) = content.detail else {
            Issue.record("expected a markdown detail body"); return
        }
        #expect(detail.contains("## Desk"))
        #expect(detail.contains("## Since yesterday"))
        #expect(detail.contains("landed the notifier seam"))
        #expect(!detail.contains("ancient history"))   // outside the yesterday cutoff
        #expect(detail.contains("## Workshop"))
        #expect(detail.contains("## Inbox"))
        #expect(detail.contains("trigger audit"))
        #expect(!detail.contains("Stub"))
    }

    @Test func emptyStateIsHonestNotAPlaceholder() async throws {
        let root = try tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let now = localDate(2026, 3, 5, 9, 0)

        let content = await builder(root: root, now: now).morningBrief()

        #expect(content.title == "Morning brief — Thursday, March 5")
        #expect(content.summary == "Morning brief for Thursday, March 5 — nothing new since yesterday.")
        #expect(!content.summary.contains("Stub"))
        #expect(content.detail == .null)
    }

    @Test func oneMalformedSourceDoesNotSinkTheBrief() async throws {
        let root = try tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let now = localDate(2026, 3, 5, 9, 0)

        // Legacy execution summary is garbage; inbox index is fine.
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("workshop"), withIntermediateDirectories: true)
        try Data("{not json".utf8).write(to: root.appendingPathComponent("workshop/legacy_executions.json"))
        try seedInboxIndex(["unread"], root: root)

        let content = await builder(root: root, now: now).morningBrief()
        #expect(content.summary.contains("1 unread"))
        #expect(!content.summary.contains("mission"))
    }

    @Test func singularPluralWording() async throws {
        let root = try tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let now = localDate(2026, 3, 5, 9, 0)
        let desk = SwiftNativeDeskStore(dataRoot: root)
        _ = try await desk.createItem(kind: .plan, project: "na", title: "only one")

        let content = await builder(root: root, now: now).morningBrief()
        #expect(content.summary.contains("1 open desk item,") || content.summary.contains("1 open desk item."))
        #expect(!content.summary.contains("1 open desk items"))
    }
}

// MARK: - idle_checkin

@Suite("TriggerContentBuilder: idle check-in")
struct IdleCheckinSuite {

    @Test func quietDurationFromNewestSession() async throws {
        let root = try tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let now = localDate(2026, 3, 5, 14, 0)
        // 134 minutes back == 2h 14m.
        try seedSessions([
            sessionRow(title: "older thread", updatedAt: now.addingTimeInterval(-6 * 3600)),
            sessionRow(title: "the last thing we talked about", updatedAt: now.addingTimeInterval(-134 * 60)),
        ], root: root)

        let content = await builder(root: root, now: now).idleCheckin()
        #expect(content.title == "Idle check-in")
        #expect(content.summary.hasPrefix("Quiet for 2h 14m."))
        #expect(content.summary.contains("the last thing we talked about"))
        #expect(!content.summary.contains("Stub"))
    }

    @Test func deskCountWinsOverSessionTitleWhenSomethingIsOpen() async throws {
        let root = try tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let now = localDate(2026, 3, 5, 14, 0)
        try seedSessions([sessionRow(title: "a thread", updatedAt: now.addingTimeInterval(-45 * 60))], root: root)
        let desk = SwiftNativeDeskStore(dataRoot: root)
        _ = try await desk.createItem(kind: .plan, project: "na", title: "open thing")

        let content = await builder(root: root, now: now).idleCheckin()
        #expect(content.summary == "Quiet for 45m. 1 open desk item waiting.")
    }

    @Test func noActivitySignalSaysSoPlainly() async throws {
        let root = try tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let content = await builder(root: root, now: localDate(2026, 3, 5, 14, 0)).idleCheckin()
        #expect(content.summary == "You've been quiet — I can't tell how long (no recorded session activity).")
        #expect(content.detail == .null)
        #expect(!content.summary.contains("Stub"))
    }

    @Test func archivedSessionsAreNotActivity() async throws {
        let root = try tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let now = localDate(2026, 3, 5, 14, 0)
        try seedSessions([
            sessionRow(title: "archived", updatedAt: now.addingTimeInterval(-60), archived: true),
            sessionRow(title: "live", updatedAt: now.addingTimeInterval(-90 * 60)),
        ], root: root)
        let content = await builder(root: root, now: now).idleCheckin()
        #expect(content.summary.hasPrefix("Quiet for 1h 30m."))
    }
}

// MARK: - Unit-level helpers

@Suite("TriggerContentBuilder: helpers")
struct TriggerContentHelperSuite {

    @Test func durationLabelShape() {
        #expect(TriggerContentBuilder.durationLabel(0) == "0m")
        #expect(TriggerContentBuilder.durationLabel(-500) == "0m")
        #expect(TriggerContentBuilder.durationLabel(14 * 60) == "14m")
        #expect(TriggerContentBuilder.durationLabel(134 * 60) == "2h 14m")
        #expect(TriggerContentBuilder.durationLabel(50 * 3600) == "2d 2h")
    }

    @Test func lastActivityIsMaxUpdatedAt() throws {
        let root = try tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(TriggerContentBuilder.lastActivityInstant(root: root) == nil)

        let newest = localDate(2026, 3, 5, 12, 30)
        try seedSessions([
            sessionRow(title: "a", updatedAt: localDate(2026, 3, 5, 9, 0)),
            sessionRow(title: "b", updatedAt: newest),
            sessionRow(title: "c", updatedAt: localDate(2026, 3, 4, 23, 0)),
        ], root: root)
        let got = try #require(TriggerContentBuilder.lastActivityInstant(root: root))
        #expect(abs(got.timeIntervalSince(newest)) < 1)
    }

    @Test func tailTextDropsLeadingPartialLine() throws {
        let root = try tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("tail.txt")
        try Data("aaaaaaaaaa\nbbbb\ncccc\n".utf8).write(to: path)
        // maxBytes lands mid-"aaaaaaaaaa" → that fragment must be dropped.
        let tail = try #require(TriggerContentBuilder.tailText(path, maxBytes: 15))
        #expect(!tail.contains("aaa"))
        #expect(tail.contains("bbbb"))
        #expect(tail.contains("cccc"))
    }

    @Test func tailTextOnMissingFileIsNil() throws {
        let root = try tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(TriggerContentBuilder.tailText(root.appendingPathComponent("nope"), maxBytes: 100) == nil)
    }

    @Test func quietHoursWrapMidnight() {
        // Default config: 23 → 08.
        #expect(SwiftNativeTriggerScheduler.inQuietHours(localDate(2026, 3, 5, 2, 0), startHour: 23, endHour: 8))
        #expect(SwiftNativeTriggerScheduler.inQuietHours(localDate(2026, 3, 5, 23, 30), startHour: 23, endHour: 8))
        #expect(!SwiftNativeTriggerScheduler.inQuietHours(localDate(2026, 3, 5, 8, 0), startHour: 23, endHour: 8))
        #expect(!SwiftNativeTriggerScheduler.inQuietHours(localDate(2026, 3, 5, 14, 0), startHour: 23, endHour: 8))
        // Non-wrapping window.
        #expect(SwiftNativeTriggerScheduler.inQuietHours(localDate(2026, 3, 5, 10, 0), startHour: 9, endHour: 17))
        // Misconfiguration must not silence a trigger forever.
        #expect(!SwiftNativeTriggerScheduler.inQuietHours(localDate(2026, 3, 5, 10, 0), startHour: 5, endHour: 5))
        #expect(!SwiftNativeTriggerScheduler.inQuietHours(localDate(2026, 3, 5, 10, 0), startHour: -1, endHour: 30))
    }
}
