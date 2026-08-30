import Foundation
import Testing
import NativeAgentCore
import PersistenceCore
@testable import NotificationInbox

// Ledger rows: notifications.live.upsert, notifications.live.sharedSingleton
//
// Silent-failure classes:
//   * STALE / LEAK — `upsert` is a full-row replace under the flock followed by
//     `Self.retained` + `invalidate()`. Drop the invalidate and every reader in
//     the process keeps serving the PRE-upsert card forever (the file is right,
//     the UI is wrong, nothing errors). Drop the replace and stable-identity
//     notices accumulate duplicates instead of updating.
//   * WRONG PATH — `shared` is bound once at process start to
//     `livePath(dataRoot: PersistenceCore.defaultDataRoot())`. If that binding
//     drifts, the app writes its live inbox somewhere nothing reads.

private func upsertFixture(_ id: String, status: String = "unread", body: String) -> JSONValue {
    .object([
        "id": .string(id),
        "created_at": .string("2026-08-23T00:00:00Z"),
        "source": .string("test"),
        "severity": .string(status == "unread" ? "actionable" : "info"),
        "title": .string(id),
        "summary": .string(body),
        "actions": .array([]),
        "status": .string(status),
        "read_at": .null,
    ])
}

private func informationalFixture(
    _ id: String,
    severity: String = "info",
    status: String = "unread",
    createdAt: String,
    body: String
) -> JSONValue {
    .object([
        "id": .string(id),
        "created_at": .string(createdAt),
        "source": .string("recurring-health-note"),
        "severity": .string(severity),
        "title": .string("Recurring health note"),
        "summary": .string(body),
        "actions": .array([]),
        "status": .string(status),
        "read_at": status == "read" ? .string("2026-08-23T00:01:00Z") : .null,
    ])
}

private func upsertTestPath() throws -> URL {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("live-inbox-upsert-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory.appendingPathComponent("inbox.jsonl")
}

private func summaries(_ rows: [JSONValue]) -> [String] {
    rows.compactMap {
        guard case .object(let object) = $0,
              case .string(let summary)? = object["summary"] else { return nil }
        return summary
    }
}

private func ids(_ rows: [JSONValue]) -> [String] {
    rows.compactMap {
        guard case .object(let object) = $0,
              case .string(let id)? = object["id"] else { return nil }
        return id
    }
}

@Test("upsert inserts once, then replaces in place instead of accumulating duplicates")
func liveInboxUpsertReplacesInPlace() async throws {
    let path = try upsertTestPath()
    defer { try? FileManager.default.removeItem(at: path.deletingLastPathComponent()) }
    let inbox = LiveNotificationInbox(path: path)

    #expect(try await inbox.upsert(upsertFixture("card", body: "v1"), id: "card") == true)
    #expect(try await inbox.upsert(upsertFixture("card", body: "v2"), id: "card") == false)
    #expect(try await inbox.upsert(upsertFixture("card", body: "v3"), id: "card") == false)

    let rows = try await inbox.rows()
    #expect(rows.count == 1)
    #expect(summaries(rows) == ["v3"])
    // The file itself carries one physical line — a stable-identity notice that
    // re-renders every tick must not grow the log without bound.
    let physical = try String(contentsOf: path, encoding: .utf8)
        .split(separator: "\n", omittingEmptySubsequences: true)
    #expect(physical.count == 1)
}

@Test("a reader never serves the pre-upsert row from the parsed snapshot")
func liveInboxUpsertInvalidatesCache() async throws {
    // MUTATION NOTE (verified 2026-08-23): deleting `invalidate()` from `upsert`
    // does NOT make this fail — the atomic replace changes the file's
    // (inode, size, mtime) stamp, so `rows()` re-reads anyway. So this pins the
    // OUTCOME (no stale content after an upsert) rather than one of the two
    // mechanisms that defend it; a regression in EITHER the stamp check or the
    // invalidate is caught only if both stop working. Making the invalidate
    // independently observable would need a production seam (see
    // productionSeamNeeded).
    let path = try upsertTestPath()
    defer { try? FileManager.default.removeItem(at: path.deletingLastPathComponent()) }
    let inbox = LiveNotificationInbox(path: path)

    #expect(try await inbox.upsert(upsertFixture("card", body: "v1"), id: "card"))
    // Warm the cache before mutating: an unwarmed reader can never be stale.
    #expect(summaries(try await inbox.rows()) == ["v1"])

    #expect(try await inbox.upsert(upsertFixture("card", body: "v2"), id: "card") == false)
    #expect(summaries(try await inbox.rows()) == ["v2"], "reader served a stale cached row")

    // Status changes through upsert are visible too (the card's identity
    // survives, its content does not).
    #expect(try await inbox.upsert(
        upsertFixture("card", status: "archived", body: "v3"), id: "card"
    ) == false)
    let rows = try await inbox.rows()
    guard case .object(let object)? = rows.first else {
        Issue.record("no row after upsert")
        return
    }
    #expect(object["status"] == .string("archived"))
    #expect(object["summary"] == .string("v3"))
}

@Test("upsert replaces in position and leaves its neighbours untouched")
func liveInboxUpsertPreservesOrderAndNeighbours() async throws {
    let path = try upsertTestPath()
    defer { try? FileManager.default.removeItem(at: path.deletingLastPathComponent()) }
    let inbox = LiveNotificationInbox(path: path)

    for id in ["a", "b", "c"] {
        #expect(try await inbox.upsert(upsertFixture(id, body: "\(id)-v1"), id: id))
    }
    #expect(try await inbox.upsert(upsertFixture("b", body: "b-v2"), id: "b") == false)

    let rows = try await inbox.rows()
    #expect(ids(rows) == ["a", "b", "c"], "upsert moved the row instead of replacing it")
    #expect(summaries(rows) == ["a-v1", "b-v2", "c-v1"])
}

@Test("upsert matches on the passed id, not on the row's own id field")
func liveInboxUpsertKeysOnThePassedID() async throws {
    let path = try upsertTestPath()
    defer { try? FileManager.default.removeItem(at: path.deletingLastPathComponent()) }
    let inbox = LiveNotificationInbox(path: path)

    #expect(try await inbox.upsert(upsertFixture("card", body: "v1"), id: "card"))
    // A different id is a different card, even with an identical body shape.
    #expect(try await inbox.upsert(upsertFixture("other", body: "v1"), id: "other"))
    #expect(try await inbox.rows().count == 2)
}

@Test("upsert of a brand-new id after appendUnique does not disturb the appended card")
func liveInboxUpsertCoexistsWithAppendUnique() async throws {
    let path = try upsertTestPath()
    defer { try? FileManager.default.removeItem(at: path.deletingLastPathComponent()) }
    let inbox = LiveNotificationInbox(path: path)

    #expect(try await inbox.appendUnique(upsertFixture("appended", body: "once"), id: "appended"))
    #expect(try await inbox.upsert(upsertFixture("appended", body: "twice"), id: "appended") == false)
    // appendUnique still refuses the id it already knows, even after upsert
    // rewrote the row.
    #expect(try await inbox.appendUnique(upsertFixture("appended", body: "thrice"), id: "appended") == false)

    let rows = try await inbox.rows()
    #expect(rows.count == 1)
    #expect(summaries(rows) == ["twice"])
}

@Test("opted-in repeated info notices roll up into one resurfaced card")
func informationalNoticesRollUpWithoutUnreadPile() async throws {
    let path = try upsertTestPath()
    defer { try? FileManager.default.removeItem(at: path.deletingLastPathComponent()) }
    let inbox = LiveNotificationInbox(path: path)

    let first = try await inbox.appendOrRollUpInformational(
        informationalFixture(
            "first", createdAt: "2026-08-23T00:00:00Z", body: "first occurrence"
        ),
        id: "first",
        rollupKey: "health:provider-a"
    )
    #expect(first == .init(inserted: true, cardID: "first", occurrenceCount: 1))
    #expect(try await inbox.updateStatus(
        id: "first", status: "read", readAt: "2026-08-23T00:01:00Z"
    ))

    let repeated = try await inbox.appendOrRollUpInformational(
        informationalFixture(
            "second", createdAt: "2026-08-24T00:00:00Z", body: "second occurrence"
        ),
        id: "second",
        rollupKey: "health:provider-a"
    )
    #expect(repeated == .init(inserted: false, cardID: "first", occurrenceCount: 2))

    let rows = try await inbox.rows()
    #expect(rows.count == 1)
    guard case .object(let row)? = rows.first else {
        Issue.record("missing rolled-up informational card")
        return
    }
    #expect(row["id"] == .string("first"))
    #expect(row["summary"] == .string("second occurrence"))
    #expect(row["status"] == .string("unread"))
    #expect(row["read_at"] == .null)
    #expect(row["occurrence_count"] == .int(2))
    #expect(row["first_created_at"] == .string("2026-08-23T00:00:00Z"))
    #expect(row["last_created_at"] == .string("2026-08-24T00:00:00Z"))
}

@Test("roll-up never consolidates important or archived informational cards")
func informationalRollupProtectsAttentionAndHandledHistory() async throws {
    let path = try upsertTestPath()
    defer { try? FileManager.default.removeItem(at: path.deletingLastPathComponent()) }
    let inbox = LiveNotificationInbox(path: path)

    _ = try await inbox.appendOrRollUpInformational(
        informationalFixture(
            "handled", status: "archived", createdAt: "2026-08-23T00:00:00Z", body: "handled"
        ),
        id: "handled",
        rollupKey: "health:provider-a"
    )
    _ = try await inbox.appendOrRollUpInformational(
        informationalFixture(
            "fresh", createdAt: "2026-08-24T00:00:00Z", body: "fresh"
        ),
        id: "fresh",
        rollupKey: "health:provider-a"
    )
    _ = try await inbox.appendOrRollUpInformational(
        informationalFixture(
            "important", severity: "important", createdAt: "2026-08-25T00:00:00Z",
            body: "needs individual identity"
        ),
        id: "important",
        rollupKey: "health:provider-a"
    )

    let rows = try await inbox.rows()
    #expect(Set(ids(rows)) == ["handled", "fresh", "important"])
}

@Test("upsert enforces the same retention bound as append")
func liveInboxUpsertRespectsRetentionBound() async throws {
    let path = try upsertTestPath()
    defer { try? FileManager.default.removeItem(at: path.deletingLastPathComponent()) }
    var payload = Data()
    for index in 0..<(LiveNotificationInbox.rowLimit + 20) {
        payload.append(Data((try upsertFixture(
            "row-\(index)", status: index < 30 ? "unread" : "archived", body: "b"
        ).serialize(pretty: false) + "\n").utf8))
    }
    try payload.write(to: path)

    let inbox = LiveNotificationInbox(path: path)
    #expect(try await inbox.upsert(upsertFixture("fresh", body: "new"), id: "fresh"))
    let rows = try await inbox.rows()
    #expect(rows.count == LiveNotificationInbox.rowLimit)
    #expect(ids(rows).contains("fresh"))
    // Active cards keep the budget first — the retention policy is shared with
    // appendUnique and must not have a second, laxer copy inside upsert.
    for index in 0..<30 {
        #expect(ids(rows).contains("row-\(index)"), "an active card was evicted by upsert")
    }
}

@Test("upsert of a corrupt-but-nonempty store fails closed rather than truncating it")
func liveInboxUpsertOnCorruptStoreFailsClosed() async throws {
    let path = try upsertTestPath()
    defer { try? FileManager.default.removeItem(at: path.deletingLastPathComponent()) }
    let corrupt = Data("{not-json\n{also-not-json\n".utf8)
    try corrupt.write(to: path)
    let inbox = LiveNotificationInbox(path: path)

    // Malformed physical lines are carried through byte-for-byte; the upsert
    // appends beside them instead of "cleaning up" bytes it cannot read.
    #expect(try await inbox.upsert(upsertFixture("card", body: "v1"), id: "card"))
    let text = try String(contentsOf: path, encoding: .utf8)
    #expect(text.contains("{not-json"))
    #expect(text.contains("{also-not-json"))
    #expect(try await inbox.rows().count == 1)
}

@Test("the shared singleton is bound to the live inbox path under the default data root")
func liveInboxSharedSingletonPath() async {
    // Read-only: naming the actor does not touch the file.
    let expected = LiveNotificationInbox.livePath(dataRoot: PersistenceCore.defaultDataRoot())
    #expect(await LiveNotificationInbox.shared.path == expected)
    #expect(expected.lastPathComponent == "inbox.jsonl")
    #expect(expected.deletingLastPathComponent().lastPathComponent == "notifications")
    #expect(
        expected.deletingLastPathComponent().deletingLastPathComponent().standardizedFileURL.path
            == PersistenceCore.defaultDataRoot().standardizedFileURL.path
    )
}

@Test("livePath is a pure function of the data root it is handed")
func liveInboxLivePathIsPureInTheRoot() {
    let root = URL(fileURLWithPath: "/tmp/na-eval-root", isDirectory: true)
    let path = LiveNotificationInbox.livePath(dataRoot: root)
    #expect(path.path == "/tmp/na-eval-root/notifications/inbox.jsonl")
    #expect(LiveNotificationInbox.livePath(dataRoot: root) == path)
    #expect(LiveNotificationInbox.livePath(
        dataRoot: URL(fileURLWithPath: "/tmp/other", isDirectory: true)
    ) != path)
}
