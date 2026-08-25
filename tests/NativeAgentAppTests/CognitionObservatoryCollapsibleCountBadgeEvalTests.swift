import CognitiveSubstrate
import Testing
@testable import NativeAgentApp

// EVAL FENCE: app.mind / ui.cognitionObservatory.collapsible.countBadge

@MainActor
@Suite("Cognition Observatory collapsible count badge")
struct CognitionObservatoryCollapsibleCountBadgeEvalTests {
    @Test("the live receipt-count producer keeps unknown and explicit zero distinct")
    func receiptCountProvenanceReachesTheSharedBadgePresentation() {
        let quietCount = CognitionLoopActivityPresentation.receiptCount(for: .available([]))
        let unavailableCount = CognitionLoopActivityPresentation.receiptCount(
            for: .unavailable(.cognitionDisabled)
        )

        #expect(quietCount == 0)
        #expect(unavailableCount == nil)
        #expect(CognitionObservatoryCountBadgePresentation.badge(for: quietCount)
            == .init(count: 0))
        #expect(CognitionObservatoryCountBadgePresentation.badge(for: unavailableCount) == nil)
        #expect(CognitionObservatoryCountBadgePresentation.badge(for: 3)
            == .init(count: 3))
        #expect(CognitionObservatoryCountBadgePresentation.badge(for: -1) == nil,
                "a malformed negative count must not be relabeled as a real zero")
        #expect(CognitionObservatoryCollapsedRowPresentation.accessibilityLabel(
            title: "Loop Activity", count: nil, pending: 0, hint: nil
        ) == "Loop Activity")
        #expect(CognitionObservatoryCollapsedRowPresentation.accessibilityLabel(
            title: "Loop Activity", count: 0, pending: 0, hint: nil
        ) == "Loop Activity, 0 items")
    }

    @Test("the shared header presentation renders zero and nonzero badges but omits unknown")
    func badgePresentationPreservesCountAvailability() {
        let unknown = CognitionObservatoryCountBadgePresentation.badge(for: nil)
        let zero = CognitionObservatoryCountBadgePresentation.badge(for: 0)
        let three = CognitionObservatoryCountBadgePresentation.badge(for: 3)

        #expect(unknown == nil,
                "an unavailable count must not fabricate a zero badge")
        #expect(zero?.text == "0",
                "a successful producer reporting zero must remain visible")
        #expect(three?.text == "3")
        #expect(zero != unknown)
    }
}
