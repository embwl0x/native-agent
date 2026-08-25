import Foundation
@testable import PersistenceCore
import Testing
@testable import NativeAgentApp

// EVAL FENCE: app.desk / desk.github.portfolioStripCounts
//
// Exercises the exact presentation projection shared by the portfolio strip
// and the rendered GitHub rows. A resolved feed larger than the visible cap
// must disclose that cap rather than reporting an incompatible total.

@Test
func deskGitHubPortfolioStripCountsItsRenderedRowsOrNamesTheCap() {
    let resolved = (1...7).map { index in
        githubPortfolioItem(
            id: "resolved-\(index)",
            number: index,
            state: .resolved,
            updatedAt: "2026-08-\(String(format: "%02d", index))T00:00:00.000000+00:00"
        )
    }
    let needsUser = githubPortfolioItem(
        id: "needs-user",
        number: 99,
        state: .needsUser,
        updatedAt: "2026-08-10T00:00:00.000000+00:00"
    )
    let items = resolved + [needsUser]

    let resolvedPresentation = DeskGitHubPortfolioStrip.presentation(for: .resolved, items: items)
    #expect(resolvedPresentation.matchingCount == 7)
    #expect(resolvedPresentation.renderedCount == DeskGitHubBucket.resolvedDisplayLimit)
    #expect(resolvedPresentation.isCapped)
    #expect(resolvedPresentation.label == "Recently resolved 5 shown of 7")
    #expect(resolvedPresentation.renderedItems.map(\.itemId) == [
        "resolved-7", "resolved-6", "resolved-5", "resolved-4", "resolved-3",
    ])

    let needsUserPresentation = DeskGitHubPortfolioStrip.presentation(for: .needsUser, items: items)
    #expect(needsUserPresentation.matchingCount == needsUserPresentation.renderedCount)
    #expect(!needsUserPresentation.isCapped)
    #expect(needsUserPresentation.label == "Needs you 1")
    #expect(needsUserPresentation.renderedItems.map(\.itemId) == ["needs-user"])
}

private func githubPortfolioItem(
    id: String,
    number: Int,
    state: GitHubCommandItemState,
    updatedAt: String
) -> GitHubCommandItem {
    GitHubCommandItem(
        itemId: id,
        repository: "user/portfolio",
        number: number,
        kind: .pullRequest,
        title: "PR \(number)",
        state: state,
        observation: nil,
        dispatchIntent: nil,
        dispatchReceipt: nil,
        workLog: [],
        blocker: nil,
        finalReceipt: nil,
        lastCallbackStatus: nil,
        lastSettledEventKey: nil,
        notificationClaims: [],
        notificationReceipts: [],
        verificationReadFailures: nil,
        createdAt: "2026-08-01T00:00:00.000000+00:00",
        updatedAt: updatedAt
    )
}
