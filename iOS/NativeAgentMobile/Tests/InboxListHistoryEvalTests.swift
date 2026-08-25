import XCTest
@testable import NativeAgentMobile

/// Executable fence for `ios.screens / ios.inbox.list`.
///
/// A compact earlier-history preview is allowed only when its total and the
/// remaining card count are explicit, and the expanded projection exposes
/// every record.
final class InboxListHistoryEvalTests: XCTestCase {
    func test_earlierHistoryCountAndExpansionExposeEveryReadCard() {
        let readItems = (1...12).map { item("read-\($0)") }

        let preview = InboxListPresentation.earlierSection(
            items: readItems,
            showsAll: false
        )
        XCTAssertEqual(preview.totalCount, 12)
        XCTAssertEqual(preview.visibleItems.map(\.id), readItems.prefix(10).map(\.id))
        XCTAssertEqual(preview.hiddenCount, 2)

        let expanded = InboxListPresentation.earlierSection(
            items: readItems,
            showsAll: true
        )
        XCTAssertEqual(expanded.totalCount, 12)
        XCTAssertEqual(expanded.visibleItems.map(\.id), readItems.map(\.id))
        XCTAssertEqual(expanded.hiddenCount, 0)
    }

    private func item(_ id: String) -> InboxItemRecord {
        InboxItemRecord(
            id: id,
            created_at: "2026-08-24T00:00:00Z",
            source: "eval",
            severity: "info",
            title: "Earlier item \(id)",
            summary: "Read history",
            detail: nil,
            relatedWorkshopExecutionId: nil,
            related_approval_id: nil,
            related_paths: nil,
            related_groups: nil,
            actions: [],
            status: "read",
            read_at: "2026-08-24T01:00:00Z"
        )
    }
}
