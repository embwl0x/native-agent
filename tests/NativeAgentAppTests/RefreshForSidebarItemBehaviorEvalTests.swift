import Foundation
import Testing
@testable import NativeAgentApp

// EVAL FENCE: app.mac / loop.refreshForSidebarItem

@MainActor
@Suite("app.mac · sidebar refresh loop", .serialized)
struct RefreshForSidebarItemBehaviorEvalTests {
    @Test("the real scoped refresh returns the same receipt it publishes for the active panel")
    func refreshReturnsThePublishedPanelReceipt() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("sidebar-refresh-receipt-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let app = AppModel(dataRootOverride: root, startBackgroundTasks: false)
        let receipt = await app.refreshForSidebarItem(.tools)

        #expect(app.panelRefreshStatus[.tools] == receipt)
        #expect(receipt.lastAttemptAt >= (receipt.lastSuccessAt ?? .distantPast))
    }

    @Test("failed endpoint receipts retain the previous known-good timestamp")
    func failureDoesNotMasqueradeAsACompleteRefresh() {
        let prior = AppModel.PanelRefreshStatus(
            lastAttemptAt: Date(timeIntervalSince1970: 10),
            lastSuccessAt: Date(timeIntervalSince1970: 9),
            failedEndpoints: []
        )
        let next = AppModel.nextRefreshStatus(
            previous: prior,
            failedEndpoints: ["tool catalog", "tools"],
            at: Date(timeIntervalSince1970: 20)
        )

        #expect(next.isStale)
        #expect(next.lastSuccessAt == prior.lastSuccessAt)
        #expect(next.failedEndpoints == ["tool catalog", "tools"])
    }
}
