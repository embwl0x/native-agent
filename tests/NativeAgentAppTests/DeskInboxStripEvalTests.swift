import Foundation
import Testing
@testable import NativeAgentApp

// EVAL FENCE: app.desk / desk.inbox.strip
@Suite("Desk inbox strip")
struct DeskInboxStripEvalTests {
    private func item(_ id: Int, status: String) throws -> InboxItemRecord {
        try JSONDecoder().decode(
            InboxItemRecord.self,
            from: Data("""
            {"id":"inbox-\(id)","created_at":"2026-08-24T00:00:00Z","source":"desk",
             "severity":"actionable","title":"Item \(id)","summary":"Inbox fixture",
             "actions":[],"status":"\(status)"}
            """.utf8)
        )
    }

    @Test("visible cards plus overflow always account for the unread input")
    func boundedUnreadProjectionAccountsForEverySize() throws {
        for size in [0, 1, 3, 4, 20] {
            let items = try (0..<size).map { index in
                try item(index, status: index.isMultiple(of: 3) ? "read" : "unread")
            }
            let display = InboxStripDisplay(items: items)
            let expectedUnread = items.filter(\.isUnread).count

            #expect(display.unreadCount == expectedUnread)
            #expect(display.visibleItems.count <= InboxStripDisplay.visibleLimit)
            #expect(display.visibleItems.count + display.overflowCount == expectedUnread)
        }
    }

    @Test("quiet, mixed-status, and malformed-status inputs remain honest")
    func stripOnlyCallsExplicitUnreadActionable() throws {
        let quiet = try [
            item(1, status: "read"),
            item(2, status: "archived"),
            item(3, status: "dismissed"),
            item(4, status: "not-a-real-status"),
        ]
        let mixed = try [
            item(10, status: "unread"),
            item(11, status: " READ "),
            item(12, status: "UNREAD"),
            item(13, status: "bad-wire-value"),
            item(14, status: "unread"),
            item(15, status: "unread"),
        ]

        #expect(InboxStripDisplay(items: quiet).isQuiet)
        let display = InboxStripDisplay(items: mixed)
        #expect(!display.isQuiet)
        #expect(display.visibleItems.map(\.id) == ["inbox-10", "inbox-12", "inbox-14"])
        #expect(display.overflowCount == 1)
    }

    @Test("mounted strip uses the shared projection and keeps unavailable reads visible")
    func presentationAndUnavailableBoundaryAreMounted() throws {
        let strip = try AppSourceScraping.appSource("InboxView.swift")
        #expect(strip.contains("let unreadItems = items.filter(\\.isUnread)"))
        #expect(strip.contains("ForEach(display.visibleItems)"))
        #expect(strip.contains("if display.overflowCount > 0"))
        #expect(strip.contains("if display.isQuiet { EmptyView() }"))

        let container = try AppSourceScraping.appSource("ChatInboxStrip.swift")
        #expect(container.contains("Inbox unavailable:"))
        #expect(container.contains("InboxStripPresentation.failed("))
        #expect(container.contains("previousItems: items"))
        #expect(container.contains("InboxStripView(\n            items: items,"))
    }
}
