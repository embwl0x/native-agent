import Foundation
import Testing
@testable import PersistenceCore
@testable import NativeAgentApp

@Suite("Desk pursuits card behavior")
struct DeskPursuitsCardBehaviorTests {
    private func item(
        _ handle: String,
        origin: DeskOrigin = .agent,
        kind: DeskKind = .project,
        pursuit: Pursuit? = nil
    ) -> DeskItem {
        DeskItem(
            handle: handle,
            alias: handle,
            kind: kind,
            status: .now,
            project: "NativeAgent",
            title: "Title \(handle)",
            openedAt: "2026-08-01T00:00:00Z",
            updatedAt: "2026-08-01T00:00:00Z",
            origin: origin,
            pursuit: pursuit
        )
    }

    private func validPursuit() -> Pursuit {
        Pursuit(
            why: "This keeps returning in independent evidence.",
            evidence: PromotionDossier(citations: []),
            doneLooksLike: "The gap is resolved with a durable receipt.",
            abandonCondition: "The pattern no longer recurs.",
            privateName: "Receipt truth"
        )
    }

    // app.desk / desk.pursuits.card
    @Test("pursuit header counts exactly the rendered cards and exposes a decoded-payload failure")
    func pursuitRowsRetainUnreadableAgentProjectInsteadOfDroppingIt() {
        let valid = item("desk-valid", pursuit: validPursuit())
        // This is the state left by the real tolerant decoder when an
        // origin=agent project has a malformed optional pursuit payload.
        let unreadable = item("desk-unreadable", pursuit: nil)
        let ordinary = item("desk-owner", origin: .owner, pursuit: nil)

        let rows = DeskPursuitSectionPresentation.rows(from: [valid, unreadable, ordinary])
        #expect(rows.map(\.item.handle) == ["desk-valid", "desk-unreadable"])
        #expect(DeskPursuitSectionPresentation.headerCount(for: rows) == 2)

        guard case let .rendered(validCard) = rows[0].cardState else {
            Issue.record("A complete persisted pursuit must render a normal card")
            return
        }
        #expect(validCard.title == "Receipt truth")

        guard case .payloadUnreadable = rows[1].cardState else {
            Issue.record("An agent project without a decoded payload must render an honesty card")
            return
        }
        #expect(DeskPursuitSectionPresentation.unreadablePayloadLabel == "Pursuit payload unreadable")
        #expect(DeskPursuitSectionPresentation.unreadablePayloadDetail.contains("could not be rendered"))

        let board = DeskBoardLayout.board([valid, unreadable, ordinary])
        #expect(!board.contains(where: { $0.handle == unreadable.handle }))
        #expect(board.map(\.handle) == [ordinary.handle])
        #expect(Array(DeskBoardLayout.selectableHandles(
            items: [valid, unreadable, ordinary],
            expandedRoots: []
        ).prefix(2)) == [valid.handle, unreadable.handle])
        #expect(DeskBoardLayout.revealKeys(for: unreadable.handle, items: [valid, unreadable, ordinary]).isEmpty)
    }

    // app.desk / desk.pursuits.card
    @Test("an honestly empty pursuits lane has no count while malformed rows remain visible")
    func emptyAndMalformedPursuitLanesRemainDistinguishable() {
        let emptyRows = DeskPursuitSectionPresentation.rows(from: [item("desk-owner", origin: .owner)])
        #expect(emptyRows.isEmpty)
        #expect(DeskPursuitSectionPresentation.headerCount(for: emptyRows) == nil)

        let malformedRows = DeskPursuitSectionPresentation.rows(from: [item("desk-bad")])
        #expect(malformedRows.count == 1)
        #expect(DeskPursuitSectionPresentation.headerCount(for: malformedRows) == 1)
        #expect(malformedRows[0].cardState == .payloadUnreadable)
    }
}
