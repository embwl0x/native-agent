import Testing
@testable import NativeAgentApp

// EVAL FENCE: app.mind / ui.cognitionObservatory.hint.collapsedRow

@Suite("Cognition Observatory collapsed row hint")
struct CognitionObservatoryCollapsedRowHintEvalTests {
    @Test("a collapsed row preserves its truthful compact state in both visible and accessible summaries")
    func collapsedHintCarriesCountsPendingWorkAndStatus() {
        let hint = CognitionObservatoryCollapsedRowPresentation.hint(
            raw: "microcycle · 10:42 AM",
            isExpanded: false
        )

        #expect(hint == .init(text: "microcycle · 10:42 AM", isTruncated: false))
        #expect(CognitionObservatoryCollapsedRowPresentation.accessibilityLabel(
            title: "Loop Activity",
            count: 2,
            pending: 1,
            hint: hint
        ) == "Loop Activity, 2 items, 1 pending, microcycle · 10:42 AM")
    }

    @Test("empty, expanded, and oversized adverse hints cannot become a blank or misleading collapsed status")
    func malformedOrUnavailableHintsRemainHonestAndBounded() throws {
        #expect(CognitionObservatoryCollapsedRowPresentation.hint(
            raw: " \n\t ",
            isExpanded: false
        ) == nil)
        #expect(CognitionObservatoryCollapsedRowPresentation.hint(
            raw: "Loop activity unavailable because the receipt store is unavailable.",
            isExpanded: true
        ) == nil)

        let oversized = CognitionObservatoryCollapsedRowPresentation.hint(
            raw: "  Loop activity   unavailable\n" + String(repeating: "x", count: 120),
            isExpanded: false
        )
        let visible = try #require(oversized)
        #expect(visible.isTruncated)
        #expect(visible.text.hasPrefix("Loop activity unavailable "))
        #expect(visible.text.hasSuffix("…"))
        #expect(visible.text.count == CognitionObservatoryCollapsedRowPresentation.maximumVisibleHintCharacters + 1)
        #expect(CognitionObservatoryCollapsedRowPresentation.accessibilityLabel(
            title: "Loop Activity",
            count: nil,
            pending: 0,
            hint: visible
        ).contains("unavailable"))
    }
}
