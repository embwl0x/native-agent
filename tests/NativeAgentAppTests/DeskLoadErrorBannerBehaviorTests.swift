import Foundation
import Testing
@testable import NativeAgentApp

@Suite("Desk load-error banner behavior")
struct DeskLoadErrorBannerBehaviorTests {
    private struct StoreReadError: LocalizedError {
        let errorDescription: String?
    }

    // app.desk / desk.view.loadErrorBanner
    @Test("the mounted Desk-store failure keeps its cause visible and shares the lane notice bound")
    func loadFailureIsExplicitBoundedAndNeverAnEmptyDeskClaim() {
        let ordinary = DeskItemPresentation.loadFailure(
            StoreReadError(errorDescription: "Permission denied while opening desk.json")
        )
        #expect(ordinary == "Couldn't load the bench: Permission denied while opening desk.json")
        #expect(!ordinary.contains("The desk is clear"))

        let unknownCause = DeskItemPresentation.loadFailure(StoreReadError(errorDescription: " \n\t "))
        #expect(unknownCause == "Couldn't load the bench: The storage read failed without details.")
        #expect(!unknownCause.isEmpty)

        let oversizedCause = "Database corrupt: " + String(repeating: "x", count: 2_000)
        let oversizedBanner = DeskItemPresentation.loadFailure(
            StoreReadError(errorDescription: oversizedCause)
        )
        let laneBound = DeskLaneState<Int>.maxReasonChars
        #expect(oversizedBanner.count == laneBound)
        #expect(oversizedBanner == DeskLaneState<Int>.boundedReason(
            "Couldn't load the bench: \(oversizedCause)"
        ))
        #expect(oversizedBanner.hasPrefix("Couldn't load the bench: Database corrupt:"))
    }
}
