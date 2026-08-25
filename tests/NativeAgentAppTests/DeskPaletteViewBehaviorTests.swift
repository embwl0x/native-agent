import PersistenceCore
import Testing
@testable import NativeAgentApp

@MainActor
@Suite("Desk palette view behavior", .serialized)
struct DeskPaletteViewBehaviorTests {
    private let rows = [
        DeskPaletteRow(handle: "desk-alpha", alias: "1", title: "Alpha planning", project: "NativeAgent", status: "now"),
        DeskPaletteRow(handle: "desk-release", alias: "2", title: "Release readiness", project: "NativeAgent", status: "now"),
        DeskPaletteRow(handle: "desk-archive", alias: "3", title: "Archive old receipts", project: "NativeAgent", status: "later"),
    ]

    private func activeItem(handle: String, title: String, updatedAt: String) -> DeskItem {
        DeskItem(
            handle: handle,
            alias: "1",
            kind: .plan,
            status: .now,
            project: "NativeAgent",
            title: title,
            openedAt: "2026-08-01T00:00:00.000000+00:00",
            updatedAt: updatedAt
        )
    }

    // app.desk / desk.palette.view
    @Test("banner target and Enter target share one resolution, including bare-verb selected-row fallback")
    func presentationNamesTheExactRowThatCommandDispatches() {
        let selectedFallback = DeskPaletteQuery.parse("close")
        let selectedTarget = DeskPalettePresentation.target(
            rows: rows,
            matches: DeskFuzzy.filter(rows, query: selectedFallback.query),
            selectedHandle: "desk-release",
            parsed: selectedFallback,
            highlighted: 0
        )
        #expect(selectedTarget?.handle == "desk-release")
        #expect(DeskPalettePresentation.bannerText(
            for: .close,
            target: selectedTarget,
            query: selectedFallback.query
        ) == "Enter closes \u{201C}Release readiness\u{201D}.")

        let queried = DeskPaletteQuery.parse("note archive")
        let queriedTarget = DeskPalettePresentation.target(
            rows: rows,
            matches: DeskFuzzy.filter(rows, query: queried.query),
            selectedHandle: "desk-release",
            parsed: queried,
            highlighted: 0
        )
        #expect(queriedTarget?.handle == "desk-archive")
        #expect(DeskPalettePresentation.bannerText(
            for: .note,
            target: queriedTarget,
            query: queried.query
        ) == "Enter selects \u{201C}Archive old receipts\u{201D} and opens the note field.")

        let missingSelection = DeskPalettePresentation.target(
            rows: rows,
            matches: rows,
            selectedHandle: "missing-row",
            parsed: selectedFallback,
            highlighted: 0
        )
        #expect(missingSelection == nil)
        #expect(DeskPalettePresentation.bannerText(
            for: .close,
            target: missingSelection,
            query: selectedFallback.query
        ) == "Close — nothing selected yet; type part of an item's title.")

        let noMatch = DeskPaletteQuery.parse("defer absent")
        #expect(DeskPalettePresentation.target(
            rows: rows,
            matches: DeskFuzzy.filter(rows, query: noMatch.query),
            selectedHandle: "desk-release",
            parsed: noMatch,
            highlighted: 0
        ) == nil)
        #expect(DeskPalettePresentation.bannerText(
            for: .deferItem,
            target: nil,
            query: noMatch.query
        ) == "Defer — no item matches \u{201C}absent\u{201D}.")
    }

    // app.desk / desk.palette.view
    @Test("Return submits the displayed selected fallback through the shared Desk close action")
    func displayedSelectedFallbackBecomesTheExactLiveCloseAction() {
        let parsed = DeskPaletteQuery.parse("close")
        let displayedTarget = DeskPalettePresentation.target(
            rows: rows,
            matches: DeskFuzzy.filter(rows, query: parsed.query),
            selectedHandle: "desk-release",
            parsed: parsed,
            highlighted: 0
        )
        #expect(DeskPalettePresentation.submission(parsed: parsed, target: displayedTarget)
            == .command(verb: .close, handle: "desk-release"))

        let release = activeItem(
            handle: "desk-release",
            title: "Release readiness",
            updatedAt: "2026-08-03T00:00:00.000000+00:00"
        )
        let alpha = activeItem(
            handle: "desk-alpha",
            title: "Alpha planning",
            updatedAt: "2026-08-02T00:00:00.000000+00:00"
        )
        guard case let .command(verb, handle) = DeskPalettePresentation.submission(
            parsed: parsed,
            target: displayedTarget
        ) else {
            Issue.record("the displayed selected row must produce a command submission")
            return
        }
        #expect(DeskPaletteCommandApplication.resolve(
            verb: verb,
            handle: handle,
            activeItems: [alpha, release]
        ) == .dispatch(.closeIfCurrent(
            handle: "desk-release",
            outcome: DeskQuickAction.deskCloseOutcome,
            expectedUpdatedAt: release.updatedAt
        )))
    }
}
