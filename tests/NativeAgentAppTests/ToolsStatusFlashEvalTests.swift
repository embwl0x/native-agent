import Foundation
import Testing
@testable import NativeAgentApp

@Suite("app.settings · Tools status feed", .serialized)
struct ToolsStatusFlashEvalTests {
    @Test @MainActor
    func identicalConsecutiveFailuresRemainTwoVisibleToolReceipts() {
        let app = AppModel(startBackgroundTasks: false)
        let failure = "Tool update failed: registry unavailable"

        // These are two completed action attempts with byte-identical error
        // text. The mounted Tools view reads this receipt list directly; it
        // must not depend on `statusText` changing to make the second visible.
        app.recordToolOperationStatus(failure, outcome: .failed)
        app.recordToolOperationStatus(failure, outcome: .failed)

        #expect(app.statusText == failure)
        #expect(app.toolOperationStatusReceipts.count == 2)
        #expect(app.toolOperationStatusReceipts.map(\.message) == [failure, failure])
        #expect(app.toolOperationStatusReceipts.allSatisfy { $0.outcome == .failed })
        #expect(app.toolOperationStatusReceipts[0].id != app.toolOperationStatusReceipts[1].id)
        #expect(app.toolOperationStatusReceipts.allSatisfy { $0.outcome.badgeStatus == "error" })
    }

    @Test @MainActor
    func toolReceiptsSurviveAnUnmountedToolsSurfaceAndRetainBoundedNewestFirstOrder() {
        let app = AppModel(startBackgroundTasks: false)
        // No ToolsView is mounted while these real owner receipts arrive.
        // Opening Tools later reads the same AppModel list.
        for index in 0...ToolsStatusFeed.maximumRetainedReceipts {
            app.recordToolOperationStatus("Tool operation \(index)", outcome: .succeeded)
        }

        #expect(app.toolOperationStatusReceipts.count == ToolsStatusFeed.maximumRetainedReceipts)
        #expect(app.toolOperationStatusReceipts.first?.message == "Tool operation 8")
        #expect(app.toolOperationStatusReceipts.last?.message == "Tool operation 1")
        #expect(app.toolOperationStatusReceipts.allSatisfy { $0.outcome == .succeeded })
    }
}
