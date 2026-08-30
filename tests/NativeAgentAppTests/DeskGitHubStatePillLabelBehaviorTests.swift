import Testing
@testable import NativeAgentApp
@testable import PersistenceCore

@Suite("Desk GitHub state-pill labels")
struct DeskGitHubStatePillLabelBehaviorTests {
    private func item(
        state: GitHubCommandItemState,
        callbackStatus: String? = nil
    ) -> GitHubCommandItem {
        GitHubCommandItem(
            itemId: "github-item",
            repository: "nativeagent/desktop",
            number: 42,
            kind: .pullRequest,
            title: "State label evaluation",
            state: state,
            observation: nil,
            dispatchIntent: nil,
            dispatchReceipt: nil,
            workLog: [],
            blocker: nil,
            finalReceipt: nil,
            lastCallbackStatus: callbackStatus,
            lastSettledEventKey: nil,
            notificationClaims: [],
            notificationReceipts: [],
            verificationReadFailures: nil,
            createdAt: "2026-08-24T12:00:00Z",
            updatedAt: "2026-08-24T12:00:00Z"
        )
    }

    // app.desk / desk.github.statePillLabel
    @Test("every persisted state and attention reason has human label vocabulary")
    func noStatePillLeaksSnakeCaseStorageIdentifiers() {
        let ordinaryStates: [GitHubCommandItemState] = [
            .detected,
            .needsCodex,
            .codexWorking,
            .verifying,
            .needsUser,
            .resolved,
        ] + GitHubCommandWaitingKind.allCases.map(GitHubCommandItemState.waitingUpstream)
        let attentionStates = GitHubCommandAttentionReason.allCases.map(GitHubCommandItemState.attention)

        for state in ordinaryStates + attentionStates {
            let pill = DeskGitHubStatePillPresentation.pill(for: item(state: state))
            #expect(!pill.label.isEmpty)
            #expect(!pill.label.contains("_"))
            #expect(pill.label != state.name.rawValue)
        }

        let stalled = DeskGitHubStatePillPresentation.pill(for: item(
            state: .attention(.codexFailed),
            callbackStatus: "  \(DeskGitHubStatePillPresentation.stalledCallbackStatus.uppercased())  "
        ))
        #expect(stalled.label == "Codex stalled")
        #expect(stalled.tone == .danger)

        let noResult = DeskGitHubStatePillPresentation.pill(for: item(
            state: .attention(.codexFailed),
            callbackStatus: "failed"
        ))
        #expect(noResult.label == "Codex no result")
        #expect(noResult.tone == .danger)
    }

    // app.desk / desk.github.statePillLabel
    @Test("waiting and critical attention labels retain their user-facing meaning")
    func specialPillLabelsNameTheActualStateRatherThanItsWireToken() {
        #expect(DeskGitHubStatePillPresentation.pill(for: item(
            state: .waitingUpstream(.readyToMerge)
        )).label == "Ready to merge")
        #expect(DeskGitHubStatePillPresentation.pill(for: item(
            state: .attention(.verificationReadFailed)
        )).label == "GitHub verification unreadable")
        #expect(DeskGitHubStatePillPresentation.pill(for: item(
            state: .attention(.contradictoryState)
        )).label == "State needs review")
    }
}
