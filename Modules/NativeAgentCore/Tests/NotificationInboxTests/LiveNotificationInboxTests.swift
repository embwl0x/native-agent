import Foundation
import Testing
import NativeAgentCore
import PersistenceCore
@testable import NotificationInbox

private func liveInboxFixture(_ id: String, status: String = "unread") -> JSONValue {
    .object([
        "id": .string(id),
        "created_at": .string("2026-08-16T00:00:00Z"),
        "source": .string("test"),
        "severity": .string(status == "unread" ? "actionable" : "info"),
        "title": .string(id),
        "summary": .string("fixture"),
        "actions": .array([]),
        "status": .string(status),
        "read_at": .null,
    ])
}

private func temporaryLiveInbox() throws -> URL {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("live-inbox-tests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory.appendingPathComponent("inbox.jsonl")
}

@Test("live inbox caches parsed rows but invalidates on an external file change")
func liveInboxValidatedCache() async throws {
    let path = try temporaryLiveInbox()
    defer { try? FileManager.default.removeItem(at: path.deletingLastPathComponent()) }
    let owner = LiveNotificationInbox(path: path)
    #expect(try await owner.appendUnique(liveInboxFixture("one"), id: "one"))
    #expect(try await owner.rows().count == 1)

    let external = liveInboxFixture("two")
    let handle = try FileHandle(forWritingTo: path)
    try handle.seekToEnd()
    try handle.write(contentsOf: Data((try external.serialize(pretty: false) + "\n").utf8))
    try handle.close()

    #expect(try await owner.rows().count == 2)
    #expect(try await owner.appendUnique(external, id: "two") == false)
}

@Test("retention protects active cards before keeping newest terminal history")
func liveInboxRetentionPrioritizesActiveCards() async throws {
    let path = try temporaryLiveInbox()
    defer { try? FileManager.default.removeItem(at: path.deletingLastPathComponent()) }
    var payload = Data()
    for index in 0..<(LiveNotificationInbox.rowLimit + 20) {
        let status = index < 30 ? "unread" : "archived"
        payload.append(Data((try liveInboxFixture("row-\(index)", status: status)
            .serialize(pretty: false) + "\n").utf8))
    }
    try payload.write(to: path)

    // Pinned clock: every fixture row is stamped 2026-08-16, so a wall-clock
    // `now` would start age-pruning this file 30 days after that date and turn
    // a cap assertion into a calendar-dependent flake.
    let owner = LiveNotificationInbox(
        path: path, clock: { Date(timeIntervalSince1970: 1_788_000_000) }
    )
    #expect(try await owner.appendUnique(liveInboxFixture("new"), id: "new"))
    let rows = try await owner.rows()
    #expect(rows.count == LiveNotificationInbox.rowLimit)
    let ids = Set(rows.compactMap { row -> String? in
        guard case .object(let object) = row,
              case .string(let id)? = object["id"] else { return nil }
        return id
    })
    #expect(ids.contains("new"))
    for index in 0..<30 { #expect(ids.contains("row-\(index)")) }
    #expect(!ids.contains("row-30"), "oldest terminal history should be evicted first")
}

// REPORTS-ONLY -> executable boundary checks (Wave 1):
// core.misc / notifications.live.inbox
@Test("status updates preserve identity, are durable, and refuse a missing card")
func liveInboxStatusUpdateHasARealPersistenceBoundary() async throws {
    let path = try temporaryLiveInbox()
    defer { try? FileManager.default.removeItem(at: path.deletingLastPathComponent()) }
    let inbox = LiveNotificationInbox(path: path)
    #expect(try await inbox.appendUnique(liveInboxFixture("card"), id: "card"))
    #expect(try await inbox.updateStatus(id: "card", status: "read", readAt: "fixed-time"))
    let missingChanged = try await inbox.updateStatus(
        id: "missing", status: "read", readAt: "fixed-time"
    )
    #expect(!missingChanged)

    let reloaded = LiveNotificationInbox(path: path)
    let row = try #require(await reloaded.rows().first)
    guard case .object(let fields) = row else {
        Issue.record("notification row did not survive its real JSONL round trip")
        return
    }
    #expect(fields["id"] == .string("card"))
    #expect(fields["status"] == .string("read"))
    #expect(fields["read_at"] == .string("fixed-time"))
}

@Test("nonempty malformed inbox is unavailable rather than an apparently empty feed")
func liveInboxMalformedOnlyFeedFailsClosed() async throws {
    let path = try temporaryLiveInbox()
    defer { try? FileManager.default.removeItem(at: path.deletingLastPathComponent()) }
    let corrupt = Data("{not-json}\n".utf8)
    try corrupt.write(to: path)
    let inbox = LiveNotificationInbox(path: path)
    await #expect(throws: NSError.self) { _ = try await inbox.rows() }
    #expect(try Data(contentsOf: path) == corrupt)
}
