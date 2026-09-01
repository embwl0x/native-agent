import Foundation
import NotificationInbox
import PersistenceCore
import Testing
@testable import NativeAgentApp

// MARK: - Every notifications/inbox.jsonl writer goes through the feed's owner
//
// Three app-side writers (scheduler receipts, the trigger mirror, self-evolution
// cards) appended to the LIVE inbox through `appendJSONLCapped` with a 1000-line
// budget. That was never retention — `enforceJSONLLineCap` keeps a
// `suffix(maxLines)`, so the first append past the budget would have hard-deleted
// the oldest cards, unread ones included, with nothing kept anywhere. The feed's
// real retention lives in `LiveNotificationInbox`, which shelves every row it
// evicts to `notifications/inbox_archive.jsonl` first.
//
// Silent-failure class: a new card writer copies the old pattern. Nothing errors,
// nothing looks wrong, and cards start disappearing once the file grows. This
// suite pins BOTH ends — the routing in source, and the shelf guarantee on the
// two actor entry points those writers use.

private func writerRoutingRoot() throws -> URL {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("inbox-writer-routing-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(
        at: root.appendingPathComponent("notifications", isDirectory: true),
        withIntermediateDirectories: true
    )
    return root
}

private func rowIDs(_ path: URL) throws -> [String] {
    guard let data = try? Data(contentsOf: path) else { return [] }
    return data.split(separator: 0x0A).compactMap { line in
        guard case .object(let object)? = try? JSONValue.parse(Data(line)),
              case .string(let id)? = object["id"] else { return nil }
        return id
    }
}

@Suite("Live inbox writer routing")
struct NotificationInboxWriterRoutingTests {

    @Test("no app source reaches the destructive capped-append route for the live inbox")
    func noWriterCapsTheLiveInboxDestructively() throws {
        let sources = try AppSourceScraping.swiftSourceContents(
            under: AppSourceScraping.appSourcesRoot()
        )
        for (name, contents) in sources {
            #expect(
                !contents.contains("JSONLLineCaps.notificationInbox"),
                """
                \(name) names a line cap for notifications/inbox.jsonl. That \
                constant is deleted precisely because the capped append trims by \
                keeping a suffix and destroys the overflow — append through \
                LiveNotificationInbox, which shelves what it evicts.
                """
            )
        }
    }

    @Test("the three card writers append through LiveNotificationInbox")
    func theCardWritersUseTheFeedOwner() throws {
        for name in [
            "SchedulerDueJobRunner+Persistence.swift",
            "TriggerNotifierBinding.swift",
            "NativeClient+SelfEvolutionApproval.swift",
        ] {
            let source = try AppSourceScraping.appSource(name)
            #expect(source.contains("LiveNotificationInbox("),
                    "\(name) no longer writes its inbox card through the feed's owner")
        }
    }

    @Test("the scheduler's card writer shelves history instead of destroying it")
    func schedulerCardWriterShelvesOverflow() async throws {
        let root = try writerRoutingRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let path = LiveNotificationInbox.livePath(dataRoot: root)

        // History the old capped append would have dropped on the floor: a
        // terminal card retired well beyond the retention window.
        let stale = ISO8601DateFormatter().string(
            from: Date().addingTimeInterval(-90 * 24 * 60 * 60)
        )
        let aged = """
        {"id":"aged","created_at":"\(stale)","source":"scheduler","severity":"info",\
        "title":"old","summary":"old","status":"archived","read_at":"\(stale)","actions":[]}
        """
        try Data((aged + "\n").utf8).write(to: path)

        // The production write path the scheduler's parked-job receipt uses.
        let runner = SchedulerDueJobRunner(root: root)
        try await runner.appendNotificationInbox(
            title: "Job paused",
            message: "paused after repeated failures",
            source: "scheduler",
            severity: "important",
            jobId: "job-1",
            itemId: "fresh"
        )

        #expect(try rowIDs(path) == ["fresh"], "the aged card was not retired from the feed")
        #expect(
            try rowIDs(LiveNotificationInbox.archivePath(forInbox: path)) == ["aged"],
            "the scheduler's append destroyed a card instead of shelving it"
        )
    }
}
