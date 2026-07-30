import XCTest
@testable import CommandPalette

final class ExactActivityCommandRouteTests: XCTestCase {
    func testActivityCommandEntriesNameTheirExactSubsections() throws {
        let entries = commandPaletteEntries()
        let approvals = try XCTUnwrap(entries.first { $0.id == "approvals" })
        let selfImprovement = try XCTUnwrap(
            entries.first { $0.id == "self-improvement-scoreboard" }
        )

        XCTAssertEqual(approvals.route, "sidebar:activity/approvals")
        XCTAssertEqual(
            selfImprovement.route,
            "sidebar:activity/self-improvement"
        )
    }
}
