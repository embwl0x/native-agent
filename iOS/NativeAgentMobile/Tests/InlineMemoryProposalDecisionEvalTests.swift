import XCTest
@testable import NativeAgentMobile

/// EVAL FENCE: ios.screens / ios.activity.inlineMemoryProposal.decide
final class InlineMemoryProposalDecisionEvalTests: XCTestCase {
    func testConfirmedAcceptRemainsVisibleButCannotBeSubmittedAgainBeforeSnapshotPublication() {
        let submitted = InlineMemoryProposalDecisionPresentation.submitted(approve: true)

        XCTAssertFalse(submitted.canDecide)
        XCTAssertFalse(submitted.showsProgress)
        XCTAssertEqual(submitted.feedback?.message, "Accepted; waiting for the Mac/iCloud snapshot.")
        XCTAssertEqual(submitted.feedback?.isError, false)
    }

    func testTimeoutUsesTheSameDuplicateSafeAwaitingStateForReject() {
        let submitted = InlineMemoryProposalDecisionPresentation.submitted(approve: false)

        XCTAssertFalse(submitted.canDecide)
        XCTAssertEqual(submitted.feedback?.message, "Rejected; waiting for the Mac/iCloud snapshot.")
        XCTAssertEqual(submitted.feedback?.isError, false)
    }

    func testOnlyAnExplicitFailureRestoresTheAbilityToRetry() {
        let deciding = InlineMemoryProposalDecisionPresentation.State.deciding
        let failed = InlineMemoryProposalDecisionPresentation.State.failed("Failed: Mac unavailable")

        XCTAssertFalse(deciding.canDecide)
        XCTAssertTrue(deciding.showsProgress)
        XCTAssertTrue(failed.canDecide)
        XCTAssertEqual(failed.feedback?.message, "Failed: Mac unavailable")
        XCTAssertEqual(failed.feedback?.isError, true)
    }
}
