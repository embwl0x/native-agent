import Foundation
import Testing
@testable import PersistenceCore
@testable import NativeAgentApp

// EVAL FENCE: app.desk / desk.board.ghProjectSummaryNeedsEyes
@Suite("Desk GitHub project summary needs-eyes")
struct DeskBoardGHProjectSummaryNeedsEyesEvalTests {
    private func item(
        _ handle: String,
        kind: DeskKind = .gh,
        status: DeskStatus,
        blockedReason: String? = nil,
        waitingOn: String? = nil
    ) -> DeskItem {
        DeskItem(
            handle: handle,
            alias: handle,
            kind: kind,
            status: status,
            project: "nativeagent",
            title: "Desk row \(handle)",
            openedAt: "2026-08-24T00:00:00.000000+00:00",
            updatedAt: "2026-08-24T00:00:00.000000+00:00",
            blockedReason: blockedReason,
            waitingOn: waitingOn)
    }

    @Test("collapsed GitHub count and attention strip include exactly the same GitHub rows")
    func projectSummaryAndAttentionStripShareNeedsEyesPredicate() {
        let items = [
            item("blocked", status: .blocked),
            item("github-blocked", status: .blocked,
                 blockedReason: DeskAttentionStrip.githubStampedBlockedReason),
            item("flagged", status: .flag),
            item("waiting", status: .todo, waitingOn: "maintainer review"),
            item("quiet", status: .todo),
            item("non-gh-waiting", kind: .plan, status: .todo, waitingOn: "operator"),
        ]
        let active = DeskBoardLayout.activeItems(items)
        let attention = active.filter(DeskItemPresentation.needsEyes)
        let githubSummaryRows = DeskBoardLayout
            .ghByProject(DeskBoardLayout.board(active))
            .flatMap(\.items)
            .filter(DeskItemPresentation.needsEyes)
        let githubBlocked = attention.filter(DeskAttentionStrip.isGitHubStampedBlock)
        let otherAttention = attention.filter { !DeskAttentionStrip.isGitHubStampedBlock($0) }
        let plan = DeskAttentionStrip.plan(
            approvals: [],
            githubNeedsYou: [],
            otherAttention: otherAttention,
            githubBlocked: githubBlocked,
            showingAll: true)
        let stripGitHubHandles = Set(plan.visible.compactMap { line -> String? in
            let prefixes = ["item:", "ghblocked:"]
            guard let prefix = prefixes.first(where: { line.id.hasPrefix($0) }) else { return nil }
            let handle = String(line.id.dropFirst(prefix.count))
            return items.first(where: { $0.handle == handle && $0.kind == .gh })?.handle
        })

        #expect(DeskItemPresentation.githubProjectNeedsEyes(items.filter { $0.kind == .gh }) == 4)
        #expect(Set(githubSummaryRows.map(\.handle)) == stripGitHubHandles)
        #expect(!stripGitHubHandles.contains("quiet"))
    }

    @Test("view derives both the collapsed summary and attention strip from the shared predicate")
    func mountedDeskUsesSharedNeedsEyesDefinition() throws {
        let presentation = try AppSourceScraping.appSource("DeskPresentation.swift")
        #expect(presentation.contains("static func needsEyes(_ item: DeskItem) -> Bool"))
        #expect(presentation.contains("items.lazy.filter(needsEyes).count"))

        let view = try AppSourceScraping.appSource("DeskView.swift")
        #expect(view.contains("activeItems.filter(DeskItemPresentation.needsEyes)"))
        #expect(view.contains("let needsEyes = DeskItemPresentation.githubProjectNeedsEyes(group.items)"))
        #expect(view.contains("Text(\"\\(needsEyes) need\\(needsEyes == 1 ? \"s\" : \"\") attention\")"))
    }
}
