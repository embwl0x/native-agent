import XCTest
@testable import NativeAgentMobile

/// Executable fence for `ios.screens / ios.memory.errorLine`.
@MainActor
final class MemoryErrorLineEvalTests: XCTestCase {
    func test_successfulRefreshClearsAPriorSnapshotError() async {
        var refreshErrors: [String?] = ["Memory snapshots are still downloading.", nil]
        let store = MemoryStore(
            refreshMemorySnapshot: {},
            syncErrorProvider: { refreshErrors.removeFirst() }
        )

        await store.refresh()
        XCTAssertEqual(store.error, "Memory snapshots are still downloading.")

        await store.refresh()
        XCTAssertNil(store.error)
    }

    func test_errorLineIgnoresWhitespaceAndCanBeDismissed() {
        XCTAssertNil(MemoryErrorLinePresentation.visibleMessage(" \n "))
        XCTAssertEqual(
            MemoryErrorLinePresentation.visibleMessage("  Snapshot unavailable.  "),
            "Snapshot unavailable."
        )

        let store = MemoryStore()
        store.error = "Snapshot unavailable."
        store.dismissError()
        XCTAssertNil(store.error)
    }

    func test_memoryScreenUsesTheDismissibleLineAndSharedSyncBanner() throws {
        let source = try MobileEvalSources.mobileSource("MemoryView.swift")
        let view = try XCTUnwrap(MobileEvalSources.blockBody(named: "MemoryView", keyword: "struct", in: source))

        XCTAssertTrue(view.contains("MemoryErrorLinePresentation.visibleMessage(store.error)"))
        XCTAssertTrue(view.contains("MemoryErrorLine(message: error)"))
        XCTAssertTrue(view.contains("store.dismissError()"))
        XCTAssertTrue(view.contains(".macSyncErrorBanner()"))
    }
}
